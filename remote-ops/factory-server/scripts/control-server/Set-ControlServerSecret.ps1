#Requires -Version 7
<#
.SYNOPSIS
    Writes the ControlServer deployment secrets into the DPAPI store on the
    control host.

.DESCRIPTION
    Four secrets travel with a WIRE_TO_GATE deployment. They are held here,
    encrypted with DPAPI so only the current Windows user on this machine can
    read them back, and assembled into a deployment config at deploy time. They
    never appear on a command line, in a CI log, or in this repository.

        RiotCallApiKey         CONTROL_SERVER_RIOT_CALL_API_KEY
        OnboardCredential      CONTROL_SERVER_ONBOARD_CREDENTIAL
        MesIngestSharedSecret  CONTROL_SERVER_MES_INGEST_SHARED_SECRET
        OperatorId             CONTROL_SERVER_OPERATOR_ID

    OnboardCredential is the one shared value: the same static string
    authenticates the onboard client to the server, so both halves of the
    deployment read it from here. Section 11.1 of RELEASE-CANDIDATE.md is
    explicit about what that means on a plaintext link -- one packet capture
    impersonates the vehicle permanently, with no rotation and no replay window
    -- and that is a known cost accepted for a controlled plant network, not
    something this script can improve on.

.PARAMETER Import
    Take whatever is already on this machine instead of retyping it:
    CONTROL_SERVER_RIOT_CALL_API_KEY and CONTROL_SERVER_OPERATOR_ID from the
    environment, and the MesIngest shared secret from the store that
    13-deploy-mes-ingest-server.ps1 already uses. Anything still missing is
    prompted for.

.PARAMETER Show
    List which secrets are present and how long they are. Never prints a value.

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -Import

.EXAMPLE
    ./Set-ControlServerSecret.ps1 -Show
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set')]
    [switch] $Import,

    [Parameter(Mandatory = $true, ParameterSetName = 'Show')]
    [switch] $Show,

    [string] $SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\control-server-deployment.xml'),

    [string] $MesIngestSecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$keys = @('RiotCallApiKey', 'OnboardCredential', 'MesIngestSharedSecret', 'OperatorId')

$store = @{}
if (Test-Path -LiteralPath $SecretPath) { $store = Import-Clixml -LiteralPath $SecretPath }

if ($Show) {
    foreach ($key in $keys) {
        if ($store.ContainsKey($key) -and $store[$key]) {
            $length = [System.Net.NetworkCredential]::new('', $store[$key]).Password.Length
            Write-Host ("  {0,-22} present ({1} chars)" -f $key, $length) -ForegroundColor Green
        } else {
            Write-Host ("  {0,-22} MISSING" -f $key) -ForegroundColor Yellow
        }
    }
    Write-Host "  store: $SecretPath"
    return
}

function Read-Secret {
    param([string] $Name, [string] $Hint)
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host "  $Hint" -ForegroundColor DarkGray
    while ($true) {
        $value = Read-Host -Prompt '  value' -AsSecureString
        if ([System.Net.NetworkCredential]::new('', $value).Password) { return $value }
        Write-Host '  empty; try again' -ForegroundColor Yellow
    }
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
    RiotCallApiKey        = 'RIoT CallApiKey. Site-issued; the RIoT owner does not reissue or support it.'
    OnboardCredential     = 'Shared onboard credential. The same value goes to the onboard machines.'
    MesIngestSharedSecret = 'MesIngest Bearer token. Required once JourneyRuntime is enabled.'
    OperatorId            = 'Operator identity the onboard client reports.'
}

foreach ($key in $keys) {
    if ($store.ContainsKey($key) -and $store[$key]) { continue }
    $store[$key] = Read-Secret -Name $key -Hint $hints[$key]
}

$directory = Split-Path -Parent $SecretPath
if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$store | Export-Clixml -LiteralPath $SecretPath -Force

Write-Host ''
Write-Host "Stored $($keys.Count) secrets in $SecretPath" -ForegroundColor Green
Write-Host "DPAPI-encrypted; readable only by $env:USERNAME on $env:COMPUTERNAME." -ForegroundColor DarkGray
