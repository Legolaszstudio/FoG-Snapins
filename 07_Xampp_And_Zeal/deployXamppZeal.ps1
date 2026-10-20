<#
====================================================================
deployXamppZeal.ps1 - Automated FOG Snapin Deployment Script
====================================================================
Components:
1. XAMPP 8.2 (Apache, MariaDB/MySQL, PHP, phpMyAdmin) machine-wide at C:\xampp
2. Full standard-user / student multi-user ACL configuration (no Admin prompts)
3. Exhaustive sudden shutdown crash-hardening for MariaDB/MySQL:
   - Full ACID transaction log flushing (innodb_flush_log_at_trx_commit = 1)
   - Doublewrite torn page protection (innodb_doublewrite = 1)
   - Hardware checksums (innodb_checksum_algorithm = full_crc32)
   - Adaptive dirty page management (innodb_adaptive_flushing = 1, max_dirty_pages = 50%)
   - Aria engine auto-recovery (aria_recover_options = BACKUP,QUICK,FORCE)
   - Aria log sync & immediate purge (aria_sync_log_dir = ALWAYS, immediate)
   - MyISAM engine auto-recovery (myisam_recover_options = BACKUP,QUICK,FORCE)
   - Binary logging disabled (skip-log-bin, prevents corrupt binlog index halts)
   - Clean fast shutdown enforcement (innodb_fast_shutdown = 0)
4. Docker-Friendly No-Service Architecture:
   - Does NOT install or run MariaDB/Apache/phpMyAdmin as background Windows services.
   - Ports 80, 443, 3306 remain completely free for Docker and senior classes.
   - Students start XAMPP manually via XAMPP Control Panel only when needed.
5. Automated Boot-Time Offline Self-Healing Task (AutoHealMySQLOnBoot):
   - Runs silently at boot under SYSTEM, repairs any dirty Aria tables, clears stale
     locks, and exits with all ports free before students log in.
6. Zeal Offline Documentation Reader v0.9.1 machine-wide installation
7. MySQL offline documentation preloaded into C:\ProgramData\Zeal\docsets
8. Public desktop shortcuts for XAMPP, Zeal, and One-Click MySQL Repair
====================================================================
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\xampp",
    [string]$ZealDocsetDir = "C:\ProgramData\Zeal\docsets",
    [switch]$RegisterAutoHealTask = $true,
    [string]$LogPath = "C:\ProgramData\XAMPP_Zeal_Install.log"
)

$ErrorActionPreference = 'Stop'

function Write-DeployLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    } catch {}
    switch ($Level) {
        "WARN"  { Write-Warning $Message }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

# --------------------------------------------------------------------
# 1. Administrative Elevation Check
# --------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ([Environment]::UserInteractive -and $PSCommandPath) {
        try {
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            Start-Process -FilePath "PowerShell.exe" -ArgumentList $arguments -Verb RunAs
            exit 0
        } catch {}
    }
    Write-Error "Deployment requires elevated administrative privileges. Run as Administrator or deploy via SYSTEM (FOG Snapin)."
    exit 1
}

Write-DeployLog "=== Starting FOG Snapin Deployment: XAMPP, MariaDB Hardening & Zeal ==="

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$XamppInstaller = Join-Path $ScriptRoot "xampp-windows-x64-8.2.12-0-VS16-installer.exe"
$ZealInstaller  = Join-Path $ScriptRoot "zeal-0.9.1-windows-x64.msi"
$MysqlDocsetTgz = Join-Path $ScriptRoot "MySQL.tgz"

# --------------------------------------------------------------------
# 2. Terminate Conflicting Processes & Remove Background Services
# --------------------------------------------------------------------
Write-DeployLog "Checking for active server and documentation processes..."
try {
    Stop-Service -Name "mysql" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "Apache2.4" -Force -ErrorAction SilentlyContinue
} catch {}

