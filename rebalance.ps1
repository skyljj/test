# PowerShell Script: VM Cluster Rebalance
# Function: Connect to vCenter, rebalance VMs across core-01/core-02/core-03 clusters by buildid algorithm
# Cluster order: [core-02, core-03, core-01] - core-03 is high-performance cluster
#
# Algorithm: cluster = buildid % cluster_count
#            host = (buildid / cluster_count) % host_count
#            ds   = (buildid / cluster_count) % datastore_count
#
# Usage:
#   .\vm_cluster_rebalance.ps1                    # Default run
#   .\vm_cluster_rebalance.ps1 -DryRun            # Analyze only, no migration
#   .\vm_cluster_rebalance.ps1 -SkipVerification  # Skip port verification
#   .\vm_cluster_rebalance.ps1 -NoPrompt          # Auto run, no key prompt
#   .\vm_cluster_rebalance.ps1 -MaxConcurrent 5  # Sliding window: 5 concurrent, start new when any completes
#   .\vm_cluster_rebalance.ps1 -InterMigrationDelay 60  # Wait 60s after each VM for storage to settle
#   .\vm_cluster_rebalance.ps1 -MigrationPlanCsv plan.csv  # Save migration plan to CSV

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_cluster_rebalance_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$MigrationPlanCsv = "vm_cluster_rebalance_migration_plan.csv",
    [Parameter(Mandatory=$false)]
    [int]$MaxConcurrentMigrations = 5,
    [Parameter(Mandatory=$false)]
    [int]$InterMigrationDelaySeconds = 30,
    [Parameter(Mandatory=$false)]
    [int]$InterBatchDelaySeconds = 60,
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

