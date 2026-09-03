#Requires -Version 7
<#
.SYNOPSIS
    Turns the factory server into an NTP server for the plant machines. Runs ON
    the factory server.

.DESCRIPTION
    The AGV onboard machines have no reachable time source: the NTP server they
    were configured with (172.19.206.222) runs RIoT but answers nothing on 123,
    the gateway resets the connection, and they have no DNS to reach a public
    pool. So their clocks free-run, and agv01 was found 158 days fast on
    2026-09-03.

    That is not a cosmetic problem. The onboard vehicle-safety gate compares the
    server's observedAt against the vehicle's own clock inside a 5-second
    window (VehicleSafetySignal.IsFresh: `now - ObservedAt <= maxAge`). A clock
    that far off makes every projection look stale, so a clean session can never
    leave RecoveryRequired / DEPARTURE_SAFETY_NOT_READY -- the gate fails closed
    on a fact that has nothing to do with the vehicle.

    This host is the natural source: the vehicles already reach it (that is how
    they reach ControlServer), and its own clock agrees with the control host.

.PARAMETER Disable
    Undo: turn the NTP server off again and remove the firewall rule.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch] $Disable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$providerKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer'
$configKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$ruleName = 'NTP Server (UDP 123)'

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run elevated.'
}

if ($Disable) {
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Disable the NTP server')) { return }
    Set-ItemProperty -Path $providerKey -Name 'Enabled' -Value 0 -Type DWord
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    Restart-Service w32time
    Write-Step 'NTP server disabled and firewall rule removed.'
    return
}

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Enable the NTP server on UDP 123')) { return }

Write-Step ("Local time is {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))

# AnnounceFlags 5 makes this host advertise itself as a reliable time source
# even though it does not itself sync from an upstream server -- this network
# has no upstream that answers. Without it the service starts, listens, and
# tells every client it is unsynchronised, which clients then ignore.
Set-ItemProperty -Path $configKey -Name 'AnnounceFlags' -Value 5 -Type DWord
Set-ItemProperty -Path $providerKey -Name 'Enabled' -Value 1 -Type DWord
Write-Step 'NtpServer provider enabled, AnnounceFlags set to 5'

Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
    -Protocol UDP -LocalPort 123 -Profile Any | Out-Null
Write-Step 'Firewall open for UDP 123'

Restart-Service w32time
Start-Sleep -Seconds 3

# The service has to be running and the provider enabled; a client that gets no
# answer falls back to free-running, which is the failure this fixes.
$enabled = (Get-ItemProperty -Path $providerKey).Enabled
$status = (Get-Service w32time).Status
Write-Step ("w32time {0}, NtpServer.Enabled={1}" -f $status, $enabled)
if ($status -ne 'Running' -or $enabled -ne 1) {
    throw 'The NTP server did not come up as expected.'
}

Write-Step 'Done. Point the vehicles at this host:'
Write-Step '  w32tm /config /manualpeerlist:"172.19.205.222,0x9" /syncfromflags:manual /update'
