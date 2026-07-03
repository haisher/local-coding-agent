#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =========================
# Configuration (edit here)
# =========================
$InstallModel = $true
$Model = 'qwen2.5-coder:7b'
$NumCtx = 24576
$NumPredict = 4096
$OllamaFlashAttention = '1'
$OllamaKvCacheType = 'q8_0'
$Temperature = 0.7
$TopP = 0.8
$TopK = 20
$RepeatPenalty = 1.1

$InstallFastModel = $true
$FastModel = 'qwen2.5-coder:3b'
$FastNumCtx = 32768
$FastNumPredict = 4096
$FastRepeatPenalty = 1.05
$FastTunedName = 'qcoder-fast'

$InstallAgenticModel = $true
$AgenticModel = 'granite4:7b-a1b-h'
$AgenticNumCtx = 32768
$AgenticNumPredict = 4096
$AgenticTemperature = 0.0
$AgenticTopP = 0.9
$AgenticTopK = 40
$AgenticRepeatPenalty = 1.05
$AgenticTunedName = 'agentic'

$InstallGeneralModel = $true
$GeneralModel = 'qwen3.5:4b'
$GeneralNumCtx = 32768
$GeneralNumPredict = 4096
$GeneralTemperature = 1.0
$GeneralTopP = 0.95
$GeneralTopK = 20
$GeneralRepeatPenalty = 1.0
$GeneralPresencePenalty = 1.5
$GeneralTunedName = 'general'

$InstallOpenCode = $true
$TunedName = 'qcoder'

$UpdateModels = $false
$IgnoreOllamaCodeIntegrityBlock = $false

# Optional: web search via Tavily MCP (disabled by default).
# 1. Get a free API key at https://app.tavily.com (1,000 searches/month).
# 2. Set $EnableWebSearch = $true and paste your key below.
# 3. Re-run .\setup.ps1 to apply.
# Privacy: when the agent invokes tavily_search, the search query leaves your
# machine and is sent to Tavily's API (api.tavily.com). Model inference, source
# code, and all other tool calls stay on localhost. Disable at any time by
# setting $EnableWebSearch = $false and re-running .\setup.ps1.
$EnableWebSearch = $false
$TavilyApiKey = ''     # e.g. tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

$ApiUrl = 'http://127.0.0.1:11434'
$OpenAiUrl = 'http://127.0.0.1:11434/v1/chat/completions'

function Write-Log([string]$Message) {
    Write-Host "[setup-windows] $Message"
}

function Write-WarningLog([string]$Message) {
    Write-Warning "[setup-windows] $Message"
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$userPath", 'Process')
}

