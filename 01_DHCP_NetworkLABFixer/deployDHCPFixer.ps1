# ====================================================================
# deployDHCPFixer.ps1 - Physical NIC DHCP & TCP/IP Stack Fixer
# ====================================================================
# Purpose:
# 1. Stages the DHCP healing script into Program Files (tamper-proof).
# 2. Registers primary scheduled task (ResetPhysicalNICsToDHCP) to run silently under SYSTEM at:
#    - System Startup (cold boot / reboot)
#    - Complete User Logoff (TerminalServices Event 23)
# 3. Stages the user permission script (Add-UsersToNetworkOperators.ps1) into Program Files.
# 4. Registers secondary scheduled task (AddUsersToNetworkOperators) to run silently under SYSTEM at:
#    - System Startup
#    - User Logon (any user)
#    Adds users to the "Network Configuration Operators" (S-1-5-32-556) group so they can configure network settings during lab exercises.
# 5. Logs execution timestamps and results to Program Files.
# ====================================================================

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path -Path $env:ProgramFiles -ChildPath "DHCPFixer"),
    [string]$TaskName = "ResetPhysicalNICsToDHCP",
    [string]$NetOpsTaskName = "AddUsersToNetworkOperators"
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------
# 1. Elevation Check
# --------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ([Environment]::UserInteractive -and $PSCommandPath) {
        try {
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            Start-Process -FilePath "PowerShell.exe" -ArgumentList $arguments -Verb RunAs
            exit 0
        } catch {}
    }
    Write-Error "Deployment requires elevated administrative privileges. Please run as Administrator or deploy via SYSTEM (e.g. FOG Snapin)."
    exit 1
}

$TaskDescription = "Restores all physical network adapters to DHCP at startup and complete user logoff."
$ScriptPath = Join-Path -Path $InstallDir -ChildPath "Reset-NetworkAdapters.ps1"
$LogPath    = Join-Path -Path $InstallDir -ChildPath "dhcpfixer.log"

$NetOpsTaskDescription = "Adds all standard and logging-on users to Network Configuration Operators at startup and logon."
$NetOpsScriptPath = Join-Path -Path $InstallDir -ChildPath "Add-UsersToNetworkOperators.ps1"
$NetOpsLogPath    = Join-Path -Path $InstallDir -ChildPath "netconfigops.log"

