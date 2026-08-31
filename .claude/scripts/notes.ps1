# notes.ps1 -- the record store, and the "already posted" watermark.
#
# One JSON file per session, under .claude/ticket-notes/sessions/.
#
# WHY ONE FILE PER SESSION, rather than appending to a single log:
# sessions run concurrently, so several workers can finish in the same instant.
# Concurrent appends to one file can interleave and corrupt a line -- and a
# corrupted line is a session's reasoning lost silently, which is the worst
# failure this tool has. Separate files cannot collide at all. (Observed for
# real: the shared worker.log visibly interleaved while the records stayed
# intact.)
#
# Usage:
#   notes.ps1 -ForDraft                          list unposted records, numbered
#   notes.ps1 -MarkPosted "1,3" -Ticket ABC-12   consume ONLY those records
#
# Dot-source it to get the functions:
#   . "$PSScriptRoot\notes.ps1"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Notes    = Join-Path (Split-Path -Parent $ScriptDir) 'ticket-notes'
$Script:Sessions = Join-Path $Script:Notes 'sessions'

# PowerShell 5.1's Out-File -Encoding utf8 writes a byte-order mark, which
# breaks strict JSON readers. This encoder omits it.
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Force UTF-8 on our own output. PowerShell writes to a redirected stdout using
# the console codepage, which mangles every em dash -- and this script's output
# is read by /updatejira and lands in a real ticket comment, so mojibake here
# becomes mojibake on the ticket.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }


function Write-SessionRecord {
    <#
      Write one record. Two protections:

      - ATOMIC: write to a temp file, then move it into place. A reader never
        sees a half-written file. Move-Item -Force maps to the Win32 MoveFileEx
        with replace-existing, which is atomic on a single volume. (Note:
        [IO.File]::Move has no overwrite overload on .NET Framework, so the
        cmdlet is the right tool here, not the .NET method.)

      - NEVER REGRESS: a session can end more than once -- `claude -p --continue`
        fires the hook after every call, each time for the same session id.
        Later firings see more turns, so overwriting is normally right. But
        workers run detached and can finish out of order, so an earlier, thinner
        result must never replace a fuller one. We compare turn counts. We also
        refuse to touch a record already consumed by a ticket.
    #>
    param([Parameter(Mandatory)] [hashtable] $Record)

    if (-not (Test-Path $Script:Sessions)) {
        New-Item -ItemType Directory -Path $Script:Sessions -Force | Out-Null
    }

    $Name = $Record.session_id
    if (-not $Name) { $Name = "nosid-$PID-$(Get-Random)" }
    $Final = Join-Path $Script:Sessions "$Name.json"

    if (Test-Path $Final) {
        try {
            # Explicit UTF-8. PS 5.1's Get-Content sniffs a BOM and, finding
            # none, falls back to the system ANSI codepage -- which silently
            # corrupts every non-ASCII character in our own BOM-less records.
            $Existing = [IO.File]::ReadAllText($Final, $Script:Utf8NoBom) | ConvertFrom-Json
            if ($Existing.posted) { return $Final }         # already used by a ticket
            $OldTurns = [int]($Existing.turns | ForEach-Object { $_ })
            $NewTurns = [int]$Record.turns
            if ($OldTurns -gt $NewTurns) { return $Final }  # existing is fuller
        } catch {
            # Unreadable existing record: fall through and replace it.
        }
    }

    $Tmp = "$Final.tmp$PID"
    [IO.File]::WriteAllText($Tmp, ($Record | ConvertTo-Json -Depth 6), $Script:Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $Final -Force
    return $Final
}


function Get-SessionRecords {
    <#
      Every record, oldest first.

      An unreadable file is RETURNED as gate="corrupt" rather than skipped.
      Silently dropping a broken record would hide exactly the data loss we
      most need to know about.
    #>
    if (-not (Test-Path $Script:Sessions)) { return @() }

    $Out = @()
    foreach ($f in (Get-ChildItem "$Script:Sessions\*.json" | Sort-Object LastWriteTime)) {
        try {
            # Explicit UTF-8 -- see the note in Write-SessionRecord. Reading
            # our own records with the default encoding mangled every em dash,
            # and that text goes straight into ticket comments.
            $r = [IO.File]::ReadAllText($f.FullName, $Script:Utf8NoBom) | ConvertFrom-Json
            Add-Member -InputObject $r -NotePropertyName '_path' -NotePropertyValue $f.FullName -Force
            $Out += $r
        } catch {
            $Out += [pscustomobject]@{
                _path = $f.FullName; gate = 'corrupt'
                error = "unreadable record: $($_.Exception.Message)"
            }
        }
    }
    return $Out
}


function Get-UnpostedRecords {
    <#
      Records not yet consumed by a ticket.

      Sessions that were themselves /updatejira runs are kept on disk as an
      audit trail but excluded here. They are not work, and listing them would
      put permanent noise in front of every future draft.
    #>
    param([switch] $IncludeDraftSessions)

    $All = Get-SessionRecords | Where-Object { -not $_.posted }
    if (-not $IncludeDraftSessions) {
        $All = $All | Where-Object { -not $_.is_draft_session }
    }
    return @($All)
}


function Set-RecordsPosted {
    <#
      Mark ONLY the given 1-based indices into the unposted list.

      Deliberately not "mark everything". Several tickets get worked in one
      repo, so consuming all unposted records would attribute one ticket's
      reasoning to another AND consume records that belonged elsewhere. The
      caller must say which.
    #>
    param([Parameter(Mandatory)] [int[]] $Indices,
          [string] $Ticket = '')

    $Recs = @(Get-UnpostedRecords)     # see the note in Show-DraftFeed
    $Bad  = $Indices | Where-Object { $_ -lt 1 -or $_ -gt $Recs.Count }
    if ($Bad) {
        throw "No such session(s): $($Bad -join ', ') (there are $($Recs.Count) unposted)"
    }

    $Done = @()
    foreach ($i in $Indices) {
        $r = $Recs[$i - 1]
        if ($r.gate -eq 'corrupt') { continue }

        # Rebuild as a hashtable so Write-SessionRecord can serialise it, and so
        # the internal _path field does not leak into the file.
        $h = @{}
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -ne '_path') { $h[$p.Name] = $p.Value }
        }
        $h['posted']    = $true
        $h['posted_to'] = $Ticket
        $h['posted_at'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

        # Bypass the no-regress check: we are deliberately updating in place.
        $Tmp = "$($r._path).tmp$PID"
        [IO.File]::WriteAllText($Tmp, ($h | ConvertTo-Json -Depth 6), $Script:Utf8NoBom)
        Move-Item -LiteralPath $Tmp -Destination $r._path -Force
        $Done += $i
    }
    return $Done
}


