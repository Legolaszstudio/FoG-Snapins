# ====================================================================
# deploySerialDriverFixer.ps1 - Serial Driver Lab Mass Deployment (MAIN)
# ====================================================================
# Designed for mass deployment via FOG Client / SCCM / Intune / GPO.
# Purpose:
# 1. Deploys the Prolific PL2303 working driver (v3.3.2.102) from PL2303.
# 2. Deploys the WCH CH340 / CH341 serial driver (v3.9) from CH340.
# 3. Stages driver packages securely in Program Files (tamper-proof).
# 4. Pre-installs drivers into the Windows Driver Store (pnputil).
# 5. Purges any newer incompatible Prolific drivers from Windows Update.
# 6. Schedules a persistent watchdog task under SYSTEM triggered at:
#    - System Startup (BootTrigger)
#    - User Logon via Event 21 & 25 (Session logon / reconnect)
# ====================================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    # Target directory in Program Files (protected by Windows NTFS ACLs)
    [string]$InstallDir = (Join-Path -Path $env:ProgramFiles -ChildPath "SerialDriverFixer"),

    # Name of the scheduled watchdog task
    [string]$TaskName = "SerialDriverFixer",

    # Optionally set the Hidden attribute on the installation folder
    [switch]$HideFolder,

    # Cleanly remove the scheduled task, staged driver files, and legacy artifacts
    [switch]$Uninstall,

    # Skip immediate execution of the watchdog during deployment
    [switch]$SkipImmediateRun,

    # Optionally skip CH340 driver deployment
    [switch]$SkipCH340,

    # Optionally skip PL2303 driver deployment
    [switch]$SkipPL2303
)

# --------------------------------------------------------------------
# 1. Elevation Check
# --------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Deployment requires elevated administrative privileges. Please run as Administrator or deploy via SYSTEM (FOG/Intune/SCCM/GPO)."
    exit 1
}

$sourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $sourceDir) { $sourceDir = (Get-Location).Path }

