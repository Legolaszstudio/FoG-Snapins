# 00 - Azure AD / Entra ID Join Snapin

## Overview
This snapin automatically and silently joins freshly imaged Windows workstations to Microsoft Entra ID (formerly Azure Active Directory) using a Windows Provisioning Package (`.ppkg`).

## What It Does
- Executes `Install-ProvisioningPackage` silently via PowerShell ([install.ps1](install.ps1)).
- Automatically joins the workstation to the configured Microsoft Entra ID tenant using a Bulk Primary Refresh Token (BPRT).
- Applies device naming conventions (e.g., `petrik-%serial%` - However it will later by overriden by FoG client inventory name).
- Suppresses initial Windows Out-Of-Box Experience (OOBE) prompts.
- Configures application management policies (enables trusted application sideloading).

## Usage
1. Generate your organization's provisioning package using **Windows Configuration Designer (WCD)**.
2. Name the generated package `azure_join.ppkg` and place it in this folder.
3. Deploy this snapin to the target host or group through the FOG web interface.

> [!CAUTION]
> **Security Notice**: Do not commit or publicly share `.ppkg` files or configuration files containing unredacted BPRT tokens. BPRT tokens are administrative credentials that allow arbitrary devices to join your cloud tenant.

## Licensing Notice
- **Scripts:** The PowerShell deployment script ([install.ps1](install.ps1)) is provided under the [MIT License](../LICENSE).
- **Third-Party Software & Tokens:** The `.ppkg` package format, Windows provisioning engine, and Microsoft Entra ID authentication artifacts are proprietary to **Microsoft Corporation** and are not licensed under MIT.

