# ticket_context.ps1 -- fetch a ticket's summary and description as plain text.
#
#   ticket_context.ps1 -Issue ABC-123
#
# THIS IS THE ONE PLACE TICKET PROSE REACHES THE MODEL, and it is deliberate.
#
# The rest of the tool keeps ticket content away from the model: the description
# append does its read-modify-write entirely inside jira_comment.ps1. But
# attribution -- deciding which captured sessions belong to this ticket -- is
# impossible without knowing what the ticket is about. So this is a bounded
# relaxation: summary and description only. Never comments, never other fields,
# never other issues.
#
# On failure it prints a plain message and exits 0 rather than throwing. The
# command that calls it then falls back to asking the developer which sessions
# belong, which is the correct behaviour -- better than failing the whole draft,
# and far better than guessing.

param([Parameter(Mandatory)] [string] $Issue)

$ErrorActionPreference = 'Stop'

$MaxDescChars = 4000   # a huge description would swamp the records it is meant
                       # to be compared against

# Shared plumbing: auth, the HTTP call, and ADF flattening.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'jira_lib.ps1')


# ========================= main =========================================

if ($MyInvocation.InvocationName -eq '.') { return }

# Credentials missing is a normal condition, not a crash: a developer may not
# have set them up yet. Say so clearly and let the caller ask instead.
foreach ($v in @('JIRA_URL', 'JIRA_USER', 'JIRA_TOKEN')) {
    if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue).Value) {
        Write-Output "COULD NOT READ TICKET $Issue - $v is not set"
        Write-Output 'Attribution cannot be automatic without the ticket. Ask which sessions belong before drafting.'
        exit 0
    }
}

try {
    $Data = Invoke-Jira -Method 'GET' -Path "/rest/api/3/issue/$Issue`?fields=summary,description"
} catch {
    Write-Output "COULD NOT READ TICKET $Issue - $($_.Exception.Message)"
    Write-Output 'Attribution cannot be automatic without the ticket. Ask which sessions belong before drafting.'
    exit 0
}

$Summary = if ($Data.fields.summary) { $Data.fields.summary } else { '(no summary)' }

$Desc = $Data.fields.description
if ($Desc -is [string]) {
    $Text = $Desc                                        # written via the v2 API
} elseif ($Desc) {
    $Text = (Convert-AdfToText -Node $Desc).ToString()    # v3 ADF document
} else {
    $Text = ''
}

# Collapse blank lines so the output stays compact.
$Lines = @($Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Text  = $Lines -join "`n"

# The watermark for the session search: when this tool last commented here.
# Printed even when empty, so the caller can tell "never written up" from
# "I forgot to look".
$LastUpdate = ''
try { $LastUpdate = Get-LastPostDate -Issue $Issue } catch { $LastUpdate = '' }

Write-Output "TICKET: $Issue"
Write-Output "SUMMARY: $Summary"
if ($LastUpdate) {
    Write-Output "LAST_UPDATE: $LastUpdate   (only read sessions modified after this)"
} else {
    Write-Output 'LAST_UPDATE: (none - no change log yet, so consider every session)'
}
Write-Output 'DESCRIPTION:'
if ($Text) {
    Write-Output $Text.Substring(0, [Math]::Min($MaxDescChars, $Text.Length))
    if ($Text.Length -gt $MaxDescChars) {
        Write-Output "... (truncated at $MaxDescChars chars)"
    }
} else {
    Write-Output '(empty)'
}
