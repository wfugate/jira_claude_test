# vcs.ps1 -- the ONLY file that knows which version control system this repo uses.
#
# Everything else here is VCS-agnostic. The capture half reads Claude Code
# transcripts and never touches version control at all; only the draft step
# needs a diff. So porting to a different VCS means changing this file and
# nothing else -- which matters, because git is what we developed against and
# AccuRev is the real target.
#
# Usage:
#   vcs.ps1 prepare          make new files visible to the diff (may be a no-op)
#   vcs.ps1 status           what has changed in the working copy
#   vcs.ps1 diff             the actual changes
#   vcs.ps1 backend          which backend is active, and why
#   vcs.ps1 ticket-history ABC-123    all transactions for a ticket (accurev)
#
# Backend selection, in order:
#   1. $env:UPDATEJIRA_VCS = git | accurev
#   2. a .git directory        -> git
#   3. a .acignore file, or accurev on PATH -> accurev
#   4. otherwise: ERROR. Guessing wrong would silently produce an empty diff,
#      and an empty diff reads as "nothing changed" rather than as a failure.

param(
    [Parameter(Position = 0)] [string] $Action = '',
    [Parameter(Position = 1)] [string] $Ticket = '',
    # The last write-up's timestamp. Bounds the diff the same way it bounds the
    # session search: everything since this ticket was last written up,
    # committed or not.
    [string] $Since = ''
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)   # up out of .claude/scripts


function Invoke-Vcs {
    <#
      Run a VCS command in the repo root and return rc / stdout / stderr.

      Uses file redirection rather than the PowerShell pipeline for the same
      reason worker.ps1 does: PowerShell re-encodes native program output using
      the console's OEM codepage, which corrupts any non-ASCII character in a
      diff. Redirecting to a file means the bytes are never touched, and we
      decode them as UTF-8 ourselves.
    #>
    param([Parameter(Mandatory)] [string] $Exe,
          [string[]] $Arguments = @())

    $Utf8    = New-Object System.Text.UTF8Encoding($false)
    $Base    = Join-Path $env:TEMP "updatejira-vcs-$PID-$(Get-Random)"
    $OutFile = "$Base.out"; $ErrFile = "$Base.err"

    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments `
                 -WorkingDirectory $RepoRoot `
                 -RedirectStandardOutput $OutFile `
                 -RedirectStandardError  $ErrFile `
                 -WindowStyle Hidden -PassThru -Wait
        $Out = if (Test-Path $OutFile) { [IO.File]::ReadAllText($OutFile, $Utf8) } else { '' }
        $Err = if (Test-Path $ErrFile) { [IO.File]::ReadAllText($ErrFile, $Utf8) } else { '' }
        return @{ Code = $p.ExitCode; Out = $Out; Err = $Err }
    } catch {
        # Exe not found, or could not start. 127 mirrors the shell convention.
        return @{ Code = 127; Out = ''; Err = "could not run '$Exe': $($_.Exception.Message)" }
    } finally {
        foreach ($f in @($OutFile, $ErrFile)) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
}


# ---------------------------------------------------------------------------
# git -- fully verified. All development and testing ran against this.
# ---------------------------------------------------------------------------

function Git-Prepare {
    # Intent-to-add: registers new file paths so they appear in `diff HEAD`,
    # without staging content and without committing anything.
    #
    # This matters more than it looks. `git diff HEAD` does NOT show untracked
    # files, and new features are exactly where new files live -- so without
    # this, most of a new feature is invisible to the draft.
    return Invoke-Vcs -Exe 'git' -Arguments @('add', '-N', '.')
}

function Git-Status { return Invoke-Vcs -Exe 'git' -Arguments @('status', '--short') }

