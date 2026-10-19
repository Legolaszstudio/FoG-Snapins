<#
.SYNOPSIS
    Automated mass deployment script for Android Studio, Android SDK (API 37.0), and dual shared emulators (Android 12 / API 31 & Android 17 / API 37.0).
    Configures shared machine-wide SDK/AVD directories, host GPU acceleration (hw.gpu.mode=host), QuickBoot, and default Welcome Screen configuration.
    This version forcefully eradicates existing installations prior to executing a clean deployment.

.DESCRIPTION
    Designed for mass deployment (SCCM / Intune / GPO / PDQ Deploy / FOG Client / Admin shell).
    1. Terminates conflicting processes (Android Studio, ADB, Emulator, Java).
    2. Auto-detects and silently uninstalls existing Android Studio instances (using synchronous NSIS handling).
    3. Auto-detects and completely purges all pre-existing SDK and AVD directories (including C:\Sdk, C:\Android, and user profiles).
    4. Silently installs Android Studio from the local installer in the script folder.
    5. Configures a shared system SDK path (C:\Sdk) and AVD path (C:\Sdk\avd).
    6. Reuses Android Studio's bundled JBR (Java) to execute SDK commands without extra JDK dependencies.
    7. Provisions command-line tools v23.0+ into C:\Sdk\cmdline-tools\latest.
    8. Non-interactively accepts all Android SDK licenses.
    9. Installs platform (android-37.0), build-tools (36.0.0, 37.0.0), platform-tools, emulator, and Google APIs system images (android-31, android-37.0).
    10. Creates dual shared AVDs in C:\Sdk\avd:
        - Pixel_4_API_31: Android 12 (API 31) with Google APIs (2048 MB RAM, 4 vCPUs) for fast, lightweight lab testing.
        - Pixel_7_API_37: Android 17 (API 37.0) with Google APIs (3072 MB RAM, 720x1600 resolution, borderless) for modern API teaching.
    11. Enforces forced host GPU acceleration (hw.gpu.mode=host), fastboot quickboot, and hardware keyboard pass-through.
    12. Configures Machine-level environment variables (ANDROID_HOME, ANDROID_SDK_ROOT, ANDROID_AVD_HOME, ANDROID_USER_HOME, PATH)
        and grants Authenticated Users FullControl on AVD/User directories and Modify on SDK root, enabling multi-user QuickBoot sharing.
    13. Deploys machine-wide Gradle memory caps (3 GB heap / ~3.5 GB total) and build accelerations to C:\Users\Default and all profiles.
    14. Injects Android Studio optional default to always open the Welcome / Project Selection page instead of auto-reopening the previous user's project.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Name of the local installer placed in the script directory
    [string]$InstallerName = "android-studio-rabbit1-windows.exe",

    # Shared root directory for the Android SDK
    [string]$SdkRoot = "C:\Sdk",

    # Shared root directory for Android Virtual Devices (AVDs)
    [string]$AvdRoot = "C:\Sdk\avd",

    # Name of the lightweight/fallback emulator
    [string]$AvdName = "Pixel_4_API_31",

    # Name of the modern API 37 emulator
    [string]$AvdNameModern = "Pixel_7_API_37",

    # Maximum download retry attempts per SDK package
    [int]$MaxRetries = 5,

    # Fallback URL for Command-Line Tools if not cached locally (v23.0+ required for Android 17 / API 37.0 decimal support)
    [string]$CmdLineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Message)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] ========================================" -ForegroundColor Cyan
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ========================================" -ForegroundColor Cyan
}

