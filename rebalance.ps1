# PowerShell Script: VM Cluster Rebalance
# Function: Connect to vCenter, rebalance VMs across core-01/core-02/core-03 clusters by buildid algorithm
# Cluster order: [core-02, core-03, core-01] - core-03 is high-performance cluster
#
# Algorithm: buildid = digits from VM name, index = buildid % 3, cluster = vsphere_cluster[index]
#            ESXi/Datastore distributed by buildid % count
#
# Usage:
#   .\vm_cluster_rebalance.ps1                    # Default run
#   .\vm_cluster_rebalance.ps1 -DryRun            # Analyze only, no migration
#   .\vm_cluster_rebalance.ps1 -BatchSize 3       # 3 VMs per batch
#   .\vm_cluster_rebalance.ps1 -SkipVerification  # Skip port verification
#   .\vm_cluster_rebalance.ps1 -NoPrompt          # Auto run, no key prompt

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_cluster_rebalance_log.txt",
    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 5,
    [Parameter(Mandatory=$false)]
    [switch]$DryRun = $false,
    [Parameter(Mandatory=$false)]
    [switch]$SkipVerification = $false,
    [Parameter(Mandatory=$false)]
    [int]$VerificationTimeoutSeconds = 30,
    [Parameter(Mandatory=$false)]
    [string[]]$ExclusionKeywords = @("vcls", "svm", "hci", "template"),
    [Parameter(Mandatory=$false)]
    [switch]$NoPrompt = $false
)

# ============ Configuration - Edit for your environment ============
# vCenter connection
$vCenterConfig = @{
    Server   = "vcenter.company.com"
    User     = "administrator@vsphere.local"
    Password = "your_password"
}

# Cluster order: [core-02, core-03, core-01] - core-03 is high-performance
$vsphereClusters = @("core-02", "core-03", "core-01")

# Jump host config - for VM connectivity verification (Linux VMs only via SSH port 22)
# Leave Host empty if VMs are reachable from local machine
$JumpHostConfig = @{
    Host     = "jump.company.com"   # Jump host address, empty "" for local verification
    User     = "admin"              # SSH username (jump host)
    Password = ""                   # Jump host password, empty for SSH key (ssh-copy-id)
    Port     = 22                   # SSH port
}

# Only verify VMs with "linux" in name, using SSH port 22
$VMVerificationPorts = @(22)

# ============ Script logic ============
# Cluster resources cache
$script:ClusterResourcesCache = @{}

# Import VMware PowerCLI module
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Write-Host "VMware PowerCLI module loaded successfully" -ForegroundColor Green
} catch {
    Write-Error "Cannot import VMware PowerCLI module. Please ensure VMware PowerCLI is installed."
    exit 1
}

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
Set-PowerCLIConfiguration -DefaultVIServerMode Single -Confirm:$false

