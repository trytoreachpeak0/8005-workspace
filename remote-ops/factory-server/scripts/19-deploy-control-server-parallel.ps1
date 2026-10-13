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

    SAME COMMIT (control-server#552). The package and the instance definition travel separately:
    the package from GitHub or disk, the definition and the server-side scripts from
    -ControlServerRepository. A package from one commit with a definition from another is how a
    batch-10 admissionPolicyVersion (3) got bound to an older build's seed, after which every later
    batch-10 install judged drift and stopped accepting demand. So an install or upgrade is refused
    unless the clone is clean, the definition is a tracked file of the clone, and the package's
    release-manifest.json names the clone's HEAD as components.controlServer.commit. A rollback
    cannot meet the last condition (the previous package is on the server), so it is not asked to;
    it must instead raise the version explicitly with -AdmissionPolicyVersionOverride.

.PARAMETER RunId
    GitHub Actions release run to deploy. Omit to take the most recent successful release run
    built from -ControlServerRepository's HEAD commit (gh run list --commit); none is refused, it
    never falls back to "the latest release". Either way the package is checked against the clone.

.PARAMETER PackagePath
    Deploy a zip already on disk instead of downloading one. The matching .sha256 must sit
    beside it, and its release-manifest.json must name the clone's HEAD.

.PARAMETER Rollback
    Swap the previous parallel package back in. Downloads nothing, and never touches the MVP.
    Requires -AdmissionPolicyVersionOverride.

.PARAMETER AdmissionPolicyVersionOverride
    Replaces journeyRuntime.admissionPolicyVersion in the copy of the instance definition that is
    sent to the server; the clone's file is not changed. Required with -Rollback: the database
    refuses both a version it has already bound to other content and any version below the highest
    it has bound, so a rolled-back build needs the highest version this instance has ever bound + 1
    (control-server scripts/parallel/README.md, the rollback section). Optional on an install, for the same reason
    when re-installing after a rollback. Must be above the definition's own value. Printed, with the
    reason, as ADMISSION_POLICY_VERSION_OVERRIDE=...; write the version into the deployment record.

.PARAMETER ControlServerRepository
    A clean 8005-agv-control-server checkout or worktree at the commit being deployed. The
    instance definition, the validator module, the on-server installer and the FakeMesIngest
    source all come from here -- so that what is deployed and what validates it are the same
    revision. Enforced: any uncommitted change or untracked file is refused (control-server#552).

.PARAMETER InstanceDefinitionPath
    Default scripts/parallel/instance-factory01-v2.json in the clone. Must be a file tracked in
    the clone (e.g. scripts/parallel/instance-factory01-v2.production-mes.json); a path outside it
    is refused. To change the version for one deployment use -AdmissionPolicyVersionOverride, and
    commit any other change.

.PARAMETER FakeMesIngestZip
    A FakeMesIngest package already built by scripts/parallel/Publish-FakeMesIngest.ps1. Omit
    to build one from -ControlServerRepository. 'fake' mode only: with a definition whose
    mesIngest.source is 'production' (control-server#535; scripts/parallel/
    instance-factory01-v2.production-mes.json) no double is built, copied or registered, and
    passing this is refused.

.PARAMETER Uninstall
    Remove the parallel instance: the double's task and directory, the V2 firewall rules, the
    service and install root (through the product uninstaller), both package generations and
    the staging directory. Every item comes from the same footprint list the installer uses.
    Data -- the SQLite data root, the upgrade backups, the ops results -- is kept unless
    -RemoveData. Also the recovery from a half-finished first install, which has no previous
    generation to roll back to.

.PARAMETER RemoveData
    With -Uninstall: also remove the data root, the backups and the ops directory.

.PARAMETER ProductionCutover
    control-server#564 (that repository's docs/production-cutover-mode-plan.md; user decision 2026-10-13). Deploys a
    production cutover definition -- one carrying productionCutover.approvalRecord, agv01 in its roster, all six task types
    from the production MesIngest -- and is passed on to the server's installer. The definition check lifts those two guards
    only with this switch and that record together; the MVP's service name, paths, ports and map 25 stay refused. On the
    server the first cutover install must find an empty data root and must not be -Rollback, and once the instance is a
    cutover every later install and rollback must carry this switch. Running it reads the production MesIngest for every
    task type and drives agv01: the cutover steps that touch agv01, the MVP or the production MesIngest are asked of the
    user first, every time.

.PARAMETER LeaveProductionCutover
    control-server#564 review S4. The governed way out of an installed production cutover: installs the parallel
    definition given with -InstanceDefinitionPath over it. The server's installer requires an empty data root -- the
    cutover database renamed aside first, as evidence -- and refuses it with -ProductionCutover or -Rollback. The last
    step of the rollback in that repository's docs/production-cutover-mode-plan.md section 7; asked of the user first.

.PARAMETER WhatIf
    Stage and verify everything, print what would run, and stop before changing the server. One
    read-only ssh still runs (except with -Uninstall): reading the admission policy version in the
    server's installed-instance.json, which the version check needs (control-server#552).
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Download')]
param(
    [Parameter(ParameterSetName = 'Download')]
    [string] $RunId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Local')]
    [string] $PackagePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    # Not Mandatory on purpose: a missing value is refused with the explanation of what to pass,
    # rather than an interactive prompt (or a bare binding error under -NonInteractive).
    [Parameter(ParameterSetName = 'Download')]
    [Parameter(ParameterSetName = 'Local')]
    [Parameter(ParameterSetName = 'Rollback')]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $AdmissionPolicyVersionOverride,

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

    [switch] $AllowRiotCreateDispatch,

    [switch] $ProductionCutover,

    [switch] $LeaveProductionCutover
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# The local copy of the definition made for -AdmissionPolicyVersionOverride. Removed by the rollback
# and install finally blocks; the trap covers a refusal between its creation and those blocks, and
# rethrows the same error ('break').
$definitionStage = $null
trap {
    if ($definitionStage) { Remove-Item -LiteralPath $definitionStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    break
}

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

# ------------------------------------------------------------- provenance ---
# control-server#552. What is deployed, and what it is deployed with, must be one commit.

function Get-CleanCloneHead {
    <#
        The clone's HEAD, refused unless the whole clone is clean: no uncommitted change and no
        untracked file (ignored build output does not count). The whole clone rather than only
        scripts/parallel, because more than that directory reaches the server: the product
        uninstaller comes from scripts/, and in 'fake' mode FakeMesIngest is built from tools/ and
        the repository's build props -- an untracked .cs file there is compiled into it.
    #>
    param([string] $Root)
    $head = "$(& git -C $Root rev-parse HEAD 2>&1)".Trim()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') {
        throw "CLONE_NOT_A_GIT_CHECKOUT: git rev-parse HEAD failed in $Root ($head)."
    }
    $dirty = @(& git -C $Root status --porcelain --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "CLONE_NOT_CLEAN: git status failed in $Root ($($dirty -join ' '))." }
    if ($dirty.Count -gt 0) {
        $shown = @($dirty | Select-Object -First 10 | ForEach-Object { "$_".Trim() }) -join '; '
        $more = $dirty.Count -gt 10 ? " (and $($dirty.Count - 10) more)" : ''
        throw ("CLONE_NOT_CLEAN: -ControlServerRepository $Root at $head has $($dirty.Count) uncommitted or untracked " +
            "path(s): $shown$more. The definition and the scripts sent to the server come from this clone, so it " +
            'must be exactly the commit being deployed. Commit or remove them, or use a fresh worktree. Nothing was downloaded or copied.')
    }
    return $head
}

function Assert-DefinitionFromClone {
    <#
        The definition must be a file tracked in the clone. A copy outside it -- or an untracked or
        ignored file inside it -- carries no commit, and the same-commit check would vouch for a
        definition it never saw. Refused rather than allowed behind a switch: the one edit there was
        a reason to make in a copy, the admission policy version on a rollback, now has its own
        parameter, and any other edit belongs in a commit.
    #>
    param([string] $Root, [string] $Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $rootPrefix = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root)) + [IO.Path]::DirectorySeparatorChar
    $inside = $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    $relative = $inside ? [IO.Path]::GetRelativePath($Root, $full).Replace('\', '/') : $null
    if ($inside) {
        $null = & git -C $Root ls-files --error-unmatch -- $relative 2>&1
        $inside = $LASTEXITCODE -eq 0
    }
    if (-not $inside) {
        throw ("DEFINITION_NOT_FROM_CLONE: -InstanceDefinitionPath $full is not a tracked file of -ControlServerRepository " +
            "$Root. Deploy a definition committed in the clone (scripts/parallel/instance-factory01-v2*.json); to raise " +
            'the admission policy version for one deployment use -AdmissionPolicyVersionOverride. Nothing was downloaded or copied.')
    }
    return $relative
}

function Get-InstallerSwitchArgument {
    <#
        The switches this script hands on to Install-ParallelInstanceLocal.ps1, as the text appended to its command line.
        One place for the install and the rollback command (control-server#564 review, MW1). Pure.
    #>
    param([bool] $AllowRiotCreateDispatch, [bool] $ProductionCutover, [bool] $LeaveProductionCutover)
    return ($AllowRiotCreateDispatch ? ' -AllowRiotCreateDispatch' : '') + ($ProductionCutover ? ' -ProductionCutover' : '') +
        ($LeaveProductionCutover ? ' -LeaveProductionCutover' : '')
}

function Get-FaultRecoveryCredentialRefusal {
    <#
        Whether this definition needs the parallel instance's fault recovery credential, and it is not in the store. $null
        when deployable; otherwise the refusal. Pure: Test-DeployControlServerParallel.ps1 lifts it out and feeds it
        hand-made definitions, so it holds whether or not the fixture's control-server revision knows each section.

        Two sections use the one credential (CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL in the service Environment):
        vehicleFaultRecovery (control-server#454, the Host recovery and clearance entries) and foreignRunningOrderRelease
        (control-server#617, PR #679: releasing a car held by a foreign running order). Either one on requires it. A
        definition without foreignRunningOrderRelease -- every one before #679 -- reads as off, so an older
        control-server checkout deploys exactly as before. Only a JSON true counts as on; the definition check refuses any
        other value where the module knows the section.
    #>
    param([System.Collections.IDictionary] $Definition, [bool] $HasCredential, [string] $SecretPath)
    $on = @(foreach ($section in @('vehicleFaultRecovery', 'foreignRunningOrderRelease')) {
            $node = $Definition.Contains($section) ? $Definition[$section] : $null
            if ($node -is [System.Collections.IDictionary] -and $node.Contains('enabled') -and $node['enabled'] -is [bool] -and $node['enabled']) { "$section.enabled" }
        })
    if ($on.Count -eq 0 -or $HasCredential) { return $null }
    return ("$($on -join ' and ') $($on.Count -eq 1 ? 'is' : 'are') true, but 'V2FaultRecoveryCredential' is missing from $SecretPath. " +
        'Run control-server\Set-ControlServerSecret.ps1 to add it. Nothing was downloaded or copied.')
}

function Format-VehicleLines {
    <#
        The vehicle line(s) of the target summary. A definition with a fleet table
        (journeyRuntime.fleet, control-server#571) has no top-level agvId/vehicleKey and printed an
        empty "Vehicle:  ()"; it gets one line per vehicle instead. Display only: nothing is checked here.
    #>
    param([System.Collections.IDictionary] $Definition)
    $journey = $Definition['journeyRuntime']
    if ($journey -isnot [System.Collections.IDictionary]) { return 'Vehicle: (no journeyRuntime section)' }
    $fleet = $journey.Contains('fleet') ? @($journey['fleet'] | Where-Object { $_ -is [System.Collections.IDictionary] }) : @()
    if ($fleet.Count -eq 0) { return "Vehicle: $($journey['agvId']) ($($journey['vehicleKey']))" }
    $lines = for ($i = 0; $i -lt $fleet.Count; $i++) {
        "Vehicle $($i + 1)/$($fleet.Count): $($fleet[$i]['agvId']) ($($fleet[$i]['vehicleKey']))"
    }
    # Enumerated, one string per vehicle: the caller writes each as its own line.
    return $lines
}

function Assert-SentFilesMatchHead {
    <#
        Every file sent to the server, compared with the blob at HEAD. 'git status' is blind to
        files marked skip-worktree or assume-unchanged (review of control-server#552: either mark,
        then an edited definition or module, and status stays empty), and to an edit that keeps the
        size and the write time. So each file's bytes are compared with the blob's own, and any such
        mark anywhere in the clone is refused as well. Line endings alone are not a difference: which
        of CRLF or LF a checkout writes depends on core.autocrlf and the attributes, not on the
        commit ('git hash-object --path' was tried first and disagreed with a clean file on exactly
        that), and neither a script nor a definition means anything different for it.
    #>
    param([string] $Root, [string[]] $Relative)
    $toLf = {
        param([byte[]] $Bytes)
        $list = [System.Collections.Generic.List[byte]]::new($Bytes.Length)
        for ($i = 0; $i -lt $Bytes.Length; $i++) {
            if ($Bytes[$i] -eq 0x0D -and $i + 1 -lt $Bytes.Length -and $Bytes[$i + 1] -eq 0x0A) { continue }
            $list.Add($Bytes[$i])
        }
        , $list.ToArray()
    }
    # The blob's raw bytes. A Process rather than '& git': a native pipe into PowerShell decodes text.
    $blobBytes = {
        param([string] $Path)
        $info = [Diagnostics.ProcessStartInfo]::new('git')
        foreach ($a in @('-C', $Root, 'cat-file', 'blob', "HEAD:$Path")) { $info.ArgumentList.Add($a) }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($info)
        $stderr = $process.StandardError.ReadToEndAsync()
        $buffer = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "CLONE_NOT_CLEAN: $Path is not in HEAD of $Root ($($stderr.Result.Trim())). Nothing was downloaded or copied." }
        , $buffer.ToArray()
    }
    $flags = @(& git -C $Root ls-files -v 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "CLONE_NOT_CLEAN: git ls-files -v failed in $Root ($($flags -join ' '))." }
    # Lower-case tag: assume-unchanged. 'S' (or 's'): skip-worktree.
    $marked = @($flags | Where-Object { "$_" -cmatch '^(?:[a-z]|S) ' } | ForEach-Object { "$_".Trim() })
    if ($marked.Count -gt 0) {
        throw ("CLONE_NOT_CLEAN: -ControlServerRepository $Root has $($marked.Count) path(s) marked assume-unchanged or " +
            "skip-worktree, which git status does not report: $(@($marked | Select-Object -First 10) -join '; '). " +
            'Clear the marks (git update-index --no-assume-unchanged / --no-skip-worktree; a sparse checkout is not a deploy ' +
            'source) or use a fresh worktree. Nothing was downloaded or copied.')
    }
    foreach ($path in $Relative) {
        $committed = & $toLf (& $blobBytes $path)
        $working = & $toLf ([IO.File]::ReadAllBytes((Join-Path $Root $path)))
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]] $committed, [byte[]] $working)) {
            throw ("CLONE_NOT_CLEAN: $path in $Root differs from HEAD ($($working.Length) bytes in the working copy, " +
                "$($committed.Length) in HEAD, line endings aside) although git status did not report it. It is sent to the " +
                'server, so it must be the committed file. Nothing was downloaded or copied.')
        }
    }
}

function Get-PackageControlServerCommit {
    <#
        components.controlServer.commit from the release-manifest.json at the root of the zip
        (control-server scripts/New-WireToGateReleaseCandidate.ps1), read without extracting; also
        components.onboardHmi.commit, for the record (not checked: the onboard half is deployed
        separately, to the vehicles).
    #>
    param([string] $Zip)
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $entry = @($archive.Entries | Where-Object { $_.FullName -ceq 'release-manifest.json' })
        if ($entry.Count -ne 1) {
            throw "PACKAGE_MANIFEST_MISSING: $Zip has no release-manifest.json at its root, so the commit it was built from is unknown. Refusing to deploy it. Nothing was copied."
        }
        $reader = [IO.StreamReader]::new($entry[0].Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }
    $commit = $null
    $onboard = $null
    try {
        $manifest = $text | ConvertFrom-Json -AsHashtable
        $commit = "$($manifest['components']['controlServer']['commit'])".Trim().ToLowerInvariant()
    } catch {
        $commit = $null
    }
    try { $onboard = "$($manifest['components']['onboardHmi']['commit'])".Trim() } catch { $onboard = $null }
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "PACKAGE_MANIFEST_NO_COMMIT: release-manifest.json in $Zip has no 40-hex components.controlServer.commit ('$commit'). Refusing to deploy it. Nothing was copied."
    }
    return [pscustomobject]@{ ControlServer = $commit; Onboard = ($onboard ? $onboard : '(none in the manifest)') }
}

function Get-InstalledAdmissionPolicyVersion {
    <#
        journeyRuntime.admissionPolicyVersion of <opsRoot>\installed-instance.json on the server, read
        over one read-only ssh. The installer records that file on every install and rollback before
        it changes anything, so it holds the version of the last deployment -- the floor the next
        one is held to (review of control-server#552: the commonest slip is reinstalling after a
        rollback without the override). Returns $null when there is no such file (first install).
        Anything else that is not a version -- ssh failing, an unreadable file -- is refused: a
        server this machine cannot read is not one to deploy to.
    #>
    param([string] $Path)
    $remote = @(
        "`$p = '$Path'"
        "if (-not (Test-Path -LiteralPath `$p -PathType Leaf)) { 'INSTALLED_DEFINITION=ABSENT'; exit 0 }"
        "try { `$v = (Get-Content -Raw -LiteralPath `$p | ConvertFrom-Json -AsHashtable)['journeyRuntime']['admissionPolicyVersion']; 'INSTALLED_DEFINITION=PRESENT version=' + `$v }"
        "catch { 'INSTALLED_DEFINITION=UNREADABLE ' + `$_.Exception.Message }"
    ) -join "`n"   # not '; ': "try { } ; catch { }" does not parse, and the version check then refused every deploy
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
    $output = @(& ssh $SshAlias 'pwsh' '-NoProfile' '-EncodedCommand' $encoded 2>&1 | ForEach-Object { "$_".Trim() })
    $exit = $LASTEXITCODE
    $line = @($output | Where-Object { $_.StartsWith('INSTALLED_DEFINITION=', [StringComparison]::Ordinal) } | Select-Object -Last 1)
    if ($exit -ne 0 -or $line.Count -eq 0) {
        throw ("INSTALLED_VERSION_UNREAD: could not read $Path on $SshAlias (ssh exit $exit): $($output -join ' | '). " +
            'The version check needs it. Nothing was downloaded or copied.')
    }
    if ($line[0] -ceq 'INSTALLED_DEFINITION=ABSENT') { return $null }
    if ($line[0] -cmatch '^INSTALLED_DEFINITION=PRESENT version=(\d+)$') { return [long] $Matches[1] }
    throw "INSTALLED_VERSION_UNREAD: $Path on $SshAlias has no numeric journeyRuntime.admissionPolicyVersion ($($line[0])). Nothing was downloaded or copied."
}

function New-AdmissionPolicyOverrideDefinition {
    <#
        A copy of the definition with journeyRuntime.admissionPolicyVersion replaced, written into
        $Directory under the same file name. The text is edited, not re-serialized, so nothing else
        in the file can change; both files are then parsed and compared to prove exactly that.
    #>
    param([string] $SourcePath, [int] $Version, [string] $Directory)
    $bytes = [IO.File]::ReadAllBytes($SourcePath)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes, ($bom ? 3 : 0), $bytes.Length - ($bom ? 3 : 0))
    $pattern = '("admissionPolicyVersion"\s*:\s*)(\d+)'
    $found = [regex]::Matches($text, $pattern).Count
    if ($found -ne 1) {
        throw "ADMISSION_POLICY_VERSION_OVERRIDE_UNAPPLIED: expected one numeric admissionPolicyVersion in $SourcePath, found $found. Nothing was downloaded or copied."
    }
    $edited = [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + $Version })
    $target = Join-Path $Directory (Split-Path -Leaf $SourcePath)
    [IO.File]::WriteAllBytes($target, [Text.UTF8Encoding]::new($bom).GetPreamble() + [Text.UTF8Encoding]::new($false).GetBytes($edited))

    $expected = Read-ParallelInstanceDefinition -Path $SourcePath
    $actual = Read-ParallelInstanceDefinition -Path $target
    $expected['journeyRuntime']['admissionPolicyVersion'] = $actual['journeyRuntime']['admissionPolicyVersion']
    if ("$($actual['journeyRuntime']['admissionPolicyVersion'])" -cne "$Version" -or
        (ConvertTo-Json -InputObject $expected -Depth 32 -Compress) -cne (ConvertTo-Json -InputObject $actual -Depth 32 -Compress)) {
        throw "ADMISSION_POLICY_VERSION_OVERRIDE_UNAPPLIED: the derived definition $target does not differ from $SourcePath in journeyRuntime.admissionPolicyVersion alone. Nothing was downloaded or copied."
    }
    return $target
}

