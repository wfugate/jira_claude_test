# test-accurev.ps1 -- verify the AccuRev half of vcs.ps1 against a real workspace.
#
#   test-accurev.ps1 [-TestFile <relative path>] [-TicketKey <KEY>]
#
# Run this from the root of an AccuRev workspace that has the six runtime files
# in it. It is deterministic and involves no model: every check either passes or
# fails, and it prints why.
#
# WHAT IT DOES NOT DO: keep, add, promote, or create anything in the depot. It
# modifies one tracked file locally and restores it, and creates one scratch
# file and deletes it. Nothing reaches the server.
#
# Exits 0 if every check passed, 1 otherwise.

param(
    [string] $TestFile  = '',
    [string] $TicketKey = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Vcs       = Join-Path $ScriptDir 'vcs.ps1'

$Script:Pass = 0
$Script:Fail = 0
$Script:Notes = New-Object System.Collections.ArrayList

function Check([string] $Name, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) {
        Write-Output "  PASS  $Name"
        $Script:Pass++
    } else {
        Write-Output "  FAIL  $Name"
        if ($Detail) { Write-Output "        $Detail" }
        $Script:Fail++
    }
}

function Note([string] $Text) {
    Write-Output "  note  $Text"
    [void]$Script:Notes.Add($Text)
}

function Vcs([string[]] $VcsArgs) {
    <#
      Run vcs.ps1 and return its combined output as one string.

      NOT $Args. That is a PowerShell automatic variable and cannot be used as a
      parameter name -- it silently does not bind, so every call ran vcs.ps1
      with no arguments and got back its usage message. Half the checks then
      passed against that usage text, because "is not empty" and "has no !!
      line" are both true of it.

      The same trap was found and fixed in this codebase once before (review
      finding F16). Hence the sentinel below: a usage message means the
      arguments never arrived, and a test must never score against it.
    #>
    $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Vcs @VcsArgs 2>&1
    $Text = (($o | ForEach-Object { [string]$_ }) -join "`n")

    if ($Text -match 'Usage: vcs\.ps1') {
        Write-Output ''
        Write-Output "  ABORT  vcs.ps1 printed its usage message for: $($VcsArgs -join ' ')"
        Write-Output '         The arguments did not reach it, so every check below would be'
        Write-Output '         scored against usage text rather than real output.'
        exit 2
    }
    return $Text
}


Write-Output ''
Write-Output "test-accurev.ps1  --  workspace root: $Root"
Write-Output ''

# ===================== 0. preflight =====================
Write-Output '0. Preflight'

$AccuRev = Get-Command 'accurev' -ErrorAction SilentlyContinue
Check 'accurev is on PATH' ([bool]$AccuRev) `
      'Not found. If AccuRev was installed after the app launched, restart the app.'
if (-not $AccuRev) { Write-Output ''; Write-Output 'Cannot continue.'; exit 1 }

# The fix being tested is in Invoke-Vcs. If this copy predates it, everything
# below is measuring the wrong code -- which is exactly what happened once.
$VcsText = [IO.File]::ReadAllText($Vcs, (New-Object System.Text.UTF8Encoding($false)))
Check 'vcs.ps1 has the CMD capture fix (contains ComSpec)' ($VcsText -match 'ComSpec') `
      'This copy of vcs.ps1 predates the fix. Pull the repo and re-copy, or clone into the workspace.'

# AM I ACTUALLY IN AN ACCUREV WORKSPACE?
#
# This has now been the third run that measured the wrong thing. First $Args did
# not bind so everything scored against a usage message; then the script was run
# from the git clone rather than the workspace, so every accurev command failed
# with "not in a directory associated with a workspace" and the checks scored
# that instead.
#
# A test that runs in the wrong place and still reports numbers is worse than
# one that refuses. So: ask accurev where it thinks it is, and stop if the
# answer is not a workspace.
Push-Location -LiteralPath $Root
try {
    $Info = (& accurev info 2>&1 | Out-String)
} catch {
    $Info = "could not run accurev info: $($_.Exception.Message)"
}
Pop-Location

if ($Info -match 'not in a directory associated with a workspace' -or
    $Info -notmatch '(?im)^\s*Workspace/ref:\s*\S') {
    Write-Output ''
    Write-Output '  ABORT  this is not an AccuRev workspace.'
    Write-Output "         root: $Root"
    Write-Output ''
    Write-Output '         accurev info said:'
    foreach ($l in @($Info -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6)) {
        Write-Output "           $l"
    }
    Write-Output ''
    Write-Output '         cd to the AccuRev workspace and run it from there. Running from'
    Write-Output '         the git clone scores every check against an error message.'
    exit 2
}

$WsLine = (@($Info -split "`r?`n" | Where-Object { $_ -match '(?i)^\s*Workspace/ref:' }) | Select-Object -First 1)
Write-Output "        $($WsLine.Trim())"

if (Test-Path (Join-Path $Root '.git')) {
    Note 'This workspace also contains a .git directory. UPDATEJIRA_VCS is forcing accurev, but that is worth knowing.'
}

$Backend = Vcs @('backend')
Check 'backend resolves to accurev' ($Backend -match 'backend:\s*accurev') `
      "Got: $($Backend -split "`n" | Select-Object -First 1)"

Write-Output ''

# ===================== 1. status =====================
Write-Output '1. Status'

$Status = Vcs @('status')
Check 'status returns output' ([bool]$Status.Trim()) 'Empty.'
Check 'status has no !! failure line' ($Status -notmatch '(?m)^!!') `
      (($Status -split "`n" | Where-Object { $_ -match '^!!' }) -join ' | ')

Write-Output ''

# ===================== 2. pick a file =====================
Write-Output '2. Choosing a tracked file to modify'

