# PowerShell Script: Create VM folders in a datacenter and assign PowerUser roles
# Function: Connect to a defined vCenter, create VM folders under a datacenter, then grant COD_VMPowerUser
# Folder name format: {Linux|Windows|OVA}_{prod|qa|dev}_{trade|oa}
# Example: Linux_qa_trade
#
# Permission:
#   Linux_*   -> vsphere.local\COD_Linux_PowerUsers   role COD_VMPowerUser
#   Windows_* -> vsphere.local\COD_Windows_PowerUsers role COD_VMPowerUser
#   OVA_*     -> no extra permission
#
# Usage:
#   .\create_vm_folder.ps1 -VCenterName vCenter1 -DatacenterName DC1

param(
    [Parameter(Mandatory = $true)]
    [string]$VCenterName,

    [Parameter(Mandatory = $true)]
    [string]$DatacenterName,

    [Parameter(Mandatory = $false)]
    [string]$LogFile = "create_vm_folder_log.txt"
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

$osTypes = @("Linux", "Windows", "OVA")
$envs = @("prod", "qa", "dev")
$bizTypes = @("trade", "oa")

$permissionMap = @{
    "Linux"   = "vsphere.local\COD_Linux_PowerUsers"
    "Windows" = "vsphere.local\COD_Windows_PowerUsers"
}
$roleName = "COD_VMPowerUser"

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

function Get-FolderNameList {
    $names = @()
    foreach ($osType in $osTypes) {
        foreach ($env in $envs) {
            foreach ($bizType in $bizTypes) {
                $names += "${osType}_${env}_${bizType}"
            }
        }
    }
    return $names
}

function New-VmFolderWithPermission {
    param(
        [object]$ParentFolder,
        [string]$FolderName,
        [object]$ViRole
    )

    try {
        $existing = Get-Folder -Name $FolderName -Location $ParentFolder -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existing) {
            Write-Log "Folder already exists, skip create: $FolderName" "WARNING"
            $folder = $existing
        } else {
            Write-Log "Creating VM folder: $FolderName"
            $folder = New-Folder -Name $FolderName -Location $ParentFolder -ErrorAction Stop
            Write-Log "Created VM folder: $FolderName" "SUCCESS"
        }

        $osType = $FolderName.Split("_")[0]
        if (-not $permissionMap.ContainsKey($osType)) {
            Write-Log "Skip permission for OVA folder: $FolderName"
            return $true
        }

        $principal = $permissionMap[$osType]
        $existingPerm = Get-VIPermission -Entity $folder -ErrorAction SilentlyContinue |
            Where-Object { $_.Principal -eq $principal -and $_.Role -eq $roleName }

        if ($existingPerm) {
            Write-Log "Permission already exists on $FolderName for $principal ($roleName), skip" "WARNING"
            return $true
        }

        Write-Log "Granting $roleName to $principal on $FolderName"
        New-VIPermission -Entity $folder -Principal $principal -Role $ViRole -Propagate:$true -ErrorAction Stop | Out-Null
        Write-Log "Granted $roleName to $principal on $FolderName" "SUCCESS"
        return $true
    } catch {
        Write-Log "Error processing folder $FolderName : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Main {
    $vCenter = $vCenters | Where-Object { $_.Name -eq $VCenterName } | Select-Object -First 1
    if (-not $vCenter) {
        Write-Log "vCenter '$VCenterName' is not in the configured list" "ERROR"
        return
    }

    $folderNames = Get-FolderNameList
    Write-Log "Starting VM folder create task"
    Write-Log "Target vCenter: $VCenterName"
    Write-Log "Target datacenter: $DatacenterName"
    Write-Log "Folders to create: $($folderNames.Count)"
    Write-Log "Log file: $LogFile"

    Write-Host ""
    Write-Host "Planned folders:" -ForegroundColor Yellow
    foreach ($name in $folderNames) {
        $osType = $name.Split("_")[0]
        if ($permissionMap.ContainsKey($osType)) {
            Write-Host "  $name  -> $($permissionMap[$osType]) / $roleName"
        } else {
            Write-Host "  $name  -> no extra permission"
        }
    }
    Write-Host ""
    $confirmation = Read-Host "Confirm create these folders and grant permissions? (Type 'YES' to confirm)"
    if ($confirmation -ne "YES") {
        Write-Log "Operation cancelled by user" "INFO"
        return
    }

    $connection = Connect-ToVCenter -vCenter $vCenter
    if (-not $connection) {
        Write-Log "Abort: connection failed" "ERROR"
        return
    }

    $totalSuccess = 0
    $totalFailed = 0

    try {
        $datacenter = Get-Datacenter -Name $DatacenterName -ErrorAction Stop
        Write-Log "Found datacenter: $($datacenter.Name)" "SUCCESS"

        $vmRootFolder = Get-Folder -Type VM -Location $datacenter | Where-Object { $_.ParentId -eq $datacenter.Id } | Select-Object -First 1
        if (-not $vmRootFolder) {
            $vmRootFolder = Get-Folder -Name "vm" -Location $datacenter -ErrorAction Stop | Select-Object -First 1
        }
        Write-Log "VM root folder: $($vmRootFolder.Name)"

        $viRole = Get-VIRole -Name $roleName -ErrorAction Stop
        Write-Log "Found role: $($viRole.Name)" "SUCCESS"

        foreach ($folderName in $folderNames) {
            $result = New-VmFolderWithPermission -ParentFolder $vmRootFolder -FolderName $folderName -ViRole $viRole
            if ($result) {
                $totalSuccess++
            } else {
                $totalFailed++
            }
        }
    } catch {
        Write-Log "Error processing datacenter $DatacenterName : $($_.Exception.Message)" "ERROR"
    } finally {
        try {
            Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Disconnected from $($vCenter.Name)"
        } catch {
            Write-Log "Error during disconnect: $($_.Exception.Message)" "WARNING"
        }
    }

    Write-Log ""
    Write-Log "=================================================================" "INFO"
    Write-Log "Task Completion Summary" "INFO"
    Write-Log "=================================================================" "INFO"
    Write-Log "vCenter: $VCenterName"
    Write-Log "Datacenter: $DatacenterName"
    Write-Log "Folders planned: $($folderNames.Count)"
    Write-Log "Successfully processed: $totalSuccess"
    Write-Log "Failed: $totalFailed"
    Write-Log "=================================================================" "INFO"
    Write-Log "Detailed log available at: $LogFile" "INFO"
    Write-Log "=================================================================" "INFO"
}

Main

Write-Host "Script execution completed. Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
