#Requires -Version 7
<#
.SYNOPSIS
    Opens the recovery entry on agv01 for the duration of a field acceptance
    window, and closes it again with -Revert. Runs on the control host and
    reaches both agv01 and factory01.

.DESCRIPTION
    ADR-cross-0058 decision 2 has two halves, and only one of them is provable
    with the recovery entry shut: "the operator not putting cargo in is not a
    failure" is visible either way, but "a genuine UNKNOWN can actually reach
    recovery" needs a vehicle whose recovery entry appears. It ships shut --
    wireToGate.recoveryResumeEnabled is false in the product template, so the
    deployment script renders it false every time.

    Three facts make this a script rather than a line in a checklist.

    1. The two ends read DIFFERENT environment variable names for the same
       secret. The vehicle sends the value of CONTROL_SERVER_RECOVERY_PROOF as
       the authenticationProof field; the server compares it against
       Recovery:AuthenticationProofEnvironmentVariable, and its appsettings.json
       carries no Recovery section at all, so that resolves to the fallback name
       CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF. The comparison is
       CryptographicOperations.FixedTimeEquals over the UTF-8 bytes -- the two
       values have to be identical, and an unset server-side variable refuses
       every recovery request with RECOVERY_AUTHENTICATION_REQUIRED rather than
       saying anything about configuration.

    2. Flipping the toggle without the vehicle-side variable is worse than not
       flipping it. SQCD.Agv.Infrastructure/Configuration.cs requires that
       variable in Production the moment RecoveryResumeEnabled is true, so the
       client throws at startup -- in front of whoever is standing at the
       vehicle, at the start of the window.

    3. The server-side variable belongs in the service's own registry
       Environment value, not in the machine environment: that is where
       Install-ControlServerRemote.ps1 puts CONTROL_SERVER_MES_INGEST_SHARED_
       SECRET, the service is already running, and a service reads that key at
       start. So the value is appended to the existing MultiString rather than
       replacing it, and the service is restarted.

    The window state is deliberately NOT folded into the deployment scripts.
    Shut is the factory setting, and a deployment that quietly left the recovery
    entry open would be a worse default than one that closes it. The practical
    consequence is the other way round, and worth knowing before it bites:
    re-running 06-deploy-onboard-hmi.ps1 during a window renders
    recoveryResumeEnabled back to false while the machine variable stays set, so
    the client still starts and the recovery entry silently disappears. Re-run
    this script after any redeployment inside a window.

    The proof itself is generated here, kept in the control host's DPAPI store
    beside the other deployment secrets, and reused on a second run so the two
    ends never drift apart. -Revert removes it from both ends and deletes the
    store entry.

    This changes what a vehicle can be asked to do. It starts nothing: the
    client is left stopped, exactly as 06-deploy-onboard-hmi.ps1 leaves it.

