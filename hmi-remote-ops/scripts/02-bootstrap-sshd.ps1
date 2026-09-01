<#
  02-bootstrap-sshd.ps1 - Install and configure OpenSSH Server on an AGV onboard HMI.

  WHY A DEDICATED ACCOUNT:
    The production account (HT) has a BLANK password, which is how the machine
    boots straight to the desktop. Windows' LimitBlankPasswordUse policy blocks
    blank-password accounts from network logon, so SSH as HT would fail. Giving
    HT a password would break the auto-desktop behaviour the AGV depends on, and
    relaxing the policy would expose HT over SMB (445 is open). So this script
    creates a separate 'agvops' administrator instead. HT is left untouched.

  WHAT THIS CHANGES ON THE MACHINE (all reversible, see UNDO at the end):
    1. Creates a local admin account (default: agvops) with a random password.
    2. Installs the OpenSSH.Server capability, or from an offline zip.
    3. Sets the sshd service to Automatic and starts it.
    4. Sets sshd's default shell to PowerShell 7.
    5. Writes the ops public key to administrators_authorized_keys, ACL-locked.
    6. Backs up then edits C:\ProgramData\ssh\sshd_config.
    7. Adds an inbound firewall rule for the SSH port.

  DELIBERATELY NOT DONE HERE: disabling password authentication.
  Password auth stays ON until key login is proven. Run 03-harden-sshd.ps1 after.

  THIS MACHINE HAS NO INTERNET (probe confirmed: 1.1.1.1:443 unreachable,
  DNS resolution fails), so -OfflinePackage is effectively required.

  Usage (on the HMI machine, PowerShell 7 as Administrator):
      pwsh -ExecutionPolicy Bypass -File .\02-bootstrap-sshd.ps1 -OfflinePackage C:\temp\OpenSSH-Win64.zip
#>

[CmdletBinding()]
param(
    # Public half of the ops keypair held on the control workstation.
    [string]$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDsJSPXBPihtqYQKyITbOMP4eI0zs3p1JFfU3GB7LwRB agv-ops@LAB-WIN-01',

    # Dedicated ops account. Kept separate from the production desktop account.
    [string]$OpsUser = 'agvops',

    # Use the account running this script instead of creating a dedicated one.
    # Only sane if that account has a real password.
    [switch]$UseCurrentUser,

    # Port sshd listens on LOCALLY. The CPE forwards an external port to this.
    [int]$Port = 22,

    # Path to OpenSSH-Win64.zip. Required on machines with no internet.
    [string]$OfflinePackage,

    # Skip the install step, e.g. when re-running to fix configuration only.
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ok   $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "  FAIL $msg" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------ preconditions
Step 'Checking preconditions'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Must run elevated. Right-click PowerShell 7 -> Run as administrator.'
}
Ok "elevated as $env:USERDOMAIN\$env:USERNAME"

if ($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2)\s+\S+') {
    Die "PublicKey does not look like an OpenSSH public key."
}
Ok 'public key format looks valid'

# ------------------------------------------------------------- ops account
$generatedPassword = $null

