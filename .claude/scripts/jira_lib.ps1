# jira_lib.ps1 -- shared Jira plumbing. No param block, so it can be
# dot-sourced safely.
#
# This file exists because of a PowerShell constraint: dot-sourcing a script
# that declares a mandatory parameter makes PowerShell demand that parameter,
# even though you only wanted its functions. jira_comment.ps1 has a mandatory
# -Issue, so ticket_context.ps1 could not reuse it. The shared parts live here
# instead and both scripts dot-source this.
#
# Nothing here performs an action on its own. Dot-source it:
#   . "$PSScriptRoot\jira_lib.ps1"

$Script:JiraTimeoutSec = 30

# Block-level ADF node types. After one, a newline keeps flattened text readable.
$Script:AdfBlockTypes = @('paragraph', 'heading', 'listItem', 'blockquote', 'codeBlock')


function Get-JiraCredentials {
    <#
      Credentials come from the environment, never from a file in the repo.

      WHY: Claude Code has shell access inside the repo, so anything written to
      disk there can end up in a transcript. Environment variables stay out of
      reach.

        JIRA_URL    https://yourcompany.atlassian.net
        JIRA_USER   your full email address -- NOT a username. This is the
                    single commonest cause of a 401 here.
        JIRA_TOKEN  an API token from id.atlassian.com
    #>
    $Url   = $env:JIRA_URL
    $User  = $env:JIRA_USER
    $Token = $env:JIRA_TOKEN

    $Missing = @()
    if (-not $Url)   { $Missing += 'JIRA_URL' }
    if (-not $User)  { $Missing += 'JIRA_USER' }
    if (-not $Token) { $Missing += 'JIRA_TOKEN' }
    if ($Missing.Count) { throw "Not set: $($Missing -join ', ')" }

    # Jira Cloud uses HTTP basic auth with the API token as the password.
    $Auth = [Convert]::ToBase64String(
                [Text.Encoding]::UTF8.GetBytes("${User}:${Token}"))

    return @{
        Url     = $Url.TrimEnd('/')
        Headers = @{ Authorization = "Basic $Auth"; Accept = 'application/json' }
    }
}


function ConvertTo-Adf {
    <#
      Turn plain text into an Atlassian Document Format document.

      Jira Cloud's v3 API will not accept a string for a comment body -- it
      wants a structured document. This exists so nothing else has to know that.

      Blank-line-separated blocks become paragraphs. Single newlines inside a
      block become hard breaks, which is what keeps an indented list looking
      like a list instead of one run-on line.
    #>
    param([Parameter(Mandatory)] [string] $Text)

    $Content = @()
    foreach ($Block in (($Text -replace "`r`n", "`n") -split "`n`n")) {
        $Block = $Block.Trim("`n")
        if (-not $Block.Trim()) { continue }

        $Nodes = @()
        $Lines = $Block -split "`n"
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($i -gt 0) { $Nodes += @{ type = 'hardBreak' } }
            if ($Lines[$i]) { $Nodes += @{ type = 'text'; text = $Lines[$i] } }
        }
        if ($Nodes.Count) { $Content += @{ type = 'paragraph'; content = $Nodes } }
    }

    if (-not $Content.Count) {
        $Content = @(@{ type = 'paragraph'
                        content = @(@{ type = 'text'; text = '(empty)' }) })
    }
    return @{ type = 'doc'; version = 1; content = $Content }
}


function Convert-AdfToText {
    <#
      Flatten an ADF document to plain text.

      Deliberately crude: the result is only used for matching session subject
      matter against a ticket, so structure does not need to survive. Enough
      shape to read, no more.
    #>
    param($Node, [System.Text.StringBuilder] $Builder = $null)

    if (-not $Builder) { $Builder = New-Object System.Text.StringBuilder }
    if ($null -eq $Node) { return $Builder }
    if ($Node -is [string]) { [void]$Builder.Append($Node); return $Builder }

    $Kind = $Node.type
    if     ($Kind -eq 'text')      { [void]$Builder.Append([string]$Node.text) }
    elseif ($Kind -eq 'hardBreak') { [void]$Builder.Append("`n") }

    foreach ($Child in @($Node.content)) {
        [void](Convert-AdfToText -Node $Child -Builder $Builder)
    }

    if ($Script:AdfBlockTypes -contains $Kind) { [void]$Builder.Append("`n") }
    return $Builder
}