function Test-IsSafeToPurge {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    } catch {
        return $false
    }

    $systemDrive = $env:SystemDrive.TrimEnd('\')
    $protectedPaths = @(
        $systemDrive,
        "$systemDrive\Windows",
        "$systemDrive\Windows\System32",
        $env:ProgramFiles.TrimEnd('\'),
        ${env:ProgramFiles(x86)}.TrimEnd('\'),
        "$systemDrive\Users"
    )

    foreach ($prot in $protectedPaths) {
        if ($resolved -ieq $prot) { return $false }
    }

    # Protect entire user profile roots (e.g. C:\Users\Username)
    if ($resolved -match '^[a-zA-Z]:\\Users\\[^\\]+$') { return $false }

    return $true
}

# -------------------------------------------------------------------------
# Step 1: Validate Local Installer
# -------------------------------------------------------------------------
Write-Step "Validating Android Studio Installer"

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

$InstallerPath = Join-Path -Path $ScriptDir -ChildPath $InstallerName

if (-not (Test-Path -Path $InstallerPath)) {
    throw "Installer not found at '$InstallerPath'. Please ensure '$InstallerName' resides in the script directory."
}

Write-Host "Located installer: $InstallerPath" -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 2: Auto-Detect and Purge Pre-existing Installations, SDKs, and AVDs
# -------------------------------------------------------------------------
Write-Step "Eradicating Previous Installations, SDKs, and AVDs"

# 1. Terminate all conflicting processes to release file locks
Write-Host "Terminating associated processes to release file locks..." -ForegroundColor Gray
$ProcessesToKill = @("studio64", "studio", "emulator", "emulator64-x86", "emulator64-arm", "qemu-system-x86_64", "qemu-system-aarch64", "java", "adb")
foreach ($proc in $ProcessesToKill) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# 2. Detect and silently uninstall existing Android Studio installations
Write-Host "Detecting existing Android Studio installations..." -ForegroundColor Gray
$StudioInstallsToPurge = [System.Collections.Generic.List[string]]::new()

# Check registry uninstall entries
$RegUninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($regPath in $RegUninstallPaths) {
    if (Test-Path $regPath) {
        Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | ForEach-Object {
            $displayName = $_.GetValue("DisplayName")
            $installLocation = $_.GetValue("InstallLocation")
            $uninstallStr = $_.GetValue("UninstallString")
            if ($displayName -like "*Android Studio*" -or $_.PSChildName -like "*Android Studio*") {
                if ($installLocation -and (Test-Path $installLocation)) {
                    $StudioInstallsToPurge.Add($installLocation)
                }
                if ($uninstallStr) {
                    $cleanPath = ($uninstallStr -replace '"', '').Trim()
                    $parentDir = Split-Path -Path $cleanPath -Parent
                    if ($parentDir -and (Test-Path $parentDir)) {
                        $StudioInstallsToPurge.Add($parentDir)
                    }
                }
            }
        }
    }
}

# Check Android Studio registry key
$StudioRegKey = "HKLM:\SOFTWARE\Android Studio"
if (Test-Path $StudioRegKey) {
    $regInstallPath = (Get-ItemProperty -Path $StudioRegKey -Name "Path" -ErrorAction SilentlyContinue).Path
    if ($regInstallPath -and (Test-Path $regInstallPath)) {
        $StudioInstallsToPurge.Add($regInstallPath)
    }
}

# Standard known installation directories
$StandardStudioPaths = @(
    "$env:ProgramFiles\Android\Android Studio",
    "${env:ProgramFiles(x86)}\Android\Android Studio",
    "$env:LOCALAPPDATA\Programs\Android Studio"
)
foreach ($path in $StandardStudioPaths) {
    if (Test-Path $path) {
        $StudioInstallsToPurge.Add($path)
    }
}

# Deduplicate installation directories
$UniqueStudioDirs = $StudioInstallsToPurge | Select-Object -Unique

foreach ($studioDir in $UniqueStudioDirs) {
    if (-not (Test-IsSafeToPurge -Path $studioDir)) { continue }

    $uninstallerPath = Join-Path -Path $studioDir -ChildPath "uninstall.exe"
    if (Test-Path $uninstallerPath) {
        Write-Host "Executing synchronous silent uninstallation: $uninstallerPath" -ForegroundColor Gray
        # NSIS requires _?=<dir> as the final argument to run synchronously without copying to %TEMP%
        $uninstallArgs = @("/S", "_?=$studioDir")
        $uninstallProcess = Start-Process -FilePath $uninstallerPath -ArgumentList $uninstallArgs -Wait -PassThru
        Write-Host "Uninstaller terminated with exit code $($uninstallProcess.ExitCode)." -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }

    if (Test-Path $studioDir) {
        Write-Host "Obliterating remnant directory tree: $studioDir" -ForegroundColor Gray
        Remove-Item -Path $studioDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Clean up Android Studio Start Menu shortcuts
$ShortcutDirs = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
)
foreach ($scDir in $ShortcutDirs) {
    if (Test-Path $scDir) {
        Get-ChildItem -Path $scDir -Filter "*Android Studio*" -Recurse -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 3. Detect and completely eradicate existing SDK and AVD directories
Write-Host "Detecting existing SDK and AVD locations across the system..." -ForegroundColor Gray
$DirectoriesToPurge = [System.Collections.Generic.List[string]]::new()

# Target parameters
$DirectoriesToPurge.Add($SdkRoot)
$DirectoriesToPurge.Add($AvdRoot)

# Environment variables
$EnvVarsToCheck = @("ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_USER_HOME")
foreach ($varName in $EnvVarsToCheck) {
    foreach ($target in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User, [EnvironmentVariableTarget]::Process)) {
        $val = [Environment]::GetEnvironmentVariable($varName, $target)
        if (-not [string]::IsNullOrWhiteSpace($val) -and (Test-Path $val)) {
            $DirectoriesToPurge.Add($val)
        }
    }
}

# Standard known paths (including C:\Sdk, C:\Android, and subdirectories)
$KnownSdkAvdPaths = @(
    "C:\Sdk",
    "C:\Sdk\Android",
    "C:\Sdk\.android",
    "C:\Sdk\avd",
    "C:\Android",
    "C:\Android\Sdk",
    "C:\Android\avd",
    "$env:LOCALAPPDATA\Android\Sdk",
    "$env:USERPROFILE\.android\avd"
)
foreach ($known in $KnownSdkAvdPaths) {
    if (Test-Path $known) {
        $DirectoriesToPurge.Add($known)
    }
}

# Scan all local user profiles for SDK and AVD remnants
$UsersRoot = "$env:SystemDrive\Users"
if (Test-Path $UsersRoot) {
    Get-ChildItem -Path $UsersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $userDir = $_.FullName
        $candidatePaths = @(
            (Join-Path -Path $userDir -ChildPath "AppData\Local\Android\Sdk"),
            (Join-Path -Path $userDir -ChildPath ".android\avd"),
            (Join-Path -Path $userDir -ChildPath "AppData\Roaming\Google\AndroidStudio*"),
            (Join-Path -Path $userDir -ChildPath "AppData\Local\Google\AndroidStudio*")
        )
        foreach ($cp in $candidatePaths) {
            Get-Item -Path $cp -ErrorAction SilentlyContinue | ForEach-Object {
                $DirectoriesToPurge.Add($_.FullName)
            }
        }
    }
}

# Deduplicate and sort (longest path first so child folders are processed before parent roots)
$UniquePurgeDirs = $DirectoriesToPurge |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique |
    Sort-Object -Property Length -Descending

foreach ($dir in $UniquePurgeDirs) {
    if (Test-Path $dir) {
        if (Test-IsSafeToPurge -Path $dir) {
            Write-Host "Obliterating directory: $dir" -ForegroundColor Gray
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Skipped unsafe deletion target: $dir"
        }
    }
}

# -------------------------------------------------------------------------
# Step 3: Execute Clean Android Studio Installation
# -------------------------------------------------------------------------
Write-Step "Deploying Android Studio"

$StudioInstallDir = "$env:ProgramFiles\Android\Android Studio"

Write-Host "Initiating silent installation (/S)... Please wait." -ForegroundColor Gray
$installProcess = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait -PassThru

# NSIS installers frequently return 1223 (ERROR_CANCELLED) in silent mode due to suppressed post-install launch actions.
$ValidExitCodes = @(0, 1223)
if ($installProcess.ExitCode -notin $ValidExitCodes -or -not (Test-Path "$StudioInstallDir\bin\studio64.exe")) {
    throw "Android Studio deployment failed with exit code $($installProcess.ExitCode)."
}

Write-Host "Android Studio deployed successfully (Exit Code: $($installProcess.ExitCode))." -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 4: Locate Bundled Java (JBR/JRE)
# -------------------------------------------------------------------------
Write-Step "Identifying Bundled Java Runtime"

$BundledJava = "$StudioInstallDir\jbr"
if (-not (Test-Path "$BundledJava\bin\java.exe")) {
    $BundledJava = "$StudioInstallDir\jre"
}
if (-not (Test-Path "$BundledJava\bin\java.exe")) {
    throw "Failed to locate the bundled Java executable within '$StudioInstallDir\jbr' or '$StudioInstallDir\jre'."
}

Write-Host "Designated Java environment: $BundledJava" -ForegroundColor Green
$env:JAVA_HOME = $BundledJava
$env:Path = "$BundledJava\bin;" + $env:Path

# -------------------------------------------------------------------------
# Step 5: Provision Android Command-Line Tools
# -------------------------------------------------------------------------
Write-Step "Provisioning Android SDK Command-Line Tools"

# Ensure target directories exist
$TargetDirs = @($SdkRoot, $AvdRoot)
foreach ($dir in $TargetDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$CmdLineToolsParent = "$SdkRoot\cmdline-tools"
$CmdLineToolsLatest = "$CmdLineToolsParent\latest"
$SdkManager = "$CmdLineToolsLatest\bin\sdkmanager.bat"
$AvdManager = "$CmdLineToolsLatest\bin\avdmanager.bat"

# Check if a zip is already cached in the script folder
$LocalZip = Get-ChildItem -Path $ScriptDir -Filter "commandlinetools*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
$ZipToExtract = $null

if ($LocalZip) {
    Write-Host "Utilizing cached Command-Line Tools archive: $($LocalZip.FullName)" -ForegroundColor Gray
    $ZipToExtract = $LocalZip.FullName
} else {
    $ZipToExtract = "$env:TEMP\commandlinetools.zip"
    Write-Host "Downloading Command-Line Tools infrastructure from Google..." -ForegroundColor Gray
    try {
        Start-BitsTransfer -Source $CmdLineToolsUrl -Destination $ZipToExtract -ErrorAction Stop
    } catch {
        Write-Warning "Start-BitsTransfer failed ($($_.Exception.Message)). Falling back to curl/Invoke-WebRequest..."
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -sSL "$CmdLineToolsUrl" -o "$ZipToExtract"
        } else {
            (New-Object System.Net.WebClient).DownloadFile($CmdLineToolsUrl, $ZipToExtract)
        }
    }
}

Write-Host "Extracting Command-Line Tools to '$CmdLineToolsLatest'..." -ForegroundColor Gray
$TempExtract = Join-Path -Path $env:TEMP -ChildPath "cmdtools_extract_$([guid]::NewGuid().ToString('N'))"
Expand-Archive -Path $ZipToExtract -DestinationPath $TempExtract -Force

if (-not (Test-Path $CmdLineToolsParent)) {
    New-Item -ItemType Directory -Path $CmdLineToolsParent -Force | Out-Null
}

if (Test-Path $CmdLineToolsLatest) {
    Remove-Item -Path $CmdLineToolsLatest -Recurse -Force -ErrorAction SilentlyContinue
}

$ExtractedCmdlineDir = Join-Path -Path $TempExtract -ChildPath "cmdline-tools"
if (Test-Path $ExtractedCmdlineDir) {
    Move-Item -Path $ExtractedCmdlineDir -Destination $CmdLineToolsLatest -Force
} else {
    Move-Item -Path $TempExtract -Destination $CmdLineToolsLatest -Force
}

Remove-Item -Path $TempExtract -Recurse -Force -ErrorAction SilentlyContinue

if ($ZipToExtract -eq "$env:TEMP\commandlinetools.zip" -and (Test-Path $ZipToExtract)) {
    Remove-Item -Path $ZipToExtract -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $SdkManager)) {
    throw "Initialization of sdkmanager failed at '$SdkManager'."
}
Write-Host "Command-line tools configured at: $CmdLineToolsLatest" -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 6: Endorse Licenses & Provision SDK Components
# -------------------------------------------------------------------------
Write-Step "Endorsing Licenses & Provisioning SDK Components"

# Automatically pre-seed all Android SDK license hashes to guarantee silent/mass-deployment execution
Write-Host "Pre-seeding SDK cryptographic license hashes..." -ForegroundColor Gray
$LicensesDir = Join-Path -Path $SdkRoot -ChildPath "licenses"
if (-not (Test-Path $LicensesDir)) {
    New-Item -ItemType Directory -Path $LicensesDir -Force | Out-Null
}

$LicenseHashes = @{
    "android-sdk-license" = @(
        "24333f8a63b6825ea9c5514f83c2829b004d1fee",
        "d56f518747942e67a3f5f8f143e030887b39b3fe",
        "84831b9409646a246e30730b53cf86ec49cabba1"
    )
    "android-sdk-preview-license" = @(
        "84831b9409646a246e30730b53cf86ec49cabba1",
        "799f614c1c70e24d8723045210474043b4e69a39",
        "a5a48384968edd646824d422a211ad47f6d5c4f2",
        "84831b9409646a918e30573bab4c9c91346d8abd"
    )
    "android-googletv-license" = @("601085b94cd77f0b54ff86406957099ebe79c4d6")
    "android-googlexr-license" = @("ceff83576aac4f7f37cb98fe189e9fb3c49d3b81")
    "android-sdk-arm-dbt-license" = @("859f317696f67ef3d7f30a50a5560e7834b43903")
    "google-gdk-license" = @(
        "33b6a2b647907d4879c65370f1264ee96173d123",
        "33b6a2b64607f11b759f320ef9dff4ae5c47d97a"
    )
    "intel-android-extra-license" = @("d975f751698a77b662f1254ddbeed3901e976f5a")
    "intel-android-sysimage-license" = @("184a4253a652c47c724732a39521f292431446cb")
    "mips-android-sdk-license" = @("e9acab587f1749c68bb81786026336a60f454f02")
    "mips-android-sysimage-license" = @("e9acab5b5fbb560a72cfaecce8946896ff6aab9d")
    "microxr-sysimage-license" = @("3a7848b1d7366ca5cfa0be477627644ca73f47e3")
}

foreach ($licFile in $LicenseHashes.Keys) {
    Set-Content -Path (Join-Path -Path $LicensesDir -ChildPath $licFile) -Value ($LicenseHashes[$licFile] -join "`n") -Force
}
Write-Host "Android SDK licenses pre-seeded in '$LicensesDir'." -ForegroundColor Green

# Interactively accept any remaining/updated licenses via sdkmanager CLI
Write-Host "Accepting all SDK licenses via sdkmanager..." -ForegroundColor Gray
& cmd.exe /c "echo y | `"$SdkManager`" --sdk_root=`"$SdkRoot`" --licenses" | Out-Null

# Increase JVM timeouts to mitigate transient connection drops during substantial downloads
$env:JAVA_OPTS = "-Dsun.net.client.defaultConnectTimeout=60000 -Dsun.net.client.defaultReadTimeout=180000"

$Packages = @(
    "platform-tools",
    "emulator",
    "platforms;android-37.0",
    "sources;android-37.0",
    "build-tools;37.0.0",
    "build-tools;36.0.0",
    "system-images;android-31;google_apis;x86_64",
    "system-images;android-37.0;google_apis;x86_64"
)

Write-Host "Acquiring SDK dependencies..." -ForegroundColor Gray
foreach ($pkg in $Packages) {
    $attempt = 0
    $success = $false

    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        if ($attempt -gt 1) {
            Write-Host "Reattempting acquisition of '$pkg' (Attempt $attempt of $MaxRetries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        } else {
            Write-Host "--> Provisioning: $pkg" -ForegroundColor Cyan
        }

        & cmd.exe /c "`"$SdkManager`" --sdk_root=`"$SdkRoot`" `"$pkg`""

        if ($LASTEXITCODE -eq 0) {
            $success = $true
            Write-Host "Dependency '$pkg' integrated successfully." -ForegroundColor Green
        } else {
            Write-Warning "Attempt $attempt failed for dependency '$pkg' (exit code $LASTEXITCODE)."
            $TempSdkDir = Join-Path -Path $SdkRoot -ChildPath ".temp"
            if (Test-Path $TempSdkDir) {
                Remove-Item -Path $TempSdkDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $success) {
        throw "Failed to provision dependency '$pkg' after $MaxRetries attempts."
    }
}
Write-Host "SDK components provisioned comprehensively." -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 7: Instantiate Shared AVDs (Dual Emulators: API 31 & API 37.0)
# -------------------------------------------------------------------------
Write-Step "Instantiating Shared AVDs (API 31 & API 37.0)"

$env:ANDROID_AVD_HOME = $AvdRoot

function Set-IniValues {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][hashtable]$Settings
    )
    if (-not (Test-Path $FilePath)) { return }

    # Android SDK AvdManager requires UTF-8 WITHOUT BOM (or ASCII).
    # Windows PowerShell's Set-Content -Encoding UTF8 emits a 3-byte BOM (0xEF, 0xBB, 0xBF / ï»¿)
    # which causes AvdManager to crash with: Error parsing config.ini: "ï»¿..." is not a valid syntax.
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $lines = [System.IO.File]::ReadAllLines($FilePath)
    $updatedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $newLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        # Strip any stray leading BOM character (0xFEFF) from the line
        $cleanLine = $line.TrimStart([char]0xFEFF)
        if ($cleanLine -match '^\s*([^#;=\s]+)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            if ($Settings.ContainsKey($key)) {
                $newLines.Add("$key = $($Settings[$key])")
                $updatedKeys.Add($key) | Out-Null
            } else {
                $newLines.Add($cleanLine)
            }
        } else {
            $newLines.Add($cleanLine)
        }
    }

    foreach ($key in $Settings.Keys) {
        if (-not $updatedKeys.Contains($key)) {
            $newLines.Add("$key = $($Settings[$key])")
        }
    }

    [System.IO.File]::WriteAllLines($FilePath, $newLines, $utf8NoBom)
}

