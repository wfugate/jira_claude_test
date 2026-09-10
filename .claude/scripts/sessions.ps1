# sessions.ps1 -- find and read Claude Code session transcripts for this repo.
#
# This replaces the hook-and-records half of the tool. There is nothing to
# register, nothing runs in the background, and no state is written anywhere:
# the transcripts Claude Code already keeps ARE the record.
#
#   sessions.ps1 -Key TEST-117 [-Since 2026-08-28] [-ExcludeSession <id>]
#       Sessions whose conversation mentions that ticket key, newest last.
#
#   sessions.ps1 -Extract "abc12345,def67890"
#       The conversation from those sessions, as data for the draft step. Each
#       turn is tagged [DEVELOPER said] or [CLAUDE proposed...] -- the two carry
#       different weight and the draft must not conflate them.
#
#   sessions.ps1 -List [-Limit 20]
#       Every recent session in this repo, labelled, for when no key was stated.
#
# WHY THIS WORKS WHERE THE HOOK DID NOT: a SessionEnd hook does not fire when
# the desktop app is closed with X or when switching chats, which are the two
# ways people actually leave a chat. Transcripts are written continuously and
# survive that -- verified also across compaction and interrupted responses.

param(
    [string] $Key             = '',
    [string] $Extract         = '',
    [switch] $List,
    [string] $Since           = '',
    [string] $ExcludeSession  = '',
    [int]    $Limit           = 20
)

$ErrorActionPreference = 'Stop'

# Our output feeds the draft and can land in a real ticket comment, so mojibake
# here becomes mojibake on the ticket. PowerShell writes to a redirected stdout
# using the console codepage unless told otherwise.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$MaxTurnChars      = 4000   # one developer turn; long pastes are not reasoning
$MaxAssistantChars = 2000   # tighter: assistant turns are ~44% of transcript
                            # volume and much of it narrates what the diff
                            # already shows
$MaxSessions    = 8       # past this, say so rather than silently truncating
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot       = Split-Path -Parent (Split-Path -Parent $ScriptDir)


function Get-ProjectTranscripts {
    <#
      Every transcript belonging to this repo.

      Claude Code stores them under ~/.claude/projects/<mangled-cwd>/. The
      mangling is undocumented, so it is used only as a fast glob and never
      trusted: each candidate is confirmed against the `cwd` field inside its
      own records, which is authoritative.

      The trailing wildcard matters. A session started in a subdirectory gets
      its own project directory -- C--demo-lending-multi--claude-scripts exists
      in practice -- and that work belongs to this repo too.
    #>
    $Mangled = $RepoRoot -replace '[:\\/.]', '-'
    $Base    = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $Base)) { return @() }

    $Found = New-Object System.Collections.ArrayList

    foreach ($Dir in @(Get-ChildItem -Path $Base -Directory -Filter "$Mangled*" -ErrorAction SilentlyContinue)) {
        foreach ($F in @(Get-ChildItem -Path $Dir.FullName -Filter '*.jsonl' -ErrorAction SilentlyContinue)) {
            $Cwd = Get-TranscriptCwd -Path $F.FullName
            # No cwd at all: keep it. The glob matched, and dropping a session
            # because one field is missing loses reasoning silently.
            if ($Cwd -and -not $Cwd.ToLower().StartsWith($RepoRoot.ToLower())) { continue }
            [void]$Found.Add($F)
        }
    }
    return @($Found)
}


function Get-TranscriptCwd {
    # First cwd seen. Read only the head of the file: this runs per candidate.
    param([Parameter(Mandatory)] [string] $Path)

    $n = 0
    foreach ($Line in [IO.File]::ReadLines($Path)) {
        if ($n++ -gt 40) { break }
        if (-not $Line.Trim()) { continue }
        try { $o = $Line | ConvertFrom-Json } catch { continue }
        if ($o.cwd) { return [string]$o.cwd }
    }
    return ''
}


