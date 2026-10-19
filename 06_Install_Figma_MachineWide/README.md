# 06 - Figma Machine-Wide Installation Snapin

## Overview
This snapin silently installs the **Figma Desktop** application machine-wide for all users on Windows workstations via FOG Project.

## What It Does
- Installs Figma globally into `C:\Program Files` using the official enterprise Windows Installer package (`Figma.msi`).
- Runs `msiexec.exe` with `ALLUSERS=1 /qn /norestart` parameters via [install_figma.ps1](install_figma.ps1), ensuring standard non-admin users have instant access to Figma upon login without requiring individual per-user installations in `%LOCALAPPDATA%`.
- Writes installation logs to `C:\ProgramData\Figma_Install.log`.
- Evaluates exit codes (`0` for success, `3010` for success with pending reboot).

## Bundled Version & Updates
- **Currently Bundled Version:** `126.9.13` (Downloaded: October 19, 2026)
- **Official Enterprise Releases Feed:** The latest machine-wide MSI releases can be tracked at [https://desktop.figma.com/win/releases.xml](https://desktop.figma.com/win/releases.xml).

## Usage
Deploy [install_figma.ps1](install_figma.ps1) as a FOG snapin run under the local `SYSTEM` account:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "install_figma.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Software & MSI Installer Notice**:
> While the PowerShell deployment script ([install_figma.ps1](install_figma.ps1)) is licensed under the [MIT License](../LICENSE), the **Figma Desktop application** and the `Figma.msi` installer are **NOT** open-source and are **NOT** covered by the MIT license.
> - Figma is proprietary software copyrighted by **Figma, Inc.**
> - Use of the software is governed by the [Figma Terms of Service](https://www.figma.com/tos/).
## Overview
This snapin silently installs the **Figma Desktop** application machine-wide for all users on Windows workstations via FOG Project.

## What It Does
- Installs Figma globally into `C:\Program Files` using the official enterprise Windows Installer package (`Figma.msi`).
- Runs `msiexec.exe` with `ALLUSERS=1 /qn /norestart` parameters via [install_figma.ps1](install_figma.ps1), ensuring standard non-admin users have instant access to Figma upon login without requiring individual per-user installations in `%LOCALAPPDATA%`.
- Writes installation logs to `C:\ProgramData\Figma_Install.log`.
- Evaluates exit codes (`0` for success, `3010` for success with pending reboot).

## Bundled Version & Updates
- **Currently Bundled Version:** `126.9.13` (Downloaded: October 19, 2026)
- **Official Enterprise Releases Feed:** The latest machine-wide MSI releases can be tracked at [https://desktop.figma.com/win/releases.xml](https://desktop.figma.com/win/releases.xml).

## Usage
Deploy [install_figma.ps1](install_figma.ps1) as a FOG snapin run under the local `SYSTEM` account:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "install_figma.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Software & MSI Installer Notice**:
> While the PowerShell deployment script ([install_figma.ps1](install_figma.ps1)) is licensed under the [MIT License](../LICENSE), the **Figma Desktop application** and the `Figma.msi` installer are **NOT** open-source and are **NOT** covered by the MIT license.
> - Figma is proprietary software copyrighted by **Figma, Inc.**
> - Use of the software is governed by the [Figma Terms of Service](https://www.figma.com/tos/).