#Requires -Version 7
<#
.SYNOPSIS
    Writes the ControlServer deployment secrets into the DPAPI store on the
    control host.

.DESCRIPTION
    Five secrets travel with a WIRE_TO_GATE deployment. They are held here,
    encrypted with DPAPI so only the current Windows user on this machine can
    read them back, and assembled into a deployment config at deploy time. They
    never appear on a command line, in a CI log, or in this repository.

        RiotCallApiKey             CONTROL_SERVER_RIOT_CALL_API_KEY
        OnboardCredential          CONTROL_SERVER_ONBOARD_CREDENTIAL
        MesIngestSharedSecret      CONTROL_SERVER_MES_INGEST_SHARED_SECRET
        OperatorId                 CONTROL_SERVER_OPERATOR_ID
        V2FaultRecoveryCredential  CONTROL_SERVER_V2_FAULT_RECOVERY_CREDENTIAL (optional)

    V2FaultRecoveryCredential belongs to the v2 parallel instance alone
    (control-server#454): 19-deploy-control-server-parallel.ps1 sends it, and the
    parallel installer writes it into that service's own registry Environment. It
    is a value of its own -- the MVP's fault recovery credential, if it has one,
    is a different secret -- and -Import never fills it: nothing on this machine
    holds it yet. It is OPTIONAL: an empty answer skips it. That matters twice
    over. An operator who only came to complete the MVP's keys is not made to
    invent a v2 value; and an invented value would defeat the one check that
    protects the v2 deployment -- 19-deploy refuses an instance whose Host
    recovery entry is on while this key is missing, and a made-up value is
    "present".

    OnboardCredential is the one shared value: the same static string
    authenticates the onboard client to the server, so both halves of the
    deployment read it from here. Section 11.1 of RELEASE-CANDIDATE.md is
    explicit about what that means on a plaintext link -- one packet capture
    impersonates the vehicle permanently, with no rotation and no replay window
    -- and that is a known cost accepted for a controlled plant network, not
    something this script can improve on.

    Which keys are asked for is decided by Get-SecretPromptPlan below, which
    reads nothing and writes nothing; Test-SetControlServerSecret.ps1 drives it
    and Update-SecretStore offline, without DPAPI.

    Since control-server#600 the store also holds one vehicle-safety projection
    credential per vehicle, under OnboardSafetyCredential:<vehicleKey>. Those are
    never typed: -NewVehicleSafetyCredential generates them. The v2 server answers
    a vehicle's projection only to its own credential, 19-deploy sends each
    roster vehicle's to the parallel instance, and 06-deploy writes a vehicle's
    own into CONTROL_SERVER_ONBOARD_SAFETY_CREDENTIAL on that vehicle.

.PARAMETER Import
    Take whatever is already on this machine instead of retyping it:
    CONTROL_SERVER_RIOT_CALL_API_KEY and CONTROL_SERVER_OPERATOR_ID from the
    environment, and the MesIngest shared secret from the store that
    13-deploy-mes-ingest-server.ps1 already uses. Anything still missing is
    prompted for.

.PARAMETER Replace
    Ask again for these keys even though the store has them, and keep the new
    value. An empty answer keeps the old one. Without it a key that is present is
    never asked for, so this is the only way to change a stored value.

.PARAMETER NewVehicleSafetyCredential
    Generate the vehicle-safety projection credential of these vehicles, by SSH
    alias (agv02, agv03). The vehicleKey comes from
    remote-ops/onboard-hmi/config/site-<alias>.json. A vehicle that already has
    one is refused unless -Rotate; a rotated credential needs the server and
    that vehicle deployed again. Prints names only, never a value.

.PARAMETER Rotate
    With -NewVehicleSafetyCredential: replace a credential that is present.

.PARAMETER Show
    List which secrets are present and how long they are. Never prints a value.

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -Import

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -Replace V2FaultRecoveryCredential

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -Show

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -NewVehicleSafetyCredential agv02, agv03
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set')]
    [switch] $Import,

    [Parameter(ParameterSetName = 'Set')]
    [ValidateSet('RiotCallApiKey', 'OnboardCredential', 'MesIngestSharedSecret', 'OperatorId', 'V2FaultRecoveryCredential')]
    [string[]] $Replace = @(),

    [Parameter(Mandatory = $true, ParameterSetName = 'Show')]
    [switch] $Show,

    [Parameter(Mandatory = $true, ParameterSetName = 'VehicleSafety')]
    [ValidatePattern('^agv0[23]$')]
    [string[]] $NewVehicleSafetyCredential,

    [Parameter(ParameterSetName = 'VehicleSafety')]
    [switch] $Rotate,

    [Parameter(ParameterSetName = 'VehicleSafety')]
    [string] $SiteDirectory = (Join-Path $PSScriptRoot '..\..\..\onboard-hmi\config'),

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),

    [string] $MesIngestSecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Get-SecretPromptPlan {
    <#
        Which keys to ask for, in order, and how. Pure: Test-SetControlServerSecret.ps1 lifts
        this function out of the file and runs it without a store.

        A key is asked for when it is missing (or present only as an empty value), or when it is
        named in -Replace. Each entry says whether an empty answer is allowed and what it means:
          * required and missing   -> an empty answer is refused, ask again;
          * optional and missing   -> an empty answer skips the key, it stays missing;
          * named in -Replace      -> an empty answer keeps the stored value.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]] $Required,
        [string[]] $Optional = @(),
        [Parameter(Mandatory = $true)][string[]] $Present,
        [string[]] $Replace = @()
    )
    foreach ($key in @($Required) + @($Optional)) {
        $isPresent = $Present -contains $key
        $isReplaced = $Replace -contains $key
        if ($isPresent -and -not $isReplaced) { continue }
        [pscustomobject]@{
            Key = $key
            OnEmpty = $isPresent ? 'Keep' : (($Optional -contains $key) ? 'Skip' : 'AskAgain')
        }
    }
}

