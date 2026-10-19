# ====================================================================
# deployCH340.ps1 - WCH CH340 / CH341 Serial Driver Deployment
# ====================================================================
# Purpose:
# 1. Deploys the official WCH CH340/CH341 USB-to-Serial driver (v3.9).
# 2. Stages the driver package into Program Files (tamper-proof).
# 3. Pre-installs the driver package into the Windows Driver Store.
# 4. Triggers PnP rescan and verifies any currently plugged-in CH340 devices.
# 5. Logs status to ch340.log (overwriting on each run to retain latest only).
# ====================================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    # Target directory in Program Files for staging driver files
    [string]$InstallDir = (Join-Path -Path $env:ProgramFiles -ChildPath "SerialDriverFixer\CH340"),

    # Path to log file (defaults to ch340.log in SerialDriverFixer root)
    [string]$LogFile = "",

    # Cleanly remove the staged driver files and unregister driver from Driver Store
    [switch]$Uninstall,

    # Skip device bus rescan after staging
    [switch]$SkipRescan
)

# --------------------------------------------------------------------
# 1. Elevation Check
# --------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Deployment requires elevated administrative privileges. Please run as Administrator or deploy via SYSTEM (Intune/SCCM/GPO)."
    exit 1
}

$sourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $sourceDir) { $sourceDir = (Get-Location).Path }

# Resolve default log file (stored next to InstallDir in SerialDriverFixer root)
if (-not $LogFile) {
    $parentDir = Split-Path -Path $InstallDir -Parent
    if ($parentDir) {
        $LogFile = Join-Path -Path $parentDir -ChildPath "ch340.log"
    } else {
        $LogFile = Join-Path -Path $InstallDir -ChildPath "ch340.log"
    }
}

