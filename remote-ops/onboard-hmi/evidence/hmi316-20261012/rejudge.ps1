#Requires -Version 7
<#
    Re-judges recorded cross-checks with the current comparison of 18-read-hmi-screen-state.ps1, offline:
    the snapshot (…-state-before.json) and the UIA reading (…-uia-uia.json) are the ones recorded on the
    real onboard client; only the judging code is today's. onboard-hmi#316.

    pwsh -File remote-ops/onboard-hmi/evidence/hmi316-20261012/rejudge.ps1 -Out <local-crosscheck out\<timestamp>>
#>
param([Parameter(Mandatory)][string] $Out)
$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../../scripts/18-read-hmi-screen-state.ps1'
# The script has mandatory parameters and no dot-source exit, so its functions are lifted from the syntax tree.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $reader).Path, [ref] $null, [ref] $null)
foreach ($name in 'Get-UiaNodes', 'Get-UiaMainWindow', 'Compare-ScreenState', 'Get-UiaCompleteness') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
foreach ($dir in Get-ChildItem -LiteralPath $Out -Directory -Filter 'crosscheck-*' | Sort-Object Name) {
    $record = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $dir.FullName -Filter '*-crosscheck.json')[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    # Raw snapshot and UIA files were kept for the first and the last run only (the screen did not change).
    if (-not (Get-ChildItem -LiteralPath $dir.FullName -Filter '*-uia-uia.json')) { continue }
    $state = (Get-Content -LiteralPath (Get-ChildItem -LiteralPath $dir.FullName -Filter '*-state-before.json')[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String).state
    $uia = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $dir.FullName -Filter '*-uia-uia.json')[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    $rows = @(Compare-ScreenState $state $uia)
    $diff = @($rows | Where-Object { -not $_.match } | ForEach-Object { "$($_.category).$($_.key).$($_.field): $($_.snapshot) / $($_.uia)" })
    $moved = $record.read.processStartId -ne $record.secondRead.processStartId -or $record.read.contentRevision -ne $record.secondRead.contentRevision
    [ordered]@{
        run = $dir.Name; recorded = $record.outcome; capture = $record.capture.outcome; incomplete = Get-UiaCompleteness $uia
        revision = "$($record.read.contentRevision)->$($record.secondRead.contentRevision)"; moved = $moved
        rows = $rows.Count; differences = $diff; rejudged = $moved ? 'MOVING' : ($diff.Count ? 'MISMATCH' : 'MATCH')
        banner = "$($state.banner.stateText) ($($state.banner.source))"
        visibleButtons = @($state.buttons | Where-Object visible | ForEach-Object { "$($_.content ?? $_.key)[$($_.enabled)]" }) -join ' '
    } | ConvertTo-Json -Compress
}