# ------------------------------------------------- repository and definition ---

# The server-side scripts Copy-ParallelScripts sends from scripts/parallel; the same list is checked
# against HEAD before anything is sent.
$serverScriptNames = @('ParallelInstance.psm1', 'ParallelHost.psm1', 'Install-ParallelInstanceLocal.ps1',
    'Uninstall-ParallelInstanceLocal.ps1', 'Start-FakeMesIngestResident.ps1')

$repoRoot = (Resolve-Path -LiteralPath $ControlServerRepository).Path
$parallelScripts = Join-Path $repoRoot 'scripts\parallel'
if (-not (Test-Path -LiteralPath $parallelScripts -PathType Container)) {
    throw "No scripts/parallel directory in $repoRoot. Is this an 8005-agv-control-server checkout on fp/v2-impl or later?"
}

if (-not $InstanceDefinitionPath) {
    $InstanceDefinitionPath = Join-Path $parallelScripts 'instance-factory01-v2.json'
}

# An uninstall copies nothing from the clone and sends no definition (see below), so it is not held
# to these: it must stay possible to remove an instance from whatever checkout is at hand.
$cloneHead = $null
if (-not $Uninstall) {
    $cloneHead = Get-CleanCloneHead -Root $repoRoot
    $definitionRelative = Assert-DefinitionFromClone -Root $repoRoot -Path $InstanceDefinitionPath
    Assert-SentFilesMatchHead -Root $repoRoot -Relative (@($definitionRelative, 'scripts/Uninstall-ControlServerLocal.ps1') +
        @($serverScriptNames | ForEach-Object { "scripts/parallel/$_" }))
    Write-Step "Clone $repoRoot is clean at $cloneHead; definition $definitionRelative is tracked there; the files sent match HEAD"
    if ($Rollback -and -not $PSBoundParameters.ContainsKey('AdmissionPolicyVersionOverride')) {
        throw ('ADMISSION_POLICY_VERSION_OVERRIDE_REQUIRED: -Rollback needs -AdmissionPolicyVersionOverride <n>. The rollback ' +
            'reinstalls the previous package but rewrites the overlay from this clone''s definition, and the database refuses ' +
            'a version it has already bound to other content as well as any version below the highest it has bound -- either ' +
            'way the instance stops accepting demand. Pass the highest admissionPolicyVersion this instance has ever bound + 1 ' +
            '(AdmissionPolicyState.Version in the v2 database + 1, checked against the deployment record; the first rollback ' +
            'from 3 is 4). See the control-server scripts/parallel/README.md section on rollback. Nothing was copied.')
    }
}

