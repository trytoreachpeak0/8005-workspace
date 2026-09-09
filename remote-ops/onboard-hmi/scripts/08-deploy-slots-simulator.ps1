#Requires -Version 7
<#
.SYNOPSIS
    Builds the slot IO simulator and installs it on an onboard machine. Runs ON
    the control host.

.DESCRIPTION
    The simulator stands in for the Kangnaide C2000-A2-KDDA0A0-AD6 IO module:
    eight slots of relay DO, lock-feedback DI, light-curtain DI, door and cargo
    state, served as Modbus TCP. RELEASE-CANDIDATE.md section 11 is explicit that
    it does not qualify real IO, wiring, locks or light curtains -- it proves the
    software loop and nothing else.

    It must run ON the vehicle, beside the onboard client, because it binds
    127.0.0.1:1502 for Modbus and 127.0.0.1:58006 for its automation control
    plane. Both are loopback by design: the HMI reaches IO only through Modbus,
    and the HTTP plane -- which the HMI must never call and which cannot unlock
    anything -- is for test automation on that same machine.

    slots-simulator belongs to Kun Wang and is READ-ONLY to agents. This script
    never builds inside that working tree: it clones it to a scratch directory,
    builds there, and leaves the source worktree untouched. Same shape the CD
    workflow uses for the onboard repository.

    The vehicle has no .NET runtime, so the publish is self-contained win-x64 --
    about 400 files and 190 MB before compression.

    Nothing is started. The simulator is a WPF application: it needs an
    interactive desktop session, which an ssh session 0 does not have, and the
    order at the vehicle matters -- the simulator must be listening before the
    onboard client opens its Modbus connection.

.PARAMETER PublishPath
    Skip the clone and build and install an already-published directory. For
    re-running the install half without paying for the build again.

.PARAMETER Force
    Install even though the simulator is currently running on the target. The
    default refusal exists because replacing binaries under a running simulator
    while the onboard client is polling it produces IO reads no one can explain.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $SshAlias = 'agv01',
    [string] $SourceRepository = 'C:\Users\szy\Desktop\8005-workspace\repos\slots-simulator',
    [string] $PublishPath,
    [string] $InstallRoot = 'C:\8005\SlotsSimulator',
    [string] $SdkVersion = '8.0.425',
    [string] $StagingRoot = 'C:\temp\agv\simulator-staging',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }

