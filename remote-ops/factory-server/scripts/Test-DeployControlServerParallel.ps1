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
        a lookup that finds none, or one built from another commit, is refused;
      * after the install or the rollback (control-server#672), the installer's EFFECTIVE_JOURNEY_BINDING= line
        against the definition sent: any difference refused, no line refused, not-logged refused on an install
        and warned on -Rollback -- checked on Assert-JourneyBindingReported lifted out by its AST.
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

# control-server#564: the switches handed on to the server's installer (MW1), and the server's report under the cutover (M1).
Write-Host ''
Write-Host 'Production cutover in the deploy script (control-server#564)' -ForegroundColor Cyan
foreach ($name in @('Get-InstallerSwitchArgument', 'Assert-MesIngestSourceReported')) {
    $found = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $found) { Write-Result -Ok $false -Name "$name is defined in the deploy script" -Detail 'not found' } else { . ([scriptblock]::Create($found.Extent.Text)) }
}
if (Get-Command Get-InstallerSwitchArgument -ErrorAction SilentlyContinue) {
    foreach ($case in @(
            @{ A = $false; P = $false; L = $false; Expect = '' }
            @{ A = $true; P = $false; L = $false; Expect = ' -AllowRiotCreateDispatch' }
            @{ A = $false; P = $true; L = $false; Expect = ' -ProductionCutover' }
            @{ A = $true; P = $true; L = $false; Expect = ' -AllowRiotCreateDispatch -ProductionCutover' }
            @{ A = $false; P = $false; L = $true; Expect = ' -LeaveProductionCutover' })) {
        $got = Get-InstallerSwitchArgument -AllowRiotCreateDispatch $case.A -ProductionCutover $case.P -LeaveProductionCutover $case.L
        Write-Result -Ok ($got -ceq $case.Expect) -Name "installer switches: '$($case.Expect)'" -Detail "got '$got'"
    }
    $switchCalls = @($deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-InstallerSwitchArgument' }, $true))
    $scriptText19 = Get-Content -LiteralPath $ScriptPath -Raw
    Write-Result -Ok ($switchCalls.Count -eq 2 -and @($switchCalls | Where-Object { $_.Extent.Text.Contains('-ProductionCutover $ProductionCutover -LeaveProductionCutover $LeaveProductionCutover') }).Count -eq 2 -and
            ([regex]::Matches($scriptText19, '\$allow = Get-InstallerSwitchArgument')).Count -eq 2 -and -not $scriptText19.Contains("? ' -ProductionCutover' : '')`n")) `
        -Name 'the install and the rollback command both take their switches from Get-InstallerSwitchArgument' -Detail "calls $($switchCalls.Count)"
}
if (Get-Command Assert-MesIngestSourceReported -ErrorAction SilentlyContinue) {
    function Write-Step { param([string] $Message) }
    $six = @('DIE_TO_WIRE_STAGING', 'DIE_TO_OVEN', 'WIRE_TO_GATE', 'WIRE_TO_OPTICAL', 'STAGING_TO_WIRE', 'WIRE_TO_NITROGEN')
    $definition = @{ mesIngest = @{ source = 'production'; baseUrl = 'http://127.0.0.1:5088' }; journeyRuntime = @{ allowedWorkTypes = $six; allowedDispatchZones = @('WIRE_BONDING') } }
    $sourceProperty = [pscustomobject]@{ Value = 'production' }; $mesIngestSource = 'production'; $productionSource = $true
    $cutoverAudit = "MES_INGEST_SOURCE=production baseUrl=http://127.0.0.1:5088 allowedWorkTypes=$($six -join ',') -- PRODUCTION CUTOVER (trial): this instance reads the PRODUCTION MesIngest for all six task types and drives agv01; the MVP must be stopped (control-server#564)"
    $cutoverEffective = "EFFECTIVE_CONFIGURATION=allowedWorkTypes=$($six -join ',') allowedDispatchZones=WIRE_BONDING mesIngestBaseUrl=http://127.0.0.1:5088"
    function Get-ReportVerdict([object[]] $Lines) { try { Assert-MesIngestSourceReported -Output $Lines; return 'OK' } catch { return $_.Exception.Message } }
    $ProductionCutover = $true
    $v = Get-ReportVerdict @($cutoverAudit, $cutoverEffective)
    Write-Result -Ok ($v -ceq 'OK') -Name 'server report under -ProductionCutover: the six types and PRODUCTION CUTOVER are accepted' -Detail $v
    $v = Get-ReportVerdict @(($cutoverAudit -replace ' -- PRODUCTION CUTOVER.*$', ' -- this instance reads the PRODUCTION MesIngest the MVP also reads; it may take STAGING_TO_WIRE only'), $cutoverEffective)
    Write-Result -Ok ($v.StartsWith('MES_INGEST_SOURCE_MISMATCH: production cutover')) -Name 'server report under -ProductionCutover without the cutover wording (an old installer) is refused' -Detail $v
    $v = Get-ReportVerdict @($cutoverAudit, $cutoverEffective, 'FAKE_MES_INGEST=x')
    Write-Result -Ok ($v.StartsWith('MES_INGEST_SOURCE_MISMATCH: production cutover, but the installer also reported')) -Name 'server report under -ProductionCutover with a FAKE_MES_INGEST line is refused' -Detail $v
    $v = Get-ReportVerdict @($cutoverAudit, ($cutoverEffective -replace 'WIRE_TO_NITROGEN', 'X'))
    Write-Result -Ok ($v.StartsWith('EFFECTIVE_CONFIGURATION_MISMATCH:')) -Name 'server report under -ProductionCutover with a different bound list is refused' -Detail $v
    $ProductionCutover = $false
    $v = Get-ReportVerdict @($cutoverAudit, $cutoverEffective)
    Write-Result -Ok ($v.StartsWith('MES_INGEST_SOURCE_MISMATCH: production mode')) -Name 'the same six-type report without -ProductionCutover is refused, as before' -Detail $v
    $definition['journeyRuntime']['allowedWorkTypes'] = @('STAGING_TO_WIRE')
    $v = Get-ReportVerdict @('MES_INGEST_SOURCE=production baseUrl=http://127.0.0.1:5088 allowedWorkTypes=STAGING_TO_WIRE -- this instance reads ...', 'EFFECTIVE_CONFIGURATION=allowedWorkTypes=STAGING_TO_WIRE allowedDispatchZones=WIRE_BONDING mesIngestBaseUrl=http://127.0.0.1:5088')
    Write-Result -Ok ($v -ceq 'OK') -Name 'the parallel production report without -ProductionCutover is accepted, as before' -Detail $v
    Remove-Item function:Write-Step
    Remove-Variable definition, sourceProperty, mesIngestSource, productionSource, ProductionCutover -ErrorAction SilentlyContinue
}

# control-server#672: after the install and the rollback, the admission policy version and label and the two waits the
# Host bound (the installer's EFFECTIVE_JOURNEY_BINDING= line, read from its EFFECTIVE_CONFIGURATION event) are compared
# with the definition 19 sent -- the derived copy under -AdmissionPolicyVersionOverride.
Write-Host ''
Write-Host 'Admission policy and waits read back after the install (control-server#672)' -ForegroundColor Cyan
$bindingAst = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-JourneyBindingReported' }, $true)
if ($null -eq $bindingAst) {
    Write-Result -Ok $false -Name 'Assert-JourneyBindingReported is defined in the deploy script' -Detail 'not found'
} else {
    . ([scriptblock]::Create($bindingAst.Extent.Text))
    function Write-Step { param([string] $Message) }
    $definition = @{ journeyRuntime = @{ admissionPolicyVersion = 6; admissionPolicyDeploymentId = 'MAP-26-WIRE_TO_GATE-20261007'; cargoHoldingTimeout = '00:05:00'; stationDepartureWaitTimeout = '00:05:00' } }
    $asDefined = 'EFFECTIVE_JOURNEY_BINDING=admissionPolicyVersion=6 admissionPolicyDeploymentId=MAP-26-WIRE_TO_GATE-20261007 cargoHoldingTimeout=00:05:00 stationDepartureWaitTimeout=00:05:00'
    $other = 'MES_INGEST_SOURCE=fake baseUrl=http://127.0.0.1:58188 allowedWorkTypes=STAGING_TO_WIRE'
    $effectiveLine = 'EFFECTIVE_CONFIGURATION=allowedWorkTypes=STAGING_TO_WIRE allowedDispatchZones=WIRE_BONDING mesIngestBaseUrl=http://127.0.0.1:58188'
    $productionSource = $false
    function Get-BindingVerdict([object[]] $Lines, [switch] $Rollback) {
        $warnings = $null
        try { Assert-JourneyBindingReported -Output $Lines -Rollback:$Rollback -WarningVariable warnings -WarningAction SilentlyContinue; return ($warnings ? "WARN $warnings" : 'OK') } catch { return $_.Exception.Message }
    }
    foreach ($case in @(
            @{ Name = 'bound as defined: accepted'; Lines = @($other, $asDefined); Expect = 'OK' }
            @{ Name = 'bound as defined, on -Rollback: accepted'; Lines = @($asDefined); Rollback = $true; Expect = 'OK' }
            @{ Name = 'version 5 bound where 6 was sent: refused, naming the field'; Lines = @($asDefined -replace 'Version=6 ', 'Version=5 '); Expect = "EFFECTIVE_JOURNEY_BINDING_MISMATCH: admissionPolicyVersion bound '5', the definition says '6'" }
            @{ Name = 'another deployment label: refused'; Lines = @($asDefined -replace '20261007', '20260827'); Expect = "EFFECTIVE_JOURNEY_BINDING_MISMATCH: admissionPolicyDeploymentId bound 'MAP-26-WIRE_TO_GATE-20260827'" }
            @{ Name = 'cargo holding 00:30:00 bound (the 2026-10-12 field case): refused'; Lines = @($asDefined -replace 'cargoHoldingTimeout=00:05:00', 'cargoHoldingTimeout=00:30:00'); Expect = "EFFECTIVE_JOURNEY_BINDING_MISMATCH: cargoHoldingTimeout bound '00:30:00', the definition says '00:05:00'" }
            @{ Name = 'station departure 00:30:00 bound: refused'; Lines = @($asDefined -replace 'stationDepartureWaitTimeout=00:05:00', 'stationDepartureWaitTimeout=00:30:00'); Expect = "EFFECTIVE_JOURNEY_BINDING_MISMATCH: stationDepartureWaitTimeout bound '00:30:00', the definition says '00:05:00'" }
            @{ Name = 'a mismatch on -Rollback is refused too'; Lines = @($asDefined -replace 'Version=6 ', 'Version=5 '); Rollback = $true; Expect = 'EFFECTIVE_JOURNEY_BINDING_MISMATCH: admissionPolicyVersion' }
            @{ Name = 'the last line counts (the Released read-back comes after the Held one)'; Lines = @(($asDefined -replace 'Version=6 ', 'Version=5 '), $asDefined); Expect = 'OK' }
            @{ Name = 'a line missing one of the four: refused'; Lines = @('EFFECTIVE_JOURNEY_BINDING=admissionPolicyVersion=6'); Expect = 'EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported' }
            @{ Name = 'a line naming a field twice: refused'; Lines = @("$asDefined admissionPolicyVersion=5"); Expect = 'EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported' }
            @{ Name = 'a line that is not name=value pairs: refused'; Lines = @('EFFECTIVE_JOURNEY_BINDING=6 MAP-26'); Expect = 'EFFECTIVE_JOURNEY_BINDING_MISMATCH: the installer reported' }
            @{ Name = 'a field the installer adds later (cs#686) is ignored, the four still compared'; Lines = @("$asDefined slotReadinessGate=enforce"); Expect = 'OK' }
            @{ Name = 'fields in another order are read by name'; Lines = @('EFFECTIVE_JOURNEY_BINDING=stationDepartureWaitTimeout=00:05:00 cargoHoldingTimeout=00:05:00 admissionPolicyDeploymentId=MAP-26-WIRE_TO_GATE-20261007 admissionPolicyVersion=6'); Expect = 'OK' }
            @{ Name = 'EFFECTIVE_CONFIGURATION= but no EFFECTIVE_JOURNEY_BINDING line (installer scripts older than control-server#672): refused, naming the checkout, on -Rollback too'; Lines = @($other, $effectiveLine); Rollback = $true; Expect = 'EFFECTIVE_JOURNEY_BINDING_UNREAD: the installer reported an EFFECTIVE_CONFIGURATION= line' }
            # Review S1 (Q5): neither line -- the installer read no event and, in fake mode, only warned. Not the checkout's fault.
            @{ Name = 'neither result line, fake mode, on -Rollback: warned, not refused'; Lines = @($other); Rollback = $true; Expect = 'WARN EFFECTIVE_JOURNEY_BINDING_UNREAD: the installer read no EFFECTIVE_CONFIGURATION event' }
            @{ Name = 'neither result line, fake mode, on an install: warned, as for the EFFECTIVE_CONFIGURATION= line'; Lines = @($other); Expect = 'WARN EFFECTIVE_JOURNEY_BINDING_UNREAD: the installer read no EFFECTIVE_CONFIGURATION event' }
            @{ Name = 'neither result line, production mode, on -Rollback: refused'; Lines = @($other); Rollback = $true; Production = $true; Expect = 'EFFECTIVE_JOURNEY_BINDING_UNREAD: the installer read no EFFECTIVE_CONFIGURATION event' }
            @{ Name = 'not logged (a package older than control-server#672) on an install: refused'; Lines = @('EFFECTIVE_JOURNEY_BINDING=not-logged'); Expect = 'EFFECTIVE_JOURNEY_BINDING_NOT_LOGGED:' }
            @{ Name = 'not logged on -Rollback: warned, not refused'; Lines = @('EFFECTIVE_JOURNEY_BINDING=not-logged'); Rollback = $true; Expect = 'WARN EFFECTIVE_JOURNEY_BINDING_NOT_LOGGED:' })) {
        $productionSource = [bool] $case['Production']
        $v = Get-BindingVerdict $case.Lines -Rollback:([bool] $case['Rollback'])
        Write-Result -Ok ($case.Expect -ceq 'OK' ? ($v -ceq 'OK') : $v.StartsWith($case.Expect, [StringComparison]::Ordinal)) -Name "journey binding: $($case.Name)" -Detail "got: $v"
    }
    $productionSource = $false
    # A key the definition leaves out: the package's appsettings.json decides, so it is printed, not compared.
    $definition['journeyRuntime'].Remove('stationDepartureWaitTimeout')
    $v = Get-BindingVerdict @($asDefined -replace 'stationDepartureWaitTimeout=00:05:00', 'stationDepartureWaitTimeout=00:30:00')
    Write-Result -Ok ($v -ceq 'OK') -Name 'journey binding: a key the definition leaves out is not compared' -Detail "got: $v"
    # The version compared is the one sent: under -AdmissionPolicyVersionOverride $definition is the derived copy.
    $definition['journeyRuntime']['admissionPolicyVersion'] = 7
    $v = Get-BindingVerdict @($asDefined)
    Write-Result -Ok ($v.StartsWith("EFFECTIVE_JOURNEY_BINDING_MISMATCH: admissionPolicyVersion bound '6', the definition says '7'", [StringComparison]::Ordinal)) -Name 'journey binding: compared with $definition as it stands (the derived copy after an override)' -Detail "got: $v"
    Remove-Item function:Write-Step
    Remove-Variable definition, productionSource, effectiveLine -ErrorAction SilentlyContinue
    # Both read-backs call it, right after Assert-MesIngestSourceReported, with -Rollback on the rollback only.
    $scriptText672 = Get-Content -LiteralPath $ScriptPath -Raw
    $bindingCalls = @($deployAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-JourneyBindingReported' }, $true))
    Write-Result -Ok ($bindingCalls.Count -eq 2 -and
            [regex]::IsMatch($scriptText672, 'Assert-MesIngestSourceReported -Output \$rollbackOutput -Rollback\s+Assert-JourneyBindingReported -Output \$rollbackOutput -Rollback') -and
            [regex]::IsMatch($scriptText672, 'Assert-MesIngestSourceReported -Output \$installOutput\s+Assert-JourneyBindingReported -Output \$installOutput\s')) `
        -Name 'journey binding: checked after the install and after the rollback' -Detail "calls $($bindingCalls.Count)"
}

# workspace#49: the two emergency stop release credentials. Hand-made definitions, so this holds whatever the fixture's
# revision knows; the end-to-end -WhatIf cases further down run the real script.
Write-Host ''
Write-Host 'Emergency stop release entries (workspace#49)' -ForegroundColor Cyan
foreach ($name in @('Test-EmergencyReleaseOn', 'Get-EmergencyReleaseCredentialRefusal', 'Format-EmergencyReleaseSummary', 'Assert-EmergencyReleaseReported', 'Get-EmergencyReleaseProbeVerdict', 'Invoke-EmergencyReleaseProbe')) {
    $found = $deployAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $found) { Write-Result -Ok $false -Name "$name is defined in the deploy script" -Detail 'not found' } else { . ([scriptblock]::Create($found.Extent.Text)) }
}
function New-ReleaseDefinition($Enabled) {
    $d = [ordered]@{ instanceId = 'selftest' }
    if ($null -ne $Enabled) { $d['emergencyStopRelease'] = @{ enabled = $Enabled } }
    return $d
}
$bothKeys = @('EmergencyReleaseCredential', 'EmergencyLoadedReleaseCredential')
if (Get-Command Get-EmergencyReleaseCredentialRefusal -ErrorAction SilentlyContinue) {
    foreach ($case in @(
            @{ Name = 'on, both in the store'; Enabled = $true; Present = $bothKeys; Missing = @() }
            @{ Name = 'on, the loaded one missing'; Enabled = $true; Present = @('EmergencyReleaseCredential'); Missing = @('EmergencyLoadedReleaseCredential') }
            @{ Name = 'on, the empty-vehicle one missing'; Enabled = $true; Present = @('EmergencyLoadedReleaseCredential'); Missing = @('EmergencyReleaseCredential') }
            @{ Name = 'on, neither'; Enabled = $true; Present = @(); Missing = $bothKeys }
            @{ Name = 'off, neither'; Enabled = $false; Present = @(); Missing = @() }
            @{ Name = 'no section (a definition before workspace#49), neither'; Enabled = $null; Present = @(); Missing = @() }
            @{ Name = 'enabled as the string "true" (the definition check refuses it), neither'; Enabled = 'true'; Present = @(); Missing = @() })) {
        $r = Get-EmergencyReleaseCredentialRefusal -Definition (New-ReleaseDefinition $case.Enabled) -Present $case.Present -SecretPath 'C:\selftest\secrets.xml'
        $ok = ($case.Missing.Count -eq 0) ? ($null -eq $r) :
            ($r -is [string] -and $r.StartsWith('EMERGENCY_RELEASE_CREDENTIAL_MISSING: emergencyStopRelease.enabled is true') -and
                @($case.Missing | Where-Object { -not $r.Contains("'$_'") }).Count -eq 0 -and
                @($bothKeys | Where-Object { $case.Missing -notcontains $_ -and $r.Contains("'$_'") }).Count -eq 0 -and
                $r.Contains('C:\selftest\secrets.xml') -and $r.Contains('-NewEmergencyReleaseCredential') -and $r.EndsWith('Nothing was downloaded or copied.'))
        Write-Result -Ok $ok -Name "release credential precheck: $($case.Name) -> $($case.Missing.Count -eq 0 ? 'accepted' : 'refused')" -Detail "got: $r"
    }
}
if (Get-Command Format-EmergencyReleaseSummary -ErrorAction SilentlyContinue) {
    foreach ($case in @(
            @{ Enabled = $true; Present = $bothKeys; Expect = 'EMERGENCY_STOP_RELEASE_REQUESTED=enabled=true credential=present loadedCredential=present (both sent; values not shown)' }
            @{ Enabled = $false; Present = @(); Expect = 'EMERGENCY_STOP_RELEASE_REQUESTED=enabled=false credential=absent loadedCredential=absent (the server keeps what its service already holds)' }
            @{ Enabled = $null; Present = @('EmergencyReleaseCredential'); Expect = 'EMERGENCY_STOP_RELEASE_REQUESTED=enabled=false credential=present loadedCredential=absent (sent where present; values not shown)' })) {
        $got = Format-EmergencyReleaseSummary -Definition (New-ReleaseDefinition $case.Enabled) -Present $case.Present
        Write-Result -Ok ($got -ceq $case.Expect) -Name "release summary: $($case.Expect)" -Detail "got '$got'"
    }
}
if (Get-Command Assert-EmergencyReleaseReported -ErrorAction SilentlyContinue) {
    function Write-Step { param([string] $Message) }
    function Get-ReleaseReportVerdict($Definition, [object[]] $Lines) {
        try { $null = Assert-EmergencyReleaseReported -Output $Lines -Definition $Definition 3>$null; return 'OK' } catch { return $_.Exception.Message }
    }
    $on = New-ReleaseDefinition $true
    $productionOn = New-ReleaseDefinition $true; $productionOn['productionCutover'] = @{ approvalRecord = 'x'; phase = 'production' }
    $trialOn = New-ReleaseDefinition $true; $trialOn['productionCutover'] = @{ approvalRecord = 'x'; phase = 'trial' }
    foreach ($case in @(
            @{ Name = 'on, the installer read both credentials back'; Definition = $on; Lines = @('x', 'EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set loadedConfirmers=1'); Expect = 'OK' }
            @{ Name = 'on, the loaded credential not in the service (its entry would answer 503)'; Definition = $on; Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=unset loadedConfirmers=1'); Expect = 'EMERGENCY_STOP_RELEASE_MISMATCH:' }
            @{ Name = 'on, but the Host was configured off'; Definition = $on; Lines = @('EMERGENCY_STOP_RELEASE=enabled=false credential=set loadedCredential=set loadedConfirmers=1'); Expect = 'EMERGENCY_STOP_RELEASE_MISMATCH:' }
            @{ Name = 'on, no line at all (an installer older than workspace#49)'; Definition = $on; Lines = @('x'); Expect = 'EMERGENCY_STOP_RELEASE_UNREAD:' }
            @{ Name = 'off, the line says off'; Definition = (New-ReleaseDefinition $false); Lines = @('EMERGENCY_STOP_RELEASE=enabled=false credential=unset loadedCredential=unset loadedConfirmers=0'); Expect = 'OK' }
            @{ Name = 'off, but the Host was configured on'; Definition = (New-ReleaseDefinition $false); Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set loadedConfirmers=1'); Expect = 'EMERGENCY_STOP_RELEASE_MISMATCH:' }
            @{ Name = 'no section and no line (an older checkout): warned, not refused'; Definition = (New-ReleaseDefinition $null); Lines = @('x'); Expect = 'OK' }
            # Review M2: the loaded entry accepts R-13 alone.
            @{ Name = 'on, production phase, nobody holds R-13'; Definition = $productionOn; Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set loadedConfirmers=0'); Expect = 'EMERGENCY_RELEASE_NO_LOADED_CONFIRMER:' }
            @{ Name = 'on, production phase, two R-13 holders'; Definition = $productionOn; Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set loadedConfirmers=2'); Expect = 'OK' }
            @{ Name = 'on, trial phase, nobody holds R-13: warned, not refused'; Definition = $trialOn; Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set loadedConfirmers=0'); Expect = 'OK' }
            @{ Name = 'on, the line without a confirmer count (an installer before review M2)'; Definition = $on; Lines = @('EMERGENCY_STOP_RELEASE=enabled=true credential=set loadedCredential=set'); Expect = 'EMERGENCY_STOP_RELEASE_MISMATCH:' })) {
        $v = Get-ReleaseReportVerdict $case.Definition $case.Lines
        Write-Result -Ok ($v.StartsWith($case.Expect)) -Name "release read-back: $($case.Name)" -Detail $v
    }
    Remove-Item function:Write-Step
}
if (Get-Command Get-EmergencyReleaseProbeVerdict -ErrorAction SilentlyContinue) {
    foreach ($case in @(
            @{ Enabled = $true; Empty = 401; Loaded = 401; Expect = $null }
            @{ Enabled = $true; Empty = 401; Loaded = 503; Expect = 'loaded-vehicle entry answered 503' }
            @{ Enabled = $true; Empty = 404; Loaded = 404; Expect = 'empty-vehicle entry answered 404' }
            @{ Enabled = $true; Empty = 503; Loaded = 401; Expect = 'empty-vehicle entry answered 503' }
            @{ Enabled = $true; Empty = 0; Loaded = 401; Expect = 'empty-vehicle entry answered 0' }
            @{ Enabled = $true; Empty = 200; Loaded = 401; Expect = 'empty-vehicle entry answered 200' }
            @{ Enabled = $false; Empty = 404; Loaded = 404; Expect = $null }
            @{ Enabled = $false; Empty = 401; Loaded = 404; Expect = 'empty-vehicle entry answered 401' })) {
        $r = Get-EmergencyReleaseProbeVerdict -Enabled $case.Enabled -EmptyStatus $case.Empty -LoadedStatus $case.Loaded
        $ok = ($null -eq $case.Expect) ? ($null -eq $r) : ($r -is [string] -and $r.StartsWith('EMERGENCY_RELEASE_PROBE_MISMATCH:') -and $r.Contains($case.Expect))
        Write-Result -Ok $ok -Name "release probe: enabled=$($case.Enabled), empty $($case.Empty), loaded $($case.Loaded) -> $($null -eq $case.Expect ? 'as expected' : 'refused')" -Detail "got: $r"
    }
}
# Review M3: the probe itself, with Invoke-WebRequest answered by a double -- what it sends, and that a rollback to a package
# without the loaded entry (404 there) is refused.
if (Get-Command Invoke-EmergencyReleaseProbe -ErrorAction SilentlyContinue) {
    function Write-Step { param([string] $Message) }
    $script:ProbeCalls = [System.Collections.Generic.List[string]]::new()
    $script:ProbeAnswers = @{}
    function Invoke-WebRequest {
        param([string] $Method, [string] $Uri, [string] $ContentType, [string] $Body, [switch] $NoProxy, [int] $TimeoutSec, [switch] $SkipHttpErrorCheck, [switch] $UseBasicParsing, $Headers)
        $script:ProbeCalls.Add("$Method $Uri body=$Body auth=$($null -ne $Headers) noproxy=$NoProxy")
        $status = $script:ProbeAnswers[$Uri.Substring($Uri.IndexOf('/api/'))]
        if ($status -eq 0) { throw 'no answer' }
        return [pscustomobject]@{ StatusCode = $status }
    }
    function Get-ProbeVerdict($Definition, $Empty, $Loaded) {
        $script:ProbeCalls.Clear()
        $script:ProbeAnswers = @{ '/api/safety/v1/emergency-stop-releases' = $Empty; '/api/safety/v1/emergency-stop-releases/loaded' = $Loaded }
        try { Invoke-EmergencyReleaseProbe -Definition $Definition -BaseUrl 'http://192.0.2.1:58107'; return 'OK' } catch { return $_.Exception.Message }
    }
    $v = Get-ProbeVerdict (New-ReleaseDefinition $true) 401 401
    Write-Result -Ok ($v -ceq 'OK' -and ($script:ProbeCalls -join ' | ') -ceq ('Post http://192.0.2.1:58107/api/safety/v1/emergency-stop-releases body={} auth=False noproxy=True | ' +
            'Post http://192.0.2.1:58107/api/safety/v1/emergency-stop-releases/loaded body={} auth=False noproxy=True')) `
        -Name 'release probe: two POSTs with an empty body and no credential, direct (no proxy); 401/401 accepted' -Detail "$v; calls: $($script:ProbeCalls -join ' | ')"
    $v = Get-ProbeVerdict (New-ReleaseDefinition $true) 401 404
    Write-Result -Ok ($v.StartsWith('EMERGENCY_RELEASE_PROBE_MISMATCH:') -and $v.Contains('loaded-vehicle entry answered 404')) `
        -Name 'release probe: the loaded entry absent (a package before control-server#539, after a rollback) is refused' -Detail $v
    $v = Get-ProbeVerdict (New-ReleaseDefinition $true) 401 0
    Write-Result -Ok ($v.StartsWith('EMERGENCY_RELEASE_PROBE_MISMATCH:') -and $v.Contains('answered 0')) -Name 'release probe: no answer is refused, not passed' -Detail $v
    Remove-Item function:Invoke-WebRequest, function:Write-Step
}
$deployText49 = Get-Content -LiteralPath $ScriptPath -Raw
$rollbackStart = $deployText49.IndexOf('if ($Rollback) {')
$rollbackEnd = $deployText49.IndexOf('# ------------------------------------------------------------------- secrets ---')
$probeCalls = [regex]::Matches($deployText49, 'Invoke-EmergencyReleaseProbe -Definition \$definition -BaseUrl')
Write-Result -Ok ($probeCalls.Count -eq 2 -and @($probeCalls | Where-Object { $_.Index -gt $rollbackStart -and $_.Index -lt $rollbackEnd }).Count -eq 1) `
    -Name 'release probe runs after the install and after a rollback (review M3)' -Detail "calls $($probeCalls.Count); rollback block $rollbackStart..$rollbackEnd"
Write-Result -Ok ($deployText49.Contains('$config[''emergencyReleaseCredential''] = $plain[''EmergencyReleaseCredential'']') -and
        $deployText49.Contains('$config[''emergencyLoadedReleaseCredential''] = $plain[''EmergencyLoadedReleaseCredential'']') -and
        $deployText49.Contains('Assert-EmergencyReleaseReported -Output $installOutput -Definition $definition') -and
        $deployText49.Contains('Get-EmergencyReleaseProbeVerdict -Enabled') -and
        $deployText49.Contains('if ($releaseRefusal) { throw $releaseRefusal }')) `
    -Name 'the deploy script sends both credentials, checks the installer''s line and probes both entries after the install' -Detail 'pinned text missing'

# 20-set-control-server-parallel-dispatch-gate.ps1, review S5: an old checkout and an installed cutover.
$gateScript = Join-Path (Split-Path -Parent $ScriptPath) '20-set-control-server-parallel-dispatch-gate.ps1'
$gateAst = [System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$null, [ref]$null)
$gateFunction = $gateAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CheckoutCutoverRefusal' }, $true)
if ($null -eq $gateFunction) {
    Write-Result -Ok $false -Name 'Get-CheckoutCutoverRefusal is defined in 20' -Detail 'not found'
} else {
    . ([scriptblock]::Create($gateFunction.Extent.Text))
    foreach ($case in @(
            @{ K = $true; I = $true; Refused = $false }; @{ K = $true; I = $false; Refused = $false }
            @{ K = $false; I = $false; Refused = $false }; @{ K = $false; I = $true; Refused = $true })) {
        $r = Get-CheckoutCutoverRefusal -ModuleKnowsCutover $case.K -InstalledIsCutover $case.I -Repository 'C:\selftest\cs'
        $ok = $case.Refused ? ($r -is [string] -and $r.StartsWith('CHECKOUT_PREDATES_CUTOVER:') -and $r.EndsWith('Nothing was copied or changed.')) : ($null -eq $r)
        Write-Result -Ok $ok -Name "20: checkout knows the cutover $($case.K), installed is a cutover $($case.I) -> $($case.Refused ? 'refused' : 'goes ahead')" -Detail "got: $r"
    }
    # Review round 2, V2: the probe the server runs, run here against scratch files -- the record of a cutover says True,
    # a parallel one False, no record False.
    $probeAst = $gateAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InstalledCutoverProbeCommand' }, $true)
    if ($null -eq $probeAst) {
        Write-Result -Ok $false -Name 'Get-InstalledCutoverProbeCommand is defined in 20' -Detail 'not found'
    } else {
        . ([scriptblock]::Create($probeAst.Extent.Text))
        $probeRoot = Join-Path ([IO.Path]::GetTempPath()) "cs564-probe-$([guid]::NewGuid().ToString('N')) it's"
        New-Item -ItemType Directory -Path $probeRoot | Out-Null
        try {
            $cutoverRecord = Join-Path $probeRoot 'cutover.json'
            '{ "instanceId": "x", "productionCutover": { "approvalRecord": "x", "phase": "trial" } }' | Set-Content -LiteralPath $cutoverRecord -Encoding utf8NoBOM
            $parallelRecord = Join-Path $probeRoot 'parallel.json'
            '{ "instanceId": "x", "approvalRecord": "productionCutover is only a word here" }' | Set-Content -LiteralPath $parallelRecord -Encoding utf8NoBOM
            foreach ($case in @(@{ Path = $cutoverRecord; Expect = 'True' }, @{ Path = $parallelRecord; Expect = 'False' }, @{ Path = (Join-Path $probeRoot 'none.json'); Expect = 'False' })) {
                $got = "$(& ([scriptblock]::Create((Get-InstalledCutoverProbeCommand -RecordPath $case.Path))))".Trim()
                Write-Result -Ok ($got -ceq $case.Expect) -Name "20 probe: $(Split-Path -Leaf $case.Path) -> $($case.Expect)" -Detail "got '$got'"
            }
        } finally { Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $gateText = Get-Content -LiteralPath $gateScript -Raw
    Write-Result -Ok ($gateText.Contains('$probe = Invoke-Ssh @(Get-InstalledCutoverProbeCommand -RecordPath "$opsRoot\installed-instance.json")') -and
            $gateText.Contains('$contract = (Get-Command Get-ParallelCutoverContractVersion -ErrorAction SilentlyContinue) ? (Get-ParallelCutoverContractVersion) : 0') -and
            $gateText.Contains('if ($contract -lt $script:RequiredCutoverContract) {') -and $gateText.Contains('$script:RequiredCutoverContract = 2')) `
        -Name '20 judges the checkout by the cutover contract version (review round 2, L3) and asks the server with that probe' -Detail 'pinned text missing'
    $at = $gateText.IndexOf('if ($checkoutRefusal) { throw $checkoutRefusal }')
    Write-Result -Ok ($at -gt 0 -and $at -lt $gateText.IndexOf('Invoke-Ssh @("New-Item -ItemType Directory -Force -Path ''$gateRoot'' | Out-Null")')) `
        -Name '20 refuses an old checkout on a cutover instance before anything is staged' -Detail "at $at"
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
    # control-server#564 (review MW2): a committed copy of the cutover definition with its record, the way the cutover day
    # commits one, so that -ProductionCutover can be run end to end below. Only when the revision ships both.
    $cutoverSource = Join-Path $clone 'scripts\parallel\instance-factory01-v2.cutover-two-zones.json'
    $cutoverFixture = Join-Path $clone 'scripts\parallel\instance-factory01-v2.cutover-selftest.json'
    $fixtureKnowsCutover = (Test-Path -LiteralPath $cutoverSource) -and
        (Get-Content -LiteralPath (Join-Path $clone 'scripts\parallel\ParallelInstance.psm1') -Raw).Contains('function Get-ParallelCutoverMvpRefusal')
    if ($fixtureKnowsCutover) {
        $c = Get-Content -LiteralPath $cutoverSource -Raw | ConvertFrom-Json -AsHashtable
        $c['productionCutover'] = [ordered]@{ approvalRecord = 'selftest: approval written in on the cutover day'; phase = 'trial' }
        ConvertTo-Json -InputObject $c -Depth 12 | Set-Content -LiteralPath $cutoverFixture -Encoding utf8NoBOM
    }
    # workspace#49: a committed copy of the shipped definition with the emergency stop release entries on, when the
    # revision's module knows the section.
    $releaseFixture = Join-Path $clone 'scripts\parallel\instance-factory01-v2.release-selftest.json'
    $fixtureKnowsRelease = (Get-Content -LiteralPath (Join-Path $clone 'scripts\parallel\ParallelInstance.psm1') -Raw).Contains("'emergencyStopRelease' = @('enabled')")
    if ($fixtureKnowsRelease) {
        $r = Get-Content -LiteralPath (Join-Path $clone 'scripts\parallel\instance-factory01-v2.json') -Raw | ConvertFrom-Json -AsHashtable
        $r['emergencyStopRelease'] = [ordered]@{ enabled = $true }
        ConvertTo-Json -InputObject $r -Depth 12 | Set-Content -LiteralPath $releaseFixture -Encoding utf8NoBOM
    }
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

    # control-server#564 (review MW2): the definition check gets -ProductionCutover. A cutover definition with its record is
    # accepted with the switch and reaches the dry-run stop; the same command without the switch is refused by the module.
    if ($fixtureKnowsCutover) {
        $cutoverKeys = @((Get-Content -LiteralPath $cutoverFixture -Raw | ConvertFrom-Json -AsHashtable)['journeyRuntime']['fleet'] | ForEach-Object { [string] $_['vehicleKey'] })
        $cutoverSecrets = Join-Path $work 'secrets-cutover.xml'
        $withCutover = Import-Clixml -LiteralPath $secretPath
        foreach ($key in $cutoverKeys) { $withCutover["OnboardSafetyCredential:$key"] = & $fake "selftest-safety-$key" }
        $withCutover | Export-Clixml -LiteralPath $cutoverSecrets
        $cutoverCommon = $common.Clone(); $cutoverCommon.Remove('FakeMesIngestZip'); $cutoverCommon['SecretPath'] = $cutoverSecrets
        $run = Invoke-Deploy ($cutoverCommon + @{ PackagePath = $samePackage; InstanceDefinitionPath = $cutoverFixture; ProductionCutover = $true })
        Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('WhatIf: stopping before the server is touched')) `
            -Name 'cutover definition with its record and -ProductionCutover: accepted, stops at the dry run' -Detail (Get-Detail $run)
        $run = Invoke-Deploy ($cutoverCommon + @{ PackagePath = $samePackage; InstanceDefinitionPath = $cutoverFixture })
        Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('CUTOVER_RECORD_WITHOUT_SWITCH')) `
            -Name 'the same definition without -ProductionCutover: refused by the definition check' -Detail (Get-Detail $run)
        $run = Invoke-Deploy ($cutoverCommon + @{ PackagePath = $samePackage; InstanceDefinitionPath = $cutoverFixture; ProductionCutover = $true; LeaveProductionCutover = $true })
        Write-Result -Ok ($null -ne $run.Error -and $run.Error.Contains('-LeaveProductionCutover leaves one; pass one')) `
            -Name '-ProductionCutover with -LeaveProductionCutover: refused before anything' -Detail (Get-Detail $run)
    } else {
        Write-Host "  SKIP  cutover end-to-end cases: $ControlServerRef has no cutover switch or no cutover definition" -ForegroundColor Yellow
    }

    # workspace#49: the emergency stop release entries, end to end under -WhatIf. The store has neither release credential.
    $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage })
    Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('EMERGENCY_STOP_RELEASE_REQUESTED=enabled=false credential=absent loadedCredential=absent')) `
        -Name 'release: a definition without the section deploys as before, and the summary says the entries are off, under -WhatIf' -Detail (Get-Detail $run)
    if ($fixtureKnowsRelease) {
        $run = Invoke-Deploy ($common + @{ PackagePath = $samePackage; InstanceDefinitionPath = $releaseFixture })
        Write-Result -Ok ($null -ne $run.Error -and $run.Error.StartsWith('EMERGENCY_RELEASE_CREDENTIAL_MISSING:') -and
                $run.Error.Contains("'EmergencyReleaseCredential'") -and $run.Error.Contains("'EmergencyLoadedReleaseCredential'") -and
                -not $run.Text.Contains('WhatIf: stopping before the server is touched') -and @($global:GhCalls).Count -eq 0) `
            -Name 'release on, store without the two credentials: refused before anything is staged, naming both' -Detail (Get-Detail $run)
        $releaseSecrets = Join-Path $work 'secrets-release.xml'
        $withRelease = Import-Clixml -LiteralPath $secretPath
        $withRelease['EmergencyReleaseCredential'] = & $fake 'selftest-release-empty'
        $withRelease['EmergencyLoadedReleaseCredential'] = & $fake 'selftest-release-loaded'
        $withRelease | Export-Clixml -LiteralPath $releaseSecrets
        $released = $common.Clone(); $released['SecretPath'] = $releaseSecrets
        $run = Invoke-Deploy ($released + @{ PackagePath = $samePackage; InstanceDefinitionPath = $releaseFixture })
        Write-Result -Ok ($null -eq $run.Error -and $run.Text.Contains('WhatIf: stopping before the server is touched') -and
                $run.Text.Contains('EMERGENCY_STOP_RELEASE_REQUESTED=enabled=true credential=present loadedCredential=present (both sent; values not shown)') -and
                -not $run.Text.Contains('selftest-release-')) `
            -Name 'release on, both credentials in the store: accepted under -WhatIf, the summary says both are sent, no value printed' -Detail (Get-Detail $run)
    } else {
        Write-Host "  SKIP  release end-to-end cases: $ControlServerRef's module has no emergencyStopRelease section" -ForegroundColor Yellow
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
