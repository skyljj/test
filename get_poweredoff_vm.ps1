# PowerShell Script: Get all powered-off VMs from all vCenters
# Function: Connect to all vCenters, get list of powered-off VMs and save to file

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "get_poweredoff_vm_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "poweredoff_vms.json"
)

# 导入VMware PowerCLI模块
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Write-Host "VMware PowerCLI模块已成功导入" -ForegroundColor Green
} catch {
    Write-Error "Cannot import VMware PowerCLI module. Please ensure VMware PowerCLI is installed."
    exit 1
}

# 设置PowerCLI配置
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Confirm:$false

# vCenter服务器配置
$vCenters = @(
    @{Name="vCenter1"; Server="vcenter1.company.com"; User="administrator@vsphere.local"; Password="password1"},
    @{Name="vCenter2"; Server="vcenter2.company.com"; User="administrator@vsphere.local"; Password="password2"},
    @{Name="vCenter3"; Server="vcenter3.company.com"; User="administrator@vsphere.local"; Password="password3"},
    @{Name="vCenter4"; Server="vcenter4.company.com"; User="administrator@vsphere.local"; Password="password4"},
    @{Name="vCenter5"; Server="vcenter5.company.com"; User="administrator@vsphere.local"; Password="password5"},
    @{Name="vCenter6"; Server="vcenter6.company.com"; User="administrator@vsphere.local"; Password="password6"},
    @{Name="vCenter7"; Server="vcenter7.company.com"; User="administrator@vsphere.local"; Password="password7"},
    @{Name="vCenter8"; Server="vcenter8.company.com"; User="administrator@vsphere.local"; Password="password8"},
    @{Name="vCenter9"; Server="vcenter9.company.com"; User="administrator@vsphere.local"; Password="password9"},
    @{Name="vCenter10"; Server="vcenter10.company.com"; User="administrator@vsphere.local"; Password="password10"}
)

# 日志函数
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogFile -Value $logMessage
}

# 连接到vCenter
function Connect-ToVCenter {
    param(
        [hashtable]$vCenter
    )
    
    try {
        Write-Log "Connecting to $($vCenter.Name) ($($vCenter.Server))..."
        $securePassword = ConvertTo-SecureString $vCenter.Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($vCenter.User, $securePassword)
        
        $connection = Connect-VIServer -Server $vCenter.Server -Credential $credential -ErrorAction Stop
        Write-Log "Successfully connected to $($vCenter.Name)" "SUCCESS"
        return $connection
    } catch {
        Write-Log "Connection failed $($vCenter.Name): $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# 获取已关闭的虚拟机
function Get-PoweredOffVMs {
    param(
        [string]$vCenterName
    )
    
    try {
        Write-Log "Getting powered-off VMs in $vCenterName..."
        $poweredOffVMs = Get-VM | Where-Object { $_.PowerState -eq "PoweredOff" }
        
        $vmList = @()
        foreach ($vm in $poweredOffVMs) {
            $vmInfo = @{
                Name = $vm.Name
                PowerState = $vm.PowerState
                vCenter = $vCenterName
                Id = $vm.Id
                Folder = $vm.Folder.Name
                ResourcePool = $vm.ResourcePool.Name
                Created = $vm.Created
                Notes = $vm.Notes
            }
            $vmList += $vmInfo
        }
        
        Write-Log "Found $($vmList.Count) powered-off VMs in $vCenterName" "SUCCESS"
        return $vmList
    } catch {
        Write-Log "Error getting powered-off VMs in $vCenterName: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting to get all powered-off VMs from all vCenters"
    Write-Log "日志文件: $LogFile"
    Write-Log "输出文件: $OutputFile"
    
    $allPoweredOffVMs = @()
    $totalVMs = 0
    
    foreach ($vCenter in $vCenters) {
        Write-Log "Processing vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }
        
        try {
            # 获取已关闭的虚拟机
            $poweredOffVMs = Get-PoweredOffVMs -vCenterName $vCenter.Name
            $allPoweredOffVMs += $poweredOffVMs
            $totalVMs += $poweredOffVMs.Count
            
        } catch {
            Write-Log "Error processing vCenter $($vCenter.Name): $($_.Exception.Message)" "ERROR"
        } finally {
            # Disconnect
            try {
                Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Disconnected from $($vCenter.Name)"
            } catch {
                Write-Log "Error during disconnect: $($_.Exception.Message)" "WARNING"
            }
        }
    }
    
    # Save results to JSON file
    try {
        $outputData = @{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            TotalCount = $totalVMs
            PoweredOffVMs = $allPoweredOffVMs
        }
        
        $outputData | ConvertTo-Json -Depth 3 | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-Log "Powered-off VM list saved to: $OutputFile" "SUCCESS"
        
        # Also save as CSV format (easy to view in Windows)
        $csvFile = $OutputFile -replace "\.json$", ".csv"
        
        # Create CSV format suitable for Windows viewing
        $csvData = @()
        foreach ($vm in $allPoweredOffVMs) {
            $csvRow = [PSCustomObject]@{
                'VM Name' = $vm.Name
                'Power State' = $vm.PowerState
                'vCenter' = $vm.vCenter
                'VM ID' = $vm.Id
                'Folder' = $vm.Folder
                'Resource Pool' = $vm.ResourcePool
                'Created' = $vm.Created
                'Notes' = $vm.Notes
            }
            $csvData += $csvRow
        }
        
        $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log "Powered-off VM list saved to: $csvFile" "SUCCESS"
        
    } catch {
        Write-Log "Error saving output file: $($_.Exception.Message)" "ERROR"
    }
    
    # Output summary
    Write-Log "Task completion summary:"
    Write-Log "Total vCenters: $($vCenters.Count)"
    Write-Log "Successfully connected vCenters: $($vCenters.Count - (($vCenters | Where-Object { $_.Name -notin $allPoweredOffVMs.vCenter }).Count))"
    Write-Log "Total powered-off VMs: $totalVMs"
    Write-Log "Detailed log available at: $LogFile"
    Write-Log "VM list available at: $OutputFile"
}

# 执行主函数
Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