function Invoke-Onboard {
    param([string] $Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $raw = & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshAlias "pwsh -NoProfile -EncodedCommand $encoded" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ssh $SshAlias failed: $(($raw | Out-String).Trim())" }
    ($raw | Out-String).Trim()
}

# -------------------------------------------------------------- vehicle state ---

$running = Invoke-Onboard @'
[pscustomobject]@{
    simulator = [bool](Get-Process 'SQCD_8005AGV_Simulator' -ErrorAction SilentlyContinue)
    onboard   = [bool](Get-Process 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue)
} | ConvertTo-Json -Compress
'@ | ConvertFrom-Json

if (($running.simulator -or $running.onboard) -and -not $Force) {
    throw "Running on ${SshAlias}: simulator=$($running.simulator), onboard=$($running.onboard). Close them from the vehicle's own desktop session, then rerun."
}

# --------------------------------------------------------------------- build ---

$scratch = Join-Path ([IO.Path]::GetTempPath()) "slots-sim-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$builtHere = $false
try {
    if (-not $PublishPath) {
        if (-not (Test-Path -LiteralPath $SourceRepository)) { throw "No simulator source at $SourceRepository." }

        Write-Step "Cloning to $scratch (the source worktree is never built in)"
        # --no-hardlinks: a hardlinked object store shares files with the protected
        # repository. Nothing here writes to it, but the isolation should not
        # depend on that being true.
        & git clone --quiet --no-hardlinks $SourceRepository $scratch
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
        $sourceCommit = (& git -C $scratch rev-parse HEAD).Trim()
        Write-Step "Source commit $sourceCommit"

        # The simulator repository carries no global.json. Pin the workspace
        # baseline SDK for the build rather than inheriting whatever is default.
        @{ sdk = @{ version = $SdkVersion; rollForward = 'disable' } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'global.json') -Encoding utf8NoBOM

        $PublishPath = Join-Path $scratch 'publish'
        Write-Step "Publishing self-contained win-x64 (the vehicle has no .NET runtime)"
        & dotnet publish (Join-Path $scratch 'src\SQCD_8005AGV_Simulator\SQCD_8005AGV_Simulator.csproj') `
            -c Release -r win-x64 --self-contained true -o $PublishPath --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }
        $builtHere = $true
    }
    else {
        $sourceCommit = 'n/a (-PublishPath)'
    }

    $exe = Join-Path $PublishPath 'SQCD_8005AGV_Simulator.exe'
    foreach ($required in @($exe, (Join-Path $PublishPath 'simulator.settings.json'), (Join-Path $PublishPath 'hostfxr.dll'))) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Publish output is missing $required." }
    }
    $fileCount = @(Get-ChildItem -LiteralPath $PublishPath -Recurse -File).Count
    Write-Step "$fileCount files published"

    # ------------------------------------------------------------------ ship ---

    $archive = Join-Path ([IO.Path]::GetTempPath()) "slots-simulator-$([DateTime]::Now.ToString('yyyyMMddHHmmss')).zip"
    Write-Step 'Compressing'
    Compress-Archive -Path (Join-Path $PublishPath '*') -DestinationPath $archive -CompressionLevel Optimal -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $sizeMb = [math]::Round((Get-Item -LiteralPath $archive).Length / 1MB, 1)
    Write-Step "$sizeMb MB, sha256 $($hash.Substring(0, 16))..."

    if (-not $PSCmdlet.ShouldProcess("${SshAlias}:$InstallRoot", "Install the slot IO simulator")) {
        Write-Host 'Not installed.' -ForegroundColor Yellow
        return
    }

    Invoke-Onboard "New-Item -ItemType Directory -Path '$StagingRoot' -Force | Out-Null" | Out-Null
    $remoteArchive = "$StagingRoot\$(Split-Path -Leaf $archive)"
    Write-Step "Copying to ${SshAlias}:$remoteArchive"
    & scp -q $archive "${SshAlias}:$remoteArchive"
    if ($LASTEXITCODE -ne 0) { throw 'scp failed.' }

    # --------------------------------------------------------------- install ---

    # The hash is verified on the far side as well as here. A truncated scp is
    # exactly how that failure has presented before.
    $result = Invoke-Onboard @"
`$archive = '$remoteArchive'
`$actual = (Get-FileHash -LiteralPath `$archive -Algorithm SHA256).Hash
if (`$actual -ne '$hash') { throw "Hash mismatch after transfer: `$actual" }

`$unpack = '$StagingRoot\unpack'
Remove-Item -LiteralPath `$unpack -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath `$archive -DestinationPath `$unpack -Force

`$root = '$InstallRoot'
`$previous = "`$root.previous"
if (Test-Path -LiteralPath `$root) {
    Remove-Item -LiteralPath `$previous -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath `$root -Destination `$previous
}
New-Item -ItemType Directory -Path (Split-Path -Parent `$root) -Force | Out-Null
Move-Item -LiteralPath `$unpack -Destination `$root

# Same shape as the onboard client's shortcut: the vehicle operator starts both
# from the desktop, and the simulator has to be listening first.
`$shortcut = "`$([Environment]::GetFolderPath('CommonDesktopDirectory'))\8005 仓位模拟器.lnk"
`$shell = New-Object -ComObject WScript.Shell
`$link = `$shell.CreateShortcut(`$shortcut)
`$link.TargetPath = "`$root\SQCD_8005AGV_Simulator.exe"
`$link.WorkingDirectory = `$root
`$link.Description = '8005 AGV 仓位 IO 模拟器（Modbus 127.0.0.1:1502）'
`$link.Save()

Remove-Item -LiteralPath `$archive -Force -ErrorAction SilentlyContinue
[pscustomobject]@{
    installRoot   = `$root
    fileCount     = @(Get-ChildItem -LiteralPath `$root -Recurse -File).Count
    exePresent    = Test-Path -LiteralPath "`$root\SQCD_8005AGV_Simulator.exe"
    settings      = Test-Path -LiteralPath "`$root\simulator.settings.json"
    previousKept  = Test-Path -LiteralPath `$previous
    shortcut      = `$shortcut
} | ConvertTo-Json -Compress
"@ | ConvertFrom-Json

    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Step "Installed to $($result.installRoot): $($result.fileCount) files"
    Write-Step "Shortcut: $($result.shortcut)"
    if ($result.previousKept) { Write-Step 'Previous generation kept alongside as .previous' }
    Write-Host ''
    Write-Host 'Not started. The simulator is a WPF application and must be started from the' -ForegroundColor Yellow
    Write-Host 'vehicle desktop, BEFORE the onboard client, so its Modbus port is listening' -ForegroundColor Yellow
    Write-Host 'when the client connects.' -ForegroundColor Yellow

    [pscustomobject]@{
        sourceCommit = $sourceCommit
        sha256       = $hash
        installRoot  = $result.installRoot
        fileCount    = $result.fileCount
    }
}
finally {
    if ($builtHere) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
