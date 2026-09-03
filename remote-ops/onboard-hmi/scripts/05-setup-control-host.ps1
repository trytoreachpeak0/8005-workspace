#Requires -Version 7

<#
  05-setup-control-host.ps1 - Rebuild the CONTROL side of the AGV ops channel.

  RUN THIS ON A CONTROL WORKSTATION, NOT ON AN HMI.

  Use it when moving to a new laptop, after reinstalling Windows, or to verify
  an existing setup. It installs the SSH config, checks the ops keypair, and
  tests every configured car.

  WHAT THIS CHANGES ON THIS MACHINE:
    - Creates %USERPROFILE%\.ssh if missing.
    - Installs config\ssh_config.agv to %USERPROFILE%\.ssh\config
      (backs up any existing config first).
    - With -GenerateNewKey: creates a NEW ops keypair. The old one stops working
      everywhere until you distribute the new public key to every car by hand.

  The private key is NOT in this repository by design -- see docs/ASSETS.md.
  Copy it from the old machine before running this, or pass -GenerateNewKey and
  accept that you must revisit every car over VNC.

  Usage:
      pwsh -ExecutionPolicy Bypass -File .\05-setup-control-host.ps1
      pwsh -ExecutionPolicy Bypass -File .\05-setup-control-host.ps1 -GenerateNewKey
      pwsh -ExecutionPolicy Bypass -File .\05-setup-control-host.ps1 -SkipConnectivityTest
#>

[CmdletBinding()]
param(
    # Create a fresh keypair. Only do this if the old private key is truly gone:
    # every car must then have the new public key installed manually over VNC.
    [switch]$GenerateNewKey,

    # Skip the "can we actually reach the cars" step.
    [switch]$SkipConnectivityTest,

    # Forwarded to Build-SshConfig.ps1. Needed once, on a machine whose
    # ~/.ssh/config still has the channel blocks pasted in inline.
    [switch]$ReplaceExistingConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok   $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m"   -ForegroundColor Yellow }
function Info($m) { Write-Host "  ..   $m"   -ForegroundColor Gray }
function Die($m)  { Write-Host "  FAIL $m"   -ForegroundColor Red; exit 1 }

$repoRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$configSrc = Join-Path $repoRoot 'config\ssh_config.agv'
$pubSrc    = Join-Path $repoRoot 'config\agv_ops_ed25519.pub'
$sshDir    = Join-Path $env:USERPROFILE '.ssh'
$keyPath   = Join-Path $sshDir 'agv_ops_ed25519'

# ------------------------------------------------------------ preconditions
Step 'Checking the repository copy is intact'
foreach ($f in $configSrc, $pubSrc) {
    if (-not (Test-Path $f)) { Die "missing from the repo: $f" }
}
Ok 'config/ssh_config.agv and config/agv_ops_ed25519.pub present'

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Die 'no ssh client on PATH. Install the OpenSSH Client Windows capability first.'
}
Ok "ssh client: $((Get-Command ssh).Source)"

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    Ok "created $sshDir"
}

# ------------------------------------------------------------------- keypair
Step 'Checking the ops keypair'

if ($GenerateNewKey) {
    if (Test-Path $keyPath) {
        Warn "a key already exists at $keyPath"
        $answer = Read-Host 'Type REPLACE to overwrite it (every car will need the new public key)'
        if ($answer -ne 'REPLACE') { Die 'aborted, nothing changed' }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item $keyPath "$keyPath.old-$stamp"
        if (Test-Path "$keyPath.pub") { Move-Item "$keyPath.pub" "$keyPath.pub.old-$stamp" }
        Ok "old key moved aside with suffix .old-$stamp"
    }
    # No passphrase: this key drives unattended automation. The tradeoff is
    # documented in README section 5.
    & ssh-keygen -t ed25519 -f $keyPath -N '' -C "agv-ops@$env:COMPUTERNAME" | Out-Null
    if (-not (Test-Path $keyPath)) { Die 'ssh-keygen did not produce a key' }
    Ok 'new keypair generated'
}
elseif (Test-Path $keyPath) {
    Ok "private key present: $keyPath"
}
else {
    Die @"
No private key at $keyPath

The private key is deliberately NOT stored in this repository (see docs/ASSETS.md).
Either:
  - copy agv_ops_ed25519 and agv_ops_ed25519.pub from the previous control
    machine into $sshDir, then re-run this script; or
  - re-run with -GenerateNewKey and then install the new public key on every
    car over VNC, because the old key will no longer work anywhere.
"@
}

