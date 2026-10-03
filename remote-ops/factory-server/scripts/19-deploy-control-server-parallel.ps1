#Requires -Version 7
<#
.SYNOPSIS
    Deploys the v2 parallel ControlServer instance to factory01, beside the running MVP
    service. Runs on the control host.

.DESCRIPTION
    control-server#262. The delivery half of the parallel CD path, and a deliberate twin of
    15-deploy-control-server.ps1 rather than an extension of it:

        GitHub artifact -> control host -> scp -> factory01 -> parallel install

    Two scripts rather than one parameterised script, because the parameter that would select
    between them is the parameter that decides whether a mistake lands on the production
    deployment. Keeping them separate means the MVP command cannot install the parallel
    instance and this command cannot install over the MVP -- the second half of that is also
    enforced, by Assert-ParallelInstanceDefinition, which refuses the production service name,
    install roots, ports and vehicle outright.

    The runner still does not deploy. win11-01 is a Hyper-V guest of this very host; giving it
    a key into its own host would put a production-server administrator credential on CI. Same
    reason as the MVP path and as mes-ingest-cd.md.

    See remote-ops/factory-server/docs/wire-to-gate-parallel-cd.md.

    TWIN SCRIPT. The MVP equivalent is 15-deploy-control-server.ps1, and the server-side twins
    are control-server/Install-ControlServerRemote.ps1 (MVP) and the control-server
    repository's scripts/parallel/Install-ParallelInstanceLocal.ps1 (this one). Separate on
    purpose, so a fix to one does not reach the other by itself: when a change here touches
    the machine rather than this instance, look at the twin too. The first case was found in
    review -- both server-side scripts carried the same unprefixed '*.incoming-*' cleanup, and
    each deleted the other's staging directory.

.PARAMETER RunId
    GitHub Actions release run to deploy. Omit to take the most recent successful one on the
    v2 line.

.PARAMETER PackagePath
    Deploy a zip already on disk instead of downloading one. The matching .sha256 must sit
    beside it.

.PARAMETER Rollback
    Swap the previous parallel package back in. Downloads nothing, and never touches the MVP.

.PARAMETER ControlServerRepository
    A clean 8005-agv-control-server checkout or worktree at the commit being deployed. The
    instance definition, the validator module, the on-server installer and the FakeMesIngest
    source all come from here -- so that what is deployed and what validates it are the same
    revision.

.PARAMETER FakeMesIngestZip
    A FakeMesIngest package already built by scripts/parallel/Publish-FakeMesIngest.ps1. Omit
    to build one from -ControlServerRepository.

.PARAMETER Uninstall
    Remove the parallel instance: the double's task and directory, the V2 firewall rules, the
    service and install root (through the product uninstaller), both package generations and
    the staging directory. Every item comes from the same footprint list the installer uses.
    Data -- the SQLite data root, the upgrade backups, the ops results -- is kept unless
    -RemoveData. Also the recovery from a half-finished first install, which has no previous
    generation to roll back to.

.PARAMETER RemoveData
    With -Uninstall: also remove the data root, the backups and the ops directory.

.PARAMETER WhatIf
    Stage and verify everything, print what would run, and stop before touching the server.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Download')]
    [string] $RunId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [string] $PackagePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    [Parameter(Mandatory = $true, ParameterSetName = 'Uninstall')]
    [switch] $Uninstall,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $RemoveData,

    [Parameter(Mandatory = $true)]
    [string] $ControlServerRepository,

    [string] $InstanceDefinitionPath,

    [string] $FakeMesIngestZip,

    [string] $SshAlias = 'factory01',

    [string] $Repository = 'trytoreachpeak0/8005-agv-control-server',

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),

    [switch] $AllowRiotCreateDispatch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string] $Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-Ssh {
    param([string[]] $Arguments)
    $output = & ssh $SshAlias @Arguments 2>&1
    $output | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed (exit $LASTEXITCODE)" }
    return $output
}

# ------------------------------------------------- repository and definition ---

$repoRoot = (Resolve-Path -LiteralPath $ControlServerRepository).Path
$parallelScripts = Join-Path $repoRoot 'scripts\parallel'
if (-not (Test-Path -LiteralPath $parallelScripts -PathType Container)) {
    throw "No scripts/parallel directory in $repoRoot. Is this an 8005-agv-control-server checkout on fp/v2-impl or later?"
}
Import-Module (Join-Path $parallelScripts 'ParallelInstance.psm1') -Force

if (-not $InstanceDefinitionPath) {
    $InstanceDefinitionPath = Join-Path $parallelScripts 'instance-factory01-v2.json'
}
$definition = Read-ParallelInstanceDefinition -Path $InstanceDefinitionPath

