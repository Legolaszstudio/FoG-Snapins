# 03 - HP EliteDesk 600 G2 (i5-6500) Drivers Snapin

Our golden image is captured for newer HP Elite SFF 800 G9 workstations, but we still have a few older G2 workstations in the lab that require specific drivers for stable functionality.

## Overview
This snapin provides unattended, silent installation of essential hardware drivers for HP EliteDesk 600 G2 Desktop workstations (Intel Core i5-6500 Skylake platform) deployed via FOG Project.

## What It Does
- **Silent Unattended Driver Installation**: Executes vendor installer packages silently without requiring any user input.
- **Reboot Suppression**: Guarantees that none of the driver installers trigger an unexpected system reboot during deployment, allowing the FOG Client service to safely finish all pending snapins and manage machine reboots cleanly.
- **Comprehensive Logging**: Outputs detailed operation logs to `C:\Windows\Temp\FOG_Driver_Deployment.log`.

## Included Drivers
1. **Intel Chipset Support**: `sp101125.exe` (HP SoftPaq running `setupChipset.exe -s -norestart`)
2. **Intel Network Interface (NIC)**: `sp110164.exe` (Intel Gigabit Ethernet via `pnputil`)
3. **Realtek High Definition Audio**: `sp103864.exe` (HP SoftPaq with `setup.iss` non-interactive response file)
4. **Intel HD Graphics 530**: `gfx_win_101.2115.exe` (Intel Graphics Installer with `-s --overwrite`, reboot flag omitted)

## Usage
Deploy [Install-Drivers.ps1](Install-Drivers.ps1) as a FOG snapin run under the local `SYSTEM` account:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "Install-Drivers.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Executable (.EXE) & Driver Files Notice**:
> While the automation script ([Install-Drivers.ps1](Install-Drivers.ps1)) is licensed under the [MIT License](../LICENSE), the bundled installer executables (`.exe`) and hardware drivers are **NOT** open-source and are **NOT** covered by the MIT license:
> - **HP SoftPaqs** (`sp101125.exe`, `sp103864.exe`, `sp110164.exe`) are proprietary to **HP Inc.**
> - **Intel Chipset, Network, and Graphics Installers** are proprietary software copyrighted by **Intel Corporation**.
> - **Realtek Audio Drivers** are proprietary software copyrighted by **Realtek Semiconductor Corp.**
>
> All executable installers and drivers are subject to their respective manufacturers' End User License Agreements (EULAs).

