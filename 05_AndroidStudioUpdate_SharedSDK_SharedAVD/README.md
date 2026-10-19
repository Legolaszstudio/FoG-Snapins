# 05 - Android Studio, Shared SDK & Shared AVD Deployment Snapin

## Overview
This snapin provides a fully automated mass deployment and update solution for **Android Studio**, provisioning a shared machine-wide **Android SDK** (API 37.0 / Android 17) and pre-configured **dual emulators** (Pixel 4 on Android 12 with Google Play for lightweight lab performance, and Pixel 7 on Android 17 with Google Play for cutting-edge development). 

In academic and lab environments, standard Android Studio setups waste dozens of gigabytes per student by downloading duplicate SDKs and emulators into individual user profiles (`%LOCALAPPDATA%`). This snapin eliminates that issue by centralizing the SDK and AVD in a shared directory with appropriate multi-user permissions.

## What It Does
- **Process & Legacy Cleanup**: Gracefully terminates running ADB, emulator, and Java processes, then cleanly uninstalls legacy Android Studio versions and purges corrupted or old SDK/AVD directories.
- **Silent Installation**: Installs Android Studio silently from the local installer executable.
- **Shared SDK Provisioning**:
  - Sets up a shared SDK root at `C:\Sdk`.
  - Reuses Android Studio's bundled JBR (Java Runtime) to run SDK tools without requiring a separate JDK installation.
  - Automatically provisions command-line tools into `C:\Sdk\cmdline-tools\latest` (omitting redundant package re-downloads).
  - Non-interactively accepts all Android SDK licenses and installs:
    - `platforms;android-37.0` & `sources;android-37.0` (Android 17 Platform & Sources)
    - `build-tools;37.0.0` & `build-tools;36.0.0` (Android SDK Build-Tools)
    - `platform-tools` (ADB, Fastboot)
    - `emulator`
    - `system-images;android-31;google_apis_playstore;x86_64` (Android 12 Play Store System Image)
    - `system-images;android-37.0;google_apis_playstore;x86_64` (Android 17 Play Store System Image)
- **Shared Dual Emulators (AVD)**: Creates and configures shared Virtual Devices in `C:\Sdk\avd` tuned for 16 GB lab workstations:
  - **`Pixel_4_API_31`**: Android 12 (API 31) with Google Play — lightweight, optimal for fast classroom testing and older hardware.
  - **`Pixel_7_API_37`**: Android 17 (API 37.0) with Google Play — enables instruction and testing of the latest Android APIs.
  - **Workstation Tuning**: Injects 4 CPU cores (`hw.cpu.ncore=4`), 2048 MB RAM (`hw.ramSize=2048`), 512 MB VM heap (`vm.heapSize=512`), auto host GPU acceleration (`hw.gpu.mode=auto`), and snapshot quickboot (`fastboot.forceFastBoot=yes`) to prevent host RAM starvation.
- **Environment & Virtualization**:
  - Automatically verifies and enables both **`VirtualMachinePlatform`** and **`HypervisorPlatform`** (WHPX), ensuring Android Emulator, WSL2, and VirtualBox run concurrently with full hardware virtualization on Intel 12th/13th/14th Gen processors (e.g. i5-14500) without obsolete Intel HAXM drivers.
  - Configures system-wide environment variables: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_AVD_HOME`, `ANDROID_USER_HOME`, and updates system `PATH`.
  - Grants `Authenticated Users` Modify permissions on `C:\Sdk` and `C:\Sdk\avd` so non-administrator students can build and emulate projects seamlessly.

## Prerequisites & Setup
1. Download the latest official Windows installer from the official Android Studio portal:
   - Official Download Page: [https://developer.android.com/studio](https://developer.android.com/studio)
2. Place the installer into this folder alongside [deployAndroidStudio.ps1](deployAndroidStudio.ps1).
3. If using a specific installer filename, specify it via the `-InstallerName` parameter or match the default filename configured in the script (`android-studio-rabbit1-windows.exe`).

## Usage
Deploy [deployAndroidStudio.ps1](deployAndroidStudio.ps1) via FOG snapin under `SYSTEM`:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "deployAndroidStudio.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Software & SDK License Notice**:
> While the PowerShell automation script ([deployAndroidStudio.ps1](deployAndroidStudio.ps1)) is licensed under the [MIT License](../LICENSE), **Android Studio**, the **Android SDK**, emulator system images, command-line tools, and Google APIs are **NOT** covered by the MIT license:
> - Software, tools, and binaries (`.exe`, `.zip`, `.img`) are proprietary to **Google LLC** and the Open Handset Alliance.
> - Usage is governed by the [Android Software Development Kit License Agreement](https://developer.android.com/studio/terms) and Google Terms of Service.