function Update-SecretStore {
    <#
        Applies the plan to a store, reading each value through -ReadSecret, which returns a
        SecureString (empty means "no answer"). Returns the store. Pure apart from the reader:
        the test passes a reader that answers from a list, and checks the store it gets back.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable] $Store,
        [Parameter(Mandatory = $true)][object[]] $Plan,
        [Parameter(Mandatory = $true)][scriptblock] $ReadSecret,
        [hashtable] $Hints = @{}
    )
    foreach ($step in $Plan) {
        while ($true) {
            $value = & $ReadSecret $step.Key ($Hints[$step.Key]) $step.OnEmpty
            $empty = $null -eq $value -or -not [System.Net.NetworkCredential]::new('', $value).Password
            if (-not $empty) { $Store[$step.Key] = $value; break }
            if ($step.OnEmpty -eq 'AskAgain') { continue }
            break
        }
    }
    return $Store
}

function Format-SecretPresence {
    <#
        The -Show lines: one per key, padded to the longest key name. Never a value.
    #>
    param([string[]] $Keys, [hashtable] $Store, [string[]] $Optional = @())
    $width = (@($Keys | ForEach-Object Length) | Measure-Object -Maximum).Maximum
    foreach ($key in $Keys) {
        if ($Store.ContainsKey($key) -and $Store[$key]) {
            $length = [System.Net.NetworkCredential]::new('', $Store[$key]).Password.Length
            "  {0} present ({1} chars)" -f $key.PadRight($width), $length
        } else {
            "  {0} {1}" -f $key.PadRight($width), (($Optional -contains $key) ? 'missing (optional)' : 'MISSING')
        }
    }
}

function Get-VehicleSafetySecretKey {
    <#
        control-server#600. The store key of one vehicle's projection credential. The name is the contract with
        19-deploy-control-server-parallel.ps1 and 06-deploy-onboard-hmi.ps1, which read it by the same literal.
    #>
    param([Parameter(Mandatory = $true)][string] $VehicleKey)
    return 'OnboardSafetyCredential:' + $VehicleKey
}