$conflictingApps = @("xampp-control", "mysqld", "httpd", "zeal")
foreach ($app in $conflictingApps) {
    Get-Process -Name $app -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

# --------------------------------------------------------------------
# 3. XAMPP Silent Machine-Wide Installation
# --------------------------------------------------------------------
$mysqldPath = Join-Path $InstallDir "mysql\bin\mysqld.exe"
$httpdPath  = Join-Path $InstallDir "apache\bin\httpd.exe"

if (Test-Path $mysqldPath) {
    Write-DeployLog "XAMPP is already installed at $InstallDir. Preserving existing databases and updating hardening configuration..." "OK"
} else {
    if (-not (Test-Path $XamppInstaller)) {
        Write-DeployLog "Missing XAMPP installer executable at $XamppInstaller" "ERROR"
        throw "Missing XAMPP installer"
    }

    Write-DeployLog "Installing XAMPP silently to $InstallDir (this may take 2-4 minutes)..."
    
    # Bitnami unattended command line flags
    $xamppArgs = @(
        "--mode", "unattended"
    )
    if ($InstallDir -and $InstallDir -ne "C:\xampp") {
        $xamppArgs += @("--prefix", "$InstallDir")
    }
    
    $installProc = Start-Process -FilePath $XamppInstaller -ArgumentList $xamppArgs -NoNewWindow -PassThru -Wait
    if ($installProc.ExitCode -ne 0) {
        Write-DeployLog "XAMPP installer exited with non-zero code: $($installProc.ExitCode)" "WARN"
    }
    
    if (-not (Test-Path $mysqldPath)) {
        Write-DeployLog "Verification failed: mysqld.exe was not found at $mysqldPath after installation!" "ERROR"
        throw "XAMPP installation verification failed."
    }
    Write-DeployLog "XAMPP core installed successfully at $InstallDir." "OK"
}

# --------------------------------------------------------------------
# 4. Pre-stage xampp-control.ini (No Language Prompt, No Service Autostart)
# --------------------------------------------------------------------
$controlIniPath = Join-Path $InstallDir "xampp-control.ini"
Write-DeployLog "Configuring XAMPP Control Panel defaults in $controlIniPath..."
$controlIniContent = @"
[General]
Language=en
TomcatVisible=0
MercuryVisible=0
FileZillaVisible=0

[Autostart]
Apache=0
MySQL=0
FileZilla=0
Mercury=0
Tomcat=0

[Services]
Apache=0
MySQL=0
FileZilla=0
Mercury=0
Tomcat=0

[UserConfigs]
Editor=
Browser=
"@
$asciiEncoding = [System.Text.Encoding]::ASCII
[System.IO.File]::WriteAllText($controlIniPath, $controlIniContent, $asciiEncoding)

# --------------------------------------------------------------------
# 5. Multi-User ACL Configuration (C:\xampp for All Users / Students)
# --------------------------------------------------------------------
Write-DeployLog "Configuring multi-user permissions on $InstallDir for standard non-admin users..."
# *S-1-5-32-545 = BUILTIN\Users
# *S-1-5-11     = NT AUTHORITY\Authenticated Users
# (OI)(CI)F     = Object Inherit, Container Inherit, FullControl (Required for xampp-control.exe to update .ini files)
$icaclsUsersArgs = @("$InstallDir", "/grant", "*S-1-5-32-545:(OI)(CI)F", "/T", "/Q")
Start-Process -FilePath "icacls.exe" -ArgumentList $icaclsUsersArgs -NoNewWindow -Wait

$icaclsAuthArgs = @("$InstallDir", "/grant", "*S-1-5-11:(OI)(CI)F", "/T", "/Q")
Start-Process -FilePath "icacls.exe" -ArgumentList $icaclsAuthArgs -NoNewWindow -Wait

# Explicitly ensure xampp-control.ini has inheritance reset and FullControl granted
# (Bitnami and Delphi file writes can otherwise mark the ini with protected DACL)
Start-Process -FilePath "icacls.exe" -ArgumentList @("$controlIniPath", "/reset") -NoNewWindow -Wait
Start-Process -FilePath "icacls.exe" -ArgumentList @("$controlIniPath", "/grant", "*S-1-5-32-545:F", "/grant", "*S-1-5-11:F", "/Q") -NoNewWindow -Wait

Write-DeployLog "Multi-user FullControl permissions granted successfully on $InstallDir and $controlIniPath." "OK"

# --------------------------------------------------------------------
# 6. MariaDB / MySQL Sudden Shutdown Hardening (my.ini)
# --------------------------------------------------------------------
$myIni = Join-Path $InstallDir "mysql\bin\my.ini"
if (Test-Path $myIni) {
    Write-DeployLog "Applying comprehensive crash-resilient hardening to MySQL configuration ($myIni)..."
    
    # Backup pristine my.ini if not already done
    $myIniBak = Join-Path $InstallDir "mysql\bin\my.ini.bak"
    if (-not (Test-Path $myIniBak)) {
        Copy-Item -Path $myIni -Destination $myIniBak -Force
    }

    $iniContent = Get-Content -Path $myIni -Raw
    
    # Backup pristine copy of initial system privilege tables
    $systemDataDir = Join-Path $InstallDir "mysql\data\mysql"
    $pristineBackup = Join-Path $InstallDir "mysql\backup_system_pristine"
    if ((Test-Path $systemDataDir) -and (-not (Test-Path $pristineBackup))) {
        Copy-Item -Path $systemDataDir -Destination $pristineBackup -Recurse -Force -ErrorAction SilentlyContinue
        Write-DeployLog "Created golden backup of system tables at $pristineBackup." "OK"
    }

    # Remove older resilience blocks if reapplying
    $blockHeader = "# === FOG CRASH RESILIENCE & SUDDEN SHUTDOWN HARDENING ==="
    $blockFooter = "# === END FOG CRASH RESILIENCE HARDENING ==="
    if ($iniContent.Contains($blockHeader)) {
        $regex = [regex]::Escape($blockHeader) + "[\s\S]*?" + [regex]::Escape($blockFooter) + "\r?\n"
        $iniContent = [regex]::Replace($iniContent, $regex, "")
    }

    # Comprehensive hardening configuration block
    $hardeningSettings = @"
$blockHeader
# --- Disable Binary Logging (Eliminates corrupt binlog index crashes on sudden cut) ---
skip-log-bin

# --- Aria Storage Engine Crash Resilience (System Tables: mysql.global_priv, etc.) ---
# Auto-repair Aria system tables on startup if marked dirty/crashed
# FORCE ensures MariaDB recovers crashed/dirty Aria tables instead of aborting startup.
aria_recover_options = BACKUP,QUICK,FORCE
# Flush committed Aria transaction logs immediately to minimize stale log backlog
aria_log_purge_type = immediate
# Force Aria directory entry metadata to be synced to disk on Windows NTFS
aria_sync_log_dir = ALWAYS
# Generous buffer cache for Aria system tables
aria_pagecache_buffer_size = 64M

# --- MyISAM Storage Engine Auto-Recovery (Legacy/Auxiliary Tables) ---
myisam_recover_options = BACKUP,QUICK,FORCE

# --- InnoDB Engine Durability & Torn Page Protection ---
# ACID durability: flush redo log buffer to disk on every transaction commit
innodb_flush_log_at_trx_commit = 1
# Doublewrite buffer: CRITICAL to recover from torn/half-written pages caused by power cuts
innodb_doublewrite = 1
# Hardware CRC32 checksums to immediately detect page corruption
innodb_checksum_algorithm = full_crc32
# Isolate each table in its own .ibd file, protecting the shared ibdata1 tablespace
innodb_file_per_table = 1
# Buffer pool size tuned for lab workstations (256 MB)
innodb_buffer_pool_size = 256M
# Fast shutdown: 0 forces complete buffer pool purge on clean shutdown signals
innodb_fast_shutdown = 0
# Flushes dirty pages dynamically to keep dirty page count low before sudden cuts
innodb_adaptive_flushing = 1
innodb_max_dirty_pages_pct = 50
# Redo log file size buffer
innodb_log_buffer_size = 16M
# Standard Windows buffered I/O flush method
innodb_flush_method = normal
# Tablespace expansion increment
innodb_autoextend_increment = 64
$blockFooter
"@

    # Insert under [mysqld] section
    if ($iniContent -match "\[mysqld\]") {
        $iniContent = $iniContent -replace "\[mysqld\]", "[mysqld]`r`n$hardeningSettings"
    } else {
        $iniContent = "$iniContent`r`n[mysqld]`r`n$hardeningSettings"
    }

    # Write back without BOM
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($myIni, $iniContent, $utf8NoBom)
    Write-DeployLog "my.ini successfully hardened with full Aria and InnoDB crash resilience parameters." "OK"
} else {
    Write-DeployLog "my.ini not found at $myIni!" "WARN"
}

# --------------------------------------------------------------------
# 7. Stage AutoHeal Script & Maintenance Tools
# --------------------------------------------------------------------
Write-DeployLog "Staging AutoHeal-MySQL and Repair-MySQL tools in $InstallDir..."
$stagedAutoHeal = Join-Path $InstallDir "AutoHeal-MySQL.ps1"
$stagedRepairBat = Join-Path $InstallDir "Repair-MySQL.bat"

$sourceAutoHeal = Join-Path $ScriptRoot "AutoHeal-MySQL.ps1"
$sourceRepairBat = Join-Path $ScriptRoot "Repair-MySQL.bat"

if (Test-Path $sourceAutoHeal) {
    Copy-Item -Path $sourceAutoHeal -Destination $stagedAutoHeal -Force
}
if (Test-Path $sourceRepairBat) {
    Copy-Item -Path $sourceRepairBat -Destination $stagedRepairBat -Force
}

# --------------------------------------------------------------------
# 8. Register Boot Scheduled Task (AutoHealMySQLOnBoot - Offline Mode)
# --------------------------------------------------------------------
if ($RegisterAutoHealTask) {
    Write-DeployLog "Registering boot-time offline self-healing Scheduled Task (AutoHealMySQLOnBoot)..."
    try {
        $taskName = "AutoHealMySQLOnBoot"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stagedAutoHeal`""
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "Heals MariaDB Aria tables and clears stale lock files offline at boot without binding ports." | Out-Null
        Write-DeployLog "Scheduled task AutoHealMySQLOnBoot successfully registered (offline mode)." "OK"
    } catch {
        Write-DeployLog "Failed to register scheduled task: $_" "WARN"
    }
}

# Run offline AutoHeal once now to verify health
if (Test-Path $stagedAutoHeal) {
    & $stagedAutoHeal
}

# --------------------------------------------------------------------
# 9. Zeal Documentation Reader Machine-Wide Installation
# --------------------------------------------------------------------
Write-DeployLog "Installing Zeal Documentation Reader machine-wide..."
if (-not (Test-Path $ZealInstaller)) {
    Write-DeployLog "Zeal installer MSI not found at $ZealInstaller" "ERROR"
    throw "Missing Zeal MSI installer."
}

$zealLog = Join-Path $env:ProgramData "Zeal_Install.log"
$msiArgs = @(
    "/i",
    "`"$ZealInstaller`"",
    "ALLUSERS=1",
    "/qn",
    "/norestart",
    "/log",
    "`"$zealLog`""
)

$msiProc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -NoNewWindow -PassThru -Wait
if ($msiProc.ExitCode -in 0, 3010) {
    Write-DeployLog "Zeal installed successfully (Exit Code: $($msiProc.ExitCode))." "OK"
} else {
    Write-DeployLog "Zeal installation failed with exit code $($msiProc.ExitCode). Check $zealLog for details." "ERROR"
    throw "Zeal installation failed."
}

# --------------------------------------------------------------------
# 10. Extract & Preload MySQL Docset for All Users
# --------------------------------------------------------------------
Write-DeployLog "Configuring shared docsets directory at $ZealDocsetDir..."
if (-not (Test-Path $ZealDocsetDir)) {
    New-Item -ItemType Directory -Path $ZealDocsetDir -Force | Out-Null
}

# Grant multi-user access to docsets directory
Start-Process -FilePath "icacls.exe" -ArgumentList @("$ZealDocsetDir", "/grant", "*S-1-5-32-545:(OI)(CI)M", "/T", "/Q") -NoNewWindow -Wait

# Extract bundled MySQL docset if present
if (Test-Path $MysqlDocsetTgz) {
    Write-DeployLog "Extracting bundled MySQL offline docset into $ZealDocsetDir..."
    $tarProc = Start-Process -FilePath "tar.exe" -ArgumentList @("-xzf", "`"$MysqlDocsetTgz`"", "-C", "`"$ZealDocsetDir`"") -NoNewWindow -PassThru -Wait
    if ($tarProc.ExitCode -eq 0) {
        Write-DeployLog "MySQL docset successfully extracted." "OK"
    } else {
        Write-DeployLog "tar.exe returned exit code $($tarProc.ExitCode) during docset extraction." "WARN"
    }
} else {
    Write-DeployLog "MySQL.tgz archive not found in $ScriptRoot." "WARN"
}

# Configure Machine-Wide Registry for Zeal docset path
Write-DeployLog "Setting machine-wide Zeal registry docset path to $ZealDocsetDir..."
$zealHklm = "HKLM:\Software\Zeal\Zeal\docsets"
if (-not (Test-Path $zealHklm)) {
    New-Item -Path $zealHklm -Force | Out-Null
}
Set-ItemProperty -Path $zealHklm -Name "path" -Value ($ZealDocsetDir -replace '\\', '/') -Type String

# Configure Default User Profile registry so all newly created student profiles inherit Zeal settings
try {
    $defaultHivePath = "C:\Users\Default\NTUSER.DAT"
    if (Test-Path $defaultHivePath) {
        reg.exe load "HKU\TempDefault" "$defaultHivePath" | Out-Null
        $regPath = ($ZealDocsetDir -replace '\\', '/')
        reg.exe add "HKU\TempDefault\Software\Zeal\Zeal\docsets" /v "path" /t REG_SZ /d "$regPath" /f | Out-Null
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        reg.exe unload "HKU\TempDefault" | Out-Null
        Write-DeployLog "Configured Zeal docset path in Default User profile." "OK"
    }
} catch {
    Write-DeployLog "Notice: Could not modify Default User profile hive: $_" "WARN"
}

# Configure any currently loaded active user hives in HKU
Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-5-21-" -and $_.PSChildName -notmatch "_Classes$" } | ForEach-Object {
    try {
        $uKey = Join-Path "Registry::HKEY_USERS\$($_.PSChildName)" "Software\Zeal\Zeal\docsets"
        if (-not (Test-Path $uKey)) {
            New-Item -Path $uKey -Force | Out-Null
        }
        Set-ItemProperty -Path $uKey -Name "path" -Value ($ZealDocsetDir -replace '\\', '/') -Type String
    } catch {}
}

