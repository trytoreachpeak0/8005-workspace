#Requires -Version 7
# Run ON agv02 (cs#566 field test): stands in for the person at the slot. Waits for the slot simulator to
# report one open door, sets that slot's cargo (OCCUPIED for a load, EMPTY for an unload), then closes the door.
# One door per call. Talks only to the simulator's automation face on 127.0.0.1:58006.
param(
    [Parameter(Mandatory)][ValidateSet('Load', 'Unload')][string] $Mode,
    [int] $WaitSeconds = 300,
    [int] $DwellSeconds = 4
)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
$base = 'http://127.0.0.1:58006/api/v1'
function Snap { Invoke-RestMethod "$base/snapshot" -NoProxy -TimeoutSec 5 }
function Context($s, $what, $slot) { [ordered]@{ runId = $s.runId; commandId = "cs566-$what-$slot-$(Get-Date -Format HHmmssfff)"; expectedRevision = $s.revision } }
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$open = $null
while (-not $open -and (Get-Date) -lt $deadline) {
    $s = Snap
    $open = @($s.slots | Where-Object doorState -eq 'OPEN') | Select-Object -First 1
    if (-not $open) { Start-Sleep -Milliseconds 500 }
}
if (-not $open) { "$(Get-Date -Format o) NO_OPEN_DOOR within $WaitSeconds s"; exit 2 }
"$(Get-Date -Format o) door open: slot $($open.slotNo) cargo=$($open.cargoState)"
Start-Sleep -Seconds $DwellSeconds
$s = Snap
$ctx = Context $s 'cargo' $open.slotNo
$ctx.state = ($Mode -eq 'Load') ? 'OCCUPIED' : 'EMPTY'
$r = Invoke-WebRequest "$base/slots/$($open.slotNo)/cargo" -Method Put -ContentType 'application/json' -Body ($ctx | ConvertTo-Json) -NoProxy -SkipHttpErrorCheck
"$(Get-Date -Format o) cargo slot=$($open.slotNo) -> $($ctx.state) $($r.StatusCode)"
Start-Sleep -Seconds $DwellSeconds
$s = Snap
$r = Invoke-WebRequest "$base/slots/$($open.slotNo)/close-door" -Method Post -ContentType 'application/json' -Body ((Context $s 'close' $open.slotNo) | ConvertTo-Json) -NoProxy -SkipHttpErrorCheck
"$(Get-Date -Format o) close slot=$($open.slotNo) $($r.StatusCode)"
Start-Sleep -Seconds 2
$s = Snap
"$(Get-Date -Format o) after: open=$($s.openDoorCount) " + (($s.slots | Where-Object { $_.cargoState -ne 'EMPTY' -or $_.doorState -ne 'CLOSED' } | ForEach-Object { "$($_.slotNo):$($_.doorState)/$($_.cargoState)/lock$($_.lockFeedbackRaw)" }) -join ' ')