Import-Module (Join-Path $parallelScripts 'ParallelInstance.psm1') -Force

$definition = Read-ParallelInstanceDefinition -Path $InstanceDefinitionPath
# The definition is asserted further down; until then journeyRuntime may be missing or malformed.
$getDefinedVersion = { $j = $definition['journeyRuntime']; ($j -is [System.Collections.IDictionary]) ? $j['admissionPolicyVersion'] : $null }
if ($PSBoundParameters.ContainsKey('AdmissionPolicyVersionOverride')) {
    $definedVersion = & $getDefinedVersion
    if ($null -ne $definedVersion -and $AdmissionPolicyVersionOverride -le [long] $definedVersion) {
        throw ("ADMISSION_POLICY_VERSION_OVERRIDE_NOT_ABOVE_DEFINITION: -AdmissionPolicyVersionOverride $AdmissionPolicyVersionOverride " +
            "is not above the definition's own $definedVersion. That version is already bound (or about to be) to this " +
            "commit's seed; pass the highest version this instance has ever bound + 1. Nothing was copied.")
    }
    $definitionStage = Join-Path $env:TEMP "control-server-v2-definition-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $definitionStage -Force -WhatIf:$false | Out-Null
    $InstanceDefinitionPath = New-AdmissionPolicyOverrideDefinition -SourcePath $InstanceDefinitionPath -Version $AdmissionPolicyVersionOverride -Directory $definitionStage
    $definition = Read-ParallelInstanceDefinition -Path $InstanceDefinitionPath
    $reason = $Rollback ?
        'rollback: the previous package''s seed cannot reuse a bound version and the database refuses a lower one' :
        'operator raised the version above the definition (e.g. reinstalling after a rollback)'
    $overrideLine = "ADMISSION_POLICY_VERSION_OVERRIDE=$AdmissionPolicyVersionOverride definition=$definedVersion reason=$reason"
    Write-Step $overrideLine
    Write-Warning $overrideLine
    Write-Step "journeyRuntime.admissionPolicyVersion=$($definition['journeyRuntime']['admissionPolicyVersion']) read back from the derived definition $InstanceDefinitionPath"
}
if (-not $Uninstall) {
    Write-Step ("ADMISSION_POLICY_VERSION={0} -- write it into the deployment record; a rollback needs the highest one ever installed + 1" -f
        ((& $getDefinedVersion) ?? '(not in the definition)'))
}

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
    if ($ProductionCutover -and $LeaveProductionCutover) {
        throw '-ProductionCutover installs a production cutover and -LeaveProductionCutover leaves one; pass one. Nothing was downloaded or copied.'
    }
    # control-server#564: a -ControlServerRepository older than the switch has no such parameter; say which, not a binding error.
    if (($ProductionCutover -or $LeaveProductionCutover) -and -not (Get-Command Assert-ParallelInstanceDefinition).Parameters.ContainsKey('ProductionCutover')) {
        throw '-ProductionCutover was passed, but -ControlServerRepository is older than control-server#564 (its ParallelInstance.psm1 has no cutover switch). Deploy from a checkout that has it.'
    }
    # Splatted only when on: an older module must keep accepting today's deployments without the parameter.
    $cutoverArgument = $ProductionCutover ? @{ ProductionCutover = $true } : @{}
    $null = Assert-ParallelInstanceDefinition -Definition $definition -AllowRiotCreateDispatch:$AllowRiotCreateDispatch @cutoverArgument
    # A checkout from before control-server#454 validates a definition without the clearance exit
    # sections and deploys an instance that silently has no exit. Say so instead.
    foreach ($section in @('vehicleFaultRecovery', 'fieldOperatorRoles')) {
        if (-not $definition.Contains($section)) {
            throw "$InstanceDefinitionPath has no '$section' section. -ControlServerRepository is older than control-server#454; deploy from a checkout that has it."
        }
    }
    Write-Step "Instance definition accepted: $($definition['instanceId']) (from $InstanceDefinitionPath)"
}

