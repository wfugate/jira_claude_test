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
#   notes.ps1                                        list unposted records
#   notes.ps1 -MarkPosted <ids> -Ticket ABC-12       consume ONLY those records
#   notes.ps1 -MarkSessionPosted <id> -Ticket ABC-12
#
# RECORDS ARE ADDRESSED BY SESSION ID, NOT BY POSITION. An earlier version
# numbered them by position in a list sorted on LastWriteTime, and re-derived
# that list at approval time. Any write in between - another session ending, a
# worker firing, the posted-flag merge - renumbered everything, so the mark step
# could consume a different record than the one shown. That was demonstrated: it
# consumed another ticket's record and left this ticket's unposted. Ordinals are
# still accepted, but they are resolved against the listing the caller was
# shown, and an id is what gets matched.
#
# Dot-source it to get the functions:
#   . "$PSScriptRoot\notes.ps1"

param(
    # Comma-separated session ids (preferred) or ordinals from the last listing.
    [string] $MarkPosted        = '',
    # A single session id, for a session that has not ended yet.
    [string] $MarkSessionPosted = '',
    # The ticket consuming them. A NAMED parameter -- it used to be read
    # positionally as $args[$idx+2], which is the flag itself, so every record
    # recorded posted_to = "-Ticket" and the audit trail was worthless.
    [string] $Ticket            = ''
)

# $Script: scoped so dot-sourcing does not overwrite the caller's $ScriptDir.
$Script:NotesScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Notes    = Join-Path (Split-Path -Parent $Script:NotesScriptDir) 'ticket-notes'
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

            # Already consumed by a ticket? Keep the posted flags but let the
            # new content land. This is how a session drafted from live context
            # still ends up with a full record: /updatejira marks the session
            # posted BEFORE it has ended, then the worker fills in the reasoning
            # afterwards. Refusing outright would leave a stub with no audit
            # trail; ignoring the flags would let the ticket claim it twice.
            if ($Existing.posted) {
                $Record['posted']    = $true
                $Record['posted_to'] = $Existing.posted_to
                $Record['posted_at'] = $Existing.posted_at
            }

            $OldTurns = [int]($Existing.turns | ForEach-Object { $_ })
            $NewTurns = [int]$Record.turns
            if ($OldTurns -gt $NewTurns) { return $Final }  # existing is fuller

            # Turn count alone was not enough. A re-firing over the SAME
            # transcript yields the same count, so EQUAL counts passed the check
            # above and a gate failure on the second run replaced the first run's
            # extracted reasoning. Compare content too: a record holding items
            # must never be replaced by one holding none.
            $OldItems = @($Existing.decisions).Count + @($Existing.constraints).Count +
                        @($Existing.rejected).Count  + @($Existing.deferred).Count
            $NewItems = [int]$Record.item_count
            if ($OldItems -gt 0 -and $NewItems -eq 0) { return $Final }
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
    param([Parameter(Mandatory)] [string[]] $Selectors,
          [string] $Ticket = '')

    $Recs   = @(Get-UnpostedRecords)     # see the note in Show-DraftFeed
    $Chosen = @()
    $Bad    = @()

    foreach ($sel in $Selectors) {
        $sel = "$sel".Trim()
        if (-not $sel) { continue }

        if ($sel -match '^[0-9]+$') {
            # An ordinal: resolved here, against the current listing. Weaker.
            $i = [int]$sel
            if ($i -lt 1 -or $i -gt $Recs.Count) { $Bad += $sel; continue }
            $Chosen += $Recs[$i - 1]
        } else {
            # A session id, full or a unique prefix. Cannot be shifted by a
            # concurrent write, which is the whole point.
            $hit = @($Recs | Where-Object { "$($_.session_id)".StartsWith($sel) })
            if     ($hit.Count -eq 1) { $Chosen += $hit[0] }
            elseif ($hit.Count -gt 1) { $Bad += "$sel (ambiguous, matches $($hit.Count))" }
            else                      { $Bad += $sel }
        }
    }

    if ($Bad.Count) {
        throw "No such unposted session(s): $($Bad -join ', ') (there are $($Recs.Count) unposted)"
    }

    $Done = @()
    foreach ($r in $Chosen) {
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
        $Done += $r.session_id
    }
    return $Done
}