function Show-DraftFeed {
    <#
      What /updatejira reads: unposted records, numbered for selection.

      Only extracted reasoning is printed -- never raw transcript content.
    #>
    # @() at the CALL SITE, not in the function. PowerShell unrolls a
    # single-element array on return, so a lone record arrives as a bare object
    # -- and in PS 5.1 a scalar has no .Count, which silently read as empty.
    $Recs = @(Get-UnpostedRecords)
    if ($Recs.Count -eq 0) { Write-Output '(no unposted sessions captured)'; return }

    Write-Output "$($Recs.Count) unposted session(s). Numbers are for selection at post time."
    Write-Output ''

    $Blank = 0
    $Hints = @{}
    for ($i = 0; $i -lt $Recs.Count; $i++) {
        $r = $Recs[$i]
        $n = $i + 1

        $HintText = ''
        if ($r.ticket_hint) {
            $Hints[$r.ticket_hint] = $true
            $HintText = "   ticket named in session: $($r.ticket_hint)"
        }
        Write-Output "[$n] ended $($r.ended), $($r.turns) user turns$HintText"
        if ($r.summary) { Write-Output "    summary: $($r.summary)" }

        foreach ($pair in @(@('decisions','DECISION'), @('constraints','CONSTRAINT'),
                            @('rejected','REJECTED'), @('deferred','DEFERRED'))) {
            foreach ($item in @($r.($pair[0]))) {
                if ($item) { Write-Output "    $($pair[1]): $item" }
            }
        }

        if ($r.gate -in @('skip','empty','error','unparsed','corrupt')) {
            # A confident empty is not a gap. Only an uncertain one is.
            if ($r.skip_reason -eq 'NOTHING_TO_RECORD') {
                Write-Output '    (nothing to record - the gate read this and found no decision. Not a gap.)'
            } else {
                $Blank++
                Write-Output "    NOTE: nothing extracted, and the gate was NOT confident it was empty (gate=$($r.gate)$(if($r.skip_reason){", $($r.skip_reason)"}))."
                if ($r.transcript_path) { Write-Output "          transcript available: $($r.transcript_path)" }
            }
        }
        if ($r.files) { Write-Output "    files touched: $(@($r.files) -join ', ')" }
        Write-Output ''
    }

    if ($Hints.Keys.Count -gt 1) {
        Write-Output "CAUTION: these sessions name more than one ticket ($(($Hints.Keys | Sort-Object) -join ', '))."
        Write-Output 'They do NOT all belong to the same update. Select carefully.'
        Write-Output ''
    }
    if ($Blank -gt 0) {
        Write-Output "WARNING: $Blank of $($Recs.Count) sessions produced nothing AND the gate was not"
        Write-Output 'confident they were empty. Those may be missing real decisions,'
        Write-Output 'so any draft is possibly INCOMPLETE - say so.'
        Write-Output '(Sessions the gate confidently found empty are not counted.)'
    }
}


# --- Command line --------------------------------------------------------
# Only acts when run directly. Dot-sourcing just loads the functions above.
if ($MyInvocation.InvocationName -ne '.') {
    if ($args -contains '-MarkPosted' -or $args -contains '--mark-posted') {
        $idx = [array]::IndexOf($args, ($args | Where-Object { $_ -match '^-{1,2}[Mm]ark' } | Select-Object -First 1))
        $Selection = if ($idx -ge 0 -and $idx + 1 -lt $args.Count) { $args[$idx + 1] } else { $null }
        $Ticket    = if ($idx + 2 -lt $args.Count) { $args[$idx + 2] } else { '' }

        if (-not $Selection -or $Selection -notmatch '\d') {
            $n = @(Get-UnpostedRecords).Count
            Write-Output "Refusing to mark anything without a selection."
            Write-Output "There are $n unposted session(s). Pass the ones belonging to this ticket:"
            Write-Output '    notes.ps1 -MarkPosted "1,3" -Ticket TICKET-KEY'
            exit 1
        }
        $Indices = @($Selection -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
        $Done    = Set-RecordsPosted -Indices $Indices -Ticket $Ticket
        Write-Output "Marked $($Done.Count) session(s) as posted$(if($Ticket){" to $Ticket"}): $($Done -join ', ')"
        $Left = @(Get-UnpostedRecords).Count
        if ($Left -gt 0) {
            Write-Output "$Left session(s) still unposted - they stay available for another ticket."
        }
    } else {
        Show-DraftFeed
    }
}