# Refused here, before a package is downloaded and before anything is copied to a machine that
# is serving customers. The same assertion runs again on the server: the control host proves
# the file it read is deployable, the server proves the file it received is.
#
# Except for -Uninstall. An uninstall removes what was installed, from the definition the server
# recorded at install time, and that script asserts it there. Here only opsRoot is needed -- to
# find the server-side scripts -- and it is held to the same allowlist a directory the uninstaller
# may delete is. Requiring the whole local file to be deployable would make an instance that
# was installed impossible to remove the moment this machine's copy gained a placeholder.
if ($Uninstall) {
    $opsProblem = Test-ParallelInstanceOwnedPath -Path ([string] $definition['opsRoot'])
    if ($opsProblem) { throw "opsRoot in $InstanceDefinitionPath $opsProblem." }
    Write-Step "Uninstall: using opsRoot $($definition['opsRoot']) from $InstanceDefinitionPath; the server asserts its own installed definition."
} else {
    $null = Assert-ParallelInstanceDefinition -Definition $definition -AllowRiotCreateDispatch:$AllowRiotCreateDispatch
    # A checkout from before control-server#454 validates a definition without the clearance exit
    # sections and deploys an instance that silently has no exit. Say so instead.
    foreach ($section in @('vehicleFaultRecovery', 'fieldOperatorRoles')) {
        if (-not $definition.Contains($section)) {
            throw "$InstanceDefinitionPath has no '$section' section. -ControlServerRepository is older than control-server#454; deploy from a checkout that has it."
        }
    }
    Write-Step "Instance definition accepted: $($definition['instanceId']) (from $InstanceDefinitionPath)"
}

$opsRoot = [string] $definition['opsRoot']
$stagingRoot = [string] $definition['stagingRoot']
$packageRoot = [string] $definition['packageRoot']
$healthBindAddress = [string] $definition['healthBindAddress']
$healthPort = [int] $definition['healthPort']
$listenAddress = [string] $definition['listenAddress']
$onboardPort = [int] $definition['onboardPort']

Write-Step "Target: $SshAlias  service '$($definition['serviceName'])'"
Write-Step "Vehicle: $($definition['journeyRuntime']['agvId']) ($($definition['journeyRuntime']['vehicleKey']))"
Write-Step ("RouteGraph: enabled={0} mapId={1}   RiotCreateDispatch: enabled={2}" -f
    $definition['routeGraph']['enabled'], $definition['routeGraph']['mapId'],
    $definition['riotCreateDispatch']['enabled'])
if (-not $Uninstall) {
    # control-server#454: the two sections the manual station clearance exit needs, from the definition.
    Write-Step ("Clearance exit: VehicleFaultRecovery enabled={0}   FieldOperatorRoles roster={1} onboardEntryDeclared={2}" -f
        $definition['vehicleFaultRecovery']['enabled'], $definition['fieldOperatorRoles']['path'],
        $definition['fieldOperatorRoles']['onboardClearanceEntryDeclared'])
}

function Copy-ParallelScripts {
    <#
        The files the server-side scripts need, copied together every time. The modules and the
        scripts are one unit: an installer that ran against a stale module would validate a
        definition by rules the definition was not written to.
    #>
    Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$opsRoot' | Out-Null")
    foreach ($name in @('ParallelInstance.psm1', 'ParallelHost.psm1', 'Install-ParallelInstanceLocal.ps1',
                         'Uninstall-ParallelInstanceLocal.ps1', 'Start-FakeMesIngestResident.ps1')) {
        & scp -q (Join-Path $parallelScripts $name) "${SshAlias}:$(& $toPosix "$opsRoot\$name")"
        if ($LASTEXITCODE -ne 0) { throw "scp of $name failed (exit $LASTEXITCODE)" }
    }
    # The product uninstaller, from the same revision. Uninstall-ParallelInstanceLocal.ps1 prefers
    # the installed package's copy, but a first install that failed half way has no package root
    # -- and that is the case the uninstaller is the recovery for.
    & scp -q (Join-Path $repoRoot 'scripts\Uninstall-ControlServerLocal.ps1') "${SshAlias}:$(& $toPosix "$opsRoot\Uninstall-ControlServerLocal.ps1")"
    if ($LASTEXITCODE -ne 0) { throw "scp of Uninstall-ControlServerLocal.ps1 failed (exit $LASTEXITCODE)" }
    & scp -q $InstanceDefinitionPath "${SshAlias}:$(& $toPosix "$opsRoot\instance.json")"
    if ($LASTEXITCODE -ne 0) { throw "scp of the instance definition failed (exit $LASTEXITCODE)" }
    Write-Step "Parallel scripts and instance definition staged in $opsRoot"
}

