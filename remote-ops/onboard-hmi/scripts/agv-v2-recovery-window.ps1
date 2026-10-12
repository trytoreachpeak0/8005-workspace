#Requires -Version 7
<#
.SYNOPSIS
    The vehicle half of 18-set-v2-recovery-window.ps1. Runs ON agv02/agv03, staged beside
    V2RecoveryWindow.psm1; never run by hand.

.DESCRIPTION
    Takes no parameters: the request (state, install root, onboardInstanceId, proof) arrives as one
    line of JSON on standard input, so nothing from the control host's parameters is spliced into a
    command line and the proof never lies in a file. The logic and its order are
    Invoke-V2RecoveryWindowVehicle's, the actions New-V2VehicleActions'; this file only connects them.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1') -Force

$request = Read-V2RecoveryWindowRequest -Line ([Console]::In.ReadLine())
# No arguments: the defaults are the production wiring, and Test-SetV2RecoveryWindow.ps1 pins both the
# defaults and that this call passes none.
Invoke-V2RecoveryWindowVehicle -Request $request -Actions (New-V2VehicleActions)
