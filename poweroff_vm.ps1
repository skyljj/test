# PowerShell脚本：关闭多个vCenter中的虚拟机并重命名
# 功能：连接到10个vCenter，每个vCenter关闭10台VM并重命名为 vm-name_deco

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_poweroff_log.txt"
)

# 导入VMware PowerCLI模块
try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Write-Host "VMware PowerCLI模块已成功导入" -ForegroundColor Green
} catch {
    Write-Error "无法导入VMware PowerCLI模块。请确保已安装VMware PowerCLI。"
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
        Write-Log "正在连接到 $($vCenter.Name) ($($vCenter.Server))..."
        $securePassword = ConvertTo-SecureString $vCenter.Password -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($vCenter.User, $securePassword)
        
        $connection = Connect-VIServer -Server $vCenter.Server -Credential $credential -ErrorAction Stop
        Write-Log "成功连接到 $($vCenter.Name)" "SUCCESS"
        return $connection
    } catch {
        Write-Log "连接失败 $($vCenter.Name): $($_.Exception.Message)" "ERROR"
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
            Write-Log "正在关闭虚拟机: $($vm.Name) 在 $vCenterName"
            Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Write-Log "虚拟机 $($vm.Name) 已成功关闭" "SUCCESS"
        } else {
            Write-Log "虚拟机 $($vm.Name) 已经关闭，跳过关闭操作"
        }
        
        # 重命名虚拟机
        $newName = "$($vm.Name)_deco"
        Write-Log "正在重命名虚拟机: $($vm.Name) -> $newName"
        Set-VM -VM $vm -Name $newName -Confirm:$false -ErrorAction Stop
        Write-Log "虚拟机重命名成功: $($vm.Name) -> $newName" "SUCCESS"
        
        return $true
    } catch {
        Write-Log "处理虚拟机 $($vm.Name) 时出错: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 主执行逻辑
function Main {
    Write-Log "开始执行虚拟机关闭和重命名任务"
    Write-Log "日志文件: $LogFile"
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    
    foreach ($vCenter in $vCenters) {
        # 检查是否配置了需要处理的虚拟机
        if (-not $vmsToDecoMap.ContainsKey($vCenter.Name)) {
            Write-Log "未配置 $($vCenter.Name) 需要deco的虚拟机，跳过该vCenter" "INFO"
            continue
        }
        
        Write-Log "处理vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "跳过vCenter: $($vCenter.Name) - 连接失败" "WARNING"
            continue
        }
        
        try {
            # 获取需要deco的虚拟机列表
            Write-Log "获取 $($vCenter.Name) 需要deco的虚拟机列表..."
            $vmNames = $vmsToDecoMap[$vCenter.Name]
            $vms = @()
            foreach ($vmName in $vmNames) {
                $vmObj = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if ($vmObj) {
                    $vms += $vmObj
                } else {
                    Write-Log "未找到虚拟机: $vmName in $($vCenter.Name)" "WARNING"
                }
            }
            
            if ($vms.Count -eq 0) {
                Write-Log "在 $($vCenter.Name) 中未找到虚拟机" "WARNING"
                continue
            }
            
            Write-Log "在 $($vCenter.Name) 中找到 $($vms.Count) 台虚拟机"
            
            # 处理每台虚拟机
            foreach ($vm in $vms) {
                $totalProcessed++
                Write-Log "处理虚拟机: $($vm.Name) (第 $totalProcessed 台)"
                
                $result = PowerOffAndRenameVM -vCenterName $vCenter.Name -vm $vm
                if ($result) {
                    $totalSuccess++
                } else {
                    $totalFailed++
                }
            }
            
        } catch {
            Write-Log "处理vCenter $($vCenter.Name) 时出错: $($_.Exception.Message)" "ERROR"
        } finally {
            # 断开连接
            try {
                Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "已断开与 $($vCenter.Name) 的连接"
            } catch {
                Write-Log "断开连接时出错: $($_.Exception.Message)" "WARNING"
            }
        }
    }
    
    # 输出总结
    Write-Log "任务完成总结:"
    Write-Log "总处理虚拟机数: $totalProcessed"
    Write-Log "成功处理数: $totalSuccess"
    Write-Log "失败数: $totalFailed"
    Write-Log "详细日志请查看: $LogFile"
}

# 执行主函数
Main

Write-Host "脚本执行完成。按任意键退出..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