$AvdConfigurations = @(
    @{
        Name        = $AvdName
        Device      = "pixel_4"
        SystemImage = "system-images;android-31;google_apis;x86_64"
        Description = "Pixel 4 (Android 12, API 31, Google APIs)"
        Settings    = @{
            "hw.cpu.ncore"           = "4"
            "hw.ramSize"             = "2048"
            "vm.heapSize"            = "512"
            "hw.gpu.enabled"         = "yes"
            "hw.gpu.mode"            = "host"
            "fastboot.forceFastBoot" = "yes"
            "fastboot.forceColdBoot" = "no"
            "PlayStore.enabled"      = "no"
            "hw.keyboard"            = "yes"
        }
    },
    @{
        Name        = $AvdNameModern
        Device      = "pixel_4"
        SystemImage = "system-images;android-37.0;google_apis;x86_64"
        Description = "Android 17 (API 37.0, Google APIs - 720p Clean Pixel 4 Profile)"
        Settings    = @{
            "hw.cpu.ncore"           = "4"
            "hw.ramSize"             = "3072"
            "vm.heapSize"            = "512"
            "hw.gpu.enabled"         = "yes"
            "hw.gpu.mode"            = "host"
            "fastboot.forceFastBoot" = "yes"
            "fastboot.forceColdBoot" = "no"
            "PlayStore.enabled"      = "no"
            "hw.keyboard"            = "yes"
            "hw.lcd.width"           = "720"
            "hw.lcd.height"          = "1600"
            "hw.lcd.density"         = "320"
            "skin.name"              = "720x1600"
            "showDeviceFrame"        = "no"
        }
    }
)