function Invoke-Jira {
    <#
      One HTTP call. Maps the three failures that actually happen to their real
      causes, because "401" on its own sends people looking in the wrong place.
    #>
    param([Parameter(Mandatory)] [string] $Method,
          [Parameter(Mandatory)] [string] $Path,
          [hashtable] $Body = $null)

    $Cred = Get-JiraCredentials
    $Req = @{
        Uri         = "$($Cred.Url)$Path"
        Method      = $Method
        Headers     = $Cred.Headers
        TimeoutSec  = $Script:JiraTimeoutSec
        ErrorAction = 'Stop'
    }
    if ($Body) {
        # -Depth 100. The default of 2 truncates ADF instantly; 20 was not
        # enough either. ADF nests deeply - a table cell containing
        # nested bullets reaches depth 13 in ordinary use - and ConvertTo-Json
        # TRUNCATES past the limit into something structurally plausible rather
        # than failing. On the description PUT that is a permanent deletion of
        # human-authored content, reported as success.
        $Req['Body']        = ($Body | ConvertTo-Json -Depth 100 -Compress)
        $Req['ContentType'] = 'application/json; charset=utf-8'
    }

    try {
        return Invoke-RestMethod @Args
    } catch {
        $Code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $Hint = switch ($Code) {
            401     { 'Auth rejected. Check JIRA_USER is your full email address and the token is current.' }
            403     { 'Authenticated but not permitted. Can your account comment on this project?' }
            404     { 'Issue not found, or your account cannot see it. Check the key.' }
            default { '' }
        }
        throw "Jira returned $Code.`n$Hint`n$($_.Exception.Message)"
    }
}


function Test-HasChangeLogHeading {
    # Does the description already have our heading? Used so it is added once
    # and never duplicated.
    param($Doc)
    foreach ($Node in @($Doc.content)) {
        if ($Node.type -ne 'heading') { continue }
        $Text = (@($Node.content) | ForEach-Object { $_.text }) -join ''
        if ($Text.Trim().ToLower() -eq 'change log') { return $true }
    }
    return $false
}


function Add-ChangeLogLine {
    <#
      Return a NEW description document with one line appended under a
      "Change log" heading, creating the heading if it is absent.

      Everything above the heading is copied untouched. That is the whole safety
      property here: it appends, and it can never rewrite something a human
      wrote. The input is deep-copied through a JSON round-trip so the caller's
      object is never mutated.
    #>
    param($Existing,
          [Parameter(Mandatory)] [string] $Line,
          [Parameter(Mandatory)] [string] $Stamp)

    if (-not $Existing) {
        $Doc = @{ type = 'doc'; version = 1; content = @() }
    } elseif ($Existing -is [string]) {
        # Written through the older v2 API, so it is plain text. Preserve it as
        # paragraphs rather than discarding it.
        $Doc = ConvertTo-Adf -Text $Existing
    } else {
        $Doc = $Existing | ConvertTo-Json -Depth 100 | ConvertFrom-Json  # deep copy
    }

    $Content = @(if ($Doc.content) { $Doc.content } else { @() })

    if (-not (Test-HasChangeLogHeading $Doc)) {
        $Content += @{ type = 'heading'; attrs = @{ level = 3 }
                       content = @(@{ type = 'text'; text = 'Change log' }) }
    }
    $Content += @{ type = 'paragraph'
                   content = @(@{ type = 'text'; text = "$Stamp - $($Line.Trim())" }) }

    return @{ type = 'doc'; version = 1; content = $Content }
}


function Assert-DescriptionSurvived {
    <#
      Refuse to write a description that has lost any of the original.

      This is an append-only operation by contract, but it is implemented as a
      read-modify-write, so a serialisation fault is a permanent deletion of
      someone else's writing. Depth limits are one way that happens; there will
      be others. So rather than trusting the transform, check it: every original
      node must still be present, verbatim, in what we are about to send.

      Compares the serialised forms because ADF is a nested structure and a
      node-by-node walk would have to re-implement the comparison ADF already
      makes easy this way.
    #>
    param($Original, $Updated)

    if (-not $Original) { return }   # nothing to lose

    $Before = $Original | ConvertTo-Json -Depth 100 -Compress
    $After  = $Updated  | ConvertTo-Json -Depth 100 -Compress

    # Strip the outer braces: the original document is nested inside the new one,
    # so its body must appear as a substring.
    $Inner = $Before.Trim()
    if ($Inner.StartsWith('{')) { $Inner = $Inner.Substring(1) }
    if ($Inner.EndsWith('}'))   { $Inner = $Inner.Substring(0, $Inner.Length - 1) }

    # The content array is what must survive; version/type are rebuilt.
    $Marker = ($Original.content | ConvertTo-Json -Depth 100 -Compress)
    if ($Marker -and $Marker.Length -gt 2) {
        $Body = $Marker.Trim('[', ']')
        if ($Body -and -not $After.Contains($Body)) {
            throw ("Refusing to write the description: the existing content did " +
                   "not survive the append intact. Nothing was sent. This is the " +
                   "guard against silently deleting text somebody wrote.")
        }
    }
}
