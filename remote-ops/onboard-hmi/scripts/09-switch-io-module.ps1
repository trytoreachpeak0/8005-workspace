#Requires -Version 7
<#
.SYNOPSIS
    Points the onboard client's IO at either the slot simulator or the real
    Modbus module. Runs ON the control host.

.DESCRIPTION
    Changes exactly two fields of the deployed appsettings.json on the vehicle:
    ioModule.host and ioModule.port.

      -Simulator   127.0.0.1:1502  the simulator installed by 08-deploy-slots-simulator.ps1
      -RealModule  <site>:502      the address in remote-ops/onboard-hmi/config/site-<alias>.json

    Loopback is allowed here and is in fact the product's own default --
    IoModuleSettings.Validate only rejects placeholder values, and the real
    module address is the line commented out in the repository's appsettings.json.
    This is not a workaround; it is the configuration the simulator was written
    for. The production guard that rejects loopback applies to wireToGate.host
    and vehicleSafety.endpoint, not to IO.

    This is a post-deployment change to the file on the vehicle, so a later run
    of 06-deploy-onboard-hmi.ps1 renders the site file again and puts the real
    module address back. Re-run this afterwards if the simulator is still wanted.

    The client reads its configuration once at startup, so a change while it is
    running is invisible until restart -- and swapping the IO target under a
    running client is exactly the kind of thing that produces an unexplainable
    IO trace. The script refuses while it is running.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Simulator')]
param(
    [Parameter(ParameterSetName = 'Simulator')]
    [switch] $Simulator,

    [Parameter(ParameterSetName = 'RealModule', Mandatory = $true)]
    [switch] $RealModule,

    [string] $SshAlias = 'agv01',
    [string] $SitePath,
    [string] $ConfigPath = 'C:\8005\OnboardHmi\appsettings.json',
    [int] $SimulatorPort = 1502,
    [int] $RealModulePort = 502
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Onboard {
    param([string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

if (-not $SitePath) {
    $SitePath = Join-Path $PSScriptRoot "../config/site-$SshAlias.json"
}
if (-not (Test-Path -LiteralPath $SitePath)) {
    throw "No site file at $SitePath. The real module address is per vehicle and is never guessed."
}
$site = Get-Content -Raw -LiteralPath $SitePath | ConvertFrom-Json

if ($RealModule) {
    $targetHost = $site.ioModule.host
    $targetPort = $RealModulePort
    $label = 'the real Modbus IO module'
    if ([string]::IsNullOrWhiteSpace($targetHost) -or $targetHost -like 'REPLACE_*') {
        throw "Site file $SitePath has no real ioModule.host."
    }
}
else {
    $targetHost = '127.0.0.1'
    $targetPort = $SimulatorPort
    $label = 'the slot IO simulator on this vehicle'
}

$state = Invoke-Onboard @"
`$c = Get-Content -LiteralPath '$ConfigPath' -Raw | ConvertFrom-Json
[pscustomobject]@{
    host    = `$c.ioModule.host
    port    = `$c.ioModule.port
    onboard = [bool](Get-Process 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue)
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Host ''
Write-Host "Onboard IO target is currently $($state.host):$($state.port)."

if ($state.onboard) {
    throw "SQCD.Agv.Wpf is running on $SshAlias. Close it from the vehicle's own desktop session first -- the client reads this file once, at startup."
}
if ($state.host -eq $targetHost -and $state.port -eq $targetPort) {
    Write-Host "Already $targetHost`:$targetPort. Nothing to do." -ForegroundColor Yellow
    return
}

if (-not $PSCmdlet.ShouldProcess("${SshAlias}:$ConfigPath", "Point onboard IO at $label ($targetHost`:$targetPort)")) {
    Write-Host 'Not changed.' -ForegroundColor Yellow
    return
}

# Round-tripping reformats the file, so the change is verified field by field
# against the original rather than trusted.
$result = Invoke-Onboard @"
`$path = '$ConfigPath'
`$backup = "`$path.bak-`$([DateTime]::Now.ToString('yyyyMMddHHmmss'))"
Copy-Item -LiteralPath `$path -Destination `$backup
`$before = Get-Content -LiteralPath `$path -Raw
`$c = `$before | ConvertFrom-Json
`$c.ioModule.host = '$targetHost'
`$c.ioModule.port = $targetPort
Set-Content -LiteralPath `$path -Value (`$c | ConvertTo-Json -Depth 12) -Encoding utf8NoBOM

`$expected = `$before | ConvertFrom-Json
`$expected.ioModule.host = '$targetHost'
`$expected.ioModule.port = $targetPort
`$actual = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json) | ConvertTo-Json -Depth 12 -Compress
[pscustomobject]@{
    backup = `$backup
    drift  = (`$expected | ConvertTo-Json -Depth 12 -Compress) -ne `$actual
    host   = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json).ioModule.host
    port   = (Get-Content -LiteralPath `$path -Raw | ConvertFrom-Json).ioModule.port
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Step "Backup: $($result.backup)"
if ($result.drift) {
    throw "More than ioModule.host and ioModule.port changed. Restore $($result.backup) on $SshAlias."
}
Write-Step "Onboard IO target is now $($result.host):$($result.port) -- $label"
Write-Host ''
Write-Host 'Takes effect the next time the onboard client starts.' -ForegroundColor Yellow
