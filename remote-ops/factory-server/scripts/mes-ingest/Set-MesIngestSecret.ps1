#Requires -Version 7
<#
.SYNOPSIS
    Stores the MesIngest deployment secrets on this control host, DPAPI-protected.

.DESCRIPTION
    The deployment needs three secrets that must never reach the repository, a
    CI log, a command line, or a chat transcript:

      SqlPassword    - the dedicated `mesingest` SQL Server login
      OraclePassword - the MES source account (`fwmes`)
      SharedSecret   - the bearer token the Host requires once Urls binds beyond
                       localhost, and that Watch sends on every request

    They are held as SecureStrings inside a Export-Clixml file, which on Windows
    means DPAPI under the current user account. Another user on this machine
    cannot read it, and it does not survive being copied to another machine —
    both are the point. This is the same mechanism and the same directory that
    already holds the agvops console-rescue password.

    Run with -Import to lift the Oracle password out of the retired local
    install (C:\MesIngest\service\appsettings.Local.json) instead of retyping it.

.PARAMETER Path
    Secret store location. Defaults to the AgvOpsSecrets directory used by the
    rest of remote-ops.

.PARAMETER Import
    Read OraclePassword (and the SQL password, if that install used one) from an
    existing appsettings.Local.json rather than prompting for it.

.PARAMETER ResetSqlPassword
    Prompt for the SQL password again even though one is already stored. Needed
    after SQL Server rejects one for complexity, and whenever the login's
    password is changed out of band.

.PARAMETER RotateSharedSecret
    Generate a new SharedSecret even if one is already stored. Both the Host and
    every Watch must be redeployed afterwards, or they stop authenticating.

.EXAMPLE
    ./Set-MesIngestSecret.ps1 -Import 'C:\MesIngest\service\appsettings.Local.json'

.EXAMPLE
    ./Set-MesIngestSecret.ps1 -Show
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [string] $Path = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\mes-ingest-deployment.xml'),

    [Parameter(ParameterSetName = 'Set')]
    [string] $Import,

    [Parameter(ParameterSetName = 'Set')]
    [switch] $ResetSqlPassword,

    [Parameter(ParameterSetName = 'Set')]
    [switch] $RotateSharedSecret,

    [Parameter(ParameterSetName = 'Show')]
    [switch] $Show
)

$ErrorActionPreference = 'Stop'

function Read-Existing {
    param([string] $StorePath)
    if (Test-Path -LiteralPath $StorePath) { return Import-Clixml -LiteralPath $StorePath }
    return @{}
}

# SQL Server creates the login with CHECK_POLICY = ON, so the password has to
# satisfy the server's Windows policy. Getting that wrong used to surface as a
# failed deployment several minutes later:
#
#     消息 15118 ... 密码验证失败。该密码不够复杂，不符合操作系统策略要求。
#
# by which point a database had already been created. Checking here turns that
# into a reprompt. This mirrors the Windows default complexity rule rather than
# reading the server's actual policy — a local check cannot be authoritative, so
# it is deliberately no stricter than the default: passing here is not a promise,
# but failing here is certain.
function Test-PasswordComplexity {
    param([securestring] $Password, [string] $LoginName)

    $value = [System.Net.NetworkCredential]::new('', $Password).Password
    $problems = @()

    if ($value.Length -lt 8) { $problems += '至少 8 个字符' }

    $classes = 0
    if ($value -cmatch '[A-Z]') { $classes++ }
    if ($value -cmatch '[a-z]') { $classes++ }
    if ($value -match '[0-9]') { $classes++ }
    if ($value -match '[^a-zA-Z0-9]') { $classes++ }
    if ($classes -lt 3) {
        $problems += '大写字母、小写字母、数字、符号，四类里至少要占三类'
    }

    if ($LoginName -and $value -like "*$LoginName*") {
        $problems += "不能包含登录名 $LoginName"
    }

    return $problems
}

if ($Show) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Output "No secret store at $Path"
        exit 1
    }
    $store = Read-Existing $Path
    Write-Output "Secret store: $Path"
    foreach ($key in @('SqlPassword', 'OraclePassword', 'SharedSecret')) {
        $state = if ($store.ContainsKey($key) -and $store[$key]) { 'set' } else { 'MISSING' }
        Write-Output ("  {0,-15} {1}" -f $key, $state)
    }
    Write-Output "Values are never printed. Deployment scripts read them directly."
    exit 0
}

$store = Read-Existing $Path

# Oracle credentials already exist on this machine, in the install that is being
# retired. Retyping a password is a chance to get it wrong silently, so offer to
# lift it instead. Only the password is taken; host, service name and user are
# not secret and live in the deployment config.
if ($Import) {
    if (-not (Test-Path -LiteralPath $Import)) { throw "Import source not found: $Import" }
    $existing = Get-Content -LiteralPath $Import -Raw | ConvertFrom-Json

    $oracle = $existing.MesIngest.OraclePassword
    if ([string]::IsNullOrWhiteSpace($oracle)) {
        Write-Warning "No OraclePassword in $Import; you will be prompted for it."
    } else {
        $store['OraclePassword'] = ConvertTo-SecureString -String $oracle -AsPlainText -Force
        Write-Output "Imported OraclePassword from $Import"
    }
}

if (-not $store.ContainsKey('OraclePassword') -or -not $store['OraclePassword']) {
    $store['OraclePassword'] = Read-Host -AsSecureString -Prompt 'MES Oracle password (user fwmes)'
}

if ($ResetSqlPassword -or -not $store.ContainsKey('SqlPassword') -or -not $store['SqlPassword']) {
    Write-Output ''
    Write-Output 'SQL Server login `mesingest` on the factory server.'
    Write-Output 'Pick it now; the deployment creates the login with this password.'
    Write-Output '要求：至少 8 位，且大写/小写/数字/符号四类里占三类。'

    while ($true) {
        $candidate = Read-Host -AsSecureString -Prompt 'Password for SQL login mesingest'
        if ($candidate.Length -eq 0) {
            Write-Warning '密码不能为空。'
            continue
        }
        $problems = Test-PasswordComplexity -Password $candidate -LoginName 'mesingest'
        if ($problems.Count -eq 0) {
            $store['SqlPassword'] = $candidate
            break
        }
        Write-Warning "这个密码 SQL Server 会拒绝（CHECK_POLICY = ON）：$($problems -join '；')"
    }
}

# The shared secret is machine-generated on purpose. It is never typed by a
# human, never displayed, and both ends of the deployment read it from here — so
# there is no reason for it to be memorable or short.
if ($RotateSharedSecret -or -not $store.ContainsKey('SharedSecret') -or -not $store['SharedSecret']) {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $generated = [Convert]::ToBase64String($bytes)
    $store['SharedSecret'] = ConvertTo-SecureString -String $generated -AsPlainText -Force
    $verb = if ($RotateSharedSecret) { 'Rotated' } else { 'Generated' }
    Write-Output "$verb SharedSecret (32 random bytes, base64). Value not displayed."
    if ($RotateSharedSecret) {
        Write-Warning 'Redeploy the Host AND every Watch, or they will stop authenticating.'
    }
}

$dir = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$store | Export-Clixml -LiteralPath $Path -Force

Write-Output ''
Write-Output "Stored (DPAPI, current user only): $Path"
Write-Output 'Run with -Show to check what is set without revealing values.'