# Does the private key on this machine match the public key in the repo? If not,
# ssh will fail with a confusing "Permission denied (publickey)" later.
Step 'Verifying the private key matches the public key in the repo'
$derived = (& ssh-keygen -y -f $keyPath) -join ''
$repoPub = (Get-Content $pubSrc -Raw).Trim()
$derivedBody = ($derived -split '\s+')[1]
$repoBody    = ($repoPub -split '\s+')[1]

if ($derivedBody -eq $repoBody) {
    Ok 'private key matches config/agv_ops_ed25519.pub'
} else {
    Warn 'the private key here does NOT match the public key recorded in the repo'
    Warn "  repo    : $repoBody"
    Warn "  derived : $derivedBody"
    Warn 'The cars trust whichever key was installed on them. If you just generated'
    Warn 'a new key, update config/agv_ops_ed25519.pub and redistribute it.'
}

# ------------------------------------------------------------------- config
Step 'Building the SSH config from every remote-ops channel'

# This used to copy config\ssh_config.agv over ~/.ssh/config. There is only one
# such file and the factory-server and lab-VM channels keep their aliases in it
# too, so that copy silently deleted factory01 and vm01. Build-SshConfig.ps1
# merges every channel's fragment into ~/.ssh/conf.d and refuses to write on a
# name collision. See ..\..\control-host\README.md.
$builder = Join-Path (Split-Path -Parent $repoRoot) 'control-host\Build-SshConfig.ps1'
if (-not (Test-Path $builder)) { Die "missing: $builder" }

$configDst = Join-Path $sshDir 'config'
$builderArgs = @('-NoProfile', '-File', $builder)
if ($ReplaceExistingConfig) { $builderArgs += '-ReplaceExisting' }

& pwsh @builderArgs
if ($LASTEXITCODE -ne 0) {
    Die "Build-SshConfig.ps1 exited $LASTEXITCODE. Fix what it reported and re-run; nothing else here was changed."
}
Ok "SSH config built (managed block in $configDst, fragments in $sshDir\conf.d)"

# ------------------------------------------------------------- connectivity
# Read the fragment, not ~/.ssh/config: the built config reaches the aliases
# through an Include, so they are not literally in that file any more.
$fragLines = @(Get-Content $configSrc)
$hosts = @()
for ($i = 0; $i -lt $fragLines.Count; $i++) {
    if ($fragLines[$i] -notmatch '^\s*Host\s+(agv\d+)\s*$') { continue }
    $alias = $Matches[1]
    # A HostName of REPLACE_* means the name is reserved but the car is not
    # online. Build-SshConfig.ps1 omits it, so there is nothing to test.
    $reserved = $false
    for ($j = $i + 1; $j -lt $fragLines.Count -and $fragLines[$j] -notmatch '^\s*Host\s'; $j++) {
        if ($fragLines[$j] -match '^\s*HostName\s+REPLACE_') { $reserved = $true }
    }
    if ($reserved) { Info "$alias is reserved but not online yet -- skipping" } else { $hosts += $alias }
}

if ($SkipConnectivityTest) {
    Warn 'skipping connectivity test as requested'
} elseif ($hosts.Count -eq 0) {
    Warn 'no agvNN hosts defined in the config yet'
} else {
    Step "Testing $($hosts.Count) configured car(s)"
    foreach ($h in $hosts) {
        try {
            $result = & ssh -o BatchMode=yes -o ConnectTimeout=10 $h `
                '$env:USERNAME + "@" + $env:COMPUTERNAME' 2>&1
            if ($LASTEXITCODE -eq 0) {
                Ok "$h -> $($result -join ' ')"
            } else {
                Warn "$h -> FAILED: $($result -join ' ')"
            }
        } catch {
            Warn "$h -> FAILED: $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------------- summary
Write-Host @"

=====================================================================
 CONTROL HOST READY

   SSH config : $configDst
   Private key: $keyPath
   Cars       : $(if ($hosts) { $hosts -join ', ' } else { '(none configured)' })

 Day-to-day usage: docs\USAGE.md
 Where everything lives: docs\ASSETS.md
"@ -ForegroundColor White

if ($GenerateNewKey) {
    $newPub = (Get-Content "$keyPath.pub" -Raw).Trim()
    Write-Host @"

 *** NEW KEY GENERATED - NO CAR TRUSTS IT YET ***

 Public key:
   $newPub

 On EACH car, over VNC, in an elevated PowerShell:

   `$k = '$newPub'
   `$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
   Set-Content -Path `$f -Value `$k -Encoding utf8NoBOM
   icacls `$f /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F'
   Restart-Service sshd

 Then update config\agv_ops_ed25519.pub in the repo to match.
"@ -ForegroundColor Yellow
}
