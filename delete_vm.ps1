# PowerShell Script: Delete _deco VMs from multiple vCenters
# Function: Connect to vCenters and delete all VMs ending with _deco (run one week after poweroff_vm.ps1)

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_delete_log.txt",
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
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

# 定义需要处理的vCenter映射 - 只有配置了虚拟机的vCenter才会被处理
$vmsToDeleteMap = @{
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

# 删除虚拟机
function DeleteVM {
    param(
        [string]$vCenterName,
        [object]$vm
    )
    
    try {
        # 确保虚拟机已关闭
        if ($vm.PowerState -eq "PoweredOn") {
            Write-Log "Force stopping VM: $($vm.Name) in $vCenterName"
            Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Write-Log "VM $($vm.Name) has been force stopped" "SUCCESS"
            
            # Wait for VM to fully stop
            Start-Sleep -Seconds 10
        }
        
        # Delete VM
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
    Write-Log "Starting VM deletion task"
    Write-Log "日志文件: $LogFile"
    
    if (-not $Force) {
        Write-Log "WARNING: This operation will permanently delete VMs!" "WARNING"
        Write-Log "Use -Force parameter to force execution, or press Ctrl+C to cancel" "WARNING"
        
        $confirmation = Read-Host "Confirm deletion of all _deco VMs? (Type 'YES' to confirm)"
        if ($confirmation -ne "YES") {
            Write-Log "Operation cancelled" "INFO"
            return
        }
    }
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    
    foreach ($vCenter in $vCenters) {
        # 检查是否配置了需要处理的虚拟机
        if (-not $vmsToDeleteMap.ContainsKey($vCenter.Name)) {
            Write-Log "No VMs configured for deletion in $($vCenter.Name), skipping this vCenter" "INFO"
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
            # Get list of VMs to delete
            Write-Log "Getting list of VMs to delete in $($vCenter.Name)..."
            $vmNames = $vmsToDeleteMap[$vCenter.Name]
            $vms = @()
            foreach ($vmName in $vmNames) {
                # Find VMs with vm_name_deco format
                $decoVMName = "$vmName" + "_deco"
                $vmObj = Get-VM -Name $decoVMName -ErrorAction SilentlyContinue
                if ($vmObj) {
                    $vms += $vmObj
                } else {
                    Write-Log "VM not found: $decoVMName in $($vCenter.Name)" "WARNING"
                }
            }
            
            if ($vms.Count -eq 0) {
                Write-Log "No VMs found for deletion in $($vCenter.Name)" "WARNING"
                continue
            }
            
            Write-Log "Found $($vms.Count) VMs to delete in $($vCenter.Name)"
            
            # Process each VM
            foreach ($vm in $vms) {
                $totalProcessed++
                Write-Log "Processing VM: $($vm.Name) (#$totalProcessed)"
                
                $result = DeleteVM -vCenterName $vCenter.Name -vm $vm
                if ($result) {
                    $totalSuccess++
                } else {
                    $totalFailed++
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
    Write-Log "Task completion summary:"
    Write-Log "Total VMs processed: $totalProcessed"
    Write-Log "Successfully deleted: $totalSuccess"
    Write-Log "Failed: $totalFailed"
    Write-Log "Detailed log available at: $LogFile"
}

# 执行主函数
Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
