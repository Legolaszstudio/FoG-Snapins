# ====================================================================
# deployPL2303.ps1 - Prolific PL2303 Serial Driver Deployment
# ====================================================================
# Purpose:
# 1. Deploys the Prolific USB-to-Serial working driver (v3.3.2.102) from PL2303 folder.
# 2. Stages the files securely into Program Files (tamper-proof from students).
# 3. Pre-installs driver into Driver Store (pnputil /add-driver ... /install).
# 4. Purges any newer incompatible Prolific drivers installed by Windows Update.
# 5. Schedules a persistent watchdog task to run at Startup and Logon.
# 6. Optionally chains deployCH340.ps1 when -IncludeCH340 is specified.
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

    # Optionally chain deployCH340.ps1 to also deploy CH340 drivers
    [switch]$IncludeCH340
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

# ====================================================================
# UNINSTALLATION ROUTINE
# ====================================================================
if ($Uninstall) {
    Write-Host "--- Uninstalling SerialDriverFixer (PL2303) ---" -ForegroundColor Yellow

    # Remove any scheduled tasks matching SerialDriverFixer*
    $existingTasks = Get-ScheduledTask -TaskName "$TaskName*" -ErrorAction SilentlyContinue
    foreach ($task in $existingTasks) {
        Write-Host "Unregistering scheduled task '$($task.TaskName)'..." -ForegroundColor Cyan
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false
    }

    # Remove target directory
    if (Test-Path $InstallDir) {
        Write-Host "Removing installation directory: $InstallDir..." -ForegroundColor Cyan
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    # Clean legacy C:\Deployments artifacts if present
    $legacyScript = "C:\Deployments\Scripts\SerialDriverFixer*"
    if (Test-Path "C:\Deployments\Scripts") {
        Get-ChildItem -Path $legacyScript -ErrorAction SilentlyContinue | Remove-Item -Force
        # Remove folder if empty
        if ((Get-ChildItem -Path "C:\Deployments\Scripts").Count -eq 0) {
            Remove-Item -Path "C:\Deployments\Scripts" -Force -ErrorAction SilentlyContinue
        }
        if ((Get-ChildItem -Path "C:\Deployments").Count -eq 0) {
            Remove-Item -Path "C:\Deployments" -Force -ErrorAction SilentlyContinue
        }
    }

    if ($IncludeCH340) {
        $ch340Deployer = Join-Path -Path $sourceDir -ChildPath "deployCH340.ps1"
        if (Test-Path $ch340Deployer) {
            Write-Host "Triggering CH340 uninstallation..." -ForegroundColor Cyan
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ch340Deployer -Uninstall
        }
    }

    Write-Host "SerialDriverFixer uninstallation completed successfully." -ForegroundColor Green
    exit 0
}

# ====================================================================
# INSTALLATION & DEPLOYMENT ROUTINE
# ====================================================================
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Deploying Prolific PL2303 Serial Driver (v3.3.2.102)" -ForegroundColor Cyan
Write-Host " Target Directory: $InstallDir" -ForegroundColor Cyan
Write-Host " Scheduled Task:   $TaskName (Startup + Logon)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# --------------------------------------------------------------------
# 2. Verify Source Package Files
# --------------------------------------------------------------------
$pl2303SourceDir = Join-Path -Path $sourceDir -ChildPath "PL2303"
if (-not (Test-Path $pl2303SourceDir)) {
    $pl2303SourceDir = $sourceDir
}
$sourceInf      = Join-Path -Path $pl2303SourceDir -ChildPath "Ser2pl.inf"
$sourceSys      = Join-Path -Path $pl2303SourceDir -ChildPath "Ser2pl64.sys"
$sourceWatchdog = Join-Path -Path $sourceDir -ChildPath "SerialDriverFixer.ps1"

if (-not (Test-Path $sourceInf) -or -not (Test-Path $sourceSys)) {
    Write-Error "CRITICAL: Required PL2303 driver files (Ser2pl.inf, Ser2pl64.sys) not found in '$pl2303SourceDir'!"
    exit 1
}

if (-not (Test-Path $sourceWatchdog)) {
    Write-Error "CRITICAL: Watchdog script 'SerialDriverFixer.ps1' not found in '$sourceDir'! Ensure all files are present."
    exit 1
}

# --------------------------------------------------------------------
# 3. Stage Files to Permanent Location in Program Files
# --------------------------------------------------------------------
$pl2303DestDir  = Join-Path -Path $InstallDir -ChildPath "PL2303"
$driverDestDir  = Join-Path -Path $InstallDir -ChildPath "Driver"
$watchdogScript = Join-Path -Path $InstallDir -ChildPath "SerialDriverFixer.ps1"

Write-Host "Creating protected directories in $InstallDir..." -ForegroundColor Cyan
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $pl2303DestDir)) {
    New-Item -Path $pl2303DestDir -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $driverDestDir)) {
    New-Item -Path $driverDestDir -ItemType Directory -Force | Out-Null
}

Write-Host "Copying PL2303 driver files to $pl2303DestDir..." -ForegroundColor Cyan
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
# 5. Pre-install Target Driver into Driver Store
# --------------------------------------------------------------------
Write-Host "Staging PL2303 driver package into Windows Driver Store..." -ForegroundColor Cyan
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

# --------------------------------------------------------------------
# 6. Execute Immediate Cleanup (Fix Current Session)
# --------------------------------------------------------------------
if (-not $SkipImmediateRun) {
    Write-Host "Running initial cleanup pass to resolve any currently broken PL2303 drivers..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watchdogScript

    Write-Host "Triggering PnP device rescan..." -ForegroundColor Cyan
    $scanOut = & pnputil.exe /scan-devices 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Device rescan exited with code $($LASTEXITCODE): $scanOut"
    } else {
        Write-Host "Hardware rescan completed successfully." -ForegroundColor Green
    }
}

# Report currently connected serial devices
$connectedPorts = Get-PnpDevice -Class Ports -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'Prolific|CH340|Serial' -or $_.InstanceId -match 'VID_067B|VID_1A86'
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
    Write-Host " SUCCESS: PL2303 Driver & Watchdog deployed!" -ForegroundColor Green
    Write-Host " Staged Location: $pl2303DestDir" -ForegroundColor Green
    Write-Host " Watchdog Script: $watchdogScript" -ForegroundColor Green
    Write-Host " Task Name:       $TaskName" -ForegroundColor Green
    Write-Host " Triggers:        Startup (Boot) + User Logon (Event 21/25)" -ForegroundColor Green
    Write-Host " Security:        NT AUTHORITY\SYSTEM (Highest Privileges)" -ForegroundColor Green
    Write-Host " Log File:        $(Join-Path $InstallDir 'pl2303.log')" -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Green
}

# Optional chain of CH340 deployment
if ($IncludeCH340) {
    $ch340Deployer = Join-Path -Path $sourceDir -ChildPath "deployCH340.ps1"
    if (Test-Path $ch340Deployer) {
        Write-Host "`n--- Running CH340 Deployment ---" -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ch340Deployer
    } else {
        Write-Warning "deployCH340.ps1 not found in '$sourceDir'."
    }
}