try {
    # --------------------------------------------------------------------
    # 2. Stage Directory in Program Files
    # --------------------------------------------------------------------
    # Default C:\Program Files permissions already restrict Standard Users/Students to Read & Execute.
    if (-not (Test-Path -Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

# --------------------------------------------------------------------
# 3. Write the Maintenance Script to Disk
# --------------------------------------------------------------------
$ScriptContent = @'
# ====================================================================
# Reset-NetworkAdapters.ps1 - Physical NICs DHCP & Stack Restorer
# ====================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$LogFile   = Join-Path -Path $scriptDir -ChildPath "dhcpfixer.log"

# Overwrites log on each run to record the latest execution time and result
try {
    $header = "====================================================`r`nDHCPFixer - Last Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n===================================================="
    Set-Content -Path $LogFile -Value $header -Force -ErrorAction SilentlyContinue
} catch {}

function Write-FixerLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry  = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $LogFile -Value $logEntry -Force -ErrorAction SilentlyContinue
    } catch {}
}

Write-FixerLog "Starting physical adapter DHCP and TCP/IP stack verification."

try {
    # Retrieve only physical network adapters (ignores WSL, Hyper-V, VirtualBox, VMware, VPNs)
    $adapters = @(Get-NetAdapter -Physical -IncludeHidden -ErrorAction SilentlyContinue)
    Write-FixerLog "Found $($adapters.Count) physical adapter(s)."

    $anyAdapterChanged = $false

    foreach ($nic in $adapters) {
        $idx       = $nic.InterfaceIndex
        $name      = $nic.Name
        $guid      = $nic.InterfaceGuid
        $changed   = $false
        $tcpipKey  = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        $tcpip6Key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$guid"

        # 1. Re-enable adapter if disabled
        if ($nic.AdminStatus -ne 'Up') {
            Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue
            $changed = $true
            Write-FixerLog "Enabled disabled adapter: $name"
        }

        # 2. Re-enable IPv4 and IPv6 bindings
        foreach ($comp in @('ms_tcpip', 'ms_tcpip6')) {
            $binding = Get-NetAdapterBinding -Name $name -ComponentID $comp -ErrorAction SilentlyContinue
            if ($binding -and -not $binding.Enabled) {
                Enable-NetAdapterBinding -Name $name -ComponentID $comp -ErrorAction SilentlyContinue
                $changed = $true
                Write-FixerLog "Enabled $comp binding on: $name"
            }
        }

        if ($changed) {
            Start-Sleep -Seconds 1
        }

        # 3. Clean manual IPv4 & IPv6 addresses from both ActiveStore and PersistentStore
        foreach ($store in @('ActiveStore', 'PersistentStore')) {
            $manualIpv4 = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -PrefixOrigin Manual -PolicyStore $store -ErrorAction SilentlyContinue
            if ($manualIpv4) {
                $manualIpv4 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                $changed = $true
                Write-FixerLog "Removed manual IPv4 address(es) from $store on: $name"
            }

            $manualIpv6 = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv6 -PrefixOrigin Manual -PolicyStore $store -ErrorAction SilentlyContinue
            if ($manualIpv6) {
                $manualIpv6 | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                $changed = $true
                Write-FixerLog "Removed manual IPv6 address(es) from $store on: $name"
            }
        }

        # 4. Purge static DefaultGateway and static IP residues from Registry
        $staticGws = @()
        if (Test-Path -Path $tcpipKey) {
            $regVals = Get-ItemProperty -Path $tcpipKey -ErrorAction SilentlyContinue
            if ($regVals) {
                $staticGws = @($regVals.DefaultGateway | Where-Object { $_ -and $_ -ne "0.0.0.0" })
                if ($staticGws.Count -gt 0) {
                    Remove-ItemProperty -Path $tcpipKey -Name "DefaultGateway" -Force -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $tcpipKey -Name "DefaultGatewayMetric" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Purged static DefaultGateway from registry on: $name ($($staticGws -join ', '))"
                }
                $staticIps = @($regVals.IPAddress | Where-Object { $_ -and $_ -ne "0.0.0.0" })
                if ($staticIps.Count -gt 0) {
                    Remove-ItemProperty -Path $tcpipKey -Name "IPAddress" -Force -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $tcpipKey -Name "SubnetMask" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Purged static IPAddress/SubnetMask from registry on: $name ($($staticIps -join ', '))"
                }
                if ($regVals.NameServer -and $regVals.NameServer -ne "") {
                    Set-ItemProperty -Path $tcpipKey -Name "NameServer" -Value "" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Reset static IPv4 NameServer in registry on: $name"
                }
            }
        }

        if (Test-Path -Path $tcpip6Key) {
            $regVals6 = Get-ItemProperty -Path $tcpip6Key -ErrorAction SilentlyContinue
            if ($regVals6) {
                $staticGws6 = @($regVals6.DefaultGateway | Where-Object { $_ -and $_ -ne "::" })
                if ($staticGws6.Count -gt 0) {
                    Remove-ItemProperty -Path $tcpip6Key -Name "DefaultGateway" -Force -ErrorAction SilentlyContinue
                    Remove-ItemProperty -Path $tcpip6Key -Name "DefaultGatewayMetric" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Purged static IPv6 DefaultGateway from registry on: $name ($($staticGws6 -join ', '))"
                }
                $staticIps6 = @($regVals6.IPAddress | Where-Object { $_ -and $_ -ne "::" })
                if ($staticIps6.Count -gt 0) {
                    Remove-ItemProperty -Path $tcpip6Key -Name "IPAddress" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Purged static IPv6 IPAddress from registry on: $name ($($staticIps6 -join ', '))"
                }
                if ($regVals6.NameServer -and $regVals6.NameServer -ne "") {
                    Set-ItemProperty -Path $tcpip6Key -Name "NameServer" -Value "" -Force -ErrorAction SilentlyContinue
                    $changed = $true
                    Write-FixerLog "Reset static IPv6 NameServer in registry on: $name"
                }
            }
        }

        # 5. Check interface TCP/IP stack settings and ensure DHCP is enabled
        $ipV4If = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipV4If -and ($ipV4If.Dhcp -ne 'Enabled' -or $ipV4If.Forwarding -ne 'Disabled' -or $ipV4If.AutomaticMetric -ne 'Enabled')) {
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled -AutomaticMetric Enabled -Forwarding Disabled -WeakHostReceive Disabled -WeakHostSend Disabled -ErrorAction SilentlyContinue
            $changed = $true
        }
        $ipV6If = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction SilentlyContinue
        if ($ipV6If -and ($ipV6If.Dhcp -ne 'Enabled' -or $ipV6If.RouterDiscovery -ne 'Enabled' -or $ipV6If.Forwarding -ne 'Disabled' -or $ipV6If.AutomaticMetric -ne 'Enabled')) {
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv6 -Dhcp Enabled -RouterDiscovery Enabled -AutomaticMetric Enabled -Forwarding Disabled -WeakHostReceive Disabled -WeakHostSend Disabled -ErrorAction SilentlyContinue
            $changed = $true
        }

        # Ensure netsh address source is set to DHCP
        netsh interface ipv4 set address name="$name" source=dhcp | Out-Null

        # 6. Purge persistent static routes from PersistentStore for this adapter
        $persistentRoutes = Get-NetRoute -InterfaceIndex $idx -PolicyStore PersistentStore -ErrorAction SilentlyContinue
        if ($persistentRoutes) {
            $persistentRoutes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            $changed = $true
            Write-FixerLog "Removed persistent route(s) from PersistentStore on: $name"
        }

        # 7. Purge custom static routes and rogue default gateways from ActiveStore
        $activeRoutes = Get-NetRoute -InterfaceIndex $idx -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        if ($activeRoutes) {
            # Retrieve legitimate DHCP default gateway(s) from registry
            $dhcpGws = @((Get-ItemProperty -Path $tcpipKey -ErrorAction SilentlyContinue).DhcpDefaultGateway | Where-Object { $_ })

            # A. Custom static routes (non-default routes with Protocol Static/NetMgmt that are not Local interface routes)
            $customStaticRoutes = $activeRoutes | Where-Object {
                $_.Protocol -in @('NetMgmt', 'Static') -and
                $_.DestinationPrefix -notin @('0.0.0.0/0', '::/0')
            }
            if ($customStaticRoutes) {
                $customStaticRoutes | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                $changed = $true
                Write-FixerLog "Removed custom static route(s) from ActiveStore on: $name"
            }

            # B. Default gateway routes: purge any rogue default gateway that does NOT match DhcpDefaultGateway
            $defaultRoutes = $activeRoutes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }
            foreach ($defRoute in $defaultRoutes) {
                $isRogue = $false
                if ($dhcpGws.Count -gt 0 -and $defRoute.NextHop -notin $dhcpGws) {
                    $isRogue = $true
                } elseif ($staticGws.Count -gt 0 -and $defRoute.NextHop -in $staticGws) {
                    $isRogue = $true
                }

                if ($isRogue) {
                    $rogueGw = $defRoute.NextHop
                    $defRoute | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    & route.exe delete 0.0.0.0 $rogueGw 2>$null
                    $changed = $true
                    Write-FixerLog "Removed rogue default gateway route ($rogueGw) from ActiveStore on: $name"
                }
            }
        }

        # 8. Reset DNS & WINS servers and suffixes
        Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction SilentlyContinue
        Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix "" -RegisterThisConnectionsAddress $true -UseSuffixWhenRegistering $false -ErrorAction SilentlyContinue
        netsh interface ipv4 set dnsservers name="$name" source=dhcp | Out-Null
        netsh interface ipv6 set dnsservers name="$name" source=dhcp | Out-Null
        netsh interface ipv4 set winsservers name="$name" source=dhcp | Out-Null

        # 9. Reset WMI / CIM Alternate IP configuration, gateways, and NetBIOS settings
        $wmiNic = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $idx" -ErrorAction SilentlyContinue
        if ($wmiNic) {
            if ($wmiNic.DefaultIPGateway) {
                $dhcpGw = (Get-ItemProperty -Path $tcpipKey -ErrorAction SilentlyContinue).DhcpDefaultGateway
                $nonDhcpGws = @($wmiNic.DefaultIPGateway | Where-Object { $_ -and (-not $dhcpGw -or $_ -notin $dhcpGw) })
                if ($nonDhcpGws.Count -gt 0) {
                    Invoke-CimMethod -InputObject $wmiNic -MethodName "SetGateways" -Arguments @{ DefaultIPGateway = @() } -ErrorAction SilentlyContinue | Out-Null
                    $changed = $true
                    Write-FixerLog "Cleared static default gateway(s) via WMI on: $name"
                }
            }
            if (-not $wmiNic.DHCPEnabled) {
                Invoke-CimMethod -InputObject $wmiNic -MethodName "EnableDHCP" -ErrorAction SilentlyContinue | Out-Null
                $changed = $true
                Write-FixerLog "Enabled DHCP via WMI on: $name"
            }
            # Reset NetBIOS over TCP/IP to Default (0 = Use NetBIOS setting from DHCP server)
            Invoke-CimMethod -InputObject $wmiNic -MethodName "SetTcpipNetbios" -Arguments @{ TcpipNetbiosOptions = [uint32]0 } -ErrorAction SilentlyContinue | Out-Null
        }

        # Flush neighbor/ARP cache for this physical adapter
        Remove-NetNeighbor -InterfaceIndex $idx -Confirm:$false -ErrorAction SilentlyContinue
        & arp.exe -d * 2>$null

        # If any static settings were cleared or restored, restart the adapter to reload the clean stack
        if ($changed) {
            Write-FixerLog "Settings changed on $name. Restarting adapter to reload stack."
            Restart-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue
            $anyAdapterChanged = $true

            # Wait for physical link to recover
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 15) {
                Start-Sleep -Seconds 1
                $currentNic = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
                if ($currentNic -and $currentNic.Status -eq 'Up' -and $currentNic.MediaConnectionState -eq 'Connected') {
                    break
                }
            }
        }
    }

    # 10. Purge all persistent static routes added via 'route -p add' from the registry
    foreach ($svc in @('Tcpip', 'Tcpip6')) {
        $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc\Parameters\PersistentRoutes"
        if (Test-Path -Path $regKey) {
            $props = (Get-Item -Path $regKey -ErrorAction SilentlyContinue).Property
            if ($props) {
                foreach ($p in $props) {
                    Remove-ItemProperty -Path $regKey -Name $p -Force -ErrorAction SilentlyContinue
                    $anyAdapterChanged = $true
                    Write-FixerLog "Purged persistent registry route '$p' ($svc)."
                }
            }
        }
    }

    # 11. Clean up global TCP/IP parameters, proxy, DNS cache, and NetBIOS cache
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "SearchList" -Value "" -ErrorAction SilentlyContinue
    netsh winhttp reset proxy | Out-Null
    netsh int tcp set global autotuninglevel=normal | Out-Null
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    nbtstat -R | Out-Null

    # 12. Check IP state and renew DHCP leases if required
    foreach ($nic in $adapters) {
        $idx  = $nic.InterfaceIndex
        $name = $nic.Name
        $guid = $nic.InterfaceGuid
        $tcpipKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"

        # Check current physical link state
        $currentNic = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
        if ($currentNic -and $currentNic.MediaConnectionState -eq 'Disconnected') {
            Write-FixerLog "NOTICE: Physical cable is disconnected on adapter '$name'." "WARN"
            continue
        }

        # Check existing IPv4 address
        $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $validIp = $ips | Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "0.0.0.0" }

        # Only request DHCP lease renewal if settings were changed or if the adapter has no valid IP (e.g. on APIPA)
        if ($anyAdapterChanged -or -not $validIp) {
            Write-FixerLog "Requesting DHCP lease renewal on: $name..."
            & ipconfig.exe /renew "$name" | Out-Null
            & ipconfig.exe /renew6 "$name" | Out-Null

            # Poll for up to 12 seconds for lease assignment without repeatedly hammering renew
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 12) {
                Start-Sleep -Seconds 2
                $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
                $validIp = $ips | Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "0.0.0.0" }
                if ($validIp) {
                    break
                }
            }
        }

        # Final IPv4 verification
        $ips = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $validIp = $ips | Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "0.0.0.0" }

        if ($validIp) {
            Write-FixerLog "SUCCESS: Adapter '$name' active with IPv4 address: $($validIp[0].IPAddress)" "INFO"
        } else {
            $currentIp = ($ips | Select-Object -First 1).IPAddress
            Write-FixerLog "NOTICE: Adapter '$name' finished with IPv4 '$currentIp' (check DHCP server or physical connection)." "WARN"
        }

        # Post-DHCP check: purge any lingering non-DHCP default gateways
        $dhcpGw = (Get-ItemProperty -Path $tcpipKey -ErrorAction SilentlyContinue).DhcpDefaultGateway
        $activeDefaultRoutes = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
        foreach ($gwRoute in $activeDefaultRoutes) {
            if ($dhcpGw -and ($gwRoute.NextHop -notin $dhcpGw) -and ($gwRoute.NextHop -ne '0.0.0.0')) {
                Write-FixerLog "Purging lingering non-DHCP default gateway '$($gwRoute.NextHop)' from ActiveStore on: $name" "WARN"
                $gwRoute | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                & route.exe delete 0.0.0.0 $gwRoute.NextHop 2>$null
            }
        }

        # Log final active default gateways
        $finalGateways = @(Get-NetRoute -InterfaceIndex $idx -DestinationPrefix "0.0.0.0/0" -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop)
        if ($finalGateways) {
            Write-FixerLog "Active IPv4 Default Gateway(s) on '$name': $(($finalGateways -join ', '))" "INFO"
        }

        # IPv6 verification
        $ipv6Addrs = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction SilentlyContinue)
        $globalIpv6 = $ipv6Addrs | Where-Object { $_.IPAddress -and $_.IPAddress -notlike "fe80:*" -and $_.IPAddress -ne "::" -and $_.IPAddress -ne "::1" }
        if ($globalIpv6) {
            Write-FixerLog "SUCCESS: Adapter '$name' acquired global IPv6 address: $($globalIpv6[0].IPAddress)" "INFO"
        } else {
            $linkLocal = $ipv6Addrs | Where-Object { $_.IPAddress -like "fe80:*" } | Select-Object -First 1
            if ($linkLocal) {
                Write-FixerLog "INFO: Adapter '$name' IPv6 link-local active: $($linkLocal.IPAddress) (no global IPv6 router/DHCPv6 detected)." "INFO"
            }
        }
    }
}
catch {
    Write-FixerLog "Execution error: $_" "ERROR"
}
'@

