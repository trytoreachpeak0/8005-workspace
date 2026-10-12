#Requires -Version 7
<#
.SYNOPSIS
    The vehicle half of 18-set-v2-recovery-window.ps1. Runs ON agv02/agv03, staged beside
    V2RecoveryWindow.psm1; never run by hand.

.DESCRIPTION
    Takes no parameters: the request (state, install root, onboardInstanceId, proof) arrives as one
    line of JSON on standard input, so nothing from the control host's parameters is spliced into a
    command line and the proof never lies in a file. The logic and its order are
    Invoke-V2RecoveryWindowVehicle's; this file only wires the real machine in.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'V2RecoveryWindow.psm1') -Force

$request = Read-V2RecoveryWindowRequest -Line ([Console]::In.ReadLine())
$actions = @{
    ClientRunning = { @(Get-Process -Name 'SQCD.Agv.Wpf' -ErrorAction SilentlyContinue).Count -gt 0 }
    GetMachineVariable = { param([string] $Name) [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    # [NullString]::Value, not $null: $null reaches a .NET string parameter as "" and writes an empty
    # REG_SZ instead of deleting the variable (agv01, 2026-09-10).
    SetMachineVariable = {
        param([string] $Name, [AllowNull()][string] $Value)
        [Environment]::SetEnvironmentVariable($Name, ([string]::IsNullOrEmpty($Value) ? [NullString]::Value : $Value), 'Machine')
    }
}
Invoke-V2RecoveryWindowVehicle -Request $request -Actions $actions
