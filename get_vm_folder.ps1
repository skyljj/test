# PowerShell Script: Get VM Folder Information from vCenters
# Function: Connect to defined vCenters, collect VM folder information and export to CSV
# Format: vc, vm, powerstatus, folder, folder_prefix, env

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "vm_folder_info_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$OutputCSV = "vm_folder_info.csv",
    [Parameter(Mandatory=$false)]
    [string]$SummaryCSV = "vm_folder_summary.csv"
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

# 获取VM的完整Folder路径
function Get-VMFolderPath {
    param(
        [object]$vm
    )
    
    try {
        $folder = $vm.Folder
        if ($null -eq $folder) {
            return ""
        }
        
        # 方法1: 尝试使用FullName属性（如果可用）
        if ($folder.FullName) {
            return $folder.FullName
        }
        
        # 方法2: 构建完整的folder路径
        $folderPath = $folder.Name
        $parent = $folder.Parent
        
        # 向上遍历获取完整路径，直到到达Datacenter或vm文件夹
        while ($parent -and $parent.Name -ne "vm" -and $parent.Name -ne "Datacenters" -and $parent.GetType().Name -ne "Datacenter") {
            if ($parent.Name) {
                $folderPath = "$($parent.Name)/$folderPath"
            }
            $parent = $parent.Parent
        }
        
        return $folderPath
    } catch {
        Write-Log "Error getting folder path for VM $($vm.Name): $($_.Exception.Message)" "WARNING"
        # 如果出错，至少返回folder名称
        try {
            return $vm.Folder.Name
        } catch {
            return "Error"
        }
    }
}

