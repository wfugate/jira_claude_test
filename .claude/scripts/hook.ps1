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
$Raw = [Console]::In.ReadToEnd()

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

$WorkerArgs = @(
    '-NoProfile'                    # don't run the user's profile: slow, and it
                                    # can print text that corrupts our output
    '-ExecutionPolicy', 'Bypass'    # this script ships in the repo unsigned
    '-File', (Join-Path $ScriptDir 'worker.ps1')
    '-Transcript', $Transcript
    '-SessionId',  $SessionId
    '-EndReason',  ([string]$Payload.reason)
)

Start-Process -FilePath 'powershell.exe' -ArgumentList $WorkerArgs `
              -WindowStyle Hidden | Out-Null

exit 0
