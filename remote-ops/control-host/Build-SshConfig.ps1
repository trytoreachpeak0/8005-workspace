#Requires -Version 7

<#
  Build-SshConfig.ps1 - Assemble the control host's SSH config from EVERY
  remote-ops channel, and enforce that no two channels claim the same name.

  RUN THIS ON THE CONTROL WORKSTATION. It touches nothing remote.

  WHY THIS EXISTS
    Each channel under remote-ops/ keeps its own ssh_config fragment. There is
    only one ~/.ssh/config, so before this script the fragments were merged by
    hand and any channel's setup script that "installed" its own fragment
    silently deleted the other channels' aliases. With more than two channels
    that stops being a hazard and becomes a certainty.

    The fragments are also the name registry. An alias reserved here is taken,
    even if the machine behind it does not exist yet -- which is how a name
    stays unique across channels that are written months apart.

  WHAT IT CHANGES ON THIS MACHINE
    - Writes one file per family to <SshDir>\conf.d\remote-ops-<family>.conf.
    - Inserts (or refreshes) a marked block at the top of <SshDir>\config that
      Includes those files. Everything outside the markers is left alone.
    - Rewrites each IdentityFile to <SshDir>, per line, so a config written on
      another machine still points at this machine's keys.
    - With -ReplaceExisting: removes legacy inline Host blocks that duplicate a
      managed alias, after backing the file up.

  It never writes a private key and never contacts a remote host.

  NAMING RULES IT ENFORCES (see ../README.md section "命名唯一性"):
    1. Fragment path is remote-ops/<channel>/config/ssh_config.<family>.
    2. <family> is lowercase kebab-case and unique across ALL channels.
    3. Every Host pattern in a fragment starts with its own <family>.
    4. Concrete aliases are <family> + two digits: agv01, factory01, vm01.
    5. Aliases are unique across all fragments (rules 2-4 make that automatic;
       this checks it anyway, because a typo defeats a convention).
    6. A ProxyJump target must be an alias some fragment defines.
    7. A HostName of REPLACE_* means the name is reserved but the machine is not
       online yet. The block is kept in git and omitted from the built config,
       so `ssh <alias>` fails as "unknown host" rather than resolving to junk.

  Usage:
      pwsh -File .\Build-SshConfig.ps1 -ValidateOnly
      pwsh -File .\Build-SshConfig.ps1
      pwsh -File .\Build-SshConfig.ps1 -ReplaceExisting
#>

[CmdletBinding()]
param(
    # Check the fragments and report; write nothing. Exit code 1 on any error.
    [switch]$ValidateOnly,

    # Allow removal of legacy inline Host blocks in ~/.ssh/config that duplicate
    # an alias this script manages. Backs the file up first.
    [switch]$ReplaceExisting,

    # Override only to inspect the generated files somewhere harmless. The
    # Include line still names ~/.ssh -- see the comment where it is built.
    [string]$SshDir = (Join-Path $HOME '.ssh')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$MarkerBegin = '# >>> remote-ops managed block >>>'
$MarkerEnd   = '# <<< remote-ops managed block <<<'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok      $m" -ForegroundColor Green }
function Info($m) { Write-Host "  ..      $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "  WARN    $m" -ForegroundColor Yellow }

$errors = [System.Collections.Generic.List[string]]::new()
function Fault($m) { $script:errors.Add($m); Write-Host "  ERROR   $m" -ForegroundColor Red }

# --------------------------------------------------------------- discovery
$remoteOpsRoot = Split-Path -Parent $PSScriptRoot

Step "Collecting channel fragments under $remoteOpsRoot"

$fragmentFiles = @(
    Get-ChildItem -LiteralPath $remoteOpsRoot -Directory |
        ForEach-Object {
            $cfg = Join-Path $_.FullName 'config'
            if (Test-Path -LiteralPath $cfg) {
                Get-ChildItem -LiteralPath $cfg -Filter 'ssh_config.*' -File
            }
        } | Sort-Object Name
)

if ($fragmentFiles.Count -eq 0) {
    Write-Host '  no ssh_config.* fragment found -- nothing to do' -ForegroundColor Red
    exit 1
}

function Read-Fragment {
    param([System.IO.FileInfo]$File)

    $family  = ($File.Name -split '\.', 2)[1]
    $channel = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $File.FullName))

    $preamble = [System.Collections.Generic.List[string]]::new()
    $blocks   = [System.Collections.Generic.List[object]]::new()
    $current  = $null

    foreach ($line in (Get-Content -LiteralPath $File.FullName)) {
        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            if ($null -ne $current) { $blocks.Add($current) }
            $current = [pscustomobject]@{
                Patterns  = @($Matches[1] -split '\s+')
                Lines     = [System.Collections.Generic.List[string]]::new()
                HostName  = $null
                ProxyJump = $null
            }
            $current.Lines.Add($line)
        }
        elseif ($null -ne $current) {
            $current.Lines.Add($line)
            if ($line -match '^\s*HostName\s+(\S+)')  { $current.HostName  = $Matches[1] }
            if ($line -match '^\s*ProxyJump\s+(\S+)') { $current.ProxyJump = $Matches[1] }
        }
        else {
            $preamble.Add($line)
        }
    }
    if ($null -ne $current) { $blocks.Add($current) }

    [pscustomobject]@{
        Family   = $family
        Channel  = $channel
        File     = $File
        Preamble = $preamble
        Blocks   = $blocks
    }
}