# control-server#535. Where the instance's demand comes from: 'fake' (its own FakeMesIngest double,
# the default) or 'production' (the production MesIngest, STAGING_TO_WIRE only -- the user's
# 2026-10-09 decision). The module decides, from the same definition; a checkout older than #535 has
# no such property and only knows 'fake' (its whitelist refuses a 'source' key outright).
$mesIngestSource = 'fake'
if (-not $Uninstall) {
    $sourceProperty = (Get-ParallelInstanceLayout -Definition $definition).PSObject.Properties['MesIngestSource']
    $mesIngestSource = ${sourceProperty}?.Value ?? 'fake'
    $productionSource = $mesIngestSource -ceq 'production'
    $mesIngestAudit = (Get-Command Format-ParallelMesIngestAudit -ErrorAction SilentlyContinue) ?
        (Format-ParallelMesIngestAudit -Definition $definition) : "MES_INGEST_SOURCE=fake baseUrl=$($definition['mesIngest']['baseUrl'])"
    Write-Step $mesIngestAudit
    if ($productionSource) {
        Write-Warning $mesIngestAudit
        if ($FakeMesIngestZip) {
            throw "-FakeMesIngestZip was passed, but $InstanceDefinitionPath reads the production MesIngest and installs no double. Nothing was downloaded or copied."
        }
    }
}

