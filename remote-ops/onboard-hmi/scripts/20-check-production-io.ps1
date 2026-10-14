#Requires -Version 7
<#
.SYNOPSIS
    Read-only: reads back each vehicle's installed ioModule and checks it is the site file's real module. Writes the
    record the dispatch gate asks for in the production phase. Runs on the control host.

.DESCRIPTION
    workspace#51, the check point after step 20 of control-server docs/production-cutover-mode-plan.md (IO switched
    back to the real module) and before any gate is opened. For each -SshAlias it reads
    <site install.root>\appsettings.json on the vehicle over one ssh -- nothing is written there -- and holds
    ioModule.host and ioModule.port to the production rule of ProductionIo.psm1: the site file's module
    (config\site-<alias>.json ioModule.host) on port 502. A loopback host, the simulator port 1502 or another module
    is a refusal with its code.

    It prints one line per vehicle, IO_CHECK <alias> OK <host:port> or IO_CHECK <alias> REFUSED <code: text>, writes
    -RecordPath (kind onboard-io-check, checkedAt, one result per vehicle with its vehicleKey from the site file) and
    exits 0 only when every vehicle passed. In the production phase
    factory-server/scripts/20-set-control-server-parallel-dispatch-gate.ps1 -State Open refuses without such a record,
    written within six hours, covering every vehicle of the installed fleet, all OK.

    It checks what the client will read at its next start. A client that is running read its configuration when it
    started; restart it after a change (09-switch-io-module.ps1 refuses while it runs, so a change through it is never
    invisible). Reading agv01 is asked of the user first, like every probe of agv01.

.PARAMETER SshAlias
    The vehicles of this stage, e.g. agv02 or agv02,agv01. One string with commas is split.

.PARAMETER RecordPath
    Where the record goes, e.g. the stage's evidence directory. Overwritten.

.EXAMPLE
    pwsh -File remote-ops/onboard-hmi/scripts/20-check-production-io.ps1 -SshAlias agv02 -RecordPath <EV>/agv02/io-check.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]] $SshAlias,
    [Parameter(Mandatory = $true)][string] $RecordPath,
    [string] $SiteDirectory = (Join-Path $PSScriptRoot '../config')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Import-Module (Join-Path $PSScriptRoot 'ProductionIo.psm1') -Force

$aliases = @($SshAlias | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($aliases.Count -eq 0) { throw 'No vehicle given; pass -SshAlias.' }

$results = foreach ($alias in $aliases) {
    $result = [ordered]@{ alias = $alias; vehicleKey = $null; siteHost = $null; host = $null; port = $null; ok = $false; refusal = $null }
    try {
        $sitePath = Join-Path $SiteDirectory "site-$alias.json"
        if (-not (Test-Path -LiteralPath $sitePath -PathType Leaf)) { throw "SITE_FILE_MISSING: no $sitePath." }
        $site = Get-Content -Raw -LiteralPath $sitePath | ConvertFrom-Json -AsHashtable
        $result['vehicleKey'] = [string] $site['vehicleSafety']['expectedVehicleKey']
        $result['siteHost'] = [string] $site['ioModule']['host']
        $root = ($site.Contains('install') -and $site['install']['root']) ? [string] $site['install']['root'] : 'C:\8005\OnboardHmi'
        $config = ($root.TrimEnd('\') + '\appsettings.json').Replace("'", "''")
        $read = "`$c = Get-Content -Raw -LiteralPath '$config' | ConvertFrom-Json; 'IO-READ ' + (@{ host = `$c.ioModule.host; port = `$c.ioModule.port } | ConvertTo-Json -Compress)"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($read))
        $output = @(& ssh -o BatchMode=yes -o ConnectTimeout=15 $alias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1 | ForEach-Object { "$_" })
        $line = @($output | Where-Object { $_.StartsWith('IO-READ ', [StringComparison]::Ordinal) } | Select-Object -Last 1)
        if ($LASTEXITCODE -ne 0 -or $line.Count -eq 0) { throw "IO_READ_FAILED: ssh $alias (exit $LASTEXITCODE): $(($output | Select-Object -First 3) -join ' | ')" }
        $io = $line[0].Substring('IO-READ '.Length) | ConvertFrom-Json -AsHashtable
        $result['host'] = [string] $io['host']
        $port = 0
        $result['port'] = [int]::TryParse([string] $io['port'], [ref]$port) ? $port : $null
        $result['refusal'] = Get-ProductionIoRefusal -Phase 'production' -IoHost $result['host'] -IoPort $port -SiteHost $result['siteHost']
        $result['ok'] = $null -eq $result['refusal']
    } catch {
        $result['refusal'] = $_.Exception.Message
    }
    if ($result['ok']) { Write-Host ("IO_CHECK {0} OK {1}:{2}" -f $alias, $result['host'], $result['port']) -ForegroundColor Green }
    else { Write-Host ("IO_CHECK {0} REFUSED {1}" -f $alias, $result['refusal']) -ForegroundColor Red }
    $result
}

$record = [ordered]@{ kind = 'onboard-io-check'; checkedAt = [DateTimeOffset]::Now.ToString('o'); results = @($results) }
$directory = Split-Path -Parent $RecordPath
if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $RecordPath -Encoding utf8NoBOM
$failed = @($results | Where-Object { -not $_['ok'] }).Count
Write-Host ("Record: {0} ({1} of {2} on the real module)" -f $RecordPath, ($aliases.Count - $failed), $aliases.Count)
exit ($failed -eq 0 ? 0 : 1)
