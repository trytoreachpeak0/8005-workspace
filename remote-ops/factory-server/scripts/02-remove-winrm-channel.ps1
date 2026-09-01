#Requires -Version 7

<#
  02-remove-winrm-channel.ps1 - Tear down the superseded WinRM ops channel.

  RUN THIS ON THE SERVER, OVER SSH, ONLY AFTER `ssh factory01` is proven to
  work with key-only authentication. It deletes the accounts the WinRM channel
  depended on; running it first would leave VNC/AweSun/console as the only way
  back in.

  WHAT IT REMOVES (all of it added by the earlier WinRM design, nothing else):
    1. Local account codex-ops    - the "day-to-day" tier that never worked.
                                    The default microsoft.powershell endpoint
                                    has an empty SDDL, so it falls back to
                                    RootSDDL, which grants non-admins only
                                    GenericRead -> every session was "access
                                    denied". On the PowerShell.7 endpoint it
                                    failed with a pwrshplugin fault instead.
    2. Local account codex-admin  - the tier that did work. Superseded by
                                    agvops over SSH.
    3. Firewall rule AGV-WinRM-Management-PC - allowed 172.19.162.241 to 5985.
                                    Decorative in practice: the em4 adapter is
                                    classified Private and the Private profile
                                    is switched off entirely, so nothing was
                                    being filtered.
    4. LocalAccountTokenFilterPolicy - the registry value that disabled remote
                                    UAC token filtering for every local admin.
                                    WinRM needed it; SSH does not. Verified on
                                    2026-09-01: an SSH session as agvops holds
                                    Administrators as an enabled group at High
                                    Mandatory Level with SeDebug, SeLoadDriver
                                    and SeTakeOwnership enabled, with this value
                                    absent.

  WHAT IT DELIBERATELY LEAVES ALONE:
    - The WinRM service and the built-in WINRM-HTTP-In-TCP rules. Those are
      Windows defaults, not something the earlier design created. Removing our
      additions restores the default; disabling stock Windows management on a
      production box is a separate decision.
    - Administrator, and the running AGV stack (AgvAmhs, AGV.Web, nginx,
      RabbitMQ, Redis, SQL Server, RealVNC, AweSun).
    - C:\Users\codex-ops and C:\Users\codex-admin. Profile directories are not
      deleted by default because deletion is irreversible; pass -RemoveProfiles
      once you have looked at what is in them.

  Usage (from the control workstation):
      scp scripts/02-remove-winrm-channel.ps1 factory01:C:/temp/agv-ops/
      ssh factory01 "pwsh -ExecutionPolicy Bypass -File C:\temp\agv-ops\02-remove-winrm-channel.ps1"
#>

[CmdletBinding()]
param(
    [string[]]$Accounts = @('codex-ops', 'codex-admin'),
    [string]$FirewallRule = 'AGV-WinRM-Management-PC',

    # Also delete C:\Users\<account>. Irreversible; off by default.
    [switch]$RemoveProfiles
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  FAIL $m" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Must run with an administrator token.'
}
Ok "running as $env:USERDOMAIN\$env:USERNAME"

# Refuse to delete the account this session is running under.
if ($Accounts -contains $env:USERNAME) {
    Die "This session is $env:USERNAME, which is on the removal list. Reconnect as agvops first."
}