$fragments = @($fragmentFiles | ForEach-Object { Read-Fragment -File $_ })

foreach ($f in $fragments) {
    Info "$($f.Channel)/config/$($f.File.Name)  -> family '$($f.Family)', $($f.Blocks.Count) Host block(s)"
}

# -------------------------------------------------------------- validation
Step 'Checking naming uniqueness'

$familyOwner = @{}   # family -> "channel/file"
$aliasOwner  = @{}   # alias  -> "channel/file"
$pending     = [System.Collections.Generic.List[string]]::new()
$proxyRefs   = [System.Collections.Generic.List[object]]::new()

foreach ($f in $fragments) {
    $where = "$($f.Channel)/config/$($f.File.Name)"

    # Rule 2 -- family shape and global uniqueness.
    if ($f.Family -notmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') {
        Fault "family '$($f.Family)' ($where) is not lowercase kebab-case"
    }
    if ($familyOwner.ContainsKey($f.Family)) {
        Fault "family '$($f.Family)' is claimed twice: $($familyOwner[$f.Family]) and $where"
    } else {
        $familyOwner[$f.Family] = $where
    }

    foreach ($b in $f.Blocks) {
        foreach ($p in $b.Patterns) {
            # Rule 3 -- a fragment may only name hosts inside its own family.
            if ($p -notlike "$($f.Family)*") {
                Fault "Host '$p' in $where escapes its family '$($f.Family)'"
                continue
            }

            if ($p -match '[*?]') { continue }   # wildcard defaults block

            # Rule 4 -- concrete aliases are <family> + two digits.
            if ($p -notmatch "^$([regex]::Escape($f.Family))\d{2}$") {
                Fault "alias '$p' in $where is not <family> + two digits"
            }

            # Rule 5 -- alias uniqueness across every fragment.
            if ($aliasOwner.ContainsKey($p)) {
                Fault "alias '$p' is defined twice: $($aliasOwner[$p]) and $where"
            } else {
                $aliasOwner[$p] = $where
            }

            if ([string]::IsNullOrWhiteSpace($b.HostName)) {
                Fault "alias '$p' in $where has no HostName"
            } elseif ($b.HostName -match '^REPLACE_') {
                # Rule 7 -- name reserved, machine not online yet.
                $pending.Add("$p ($where, HostName=$($b.HostName))")
            }
        }

        if ($b.ProxyJump) {
            $proxyRefs.Add([pscustomobject]@{ Target = $b.ProxyJump; Where = $where; Patterns = $b.Patterns })
        }
    }
}

# Rule 6 -- ProxyJump must resolve to an alias somebody defines.
foreach ($r in $proxyRefs) {
    if (-not $aliasOwner.ContainsKey($r.Target)) {
        Fault "ProxyJump '$($r.Target)' in $($r.Where) (Host $($r.Patterns -join ' ')) matches no defined alias"
    }
}