# ----------------------------------------------------------------- uninstall ---

if ($Uninstall) {
    # Nothing is copied to the server on this path, dry run or not (control-server#262
    # re-review, M2). The first version copied the scripts and instance.json before asking
    # ShouldProcess, so "-Uninstall -WhatIf" wrote to the server -- and overwrote the definition
    # the instance had been installed from with whatever this machine's copy says today. The
    # uninstall runs the scripts the last install left in opsRoot, and they read
    # installed-instance.json, which the installer recorded before it changed anything.
    $remoteScript = "$opsRoot\Uninstall-ParallelInstanceLocal.ps1"
    $present = & ssh $SshAlias "pwsh -NoProfile -Command `"Test-Path -LiteralPath '$remoteScript' -PathType Leaf`"" 2>&1
    $data = $RemoveData ? ' -RemoveData' : ''
    if (-not $PSCmdlet.ShouldProcess($SshAlias, 'Uninstall the v2 parallel instance')) {
        if ("$present".Trim() -eq 'True') {
            # Read-only: the server-side script prints its full item list under -WhatIf, from the
            # definition it would really use, and removes nothing.
            Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" -ConfirmUninstall -WhatIf$data")
        } else {
            Write-Step "WhatIf: no $remoteScript on $SshAlias -- nothing was installed through this path."
        }
        return
    }
    if ("$present".Trim() -ne 'True') {
        throw "No $remoteScript on $SshAlias. Nothing was installed through this path, or opsRoot was removed by hand."
    }
    Invoke-Ssh @("pwsh -NoProfile -File `"$remoteScript`" -ConfirmUninstall -Confirm:`$false$data")
    Write-Step 'Uninstall complete. The MVP service was not involved.'
    return
}

# ------------------------------------------------------------------ rollback ---

if ($Rollback) {
    if (-not $PSCmdlet.ShouldProcess($SshAlias, 'Roll back the v2 parallel instance to its previous package')) { return }
    Copy-ParallelScripts
    $allow = $AllowRiotCreateDispatch ? ' -AllowRiotCreateDispatch' : ''
    Invoke-Ssh @("pwsh -NoProfile -File `"$opsRoot\Install-ParallelInstanceLocal.ps1`" -Rollback -InstanceDefinitionPath `"$opsRoot\instance.json`"$allow")
    Write-Step 'Rollback complete. The MVP service was not involved.'
    Write-Step 'The onboard half was NOT rolled back. The two ends do not negotiate versions --'
    Write-Step 'roll agv02/agv03 back too, or they will simply stop connecting.'
    return
}

# ------------------------------------------------------------------- secrets ---

if (-not (Test-Path -LiteralPath $SecretPath)) {
    throw "No secret store at $SecretPath. Run control-server\Set-ControlServerSecret.ps1 -Import first."
}
$secrets = Import-Clixml -LiteralPath $SecretPath
foreach ($key in @('RiotCallApiKey', 'OnboardCredential')) {
    if (-not $secrets.ContainsKey($key) -or -not $secrets[$key]) {
        throw "Secret '$key' is missing from $SecretPath. Run Set-ControlServerSecret.ps1."
    }
}
$plain = @{}
foreach ($key in @('RiotCallApiKey', 'MesIngestSharedSecret', 'V2FaultRecoveryCredential')) {
    if ($secrets.ContainsKey($key) -and $secrets[$key]) {
        $plain[$key] = [System.Net.NetworkCredential]::new('', $secrets[$key]).Password
    }
}
# control-server#454. The parallel instance's own fault recovery credential, written into its
# service Environment as CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL -- never the MVP's value. With
# the Host entry on it is required, and refused here before anything is downloaded; with it off it
# is sent when present, so turning the entry on later needs no new secret on the server. The server
# makes the same check again, and a rollback carries over what the service already holds.
if ($definition['vehicleFaultRecovery']['enabled'] -eq $true -and -not $plain.ContainsKey('V2FaultRecoveryCredential')) {
    throw ("vehicleFaultRecovery.enabled is true, but 'V2FaultRecoveryCredential' is missing from $SecretPath. " +
        'Run control-server\Set-ControlServerSecret.ps1 to add it. Nothing was downloaded or copied.')
}
Write-Step ("Secrets loaded from the DPAPI store (V2FaultRecoveryCredential {0})" -f
    ($plain.ContainsKey('V2FaultRecoveryCredential') ? 'present, will be sent' : 'absent; the Host recovery entry is off'))

# ------------------------------------------------------------------- package ---

