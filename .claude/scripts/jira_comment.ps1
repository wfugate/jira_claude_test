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
    [switch] $SetDescription,
    [string] $AppendDescription = '',   # legacy: the dated change-log line
    [string] $VisibilityRole    = '',
    [switch] $SelfTest,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Force UTF-8 on our own output. Without it, PowerShell best-fit-maps characters
# the console codepage cannot represent - U+2014 silently becomes a plain "-".
# That made -DryRun misrepresent the payload it was meant to let you inspect,
# which is the one job a dry run has.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Shared plumbing lives in jira_lib.ps1 (auth, ADF conversion, the HTTP call,
# change-log append). It has no param block, so it can be dot-sourced -- this
# script's mandatory -Issue would otherwise be demanded of anything that tried
# to reuse its functions.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'jira_lib.ps1')


# ========================= main =========================================

if ($MyInvocation.InvocationName -eq '.') { return }

# ---- append one line to the description's change log -------------------
if ($SetDescription) {
    <#
      Replace the description with new text read from stdin.

      THIS IS THE ONE DESTRUCTIVE OPERATION IN THE TOOL, and it replaces one
      that could not be. The old -AppendDescription could only add, and
      Assert-DescriptionSurvived refused to send a document that had lost any of
      the original -- a guarantee added after review found that a depth
      truncation bug could silently delete human-authored acceptance criteria.

      An update cannot keep that guarantee, because removing text is now
      legitimate. Three things replace it:

        1. The human approves the FULL proposed text in the conversation before
           this script is ever called. That is the real gate.
        2. A shrink guard below refuses a drastic reduction outright.
        3. The diff is printed on every run, so what changed is on the record
           even when nobody reads it at the time.

      KNOWN COST: the round trip through plain text flattens structure. Headings
      and bullet lists in the existing description come back as paragraphs and
      hard breaks. Acceptable for the short prose descriptions this is aimed at;
      not acceptable for a heavily formatted one, and the diff will show it.
    #>
    $Utf8    = New-Object System.Text.UTF8Encoding($false)
    $NewText = (New-Object IO.StreamReader([Console]::OpenStandardInput(), $Utf8)).ReadToEnd()
    if (-not $NewText -or -not $NewText.Trim()) {
        throw 'No description on stdin. Pipe the full replacement text in.'
    }
    $NewText = $NewText.Trim()

    $Data    = Invoke-Jira -Method 'GET' -Path "/rest/api/3/issue/$Issue`?fields=description"
    $OldDoc  = $Data.fields.description
    $OldText = if ($OldDoc -is [string]) { $OldDoc }
               elseif ($OldDoc)          { (Convert-AdfToText -Node $OldDoc).ToString().Trim() }
               else                      { '' }

    # Shrink guard. Not a no-deletion rule -- deletion is the point -- but losing
    # half the description is far more likely to be a bug than an intention.
    if ($OldText.Length -gt 200 -and $NewText.Length -lt ($OldText.Length * 0.5)) {
        Write-Output "!! REFUSING: the new description is $($NewText.Length) chars against $($OldText.Length) now."
        Write-Output '!! That is more than half the text gone. If the cut is deliberate, make it'
        Write-Output '!! by hand in Jira - this script will not do it.'
        exit 1
    }

    $OldLines = @($OldText -split "`r?`n")
    $NewLines = @($NewText -split "`r?`n")
    Write-Output "Description diff for $Issue`:"
    $Diff = Compare-Object -ReferenceObject $OldLines -DifferenceObject $NewLines
    if (-not @($Diff).Count) {
        Write-Output '  (identical - nothing to do)'
        exit 0
    }
    foreach ($d in @($Diff)) {
        $mark = if ($d.SideIndicator -eq '=>') { '  + ' } else { '  - ' }
        Write-Output "$mark$($d.InputObject)"
    }
    Write-Output ''

    $Doc = ConvertTo-Adf -Text $NewText

    if ($DryRun) {
        Write-Output 'DRY RUN - nothing sent.'
        exit 0
    }

    Invoke-Jira -Method 'PUT' -Path "/rest/api/3/issue/$Issue" `
                -Body @{ fields = @{ description = $Doc } } | Out-Null
    Write-Output "Description updated on $Issue."
    exit 0
}

if ($AppendDescription) {
    # Date AND TIME, because this stamp is the watermark as well as a human
    # label. With date only it parses to midnight, so a second run on the same
    # day re-read the sessions the first run had already published -- which is
    # the ordinary case, not an edge one: people post an update and keep working.
    $Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

    # A read-modify-write, unlike posting a comment. The whole GET/append/PUT
    # cycle happens inside this script: the existing description text is never
    # handed to the model. That is deliberate -- it keeps this inside the data
    # decision already made about source code.
    #
    # -DryRun takes THE SAME PATH, only stopping before the PUT. An earlier
    # version previewed against an empty document instead, which meant the one
    # safety valve in the tool structurally could not reveal a fault in the one
    # destructive operation in the tool.
    $Data    = Invoke-Jira -Method 'GET' -Path "/rest/api/3/issue/$Issue`?fields=description"
    $Updated = Add-ChangeLogLine -Existing $Data.fields.description -Line $AppendDescription -Stamp $Stamp

    # Refuse to send anything that has lost part of the original. Throws.
    Assert-DescriptionSurvived -Original $Data.fields.description -Updated $Updated

    if ($DryRun) {
        Write-Output "Would append to $Issue description:"
        Write-Output "  $Stamp - $($AppendDescription.Trim())"
        Write-Output ''
        Write-Output 'The document that WOULD be sent (existing content verified intact):'
        Write-Output ($Updated | ConvertTo-Json -Depth 100)
        exit 0
    }

    Invoke-Jira -Method 'PUT' -Path "/rest/api/3/issue/$Issue" `
                -Body @{ fields = @{ description = $Updated } } | Out-Null
    Write-Output "Appended one line to $Issue description."
    Write-Output ''
    Write-Output '   That line is the watermark. The next run reads only sessions modified'
    Write-Output '   after today, so this reasoning will not be offered to another ticket.'
    exit 0
}

# ---- post a comment ----------------------------------------------------
if ($SelfTest) {
    $Text = 'Test comment from jira_comment.ps1. Auth and formatting are working.'
} else {
    # Read the raw stream and decode UTF-8 explicitly.
    #
    # [Console]::In is NOT the raw path - it decodes using
    # [Console]::InputEncoding, which in a redirected process is the OEM codepage
    # (IBM437 on this machine). Piping U+2014 in produced three CP437 characters,
    # which ConvertTo-Adf then wrapped and POSTed. This is the last hop before a
    # permanent Jira comment, so it is the worst place in the tool to mangle
    # text.
    #
    # The Python original got this right (sys.stdin.buffer.read().decode) and the
    # port lost it. Unlike the output side, [Console]::InputEncoding cannot be
    # relied on here, so bypass it entirely.
    $Text = (New-Object IO.StreamReader(
                 [Console]::OpenStandardInput(),
                 (New-Object System.Text.UTF8Encoding($false)))).ReadToEnd()
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

# NOTHING FURTHER IS REQUIRED AFTER A COMMENT POSTS.
#
# There were two warnings here in turn, and both outlived their design. The
# first told you to mark records consumed, from the record store. The second
# told you to append a change-log line, from the dated-watermark design. Each
# survived the thing it protected, and each then instructed a reader to do
# something the command body forbids.
#
# The comment's own timestamp is now the watermark, so posting it IS the
# complete operation. If a third warning is ever wanted here, check first that
# what it protects still exists.
Write-Output ''
Write-Output "   This comment's timestamp is now the watermark: the next run reads only"
Write-Output '   sessions modified after it. Nothing further is required.'
Write-Output ''
