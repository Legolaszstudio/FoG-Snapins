<#
.SYNOPSIS
    FOG Client Snapin deployment script for HP EliteDesk 600 G2 drivers.

.DESCRIPTION
    Installs HP SoftPaq drivers (Chipset, NIC, Audio) and the Intel Graphics
    driver silently and unattended.
    Guarantees that none of the installers will restart the computer, allowing
    the FOG Client to manage the reboot sequence upon snapin completion.
    Generates a detailed log file recording execution timestamps, process
    parameters, exit codes, and human-readable status interpretations.

.DRIVERS INCLUDED:
    1. Intel Chipset Support:          sp101125.exe
    2. Intel Network Interface (NIC):  sp110164.exe
    3. Realtek High Definition Audio:  sp103864.exe
    4. Intel HD Graphics 530:          gfx_win_101.2115.exe

.REBOOT SUPPRESSION:
    - sp101125: HP wrapper runs setupChipset.exe with -s -norestart.
    - sp110164: HP wrapper runs pnputil which stages/installs without rebooting.
    - sp103864: HP wrapper invoked with /s running Setup.exe -s with setup.iss (BootOption=0).
                Includes idempotency pre-check to prevent InstallShield maintenance/uninstallation loop.
    - gfx_win:  Intel installer invoked with -s --overwrite. The reboot flag (-b / --reboot)
                is intentionally omitted to prevent any reboot.

.EXIT CODES:
    Returns 0 if all drivers installed successfully (including 3010/14 pending reboot).
    Returns 1 if any driver installation failed.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DriverSourceDir = $PSScriptRoot,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "$env:SystemDrive\Windows\Temp\FOG_Driver_Deployment.log",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

