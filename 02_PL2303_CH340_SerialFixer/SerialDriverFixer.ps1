# ====================================================================
# SerialDriverFixer.ps1 - Driver Watchdog & Integrity Enforcement
# ====================================================================
# Designed to run silently under SYSTEM at startup and user logon.
# 1. Scans Driver Store for Prolific USB-to-Serial drivers.
# 2. Removes any newer/incompatible versions pushed by Windows Update.
# 3. Ensures legacy working driver (v3.3.2.102) remains installed.
# 4. Triggers PnP rescan to rebind connected serial adapters.
# ====================================================================

[CmdletBinding()]
param(
    [version]$TargetVersion = [version]"3.3.2.102",
    [version[]]$AllowedVersions = @([version]"3.3.2.102"),
    [string]$DriverDir = "",
    [string]$LogFile = "",
    [int]$DelaySeconds = 0,
    [switch]$Quiet
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $DriverDir) {
    if (Test-Path (Join-Path -Path $scriptDir -ChildPath "PL2303")) {
        $DriverDir = Join-Path -Path $scriptDir -ChildPath "PL2303"
    } else {
        $DriverDir = Join-Path -Path $scriptDir -ChildPath "Driver"
    }
}
if (-not $LogFile) {
    $LogFile = Join-Path -Path $scriptDir -ChildPath "pl2303.log"
}

# Optional initial settling delay (useful when triggered at boot)
if ($DelaySeconds -gt 0) {
    Start-Sleep -Seconds $DelaySeconds
}

# --------------------------------------------------------------------
# Helper: Logging (Overwrites log on each run to only retain latest status)
# --------------------------------------------------------------------
$legacyLog = if ($LogFile) { Join-Path -Path (Split-Path -Path $LogFile -Parent) -ChildPath "watchdog.log" } else { $null }

