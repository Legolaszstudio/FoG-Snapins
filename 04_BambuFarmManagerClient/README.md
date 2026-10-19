# 04 - Bambu Farm Manager Client Snapin

## Overview
This snapin silently installs the **Bambu Farm Manager Client** application machine-wide on Windows workstations for 3D printing laboratories and maker spaces.

## What It Does
- Executes the installer executable silently with `/S /allusers` parameters via [bambufarm.ps1](bambufarm.ps1).
- Forces system-wide installation across all user accounts (essential since FOG snapins execute under `NT AUTHORITY\SYSTEM`).
- Logs installation activity and exit codes to `%TEMP%\BambuFarmManager_Install.log`.
- Passes the installer process exit code back to the FOG Client so the FOG web interface accurately reflects deployment success or failure.

## Prerequisites & Setup
1. Download the latest official Windows installer (`bambu-farm-manager-client-*-win32-x64.exe`) from the official Bambu Lab wiki:
   - Official Download Page: [https://wiki.bambulab.com/en/software/bambu-farm-manager](https://wiki.bambulab.com/en/software/bambu-farm-manager)
2. Place the executable into this directory alongside [bambufarm.ps1](bambufarm.ps1).
3. If the version filename differs from the default (`bambu-farm-manager-client-v3.0.0-8c114304-win32-x64.exe`), update the `$installerName` variable in [bambufarm.ps1](bambufarm.ps1#L2).

## Usage
Deploy via FOG snapin under `SYSTEM`:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "bambufarm.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Software Notice**:
> While the PowerShell deployment script ([bambufarm.ps1](bambufarm.ps1)) is licensed under the [MIT License](../LICENSE), the **Bambu Farm Manager Client** application and its installer executable (`.exe`) are proprietary software copyrighted by **Bambu Lab** and are **NOT** covered by the MIT license.