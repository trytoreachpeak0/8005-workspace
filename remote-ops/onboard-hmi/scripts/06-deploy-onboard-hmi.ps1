#Requires -Version 7
<#
.SYNOPSIS
    Deploys the OnboardHmi half of a WIRE_TO_GATE release package to one AGV
    onboard machine. Runs on the control host.

.DESCRIPTION
    The same joint package that 15-deploy-control-server.ps1 installs on the
    factory server carries the onboard half. This script delivers it:

        GitHub artifact -> control host -> scp -> agv01 -> staged, configured

    It stops before starting anything. Three reasons, and none of them is
    caution for its own sake:

      * the target is a production vehicle that moves. Starting the client is
        an action with a physical consequence, and RELEASE-CANDIDATE.md
        section 11 requires a per-occasion authorisation and an on-site safety
        GO for exactly that class of action;
      * SQCD.Agv.Wpf is an interactive WPF application, not a service. There is
        no stop-swap-start; it needs a desktop session, and sshd gives us
        session 0, where a window is owned by a desktop nobody is looking at;
      * the readiness gate belongs to a person. Section 8 says a clean session
        only reaches Ready when the vehicle-safety projection returns
        motionState=STOPPED with fresh evidence. Watching that is the point of
        having someone there.

    Deployment still never starts anything. Since 2026-09-04 starting is its own
    step rather than a walk to the vehicle: 10-start-onboard-stack.ps1 brings up
    the simulator and the client, in that order, in the interactive session. It
    narrows the first two reasons above -- the authorisation is now expressed by
    somebody deliberately invoking that script, and nothing invokes it as a side
    effect of this one -- and changes nothing about the third.

    What this script does do is everything up to that line: verify the package,
    fill in the site values, reject a configuration the client would refuse at
    startup, place the binaries, set the credentials, and prove from the vehicle
    itself that the server it was pointed at answers.

.PARAMETER RunId
    GitHub Actions run to deploy. Omit to take the most recent successful
    `release` run in the ControlServer repository -- the joint package is built
    there.

.PARAMETER PackagePath
    Deploy a zip already on disk instead of downloading one.

.PARAMETER SshAlias
    Which vehicle. One alias per car; the site file is named after it.

.PARAMETER Force
    Proceed even though the onboard client is currently running. Refuses by
    default: a running client means the vehicle may be mid-journey.

.PARAMETER WhatIf
    Stage, verify and render the configuration locally, then stop before the
    vehicle is touched. The rendered configuration is printed.

.EXAMPLE
    ./06-deploy-onboard-hmi.ps1 -WhatIf

.EXAMPLE
    ./06-deploy-onboard-hmi.ps1 -RunId 12345678
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Download')]
    [string] $RunId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [string] $PackagePath,

    [string] $SshAlias = 'agv01',

    [string] $Repository = 'trytoreachpeak0/8005-agv-control-server',

    [string] $SitePath,

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),

    [string] $ControlServerHost = '172.19.205.222',

    [ValidateRange(1, 65535)]
    [int] $OnboardPort = 58005,

    [ValidateRange(1, 65535)]
    [int] $HealthPort = 58007,

    [string] $StagingRoot = 'C:\temp\agv\onboard-staging',

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scriptRoot = $PSScriptRoot
if (-not $SitePath) {
    $SitePath = Join-Path (Split-Path -Parent $scriptRoot) "config\site-$SshAlias.json"
}
# .Replace rather than -replace: the right-hand side of -replace is a regular
# expression, where a lone backslash is an error rather than a backslash.
$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-Ssh {
    param([string[]] $Arguments, [switch] $Quiet)
    $output = & ssh $SshAlias @Arguments 2>&1
    if (-not $Quiet) { $output | ForEach-Object { Write-Host "  $_" } }
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE)" }
    return $output
}

Write-Step "OnboardHmi deployment to $SshAlias"

# ---------------------------------------------------------------- site values ---

if (-not (Test-Path -LiteralPath $SitePath)) {
    throw @"
No site file at $SitePath.
Copy config\site.example.json to that name and fill in the vehicle's
values. Refusing to guess: onboardInstanceId must stay stable across
deployments, and the rule-gateway and IO-module addresses are wiring facts.
"@
}
$site = Get-Content -Raw -LiteralPath $SitePath | ConvertFrom-Json
Write-Step "Site values from $(Split-Path -Leaf $SitePath)"