if ($LogFile) {
    try {
        $logParent = Split-Path -Path $LogFile -Parent
        if ($logParent -and -not (Test-Path $logParent)) {
            New-Item -Path $logParent -ItemType Directory -Force | Out-Null
        }
        $header = "====================================================`r`nPL2303 Driver Watchdog - Last Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n===================================================="
        Set-Content -Path $LogFile -Value $header -Force -ErrorAction SilentlyContinue
        if ($legacyLog -and $LogFile -ne $legacyLog) {
            Set-Content -Path $legacyLog -Value $header -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Write-FixerLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry  = "[$timestamp] [$Level] $Message"

    if (-not $Quiet) {
        switch ($Level) {
            "WARN"  { Write-Warning $Message }
            "ERROR" { Write-Error $Message -ErrorAction Continue }
            default { Write-Output $logEntry }
        }
    }

    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logEntry -Force -ErrorAction SilentlyContinue
            if ($legacyLog -and $LogFile -ne $legacyLog) {
                Add-Content -Path $legacyLog -Value $logEntry -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

# --------------------------------------------------------------------
# Privilege Check
# --------------------------------------------------------------------
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    Write-FixerLog "Administrative privileges required. Run as Administrator or SYSTEM." "ERROR"
    exit 1
}

Write-FixerLog "--- SerialDriverFixer execution started ---"

# Resolve driver INF location (supports staged 'PL2303' subfolder, 'Driver' subfolder, or current folder)
$driverInfPath = Join-Path -Path $DriverDir -ChildPath "Ser2pl.inf"
if (-not (Test-Path $driverInfPath)) {
    $searchPaths = @(
        (Join-Path -Path $scriptDir -ChildPath "PL2303\Ser2pl.inf"),
        (Join-Path -Path $scriptDir -ChildPath "Driver\Ser2pl.inf"),
        (Join-Path -Path $scriptDir -ChildPath "Ser2pl.inf")
    )
    foreach ($cand in $searchPaths) {
        if (Test-Path $cand) {
            $driverInfPath = $cand
            $DriverDir = Split-Path -Path $cand -Parent
            break
        }
    }
}

# --------------------------------------------------------------------
# Query Driver Store for Prolific Drivers
# --------------------------------------------------------------------
function Get-ProlificDrivers {
    $drivers = @()

    # Primary method: pnputil CSV output (fast, lightweight, no DISM overhead)
    try {
        $pnpCsv = & pnputil.exe /enum-drivers /class Ports /format csv 2>$null
        if ($LASTEXITCODE -eq 0 -and $pnpCsv) {
            $parsed = $pnpCsv | ConvertFrom-Csv
            foreach ($row in $parsed) {
                if ($row.ProviderName -match "Prolific" -or $row.OriginalName -match "^ser2pl.*\.inf") {
                    $ver = $null
                    if ($row.DriverVersion -match '(\d+\.\d+\.\d+\.\d+)') {
                        $ver = [version]$matches[1]
                    }
                    $drivers += [PSCustomObject]@{
                        DriverName   = $row.DriverName
                        OriginalName = $row.OriginalName
                        Provider     = $row.ProviderName
                        Version      = $ver
                        RawVersion   = $row.DriverVersion
                    }
                }
            }
            return $drivers
        }
    } catch {
        Write-FixerLog "Notice: pnputil CSV enumeration encountered an issue: $_" "WARN"
    }

    # Fallback method: DISM Get-WindowsDriver
    try {
        $dismDrivers = Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object {
            $_.ProviderName -match "Prolific" -or $_.OriginalFileName -match "ser2pl"
        }
        foreach ($d in $dismDrivers) {
            $ver = $null
            if ($d.Version -match '(\d+\.\d+\.\d+\.\d+)') {
                $ver = [version]$matches[1]
            }
            $drivers += [PSCustomObject]@{
                DriverName   = $d.Driver
                OriginalName = $d.OriginalFileName
                Provider     = $d.ProviderName
                Version      = $ver
                RawVersion   = $d.Version
            }
        }
    } catch {
        Write-FixerLog "Notice: DISM fallback enumeration encountered an issue: $_" "WARN"
    }

    return $drivers
}

$installedDrivers = Get-ProlificDrivers
Write-FixerLog "Discovered $($installedDrivers.Count) Prolific driver package(s) in Driver Store."

$changesMade = $false

# --------------------------------------------------------------------
# Purge Incompatible / Newer Drivers
# --------------------------------------------------------------------
foreach ($item in $installedDrivers) {
    if ($null -eq $item.Version) {
        Write-FixerLog "Could not parse version for $($item.DriverName) ($($item.RawVersion)). Skipping." "WARN"
        continue
    }

    if ($item.Version -notin $AllowedVersions) {
        Write-FixerLog "Incompatible driver detected: $($item.DriverName) (v$($item.Version)). Purging..." "WARN"
        $deleteOut = & pnputil.exe /delete-driver $item.DriverName /uninstall /force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-FixerLog "Successfully uninstalled and deleted $($item.DriverName)." "INFO"
            $changesMade = $true
        } else {
            Write-FixerLog "pnputil returned exit code $($LASTEXITCODE) deleting $($item.DriverName): $deleteOut" "ERROR"
        }
    } else {
        Write-FixerLog "Retaining allowed driver package: $($item.DriverName) (v$($item.Version))." "INFO"
    }
}

# --------------------------------------------------------------------
# Ensure Target Driver (3.3.2.102) is Installed
# --------------------------------------------------------------------
# Re-query drivers after purge to verify target version presence
$currentDrivers = Get-ProlificDrivers
$targetFound = $currentDrivers | Where-Object { $_.Version -eq $TargetVersion }

if (-not $targetFound) {
    if (Test-Path $driverInfPath) {
        Write-FixerLog "Target driver v$TargetVersion not found in store. Installing from '$driverInfPath'..." "INFO"
        $addOut = & pnputil.exe /add-driver $driverInfPath /install 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-FixerLog "Successfully registered and installed driver v$TargetVersion." "INFO"
            $changesMade = $true
        } else {
            Write-FixerLog "Failed to install driver from '$driverInfPath': $addOut" "ERROR"
        }
    } else {
        Write-FixerLog "CRITICAL: Target driver INF not found at '$driverInfPath'!" "ERROR"
    }
} else {
    Write-FixerLog "Target driver v$TargetVersion verified present in Driver Store." "INFO"
}

# --------------------------------------------------------------------
# Hardware Rescan
# --------------------------------------------------------------------
if ($changesMade) {
    Write-FixerLog "Triggering PnP device rescan to bind connected hardware..." "INFO"
    $scanOut = & pnputil.exe /scan-devices 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-FixerLog "Notice: Device rescan exited with code $($LASTEXITCODE): $scanOut" "WARN"
    } else {
        Write-FixerLog "Hardware rescan completed successfully." "INFO"
    }
} else {
    Write-FixerLog "No driver modifications required. System is clean." "INFO"
}

Write-FixerLog "--- SerialDriverFixer execution completed ---"
exit 0