function Test-IsCommandExpansion {
    <#
      Is this turn a slash command being expanded, rather than something a
      human typed?

      Critical: without this, running /updatejira feeds the PREVIOUS draft back
      into the next one, manufacturing reasoning nobody gave.

      A FALLBACK, NOT THE MECHANISM. The real filter is the isMeta check in
      Get-UserTurns: the harness flags its own content structurally, and that is
      what should be trusted.

      This exists only for transcripts where the flag is absent. Measured across
      every transcript on this machine, 40 command-body records lack isMeta --
      but 36 of those are tool_result records that carry no text block and are
      already dropped. Four bare-string records genuinely need what is below.

      Content matching is fragile by nature: it is coupled to phrases in a file
      that gets edited. That is tolerable for a backstop covering four old
      records and would not be tolerable as the primary defence, which is what
      it briefly was.
    #>
    param([string] $Text)

    # The command stub, which carries the name and args.
    if ($Text -like '*<command-name>*')            { return $true }
    if ($Text -like '*<command-message>*')         { return $true }
    if ($Text -like '*<command-args>*')            { return $true }

    # The sentinel in the current command file. Covers renames of everything else.
    if ($Text -like '*UPDATEJIRA-COMMAND-BODY*')   { return $true }

    # Frontmatter only a command file has.
    if ($Text -like '*disable-model-invocation*')  { return $true }

    # Older command bodies. Two phrases required together, so an ordinary
    # sentence mentioning one of them is not caught.
    if ($Text -like '*Update ticket*' -and $Text -like '*vcs.ps1*') { return $true }
    if ($Text -like '*captured from earlier sessions*')             { return $true }

    return $false
}


