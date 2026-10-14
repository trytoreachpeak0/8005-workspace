#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for Set-ControlServerSecret.ps1's prompting rules (control-server#454 review S2, N5).

.DESCRIPTION
    Lifts Get-SecretPromptPlan, Update-SecretStore and Format-SecretPresence out of the script by their
    AST -- the script itself is never run -- and drives them with an in-memory store and a reader that
    answers from a list. Nothing touches DPAPI, the secret store on disk or the console: SecureStrings
    are built in memory, and no Export-Clixml or Import-Clixml runs.

    What it pins:
      * the v2 key is optional: an operator completing the MVP's keys is asked for it once and an empty
        answer leaves it missing -- so 19-deploy's "missing key" refusal still means something;
      * a missing required key is asked for again until it gets a value;
      * -Replace asks for a key that is present, and an empty answer keeps the stored value;
      * a present key not named in -Replace is never asked for;
      * -Show pads every key to the longest name.

.EXAMPLE
    pwsh -File remote-ops/factory-server/scripts/control-server/Test-SetControlServerSecret.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$source = Join-Path $PSScriptRoot 'Set-ControlServerSecret.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($name in @('Get-SecretPromptPlan', 'Update-SecretStore', 'Format-SecretPresence')) {
    $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $definition) { throw "$name is not defined in $source" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# The key lists come from the script, not from here (incremental review, item 6): a test that writes
# its own lists keeps passing when the script moves V2 back to required (W1) or makes -Import fill it
# (W2).
function Get-AssignedStrings {
    param([string] $Variable)
    $assignment = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Variable }, $true))
    if ($assignment.Count -ne 1) { throw "expected one assignment of $Variable in $source, found $($assignment.Count)" }
    return @($assignment[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
}
$required = @(Get-AssignedStrings '$required')
$optional = @(Get-AssignedStrings '$optional')
# What -Import fills: the Key of every pair it walks, and every key it assigns into $store directly.
$importBlock = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$Import' }, $true)
if ($null -eq $importBlock) { throw "no 'if (`$Import)' block in $source" }
$imported = @(
    $importBlock.Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | ForEach-Object {
        foreach ($pair in $_.KeyValuePairs) { if ($pair.Item1.Extent.Text -eq 'Key') { $pair.Item2.Extent.Text.Trim("'", '"', ' ') } } }
    $importBlock.Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Left.Target.Extent.Text -eq '$store' }, $true) |
        ForEach-Object { $_.Left.Index.Extent.Text.Trim("'", '"') } | Where-Object { $_ -notmatch '^\$' }
) | Select-Object -Unique

Write-Host 'Key lists read from Set-ControlServerSecret.ps1' -ForegroundColor Cyan
Write-Result -Ok ($optional -contains 'V2FaultRecoveryCredential' -and $required -notcontains 'V2FaultRecoveryCredential') `
    -Name 'V2FaultRecoveryCredential is optional, not required (W1)' -Detail ("required: " + ($required -join ',') + "; optional: " + ($optional -join ','))
Write-Result -Ok (@('RiotCallApiKey', 'OnboardCredential', 'MesIngestSharedSecret', 'OperatorId' | Where-Object { $required -notcontains $_ }).Count -eq 0) `
    -Name 'the four MVP keys stay required' -Detail ("required: " + ($required -join ','))
Write-Result -Ok ($imported.Count -ge 3 -and $imported -notcontains 'V2FaultRecoveryCredential') `
    -Name '-Import never fills V2FaultRecoveryCredential (W2)' -Detail ("-Import fills: " + ($imported -join ','))
Write-Host ''
$secure = { param([string] $Text) $Text ? (ConvertTo-SecureString $Text -AsPlainText -Force) : [securestring]::new() }
$plainOf = { param($Value) [System.Net.NetworkCredential]::new('', $Value).Password }
function New-MvpStore { $s = @{}; foreach ($k in $required) { $s[$k] = & $secure "value-of-$k" }; $s }

# A reader that answers from a queue and refuses to be called more often than expected: a rule that
# re-asks forever (an optional key treated as required) fails here instead of hanging the test.
function New-Reader {
    param([string[]] $Answers)
    $state = @{ Queue = [System.Collections.Generic.Queue[string]]::new([string[]] $Answers); Asked = [System.Collections.Generic.List[string]]::new() }
    $reader = {
        param([string] $Name, [string] $Hint, [string] $OnEmpty)
        $state.Asked.Add("$Name/$OnEmpty")
        if ($state.Queue.Count -eq 0) { throw "asked once more than expected, for $Name" }
        & $secure $state.Queue.Dequeue()
    }.GetNewClosure()
    return [pscustomobject]@{ Read = $reader; State = $state }
}

Write-Host 'Set-ControlServerSecret.ps1 prompting rules' -ForegroundColor Cyan

# 1. MVP operator completing the MVP keys: v2 asked once, optional, empty answer skips it.
$store = New-MvpStore
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present @($store.Keys) -Replace @())
Write-Result -Ok ($plan.Count -eq 1 -and $plan[0].Key -eq 'V2FaultRecoveryCredential' -and $plan[0].OnEmpty -eq 'Skip') `
    -Name 'with every MVP key present, only the v2 key is asked for, and as skippable' -Detail ($plan | ConvertTo-Json -Compress)