# -WhatIf:$false on local staging: SupportsShouldProcess puts the whole script into WhatIf
# mode, and staging for real is what lets a dry run verify the hash.
$localStage = Join-Path $env:TEMP "control-server-v2-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $localStage -Force -WhatIf:$false | Out-Null

# Set just before deploy-config.json starts its way to the server; from then on the finally below
# checks the server for it, whatever happened in between (S1 re-review, round 3).
$configCopyAttempted = $false

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

    # ------------------------------------------------------- FakeMesIngest ---

    if (-not $FakeMesIngestZip) {
        $fakeOutput = Join-Path $localStage 'fake-mes-ingest'
        Write-Step 'Building FakeMesIngest from the control-server repository'
        & pwsh -NoProfile -File (Join-Path $parallelScripts 'Publish-FakeMesIngest.ps1') -OutputPath $fakeOutput
        if ($LASTEXITCODE -ne 0) { throw "Publish-FakeMesIngest.ps1 failed (exit $LASTEXITCODE)" }
        $FakeMesIngestZip = "$fakeOutput.zip"
    }
    if (-not (Test-Path -LiteralPath $FakeMesIngestZip -PathType Leaf)) {
        throw "FakeMesIngest package not found: $FakeMesIngestZip"
    }
    Write-Step "FakeMesIngest package: $FakeMesIngestZip"

    # -------------------------------------------------------------- config ---

    $config = [ordered]@{
        riotCallApiKey = $plain['RiotCallApiKey']
        mesIngestSharedSecret = $plain['MesIngestSharedSecret']
    }
    # Only when there is one: Install-ParallelInstanceLocal.ps1 treats an absent field as "carry over
    # what the service holds", and an empty string the same way.
    if ($plain.ContainsKey('V2FaultRecoveryCredential')) {
        $config['faultRecoveryCredential'] = $plain['V2FaultRecoveryCredential']
    }
    $configPath = Join-Path $localStage 'deploy-config.json'
    ConvertTo-Json -InputObject $config -Depth 5 |
        Set-Content -LiteralPath $configPath -Encoding utf8NoBOM -WhatIf:$false

    if (-not $PSCmdlet.ShouldProcess($SshAlias, "Deploy $(Split-Path -Leaf $zip) as the v2 parallel instance")) {
        Write-Step 'WhatIf: stopping before the server is touched.'
        Write-Step "Would copy: $zip -> ${SshAlias}:$stagingRoot"
        Write-Step "Would install service '$($definition['serviceName'])' into $($definition['installRoot'])"
        Write-Step "Would bind: tcp://${listenAddress}:$onboardPort and http://${healthBindAddress}:$healthPort"
        Write-Step "Would keep the MVP at 58005/58007 untouched."
        # An upgrade keeps the installed appsettings.Production.json (Update-ControlServerLocal.ps1),
        # so the ports and bind addresses printed above take effect only on a FIRST install. To
        # move an installed instance, uninstall and install again.
        Write-Step 'NOTE: on an upgrade the installed bindings are kept; the ports above apply only to a first install.'
        return
    }

    # ------------------------------------------------------------ transfer ---

    Copy-ParallelScripts

    # Inheritance broken on both directories: deploy-config.json holds plaintext secrets for
    # the length of one install, and this server has interactive logins other than ours.
    $prepare = @"