function Git-Diff {
    <#
      Everything written up by this run, committed or not.

      THREE SOURCES, in order of preference. Each exists because the one before
      it returned an empty diff for work that was really there, and an empty
      diff reads downstream as "nothing changed" rather than as a failure.

        1. -Since given: the commit at the watermark, against the working tree.
           Covers committed and uncommitted work in one command. Preferred.
        2. `git diff HEAD`: uncommitted work only. Correct when there is no
           watermark, i.e. the ticket has never been written up.
        3. Branch against master/main, when the working copy is clean. Only
           reaches work committed on a feature branch -- it cannot see work
           committed straight onto master, which is what forced source 1.

      Whichever is used ANNOUNCES ITSELF. Silently changing where the diff came
      from would be worse than the empty diff it fixes.
    #>
    param([string] $Since = '')

    # Source 1. `git diff <base>` with no second ref compares that commit
    # against the WORKING TREE, so it spans both committed and uncommitted work.
    if ($Since) {
        $b = Invoke-Vcs -Exe 'git' -Arguments @('rev-list', '-1', "--before=$Since", 'HEAD')
        $Base = if ($b.Code -eq 0) { $b.Out.Trim() } else { '' }
        if ($Base) {
            $d = Invoke-Vcs -Exe 'git' -Arguments @('diff', $Base)
            if ($d.Code -eq 0 -and $d.Out -and $d.Out.Trim()) {
                $d.Out = "(everything since the last write-up: $($Base.Substring(0,7)) against the working tree)`n`n" + $d.Out
                return $d
            }
            if ($d.Code -eq 0) { return $d }   # genuinely nothing since then
        }
    }

    $r = Invoke-Vcs -Exe 'git' -Arguments @('diff', 'HEAD')
    if ($r.Code -ne 0)            { return $r }
    if ($r.Out -and $r.Out.Trim()) { return $r }

    $Branch = (Invoke-Vcs -Exe 'git' -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Out.Trim()

    foreach ($Base in @('master', 'main')) {
        if ($Base -eq $Branch) { continue }
        $v = Invoke-Vcs -Exe 'git' -Arguments @('rev-parse', '--verify', '--quiet', $Base)
        if ($v.Code -ne 0 -or -not $v.Out.Trim()) { continue }

        $n = Invoke-Vcs -Exe 'git' -Arguments @('rev-list', '--count', "$Base...HEAD")
        if ($n.Code -ne 0 -or [int]($n.Out.Trim()) -eq 0) { continue }

        $d = Invoke-Vcs -Exe 'git' -Arguments @('diff', "$Base...HEAD")
        if ($d.Code -eq 0 -and $d.Out -and $d.Out.Trim()) {
            $d.Out = "(working copy is clean - this diff is $Branch against $Base, i.e. work already committed on this branch)`n`n" + $d.Out
            return $d
        }
    }

    return $r
}


# ---------------------------------------------------------------------------
# AccuRev -- written from the official CLI User's Guide, NEVER RUN.
#
# Nothing below has executed against a real workspace. The flags are documented
# rather than guessed (an earlier version used `diff -a -b`, where -b is not an
# AccuRev flag at all -- extra flags pass through to the underlying comparison
# program, where -b means ignore-whitespace, so it would have silently ignored
# whitespace changes). But documented is not verified.
# ---------------------------------------------------------------------------

function AccuRev-Prepare {
    # AccuRev has no equivalent of git's intent-to-add.
    #
    # A file in the workspace but not in the depot has status (external) and is
    # in NO diff until `accurev add` is run. So on AccuRev the draft step sees
    # new files listed by status but cannot see their contents, and must
    # describe them from filenames plus the captured reasoning.
    #
    # This is a real capability difference between the two backends, not
    # something verification will remove.
    return @{ Code = 0; Err = ''
              Out  = '(no prepare step for accurev - new files appear in status as (external) but their contents are NOT in the diff)' }
}

function AccuRev-Status {
    <#
      Everything outstanding in the workspace, in one call.

      --outgoing is documented as showing all files with any of the statuses
      (member), (modified), (missing) or (external) -- modified files, new files
      not yet added, AND files deleted from the workspace. That is the whole
      picture. An earlier version used `stat -m` plus `stat -x`, which missed
      (missing) entirely: a file you deleted would have been invisible.

      -O overrides a timestamp optimisation. Without it, stat skips files whose
      timestamps have not changed since the last update or modified-search, and
      can silently omit a genuinely modified file. We pass it deliberately: slow
      and complete beats fast and wrong, because a missing file means a ticket
      comment that describes less work than was actually done.

      -O IS valid alongside --outgoing: both are documented options of `stat`,
      and the syntax permits combining them. The retry-without-O fallback below
      stays anyway - it costs nothing and covers a version that disagrees.

      ALSO UNVERIFIED: the docs say the timestamp optimisation applies to the
      external-file search too, with no documented way to disable it there. A
      brand-new file whose timestamp looks stale could be missed.
    #>
    $r = Invoke-Vcs -Exe 'accurev' -Arguments @('stat', '--outgoing', '-O')
    if ($r.Code -ne 0) {
        $r2 = Invoke-Vcs -Exe 'accurev' -Arguments @('stat', '--outgoing')
        if ($r2.Code -eq 0) {
            $r2.Out += "`n(note: -O was rejected, so the timestamp optimisation is active and a modified file could be missing from this list)"
            return $r2
        }
    }
    return $r
}

function AccuRev-Diff {
    <#
      All elements, workspace against the version last kept.

      `accurev diff` with no version spec compares the workspace file against
      the active version in the workspace stream -- what you last kept. That is
      the equivalent of `git diff HEAD`. -a means "all elements in the workspace,
      output only those that differ" - confirmed against the docs, and it does
      include changes made locally but not yet kept.

      Note -a is not a modified-only filter; it is all-elements-that-differ. That
      is what we want here. (`-m` would be the explicit modified-only form.)
    #>
    return Invoke-Vcs -Exe 'accurev' -Arguments @('diff', '-a')
}

function AccuRev-TicketHistory {
    <#
      All transactions whose comment mentions the ticket.

      Matthew's observation: with the ticket number in the transaction comment,
      AccuRev already aggregates every change for a ticket -- which is the half
      of the problem this tool does NOT need to solve.

      `hist` has a comment filter for exactly this: -a searches all elements in
      the depot, -c returns only transactions whose comments contain the string
      (case-insensitive). So no local filtering is needed - an earlier version
      dumped recent transactions and grepped them, which was a guess.

      CAVEAT: this is depot-wide ELEMENT history filtered by comment, not a
      guaranteed list of every transaction in the database. Good enough for "what
      changed under this ticket"; do not present it as exhaustive.

      Still never executed against a real workspace.
    #>
    param([string] $Key = '')

    if (-not $Key) {
        return @{ Code = 0; Err = ''; Out = '(no ticket key given)' }
    }
    return Invoke-Vcs -Exe 'accurev' -Arguments @('hist', '-a', '-c', $Key)
}


# ---------------------------------------------------------------------------

function Get-Backend {
    # Returns @{ Name; Reason }. Throws rather than guessing.
    if ($env:UPDATEJIRA_VCS) {
        switch ($env:UPDATEJIRA_VCS.Trim().ToLower()) {
            'git'     { return @{ Name = 'git';     Reason = 'UPDATEJIRA_VCS=git' } }
            'accurev' { return @{ Name = 'accurev'; Reason = 'UPDATEJIRA_VCS=accurev' } }
            default   { throw "UPDATEJIRA_VCS='$env:UPDATEJIRA_VCS' is not a known backend (git or accurev)" }
        }
    }
    if (Test-Path (Join-Path $RepoRoot '.git'))       { return @{ Name = 'git';     Reason = 'found .git' } }
    if (Test-Path (Join-Path $RepoRoot '.acignore'))  { return @{ Name = 'accurev'; Reason = 'found .acignore' } }
    if (Get-Command 'accurev' -ErrorAction SilentlyContinue) {
        return @{ Name = 'accurev'; Reason = 'accurev found on PATH' }
    }
    throw "Cannot tell which version control system $RepoRoot uses. Set UPDATEJIRA_VCS=git or UPDATEJIRA_VCS=accurev."
}


# ========================= command line =================================

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced: functions only

if (-not $Action) {
    Write-Output 'Usage: vcs.ps1 <prepare|status|diff|backend|ticket-history> [ticket]'
    exit 1
}

$Backend = Get-Backend

if ($Action -eq 'backend') {
    Write-Output "backend: $($Backend.Name)   ($($Backend.Reason))"
    if ($Backend.Name -eq 'accurev') {
        Write-Output 'WARNING: no accurev command in this file has ever been run against a real workspace. Treat its output as unverified.'
    }
    exit 0
}

$Result = switch ("$($Backend.Name)/$Action") {
    'git/prepare'             { Git-Prepare }
    'git/status'              { Git-Status }
    'git/diff'                { Git-Diff -Since $Since }
    'git/ticket-history'      { @{ Code = 0; Out = '(git backend has no ticket-history support)'; Err = '' } }
    'accurev/prepare'         { AccuRev-Prepare }
    'accurev/status'          { AccuRev-Status }
    'accurev/diff'            { AccuRev-Diff }
    'accurev/ticket-history'  { AccuRev-TicketHistory -Key $Ticket }
    default { throw "Unknown action '$Action'. Use: prepare, status, diff, backend, ticket-history" }
}

if ($Result.Out -and $Result.Out.Trim()) { Write-Output $Result.Out.TrimEnd() }

if ($Result.Code -ne 0) {
    # LOUD, never silent. A diff that failed must never look like "no changes" --
    # that would produce a ticket comment describing work it could not see.
    Write-Output ''
    Write-Output "!! $($Backend.Name) $Action failed (rc=$($Result.Code))"
    if ($Result.Err -and $Result.Err.Trim()) {
        $e = $Result.Err.Trim()
        Write-Output "!! $($e.Substring(0, [Math]::Min(600, $e.Length)))"
    }
    exit $Result.Code
}
elseif (-not ($Result.Out -and $Result.Out.Trim())) {
    Write-Output '(no output - nothing changed)'
}
