# FOG Project Snapins Collection

A modular collection of automated deployment snapins, maintenance scripts, and driver packages configured for deployment to Windows workstations via **FOG Project** (or compatible endpoint management solutions such as SCCM, Intune, PDQ Deploy, and GPO).

---

## Snapin Directory Index

| Snapin Folder | Purpose / Description | Binaries / Packages |
| :--- | :--- | :--- |
| [**00_AzureJoin**](00_AzureJoin/) | Silently joins workstations to Microsoft Entra ID (Azure AD), applies device naming (`petrik-%serial%`), skips OOBE screens, and enables app sideloading via a Windows Provisioning Package (`.ppkg`). | `azure_join.ppkg` |
| [**01_DHCP_NetworkLABFixer**](01_DHCP_NetworkLABFixer/) | Heals computer lab networking by resetting all physical NICs to DHCP at boot and user logoff, and automatically adds students to *Network Configuration Operators* so they can configure IPs during labs without admin rights. | None (Pure PowerShell) |
| [**02_PL2303_CH340_SerialFixer**](02_PL2303_CH340_SerialFixer/) | Deploys stable Prolific PL2303 and WCH CH340/CH341 USB-to-Serial drivers, stages them to the Windows Driver Store, removes broken Windows Update drivers, and registers a persistent watchdog task. | `.sys`, `.dll`, `.cat`, `.inf` |
| [**03_HP_Elitedesk600_G2_i5-6500_drivers**](03_HP_Elitedesk600_G2_i5-6500_drivers/) | Silently installs Intel Chipset, Intel Gigabit NIC, Realtek HD Audio, and Intel HD Graphics 530 drivers for HP EliteDesk 600 G2 systems with strict reboot suppression for FOG Client. | `.exe` SoftPaqs & installers |
| [**04_BambuFarmManagerClient**](04_BambuFarmManagerClient/) | Silently deploys the Bambu Farm Manager Client machine-wide across all user profiles under the FOG `SYSTEM` context for 3D printer lab workstations. | `.exe` installer (downloaded) |
| [**05_AndroidStudioUpdate_SharedSDK_SharedAVD**](05_AndroidStudioUpdate_SharedSDK_SharedAVD/) | Mass-deploys Android Studio, sets up a shared machine-wide SDK (`C:\Sdk`) with API 31 tools, configures a shared Pixel 4 AVD (`C:\Sdk\avd`), and grants multi-user NTFS permissions to prevent duplicate downloads per user. | `.exe` installer & SDK tools |
| [**06_Install_Figma_MachineWide**](06_Install_Figma_MachineWide/) | Installs the Figma Desktop client machine-wide into `Program Files` via MSI (`ALLUSERS=1 /qn /norestart`), providing instant access for all users without individual per-user installations. | `Figma.msi` |

---

## Licensing & Third-Party Software Notice

### MIT License (Scripts)
All original PowerShell deployment scripts, batch scripts, and automation logic developed in this repository are licensed under the [MIT License](LICENSE).

### Third-Party Software, Drivers & Installers Disclaimer
> [!WARNING]
> **Important Legal Disclaimer**:
> Although the scripts and automation tooling are released under the MIT License, **the actual third-party software installers (`.msi`, `.exe`), hardware driver binaries (`.sys`, `.dll`), driver catalogs (`.cat`, `.inf`), and SDK components are NOT covered by the MIT License**.
>
> They are proprietary intellectual property of their respective manufacturers and copyright holders:
>
> | Component / Vendor | Affected Files / Types | Proprietary License / Terms |
> | :--- | :--- | :--- |
> | **Microsoft Corporation** | `.ppkg`, Windows provisioning components | Microsoft Software License Terms |
> | **Prolific Technology Inc.** | `PL2303/` (`Ser2pl64.sys`, `difxapi.dll`, etc.) | Prolific Software End User License |
> | **Nanjing Qinheng Microelectronics (WCH)** | `CH340/` (`CH341SER.sys`, `CH341M64.sys`, etc.) | WCH Driver License Agreement |
> | **HP Inc.** | `sp101125.exe`, `sp103864.exe`, `sp110164.exe` | HP Software License Terms |
> | **Intel Corporation** | Intel Chipset, NIC, and Graphics (`gfx_win_*.exe`) | Intel Software License Agreement |
> | **Realtek Semiconductor Corp.** | Realtek High Definition Audio driver | Realtek Software License Terms |
> | **Bambu Lab** | `bambu-farm-manager-client-*.exe` | Bambu Lab Terms of Service |
> | **Google LLC** | Android Studio, Android SDK, and system images | [Android Software Development Kit License](https://developer.android.com/studio/terms) |
> | **Figma, Inc.** | `Figma.msi` | [Figma Terms of Service](https://www.figma.com/tos/) |
>
> Any redistribution, bundling, or deployment of these binary assets must comply with the licensing terms and distribution rights granted by the original vendors.

---

## General FOG Snapin Deployment Best Practices

1. **Execution Account:** FOG Client executes snapins under the local machine's `NT AUTHORITY\SYSTEM` account. Scripts in this repository are designed to install machine-wide rather than into a single user's profile.
2. **Reboot Suppression:** Snapin scripts suppress vendor automatic reboot commands (e.g., using `-norestart` or `/norestart`) so the FOG Client can coordinate system reboots after all tasks are completed.
3. **Execution Policy:** Ensure snapin runner commands specify bypass flags:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -NoProfile -File "scriptName.ps1"
   ```
4. **Credential Security:** Never commit provisioning packages (`.ppkg`) containing live Bulk Primary Refresh Tokens (BPRT) or hardcoded credentials to public version control repositories.

