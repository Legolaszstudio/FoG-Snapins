# 05 - Android Studio, Shared SDK & Shared AVD Deployment Snapin

## Overview
This snapin provides a fully automated mass deployment and update solution for **Android Studio**, provisioning a shared machine-wide **Android SDK** (API 31) and a pre-configured **Pixel 4 Emulator** (Android 12 with Google Play). 

In academic and lab environments, standard Android Studio setups waste dozens of gigabytes per student by downloading duplicate SDKs and emulators into individual user profiles (`%LOCALAPPDATA%`). This snapin eliminates that issue by centralizing the SDK and AVD in a shared directory with appropriate multi-user permissions.

## What It Does
- **Process & Cleanup Cleanup**: Gracefully terminates running ADB, emulator, and Java processes, then cleanly uninstalls legacy Android Studio versions and purges corrupted and old SDK/AVD directories.
- **Silent Installation**: Installs Android Studio silently from the local installer executable.
- **Shared SDK Provisioning**:
  - Sets up a shared SDK root at `C:\Sdk`.
  - Reuses Android Studio's bundled JBR (Java Runtime) to run SDK tools without requiring a separate JDK installation.
  - Automatically downloads command-line tools, non-interactively accepts all Android SDK licenses, and installs `platforms;android-31`, `build-tools;31.0.0`, `platform-tools`, `emulator`, and the Google Play system image.
- **Shared Emulator (AVD)**: Creates and configures a shared Pixel 4 Virtual Device in `C:\Sdk\avd`.
- **Environment & Permissions**:
  - Configures system-wide environment variables: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_AVD_HOME`, and updates system `PATH`.
  - Grants `Authenticated Users` Modify permissions on `C:\Sdk` so non-administrator students can build and emulate projects seamlessly.

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
# 05 - Android Studio, Shared SDK & Shared AVD Deployment Snapin

## Overview
This snapin provides a fully automated mass deployment and update solution for **Android Studio**, provisioning a shared machine-wide **Android SDK** (API 31) and a pre-configured **Pixel 4 Emulator** (Android 12 with Google Play). 

In academic and lab environments, standard Android Studio setups waste dozens of gigabytes per student by downloading duplicate SDKs and emulators into individual user profiles (`%LOCALAPPDATA%`). This snapin eliminates that issue by centralizing the SDK and AVD in a shared directory with appropriate multi-user permissions.

## What It Does
- **Process & Cleanup Cleanup**: Gracefully terminates running ADB, emulator, and Java processes, then cleanly uninstalls legacy Android Studio versions and purges corrupted SDK/AVD directories.
- **Silent Installation**: Installs Android Studio silently from the local installer executable.
- **Shared SDK Provisioning**:
  - Sets up a shared SDK root at `C:\Sdk`.
  - Reuses Android Studio's bundled JBR (Java Runtime) to run SDK tools without requiring a separate JDK installation.
  - Automatically downloads command-line tools, non-interactively accepts all Android SDK licenses, and installs `platforms;android-31`, `build-tools;31.0.0`, `platform-tools`, `emulator`, and the Google Play system image.
- **Shared Emulator (AVD)**: Creates and configures a shared Pixel 4 Virtual Device in `C:\Sdk\avd`.
- **Environment & Permissions**:
  - Configures system-wide environment variables: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_AVD_HOME`, and updates system `PATH`.
  - Grants `Authenticated Users` Modify permissions on `C:\Sdk` so non-administrator students can build and emulate projects seamlessly.

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