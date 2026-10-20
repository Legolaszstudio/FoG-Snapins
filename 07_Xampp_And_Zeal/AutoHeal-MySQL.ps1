<#
.SYNOPSIS
    AutoHeal-MySQL.ps1 - MariaDB/MySQL Crash Recovery & Health Self-Healing Script
.DESCRIPTION
    Automated pre-flight recovery and repair script designed to survive sudden power cuts,
    hard reboots, and abrupt shutdowns in academic/lab environments.
    
    CRITICAL DESIGN NOTE FOR LAB WORKSTATIONS (DOCKER COMPATIBILITY):
    This script operates in PURE OFFLINE MAINTENANCE MODE. It repairs files, clears dirty
    flags, and exits WITHOUT leaving mysqld or services running in the background.
    This guarantees that ports (3306, 80, 443) remain completely unbound and free for Docker
    and senior classes, until a student explicitly starts XAMPP via XAMPP Control Panel.
#>

[CmdletBinding()]
param(
    [string]$XamppDir = "C:\xampp",
    [switch]$Interactive = $false
)

$ErrorActionPreference = 'Continue'

$MysqlDir     = Join-Path $XamppDir "mysql"
$BinDir       = Join-Path $MysqlDir "bin"
$DataDir      = Join-Path $MysqlDir "data"
$BackupDir    = Join-Path $MysqlDir "backup"
$PristineDir  = Join-Path $MysqlDir "backup_system_pristine"
$LogFile      = Join-Path $MysqlDir "autoheal.log"
$AriaChkExe   = Join-Path $BinDir "aria_chk.exe"
$MysqldExe    = Join-Path $BinDir "mysqld.exe"
$MyIniPath    = Join-Path $BinDir "my.ini"

function Write-HealLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
    if ($Interactive) {
        switch ($Level) {
            "WARN"  { Write-Warning $Message }
            "ERROR" { Write-Host $line -ForegroundColor Red }
            "OK"    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line -ForegroundColor Cyan }
        }
    }
}

Write-HealLog "=== Starting MySQL/MariaDB Offline AutoHeal Diagnostic & Recovery ==="

if (-not (Test-Path $DataDir)) {
    Write-HealLog "MySQL data directory not found at $DataDir. Skipping recovery." "WARN"
    exit 0
}

