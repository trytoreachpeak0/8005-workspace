#Requires -Version 7
<#
.SYNOPSIS
    Report .NET toolchain drift across the workspace repositories.

.DESCRIPTION
    The workspace pins one SDK, one runtime target and one test stack. This
    script reads the real files and reports every deviation. It changes
    nothing, so it is safe to run against the two repositories owned by Kun
    Wang, which are read-only for agents and are reported but never fixed.

    Baseline rationale and the enforcement layers live in
    repos/8005-agv-program/docs/adr/cross/0056-dotnet-toolchain-baseline.md.

.PARAMETER Quiet
    Print only deviations, not the per-repository summary.

.OUTPUTS
    Exit code 0 when every writable repository matches the baseline, 1 otherwise.
    Deviations in read-only repositories never change the exit code.
    Neither does the protocol version matrix (section 5): it is frozen inside a
    released protocol, so it is reported until the next protocol release.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Baseline = @{
    Sdk              = '8.0.426'
    RollForward      = 'disable'
    TargetFrameworks = @('net8.0', 'net8.0-windows')
    TestPackages     = @{
        'xunit.v3'                  = '3.2.2'
        'Microsoft.NET.Test.Sdk'    = '18.8.1'
        'xunit.runner.visualstudio' = '3.1.5'
    }
    BannedPackages   = @(
        'xunit', 'xunit.core', 'xunit.assert', 'xunit.extensibility.core',
        'NUnit', 'NUnit3TestAdapter',
        'MSTest.TestFramework', 'MSTest.TestAdapter',
        'coverlet.collector'
    )
}

# Write authority comes from the root CLAUDE.md, identified by remote.
$Repos = [ordered]@{
    '8005-agv-control-server' = 'writable'
    '8005-mes-ingest'         = 'writable'
    'riot-sdk'                = 'writable'
    '8005-agv-protocol'       = 'writable'
    '8005-agv-program'        = 'writable'
    '8005-agv-onboard-hmi'    = 'read-only'
    'slots-simulator'         = 'read-only'
}

$root = Join-Path $PSScriptRoot 'repos'
$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param($Repo, $Authority, $Item, $Found, $Expected)
    $findings.Add([pscustomobject]@{
        Repo      = $Repo
        Authority = $Authority
        Item      = $Item
        Found     = $Found
        Expected  = $Expected
    })
}

