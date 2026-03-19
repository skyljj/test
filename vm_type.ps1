# PowerShell Script: Export VM inventory (type by folder name) to CSV
# Function: Connect to defined vCenters, list ALL VMs, classify by VM folder name:
#   - folder name contains "linux"   -> linux
#   - folder name contains "windows" -> windows
#   - otherwise                      -> ovf
# Export CSV columns: vc, vm_name, type, power_state

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_inventory_export_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$OutputCsv = "vm_inventory_export.csv"
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

# 定义需要处理的vCenter列表 - 只有在此配置的vCenter才会被处理
$vCentersToProcess = @(
    "vCenter1",
    "vCenter2"
    # 可在此添加更多 vCenter 名称
)

# vCenter服务器配置
$vCenters = @(
    @{Name="vCenter1"; Server="vcenter1.company.com"; User="administrator@vsphere.local"; Password="password1"},
    @{Name="vCenter2"; Server="vcenter2.company.com"; User="administrator@vsphere.local"; Password="password2"},
    @{Name="vCenter3"; Server="vcenter3.company.com"; User="administrator@vsphere.local"; Password="password3"}
    # 可在此添加更多 vCenter 配置
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
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
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

function Get-VmTypeByFolderName {
    param(
        [string]$FolderName
    )
    if ([string]::IsNullOrWhiteSpace($FolderName)) { return "ovf" }
    $n = $FolderName.ToLowerInvariant()
    if ($n -like "*linux*") { return "linux" }
    if ($n -like "*windows*") { return "windows" }
    return "ovf"
}

# 主执行逻辑
function Main {
    Write-Log "Starting VM inventory export task"
    Write-Log "Log file: $LogFile"
    Write-Log "Output CSV: $OutputCsv"

    $rows = @()
    $totalVCProcessed = 0
    $totalVMs = 0
    $typeCounts = @{ linux = 0; windows = 0; ovf = 0 }

    foreach ($vCenter in $vCenters) {
        if ($vCenter.Name -notin $vCentersToProcess) {
            Write-Log "vCenter $($vCenter.Name) not in processing list, skipping" "INFO"
            continue
        }

        Write-Log "Processing vCenter: $($vCenter.Name)"
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }

        $totalVCProcessed++

        try {
            Write-Log "Getting all VMs in $($vCenter.Name)..."
            $allVMs = Get-VM

            if (-not $allVMs -or $allVMs.Count -eq 0) {
                Write-Log "No VMs found in $($vCenter.Name)" "WARNING"
                continue
            }

            Write-Log "Found $($allVMs.Count) VMs in $($vCenter.Name)"
            $totalVMs += $allVMs.Count

            foreach ($vm in $allVMs) {
                $folderName = $null
                try {
                    $folderName = $vm.Folder.Name
                } catch {
                    $folderName = $null
                }

                $vmType = Get-VmTypeByFolderName -FolderName $folderName
                $typeCounts[$vmType]++

                $rows += [PSCustomObject]@{
                    vc          = $vCenter.Name
                    vm_name     = $vm.Name
                    type        = $vmType
                    power_state = [string]$vm.PowerState
                }
            }
        } catch {
            Write-Log "Error processing vCenter $($vCenter.Name): $($_.Exception.Message)" "ERROR"
        } finally {
            try {
                Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Disconnected from $($vCenter.Name)"
            } catch {
                Write-Log "Error during disconnect: $($_.Exception.Message)" "WARNING"
            }
        }
    }

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Log "CSV exported: $OutputCsv" "SUCCESS"
    } else {
        Write-Log "No data rows generated; CSV not written" "WARNING"
    }

    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Task Completion Summary" "INFO"
    Write-Log "=================================================================" "INFO"
    Write-Log "Total vCenters processed: $totalVCProcessed"
    Write-Log "Total VMs: $totalVMs"
    Write-Log "Type linux: $($typeCounts.linux)"
    Write-Log "Type windows: $($typeCounts.windows)"
    Write-Log "Type ovf: $($typeCounts.ovf)"
    Write-Log "=================================================================" "INFO"
    Write-Log "Detailed log available at: $LogFile" "INFO"
    Write-Log "=================================================================" "INFO"
}

Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