$installRoot = $site.install.root
$siteReplacements = [ordered]@{
    REPLACE_CONTROL_SERVER_IP        = $ControlServerHost
    REPLACE_CONTROL_SERVER_HOST      = "${ControlServerHost}:$HealthPort"
    REPLACE_WITH_STABLE_UUID         = $site.wireToGate.onboardInstanceId
    REPLACE_WITH_EXPECTED_VEHICLE_KEY = $site.vehicleSafety.expectedVehicleKey
    REPLACE_RULE_SERVER_IP           = $site.ruleGateway.host
    REPLACE_IO_MODULE_IP             = $site.ioModule.host
}
foreach ($entry in $siteReplacements.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value) -or $entry.Value -like 'REPLACE_*') {
        throw "Site value for $($entry.Key) is still a placeholder in $SitePath."
    }
}

# ------------------------------------------------------------------- secrets ---

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "No secret store at $SecretPath. Run ../factory-server/scripts/control-server/Set-ControlServerSecret.ps1 -Import first."
}
$secrets = Import-Clixml -LiteralPath $SecretPath
$plain = @{}
foreach ($key in @('OnboardCredential', 'OperatorId')) {
    if (-not $secrets.ContainsKey($key) -or -not $secrets[$key]) {
        throw "Secret '$key' is missing from $SecretPath."
    }
    $plain[$key] = [System.Net.NetworkCredential]::new('', $secrets[$key]).Password
}
Write-Step 'Secrets loaded from the DPAPI store'

# -------------------------------------------------------------- vehicle state ---

# A running client means the vehicle may be mid-journey. Replacing its binaries
# underneath it is the one failure mode this whole script exists to avoid.
$running = Invoke-Ssh -Quiet @("if (Get-Process SQCD.Agv.Wpf -ErrorAction SilentlyContinue) { 'RUNNING' } else { 'STOPPED' }")
if ($running -contains 'RUNNING') {
    if (-not $Force) {
        throw "SQCD.Agv.Wpf is running on $SshAlias. Stop it from the vehicle's own desktop session, then rerun. Use -Force only if you know the vehicle is idle."
    }
    Write-Warning "SQCD.Agv.Wpf is running on $SshAlias and -Force was given."
}
Write-Step "Onboard client state on ${SshAlias}: $($running -join ' ')"

# ------------------------------------------------------------------- package ---

# -WhatIf:$false on every local staging operation below. SupportsShouldProcess
# puts the whole script into WhatIf mode, which would otherwise skip creating
# this directory and then fail reading from it. WhatIf here means "do not touch
# the vehicle", not "do not use a scratch directory" -- and staging for real is
# what lets the dry run verify the hash and render the configuration, which is
# the whole point of running it.
$localStage = Join-Path $env:TEMP "onboard-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $localStage -Force -WhatIf:$false | Out-Null