.PARAMETER SshAlias
    agv01 only, with the MVP -ServiceName (workspace#38 review S1). The window of
    a car on a v2 instance -- agv02, agv03 -- is 18-set-v2-recovery-window.ps1;
    here it would put the proof into the MVP service's environment and restart
    the MVP. Both are refused before anything is touched.

.PARAMETER Revert
    Close the window: recoveryResumeEnabled back to false, both environment
    variables removed, service restarted, stored proof deleted.

.EXAMPLE
    pwsh -NoProfile -File 14-set-recovery-window.ps1

.EXAMPLE
    pwsh -NoProfile -File 14-set-recovery-window.ps1 -Revert
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Revert,

    [string]$SshAlias = 'agv01',

    [string]$ServerSshAlias = 'factory01',

    [string]$ServiceName = '8005 AGV ControlServer',

    [string]$InstallRoot = 'C:\8005\OnboardHmi',

    # The same scratch directory 06-deploy-onboard-hmi.ps1 stages into, so a
    # window does not leave a second one behind on the vehicle.
    [string]$StagingRoot = 'C:\temp\agv\onboard-staging',

    [string]$SecretPath = (Join-Path $env:LOCALAPPDATA 'AgvOpsSecrets\w2g-recovery-window.xml')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# workspace#38 review S1: this script serves the MVP and agv01; the v2 cars have their own.
Import-Module (Join-Path $PSScriptRoot '..\..\factory-server\scripts\control-server\ControlServerTarget.psm1') -Force
if (-not (Test-MvpTargetValue -Kind ServiceName -Value $ServiceName)) {
    throw ("TARGET_NOT_MVP: -ServiceName '$ServiceName' is not the MVP service. This script opens the MVP's recovery " +
        "window; a v2 instance's is 18-set-v2-recovery-window.ps1. Nothing was read or changed.")
}
try { $null = Assert-ControlServerVehicleTarget -SshAlias $SshAlias -IsMvp $true }
catch { throw "$($_.Exception.Message) The recovery window of agv02/agv03 is 18-set-v2-recovery-window.ps1." }

# .Replace rather than -replace: the right-hand side of -replace is a regular
# expression, where a lone backslash is an error rather than a backslash.
$toPosix = { param($p) $p.Replace('\', '/') }

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RemoteDirectory
    )
    $local = Join-Path ([System.IO.Path]::GetTempPath()) "$Name-$(Get-Random).ps1"
    Set-Content -LiteralPath $local -Value $Body -Encoding utf8NoBOM -WhatIf:$false
    try {
        $remote = "$RemoteDirectory\$Name.ps1"
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"New-Item -ItemType Directory -Force -Path '$RemoteDirectory' | Out-Null`""
        if ($LASTEXITCODE -ne 0) { throw "ssh $Alias failed preparing $RemoteDirectory (exit $LASTEXITCODE)" }
        & scp -q $local "${Alias}:$(& $toPosix $remote)"
        if ($LASTEXITCODE -ne 0) { throw "scp to $Alias failed (exit $LASTEXITCODE)" }
        $output = & ssh $Alias "pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '$remote'" 2>&1
        $output | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "$Name failed on $Alias (exit $LASTEXITCODE)" }
        & ssh $Alias "pwsh -NoLogo -NoProfile -Command `"Remove-Item -LiteralPath '$remote' -Force`"" | Out-Null
        return $output
    } finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    }
}

$vehicleVariable = 'CONTROL_SERVER_RECOVERY_PROOF'
$serverVariable = 'CONTROL_SERVER_RECOVERY_AUTHENTICATION_PROOF'

# --------------------------------------------------------------------- proof ---

$proof = $null
if (-not $Revert) {
    if (Test-Path -LiteralPath $SecretPath) {
        $stored = Import-Clixml -LiteralPath $SecretPath
        $proof = [System.Net.NetworkCredential]::new('', $stored['RecoveryProof']).Password
        Write-Step "Reusing the proof already stored at $SecretPath"
    } else {
        # 32 bytes, hex. Hex rather than base64 because this value travels
        # through a here-string, a registry MultiString and a JSON payload, and
        # none of those want to argue about + / =.
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $proof = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SecretPath) -WhatIf:$false | Out-Null
        @{ RecoveryProof = (ConvertTo-SecureString $proof -AsPlainText -Force) } |
            Export-Clixml -LiteralPath $SecretPath -WhatIf:$false
        Write-Step "Generated a new proof and stored it at $SecretPath"
    }
}

$action = $Revert ? 'Close' : 'Open'
if (-not $PSCmdlet.ShouldProcess("$SshAlias and $ServerSshAlias", "$action the recovery window")) {
    Write-Step 'WhatIf: stopping before either machine is touched.'
    Write-Step "Would set $vehicleVariable on $SshAlias and $serverVariable in the $ServiceName service environment on $ServerSshAlias"
    Write-Step ("Would set wireToGate.recoveryResumeEnabled to {0} in $InstallRoot\appsettings.json" -f (-not $Revert).ToString().ToLowerInvariant())
    return
}

# ------------------------------------------------------------------- vehicle ---

# The vehicle first. Its client is stopped, so the order is not forced by the
# product -- but a window whose vehicle half failed should not leave a live
# secret sitting in a production service's environment.
Write-Step "Vehicle half on $SshAlias"

$enabled = (-not $Revert).ToString().ToLowerInvariant()
$vehicleBody = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

`$settingsPath = '$InstallRoot\appsettings.json'
if (-not (Test-Path -LiteralPath `$settingsPath)) {
    throw "No onboard installation at $InstallRoot -- deploy it first with 06-deploy-onboard-hmi.ps1."
}

# The client holds this file open while it runs, and editing it under a running
# client would take effect at a restart nobody asked for.
`$running = @(Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue)
if (`$running.Count -gt 0) {
    throw 'SQCD.Agv.Wpf is running on the vehicle. Close it before changing the recovery window.'
}

`$settings = Get-Content -Raw -LiteralPath `$settingsPath | ConvertFrom-Json
`$settings.wireToGate.recoveryResumeEnabled = [bool]::Parse('$enabled')
`$settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath `$settingsPath -Encoding utf8NoBOM

# Read it back rather than trusting the write: this is the value that decides
# whether the client starts at all.
`$readBack = (Get-Content -Raw -LiteralPath `$settingsPath | ConvertFrom-Json).wireToGate.recoveryResumeEnabled
"recoveryResumeEnabled: `$readBack"

if ('$enabled' -eq 'true') {
    [Environment]::SetEnvironmentVariable('$vehicleVariable', '$proof', 'Machine')
    "$vehicleVariable set (machine scope)"
} else {
    # [NullString]::Value, not `$null: PowerShell hands `$null to a .NET string
    # parameter as "", and on .NET 10 that writes an empty REG_SZ instead of
    # deleting the variable. Measured on agv01 after the 2026-09-10 -Revert.
    [Environment]::SetEnvironmentVariable('$vehicleVariable', [NullString]::Value, 'Machine')
    "$vehicleVariable removed"
}
"@

Invoke-RemoteScript -Alias $SshAlias -Body $vehicleBody -Name 'set-recovery-window-vehicle' -RemoteDirectory $StagingRoot | Out-Null

# -------------------------------------------------------------------- server ---

Write-Step "Server half on $ServerSshAlias"

$serverBody = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

`$key = 'SYSTEM\CurrentControlSet\Services\$ServiceName'
`$registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(`$key, `$true)
if (`$null -eq `$registryKey) { throw "Cannot open the service registry key: `$key" }
try {
    # Everything already in there stays. CONTROL_SERVER_MES_INGEST_SHARED_SECRET
    # lives in this same value, and losing it would break the ControlServer's
    # calls to MesIngest the next time JourneyRuntime is enabled.
    [string[]]`$environment = @(`$registryKey.GetValue('Environment'))
    `$environment = @(`$environment | Where-Object { `$_ -and `$_ -notlike '$serverVariable=*' })
    if ('$enabled' -eq 'true') {
        `$environment += '$serverVariable=$proof'
    }
    `$registryKey.SetValue('Environment', `$environment, [Microsoft.Win32.RegistryValueKind]::MultiString)
    `$names = @(`$environment | ForEach-Object { (`$_ -split '=', 2)[0] })
    "service environment now carries: `$(`$names -join ', ')"
} finally {
    `$registryKey.Close()
}

Restart-Service -Name '$ServiceName' -Force
`$service = Get-Service -Name '$ServiceName'
"service $ServiceName is `$(`$service.Status)"
"@

Invoke-RemoteScript -Alias $ServerSshAlias -Body $serverBody -Name 'set-recovery-window-server' -RemoteDirectory 'D:\zhengyushao\control-server-ops' | Out-Null

# --------------------------------------------------------------------- after ---

if ($Revert) {
    Remove-Item -LiteralPath $SecretPath -Force -ErrorAction SilentlyContinue
    Write-Step 'Recovery window closed. The stored proof is deleted.'
} else {
    Write-Step 'Recovery window open. The client is still stopped -- starting it is yours.'
    Write-Host ''
    Write-Host '  Close it again when the window ends:' -ForegroundColor DarkGray
    Write-Host '    pwsh -NoProfile -File 14-set-recovery-window.ps1 -Revert' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Re-deploying the onboard client inside the window renders' -ForegroundColor DarkGray
    Write-Host '  recoveryResumeEnabled back to false. Re-run this script if you do.' -ForegroundColor DarkGray
}
