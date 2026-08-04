[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [ValidateSet('SearchOnly', 'Preview', 'Write')][string]$Mode = 'SearchOnly',
    [ValidateSet(0, 1, 2)][int]$Privacy = 0,
    [switch]$ConfirmWrite,
    [string]$LarkCliPath,
    [string]$NotePrefix = '候选人标签：',
    [string]$TagSeparator = '、',
    [ValidateRange(1, 50)][int]$MaxSearchPages = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'

function Resolve-LarkCliPath {
    param([string]$RequestedPath)
    if ($RequestedPath) {
        return (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
    }
    $defaultPath = Join-Path $env:APPDATA 'npm\lark-cli.cmd'
    if (Test-Path -LiteralPath $defaultPath) {
        return (Resolve-Path -LiteralPath $defaultPath).Path
    }
    return (Get-Command lark-cli.cmd -ErrorAction Stop).Source
}

function Invoke-LarkJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [object]$StdinObject
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 represents native stderr as ErrorRecord
        # objects. Collect all lines before restoring strict error handling.
        $ErrorActionPreference = 'Continue'
        if ($null -ne $StdinObject) {
            $stdinJson = $StdinObject | ConvertTo-Json -Depth 30 -Compress
            $lines = @($stdinJson | & $script:LarkCli @Arguments 2>&1)
        }
        else {
            $lines = @(& $script:LarkCli @Arguments 2>&1)
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $raw = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    try {
        $json = $raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ exit_code = $exitCode; json = $null; raw = $raw; parse_error = $_.Exception.Message }
    }
    return [pscustomobject]@{ exit_code = $exitCode; json = $json; raw = $raw; parse_error = $null }
}

function Get-ApiError {
    param($Call)
    if ($null -eq $Call.json) {
        return [pscustomobject]@{ type = 'invalid_json'; message = $Call.parse_error; raw = $Call.raw }
    }
    if ($null -ne $Call.json.error) {
        return $Call.json.error
    }
    return [pscustomobject]@{ type = 'unknown'; message = 'lark-cli call failed without an error object'; raw = $Call.raw }
}

function Test-LarkSuccess {
    param($Call)
    return $null -ne $Call.json -and $Call.exit_code -eq 0 -and $Call.json.ok -eq $true
}

function Get-TalentPayload {
    param($EnvelopeData)
    if ($null -ne $EnvelopeData -and $EnvelopeData.PSObject.Properties.Name -contains 'talent') {
        return $EnvelopeData.talent
    }
    return $EnvelopeData
}

function Mask-Mobile {
    param([string]$Mobile)
    if ([string]::IsNullOrWhiteSpace($Mobile)) { return $null }
    if ($Mobile.Length -le 4) { return ('*' * $Mobile.Length) }
    return ('*' * ($Mobile.Length - 4)) + $Mobile.Substring($Mobile.Length - 4)
}

function Mask-Email {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email) -or -not $Email.Contains('@')) { return $null }
    $parts = $Email.Split('@', 2)
    $local = $parts[0]
    $maskedLocal = if ($local.Length -le 1) { '*' } else { $local.Substring(0, 1) + ('*' * ($local.Length - 1)) }
    return $maskedLocal + '@' + $parts[1]
}

function Convert-TalentCandidate {
    param($Talent)
    $basic = $Talent.basic_info
    return [pscustomobject]@{
        talent_id = [string]$Talent.id
        name = [string]$basic.name
        mobile = Mask-Mobile -Mobile ([string]$basic.mobile)
        email = Mask-Email -Email ([string]$basic.email)
    }
}

function Search-ExactTalents {
    param([string]$Name)
    $allItems = @()
    $pageToken = $null
    $page = 0
    $truncated = $false

    do {
        $page++
        $params = [ordered]@{
            keyword = $Name
            page_size = 20
            sort_by = 2
            query_option = 'ignore_empty_error'
        }
        if ($pageToken) { $params.page_token = $pageToken }

        $call = Invoke-LarkJson -Arguments @(
            'api', 'GET', '/open-apis/hire/v1/talents',
            '--as', 'bot', '--params', '-', '--jq', '.'
        ) -StdinObject $params
        if (-not (Test-LarkSuccess -Call $call)) {
            return [pscustomobject]@{ ok = $false; error = Get-ApiError -Call $call; candidates = @(); truncated = $false }
        }

        $allItems += @($call.json.data.items)
        $hasMore = [bool]$call.json.data.has_more
        $pageToken = if ($call.json.data.PSObject.Properties.Name -contains 'page_token') { [string]$call.json.data.page_token } else { $null }
        if ($hasMore -and $page -ge $MaxSearchPages) {
            $truncated = $true
            break
        }
    } while ($hasMore -and $pageToken)

    $exact = @($allItems | Where-Object { $null -ne $_.basic_info -and [string]$_.basic_info.name -ceq $Name })
    $candidates = @($exact | ForEach-Object { Convert-TalentCandidate -Talent $_ })
    return [pscustomobject]@{ ok = $true; error = $null; candidates = $candidates; truncated = $truncated }
}