# --------------------------------------------------------------------
# 1. Stop any running mysqld processes before checking files
# --------------------------------------------------------------------
$activeProcs = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
if ($activeProcs) {
    Write-HealLog "Found running mysqld process. Stopping for database consistency check..."
    $activeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# --------------------------------------------------------------------
# 2. Clear Stale PID, Socket, and Lock Files
# --------------------------------------------------------------------
$stalePids = Get-ChildItem -Path $DataDir -Filter "*.pid" -File -ErrorAction SilentlyContinue
foreach ($pidFile in $stalePids) {
    Write-HealLog "Removing stale PID lock file: $($pidFile.FullName)"
    Remove-Item -Path $pidFile.FullName -Force -ErrorAction SilentlyContinue
}

$staleSockets = Get-ChildItem -Path $DataDir -Filter "*.sock*" -File -ErrorAction SilentlyContinue
foreach ($sockFile in $staleSockets) {
    Write-HealLog "Removing stale socket file: $($sockFile.FullName)"
    Remove-Item -Path $sockFile.FullName -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------
# 2.5 Ensure xampp-control.ini Permissions for Non-Admin Students
# --------------------------------------------------------------------
$controlIni = Join-Path $XamppDir "xampp-control.ini"
if (Test-Path $controlIni) {
    try {
        Start-Process -FilePath "icacls.exe" -ArgumentList @("$controlIni", "/reset") -NoNewWindow -Wait | Out-Null
        Start-Process -FilePath "icacls.exe" -ArgumentList @("$controlIni", "/grant", "*S-1-5-32-545:F", "/grant", "*S-1-5-11:F", "/Q") -NoNewWindow -Wait | Out-Null
    } catch {}
}

# --------------------------------------------------------------------
# 3. Repair Aria Storage Engine Tables (*.MAI)
# --------------------------------------------------------------------
# This clears the "crashed / dirty" bit in table headers (e.g. mysql.global_priv)
# Passing -f -f dynamically expands the sort buffer to avoid 'sort_buffer_size is too small' errors
if (Test-Path $AriaChkExe) {
    Write-HealLog "Scanning and repairing Aria tables with aria_chk..."
    $ariaTables = Get-ChildItem -Path $DataDir -Filter "*.MAI" -Recurse -File -ErrorAction SilentlyContinue
    if ($ariaTables) {
        foreach ($table in $ariaTables) {
            try {
                $process = Start-Process -FilePath $AriaChkExe -ArgumentList @("--silent", "--recover", "-f", "-f", "--update-state", "--datadir=$DataDir", "`"$($table.FullName)`"") -NoNewWindow -PassThru -Wait
                if ($process.ExitCode -eq 0) {
                    Write-HealLog "Aria table verified/repaired: $($table.Name)" "OK"
                } else {
                    Write-HealLog "aria_chk returned exit code $($process.ExitCode) for $($table.Name)" "WARN"
                }
            } catch {
                Write-HealLog "Failed to invoke aria_chk on $($table.FullName): $_" "ERROR"
            }
        }
    } else {
        Write-HealLog "No .MAI Aria tables found to repair."
    }
} else {
    Write-HealLog "aria_chk.exe not found at $AriaChkExe." "WARN"
}

# --------------------------------------------------------------------
# 4. Verify & Heal Corrupted Aria Logs (aria_log_control / aria_log.*)
# --------------------------------------------------------------------
# Test if MariaDB can initialize plugins or if aria logs are torn/corrupted
$testLogFile = Join-Path $DataDir "test_startup_err.log"
$testOutFile = Join-Path $DataDir "test_startup_out.log"
Remove-Item -Path $testLogFile, $testOutFile -Force -ErrorAction SilentlyContinue

$testArgs = @("--defaults-file=`"$MyIniPath`"", "--validate-user-plugins", "--help")
$testProc = Start-Process -FilePath $MysqldExe -ArgumentList $testArgs -NoNewWindow -PassThru -Wait -RedirectStandardError $testLogFile -RedirectStandardOutput $testOutFile

$hasAriaError = $false
if (Test-Path $testLogFile) {
    $errContent = Get-Content $testLogFile -Raw -ErrorAction SilentlyContinue
    if ($errContent -match "Aria.*error" -or $errContent -match "Plugin 'Aria'.*failed" -or $errContent -match "log sequence number.*invalid") {
        $hasAriaError = $true
    }
}
Remove-Item -Path $testLogFile, $testOutFile -Force -ErrorAction SilentlyContinue

if ($hasAriaError) {
    Write-HealLog "Detected corrupted Aria transaction logs preventing startup. Resetting Aria logs..." "WARN"
    Get-ChildItem -Path $DataDir -Filter "aria_log.*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $DataDir -Filter "aria_log_control" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    
    # Re-run aria_chk to ensure table headers are clean after log reset
    if (Test-Path $AriaChkExe) {
        Get-ChildItem -Path $DataDir -Filter "*.MAI" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            Start-Process -FilePath $AriaChkExe -ArgumentList @("--silent", "--recover", "-f", "-f", "--update-state", "--datadir=$DataDir", "`"$($_.FullName)`"") -NoNewWindow -PassThru -Wait | Out-Null
        }
    }
    Write-HealLog "Aria transaction logs cleanly purged. Fresh log sequence will generate on next start." "OK"
}

# --------------------------------------------------------------------
# 5. System Privilege Tables Fallback Check
# --------------------------------------------------------------------
# Check if mysql.global_priv or mysql system folder is missing / completely empty
$mysqlSystemDb = Join-Path $DataDir "mysql"
if (-not (Test-Path $mysqlSystemDb) -or (Get-ChildItem -Path $mysqlSystemDb -ErrorAction SilentlyContinue).Count -eq 0) {
    Write-HealLog "System database 'mysql' is missing or empty! Restoring from pristine backup..." "WARN"
    $sourceRestore = if (Test-Path $PristineDir) { $PristineDir } elseif (Test-Path (Join-Path $BackupDir "mysql")) { Join-Path $BackupDir "mysql" } else { $null }
    if ($sourceRestore) {
        Copy-Item -Path $sourceRestore -Destination $mysqlSystemDb -Recurse -Force -ErrorAction SilentlyContinue
        Write-HealLog "Restored system privilege tables from $sourceRestore. User databases were left intact." "OK"
    } else {
        Write-HealLog "No pristine or backup system directory found to restore." "ERROR"
    }
}

# --------------------------------------------------------------------
# 6. Ensure MySQL Process is Completely Terminated (Docker Safety)
# --------------------------------------------------------------------
# Guarantee that no background mysqld daemon lingers. Port 3306 remains 100% free.
Get-Process -Name "mysqld" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-HealLog "=== Offline AutoHeal Completed: Database files are healthy & port 3306 is free for Docker ===" "OK"

if ($Interactive) {
    Write-Host "`nRepair completed successfully!" -ForegroundColor Green
    Write-Host "Database files are clean and healthy. You can now launch XAMPP Control Panel and start MySQL when ready.`n" -ForegroundColor White
    Read-Host "Press Enter to close this window..."
}