function Test-IsSourceFile {
    # Keep real source; drop our own files and Claude's memory store, which
    # otherwise appear as though they were part of the change.
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


function Get-SessionTurns {
    <#
      The conversation's turns, tagged by who said what, plus source files
      touched.

      WHY ASSISTANT TURNS ARE INCLUDED. They used to be dropped outright, on the
      grounds that using them would invent rationales the developer never
      endorsed. That is right for one case and wrong for another:

        * Claude did something unprompted and nobody discussed it -> flagging it
          as unexplained is honest, and still happens.
        * Claude explained a change and the developer said "do that" -> the
          reasoning exists and was accepted. Dropping it made the draft assert
          "nothing accounts for this" about a change that had been explained in
          full. That is a false negative on a permanent record, and worse than a
          gap, because it manufactures a mystery and asks the reader to chase it.

      So the fix is attribution, not exclusion. Every turn carries a Role, and
      the draft step is required to render an assistant turn as something
      proposed and not contradicted -- never as the developer's stated reason.

      THE GUARD. A previous /updatejira draft is stored as an ordinary assistant
      text block. isMeta and Test-IsCommandExpansion protect only the user slot,
      so turning assistant capture on without an equivalent guard would make
      every draft ingest the last one -- the recycling bug returning through an
      unwatched door.

      The guard is POSITIONAL, which is stronger than matching the draft's
      wording: everything before the command expansion is work, everything after
      it is drafting. Once a /updatejira expansion is seen, later assistant
      turns are dropped. A content check on the draft's own format follows as a
      backstop.

      KNOWN COST of the positional rule: in a session that ran the command and
      then did more work, that later work's assistant turns are lost. It fails
      toward saying too little rather than toward inventing, which is the right
      direction, and the developer's own turns are unaffected.
    #>
    param([Parameter(Mandatory)] [string] $Path,
          [switch] $DeveloperOnly)

    $Turns = New-Object System.Collections.ArrayList
    $Files = @{}
    $SeenCommand = $false

    foreach ($Line in [IO.File]::ReadLines($Path)) {
        if (-not $Line.Trim()) { continue }
        try { $o = $Line | ConvertFrom-Json } catch { continue }

        if ($o.toolUseResult) {
            $fp = $o.toolUseResult.filePath
            if (-not $fp) { $fp = $o.toolUseResult.file_path }
            if ($fp -and (Test-IsSourceFile ([string]$fp))) {
                $Files[[IO.Path]::GetFileName([string]$fp)] = $true
            }
        }

        if ($o.isSidechain) { continue }   # a subagent's turns, not this conversation

        $Role = switch ([string]$o.type) {
            'user'      { 'developer' }
            'assistant' { 'claude' }
            default     { '' }
        }
        if (-not $Role) { continue }
        if ($Role -eq 'claude' -and $DeveloperOnly) { continue }

        # The harness writes its own content into the user slot and flags it.
        if ($Role -eq 'developer' -and ($o.isMeta -or $o.turnCompanion)) { continue }

        # message.content is a bare string or a list of typed blocks. Only text
        # blocks are wanted -- tool_use and tool_result carry no reasoning.
        $c = $o.message.content
        if ($c -is [string]) {
            $Text = $c
        } elseif ($c) {
            $Text = (@($c) | Where-Object { $_.type -eq 'text' } |
                     ForEach-Object { $_.text }) -join ' '
        } else { continue }

        if (-not $Text -or -not $Text.Trim()) { continue }

        if ($Role -eq 'developer') {
            if ($Text.StartsWith('<system-reminder>'))   { continue }
            if ($Text -like '*<local-command-caveat>*')  { continue }
            if ($Text -like '*<local-command-stderr>*')  { continue }
            if ($Text -like '*<local-command-stdout>*')  { continue }

            if (Test-IsCommandExpansion $Text) {
                # Everything after this point in the session is drafting, not
                # work. Drop the expansion itself and gate later claude turns.
                $SeenCommand = $true
                continue
            }
        }
        else {
            if ($SeenCommand)                { continue }   # positional guard
            if (Test-IsDraftOutput $Text)     { continue }   # backstop
        }

        $Cap = if ($Role -eq 'developer') { $MaxTurnChars } else { $MaxAssistantChars }
        $t = $Text.Trim()
        if ($t.Length -gt $Cap) { $t = $t.Substring(0, $Cap) + ' [...truncated]' }

        [void]$Turns.Add([pscustomobject]@{ Role = $Role; Text = $t })
    }

    return @{ Turns = @($Turns); Files = @($Files.Keys | Sort-Object) }
}


function Test-IsDraftOutput {
    <#
      Does this assistant text look like a previous /updatejira draft?

      A BACKSTOP ONLY. The positional guard in Get-SessionTurns is the real
      protection; this covers a draft that somehow appears before the command
      expansion in the transcript, or one pasted in by hand.

      Requires three of the format's labels together, so ordinary prose that
      happens to say "Why:" is not caught.
    #>
    param([string] $Text)

    $Hits = 0
    foreach ($Label in @('Why:', 'Type:', 'Areas:', 'Root cause:',
                         'Also in this diff:', 'Coverage limited:')) {
        if ($Text -like "*$Label*") { $Hits++ }
    }
    return ($Hits -ge 3)
}


function Test-KeyStatedByHuman {
    <#
      Did the DEVELOPER state this key, or does it merely appear in the file?

      This distinction is the whole attribution mechanism, and getting it wrong
      makes the tool useless in both directions. A raw file match is not good
      enough: a ticket key turns up in tool output, in pasted text, in a command
      stub, in a previous draft. Measured on this repo, nine sessions "matched"
      TEST-117 on a raw grep and not one of them had a human say it -- every hit
      was inside a tool_result.

      So: match only in the human turns, after the same isMeta / isSidechain /
      noise filtering that Get-UserTurns applies.

      A cheap raw pre-check runs first purely to reject non-candidates fast,
      because parsing every line of every transcript is not free.
    #>
    param([Parameter(Mandatory)] [string] $Path,
          [Parameter(Mandatory)] [string] $Key)

    if (-not (Select-String -Path $Path -SimpleMatch -Pattern $Key -Quiet -ErrorAction SilentlyContinue)) {
        return $false
    }

    $r = Get-SessionTurns -Path $Path -DeveloperOnly
    foreach ($t in @($r.Turns)) {
        if ($t.Text -like "*$Key*") { return $true }
    }
    return $false
}


function Get-Label {
    # What a human needs to recognise a session: when, how big, what it touched,
    # and the first thing they actually said. aiTitle is not usable -- measured
    # on real sessions, three of four came back identical because they opened
    # with the same prompt.
    param([Parameter(Mandatory)] $File)

    $r     = Get-SessionTurns -Path $File.FullName -DeveloperOnly
    $First = if (@($r.Turns).Count) { ($r.Turns[0].Text -replace '\s+', ' ') } else { '(no developer turns)' }
    if ($First.Length -gt 100) { $First = $First.Substring(0, 100) + '...' }

    return @{
        Id    = $File.BaseName
        Short = $File.BaseName.Substring(0, 8)
        When  = $File.LastWriteTime
        Turns = @($r.Turns).Count
        Files = @($r.Files)
        First = $First
    }
}


# ========================= main =========================================

if ($MyInvocation.InvocationName -eq '.') { return }

$SinceDate = $null
if ($Since) {
    try { $SinceDate = [datetime]::Parse($Since) }
    catch { Write-Output "!! -Since '$Since' is not a date I can read. Ignoring it and taking everything."; $SinceDate = $null }
}

# ---- extract: the reasoning itself ------------------------------------
if ($Extract) {
    $Ids = @($Extract -split '[,\s]+' | Where-Object { $_ })
    if (-not $Ids.Count) { Write-Output '!! -Extract needs at least one session id.'; exit 1 }

    $All = @(Get-ProjectTranscripts)
    $Hit = 0

    foreach ($Id in $Ids) {
        $F = @($All | Where-Object { $_.BaseName -like "$Id*" })
        if (-not $F.Count) {
            Write-Output "!! no transcript in this repo matches session '$Id' - it may have aged out of the ~30 day retention window."
            continue
        }
        if ($F.Count -gt 1) {
            Write-Output "!! '$Id' matches $($F.Count) sessions. Use more characters of the id."
            continue
        }

        $r = Get-SessionTurns -Path $F[0].FullName
        $Hit++

        $Dev = @($r.Turns | Where-Object { $_.Role -eq 'developer' }).Count
        $Cla = @($r.Turns | Where-Object { $_.Role -eq 'claude' }).Count

        Write-Output ''
        Write-Output "===== SESSION $($F[0].BaseName.Substring(0,8))  ended $($F[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $Dev developer turn(s), $Cla claude turn(s) ====="
        if (@($r.Files).Count) { Write-Output "files touched: $(@($r.Files) -join ', ')" }

        # Each turn is tagged, because the two carry different weight. A
        # DEVELOPER turn is a stated reason. A CLAUDE turn is a proposal the
        # developer did not contradict -- usable, but it must be described that
        # way and never presented as what the developer said.
        $Tagged = @($r.Turns | ForEach-Object {
            if ($_.Role -eq 'developer') { "[DEVELOPER said]`n$($_.Text)" }
            else { "[CLAUDE proposed, not contradicted by the developer]`n$($_.Text)" }
        })

        Write-Output '<turns>'
        Write-Output ($Tagged -join "`n---`n")
        Write-Output '</turns>'
    }

    Write-Output ''
    Write-Output "($Hit of $($Ids.Count) requested session(s) read)"
    exit 0
}

# ---- list: for when no key was ever stated ----------------------------
if ($List) {
    $All = @(Get-ProjectTranscripts | Sort-Object LastWriteTime -Descending)
    if ($SinceDate) { $All = @($All | Where-Object { $_.LastWriteTime -gt $SinceDate }) }
    if (-not $All.Count) { Write-Output 'No session transcripts found for this repo.'; exit 0 }

    $Show = @($All | Select-Object -First $Limit)
    Write-Output "$($All.Count) session(s) for this repo. Showing $($Show.Count), newest first."
    Write-Output ''

    $n = 0
    foreach ($F in $Show) {
        $n++
        $L = Get-Label -File $F
        if ($L.Id -eq $ExcludeSession) { continue }
        Write-Output "$n. [$($L.Short)]  $($L.When.ToString('yyyy-MM-dd HH:mm'))  $($L.Turns) turns"
        if (@($L.Files).Count) { Write-Output "     files: $(@($L.Files) -join ', ')" }
        Write-Output "     first: $($L.First)"
    }

    if ($All.Count -gt $Show.Count) {
        Write-Output ''
        Write-Output "($($All.Count - $Show.Count) older session(s) not shown - raise -Limit to see them)"
    }
    exit 0
}

# ---- key lookup: the normal path -------------------------------------
if (-not $Key) {
    Write-Output 'Usage: sessions.ps1 -Key TICKET-123 [-Since <date>] | -Extract <ids> | -List'
    exit 1
}

$All = @(Get-ProjectTranscripts)
if (-not $All.Count) {
    Write-Output 'No session transcripts found for this repo.'
    Write-Output 'Nothing to draft from. Either no work happened here, or the transcripts have aged out.'
    exit 0
}

$Considered = @($All)
if ($SinceDate) {
    $Considered = @($All | Where-Object { $_.LastWriteTime -gt $SinceDate })
    Write-Output "Window: sessions modified after $($SinceDate.ToString('yyyy-MM-dd HH:mm')) ($($Considered.Count) of $($All.Count))."
} else {
    Write-Output "Window: all $($All.Count) session(s) - no previous change-log entry to bound it."
}

# A LITERAL match, deliberately not a pattern. A generic [A-Z]+-[0-9]+ also
# matches UTF-8, UTF-16 and Z0-9, all of which occur in real transcripts.
#
# And only where a HUMAN said it -- see Test-KeyStatedByHuman. Matching the raw
# file instead produced nine false positives on this repo and zero true ones.
$Matched   = New-Object System.Collections.ArrayList
$Unmatched = New-Object System.Collections.ArrayList
foreach ($F in @($Considered | Sort-Object LastWriteTime)) {
    if ($F.BaseName -eq $ExcludeSession) { continue }   # live context is richer
    if (Test-KeyStatedByHuman -Path $F.FullName -Key $Key) {
        [void]$Matched.Add($F)
    } else {
        [void]$Unmatched.Add($F)
    }
}
$Unmatched = @($Unmatched)

$Matched = @($Matched)
Write-Output ''

if (-not $Matched.Count) {
    # BE PRECISE ABOUT WHICH "nothing" THIS IS. Saying "the key was never stated
    # here" when only a handful of in-window sessions were tested is a false
    # statement about the whole repo, and it reads as "there is nothing to find"
    # when the truth may be "everything was already written up".
    if ($SinceDate) {
        Write-Output "No session modified after $($SinceDate.ToString('yyyy-MM-dd HH:mm')) mentions $Key."
        Write-Output "Only $($Considered.Count) of $($All.Count) session(s) were in that window - the rest predate the last write-up."
        Write-Output ''
        Write-Output 'The usual meaning is that this ticket has already been written up and'
        Write-Output 'nothing new has happened since. That is a normal result, not a failure.'
        Write-Output ''
        Write-Output 'It does NOT establish that the key was never stated in this repo. To look'
        Write-Output 'behind the watermark, re-run without -Since, or use -List and pick by hand.'
    } else {
        Write-Output "No session in this repo mentions $Key, across all $($All.Count) session(s)."
        Write-Output ''
        Write-Output 'The key was never stated in a conversation here. Either the work happened'
        Write-Output 'before this was set up, or nobody was asked for the ticket. Run with -List'
        Write-Output 'and choose the sessions by hand - do not guess.'
    }
    exit 0
}

Write-Output "$($Matched.Count) session(s) mention $Key`:"
Write-Output ''
foreach ($F in $Matched) {
    $L = Get-Label -File $F
    Write-Output "  [$($L.Short)]  $($L.When.ToString('yyyy-MM-dd HH:mm'))  $($L.Turns) turns"
    if (@($L.Files).Count) { Write-Output "      files: $(@($L.Files) -join ', ')" }
    Write-Output "      first: $($L.First)"
}

# WHAT WAS NOT MATCHED, and why that has to be said out loud.
#
# This design finds a session only when the key was stated in it. A session
# where nobody asked, or where the answer was skipped, does not exist as far as
# the lookup is concerned -- it is not reported as thin or uncertain, it is
# simply absent. The record store this replaced could at least write "gate:
# skip" and make the gap visible.
#
# So report the shape of the window, not just the hits. "2 of 8" invites the
# question "what were the other 6"; "2 sessions found" does not.
if ($Unmatched.Count) {
    Write-Output ''
    Write-Output "$($Unmatched.Count) other session(s) in this window do not mention $Key."
    if ($Unmatched.Count -le 5) {
        Write-Output 'If any of these were work on this ticket, the key was never stated in them:'
        foreach ($F in $Unmatched) {
            $L = Get-Label -File $F
            Write-Output "  [$($L.Short)]  $($L.When.ToString('yyyy-MM-dd HH:mm'))  $($L.Turns) turns"
            Write-Output "      first: $($L.First)"
        }
    } else {
        Write-Output "Too many to list - run with -List if you think one of them belongs."
    }
    Write-Output ''
}

if ($Matched.Count -gt $MaxSessions) {
    Write-Output "!! $($Matched.Count) sessions is more than the $MaxSessions this is meant to read at once."
    Write-Output '!! Extract the most relevant ones by id, and say in the draft that coverage was'
    Write-Output '!! limited. Do not quietly read a subset.'
}
Write-Output "Next: sessions.ps1 -Extract `"$((@($Matched | ForEach-Object { $_.BaseName.Substring(0,8) })) -join ',')`""
