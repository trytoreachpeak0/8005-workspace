#Requires -Version 7
<#
    Redacts UIA readings already on disk with the same rule -CrossCheck applies before it keeps one
    (Protect-UiaReading in 18-read-hmi-screen-state.ps1, onboard-hmi#316 review S4). Rewrites each file in place.
    Use it on any agv-capture-hmi-screen JSON before it goes into git, a 17-capture-hmi-screen run included;
    the PNGs it leaves next to the JSON are not touched and must be looked at by hand.

    pwsh -File remote-ops/onboard-hmi/evidence/hmi316-20261012/redact-uia.ps1 -Path <file> [<file> ...]
#>
param([Parameter(Mandatory)][string[]] $Path, [string] $ProcessName = 'SQCD.Agv.Wpf')
$ErrorActionPreference = 'Stop'
$reader = Join-Path $PSScriptRoot '../../scripts/18-read-hmi-screen-state.ps1'
# The script has mandatory parameters and no dot-source exit, so its functions are lifted from the syntax tree.
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $reader).Path, [ref] $null, [ref] $null)
foreach ($name in 'Get-UiaNodes', 'Protect-UiaReading') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
foreach ($file in $Path) {
    $uia = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -DateKind String
    Protect-UiaReading $uia $ProcessName | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    "redacted $file (other desktop windows dropped: $($uia.otherDesktopWindows))"
}