function New-VehicleSafetySecret {
    <#
        32 random bytes, base64url without padding: 43 characters that a Bearer header, a service Environment entry and
        a machine variable all carry as they are. Returned as a SecureString; the text exists only inside this call.
    #>
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    try {
        $text = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        return ConvertTo-SecureString $text -AsPlainText -Force
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Add-VehicleSafetySecret {
    <#
        Puts a new projection credential for one vehicle into the store and returns the store. Refuses a vehicle that
        has one unless -Rotate, and refuses a value equal to the shared onboard credential or another vehicle's: the
        server would refuse to start on either (control-server#600). Pure apart from -NewSecret, which the self-test
        replaces. Errors name the vehicle, never a value.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable] $Store,
        [Parameter(Mandatory = $true)][string] $VehicleKey,
        [Parameter(Mandatory = $true)][scriptblock] $NewSecret,
        [switch] $Rotate
    )
    $key = Get-VehicleSafetySecretKey -VehicleKey $VehicleKey
    if ($Store.ContainsKey($key) -and $Store[$key] -and -not $Rotate) {
        throw "VEHICLE_SAFETY_CREDENTIAL_PRESENT: $VehicleKey already has a projection credential. Pass -Rotate to replace it, then deploy the server and that vehicle again."
    }
    $value = & $NewSecret
    $text = [System.Net.NetworkCredential]::new('', $value).Password
    foreach ($other in @($Store.Keys)) {
        if ($other -ceq $key -or -not $Store[$other]) { continue }
        if ($other -cne 'OnboardCredential' -and -not $other.StartsWith('OnboardSafetyCredential:', [StringComparison]::Ordinal)) { continue }
        if ([System.Net.NetworkCredential]::new('', $Store[$other]).Password -ceq $text) {
            throw "VEHICLE_SAFETY_CREDENTIAL_NOT_UNIQUE: the value generated for $VehicleKey equals the one stored as $other. Nothing was stored; run again."
        }
    }
    $Store[$key] = $value
    return $Store
}

$required = @('RiotCallApiKey', 'OnboardCredential', 'MesIngestSharedSecret', 'OperatorId')
$optional = @('V2FaultRecoveryCredential')
$keys = $required + $optional

$store = @{}
if (Test-Path -LiteralPath $SecretPath) { $store = Import-Clixml -LiteralPath $SecretPath }

if ($Show) {
    # control-server#600: the per-vehicle projection credentials there are, by store key (names a vehicle, not a value).
    $vehicleKeys = @($store.Keys | Where-Object { $_.StartsWith('OnboardSafetyCredential:', [StringComparison]::Ordinal) } | Sort-Object)
    foreach ($line in Format-SecretPresence -Keys ($keys + $vehicleKeys) -Store $store -Optional $optional) {
        Write-Host $line -ForegroundColor ($line -match 'MISSING$' ? 'Yellow' : 'Green')
    }
    Write-Host "  store: $SecretPath"
    return
}

if ($NewVehicleSafetyCredential) {
    foreach ($alias in $NewVehicleSafetyCredential) {
        $sitePath = Join-Path $SiteDirectory "site-$alias.json"
        if (-not (Test-Path -LiteralPath $sitePath -PathType Leaf)) { throw "No site file for ${alias}: $sitePath" }
        $vehicleKey = [string] (Get-Content -Raw -LiteralPath $sitePath | ConvertFrom-Json).vehicleSafety.expectedVehicleKey
        if ([string]::IsNullOrWhiteSpace($vehicleKey) -or $vehicleKey -like '*REPLACE*') {
            throw "$sitePath has no vehicleSafety.expectedVehicleKey; the credential is filed under it."
        }
        $store = Add-VehicleSafetySecret -Store $store -VehicleKey $vehicleKey -NewSecret { New-VehicleSafetySecret } -Rotate:$Rotate
        Write-Host "  generated $(Get-VehicleSafetySecretKey -VehicleKey $vehicleKey) ($alias)$($Rotate ? ', replacing the old one' : '')" -ForegroundColor Green
    }
    $directory = Split-Path -Parent $SecretPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $store | Export-Clixml -LiteralPath $SecretPath -Force
    Write-Host "Stored in $SecretPath (DPAPI-encrypted; readable only by $env:USERNAME on $env:COMPUTERNAME). Values were not shown." -ForegroundColor Green
    Write-Host 'Next: deploy the v2 server (19-deploy-control-server-parallel.ps1), then each vehicle (06-deploy-onboard-hmi.ps1 -SshAlias <agv02|agv03> -OnboardPort 58105 -HealthPort 58107).' -ForegroundColor DarkGray
    return
}

if ($Import) {
    # Installing the local ControlServer on this machine left both of these in
    # the environment -- the RIoT key in user scope, the onboard credential in
    # machine scope. Taking them from there is not just convenience: retyping
    # the onboard credential is how you end up deploying a different shared
    # secret than the one the local install already uses, and the failure that
    # produces is a refused session with no message that names the cause.
    foreach ($pair in @(
        @{ Key = 'RiotCallApiKey';    Env = 'CONTROL_SERVER_RIOT_CALL_API_KEY' }
        @{ Key = 'OnboardCredential'; Env = 'CONTROL_SERVER_ONBOARD_CREDENTIAL' }
        @{ Key = 'OperatorId';        Env = 'CONTROL_SERVER_OPERATOR_ID' }
    )) {
        if ($store.ContainsKey($pair.Key) -and $store[$pair.Key]) { continue }
        $value = [Environment]::GetEnvironmentVariable($pair.Env, 'User')
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($pair.Env, 'Machine')
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $store[$pair.Key] = ConvertTo-SecureString $value -AsPlainText -Force
            Write-Host "  imported $($pair.Key) from $($pair.Env)" -ForegroundColor Green
        }
    }

    # MesIngest binds 0.0.0.0 on the factory server, so its middleware requires
    # a Bearer token from every caller including the loopback one -- and
    # ControlServer becomes such a caller once JourneyRuntime is enabled. That
    # secret already exists in the MesIngest deployment store; a second copy
    # typed by hand would only be a second thing to keep in sync.
    if (-not ($store.ContainsKey('MesIngestSharedSecret') -and $store['MesIngestSharedSecret']) -and
        (Test-Path -LiteralPath $MesIngestSecretPath)) {
        $mes = Import-Clixml -LiteralPath $MesIngestSecretPath
        if ($mes.ContainsKey('SharedSecret') -and $mes['SharedSecret']) {
            $store['MesIngestSharedSecret'] = $mes['SharedSecret']
            Write-Host '  imported MesIngestSharedSecret from the MesIngest store' -ForegroundColor Green
        }
    }
}

