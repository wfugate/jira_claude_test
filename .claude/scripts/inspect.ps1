# inspect.ps1 -- show what the hook has captured so far. Read-only.
#
#   inspect.ps1          every record, with its full extracted reasoning
#   inspect.ps1 -Verbose  also show transcript paths and raw gate output
#
# This is the window into the capture half. If something looks wrong in a ticket
# draft, start here: it shows exactly what the gate pulled out of each session,
# which is all the draft step had to work from.
#
# Unlike notes.ps1 -ForDraft, this shows POSTED records too, so you can see the
# history of what went to which ticket.

param([switch] $Verbose)

$ErrorActionPreference = 'Stop'
# Force UTF-8 on our own output. PowerShell writes to a redirected stdout using
# the console codepage, which mangles every em dash -- and this script's output
# is read by /updatejira and lands in a real ticket comment, so mojibake here
# becomes mojibake on the ticket.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'notes.ps1')

# @() at the call site: PowerShell unrolls a single-element array on return, and
# a PS 5.1 scalar has no .Count, so one record would read as zero.
$Records = @(Get-SessionRecords)

if ($Records.Count -eq 0) {
    Write-Output "Nothing captured yet - no records in $Script:Sessions"
    Write-Output 'Have you ended a session in this repo since the hook was installed?'
    exit 0
}

$Bar = '=' * 72
Write-Output $Bar
Write-Output "$($Records.Count) session(s) captured"
Write-Output $Bar

$Tally    = @{}
$TotalItems = 0
$Uncertain  = @()

for ($i = 0; $i -lt $Records.Count; $i++) {
    $r = $Records[$i]
    $n = $i + 1

    $Gate = if ($r.gate) { $r.gate } else { '?' }
    if (-not $Tally.ContainsKey($Gate)) { $Tally[$Gate] = 0 }
    $Tally[$Gate]++

    $Sid   = if ($r.session_id) { "$($r.session_id)".PadRight(8).Substring(0, 8) } else { '????????' }
    $State = if ($r.posted) { "  POSTED to $($r.posted_to)" } else { '' }

    Write-Output ''
    Write-Output "[$n] $Sid   gate=$Gate   turns=$($r.turns)   ended=$($r.ended)$State"
    if ($r.summary) { Write-Output "    summary: $($r.summary)" }

    # DEFERRED is upper-cased on purpose: a deliberately-postponed decision is
    # the item most often lost, and the one worth spotting in a wall of text.
    foreach ($pair in @(@('decisions','decision'), @('constraints','constraint'),
                        @('rejected','rejected'), @('deferred','DEFERRED'))) {
        foreach ($item in @($r.($pair[0]))) {
            if ($item) {
                Write-Output ("    {0} {1}" -f ($pair[1] + ':').PadRight(11), $item)
                $TotalItems++
            }
        }
    }

    if ($r.files)    { Write-Output "    files:      $(@($r.files) -join ', ')" }
    if ($r.error)    { Write-Output "    ERROR:      $($r.error)" }
    if ($Verbose -and $r.raw)             { Write-Output "    raw:        $($r.raw)" }
    if ($Verbose -and $r.transcript_path) { Write-Output "    transcript: $($r.transcript_path)" }

    # Only an UNCERTAIN skip is a possible gap. A confident empty (a bare
    # question, a lookup) is a correct result and must not be reported as one --
    # otherwise the warning fires constantly and stops being read.
    if ($Gate -in @('skip','empty','error','unparsed','corrupt') -and
        $r.skip_reason -ne 'NOTHING_TO_RECORD') {
        $Uncertain += $r
    }
}

Write-Output ''
Write-Output $Bar
Write-Output "gate tally: $(($Tally.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
Write-Output "total captured items: $TotalItems"

if ($Uncertain.Count -gt 0) {
    Write-Output ''
    Write-Output "$($Uncertain.Count) session(s) produced nothing AND the gate was not confident they"
    Write-Output 'were empty. If any held a real decision, that is a false negative -- the'
    Write-Output 'failure that matters, because it cannot be recovered once the session is over.'
    Write-Output 'Tune worker_prompt.txt, then re-score with replay.py.'
    foreach ($r in $Uncertain) {
        Write-Output "   $($r.session_id)  turns=$($r.turns)  $($r.transcript_path)"
    }
}