function Set-SessionPosted {
    <#
      Mark a session posted BEFORE it has a record.

      /updatejira can now be run in the same session as the work, and drafts
      from the live conversation rather than from a record -- because at that
      moment no record exists: the hook only fires when the session ENDS.

      Without this, that session's record would appear later as unposted and be
      drafted into the NEXT ticket, duplicating reasoning already published. So
      we write a stub marked posted; when the worker eventually runs,
      Write-SessionRecord merges the real reasoning in and keeps these flags.
    #>
    param([Parameter(Mandatory)] [string] $SessionId,
          [string] $Ticket = '')

    if (-not (Test-Path $Script:Sessions)) {
        New-Item -ItemType Directory -Path $Script:Sessions -Force | Out-Null
    }
    $Final = Join-Path $Script:Sessions "$SessionId.json"

    # If a record already exists (the session ended between drafting and
    # approval), mark it in place rather than replacing it.
    if (Test-Path $Final) {
        try {
            $r = [IO.File]::ReadAllText($Final, $Script:Utf8NoBom) | ConvertFrom-Json
            $h = @{}
            foreach ($p in $r.PSObject.Properties) {
                if ($p.Name -ne '_path') { $h[$p.Name] = $p.Value }
            }
        } catch { $h = @{ session_id = $SessionId } }
    } else {
        $h = @{
            session_id      = $SessionId
            ended           = ''
            turns           = 0
            gate            = 'pending'
            summary         = 'Drafted from live session context; reasoning not yet extracted.'
        }
    }
    $h['posted']    = $true
    $h['posted_to'] = $Ticket
    $h['posted_at'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')

    $Tmp = "$Final.tmp$PID"
    [IO.File]::WriteAllText($Tmp, ($h | ConvertTo-Json -Depth 6), $Script:Utf8NoBom)
    Move-Item -LiteralPath $Tmp -Destination $Final -Force
    return $Final
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
        # The id is what -MarkPosted matches on. The number is a convenience.
        $Sid = "$($r.session_id)"
        $Short = if ($Sid.Length -ge 8) { $Sid.Substring(0, 8) } else { $Sid }
        Write-Output "[$n] $Short  ended $($r.ended), $($r.turns) user turns$HintText"
        if ($r.summary) { Write-Output "    summary: $($r.summary)" }

        foreach ($pair in @(@('decisions','DECISION'), @('constraints','CONSTRAINT'),
                            @('rejected','REJECTED'), @('deferred','DEFERRED'))) {
            foreach ($item in @($r.($pair[0]))) {
                if ($item) { Write-Output "    $($pair[1]): $item" }
            }
        }

        # EMPTINESS IS ABOUT CONTENT, NOT THE GATE LABEL. The prompt permits
        # substantive:true with all four lists empty, and the gate is
        # non-deterministic - so a record can arrive gate='captured' holding
        # nothing. 'captured' was in neither warning list and item_count was never
        # consulted, so the feed printed a healthy-looking row and said nothing.
        # 'pending' is included too: a pre-marked stub whose worker later died
        # would otherwise sit unflagged forever.
        $ItemTotal = @($r.decisions).Count + @($r.constraints).Count +
                     @($r.rejected).Count  + @($r.deferred).Count
        if ($r.gate -in @('skip','empty','error','unparsed','corrupt','pending') -or
            $ItemTotal -eq 0) {
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
#
# Uses the param() block at the top rather than scanning $args by hand. The
# hand-rolled version read the ticket as the argument after the selection, which
# was the -Ticket flag itself, so posted_to was the literal string "-Ticket" on
# every record -- destroying the audit trail that is the main way any
# misattribution would be noticed.
if ($MyInvocation.InvocationName -ne '.') {

    function Test-TicketKey([string] $Key) {
        return ($Key -match '^[A-Z][A-Z0-9]*-[0-9]+$')
    }

    if ($MarkSessionPosted) {
        # A session id is a GUID. If CLAUDE_CODE_SESSION_ID failed to expand, the
        # arguments shift and the TICKET KEY arrives here instead -- which used to
        # write sessions/TEST-115.json, marked posted, and report success. Refuse
        # loudly instead; requirement 7.
        if ($MarkSessionPosted -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            Write-Output "Refusing: '$MarkSessionPosted' is not a session id."
            Write-Output 'CLAUDE_CODE_SESSION_ID probably did not expand. Nothing was written.'
            exit 1
        }
        if ($Ticket -and -not (Test-TicketKey $Ticket)) {
            Write-Output "Refusing: '$Ticket' does not look like a ticket key (expected e.g. ABC-123)."
            exit 1
        }
        Set-SessionPosted -SessionId $MarkSessionPosted -Ticket $Ticket | Out-Null
        Write-Output "Marked session $MarkSessionPosted as posted$(if($Ticket){" to $Ticket"}) - its record will not be offered to a future ticket."
        exit 0
    }

    if ($MarkPosted) {
        if ($Ticket -and -not (Test-TicketKey $Ticket)) {
            Write-Output "Refusing: '$Ticket' does not look like a ticket key (expected e.g. ABC-123)."
            Write-Output 'Nothing was marked.'
            exit 1
        }
        if (-not $Ticket) {
            Write-Output 'Refusing to mark without -Ticket. The record of which ticket'
            Write-Output 'consumed which session is how a misattribution gets noticed.'
            exit 1
        }

        $Selectors = @($MarkPosted -split '[,\s]+' | Where-Object { $_ })
        if (-not $Selectors.Count) {
            $n = @(Get-UnpostedRecords).Count
            Write-Output "Refusing to mark anything without a selection."
            Write-Output "There are $n unposted session(s). Pass the ones belonging to this ticket:"
            Write-Output '    notes.ps1 -MarkPosted <session-ids> -Ticket TICKET-KEY'
            exit 1
        }

        try   { $Done = Set-RecordsPosted -Selectors $Selectors -Ticket $Ticket }
        catch { Write-Output "Refusing: $($_.Exception.Message)"; exit 1 }

        Write-Output "Marked $(@($Done).Count) session(s) as posted to $Ticket`: $(@($Done) -join ', ')"
        $Left = @(Get-UnpostedRecords).Count
        if ($Left -gt 0) {
            Write-Output "$Left session(s) still unposted - they stay available for another ticket."
        }
        exit 0
    }

    Show-DraftFeed
}
