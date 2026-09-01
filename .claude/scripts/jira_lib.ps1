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


function Get-EnvSetting {
    <#
      Read a setting from the process environment, falling back to the
      PERSISTED user and machine values.

      WHY THE FALLBACK MATTERS. A process inherits its environment at launch.
      Set a user-level variable after the Claude Code desktop app is already
      running and the app never sees it -- nor does any subprocess it spawns --
      until the app is restarted. Meanwhile a terminal opened afterwards picks
      it up immediately, so the same command works by hand and fails inside
      Claude. That looks like a broken tool, and it cost a debugging cycle twice
      before this fallback existed.

      Reading the User and Machine scopes goes to the registry directly, so the
      value is found whenever it was set. Process scope still wins, so a
      deliberate per-session override behaves as expected.
    #>
    param([Parameter(Mandatory)] [string] $Name)

    foreach ($Scope in @('Process', 'User', 'Machine')) {
        try {
            $v = [Environment]::GetEnvironmentVariable($Name, $Scope)
            if ($v) { return $v }
        } catch { }   # Machine scope can be unreadable under some policies
    }
    return $null
}


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
    $Url   = Get-EnvSetting 'JIRA_URL'
    $User  = Get-EnvSetting 'JIRA_USER'
    $Token = Get-EnvSetting 'JIRA_TOKEN'

    $Missing = @()
    if (-not $Url)   { $Missing += 'JIRA_URL' }
    if (-not $User)  { $Missing += 'JIRA_USER' }
    if (-not $Token) { $Missing += 'JIRA_TOKEN' }
    if ($Missing.Count) {
        throw ("Not set: $($Missing -join ', '). Checked the process, user and " +
               "machine environments. Set them at user level - see INSTALL.md step 3.")
    }

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
        return Invoke-RestMethod @Req
    } catch {
        $Code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { $null }
        $Hint = switch ($Code) {
            401     { 'Auth rejected. Check JIRA_USER is your full email address and the token is current.' }
            403     { 'Authenticated but not permitted. Can your account comment on this project?' }
            # A 404 on an issue endpoint does NOT mean the key is wrong. Jira
            # answers 404 rather than 401 so it does not reveal whether an issue
            # exists to a caller it has not authenticated -- so an expired token
            # looks exactly like a typo. This hint used to say "check the key",
            # and an expired token cost a full debugging cycle chasing the key.
            404     { 'Issue not found, OR the token is expired/invalid - Jira returns 404 rather than 401 on issue reads so it does not leak whether an issue exists. Check auth first: a GET on /rest/api/3/myself returns 401 if the token is the problem, and 200 if the key is.' }
            default { '' }
        }
        # Read the response body. PS 5.1 throws a WebException and does not
        # surface it, so a 400 - which is what a malformed ADF PUT returns, i.e.
        # the case that can damage a description - produced "Jira returned 400"
        # and nothing else. Jira's 400 bodies name the offending field, which
        # turns an unexplained failure into an actionable one.
        $Detail = ''
        if ($_.Exception.Response) {
            try {
                $Stream = $_.Exception.Response.GetResponseStream()
                $Detail = (New-Object IO.StreamReader(
                               $Stream, [Text.Encoding]::UTF8)).ReadToEnd()
                if ($Detail.Length -gt 800) { $Detail = $Detail.Substring(0, 800) }
            } catch { }
        }
        throw "Jira returned $Code.`n$Hint`n$Detail`n$($_.Exception.Message)"
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


function Get-LastPostDate {
    <#
      When did this tool last write up this ticket? Returns an ISO timestamp, or
      '' if it never has.

      THIS IS THE WATERMARK, and it is why no local state is needed: Jira
      already records when we posted, on the comment itself, to the
      millisecond. Nothing has to be written to the ticket for the sole purpose
      of being read back -- which is what the dated change-log line was.

      Only comments by the authenticated account count. A colleague's comment is
      not evidence that this tool wrote anything up.

      KNOWN EDGE: if the developer hand-comments on the ticket after a post, the
      watermark advances to that, and sessions in between are skipped. Rare, and
      it fails toward saying too little rather than republishing, which is the
      safer direction.
    #>
    param([Parameter(Mandatory)] [string] $Issue)

    try {
        $Me = Invoke-Jira -Method 'GET' -Path '/rest/api/3/myself'
    } catch {
        return ''   # cannot identify ourselves; caller falls back to no window
    }

    $c = Invoke-Jira -Method 'GET' `
             -Path "/rest/api/3/issue/$Issue/comment`?orderBy=-created&maxResults=25"

    foreach ($x in @($c.comments)) {
        if ($x.author.accountId -eq $Me.accountId) { return [string]$x.created }
    }
    return ''
}


function Get-LastChangeLogDate {
    <#
      The date of the most recent change-log entry, or '' if there is none.

      THIS IS THE WATERMARK, and it is why the tool needs no local state: Jira
      already records what has been written up. Bounding the session search by
      it is what stops a second run re-reading the sessions the first run
      already posted.

      Entries are written as "<yyyy-MM-dd HH:mm> - <line>" by Add-ChangeLogLine.
      We take the largest value found rather than the last node, because a human
      may have inserted a line by hand out of order.

      The time is optional in the pattern on purpose: entries written before the
      stamp gained a time still parse, and degrade to that day's midnight. That
      is the old day-granular behaviour for old entries only, rather than a
      crash or a silently ignored watermark.

      String comparison is safe here because the format sorts lexicographically.
    #>
    param($Doc)

    $Best = ''
    foreach ($Node in @($Doc.content)) {
        $Text = (@($Node.content) | ForEach-Object { $_.text }) -join ''
        $m = [regex]::Match($Text, '^\s*(\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2})?)\s*-\s')
        if ($m.Success -and $m.Groups[1].Value -gt $Best) { $Best = $m.Groups[1].Value }
    }
    return $Best
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
