#Requires -Version 7

<#
  04-serve-payload.ps1 - Temporary read-only HTTP server on the CONTROL workstation.

  The HMI machines have no internet but can reach this workstation. This serves
  the OpenSSH offline package and the bootstrap scripts over plain HTTP so a
  one-liner pasted into the HMI's PowerShell (via VNC) pulls and runs everything.

  RUN THIS ON THE CONTROL WORKSTATION (LAB-WIN-01), NOT ON THE HMI.

  WHAT THIS CHANGES ON THIS MACHINE (all undone on exit):
    - Opens an inbound firewall rule for the chosen port.
    - Listens on that port until you press Ctrl+C.
  Nothing is written outside this directory. The server is READ ONLY: it only
  serves files that already exist in payload\ and scripts\, by exact filename.

  Usage (PowerShell 7 as Administrator):
      pwsh -ExecutionPolicy Bypass -File .\04-serve-payload.ps1
      pwsh -ExecutionPolicy Bypass -File .\04-serve-payload.ps1 -Port 8080 -BindAddress 172.19.162.241
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,

    # Which local address the HMI machines should reach us on. Leave empty to
    # derive it from the routing table via -TargetHost.
    [string]$BindAddress,

    # An address on the HMI side, used only to ask the OS which local address it
    # would use to get there. Default is car 1's CPE.
    [string]$TargetHost = '172.19.162.210',

    # How long to stay up before shutting down on its own, as a safety net
    # in case this window is forgotten.
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  ok   $m"   -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m"   -ForegroundColor Yellow }
function Die($m)  { Write-Host "  FAIL $m"   -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Must run elevated: HttpListener needs it to bind a non-loopback address, and we add a firewall rule.'
}

$root       = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$payloadDir = Join-Path $root 'payload'
$scriptDir  = Join-Path $root 'scripts'

# Build the served set explicitly. Requests are matched against this map by
# exact name, so there is no path to traverse out of.
Step 'Collecting files to serve'
$files = @{}
foreach ($dir in $payloadDir, $scriptDir) {
    if (-not (Test-Path $dir)) { continue }
    foreach ($f in Get-ChildItem $dir -File) {
        if ($f.Extension -in '.zip', '.ps1', '.msi', '.txt') { $files[$f.Name] = $f.FullName }
    }
}
if ($files.Count -eq 0) { Die "nothing to serve under $payloadDir or $scriptDir" }
foreach ($name in ($files.Keys | Sort-Object)) {
    $item = Get-Item $files[$name]
    Ok ("{0,-28} {1,10:N0} bytes  sha256={2}" -f $name, $item.Length,
        (Get-FileHash $item.FullName -Algorithm SHA256).Hash.Substring(0, 16) + '...')
}

# Work out which address the HMI should call us on.
#
# Do NOT just take the first non-loopback IP. This workstation has Hyper-V
# switches (192.168.200.1, 172.22.80.1), a Clash tunnel (198.18.0.1) and
# link-local addresses that all sort ahead of the real enterprise-LAN address,
# and none of them are reachable from the cars. Ask the routing table which
# source address the OS would actually use to reach the HMI side.
Step 'Determining the address the HMI should reach us on'
if (-not $BindAddress) {
    try {
        $BindAddress = (Find-NetRoute -RemoteIPAddress $TargetHost -ErrorAction Stop |
            Select-Object -First 1).IPAddress
        Ok "route to $TargetHost leaves from $BindAddress"
    } catch {
        Warn "could not resolve a route to ${TargetHost}: $($_.Exception.Message)"
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($defaultRoute) {
            $BindAddress = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex |
                Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
            Warn "falling back to the default-route interface: $BindAddress"
        }
    }
}
if (-not $BindAddress) { Die 'could not determine a bind address; pass -BindAddress explicitly' }

# Show the alternatives so a wrong pick is obvious rather than silent.
Write-Host '  local IPv4 addresses (selected one marked):' -ForegroundColor DarkGray
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' } |
    Sort-Object IPAddress |
    ForEach-Object {
        $mark = if ($_.IPAddress -eq $BindAddress) { '  ->' } else { '    ' }
        $line = "{0} {1,-16} {2}" -f $mark, $_.IPAddress, $_.InterfaceAlias
        Write-Host $line -ForegroundColor $(if ($_.IPAddress -eq $BindAddress) { 'Green' } else { 'DarkGray' })
    }

