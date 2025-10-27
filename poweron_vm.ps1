# PowerShell Script: Power on all VMs in all vCenters (except powered-off VMs)
# Function: Read powered-off VM list, start all other VMs except those in the list

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

# 启动虚拟机
function Start-VM {
    param(
        [string]$vCenterName,
        [object]$vm
    )
    
    try {
        # 检查虚拟机状态
        if ($vm.PowerState -eq "PoweredOff") {
            Write-Log "Starting VM: $($vm.Name) in $vCenterName"
            Start-VM -VM $vm -Confirm:$false -ErrorAction Stop
            Write-Log "Start command sent for VM $($vm.Name)" "SUCCESS"
            return $true
        } elseif ($vm.PowerState -eq "PoweredOn") {
            Write-Log "VM $($vm.Name) is already running, skipping start operation"
            return $true
        } else {
            Write-Log "VM $($vm.Name) has abnormal state: $($vm.PowerState)" "WARNING"
            return $false
        }
    } catch {
        Write-Log "Error starting VM $($vm.Name): $($_.Exception.Message)" "ERROR"
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
            Write-Log "File does not exist: $FilePath" "ERROR"
            return @()
        }
        
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
        
        if ($data.PoweredOffVMs) {
            Write-Log "Successfully read powered-off VM list, total $($data.PoweredOffVMs.Count) VMs" "SUCCESS"
            return $data.PoweredOffVMs
        } else {
            Write-Log "No powered-off VM data found in file" "WARNING"
            return @()
        }
    } catch {
        Write-Log "Error reading powered-off VM list: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting VM power on task"
    Write-Log "Log file: $LogFile"
    Write-Log "Powered-off VM list file: $PoweredOffVMFile"
    
    # 读取已关闭虚拟机列表
    $poweredOffVMs = Read-PoweredOffVMList -FilePath $PoweredOffVMFile
    if ($poweredOffVMs.Count -eq 0) {
        Write-Log "No powered-off VM list found, will start all VMs" "WARNING"
    }
    
    if (-not $Force) {
        Write-Log "WARNING: This operation will start all VMs (except those in the powered-off list)!" "WARNING"
        Write-Log "Use -Force parameter to force execution, or press Ctrl+C to cancel" "WARNING"
        
        $confirmation = Read-Host "Confirm starting all VMs? (Type 'YES' to confirm)"
        if ($confirmation -ne "YES") {
            Write-Log "Operation cancelled" "INFO"
            return
        }
    }
    
    $totalProcessed = 0
    $totalSuccess = 0
    $totalFailed = 0
    $totalSkipped = 0
    $failedList = @()
    $skippedList = @()
    
    foreach ($vCenter in $vCenters) {
        Write-Log "Processing vCenter: $($vCenter.Name)"
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            continue
        }
        
        try {
            # 获取该vCenter中已关闭的虚拟机名称列表
            $vCenterPoweredOffVMs = $poweredOffVMs | Where-Object { $_.vCenter -eq $vCenter.Name }
            $poweredOffVMNames = $vCenterPoweredOffVMs | ForEach-Object { $_.Name }
            
            Write-Log "Skipping $($poweredOffVMNames.Count) powered-off VMs in $($vCenter.Name)"
            
            # Get all VMs
            Write-Log "Getting all VMs in $($vCenter.Name)..."
            $allVMs = Get-VM
            
            # Filter out powered-off VMs
            $vmsToStart = $allVMs | Where-Object { $_.Name -notin $poweredOffVMNames }
            
            # Record skipped VMs
            foreach ($skippedVM in $vCenterPoweredOffVMs) {
                $totalSkipped++
                $skippedInfo = @{
                    vCenter = $vCenter.Name
                    VMName = $skippedVM.Name
                }
                $skippedList += $skippedInfo
            }
            
            Write-Log "Found $($vmsToStart.Count) VMs to start in $($vCenter.Name)"
            
            # For vCenter2, prioritize VMs with "svm" in the name
            if ($vCenter.Name -eq "vCenter2") {
                Write-Log "Processing vCenter2: Prioritizing VMs with 'svm' keyword first"
                $svmVMs = $vmsToStart | Where-Object { $_.Name.ToLower() -like "*svm*" }
                $otherVMs = $vmsToStart | Where-Object { $_.Name.ToLower() -notlike "*svm*" }
                $vmsToStart = $svmVMs + $otherVMs
                Write-Log "Priority order: $($svmVMs.Count) SVM VMs, then $($otherVMs.Count) other VMs"
            }
            
            # Process each VM
            foreach ($vm in $vmsToStart) {
                $totalProcessed++
                Write-Log "Processing VM: $($vm.Name) (#$totalProcessed)"
                
                $result = Start-VM -vCenterName $vCenter.Name -vm $vm
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
    Write-Log "Total VMs processed: $totalProcessed"
    Write-Log "Successfully started: $totalSuccess"
    Write-Log "Skipped (powered-off): $totalSkipped"
    Write-Log "Failed: $totalFailed"
    Write-Log ""
    
    # Output skipped VM list
    if ($skippedList.Count -gt 0) {
        Write-Log "Skipped VMs (from powered-off list):" "INFO"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $skippedList) {
            Write-Log "  vCenter: $($item.vCenter) | VM: $($item.VMName)" "INFO"
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