try {
    if ($PSCmdlet.ParameterSetName -eq 'Local') {
        $zip = (Resolve-Path -LiteralPath $PackagePath).Path
        Write-Step "Using local package $zip"
    } else {
        if (-not $RunId) {
            Write-Step "Finding the most recent successful release run in $Repository"
            $RunId = & gh run list --repo $Repository --workflow release.yml `
                --status success --limit 1 --json databaseId --jq '.[0].databaseId'
            if ($LASTEXITCODE -ne 0 -or -not $RunId) {
                throw "No successful release run found in $Repository."
            }
        }
        Write-Step "Downloading artifact from run $RunId"
        & gh run download $RunId --repo $Repository --dir $localStage
        if ($LASTEXITCODE -ne 0) { throw "gh run download failed (exit $LASTEXITCODE)" }

        $zip = @(Get-ChildItem -LiteralPath $localStage -Filter '*.zip' -Recurse -File) |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $zip) { throw "Run $RunId produced no zip artifact." }
    }

    $hashFile = "$zip.sha256"
    if (-not (Test-Path -LiteralPath $hashFile)) {
        throw "Missing hash file $hashFile. Refusing to deploy an unverified package."
    }
    $expected = ((Get-Content -LiteralPath $hashFile -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        throw "Package hash mismatch on the control host. Expected $expected, got $actual."
    }
    Write-Step "Package hash verified ($actual)"

    $unpacked = Join-Path $localStage 'unpacked'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force -WhatIf:$false
    $onboardDirectory = Join-Path $unpacked 'onboard-hmi'
    if (-not (Test-Path -LiteralPath $onboardDirectory -PathType Container)) {
        throw "The package has no onboard-hmi directory: $onboardDirectory"
    }

    $manifest = Get-Content -Raw -LiteralPath (Join-Path $unpacked 'release-manifest.json') | ConvertFrom-Json
    $onboardCommit = $manifest.components.onboardHmi.commit
    Write-Step "OnboardHmi commit:    $onboardCommit"
    Write-Step "ControlServer commit: $($manifest.components.controlServer.commit)"

    # ------------------------------------------------------- configuration ---

    # The client reads only appsettings.json from its own directory -- there is
    # no appsettings.<environment>.json layering. So the production template is
    # rendered here and shipped as appsettings.json outright, replacing the
    # development default that ships in the package with wireToGate.enabled
    # false and an unresolvable endpoint.
    $templatePath = Join-Path $onboardDirectory 'appsettings.Production.template.json'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "The package carries no appsettings.Production.template.json."
    }
    $rendered = Get-Content -Raw -LiteralPath $templatePath
    foreach ($entry in $siteReplacements.GetEnumerator()) {
        $rendered = $rendered.Replace($entry.Key, $entry.Value)
    }

    $leftover = @([regex]::Matches($rendered, 'REPLACE_[A-Z0-9_]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($leftover.Count -gt 0) {
        throw "The rendered configuration still contains placeholders: $($leftover -join ', ')"
    }

    # Read the result back rather than trusting the substitution. Every check
    # below is a startup failure the client would otherwise hit on the vehicle,
    # with a person standing next to it. They mirror
    # SQCD.Agv.Infrastructure/Configuration.cs -- when that file's rules change,
    # these have to follow, or this script starts passing configurations the
    # client rejects.
    $config = $rendered | ConvertFrom-Json

    # The two top-level identities come from the site file, not from the
    # template -- which ships them as AGV-8005-01 / OBU-8005-01. Apply them
    # before validating, or every check below reads the template's sample values
    # and no site file can ever pass.
    $config.agvId = $site.agvId
    $config.onboardInstanceId = $site.onboardInstanceId

    # OnboardSettings.IsPlaceholderValue, reproduced exactly. Note that the two
    # sample identities are themselves placeholders: a site file copied from the
    # example and left with agvId AGV-8005-01 renders a configuration that looks
    # complete, carries no REPLACE_ token, and still throws at startup with
    # "Production环境必须配置真实且稳定的AgvId和OnboardInstanceId".
    $placeholderExact = @('AGV-8005-01', 'OBU-8005-01')
    $placeholderSubstrings = @('REPLACE', 'EXAMPLE', 'CHANGEME', 'YOUR_', 'YOUR-', 'TODO')
    function Test-Placeholder([string]$Value) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
        $trimmed = $Value.Trim()
        if ($placeholderExact -contains $trimmed) { return $true }
        foreach ($token in $placeholderSubstrings) {
            if ($trimmed -like "*$token*") { return $true }
        }
        return $false
    }

    # WireToGateSettings.IsForbiddenProductionHost: a loopback address is a
    # development leftover, and on the vehicle it would point the client at
    # itself rather than at the server.
    # Not $Host as the parameter name: that is an automatic variable in
    # PowerShell, and shadowing it inside a function is a trap rather than a
    # convenience.
    function Test-ForbiddenHost([string]$Candidate) {
        if (Test-Placeholder $Candidate) { return $true }
        if ($Candidate -in @('localhost', '0.0.0.0', '::')) { return $true }
        $address = [ipaddress]::Any
        if ([ipaddress]::TryParse($Candidate, [ref]$address)) {
            return [ipaddress]::IsLoopback($address)
        }
        return $false
    }

    foreach ($pair in @(
        @{ Name = 'agvId';                       Value = $config.agvId }
        @{ Name = 'onboardInstanceId';           Value = $config.onboardInstanceId }
        @{ Name = 'ruleGateway.host';            Value = $config.ruleGateway.host }
        @{ Name = 'ioModule.host';               Value = $config.ioModule.host }
        @{ Name = 'vehicleSafety.expectedVehicleKey'; Value = $config.vehicleSafety.expectedVehicleKey }
    )) {
        if (Test-Placeholder $pair.Value) {
            throw "$($pair.Name) is '$($pair.Value)', which the client treats as a placeholder and rejects in Production."
        }
    }

    if (Test-ForbiddenHost $config.wireToGate.host) {
        throw "wireToGate.host is '$($config.wireToGate.host)', which the client forbids in Production (loopback, wildcard or placeholder)."
    }

    # WireToGateSettings.Validate: the instance id must parse as a Guid in "D"
    # form, and the build commit must be 40 hex digits that are not all zero.
    $parsedGuid = [guid]::Empty
    if (-not [guid]::TryParseExact($config.wireToGate.onboardInstanceId, 'D', [ref]$parsedGuid)) {
        throw "wireToGate.onboardInstanceId '$($config.wireToGate.onboardInstanceId)' is not a Guid in 'D' form (8-4-4-4-12); the client rejects it."
    }

    # Production refuses to fall back to the legacy rule protocol.
    if (-not $config.wireToGate.enabled) {
        throw 'wireToGate.enabled must stay true; Production forbids falling back to the rule protocol alone.'
    }

    #   the client hard-rejects the TLS-era keys by name, not by value, and
    #   throws WIRE_TO_GATE配置键<键名>已移除 at startup if either is present;
    foreach ($banned in @('useTls', 'serverCertificateSha256')) {
        if ($config.wireToGate.PSObject.Properties.Name -contains $banned) {
            throw "The rendered configuration carries the removed TLS-era key wireToGate.$banned. Delete the key; setting it to false is not enough."
        }
    }
    #   VehicleSafetySettings.Validate accepts only the http scheme;
    if ($config.vehicleSafety.endpoint -notmatch '^http://') {
        throw "vehicleSafety.endpoint must be a plaintext http URI, got: $($config.vehicleSafety.endpoint)"
    }
    # Only now is the [uri] cast safe; the same forbidden-host rule applies to
    # the projection endpoint as to the transport host.
    $safetyHost = ([uri]$config.vehicleSafety.endpoint).Host
    if (Test-ForbiddenHost $safetyHost) {
        throw "vehicleSafety.endpoint points at '$safetyHost', which the client forbids in Production (loopback, wildcard or placeholder)."
    }
    #   the safety gate is not optional;
    if (-not $config.vehicleSafety.enabled) {
        throw 'vehicleSafety.enabled must stay true.'
    }
    #   and onboardBuildCommit is reported to the server during the handshake,
    #   so it must be this package's onboard build and not the older commit the
    #   development default carries.
    if ($config.wireToGate.onboardBuildCommit -ne $onboardCommit) {
        throw "wireToGate.onboardBuildCommit is $($config.wireToGate.onboardBuildCommit) but this package built $onboardCommit."
    }

    $renderedPath = Join-Path $localStage 'appsettings.json'
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $renderedPath -Encoding utf8NoBOM -WhatIf:$false
    Write-Step 'Configuration rendered and validated'

    if (-not $PSCmdlet.ShouldProcess($SshAlias, "Deploy onboard $($onboardCommit.Substring(0,7)) to $installRoot")) {
        Write-Step 'WhatIf: stopping before the vehicle is touched.'
        Write-Host (Get-Content -Raw -LiteralPath $renderedPath)
        return
    }

    # ------------------------------------------------------------ transfer ---

    Write-Step "Staging on $SshAlias"
    Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$StagingRoot' | Out-Null; 'ready'")

    $payload = Join-Path $localStage 'onboard-payload.zip'
    Copy-Item -LiteralPath $renderedPath -Destination (Join-Path $onboardDirectory 'appsettings.json') -Force
    Remove-Item -LiteralPath (Join-Path $onboardDirectory 'appsettings.Production.template.json') -Force
    Compress-Archive -Path (Join-Path $onboardDirectory '*') -DestinationPath $payload -CompressionLevel Optimal
    $payloadHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-Step "Copying payload ($([math]::Round((Get-Item $payload).Length / 1MB, 1)) MB)"
    $remoteZip = "$StagingRoot\onboard-payload.zip"
    & scp -q $payload "${SshAlias}:$(& $toPosix $remoteZip)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the payload failed (exit $LASTEXITCODE)" }

    # -------------------------------------------------------------- place ---

    # The previous generation is kept beside the install root rather than
    # deleted: the vehicle is the one machine where a bad deployment cannot be
    # fixed by redeploying over a fast link.
    $place = @"
`$ErrorActionPreference = 'Stop'
`$actual = (Get-FileHash -LiteralPath '$remoteZip' -Algorithm SHA256).Hash.ToLowerInvariant()
if (`$actual -ne '$payloadHash') { throw "Payload hash mismatch on the vehicle. Expected $payloadHash, got `$actual." }
'hash verified'

`$root = '$installRoot'
`$previous = "`$root.previous"
`$incoming = "`$root.incoming"
if (Test-Path -LiteralPath `$incoming) { Remove-Item -LiteralPath `$incoming -Recurse -Force }
Expand-Archive -LiteralPath '$remoteZip' -DestinationPath `$incoming -Force
if (Test-Path -LiteralPath `$previous) { Remove-Item -LiteralPath `$previous -Recurse -Force }
if (Test-Path -LiteralPath `$root) { Move-Item -LiteralPath `$root -Destination `$previous }
Move-Item -LiteralPath `$incoming -Destination `$root
"placed: `$root"

[Environment]::SetEnvironmentVariable('CONTROL_SERVER_ONBOARD_CREDENTIAL', '$($plain['OnboardCredential'])', 'Machine')
[Environment]::SetEnvironmentVariable('CONTROL_SERVER_OPERATOR_ID', '$($plain['OperatorId'])', 'Machine')
'credentials set (machine scope)'

# On the public desktop rather than one user's: whoever starts this is the
# operator logged in at the vehicle, not necessarily the account that deployed
# it. Recreated every deployment so the target follows the install root.
`$exe = Join-Path `$root 'SQCD.Agv.Wpf.exe'
if (Test-Path -LiteralPath `$exe) {
    `$lnkPath = 'C:\Users\Public\Desktop\8005 AGV 车载端.lnk'
    `$shell = New-Object -ComObject WScript.Shell
    `$lnk = `$shell.CreateShortcut(`$lnkPath)
    `$lnk.TargetPath = `$exe
    `$lnk.WorkingDirectory = `$root
    `$lnk.Description = '8005 AGV 车载上位机（WIRE_TO_GATE）'
    `$lnk.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject(`$shell)
    "shortcut: `$lnkPath"
} else {
    "shortcut skipped: `$exe not found"
}

# Read the body, do not trust a handshake. This is the check that decides
# whether the client will leave RecoveryRequired, and it can only be made from
# the vehicle.
try {
    `$safety = Invoke-WebRequest -Uri 'http://${ControlServerHost}:$HealthPort/api/onboard/v1/vehicle-safety' ``
        -Headers @{ Authorization = 'Bearer $($plain['OnboardCredential'])' } ``
        -NoProxy -TimeoutSec 15 -UseBasicParsing
    "vehicle-safety `$(`$safety.StatusCode): `$(`$safety.Content)"
} catch {
    "vehicle-safety UNREACHABLE: `$(`$_.Exception.Message)"
}
"@
    $placePath = Join-Path $localStage 'place-onboard.ps1'
    Set-Content -LiteralPath $placePath -Value $place -Encoding utf8NoBOM
    $remotePlace = "$StagingRoot\place-onboard.ps1"
    & scp -q $placePath "${SshAlias}:$(& $toPosix $remotePlace)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the placement script failed (exit $LASTEXITCODE)" }

    Write-Step 'Placing the payload on the vehicle'
    $placeOutput = Invoke-Ssh @("pwsh -NoProfile -File `"$remotePlace`"; Remove-Item -LiteralPath `"$remotePlace`" -Force")

    # ------------------------------------------------------------- hand off ---

    Write-Host ''
    Write-Step 'Staged. NOT started -- that part is yours.'
    Write-Host ''
    Write-Host '  On the vehicle, from a desktop session:' -ForegroundColor Yellow
    Write-Host "    $installRoot\SQCD.Agv.Wpf.exe" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Before you do:' -ForegroundColor DarkGray
    Write-Host '    - confirm the vehicle is where you think it is and is meant to move;' -ForegroundColor DarkGray
    Write-Host '    - the vehicle-safety line above must be 200 with a matching vehicleKey,' -ForegroundColor DarkGray
    Write-Host '      motionState=STOPPED and fresh observedAt, or a clean session stays in' -ForegroundColor DarkGray
    Write-Host '      RecoveryRequired / DEPARTURE_SAFETY_NOT_READY. That is the gate working,' -ForegroundColor DarkGray
    Write-Host '      not a bug;' -ForegroundColor DarkGray
    Write-Host "    - the previous build is at $installRoot.previous if you need it back." -ForegroundColor DarkGray

    if ($placeOutput -match 'UNREACHABLE') {
        Write-Warning 'The vehicle could not reach the ControlServer projection endpoint.'
        Write-Warning "Deploy the server half first: ../factory-server/scripts/15-deploy-control-server.ps1"
    }

} finally {
    if (Test-Path -LiteralPath $localStage) {
        Remove-Item -LiteralPath $localStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    $plain.Clear()
}