# ----------------------------------------------------------------- firewall
Step "Opening inbound TCP $Port (temporary)"
$ruleName = "AGV-payload-server-$Port"
$ruleAdded = $false
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name $ruleName -DisplayName "AGV payload server (temporary, TCP $Port)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
        -LocalPort $Port -Profile Any | Out-Null
    $ruleAdded = $true
    Ok "firewall rule '$ruleName' created (removed on exit)"
} else {
    Ok "firewall rule '$ruleName' already present"
}

# ------------------------------------------------------------------ listener
$listener = New-Object Net.HttpListener
# Bind '+' so the HMI reaches us regardless of which interface the packet
# arrives on. Requires elevation, which we checked above.
$listener.Prefixes.Add("http://+:$Port/")

try {
    $listener.Start()
} catch {
    if ($ruleAdded) { Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue }
    Die "could not listen on port ${Port}: $($_.Exception.Message)"
}
Ok "listening on http://+:$Port/"

$zipName  = ($files.Keys | Where-Object { $_ -like 'OpenSSH-Win64*.zip' } | Select-Object -First 1)
$zipHash  = if ($zipName) { (Get-FileHash $files[$zipName] -Algorithm SHA256).Hash } else { $null }
$baseUrl  = "http://${BindAddress}:$Port"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

Write-Host @"

=====================================================================
 PAYLOAD SERVER UP    $baseUrl
 Serving $($files.Count) file(s), read only. Auto-stops at $($deadline.ToString('HH:mm')).
 Press Ctrl+C to stop now.

 ON THE HMI MACHINE, in an ADMINISTRATOR PowerShell 7 window
 (open it via VNC), paste this single line:
"@ -ForegroundColor White

$oneLiner = @"
`$ErrorActionPreference='Stop'; `$u='$baseUrl'; `$d='C:\temp\agv'; ni `$d -ItemType Directory -Force|Out-Null; iwr "`$u/$zipName" -OutFile "`$d\$zipName" -UseBasicParsing; iwr "`$u/02-bootstrap-sshd.ps1" -OutFile "`$d\02-bootstrap-sshd.ps1" -UseBasicParsing; if((Get-FileHash "`$d\$zipName" -Algorithm SHA256).Hash -ne '$zipHash'){throw 'ZIP HASH MISMATCH'}; 'hash ok'; pwsh -ExecutionPolicy Bypass -File "`$d\02-bootstrap-sshd.ps1" -OfflinePackage "`$d\$zipName"
"@

Write-Host "`n$oneLiner`n" -ForegroundColor Yellow
Write-Host @"
 (It downloads the zip and the bootstrap script, verifies the zip's SHA256
  against the copy here, and only then runs the bootstrap.)
=====================================================================

"@ -ForegroundColor White

# ------------------------------------------------------------- serve loop
try {
    while ($listener.IsListening) {
        if ((Get-Date) -gt $deadline) { Warn 'timeout reached, shutting down'; break }

        # GetContext blocks; poll asynchronously so Ctrl+C and the deadline work.
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) {
            if ((Get-Date) -gt $deadline) { break }
        }
        if (-not $task.IsCompleted) { continue }

        $ctx      = $task.Result
        $request  = $ctx.Request
        $response = $ctx.Response
        $name     = $request.Url.Segments[-1]
        $client   = $request.RemoteEndPoint.Address

        if ($files.ContainsKey($name)) {
            $path  = $files[$name]
            $bytes = [IO.File]::ReadAllBytes($path)
            $response.ContentType = if ($name -like '*.ps1') { 'text/plain' } else { 'application/octet-stream' }
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host ("  {0}  {1} -> {2} ({3:N0} bytes)" -f (Get-Date -Format 'HH:mm:ss'), $client, $name, $bytes.Length) -ForegroundColor Green
        } else {
            $response.StatusCode = 404
            $body = [Text.Encoding]::UTF8.GetBytes("not served`n")
            $response.OutputStream.Write($body, 0, $body.Length)
            Write-Host ("  {0}  {1} -> {2} (404)" -f (Get-Date -Format 'HH:mm:ss'), $client, $name) -ForegroundColor DarkYellow
        }
        $response.Close()
    }
}
finally {
    Step 'Shutting down'
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Ok 'listener stopped'
    if ($ruleAdded) {
        Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        Ok "firewall rule '$ruleName' removed"
    }
}