# ---------------------------------------------------------------- inventory
Step 'What is about to be removed'
foreach ($a in $Accounts) {
    $u = Get-LocalUser -Name $a -ErrorAction SilentlyContinue
    if ($u) {
        $profile = "C:\Users\$a"
        $size = if (Test-Path $profile) {
            '{0:N1} MB' -f ((Get-ChildItem $profile -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1MB)
        } else { 'no profile dir' }
        # "$($u.SID)" rather than $u.SID.Value: pwsh 7 on Server 2016 reaches
        # Microsoft.PowerShell.LocalAccounts through the Windows PowerShell
        # compatibility session, so the SID arrives deserialized and has no
        # .Value property. ToString() still yields S-1-5-21-...
        Write-Host ("  account {0,-14} SID {1}  profile {2}" -f $u.Name, "$($u.SID)", $size)
    } else {
        Write-Host "  account $a already gone"
    }
}
$rule = Get-NetFirewallRule -Name $FirewallRule -ErrorAction SilentlyContinue
if ($rule) {
    $pf = $rule | Get-NetFirewallPortFilter
    $af = $rule | Get-NetFirewallAddressFilter
    Write-Host ("  rule    {0}  port {1}  from {2}" -f $rule.Name, ($pf.LocalPort -join ','), ($af.RemoteAddress -join ','))
} else {
    Write-Host "  rule    $FirewallRule already gone"
}

# ----------------------------------------------------------------- accounts
Step 'Removing the WinRM ops accounts'
foreach ($a in $Accounts) {
    if (Get-LocalUser -Name $a -ErrorAction SilentlyContinue) {
        Remove-LocalUser -Name $a
        Ok "removed local user $a"
    } else {
        Ok "$a was not present"
    }

    if ($RemoveProfiles) {
        # Not Remove-Item. Once the account is gone its SID no longer resolves,
        # and the ACLs it left on protected subfolders -- AppData\Roaming\
        # Microsoft\Windows\Start Menu\Programs\Startup is the one that bites --
        # deny even an administrator, so a recursive delete fails halfway and
        # leaves a stump. Deleting the Win32_UserProfile instance makes Windows
        # do it: it takes ownership, unloads the hive if loaded, removes the
        # directory, and clears the ProfileList registry key that Remove-Item
        # would have left behind.
        $prof = Get-CimInstance Win32_UserProfile |
            Where-Object { $_.LocalPath -eq "C:\Users\$a" -and -not $_.Special }
        if ($prof) {
            $prof | Remove-CimInstance
            if (Test-Path "C:\Users\$a") { Warn "C:\Users\$a still present after profile removal" }
            else { Ok "removed profile C:\Users\$a" }
        } elseif (Test-Path "C:\Users\$a") {
            Warn "C:\Users\$a exists but has no Win32_UserProfile entry; delete it by hand"
        } else {
            Ok "no profile for $a"
        }
    } elseif (Test-Path "C:\Users\$a") {
        Warn "C:\Users\$a left in place; re-run with -RemoveProfiles to delete it"
    }
}

# ----------------------------------------------------------------- firewall
Step 'Removing the WinRM source-restriction rule'
if (Get-NetFirewallRule -Name $FirewallRule -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -Name $FirewallRule
    Ok "removed $FirewallRule"
} else {
    Ok "$FirewallRule was not present"
}

# ------------------------------------------------------------------ policy
Step 'Restoring remote UAC token filtering'
$polKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ((Get-ItemProperty $polKey -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty $polKey -Name LocalAccountTokenFilterPolicy
    Ok 'LocalAccountTokenFilterPolicy removed (back to the Windows default)'
} else {
    Ok 'LocalAccountTokenFilterPolicy already absent'
}

# ------------------------------------------------------------------ result
Step 'Remaining state'
Write-Host '  local accounts:'
Get-LocalUser | ForEach-Object { Write-Host ("    {0,-16} enabled={1}" -f $_.Name, $_.Enabled) }
Write-Host '  administrators:'
Get-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544').Name |
    ForEach-Object { Write-Host "    $($_.Name)" }
Write-Host "  sshd: $((Get-Service sshd).Status), startup $((Get-Service sshd).StartType)"
Write-Host "  WinRM service left as found: $((Get-Service WinRM).Status), startup $((Get-Service WinRM).StartType)"

Write-Host @"

=====================================================================
 WinRM ops channel removed. SSH (agvops, key only) is now the sole
 channel this project maintains into this server.

 There is no undo script. To rebuild the WinRM channel you would have to
 recreate the accounts, re-add LocalAccountTokenFilterPolicy and re-add the
 firewall rule -- which is exactly what this project decided against.
 The console fallbacks (RealVNC 5900, AweSun, physical console) are untouched.
=====================================================================
"@ -ForegroundColor White