foreach ($repo in $Repos.Keys) {
    $authority = $Repos[$repo]
    $path = Join-Path $root $repo
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $projects = Get-ChildItem -LiteralPath $path -Filter '*.csproj' -Recurse -File `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\/](bin|obj|\.artifacts|node_modules)[\/]' }

    if (-not $projects) {
        if (-not $Quiet) { Write-Host "$repo — 无 .NET 项目，跳过" -ForegroundColor DarkGray }
        continue
    }

    # 1. global.json pins the SDK.
    $globalJson = Join-Path $path 'global.json'
    if (Test-Path -LiteralPath $globalJson) {
        $sdk = (Get-Content -LiteralPath $globalJson -Raw | ConvertFrom-Json -AsHashtable).sdk
        if ($sdk.version -ne $Baseline.Sdk) {
            Add-Finding $repo $authority 'global.json version' $sdk.version $Baseline.Sdk
        }
        if ($sdk.rollForward -ne $Baseline.RollForward) {
            Add-Finding $repo $authority 'global.json rollForward' ($sdk.rollForward ?? '(未设)') $Baseline.RollForward
        }
    }
    else {
        Add-Finding $repo $authority 'global.json' '(缺失)' "SDK $($Baseline.Sdk) 锁定"
    }

    # 2/3/4. Per-project target framework, banned packages, inline versions.
    $centrallyManaged = Test-Path -LiteralPath (Join-Path $path 'Directory.Packages.props')

    foreach ($proj in $projects) {
        $name = $proj.FullName.Substring($path.Length + 1)
        $xml = [xml](Get-Content -LiteralPath $proj.FullName -Raw)

        foreach ($tfm in $xml.SelectNodes('//TargetFramework | //TargetFrameworks')) {
            foreach ($one in $tfm.InnerText -split ';') {
                if ($one -and $one -notin $Baseline.TargetFrameworks) {
                    Add-Finding $repo $authority "$name TargetFramework" $one ($Baseline.TargetFrameworks -join ' / ')
                }
            }
        }

        foreach ($ref in $xml.SelectNodes('//PackageReference')) {
            $id = $ref.GetAttribute('Include')
            if (-not $id) { continue }

            if ($id -in $Baseline.BannedPackages) {
                Add-Finding $repo $authority "$name 禁用包" $id '改用 xunit.v3'
                continue
            }

            $version = $ref.GetAttribute('Version')
            if ($version) {
                if ($centrallyManaged) {
                    Add-Finding $repo $authority "$name 内联版本" "$id = $version" 'Directory.Packages.props'
                }
                elseif ($Baseline.TestPackages.ContainsKey($id) -and $version -ne $Baseline.TestPackages[$id]) {
                    Add-Finding $repo $authority "$name 包版本" "$id = $version" $Baseline.TestPackages[$id]
                }
            }
        }
    }

    if (-not $Quiet) {
        $count = @($findings | Where-Object Repo -eq $repo).Count
        $tag = if ($authority -eq 'read-only') { ' (只读，仅报告)' } else { '' }
        $colour = if ($count -eq 0) { 'Green' } elseif ($authority -eq 'read-only') { 'DarkYellow' } else { 'Red' }
        Write-Host "$repo — $count 处偏离$tag" -ForegroundColor $colour
    }
}

# 5. The protocol's compatibility matrix restates the SDK baseline and the runtime that ships
#    with it. It is the only copy outside a global.json, and it has no .csproj, so the loop above
#    skips that repository. G1 used to assert it against a literal in g1-validate.mjs instead, so
#    both went stale together at the 8.0.425 bump (8005-agv-program#36).
#    Reported, never blocking, since the 8.0.426 bump (2026-10-14, 8005-agv-program#181): the matrix is
#    a file in manifest/release.json, so changing it changes protocolReleaseManifestSha256, which every
#    envelope carries -- that is a protocol re-release and a new tag, not a toolchain edit. Sync it in
#    the next protocol release.
$matrixRepo = '8005-agv-protocol'
$matrixAuthority = 'deferred-to-protocol-release'
$matrixItem = 'compatibility/implementation-version-matrix.json'
$matrixPath = Join-Path $root $matrixRepo $matrixItem
if (Test-Path -LiteralPath $matrixPath) {
    $matrixBaseline = (Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json -AsHashtable).sharedDevelopmentBaseline
    if ($matrixBaseline.dotnetSdk -ne $Baseline.Sdk) {
        Add-Finding $matrixRepo $matrixAuthority "$matrixItem dotnetSdk" $matrixBaseline.dotnetSdk $Baseline.Sdk
    }

    # No file pins the runtime: it is whatever the pinned SDK bundles, so read it from that SDK.
    $sdkDirectory = (Get-Command dotnet -ErrorAction Ignore) ? ((& dotnet --list-sdks) | ForEach-Object {
            if ($_ -match "^$([regex]::Escape($Baseline.Sdk)) \[(.+)\]$") { Join-Path $Matches[1] $Baseline.Sdk }
        } | Select-Object -First 1) : $null
    $bundledProps = $sdkDirectory ? (Join-Path $sdkDirectory 'Microsoft.NETCoreSdk.BundledVersions.props') : $null
    if ($bundledProps -and (Test-Path -LiteralPath $bundledProps) -and
        (Get-Content -LiteralPath $bundledProps -Raw) -match '<BundledNETCoreAppPackageVersion>([^<]+)<') {
        if ($matrixBaseline.dotnetRuntime -ne $Matches[1]) {
            Add-Finding $matrixRepo $matrixAuthority "$matrixItem dotnetRuntime" $matrixBaseline.dotnetRuntime $Matches[1]
        }
    }
    else {
        Write-Warning "本机没有 SDK $($Baseline.Sdk)，无法核对 $matrixItem 的 dotnetRuntime"
    }
}

if ($findings.Count -gt 0) {
    Write-Host ''
    $findings | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

$blocking = @($findings | Where-Object Authority -eq 'writable')
if ($blocking.Count -gt 0) {
    Write-Host "可写仓有 $($blocking.Count) 处偏离，需要修。" -ForegroundColor Red
    exit 1
}

Write-Host '可写仓全部符合工具链基线。' -ForegroundColor Green
exit 0