$hints = @{
    RiotCallApiKey            = 'RIoT CallApiKey. Site-issued; the RIoT owner does not reissue or support it.'
    OnboardCredential         = 'Shared onboard credential. The same value goes to the onboard machines.'
    MesIngestSharedSecret     = 'MesIngest Bearer token. Required once JourneyRuntime is enabled.'
    OperatorId                = 'Operator identity the onboard client reports.'
    V2FaultRecoveryCredential = 'v2 parallel instance only: the Host recovery/clearance entry credential. A value of its own, never the MVP''s. Leave empty to skip -- only needed once the v2 Host recovery entry is turned on.'
}

$present = @($store.Keys | Where-Object { $store[$_] })
$plan = @(Get-SecretPromptPlan -Required $required -Optional $optional -Present $present -Replace $Replace)
$store = Update-SecretStore -Store $store -Plan $plan -Hints $hints -ReadSecret {
    param([string] $Name, [string] $Hint, [string] $OnEmpty)
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host "  $Hint" -ForegroundColor DarkGray
    switch ($OnEmpty) {
        'Skip' { Write-Host '  (empty = skip)' -ForegroundColor DarkGray }
        'Keep' { Write-Host '  (empty = keep the stored value)' -ForegroundColor DarkGray }
        default { }
    }
    $value = Read-Host -Prompt '  value' -AsSecureString
    if ($OnEmpty -eq 'AskAgain' -and -not [System.Net.NetworkCredential]::new('', $value).Password) {
        Write-Host '  empty; try again' -ForegroundColor Yellow
    }
    $value
}

$directory = Split-Path -Parent $SecretPath
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$store | Export-Clixml -LiteralPath $SecretPath -Force

Write-Host ''
Write-Host "Stored $(@($keys | Where-Object { $store.ContainsKey($_) -and $store[$_] }).Count) of $($keys.Count) secrets in $SecretPath" -ForegroundColor Green
Write-Host "DPAPI-encrypted; readable only by $env:USERNAME on $env:COMPUTERNAME." -ForegroundColor DarkGray