if ($errors.Count -eq 0) {
    Ok "$($familyOwner.Count) families, $($aliasOwner.Count) aliases, no collisions"
    Info "families: $(($familyOwner.Keys | Sort-Object) -join ', ')"
    Info "aliases : $(($aliasOwner.Keys | Sort-Object) -join ', ')"
}

if ($pending.Count -gt 0) {
    Step 'Names reserved but not yet online'
    foreach ($p in $pending) { Warn "$p -- kept in git, omitted from the built config" }
}

if ($errors.Count -gt 0) {
    Write-Host "`n$($errors.Count) naming error(s). Nothing was written." -ForegroundColor Red
    exit 1
}

if ($ValidateOnly) {
    Write-Host "`nValidation passed. Nothing was written (-ValidateOnly)." -ForegroundColor White
    exit 0
}

# ----------------------------------------------------------------- writing
Step "Writing fragments to $SshDir\conf.d"

$confD = Join-Path $SshDir 'conf.d'
if (-not (Test-Path -LiteralPath $confD)) {
    New-Item -ItemType Directory -Path $confD -Force | Out-Null
    Ok "created $confD"
}

$written = [System.Collections.Generic.List[string]]::new()

foreach ($f in $fragments) {
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("# GENERATED by remote-ops/control-host/Build-SshConfig.ps1 -- do not edit.")
    $out.Add("# Source: remote-ops/$($f.Channel)/config/$($f.File.Name)")
    $out.Add('')
    foreach ($line in $f.Preamble) { $out.Add($line) }

    $omitted = 0
    foreach ($b in $f.Blocks) {
        if ($b.HostName -and $b.HostName -match '^REPLACE_') { $omitted++; continue }
        foreach ($line in $b.Lines) {
            # Per-line rewrite: three channels use three different keys, so a
            # single global replace would point them all at the same file.
            if ($line -match '^(\s*IdentityFile\s+)(\S.*)$') {
                $leaf = Split-Path -Leaf ($Matches[2].Trim())
                $out.Add("$($Matches[1])$(Join-Path $SshDir $leaf)")
            } else {
                $out.Add($line)
            }
        }
    }

    $dst = Join-Path $confD "remote-ops-$($f.Family).conf"
    [System.IO.File]::WriteAllText($dst, (($out -join "`n") + "`n"), $Utf8NoBom)
    $written.Add("remote-ops-$($f.Family).conf")
    Ok "remote-ops-$($f.Family).conf$(if ($omitted) { "  ($omitted pending block(s) omitted)" })"
}

# Drop conf.d files for families that no longer exist, or this becomes another
# way for a deleted channel to keep answering.
foreach ($stale in Get-ChildItem -LiteralPath $confD -Filter 'remote-ops-*.conf' -File) {
    if ($stale.Name -notin $written) {
        Remove-Item -LiteralPath $stale.FullName -Force
        Warn "removed stale $($stale.Name) (no fragment produces it any more)"
    }
}

# ------------------------------------------------------- ~/.ssh/config block
Step "Updating $SshDir\config"

$configPath = Join-Path $SshDir 'config'
# The Include path is ALWAYS ~/.ssh/conf.d, never $SshDir. Measured on
# OpenSSH_10.5p1 for Windows: Include resolves `~/...` and paths relative to
# ~/.ssh, and SILENTLY IGNORES a Windows absolute path -- both
# `C:/Users/szy/.ssh/conf.d/*.conf` and the backslash form parse without an
# error and include nothing. So -SshDir isolates the files this script writes,
# not where ssh reads them from; a scratch run cannot be verified with
# `ssh -F <scratch>/config`. Point -F at a fragment under conf.d instead.
$managed = @(
    $MarkerBegin
    '# Generated by remote-ops/control-host/Build-SshConfig.ps1.'
    '# Edit remote-ops/<channel>/config/ssh_config.<family> and re-run it;'
    '# anything you write OUTSIDE these markers is preserved.'
    'Include ~/.ssh/conf.d/remote-ops-*.conf'
    $MarkerEnd
)