# ====================================================================
# UNINSTALLATION ROUTINE
# ====================================================================
if ($Uninstall) {
    Write-Host "--- Uninstalling SerialDriverFixer ---" -ForegroundColor Yellow

    # Remove scheduled tasks matching SerialDriverFixer*
    $existingTasks = Get-ScheduledTask -TaskName "$TaskName*" -ErrorAction SilentlyContinue
    foreach ($task in $existingTasks) {
        Write-Host "Unregistering scheduled task '$($task.TaskName)'..." -ForegroundColor Cyan
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
    }

    # Remove target directory (PL2303, CH340, Driver, watchdog)
    if (Test-Path $InstallDir) {
        Write-Host "Removing installation directory: $InstallDir..." -ForegroundColor Cyan
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    # Clean legacy C:\Deployments artifacts if present
    $legacyScript = "C:\Deployments\Scripts\SerialDriverFixer*"
    if (Test-Path "C:\Deployments\Scripts") {
        Get-ChildItem -Path $legacyScript -ErrorAction SilentlyContinue | Remove-Item -Force
        if ((Get-ChildItem -Path "C:\Deployments\Scripts").Count -eq 0) {
            Remove-Item -Path "C:\Deployments\Scripts" -Force -ErrorAction SilentlyContinue
        }
        if ((Get-ChildItem -Path "C:\Deployments").Count -eq 0) {
            Remove-Item -Path "C:\Deployments" -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "SerialDriverFixer uninstallation completed successfully." -ForegroundColor Green
    exit 0
}

# ====================================================================
# INSTALLATION & DEPLOYMENT ROUTINE
# ====================================================================
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Deploying Serial Driver Fixer (MAIN Deployment)" -ForegroundColor Cyan
if (-not $SkipPL2303) {
    Write-Host " - Prolific PL2303 Driver (v3.3.2.102) + Watchdog" -ForegroundColor Cyan
}
if (-not $SkipCH340) {
    Write-Host " - WCH CH340 Driver (v3.9)" -ForegroundColor Cyan
}
Write-Host " Target Directory: $InstallDir" -ForegroundColor Cyan
Write-Host " Scheduled Task:   $TaskName (Boot + Logon Event 21/25)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# --------------------------------------------------------------------
# 2. Verify Source Package Files
# --------------------------------------------------------------------
# PL2303 Source Driver Path
$pl2303SourceDir = Join-Path -Path $sourceDir -ChildPath "PL2303"
if (-not (Test-Path $pl2303SourceDir)) {
    $pl2303SourceDir = $sourceDir
}
$sourceInf      = Join-Path -Path $pl2303SourceDir -ChildPath "Ser2pl.inf"
$sourceSys      = Join-Path -Path $pl2303SourceDir -ChildPath "Ser2pl64.sys"
$sourceWatchdog = Join-Path -Path $sourceDir -ChildPath "SerialDriverFixer.ps1"

if (-not $SkipPL2303) {
    if (-not (Test-Path $sourceInf) -or -not (Test-Path $sourceSys)) {
        Write-Error "CRITICAL: Required PL2303 driver files (Ser2pl.inf, Ser2pl64.sys) not found in '$pl2303SourceDir'!"
        exit 1
    }

    if (-not (Test-Path $sourceWatchdog)) {
        Write-Error "CRITICAL: Watchdog script 'SerialDriverFixer.ps1' not found in '$sourceDir'! Ensure all files are present."
        exit 1
    }
}

# CH340 Source Driver Path
$ch340SourceDir = Join-Path -Path $sourceDir -ChildPath "CH340"
if (-not (Test-Path $ch340SourceDir)) {
    $ch340SourceDir = $sourceDir
}
$ch340SourceInf = Join-Path -Path $ch340SourceDir -ChildPath "CH341SER.INF"
$hasCH340       = (Test-Path $ch340SourceInf)

if (-not $SkipCH340 -and -not $hasCH340) {
    Write-Warning "CH340 driver file 'CH341SER.INF' not found in '$ch340SourceDir'. CH340 deployment will be skipped."
}

# --------------------------------------------------------------------
# 3. Stage Files to Permanent Location in Program Files
# --------------------------------------------------------------------
$pl2303DestDir  = Join-Path -Path $InstallDir -ChildPath "PL2303"
$driverDestDir  = Join-Path -Path $InstallDir -ChildPath "Driver"
$ch340DestDir   = Join-Path -Path $InstallDir -ChildPath "CH340"
$watchdogScript = Join-Path -Path $InstallDir -ChildPath "SerialDriverFixer.ps1"

Write-Host "Creating protected directories in $InstallDir..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

if (-not $SkipPL2303) {
    if (-not (Test-Path $pl2303DestDir)) {
        New-Item -Path $pl2303DestDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $driverDestDir)) {
        New-Item -Path $driverDestDir -ItemType Directory -Force | Out-Null
    }

    Write-Host "Staging PL2303 driver files to $pl2303DestDir..." -ForegroundColor Cyan
    Get-ChildItem -Path $pl2303SourceDir -Filter "Ser2pl*.*" | Copy-Item -Destination $pl2303DestDir -Force
    if (Test-Path (Join-Path $pl2303SourceDir "difxapi.dll")) {
        Copy-Item -Path (Join-Path $pl2303SourceDir "difxapi.dll") -Destination $pl2303DestDir -Force
    }

    # Backward compatibility with existing scripts expecting 'Driver' folder
    Get-ChildItem -Path $pl2303SourceDir -Filter "Ser2pl*.*" | Copy-Item -Destination $driverDestDir -Force
    if (Test-Path (Join-Path $pl2303SourceDir "difxapi.dll")) {
        Copy-Item -Path (Join-Path $pl2303SourceDir "difxapi.dll") -Destination $driverDestDir -Force
    }

    Write-Host "Staging watchdog script to '$watchdogScript'..." -ForegroundColor Cyan
    Copy-Item -Path $sourceWatchdog -Destination $watchdogScript -Force
}

if (-not $SkipCH340 -and $hasCH340) {
    Write-Host "Staging CH340 driver files to $ch340DestDir..." -ForegroundColor Cyan
    if (-not (Test-Path $ch340DestDir)) {
        New-Item -Path $ch340DestDir -ItemType Directory -Force | Out-Null
    }
    Get-ChildItem -Path $ch340SourceDir | Copy-Item -Destination $ch340DestDir -Recurse -Force
}

# --------------------------------------------------------------------
# 4. Security & Permissions Configuration
# --------------------------------------------------------------------
if ($HideFolder) {
    Write-Host "Hiding installation folder ($InstallDir)..." -ForegroundColor Cyan
    (Get-Item $InstallDir).Attributes = [System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::Hidden
}

# Clean legacy C:\Deployments artifacts if present
$legacyDir = "C:\Deployments\Scripts"
if (Test-Path $legacyDir) {
    Get-ChildItem -Path "$legacyDir\SerialDriverFixer*" -ErrorAction SilentlyContinue | Remove-Item -Force
}

# Clean up older versioned tasks (e.g. SerialDriverFixer_1.0.1)
$legacyTasks = Get-ScheduledTask -TaskName "SerialDriverFixer_*" -ErrorAction SilentlyContinue
foreach ($lt in $legacyTasks) {
    Write-Host "Unregistering legacy scheduled task: $($lt.TaskName)..." -ForegroundColor Cyan
    Unregister-ScheduledTask -TaskName $lt.TaskName -Confirm:$false
}

# --------------------------------------------------------------------
# 5. Pre-install Target Drivers into Driver Store
# --------------------------------------------------------------------
if (-not $SkipPL2303) {
    Write-Host "Registering PL2303 driver package in Windows Driver Store..." -ForegroundColor Cyan
    $stagedInf = Join-Path -Path $pl2303DestDir -ChildPath "Ser2pl.inf"
    if (-not (Test-Path $stagedInf)) {
        $stagedInf = Join-Path -Path $driverDestDir -ChildPath "Ser2pl.inf"
    }
    $addDriverOut = & pnputil.exe /add-driver $stagedInf /install 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pnputil add-driver for PL2303 exited with code $($LASTEXITCODE): $addDriverOut"
    } else {
        Write-Host "Successfully registered PL2303 driver v3.3.2.102." -ForegroundColor Green
    }
}

if (-not $SkipCH340 -and $hasCH340) {
    Write-Host "Registering CH340 driver package in Windows Driver Store..." -ForegroundColor Cyan
    $stagedCh340Inf = Join-Path -Path $ch340DestDir -ChildPath "CH341SER.INF"
    $addChDriverOut = & pnputil.exe /add-driver $stagedCh340Inf /install 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pnputil add-driver for CH340 exited with code $($LASTEXITCODE): $addChDriverOut"
    } else {
        Write-Host "Successfully registered CH340 driver (v3.9)." -ForegroundColor Green
    }

    # Write separate ch340.log (overwrites on each run to retain only latest status)
    $ch340Log = Join-Path -Path $InstallDir -ChildPath "ch340.log"
    $ch340Status = if ($LASTEXITCODE -eq 0) { "SUCCESS: Driver package registered in Windows Driver Store." } else { "WARNING: pnputil returned code $LASTEXITCODE" }
    $ch340LogContent = @"
====================================================
CH340 Driver Deployment - Last Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
====================================================
Staged Directory: $ch340DestDir
INF File:         $stagedCh340Inf
Deployment Status: $ch340Status
pnputil Output:
$addChDriverOut
"@
    Set-Content -Path $ch340Log -Value $ch340LogContent -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------
# 6. Execute Immediate Cleanup & Device Rescan
# --------------------------------------------------------------------
if (-not $SkipImmediateRun) {
    if (-not $SkipPL2303 -and (Test-Path $watchdogScript)) {
        Write-Host "Running initial cleanup pass to resolve any currently broken PL2303 drivers..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogScript
    }

    Write-Host "Triggering PnP device rescan to bind connected hardware..." -ForegroundColor Cyan
    $scanOut = & pnputil.exe /scan-devices 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Device rescan exited with code $($LASTEXITCODE): $scanOut"
    } else {
        Write-Host "Hardware rescan completed successfully." -ForegroundColor Green
    }
}

# Report currently connected serial devices
$connectedPorts = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'CH340|Prolific|Serial' -or $_.InstanceId -match 'VID_1A86|VID_067B'
}
if ($connectedPorts) {
    Write-Host "`nConnected Serial Devices:" -ForegroundColor Cyan
    foreach ($p in $connectedPorts) {
        $statusColor = if ($p.Status -eq "OK") { "Green" } else { "Yellow" }
        Write-Host "  [$($p.Status)] $($p.FriendlyName) ($($p.InstanceId))" -ForegroundColor $statusColor
    }
}