# 解析Folder路径，提取前缀和环境信息
function Parse-FolderInfo {
    param(
        [string]$folderPath
    )
    
    # 定义环境关键词
    $envKeywords = @("dev", "qa", "prod", "test", "staging", "uat", "preprod", "production")
    
    try {
        # 如果VM没有folder，返回空值
        if ([string]::IsNullOrWhiteSpace($folderPath) -or $folderPath -eq "Error") {
            return @{
                folder_prefix = ""
                env = ""
            }
        }
        
        # 如果folder路径包含斜杠，遍历所有部分查找包含下划线的部分
        if ($folderPath.Contains("/")) {
            $pathParts = $folderPath.Split("/")
            
            # 从后往前查找包含下划线的部分（优先匹配更接近VM的部分）
            for ($i = $pathParts.Length - 1; $i -ge 0; $i--) {
                $part = $pathParts[$i]
                
                # 如果这个部分包含下划线，尝试解析
                if ($part.Contains("_")) {
                    $subParts = $part.Split("_")
                    
                    # 第一部分作为前缀
                    $prefix = $subParts[0]
                    
                    # 查找环境关键词（不区分大小写）
                    $env = ""
                    for ($j = 1; $j -lt $subParts.Length; $j++) {
                        $subPart = $subParts[$j].ToLower()
                        foreach ($keyword in $envKeywords) {
                            if ($subPart -eq $keyword) {
                                $env = $keyword
                                break
                            }
                        }
                        if ($env) {
                            break
                        }
                    }
                    
                    # 找到了包含下划线的部分，返回结果（即使没有找到环境关键词也返回前缀）
                    return @{
                        folder_prefix = $prefix
                        env = $env
                    }
                }
            }
            
            # 如果没有找到包含下划线的部分，尝试在最后一部分中匹配环境关键词
            $lastPart = $pathParts[$pathParts.Length - 1]
            $lastPartLower = $lastPart.ToLower()
            $env = ""
            foreach ($keyword in $envKeywords) {
                if ($lastPartLower -like "*$keyword*") {
                    $env = $keyword
                    break
                }
            }
            
            return @{
                folder_prefix = $lastPart
                env = $env
            }
        } else {
            # 如果folder路径不包含斜杠，直接解析
            $folderName = $folderPath
            
            # 如果包含下划线，尝试解析
            if ($folderName.Contains("_")) {
                $parts = $folderName.Split("_")
                
                # 第一部分作为前缀
                $prefix = $parts[0]
                
                # 查找环境关键词（不区分大小写）
                $env = ""
                for ($i = 1; $i -lt $parts.Length; $i++) {
                    $part = $parts[$i].ToLower()
                    foreach ($keyword in $envKeywords) {
                        if ($part -eq $keyword) {
                            $env = $keyword
                            break
                        }
                    }
                    if ($env) {
                        break
                    }
                }
                
                return @{
                    folder_prefix = $prefix
                    env = $env
                }
            } else {
                # 如果没有下划线，尝试匹配环境关键词
                $folderLower = $folderName.ToLower()
                $env = ""
                foreach ($keyword in $envKeywords) {
                    if ($folderLower -like "*$keyword*") {
                        $env = $keyword
                        break
                    }
                }
                
                return @{
                    folder_prefix = $folderName
                    env = $env
                }
            }
        }
    } catch {
        Write-Log "Error parsing folder info for '$folderPath': $($_.Exception.Message)" "WARNING"
        return @{
            folder_prefix = ""
            env = ""
        }
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting VM folder information collection task"
    Write-Log "Log file: $LogFile"
    Write-Log "Output CSV file: $OutputCSV"
    Write-Log "Summary CSV file: $SummaryCSV"
    
    # 初始化结果数组
    $vmInfoList = @()
    
    # 初始化统计字典
    $summaryDict = @{}
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    
    foreach ($vCenter in $vCenters) {

        Write-Log "Processing vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }
        
        try {
            # Get all VMs in this vCenter
            Write-Log "Getting all VMs in $($vCenter.Name)..."
            $allVMs = Get-VM
            
            if ($allVMs.Count -eq 0) {
                Write-Log "No VMs found in $($vCenter.Name)" "WARNING"
                continue
            }
            
            Write-Log "Found $($allVMs.Count) VMs in $($vCenter.Name)"
            
            # Process each VM
            foreach ($vm in $allVMs) {
                $totalProcessed++
                Write-Log "Processing VM: $($vm.Name) (#$totalProcessed)"
                
                try {
                    # 获取VM信息
                    $vmName = $vm.Name
                    $powerStatus = $vm.PowerState
                    $folderPath = Get-VMFolderPath -vm $vm
                    
                    # 解析folder信息
                    $folderInfo = Parse-FolderInfo -folderPath $folderPath
                    
                    # 创建VM信息对象
                    $vmInfo = [PSCustomObject]@{
                        vc = $vCenter.Name
                        vm = $vmName
                        powerstatus = $powerStatus
                        folder = $folderPath
                        folder_prefix = $folderInfo.folder_prefix
                        env = $folderInfo.env
                    }
                    
                    $vmInfoList += $vmInfo
                    $totalSuccess++
                    
                    # 更新统计信息
                    $summaryKey = "$($vCenter.Name)|$($folderInfo.folder_prefix)|$($folderInfo.env)"
                    if ($summaryDict.ContainsKey($summaryKey)) {
                        $summaryDict[$summaryKey]++
                    } else {
                        $summaryDict[$summaryKey] = 1
                    }
                    
                    Write-Log "  - VM: $vmName | PowerStatus: $powerStatus | Folder: $folderPath | Prefix: $($folderInfo.folder_prefix) | Env: $($folderInfo.env)" "INFO"
                } catch {
                    $totalFailed++
                    Write-Log "Error processing VM $($vm.Name): $($_.Exception.Message)" "ERROR"
                    
                    # 即使出错也记录基本信息
                    $vmInfo = [PSCustomObject]@{
                        vc = $vCenter.Name
                        vm = $vm.Name
                        powerstatus = "Error"
                        folder = "Error"
                        folder_prefix = ""
                        env = ""
                    }
                    $vmInfoList += $vmInfo
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
    
    # 导出到CSV
    if ($vmInfoList.Count -gt 0) {
        try {
            $vmInfoList | Export-Csv -Path $OutputCSV -NoTypeInformation -Encoding UTF8
            Write-Log "Successfully exported $($vmInfoList.Count) VM records to $OutputCSV" "SUCCESS"
        } catch {
            Write-Log "Error exporting to CSV: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "No VM information collected, CSV file not created" "WARNING"
    }
    
    # 生成统计CSV
    if ($summaryDict.Count -gt 0) {
        try {
            $summaryList = @()
            foreach ($key in $summaryDict.Keys) {
                $parts = $key.Split("|")
                $summaryInfo = [PSCustomObject]@{
                    vc = $parts[0]
                    folder_prefix = $parts[1]
                    env = $parts[2]
                    total_num = $summaryDict[$key]
                }
                $summaryList += $summaryInfo
            }
            
            # 按vc, folder_prefix, env排序
            $summaryList = $summaryList | Sort-Object vc, folder_prefix, env
            
            $summaryList | Export-Csv -Path $SummaryCSV -NoTypeInformation -Encoding UTF8
            Write-Log "Successfully exported $($summaryList.Count) summary records to $SummaryCSV" "SUCCESS"
        } catch {
            Write-Log "Error exporting summary to CSV: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "No summary information collected, summary CSV file not created" "WARNING"
    }
    
    # Output summary
    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Task Completion Summary" "INFO"
    Write-Log "=================================================================" "INFO"
    Write-Log "Total VMs processed: $totalProcessed"
    Write-Log "Successfully collected: $totalSuccess"
    Write-Log "Failed: $totalFailed"
    Write-Log "Output CSV file: $OutputCSV"
    Write-Log "Summary CSV file: $SummaryCSV"
    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Detailed log available at: $LogFile" "INFO"
    Write-Log "=================================================================" "INFO"
}

# 执行主函数
Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