foreach (`$d in @('$opsRoot', '$stagingRoot')) {
    if (-not (Test-Path -LiteralPath `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }
    `$acl = Get-Acl -LiteralPath `$d
    `$acl.SetAccessRuleProtection(`$true, `$false)
    foreach (`$r in @(`$acl.Access)) { [void]`$acl.RemoveAccessRule(`$r) }
    foreach (`$id in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        `$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            `$id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath `$d -AclObject `$acl
    "ready: `$d"
}
"@
    $preparePath = Join-Path $localStage 'prepare-dirs.ps1'
    Set-Content -LiteralPath $preparePath -Value $prepare -Encoding utf8NoBOM
    Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$stagingRoot' | Out-Null")
    & scp -q $preparePath "${SshAlias}:$(& $toPosix "$stagingRoot\prepare-dirs.ps1")"
    if ($LASTEXITCODE -ne 0) { throw "scp of prepare-dirs.ps1 failed (exit $LASTEXITCODE)" }
    Invoke-Ssh @("pwsh -NoProfile -File `"$stagingRoot\prepare-dirs.ps1`"")

    Write-Step "Copying package ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
    $remoteZip = "$stagingRoot\$(Split-Path -Leaf $zip)"
    & scp -q $zip "${SshAlias}:$(& $toPosix $remoteZip)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the package failed (exit $LASTEXITCODE)" }

    $remoteFake = "$stagingRoot\fake-mes-ingest.zip"
    & scp -q $FakeMesIngestZip "${SshAlias}:$(& $toPosix $remoteFake)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the FakeMesIngest package failed (exit $LASTEXITCODE)" }

    # From the layout, the same function the server's installer takes it from -- never from a
    # parameter. The after-check in the finally below deletes exactly this one path on factory01.
    $configLayout = Get-ParallelInstanceLayout -Definition $definition
    $remoteConfig = $configLayout.DeploymentConfigPath
    # Before the scp, not after it: a transfer cut half way can leave a partial file.
    $configCopyAttempted = $true
    & scp -q $configPath "${SshAlias}:$(& $toPosix $remoteConfig)"
    if ($LASTEXITCODE -ne 0) { throw "scp of the deployment config failed (exit $LASTEXITCODE)" }

    # ------------------------------------------------------------- install ---

    Write-Step 'Running the parallel installer on the server'
    $allow = $AllowRiotCreateDispatch ? ' -AllowRiotCreateDispatch' : ''
    Invoke-Ssh @("pwsh -NoProfile -File `"$opsRoot\Install-ParallelInstanceLocal.ps1`" " +
        "-PackageZip `"$remoteZip`" -ExpectedSha256 $actual " +
        "-DeploymentConfigPath `"$remoteConfig`" -FakeMesIngestZip `"$remoteFake`" " +
        "-InstanceDefinitionPath `"$opsRoot\instance.json`"$allow")

    # --------------------------------------------------------------- check ---

    # The server checked loopback. This is the check that matters: a round trip from another
    # machine, reading the body. A handshake proves nothing on a host behind a global proxy.
    Write-Step "Verifying http://${healthBindAddress}:$healthPort/health/live from this machine"
    $route = Find-NetRoute -RemoteIPAddress $healthBindAddress -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty InterfaceAlias
    if ($route -eq 'Clash') {
        Write-Warning "The route to $healthBindAddress goes through the Clash TUN adapter; this result is fiction."
        Write-Warning 'Install the bypass route: ./01-control-host-route.ps1'
    }
    try {
        $live = Invoke-WebRequest -Uri "http://${healthBindAddress}:$healthPort/health/live" `
            -NoProxy -TimeoutSec 20 -UseBasicParsing
        Write-Step "health/live $($live.StatusCode): $($live.Content)"
    } catch {
        throw "The parallel instance installed but is not reachable from this machine: $($_.Exception.Message)"
    }

    Write-Step "Deployed. Onboard NDJSON: tcp://${listenAddress}:$onboardPort"
    Write-Step "Vehicle safety: http://${healthBindAddress}:$healthPort/api/onboard/v1/vehicle-safety"
    Write-Step "Package root on the server: $packageRoot"
    Write-Step 'Next: deploy the matching onboard commit to agv02/agv03 with'
    Write-Step '  remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SiteAlias agv02'

} finally {
    # deploy-config.json on the server holds the RIoT call API key and the MesIngest shared secret
    # in plain text. The installer removes it on every way out -- once its body has started. This
    # covers the rest: parameter binding or Import-Module failing before that, an ssh session that
    # dropped, a pwsh process killed (its finally never runs), a pwsh that never started, a scp cut
    # half way. It deletes on factory01, so it deletes one thing only: deploy-config.json directly
    # in the layout's ops directory, both computed above from the layout. No -Layout is passed on
    # purpose: a layout built from the path being checked would accept any path; the directory
    # rule accepts only <opsRoot>\deploy-config.json. Same function, the server's own module copy.
    if ($configCopyAttempted) {
        $check = @(
            "Import-Module '$opsRoot\ParallelInstance.psm1' -Force"
            "`$r = Remove-ParallelInstanceDeploymentConfig -Path '$remoteConfig' -FallbackDirectory '$($configLayout.OpsRoot)'"
            "if (`$r) { 'SECRET_FILE_LEFT_BEHIND: $remoteConfig ' + `$r; exit 3 }"
            "'deploy-config.json: not on the server'"
        ) -join '; '
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($check))
        try {
            $null = Invoke-Ssh @('pwsh', '-NoProfile', '-EncodedCommand', $encoded)
        } catch {
            Write-Warning "SECRET_FILE_LEFT_BEHIND: $remoteConfig on $SshAlias is still there or could not be checked ($($_.Exception.Message)). It holds plaintext secrets; remove it by hand."
        }
    }
    if (Test-Path -LiteralPath $localStage) {
        Remove-Item -LiteralPath $localStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    $plain.Clear()
}