# --------------------------------------------------------------------
# 7. Provision Scheduled Task (Startup + Logon via Event 21/25)
# --------------------------------------------------------------------
# Using Event 21 & 25 (Microsoft-Windows-TerminalServices-LocalSessionManager/Operational)
# guarantees reliable triggering for all user logons and session unlocks under SYSTEM,
# avoiding standard AtLogOn limitations on multi-user/domain lab computers.
if (-not $SkipPL2303) {
    Write-Host "`nRegistering scheduled task '$TaskName' (Startup + Logon Event 21/25)..." -ForegroundColor Cyan

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Serial Driver Fixer Watchdog Task - Enforces PL2303 v3.3.2.102 against Windows Update</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;&lt;Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"&gt;*[System[Provider[@Name='Microsoft-Windows-TerminalServices-LocalSessionManager'] and (EventID=21 or EventID=25)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$watchdogScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    # Remove existing task
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

    $registered = $false

    # Method 1: Register-ScheduledTask via XML
    try {
        Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null
        $registered = $true
    } catch {
        # Method 2: COM TaskScheduler Schedule.Service fallback
        try {
            $service = New-Object -ComObject "Schedule.Service"
            $service.Connect()
            $folder = $service.GetFolder("\")
            $taskDef = $service.NewTask(0)
            $taskDef.XmlText = $taskXml
            # 6 = TASK_CREATE_OR_UPDATE, 5 = TASK_LOGON_SERVICE_ACCOUNT
            $folder.RegisterTaskDefinition($TaskName, $taskDef, 6, $null, $null, 5) | Out-Null
            $registered = $true
        } catch {
            Write-Error "Failed to register scheduled task via XML and COM: $_"
            exit 1
        }
    }

    if ($registered) {
        Write-Host ""
        Write-Host "====================================================" -ForegroundColor Green
        Write-Host " SUCCESS: SerialDriverFixer deployed successfully!" -ForegroundColor Green
        Write-Host " Staged Drivers:  PL2303 (v3.3.2.102)" -ForegroundColor Green
        if (-not $SkipCH340 -and $hasCH340) {
            Write-Host "                  CH340 (v3.9)" -ForegroundColor Green
        }
        Write-Host " Script location: $watchdogScript" -ForegroundColor Green
        Write-Host " Task name:       $TaskName" -ForegroundColor Green
        Write-Host " Triggers:        Startup (Boot) + User Logon (Event 21/25)" -ForegroundColor Green
        Write-Host " Security:        NT AUTHORITY\SYSTEM (Highest Privileges)" -ForegroundColor Green
        Write-Host " Log files:       PL2303: $(Join-Path $InstallDir 'pl2303.log')" -ForegroundColor Green
        if (-not $SkipCH340 -and $hasCH340) {
            Write-Host "                  CH340:  $(Join-Path $InstallDir 'ch340.log')" -ForegroundColor Green
        }
        Write-Host "====================================================" -ForegroundColor Green
    }
}