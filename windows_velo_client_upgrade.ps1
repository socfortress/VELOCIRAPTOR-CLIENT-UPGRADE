#requires -version 5.1
<#
.SYNOPSIS
    Upgrades the Velociraptor Windows client to 0.76.2 using the endpoint's
    existing client.config.yaml and automatic service discovery.

.DESCRIPTION
    - Downloads the official Velociraptor 0.76.2 MSI.
    - Detects the installed Velociraptor service automatically.
    - Stops the service if present.
    - Backs up the existing client.config.yaml already on the endpoint.
    - Installs the new MSI silently.
    - Restores the original client.config.yaml in case the MSI overwrote it.
    - Starts the service and verifies health/version.
    - Does NOT modify velociraptor.writeback.yaml.

.NOTES
    Run as Administrator.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DownloadUrl = "https://github.com/Velocidex/velociraptor/releases/download/v0.76/velociraptor-v0.76.2-windows-amd64.msi",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedVersion = "0.76.2",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = "C:\ProgramData\Velociraptor",

    [switch]$SkipVersionCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallDir              = "C:\Program Files\Velociraptor"
$ExePath                 = Join-Path $InstallDir "Velociraptor.exe"
$InstalledConfig         = Join-Path $InstallDir "client.config.yaml"
$WritebackPath           = Join-Path $InstallDir "velociraptor.writeback.yaml"

$DownloadDir             = Join-Path $WorkingDirectory "Downloads"
$LogDir                  = Join-Path $WorkingDirectory "Logs"
$BackupDir               = Join-Path $WorkingDirectory "Backup"
$MsiPath                 = Join-Path $DownloadDir "velociraptor-v0.76.2-windows-amd64.msi"
$LogPath                 = Join-Path $LogDir "velociraptor-upgrade.log"
$MsiLogPath              = Join-Path $LogDir "velociraptor-msi-install.log"
$ConfigBackupPath        = Join-Path $BackupDir "client.config.yaml.backup"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line

    if ($script:LogPathInitialized) {
        Add-Content -Path $LogPath -Value $line
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VelociraptorService {
    $services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'Velociraptor' -or
        $_.DisplayName -match 'Velociraptor' -or
        $_.PathName -match 'Velociraptor'
    }

    if (-not $services) {
        return $null
    }

    $preferred = $services | Where-Object {
        $_.PathName -match [regex]::Escape($ExePath)
    } | Select-Object -First 1

    if ($preferred) {
        return $preferred
    }

    return $services | Select-Object -First 1
}

function Get-InstalledVelociraptorVersion {
    if (-not (Test-Path -LiteralPath $ExePath)) {
        return $null
    }

    try {
        $versionInfo = (Get-Item -LiteralPath $ExePath).VersionInfo
        if ($versionInfo.ProductVersion) { return $versionInfo.ProductVersion }
        if ($versionInfo.FileVersion) { return $versionInfo.FileVersion }
        return $null
    }
    catch {
        return $null
    }
}

function Stop-ServiceSafe {
    param([Parameter(Mandatory = $true)][string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "Service '$Name' not found. Continuing."
        return
    }

    if ($svc.Status -ne "Stopped") {
        Write-Log "Stopping service '$Name'."
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $svc.WaitForStatus("Stopped", (New-TimeSpan -Minutes 2))
    }
    else {
        Write-Log "Service '$Name' is already stopped."
    }
}

function Start-ServiceSafe {
    param([Parameter(Mandatory = $true)][string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -ne "Running") {
        Write-Log "Starting service '$Name'."
        Start-Service -Name $Name -ErrorAction Stop
        $svc.WaitForStatus("Running", (New-TimeSpan -Minutes 2))
    }
    else {
        Write-Log "Service '$Name' is already running."
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-Log "Downloading MSI from '$Url'."

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -MaximumRedirection 5
    }
    catch {
        throw "Failed to download MSI from '$Url'. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Download did not produce expected file '$Destination'."
    }

    $size = (Get-Item -LiteralPath $Destination).Length
    if ($size -le 0) {
        throw "Downloaded MSI is empty: '$Destination'."
    }

    Write-Log "Downloaded MSI to '$Destination' ($size bytes)."
}

function Install-Msi {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "MSI not found at '$Path'."
    }

    $arguments = @(
        "/i"
        "`"$Path`""
        "/qn"
        "/norestart"
        "/L*v"
        "`"$MsiLogPath`""
    )

    Write-Log "Launching MSI upgrade."
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden

    switch ($process.ExitCode) {
        0     { Write-Log "MSI completed successfully." }
        1641  { Write-Log "MSI completed successfully and requested restart (1641)." "WARN" }
        3010  { Write-Log "MSI completed successfully; restart required (3010)." "WARN" }
        default {
            throw "MSI installation failed with exit code $($process.ExitCode). Review '$MsiLogPath'."
        }
    }
}

function Backup-ExistingConfig {
    if (-not (Test-Path -LiteralPath $InstalledConfig)) {
        throw "Existing client config not found at '$InstalledConfig'."
    }

    Copy-Item -LiteralPath $InstalledConfig -Destination $ConfigBackupPath -Force
    Write-Log "Backed up existing client config to '$ConfigBackupPath'."
}

function Restore-ExistingConfig {
    if (-not (Test-Path -LiteralPath $ConfigBackupPath)) {
        throw "Backup config not found at '$ConfigBackupPath'."
    }

    Copy-Item -LiteralPath $ConfigBackupPath -Destination $InstalledConfig -Force
    Write-Log "Restored existing client config to '$InstalledConfig'."
}

function Test-ServiceBinaryPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        throw "Service '$Name' not found after installation."
    }

    if ($svc.PathName -match [regex]::Escape($ExePath)) {
        Write-Log "Verified service path references '$ExePath'."
    }
    else {
        Write-Log "Service path is '$($svc.PathName)' and did not exactly match '$ExePath'." "WARN"
    }
}

