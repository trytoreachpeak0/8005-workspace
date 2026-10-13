#Requires -Version 7
<#
.SYNOPSIS
    Which ControlServer instance a factory-server script is about to act on, checked before it acts
    (workspace#35). Imported by Set-JourneyRuntime.ps1 and 13-close-gates-when-idle.ps1, and since workspace#38 by
    12-reset-journey-state.ps1, Complete-ChargingRun.ps1 and 11-drive-journey.ps1.

.DESCRIPTION
    Both scripts default every instance parameter -- service name, configuration path, health URL, and for 13
    the install root and the database -- to the production MVP service. Passing only the v2 value of one of
    them used to leave the rest on the MVP: -ServiceName '8005 AGV ControlServer V2' alone rewrote the MVP's
    appsettings.Production.json gate booleans and then restarted the V2 service. The same shape as
    workspace#32, where a single port left the other one on the MVP.

    Two checks, in this order, and nothing is read or written on the server before the first passes:

      Assert-ControlServerTargetParameters (no I/O)
        TARGET_PARTIAL    some of the instance parameters given, not all. All defaults (the MVP) or all
                          explicit; never a mix of given and defaulted.
        TARGET_MIXED_MVP  all given, but some name the MVP and others do not.

      Assert-ControlServerTargetReadback (on what the server reports, before anything is written)
        TARGET_SERVICE_NOT_FOUND / TARGET_CONFIG_NOT_FOUND
        TARGET_SERVICE_CONFIG_MISMATCH  the service's executable is not in the configuration's directory
                                        (or, for 13, not in -ServerInstallRoot).
        TARGET_HEALTH_URL_UNKNOWN / TARGET_BASE_URL_MISMATCH
                                        Health.url in that configuration is missing, or its port is not
                                        -BaseUrl's.
        TARGET_DATABASE_UNKNOWN / TARGET_DATABASE_OTHER_INSTANCE
                                        (13 only) the configuration's connection string is unreadable, or
                                        -ServerDatabase is another instance's database under
                                        C:\ProgramData\8005\. A database outside that tree is a rehearsal copy
                                        and is allowed, as 13 has always documented.
        TARGET_DATABASE_NOT_OWN         (-RequireOwnDatabase: 12, Complete-ChargingRun) -ServerDatabase is not the
                                        instance's own database at all. Those two stop the service before they
                                        write, so a copy would stop one instance to write another file.
        -BaseUrl is optional: without it Health.url is not checked (12 and Complete-ChargingRun take no URL).

      Assert-ControlServerVehicleTarget (reads the car's site file only; 11 and 12, which also act on a vehicle)
        TARGET_VEHICLE_INSTANCE_MISMATCH  -SshAlias is a car whose site file says "controlServerLine": "mvp" and the
                                          instance is not the MVP, or "v2" and it is the MVP. Such a run reads one
                                          side's data to act on the other side's vehicle. Which side a car is on is
                                          that one field (VehicleControlServerLine.psm1, control-server#564): the
                                          cutover and its rollback change the site file, not this module. An alias
                                          that is no car of the fleet is not judged; a fleet car whose site file
                                          does not say is refused (VEHICLE_LINE_UNSET).

    The MVP values are written out here, once. If the MVP ever moves, change them here.
#>

Set-StrictMode -Version 3.0

$script:MvpTarget = [ordered]@{
    ServiceName = '8005 AGV ControlServer'
    InstallRoot = 'C:\Program Files\8005 AGV\ControlServer'
    HealthPort  = 58007
    Database    = 'C:\ProgramData\8005\ControlServer\data\controlserver.db'
    LogDirectory = 'C:\ProgramData\8005\ControlServer\logs'
}
$script:InstanceDataTree = 'C:\ProgramData\8005\'
# SSH aliases of the three cars (remote-ops/fleet.md). Which side each runs against is its site file's controlServerLine.
$script:FleetVehicleAliases = @('agv01', 'agv02', 'agv03')
Import-Module (Join-Path $PSScriptRoot '..\..\..\onboard-hmi\scripts\VehicleControlServerLine.psm1') -Force

function ConvertTo-ComparablePath {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Trim().Trim('"', "'").Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

# A database path as SQLite would open it: quotes off, environment variables expanded (on this machine; the
# server's ProgramData is the same C:\ProgramData), '..' resolved when the path is rooted. A relative path is left
# relative: it cannot equal a rooted -ServerDatabase, so it is refused rather than guessed.
function ConvertTo-ComparableDatabasePath {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"', "'")).Replace('/', '\')
    if ([IO.Path]::IsPathRooted($p)) { $p = [IO.Path]::GetFullPath($p) }
    return ConvertTo-ComparablePath $p
}

function Get-UrlPort {
    param([AllowNull()][string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    # Kestrel accepts http://*:58007 and http://+:58007, which [Uri] does not parse.
    $normalised = $Url.Trim() -replace '^(https?://)[*+](?=[:/]|$)', '${1}0.0.0.0'
    $uri = $null
    if (-not [Uri]::TryCreate($normalised, [UriKind]::Absolute, [ref]$uri)) { return $null }
    return $uri.Port
}

# Whether one instance parameter names the MVP. Kind is ServiceName, InstallRoot, ConfigPath, BaseUrl or Database.
function Test-MvpTargetValue {
    param(
        [Parameter(Mandatory)][ValidateSet('ServiceName', 'InstallRoot', 'ConfigPath', 'BaseUrl', 'Database')][string] $Kind,
        [AllowNull()][AllowEmptyString()][string] $Value
    )
    switch ($Kind) {
        'ServiceName' { return [string]::Equals(($Value ?? '').Trim(), $script:MvpTarget.ServiceName, [StringComparison]::OrdinalIgnoreCase) }
        'InstallRoot' { return (ConvertTo-ComparablePath $Value) -ceq (ConvertTo-ComparablePath $script:MvpTarget.InstallRoot) }
        'ConfigPath' {
            $directory = [string]::IsNullOrWhiteSpace($Value) ? '' : [IO.Path]::GetDirectoryName($Value.Trim().Replace('/', '\'))
            return (ConvertTo-ComparablePath $directory) -ceq (ConvertTo-ComparablePath $script:MvpTarget.InstallRoot)
        }
        'BaseUrl' { return (Get-UrlPort $Value) -eq $script:MvpTarget.HealthPort }
        'Database' { return (ConvertTo-ComparableDatabasePath $Value) -ceq (ConvertTo-ComparableDatabasePath $script:MvpTarget.Database) }
    }
}

<#
    Bound: the caller's $PSBoundParameters keys. Values: every instance parameter of the caller, name -> value
    (defaults included). Kinds: name -> the Test-MvpTargetValue kind of the parameters that say which instance
    it is; a parameter in Values but not in Kinds (13's -ServerDatabase, which may name a rehearsal copy) only takes
    part in TARGET_PARTIAL.
#>
function Assert-ControlServerTargetParameters {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Bound,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Values,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Kinds
    )
    $names = @($Values.Keys)
    $given = @($names | Where-Object { $_ -in $Bound })
    if ($given.Count -and $given.Count -ne $names.Count) {
        $missing = @($names | Where-Object { $_ -notin $given })
        throw ("TARGET_PARTIAL: -$($given -join ', -') given without -$($missing -join ', -'). The defaults are the production " +
            "MVP service, so a partial set would act on two instances at once. Give all of -$($names -join ', -'), or none " +
            "(the MVP). Nothing was read or changed.")
    }
    $mvp = @(); $other = @()
    foreach ($name in @($Kinds.Keys)) {
        if (Test-MvpTargetValue -Kind $Kinds[$name] -Value ([string]$Values[$name])) { $mvp += "-$name" } else { $other += "-$name" }
    }
    if ($mvp.Count -and $other.Count) {
        throw ("TARGET_MIXED_MVP: $($mvp -join ', ') name the production MVP service but $($other -join ', ') do not. One " +
            "instance per run: all MVP values or none of them. Nothing was read or changed.")
    }
    return [pscustomobject]@{ IsMvp = ($mvp.Count -gt 0 -and -not $other.Count); Explicit = ($given.Count -gt 0) }
}

# The read-only server-side script that reports what the service and its configuration say about themselves.
# It reads one service's metadata and one configuration file (plus its base appsettings.json); nothing else.
function Get-ControlServerTargetReadbackScript {
    param([Parameter(Mandatory)][string] $ServiceName, [Parameter(Mandatory)][string] $ConfigPath)
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    return @"
# workspace#35 target read-back
`$name = $(& $q $ServiceName)
`$cfg = $(& $q $ConfigPath)
`$svc = Get-CimInstance -ClassName Win32_Service | Where-Object { `$_.Name -eq `$name } | Select-Object -First 1
`$read = { param(`$p) if (Test-Path -LiteralPath `$p -PathType Leaf) { try { Get-Content -LiteralPath `$p -Raw | ConvertFrom-Json } catch { `$null } } }
`$c = & `$read `$cfg
`$b = & `$read (Join-Path (Split-Path -Parent `$cfg) 'appsettings.json')
`$pick = { param(`$f) foreach (`$o in @(`$c, `$b)) { if (`$null -ne `$o) { `$v = & `$f `$o; if (`$v) { return [string]`$v } } }; `$null }
[pscustomobject]@{
    serviceFound     = `$null -ne `$svc
    servicePathName  = [string]`$svc.PathName
    configFound      = Test-Path -LiteralPath `$cfg -PathType Leaf
    healthUrl        = & `$pick { param(`$o) `$o.Health.url }
    connectionString = & `$pick { param(`$o) `$o.ConnectionStrings.ControlServer }
    logPath          = & `$pick { param(`$o) @(`$o.Serilog.WriteTo | Where-Object { `$_.Name -eq 'File' })[0].Args.path }
} | ConvertTo-Json -Compress
"@
}

function Get-ServiceExecutableDirectory {
    param([AllowNull()][string] $PathName)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return '' }
    $p = $PathName.Trim()
    $exe = if ($p -match '^"([^"]+)"') { $Matches[1] } elseif ($p -match '^(.+?\.exe)(\s|$)') { $Matches[1] } else { $p }
    return [IO.Path]::GetDirectoryName($exe)
}

<#
    Readback: the parsed JSON of the read-back script. Returns the log directory the configuration names
    (null when it names none) and, for -Database, whether it is a copy rather than the instance's own.
    -BaseUrl is checked against Health.url only when given: 12 and Complete-ChargingRun work on the database, not on
    the service's HTTP face, and take no URL.
#>
function Assert-ControlServerTargetReadback {
    param(
        [Parameter(Mandatory)] $Readback,
        [Parameter(Mandatory)][string] $ServiceName,
        [Parameter(Mandatory)][string] $ConfigPath,
        [string] $BaseUrl,
        [string] $InstallRoot,
        [string] $Database,
        [switch] $RequireOwnDatabase
    )
    $where = "service '$ServiceName', configuration $ConfigPath"
    $tail = 'Nothing was changed.'
    if (-not $Readback.serviceFound) { throw "TARGET_SERVICE_NOT_FOUND: there is no service named '$ServiceName' on the server. $tail" }
    if (-not $Readback.configFound) { throw "TARGET_CONFIG_NOT_FOUND: $ConfigPath does not exist on the server. $tail" }

    $serviceDirectory = Get-ServiceExecutableDirectory $Readback.servicePathName
    $configDirectory = [IO.Path]::GetDirectoryName($ConfigPath.Trim().Replace('/', '\'))
    $mismatch = @()
    if ((ConvertTo-ComparablePath $serviceDirectory) -cne (ConvertTo-ComparablePath $configDirectory)) { $mismatch += "the configuration is in $configDirectory" }
    if ($PSBoundParameters.ContainsKey('InstallRoot') -and (ConvertTo-ComparablePath $serviceDirectory) -cne (ConvertTo-ComparablePath $InstallRoot)) {
        $mismatch += "-ServerInstallRoot is $InstallRoot"
    }
    if ($mismatch.Count) {
        throw ("TARGET_SERVICE_CONFIG_MISMATCH: service '$ServiceName' runs from '$serviceDirectory' ($($Readback.servicePathName)), but " +
            "$($mismatch -join ' and '). They are not one instance. $tail")
    }

    $checkHealth = $PSBoundParameters.ContainsKey('BaseUrl')
    $healthPort = $checkHealth ? (Get-UrlPort $Readback.healthUrl) : 0
    if ($null -eq $healthPort) { throw "TARGET_HEALTH_URL_UNKNOWN: $where names no readable Health.url ('$($Readback.healthUrl)'), so -BaseUrl $BaseUrl cannot be checked against it. $tail" }
    if ($checkHealth -and $healthPort -ne (Get-UrlPort $BaseUrl)) {
        throw "TARGET_BASE_URL_MISMATCH: $where binds health on $($Readback.healthUrl), not on -BaseUrl $BaseUrl's port. $tail"
    }

    $copy = $false
    if ($PSBoundParameters.ContainsKey('Database')) {
        # Microsoft.Data.Sqlite's keywords for the file. (DbConnectionStringBuilder is a dictionary to PowerShell,
        # so assigning its ConnectionString adds a key instead.)
        $own = ([string]$Readback.connectionString -match '(?i)(?:^|;)\s*(?:Data\s*Source|Filename)\s*=\s*([^;]+)') ? $Matches[1].Trim() : $null
        if ([string]::IsNullOrWhiteSpace($own)) {
            throw "TARGET_DATABASE_UNKNOWN: $where names no readable ConnectionStrings:ControlServer ('$($Readback.connectionString)'). $tail"
        }
        if ((ConvertTo-ComparableDatabasePath $own) -cne (ConvertTo-ComparableDatabasePath $Database)) {
            if ((ConvertTo-ComparableDatabasePath $Database).StartsWith((ConvertTo-ComparablePath $script:InstanceDataTree) + '\', [StringComparison]::Ordinal)) {
                throw ("TARGET_DATABASE_OTHER_INSTANCE: -ServerDatabase $Database is under $($script:InstanceDataTree) but is not this " +
                    "instance's database ($own). A rehearsal copy belongs outside that tree. $tail")
            }
            if ($RequireOwnDatabase) {
                throw ("TARGET_DATABASE_NOT_OWN: -ServerDatabase $Database is not this instance's database ($own). This " +
                    "script stops '$ServiceName' before it writes, so it only works on that instance's own file. $tail")
            }
            $copy = $true
        }
    }

    $logPath = [string]$Readback.logPath
    return [pscustomobject]@{
        LogDirectory = [string]::IsNullOrWhiteSpace($logPath) ? $null : [IO.Path]::GetDirectoryName($logPath.Replace('/', '\'))
        LogFilter    = [string]::IsNullOrWhiteSpace($logPath) ? $null :
            ([IO.Path]::GetFileNameWithoutExtension($logPath) + '*' + [IO.Path]::GetExtension($logPath))
        DatabaseIsCopy = $copy
    }
}

# Whether the vehicle a run acts on runs against the instance whose data it reads or writes (workspace#38).
function Assert-ControlServerVehicleTarget {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $SshAlias, [Parameter(Mandatory)][bool] $IsMvp, [string] $ConfigDirectory)
    $alias = $SshAlias.Trim().ToLowerInvariant()
    if ($alias -notin $script:FleetVehicleAliases) { return [pscustomobject]@{ Judged = $false } }
    $sitePath = $ConfigDirectory ? (Get-VehicleSitePath -SshAlias $alias -ConfigDirectory $ConfigDirectory) : (Get-VehicleSitePath -SshAlias $alias)
    $side = ((Read-VehicleControlServerLine -SitePath $sitePath) -ceq 'mvp') ? 'MVP' : 'v2'
    if (($side -eq 'MVP') -ne $IsMvp) {
        $instance = $IsMvp ? 'the production MVP service (defaulted or given as the MVP''s)' : 'an instance that is not the MVP'
        throw ("TARGET_VEHICLE_INSTANCE_MISMATCH: -SshAlias $SshAlias runs against the $side side, but the server " +
            "parameters name $instance. Give the parameters of the instance that vehicle runs against. Nothing was read " +
            "or changed.")
    }
    return [pscustomobject]@{ Judged = $true }
}

# Where Set-JourneyRuntime.ps1 tails the log after a restart: the directory the target's own configuration names;
# failing that, the MVP's fixed one for the MVP only, and nothing for any other instance.
function Resolve-ControlServerLogSource {
    param([Parameter(Mandatory)] $Facts, [Parameter(Mandatory)][bool] $IsMvp)
    $directory = $Facts.LogDirectory ?? ($IsMvp ? $script:MvpTarget.LogDirectory : $null)
    if (-not $directory) { return $null }
    return [pscustomobject]@{ Directory = $directory; Filter = $Facts.LogFilter ?? 'controlserver-*.ndjson' }
}

Export-ModuleMember -Function Resolve-ControlServerLogSource, Assert-ControlServerVehicleTarget, Test-MvpTargetValue, Assert-ControlServerTargetParameters,
    Get-ControlServerTargetReadbackScript, Get-ServiceExecutableDirectory, Assert-ControlServerTargetReadback, Get-UrlPort
