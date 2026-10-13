#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for 19-deploy-control-server-parallel.ps1's provenance checks (control-server#552).

.DESCRIPTION
    Runs 19-deploy-control-server-parallel.ps1 itself, in this process and always with -WhatIf, against a
    throwaway control-server repository and throwaway packages. Nothing here reaches factory01: every
    path that would ssh or scp stops at ShouldProcess first, -SshAlias is a name that resolves nowhere,
    and 'gh' is a function defined below that answers from fixtures and records what it was asked.

    The throwaway repository is built from a real control-server checkout (-ControlServerSource) by
    'git archive' of scripts/parallel and the product uninstaller at -ControlServerRef, committed once,
    so the deploy script imports the real ParallelInstance.psm1 and validates the real definition.

    What it pins (the ticket's list):
      * same commit, clean clone, definition inside the clone: accepted, and the output names the commit;
      * package built from another commit: refused, both commits in the message;
      * uncommitted change under scripts/parallel, or an untracked file anywhere in the clone: refused;
      * -InstanceDefinitionPath outside the clone, or inside it but not tracked (git-ignored): refused;
      * -Rollback without -AdmissionPolicyVersionOverride: refused, the message says what to pass;
        with it: accepted, the override value and reason printed and read back from the derived copy;
        an override not above the definition's own version: refused;
      * an edit git status cannot see (skip-worktree, assume-unchanged, or same size and write time):
        refused by the marks check or the content hash of every file sent;
      * the version on the server (installed-instance.json, read through an 'ssh' double): an install
        below it, or a rollback not above it, refused; ssh failing or an unreadable file refused;
      * a package without release-manifest.json at its root (absent, or only in a subdirectory), or
        without components.controlServer.commit: refused;
      * no -RunId/-PackagePath: the release run is looked up by the clone's commit, not "latest", and
        a lookup that finds none, or one built from another commit, is refused.
    Plus ParseFile with zero errors for the deploy script and for this file: the AST walk below would
    swallow a syntax error that a real run would hit. And the vehicle lines of the target summary: one
    per vehicle for a fleet definition (control-server#571), checked on Format-VehicleLines lifted out
    by its AST with hand-made definitions, so it does not depend on the fixture's revision.

.PARAMETER ControlServerSource
    A local 8005-agv-control-server clone to take scripts/parallel from. Read only ('git archive').

.PARAMETER ControlServerRef
    The revision of -ControlServerSource to take them from.

.PARAMETER ScriptPath
    The deploy script under test. Defaults to the one beside this file; pass an older copy to see
    which checks it lacks.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/Test-DeployControlServerParallel.ps1 -ControlServerSource C:/path/to/8005-agv-control-server
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ControlServerSource,

    [string] $ControlServerRef = 'origin/fp/v2-impl',

    [string] $ScriptPath = (Join-Path $PSScriptRoot '19-deploy-control-server-parallel.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

function Invoke-Git {
    param([string] $Repository, [string[]] $Arguments)
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed in ${Repository}: $output" }
    return $output
}

# --------------------------------------------------------------- parse check ---

Write-Host 'ParseFile' -ForegroundColor Cyan
foreach ($file in @($ScriptPath, $PSCommandPath)) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    Write-Result -Ok (@($errors).Count -eq 0) -Name "$(Split-Path -Leaf $file) parses with 0 errors" -Detail (@($errors) -join ' | ')
}

# ----------------------------------------------------------- vehicle lines ---
# control-server#571 review: a definition with a fleet table has no top-level agvId, and the target
# summary printed "Vehicle:  ()". Format-VehicleLines is lifted out by its AST and driven with
# hand-made definitions, so this holds whether or not the fixture's control-server revision knows
# fleets yet; the AST walk below pins that the summary prints vehicles only through it.
Write-Host ''
Write-Host 'Vehicle lines' -ForegroundColor Cyan
$deployAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
$formatAst = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Format-VehicleLines' }, $true)
if ($null -eq $formatAst) {
    Write-Result -Ok $false -Name 'Format-VehicleLines is defined in the deploy script' -Detail 'not found'
} else {
    . ([scriptblock]::Create($formatAst.Extent.Text))
    $fleetDefinition = @{ journeyRuntime = @{ fleet = @(
                @{ agvId = 'fleet-car-one'; vehicleKey = 'BROKERX-aaaa' },
                @{ agvId = 'fleet-car-two'; vehicleKey = 'BROKERX-bbbb' }) } }
    $lines = @(Format-VehicleLines -Definition $fleetDefinition)
    Write-Result -Ok ($lines.Count -eq 2 -and $lines[0] -ceq 'Vehicle 1/2: fleet-car-one (BROKERX-aaaa)' -and $lines[1] -ceq 'Vehicle 2/2: fleet-car-two (BROKERX-bbbb)') `
        -Name 'fleet definition: one line per vehicle, each with its agvId and vehicleKey' -Detail ($lines -join ' | ')
    $lines = @(Format-VehicleLines -Definition @{ journeyRuntime = @{ agvId = 'single-car'; vehicleKey = 'BROKERX-cccc' } })
    Write-Result -Ok ($lines.Count -eq 1 -and $lines[0] -ceq 'Vehicle: single-car (BROKERX-cccc)') `
        -Name 'single-vehicle definition: the line as before' -Detail ($lines -join ' | ')
    # Every "Vehicle: ..." string in the script is inside Format-VehicleLines, and the summary calls it.
    $vehicleStrings = @($deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
        Where-Object { $_.Value -clike 'Vehicle:*' -and ($_.Extent.StartOffset -lt $formatAst.Extent.StartOffset -or $_.Extent.EndOffset -gt $formatAst.Extent.EndOffset) })
    $calls = @($deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Format-VehicleLines' }, $true))
    Write-Result -Ok ($vehicleStrings.Count -eq 0 -and $calls.Count -eq 1) `
        -Name 'the target summary prints vehicles only through Format-VehicleLines' -Detail ("other Vehicle strings: $(@($vehicleStrings | ForEach-Object { $_.Extent.Text }) -join ' | '); calls: $($calls.Count)")
}

# control-server#617 (PR #679): the fault recovery credential is required when vehicleFaultRecovery or
# foreignRunningOrderRelease is on. Hand-made definitions, so this holds whether or not the fixture's
# control-server revision knows foreignRunningOrderRelease yet (its definition check would refuse the
# section before the secrets are read); the AST walk pins that the script refuses only through this function.
Write-Host ''
Write-Host 'Fault recovery credential (control-server#454, #617)' -ForegroundColor Cyan
$credentialAst = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FaultRecoveryCredentialRefusal' }, $true)
if ($null -eq $credentialAst) {
    Write-Result -Ok $false -Name 'Get-FaultRecoveryCredentialRefusal is defined in the deploy script' -Detail 'not found'
} else {
    . ([scriptblock]::Create($credentialAst.Extent.Text))
    function New-RecoveryDefinition($Recovery, $Release) {
        $d = [ordered]@{ instanceId = 'selftest' }
        if ($null -ne $Recovery) { $d['vehicleFaultRecovery'] = @{ enabled = $Recovery } }
        if ($null -ne $Release) { $d['foreignRunningOrderRelease'] = @{ enabled = $Release } }
        return $d
    }
    foreach ($case in @(
            @{ Name = 'only foreignRunningOrderRelease on, no credential'; Recovery = $false; Release = $true; Has = $false; Expect = 'foreignRunningOrderRelease.enabled is true' }
            @{ Name = 'only vehicleFaultRecovery on, no credential (unchanged)'; Recovery = $true; Release = $false; Has = $false; Expect = 'vehicleFaultRecovery.enabled is true' }
            @{ Name = 'both on, no credential'; Recovery = $true; Release = $true; Has = $false; Expect = 'vehicleFaultRecovery.enabled and foreignRunningOrderRelease.enabled are true' }
            @{ Name = 'only vehicleFaultRecovery on, no foreignRunningOrderRelease section (a definition before #679), no credential'; Recovery = $true; Release = $null; Has = $false; Expect = 'vehicleFaultRecovery.enabled is true' }
            @{ Name = 'only foreignRunningOrderRelease on, credential present'; Recovery = $false; Release = $true; Has = $true; Expect = $null }
            @{ Name = 'both on, credential present'; Recovery = $true; Release = $true; Has = $true; Expect = $null }
            @{ Name = 'both off, no credential'; Recovery = $false; Release = $false; Has = $false; Expect = $null }
            @{ Name = 'vehicleFaultRecovery off and no foreignRunningOrderRelease section (a definition before #679), no credential'; Recovery = $false; Release = $null; Has = $false; Expect = $null }
            @{ Name = 'foreignRunningOrderRelease.enabled as the string "true" (not a JSON true), no credential'; Recovery = $false; Release = 'true'; Has = $false; Expect = $null })) {
        $r = Get-FaultRecoveryCredentialRefusal -Definition (New-RecoveryDefinition $case.Recovery $case.Release) -HasCredential $case.Has -SecretPath 'C:\selftest\secrets.xml'
        $ok = ($null -eq $case.Expect) ? ($null -eq $r) :
            ($r -is [string] -and $r.StartsWith($case.Expect) -and $r.Contains("'V2FaultRecoveryCredential' is missing from C:\selftest\secrets.xml") -and $r.EndsWith('Nothing was downloaded or copied.'))
        Write-Result -Ok $ok -Name "credential precheck: $($case.Name) -> $($null -eq $case.Expect ? 'accepted' : 'refused')" -Detail "got: $r"
    }
    $credentialCalls = @($deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-FaultRecoveryCredentialRefusal' }, $true))
    $scriptText = Get-Content -LiteralPath $ScriptPath -Raw
    Write-Result -Ok ($credentialCalls.Count -eq 1 -and $scriptText.Contains('if ($credentialRefusal) { throw $credentialRefusal }') -and
            -not $scriptText.Contains("`$definition['vehicleFaultRecovery']['enabled'] -eq `$true -and -not `$plain.ContainsKey('V2FaultRecoveryCredential')")) `
        -Name 'the deploy script refuses a missing credential only through Get-FaultRecoveryCredentialRefusal' -Detail "calls $($credentialCalls.Count)"
}

# ------------------------------------------------------------------ fixtures ---

$work = Join-Path ([IO.Path]::GetTempPath()) "cs552-selftest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$clone = Join-Path $work 'control-server'
$outside = Join-Path $work 'outside'
New-Item -ItemType Directory -Path $clone, $outside -Force | Out-Null

try {
    $source = (Resolve-Path -LiteralPath $ControlServerSource).Path
    $archive = Join-Path $work 'parallel.zip'
    Invoke-Git $source @('archive', '--format=zip', "--output=$archive", $ControlServerRef, 'scripts/parallel', 'scripts/Uninstall-ControlServerLocal.ps1') | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $clone
    New-Item -ItemType Directory -Path (Join-Path $clone 'tools') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $clone 'tools\README.md') -Value 'fixture' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $clone '.gitignore') -Value 'local/' -Encoding utf8NoBOM
    Invoke-Git $clone @('init', '-q') | Out-Null
    Invoke-Git $clone @('-c', 'core.autocrlf=false', 'add', '-A') | Out-Null
    Invoke-Git $clone @('-c', 'user.name=selftest', '-c', 'user.email=selftest@invalid', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'fixture') | Out-Null
    $head = "$(Invoke-Git $clone @('rev-parse', 'HEAD'))".Trim()
    $other = 'abcdef0123456789abcdef0123456789abcdef01'
    $definitionPath = Join-Path $clone 'scripts\parallel\instance-factory01-v2.json'
    $definitionVersion = (Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json -AsHashtable)['journeyRuntime']['admissionPolicyVersion']
    Write-Host "Fixture clone $clone at $head (from $ControlServerRef); definition admissionPolicyVersion=$definitionVersion" -ForegroundColor Cyan

    # A secret store with fake values, so the script gets past its secret checks to the package.
    $secretPath = Join-Path $work 'secrets.xml'
    $fake = { param([string] $Text) ConvertTo-SecureString $Text -AsPlainText -Force }
    @{ RiotCallApiKey = (& $fake 'k'); OnboardCredential = (& $fake 'o'); MesIngestSharedSecret = (& $fake 'm'); V2FaultRecoveryCredential = (& $fake 'v') } |
        Export-Clixml -LiteralPath $secretPath
    $fakeMesZip = Join-Path $work 'fake-mes-ingest.zip'
    Set-Content -LiteralPath $fakeMesZip -Value 'not a real package' -Encoding utf8NoBOM

    # A package: a zip with release-manifest.json at its root, and the .sha256 beside it, the way
    # release.yml lays them out. -Manifest $null leaves the manifest out altogether.
    function New-Package {
        param([string] $Name, [object] $Manifest, [string] $Directory = $work)
        $root = Join-Path $work "pkg-$Name"
        New-Item -ItemType Directory -Path (Join-Path $root 'controlserver') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'controlserver\ControlServer.Host.exe') -Value 'stub' -Encoding utf8NoBOM
        if ($null -ne $Manifest) {
            ConvertTo-Json -InputObject $Manifest -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Encoding utf8NoBOM
        }
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $zip = Join-Path $Directory "WireToGate-$Name.zip"
        Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -Force
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$(Split-Path -Leaf $zip)" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
        return $zip
    }
    $onboardCommit = '0123456789abcdef0123456789abcdef01234567'
    function New-Manifest { param([string] $Commit) @{ schemaVersion = 1; components = @{ controlServer = @{ commit = $Commit; branch = 'fp/v2-impl' }; onboardHmi = @{ commit = $onboardCommit } } } }

    $samePackage = New-Package -Name 'same' -Manifest (New-Manifest $head)
    $otherPackage = New-Package -Name 'other' -Manifest (New-Manifest $other)
    $noManifestPackage = New-Package -Name 'nomanifest' -Manifest $null
    $noCommitPackage = New-Package -Name 'nocommit' -Manifest @{ schemaVersion = 1; components = @{ controlServer = @{ branch = 'fp/v2-impl' } } }
    # The manifest only in a subdirectory of the zip: not the one release.yml puts at its root.
    $nestedRoot = Join-Path $work 'pkg-nested'
    New-Item -ItemType Directory -Path (Join-Path $nestedRoot 'sub') -Force | Out-Null
    ConvertTo-Json -InputObject (New-Manifest $head) -Depth 6 | Set-Content -LiteralPath (Join-Path $nestedRoot 'sub\release-manifest.json') -Encoding utf8NoBOM
    $nestedPackage = Join-Path $work 'WireToGate-nested.zip'
    Compress-Archive -Path (Join-Path $nestedRoot '*') -DestinationPath $nestedPackage -Force
    "$((Get-FileHash -LiteralPath $nestedPackage -Algorithm SHA256).Hash.ToLowerInvariant()) *WireToGate-nested.zip" | Set-Content -LiteralPath "$nestedPackage.sha256" -Encoding ascii

    # The 'ssh' double, for the one read-only ssh made before ShouldProcess: reading the installed
    # definition's version. Answers $global:SshAnswer with exit $global:SshExit; every call recorded.
    # Default: no installed-instance.json (a first install).
    $global:SshCalls = [System.Collections.Generic.List[string]]::new()
    $global:SshAnswer = 'INSTALLED_DEFINITION=ABSENT'
    $global:SshExit = 0
    function global:ssh {
        $global:SshCalls.Add($args -join ' ')
        $global:LASTEXITCODE = $global:SshExit
        return $global:SshAnswer
    }

    # The 'gh' double. Defined globally so the script's '& gh' finds it before gh.exe; every call is
    # recorded, 'run list' answers from $global:GhRuns, 'run download' copies $global:GhPackage.
    # -WhatIf:$false on its own file operations: it runs inside the script's WhatIf scope.
    $global:GhCalls = [System.Collections.Generic.List[string]]::new()
    $global:GhRuns = '[]'
    $global:GhPackage = $samePackage
    function global:gh {
        $global:GhCalls.Add($args -join ' ')
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'run' -and $args[1] -eq 'list') {
            # The pre-#552 script asks for '--jq .[0].databaseId'; answer that the way gh would.
            $jq = [array]::IndexOf($args, '--jq')
            if ($jq -ge 0) {
                if ($args[$jq + 1] -cne '.[0].databaseId') { throw "unexpected --jq $($args[$jq + 1])" }
                $first = @($global:GhRuns | ConvertFrom-Json)[0]
                return $first ? "$($first.databaseId)" : ''
            }
            return $global:GhRuns
        }
        if ($args[0] -eq 'run' -and $args[1] -eq 'download') {
            $dir = $args[[array]::IndexOf($args, '--dir') + 1]
            $artifact = Join-Path $dir 'WireToGate-artifact'
            New-Item -ItemType Directory -Path $artifact -Force -WhatIf:$false | Out-Null
            Copy-Item -LiteralPath $global:GhPackage, "$($global:GhPackage).sha256" -Destination $artifact -WhatIf:$false
            return
        }
        $global:LASTEXITCODE = 1
        throw "unexpected gh call: $($args -join ' ')"
    }

    $common = @{
        ControlServerRepository = $clone
        SecretPath = $secretPath
        FakeMesIngestZip = $fakeMesZip
        SshAlias = 'cs552-selftest-no-such-host.invalid'
        WhatIf = $true
    }

    # Runs the script and returns its output lines and the error it ended with, if any.
    function Invoke-Deploy {
        param([hashtable] $Parameters)
        $lines = [System.Collections.Generic.List[string]]::new()
        $err = $null
        $global:GhCalls.Clear()
        $global:SshCalls.Clear()
        try {
            & { & $ScriptPath @Parameters } *>&1 | ForEach-Object { $lines.Add("$_") }
        } catch {
            $err = $_.Exception.Message
        } finally {
            # Each case that wants another installed state sets it just before its call.
            $global:SshAnswer = 'INSTALLED_DEFINITION=ABSENT'
            $global:SshExit = 0
        }
        return [pscustomobject]@{ Lines = $lines.ToArray(); Text = ($lines -join "`n"); Error = $err }
    }
    function Get-Detail { param($Run) "error: $($Run.Error)`n        output: $(($Run.Lines | Select-Object -Last 6) -join ' | ')" }

    # ------------------------------------------------------------------ cases ---

    Write-Host ''
    Write-Host '19-deploy-control-server-parallel.ps1 provenance checks' -ForegroundColor Cyan

    # 1. Same commit.
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('WhatIf: stopping before the server is touched') -and
            $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head") -and $run.Text.Contains("Package onboard commit: $onboardCommit")) `
        -Name 'package built from the clone''s commit: accepted, and the output names the commit and the onboard commit' -Detail (Get-Detail $run)
    # R7 (review): the version line the deployment record is written from.
    Write-Result -Ok ($run.Text.Contains("ADMISSION_POLICY_VERSION=$definitionVersion -- write it into the deployment record")) `
        -Name 'the output carries ADMISSION_POLICY_VERSION=<n> for the deployment record' -Detail (Get-Detail $run)
    # control-server#638 (PR #640 review M1): the clearance switch is shown before anything is touched, under -WhatIf too.
    # The shipped definition leaves it out, which is off, and off warns about nothing.
    Write-Result -Ok ($run.Text.Contains('Clearance to a waiting point (REQ-0178): journeyRuntime.clearanceToWaitingPointEnabled=False') -and
            -not $run.Text.Contains('will drive themselves to a waiting point')) `
        -Name 'the summary shows the clearance switch (off when the definition leaves it out), under -WhatIf' -Detail (Get-Detail $run)
    Write-Result -Ok ($global:SshCalls.Count -eq 1 -and $run.Text.Contains('INSTALLED_ADMISSION_POLICY_VERSION=none')) `
        -Name 'one read-only ssh for the installed version; none installed reads as a first install' -Detail ("ssh: $($global:SshCalls -join ' / ')`n        " + (Get-Detail $run))

    # 2. Different commit.
    $run = Invoke-Deploy ($common + @{ PackagePath = $otherPackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($head) -and $run.Error.Contains($other) -and
            -not $run.Text.Contains('WhatIf: stopping before the server is touched')) `
        -Name 'package built from another commit: refused, with both commits in the message' -Detail (Get-Detail $run)

    # 3. Uncommitted change under scripts/parallel.
    $tracked = Join-Path $clone 'scripts\parallel\ParallelHost.psm1'
    Add-Content -LiteralPath $tracked -Value '# local edit' -Encoding utf8NoBOM
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Invoke-Git $clone @('checkout', '--', 'scripts/parallel/ParallelHost.psm1') | Out-Null
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('scripts/parallel/ParallelHost.psm1') -and $run.Error.Contains('CLONE_NOT_CLEAN')) `
        -Name 'uncommitted change under scripts/parallel: refused, naming the file' -Detail (Get-Detail $run)

    # 3b. The same for a modified definition, and for an untracked file outside scripts/parallel.
    Add-Content -LiteralPath $definitionPath -Value ' ' -Encoding utf8NoBOM
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Invoke-Git $clone @('checkout', '--', 'scripts/parallel/instance-factory01-v2.json') | Out-Null
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('CLONE_NOT_CLEAN')) `
        -Name 'edited definition inside the clone: refused' -Detail (Get-Detail $run)
    $stray = Join-Path $clone 'tools\Stray.cs'
    Set-Content -LiteralPath $stray -Value '// stray' -Encoding utf8NoBOM
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Remove-Item -LiteralPath $stray
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('tools/Stray.cs')) `
        -Name 'untracked file elsewhere in the clone (FakeMesIngest is built from it): refused' -Detail (Get-Detail $run)

    # 3c. Edits git status does not report (review): behind skip-worktree, behind assume-unchanged,
    # and with no mark at all -- same length, write time put back, so the stat data still matches.
    $versionPattern = '("admissionPolicyVersion"\s*:\s*)\d+'
    $originalBytes = [IO.File]::ReadAllBytes($definitionPath)
    $original = [IO.File]::ReadAllText($definitionPath)
    Invoke-Git $clone @('update-index', '--skip-worktree', 'scripts/parallel/instance-factory01-v2.json') | Out-Null
    [IO.File]::WriteAllText($definitionPath, ($original -replace $versionPattern, '${1}9'))
    $statusSeen = "$(Invoke-Git $clone @('status', '--porcelain'))".Trim()
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Invoke-Git $clone @('update-index', '--no-skip-worktree', 'scripts/parallel/instance-factory01-v2.json') | Out-Null
    Invoke-Git $clone @('checkout', '--', 'scripts/parallel/instance-factory01-v2.json') | Out-Null
    Write-Result -Ok ($statusSeen -eq '' -and $null -ne $run.Error -and $run.Error.Contains('CLONE_NOT_CLEAN') -and $run.Error.Contains('skip-worktree')) `
        -Name 'definition edited behind --skip-worktree (git status empty): refused' -Detail ("status: '$statusSeen'`n        " + (Get-Detail $run))

    $module = Join-Path $clone 'scripts\parallel\ParallelInstance.psm1'
    Invoke-Git $clone @('update-index', '--assume-unchanged', 'scripts/parallel/ParallelInstance.psm1') | Out-Null
    Add-Content -LiteralPath $module -Value '# edited behind assume-unchanged' -Encoding utf8NoBOM
    $statusSeen = "$(Invoke-Git $clone @('status', '--porcelain'))".Trim()
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Invoke-Git $clone @('update-index', '--no-assume-unchanged', 'scripts/parallel/ParallelInstance.psm1') | Out-Null
    Invoke-Git $clone @('checkout', '--', 'scripts/parallel/ParallelInstance.psm1') | Out-Null
    Write-Result -Ok ($statusSeen -eq '' -and $null -ne $run.Error -and $run.Error.Contains('CLONE_NOT_CLEAN') -and $run.Error.Contains('assume-unchanged')) `
        -Name 'module edited behind --assume-unchanged (git status empty): refused' -Detail ("status: '$statusSeen'`n        " + (Get-Detail $run))

    # The write time is moved an hour back and the index refreshed first, so the entry is not
    # "racily clean" (a file as new as the index is re-hashed by git status, which would see it).
    $writeTime = (Get-Date).ToUniversalTime().AddHours(-1)
    (Get-Item -LiteralPath $definitionPath).LastWriteTimeUtc = $writeTime
    Invoke-Git $clone @('update-index', '--refresh') | Out-Null
    $edited = $original -replace $versionPattern, '${1}9'
    [IO.File]::WriteAllText($definitionPath, $edited)
    (Get-Item -LiteralPath $definitionPath).LastWriteTimeUtc = $writeTime
    $statusSeen = "$(Invoke-Git $clone @('status', '--porcelain'))".Trim()
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Invoke-Git $clone @('checkout', '--', 'scripts/parallel/instance-factory01-v2.json') | Out-Null
    [IO.File]::WriteAllBytes($definitionPath, $originalBytes)
    Write-Result -Ok ($edited.Length -eq $original.Length -and $statusSeen -eq '' -and $null -ne $run.Error -and
            $run.Error.Contains('CLONE_NOT_CLEAN') -and $run.Error.Contains('differs from HEAD')) `
        -Name 'definition edited with no mark, same size and write time (git status empty): refused by content hash' -Detail ("status: '$statusSeen'`n        " + (Get-Detail $run))
    if ("$(Invoke-Git $clone @('status', '--porcelain'))".Trim() -ne '' -or "$(Invoke-Git $clone @('diff', '--stat', 'HEAD'))".Trim() -ne '') {
        throw 'fixture clone not restored after the hash case'
    }

    # 4. Definition outside the clone.
    $outsideDefinition = Join-Path $outside 'instance-factory01-v2.json'
    Copy-Item -LiteralPath $definitionPath -Destination $outsideDefinition
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; InstanceDefinitionPath = $outsideDefinition })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('DEFINITION_NOT_FROM_CLONE')) `
        -Name '-InstanceDefinitionPath outside the clone: refused' -Detail (Get-Detail $run)
    # Inside the clone but ignored: 'git status' does not see it, so the clean check cannot either.
    $ignoredDefinition = Join-Path $clone 'local\instance-factory01-v2.json'
    New-Item -ItemType Directory -Path (Split-Path $ignoredDefinition) -Force | Out-Null
    Copy-Item -LiteralPath $definitionPath -Destination $ignoredDefinition
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; InstanceDefinitionPath = $ignoredDefinition })
    Remove-Item -LiteralPath (Split-Path $ignoredDefinition) -Recurse -Force
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('DEFINITION_NOT_FROM_CLONE')) `
        -Name '-InstanceDefinitionPath inside the clone but git-ignored (untracked): refused' -Detail (Get-Detail $run)
    $run = Invoke-Deploy ($common + @{ Rollback = $true; InstanceDefinitionPath = $outsideDefinition; AdmissionPolicyVersionOverride = ($definitionVersion + 1) })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('DEFINITION_NOT_FROM_CLONE')) `
        -Name '-InstanceDefinitionPath outside the clone on -Rollback: refused too' -Detail (Get-Detail $run)

    # 5. Rollback.
    $common.Remove('FakeMesIngestZip')
    $run = Invoke-Deploy ($common + @{ Rollback = $true })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('-AdmissionPolicyVersionOverride') -and $run.Error.Contains('+ 1')) `
        -Name '-Rollback without -AdmissionPolicyVersionOverride: refused, saying to pass the highest installed version + 1' -Detail (Get-Detail $run)
    $override = $definitionVersion + 1
    $run = Invoke-Deploy ($common + @{ Rollback = $true; AdmissionPolicyVersionOverride = $override })
    Write-Result -Ok ($null -eq $run.Error -and
            $run.Text.Contains("ADMISSION_POLICY_VERSION_OVERRIDE=$override definition=$definitionVersion reason=") -and
            $run.Text.Contains("journeyRuntime.admissionPolicyVersion=$override read back from the derived definition") -and
            $run.Text.Contains('WhatIf: rollback stops before the server is touched.')) `
        -Name "-Rollback -AdmissionPolicyVersionOverride ${override}: accepted, override and reason printed, value read back" -Detail (Get-Detail $run)
    $run = Invoke-Deploy ($common + @{ Rollback = $true; AdmissionPolicyVersionOverride = $definitionVersion })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('ADMISSION_POLICY_VERSION_OVERRIDE_NOT_ABOVE_DEFINITION')) `
        -Name "-Rollback with an override equal to the definition's own version: refused" -Detail (Get-Detail $run)

    # R6 (review): a rollback still sends the clone's scripts, so it is held to a clean clone too.
    # The edit is to a tracked file that is not sent, so only the clean check can see it (the
    # content check of the sent files would catch an edit to one of them on its own).
    $notSent = Join-Path $clone 'tools\README.md'
    Add-Content -LiteralPath $notSent -Value 'local edit' -Encoding utf8NoBOM
    $run = Invoke-Deploy ($common + @{ Rollback = $true; AdmissionPolicyVersionOverride = $override })
    Invoke-Git $clone @('checkout', '--', 'tools/README.md') | Out-Null
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('CLONE_NOT_CLEAN')) `
        -Name "-Rollback -AdmissionPolicyVersionOverride $override from a dirty clone: refused" -Detail (Get-Detail $run)

    # The installed version on the server (review, item 2): a rollback must go above it.
    $global:SshAnswer = "INSTALLED_DEFINITION=PRESENT version=$override"
    $run = Invoke-Deploy ($common + @{ Rollback = $true; AdmissionPolicyVersionOverride = $override })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('ADMISSION_POLICY_VERSION_BELOW_INSTALLED') -and
            $run.Error.Contains("-AdmissionPolicyVersionOverride $($override + 1)")) `
        -Name "-Rollback with override $override when $override is installed (rolling back a rollback with the same N): refused, says $($override + 1)" -Detail (Get-Detail $run)
    $global:SshAnswer = "INSTALLED_DEFINITION=PRESENT version=$definitionVersion"
    $run = Invoke-Deploy ($common + @{ Rollback = $true; AdmissionPolicyVersionOverride = $override })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains("INSTALLED_ADMISSION_POLICY_VERSION=$definitionVersion") -and
            $run.Text.Contains('WhatIf: rollback stops before the server is touched.')) `
        -Name "-Rollback with override $override when $definitionVersion is installed: accepted, installed version printed" -Detail (Get-Detail $run)
    $common['FakeMesIngestZip'] = $fakeMesZip

    # 5b. An install may raise the version too (re-installing after a rollback), and still needs the same commit.
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; AdmissionPolicyVersionOverride = $override + 1 })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains("ADMISSION_POLICY_VERSION_OVERRIDE=$($override + 1) definition=$definitionVersion") -and
            $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head")) `
        -Name 'install with an override: accepted, override printed, same-commit check still made' -Detail (Get-Detail $run)
    $run = Invoke-Deploy ($common + @{ PackagePath = $otherPackage; AdmissionPolicyVersionOverride = $override + 1 })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($other)) `
        -Name 'install with an override and a package from another commit: still refused' -Detail (Get-Detail $run)

    # 5d. An install after a rollback (review, item 2): the factory version is below what is installed.
    $global:SshAnswer = "INSTALLED_DEFINITION=PRESENT version=$override"
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('ADMISSION_POLICY_VERSION_BELOW_INSTALLED') -and
            $run.Error.Contains("-AdmissionPolicyVersionOverride $($override + 1)")) `
        -Name "install without an override when $override is installed (after a rollback): refused, says $($override + 1)" -Detail (Get-Detail $run)
    $global:SshAnswer = "INSTALLED_DEFINITION=PRESENT version=$definitionVersion"
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains("INSTALLED_ADMISSION_POLICY_VERSION=$definitionVersion")) `
        -Name 'install with the version already installed (same seed again): accepted' -Detail (Get-Detail $run)
    $global:SshAnswer = "INSTALLED_DEFINITION=PRESENT version=$override"
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; AdmissionPolicyVersionOverride = $override + 1 })
    Write-Result -Ok ($null -eq $run.Error) `
        -Name "install with override $($override + 1) when $override is installed: accepted" -Detail (Get-Detail $run)
    $global:SshExit = 255
    $global:SshAnswer = 'ssh: Could not resolve hostname'
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('INSTALLED_VERSION_UNREAD')) `
        -Name 'installed version unreadable (ssh fails): refused' -Detail (Get-Detail $run)
    $global:SshAnswer = 'INSTALLED_DEFINITION=UNREADABLE bad json'
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('INSTALLED_VERSION_UNREAD')) `
        -Name 'installed definition present but unreadable: refused' -Detail (Get-Detail $run)

    # 5c. A refusal after the derived copy exists but before the install's try (here: the secret
    # store lacks a key) still removes the copy, and the refusal reaches the caller unchanged.
    $thinSecrets = Join-Path $work 'secrets-thin.xml'
    @{ RiotCallApiKey = (& $fake 'k') } | Export-Clixml -LiteralPath $thinSecrets
    $before = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'control-server-v2-definition-*' | ForEach-Object FullName)
    $thin = $common.Clone(); $thin['SecretPath'] = $thinSecrets
    $run = Invoke-Deploy ($thin + @{ PackagePath = $samePackage; AdmissionPolicyVersionOverride = $override })
    $left = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'control-server-v2-definition-*' | ForEach-Object FullName | Where-Object { $before -notcontains $_ })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains("'OnboardCredential' is missing") -and $left.Count -eq 0) `
        -Name 'refused after the derived definition was written: the copy is removed, the refusal unchanged' -Detail ("left: $($left -join ', ')`n        " + (Get-Detail $run))

    # 6. Manifest.
    $run = Invoke-Deploy ($common + @{ PackagePath = $noManifestPackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('release-manifest.json')) `
        -Name 'package without release-manifest.json: refused' -Detail (Get-Detail $run)
    # R2 (review): a manifest in a subdirectory is not the package's own.
    $run = Invoke-Deploy ($common + @{ PackagePath = $nestedPackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('PACKAGE_MANIFEST_MISSING')) `
        -Name 'release-manifest.json only in a subdirectory of the zip: refused' -Detail (Get-Detail $run)
    $run = Invoke-Deploy ($common + @{ PackagePath = $noCommitPackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('components.controlServer.commit')) `
        -Name 'manifest without components.controlServer.commit: refused' -Detail (Get-Detail $run)

    # 7. control-server#600: a roster definition needs one projection credential per vehicle from the store. Only when
    # the fixture's revision ships the two-car example (control-server#571 and later).
    $twoCar = Join-Path $clone 'scripts\parallel\instance-factory01-v2.two-car-example.json'
    if (Test-Path -LiteralPath $twoCar) {
        $fleetKeys = @((Get-Content -LiteralPath $twoCar -Raw | ConvertFrom-Json -AsHashtable)['journeyRuntime']['fleet'] | ForEach-Object { [string] $_['vehicleKey'] })
        $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; InstanceDefinitionPath = $twoCar })
        Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('control-server#600') -and
                @($fleetKeys | Where-Object { -not $run.Error.Contains($_) }).Count -eq 0 -and $run.Error.Contains('Nothing was downloaded or copied') -and
                -not $run.Text.Contains('WhatIf: stopping before the server is touched')) `
            -Name 'two-car definition without per-vehicle projection credentials in the store: refused, naming both vehicles' -Detail (Get-Detail $run)

        $safetySecrets = Join-Path $work 'secrets-safety.xml'
        $withSafety = Import-Clixml -LiteralPath $secretPath
        foreach ($key in $fleetKeys) { $withSafety["OnboardSafetyCredential:$key"] = & $fake "selftest-safety-$key" }
        $withSafety | Export-Clixml -LiteralPath $safetySecrets
        $safe = $common.Clone(); $safe['SecretPath'] = $safetySecrets
        $run = Invoke-Deploy ($safe + @{ PackagePath = $samePackage; InstanceDefinitionPath = $twoCar })
        Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('WhatIf: stopping before the server is touched') -and
                $run.Text.Contains("Vehicle-safety projection credentials loaded for $($fleetKeys -join ', ') (values not shown)") -and
                -not $run.Text.Contains('selftest-safety-')) `
            -Name 'two-car definition with both credentials: accepted, names the vehicles and never a value' -Detail (Get-Detail $run)

        $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
        Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('Vehicle-safety projection: single car, shared onboard credential')) `
            -Name 'single-car definition: no per-vehicle credential asked for' -Detail (Get-Detail $run)
    } else {
        Write-Host "  SKIP  two-car cases: $ControlServerRef ships no two-car example" -ForegroundColor Yellow
    }

    # 7. Default package: looked up by the clone's commit.
    $global:GhRuns = "[{`"databaseId`":111,`"headSha`":`"$head`",`"headBranch`":`"fp/v2-impl`",`"createdAt`":`"2026-10-10T10:00:00Z`"}]"
    $global:GhPackage = $samePackage
    $run = Invoke-Deploy $common
    $listCall = @($global:GhCalls | Where-Object { $_ -like 'run list*' })
    Write-Result -Ok ($null -eq $run.Error -and $listCall.Count -eq 1 -and $listCall[0].Contains("--commit $head") -and
            $listCall[0].Contains('--json databaseId,headSha,headBranch,createdAt') -and
            $run.Text.Contains('run 111') -and $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head")) `
        -Name 'no -RunId/-PackagePath: the release run is looked up by the clone''s commit, and named' -Detail ("gh: $($global:GhCalls -join ' / ')`n        " + (Get-Detail $run))
    $global:GhRuns = '[]'
    $run = Invoke-Deploy $common
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($head) -and @($global:GhCalls | Where-Object { $_ -like 'run download*' }).Count -eq 0) `
        -Name 'no release run for the clone''s commit: refused, nothing downloaded' -Detail (Get-Detail $run)
    foreach ($answer in @('null', '')) {
        $global:GhRuns = $answer
        $run = Invoke-Deploy $common
        Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('RELEASE_RUN_NOT_FOUND')) `
            -Name "gh run list answering '$answer': RELEASE_RUN_NOT_FOUND, not a StrictMode error" -Detail (Get-Detail $run)
    }
    $global:GhRuns = "[{`"databaseId`":222,`"headSha`":`"$other`",`"headBranch`":`"fp/v2-impl`",`"createdAt`":`"2026-10-10T10:00:00Z`"}]"
    $run = Invoke-Deploy $common
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($other) -and @($global:GhCalls | Where-Object { $_ -like 'run download*' }).Count -eq 0) `
        -Name 'a lookup answering with a run from another commit: refused before download' -Detail (Get-Detail $run)

    # 7b. An explicit -RunId is checked the same way, on the downloaded package.
    $global:GhPackage = $otherPackage
    $run = Invoke-Deploy ($common + @{ RunId = '333' })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($other) -and $run.Error.Contains($head)) `
        -Name '-RunId whose package is from another commit: refused after download' -Detail (Get-Detail $run)
} finally {
    Remove-Item function:global:gh, function:global:ssh -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name GhCalls, GhRuns, GhPackage, SshCalls, SshAnswer, SshExit -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