Set-Content -Path $ScriptPath -Value $ScriptContent -Encoding UTF8 -Force

# --------------------------------------------------------------------
# 4. Write the Network Configuration Operators Script to Disk
# --------------------------------------------------------------------
$NetOpsScriptContent = @'
# ====================================================================
# Add-UsersToNetworkOperators.ps1
# ====================================================================
# Purpose:
# Automatically grants standard users membership in the local
# "Network Configuration Operators" (S-1-5-32-556) group upon startup
# and logon, enabling students to configure network adapters during labs.
# ====================================================================
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$LogFile   = Join-Path -Path $scriptDir -ChildPath "netconfigops.log"

# Overwrites log on each run to record the latest execution time and result
try {
    $header = "====================================================`r`nNetConfigOps - Last Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n===================================================="
    Set-Content -Path $LogFile -Value $header -Force -ErrorAction SilentlyContinue
} catch {}

function Write-OpsLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry  = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $LogFile -Value $logEntry -Force -ErrorAction SilentlyContinue
    } catch {}
}

Write-OpsLog "Starting Network Configuration Operators membership verification."

try {
    # Detect if the workstation is Azure AD / Entra ID joined
    $isAzureAdJoined = [bool](Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo" -ErrorAction SilentlyContinue)

    # BUILTIN\Network Configuration Operators well-known SID is S-1-5-32-556 across all OS languages
    $targetSid = "S-1-5-32-556"
    $group = Get-LocalGroup -SID $targetSid -ErrorAction SilentlyContinue
    if (-not $group) {
        try {
            $trans = (New-Object System.Security.Principal.SecurityIdentifier($targetSid)).Translate([System.Security.Principal.NTAccount]).Value
            $gName = if ($trans -match '\\(.*)$') { $matches[1] } else { $trans }
            $group = Get-LocalGroup -Name $gName -ErrorAction SilentlyContinue
        } catch {}
    }

    if (-not $group) {
        Write-OpsLog "ERROR: Could not locate Network Configuration Operators group (SID: $targetSid)." "ERROR"
        exit 1
    }

    $groupName = $group.Name

    # Retrieve current group members to avoid redundant add calls
    $currentMembers = @(Get-LocalGroupMember -SID $targetSid -ErrorAction SilentlyContinue)
    $existingSids  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $existingNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($m in $currentMembers) {
        if ($m.SID -and $m.SID.Value) {
            [void]$existingSids.Add($m.SID.Value)
        }
        if ($m.Name) {
            [void]$existingNames.Add($m.Name)
            if ($m.Name -match '\\(.*)$') {
                [void]$existingNames.Add($matches[1])
            }
        }
    }

    function Add-CandidateUser {
        param(
            [string]$AccountName,
            [string]$SidString = $null
        )

        if ([string]::IsNullOrWhiteSpace($AccountName) -and [string]::IsNullOrWhiteSpace($SidString)) {
            return
        }

        # Check if already a member by SID or Name
        if ($SidString -and $existingSids.Contains($SidString)) {
            return
        }
        if ($AccountName) {
            if ($existingNames.Contains($AccountName)) {
                return
            }
            if ($AccountName -match '\\(.*)$' -and $existingNames.Contains($matches[1])) {
                return
            }
        }

        $added = $false

        # Attempt 1: Add via Account Name (e.g. AzureAD\Username, DOMAIN\Username, LocalUser)
        if ($AccountName) {
            try {
                Add-LocalGroupMember -SID $targetSid -Member $AccountName -ErrorAction Stop
                if ($SidString) { [void]$existingSids.Add($SidString) }
                [void]$existingNames.Add($AccountName)
                if ($AccountName -match '\\(.*)$') { [void]$existingNames.Add($matches[1]) }
                $added = $true
                Write-OpsLog "Added '$AccountName' to '$groupName'."
            } catch {}
        }

        # Attempt 2: Add via SID string
        if (-not $added -and $SidString) {
            try {
                Add-LocalGroupMember -SID $targetSid -Member $SidString -ErrorAction Stop
                [void]$existingSids.Add($SidString)
                if ($AccountName) {
                    [void]$existingNames.Add($AccountName)
                    if ($AccountName -match '\\(.*)$') { [void]$existingNames.Add($matches[1]) }
                }
                $added = $true
                Write-OpsLog "Added '$AccountName' (SID: $SidString) to '$groupName'."
            } catch {}
        }

        # Attempt 3: If AzureAD joined and AccountName lacks domain prefix, try with "AzureAD\"
        if (-not $added -and $isAzureAdJoined -and $AccountName -and ($AccountName -notmatch '^[^\\]+\\')) {
            $aadCandidate = "AzureAD\$AccountName"
            try {
                Add-LocalGroupMember -SID $targetSid -Member $aadCandidate -ErrorAction Stop
                if ($SidString) { [void]$existingSids.Add($SidString) }
                [void]$existingNames.Add($aadCandidate)
                [void]$existingNames.Add($AccountName)
                $added = $true
                Write-OpsLog "Added '$aadCandidate' to '$groupName'."
            } catch {}
        }

        # Attempt 4: net localgroup fallback
        if (-not $added -and $AccountName) {
            $netOut = & net.exe localgroup "$groupName" "$AccountName" /add 2>&1
            if ($LASTEXITCODE -eq 0 -or $netOut -match "already a member|már tagja") {
                if ($SidString) { [void]$existingSids.Add($SidString) }
                [void]$existingNames.Add($AccountName)
                if ($AccountName -match '\\(.*)$') { [void]$existingNames.Add($matches[1]) }
                $added = $true
                Write-OpsLog "Added '$AccountName' to '$groupName' via net localgroup."
            } else {
                Write-OpsLog "WARN: Failed to add '$AccountName' to '$groupName': $netOut" "WARN"
            }
        }
    }

    # 1. Enumerate all active local user accounts (exclude built-in Guest 501, DefaultAccount 503, WDAG 504)
    $localUsers = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object {
        $_.Enabled -and $_.SID.Value -notmatch '-(501|503|504)$'
    })
    foreach ($u in $localUsers) {
        Add-CandidateUser -AccountName $u.Name -SidString $u.SID.Value
    }

    # 2. Enumerate existing user profile folders from registry ProfileList (historical logons)
    # Includes local/domain accounts (S-1-5-21-*) and Azure AD / Microsoft Entra accounts (S-1-12-1-*)
    $profileKeys = @(Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue |
        Where-Object { ($_.PSChildName -like "S-1-5-21-*" -or $_.PSChildName -like "S-1-12-1-*") -and $_.PSChildName -notmatch '-(500|501|503|504)$' })

    foreach ($p in $profileKeys) {
        $s = $p.PSChildName
        $accName = $null
        try {
            $accName = (New-Object System.Security.Principal.SecurityIdentifier($s)).Translate([System.Security.Principal.NTAccount]).Value
        } catch {}

        if (-not $accName) {
            try {
                $profPath = (Get-ItemProperty $p.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
                if ($profPath) {
                    $leaf = Split-Path -Path $profPath -Leaf
                    $accName = if ($s -like "S-1-12-1-*" -or $isAzureAdJoined) { "AzureAD\$leaf" } else { $leaf }
                }
            } catch {}
        }

        Add-CandidateUser -AccountName $accName -SidString $s
    }

    # 3. Enumerate home folders in C:\Users (covers Azure AD and local profiles)
    $excludedFolders = @(
        'Public', 'Default', 'Default User', 'All Users',
        'systemprofile', 'LocalService', 'NetworkService', 'WDAGUtilityAccount'
    )
    $userDirs = @(Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -and ($excludedFolders -notcontains $_.Name) -and ($_.Name -notlike "defaultuser*")
    })

    foreach ($dir in $userDirs) {
        $folderName = $dir.Name
        $resolvedSid = $null
        $resolvedName = $null

        # 3a. Check matching ProfileList entry by ProfileImagePath
        $matchingProfile = $profileKeys | Where-Object {
            $pPath = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            $pPath -and ((Split-Path -Path $pPath -Leaf) -eq $folderName)
        } | Select-Object -First 1

        if ($matchingProfile) {
            $resolvedSid = $matchingProfile.PSChildName
            try {
                $resolvedName = (New-Object System.Security.Principal.SecurityIdentifier($resolvedSid)).Translate([System.Security.Principal.NTAccount]).Value
            } catch {}
        }

        # 3b. Try translating NTAccount names if not already resolved via ProfileList
        if (-not $resolvedName) {
            $cands = if ($isAzureAdJoined) {
                @("AzureAD\$folderName", "Azure\$folderName", "$folderName", "$env:COMPUTERNAME\$folderName")
            } else {
                @("$folderName", "$env:COMPUTERNAME\$folderName", "AzureAD\$folderName")
            }
            foreach ($cand in $cands) {
                try {
                    $nt = New-Object System.Security.Principal.NTAccount($cand)
                    $sidObj = $nt.Translate([System.Security.Principal.SecurityIdentifier])
                    $resolvedSid = $sidObj.Value
                    $resolvedName = $cand
                    break
                } catch {}
            }
        }

        # 3c. Fallback account name if translation didn't succeed
        if (-not $resolvedName) {
            $resolvedName = if ($isAzureAdJoined) { "AzureAD\$folderName" } else { $folderName }
        }

        Add-CandidateUser -AccountName $resolvedName -SidString $resolvedSid
    }

    # 4. Directly capture newly logging on users from TerminalServices Event 21 / 25
    # (Extracts the user immediately from the event that triggered the scheduled task, even on first-time profile creation)
    try {
        $recentLogons = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
            Id        = 21, 25
            StartTime = (Get-Date).AddMinutes(-5)
        } -MaxEvents 5 -ErrorAction SilentlyContinue)

        foreach ($evt in $recentLogons) {
            if ($evt.Properties -and $evt.Properties.Count -gt 0) {
                $logonUser = $evt.Properties[0].Value
                if ($logonUser -and $logonUser -notin @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')) {
                    Add-CandidateUser -AccountName $logonUser
                }
            }
        }
    } catch {}

    # 5. Detect all active interactive desktop sessions (explorer.exe processes)
    $explorers = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in $explorers) {
        try {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
            if ($owner -and $owner.User -and $owner.User -notin @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')) {
                $userFull = if ($owner.Domain) { "$($owner.Domain)\$($owner.User)" } else { $owner.User }
                Add-CandidateUser -AccountName $userFull
            }
        } catch {}
    }

    # 6. Check Win32_ComputerSystem.UserName
    $csUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($csUser) {
        Add-CandidateUser -AccountName $csUser
    }

    # 7. If domain-joined, add the domain's 'Domain Users' group
    $compSys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($compSys -and $compSys.PartOfDomain -and $compSys.Domain) {
        $domainUsersGroup = "$($compSys.Domain)\Domain Users"
        Add-CandidateUser -AccountName $domainUsersGroup
    }

    Write-OpsLog "Completed Network Configuration Operators membership verification."
}
catch {
    Write-OpsLog "Execution error: $_" "ERROR"
}
'@

