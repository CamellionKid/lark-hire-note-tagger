[CmdletBinding()]
param(
    [string]$LarkCliPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:LARKSUITE_CLI_NO_UPDATE_NOTIFIER = '1'
$env:LARKSUITE_CLI_NO_SKILLS_NOTIFIER = '1'

function Resolve-LarkCliPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $resolved = Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop
        return $resolved.Path
    }

    $defaultPath = Join-Path $env:APPDATA 'npm\lark-cli.cmd'
    if (Test-Path -LiteralPath $defaultPath) {
        return (Resolve-Path -LiteralPath $defaultPath).Path
    }

    $command = Get-Command lark-cli.cmd -ErrorAction Stop
    return $command.Source
}

function Invoke-LarkJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [object]$StdinObject
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns native stderr lines into non-terminating
        # ErrorRecord objects. Keep collecting them so the JSON error envelope
        # can be parsed as a whole.
        $ErrorActionPreference = 'Continue'
        if ($null -ne $StdinObject) {
            $stdinJson = $StdinObject | ConvertTo-Json -Depth 20 -Compress
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
        return [pscustomobject]@{
            exit_code = $exitCode
            json = $null
            raw = $raw
            parse_error = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        exit_code = $exitCode
        json = $json
        raw = $raw
        parse_error = $null
    }
}

function Get-ConsoleUrl {
    param($Call)
    if ($null -ne $Call.json -and $null -ne $Call.json.error -and $null -ne $Call.json.error.console_url) {
        return [string]$Call.json.error.console_url
    }
    return $null
}

try {
    $script:LarkCli = Resolve-LarkCliPath -RequestedPath $LarkCliPath

    $userCheck = Invoke-LarkJson -Arguments @(
        'auth', 'check',
        '--scope', 'hire:note hire:note:readonly hire:talent:readonly',
        '--json'
    )

    $talentProbeParams = @{
        keyword = '__codex_hire_permission_probe_no_match__'
        page_size = 1
        sort_by = 2
        query_option = 'ignore_empty_error'
    }
    $talentProbe = Invoke-LarkJson -Arguments @(
        'api', 'GET', '/open-apis/hire/v1/talents',
        '--as', 'bot', '--params', '-', '--jq', '.'
    ) -StdinObject $talentProbeParams

    if ($null -eq $talentProbe.json -or $talentProbe.json.ok -ne $true) {
        $consoleUrl = Get-ConsoleUrl -Call $talentProbe
        $isScopeError = $null -ne $talentProbe.json -and $null -ne $talentProbe.json.error -and [int]$talentProbe.json.error.code -eq 99991672
        [pscustomobject]@{
            ok = $false
            status = $(if ($isScopeError) { 'human_action_required' } else { 'probe_failed' })
            stage = 'talent_scope'
            identity = 'bot'
            required_scopes = @('hire:talent:readonly')
            console_url = $consoleUrl
            user_token_check = $userCheck.json
            error = $talentProbe.json.error
            message = $(if ($isScopeError) { '应用管理员必须点击 console_url 申请 bot scope；agent 无法代办。' } else { 'Hire 人才权限探测失败。' })
        } | ConvertTo-Json -Depth 20
        exit 1
    }

    $noteProbeParams = @{
        talent_id = '__codex_hire_permission_probe__'
        page_size = 1
    }
    $noteProbe = Invoke-LarkJson -Arguments @(
        'api', 'GET', '/open-apis/hire/v1/notes',
        '--as', 'bot', '--params', '-', '--jq', '.'
    ) -StdinObject $noteProbeParams

    $noteReady = $null -ne $noteProbe.json -and $noteProbe.json.ok -eq $true
    if (-not $noteReady -and $null -ne $noteProbe.json -and $null -ne $noteProbe.json.error) {
        $noteCode = [int]$noteProbe.json.error.code
        if ($noteCode -in @(1002002, 1002102)) {
            $noteReady = $true
        }
    }

    if (-not $noteReady) {
        $consoleUrl = Get-ConsoleUrl -Call $noteProbe
        $isScopeError = $null -ne $noteProbe.json -and $null -ne $noteProbe.json.error -and [int]$noteProbe.json.error.code -eq 99991672
        [pscustomobject]@{
            ok = $false
            status = $(if ($isScopeError) { 'human_action_required' } else { 'probe_failed' })
            stage = 'note_scope'
            identity = 'bot'
            required_scopes = @('hire:note')
            acceptable_read_scope = 'hire:note:readonly'
            missing_scopes = $(if ($null -ne $noteProbe.json.error) { @($noteProbe.json.error.missing_scopes) } else { @() })
            console_url = $consoleUrl
            user_token_check = $userCheck.json
            error = $noteProbe.json.error
            message = $(if ($isScopeError) { '应用管理员必须点击 console_url 申请 bot scope；agent 无法代办。不要用 auth login 修复 bot scope。' } else { 'Hire 备注权限探测失败。' })
        } | ConvertTo-Json -Depth 20
        exit 1
    }

    [pscustomobject]@{
        ok = $true
        status = 'ready'
        identity = 'bot'
        scopes_verified_by_probe = @('hire:talent:readonly', 'hire:note_or_readonly')
        user_token_check = $userCheck.json
        message = 'Hire bot 人才读取与备注读取权限探测通过。'
    } | ConvertTo-Json -Depth 20
}
catch {
    [pscustomobject]@{
        ok = $false
        status = 'probe_failed'
        stage = 'script'
        message = $_.Exception.Message
    } | ConvertTo-Json -Depth 10
    exit 1
}
