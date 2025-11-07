# PowerShell Script: Update Key Provider Certificate in vCenters
# Function: Connect to all vCenters, update key provider certificate

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "update_keyprovider_cert_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$CertificateFolder = "",
    [Parameter(Mandatory=$false)]
    [switch]$Force = $false
)

# 预定义的Key Provider名称
$KeyProviderName = "KeyProvider"

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

# 读取vCenter的证书文件（证书、私钥、CA证书）
function Read-VCenterCertificates {
    param(
        [string]$CertificateFolder,
        [string]$vCenterServer
    )
    
    try {
        # 使用完整的 Server FQDN 作为文件名前缀
        # 例如：vcenter1.company.com -> vcenter1.company.com-cert.pem
        
        # 构建文件路径（基于完整的 server FQDN）
        $certFile = Join-Path $CertificateFolder "$vCenterServer-cert.pem"
        $keyFile = Join-Path $CertificateFolder "$vCenterServer-key.pem"
        $caFile = Join-Path $CertificateFolder "ca.pem"
        
        # 检查文件是否存在
        $missingFiles = @()
        if (-not (Test-Path $certFile)) {
            $missingFiles += $certFile
        }
        if (-not (Test-Path $keyFile)) {
            $missingFiles += $keyFile
        }
        if (-not (Test-Path $caFile)) {
            $missingFiles += $caFile
        }
        
        if ($missingFiles.Count -gt 0) {
            Write-Log "Missing certificate files for $vCenterServer:" "ERROR"
            foreach ($file in $missingFiles) {
                Write-Log "  - $file" "ERROR"
            }
            return $null
        }
        
        # 读取所有证书文件
        $certContent = Get-Content -Path $certFile -Raw -Encoding UTF8
        $keyContent = Get-Content -Path $keyFile -Raw -Encoding UTF8
        $caContent = Get-Content -Path $caFile -Raw -Encoding UTF8
        
        Write-Log "Successfully read certificate files for $vCenterServer" "SUCCESS"
        Write-Log "  Certificate: $certFile" "INFO"
        Write-Log "  Private Key: $keyFile" "INFO"
        Write-Log "  CA Certificate: $caFile" "INFO"
        
        return @{
            Certificate = $certContent
            PrivateKey = $keyContent
            CACertificate = $caContent
        }
    } catch {
        Write-Log "Error reading certificate files for $vCenterServer: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# 获取Key Provider列表
function Get-KeyProviders {
    param(
        [string]$vCenterName
    )
    
    try {
        Write-Log "Getting key providers from $vCenterName..."
        $keyProviders = Get-KeyProvider -ErrorAction Stop
        Write-Log "Found $($keyProviders.Count) key provider(s) in $vCenterName" "SUCCESS"
        return $keyProviders
    } catch {
        Write-Log "Error getting key providers from $vCenterName: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

# 检查Key Provider连接状态
function Check-KeyProviderConnectionStatus {
    param(
        [string]$vCenterName,
        [object]$KeyProvider
    )
    
    try {
        Write-Log "Checking Key Provider connection status for $($KeyProvider.Name) in $vCenterName..."
        
        # 方法1: 通过 Get-KeyProvider 获取连接状态
        # Key Provider 对象通常包含 Status 或 ConnectionStatus 属性
        $connectionStatus = $null
        $statusMessage = ""
        
        # 检查 Key Provider 对象的属性
        if ($KeyProvider | Get-Member -Name "Status") {
            $connectionStatus = $KeyProvider.Status
        } elseif ($KeyProvider | Get-Member -Name "ConnectionStatus") {
            $connectionStatus = $KeyProvider.ConnectionStatus
        } elseif ($KeyProvider | Get-Member -Name "Health") {
            $connectionStatus = $KeyProvider.Health
        } else {
            # 方法2: 通过 vSphere API 获取 Key Provider 状态
            try {
                $keyProviderView = Get-View $KeyProvider.Id -ErrorAction SilentlyContinue
                if ($keyProviderView) {
                    # 检查 Key Provider 视图中的状态属性
                    if ($keyProviderView | Get-Member -Name "Status") {
                        $connectionStatus = $keyProviderView.Status
                    } elseif ($keyProviderView | Get-Member -Name "ConnectionStatus") {
                        $connectionStatus = $keyProviderView.ConnectionStatus
                    }
                }
            } catch {
                Write-Log "Could not get Key Provider view: $($_.Exception.Message)" "WARNING"
            }
            
            # 方法3: 重新获取 Key Provider 以检查最新状态
            try {
                $refreshedKeyProvider = Get-KeyProvider -Name $KeyProvider.Name -ErrorAction Stop
                if ($refreshedKeyProvider | Get-Member -Name "Status") {
                    $connectionStatus = $refreshedKeyProvider.Status
                } elseif ($refreshedKeyProvider | Get-Member -Name "ConnectionStatus") {
                    $connectionStatus = $refreshedKeyProvider.ConnectionStatus
                }
            } catch {
                Write-Log "Could not refresh Key Provider status: $($_.Exception.Message)" "WARNING"
            }
        }
        
        # 检查状态是否为 green
        $isGreen = $false
        if ($null -ne $connectionStatus) {
            $statusString = $connectionStatus.ToString().ToLower()
            Write-Log "Key Provider connection status: $connectionStatus" "INFO"
            
            # 检查是否为 green（可能的值：green, Green, GREEN, ok, OK, healthy, Healthy）
            if ($statusString -eq "green" -or $statusString -eq "ok" -or $statusString -eq "healthy" -or $statusString -eq "normal") {
                $isGreen = $true
                $statusMessage = "Connection status is green (normal)"
            } else {
                $statusMessage = "Connection status is $connectionStatus (not green)"
            }
        } else {
            # 如果无法获取状态，尝试通过测试连接来判断
            Write-Log "Could not get connection status directly, trying alternative method..." "WARNING"
            $statusMessage = "Connection status could not be determined"
            
            # 可以尝试测试 Key Provider 的连接
            # 注意：这可能需要特定的 API 调用
        }
        
        if ($isGreen) {
            Write-Log "Key Provider connection status is GREEN for $($KeyProvider.Name)" "SUCCESS"
            return @{
                IsGreen = $true
                Status = "Green"
                ConnectionStatus = $connectionStatus
                Message = $statusMessage
            }
        } else {
            Write-Log "Key Provider connection status is NOT GREEN for $($KeyProvider.Name)" "ERROR"
            Write-Log "Current status: $connectionStatus" "ERROR"
            return @{
                IsGreen = $false
                Status = $connectionStatus
                ConnectionStatus = $connectionStatus
                Message = $statusMessage
            }
        }
    } catch {
        Write-Log "Error checking Key Provider connection status: $($_.Exception.Message)" "ERROR"
        return @{
            IsGreen = $false
            Status = "Error"
            ConnectionStatus = $null
            Message = $_.Exception.Message
        }
    }
}

# 检查CTM（Certificate Trust Management）状态
function Check-CTMStatus {
    param(
        [string]$vCenterName
    )
    
    try {
        Write-Log "Checking CTM status for $vCenterName..."
        
        # 使用 vSphere API 检查 CTM 状态
        # 获取 CertificateManager
        $si = Get-View ServiceInstance
        $certMgr = Get-View $si.Content.CertificateManager
        
        # 获取证书信息
        $certInfo = $certMgr.CertificateInfo
        
        # 检查证书状态
        # CTM 状态通常通过证书的有效性来判断
        $isValid = $true
        $statusMessage = ""
        
        # 检查证书是否有效
        if ($null -eq $certInfo) {
            $isValid = $false
            $statusMessage = "Certificate info is null"
        } else {
            # 检查证书是否过期
            if ($certInfo.NotAfter) {
                $expiryDate = $certInfo.NotAfter
                $currentDate = Get-Date
                if ($expiryDate -lt $currentDate) {
                    $isValid = $false
                    $statusMessage = "Certificate expired on $expiryDate"
                } else {
                    $daysUntilExpiry = ($expiryDate - $currentDate).Days
                    $statusMessage = "Certificate valid until $expiryDate (expires in $daysUntilExpiry days)"
                }
            }
            
            # 检查证书主题
            if ($certInfo.Subject) {
                Write-Log "Certificate Subject: $($certInfo.Subject)" "INFO"
            }
        }
        
        if ($isValid) {
            Write-Log "CTM status is normal for $vCenterName" "SUCCESS"
            Write-Log "Status details: $statusMessage" "INFO"
            return @{
                IsValid = $true
                Status = "Normal"
                Message = $statusMessage
            }
        } else {
            Write-Log "CTM status is abnormal for $vCenterName" "ERROR"
            Write-Log "Status details: $statusMessage" "ERROR"
            return @{
                IsValid = $false
                Status = "Abnormal"
                Message = $statusMessage
            }
        }
    } catch {
        Write-Log "Error checking CTM status for $vCenterName: $($_.Exception.Message)" "ERROR"
        return @{
            IsValid = $false
            Status = "Error"
            Message = $_.Exception.Message
        }
    }
}

# 更新Key Provider证书
function Update-KeyProviderCertificate {
    param(
        [string]$vCenterName,
        [object]$KeyProvider,
        [string]$CertificateContent,
        [string]$PrivateKeyContent,
        [string]$CACertificateContent
    )
    
    try {
        Write-Log "Updating certificate for key provider: $($KeyProvider.Name) in $vCenterName"
        
        # 使用Set-KeyProvider更新证书
        # 注意：根据实际的PowerCLI版本和API，可能需要调整参数
        # 这里假设需要传入证书、私钥和CA证书
        Set-KeyProvider -KeyProvider $KeyProvider -Certificate $CertificateContent -PrivateKey $PrivateKeyContent -CACertificate $CACertificateContent -Confirm:$false -ErrorAction Stop
        
        Write-Log "Certificate update command completed for key provider $($KeyProvider.Name)" "INFO"
        
        # 等待一段时间让证书生效
        Write-Log "Waiting for certificate to take effect..." "INFO"
        Start-Sleep -Seconds 5
        
        # 检查Key Provider连接状态（是否为green）
        $connectionStatus = Check-KeyProviderConnectionStatus -vCenterName $vCenterName -KeyProvider $KeyProvider
        
        # 检查CTM状态
        $ctmStatus = Check-CTMStatus -vCenterName $vCenterName
        
        # 只有当连接状态为green且CTM状态正常时，才认为成功
        if ($connectionStatus.IsGreen -and $ctmStatus.IsValid) {
            Write-Log "Successfully updated certificate for key provider $($KeyProvider.Name) - Connection status is GREEN and CTM status is normal" "SUCCESS"
            return @{
                Success = $true
                ConnectionStatus = $connectionStatus
                CTMStatus = $ctmStatus
            }
        } else {
            $errorMessages = @()
            if (-not $connectionStatus.IsGreen) {
                $errorMessages += "Connection status is not GREEN (current: $($connectionStatus.Status))"
            }
            if (-not $ctmStatus.IsValid) {
                $errorMessages += "CTM status is abnormal: $($ctmStatus.Message)"
            }
            
            Write-Log "Certificate updated but status check failed for key provider $($KeyProvider.Name)" "ERROR"
            foreach ($msg in $errorMessages) {
                Write-Log "  - $msg" "ERROR"
            }
            
            return @{
                Success = $false
                ConnectionStatus = $connectionStatus
                CTMStatus = $ctmStatus
            }
        }
    } catch {
        Write-Log "Error updating certificate for key provider $($KeyProvider.Name): $($_.Exception.Message)" "ERROR"
        return @{
            Success = $false
            CTMStatus = @{
                IsValid = $false
                Status = "Error"
                Message = $_.Exception.Message
            }
        }
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting Key Provider certificate update task"
    Write-Log "Log file: $LogFile"
    
    # 验证证书文件夹参数
    if ([string]::IsNullOrEmpty($CertificateFolder)) {
        Write-Log "Certificate folder path is required. Please provide -CertificateFolder parameter." "ERROR"
        Write-Log "Usage: .\update_keyprovider_cert.ps1 -CertificateFolder <path> [-Force]" "INFO"
        Write-Log "Expected files in folder:" "INFO"
        Write-Log "  - {server-fqdn}-cert.pem, {server-fqdn}-key.pem (one set per vCenter Server)" "INFO"
        Write-Log "  - ca.pem (shared CA certificate)" "INFO"
        Write-Log "  Example: vcenter1.company.com-cert.pem, vcenter1.company.com-key.pem for server vcenter1.company.com" "INFO"
        return
    }
    
    # 验证证书文件夹是否存在
    if (-not (Test-Path $CertificateFolder)) {
        Write-Log "Certificate folder does not exist: $CertificateFolder" "ERROR"
        return
    }
    
    if (-not $Force) {
        Write-Log "WARNING: This operation will update key provider certificate in all vCenters!" "WARNING"
        Write-Log "Certificate folder: $CertificateFolder" "WARNING"
        Write-Log "Key Provider name: $KeyProviderName" "WARNING"
        Write-Log "Use -Force parameter to force execution, or press Ctrl+C to cancel" "WARNING"
        
        $confirmation = Read-Host "Confirm updating key provider certificate? (Type 'YES' to confirm)"
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
        
        # 读取该vCenter的证书文件（基于 Server 名称）
        $certificates = Read-VCenterCertificates -CertificateFolder $CertificateFolder -vCenterServer $vCenter.Server
        if ($null -eq $certificates) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Failed to read certificate files" "WARNING"
            $totalSkipped++
            $skippedInfo = @{
                vCenter = $vCenter.Name
                KeyProviderName = $KeyProviderName
                Reason = "Certificate files not found"
            }
            $skippedList += $skippedInfo
            continue
        }
        
        # 连接到vCenter
        $connection = Connect-ToVCenter -vCenter $vCenter
        if (-not $connection) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Connection failed" "WARNING"
            $totalSkipped++
            $skippedInfo = @{
                vCenter = $vCenter.Name
                KeyProviderName = $KeyProviderName
                Reason = "Connection failed"
            }
            $skippedList += $skippedInfo
            continue
        }
        
        try {
            # 获取Key Provider列表
            $keyProviders = Get-KeyProviders -vCenterName $vCenter.Name
            
            if ($keyProviders.Count -eq 0) {
                Write-Log "No key providers found in $($vCenter.Name)" "WARNING"
                $totalSkipped++
                $skippedInfo = @{
                    vCenter = $vCenter.Name
                    KeyProviderName = $KeyProviderName
                    Reason = "No key providers found"
                }
                $skippedList += $skippedInfo
                continue
            }
            
            # 过滤指定的Key Provider
            $targetKeyProvider = $keyProviders | Where-Object { $_.Name -eq $KeyProviderName }
            if ($null -eq $targetKeyProvider -or $targetKeyProvider.Count -eq 0) {
                Write-Log "Key provider '$KeyProviderName' not found in $($vCenter.Name)" "WARNING"
                $totalSkipped++
                $skippedInfo = @{
                    vCenter = $vCenter.Name
                    KeyProviderName = $KeyProviderName
                    Reason = "Key provider not found"
                }
                $skippedList += $skippedInfo
                continue
            }
            
            Write-Log "Found key provider '$KeyProviderName' in $($vCenter.Name)"
            
            # 处理Key Provider
            foreach ($keyProvider in $targetKeyProvider) {
                $totalProcessed++
                Write-Log "Processing Key Provider: $($keyProvider.Name) (#$totalProcessed)"
                
                $result = Update-KeyProviderCertificate -vCenterName $vCenter.Name -KeyProvider $keyProvider -CertificateContent $certificates.Certificate -PrivateKeyContent $certificates.PrivateKey -CACertificateContent $certificates.CACertificate
                
                if ($result.Success) {
                    $totalSuccess++
                } else {
                    $totalFailed++
                    $failedInfo = @{
                        vCenter = $vCenter.Name
                        KeyProviderName = $keyProvider.Name
                        ConnectionStatus = $result.ConnectionStatus.Status
                        ConnectionMessage = $result.ConnectionStatus.Message
                        CTMStatus = $result.CTMStatus.Status
                        CTMMessage = $result.CTMStatus.Message
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
    Write-Log "Total Key Providers processed: $totalProcessed"
    Write-Log "Successfully updated: $totalSuccess"
    Write-Log "Skipped: $totalSkipped"
    Write-Log "Failed: $totalFailed"
    Write-Log ""
    
    # Output skipped Key Provider list
    if ($skippedList.Count -gt 0) {
        Write-Log "Skipped Key Providers:" "INFO"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $skippedList) {
            Write-Log "  vCenter: $($item.vCenter) | Key Provider: $($item.KeyProviderName) | Reason: $($item.Reason)" "INFO"
        }
        Write-Log ""
    }
    
    # Output failed Key Provider list
    if ($failedList.Count -gt 0) {
        Write-Log "Failed Key Providers List:" "ERROR"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $failedList) {
            Write-Log "  vCenter: $($item.vCenter) | Key Provider: $($item.KeyProviderName)" "ERROR"
            if ($item.ConnectionStatus) {
                Write-Log "    Connection Status: $($item.ConnectionStatus) - $($item.ConnectionMessage)" "ERROR"
            }
            if ($item.CTMStatus) {
                Write-Log "    CTM Status: $($item.CTMStatus) - $($item.CTMMessage)" "ERROR"
            }
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