$r = New-Reader -Answers @('')
$result = $null; $err = $null
try { $result = Update-SecretStore -Store $store -Plan $plan -ReadSecret $r.Read } catch { $err = $_.Exception.Message }
Write-Result -Ok ($null -eq $err -and -not $result.ContainsKey('V2FaultRecoveryCredential') -and $r.State.Asked.Count -eq 1) `
    -Name 'an empty answer for the v2 key skips it: the store stays without it (19-deploy can still refuse)' `
    -Detail "error: $err; asked: $($r.State.Asked -join ','); has v2: $($result -and $result.ContainsKey('V2FaultRecoveryCredential'))"

# 2. A missing required key is asked for again until it gets a value.
$store = New-MvpStore; $store.Remove('OperatorId')
$store['V2FaultRecoveryCredential'] = & $secure 'v2-old'
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present @($store.Keys) -Replace @())
$r = New-Reader -Answers @('', '', 'op-7')
$err = $null
try { $result = Update-SecretStore -Store $store -Plan $plan -ReadSecret $r.Read } catch { $err = $_.Exception.Message }
Write-Result -Ok ($null -eq $err -and (& $plainOf $result['OperatorId']) -ceq 'op-7' -and ($r.State.Asked -join ',') -ceq 'OperatorId/AskAgain,OperatorId/AskAgain,OperatorId/AskAgain') `
    -Name 'a missing required key is asked for again until it has a value, and nothing else is asked' -Detail "error: $err; asked: $($r.State.Asked -join ',')"

# 3. A present key not named in -Replace is never asked for.
$store = New-MvpStore; $store['V2FaultRecoveryCredential'] = & $secure 'v2-old'
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present @($store.Keys) -Replace @())
Write-Result -Ok ($plan.Count -eq 0) -Name 'with every key present and no -Replace, nothing is asked' -Detail ($plan | ConvertTo-Json -Compress)

# 4. -Replace: a present key is asked for; a value replaces it, an empty answer keeps it.
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present @($store.Keys) -Replace @('V2FaultRecoveryCredential'))
Write-Result -Ok ($plan.Count -eq 1 -and $plan[0].OnEmpty -eq 'Keep') -Name '-Replace asks for a present key, with an empty answer meaning keep' -Detail ($plan | ConvertTo-Json -Compress)
$r = New-Reader -Answers @('v2-new')
$result = Update-SecretStore -Store $store -Plan $plan -ReadSecret $r.Read
Write-Result -Ok ((& $plainOf $result['V2FaultRecoveryCredential']) -ceq 'v2-new') -Name '-Replace with a value replaces the stored one' -Detail (& $plainOf $result['V2FaultRecoveryCredential'])
$store = New-MvpStore; $store['V2FaultRecoveryCredential'] = & $secure 'v2-old'
$r = New-Reader -Answers @('')
$result = Update-SecretStore -Store $store -Plan $plan -ReadSecret $r.Read
Write-Result -Ok ((& $plainOf $result['V2FaultRecoveryCredential']) -ceq 'v2-old' -and $r.State.Asked.Count -eq 1) `
    -Name '-Replace with an empty answer keeps the stored value, asked once' -Detail "$(& $plainOf $result['V2FaultRecoveryCredential']) asked $($r.State.Asked.Count)"