# Log function
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "ALERT"   { "Magenta" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

# Extract buildid (digits) from VM name
function Get-BuildIdFromVMName {
    param([string]$VMName)
    if ($VMName -match '(\d+)') {
        return [int]$Matches[1]
    }
    return 0
}

# Calculate target cluster by buildid
function Get-TargetCluster {
    param(
        [int]$BuildId,
        [string[]]$Clusters
    )
    $clusterLength = $Clusters.Count
    if ($clusterLength -eq 0) { return $null }
    $index = $BuildId % $clusterLength
    return $Clusters[$index]
}

# Select target from list by buildid (ESXi or Datastore)
function Get-TargetByBuildId {
    param(
        [int]$BuildId,
        [array]$Items
    )
    $count = $Items.Count
    if ($count -eq 0) { return $null }
    $index = $BuildId % $count
    return $Items[$index]
}

# Connect to vCenter
function Connect-ToVCenter {
    param([hashtable]$Config)
    try {
        Write-Log "Connecting to vCenter: $($Config.Server)..."
        $securePassword = ConvertTo-SecureString $Config.Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($Config.User, $securePassword)
        $connection = Connect-VIServer -Server $Config.Server -Credential $credential -ErrorAction Stop
        Write-Log "Connected to vCenter successfully" "SUCCESS"
        return $connection
    } catch {
        Write-Log "Failed to connect to vCenter: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Get all VMs from the three clusters
function Get-AllVMsFromClusters {
    param(
        [string[]]$ClusterNames
    )
    $allVMs = @()
    foreach ($clusterName in $ClusterNames) {
        $cluster = Get-Cluster -Name $clusterName -ErrorAction SilentlyContinue
        if (-not $cluster) {
            Write-Log "Cluster not found: $clusterName" "WARNING"
            continue
        }
        $vms = Get-VM -Location $cluster -ErrorAction SilentlyContinue
        foreach ($vm in $vms) {
            # Exclude VMs containing keywords or templates
            $vmNameLower = $vm.Name.ToLower()
            $excluded = $false
            foreach ($kw in $ExclusionKeywords) {
                if ($vmNameLower -like "*$($kw.ToLower())*") {
                    $excluded = $true
                    Write-Log "Excluding VM: $($vm.Name) (contains keyword: $kw)" "INFO"
                    break
                }
            }
            if (-not $excluded) {
                $allVMs += $vm
            }
        }
    }
    return $allVMs
}

# Get VM's current cluster
function Get-VMCurrentCluster {
    param([object]$VM)
    $vmHost = $VM | Get-VMHost -ErrorAction SilentlyContinue
    if (-not $vmHost) { return $null }
    $cluster = $vmHost | Get-Cluster -ErrorAction SilentlyContinue
    return $cluster.Name
}

# Get VM environment (prod/uat vs dev/qa) - determined by folder path
# folder contains qa/dev -> nonprod (DSC-xxx-nonprod), contains prod/uat -> prod (DSC-xxx)
function Get-VMEnvironmentFromFolder {
    param([object]$VM)
    $folderPath = ""
    try {
        $f = $VM.Folder
        while ($f -and $f.Name) {
            $folderPath = $f.Name + "/" + $folderPath
            $f = $f.Parent
        }
        $folderPath = $folderPath.TrimEnd("/").ToLower()
    } catch {
        return "prod"  # default prod
    }
    if ($folderPath -match "qa|dev") {
        return "nonprod"
    }
    if ($folderPath -match "prod|uat") {
        return "prod"
    }
    return "prod"  # default prod
}

# Get target cluster's ESXi hosts and Datastore list
# Each cluster: DSC-{cluster} (prod/uat), DSC-{cluster}-nonprod (dev/qa)
function Get-ClusterResources {
    param([string]$ClusterName)
    if ($script:ClusterResourcesCache.ContainsKey($ClusterName)) {
        return $script:ClusterResourcesCache[$ClusterName]
    }
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $cluster) {
        Write-Log "Cluster not found: $ClusterName" "ERROR"
        return $null
    }
    $hosts = @(Get-VMHost -Location $cluster -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionState -eq "Connected" } | Sort-Object Name)
    # Datastore Cluster: DSC-core-01 (prod/uat), DSC-core-01-nonprod (dev/qa)
    $dscProd = Get-DatastoreCluster -Name "DSC-$ClusterName" -ErrorAction SilentlyContinue
    $dscNonprod = Get-DatastoreCluster -Name "DSC-$ClusterName-Nonprod" -ErrorAction SilentlyContinue
    $datastoresProd = @()
    $datastoresNonprod = @()
    if ($dscProd) {
        $datastoresProd = @($dscProd | Get-Datastore -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Connected" } | Sort-Object Name)
    }
    if ($dscNonprod) {
        $datastoresNonprod = @($dscNonprod | Get-Datastore -ErrorAction SilentlyContinue | Where-Object { $_.State -eq "Connected" } | Sort-Object Name)
    }
    $result = @{
        Cluster          = $cluster
        Hosts            = $hosts
        DatastoresProd   = $datastoresProd
        DatastoresNonprod = $datastoresNonprod
    }
    $script:ClusterResourcesCache[$ClusterName] = $result
    return $result
}

# Check VM port reachability via jump host (uses vm_name as target, jump host must resolve it)
# Supports password login: use sshpass or plink when JumpHostConfig.Password is set
function Test-VMPortViaJumpHost {
    param(
        [string]$JumpHost,
        [string]$JumpUser,
        [string]$JumpPassword,
        [string]$VMName,
        [int]$VMPort,
        [int]$TimeoutSeconds = 10
    )
    if ([string]::IsNullOrWhiteSpace($VMName)) {
        return $false
    }
    $timeout = [Math]::Min($TimeoutSeconds, 15)
    $remoteCmd = "nc -zv -w $timeout $VMName $VMPort 2>&1; exit `$?"
    $target = "${JumpUser}@${JumpHost}"

    try {
        if ($JumpPassword) {
            # Password login: prefer sshpass (Linux/Git Bash), fallback plink (Windows PuTTY)
            $sshpass = Get-Command sshpass -ErrorAction SilentlyContinue
            $plink = Get-Command plink -ErrorAction SilentlyContinue
            if ($sshpass) {
                $env:SSHPASS = $JumpPassword
                $result = & sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $target $remoteCmd 2>$null
                Remove-Item Env:\SSHPASS -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) { return $true }
            } elseif ($plink) {
                $result = & plink -batch -pw $JumpPassword $target $remoteCmd 2>$null
                if ($LASTEXITCODE -eq 0) { return $true }
            } else {
                Write-Log "Jump host password configured but sshpass or plink not found. Install one or use SSH key" "WARNING"
                return $false
            }
        } else {
            # Key-based login
            $result = & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $target $remoteCmd 2>$null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
        # Fallback: bash /dev/tcp
        $cmdBash = "timeout $timeout bash -c 'echo >/dev/tcp/$VMName/$VMPort' 2>/dev/null; exit `$?"
        if ($JumpPassword -and (Get-Command sshpass -ErrorAction SilentlyContinue)) {
            $env:SSHPASS = $JumpPassword
            $null = & sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $target $cmdBash 2>$null
            Remove-Item Env:\SSHPASS -ErrorAction SilentlyContinue
        } elseif (-not $JumpPassword) {
            $null = & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $target $cmdBash 2>$null
        }
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

# Verify VM reachability (uses vm_name directly, jump host/local must resolve vm_name)
function Test-VMReachable {
    param(
        [string]$VMName,
        [hashtable]$JumpConfig,
        [int]$TimeoutSeconds = 60
    )
    # If jump host configured, verify via jump host
    if ($JumpConfig.Host) {
        $jumpPwd = if ($JumpConfig.Password) { $JumpConfig.Password } else { "" }
        foreach ($port in $VMVerificationPorts) {
            $ok = Test-VMPortViaJumpHost -JumpHost $JumpConfig.Host -JumpUser $JumpConfig.User -JumpPassword $jumpPwd -VMName $VMName -VMPort $port -TimeoutSeconds 10
            if ($ok) {
                Write-Log "VM $VMName port $port reachable" "SUCCESS"
                return $true
            }
        }
    } else {
        # No jump host, try local Test-NetConnection
        foreach ($port in $VMVerificationPorts) {
            try {
                $result = Test-NetConnection -ComputerName $VMName -Port $port -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($result.TcpTestSucceeded) {
                    Write-Log "VM $VMName port $port reachable" "SUCCESS"
                    return $true
                }
            } catch { }
        }
    }
    Write-Log "VM $VMName ports $($VMVerificationPorts -join '/') not reachable" "WARNING"
    return $false
}

# Migrate single VM
function Move-VMToTarget {
    param(
        [object]$VM,
        [object]$DestinationHost,
        [object]$DestinationDatastore,
        [string]$TargetClusterName
    )
    try {
        Write-Log "Migrating VM: $($VM.Name) -> Cluster: $TargetClusterName, Host: $($DestinationHost.Name), Datastore: $($DestinationDatastore.Name)"
        Move-VM -VM $VM -Destination $DestinationHost -Datastore $DestinationDatastore -Confirm:$false -ErrorAction Stop
        Write-Log "VM $($VM.Name) migration command executed" "SUCCESS"
        return $true
    } catch {
        Write-Log "VM $($VM.Name) migration failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Main logic
function Main {
    Write-Log "========== VM Cluster Rebalance Started =========="
    Write-Log "Log file: $LogFile"
    Write-Log "Batch size: $BatchSize"
    Write-Log "Cluster order: $($vsphereClusters -join ', ')"
    if ($DryRun) {
        Write-Log "[DRY RUN] Analyze only, no migration" "WARNING"
    }

    $connection = Connect-ToVCenter -Config $vCenterConfig
    if (-not $connection) {
        Write-Log "Cannot connect to vCenter, exiting" "ERROR"
        return
    }

    try {
        # 1. Get all VMs from the three clusters
        Write-Log "Reading VMs from clusters $($vsphereClusters -join ', ')..."
        $allVMs = Get-AllVMsFromClusters -ClusterNames $vsphereClusters
        Write-Log "Found $($allVMs.Count) VMs"

        if ($allVMs.Count -eq 0) {
            Write-Log "No VMs to process" "WARNING"
            return
        }

        # 2. Pre-fetch cluster Host and Datastore Cluster resources
        $clusterResources = @{}
        foreach ($clusterName in $vsphereClusters) {
            $res = Get-ClusterResources -ClusterName $clusterName
            $clusterResources[$clusterName] = $res
            if ($res) {
                Write-Log "Cluster $clusterName: $($res.Hosts.Count) Hosts, DSC-prod: $($res.DatastoresProd.Count) DS, DSC-nonprod: $($res.DatastoresNonprod.Count) DS" "INFO"
            } else {
                Write-Log "Cluster $clusterName resource fetch failed" "WARNING"
            }
        }

        # 3. Analyze each VM for migration target
        $migrationPlan = @()
        foreach ($vm in $allVMs) {
            $buildId = Get-BuildIdFromVMName -VMName $vm.Name
            $targetCluster = Get-TargetCluster -BuildId $buildId -Clusters $vsphereClusters
            $currentCluster = Get-VMCurrentCluster -VM $vm
            $vmEnvironment = Get-VMEnvironmentFromFolder -VM $vm

            if (-not $targetCluster) {
                Write-Log "VM $($vm.Name) buildid=$buildId cannot determine target cluster, skipping" "WARNING"
                continue
            }

            if ($currentCluster -eq $targetCluster) {
                Write-Log "VM $($vm.Name) already in target cluster $targetCluster, no migration needed" "INFO"
                continue
            }

            $resources = $clusterResources[$targetCluster]
            if (-not $resources -or $resources.Hosts.Count -eq 0) {
                Write-Log "Target cluster $targetCluster has no available Host, skipping VM $($vm.Name)" "ERROR"
                continue
            }

            $targetDatastores = if ($vmEnvironment -eq "nonprod") { $resources.DatastoresNonprod } else { $resources.DatastoresProd }
            if (-not $targetDatastores -or $targetDatastores.Count -eq 0) {
                $dscName = if ($vmEnvironment -eq "nonprod") { "DSC-$targetCluster-Nonprod" } else { "DSC-$targetCluster" }
                Write-Log "Target $dscName has no available Datastore, skipping VM $($vm.Name) (env=$vmEnvironment)" "ERROR"
                continue
            }

            $targetHost = Get-TargetByBuildId -BuildId $buildId -Items $resources.Hosts
            $targetDs = Get-TargetByBuildId -BuildId $buildId -Items $targetDatastores

            $migrationPlan += [PSCustomObject]@{
                VM              = $vm
                BuildId         = $buildId
                VMEnvironment   = $vmEnvironment
                CurrentCluster  = $currentCluster
                TargetCluster   = $targetCluster
                TargetHost      = $targetHost
                TargetDatastore = $targetDs
            }
        }

        Write-Log "VMs to migrate: $($migrationPlan.Count)"
        foreach ($item in $migrationPlan) {
            Write-Log "  [env=$($item.VMEnvironment)] $($item.VM.Name): $($item.CurrentCluster) -> $($item.TargetCluster) (DS: $($item.TargetDatastore.Name))" "INFO"
        }

        if ($migrationPlan.Count -eq 0) {
            Write-Log "All VMs already in correct clusters, no migration needed" "SUCCESS"
            return
        }

        # 4. Execute migration in batches
        $totalBatches = [Math]::Ceiling($migrationPlan.Count / $BatchSize)
        $batchIndex = 0
        $successCount = 0
        $failCount = 0

        for ($i = 0; $i -lt $migrationPlan.Count; $i += $BatchSize) {
            $batchIndex++
            $batch = $migrationPlan[$i..([Math]::Min($i + $BatchSize - 1, $migrationPlan.Count - 1))]
            Write-Log "---------- Batch $batchIndex / $totalBatches ($($batch.Count) VMs) ----------"

            if ($DryRun) {
                foreach ($item in $batch) {
                    Write-Log "[DRY RUN] $($item.VM.Name) [env=$($item.VMEnvironment)]: $($item.CurrentCluster) -> $($item.TargetCluster) (Host: $($item.TargetHost.Name), DS: $($item.TargetDatastore.Name))" "INFO"
                }
                continue
            }

            # Execute batch migration
            $batchSuccess = @()
            foreach ($item in $batch) {
                $ok = Move-VMToTarget -VM $item.VM -DestinationHost $item.TargetHost -DestinationDatastore $item.TargetDatastore -TargetClusterName $item.TargetCluster
                if ($ok) {
                    $batchSuccess += $item
                } else {
                    $failCount++
                }
            }

            # Only verify Linux VMs via jump host SSH, skip other VMs
            if ($batchSuccess.Count -gt 0 -and -not $SkipVerification -and $JumpHostConfig.Host) {
                $linuxBatch = @($batchSuccess | Where-Object { $_.VM.Name -match "linux" })
                $nonLinuxBatch = @($batchSuccess | Where-Object { $_.VM.Name -notmatch "linux" })
                if ($linuxBatch.Count -gt 0) {
                    $waitSec = [Math]::Min($VerificationTimeoutSeconds, 30)
                    Write-Log "Waiting $waitSec seconds before verifying $($linuxBatch.Count) Linux VM(s) connectivity (SSH 22)..."
                    Start-Sleep -Seconds $waitSec

                    foreach ($item in $linuxBatch) {
                        $vmName = $item.VM.Name
                        $verified = Test-VMReachable -VMName $vmName -JumpConfig $JumpHostConfig -TimeoutSeconds 30
                        if ($verified) {
                            $successCount++
                            Write-Log "VM $vmName migrated and verified (SSH 22 reachable)" "SUCCESS"
                        } else {
                            Write-Log "ALERT: VM $vmName SSH port 22 not reachable after migration, manual check required!" "ALERT"
                            $successCount++
                        }
                    }
                }
                if ($nonLinuxBatch.Count -gt 0) {
                    $successCount += $nonLinuxBatch.Count
                    Write-Log "$($nonLinuxBatch.Count) non-Linux VM(s) migrated, verification skipped" "INFO"
                }
            } elseif ($batchSuccess.Count -gt 0) {
                $successCount += $batchSuccess.Count
                Write-Log "Verification skipped, assuming $($batchSuccess.Count) migration(s) successful" "INFO"
            }

            # Brief pause between batches to reduce vCenter load
            if ($i + $BatchSize -lt $migrationPlan.Count) {
                Write-Log "Waiting 10 seconds before next batch..."
                Start-Sleep -Seconds 10
            }
        }

        # Summary
        Write-Log ""
        Write-Log "========== Execution Complete ==========" "INFO"
        Write-Log "Success: $successCount, Failed: $failCount"
    } finally {
        try {
            Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Disconnected from vCenter"
        } catch {
            Write-Log "Error during disconnect: $($_.Exception.Message)" "WARNING"
        }
    }
}

Main

if (-not $NoPrompt) {
    Write-Host "Script completed. Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