function Verify-TalentOverride {
    param([string]$TalentId, [string]$ExpectedName)
    $encodedId = [uri]::EscapeDataString($TalentId)
    $call = Invoke-LarkJson -Arguments @(
        'api', 'GET', "/open-apis/hire/v1/talents/$encodedId",
        '--as', 'bot', '--jq', '.'
    )
    if (-not (Test-LarkSuccess -Call $call)) {
        return [pscustomobject]@{ ok = $false; error = Get-ApiError -Call $call; candidate = $null }
    }
    $talent = Get-TalentPayload -EnvelopeData $call.json.data
    $candidate = Convert-TalentCandidate -Talent $talent
    if ([string]$candidate.name -cne $ExpectedName) {
        return [pscustomobject]@{
            ok = $false
            error = [pscustomobject]@{ type = 'name_mismatch'; message = "talent_id 对应姓名 '$($candidate.name)'，与输入 '$ExpectedName' 不一致" }
            candidate = $candidate
        }
    }
    return [pscustomobject]@{ ok = $true; error = $null; candidate = $candidate }
}

function Get-AllNotes {
    param([string]$TalentId)
    $items = @()
    $pageToken = $null
    $page = 0
    do {
        $page++
        if ($page -gt 100) {
            return [pscustomobject]@{ ok = $false; error = [pscustomobject]@{ type = 'pagination_limit'; message = '备注分页超过 100 页，已停止' }; items = @() }
        }
        $params = [ordered]@{ talent_id = $TalentId; page_size = 200 }
        if ($pageToken) { $params.page_token = $pageToken }
        $call = Invoke-LarkJson -Arguments @(
            'api', 'GET', '/open-apis/hire/v1/notes',
            '--as', 'bot', '--params', '-', '--jq', '.'
        ) -StdinObject $params
        if (-not (Test-LarkSuccess -Call $call)) {
            return [pscustomobject]@{ ok = $false; error = Get-ApiError -Call $call; items = @() }
        }
        $items += @($call.json.data.items)
        $hasMore = [bool]$call.json.data.has_more
        $pageToken = if ($call.json.data.PSObject.Properties.Name -contains 'page_token') { [string]$call.json.data.page_token } else { $null }
    } while ($hasMore -and $pageToken)
    return [pscustomobject]@{ ok = $true; error = $null; items = $items }
}

function Create-Note {
    param([string]$TalentId, [string]$Content, [int]$NotePrivacy, [string]$ApplicationId)
    $body = [ordered]@{
        talent_id = $TalentId
        content = $Content
        privacy = $NotePrivacy
    }
    if (-not [string]::IsNullOrWhiteSpace($ApplicationId)) {
        $body.application_id = $ApplicationId
    }
    $call = Invoke-LarkJson -Arguments @(
        'api', 'POST', '/open-apis/hire/v1/notes',
        '--as', 'bot', '--data', '-', '--jq', '.'
    ) -StdinObject $body
    if (-not (Test-LarkSuccess -Call $call)) {
        return [pscustomobject]@{ ok = $false; error = Get-ApiError -Call $call; note = $null }
    }
    return [pscustomobject]@{ ok = $true; error = $null; note = $call.json.data }
}

