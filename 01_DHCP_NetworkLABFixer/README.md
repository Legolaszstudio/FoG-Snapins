# 01 - DHCP & Network Lab Fixer

## Overview
This snapin is designed for computer and networking laboratories where students frequently set static IP configurations, change subnet masks, or alter DNS settings during classroom exercises. It ensures that network adapters are automatically restored to DHCP and grants students appropriate permissions without requiring local administrative rights.

## What It Does
- **Restores DHCP on Physical NICs**: Stages a maintenance script into `C:\Program Files\DHCPFixer` and registers a scheduled task (`ResetPhysicalNICsToDHCP`) that executes under `NT AUTHORITY\SYSTEM`:
  - Triggers at **System Startup** (cold boots and reboots).
  - Triggers on **User Logoff** (TerminalServices Event 23).
  - Identifies physical network adapters (ignoring virtual adapters such as Hyper-V, WSL, VirtualBox, VMware, and VPNs) and resets them to DHCP, clearing custom IP addresses, gateways, and static DNS servers.
- **Grants Lab User Permissions**: Stages `Add-UsersToNetworkOperators.ps1` and registers a scheduled task (`AddUsersToNetworkOperators`):
  - Adds standard user accounts and logging-on users to the built-in **Network Configuration Operators** security group (`S-1-5-32-556`).
  - Allows students to adjust adapter IP configurations during network labs without needing full local administrator rights.
- **Logging**: Maintains run logs at `C:\Program Files\DHCPFixer\dhcpfixer.log` and `netconfigops.log`.

## Usage
Deploy [deployDHCPFixer.ps1](deployDHCPFixer.ps1) as a FOG snapin run under the local `SYSTEM` account.

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "deployDHCPFixer.ps1"
```

## Licensing Notice
- **Scripts:** The PowerShell deployment and maintenance scripts are licensed under the [MIT License](../LICENSE).
- **Windows Components:** Built-in Windows security groups, task scheduler APIs, and network management cmdlets are proprietary components of **Microsoft Corporation**.