$opsRoot = [string] $definition['opsRoot']
$stagingRoot = [string] $definition['stagingRoot']
$packageRoot = [string] $definition['packageRoot']
$healthBindAddress = [string] $definition['healthBindAddress']
$healthPort = [int] $definition['healthPort']
$listenAddress = [string] $definition['listenAddress']
$onboardPort = [int] $definition['onboardPort']

Write-Step "Target: $SshAlias  service '$($definition['serviceName'])'"
foreach ($vehicleLine in (Format-VehicleLines -Definition $definition)) { Write-Step $vehicleLine }
Write-Step ("RouteGraph: enabled={0} mapId={1}   RiotCreateDispatch: enabled={2}" -f
    $definition['routeGraph']['enabled'], $definition['routeGraph']['mapId'],
    $definition['riotCreateDispatch']['enabled'])
if (-not $Uninstall) {
    # control-server#454: the two sections the manual station clearance exit needs, from the definition.
    Write-Step ("Clearance exit: VehicleFaultRecovery enabled={0}   FieldOperatorRoles roster={1} onboardEntryDeclared={2}" -f
        $definition['vehicleFaultRecovery']['enabled'], $definition['fieldOperatorRoles']['path'],
        $definition['fieldOperatorRoles']['onboardClearanceEntryDeclared'])
    # control-server#638 (PR #640 review M1). REQ-0178's clearance move, shown before anything is touched (also under
    # -WhatIf): on, a vehicle in the clearing loop drives itself to a waiting point. Left out of the definition is off,
    # which is what the installer writes. The installer reads back what the Host bound; this line is what was asked for.
    $clearanceMove = $definition['journeyRuntime'].Contains('clearanceToWaitingPointEnabled') ?
        $definition['journeyRuntime']['clearanceToWaitingPointEnabled'] : $false
    $clearanceLine = "Clearance to a waiting point (REQ-0178): journeyRuntime.clearanceToWaitingPointEnabled=$clearanceMove"
    Write-Step $clearanceLine
    if ($clearanceMove -eq $true) {
        Write-Warning ("$clearanceLine -- vehicles in the clearing loop will drive themselves to a waiting point once their old " +
            'order reads ended. That is a run that moves a vehicle: authorized each time, with somebody on site.')
    }

    # control-server#552 review. The version this deployment sends, against the one the server last
    # recorded: an install may keep it (same package again, or a new one whose seed is unchanged)
    # but never lower it; a rollback swaps the package, so it must go above it.
    $sendingVersion = & $getDefinedVersion
    $installedPath = (Get-ParallelInstanceLayout -Definition $definition).InstalledDefinitionPath
    $installedVersion = Get-InstalledAdmissionPolicyVersion -Path $installedPath
    if ($null -eq $installedVersion) {
        $firstInstallLine = ("INSTALLED_ADMISSION_POLICY_VERSION=none: $installedPath is absent on ${SshAlias}, so this is treated as a " +
            'first install and the version floor is not checked. If the instance was installed before and that file was removed, ' +
            'nothing here protects against sending a version below the bound one: check AdmissionPolicyState.Version first.')
        Write-Step $firstInstallLine
        Write-Warning $firstInstallLine
    } else {
        Write-Step "INSTALLED_ADMISSION_POLICY_VERSION=$installedVersion (from $installedPath on $SshAlias); sending $sendingVersion"
        $tooLow = $Rollback ? ([long] $sendingVersion -le $installedVersion) : ([long] $sendingVersion -lt $installedVersion)
        if ($tooLow) {
            throw ("ADMISSION_POLICY_VERSION_BELOW_INSTALLED: this " + ($Rollback ? 'rollback' : 'deployment') + " would send " +
                "admissionPolicyVersion $sendingVersion, but the last deployment recorded $installedVersion in $installedPath. " +
                'The database refuses a version below the highest it has bound, and a rollback changes the package under it, so ' +
                "it needs a higher one. Pass -AdmissionPolicyVersionOverride $($installedVersion + 1) (or higher, if the database " +
                'has bound more: AdmissionPolicyState.Version + 1). Nothing was downloaded or copied.')
        }
    }
}

