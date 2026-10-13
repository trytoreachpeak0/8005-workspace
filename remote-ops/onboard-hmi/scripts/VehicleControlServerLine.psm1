#Requires -Version 7

<#
    Which ControlServer line a car runs against today -- the MVP service or the v2 instance -- read from one field of its
    site file, remote-ops/onboard-hmi/config/site-<alias>.json: "controlServerLine": "mvp" or "v2".

    control-server#564 (D7, user decision 2026-10-13). Until then the pairing "agv01 <-> MVP, agv02/agv03 <-> v2" was
    written into four scripts (ControlServerTarget.psm1, 06-deploy-onboard-hmi.ps1, 16-enter-sublot-uia.ps1, and the status
    script cs#565 named), and the cutover would have had to change all four on the same day. A partial change is the
    dangerous state: "everything defaults to the MVP plus agv01" would still pair. One field means the cutover changes one
    file per car, and so does the rollback.

    Fails closed: a site file that is missing, unreadable, or without exactly one of the two values throws. Nothing here
    guesses a line from the alias.
#>

Set-StrictMode -Version 3.0

$script:Lines = @('mvp', 'v2')

function Get-VehicleSitePath {
    <#
        .SYNOPSIS
            remote-ops/onboard-hmi/config/site-<alias>.json for an SSH alias, or under -ConfigDirectory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $SshAlias,
        [string] $ConfigDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config')
    )
    return Join-Path $ConfigDirectory "site-$($SshAlias.Trim().ToLowerInvariant()).json"
}

function ConvertTo-VehicleControlServerLine {
    <#
        .SYNOPSIS
            The line named by a parsed site file, or a throw saying why there is none. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()] $Site,
        [Parameter(Mandatory = $true)][string] $SitePath
    )
    $value = ($Site -is [System.Collections.IDictionary] -and $Site.Contains('controlServerLine')) ? $Site['controlServerLine'] : $null
    if ($value -isnot [string] -or $script:Lines -cnotcontains $value) {
        throw ("VEHICLE_LINE_UNSET: $SitePath must say which ControlServer this car runs against: ""controlServerLine"": " +
            """mvp"" (the MVP service, 58005/58007) or ""v2"" (the v2 instance, 58105/58107), exactly, lower case; got " +
            "'$value'. Nothing was read or changed.")
    }
    return $value
}

function Read-VehicleControlServerLine {
    <#
        .SYNOPSIS
            'mvp' or 'v2' from the site file at -SitePath; throws when the file or the field is missing or wrong.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $SitePath)
    if (-not (Test-Path -LiteralPath $SitePath -PathType Leaf)) {
        throw "VEHICLE_LINE_UNSET: no site file at $SitePath, so which ControlServer this car runs against is unknown. Nothing was read or changed."
    }
    $site = $null
    try { $site = Get-Content -LiteralPath $SitePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
    catch { throw "VEHICLE_LINE_UNSET: $SitePath is not readable JSON ($($_.Exception.Message)). Nothing was read or changed." }
    return ConvertTo-VehicleControlServerLine -Site $site -SitePath $SitePath
}

Export-ModuleMember -Function Get-VehicleSitePath, ConvertTo-VehicleControlServerLine, Read-VehicleControlServerLine
