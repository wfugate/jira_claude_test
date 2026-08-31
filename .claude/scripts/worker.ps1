# worker.ps1 -- extracts the reasoning out of a finished session.
#
# Started detached by hook.ps1, so it outlives the session that triggered it.
# That is deliberate: it makes a Claude call taking 5-10 seconds, and a hook
# that waited for that would be killed mid-flight.
#
# It writes ONLY to a local file. Nothing here touches Jira. Posting happens
# later, from /updatejira, behind an explicit approval step.
#
# A record is written for EVERY session, including ones where nothing was found
# and ones that failed. That is the single most important property here: it
# means "the gate found nothing" is VISIBLE rather than silent, and the
# transcript path is kept so a thin record can be re-examined later. A dropped
# decision then becomes a prompt problem instead of permanent data loss.

param(
    [string] $Transcript = '',   # path to the session's .jsonl, from the hook
    [string] $SessionId  = '',
    [string] $EndReason  = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$NotesDir   = Join-Path (Split-Path -Parent $ScriptDir) 'ticket-notes'
$PromptFile = Join-Path $ScriptDir 'worker_prompt.txt'

. (Join-Path $ScriptDir 'notes.ps1')   # dot-source: load functions, run nothing

$MaxTurnChars = 4000    # one pathological paste should not dominate the prompt
$Script:DroppedCommandTurns = 0   # how many /updatejira expansions were filtered
$MaxTurns     = 60

function Write-Log([string] $Message) {
    # DIAGNOSTICS MUST NEVER COST A RECORD.
    #
    # This log is shared, so concurrent workers contend for it and Add-Content
    # throws "Stream was not readable". With $ErrorActionPreference = 'Stop' and
    # nothing catching it, that killed the worker - and the first Write-Log call
    # happens BEFORE the first Write-SessionRecord, so the session's reasoning
    # was lost entirely, in silence, with the worker detached and its stderr
    # going nowhere.
    #
    # An earlier version of this comment called the interleaving harmless. It was
    # not: measured with four concurrent writers, three died on their first
    # write. Two concurrent writers - what the original test used - collide
    # rarely enough to look fine.
    #
    # The per-session record files cannot collide. This log sat in front of them
    # and undid that.
    try {
        $Line = "[$(Get-Date -Format HH:mm:ss)] $Message"
        Add-Content -LiteralPath (Join-Path $NotesDir 'worker.log') `
                    -Value $Line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Losing a log line is acceptable. Losing the record is not.
    }
}


function Get-UserTurns {
    <#
      Pull the USER's turns out of the transcript, and the source files touched.

      WHY ONLY USER TURNS: measured on real transcripts, user turns are about
      13% of the volume but hold most of the reasoning. Assistant turns are
      ~44% and mostly narrate what was done -- which the diff already shows.

      There is a known cost. Claude sometimes decides something itself that the
      developer tacitly accepts, and that reasoning lives in its turn, so we
      miss it. We accept that deliberately: including assistant turns would
      invent rationales the developer never endorsed and put them on a ticket as
      though they had. Instead such code shows up in the diff with no reasoning
      behind it, and the draft flags it as unexplained. Flagging is honest;
      inventing is not.

      The transcript format is identical between the CLI and the desktop app for
      the record types we read; the types that differ are all ones we drop.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $Turns = New-Object System.Collections.ArrayList
    $Files = @{}

    # ReadLines streams: a long transcript can be several MB and we do not need
    # it all in memory at once.
    foreach ($Line in [IO.File]::ReadLines($Path)) {
        if (-not $Line.Trim()) { continue }
        try { $o = $Line | ConvertFrom-Json } catch { continue }   # skip bad lines

        # Which files were touched, from tool results. Not reasoning, but it
        # tells the draft step which areas changed.
        if ($o.toolUseResult) {
            $fp = $o.toolUseResult.filePath
            if (-not $fp) { $fp = $o.toolUseResult.file_path }
            if ($fp -and (Test-IsSourceFile ([string]$fp))) {
                $Files[[IO.Path]::GetFileName([string]$fp)] = $true
            }
        }

        if ($o.type -ne 'user') { continue }
        if ($o.isSidechain)     { continue }   # a subagent's turns, not the human's

        # message.content is either a bare string or a list of typed blocks.
        # Both shapes appear in real transcripts, so handle both.
        $c = $o.message.content
        if ($c -is [string]) {
            $Text = $c
        } elseif ($c) {
            $Text = (@($c) | Where-Object { $_.type -eq 'text' } |
                     ForEach-Object { $_.text }) -join ' '
        } else { continue }

        if (-not $Text -or -not $Text.Trim()) { continue }

        # Harness noise, not anything a human typed.
        if ($Text -like '*<local-command-caveat>*')  { continue }
        if ($Text.StartsWith('<system-reminder>'))   { continue }

        # A /updatejira invocation expands the whole command file into a user
        # turn. Drop THAT TURN, not the session.
        #
        # This used to discard the entire session, which was a real bug: doing
        # work and then writing it up in the same session is the natural way to
        # use this tool, and the guard threw the work's reasoning away before the
        # gate ever ran. Filtering per turn keeps the work and loses only the
        # command boilerplate -- which would otherwise recycle a previous draft
        # into the next one.
        if (Test-IsCommandExpansion $Text) { $Script:DroppedCommandTurns++; continue }

        $t = $Text.Trim()
        if ($t.Length -gt $MaxTurnChars) { $t = $t.Substring(0, $MaxTurnChars) }
        [void]$Turns.Add($t)
    }

    return @{ Turns = @($Turns); Files = @($Files.Keys | Sort-Object) }
}


function Test-IsCommandExpansion {
    <#
      Is this turn the /updatejira command file being expanded, rather than
      something a human typed?

      Matched on two distinctive phrases from the command body. Both must be
      present, so an ordinary sentence mentioning one of them is not caught.
    #>
    param([string] $Text)

    # THE STRUCTURAL MARKERS FIRST. A slash command produces TWO user turns: a
    # small stub carrying the command name and args, then the expanded prose
    # body. Only the body was matched, so a draft-only session ended with one
    # surviving turn instead of zero -- and the "nothing but the command" branch
    # requires zero. The draft-session guard was therefore unreachable, and every
    # draft run left an ordinary unposted record for the next ticket to pick up.
    #
    # Worse, that stub contains <command-args>TEST-115</command-args>, so the
    # gate could read a confident ticket_hint off a stale draft record - and the
    # command gives an explicit key priority over subject matter. The rule meant
    # to prevent misattribution was promoting the artefact.
    if ($Text -like '*<command-name>*')    { return $true }
    if ($Text -like '*<command-message>*') { return $true }
    if ($Text -like '*<command-args>*')    { return $true }

    # The prose body. Kept, but note it is coupled to two strings in
    # updatejira.md: rename a heading and this silently stops matching. The
    # structural markers above do not have that fragility.
    return ($Text -like '*Update ticket*' -and
            $Text -like '*captured from earlier sessions*')
}


function Test-IsSourceFile {
    <#
      Keep real source; drop everything else.

      Sessions write to Claude's memory store and to our own notes as a side
      effect, and those were turning up in "files touched" as though they were
      part of the change.
    #>
    param([string] $Path)

    $Low = $Path.Replace('\', '/').ToLower()
    if ($Low -like '*/.claude/*') { return $false }
    if ($Low -like '*/memory/*')  { return $false }
    if ([IO.Path]::GetFileName($Low) -in @('memory.md', 'claude.md')) { return $false }
    foreach ($ext in @('.md', '.json', '.jsonl', '.log', '.txt')) {
        if ($Low.EndsWith($ext)) { return $false }
    }
    return $true
}


function Invoke-Gate {
    <#
      Ask Claude what was decided. "The gate" because it also decides whether
      the session held anything worth recording at all.

      Runs headless (`claude -p`). The guard variable is set so the hook does
      not fire recursively when THIS call's session ends.
    #>
    param([Parameter(Mandatory)] [string[]] $Turns)

    # Explicit UTF-8: the default would read this BOM-less file as ANSI and
    # corrupt any non-ASCII character in the prompt itself.
    $Utf8Read = New-Object System.Text.UTF8Encoding($false)
    $Prompt = [IO.File]::ReadAllText($PromptFile, $Utf8Read) +
              ($Turns -join "`n---`n") + "`n</turns>`n"

    $env:UPDATEJIRA_HOOK_GUARD = '1'
    $Started = Get-Date
    $Utf8    = New-Object System.Text.UTF8Encoding($false)

    # ENCODING: go through FILES, not the PowerShell pipeline.
    #
    # PowerShell talks to native programs using the console's OEM codepage
    # (437/850 on Windows), not UTF-8, so every em dash Claude returned arrived
    # as mojibake and was written into the record that way. Setting
    # [Console]::OutputEncoding does not fix it here, because this worker runs
    # detached with no real console attached.
    #
    # Redirecting to files sidesteps the whole problem: Claude writes UTF-8
    # bytes straight to a file handle, PowerShell never re-encodes them, and we
    # read them back with an explicit UTF-8 decoder. Also avoids the Windows
    # command-line length limit, since the prompt is tens of kilobytes.
    $Base    = Join-Path $env:TEMP "updatejira-gate-$PID-$(Get-Random)"
    $InFile  = "$Base.in.txt"
    $OutFile = "$Base.out.txt"
    $ErrFile = "$Base.err.txt"
    $WorkDir = "$Base.cwd"

    # RUN THE GATE OUTSIDE THE REPO. Not cosmetic - this fixes two bugs found in
    # testing, both caused by the gate's own Claude session being filed under
    # this repo:
    #
    #   1. `claude -p --continue` resumed the GATE session instead of the
    #      developer's work session, because the gate's transcript was the more
    #      recent one in the same project folder.
    #   2. A gate session inside the repo loads this repo's
    #      .claude/settings.json, so OUR OWN HOOK fired for it and wrote a
    #      record for it. Those spurious records were only filtered by accident,
    #      because the gate prompt happens to contain the command's phrases.
    #
    # Two things are needed. An empty temp working directory has no .claude, so
    # no hook is registered there. AND CLAUDE_PROJECT_DIR must be cleared:
    # Claude Code files a session under that variable when it is set, IGNORING
    # the process working directory - and we inherit it from the hook, which
    # inherited it from the session that triggered us. -WorkingDirectory alone
    # was verified insufficient for exactly that reason.
    $PrevProjectDir = $env:CLAUDE_PROJECT_DIR

    try {
        [IO.File]::WriteAllText($InFile, $Prompt, $Utf8)
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        $env:CLAUDE_PROJECT_DIR = $null

        $p = Start-Process -FilePath 'claude' -ArgumentList '-p' `
                 -WorkingDirectory $WorkDir `
                 -RedirectStandardInput  $InFile `
                 -RedirectStandardOutput $OutFile `
                 -RedirectStandardError  $ErrFile `
                 -WindowStyle Hidden -PassThru -Wait
        $Code = $p.ExitCode

        $Text = if (Test-Path $OutFile) { [IO.File]::ReadAllText($OutFile, $Utf8) } else { '' }
    } catch {
        return @{ Error = "could not run claude: $($_.Exception.Message)" }
    } finally {
        # Restore: this process may go on to use the variable.
        $env:CLAUDE_PROJECT_DIR = $PrevProjectDir
        foreach ($f in @($InFile, $OutFile, $ErrFile)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path $WorkDir) {
            Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "claude -p rc=$Code in $([int]((Get-Date) - $Started).TotalSeconds)s"
    if ($Code -ne 0) { return @{ Error = "claude -p exited $Code" } }

    $Text = $Text.Trim()

    # Strip a markdown fence if the model wrapped its JSON in one.
    #
    # Handles the single-line case too (```json {...} ```), which the previous
    # split-on-first-newline version left fenced - so the record came back
    # 'unparsed' for a reply that was otherwise perfectly good.
    if ($Text.StartsWith('```')) {
        $Text = $Text.Trim()
        $NL = $Text.IndexOf("`n")
        if ($NL -ge 0 -and $NL -lt 12) {
            $Text = $Text.Substring($NL + 1)      # ```json
{...}
        } else {
            $Text = $Text.TrimStart('`')          # ```json {...} on one line
            if ($Text.StartsWith('json')) { $Text = $Text.Substring(4) }
        }
        $Text = $Text.Trim()
        if ($Text.EndsWith('```')) { $Text = $Text.Substring(0, $Text.Length - 3) }
        $Text = $Text.Trim()
    }

    try   { return @{ Parsed = ($Text | ConvertFrom-Json) } }
    catch { return @{ Raw = $Text } }    # unparseable: keep it for inspection
}


# ========================= main =========================================
# Only run when executed directly. Dot-sourcing loads the functions above and
# nothing else -- the same guard notes.ps1 uses. Without it, any script wanting
# Get-UserTurns for testing would trigger a full capture run as a side effect.
if ($MyInvocation.InvocationName -eq '.') { return }


if (-not (Test-Path $NotesDir)) {
    New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null
}

# Every record carries these, whatever happens next.
$Record = @{
    session_id      = $SessionId
    transcript_path = $Transcript
    ended           = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    end_reason      = $EndReason
    posted          = $false
}

# LAST-RESORT WRITE. "A record is written for every session" was only true as
# long as nothing above the write threw. Anything unanticipated - a transcript
# that cannot be opened, a full disk, a PowerShell edge case - killed the worker
# silently, because it is detached and hidden and the session is already over.
#
# So: register a trap. Any terminating error writes an error record naming the
# failure, then exits. The promise now holds against surprises, not just against
# the failures that were thought of.
trap {
    try {
        $Record.gate  = 'error'
        $Record.error = "worker died: $($_.Exception.Message)"
        if (-not $Record.ContainsKey('turns')) { $Record.turns = 0 }
        Write-SessionRecord -Record $Record | Out-Null
        Write-Log "worker died, wrote an error record: $($_.Exception.Message)"
    } catch {
        # Nothing left to try. Better to exit than to loop.
    }
    exit 0
}

if (-not $Transcript -or -not (Test-Path $Transcript)) {
    Write-Log "no transcript at '$Transcript'"
    $Record.gate = 'error'; $Record.error = 'transcript missing'; $Record.turns = 0
    Write-SessionRecord -Record $Record | Out-Null
    exit 0
}

$Extracted = Get-UserTurns -Path $Transcript
$Turns = $Extracted.Turns
Write-Log "extracted $($Turns.Count) user turns, $($Extracted.Files.Count) files touched"

# Get-UserTurns has already dropped any /updatejira expansions. If that is ALL
# there was, the session only ran the command and there is nothing to record.
# But if real turns survive, this was work-then-write-up and the work must be
# captured -- that is the whole point of filtering per turn rather than skipping
# the session.
if ($Script:DroppedCommandTurns -gt 0) {
    Write-Log "dropped $($Script:DroppedCommandTurns) /updatejira command turn(s); $($Turns.Count) real turn(s) remain"
}
if ($Script:DroppedCommandTurns -gt 0 -and $Turns.Count -eq 0) {
    Write-Log 'nothing but the ticket-update command - recording as empty'
    $Record.gate             = 'skip'
    $Record.turns            = 0
    $Record.skip_reason      = 'NOTHING_TO_RECORD'
    $Record.is_draft_session = $true
    $Record.summary          = 'Ran the ticket-update command; no development decisions made.'
    Write-SessionRecord -Record $Record | Out-Null
    exit 0
}

$Record.turns = $Turns.Count
$Record.files = $Extracted.Files

if ($Turns.Count -eq 0) {
    $Record.gate = 'empty'
    Write-SessionRecord -Record $Record | Out-Null
    exit 0
}

$Result = Invoke-Gate -Turns (@($Turns) | Select-Object -First $MaxTurns)

if ($Result.Error) {
    Write-Log "gate failed: $($Result.Error)"
    $Record.gate = 'error'; $Record.error = $Result.Error
} elseif ($Result.Raw -ne $null) {
    Write-Log 'unparseable output, storing raw'
    $Record.gate = 'unparsed'
    $Record.raw  = $Result.Raw.Substring(0, [Math]::Min(2000, $Result.Raw.Length))
} else {
    $p = $Result.Parsed
    # @() forces a single item to still be an array -- ConvertFrom-Json returns a
    # bare value for one-element JSON arrays, which would otherwise miscount.
    $Record.gate        = if ($p.substantive) { 'captured' } else { 'skip' }
    $Record.ticket_hint = [string]$p.ticket
    $Record.skip_reason = [string]$p.skip_reason
    $Record.summary     = [string]$p.summary
    $Record.decisions   = @($p.decisions)
    $Record.constraints = @($p.constraints)
    $Record.rejected    = @($p.rejected)
    $Record.deferred    = @($p.deferred)
    $Record.item_count  = @($p.decisions).Count + @($p.constraints).Count +
                          @($p.rejected).Count  + @($p.deferred).Count
    Write-Log "gate=$($Record.gate) items=$($Record.item_count)"
}

Write-SessionRecord -Record $Record | Out-Null
exit 0
