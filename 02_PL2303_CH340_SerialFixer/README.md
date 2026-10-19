# 02 - Prolific PL2303 & WCH CH340 Serial Driver Fixer

## Overview
This snapin resolves common driver conflicts and code 10/code 52 errors on workstations using USB-to-Serial TTL converters (widely used with microcontrollers, Cisco consoles, Arduino, and embedded devices in electronics labs).

## What It Does
- **Stages Working Drivers**: Stages stable driver packages into `C:\Program Files\SerialDriverFixer`:
  - **Prolific PL2303**: Installs legacy working driver v3.3.2.102 (`PL2303/`) that works reliably with common PL2303 chips and prevents counterfeit/discontinued chip bricking errors.
  - **WCH CH340 / CH341**: Installs working USB-to-Serial driver v3.9 (`CH340/`).
- **Driver Store Pre-Installation**: Injects the driver packages directly into the Windows Driver Store using `pnputil.exe`.
- **Purges Incompatible Drivers**: Automatically identifies and removes broken or newer incompatible Prolific drivers installed by Windows Update.
- **Persistent Watchdog Task**: Registers a scheduled task running under `SYSTEM` at boot and user logon to ensure drivers remain properly assigned and bound.

## Files
- `deploySerialDriverFixer.ps1`: Primary mass deployment script (installs both PL2303 and CH340 drivers and registers watchdog).
- `deployPL2303.ps1`: Standalone deployment for Prolific PL2303.
- `deployCH340.ps1`: Standalone deployment for WCH CH340.
- `SerialDriverFixer.ps1`: The watchdog script run by Task Scheduler.
- `CH340/`: Driver files (`CH341SER.inf`, `CH341SER.sys`, `CH341M64.sys`, `CH341S64.sys`, `CH341SER.CAT`, DLLs).
- `PL2303/`: Driver files (`Ser2pl.inf`, `Ser2pl64.sys`, `Ser2pl.cat`, `difxapi.dll`).

## Usage
Deploy [deploySerialDriverFixer.ps1](deploySerialDriverFixer.ps1) via FOG snapin under `SYSTEM`:

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "deploySerialDriverFixer.ps1"
```

## Licensing Notice & Disclaimer
> [!WARNING]
> **Proprietary Driver Files Notice**:
> While all PowerShell deployment and maintenance scripts in this directory are licensed under the [MIT License](../LICENSE), the bundled hardware driver binaries (`.sys`, `.dll`, `.cat`, `.inf`) are **NOT** open-source and are **NOT** covered by the MIT license:
> - **Prolific PL2303 drivers** (`Ser2pl64.sys`, etc.) are proprietary software copyrighted by **Prolific Technology Inc.**
> - **WCH CH340 / CH341 drivers** (`CH341SER.sys`, etc.) are proprietary software copyrighted by **Nanjing Qinheng Microelectronics Co., Ltd. (WCH)**.
>
> These drivers are provided solely for educational and lab deployment interoperability under their respective original vendor licensing terms.

