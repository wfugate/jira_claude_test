# hook.ps1 -- runs when a Claude Code session ends.
#
# Registered in .claude/settings.json. Claude Code passes a JSON object on
# stdin describing the session that just finished.
#
# This script does as little as possible, for two reasons learned the hard way:
#
#   1. IT MUST NOT BLOCK. A SessionEnd hook is killed when the session tears
#      down. An earlier version ran the summarising call inline and Claude Code
#      reported "Hook cancelled" -- the work never finished. So the real work
#      goes to a separate process that outlives us, and this script returns at
#      once.
#
#   2. IT MUST NOT RECURSE. The worker asks Claude for a summary, which starts
#      another session, whose end fires THIS hook again -- forever. The guard
#      below stops that: we set an environment variable before spawning, and
#      exit immediately if we already see it. Child processes inherit their
#      parent's environment, so the marker is present in exactly the process
#      tree we created, and absent in any session a human starts.

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$NotesDir  = Join-Path (Split-Path -Parent $ScriptDir) 'ticket-notes'
$GuardName = 'UPDATEJIRA_HOOK_GUARD'

# Always drain stdin. If we exit without reading it, the writer can block.
#
# Read the raw stream and decode UTF-8 ourselves. [Console]::In decodes using
# [Console]::InputEncoding, which in a redirected process is the OEM codepage
# (IBM437 here) - so a non-ASCII character anywhere in the payload, such as an
# accented Windows user name inside the transcript path, arrives corrupted.
$Raw = (New-Object IO.StreamReader(
            [Console]::OpenStandardInput(),
            (New-Object System.Text.UTF8Encoding($false)))).ReadToEnd()

# --- TEMPORARY PROBE -- remove after the SessionEnd firing test ----------
# Records that this hook ran AT ALL, before the guard and before the spawn.
# Without it, "no record appeared" is ambiguous between three causes: the hook
# never fired, the hook fired but was guarded, or the worker died after being
# spawned. Writes outside the repo so it survives a clean checkout.
try {
    Add-Content -LiteralPath (Join-Path $env:TEMP 'sessionend-probe.log') `
        -Value ("{0}  guard={1}  {2}" -f (Get-Date -Format 'HH:mm:ss'),
                                          $env:UPDATEJIRA_HOOK_GUARD,
                                          ($Raw -replace '\s+', ' ')) `
        -ErrorAction SilentlyContinue
} catch { }

# --- The recursion guard -------------------------------------------------
# Set means: this session was started by our own machinery, not by a person.
if ($env:UPDATEJIRA_HOOK_GUARD) { exit 0 }

# --- Parse what Claude Code told us -------------------------------------
# Fields available: session_id, transcript_path, cwd, reason, prompt_id.
# We only need the first two. A malformed payload must not throw -- a broken
# hook that errors on every session end is worse than one that records nothing.
$SessionId  = ''
$Transcript = ''
try {
    $Payload    = $Raw | ConvertFrom-Json
    $SessionId  = [string]$Payload.session_id
    $Transcript = [string]$Payload.transcript_path
} catch {
    # Fall through with empty values; the worker records the failure so it is
    # visible rather than silent.
}

if (-not (Test-Path $NotesDir)) {
    New-Item -ItemType Directory -Path $NotesDir -Force | Out-Null
}

# --- Hand off to the detached worker ------------------------------------
# -WindowStyle Hidden and no -Wait: Start-Process returns immediately and the
# child is not tied to our lifetime, so it survives session teardown.
# Verified: a worker sleeping 25s still completed after the session had gone.
$env:UPDATEJIRA_HOOK_GUARD = '1'   # inherited by the child we are about to start

# TWO ARGUMENT-PASSING TRAPS, both of which silently stopped capture.
#
# 1. EMPTY ELEMENTS ABORT THE SPAWN. Start-Process -ArgumentList validates every
#    element as not-null-and-not-empty and rejects the whole array if any fails.
#    So the malformed-payload path above - whose comment promised "the worker
#    records the failure so it is visible" - never started the worker at all.
#    The same applied to any payload without a `reason` field, which a Claude
#    Code version change could introduce, stopping all capture with no symptom.
#    Placeholders keep the array well-formed and let the worker classify it.
#
# 2. ELEMENTS ARE NOT QUOTED. Start-Process joins them with spaces, so
#    C:\Users\Bob Smith\...\x.jsonl reached the worker as C:\Users\Bob. Windows
#    user names very often contain a space, and transcript paths always contain
#    the user name - so on such a machine every session would record
#    "transcript missing", forever. Quoting each path fixes it.
$SidArg = if ($SessionId)       { $SessionId }              else { 'unknown' }
$RsnArg = if ($Payload.reason)  { [string]$Payload.reason } else { 'unknown' }

$WorkerArgs = @(
    '-NoProfile'                    # don't run the user's profile: slow, and it
                                    # can print text that corrupts our output
    '-ExecutionPolicy', 'Bypass'    # this script ships in the repo unsigned
    '-File', ('"' + (Join-Path $ScriptDir 'worker.ps1') + '"')
    '-Transcript', ('"' + $Transcript + '"')   # quoted: spaces survive, and the
                                               # element is never empty
    '-SessionId',  $SidArg
    '-EndReason',  $RsnArg
)

# If the spawn itself fails there is no worker to record anything, so the hook
# has to do it. This is the only place the hook writes a record.
try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $WorkerArgs `
                  -WindowStyle Hidden -ErrorAction Stop | Out-Null
} catch {
    try {
        . (Join-Path $ScriptDir 'notes.ps1')
        Write-SessionRecord -Record @{
            session_id      = $SidArg
            transcript_path = $Transcript
            ended           = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            end_reason      = $RsnArg
            posted          = $false
            turns           = 0
            gate            = 'error'
            error           = "hook could not start the worker: $($_.Exception.Message)"
        } | Out-Null
    } catch {
        # Out of options. Exit 0 regardless: a hook that fails the session end
        # is worse than one that loses a record.
    }
}

exit 0
