# 05 - Android Studio, Shared SDK & Shared AVD Deployment Snapin

## Overview
This snapin provides a fully automated mass deployment and maintenance solution for **Android Studio**, provisioning a shared machine-wide **Android SDK** (API 37.0 / Android 17), Command-Line Tools v23.0+, and pre-configured **dual shared emulators** (`Pixel_4_API_31` and `Pixel_7_API_37`) tuned specifically for 16 GB lab workstations (such as HP Elite SFF systems with Intel Core i5-14500 and Intel UHD Graphics 770).

In academic computer labs, standard Android Studio installations waste dozens of gigabytes per student by downloading duplicate SDKs, tools, and emulators into individual user profiles (`%LOCALAPPDATA%`). This snapin completely solves this by centralizing the SDK (`C:\Sdk`) and AVDs (`C:\Sdk\avd`) into shared directories with multi-user permissions, while enforcing host memory caps on Gradle to prevent RAM starvation.

---

## Architecture & Workstation Tuning

### 1. Dual Emulator Strategy (`Pixel_4_API_31` vs. `Pixel_7_API_37`)

| Specification | `Pixel_4_API_31` (Daily Driver) | `Pixel_7_API_37` (Modern APIs) | Rationale / Workstation Impact |
| :--- | :--- | :--- | :--- |
| **Android Version** | Android 12.0 ("S", API 31) | Android 17.0 ("CinnamonBun", API 37.0) | API 31 for core curriculum; API 37 for modern platform features. |
| **Image Variant** | `google_apis` (x86_64) | `google_apis` (x86_64) | Omits Play Store client app to save ~500 MB RAM, eliminate background update churn, and enable `adb root`. |
| **Guest RAM / Heap**| **2048 MB** RAM / 512 MB Heap | **3072 MB** RAM / 512 MB Heap | 3072 MB gives Android 17 adequate headroom to prevent Low Memory Killer (LMK) process thrashing. |
| **Resolution & Scale**| 1080×2280 @ 440 dpi | **720×1600** @ 320 dpi (Borderless) | Reduces pixel fill-rate by **55.5%** (1.15M vs 2.59M pixels), slashing shared GPU memory bandwidth on Intel UHD 770. |
| **vCPU Cores** | 4 cores (`hw.cpu.ncore=4`) | 4 cores (`hw.cpu.ncore=4`) | Fully utilizes i5-14500 P-cores via Thread Director while leaving 16 threads free for Windows 11 & Gradle. |
| **GPU Acceleration** | `hw.gpu.mode=host` | `hw.gpu.mode=host` | Forces ANGLE Direct3D 11 hardware execution, bypassing slow SwiftShader software CPU fallback. |
| **Boot Optimization**| Fastboot Quickboot Snapshot | Fastboot Quickboot Snapshot | Cold boots are bypassed after initial capture; snapshot boots execute in **~350 ms**. |

> [!TIP]
> **Recommended Daily Usage in Classrooms**:
> Instruct students to use **`Pixel_4_API_31`** as their primary emulator. With an idle memory footprint of only ~1.1 GB, it leaves ample headroom for concurrent IDE and browser multitasking. Students can still set `compileSdk = 35` (or higher) in their projects and test on API 31 as long as `minSdk <= 31`.

---

### 2. The 16 GB Host RAM Budget & Machine-Wide Gradle Limits

On a 16 GB Windows 11 workstation running Android Studio, the host memory budget is strictly constrained:
* **Windows 11 Base + Services**: ~4.5–5.0 GB
* **Android Studio IDE**: ~2.0–2.5 GB
* **Intel UHD 770 Dynamic VRAM**: ~1.0–1.5 GB
* **Android Emulator (API 31 / 37)**: ~2.0–3.0 GB
* **Browser (Docs, Canvas, StackOverflow)**: ~1.5–2.0 GB
* **Gradle Daemon (Uncapped Default)**: Up to 4.0–6.0 GB ⚠️ *(Risk of severe disk paging)*

To prevent system lockups during student project builds, the snapin automatically deploys a machine-wide `gradle.properties` to **`C:\Users\Default\.gradle`** (inherited by all new user accounts) and **all existing profiles under `C:\Users\*`**, as well as setting the system-level `GRADLE_OPTS` variable:

```properties
# Machine-wide Gradle configuration for 16 GB Lab Workstations (HP SFF i5-14500)
# Enforces a 3 GB max JVM heap and 512 MB Metaspace cap to prevent host memory exhaustion
org.gradle.jvmargs=-Xmx3072m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:+ParallelRefProcEnabled
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.vfs.watch=true
```

* **Memory Cap**: Capping heap at 3072 MB and Metaspace at 512 MB guarantees the Gradle daemon never exceeds ~3.5 GB total footprint.
* **Build Acceleration**: Activates parallel execution across the i5-14500's 20 threads, persistent task caching, and Windows 11 virtual file system (VFS) watching for rapid incremental builds.

---

### 3. Critical Technical Safeguards

