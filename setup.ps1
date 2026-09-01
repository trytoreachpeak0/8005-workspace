#Requires -Version 7

<#
  setup.ps1 - Restore the workspace on a new machine.

  Clones any of the five component repositories that are missing, at the
  working branch listed in repos.md. Existing clones are left untouched — this
  script never pulls, resets, or checks out over your work.

  Usage:  pwsh -File .\setup.ps1
#>

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$base = 'https://github.com/trytoreachpeak0'

$repos = @(
    @{ Dir = '8005---AGV';              Branch = 'main' }
    @{ Dir = '8005-agv-control-server'; Branch = 'ControlServer_MVP' }
    @{ Dir = '8005-agv-onboard-hmi';    Branch = 'OnboardHmi_MVP' }
    @{ Dir = 'slots-simulator';         Branch = 'main' }
    @{ Dir = '8005-agv-protocol';       Branch = 'main' }
)

foreach ($r in $repos) {
    $path = Join-Path $root $r.Dir
    if (Test-Path (Join-Path $path '.git')) {
        Write-Host "skip   $($r.Dir) (already cloned)"
        continue
    }
    Write-Host "clone  $($r.Dir) @ $($r.Branch)"
    git clone --branch $r.Branch "$base/$($r.Dir).git" $path
}

Write-Host ''
Write-Host 'Done. The w2g-rc-* release candidate is not restored by this script;'
Write-Host 'rebuild it from releases/<id>/RELEASE-CANDIDATE.md if you need it.'