$outside = @()
if (Test-Path -LiteralPath $configPath) {
    $existing = @(Get-Content -LiteralPath $configPath)
    $inBlock = $false
    foreach ($line in $existing) {
        if ($line.Trim() -eq $MarkerBegin) { $inBlock = $true; continue }
        if ($line.Trim() -eq $MarkerEnd)   { $inBlock = $false; continue }
        if (-not $inBlock) { $outside += $line }
    }
} else {
    Info 'no existing config; creating one'
}

# Legacy inline blocks: a name we manage, written directly into ~/.ssh/config.
# ssh takes the first match, so these would silently win over the Include.
function Test-ManagedPattern {
    param([string]$Pattern)
    if ($aliasOwner.ContainsKey($Pattern)) { return $true }
    # A defaults block such as `Host agv*` belongs to family `agv`.
    foreach ($fam in $familyOwner.Keys) { if ($Pattern -like "$fam*") { return $true } }
    return $false
}

$legacy = @()
foreach ($line in $outside) {
    if ($line -match '^\s*Host\s+(.+?)\s*$') {
        foreach ($p in ($Matches[1] -split '\s+')) {
            if (Test-ManagedPattern -Pattern $p) { $legacy += $p }
        }
    }
}

if ($legacy.Count -gt 0) {
    if (-not $ReplaceExisting) {
        Write-Host ''
        Warn "$configPath still defines these managed names inline:"
        Warn "  $(($legacy | Select-Object -Unique) -join ', ')"
        Warn 'ssh takes the FIRST match, so those would win over the Include and the'
        Warn 'fragments would have no effect. Re-run with -ReplaceExisting to remove'
        Warn 'them (the file is backed up first). conf.d was written; config was not.'
        exit 1
    }

    $backup = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $configPath -Destination $backup -Force
    Ok "backed up to $backup"

    $kept = [System.Collections.Generic.List[string]]::new()
    $dropping = $false
    foreach ($line in $outside) {
        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            $pats = @($Matches[1] -split '\s+')
            $dropping = [bool](@($pats | Where-Object { Test-ManagedPattern -Pattern $_ }).Count)
            # The comments directly above a Host block describe that block. Drop
            # them with it, or migration leaves orphaned prose behind.
            if ($dropping) {
                while ($kept.Count -gt 0 -and ($kept[$kept.Count-1].TrimStart().StartsWith('#') -or [string]::IsNullOrWhiteSpace($kept[$kept.Count-1]))) {
                    $kept.RemoveAt($kept.Count - 1)
                }
            }
        }
        if (-not $dropping) { $kept.Add($line) }
    }
    $outside = @($kept)
    Ok "removed $(($legacy | Select-Object -Unique).Count) legacy inline block(s)"
}

# Trim leading/trailing blank lines so repeated runs do not grow the file.
# Select-Object rather than a range: with one element left, $outside[0..-1] is
# the range 0,-1 -- first and last -- which grows the array instead of emptying
# it and then indexes past the end.
while ($outside.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outside[0]))  { $outside = @($outside | Select-Object -Skip 1) }
while ($outside.Count -gt 0 -and [string]::IsNullOrWhiteSpace($outside[-1])) { $outside = @($outside | Select-Object -First ($outside.Count - 1)) }

$final = @($managed) + @('') + @($outside)
[System.IO.File]::WriteAllText($configPath, (($final -join "`n") + "`n"), $Utf8NoBom)
Ok "managed block installed at the top of $configPath"

# ----------------------------------------------------------------- summary
Write-Host @"

=====================================================================
 CONTROL HOST SSH CONFIG BUILT

   config    : $configPath  (managed block + $($outside.Count) hand-written line(s))
   fragments : $confD\remote-ops-*.conf
   families  : $(($familyOwner.Keys | Sort-Object) -join ', ')
   live      : $((($aliasOwner.Keys | Sort-Object) | Where-Object { $n = $_; -not ($pending | Where-Object { $_ -like "$n *" }) }) -join ', ')
   reserved  : $(if ($pending.Count) { ($pending | ForEach-Object { ($_ -split ' ')[0] }) -join ', ' } else { '(none)' })

 Verify an alias resolves as expected, without connecting:
   ssh -G agv01 | Select-String '^(hostname|port|user|identityfile|proxyjump) '
"@ -ForegroundColor White