if (-not $TestFile) {
    $Candidates = @(Get-ChildItem -Path $Root -Recurse -File -Include *.txt,*.cs,*.bat `
                        -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\\.claude\\' -and $_.Length -lt 65536 } |
                    Sort-Object { $_.FullName -notmatch '(?i)test_deleteme' }, Length)
    if ($Candidates.Count) { $TestFile = $Candidates[0].FullName }
}
else {
    $TestFile = Join-Path $Root $TestFile
}

Check 'found a file to modify' ([bool]$TestFile -and (Test-Path -LiteralPath $TestFile)) `
      'Pass one explicitly with -TestFile <relative path>.'
if (-not ($TestFile -and (Test-Path -LiteralPath $TestFile))) { exit 1 }

Write-Output "        using: $($TestFile.Substring($Root.Length).TrimStart('\'))"
$Original = [IO.File]::ReadAllBytes($TestFile)
$Scratch  = Join-Path $Root 'accurev_probe_delete_me.txt'
$Marker   = "PROBE-" + [guid]::NewGuid().ToString('N').Substring(0, 8)

Write-Output ''

try {
    # ===================== 3. diff of an unkept change =====================
    Write-Output '3. Diff of a modified, unkept file'

    Add-Content -LiteralPath $TestFile -Value "// $Marker unkept change, restored by test-accurev.ps1"
    $Diff = Vcs @('diff')

    Check 'diff is not empty' ([bool]$Diff.Trim()) 'Empty -- the capture is still losing the body.'
    Check 'diff contains the unkept change' ($Diff -match [regex]::Escape($Marker)) `
          'The added line is absent. This is the silent-empty-diff bug.'
    Check 'diff is unified format (has +++ and @@)' (($Diff -match '(?m)^\+\+\+') -and ($Diff -match '@@')) `
          'Not unified -- the `-- -u` passthrough is not taking effect.'
    Check 'diff does NOT report failure (rc=1 handled)' ($Diff -notmatch 'diff failed \(rc=1\)') `
          'Exit code 1 is being treated as failure. Differences existing is not a failure.'
    Check 'no stderr-on-success warning' ($Diff -notmatch 'exit 0, but stderr was not empty') `
          'Something wrote to stderr. Read the !! line above -- it is now surfaced deliberately.'

    Write-Output ''

    # ===================== 4. new file contents =====================
    Write-Output '4. New (external) file contents'

    $NewMarker = "NEWFILE-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [IO.File]::WriteAllText($Scratch, "line one $NewMarker`nline two`nline three`n",
                            (New-Object System.Text.UTF8Encoding($false)))

    $Stat = Vcs @('status')
    Check 'new file appears in status as (external)' `
          ($Stat -match 'accurev_probe_delete_me\.txt' -and $Stat -match '\(external\)') `
          'Not listed. The timestamp optimisation may be hiding it.'

    $Diff2 = Vcs @('diff')
    Check 'diff has a NEW FILES section' ($Diff2 -match 'NEW FILES') `
          'Absent -- Get-AccuRevExternals found nothing, so the stat -fx XML parse is failing.'
    Check 'new file CONTENTS reach the diff' ($Diff2 -match [regex]::Escape($NewMarker)) `
          'The filename may be there but the contents are not. This is the gap the fix closes.'

    Write-Output ''

    # ===================== 5. ticket history =====================
    Write-Output '5. Ticket history'

    if (-not $TicketKey) {
        Note 'No -TicketKey given, so the hist whole-key filter was not exercised.'
        Note 'Re-run with -TicketKey <a key that is a prefix of a longer one, e.g. QRM-124>.'
    }
    else {
        $Hist = Vcs @('ticket-history', $TicketKey)
        Check 'ticket-history returns without failing' ($Hist -notmatch '(?m)^!!.*failed') $Hist

        $Longer = [regex]::new([regex]::Escape($TicketKey) + '[0-9]')
        Check "no transaction shows $TicketKey followed by a digit (over-match filtered)" `
              (-not $Longer.IsMatch($Hist)) `
              'A longer key leaked through -- the whole-key filter is not working.'

        if ($Hist -match 'dropped (\d+) transaction') {
            Note "filter discarded $($Matches[1]) substring match(es) -- working as intended"
        }
    }
}
finally {
    # ===================== restore =====================
    Write-Output ''
    Write-Output 'Cleanup'
    [IO.File]::WriteAllBytes($TestFile, $Original)
    Check 'modified file restored' (-not ((Get-Content -LiteralPath $TestFile -Raw) -match [regex]::Escape($Marker)))
    if (Test-Path -LiteralPath $Scratch) { Remove-Item -LiteralPath $Scratch -Force }
    Check 'scratch file removed' (-not (Test-Path -LiteralPath $Scratch))

    $Final = Vcs @('status')
    Check 'workspace back to its starting state' `
          ($Final -notmatch 'accurev_probe_delete_me' -and $Final -notmatch [regex]::Escape($Marker)) `
          'Check `accurev stat --outgoing` by hand.'
}

Write-Output ''
Write-Output "=============================================="
Write-Output "  $Script:Pass passed, $Script:Fail failed"
if ($Script:Notes.Count) {
    Write-Output ''
    foreach ($n in $Script:Notes) { Write-Output "  note: $n" }
}
Write-Output "=============================================="
Write-Output ''

if ($Script:Fail -gt 0) {
    Write-Output 'Send the whole output above back. A FAIL on check 3 or 4 means the'
    Write-Output 'fix did not work on AccuRev and vcs.ps1 needs more work.'
    exit 1
}
Write-Output 'All checks passed. The AccuRev half of vcs.ps1 works against a real workspace.'
exit 0
