# vcs.ps1 -- the ONLY file that knows which version control system this repo uses.
#
# Everything else here is VCS-agnostic. The capture half reads Claude Code
# transcripts and never touches version control at all; only the draft step
# needs a diff. So porting to a different VCS means changing this file and
# nothing else -- which matters, because git is what we developed against and
# AccuRev is the real target.
#
# The accurev commands were verified against a real workspace on 2026-09-10.
# The git half stays: it is the only end-to-end verified path, the demo runs on
# it, and it is the regression test for the shared capture layer below.
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

      Output is captured by having CMD redirect it to files, and we decode those
      bytes as UTF-8 ourselves. Two separate reasons, and the second was found
      the hard way:

      1. PowerShell re-encodes native program output through the console's OEM
         codepage, which corrupts any non-ASCII character in a diff. Writing to
         a file means the bytes are never touched.

      2. IT MUST BE CMD DOING THE REDIRECTION, NOT Start-Process.
         `accurev diff` shells out to its own bundled diff.exe to produce the
         body. Under Start-Process -RedirectStandardOutput that child fails with
         "Error running diff: 0 9013", accurev still exits 0, and the diff comes
         back as a header and nothing else. Verified against a real workspace:

           Start-Process + redirect   rc=0   body LOST
           cmd.exe /c "... > file"    rc=1   body complete

         So the mechanism added to prevent silent corruption was itself causing
         silent total loss -- the exact outcome the comment above promised could
         not happen. Hence CMD.
    #>
    param([Parameter(Mandatory)] [string] $Exe,
          [string[]] $Arguments = @())

    $Utf8    = New-Object System.Text.UTF8Encoding($false)
    $Base    = Join-Path $env:TEMP "updatejira-vcs-$PID-$(Get-Random)"
    $OutFile = "$Base.out"; $ErrFile = "$Base.err"

    # Quote any argument containing whitespace. CMD sees one command line, so an
    # unquoted path with a space would split into two arguments.
    $Quoted = @($Arguments | ForEach-Object {
        if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ }
    })

    $Prev = Get-Location
    try {
        Set-Location -LiteralPath $RepoRoot
        $Line = '"' + $Exe + '" ' + ($Quoted -join ' ') +
                ' > "' + $OutFile + '" 2> "' + $ErrFile + '"'
        # cmd /c needs the whole line wrapped when it begins with a quote.
        & $env:ComSpec /c ('"' + $Line + '"') | Out-Null
        $Code = $LASTEXITCODE

        $Out = if (Test-Path $OutFile) { [IO.File]::ReadAllText($OutFile, $Utf8) } else { '' }
        $Err = if (Test-Path $ErrFile) { [IO.File]::ReadAllText($ErrFile, $Utf8) } else { '' }
        return @{ Code = $Code; Out = $Out; Err = $Err }
    } catch {
        # Exe not found, or could not start. 127 mirrors the shell convention.
        return @{ Code = 127; Out = ''; Err = "could not run '$Exe': $($_.Exception.Message)" }
    } finally {
        Set-Location -LiteralPath $Prev
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
# AccuRev -- VERIFIED against a real workspace on 2026-09-10.
#
# Every command below has been executed. All four flag choices turned out to be
# correct; what was broken was the capture layer in Invoke-Vcs, not the flags.
# See that function for the detail. Three things were learned that documentation
# alone did not give:
#
#   * `accurev diff` EXITS 1 when differences exist. Non-zero is not failure.
#   * `-- -u` passes -u to the bundled diff program, giving a real unified diff.
#     Without it the format is ed/normal (1c1,2 / < / --- / >).
#   * `stat -fx` returns XML with an explicit status attribute. The plain-text
#     column spacing is NOT fixed-width, so parsing it is unsafe.
#
# CORRECTION: an earlier comment here claimed `-b` "is not an AccuRev flag at
# all". It is -- `accurev help diff` documents it as "compare the file in the
# workspace tree with the version in the workspace's backing stream". The old
# `diff -a -b` was still wrong, but because it compared against the backing
# stream rather than the last kept version. Passthrough to the diff program is
# `--`, not a bare unrecognised flag.
# ---------------------------------------------------------------------------

function AccuRev-Prepare {
    # AccuRev has no equivalent of git's intent-to-add: a file in the workspace
    # but not in the depot is (external) and appears in no diff.
    #
    # This is no longer a capability gap. AccuRev-Diff now finds (external)
    # entries via `stat -fx` and reads their contents off disk, so new-file
    # contents do reach the draft. Nothing to do here.
    return @{ Code = 0; Err = ''
              Out  = '(no prepare step needed on accurev - new file contents are read from disk by the diff step)' }
}

function AccuRev-Status {
    <#
      Everything outstanding in the workspace, in one call.

      VERIFIED: --outgoing covers (modified), (external) AND (missing) -- the
      last confirmed by moving a file aside and back, which produced a (missing)
      line and then (backed) again.

      VERIFIED: -O is accepted alongside --outgoing. `accurev help stat`
      documents it as "Override the optimized search for modified files", and
      both appear in the same USAGE line. It produced output identical to
      running without it, so its protective value is documented rather than
      demonstrated -- but it costs nothing and the failure it guards against
      (a modified file silently skipped) is one we cannot afford.

      The retry-without-O fallback stays: it covers a version that disagrees.
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

function Get-AccuRevExternals {
    <#
      Paths of (external) files -- in the workspace, unknown to the depot.

      Read from `stat -fx` XML, not the plain-text listing. The text columns are
      not fixed-width (four spaces before (external) on one line, two on
      another), so a text parse would be guesswork. The XML gives
      status="(external)" as an attribute.

      Returns workspace-relative paths as AccuRev reports them (".\some\path").
    #>
    $r = Invoke-Vcs -Exe 'accurev' -Arguments @('stat', '--outgoing', '-fx')
    if ($r.Code -ne 0 -or -not $r.Out.Trim()) { return @() }

    try { $doc = [xml]$r.Out } catch { return @() }

    # EXCLUDE OUR OWN FILES. In an AccuRev workspace the toolchain is itself
    # (external) -- .claude/ is copied in, not tracked by the depot -- so
    # without this the diff dumps every script and doc into the draft as new
    # files. Same reason Test-IsSourceFile exists on the transcript side.
    return @($doc.SelectNodes('//element') | Where-Object {
        $_.status -and $_.status.Contains('(external)') -and $_.dir -ne 'yes'
    } | ForEach-Object { $_.location } | Where-Object {
        $l = $_.Replace([char]92, '/').ToLower()
        ($l -notmatch '(^|/)\.claude/') -and
        ($l -notmatch '(^|/)\.git/')    -and
        ($l -notmatch '(^|/)claude\.md$')
    })
}

function AccuRev-Diff {
    <#
      All elements that differ, workspace against the version last kept, PLUS
      the contents of new files.

      VERIFIED: `diff -a` does show changes made but not yet kept. That was the
      main open question and the answer is yes.

      `-- -u` passes -u through to the bundled diff program for a unified diff.
      Everything downstream already expects that shape.

      EXIT CODE 1 MEANS DIFFERENCES FOUND, not failure. Treated as success here,
      because the caller exits non-zero and prints `!!` on a real failure -- so
      leaving this uncorrected would have made every run with changes look like
      a broken diff.

      New files are appended as synthetic added-file blocks. `accurev diff`
      cannot show them: an (external) file has no depot version to compare
      against. But the file is on disk, so we read it. New files are exactly
      where new features live, and describing them from a filename alone is how
      a draft starts guessing.
    #>
    $r = Invoke-Vcs -Exe 'accurev' -Arguments @('diff', '-a', '--', '-u')

    # rc=1 is "differences exist". Anything else non-zero is a genuine failure.
    if ($r.Code -eq 1) { $r.Code = 0 }
    if ($r.Code -ne 0) { return $r }

    $MaxNewFileLines = 200
    $Blocks = @()
    foreach ($Path in Get-AccuRevExternals) {
        $Full = Join-Path $RepoRoot ($Path -replace '^\.[\\/]', '')
        if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }

        try {
            $Bytes = [IO.File]::ReadAllBytes($Full)
        } catch {
            $Blocks += "--- /dev/null`n+++ $Path`n(new file - could not be read: $($_.Exception.Message))"
            continue
        }

        # Skip binaries: a NUL byte in the first chunk is the cheap test.
        $Probe = $Bytes[0..([Math]::Min(1023, [Math]::Max(0, $Bytes.Length - 1)))]
        if ($Bytes.Length -gt 0 -and ($Probe -contains 0)) {
            $Blocks += "--- /dev/null`n+++ $Path`n(new binary file, $($Bytes.Length) bytes - contents not shown)"
            continue
        }

        $Lines = @([IO.File]::ReadAllLines($Full))
        $Shown = @($Lines | Select-Object -First $MaxNewFileLines)
        $Body  = ($Shown | ForEach-Object { '+' + $_ }) -join "`n"
        $Note  = ''
        if ($Lines.Count -gt $MaxNewFileLines) {
            $Note = "`n(truncated: showing $MaxNewFileLines of $($Lines.Count) lines)"
        }
        $Blocks += "--- /dev/null`n+++ $Path`n@@ new file, $($Lines.Count) line(s) @@`n$Body$Note"
    }

    if ($Blocks.Count) {
        $r.Out = $r.Out.TrimEnd() + "`n`n" +
                 "=== NEW FILES ($($Blocks.Count)) - (external), so absent from accurev diff; read from disk ===`n`n" +
                 ($Blocks -join "`n`n")
    }
    return $r
}

function AccuRev-TicketHistory {
    <#
      Transactions whose comment mentions the ticket.

      VERIFIED working. But `-c` is a CASE-INSENSITIVE SUBSTRING match, and that
      matters more than it sounds: `-c "QRM-124"` returned QRM-1240's
      transactions alongside the real QRM-124 ones. Left unfiltered, this
      attributes someone else's work to your ticket -- a confident, plausible
      wrong answer on a permanent record, which is the exact failure this whole
      tool exists to avoid.

      So the results are filtered here for the key as a WHOLE TOKEN: the key
      must not be followed by a digit or hyphen. A script is the right place for
      that rule, because it has to hold on every run.

      Also note `-c` searches all history with no time bound -- the QRM-124
      match reached back to 2015. Bounding it needs `-t`, whose flags are not
      verified, so for now the output is passed through with a warning.

      CAVEAT: this is depot-wide ELEMENT history filtered by comment, not a
      guaranteed list of every transaction. Do not present it as exhaustive.
    #>
    param([string] $Key = '')

    if (-not $Key) {
        return @{ Code = 0; Err = ''; Out = '(no ticket key given)' }
    }

    $r = Invoke-Vcs -Exe 'accurev' -Arguments @('hist', '-a', '-c', $Key)
    if ($r.Code -ne 0 -or -not $r.Out.Trim()) { return $r }

    # Transactions are separated by lines starting "transaction ".
    $Raw    = $r.Out -replace "`r`n", "`n"
    $Chunks = @($Raw -split '(?m)(?=^transaction\s)') | Where-Object { $_.Trim() }

    # Whole-token match: the key not followed by a digit or hyphen, so QRM-124
    # does not match QRM-1240.
    $Rx   = [regex]::new('(?i)' + [regex]::Escape($Key) + '(?![0-9\-])')
    $Keep = @($Chunks | Where-Object { $Rx.IsMatch($_) })
    $Drop = @($Chunks).Count - $Keep.Count

    if (-not $Keep.Count) {
        $Extra = ''
        if ($Drop -gt 0) {
            $Extra = " - $Drop substring match(es) were discarded, e.g. a longer key beginning with it"
        }
        $r.Out = "(no transaction comment contains $Key as a whole key$Extra)"
        return $r
    }

    $r.Out = ($Keep -join "`n").TrimEnd()
    if ($Drop -gt 0) {
        $r.Out += "`n`n(dropped $Drop transaction(s) that matched $Key only as a substring of a longer key)"
    }
    $r.Out += "`n(note: hist -c is unbounded in time - old transactions may appear)"
    return $r
}


function Get-EnvSetting {
    # Process environment first, then the PERSISTED user and machine values.
    #
    # A process inherits its environment at launch, so a user-level variable set
    # after the Claude Code desktop app is already running is invisible to it and
    # to everything it spawns until the app restarts -- while a terminal opened
    # afterwards sees it immediately. The same command then works by hand and
    # fails inside Claude, which looks like a broken tool. Reading the registry
    # scopes directly finds the value whenever it was set.
    #
    # Duplicated from jira_lib.ps1 rather than shared: this file is the VCS
    # boundary and deliberately depends on nothing else.
    param([Parameter(Mandatory)] [string] $Name)

    foreach ($Scope in @('Process', 'User', 'Machine')) {
        try {
            $v = [Environment]::GetEnvironmentVariable($Name, $Scope)
            if ($v) { return $v }
        } catch { }
    }
    return $null
}


function Get-Backend {
    # Returns @{ Name; Reason }. Throws rather than guessing.
    $Override = Get-EnvSetting 'UPDATEJIRA_VCS'
    if ($Override) {
        switch ($Override.Trim().ToLower()) {
            'git'     { return @{ Name = 'git';     Reason = 'UPDATEJIRA_VCS=git' } }
            'accurev' { return @{ Name = 'accurev'; Reason = 'UPDATEJIRA_VCS=accurev' } }
            default   { throw "UPDATEJIRA_VCS='$Override' is not a known backend (git or accurev)" }
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
        Write-Output 'note: status, diff and ticket-history are VERIFIED against a real workspace (2026-09-10).'
        Write-Output 'note: hist -c matches substrings, so results are filtered here to whole keys. It is also unbounded in time.'
        Write-Output 'note: NOT yet verified is a full /updatejira run from an accurev workspace.'
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

# STDERR IS REPORTED WHENEVER THERE IS ANY, EVEN ON SUCCESS.
#
# This used to be printed only when the exit code was non-zero, and that hid a
# total data loss. `accurev diff` shelled out to its bundled diff.exe, that
# child failed with "Error running diff: 0 9013" on stderr, and accurev itself
# still exited 0. So: exit code fine, stderr discarded because the code was
# fine, and stdout non-empty (a header with no body) so the "nothing changed"
# branch did not fire either. The diff came back empty and the script reported
# success -- invisible in every direction.
#
# A tool that writes to stderr and exits 0 is telling you something. Print it.
if ($Result.Err -and $Result.Err.Trim()) {
    $e = $Result.Err.Trim()
    $Marker = if ($Result.Code -ne 0) { '!!' } else { '!! (exit 0, but stderr was not empty)' }
    Write-Output ''
    Write-Output "$Marker $($Backend.Name) $Action"
    Write-Output "!! $($e.Substring(0, [Math]::Min(600, $e.Length)))"
}

if ($Result.Code -ne 0) {
    # LOUD, never silent. A diff that failed must never look like "no changes" --
    # that would produce a ticket comment describing work it could not see.
    Write-Output ''
    Write-Output "!! $($Backend.Name) $Action failed (rc=$($Result.Code))"
    exit $Result.Code
}
elseif (-not ($Result.Out -and $Result.Out.Trim())) {
    Write-Output '(no output - nothing changed)'
}