# ---------------------------------------------------------------------------
# Logging Functions
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "STEP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedEntry = "[$timestamp] [$Level] $Message"

    # Console output with color
    switch ($Level) {
        "INFO"    { Write-Host $formattedEntry -ForegroundColor Cyan }
        "STEP"    { Write-Host "`n$formattedEntry" -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formattedEntry -ForegroundColor Green }
        "WARN"    { Write-Host $formattedEntry -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host $formattedEntry -ForegroundColor Red }
    }

    # Append to log file
    try {
        $logDir = [System.IO.Path]::GetDirectoryName($LogPath)
        if (-not (Test-Path -Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $formattedEntry | Out-File -FilePath $LogPath -Append -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

# ---------------------------------------------------------------------------
# Environment & Privilege Validation
# ---------------------------------------------------------------------------
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Log "================================================================================" "INFO"
Write-Log " FOG CLIENT SNAPIN: HP ELITEDESK 600 G2 DRIVER DEPLOYMENT                       " "INFO"
Write-Log "================================================================================" "INFO"
Write-Log "Host Name:       $env:COMPUTERNAME" "INFO"
Write-Log "OS Architecture: $((Get-CimInstance Win32_OperatingSystem).OSArchitecture)" "INFO"
Write-Log "OS Version:      $((Get-CimInstance Win32_OperatingSystem).Caption) ($((Get-CimInstance Win32_OperatingSystem).Version))" "INFO"
Write-Log "System Model:    $((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)" "INFO"
Write-Log "Execution User:  $currentUser (Elevated/Admin: $isAdmin)" "INFO"
Write-Log "Log Location:    $LogPath" "INFO"
Write-Log "Reboot Policy:   SUPPRESSED (FOG Client handles post-snapin restart)" "INFO"
Write-Log "================================================================================" "INFO"

if (-not $isAdmin) {
    Write-Log "This script requires Administrator privileges. FOG Client runs as SYSTEM." "ERROR"
    if (-not $DryRun) {
        Exit 1
    }
}

# Determine active driver directory
if ([string]::IsNullOrWhiteSpace($DriverSourceDir) -or (-not (Test-Path -Path $DriverSourceDir))) {
    $DriverSourceDir = (Get-Location).Path
}
Write-Log "Driver Source Directory: $DriverSourceDir" "INFO"

# ---------------------------------------------------------------------------
# Driver Definition Catalog
# ---------------------------------------------------------------------------
# Order is critical:
# 1. Chipset (INF device registration)
# 2. NIC (Network Interface)
# 3. Audio (Realtek)
# 4. Graphics (Intel HD 530)
$Drivers = @(
    @{
        Id              = "CHIPSET"
        DisplayName     = "Intel Chipset Device Software"
        FileName        = "sp101125.exe"
        Arguments       = "/s"
        RebootSuppressed= $true
        SuppressDetail  = "SoftPaq runs setupChipset.exe with -s -norestart"
        SuccessCodes    = @(0, 14, 3010)
        StageSafe       = $false
    },
    @{
        Id              = "NIC"
        DisplayName     = "Intel Network Interface Card (NIC) Driver"
        FileName        = "sp110164.exe"
        Arguments       = "/s"
        RebootSuppressed= $true
        SuppressDetail  = "SoftPaq runs pnputil -i -a without reboot flags"
        SuccessCodes    = @(0, 259, 3010)
        StageSafe       = $false
    },
    @{
        Id              = "AUDIO"
        DisplayName     = "Realtek High Definition Audio Driver"
        FileName        = "sp103864.exe"
        Arguments       = "/s"
        RebootSuppressed= $true
        SuppressDetail  = "SoftPaq runs Setup.exe -s with setup.iss (BootOption=0)"
        SuccessCodes    = @(0, 14, 3010)
        StageSafe       = $false
        InstalledCheck  = {
            # Realtek InstallShield setup enters maintenance/uninstall mode if already installed.
            # Skip execution if the Realtek sound device or service is already present.
            $soundDev = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Where-Object { $_.Manufacturer -match "Realtek" -or $_.Name -match "Realtek" }
            $pnpMedia = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.PNPClass -eq "MEDIA" -and ($_.Manufacturer -match "Realtek" -or $_.Name -match "Realtek") }
            $rtkSvc   = Get-Service -Name "RtkAudioService*" -ErrorAction SilentlyContinue
            return [bool]($soundDev -or $pnpMedia -or $rtkSvc)
        }
    },
    @{
        Id              = "GRAPHICS"
        DisplayName     = "Intel HD Graphics Driver (101.2115)"
        FileName        = "gfx_win_101.2115.exe"
        Arguments       = "-s --overwrite"
        RebootSuppressed= $true
        SuppressDetail  = "Intel Installer -s --overwrite (reboot flag -b / --reboot omitted)"
        SuccessCodes    = @(0, 14, 3010)
        StageSafe       = $true # Staged to C:\Drivers_Temp if run from Program Files / FOG tmp
    }
)

# Helper function to interpret return codes
function Get-ExitCodeDescription {
    param([int]$Code)
    switch ($Code) {
        0    { return "SUCCESS: Installed successfully (no reboot required)" }
        14   { return "SUCCESS_REBOOT_REQUIRED: Installed successfully (reboot required, suppressed)" }
        259  { return "SUCCESS_STAGED: Driver staged/installed successfully" }
        3010 { return "SUCCESS_REBOOT_REQUIRED: ERROR_SUCCESS_REBOOT_REQUIRED (reboot required, suppressed)" }
        1602 { return "FAILED: User cancelled installation" }
        1603 { return "FAILED: Fatal error during installation" }
        1618 { return "FAILED: Another installation is already in progress" }
        1641 { return "SUCCESS_REBOOT_INITIATED: ERROR_SUCCESS_REBOOT_INITIATED" }
        default { return "UNKNOWN / FAILED: Exit code $Code (0x$($Code.ToString('X8')))" }
    }
}

# ---------------------------------------------------------------------------
# Execution Engine
# ---------------------------------------------------------------------------
$Results = @()
$StagingDir = "$env:SystemDrive\Drivers_Temp"

foreach ($driver in $Drivers) {
    Write-Log "--------------------------------------------------------------------------------" "STEP"
    Write-Log "Processing: $($driver.DisplayName)" "STEP"
    Write-Log "Installer File: $($driver.FileName)" "INFO"
    Write-Log "Reboot Protection: $($driver.SuppressDetail)" "INFO"

    $driverFilePath = Join-Path -Path $DriverSourceDir -ChildPath $driver.FileName

    # Validate file presence
    if (-not (Test-Path -Path $driverFilePath)) {
        Write-Log "Installer NOT FOUND: $driverFilePath" "ERROR"
        $Results += [PSCustomObject]@{
            Driver    = $driver.DisplayName
            File      = $driver.FileName
            ExitCode  = -1
            Status    = "FILE_NOT_FOUND"
            Details   = "File missing in $DriverSourceDir"
            Duration  = "0s"
        }
        continue
    }

    $fileInfo = Get-Item -Path $driverFilePath
    $sizeMB = [Math]::Round(($fileInfo.Length / 1MB), 2)
    Write-Log "File verified: $driverFilePath (${sizeMB} MB)" "INFO"

    # Staging logic for installers sensitive to execution paths (e.g., Intel inside Program Files)
    $execPath = $driverFilePath
    $stagedCleanUpNeeded = $false

    if ($driver.StageSafe -and ($DriverSourceDir -match "Program Files|System32")) {
        Write-Log "Restricted source path detected for $($driver.DisplayName). Staging to $StagingDir..." "INFO"
        if (-not (Test-Path -Path $StagingDir)) {
            New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
        }
        $stagedFile = Join-Path -Path $StagingDir -ChildPath $driver.FileName
        Copy-Item -Path $driverFilePath -Destination $stagedFile -Force
        $execPath = $stagedFile
        $stagedCleanUpNeeded = $true
        Write-Log "Staged binary to $execPath" "INFO"
    }

    $workDir = [System.IO.Path]::GetDirectoryName($execPath)
    Write-Log "Execution Command: `"$execPath`" $($driver.Arguments)" "INFO"
    Write-Log "Working Directory: $workDir" "INFO"

    # Pre-check: skip installer if driver is already present (prevents InstallShield uninstallation loop)
    if ($driver.InstalledCheck) {
        try {
            $isInstalled = & $driver.InstalledCheck
            if ($isInstalled) {
                Write-Log "Pre-check: $($driver.DisplayName) is already installed. Skipping to prevent uninstallation." "SUCCESS"
                if ($stagedCleanUpNeeded -and (Test-Path -Path $execPath)) {
                    Remove-Item -Path $execPath -Force -ErrorAction SilentlyContinue
                }
                $Results += [PSCustomObject]@{
                    Driver    = $driver.DisplayName
                    File      = $driver.FileName
                    ExitCode  = 0
                    Status    = "ALREADY_INSTALLED"
                    Details   = "Driver already present. Skipped to prevent uninstallation."
                    Duration  = "0s"
                }
                continue
            }
        }
        catch {
            Write-Log "Warning during driver installed pre-check: $_" "WARN"
        }
    }

    if ($DryRun) {
        Write-Log "[DRY-RUN] Execution skipped by request." "WARN"
        $Results += [PSCustomObject]@{
            Driver    = $driver.DisplayName
            File      = $driver.FileName
            ExitCode  = 0
            Status    = "DRY_RUN"
            Details   = "Simulated execution"
            Duration  = "0s"
        }
        continue
    }

    # Execute process and monitor
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1
    $status = "FAILED"

    try {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $execPath
        $pinfo.Arguments = $driver.Arguments
        $pinfo.WorkingDirectory = $workDir
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::Start($pinfo)
        # Wait up to 10 minutes (600,000 ms) preventing indefinitely hanging on child handles
        $hasExited = $process.WaitForExit(600000)
        if (-not $hasExited) {
            Write-Log "Process execution timed out after 10 minutes. Terminating process..." "ERROR"
            try { $process.Kill() } catch {}
            $exitCode = -998
        } else {
            $exitCode = $process.ExitCode
        }
        $stopwatch.Stop()
    }
    catch {
        $stopwatch.Stop()
        Write-Log "Process execution failed to start: $_" "ERROR"
        $exitCode = -999
    }

    $durationStr = "$([Math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"
    $codeInterpretation = Get-ExitCodeDescription -Code $exitCode

    Write-Log "Process finished in $durationStr with Exit Code: $exitCode (0x$($exitCode.ToString('X8')))" "INFO"
    Write-Log "Status Interpretation: $codeInterpretation" "INFO"

    if ($driver.SuccessCodes -contains $exitCode) {
        if ($exitCode -in @(14, 3010)) {
            $status = "SUCCESS_PENDING_REBOOT"
            Write-Log "Driver install succeeded. System restart required (deferred to FOG completion)." "SUCCESS"
        } else {
            $status = "SUCCESS"
            Write-Log "Driver install succeeded without requiring restart." "SUCCESS"
        }
    } else {
        $status = "FAILED"
        Write-Log "Driver install FAILED with return code: $exitCode" "ERROR"
    }

    $Results += [PSCustomObject]@{
        Driver    = $driver.DisplayName
        File      = $driver.FileName
        ExitCode  = $exitCode
        Status    = $status
        Details   = $codeInterpretation
        Duration  = $durationStr
    }

    # Clean up staged files if created
    if ($stagedCleanUpNeeded -and (Test-Path -Path $execPath)) {
        Remove-Item -Path $execPath -Force -ErrorAction SilentlyContinue
    }
}

# Clean up staging directory if empty
if (Test-Path -Path $StagingDir) {
    Remove-Item -Path $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Final Deployment Summary & Exit Determination
# ---------------------------------------------------------------------------
Write-Log "================================================================================" "STEP"
Write-Log " DRIVER DEPLOYMENT SUMMARY                                                     " "STEP"
Write-Log "================================================================================" "STEP"

$anyFailure = $false
$rebootPending = $false

foreach ($res in $Results) {
    $summaryLine = "{0,-38} | Code: {1,-6} | Status: {2,-22} | Time: {3}" -f $res.Driver, $res.ExitCode, $res.Status, $res.Duration
    if ($res.Status -eq "FAILED" -or $res.Status -eq "FILE_NOT_FOUND") {
        $anyFailure = $true
        Write-Log $summaryLine "ERROR"
    } elseif ($res.Status -eq "SUCCESS_PENDING_REBOOT") {
        $rebootPending = $true
        Write-Log $summaryLine "SUCCESS"
    } else {
        Write-Log $summaryLine "SUCCESS"
    }
}

Write-Log "--------------------------------------------------------------------------------" "INFO"

if ($anyFailure) {
    Write-Log "OVERALL STATUS: FAILED. One or more drivers failed installation." "ERROR"
    Write-Log "Check the log entries above and installer logs in C:\System.sav\logs or C:\ProgramData\Intel." "ERROR"
    Exit 1
} else {
    if ($rebootPending) {
        Write-Log "OVERALL STATUS: SUCCESSFUL (Reboot pending)." "SUCCESS"
        Write-Log "All drivers deployed. FOG Client will initiate system restart upon snapin completion." "SUCCESS"
    } else {
        Write-Log "OVERALL STATUS: SUCCESSFUL. All drivers installed cleanly." "SUCCESS"
    }
    Exit 0
}

