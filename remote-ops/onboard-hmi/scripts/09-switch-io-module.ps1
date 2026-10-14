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
    for. The client's own production guard that rejects loopback applies to
    wireToGate.host and vehicleSafety.endpoint, not to IO.

    Since workspace#51 this script refuses -Simulator when the server the
    vehicle talks to is in the production phase of the cutover
    (PRODUCTION_IO_LOOPBACK): the port in the vehicle's own wireToGate.port
    says which server, the MVP's 58005 counts as production without asking,
    and any other is read from the v2 instance's installed-instance.json on
    -ServerSshAlias (ProductionIo.psm1, one read-only ssh). A record that
    cannot be read is refused rather than taken for trial. In trial the
    simulator is allowed as before. -RealModule is never refused by it.

    This is a post-deployment change to the file on the vehicle. Since
    workspace#28 a later run of 06-deploy-onboard-hmi.ps1 no longer puts the
    real module back behind your back: on a vehicle this script pointed at the
    simulator, 06 refuses unless it is told which one is wanted --
    -KeepCurrentIo keeps the simulator (only host and port are kept; the rest
    of ioModule follows the new package), -UseSiteIo switches to the real
    module, which needs the user's authorisation and someone on site. Before
    that change, 06 silently rendered the site file's module and this script
    had to be run again after every deployment.

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
    [int] $RealModulePort = 502,
    [string] $ServerSshAlias = 'factory01'
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
    serverPort = `$c.wireToGate.port
    onboard = [bool](Get-Process 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue)
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

Write-Host ''
Write-Host "Onboard IO target is currently $($state.host):$($state.port)."

# workspace#51: never onto the simulator while the vehicle's server is in production (the MVP's 58005 included).
if (-not $RealModule) {
    Import-Module (Join-Path $PSScriptRoot 'ProductionIo.psm1') -Force
    $serverPort = 0
    if (-not [int]::TryParse([string] $state.serverPort, [ref]$serverPort) -or $serverPort -le 0) {
        throw "SERVER_PHASE_UNREAD: the vehicle's wireToGate.port reads '$($state.serverPort)', so which server it talks to is unknown. Refusing rather than guessing."
    }
    $serverPhase = (Read-ServerCutoverPhase -ServerSshAlias $ServerSshAlias -OnboardPort $serverPort).Phase
    Write-Step "Server phase (onboard port $serverPort): $serverPhase"
    Assert-ProductionIoTarget -Phase $serverPhase -IoHost $targetHost -IoPort $targetPort -SiteHost ([string] $site.ioModule.host)
}

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
