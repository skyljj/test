# PowerShell脚本：启动所有vCenter中的虚拟机（除了已关闭的虚拟机）
# 功能：读取已关闭虚拟机列表，启动除了这些虚拟机之外的所有其他虚拟机

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "poweron_vm_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$PoweredOffVMFile = "poweredoff_vms.json",
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
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

# 启动虚拟机
function Start-VM {
    param(
        [string]$vCenterName,
        [object]$vm
    )
    
    try {
        # 检查虚拟机状态
        if ($vm.PowerState -eq "PoweredOff") {
            Write-Log "正在启动虚拟机: $($vm.Name) 在 $vCenterName"
            Start-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Write-Log "虚拟机 $($vm.Name) 启动命令已发送" "SUCCESS"
            return $true
        } elseif ($vm.PowerState -eq "PoweredOn") {
            Write-Log "虚拟机 $($vm.Name) 已经运行，跳过启动操作"
            return $true
        } else {
            Write-Log "虚拟机 $($vm.Name) 状态异常: $($vm.PowerState)" "WARNING"
            return $false
        }
    } catch {
        Write-Log "启动虚拟机 $($vm.Name) 时出错: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# 读取已关闭虚拟机列表
function Read-PoweredOffVMList {
    param(
        [string]$FilePath
    )
    
    try {
        if (-not (Test-Path $FilePath)) {
            Write-Log "文件不存在: $FilePath" "ERROR"
            return @()
        }
        
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
        
        if ($data.PoweredOffVMs) {
            Write-Log "成功读取已关闭虚拟机列表，共 $($data.PoweredOffVMs.Count) 台虚拟机" "SUCCESS"
            return $data.PoweredOffVMs
        } else {
            Write-Log "文件中未找到已关闭虚拟机数据" "WARNING"
            return @()
        }
    } catch {
        Write-Log "读取已关闭虚拟机列表时出错: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# 主执行逻辑
function Main {
    Write-Log "开始启动虚拟机任务"
    Write-Log "日志文件: $LogFile"
    Write-Log "已关闭虚拟机列表文件: $PoweredOffVMFile"
    
    # 读取已关闭虚拟机列表
    $poweredOffVMs = Read-PoweredOffVMList -FilePath $PoweredOffVMFile
    if ($poweredOffVMs.Count -eq 0) {
        Write-Log "未找到已关闭虚拟机列表，将启动所有虚拟机" "WARNING"
    }
    
    if (-not $Force) {
        Write-Log "警告：此操作将启动所有虚拟机（除了已关闭列表中的虚拟机）！" "WARNING"
        Write-Log "使用 -Force 参数强制执行，或按 Ctrl+C 取消" "WARNING"
        
        $confirmation = Read-Host "确认启动所有虚拟机？(输入 'YES' 确认)"
        if ($confirmation -ne "YES") {
            Write-Log "操作已取消" "INFO"
            return
        }
    }
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    $totalSkipped = 0
    
    foreach ($vCenter in $vCenters) {
        Write-Log "处理vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "跳过vCenter: $($vCenter.Name) - 连接失败" "WARNING"
            continue
        }
        
        try {
            # 获取该vCenter中已关闭的虚拟机名称列表
            $vCenterPoweredOffVMs = $poweredOffVMs | Where-Object { $_.vCenter -eq $vCenter.Name }
            $poweredOffVMNames = $vCenterPoweredOffVMs | ForEach-Object { $_.Name }
            
            Write-Log "在 $($vCenter.Name) 中跳过 $($poweredOffVMNames.Count) 台已关闭的虚拟机"
            
            # 获取所有虚拟机
            Write-Log "获取 $($vCenter.Name) 中的所有虚拟机..."
            $allVMs = Get-VM
            
            # 过滤掉已关闭的虚拟机
            $vmsToStart = $allVMs | Where-Object { $_.Name -notin $poweredOffVMNames }
            
            Write-Log "在 $($vCenter.Name) 中找到 $($vmsToStart.Count) 台需要启动的虚拟机"
            
            # 处理每台虚拟机
            foreach ($vm in $vmsToStart) {
                $totalProcessed++
                Write-Log "处理虚拟机: $($vm.Name) (第 $totalProcessed 台)"
                
                $result = Start-VM -vCenterName $vCenter.Name -vm $vm
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
    Write-Log "成功启动数: $totalSuccess"
    Write-Log "失败数: $totalFailed"
    Write-Log "详细日志请查看: $LogFile"
}

# 执行主函数
Main

Write-Host "脚本执行完成。按任意键退出..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