Set-Content -Path $NetOpsScriptPath -Value $NetOpsScriptContent -Encoding UTF8 -Force

# --------------------------------------------------------------------
    # 5. Provision Scheduled Tasks
    # --------------------------------------------------------------------
    # Disable Windows Fast Startup so Startup triggers on cold boots
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type DWord -Force

    $Principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    # ----------------------------------------------------------------
    # Primary Task: Restore Physical NICs to DHCP (Startup + Logoff)
    # ----------------------------------------------------------------
    $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    # Triggers:
    # 1. At Startup only (no repetition interval; will not run periodically during classes)
    $StartupTrigger = New-ScheduledTaskTrigger -AtStartup

    # 2. On Complete User Logoff only (TerminalServices Event 23)
    #    Screen lock (Win+L / screensaver) generates Event 24 (Disconnect) or Event 4800, NOT Event 23.
    #    Therefore, screen lock during a 30-minute break will NOT trigger this task.
    $CimTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $LogoffTriggerCim = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $LogoffTriggerCim.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"><Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[Provider[@Name=''Microsoft-Windows-TerminalServices-LocalSessionManager''] and (EventID=23)]]</Select></Query></QueryList>'
    $LogoffTriggerCim.Enabled = $true

    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Description $TaskDescription `
        -Action $Action `
        -Trigger @($StartupTrigger, $LogoffTriggerCim) `
        -Principal $Principal `
        -Settings $Settings `
        -Force | Out-Null

    # ----------------------------------------------------------------
    # Secondary Task: Add Users to Network Configuration Operators (Startup + Logon)
    # ----------------------------------------------------------------
    $NetOpsAction = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$NetOpsScriptPath`""
    $NetOpsStartupTrigger = New-ScheduledTaskTrigger -AtStartup

    # Event 21 (Session logon) and Event 25 (Session reconnect) from TerminalServices-LocalSessionManager
    $LogonTriggerCim = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $LogonTriggerCim.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"><Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[Provider[@Name=''Microsoft-Windows-TerminalServices-LocalSessionManager''] and (EventID=21 or EventID=25)]]</Select></Query></QueryList>'
    $LogonTriggerCim.Enabled = $true

    Get-ScheduledTask -TaskName $NetOpsTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

    Register-ScheduledTask `
        -TaskName $NetOpsTaskName `
        -Description $NetOpsTaskDescription `
        -Action $NetOpsAction `
        -Trigger @($NetOpsStartupTrigger, $LogonTriggerCim) `
        -Principal $Principal `
        -Settings $Settings `
        -Force | Out-Null

    # Run the user permission script immediately to populate current users
    try {
        & $NetOpsScriptPath
    } catch {}

    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host " SUCCESS: DHCPFixer Suite deployed successfully!" -ForegroundColor Green
    Write-Host " Primary Task:   $TaskName" -ForegroundColor Green
    Write-Host "   Triggers:     Startup + Complete Logoff (SYSTEM Account)" -ForegroundColor Green
    Write-Host "   Script:       $ScriptPath" -ForegroundColor Green
    Write-Host "   Log:          $LogPath" -ForegroundColor Green
    Write-Host " Secondary Task: $NetOpsTaskName" -ForegroundColor Green
    Write-Host "   Triggers:     Startup + User Logon (All Users)" -ForegroundColor Green
    Write-Host "   Script:       $NetOpsScriptPath" -ForegroundColor Green
    Write-Host "   Log:          $NetOpsLogPath" -ForegroundColor Green
    Write-Host "====================================================" -ForegroundColor Green
    Write-Host ""
    exit 0
}
catch {
    Write-Host ""
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host " DEPLOYMENT FAILED!" -ForegroundColor Red
    Write-Host " Error Details: $_" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Error "Deployment failed. Details: $_"
    exit 1
}