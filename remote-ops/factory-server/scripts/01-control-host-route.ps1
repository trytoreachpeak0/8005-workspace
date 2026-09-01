#Requires -Version 7

<#
  01-control-host-route.ps1 - Keep factory-server traffic out of the Clash TUN.

  THE PROBLEM THIS SOLVES:
    Clash for Windows runs in TUN mode on the control workstation and installs
    a 128.0.0.0/1 route (metric 0) on its "Clash" adapter. 172.19.205.222 falls
    under that prefix, so every packet aimed at the factory server enters the
    tunnel. Clash's rule table happens to send it back out DIRECT
    (IP-CIDR,172.16.0.0/12,DIRECT), so the channel works -- but the TUN answers
    ICMP itself and completes TCP handshakes locally before dialling upstream.
    Measured on 2026-09-01: ping to a nonexistent 172.19.199.199 succeeded at
    0 ms, and ports 7, 9999, 31337, 54321 on the server all reported OPEN.
    Every reachability probe from this machine was therefore meaningless.

    The onboard HMIs are unaffected: Wi-Fi carries an on-link 172.19.162.0/24
    route, which is more specific than 128.0.0.0/1 and wins on its own.

  THE FIX:
    Add the same kind of on-link-beating route for the server's subnet. Longest
    prefix match puts 172.19.205.0/24 ahead of Clash's /1, so the traffic never
    reaches the TUN adapter at all. This needs no Clash configuration change and
    survives subscription updates, profile switches, and Clash being stopped.

  WHAT THIS CHANGES ON THIS MACHINE (nothing on the server):
    One IPv4 route, written to both the ActiveStore (effective immediately) and
    the PersistentStore (survives reboot). Nothing else.

  Usage (control workstation, PowerShell 7 as Administrator):
      pwsh -ExecutionPolicy Bypass -File .\01-control-host-route.ps1
      pwsh -ExecutionPolicy Bypass -File .\01-control-host-route.ps1 -Remove
#>

[CmdletBinding()]
param(
    # Subnet the factory server lives on.
    [string]$Prefix = '172.19.205.0/24',

    # Subnet of the enterprise LAN this workstation is on. Used to locate the
    # physical adapter and its gateway, so nothing is hardcoded to "Wi-Fi".
    [string]$LocalPrefix = '172.19.162.0/24',

    # Roll the route back out again.
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  FAIL $m" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Must run elevated. Routing table changes need an administrator token.'
}

$probeIp = ($Prefix -replace '\.0/\d+$', '.222')

# route.exe wants a dotted mask, not a prefix length.
$network, $prefixLen = $Prefix -split '/'
$mask = ([IPAddress](([uint32]::MaxValue -shl (32 - [int]$prefixLen)) -band [uint32]::MaxValue)).GetAddressBytes()
[Array]::Reverse($mask)
$mask = ($mask -join '.')

Step "Route to $probeIp before the change"
$before = Find-NetRoute -RemoteIPAddress $probeIp | Select-Object -First 1
Write-Host ("  source {0} via {1}" -f $before.IPAddress, $before.InterfaceAlias)

# ------------------------------------------------------------------- remove
if ($Remove) {
    Step "Removing $Prefix from the live table and from PersistentRoutes"
    $existed = [bool](Get-NetRoute -DestinationPrefix $Prefix -ErrorAction SilentlyContinue)
    # One `route delete` clears both, the same way `route -p add` set both.
    $out = & route.exe delete $network mask $mask 2>&1
    if ($existed) { Ok 'removed' } else { Warn "no route was present; route.exe said: $out" }

    $after = Find-NetRoute -RemoteIPAddress $probeIp | Select-Object -First 1
    Write-Host ("`n  now: source {0} via {1}" -f $after.IPAddress, $after.InterfaceAlias)
    Write-Host '  (back through the Clash TUN if that is what it says)' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------- add
Step "Locating the adapter that owns $LocalPrefix"
$localNet = ($LocalPrefix -split '/')[0] -replace '\.0$', '.'
$localAddr = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like "$localNet*" } |
    Select-Object -First 1
if (-not $localAddr) { Die "No local address on $LocalPrefix. Is this machine on the enterprise LAN?" }
Ok "$($localAddr.InterfaceAlias) has $($localAddr.IPAddress)"

$gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $localAddr.InterfaceIndex -ErrorAction SilentlyContinue |
    Select-Object -First 1).NextHop
if (-not $gateway) { Die "No default gateway on $($localAddr.InterfaceAlias); cannot pick a next hop." }
Ok "next hop $gateway"

Step "Adding $Prefix via $gateway on $($localAddr.InterfaceAlias)"

# route.exe rather than New-NetRoute. On this workstation (Windows 11 25H2)
# `New-NetRoute -PolicyStore PersistentStore` fails with "Invalid parameter
# PolicyStore PersistentStore" whichever way the interface is named, so the
# route would vanish on reboot. `route -p add` writes the live table and the
# PersistentRoutes registry key in one call, and is idempotent once the
# existing entry is dropped first.
#
# No metric is set: longest prefix match is decided before metrics are
# compared, so this /24 beats Clash's /1 whatever either metric says.
& route.exe delete $network mask $mask 2>&1 | Out-Null   # ignore "not found"
$add = & route.exe -p add $network mask $mask $gateway IF $($localAddr.InterfaceIndex) 2>&1
if ($LASTEXITCODE -ne 0) { Die "route add failed: $add" }
Ok 'added to the live table and to PersistentRoutes'

# ------------------------------------------------------------------- verify
Step 'Verifying the TUN is now bypassed'
$after = Find-NetRoute -RemoteIPAddress $probeIp | Select-Object -First 1
Write-Host ("  source {0} via {1}" -f $after.IPAddress, $after.InterfaceAlias)
if ($after.InterfaceAlias -eq $localAddr.InterfaceAlias) {
    Ok 'traffic now leaves on the physical adapter'
} else {
    Warn "still going out via $($after.InterfaceAlias); check for a competing route"
}

# The whole point of the change: probes have to start telling the truth. While
# the TUN was in the path it answered for EVERY address in the subnet, so the
# honest test is that at least some addresses now go silent. Do not assume any
# single address is free -- 172.19.205.199 and .250 turned out to be real hosts.
Step 'Sanity check: some addresses in that subnet must now go unanswered'
$ghosts  = 3, 77, 199, 250 | ForEach-Object { $Prefix -replace '\.0/\d+$', ".$_" }
$replied = @($ghosts | Where-Object {
    Test-Connection -TargetName $_ -Count 1 -TimeoutSeconds 2 -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Success'
})
if ($replied.Count -eq $ghosts.Count) {
    Warn 'every probed address replied -- something is still intercepting. Do not trust probe results.'
} else {
    Ok "$($ghosts.Count - $replied.Count) of $($ghosts.Count) probed addresses are silent, as real subnets behave"
    if ($replied) { Write-Host "  (these are live hosts: $($replied -join ', '))" }
}

Write-Host @"

=====================================================================
 DONE. $Prefix -> $gateway on $($localAddr.InterfaceAlias).
 Written to ActiveStore (live now) and PersistentStore (survives reboot).

 UNDO:
   pwsh -ExecutionPolicy Bypass -File .\01-control-host-route.ps1 -Remove
 or by hand, elevated:
   route delete $network mask $mask
=====================================================================
"@ -ForegroundColor White
