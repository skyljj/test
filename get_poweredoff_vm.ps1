# PowerShell脚本：获取所有vCenter中已关闭的虚拟机
# 功能：连接到所有vCenter，获取已关闭的虚拟机列表并保存到文件

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

# 获取已关闭的虚拟机
function Get-PoweredOffVMs {
    param(
        [string]$vCenterName
    )
    
    try {
        Write-Log "获取 $vCenterName 中已关闭的虚拟机..."
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
        
        Write-Log "在 $vCenterName 中找到 $($vmList.Count) 台已关闭的虚拟机" "SUCCESS"
        return $vmList
    } catch {
        Write-Log "获取 $vCenterName 中已关闭虚拟机时出错: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# 主执行逻辑
function Main {
    Write-Log "开始获取所有vCenter中已关闭的虚拟机"
    Write-Log "日志文件: $LogFile"
    Write-Log "输出文件: $OutputFile"
    
    $allPoweredOffVMs = @()
    $totalVMs = 0
    
    foreach ($vCenter in $vCenters) {
        Write-Log "处理vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "跳过vCenter: $($vCenter.Name) - 连接失败" "WARNING"
            continue
        }
        
        try {
            # 获取已关闭的虚拟机
            $poweredOffVMs = Get-PoweredOffVMs -vCenterName $vCenter.Name
            $allPoweredOffVMs += $poweredOffVMs
            $totalVMs += $poweredOffVMs.Count
            
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
    
    # 保存结果到JSON文件
    try {
        $outputData = @{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            TotalCount = $totalVMs
            PoweredOffVMs = $allPoweredOffVMs
        }
        
        $outputData | ConvertTo-Json -Depth 3 | Out-File -FilePath $OutputFile -Encoding UTF8
        Write-Log "已关闭虚拟机列表已保存到: $OutputFile" "SUCCESS"
        
        # 同时保存为CSV格式（便于在Windows中查看）
        $csvFile = $OutputFile -replace "\.json$", ".csv"
        
        # 创建适合Windows查看的CSV格式
        $csvData = @()
        foreach ($vm in $allPoweredOffVMs) {
            $csvRow = [PSCustomObject]@{
                '虚拟机名称' = $vm.Name
                '电源状态' = $vm.PowerState
                'vCenter' = $vm.vCenter
                '虚拟机ID' = $vm.Id
                '文件夹' = $vm.Folder
                '资源池' = $vm.ResourcePool
                '创建时间' = $vm.Created
                '备注' = $vm.Notes
            }
            $csvData += $csvRow
        }
        
        $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log "已关闭虚拟机列表已保存到: $csvFile" "SUCCESS"
        
    } catch {
        Write-Log "保存输出文件时出错: $($_.Exception.Message)" "ERROR"
    }
    
    # 输出总结
    Write-Log "任务完成总结:"
    Write-Log "总vCenter数: $($vCenters.Count)"
    Write-Log "成功连接的vCenter数: $($vCenters.Count - (($vCenters | Where-Object { $_.Name -notin $allPoweredOffVMs.vCenter }).Count))"
    Write-Log "总已关闭虚拟机数: $totalVMs"
    Write-Log "详细日志请查看: $LogFile"
    Write-Log "虚拟机列表请查看: $OutputFile"
}

# 执行主函数
Main

Write-Host "脚本执行完成。按任意键退出..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
