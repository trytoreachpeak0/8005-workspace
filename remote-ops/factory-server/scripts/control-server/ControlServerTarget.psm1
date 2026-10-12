#Requires -Version 7
<#
.SYNOPSIS
    Which ControlServer instance a factory-server script is about to act on, checked before it acts
    (workspace#35). Imported by Set-JourneyRuntime.ps1 and 13-close-gates-when-idle.ps1.

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

function ConvertTo-ComparablePath {
    param([AllowNull()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Trim().Trim('"').Replace('/', '\').TrimEnd('\').ToLowerInvariant()
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

# Whether one instance parameter names the MVP. Kind is ServiceName, InstallRoot, ConfigPath or BaseUrl.
function Test-MvpTargetValue {
    param(
        [Parameter(Mandatory)][ValidateSet('ServiceName', 'InstallRoot', 'ConfigPath', 'BaseUrl')][string] $Kind,
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
    }
}

<#
    Bound: the caller's $PSBoundParameters keys. Values: every instance parameter of the caller, name -> value
    (defaults included). Kinds: name -> the Test-MvpTargetValue kind of the parameters that say which instance
    it is; a parameter in Values but not in Kinds (13's -ServerDatabase) only takes part in TARGET_PARTIAL.
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
#>
function Assert-ControlServerTargetReadback {
    param(
        [Parameter(Mandatory)] $Readback,
        [Parameter(Mandatory)][string] $ServiceName,
        [Parameter(Mandatory)][string] $ConfigPath,
        [Parameter(Mandatory)][string] $BaseUrl,
        [string] $InstallRoot,
        [string] $Database
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

    $healthPort = Get-UrlPort $Readback.healthUrl
    if ($null -eq $healthPort) { throw "TARGET_HEALTH_URL_UNKNOWN: $where names no readable Health.url ('$($Readback.healthUrl)'), so -BaseUrl $BaseUrl cannot be checked against it. $tail" }
    if ($healthPort -ne (Get-UrlPort $BaseUrl)) {
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
        if ((ConvertTo-ComparablePath $own) -cne (ConvertTo-ComparablePath $Database)) {
            if ((ConvertTo-ComparablePath $Database).StartsWith((ConvertTo-ComparablePath $script:InstanceDataTree) + '\', [StringComparison]::Ordinal)) {
                throw ("TARGET_DATABASE_OTHER_INSTANCE: -ServerDatabase $Database is under $($script:InstanceDataTree) but is not this " +
                    "instance's database ($own). A rehearsal copy belongs outside that tree. $tail")
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

# Where Set-JourneyRuntime.ps1 tails the log after a restart: the directory the target's own configuration names;
# failing that, the MVP's fixed one for the MVP only, and nothing for any other instance.
function Resolve-ControlServerLogSource {
    param([Parameter(Mandatory)] $Facts, [Parameter(Mandatory)][bool] $IsMvp)
    $directory = $Facts.LogDirectory ?? ($IsMvp ? $script:MvpTarget.LogDirectory : $null)
    if (-not $directory) { return $null }
    return [pscustomobject]@{ Directory = $directory; Filter = $Facts.LogFilter ?? 'controlserver-*.ndjson' }
}

Export-ModuleMember -Function Resolve-ControlServerLogSource, Test-MvpTargetValue, Assert-ControlServerTargetParameters,
    Get-ControlServerTargetReadbackScript, Get-ServiceExecutableDirectory, Assert-ControlServerTargetReadback, Get-UrlPort
