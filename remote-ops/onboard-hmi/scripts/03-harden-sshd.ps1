#Requires -Version 7

<#
  03-harden-sshd.ps1 - Disable password authentication on an AGV onboard HMI.

  RUN THIS ONLY AFTER you have successfully logged in from the control
  workstation using the key. Running it before that can lock you out of SSH.
  (You would still get in via VNC/console, but it wastes a trip to the car.)

  WHAT THIS CHANGES:
    - sshd_config: PasswordAuthentication no, KbdInteractiveAuthentication no,
      PermitEmptyPasswords no, PubkeyAuthentication yes
    - restarts sshd

  Usage (on the HMI machine, PowerShell 7 as Administrator):
      pwsh -ExecutionPolicy Bypass -File .\03-harden-sshd.ps1
      pwsh -ExecutionPolicy Bypass -File .\03-harden-sshd.ps1 -Force   # skip the confirmation
#>

[CmdletBinding()]
param(
    # Skip the "have you actually tested key login?" prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ok   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "  FAIL $msg" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Must run elevated.'
}

$sshDir  = 'C:\ProgramData\ssh'
$cfgPath = Join-Path $sshDir 'sshd_config'
if (-not (Test-Path $cfgPath)) { Die "$cfgPath not found. Run 02-bootstrap-sshd.ps1 first." }

# ------------------------------------------------------------- sanity check
Step 'Checking that an authorized key is actually installed'
$adminKeys = Join-Path $sshDir 'administrators_authorized_keys'
$userKeys  = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$keyCount  = 0
foreach ($f in $adminKeys, $userKeys) {
    if (Test-Path $f) {
        $n = @(Get-Content $f | Where-Object { $_ -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2)' }).Count
        if ($n -gt 0) { Ok "$n key(s) in $f" }
        $keyCount += $n
    }
}
if ($keyCount -eq 0) {
    Die 'No authorized keys found. Disabling passwords now would lock SSH out entirely.'
}

if (-not $Force) {
    Write-Host "`nHave you already logged in from the control workstation using the key?" -ForegroundColor Yellow
    Write-Host "If not, answer no, go test it, then come back." -ForegroundColor Yellow
    $answer = Read-Host 'Type YES to disable password authentication'
    if ($answer -ne 'YES') { Warn 'aborted, nothing changed'; exit 0 }
}

# ------------------------------------------------------------------- apply
Step 'Editing sshd_config'
$backup = Join-Path $sshDir ("sshd_config.backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $cfgPath $backup -Force
Ok "backed up to $backup"

function Set-Directive {
    param([string[]]$Lines, [string]$Name, [string]$Value)
    $pattern = "^\s*#?\s*$Name\s+"
    if ($Lines | Where-Object { $_ -match $pattern }) {
        return $Lines | ForEach-Object { if ($_ -match $pattern) { "$Name $Value" } else { $_ } }
    }
    return $Lines + "$Name $Value"
}

$cfg = Get-Content $cfgPath
$cfg = Set-Directive $cfg 'PubkeyAuthentication'         'yes'
$cfg = Set-Directive $cfg 'PasswordAuthentication'       'no'
$cfg = Set-Directive $cfg 'KbdInteractiveAuthentication' 'no'
$cfg = Set-Directive $cfg 'PermitEmptyPasswords'         'no'
[IO.File]::WriteAllLines($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
Ok 'password authentication disabled'

Step 'Restarting sshd'
Restart-Service sshd
Start-Sleep -Seconds 2
if ((Get-Service sshd).Status -ne 'Running') {
    Warn 'sshd did not come back up. Restoring the backup.'
    Copy-Item $backup $cfgPath -Force
    Restart-Service sshd
    Die 'config rejected by sshd; original restored'
}
Ok 'sshd running'

Step 'Effective settings'
Get-Content $cfgPath |
    Where-Object { $_ -match '^\s*(Port|PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|PermitEmptyPasswords)\s' } |
    ForEach-Object { "    $_" }

Write-Host @"

=====================================================================
 HARDENED. SSH now accepts the ops key only.

 UNDO:
   Copy-Item '$backup' '$cfgPath' -Force ; Restart-Service sshd
=====================================================================
"@ -ForegroundColor White
