# PowerShell Script: Power off / rename / delete defined VMs across vCenters
# Actions:
#   deco   (default) - power off, rename to vm-name_deco, disconnect NICs
#   delete           - delete previously renamed vm-name_deco VMs (requires confirmation)
#
# Usage:
#   .\poweroff_vm_defined.ps1
#   .\poweroff_vm_defined.ps1 deco
#   .\poweroff_vm_defined.ps1 delete

param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("deco", "delete")]
    [string]$Action = "deco",

    [Parameter(Mandatory = $false)]
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
        $vm = Set-VM -VM $vm -Name $newName -Confirm:$false -ErrorAction Stop
        Write-Log "VM renamed successfully: $($vm.Name)" "SUCCESS"

        # Disconnect all network adapters
        $nics = Get-NetworkAdapter -VM $vm -ErrorAction Stop
        Write-Log "Disconnecting $($nics.Count) network adapter(s) on VM: $($vm.Name)"
        foreach ($nic in $nics) {
            Set-NetworkAdapter -NetworkAdapter $nic -Connected:$false -StartConnected:$false -Confirm:$false -ErrorAction Stop
            Write-Log "Disconnected network adapter: $($nic.Name) (Network: $($nic.NetworkName))" "SUCCESS"
        }
        
        return $true
    } catch {
        Write-Log "Error processing VM $($vm.Name): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 删除已 rename 的 _deco 虚拟机
function DeleteDecoVM {
    param(
        [string]$vCenterName,
        [object]$vm
    )

    try {
        if ($vm.PowerState -ne "PoweredOff") {
            Write-Log "VM $($vm.Name) in $vCenterName is $($vm.PowerState), skip delete (only delete powered-off VMs)" "WARNING"
            return $false
        }

        Write-Log "Deleting VM: $($vm.Name) in $vCenterName"
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false -ErrorAction Stop
        Write-Log "VM $($vm.Name) has been successfully deleted" "SUCCESS"
        return $true
    } catch {
        Write-Log "Error deleting VM $($vm.Name): $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting task with Action=$Action"
    Write-Log "Log file: $LogFile"

    if ($Action -eq "delete") {
        Write-Log "WARNING: This will permanently delete renamed *_deco VMs from the map!" "WARNING"
        Write-Host ""
        Write-Host "Planned delete targets (original name -> deco name):" -ForegroundColor Yellow
        foreach ($vcName in ($vmsToDecoMap.Keys | Sort-Object)) {
            foreach ($vmName in $vmsToDecoMap[$vcName]) {
                Write-Host "  [$vcName] $vmName -> ${vmName}_deco"
            }
        }
        Write-Host ""
        $confirmation = Read-Host "Confirm deletion of these *_deco VMs? (Type 'YES' to confirm)"
        if ($confirmation -ne "YES") {
            Write-Log "Delete operation cancelled by user" "INFO"
            return
        }
        Write-Log "Delete confirmed by user" "WARNING"
    }

    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    $totalNotFound = 0
    $notFoundList = @()
    $failedList = @()
    $totalToProcess = 0

    foreach ($vCenter in $vCenters) {
        if (-not $vmsToDecoMap.ContainsKey($vCenter.Name)) {
            Write-Log "No VMs configured for $Action in $($vCenter.Name), skipping this vCenter" "INFO"
            continue
        }

        Write-Log "Processing vCenter: $($vCenter.Name)"

        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }

        try {
            $vmNames = $vmsToDecoMap[$vCenter.Name]
            $totalToProcess += $vmNames.Count

            $vms = @()
            foreach ($vmName in $vmNames) {
                $lookupName = if ($Action -eq "delete") { "${vmName}_deco" } else { $vmName }
                $vmObj = Get-VM -Name $lookupName -ErrorAction SilentlyContinue
                if ($vmObj) {
                    $vms += $vmObj
                } else {
                    $totalNotFound++
                    $notFoundList += @{
                        vCenter = $vCenter.Name
                        VMName = $lookupName
                    }
                    Write-Log "VM not found: $lookupName in $($vCenter.Name)" "WARNING"
                }
            }

            if ($vms.Count -eq 0) {
                Write-Log "No VMs found in $($vCenter.Name)" "WARNING"
                continue
            }

            Write-Log "Found $($vms.Count) VMs in $($vCenter.Name)"

            foreach ($vm in $vms) {
                $totalProcessed++
                Write-Log "Processing VM: $($vm.Name) (#$totalProcessed)"

                if ($Action -eq "delete") {
                    $result = DeleteDecoVM -vCenterName $vCenter.Name -vm $vm
                } else {
                    $result = PowerOffAndRenameVM -vCenterName $vCenter.Name -vm $vm
                }

                if ($result) {
                    $totalSuccess++
                } else {
                    $totalFailed++
                    $failedList += @{
                        vCenter = $vCenter.Name
                        VMName = $vm.Name
                    }
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

    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Task Completion Summary (Action=$Action)" "INFO"
    Write-Log "=================================================================" "INFO"
    Write-Log "Total VMs to process: $totalToProcess"
    Write-Log "Total VMs not found: $totalNotFound"
    Write-Log "Total VMs processed: $totalProcessed"
    Write-Log "Successfully processed: $totalSuccess"
    Write-Log "Failed: $totalFailed"
    Write-Log ""

    if ($notFoundList.Count -gt 0) {
        Write-Log "VMs Not Found List:" "WARNING"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $notFoundList) {
            Write-Log "  vCenter: $($item.vCenter) | VM: $($item.VMName)" "WARNING"
        }
        Write-Log ""
    }

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