# Create failsafe junction in C:\Users\Default\AppData\Local\Zeal\Zeal\docsets
try {
    $defLocalZeal = "C:\Users\Default\AppData\Local\Zeal\Zeal"
    if (-not (Test-Path $defLocalZeal)) {
        New-Item -ItemType Directory -Path $defLocalZeal -Force | Out-Null
    }
    $defLocalDocsets = Join-Path $defLocalZeal "docsets"
    if (-not (Test-Path $defLocalDocsets)) {
        cmd.exe /c "mklink /J `"$defLocalDocsets`" `"$ZealDocsetDir`"" | Out-Null
    }
} catch {}

# --------------------------------------------------------------------
# 11. Adjust Windows Service Shutdown Timeout
# --------------------------------------------------------------------
# Extends OS timeout to 20 seconds, allowing running processes enough time to flush on shutdown
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "WaitToKillServiceTimeout" -Value "20000" -Type String -Force

# --------------------------------------------------------------------
# 12. Create Public Desktop Shortcuts
# --------------------------------------------------------------------
Write-DeployLog "Creating public desktop shortcuts for all users..."
try {
    $publicDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
    $wsh = New-Object -ComObject WScript.Shell

    # 1. XAMPP Control Panel
    $xamppControlExe = Join-Path $InstallDir "xampp-control.exe"
    if (Test-Path $xamppControlExe) {
        $scXampp = $wsh.CreateShortcut((Join-Path $publicDesktop "XAMPP Control Panel.lnk"))
        $scXampp.TargetPath = $xamppControlExe
        $scXampp.WorkingDirectory = $InstallDir
        $scXampp.Description = "XAMPP Server Control Panel (Start/Stop MySQL & Apache)"
        $scXampp.Save()
    }

    # 2. Zeal Documentation Reader
    $zealExe = "C:\Program Files\Zeal\zeal.exe"
    if (Test-Path $zealExe) {
        $scZeal = $wsh.CreateShortcut((Join-Path $publicDesktop "Zeal Documentation.lnk"))
        $scZeal.TargetPath = $zealExe
        $scZeal.WorkingDirectory = "C:\Program Files\Zeal"
        $scZeal.Description = "Offline Documentation Browser"
        $scZeal.Save()
    }

    # 3. Repair MySQL Shortcut
    if (Test-Path $stagedRepairBat) {
        $scRepair = $wsh.CreateShortcut((Join-Path $publicDesktop "Repair MySQL.lnk"))
        $scRepair.TargetPath = $stagedRepairBat
        $scRepair.WorkingDirectory = $InstallDir
        $scRepair.Description = "One-click self-healing repair tool for XAMPP MySQL"
        if (Test-Path $mysqldPath) {
            $scRepair.IconLocation = "$mysqldPath,0"
        }
        $scRepair.Save()
    }
    Write-DeployLog "Desktop shortcuts successfully created in $publicDesktop." "OK"
} catch {
    Write-DeployLog "Failed to create public desktop shortcuts: $_" "WARN"
}

Write-DeployLog "=== FOG Snapin Deployment Completed Successfully ===" "OK"
exit 0