function Test-Command([string]$Name) {
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    if (-not (Test-Command 'winget.exe')) {
        throw "winget is required to install $DisplayName. Install or update App Installer from Microsoft Store, then rerun this script."
    }

    Write-Log "Installing $DisplayName..."
    & winget.exe install --id $Id --exact --source winget --silent `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $DisplayName (exit code $LASTEXITCODE)."
    }
    Refresh-Path
}

function Get-OllamaExecutable {
    $command = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    throw 'Ollama was installed but ollama.exe could not be found. Open a new PowerShell window and rerun this script.'
}

function Wait-ForOllama {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            Invoke-RestMethod -Uri "$ApiUrl/api/version" -Method Get -TimeoutSec 5 | Out-Null
            return
        }
        catch {
            Start-Sleep -Seconds 1
        }
    }
    throw "Ollama did not start. Check $env:TEMP\ollama-setup-error.log."
}

function Start-OllamaServer([string]$OllamaExe) {
    try {
        Invoke-RestMethod -Uri "$ApiUrl/api/version" -Method Get -TimeoutSec 5 | Out-Null
        return
    }
    catch {
        Write-Log 'Starting Ollama server...'
    }

    $stdoutLog = Join-Path $env:TEMP 'ollama-setup.log'
    $stderrLog = Join-Path $env:TEMP 'ollama-setup-error.log'
    Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog | Out-Null
    Wait-ForOllama

    if (
        (Test-Path -LiteralPath $stderrLog) -and
        (Select-String -LiteralPath $stderrLog -Pattern 'Application Control policy has blocked this file' -Quiet)
    ) {
        Write-WarningLog 'Windows Application Control blocked Ollama GPU helper binaries. Ollama started, but inference may use CPU until the policy allows the Ollama installation directory.'
    }
}

function Assert-OllamaInferenceAllowed([string]$OllamaExe) {
    if ($IgnoreOllamaCodeIntegrityBlock) {
        return
    }

    $ollamaRoot = Split-Path -Parent $OllamaExe
    $smartAppControlState = (
        Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
            -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
    ).VerifiedAndReputablePolicyState
    if ($smartAppControlState -eq 0) {
        return
    }

    try {
        $blockedEvent = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-CodeIntegrity/Operational'
            Id = 3033, 3077
            StartTime = (Get-Date).AddDays(-1)
        } -ErrorAction Stop |
            Where-Object {
                $_.Message -match '\\Programs\\Ollama\\' -and
                $_.Message -match '\\lib\\ollama\\(libmtmd\.dll|llama-server\.exe)'
            } |
            Select-Object -First 1
    }
    catch {
        return
    }

    if ($blockedEvent) {
        throw @"
Windows Application Control is blocking Ollama inference binaries.

Blocked path: $ollamaRoot
Code Integrity event: $($blockedEvent.Id)

For a personal PC using Smart App Control, review:
Settings > Privacy & security > Windows Security > App & browser control > Smart App Control

Turning Smart App Control off lowers Windows security and cannot normally be undone without
resetting or reinstalling Windows. On a managed PC, ask the administrator to allow Ollama with
an App Control supplemental policy. Reinstalling Ollama alone will not resolve this policy block.

After resolving the policy, rerun this script. If an administrator has already added an exception
but this old event remains, set `$IgnoreOllamaCodeIntegrityBlock = `$true at the top of the script.
"@
    }
}

function Get-InstalledModelNames {
    try {
        $tags = Invoke-RestMethod -Uri "$ApiUrl/api/tags" -Method Get -TimeoutSec 10
        return @($tags.models | ForEach-Object {
            if ($_.name) { $_.name } else { $_.model }
        })
    }
    catch {
        return @()
    }
}

function Format-Invariant([object]$Value) {
    if ($Value -is [IFormattable]) {
        return $Value.ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function New-TunedModel {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Tuned,
        [Parameter(Mandatory = $true)][int]$Context,
        [double]$Repeat = $RepeatPenalty,
        [double]$Temp = $Temperature,
        [double]$TopProbability = $TopP,
        [int]$TopTokens = $TopK,
        [int]$Predict = $NumPredict,
        [Nullable[double]]$Presence = $null
    )

    $installedModels = Get-InstalledModelNames
    if ($UpdateModels -or $installedModels -notcontains $Base) {
        Write-Log "Pulling $Base..."
        & $script:OllamaExe pull $Base
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to pull Ollama model $Base."
        }
    }

    $safeName = $Tuned -replace '[:/\\]', '-'
    $modelFile = Join-Path $script:TempDir "Modelfile-$safeName"
    $lines = @(
        "FROM $Base"
        "PARAMETER num_ctx $(Format-Invariant $Context)"
        "PARAMETER num_predict $(Format-Invariant $Predict)"
        "PARAMETER temperature $(Format-Invariant $Temp)"
        "PARAMETER top_p $(Format-Invariant $TopProbability)"
        "PARAMETER top_k $(Format-Invariant $TopTokens)"
        "PARAMETER repeat_penalty $(Format-Invariant $Repeat)"
    )
    if ($null -ne $Presence) {
        $lines += "PARAMETER presence_penalty $(Format-Invariant $Presence)"
    }
    if ($lines | Where-Object { $_ -match '^PARAMETER\s+\S+\s*$' }) {
        throw "Generated Modelfile for $Tuned contains an empty parameter value."
    }
    [IO.File]::WriteAllLines($modelFile, $lines, [Text.UTF8Encoding]::new($false))

    & $script:OllamaExe create $Tuned -f $modelFile
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create Ollama model alias $Tuned."
    }
    Write-Log "Prepared model alias: $Tuned"
}

function New-ModelEntry {
    param(
        [string]$Id,
        [string]$Label
    )

    return [ordered]@{ name = "$Id ($Label)" }
}

function Get-DefaultTunedModel {
    if ($InstallModel) { return $TunedName }
    if ($InstallAgenticModel) { return $AgenticTunedName }
    if ($InstallGeneralModel) { return $GeneralTunedName }
    if ($InstallFastModel) { return $FastTunedName }
    return $null
}

function Configure-OpenCode {
    $openCodeDirectory = Join-Path $HOME '.config\opencode'
    $configPath = Join-Path $openCodeDirectory 'opencode.json'
    New-Item -ItemType Directory -Path $openCodeDirectory -Force | Out-Null

    # This script is the sole owner of opencode.json (no manual-edit merging
    # is needed/supported) — it is regenerated from the config variables
    # above on every run, so re-running setup.ps1 is always idempotent and
    # reproducible.

    # --- Provider: a single "ollama" custom OpenAI-compatible provider
    # exposing every tuned local alias this setup creates. ---
    $models = [ordered]@{}
    $models[$TunedName] = New-ModelEntry $TunedName 'daily driver'
    if ($InstallAgenticModel) {
        $models[$AgenticTunedName] = New-ModelEntry $AgenticTunedName 'tool calling'
    }
    if ($InstallGeneralModel) {
        $models[$GeneralTunedName] = New-ModelEntry $GeneralTunedName 'general chat/reasoning'
    }
    if ($InstallFastModel) {
        $models[$FastTunedName] = New-ModelEntry $FastTunedName 'fast/background'
    }

    # --- MCP servers: git and memory are always included; Tavily is optional ---
    $memoryFilePath = Join-Path $openCodeDirectory 'mcp-memory.jsonl'
    $mcp = [ordered]@{
        git    = [ordered]@{
            type    = 'local'
            command = @('uvx', 'mcp-server-git')
            enabled = $true
        }
        memory = [ordered]@{
            type        = 'local'
            command     = @('npx', '-y', '@modelcontextprotocol/server-memory')
            environment = [ordered]@{ MEMORY_FILE_PATH = $memoryFilePath }
            enabled     = $true
        }
    }
    if ($EnableWebSearch) {
        $mcp['tavily'] = [ordered]@{
            type    = 'remote'
            url     = "https://mcp.tavily.com/mcp/?tavilyApiKey=$TavilyApiKey"
            enabled = $true
        }
        Write-Log 'Web search: Tavily MCP will be configured in opencode.json.'
    }
    $mcpNote = if ($EnableWebSearch) { ', tavily (remote)' } else { '' }
    Write-Log "MCP servers configured: git (uvx), memory (npx)$mcpNote"

    $config = [ordered]@{
        '$schema'   = 'https://opencode.ai/config.json'
        share       = 'disabled'
        autoupdate  = 'notify'
        model       = "ollama/$TunedName"
    }
    if ($InstallFastModel) {
        $config['small_model'] = "ollama/$FastTunedName"
    }
    $config['permission'] = [ordered]@{
        edit     = 'allow'
        bash     = 'ask'
        webfetch = 'ask'
    }
    $config['provider'] = [ordered]@{
        ollama = [ordered]@{
            npm     = '@ai-sdk/openai-compatible'
            name    = 'Ollama (local)'
            options = [ordered]@{ baseURL = 'http://127.0.0.1:11434/v1' }
            models  = $models
        }
    }
    $config['mcp'] = $mcp

    # Write the full config directly (this file is fully generated, not
    # hand-edited) and atomically replace any previous version.
    $json = $config | ConvertTo-Json -Depth 100
    $tempConfigPath = Join-Path $script:TempDir 'opencode.json'
    [IO.File]::WriteAllText($tempConfigPath, "$json`r`n", [Text.UTF8Encoding]::new($false))
    try {
        Get-Content -LiteralPath $tempConfigPath -Raw | ConvertFrom-Json | Out-Null
    }
    catch {
        throw "Generated opencode config is not valid JSON: $($_.Exception.Message)"
    }
    Move-Item -LiteralPath $tempConfigPath -Destination $configPath -Force
    Write-Log "Wrote $configPath"

    # Personal, non-git-shared default instructions. Seeded once; re-running
    # setup.ps1 never overwrites it so any personal notes added later survive.
    $globalAgentsMd = Join-Path $openCodeDirectory 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $globalAgentsMd)) {
        $agentsContent = @'
# Personal defaults (local-coding-agent)

- This is a fully local, offline setup (Ollama + OpenCode). Prefer the local
  `git` and `memory` MCP tools over re-deriving the same information.
- Do not add a "Co-authored-by" trailer to git commits unless explicitly asked.
- Keep explanations concise; this is a terminal workflow.
'@
        [IO.File]::WriteAllText($globalAgentsMd, $agentsContent, [Text.UTF8Encoding]::new($false))
        Write-Log "Wrote default global instructions to $globalAgentsMd"
    }
}


function Test-OpenAiModel([string]$Name) {
    $body = @{
        model = $Name
        messages = @(@{ role = 'user'; content = 'Reply with OK' })
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri $OpenAiUrl -Method Post -ContentType 'application/json' `
            -Body $body -TimeoutSec 300
        if (-not $response.choices[0].message.content) {
            Write-WarningLog "Unexpected OpenAI response for $Name."
            return $false
        }
        return $true
    }
    catch {
        Write-WarningLog "OpenAI endpoint request failed for ${Name}: $($_.Exception.Message)"
        return $false
    }
}