# Migration tuning: MaxConcurrent=5 (up to 5 vMotions at once), InterMigrationDelay=30, InterBatchDelay=60

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
# cluster = vm_id % cluster_count
# host/ds = (vm_id / cluster_count) % host_count  - better distribution when same cluster gets many VMs
function Get-TargetByBuildIdWithinCluster {
    param(
        [int]$BuildId,
        [int]$ClusterCount,
        [array]$Items
    )
    $count = $Items.Count
    if ($count -eq 0) { return $null }
    $groupIndex = [Math]::Floor($BuildId / $ClusterCount)
    $index = $groupIndex % $count
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

    # Get all DatastoreClusters first - Get-DatastoreCluster -Name often returns nothing when DSC is in a different Datacenter
    $allDSCs = @(Get-DatastoreCluster -ErrorAction SilentlyContinue)

    # Datastore Cluster: DSC-core-01 (prod/uat), DSC-core-01-nonprod (dev/qa)
    # Filter from all DSCs - -Name lookup can fail when DSC is in specific Datacenter
    $dscProdName = "DSC-$ClusterName"
    $dscNonprodNames = @("DSC-$ClusterName-nonprod", "DSC-$ClusterName-Nonprod")
    $dscProd = $allDSCs | Where-Object { $_.Name -eq $dscProdName } | Select-Object -First 1
    $dscNonprod = $null
    foreach ($name in $dscNonprodNames) {
        $dscNonprod = $allDSCs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($dscNonprod) { break }
    }

    $datastoresProd = @()
    $datastoresNonprod = @()

    # Get datastores: use -Location (explicit) as primary, pipe as fallback
    if ($dscProd) {
        $dsRaw = Get-Datastore -Location $dscProd -ErrorAction SilentlyContinue
        $datastoresProd = @($dsRaw | Where-Object { $_.State -eq "Connected" } | Sort-Object Name)
    }

    if ($dscNonprod) {
        $dsRaw = Get-Datastore -Location $dscNonprod -ErrorAction SilentlyContinue
        $datastoresNonprod = @($dsRaw | Where-Object { $_.State -eq "Connected" } | Sort-Object Name)
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

# Migrate single VM - waits for vMotion task to complete before returning
# Use -RunAsync to get Task object for explicit task-based waiting
function Move-VMToTarget {
    param(
        [object]$VM,
        [object]$DestinationHost,
        [object]$DestinationDatastore,
        [string]$TargetClusterName,
        [switch]$RunAsync = $false
    )
    try {
        $vmName = if ($VM) { $VM.Name } else { "null" }
        $hostName = if ($DestinationHost) { $DestinationHost.Name } else { "null" }
        $dsName = if ($DestinationDatastore) { $DestinationDatastore.Name } else { "null" }
        if (-not $VM -or -not $DestinationHost -or -not $DestinationDatastore) {
            Write-Log "Move-VMToTarget: invalid params (VM=$vmName, Host=$hostName, DS=$dsName)" "ERROR"
            return @{ Success = $false; Task = $null; VM = $VM }
        }
        Write-Log "Migrating VM: $vmName -> Cluster: $TargetClusterName, Host: $hostName, Datastore: $dsName"
        if ($RunAsync) {
            $task = Move-VM -VM $VM -Destination $DestinationHost -Datastore $DestinationDatastore -Confirm:$false -RunAsync -ErrorAction Stop
            return @{ Success = $true; Task = $task; VM = $VM }
        } else {
            Move-VM -VM $VM -Destination $DestinationHost -Datastore $DestinationDatastore -Confirm:$false -ErrorAction Stop
            Write-Log "VM $vmName migration completed (task finished)" "SUCCESS"
            return @{ Success = $true; Task = $null; VM = $VM }
        }
    } catch {
        Write-Log "VM $vmName migration failed: $($_.Exception.Message)" "ERROR"
        return @{ Success = $false; Task = $null; VM = $VM }
    }
}

# Wait for vMotion task(s) to complete - polls until all tasks done or timeout
# Task State: Success, Running, Queued, Error, Unknown (refresh via Get-Task for current state)
function Wait-ForMigrationTasks {
    param(
        [array]$TaskResults,
        [int]$TimeoutMinutes = 120
    )
    $tasks = $TaskResults | Where-Object { $_.Task -ne $null } | ForEach-Object { $_.Task }
    if ($tasks.Count -eq 0) { return $true }
    $timeoutSec = $TimeoutMinutes * 60
    $elapsed = 0
    $pollInterval = 15
    while ($elapsed -lt $timeoutSec) {
        $running = 0
        foreach ($t in $tasks) {
            $refreshed = Get-Task -Id $t.Id -ErrorAction SilentlyContinue
            if ($refreshed -and ($refreshed.State -eq 'Running' -or $refreshed.State -eq 'Queued')) { $running++ }
        }
        if ($running -eq 0) { break }
        Write-Log "Waiting for $running migration task(s)... (${elapsed}s elapsed)" "INFO"
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }
    foreach ($tr in $TaskResults) {
        if ($tr.Task -and ($tr.Task.State -eq 'error' -or $tr.Task.State -eq 'Error')) {
            Write-Log "VM $($tr.VM.Name) migration task failed" "ERROR"
            return $false
        }
    }
    if ($elapsed -ge $timeoutSec) {
        Write-Log "Migration task(s) timeout after $TimeoutMinutes minutes" "ERROR"
        return $false
    }
    return $true
}

# Main logic
function Main {
    Write-Log "========== VM Cluster Rebalance Started =========="
    Write-Log "Log file: $LogFile"
    Write-Log "MaxConcurrent: $MaxConcurrentMigrations (sliding window), InterMigrationDelay: ${InterMigrationDelaySeconds}s"
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

            $clusterCount = $vsphereClusters.Count
            $targetHost = Get-TargetByBuildIdWithinCluster -BuildId $buildId -ClusterCount $clusterCount -Items $resources.Hosts
            $targetDs = Get-TargetByBuildIdWithinCluster -BuildId $buildId -ClusterCount $clusterCount -Items $targetDatastores

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

        # Save migration plan to CSV
        if ($migrationPlan.Count -gt 0) {
            $csvData = $migrationPlan | ForEach-Object {
                [PSCustomObject]@{
                    VMName          = $_.VM.Name
                    BuildId         = $_.BuildId
                    VMEnvironment   = $_.VMEnvironment
                    CurrentCluster  = $_.CurrentCluster
                    TargetCluster   = $_.TargetCluster
                    TargetHost      = $_.TargetHost.Name
                    TargetDatastore = $_.TargetDatastore.Name
                }
            }
            $csvData | Export-Csv -Path $MigrationPlanCsv -NoTypeInformation -Encoding UTF8
            Write-Log "Migration plan saved to $MigrationPlanCsv" "INFO"
        }

        if ($migrationPlan.Count -eq 0) {
            Write-Log "All VMs already in correct clusters, no migration needed" "SUCCESS"
            return
        }

        # 4. Execute migration - sliding window: keep 5 running, start new when one completes
        $successCount = 0
        $failCount = 0
        $allSuccess = @()

        if ($DryRun) {
            foreach ($item in $migrationPlan) {
                Write-Log "[DRY RUN] $($item.VM.Name) [env=$($item.VMEnvironment)]: $($item.CurrentCluster) -> $($item.TargetCluster) (Host: $($item.TargetHost.Name), DS: $($item.TargetDatastore.Name))" "INFO"
            }
        } else {
            $running = @()  # array of @{ Task; Item }
            $pollInterval = 10

            if ($MaxConcurrentMigrations -eq 1) {
                # One at a time: sync Move-VM, verify Linux immediately when done
                $totalToMigrate = $migrationPlan.Count
                $completed = 0
                foreach ($item in $migrationPlan) {
                    $result = Move-VMToTarget -VM $item.VM -DestinationHost $item.TargetHost -DestinationDatastore $item.TargetDatastore -TargetClusterName $item.TargetCluster
                    if ($result.Success) {
                        $allSuccess += $item
                        $successCount++
                        $completed++
                        if (-not $SkipVerification -and $JumpHostConfig.Host -and $item.VM.Name -match "linux") {
                            $waitSec = [Math]::Min($VerificationTimeoutSeconds, 30)
                            Start-Sleep -Seconds $waitSec
                            $verified = Test-VMReachable -VMName $item.VM.Name -JumpConfig $JumpHostConfig -TimeoutSeconds 30
                            if ($verified) { Write-Log "VM $($item.VM.Name) verified (SSH 22 reachable)" "SUCCESS" }
                            else { Write-Log "ALERT: VM $($item.VM.Name) SSH port 22 not reachable after migration!" "ALERT" }
                        }
                    } else {
                        $failCount++
                    }
                    if ($InterMigrationDelaySeconds -gt 0 -and $item -ne $migrationPlan[-1]) {
                        Start-Sleep -Seconds $InterMigrationDelaySeconds
                    }
                }
            } else {
                # Sliding window: keep MaxConcurrent running, start new when one completes
                Write-Log "Sliding window: up to $MaxConcurrentMigrations concurrent, start new when any completes" "INFO"
                $totalToMigrate = $migrationPlan.Count
                $completed = 0
                $queue = @($migrationPlan)  # Fixed array - use index to avoid ArrayList issues
                $queueIndex = 0

                while ($queueIndex -lt $queue.Count -or $running.Count -gt 0) {
                    # Check completed tasks
                    $stillRunning = @()
                    foreach ($r in $running) {
                        $refreshed = Get-Task -Id $r.Task.Id -ErrorAction SilentlyContinue
                        $state = if ($refreshed) { $refreshed.State.ToString() } else { 'Unknown' }
                        if ($state -eq 'Success') {
                            $allSuccess += $r.Item
                            $successCount++
                            $completed++
                            Write-Log "VM $($r.Item.VM.Name) done ($completed/$totalToMigrate). Starting next..." "SUCCESS"
                            # Verify Linux VM immediately if jump host configured
                            if (-not $SkipVerification -and $JumpHostConfig.Host -and $r.Item.VM.Name -match "linux") {
                                $waitSec = [Math]::Min($VerificationTimeoutSeconds, 30)
                                Start-Sleep -Seconds $waitSec
                                $verified = Test-VMReachable -VMName $r.Item.VM.Name -JumpConfig $JumpHostConfig -TimeoutSeconds 30
                                if ($verified) { Write-Log "VM $($r.Item.VM.Name) verified (SSH 22 reachable)" "SUCCESS" }
                                else { Write-Log "ALERT: VM $($r.Item.VM.Name) SSH port 22 not reachable after migration!" "ALERT" }
                            }
                            # Start next from queue
                            if ($queueIndex -lt $queue.Count) {
                                if ($InterMigrationDelaySeconds -gt 0) { Start-Sleep -Seconds $InterMigrationDelaySeconds }
                                $item = $queue[$queueIndex]; $queueIndex++
                                if ($item.VM -and $item.TargetHost -and $item.TargetDatastore) {
                                    $res = Move-VMToTarget -VM $item.VM -DestinationHost $item.TargetHost -DestinationDatastore $item.TargetDatastore -TargetClusterName $item.TargetCluster -RunAsync
                                    if ($res.Success) { $stillRunning += @{ Task = $res.Task; Item = $item } } else { $failCount++; $completed++ }
                                } else { Write-Log "Skip invalid item at index $($queueIndex-1)" "WARNING"; $failCount++; $completed++ }
                            }
                        } elseif ($state -eq 'Error') {
                            $failCount++
                            $completed++
                            Write-Log "VM $($r.Item.VM.Name) migration failed" "ERROR"
                            if ($queueIndex -lt $queue.Count) {
                                if ($InterMigrationDelaySeconds -gt 0) { Start-Sleep -Seconds $InterMigrationDelaySeconds }
                                $item = $queue[$queueIndex]; $queueIndex++
                                if ($item.VM -and $item.TargetHost -and $item.TargetDatastore) {
                                    $res = Move-VMToTarget -VM $item.VM -DestinationHost $item.TargetHost -DestinationDatastore $item.TargetDatastore -TargetClusterName $item.TargetCluster -RunAsync
                                    if ($res.Success) { $stillRunning += @{ Task = $res.Task; Item = $item } } else { $failCount++; $completed++ }
                                } else { Write-Log "Skip invalid item at index $($queueIndex-1)" "WARNING"; $failCount++; $completed++ }
                            }
                        } else {
                            $stillRunning += $r
                        }
                    }
                    $running = $stillRunning

                    # Fill pool up to MaxConcurrentMigrations
                    while ($running.Count -lt $MaxConcurrentMigrations -and $queueIndex -lt $queue.Count) {
                        if ($InterMigrationDelaySeconds -gt 0 -and $running.Count -gt 0) { Start-Sleep -Seconds $InterMigrationDelaySeconds }
                        $item = $queue[$queueIndex]; $queueIndex++
                        if ($item.VM -and $item.TargetHost -and $item.TargetDatastore) {
                            $res = Move-VMToTarget -VM $item.VM -DestinationHost $item.TargetHost -DestinationDatastore $item.TargetDatastore -TargetClusterName $item.TargetCluster -RunAsync
                            if ($res.Success) { $running += @{ Task = $res.Task; Item = $item } } else { $failCount++; $completed++ }
                        } else { Write-Log "Skip invalid item at index $($queueIndex-1)" "WARNING"; $failCount++; $completed++ }
                    }

                    if ($running.Count -gt 0) {
                        Start-Sleep -Seconds $pollInterval
                    }
                }
            }

            # Linux VMs verified immediately when each migration completes
            if (($allSuccess | Where-Object { $_.VM.Name -notmatch "linux" }).Count -gt 0) {
                Write-Log "$(($allSuccess | Where-Object { $_.VM.Name -notmatch "linux" }).Count) non-Linux VM(s) migrated, verification skipped" "INFO"
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