$store = New-MvpStore
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present @($store.Keys) -Replace @('OperatorId'))
$r = New-Reader -Answers @('', '')
$result = Update-SecretStore -Store $store -Plan $plan -ReadSecret $r.Read
Write-Result -Ok ((& $plainOf $result['OperatorId']) -ceq 'value-of-OperatorId' -and ($r.State.Asked -join ',') -ceq 'OperatorId/Keep,V2FaultRecoveryCredential/Skip') `
    -Name '-Replace of a required key: an empty answer keeps it rather than asking again' -Detail "asked: $($r.State.Asked -join ',')"

# 5. -Show alignment (review N5): the status column starts at the same place on every line.
$store = New-MvpStore
$lines = @(Format-SecretPresence -Keys ($required + $optional) -Store $store -Optional $optional)
$columns = @($lines | ForEach-Object { [regex]::Match($_, '^  \S+ +').Length } | Select-Object -Unique)
Write-Result -Ok ($lines.Count -eq 5 -and $columns.Count -eq 1 -and ($lines[-1] -like '*missing (optional)')) `
    -Name '-Show pads every key to the longest name; the optional key reads "missing (optional)"' -Detail ($lines -join ' | ')
Write-Result -Ok (-not ($lines -join "`n").Contains('value-of-')) -Name '-Show never prints a value' -Detail ($lines -join ' | ')

# 6. control-server#600: one vehicle-safety projection credential per vehicle, generated here, never typed.
Write-Host ''
Write-Host 'Per-vehicle projection credentials (control-server#600)' -ForegroundColor Cyan
foreach ($name in @('Get-VehicleSafetySecretKey', 'New-VehicleSafetySecret', 'Add-VehicleSafetySecret')) {
    $definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Write-Result -Ok ($null -ne $definition) -Name "$name is defined in Set-ControlServerSecret.ps1" -Detail 'missing'
    if ($null -ne $definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$agv02Key = 'BROKERX-f38975561adf46ccb1d2f23833c7d0e4'
$agv03Key = 'BROKERX-7daca4ee91da498d8026c68b7b941127'
$err = $null
try {
    Write-Result -Ok ((Get-VehicleSafetySecretKey -VehicleKey $agv02Key) -ceq "OnboardSafetyCredential:$agv02Key") `
        -Name 'the store key is OnboardSafetyCredential:<vehicleKey>' -Detail (Get-VehicleSafetySecretKey -VehicleKey $agv02Key)
    $a = & $plainOf (New-VehicleSafetySecret); $b = & $plainOf (New-VehicleSafetySecret)
    Write-Result -Ok ($a.Length -ge 43 -and $a -cne $b -and $a -match '^[A-Za-z0-9_-]+$') `
        -Name 'a generated credential is at least 256 bits, URL- and header-safe, and different every time' -Detail "lengths $($a.Length)/$($b.Length)"

    $counter = @{ N = 0 }
    $fixed = { $counter.N++; & $secure "generated-$($counter.N)" }.GetNewClosure()
    $store = New-MvpStore
    $added = Add-VehicleSafetySecret -Store $store -VehicleKey $agv02Key -NewSecret $fixed
    Write-Result -Ok ((& $plainOf $added["OnboardSafetyCredential:$agv02Key"]) -ceq 'generated-1') -Name 'a missing vehicle credential is generated into the store' -Detail ''

    $refused = $null
    try { $null = Add-VehicleSafetySecret -Store $store -VehicleKey $agv02Key -NewSecret $fixed } catch { $refused = $_.Exception.Message }
    Write-Result -Ok ($null -ne $refused -and $refused.Contains('VEHICLE_SAFETY_CREDENTIAL_PRESENT') -and $refused.Contains('-Rotate') -and
        (& $plainOf $store["OnboardSafetyCredential:$agv02Key"]) -ceq 'generated-1' -and -not $refused.Contains('generated-')) `
        -Name 'a present vehicle credential is not replaced without -Rotate, and the refusal shows no value' -Detail "error: $refused"
    $null = Add-VehicleSafetySecret -Store $store -VehicleKey $agv02Key -NewSecret $fixed -Rotate
    Write-Result -Ok ((& $plainOf $store["OnboardSafetyCredential:$agv02Key"]) -cne 'generated-1') -Name '-Rotate replaces it' -Detail ''

    # A generator that hands back the shared onboard credential, or another vehicle's, is refused rather than stored.
    $store = New-MvpStore
    $store["OnboardSafetyCredential:$agv03Key"] = & $secure 'agv03-value'
    foreach ($case in @(@{ Name = 'the shared onboard credential'; Value = 'value-of-OnboardCredential' }, @{ Name = 'another vehicle''s'; Value = 'agv03-value' })) {
        $same = { & $secure $case.Value }.GetNewClosure()
        $refused = $null
        try { $null = Add-VehicleSafetySecret -Store $store -VehicleKey $agv02Key -NewSecret $same } catch { $refused = $_.Exception.Message }
        Write-Result -Ok ($null -ne $refused -and -not $store.ContainsKey("OnboardSafetyCredential:$agv02Key") -and -not $refused.Contains($case.Value)) `
            -Name "a generated value equal to $($case.Name) is refused, not stored" -Detail "error: $refused"
    }
} catch { $err = $_.Exception.Message }
Write-Result -Ok ($null -eq $err) -Name 'the per-vehicle credential cases ran to the end' -Detail "threw: $err"

# 7. workspace#49: the two emergency stop release credentials (empty-vehicle entry, loaded-vehicle entry). Generated here,
#    never typed, never imported; a present one is refused unless -Rotate; a generated value equal to anything else in the
#    store is refused rather than stored -- the two equal would let the empty-vehicle credential release a loaded vehicle.
Write-Host ''
Write-Host 'Emergency stop release credentials (workspace#49)' -ForegroundColor Cyan
$releaseDefinition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-EmergencyReleaseSecret' }, $true)
Write-Result -Ok ($null -ne $releaseDefinition) -Name 'Add-EmergencyReleaseSecret is defined in Set-ControlServerSecret.ps1' -Detail 'missing'
if ($null -ne $releaseDefinition) { . ([scriptblock]::Create($releaseDefinition.Extent.Text)) }
$parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'NewEmergencyReleaseCredential' })
$validateSet = @($parameter | ForEach-Object { $_.Attributes } | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' } |
    ForEach-Object { $_.PositionalArguments | ForEach-Object Value })