try {
    Ensure-Directory -Path $WorkingDirectory
    Ensure-Directory -Path $DownloadDir
    Ensure-Directory -Path $LogDir
    Ensure-Directory -Path $BackupDir
    Ensure-Directory -Path $InstallDir

    $script:LogPathInitialized = $true

    if (-not (Test-IsAdministrator)) {
        throw "This script must be run as Administrator."
    }

    Write-Log "Starting Velociraptor client upgrade using endpoint's existing client.config.yaml."
    Write-Log "Download URL: $DownloadUrl"

    $beforeVersion = Get-InstalledVelociraptorVersion
    if ($beforeVersion) {
        Write-Log "Existing version detected: $beforeVersion"
    }
    else {
        Write-Log "No existing Velociraptor binary detected at '$ExePath'." "WARN"
    }

    if (Test-Path -LiteralPath $WritebackPath) {
        Write-Log "Existing writeback file detected at '$WritebackPath'. It will be preserved."
    }
    else {
        Write-Log "No writeback file found at '$WritebackPath'. Continuing." "WARN"
    }

    $existingService = Get-VelociraptorService
    if ($existingService) {
        $serviceName = $existingService.Name
        Write-Log "Detected Velociraptor service name: '$serviceName' (DisplayName: '$($existingService.DisplayName)')."
    }
    else {
        $serviceName = $null
        Write-Log "No existing Velociraptor service detected before upgrade. Continuing." "WARN"
    }

    if ($serviceName) {
        Stop-ServiceSafe -Name $serviceName
    }

    Backup-ExistingConfig
    Download-File -Url $DownloadUrl -Destination $MsiPath
    Install-Msi -Path $MsiPath
    Restore-ExistingConfig

    $postInstallService = Get-VelociraptorService
    if (-not $postInstallService) {
        throw "Could not find the Velociraptor service after installation."
    }

    $serviceName = $postInstallService.Name
    Write-Log "Using detected post-install service name: '$serviceName' (DisplayName: '$($postInstallService.DisplayName)')."

    Test-ServiceBinaryPath -Name $serviceName
    Start-ServiceSafe -Name $serviceName

    Start-Sleep -Seconds 5

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -ne "Running") {
        throw "Service '$serviceName' is not running after upgrade."
    }

    Write-Log "Verified service '$serviceName' is running."

    if (-not $SkipVersionCheck) {
        $afterVersion = Get-InstalledVelociraptorVersion
        if (-not $afterVersion) {
            throw "Could not determine installed version from '$ExePath'."
        }

        Write-Log "Installed version after upgrade: $afterVersion"

        if ($afterVersion -notlike "$ExpectedVersion*") {
            throw "Installed version '$afterVersion' does not match expected '$ExpectedVersion'."
        }

        Write-Log "Verified installed version matches expected '$ExpectedVersion'."
    }
    else {
        Write-Log "Version check skipped." "WARN"
    }

    Write-Log "Velociraptor client upgrade completed successfully."
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}
