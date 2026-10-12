#Requires -Version 7
<#
.SYNOPSIS
    Offline self-test for Get-WireToGateStatus.ps1's choice of server for a v2-line vehicle (workspace#32 review S2).

.DESCRIPTION
    Lifts Assert-StatusTarget out of the status script by its AST and drives it, then runs the whole script in a child
    pwsh whose ssh and Invoke-WebRequest are replaced by functions that only log -- functions win over both the cmdlet
    and anything on PATH -- with a fake secret store and a scratch journal directory. Nothing reaches a vehicle,
    factory01 or the MVP service, including under a mutation that removes the refusal.

    What it pins:
      * agv02/agv03 without -BaseUrl are refused before the site file, any ssh and any HTTP request;
      * agv02/agv03 with a -BaseUrl on the MVP's 58005/58007 are refused the same way;
      * agv02 with the v2 instance's URL, and agv01 on the default, go ahead as before.

.EXAMPLE
    pwsh -File remote-ops/status/Test-GetWireToGateStatus.ps1
#>
[CmdletBinding()]
param(
    # Mutation runs point this at an edited copy; normally the sibling script.
    [string] $StatusScript = (Join-Path $PSScriptRoot 'Get-WireToGateStatus.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:Passed = 0
$script:Failed = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail)
    if ($Ok) { $script:Passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Name" -ForegroundColor Red; Write-Host "        $Detail" -ForegroundColor Red }
}

$source = (Resolve-Path -LiteralPath $StatusScript).Path
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
Write-Result -Ok (@($errors).Count -eq 0) -Name 'Get-WireToGateStatus.ps1 parses' -Detail (@($errors) -join ' | ')
$definition = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-StatusTarget' }, $true)
Write-Result -Ok ($null -ne $definition) -Name 'Assert-StatusTarget is defined in Get-WireToGateStatus.ps1' -Detail 'missing'
if ($null -eq $definition) {
    Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor Red
    exit 1
}
. ([scriptblock]::Create($definition.Extent.Text))

$mvpDefault = 'http://172.19.205.222:58007'
$v2Url = 'http://172.19.205.222:58107'
function Invoke-Assert([string] $Alias, [string] $Url, [bool] $Given) {
    try { Assert-StatusTarget -SiteAlias $Alias -BaseUrl $Url -BaseUrlGiven $Given; return $null } catch { return $_.Exception.Message }
}

Write-Host 'Which server a vehicle is checked against (workspace#32 review S2)' -ForegroundColor Cyan
foreach ($alias in @('agv02', 'agv03', 'AGV02', ' agv03 ')) {
    $e = Invoke-Assert $alias $mvpDefault $false
    Write-Result -Ok ($null -ne $e -and $e.StartsWith('STATUS_BASEURL_REQUIRED:') -and $e.Contains('58107')) -Name "'$alias' without -BaseUrl is refused" -Detail "error: $e"
}
foreach ($url in @($mvpDefault, 'http://172.19.205.222:58005', 'http://172.19.205.222:58007/')) {
    $e = Invoke-Assert 'agv02' $url $true
    Write-Result -Ok ($null -ne $e -and $e.StartsWith('STATUS_MVP_URL_FOR_V2_VEHICLE:')) -Name "agv02 with -BaseUrl $url (an MVP port) is refused" -Detail "error: $e"
}
$e = Invoke-Assert 'agv03' $v2Url $true
Write-Result -Ok ($null -eq $e) -Name 'agv03 with the v2 instance''s URL passes' -Detail "error: $e"
$e = Invoke-Assert 'agv01' $mvpDefault $false
Write-Result -Ok ($null -eq $e) -Name 'agv01 on the default (the MVP) passes, as before' -Detail "error: $e"

Write-Host ''
Write-Host 'The whole script, ssh and Invoke-WebRequest replaced by loggers (workspace#32 review S2)' -ForegroundColor Cyan
$work = Join-Path ([IO.Path]::GetTempPath()) "ws32-status-selftest-$PID"
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'journal') | Out-Null
    $secretPath = Join-Path $work 'secrets.xml'
    @{ OnboardCredential = (ConvertTo-SecureString 'fake-onboard' -AsPlainText -Force) } | Export-Clixml -LiteralPath $secretPath
    $log = Join-Path $work 'calls.log'
    $env:WS32_STATUS_LOG = $log
    $env:WS32_STATUS_SCRIPT = $source
    $harness = @'
function global:ssh { Add-Content -LiteralPath $env:WS32_STATUS_LOG -Value "ssh | $($args -join ' ')"; $global:LASTEXITCODE = 255 }
function global:Invoke-WebRequest { $i = [array]::IndexOf($args, '-Uri'); Add-Content -LiteralPath $env:WS32_STATUS_LOG -Value "http | $($args[$i + 1])"; throw 'offline self-test' }
$arguments = $env:WS32_STATUS_ARGS | ConvertFrom-Json -AsHashtable
& $env:WS32_STATUS_SCRIPT @arguments
'@
    function Invoke-Status([hashtable] $Arguments) {
        if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
        $all = @{ SecretPath = $secretPath; JournalDirectory = (Join-Path $work 'journal'); TimeoutSec = 1 }
        foreach ($key in $Arguments.Keys) { $all[$key] = $Arguments[$key] }
        $env:WS32_STATUS_ARGS = $all | ConvertTo-Json -Compress
        $output = & pwsh -NoProfile -Command $harness *>&1 | Out-String
        $code = $LASTEXITCODE
        $output = ($output -replace '\x1b\[[0-9;]*m', '') -replace '\r?\n {2,}\| ?', ' '
        $calls = @((Test-Path -LiteralPath $log) ? (Get-Content -LiteralPath $log) : @())
        return [pscustomobject]@{ Code = $code; Output = $output; Calls = $calls }
    }

    foreach ($alias in @('agv02', 'agv03')) {
        $d = Invoke-Status @{ SiteAlias = $alias }
        Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('STATUS_BASEURL_REQUIRED:') -and $d.Calls.Count -eq 0) `
            -Name "E2E $alias without -BaseUrl: refused, no ssh and no HTTP request" -Detail "exit $($d.Code), calls: $($d.Calls -join ' || ')`n$($d.Output)"
    }
    $d = Invoke-Status @{ SiteAlias = 'agv02'; BaseUrl = $mvpDefault }
    Write-Result -Ok ($d.Code -ne 0 -and $d.Output.Contains('STATUS_MVP_URL_FOR_V2_VEHICLE:') -and $d.Calls.Count -eq 0) `
        -Name 'E2E agv02 with -BaseUrl on 58007: refused, no ssh and no HTTP request' -Detail "exit $($d.Code), calls: $($d.Calls -join ' || ')`n$($d.Output)"
    $d = Invoke-Status @{ SiteAlias = 'agv02'; BaseUrl = $v2Url }
    $http = @($d.Calls | Where-Object { $_.StartsWith('http | ') })
    Write-Result -Ok ($http.Count -ge 1 -and @($http | Where-Object { -not $_.StartsWith("http | $v2Url/") }).Count -eq 0 -and -not $d.Output.Contains('STATUS_')) `
        -Name 'E2E agv02 with the v2 instance''s URL: goes ahead, every HTTP request to 58107' -Detail "exit $($d.Code), calls: $($d.Calls -join ' || ')`n$($d.Output)"
} finally {
    Remove-Item Env:WS32_STATUS_LOG, Env:WS32_STATUS_SCRIPT, Env:WS32_STATUS_ARGS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor ($script:Failed -eq 0 ? 'Green' : 'Red')
exit ($script:Failed -eq 0 ? 0 : 1)
