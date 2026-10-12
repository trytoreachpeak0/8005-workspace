#Requires -Version 7
<#
    Mutation check of 18-read-hmi-screen-state.ps1's self-test (onboard-hmi#316). Each mutation breaks one
    judgement in a copy of the scripts directory; the self-test of that copy must fail. Run from anywhere:
    pwsh -File remote-ops/onboard-hmi/evidence/hmi316-20261012/mutate-18.ps1 [-Only <regex on names>]
#>
param([string] $Only)
$ErrorActionPreference = 'Stop'
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '../../scripts')).Path
$mutations = @(
    @{ Name = 'STALE limit ignored'; From = 'if ($verdict.ageSeconds -gt $StaleAfterSeconds) {'; To = 'if ($verdict.ageSeconds -gt 100 * $StaleAfterSeconds) {' }
    @{ Name = 'STALE limit off by one (-ge)'; From = 'if ($verdict.ageSeconds -gt $StaleAfterSeconds) {'; To = 'if ($verdict.ageSeconds -ge $StaleAfterSeconds) {' }
    @{ Name = 'future writtenAt accepted'; From = 'if ($verdict.ageSeconds -lt -$StaleAfterSeconds) {'; To = 'if ($false) {' }
    @{ Name = 'process id not checked'; From = '$verdict.writerAlive = [bool] $writer -and -not $reused'; To = '$verdict.writerAlive = $true' }
    @{ Name = 'reused process id accepted'; From = '$verdict.writerAlive = [bool] $writer -and -not $reused'; To = '$verdict.writerAlive = [bool] $writer' }
    @{ Name = 'STALE checked before EXITED'; From = '    if (-not $verdict.writerAlive) {'; To = '    if ($verdict.ageSeconds -gt $StaleAfterSeconds) { return Done ''STALE'' ''x'' }; if (-not $verdict.writerAlive) {' }
    @{ Name = 'DISABLED not recognised'; From = 'if ($document.status -eq ''DISABLED'') {'; To = 'if ($false) {' }
    @{ Name = 'schema version not checked'; From = 'if ($document.schemaVersion -ne $knownSchemaVersion)'; To = 'if ($false)' }
    @{ Name = 'lenient UTF-8'; From = '[System.Text.UTF8Encoding]::new($false, $true)'; To = '[System.Text.UTF8Encoding]::new($false, $false)' }
    @{ Name = 'agv01 allowed'; From = '[ValidateSet(''agv02'', ''agv03'','; To = '[ValidateSet(''agv01'', ''agv02'', ''agv03'',' }
    @{ Name = 'Remove-Item and Stop-Process on the read allowlist'; From = '$readScriptCommands = ''Test-Path'','; To = '$readScriptCommands = ''Remove-Item'', ''Stop-Process'', ''Test-Path'',' }
    @{ Name = 'File.Open access not checked'; From = '$arguments[2] -ne ''[System.IO.FileAccess]::Read'''; To = '$false' }
    @{ Name = 'share mode not checked'; From = 'if ($Text -notmatch [regex]::Escape("`$share = [System.IO.FileShare]''ReadWrite, Delete''"))'; To = 'if ($false)' }
    @{ Name = 'MOVING ignores the revision'; From = 'if ($Before.contentRevision -ne $After.contentRevision)'; To = 'if ($false)' }
    @{ Name = 'MOVING ignores a restart'; From = 'if ($Before.processStartId -ne $After.processStartId)'; To = 'if ($false)' }
    @{ Name = 'MOVING ignores the UIA process'; From = 'if ($Before.processId -notin $uiaPids)'; To = 'if ($false)' }
    @{ Name = 'second read not required ACTIVE'; From = 'if ($After.outcome -ne ''ACTIVE'')'; To = 'if ($false)' }
    @{ Name = 'truncated UIA accepted'; From = '    $incomplete = Get-UiaCompleteness $Uia'; To = '    $incomplete = $null' }
    @{ Name = 'capture outcome not checked'; From = 'if ($CaptureOutcome -notin ''CAPTURED'', ''DESKTOP_LOCKED'')'; To = 'if ($false)' }
    @{ Name = 'button visibility not compared'; From = 'Row ''button'' $button.key ''visible'' $button.visible ($matched.Count -eq 1)'; To = 'Row ''button'' $button.key ''visible'' 1 1' }
    @{ Name = 'button enabledness not compared'; From = 'Row ''button'' $button.key ''enabled'' $button.enabled ([bool] $matched[0].isEnabled)'; To = 'Row ''button'' $button.key ''enabled'' 1 1' }
    @{ Name = 'ambiguous button not reported'; From = "        if (`$matched.Count -gt 1) {`n            Row"; To = "        if (`$false) {`n            Row" }
    @{ Name = 'template options not compared'; From = 'Row ''button'' $button.key ''options'' (($expected | Sort-Object) -join '','')'; To = 'Row ''button'' $button.key ''options'' ((@($seen | ForEach-Object { $_.automationId }) | Sort-Object) -join '','')' }
    @{ Name = 'banner taken from the button''s own Text (the 2026-10-12 real-WPF false MISMATCH)'; From = '$after = $i + @(Get-UiaNodes $nodes[$i]).Count'; To = '$after = $i + 1' }
    @{ Name = 'banner taken from any Text with that wording'; From = '$bannerNode = @($nodes | Select-Object -Skip $after | Where-Object { $_.controlType -eq ''Text'' }) | Select-Object -First 1'; To = '$bannerNode = @($nodes | Where-Object { $_.controlType -eq ''Text'' -and $_.name -ceq $State.banner.stateText }) | Select-Object -First 1' }
    @{ Name = 'hasText not compared'; From = 'Row ''input'' $box.key ''hasText'' $box.hasText $hasText'; To = 'Row ''input'' $box.key ''hasText'' 1 1' }
    @{ Name = 'input visibility not compared'; From = 'Row ''input'' $box.key ''visible'' $box.visible ($matched.Count -eq 1)'; To = 'Row ''input'' $box.key ''visible'' 1 1' }
    @{ Name = 'input enabledness not compared'; From = 'Row ''input'' $box.key ''enabled'' $box.enabled ([bool] $matched[0].isEnabled)'; To = 'Row ''input'' $box.key ''enabled'' 1 1' }
    @{ Name = 'dialog depth not compared'; From = 'Row ''modal'' ''dialogs'' ''depth'' $State.modals.depth $dialogs.Count'; To = 'Row ''modal'' ''dialogs'' ''depth'' 1 1' }
    @{ Name = 'dialog titles not compared'; From = '((@($dialogs | ForEach-Object { $_.title }) | Sort-Object) -join '' | '')'; To = '((@($State.modals.open | ForEach-Object { $_.title }) | Sort-Object) -join '' | '')' }
    @{ Name = 'hidden dialogs counted'; From = '$_.className -eq ''#32770'' -and $_.visible'; To = '$_.className -eq ''#32770''' }
    @{ Name = 'raw code value not compared'; From = 'Row ''rawCode'' $code.automationId ''value'' $code.value ($matched[0].itemStatus ?? '''')'; To = 'Row ''rawCode'' $code.automationId ''value'' 1 1' }
    @{ Name = 'raw code visibility not compared'; From = 'Row ''rawCode'' $code.automationId ''visible'' $code.visible ($matched.Count -eq 1)'; To = 'Row ''rawCode'' $code.automationId ''visible'' 1 1' }
    @{ Name = 'every row matches'; From = 'match = ("$Snapshot" -ceq "$UiaValue")'; To = 'match = $true' }
    @{ Name = 'MISMATCH exits 0'; From = 'MISMATCH = 10;'; To = 'MISMATCH = 0;' }
    # A busy wait, not Start-Sleep: the read-only scan would catch a command and kill this for the wrong reason.
    # About 200 ms, well past the writer's retry window (5 attempts, 10 ms apart, about 60 ms with the timer's
    # granularity). 400000 iterations held it about 20 ms: the writer retried twice as often and never gave up,
    # which is the writer coping, not a gap; 2000000 (about 100 ms) was killed once and survived once.
    @{ Name = 'the reader holds the handle past the writer''s retry window'; From = '        `$stream.CopyTo(`$buffer)'; To = '        `$stream.CopyTo(`$buffer); for (`$k = 0; `$k -lt 4000000; `$k++) { }' }
)
# -Only: a regex on the names, to rerun the mutations that changed.
if ($Only) { $mutations = @($mutations | Where-Object { $_.Name -match $Only }) }
$results = foreach ($m in $mutations) {
    $copy = Join-Path ([System.IO.Path]::GetTempPath()) "hmi316-mut-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Copy-Item -LiteralPath $scripts -Destination $copy -Recurse
    $target = Join-Path $copy '18-read-hmi-screen-state.ps1'
    $text = [System.IO.File]::ReadAllText($target)
    $applied = $text.Contains($m.From)
    [System.IO.File]::WriteAllText($target, $text.Replace($m.From, $m.To))
    $out = if ($applied) { & pwsh -NoProfile -NonInteractive -File $target -SelfTest 2>&1 | ForEach-Object { "$_" } }
    $exit = $LASTEXITCODE
    Remove-Item -LiteralPath $copy -Recurse -Force
    # A mutant that does not parse never ran: that is a broken mutation, not a survivor.
    $unparsed = $applied -and ($out -match 'ParserError|Unexpected token|Missing closing')
    $failed = @($out | Where-Object { $_ -like 'FAIL *' } | ForEach-Object { $_ -replace '^FAIL ', '' -replace ' -- .*$', '' })
    $verdict = if (-not $applied) { 'NOT_APPLIED' } elseif ($unparsed) { 'DID_NOT_PARSE' } elseif ($exit -ne 0 -and $failed.Count) { 'KILLED' } else { 'SURVIVED' }
    '{0,-11} {1}  <- {2}' -f $verdict, $m.Name, (($failed | Select-Object -First 2) -join ' ; ')
}
$results
$notKilled = @($results | Where-Object { $_ -notlike 'KILLED*' })
"MUTATIONS $($mutations.Count), killed $($mutations.Count - $notKilled.Count), not killed $($notKilled.Count)"
if ($notKilled.Count) { exit 1 }