foreach ($avd in $AvdConfigurations) {
    $currentName = $avd.Name
    $currentDevice = $avd.Device
    $currentImage = $avd.SystemImage

    Write-Host "Creating AVD '$currentName' ($($avd.Description))..." -ForegroundColor Cyan

    # Piping "no" bypasses the interactive custom hardware profile prompt
    & cmd.exe /c "echo no | `"$AvdManager`" create avd -n `"$currentName`" -k `"$currentImage`" -d `"$currentDevice`" --force"

    if ($LASTEXITCODE -ne 0) {
        throw "avdmanager failed to instantiate AVD '$currentName' (exit code $LASTEXITCODE)."
    }

    # Fine-tune emulator configuration to optimize virtualization performance
    $ConfigFile = Join-Path -Path $AvdRoot -ChildPath "$currentName.avd\config.ini"
    if (Test-Path $ConfigFile) {
        Write-Host "Injecting optimized hardware specifications for '$currentName'..." -ForegroundColor Gray
        Set-IniValues -FilePath $ConfigFile -Settings $avd.Settings
    }
    Write-Host "AVD '$currentName' generated successfully." -ForegroundColor Green
}

# -------------------------------------------------------------------------
# Step 8: Configure Environment Variables & Permissions
# -------------------------------------------------------------------------
Write-Step "Enforcing Environment Variables & Permissions"

# Define system-wide variables for cross-user accessibility
[Environment]::SetEnvironmentVariable("ANDROID_HOME", $SdkRoot, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $SdkRoot, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_AVD_HOME", $AvdRoot, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_USER_HOME", "$SdkRoot\.android", "Machine")

# Remove obsolete/overriding user-level variables to ensure machine variables take effect uniformly
foreach ($var in @("ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME")) {
    [Environment]::SetEnvironmentVariable($var, $null, "User")
}

# Append requisite binaries to the System PATH
$CurrentSysPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$PathsToAdd = @(
    "$SdkRoot\platform-tools",
    "$SdkRoot\emulator",
    "$CmdLineToolsLatest\bin"
)

foreach ($p in $PathsToAdd) {
    if ($CurrentSysPath -notlike "*$p*") {
        $CurrentSysPath = "$CurrentSysPath;$p"
    }
}
[Environment]::SetEnvironmentVariable("Path", $CurrentSysPath, "Machine")

# Also export variables directly into the current PowerShell process scope
# This ensures that tools and emulator spawned in Step 9 immediately inherit ANDROID_AVD_HOME and PATH
$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot
$env:ANDROID_AVD_HOME = $AvdRoot
$env:ANDROID_USER_HOME = "$SdkRoot\.android"
$env:Path = "$SdkRoot\platform-tools;$SdkRoot\emulator;$CmdLineToolsLatest\bin;$env:Path"

# Ensure shared .android directory exists for machine-wide adb/emulator configs
$AndroidUserHome = "$SdkRoot\.android"
if (-not (Test-Path $AndroidUserHome)) {
    New-Item -ItemType Directory -Path $AndroidUserHome -Force | Out-Null
}

# Authorize Authenticated Users:
# - Modify rights on C:\Sdk (allows reading/executing SDK tools and updating components)
# - FullControl on C:\Sdk\avd and C:\Sdk\.android (guarantees that when Student A creates snapshots,
#   locks, or userdata changes, Student B can cleanly load snapshots, overwrite them, and clear stale locks)
Write-Host "Configuring multi-user permissions for Authenticated Users (C:\Sdk, C:\Sdk\avd, C:\Sdk\.android)..." -ForegroundColor Gray
$AuthUserSid = [System.Security.Principal.SecurityIdentifier]::new(
    [System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
    $null
)

$ModifyRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $AuthUserSid,
    [System.Security.AccessControl.FileSystemRights]::Modify,
    [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
)

$FullControlRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    $AuthUserSid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit",
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
)

if (Test-Path $SdkRoot) {
    $Acl = Get-Acl -Path $SdkRoot
    $Acl.AddAccessRule($ModifyRule)
    Set-Acl -Path $SdkRoot -AclObject $Acl
    & icacls.exe $SdkRoot /grant "*S-1-5-11:(OI)(CI)M" /Q 2>$null
}

foreach ($dir in @($AvdRoot, $AndroidUserHome)) {
    if (Test-Path $dir) {
        $Acl = Get-Acl -Path $dir
        $Acl.SetAccessRule($FullControlRule)
        Set-Acl -Path $dir -AclObject $Acl
        & icacls.exe $dir /grant:r "*S-1-5-11:(OI)(CI)F" /T /Q 2>$null
    }
}

# Ensure virtualization platform features are enabled for Android Emulator, WSL2, and VirtualBox
Write-Host "Verifying hardware virtualization features (VirtualMachinePlatform & HypervisorPlatform)..." -ForegroundColor Gray
$VirtualizationFeatures = @(
    "VirtualMachinePlatform",
    "HypervisorPlatform"
)

foreach ($feat in $VirtualizationFeatures) {
    try {
        $featureState = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction SilentlyContinue
        if ($featureState -and $featureState.State -ne "Enabled") {
            Write-Host "Enabling Windows feature '$feat' for hardware virtualization..." -ForegroundColor Cyan
            Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-Warning "Could not query or enable optional feature '$feat': $_"
    }
}

# -------------------------------------------------------------------------
# Step 9: Configure Machine-Wide Gradle Performance & Memory Limits
# -------------------------------------------------------------------------
Write-Step "Configuring Machine-Wide Gradle Performance & Memory Caps"

# Capping Gradle daemon memory to 3072 MB heap + 512 MB Metaspace keeps total Gradle footprint under 3.5 GB.
# This ensures that on 16 GB workstations, Gradle, Android Studio, Windows 11, and the AVD do not exhaust RAM.
$GradlePropsContent = @(
    "# Machine-wide Gradle configuration for 16 GB Lab Workstations (HP SFF i5-14500)",
    "# Enforces a 3 GB max JVM heap and 512 MB Metaspace cap to prevent host memory exhaustion",
    "org.gradle.jvmargs=-Xmx3072m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:+ParallelRefProcEnabled",
    "org.gradle.parallel=true",
    "org.gradle.caching=true",
    "org.gradle.vfs.watch=true"
) -join "`r`n"

# 1. Seed into C:\Users\Default\.gradle so all future student logins automatically inherit this configuration
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$DefaultUserProfile = "$env:SystemDrive\Users\Default"
if (Test-Path $DefaultUserProfile) {
    $DefaultGradleDir = Join-Path -Path $DefaultUserProfile -ChildPath ".gradle"
    if (-not (Test-Path $DefaultGradleDir)) {
        New-Item -ItemType Directory -Path $DefaultGradleDir -Force | Out-Null
    }
    $targetPath = Join-Path -Path $DefaultGradleDir -ChildPath "gradle.properties"
    [System.IO.File]::WriteAllText($targetPath, $GradlePropsContent, $utf8NoBom)
    Write-Host "Default user profile template provisioned: $targetPath" -ForegroundColor Gray
}

# 2. Update all existing user profiles on the workstation
$UsersRoot = "$env:SystemDrive\Users"
if (Test-Path $UsersRoot) {
    Get-ChildItem -Path $UsersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $uDir = $_.FullName
        $uName = $_.Name
        if ($uName -notin @("Public", "All Users", "Default User")) {
            $uGradleDir = Join-Path -Path $uDir -ChildPath ".gradle"
            if (-not (Test-Path $uGradleDir)) {
                New-Item -ItemType Directory -Path $uGradleDir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if (Test-Path $uGradleDir) {
                $targetFile = Join-Path -Path $uGradleDir -ChildPath "gradle.properties"
                [System.IO.File]::WriteAllText($targetFile, $GradlePropsContent, $utf8NoBom)
                Write-Host "Configured Gradle properties for existing profile: $uDir" -ForegroundColor Gray
            }
        }
    }
}

# 3. Set machine-level GRADLE_OPTS environment variable as fallback
[Environment]::SetEnvironmentVariable("GRADLE_OPTS", "-Dorg.gradle.jvmargs=""-Xmx3072m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:+ParallelRefProcEnabled""", "Machine")
Write-Host "Machine-wide GRADLE_OPTS environment variable set." -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 10: Configure Android Studio Default Welcome Screen (Open Projects Page)
# -------------------------------------------------------------------------
Write-Step "Configuring Android Studio Welcome Screen Default (Open Projects Page)"

# By default, Android Studio re-opens the last active project on startup.
# In a shared lab, students should see the Welcome / Project Selection page instead of the previous student's project.
# Setting reopenLastProject=false in ide.general.xml establishes this as an optional default:
# students who prefer auto-reopening can still change it in Settings -> System Settings -> Reopen projects on startup.

$ProductInfoPath = Join-Path -Path $StudioInstallDir -ChildPath "product-info.json"
$DataDirName = "AndroidStudio*"
if (Test-Path $ProductInfoPath) {
    try {
        $prodJson = Get-Content -Path $ProductInfoPath -Raw | ConvertFrom-Json
        if ($prodJson.dataDirectoryName) {
            $DataDirName = $prodJson.dataDirectoryName
        }
    } catch {}
}

function Set-StudioProjectPageDefault {
    param([string]$OptionsDir)
    if (-not (Test-Path $OptionsDir)) {
        New-Item -ItemType Directory -Path $OptionsDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path $OptionsDir)) { return }

    $xmlFile = Join-Path -Path $OptionsDir -ChildPath "ide.general.xml"
    if (-not (Test-Path $xmlFile)) {
        $xmlContent = @(
            '<application>',
            '  <component name="GeneralSettings">',
            '    <option name="reopenLastProject" value="false" />',
            '  </component>',
            '</application>'
        ) -join "`r`n"
        $utf8NoBomLocal = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($xmlFile, $xmlContent, $utf8NoBomLocal)
    } else {
        try {
            [xml]$doc = Get-Content -Path $xmlFile
            $genComp = $doc.application.component | Where-Object { $_.name -eq "GeneralSettings" }
            if (-not $genComp) {
                $genComp = $doc.CreateElement("component")
                $genComp.SetAttribute("name", "GeneralSettings")
                $doc.application.AppendChild($genComp) | Out-Null
            }
            $opt = $genComp.option | Where-Object { $_.name -eq "reopenLastProject" }
            if (-not $opt) {
                $opt = $doc.CreateElement("option")
                $opt.SetAttribute("name", "reopenLastProject")
                $opt.SetAttribute("value", "false")
                $genComp.AppendChild($opt) | Out-Null
                $doc.Save($xmlFile)
            } elseif ($opt.value -ne "false") {
                $opt.SetAttribute("value", "false")
                $doc.Save($xmlFile)
            }
        } catch {
            Write-Warning "Could not update $($xmlFile) - $_"
        }
    }
}

# 1. Seed into C:\Users\Default so all future student logins automatically inherit this default
$DefaultOptionsDir = "$env:SystemDrive\Users\Default\AppData\Roaming\Google\$DataDirName\options"
Set-StudioProjectPageDefault -OptionsDir $DefaultOptionsDir
Write-Host "Default user profile template provisioned: $DefaultOptionsDir\ide.general.xml" -ForegroundColor Gray

# 2. Apply to all existing local user profiles on the workstation
$UsersRoot = "$env:SystemDrive\Users"
if (Test-Path $UsersRoot) {
    Get-ChildItem -Path $UsersRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $uName = $_.Name
        $uDir = $_.FullName
        if ($uName -notin @("Public", "All Users", "Default User")) {
            $googleDir = Join-Path -Path $uDir -ChildPath "AppData\Roaming\Google"
            if (Test-Path $googleDir) {
                Get-ChildItem -Path $googleDir -Directory -Filter "AndroidStudio*" -ErrorAction SilentlyContinue | ForEach-Object {
                    $optDir = Join-Path -Path $_.FullName -ChildPath "options"
                    Set-StudioProjectPageDefault -OptionsDir $optDir
                    Write-Host "Set welcome screen default for existing profile: $($_.FullName)" -ForegroundColor Gray
                }
            } else {
                $optDir = Join-Path -Path $uDir -ChildPath "AppData\Roaming\Google\$DataDirName\options"
                Set-StudioProjectPageDefault -OptionsDir $optDir
            }
        }
    }
}
Write-Host "Android Studio welcome screen default applied." -ForegroundColor Green

Write-Step "Deployment Executed Successfully!"
Write-Host "Android Studio : $StudioInstallDir" -ForegroundColor Green
Write-Host "Android SDK    : $SdkRoot (API 37.0, Build-Tools 36.0.0 & 37.0.0, Platform-Tools)" -ForegroundColor Green
Write-Host "AVDs Created   : $AvdName (Android 12, API 31, Google APIs) & $AvdNameModern (Android 17, API 37.0, Google APIs, 720p)" -ForegroundColor Green
Write-Host "AVD Directory  : $AvdRoot" -ForegroundColor Green
Write-Host "Host GPU Accel : Force-enabled (hw.gpu.mode=host via ANGLE Direct3D 11)" -ForegroundColor Green
Write-Host "QuickBoot State: Enabled (host GPU snapshot captured on 1st student run, shared across all users)" -ForegroundColor Green
Write-Host "Permissions    : Authenticated Users FullControl on AVDs & .android, Modify on SDK root" -ForegroundColor Green
Write-Host "Gradle Tuning  : 3 GB Heap Cap, Parallel Builds, Build Cache, VFS Watch" -ForegroundColor Green
Write-Host "Studio Default : Welcome / Project Selection page set as default for all users" -ForegroundColor Green