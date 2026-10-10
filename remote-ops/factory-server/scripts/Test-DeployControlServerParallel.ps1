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
      * a package without release-manifest.json, or without components.controlServer.commit: refused;
      * no -RunId/-PackagePath: the release run is looked up by the clone's commit, not "latest", and
        a lookup that finds none, or one built from another commit, is refused.
    Plus ParseFile with zero errors for the deploy script and for this file: the AST walk below would
    swallow a syntax error that a real run would hit.

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
    function New-Manifest { param([string] $Commit) @{ schemaVersion = 1; components = @{ controlServer = @{ commit = $Commit; branch = 'fp/v2-impl' } } } }

    $samePackage = New-Package -Name 'same' -Manifest (New-Manifest $head)
    $otherPackage = New-Package -Name 'other' -Manifest (New-Manifest $other)
    $noManifestPackage = New-Package -Name 'nomanifest' -Manifest $null
    $noCommitPackage = New-Package -Name 'nocommit' -Manifest @{ schemaVersion = 1; components = @{ controlServer = @{ branch = 'fp/v2-impl' } } }

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
        try {
            & { & $ScriptPath @Parameters } *>&1 | ForEach-Object { $lines.Add("$_") }
        } catch {
            $err = $_.Exception.Message
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
            $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head")) `
        -Name 'package built from the clone''s commit: accepted, and the output names the commit' -Detail (Get-Detail $run)

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
    $common['FakeMesIngestZip'] = $fakeMesZip

    # 5b. An install may raise the version too (re-installing after a rollback), and still needs the same commit.
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; AdmissionPolicyVersionOverride = $override + 1 })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains("ADMISSION_POLICY_VERSION_OVERRIDE=$($override + 1) definition=$definitionVersion") -and
            $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head")) `
        -Name 'install with an override: accepted, override printed, same-commit check still made' -Detail (Get-Detail $run)
    $run = Invoke-Deploy ($common + @{ PackagePath = $otherPackage; AdmissionPolicyVersionOverride = $override + 1 })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($other)) `
        -Name 'install with an override and a package from another commit: still refused' -Detail (Get-Detail $run)

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
    $run = Invoke-Deploy ($common + @{ PackagePath = $noCommitPackage })
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('components.controlServer.commit')) `
        -Name 'manifest without components.controlServer.commit: refused' -Detail (Get-Detail $run)

    # 7. Default package: looked up by the clone's commit.
    $global:GhRuns = "[{`"databaseId`":111,`"headSha`":`"$head`",`"headBranch`":`"fp/v2-impl`",`"createdAt`":`"2026-10-10T10:00:00Z`"}]"
    $global:GhPackage = $samePackage
    $run = Invoke-Deploy $common
    $listCall = @($global:GhCalls | Where-Object { $_ -like 'run list*' })
    Write-Result -Ok ($null -eq $run.Error -and $listCall.Count -eq 1 -and $listCall[0].Contains("--commit $head") -and
            $run.Text.Contains('run 111') -and $run.Text.Contains("PACKAGE_COMMIT_MATCHES_CLONE=$head")) `
        -Name 'no -RunId/-PackagePath: the release run is looked up by the clone''s commit, and named' -Detail ("gh: $($global:GhCalls -join ' / ')`n        " + (Get-Detail $run))
    $global:GhRuns = '[]'
    $run = Invoke-Deploy $common
    Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains($head) -and @($global:GhCalls | Where-Object { $_ -like 'run download*' }).Count -eq 0) `
        -Name 'no release run for the clone''s commit: refused, nothing downloaded' -Detail (Get-Detail $run)
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
    Remove-Item function:global:gh -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name GhCalls, GhRuns, GhPackage -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
