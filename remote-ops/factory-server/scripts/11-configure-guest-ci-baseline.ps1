#Requires -Version 7
<#
.SYNOPSIS
    Bring a guest's OS-level settings in line with the control machine so CI and
    local runs behave the same. Runs in the guest, not the host.

.DESCRIPTION
    Every setting here exists because the control machine already has it and a
    difference would make a build pass in one place and fail in the other. That
    class of failure looks like a code defect and costs far more to diagnose
    than to prevent.

    Long paths: the control machine has LongPathsEnabled=1; a fresh Windows 11
    guest has 0, i.e. the 260-character limit. A runner's working directory is
    deeper than a local clone to begin with
    (C:\actions-runner\<name>\_work\<repo>\<repo>\...), so the guest is the side
    that would hit the limit. git gets core.longpaths as well, since it enforces
    its own limit independently of the OS setting.

    Settings take effect for new processes, so the runner services are restarted.

.PARAMETER SkipServiceRestart
    Leave the runner services alone. Use when no runner is installed yet.

.EXAMPLE
    pwsh -NoProfile -File 11-configure-guest-ci-baseline.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipServiceRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
$current = (Get-ItemProperty -Path $fsKey -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled

$changed = $false
if ($current -ne 1) {
    Set-ItemProperty -Path $fsKey -Name LongPathsEnabled -Value 1 -Type DWord
    Write-Output "LongPathsEnabled: $($current ?? 0) -> 1"
    $changed = $true
}
else {
    Write-Output 'LongPathsEnabled: 1（已符合）'
}

$gitExe = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
if (Test-Path -LiteralPath $gitExe) {
    if ((& $gitExe config --system core.longpaths) -ne 'true') {
        & $gitExe config --system core.longpaths true
        Write-Output 'git core.longpaths -> true'
        $changed = $true
    }
    else {
        Write-Output 'git core.longpaths: true（已符合）'
    }
}

if (-not $changed) {
    Write-Output ''
    Write-Output '无改动。'
    exit 0
}

if ($SkipServiceRestart) {
    Write-Output ''
    Write-Output '已跳过服务重启。新设置只对新进程生效。'
    exit 0
}

$services = @(Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue)
if ($services.Count -gt 0) {
    Write-Output ''
    Write-Output '正在重启 runner 服务以读入新设置 ...'
    $services | Restart-Service -PassThru | Select-Object Name, Status |
        Format-Table -AutoSize | Out-String | Write-Output
}