# --------------------------------------------------------------------
# Helper: Logging (Overwrites log on each run to only retain latest status)
# --------------------------------------------------------------------
if ($LogFile) {
    try {
        $logParent = Split-Path -Path $LogFile -Parent
        if ($logParent -and -not (Test-Path $logParent)) {
            New-Item -Path $logParent -ItemType Directory -Force | Out-Null
        }
        $header = "====================================================`r`nCH340 Driver Deployer - Last Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n===================================================="
        Set-Content -Path $LogFile -Value $header -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Write-CH340Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry  = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "WARN"  { Write-Warning $Message }
        "ERROR" { Write-Error $Message -ErrorAction Continue }
        default { Write-Host $Message -ForegroundColor $ForegroundColor }
    }

    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logEntry -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

# ====================================================================
# UNINSTALLATION ROUTINE
# ====================================================================
if ($Uninstall) {
    Write-CH340Log "--- Uninstalling CH340 Driver ---" "WARN" [ConsoleColor]::Yellow

    # Remove CH340 drivers from Windows Driver Store
    try {
        $pnpCsv = & pnputil.exe /enum-drivers /class Ports /format csv 2>$null
        if ($LASTEXITCODE -eq 0 -and $pnpCsv) {
            $parsed = $pnpCsv | ConvertFrom-Csv
            foreach ($row in $parsed) {
                if ($row.ProviderName -match "wch\.cn|WinChipHead" -or $row.OriginalName -match "^ch34.*\.inf") {
                    Write-CH340Log "Removing driver package '$($row.DriverName)' ($($row.OriginalName))..." "INFO" [ConsoleColor]::Cyan
                    & pnputil.exe /delete-driver $row.DriverName /uninstall /force | Out-Null
                }
            }
        }
    } catch {
        Write-CH340Log "Could not enumerate driver store for CH340 drivers: $_" "WARN"
    }

    # Remove staged directory
    if (Test-Path $InstallDir) {
        Write-CH340Log "Removing staged directory: $InstallDir..." "INFO" [ConsoleColor]::Cyan
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    if (-not $SkipRescan) {
        Write-CH340Log "Rescanning devices..." "INFO" [ConsoleColor]::Cyan
        & pnputil.exe /scan-devices | Out-Null
    }

    Write-CH340Log "CH340 uninstallation completed successfully." "INFO" [ConsoleColor]::Green
    exit 0
}

# ====================================================================
# INSTALLATION & DEPLOYMENT ROUTINE
# ====================================================================
Write-CH340Log "====================================================" "INFO" [ConsoleColor]::Cyan
Write-CH340Log " Deploying WCH CH340 / CH341 Serial Driver" "INFO" [ConsoleColor]::Cyan
Write-CH340Log " Target Directory: $InstallDir" "INFO" [ConsoleColor]::Cyan
Write-CH340Log " Log File:        $LogFile (Overwrites each run)" "INFO" [ConsoleColor]::Cyan
Write-CH340Log "====================================================" "INFO" [ConsoleColor]::Cyan

# --------------------------------------------------------------------
# 2. Locate Source Driver Package
# --------------------------------------------------------------------
$driverCandidates = @(
    (Join-Path -Path $sourceDir -ChildPath "CH340\CH341SER.INF"),
    (Join-Path -Path $sourceDir -ChildPath "CH341SER.INF")
)

$sourceInf = $null
foreach ($cand in $driverCandidates) {
    if (Test-Path $cand) {
        $sourceInf = $cand
        break
    }
}

if (-not $sourceInf) {
    Write-CH340Log "CRITICAL: CH340 driver file 'CH341SER.INF' not found in '$sourceDir' or '$(Join-Path $sourceDir 'CH340')'!" "ERROR"
    exit 1
}

$sourceDriverDir = Split-Path -Path $sourceInf -Parent

# --------------------------------------------------------------------
# 3. Stage Files to Protected Program Files Directory
# --------------------------------------------------------------------
Write-CH340Log "Creating target directory: $InstallDir..." "INFO" [ConsoleColor]::Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

Write-CH340Log "Staging CH340 driver files from '$sourceDriverDir'..." "INFO" [ConsoleColor]::Cyan
Get-ChildItem -Path $sourceDriverDir | Copy-Item -Destination $InstallDir -Recurse -Force

$stagedInf = Join-Path -Path $InstallDir -ChildPath "CH341SER.INF"

# --------------------------------------------------------------------
# 4. Pre-install Target Driver into Windows Driver Store
# --------------------------------------------------------------------
Write-CH340Log "Registering CH340 driver package into Windows Driver Store..." "INFO" [ConsoleColor]::Cyan
$addDriverOut = & pnputil.exe /add-driver $stagedInf /install 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-CH340Log "pnputil add-driver exited with code $($LASTEXITCODE): $addDriverOut" "WARN"
} else {
    Write-CH340Log "Successfully registered CH340 driver in Driver Store." "INFO" [ConsoleColor]::Green
}

# --------------------------------------------------------------------
# 5. Device Rescan and Verification
# --------------------------------------------------------------------
if (-not $SkipRescan) {
    Write-CH340Log "Triggering PnP device rescan..." "INFO" [ConsoleColor]::Cyan
    $scanOut = & pnputil.exe /scan-devices 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-CH340Log "Device rescan exited with code $($LASTEXITCODE): $scanOut" "WARN"
    } else {
        Write-CH340Log "Hardware rescan completed successfully." "INFO" [ConsoleColor]::Green
    }
}

# Check for currently connected CH340 devices
$ch340Devices = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'CH340' -or $_.InstanceId -match 'VID_1A86'
}

Write-CH340Log "" "INFO"
Write-CH340Log "====================================================" "INFO" [ConsoleColor]::Green
Write-CH340Log " SUCCESS: CH340 driver deployment completed!" "INFO" [ConsoleColor]::Green
Write-CH340Log " Staged Location: $InstallDir" "INFO" [ConsoleColor]::Green
Write-CH340Log " INF File:        $stagedInf" "INFO" [ConsoleColor]::Green
Write-CH340Log " Log File:        $LogFile" "INFO" [ConsoleColor]::Green

if ($ch340Devices) {
    Write-CH340Log "`nConnected CH340 Hardware Detected:" "INFO" [ConsoleColor]::Cyan
    foreach ($dev in $ch340Devices) {
        $statusColor = if ($dev.Status -eq "OK") { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-CH340Log "  - $($dev.FriendlyName) [$($dev.Status)]" "INFO" $statusColor
        Write-CH340Log "    Instance: $($dev.InstanceId)" "INFO" [ConsoleColor]::Gray
    }
} else {
    Write-CH340Log "`nNote: No CH340 hardware is currently connected. Devices will automatically configure when plugged in." "INFO" [ConsoleColor]::Gray
}
Write-CH340Log "====================================================" "INFO" [ConsoleColor]::Green
