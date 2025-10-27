# PowerShell Script: Power off VMs in multiple vCenters and rename
# Function: Connect to 10 vCenters, power off 10 VMs in each vCenter and rename to vm-name_deco

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_poweroff_log.txt"
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

# 定义需要deco的虚拟机映射 - 只有配置了虚拟机的vCenter才会被处理
$vmsToDecoMap = @{
    "vCenter1" = @("vm11", "vm12", "vm13")
    "vCenter2" = @("vm21", "vm22", "vm23")
    # 可在此添加更多 vCenter 和对应 VM 名
}

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

# 关闭并重命名虚拟机
function PowerOffAndRenameVM {
    param(
        [string]$vCenterName,
        [object]$vm
    )
    
    try {
        # 检查虚拟机状态
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Log "Powering off VM: $($vm.Name) in $vCenterName"
            Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Write-Log "VM $($vm.Name) has been successfully powered off" "SUCCESS"
        } else {
            Write-Log "VM $($vm.Name) is already powered off, skipping power off operation"
        }
        
        # Rename VM
        $newName = "$($vm.Name)_deco"
        Write-Log "Renaming VM: $($vm.Name) -> $newName"
        Set-VM -VM $vm -Name $newName -Confirm:$false -ErrorAction Stop
        Write-Log "VM renamed successfully: $($vm.Name) -> $newName" "SUCCESS"
        
        return $true
    } catch {
        Write-Log "Error processing VM $($vm.Name): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting VM power off and rename task"
    Write-Log "Log file: $LogFile"
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    $totalNotFound = 0
    $notFoundList = @()
    $failedList = @()
    $totalToProcess = 0
    
    foreach ($vCenter in $vCenters) {
        # 检查是否配置了需要处理的虚拟机
        if (-not $vmsToDecoMap.ContainsKey($vCenter.Name)) {
            Write-Log "No VMs configured for deco in $($vCenter.Name), skipping this vCenter" "INFO"
            continue
        }
        
        Write-Log "Processing vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }
        
        try {
            # Get list of VMs that need deco
            Write-Log "Getting list of VMs that need deco in $($vCenter.Name)..."
            $vmNames = $vmsToDecoMap[$vCenter.Name]
            $totalToProcess += $vmNames.Count
            
            $vms = @()
            foreach ($vmName in $vmNames) {
                $vmObj = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if ($vmObj) {
                    $vms += $vmObj
                } else {
                    $totalNotFound++
                    $notFoundInfo = @{
                        vCenter = $vCenter.Name
                        VMName = $vmName
                    }
                    $notFoundList += $notFoundInfo
                    Write-Log "VM not found: $vmName in $($vCenter.Name)" "WARNING"
                }
            }
            
            if ($vms.Count -eq 0) {
                Write-Log "No VMs found in $($vCenter.Name)" "WARNING"
                continue
            }
            
            Write-Log "Found $($vms.Count) VMs in $($vCenter.Name)"
            
            # Process each VM
            foreach ($vm in $vms) {
                $totalProcessed++
                Write-Log "Processing VM: $($vm.Name) (#$totalProcessed)"
                
                $result = PowerOffAndRenameVM -vCenterName $vCenter.Name -vm $vm
                if ($result) {
                    $totalSuccess++
                } else {
                    $totalFailed++
                    $failedInfo = @{
                        vCenter = $vCenter.Name
                        VMName = $vm.Name
                    }
                    $failedList += $failedInfo
                }
            }
            
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
    
    # Output summary
    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Task Completion Summary" "INFO"
    Write-Log "=================================================================" "INFO"
    Write-Log "Total VMs to process: $totalToProcess"
    Write-Log "Total VMs not found: $totalNotFound"
    Write-Log "Total VMs processed: $totalProcessed"
    Write-Log "Successfully processed: $totalSuccess"
    Write-Log "Failed: $totalFailed"
    Write-Log ""
    
    # Output not found VM list
    if ($notFoundList.Count -gt 0) {
        Write-Log "VMs Not Found List:" "WARNING"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $notFoundList) {
            Write-Log "  vCenter: $($item.vCenter) | VM: $($item.VMName)" "WARNING"
        }
        Write-Log ""
    }
    
    # Output failed VM list
    if ($failedList.Count -gt 0) {
        Write-Log "Failed VMs List:" "ERROR"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $failedList) {
            Write-Log "  vCenter: $($item.vCenter) | VM: $($item.VMName)" "ERROR"
        }
        Write-Log ""
    }
    
    Write-Log "=================================================================" "INFO"
    Write-Log "Detailed log available at: $LogFile" "INFO"
    Write-Log "=================================================================" "INFO"
}

# 执行主函数
Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