function Preload-Model([string]$Name, [string]$KeepAlive = '30m') {
    $body = @{
        model = $Name
        messages = @()
        keep_alive = $KeepAlive
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$ApiUrl/api/chat" -Method Post -ContentType 'application/json' `
        -Body $body -TimeoutSec 300 | Out-Null
}

if ($args.Count -ne 0) {
    throw 'No runtime arguments are supported. Edit the configuration at the top of this file.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script is for Windows only.'
}

Write-Log 'This setup expects Windows 11, internet access, winget, and permission to install applications.'
if (-not (Get-DefaultTunedModel)) {
    throw 'At least one model install flag must be enabled.'
}
if ($EnableWebSearch -and [string]::IsNullOrWhiteSpace($TavilyApiKey)) {
    throw 'EnableWebSearch is $true but TavilyApiKey is empty. Paste your key in the config section.'
}
$script:TempDir = Join-Path ([IO.Path]::GetTempPath()) "setup-windows-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $script:TempDir | Out-Null

try {
    if (-not (Test-Command 'ollama.exe')) {
        $knownOllama = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (-not (Test-Path -LiteralPath $knownOllama)) {
            Install-WingetPackage 'Ollama.Ollama' 'Ollama'
        }
    }
    $script:OllamaExe = Get-OllamaExecutable

    if ($InstallOpenCode) {
        if (-not (Test-Command 'git.exe')) {
            Install-WingetPackage 'Git.Git' 'Git'
        }
        $nodeMajor = 0
        $nodeCommand = Get-Command 'node.exe' -ErrorAction SilentlyContinue
        if ($nodeCommand) {
            $nodeMajor = $nodeCommand.Version.Major
            if ($nodeMajor -le 0) {
                $nodeFileVersion = (Get-Item -LiteralPath $nodeCommand.Source).VersionInfo.ProductVersion
                if ($nodeFileVersion -match '^(\d+)') {
                    $nodeMajor = [int]$Matches[1]
                }
            }
        }
        if ($nodeMajor -lt 22) {
            Install-WingetPackage 'OpenJS.NodeJS.LTS' 'Node.js LTS'
        }
        if (-not (Test-Command 'npm.cmd')) {
            throw 'npm was not found after installing Node.js. Open a new PowerShell window and rerun this script.'
        }
        if (-not (Test-Command 'opencode.cmd')) {
            Write-Log 'Installing opencode CLI...'
            & npm.cmd install -g 'opencode-ai@latest'
            if ($LASTEXITCODE -ne 0) {
                throw 'npm failed to install opencode CLI.'
            }
            Refresh-Path
        }

        # uv is required at runtime to launch mcp-server-git.
        if (-not (Test-Command 'uvx')) {
            Install-WingetPackage 'astral-sh.uv' 'uv'
        }
    }

    $ollamaEnvironmentChanged = $false
    foreach ($entry in @{
        OLLAMA_FLASH_ATTENTION = $OllamaFlashAttention
        OLLAMA_KV_CACHE_TYPE = $OllamaKvCacheType
    }.GetEnumerator()) {
        if ([Environment]::GetEnvironmentVariable($entry.Key, 'User') -ne $entry.Value) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'User')
            $ollamaEnvironmentChanged = $true
        }
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }

    if ($ollamaEnvironmentChanged) {
        Write-Log "Configuring Ollama environment (flash_attention=$OllamaFlashAttention, kv_cache=$OllamaKvCacheType)..."
        Get-Process -Name 'ollama', 'ollama app' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Start-OllamaServer $script:OllamaExe
    Assert-OllamaInferenceAllowed $script:OllamaExe

    if ($InstallModel) {
        New-TunedModel -Base $Model -Tuned $TunedName -Context $NumCtx
    }
    if ($InstallFastModel) {
        New-TunedModel -Base $FastModel -Tuned $FastTunedName -Context $FastNumCtx `
            -Repeat $FastRepeatPenalty -Predict $FastNumPredict
    }
    if ($InstallAgenticModel) {
        New-TunedModel -Base $AgenticModel -Tuned $AgenticTunedName -Context $AgenticNumCtx `
            -Repeat $AgenticRepeatPenalty -Temp $AgenticTemperature `
            -TopProbability $AgenticTopP -TopTokens $AgenticTopK -Predict $AgenticNumPredict
    }
    if ($InstallGeneralModel) {
        New-TunedModel -Base $GeneralModel -Tuned $GeneralTunedName -Context $GeneralNumCtx `
            -Repeat $GeneralRepeatPenalty -Temp $GeneralTemperature `
            -TopProbability $GeneralTopP -TopTokens $GeneralTopK -Predict $GeneralNumPredict `
            -Presence $GeneralPresencePenalty
    }

    if ($InstallOpenCode) {
        Configure-OpenCode
    }

    $failedModels = [Collections.Generic.List[string]]::new()
    if ($InstallModel -and -not (Test-OpenAiModel $TunedName)) {
        $failedModels.Add($TunedName)
    }
    if ($InstallFastModel -and -not (Test-OpenAiModel $FastTunedName)) {
        $failedModels.Add($FastTunedName)
    }
    if ($InstallAgenticModel -and -not (Test-OpenAiModel $AgenticTunedName)) {
        $failedModels.Add($AgenticTunedName)
    }
    if ($InstallGeneralModel -and -not (Test-OpenAiModel $GeneralTunedName)) {
        $failedModels.Add($GeneralTunedName)
    }
    if ($failedModels.Count -gt 0) {
        throw "Model validation failed: $($failedModels -join ', '). Setup is incomplete."
    }

    $defaultModel = Get-DefaultTunedModel
    Write-Log "Preloading default model: $defaultModel"
    try {
        Preload-Model $defaultModel '30m'
    }
    catch {
        Write-WarningLog "Unable to preload ${defaultModel}: $($_.Exception.Message)"
    }

    $processInfo = & $script:OllamaExe ps 2>$null
    if ($processInfo) {
        Write-Log 'ollama ps:'
        $processInfo | ForEach-Object { Write-Host $_ }
        $partiallyLoaded = @($processInfo | Select-Object -Skip 1 | Where-Object {
            $_ -and $_ -notmatch '100%\s+GPU'
        })
        if ($partiallyLoaded.Count -gt 0) {
            Write-WarningLog 'At least one loaded model may not be fully GPU-resident. Check VRAM and num_ctx.'
        }
    }

    Write-Log 'Done. Start OpenCode with: opencode'
}
catch {
    Write-Host ''
    Write-Host "[setup-windows] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force
    }
}