Write-Result -Ok ($parameter.Count -eq 1 -and ($validateSet -join ',') -ceq 'Empty,Loaded') `
    -Name '-NewEmergencyReleaseCredential takes Empty and/or Loaded' -Detail "parameter $($parameter.Count); ValidateSet: $($validateSet -join ',')"
$rotateSets = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Rotate' } | ForEach-Object { $_.Attributes } |
    Where-Object { $_.TypeName.Name -ceq 'Parameter' } | ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -ceq 'ParameterSetName' } |
    ForEach-Object { $_.Argument.Value })
Write-Result -Ok ($rotateSets -ccontains 'EmergencyRelease' -and $rotateSets -ccontains 'VehicleSafety') `
    -Name '-Rotate works with -NewEmergencyReleaseCredential as with -NewVehicleSafetyCredential' -Detail "parameter sets: $($rotateSets -join ',')"
$releaseKeys = @('EmergencyReleaseCredential', 'EmergencyLoadedReleaseCredential')
Write-Result -Ok (@($releaseKeys | Where-Object { $required -ccontains $_ -or $optional -ccontains $_ -or $imported -ccontains $_ }).Count -eq 0) `
    -Name 'the two release credentials are never prompted for and never imported' -Detail "required: $($required -join ','); optional: $($optional -join ','); imported: $($imported -join ',')"
$err = $null
try {
    $counter = @{ N = 0 }
    $fixed = { $counter.N++; & $secure "release-$($counter.N)" }.GetNewClosure()
    $store = New-MvpStore
    $store = Add-EmergencyReleaseSecret -Store $store -Which 'Empty' -NewSecret $fixed
    $store = Add-EmergencyReleaseSecret -Store $store -Which 'Loaded' -NewSecret $fixed
    Write-Result -Ok ((& $plainOf $store['EmergencyReleaseCredential']) -ceq 'release-1' -and (& $plainOf $store['EmergencyLoadedReleaseCredential']) -ceq 'release-2') `
        -Name 'Empty and Loaded are generated into EmergencyReleaseCredential and EmergencyLoadedReleaseCredential' -Detail "keys: $(@($store.Keys) -join ',')"

    foreach ($which in @('Empty', 'Loaded')) {
        $before = & $plainOf $store[($which -ceq 'Empty') ? 'EmergencyReleaseCredential' : 'EmergencyLoadedReleaseCredential']
        $refused = $null
        try { $null = Add-EmergencyReleaseSecret -Store $store -Which $which -NewSecret $fixed } catch { $refused = $_.Exception.Message }
        $after = & $plainOf $store[($which -ceq 'Empty') ? 'EmergencyReleaseCredential' : 'EmergencyLoadedReleaseCredential']
        Write-Result -Ok ($null -ne $refused -and $refused.StartsWith('EMERGENCY_RELEASE_CREDENTIAL_PRESENT:') -and $refused.Contains('-Rotate') -and
            $after -ceq $before -and -not $refused.Contains('release-')) `
            -Name "a present $which credential is not replaced without -Rotate, and the refusal shows no value" -Detail "error: $refused"
    }
    $null = Add-EmergencyReleaseSecret -Store $store -Which 'Loaded' -NewSecret $fixed -Rotate
    Write-Result -Ok ((& $plainOf $store['EmergencyLoadedReleaseCredential']) -cnotin @('release-2', '') -and (& $plainOf $store['EmergencyReleaseCredential']) -ceq 'release-1') `
        -Name '-Rotate replaces only the one named' -Detail ''

    # A generator that hands back a value already in the store -- the other release credential, the shared onboard
    # credential, the v2 fault recovery credential, a vehicle's projection credential -- is refused, nothing stored.
    $store = New-MvpStore
    $store['V2FaultRecoveryCredential'] = & $secure 'v2-value'
    $store['OnboardSafetyCredential:BROKERX-x'] = & $secure 'vehicle-value'
    $store['EmergencyReleaseCredential'] = & $secure 'empty-value'
    foreach ($case in @(@{ Name = 'the empty-vehicle release credential'; Value = 'empty-value' }, @{ Name = 'the shared onboard credential'; Value = 'value-of-OnboardCredential' },
            @{ Name = 'the v2 fault recovery credential'; Value = 'v2-value' }, @{ Name = 'a vehicle''s projection credential'; Value = 'vehicle-value' })) {
        $same = { & $secure $case.Value }.GetNewClosure()
        $refused = $null
        try { $null = Add-EmergencyReleaseSecret -Store $store -Which 'Loaded' -NewSecret $same } catch { $refused = $_.Exception.Message }
        Write-Result -Ok ($null -ne $refused -and $refused.StartsWith('EMERGENCY_RELEASE_CREDENTIAL_NOT_UNIQUE:') -and -not $store.ContainsKey('EmergencyLoadedReleaseCredential') -and
            -not $refused.Contains($case.Value)) -Name "a generated Loaded value equal to $($case.Name) is refused, not stored" -Detail "error: $refused"
    }
} catch { $err = $_.Exception.Message }
Write-Result -Ok ($null -eq $err) -Name 'the release credential cases ran to the end' -Detail "threw: $err"
$scriptText = Get-Content -Raw -LiteralPath $source
Write-Result -Ok ($scriptText.Contains("'EmergencyReleaseCredential'") -and $scriptText.Contains("'EmergencyLoadedReleaseCredential'") -and
    $scriptText.Contains('Add-EmergencyReleaseSecret -Store $store -Which $which -NewSecret { New-VehicleSafetySecret } -Rotate:$Rotate')) `
    -Name 'the script generates them with the same 256-bit generator as the projection credentials' -Detail 'pinned text missing'
$deployText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\19-deploy-control-server-parallel.ps1')
Write-Result -Ok ($deployText.Contains("'EmergencyReleaseCredential'") -and $deployText.Contains("'EmergencyLoadedReleaseCredential'")) `
    -Name '19-deploy-control-server-parallel.ps1 reads both store keys by the same literals' -Detail 'literal not found'

# The two deployment scripts read the same store key; the name is the contract between the three files.
foreach ($consumer in @('..\19-deploy-control-server-parallel.ps1', '..\..\..\onboard-hmi\scripts\06-deploy-onboard-hmi.ps1')) {
    $text = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot $consumer)
    Write-Result -Ok ($text.Contains("'OnboardSafetyCredential:'")) -Name "$(Split-Path -Leaf $consumer) reads the per-vehicle store key OnboardSafetyCredential:<vehicleKey>" -Detail 'literal not found'
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