function Copy-ParallelScripts {
    <#
        The files the server-side scripts need, copied together every time. The modules and the
        scripts are one unit: an installer that ran against a stale module would validate a
        definition by rules the definition was not written to.
    #>
    Invoke-Ssh @("New-Item -ItemType Directory -Force -Path '$opsRoot' | Out-Null")
    foreach ($name in $serverScriptNames) {
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

function Assert-JourneyBindingReported {
    <#
        control-server#672. What the Host bound for the admission policy version and deployment label and the cargo holding
        and station departure waits, as the server-side installer read it from the Host's EFFECTIVE_CONFIGURATION event and
        printed it (EFFECTIVE_JOURNEY_BINDING=, the last one: the Released read-back follows the Held one), against the
        definition this script sent -- $definition, which is the derived copy under -AdmissionPolicyVersionOverride. Until
        #672 only the overlay file or the database said which version was in effect, and on 2026-10-12 a hand edit of the
        holding wait to five minutes was reinstalled back to thirty unseen.
          * any of the four the definition names that differs: EFFECTIVE_JOURNEY_BINDING_MISMATCH, install or rollback;
            a key the definition leaves out is the package's appsettings.json's to decide, so it is printed, not compared;
          * no such line: EFFECTIVE_JOURNEY_BINDING_UNREAD, always -- the installer scripts come from the same clone as this
            script, so a checkout without the line is the wrong checkout;
          * EFFECTIVE_JOURNEY_BINDING=not-logged (the package is older than #672, its event does not carry them): refused on
            an install, warned on -Rollback. Asymmetric on purpose: a rollback goes to the previous package, which may well
            predate #672, and refusing it would leave no way back; an install brings the package this script was built for,
            and one that cannot say what it bound is not accepted.
        Runs after the installer has already compared the same values and stopped the service on a difference; this is the
        control host's own check, on what was really sent.
    #>
    [CmdletBinding()]
    param([object[]] $Output, [switch] $Rollback)
    $lines = @($Output | ForEach-Object { "$_".Trim() })
    $reported = @($lines | Where-Object { $_.StartsWith('EFFECTIVE_JOURNEY_BINDING=', [StringComparison]::Ordinal) })
    if ($reported.Count -eq 0) {
        throw ('EFFECTIVE_JOURNEY_BINDING_UNREAD: the installer reported no EFFECTIVE_JOURNEY_BINDING line (installer scripts older than ' +
            'control-server#672), so which admission policy version and waits the Host bound is unknown. Deploy from a control-server checkout that has #672.')
    }
    $line = $reported[-1]
    if ($line -ceq 'EFFECTIVE_JOURNEY_BINDING=not-logged') {
        $message = ('EFFECTIVE_JOURNEY_BINDING_NOT_LOGGED: the Host''s EFFECTIVE_CONFIGURATION event does not carry the admission policy ' +
            'version, the deployment label or the two waits (a package older than control-server#672), so what it bound is unknown.')
        if ($Rollback) {
            Write-Warning "$message On -Rollback this is reported, not refused: the previous package may predate #672, and a rollback has to stay possible. Check AdmissionPolicyState and appsettings.Production.json by hand."
            return
        }
        throw "$message Install a package built from a commit with #672."
    }
    # name=value pairs, one space apart, read by name: a field the installer adds later (its read-back table grows one row at a
    # time) is printed and ignored here, and each of the four below must be there exactly once.
    $reportedFields = @{}
    foreach ($pair in $line.Substring('EFFECTIVE_JOURNEY_BINDING='.Length).Split(' ')) {
        $at = $pair.IndexOf('=')
        if ($at -le 0) { throw "EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported '$line', which is not name=value pairs." }
        $name = $pair.Substring(0, $at)
        if ($reportedFields.ContainsKey($name)) { throw "EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported '$line', which names $name twice." }
        $reportedFields[$name] = $pair.Substring($at + 1)
    }
    $journey = $definition['journeyRuntime']
    [string[]] $problems = @()
    foreach ($key in @('admissionPolicyVersion', 'admissionPolicyDeploymentId', 'cargoHoldingTimeout', 'stationDepartureWaitTimeout')) {
        if (-not $reportedFields.ContainsKey($key)) {
            throw "EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported '$line', which does not name $key."
        }
        if (-not ($journey -is [System.Collections.IDictionary] -and $journey.Contains($key))) { continue }
        $expected = "$($journey[$key])"
        $actual = $reportedFields[$key]
        if ($actual -cne $expected) { $problems += "$key bound '$actual', the definition says '$expected'" }
    }
    if ($problems.Count -gt 0) {
        throw "EFFECTIVE_JOURNEY_BINDING_MISMATCH: $($problems -join '; '). The installer reported '$line'."
    }
    Write-Step "Admission policy and waits the Host bound, confirmed by the server: $line"
}

function Assert-MesIngestSourceReported {
    <#
        control-server#535. The server-side installer reads the overlay back and asserts that the
        MesIngest origin is this definition's own (wire-to-gate-parallel-cd.md section 7); this checks,
        per mode, that what it reports agrees with what the control host meant to deploy:
          * the MES_INGEST_SOURCE result line names this mode and this baseUrl;
          * 'production': allowedWorkTypes is STAGING_TO_WIRE alone, and no FAKE_MES_INGEST line;
          * 'production' under -ProductionCutover (control-server#564 review M1): allowedWorkTypes is the definition's list
            and that list is the six types, the line says PRODUCTION CUTOVER, and no FAKE_MES_INGEST line;
          * 'fake', on an install: the FAKE_MES_INGEST line is there (a rollback never printed one).
        A checkout older than #535 prints no MES_INGEST_SOURCE line and is only ever 'fake'.
    #>
    param([object[]] $Output, [switch] $Rollback)
    $lines = @($Output | ForEach-Object { "$_".Trim() })
    $fakeLines = @($lines | Where-Object { $_.StartsWith('FAKE_MES_INGEST=', [StringComparison]::Ordinal) })
    if ($null -eq $sourceProperty) {
        if (-not $Rollback -and $fakeLines.Count -eq 0) { throw 'The installer reported no FAKE_MES_INGEST line.' }
        Write-Step 'MesIngest source: fake (control-server checkout older than #535)'
        return
    }
    $prefix = "MES_INGEST_SOURCE=$mesIngestSource baseUrl=$($definition['mesIngest']['baseUrl']) "
    $audit = @($lines | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
    if ($audit.Count -eq 0) {
        throw "MES_INGEST_SOURCE_MISMATCH: the installer reported no line starting '$prefix'. What it did report: $(@($lines | Where-Object { $_ -match 'MES_INGEST' }) -join ' | ')"
    }
    $cutoverTypes = @('DIE_TO_WIRE_STAGING', 'DIE_TO_OVEN', 'WIRE_TO_GATE', 'WIRE_TO_OPTICAL', 'STAGING_TO_WIRE', 'WIRE_TO_NITROGEN')
    $definedTypes = @($definition['journeyRuntime']['allowedWorkTypes'])
    $sixDefined = $definedTypes.Count -eq 6 -and (@($definedTypes | Sort-Object -CaseSensitive) -join ',') -ceq (@($cutoverTypes | Sort-Object -CaseSensitive) -join ',')
    if ($productionSource -and $ProductionCutover) {
        if (-not $sixDefined -or -not $audit[-1].Contains("allowedWorkTypes=$($definedTypes -join ',') -- PRODUCTION CUTOVER")) {
            throw "MES_INGEST_SOURCE_MISMATCH: production cutover, but the installer reported '$($audit[-1])'."
        }
        if ($fakeLines.Count -gt 0) {
            throw "MES_INGEST_SOURCE_MISMATCH: production cutover, but the installer also reported $($fakeLines -join ', ')."
        }
    } elseif ($productionSource) {
        if (-not $audit[-1].Contains('allowedWorkTypes=STAGING_TO_WIRE ')) {
            throw "MES_INGEST_SOURCE_MISMATCH: production mode, but the installer reported '$($audit[-1])'."
        }
        if ($fakeLines.Count -gt 0) {
            throw "MES_INGEST_SOURCE_MISMATCH: production mode, but the installer also reported $($fakeLines -join ', ')."
        }
    } elseif (-not $Rollback -and $fakeLines.Count -eq 0) {
        throw 'MES_INGEST_SOURCE_MISMATCH: fake mode, but the installer reported no FAKE_MES_INGEST line.'
    }
    Write-Step "MesIngest source confirmed by the server: $($audit[-1])"

    # control-server#535 review M2. The line above is built from the definition; this one is what the Host
    # really bound, read back by the installer from the Host's own log. M1 was a definition saying
    # STAGING_TO_WIRE and a Host binding six types, so this is the line that proves the mode.
    $journey = $definition['journeyRuntime']
    $expectedEffective = "EFFECTIVE_CONFIGURATION=allowedWorkTypes=$(@($journey['allowedWorkTypes']) -join ',') " +
        "allowedDispatchZones=$(@($journey['allowedDispatchZones']) -join ',') mesIngestBaseUrl=$($definition['mesIngest']['baseUrl'])"
    $effective = @($lines | Where-Object { $_.StartsWith('EFFECTIVE_CONFIGURATION=', [StringComparison]::Ordinal) })
    if ($effective.Count -eq 0) {
        if ($productionSource) {
            throw 'EFFECTIVE_CONFIGURATION_UNREAD: the installer reported no EFFECTIVE_CONFIGURATION line, so what the Host really bound is unknown.'
        }
        Write-Warning 'The installer reported no EFFECTIVE_CONFIGURATION line (a package older than control-server#535 does not log it); fake mode, reported, not refused.'
        return
    }
    if ($effective[-1] -cne $expectedEffective) {
        throw "EFFECTIVE_CONFIGURATION_MISMATCH: the Host bound '$($effective[-1])', the definition says '$expectedEffective'."
    }
    # Under the cutover the definition's own list, compared above, is the six types ($sixDefined).
    if ($productionSource -and -not $ProductionCutover -and -not $effective[-1].StartsWith('EFFECTIVE_CONFIGURATION=allowedWorkTypes=STAGING_TO_WIRE ', [StringComparison]::Ordinal)) {
        throw "EFFECTIVE_CONFIGURATION_MISMATCH: production mode, but the Host bound '$($effective[-1])'."
    }
    Write-Step "What the Host bound, confirmed by the server: $($effective[-1])"
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
    try {
        # Not checked against the package: the previous generation is already on the server. The
        # scripts and the definition sent are still this clean clone's, with the version overridden.
        Write-Step "Rollback: package commit not checked (the previous generation is on the server); scripts and definition from $cloneHead"
        if (-not $PSCmdlet.ShouldProcess($SshAlias, 'Roll back the v2 parallel instance to its previous package')) {
            Write-Step 'WhatIf: rollback stops before the server is touched.'
            return
        }
        Copy-ParallelScripts
        $allow = Get-InstallerSwitchArgument -AllowRiotCreateDispatch $AllowRiotCreateDispatch -ProductionCutover $ProductionCutover -LeaveProductionCutover $LeaveProductionCutover
        $rollbackOutput = Invoke-Ssh @("pwsh -NoProfile -File `"$opsRoot\Install-ParallelInstanceLocal.ps1`" -Rollback -InstanceDefinitionPath `"$opsRoot\instance.json`"$allow")
        Assert-MesIngestSourceReported -Output $rollbackOutput -Rollback
        Assert-JourneyBindingReported -Output $rollbackOutput -Rollback
        Write-Step 'Rollback complete. The MVP service was not involved.'
        Write-Step "Record admissionPolicyVersion=$AdmissionPolicyVersionOverride in the deployment record: the next install needs a higher one."
        Write-Step 'The onboard half was NOT rolled back. The two ends do not negotiate versions --'
        Write-Step 'roll agv02/agv03 back too, or they will simply stop connecting.'
        return
    } finally {
        if ($definitionStage) { Remove-Item -LiteralPath $definitionStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
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
# the Host entry on -- or, since control-server#617, the foreign running order release -- it is
# required, and refused here before anything is downloaded; with both off it is sent when present,
# so turning one on later needs no new secret on the server. The server makes the same check again,
# and a rollback carries over what the service already holds.
$credentialRefusal = Get-FaultRecoveryCredentialRefusal -Definition $definition -HasCredential $plain.ContainsKey('V2FaultRecoveryCredential') -SecretPath $SecretPath
if ($credentialRefusal) { throw $credentialRefusal }
# control-server#535. Reading the production MesIngest needs its Bearer token; without it every read
# is 401 and nothing is dispatched. Refused here, before anything is downloaded; the server checks again.
if ($productionSource -and -not $plain.ContainsKey('MesIngestSharedSecret')) {
    throw ("mesIngest.source is 'production', but 'MesIngestSharedSecret' is missing from $SecretPath. " +
        'Run control-server\Set-ControlServerSecret.ps1 to add it. Nothing was downloaded or copied.')
}
Write-Step ("Secrets loaded from the DPAPI store (V2FaultRecoveryCredential {0})" -f
    ($plain.ContainsKey('V2FaultRecoveryCredential') ? 'present, will be sent' : 'absent; the Host recovery entry and the foreign order release are off'))

# control-server#600. A roster definition makes the v2 server answer each vehicle's vehicle-safety projection only to that
# vehicle's own credential, and refuse to start without one per roster row. They are generated on this machine
# (Set-ControlServerSecret.ps1 -NewVehicleSafetyCredential) and filed under OnboardSafetyCredential:<vehicleKey>. Refused
# here, before anything is downloaded, when a row has none; the server-side installer checks again (and also refuses two
# rows with one value, or one equal to the shared onboard credential). A single-car definition sends none.
$journeyDefinition = $definition['journeyRuntime']
$fleetRows = $journeyDefinition.Contains('fleet') ? @($journeyDefinition['fleet']) : @()
$safetyCredentials = [ordered]@{}
$missingSafety = @()
foreach ($row in $fleetRows) {
    $vehicleKey = [string] $row['vehicleKey']
    $storeKey = 'OnboardSafetyCredential:' + $vehicleKey
    if ($secrets.ContainsKey($storeKey) -and $secrets[$storeKey]) {
        $safetyCredentials[$vehicleKey] = [System.Net.NetworkCredential]::new('', $secrets[$storeKey]).Password
    } else {
        $missingSafety += "$vehicleKey (riotId $($row['riotId']))"
    }
}
if ($missingSafety.Count -gt 0) {
    throw ("The definition's roster needs one vehicle-safety projection credential per vehicle (control-server#600), and " +
        "$SecretPath has none for: $($missingSafety -join ', '). Run control-server\Set-ControlServerSecret.ps1 " +
        '-NewVehicleSafetyCredential <alias> for each, then deploy again; each vehicle''s onboard half needs redeploying ' +
        'with 06-deploy-onboard-hmi.ps1 afterwards. Nothing was downloaded or copied.')
}
Write-Step ($fleetRows.Count -eq 0 ? 'Vehicle-safety projection: single car, shared onboard credential' :
    "Vehicle-safety projection credentials loaded for $(@($safetyCredentials.Keys) -join ', ') (values not shown)")

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
            # control-server#552. By the clone's commit, not by branch and never "the latest": the
            # latest successful release is whatever was built last on any branch, and a branch filter
            # would still pick that branch's tip rather than the commit the definition comes from (and
            # would refuse a field build, which is cut on its own branch). Full SHA: gh matches no
            # abbreviation here.
            Write-Step "Finding the most recent successful release run in $Repository built from $cloneHead"
            $runsJson = & gh run list --repo $Repository --workflow release.yml --status success `
                --commit $cloneHead --limit 1 --json 'databaseId,headSha,headBranch,createdAt'
            if ($LASTEXITCODE -ne 0) { throw "gh run list failed (exit $LASTEXITCODE)" }
            # gh can answer with nothing at all, or 'null'; both mean "no run", not a StrictMode error.
            $runsText = "$($runsJson -join "`n")".Trim()
            $runs = $runsText ? @($runsText | ConvertFrom-Json | Where-Object { $null -ne $_ }) : @()
            if ($runs.Count -eq 0) {
                throw ("RELEASE_RUN_NOT_FOUND: no successful release.yml run in $Repository was built from $cloneHead, " +
                    'the commit -ControlServerRepository is at. Dispatch release.yml on that commit, or check out the commit ' +
                    'of the package you mean and pass -RunId or -PackagePath. Nothing was downloaded.')
            }
            if ("$($runs[0].headSha)" -cne $cloneHead) {
                throw "RELEASE_RUN_COMMIT_MISMATCH: asked for a release run built from $cloneHead, got run $($runs[0].databaseId) built from $($runs[0].headSha). Nothing was downloaded."
            }
            $RunId = "$($runs[0].databaseId)"
            Write-Step "Selected release run $RunId (branch $($runs[0].headBranch), commit $($runs[0].headSha), created $($runs[0].createdAt))"
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

    # control-server#552. After the hash, so the manifest read is the one the hash vouches for.
    $packageCommits = Get-PackageControlServerCommit -Zip $zip
    $packageCommit = $packageCommits.ControlServer
    if ($packageCommit -cne $cloneHead) {
        throw ("PACKAGE_COMMIT_MISMATCH: the package was built from control-server $packageCommit, but " +
            "-ControlServerRepository is at $cloneHead. The instance definition and the server-side scripts come from " +
            'the clone, so a mismatch binds this definition''s admission policy version to another build''s seed. ' +
            "Deploy from a clean checkout of $packageCommit, or deploy the package built from $cloneHead. Nothing was copied.")
    }
    Write-Step "PACKAGE_COMMIT_MATCHES_CLONE=$cloneHead (release-manifest.json components.controlServer.commit)"
    # The onboard half is in the same package and goes to the vehicles separately; its commit is what
    # 06-deploy-onboard-hmi.ps1 must match.
    Write-Step "Package onboard commit: $($packageCommits.Onboard) (components.onboardHmi.commit)"

    # ------------------------------------------------------- FakeMesIngest ---

    # 'fake' mode only (control-server#535): 'production' builds, copies and registers no double.
    if ($productionSource) {
        Write-Step 'No FakeMesIngest: mesIngest.source is production'
    } else {
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
    }

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
    # control-server#600: vehicleKey -> value, one per roster row; the installer writes each into the service's Environment.
    if ($safetyCredentials.Count -gt 0) {
        $config['onboardSafetyCredentials'] = $safetyCredentials
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

    $fakeArgument = ''
    if (-not $productionSource) {
        $remoteFake = "$stagingRoot\fake-mes-ingest.zip"
        & scp -q $FakeMesIngestZip "${SshAlias}:$(& $toPosix $remoteFake)"
        if ($LASTEXITCODE -ne 0) { throw "scp of the FakeMesIngest package failed (exit $LASTEXITCODE)" }
        $fakeArgument = "-FakeMesIngestZip `"$remoteFake`" "
    }

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
    $allow = Get-InstallerSwitchArgument -AllowRiotCreateDispatch $AllowRiotCreateDispatch -ProductionCutover $ProductionCutover -LeaveProductionCutover $LeaveProductionCutover
    $installOutput = Invoke-Ssh @("pwsh -NoProfile -File `"$opsRoot\Install-ParallelInstanceLocal.ps1`" " +
        "-PackageZip `"$remoteZip`" -ExpectedSha256 $actual " +
        "-DeploymentConfigPath `"$remoteConfig`" $fakeArgument" +
        "-InstanceDefinitionPath `"$opsRoot\instance.json`"$allow")
    Assert-MesIngestSourceReported -Output $installOutput
    Assert-JourneyBindingReported -Output $installOutput

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
    Write-Step ($ProductionCutover ? 'Next: deploy the matching onboard commit to every car in the roster (agv01 too: its site file must say controlServerLine "v2"; asked of the user first) with' :
        'Next: deploy the matching onboard commit to agv02/agv03 with')
    # -SshAlias, not -SiteAlias: 06-deploy has no such parameter (control-server#600 review L8). The ports are this
    # instance's; 06 has had no port defaults since workspace#32 and refuses a call without both.
    Write-Step "  remote-ops/onboard-hmi/scripts/06-deploy-onboard-hmi.ps1 -SshAlias agv02 -OnboardPort $onboardPort -HealthPort $healthPort"
    if ($safetyCredentials.Count -gt 0) {
        Write-Step '  Each vehicle reads its projection with its own credential now: redeploy its onboard half with 06-deploy.'
    }

} finally {
    # deploy-config.json on the server holds the RIoT call API key, the MesIngest shared secret, each roster
    # vehicle's projection credential (control-server#600) and, when the store has it, the v2 fault recovery credential
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
    if ($definitionStage) {
        Remove-Item -LiteralPath $definitionStage -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    $plain.Clear()
    if ($null -ne (Get-Variable -Name safetyCredentials -ValueOnly -ErrorAction SilentlyContinue)) { $safetyCredentials.Clear() }
}
