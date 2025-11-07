# PowerShell Script: Update vCenter SSL Certificate
# Function: Connect to all vCenters, update vCenter SSL certificate

param(
    [Parameter(Mandatory=$false)]
    [string]$LogFile = "update_vcenter_ssl_cert_log.txt",
    [Parameter(Mandatory=$false)]
    [string]$CertificateFolder = "",
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

# 读取vCenter的SSL证书文件（证书、私钥、CA证书）
function Read-VCenterSSLCertificates {
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
            CertificateFilePath = $certFile
            PrivateKeyFilePath = $keyFile
            CACertificateFilePath = $caFile
        }
    } catch {
        Write-Log "Error reading certificate files for $vCenterServer: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# 检查vCenter SSL证书状态
function Check-VCenterSSLCertificateStatus {
    param(
        [string]$vCenterName,
        [string]$vCenterServer
    )
    
    try {
        Write-Log "Checking SSL certificate status for vCenter: $vCenterName ($vCenterServer)..."
        
        # 使用 vSphere API 检查 SSL 证书状态
        # 获取 ServiceInstance 和 CertificateManager
        $si = Get-View ServiceInstance
        $certMgr = Get-View $si.Content.CertificateManager
        
        # 获取当前证书信息
        $certInfo = $certMgr.CertificateInfo
        
        # 检查证书状态
        $isValid = $true
        $statusMessage = ""
        $statusDetails = @()
        
        # 检查证书是否有效
        if ($null -eq $certInfo) {
            $isValid = $false
            $statusMessage = "Certificate info is null"
            $statusDetails += "Certificate info is null"
        } else {
            # 检查证书是否过期
            if ($certInfo.NotAfter) {
                $expiryDate = $certInfo.NotAfter
                $currentDate = Get-Date
                if ($expiryDate -lt $currentDate) {
                    $isValid = $false
                    $statusMessage = "Certificate expired on $expiryDate"
                    $statusDetails += "Certificate expired on $expiryDate"
                } else {
                    $daysUntilExpiry = ($expiryDate - $currentDate).Days
                    $statusDetails += "Certificate valid until $expiryDate (expires in $daysUntilExpiry days)"
                }
            }
            
            # 检查证书生效日期
            if ($certInfo.NotBefore) {
                $validFrom = $certInfo.NotBefore
                $currentDate = Get-Date
                if ($validFrom -gt $currentDate) {
                    $isValid = $false
                    $statusMessage = "Certificate not yet valid (valid from $validFrom)"
                    $statusDetails += "Certificate not yet valid (valid from $validFrom)"
                } else {
                    $statusDetails += "Certificate valid from $validFrom"
                }
            }
            
            # 检查证书主题和颁发者
            if ($certInfo.Subject) {
                $statusDetails += "Subject: $($certInfo.Subject)"
                Write-Log "Certificate Subject: $($certInfo.Subject)" "INFO"
            }
            
            if ($certInfo.Issuer) {
                $statusDetails += "Issuer: $($certInfo.Issuer)"
                Write-Log "Certificate Issuer: $($certInfo.Issuer)" "INFO"
            }
            
            # 检查证书指纹
            if ($certInfo.ThumbprintSHA1) {
                Write-Log "Certificate Thumbprint (SHA1): $($certInfo.ThumbprintSHA1)" "INFO"
            }
        }
        
        # 尝试验证证书链
        try {
            # 检查是否有 CA 证书链
            $caCerts = $certMgr.CACertificates
            if ($caCerts -and $caCerts.Count -gt 0) {
                $statusDetails += "CA certificates found: $($caCerts.Count)"
                Write-Log "Found $($caCerts.Count) CA certificate(s)" "INFO"
            } else {
                Write-Log "No CA certificates found" "WARNING"
            }
        } catch {
            Write-Log "Could not check CA certificates: $($_.Exception.Message)" "WARNING"
        }
        
        if ($isValid) {
            Write-Log "SSL certificate status is normal for vCenter $vCenterName" "SUCCESS"
            foreach ($detail in $statusDetails) {
                Write-Log "  - $detail" "INFO"
            }
            return @{
                IsValid = $true
                Status = "Normal"
                Message = ($statusDetails -join "; ")
            }
        } else {
            Write-Log "SSL certificate status is abnormal for vCenter $vCenterName" "ERROR"
            foreach ($detail in $statusDetails) {
                Write-Log "  - $detail" "ERROR"
            }
            return @{
                IsValid = $false
                Status = "Abnormal"
                Message = $statusMessage
            }
        }
    } catch {
        Write-Log "Error checking SSL certificate status for vCenter $vCenterName: $($_.Exception.Message)" "ERROR"
        return @{
            IsValid = $false
            Status = "Error"
            Message = $_.Exception.Message
        }
    }
}

# 更新vCenter SSL证书
function Update-VCenterSSLCertificate {
    param(
        [string]$vCenterName,
        [string]$vCenterServer,
        [hashtable]$Certificates
    )
    
    try {
        Write-Log "Updating SSL certificate for vCenter: $vCenterName ($vCenterServer)"
        
        # 使用 vSphere API 的 CertificateManager 来更新证书
        # 获取 ServiceInstance 和 CertificateManager
        $si = Get-View ServiceInstance
        $certMgr = Get-View $si.Content.CertificateManager
        
        # 创建证书信息对象
        # 注意：根据 vSphere API 版本，可能需要调整证书格式
        $certInfo = New-Object VMware.Vim.CertificateInfo
        
        # 设置证书内容（去除可能的头尾标记和换行符）
        $certContent = $Certificates.Certificate -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "`r`n", "" -replace "`n", "" -replace "`r", ""
        $keyContent = $Certificates.PrivateKey -replace "-----BEGIN PRIVATE KEY-----", "" -replace "-----END PRIVATE KEY-----", "" -replace "-----BEGIN RSA PRIVATE KEY-----", "" -replace "-----END RSA PRIVATE KEY-----", "" -replace "`r`n", "" -replace "`n", "" -replace "`r", ""
        
        # 设置证书信息
        $certInfo.Certificate = $certContent
        $certInfo.PrivateKey = $keyContent
        
        # 如果有 CA 证书，也需要设置
        if (-not [string]::IsNullOrEmpty($Certificates.CACertificate)) {
            $caContent = $Certificates.CACertificate -replace "-----BEGIN CERTIFICATE-----", "" -replace "-----END CERTIFICATE-----", "" -replace "`r`n", "" -replace "`n", "" -replace "`r", ""
            # 注意：CertificateInfo 可能需要链式证书，具体取决于 API 版本
        }
        
        # 调用 ReplaceCertificate 方法更新证书
        # 注意：某些版本可能需要使用 ReplaceCACertificatesAndCRLs 或其他方法
        $certMgr.ReplaceCertificate($certInfo)
        
        Write-Log "Certificate update command completed for vCenter $vCenterName" "INFO"
        
        # 等待一段时间让证书生效
        Write-Log "Waiting for certificate to take effect..." "INFO"
        Start-Sleep -Seconds 5
        
        # 检查SSL证书状态
        $sslStatus = Check-VCenterSSLCertificateStatus -vCenterName $vCenterName -vCenterServer $vCenterServer
        
        if ($sslStatus.IsValid) {
            Write-Log "Successfully updated SSL certificate for vCenter $vCenterName - Status is normal" "SUCCESS"
            return @{
                Success = $true
                SSLStatus = $sslStatus
            }
        } else {
            Write-Log "Certificate updated but SSL status is abnormal for vCenter $vCenterName" "ERROR"
            Write-Log "SSL Status: $($sslStatus.Status) - $($sslStatus.Message)" "ERROR"
            return @{
                Success = $false
                SSLStatus = $sslStatus
            }
        }
    } catch {
        Write-Log "Error updating SSL certificate for vCenter $vCenterName: $($_.Exception.Message)" "ERROR"
        Write-Log "Error details: $($_.Exception.GetType().FullName)" "ERROR"
        if ($_.Exception.InnerException) {
            Write-Log "Inner exception: $($_.Exception.InnerException.Message)" "ERROR"
        }
        return @{
            Success = $false
            SSLStatus = @{
                IsValid = $false
                Status = "Error"
                Message = $_.Exception.Message
            }
        }
    }
}

# 主执行逻辑
function Main {
    Write-Log "Starting vCenter SSL certificate update task"
    Write-Log "Log file: $LogFile"
    
    # 验证证书文件夹参数
    if ([string]::IsNullOrEmpty($CertificateFolder)) {
        Write-Log "Certificate folder path is required. Please provide -CertificateFolder parameter." "ERROR"
        Write-Log "Usage: .\update_vcenter_ssl_cert.ps1 -CertificateFolder <path> [-Force]" "INFO"
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
        Write-Log "WARNING: This operation will update SSL certificate in all vCenters!" "WARNING"
        Write-Log "Certificate folder: $CertificateFolder" "WARNING"
        Write-Log "Use -Force parameter to force execution, or press Ctrl+C to cancel" "WARNING"
        
        $confirmation = Read-Host "Confirm updating vCenter SSL certificate? (Type 'YES' to confirm)"
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
        $certificates = Read-VCenterSSLCertificates -CertificateFolder $CertificateFolder -vCenterServer $vCenter.Server
        if ($null -eq $certificates) {
            Write-Log "Skipping vCenter: $($vCenter.Name) - Failed to read certificate files" "WARNING"
            $totalSkipped++
            $skippedInfo = @{
                vCenter = $vCenter.Name
                Server = $vCenter.Server
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
                Server = $vCenter.Server
                Reason = "Connection failed"
            }
            $skippedList += $skippedInfo
            continue
        }
        
        try {
            # 更新vCenter SSL证书
            $totalProcessed++
            Write-Log "Updating SSL certificate for vCenter: $($vCenter.Name) (#$totalProcessed)"
            
            $result = Update-VCenterSSLCertificate -vCenterName $vCenter.Name -vCenterServer $vCenter.Server -Certificates $certificates
            
            if ($result.Success) {
                $totalSuccess++
            } else {
                $totalFailed++
                $failedInfo = @{
                    vCenter = $vCenter.Name
                    Server = $vCenter.Server
                    SSLStatus = $result.SSLStatus.Status
                    SSLMessage = $result.SSLStatus.Message
                }
                $failedList += $failedInfo
            }
            
        } catch {
            Write-Log "Error processing vCenter $($vCenter.Name): $($_.Exception.Message)" "ERROR"
            $totalFailed++
            $failedInfo = @{
                vCenter = $vCenter.Name
                Server = $vCenter.Server
                SSLStatus = "Error"
                SSLMessage = $_.Exception.Message
            }
            $failedList += $failedInfo
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
    Write-Log "Total vCenters processed: $totalProcessed"
    Write-Log "Successfully updated: $totalSuccess"
    Write-Log "Skipped: $totalSkipped"
    Write-Log "Failed: $totalFailed"
    Write-Log ""
    
    # Output skipped vCenter list
    if ($skippedList.Count -gt 0) {
        Write-Log "Skipped vCenters:" "INFO"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $skippedList) {
            Write-Log "  vCenter: $($item.vCenter) | Server: $($item.Server) | Reason: $($item.Reason)" "INFO"
        }
        Write-Log ""
    }
    
    # Output failed vCenter list
    if ($failedList.Count -gt 0) {
        Write-Log "Failed vCenters List:" "ERROR"
        Write-Log "=================================================================" "INFO"
        foreach ($item in $failedList) {
            Write-Log "  vCenter: $($item.vCenter) | Server: $($item.Server)" "ERROR"
            if ($item.SSLStatus) {
                Write-Log "    SSL Status: $($item.SSLStatus) - $($item.SSLMessage)" "ERROR"
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