#### Command-Line Tools v23.0+ Requirement
* **Why v23.0+**: Android 17 introduces decimal API levels (`AndroidVersion.ApiLevel=37.0`). Older Command-Line Tools (e.g. v12.0 / build `11076708`) do not support decimal levels and parse `37.0` as `0`, writing `target=android-0`. This causes SurfaceFlinger to SIGABRT in `mapper.ranchu.so` (`Assertion failed: !rcEnc->featureInfo()->hasReadColorBufferDma`) and locks the emulator in an infinite boot loop.
* **Implementation**: The script provisions Google's modern build **`15859902`** (v23.0+), properly configuring `target=android-37.0` and modern gralloc DMA protocols.

#### UTF-8 Without BOM Encoding Enforcement
* **Why BOM-less**: Windows PowerShell 5.1's `Set-Content -Encoding UTF8` automatically inserts a 3-byte Byte Order Mark (`0xEF, 0xBB, 0xBF` / `ï»¿`). Android Studio's SDK parser (`AvdManager`) fails to parse keys prefixed with BOM bytes (`Error parsing config.ini: "ï»¿PlayStore.enabled = no" is not a valid syntax`).
* **Implementation**: The script uses a custom `Set-IniValues` helper backed by .NET's `[System.Text.UTF8Encoding]::new($false)` to guarantee all `.ini` and `.properties` files are written strictly without a BOM.

---

## What the Script Does

1. **Process & Legacy Eradication**:
   - Forcefully terminates conflicting processes (`studio64`, `studio`, `emulator`, `qemu-system-*`, `adb`, `java`).
   - Detects and silently uninstalls pre-existing Android Studio installations via synchronous NSIS uninstaller invocation (`_?=<dir>`).
   - Recursively purges legacy SDKs and AVDs from `C:\Sdk`, `C:\Android`, environment variable targets, and all user profile roots.
2. **Silent Android Studio Installation**: Installs Android Studio silently (`/S`) from the bundled local installer.
3. **Bundled JBR Reuse**: Reuses Android Studio's embedded Java runtime (`jbr\bin\java.exe`) to execute SDK tools without requiring a standalone JDK.
4. **Command-Line Tools Provisioning**: Downloads and provisions Command-Line Tools v23.0+ (`15859902`) into `C:\Sdk\cmdline-tools\latest`.
5. **Pre-Seeded License Endorsement**: Pre-seeds official cryptographic license hashes in `C:\Sdk\licenses` and accepts any remaining agreements via `sdkmanager --licenses`.
6. **SDK Component Provisioning**: Installs `platform-tools`, `emulator`, `platforms;android-37.0`, `sources;android-37.0`, `build-tools;37.0.0`, `build-tools;36.0.0`, and system images `system-images;android-31;google_apis;x86_64` and `system-images;android-37.0;google_apis;x86_64`.
7. **AVD Instantiation & Clean INI Tuning**: Creates `Pixel_4_API_31` and `Pixel_7_API_37` with dedicated memory, resolution, host GPU acceleration, and snapshot parameters written without duplicate keys or BOM artifacts.
8. **Virtualization & Permissions**:
   - Enables Windows optional features `VirtualMachinePlatform` and `HypervisorPlatform` (WHPX) for Intel VT-x hardware virtualization.
   - Configures system environment variables (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_AVD_HOME`, `ANDROID_USER_HOME`, `GRADLE_OPTS`, `PATH`).
   - Grants `Authenticated Users` Modify permissions on `C:\Sdk` and `C:\Sdk\avd` so non-administrator students can compile and emulate seamlessly.
9. **Machine-Wide Gradle Tuning**: Injects memory caps and acceleration properties into `C:\Users\Default\.gradle` and all local student profiles.

---

## Prerequisites & Setup

1. Download the official Android Studio Windows installer:
   * Official Download Portal: [https://developer.android.com/studio](https://developer.android.com/studio)
2. Place the installer executable into this folder alongside [`deployAndroidStudio.ps1`](deployAndroidStudio.ps1).
3. Ensure the filename matches `$InstallerName` (`android-studio-rabbit1-windows.exe`) or specify it via the `-InstallerName` parameter.

---

## Usage

Deploy [`deployAndroidStudio.ps1`](deployAndroidStudio.ps1) via FOG snapin under `SYSTEM` (or from an elevated Administrator PowerShell console):

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "deployAndroidStudio.ps1"
```

---

## Licensing Notice & Disclaimer

> [!WARNING]
> **Proprietary Software & SDK License Notice**:
> While the PowerShell automation script ([`deployAndroidStudio.ps1`](deployAndroidStudio.ps1)) is licensed under the [MIT License](../LICENSE), **Android Studio**, the **Android SDK**, emulator system images, command-line tools, and Google APIs are **NOT** covered by the MIT license:
> * Software, tools, and binaries (`.exe`, `.zip`, `.img`) are proprietary to **Google LLC** and the Open Handset Alliance.
> * Usage is governed by the [Android Software Development Kit License Agreement](https://developer.android.com/studio/terms) and Google Terms of Service.