function Normalize-InputRows {
    param([object[]]$Rows)
    $normalized = @()
    foreach ($row in $Rows) {
        $propertyNames = @($row.PSObject.Properties.Name)
        $name = if ($propertyNames -contains 'name' -and $null -ne $row.name) { ([string]$row.name).Trim() } else { '' }
        $rawTags = @()
        if ($propertyNames -contains 'tags' -and $null -ne $row.tags) { $rawTags = @($row.tags) }
        $tags = @($rawTags | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $normalized += [pscustomobject]@{
            name = $name
            tags = $tags
            talent_id = if ($propertyNames -contains 'talent_id' -and $null -ne $row.talent_id) { ([string]$row.talent_id).Trim() } else { '' }
            application_id = if ($propertyNames -contains 'application_id' -and $null -ne $row.application_id) { ([string]$row.application_id).Trim() } else { '' }
        }
    }
    return $normalized
}

try {
    if ($Mode -ne 'SearchOnly' -and $Privacy -notin @(1, 2)) {
        throw 'Preview/Write 模式必须显式传 -Privacy 1（私密）或 -Privacy 2（公开）。'
    }
    if ($Mode -eq 'Write' -and -not $ConfirmWrite) {
        throw 'Write 模式必须在用户确认预览后显式传 -ConfirmWrite。'
    }
    if ($Mode -ne 'Write' -and $ConfirmWrite) {
        throw '-ConfirmWrite 仅可与 -Mode Write 一起使用。'
    }

    $script:LarkCli = Resolve-LarkCliPath -RequestedPath $LarkCliPath
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    $inputText = Get-Content -LiteralPath $resolvedInput -Raw -Encoding UTF8
    $parsed = $inputText | ConvertFrom-Json
    $rows = Normalize-InputRows -Rows @($parsed)
    $results = @()

    foreach ($row in $rows) {
        $content = $NotePrefix + ($row.tags -join $TagSeparator)
        $baseResult = [ordered]@{
            name = $row.name
            talent_id = $null
            status = $null
            privacy = $(if ($Privacy -eq 1) { 'private' } elseif ($Privacy -eq 2) { 'public' } else { $null })
            content = $content
        }

        if ([string]::IsNullOrWhiteSpace($row.name) -or $row.tags.Count -eq 0) {
            $baseResult.status = 'invalid_input'
            $baseResult.reason = 'name 或 tags 为空'
            $results += [pscustomobject]$baseResult
            continue
        }

        $candidate = $null
        if (-not [string]::IsNullOrWhiteSpace($row.talent_id)) {
            $verified = Verify-TalentOverride -TalentId $row.talent_id -ExpectedName $row.name
            if (-not $verified.ok) {
                $baseResult.talent_id = $row.talent_id
                $baseResult.status = 'api_error'
                $baseResult.error = $verified.error
                $results += [pscustomobject]$baseResult
                continue
            }
            $candidate = $verified.candidate
        }
        else {
            $search = Search-ExactTalents -Name $row.name
            if (-not $search.ok) {
                $baseResult.status = 'api_error'
                $baseResult.error = $search.error
                $results += [pscustomobject]$baseResult
                continue
            }
            if ($search.truncated) {
                $baseResult.status = 'ambiguous'
                $baseResult.reason = 'search_truncated'
                $baseResult.candidates = $search.candidates
                $results += [pscustomobject]$baseResult
                continue
            }
            if ($search.candidates.Count -eq 0) {
                $baseResult.status = 'not_found'
                $results += [pscustomobject]$baseResult
                continue
            }
            if ($search.candidates.Count -gt 1) {
                $baseResult.status = 'ambiguous'
                $baseResult.candidates = $search.candidates
                $results += [pscustomobject]$baseResult
                continue
            }
            $candidate = $search.candidates[0]
        }

        $baseResult.talent_id = $candidate.talent_id
        if ($Mode -eq 'SearchOnly') {
            $baseResult.status = 'matched'
            $results += [pscustomobject]$baseResult
            continue
        }

        $notes = Get-AllNotes -TalentId $candidate.talent_id
        if (-not $notes.ok) {
            $baseResult.status = 'api_error'
            $baseResult.error = $notes.error
            $results += [pscustomobject]$baseResult
            continue
        }
        $duplicate = @($notes.items | Where-Object {
            $null -ne $_ -and $_.PSObject.Properties.Name -contains 'content' -and ([string]$_.content).Trim() -ceq $content.Trim()
        } | Select-Object -First 1)
        if ($duplicate.Count -gt 0) {
            $baseResult.status = 'skipped_duplicate'
            $baseResult.note_id = [string]$duplicate[0].id
            $results += [pscustomobject]$baseResult
            continue
        }

        if ($Mode -eq 'Preview') {
            $baseResult.status = 'would_create'
            $results += [pscustomobject]$baseResult
            continue
        }

        $created = Create-Note -TalentId $candidate.talent_id -Content $content -NotePrivacy $Privacy -ApplicationId $row.application_id
        if (-not $created.ok) {
            $baseResult.status = 'api_error'
            $baseResult.error = $created.error
            $results += [pscustomobject]$baseResult
            continue
        }
        $baseResult.status = 'created'
        if ($null -ne $created.note -and $created.note.PSObject.Properties.Name -contains 'id') {
            $baseResult.note_id = [string]$created.note.id
        }
        $results += [pscustomobject]$baseResult
    }

    $counts = [ordered]@{}
    foreach ($group in ($results | Group-Object status)) {
        $counts[$group.Name] = $group.Count
    }
    [pscustomobject]@{
        ok = $true
        mode = $Mode
        privacy = $(if ($Privacy -eq 1) { 'private' } elseif ($Privacy -eq 2) { 'public' } else { $null })
        counts = $counts
        results = $results
    } | ConvertTo-Json -Depth 30
}
catch {
    [pscustomobject]@{
        ok = $false
        mode = $Mode
        error = [pscustomobject]@{
            type = 'script_error'
            message = $_.Exception.Message
            location = $_.ScriptStackTrace
        }
    } | ConvertTo-Json -Depth 10
    exit 1
}