if ($UseCurrentUser) {
    $sshUser = $env:USERNAME
    Warn "using current account '$sshUser' for SSH; blank-password accounts will fail network logon"
} else {
    Step "Preparing dedicated ops account '$OpsUser'"
    $existing = Get-LocalUser -Name $OpsUser -ErrorAction SilentlyContinue

    if ($existing) {
        Ok "account '$OpsUser' already exists; leaving its password alone"
    } else {
        # Random password. Shown once, never written to disk. Day-to-day access
        # is by key; this exists only to satisfy Windows and for console rescue.
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+'
        $generatedPassword = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
        $secure = ConvertTo-SecureString $generatedPassword -AsPlainText -Force

        # -Description is capped at 48 characters by New-LocalUser; keep it short.
        New-LocalUser -Name $OpsUser -Password $secure `
            -FullName 'AGV remote operations' `
            -Description 'AGV remote ops automation' `
            -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
        Ok "account '$OpsUser' created"
    }

    # Administrators group membership, by SID so localised Windows works too.
    $adminGroup = (Get-LocalGroup -SID 'S-1-5-32-544').Name
    $isMember = Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "$env:COMPUTERNAME\$OpsUser" }
    if ($isMember) {
        Ok "'$OpsUser' already in $adminGroup"
    } else {
        Add-LocalGroupMember -Group $adminGroup -Member $OpsUser
        Ok "'$OpsUser' added to $adminGroup"
    }
    $sshUser = $OpsUser
}

# ---------------------------------------------------------------- install
if (-not $SkipInstall) {
    Step 'Installing OpenSSH Server'

    $cap = $null
    try { $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' } catch { }

    if ($cap -and $cap.State -eq 'Installed') {
        Ok 'OpenSSH.Server capability already installed'
    }
    elseif ($OfflinePackage) {
        if (-not (Test-Path $OfflinePackage)) { Die "offline package not found: $OfflinePackage" }
        Step "Installing from offline package $OfflinePackage"
        $dest = 'C:\Program Files\OpenSSH'
        Expand-Archive -Path $OfflinePackage -DestinationPath 'C:\Program Files' -Force
        # The official zip expands to OpenSSH-Win64; normalise the folder name.
        if (Test-Path 'C:\Program Files\OpenSSH-Win64') {
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            Move-Item 'C:\Program Files\OpenSSH-Win64' $dest
        }
        if (-not (Test-Path "$dest\install-sshd.ps1")) { Die "install-sshd.ps1 missing under $dest" }
        # install-sshd.ps1 ships targeting Windows PowerShell; run it there.
        & powershell.exe -ExecutionPolicy Bypass -File "$dest\install-sshd.ps1"
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if ($machinePath -notlike "*$dest*") {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$dest", 'Machine')
            $env:Path = "$env:Path;$dest"
        }
        Ok 'offline OpenSSH installed'
    }
    else {
        Step 'Trying the Windows capability route (needs internet or a local FoD source)'
        try {
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
            Ok 'OpenSSH.Server capability installed'
        } catch {
            Die @"
Capability install failed: $($_.Exception.Message)

The probe confirmed this machine has no internet access, so this was expected.
Download OpenSSH-Win64.zip from
  https://github.com/PowerShell/Win32-OpenSSH/releases
on a machine that has internet, copy it over, and re-run with:
  -OfflinePackage <path-to-zip>
"@
        }
    }
} else {
    Warn 'skipping install step as requested'
}

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Die 'sshd service still not present after install.'
}

# ------------------------------------------------------------- service up
Step 'Starting sshd and setting it to start automatically'
Set-Service -Name sshd -StartupType Automatic
Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd
Start-Service 'ssh-agent' -ErrorAction SilentlyContinue
Ok "sshd is $((Get-Service sshd).Status), startup $((Get-Service sshd).StartType)"

# sshd only creates C:\ProgramData\ssh after its first successful start.
$sshDir = 'C:\ProgramData\ssh'
if (-not (Test-Path $sshDir)) { Die "$sshDir does not exist even after starting sshd." }

# ----------------------------------------------------------- default shell
Step 'Setting default shell to PowerShell 7'
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshPath) {
    foreach ($candidate in 'C:\Program Files\PowerShell\7\pwsh.exe',
                           'C:\Program Files (x86)\PowerShell\7\pwsh.exe') {
        if (Test-Path $candidate) { $pwshPath = $candidate; break }
    }
}
if ($pwshPath) {
    $key = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name DefaultShell -Value $pwshPath -PropertyType String -Force | Out-Null
    Ok "default shell -> $pwshPath"
} else {
    Warn 'pwsh 7 not found; sshd will keep using cmd.exe'
}

# ------------------------------------------------------------ authorized key
Step "Installing the ops public key for '$sshUser'"

# The ops account is an administrator, and Windows OpenSSH ships a
# `Match Group administrators` block that redirects admins to this one
# machine-wide file. Putting the key in ~\.ssh\authorized_keys would be ignored.
$keyFile = Join-Path $sshDir 'administrators_authorized_keys'

$existingKeys = if (Test-Path $keyFile) { @(Get-Content $keyFile -ErrorAction SilentlyContinue) } else { @() }
$keyBody = ($PublicKey -split '\s+')[1]

if ($existingKeys | Where-Object { $_ -match [regex]::Escape($keyBody) }) {
    Ok "key already present in $keyFile"
} else {
    # Windows OpenSSH rejects a BOM; write UTF-8 without one.
    $lines = @($existingKeys | Where-Object { $_ -and $_.Trim() }) + $PublicKey
    [IO.File]::WriteAllLines($keyFile, $lines, (New-Object Text.UTF8Encoding($false)))
    Ok "key appended to $keyFile"
}

# The single most common reason key auth silently fails on Windows: sshd
# refuses an authorized-keys file writable by anyone but SYSTEM/Administrators.
# SIDs rather than names, so this also works on Chinese Windows.
Step 'Locking down the authorized-keys file ACL'
& icacls.exe $keyFile /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null
if ($LASTEXITCODE -ne 0) { Warn "icacls returned $LASTEXITCODE" } else { Ok 'ACL: SYSTEM + Administrators only' }

# ------------------------------------------------------------- sshd_config
Step 'Configuring sshd_config'
$cfgPath = Join-Path $sshDir 'sshd_config'
$backup  = Join-Path $sshDir ("sshd_config.backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $cfgPath $backup -Force
Ok "backed up original to $backup"

# Rewrite a directive whether it is currently commented out, set, or absent.
function Set-Directive {
    param([string[]]$Lines, [string]$Name, [string]$Value)
    $pattern = "^\s*#?\s*$Name\s+"
    if ($Lines | Where-Object { $_ -match $pattern }) {
        return $Lines | ForEach-Object { if ($_ -match $pattern) { "$Name $Value" } else { $_ } }
    }
    return $Lines + "$Name $Value"
}

$cfg = Get-Content $cfgPath
$cfg = Set-Directive $cfg 'Port'                 $Port
$cfg = Set-Directive $cfg 'PubkeyAuthentication' 'yes'
# PasswordAuthentication intentionally untouched; 03-harden-sshd.ps1 turns it off.
[IO.File]::WriteAllLines($cfgPath, $cfg, (New-Object Text.UTF8Encoding($false)))
Ok "Port $Port, PubkeyAuthentication yes"

# ---------------------------------------------------------------- firewall
Step "Opening inbound TCP $Port on all profiles"
$ruleName = "OpenSSH-Server-In-TCP-$Port"
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    Ok "firewall rule '$ruleName' already exists"
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName "OpenSSH Server (TCP $Port)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
        -LocalPort $Port -Profile Any | Out-Null
    Ok "firewall rule '$ruleName' created"
}

# ----------------------------------------------------------------- restart
Step 'Restarting sshd to apply configuration'
Restart-Service sshd
Start-Sleep -Seconds 2
if ((Get-Service sshd).Status -ne 'Running') {
    Die "sshd is not running after restart. Check: Get-WinEvent -LogName 'OpenSSH/Operational' -Max 20"
}
Ok 'sshd running'

# -------------------------------------------------------------- self-check
Step 'Self-check'
if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    Ok "listening on TCP $Port"
} else {
    Warn "nothing listening on TCP $Port"
}

$lanIp = ((Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress |
    Select-Object -First 1)
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric | Select-Object -First 1).NextHop

Write-Host @"

=====================================================================
 BOOTSTRAP COMPLETE on $env:COMPUTERNAME

   LAN IP           : $lanIp
   CPE (gateway)    : $gw
   SSH user         : $sshUser
   SSH port (local) : $Port
   Auth             : public key AND password (password disabled in step 03)
   Key file         : $keyFile
"@ -ForegroundColor White

if ($generatedPassword) {
    Write-Host @"

 *** WRITE THIS DOWN NOW - IT IS NOT STORED ANYWHERE ***
   $sshUser password: $generatedPassword

   Only needed for console/VNC rescue. Normal access is by key.
"@ -ForegroundColor Yellow
}

Write-Host @"

 NEXT, ON THE CPE (172.19.162.210, KonNaD CPE2458):
   Public port 22022, protocol TCP  ->  ${lanIp}:$Port
   Not external 22 (the CPE's own dropbear owns it) and not 2222 (already
   forwarded). Also taken: 80, 443, 502, 5001-5003, 5010, 5900, 8001, 8005,
   8008, 8009.

 THEN, FROM THE CONTROL WORKSTATION:
   ssh agv01
   (equivalently: ssh -i `$env:USERPROFILE\.ssh\agv_ops_ed25519 -p 22022 $sshUser@172.19.162.210)

 ONLY AFTER that key login succeeds, run 03-harden-sshd.ps1 here.

 UNDO EVERYTHING:
   Stop-Service sshd; Set-Service sshd -StartupType Disabled
   Copy-Item '$backup' '$cfgPath' -Force
   Remove-NetFirewallRule -Name '$ruleName'
   Remove-Item '$keyFile'
   Remove-LocalUser -Name '$OpsUser'
   Remove-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
=====================================================================
"@ -ForegroundColor White
