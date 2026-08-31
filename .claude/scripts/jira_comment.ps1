# jira_comment.ps1 -- posts a comment to a Jira issue, and appends one line to
# the issue description's change log.
#
# This is the ONLY file that writes to Jira. Nothing else in the tool does, and
# nothing here runs without the developer having approved the draft first.
#
# Usage:
#   "text" | jira_comment.ps1 -Issue ABC-123                 post a comment
#   jira_comment.ps1 -Issue ABC-123 -SelfTest                prove auth works
#   jira_comment.ps1 -Issue ABC-123 -AppendDescription "..."  add a change-log line
#   "text" | jira_comment.ps1 -Issue ABC-123 -DryRun         show, send nothing
#
# Credentials come from the environment, never from a file in the repo:
#   JIRA_URL    https://yourcompany.atlassian.net
#   JIRA_USER   your full email address (NOT a username -- the commonest cause
#               of a 401 here)
#   JIRA_TOKEN  an API token from id.atlassian.com
#
# Why environment variables: Claude Code has shell access in the repo, so
# anything written to disk there can end up in a transcript. Environment
# variables stay out of reach.

param(
    [Parameter(Mandatory)] [string] $Issue,
    [string] $AppendDescription = '',
    [string] $VisibilityRole    = '',
    [switch] $SelfTest,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Shared plumbing lives in jira_lib.ps1 (auth, ADF conversion, the HTTP call,
# change-log append). It has no param block, so it can be dot-sourced -- this
# script's mandatory -Issue would otherwise be demanded of anything that tried
# to reuse its functions.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'jira_lib.ps1')


# ========================= main =========================================

if ($MyInvocation.InvocationName -eq '.') { return }

# ---- append one line to the description's change log -------------------
if ($AppendDescription) {
    $Stamp = Get-Date -Format 'yyyy-MM-dd'

    if ($DryRun) {
        $Preview = Add-ChangeLogLine -Existing $null -Line $AppendDescription -Stamp $Stamp
        Write-Output "Would append to $Issue description:"
        Write-Output "  $Stamp - $($AppendDescription.Trim())"
        Write-Output ''
        Write-Output ($Preview | ConvertTo-Json -Depth 20)
        exit 0
    }

    # A read-modify-write, unlike posting a comment. Note the whole GET/append/
    # PUT cycle happens inside this script: the existing description text is
    # never handed to the model. That is deliberate -- it keeps this inside the
    # data decision already made about source code.
    $Data    = Invoke-Jira -Method 'GET' -Path "/rest/api/3/issue/$Issue`?fields=description"
    $Updated = Add-ChangeLogLine -Existing $Data.fields.description -Line $AppendDescription -Stamp $Stamp

    Invoke-Jira -Method 'PUT' -Path "/rest/api/3/issue/$Issue" `
                -Body @{ fields = @{ description = $Updated } } | Out-Null
    Write-Output "Appended one line to $Issue description."
    exit 0
}

# ---- post a comment ----------------------------------------------------
if ($SelfTest) {
    $Text = 'Test comment from jira_comment.ps1. Auth and formatting are working.'
} else {
    # Read stdin as raw UTF-8. PowerShell's default would use the console
    # codepage and mangle every em dash on the way to a real ticket.
    $Text = [Console]::In.ReadToEnd()
}

if (-not $Text -or -not $Text.Trim()) {
    throw 'Nothing on stdin. Pipe the comment text in.'
}

$Body = @{ body = (ConvertTo-Adf -Text $Text) }
if ($VisibilityRole) {
    $Body['visibility'] = @{ type = 'role'; value = $VisibilityRole }
}

if ($DryRun) {
    Write-Output "POST /rest/api/3/issue/$Issue/comment"
    Write-Output ($Body | ConvertTo-Json -Depth 20)
    exit 0
}

$Result = Invoke-Jira -Method 'POST' -Path "/rest/api/3/issue/$Issue/comment" -Body $Body
Write-Output "Posted comment $($Result.id) to $Issue"
