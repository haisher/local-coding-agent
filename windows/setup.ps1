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

$InstallQwenCode = $true
$TunedName = 'qcoder'

$UpdateModels = $false
$MaxSettingsBackups = 10
$IgnoreOllamaCodeIntegrityBlock = $false

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

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    process {
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $result[$key] = ConvertTo-Hashtable $InputObject[$key]
            }
            return $result
        }
        if ($InputObject -is [Management.Automation.PSCustomObject]) {
            $result = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = ConvertTo-Hashtable $property.Value
            }
            return $result
        }
        if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
        }
        return $InputObject
    }
}

function Merge-Hashtable {
    param(
        [Collections.IDictionary]$Existing,
        [Collections.IDictionary]$Owned
    )

    $result = [ordered]@{}
    foreach ($key in $Existing.Keys) {
        $result[$key] = $Existing[$key]
    }
    foreach ($key in $Owned.Keys) {
        if (
            $result.Contains($key) -and
            $result[$key] -is [Collections.IDictionary] -and
            $Owned[$key] -is [Collections.IDictionary]
        ) {
            $result[$key] = Merge-Hashtable $result[$key] $Owned[$key]
        }
        else {
            $result[$key] = $Owned[$key]
        }
    }
    return $result
}

function New-ProviderEntry {
    param(
        [string]$Id,
        [string]$BaseModel,
        [int]$Context
    )

    return [ordered]@{
        id = $Id
        name = "$Id (local Ollama)"
        baseUrl = 'http://127.0.0.1:11434/v1'
        envKey = 'OLLAMA_API_KEY'
        description = "$BaseModel served locally via Ollama"
        generationConfig = [ordered]@{
            contextWindowSize = $Context
            timeout = 300000
        }
    }
}

function Get-DefaultTunedModel {
    if ($InstallModel) { return $TunedName }
    if ($InstallAgenticModel) { return $AgenticTunedName }
    if ($InstallGeneralModel) { return $GeneralTunedName }
    if ($InstallFastModel) { return $FastTunedName }
    return $null
}

function Backup-QwenSettings {
    param([string]$SettingsPath, [string]$QwenDirectory)

    $timestamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    Copy-Item -LiteralPath $SettingsPath -Destination "$SettingsPath.bak.$timestamp"
    Get-ChildItem -LiteralPath $QwenDirectory -Filter 'settings.json.bak.*' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxSettingsBackups |
        Remove-Item -Force
}

function Configure-QwenCode {
    $qwenDirectory = Join-Path $HOME '.qwen'
    $settingsPath = Join-Path $qwenDirectory 'settings.json'
    New-Item -ItemType Directory -Path $qwenDirectory -Force | Out-Null

    $providers = [Collections.Generic.List[object]]::new()
    $ownedIds = [Collections.Generic.List[string]]::new()

    if ($InstallModel) {
        $providers.Add((New-ProviderEntry $TunedName $Model $NumCtx))
        $ownedIds.Add($TunedName)
    }
    if ($InstallAgenticModel) {
        $providers.Add((New-ProviderEntry $AgenticTunedName $AgenticModel $AgenticNumCtx))
        $ownedIds.Add($AgenticTunedName)
    }
    if ($InstallGeneralModel) {
        $providers.Add((New-ProviderEntry $GeneralTunedName $GeneralModel $GeneralNumCtx))
        $ownedIds.Add($GeneralTunedName)
    }
    if ($InstallFastModel) {
        $providers.Add((New-ProviderEntry $FastTunedName $FastModel $FastNumCtx))
        $ownedIds.Add($FastTunedName)
    }

    $defaultModel = Get-DefaultTunedModel
    $owned = [ordered]@{
        modelProviders = [ordered]@{ openai = @($providers) }
        security = [ordered]@{ auth = [ordered]@{ selectedType = 'openai' } }
        model = [ordered]@{
            name = $defaultModel
            skipLoopDetection = $false
        }
        general = [ordered]@{
            showSessionRecap = $true
            checkpointing = [ordered]@{ enabled = $true }
        }
        memory = [ordered]@{ enableManagedAutoDream = $true }
        tools = [ordered]@{ approvalMode = 'auto-edit' }
        privacy = [ordered]@{ usageStatisticsEnabled = $false }
        ui = [ordered]@{ shellOutputMaxLines = 200 }
    }
    if ($InstallFastModel) {
        $owned['fastModel'] = $FastTunedName
    }

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        Backup-QwenSettings $settingsPath $qwenDirectory
        try {
            $rawSettings = Get-Content -LiteralPath $settingsPath -Raw
            $existing = ConvertTo-Hashtable ($rawSettings | ConvertFrom-Json)
        }
        catch {
            Write-WarningLog "$settingsPath is not valid JSON; it was backed up and will be replaced."
            $existing = [ordered]@{}
        }
    }

    $preservedProviders = @()
    if (
        $existing.Contains('modelProviders') -and
        $existing.modelProviders -is [Collections.IDictionary] -and
        $existing.modelProviders.Contains('openai')
    ) {
        $preservedProviders = @($existing.modelProviders.openai | Where-Object {
            $providerId = if ($_ -is [Collections.IDictionary]) { $_['id'] } else { $_.id }
            $ownedIds -notcontains $providerId
        })
    }

    $merged = Merge-Hashtable $existing $owned
    $merged.modelProviders.openai = @($preservedProviders) + @($providers)
    $json = $merged | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($settingsPath, "$json`r`n", [Text.UTF8Encoding]::new($false))

    $envPath = Join-Path $qwenDirectory '.env'
    $envLines = if (Test-Path -LiteralPath $envPath) {
        @(Get-Content -LiteralPath $envPath)
    }
    else {
        @()
    }
    if (-not ($envLines | Where-Object { $_ -match '^OLLAMA_API_KEY=' })) {
        Add-Content -LiteralPath $envPath -Value 'OLLAMA_API_KEY=ollama' -Encoding ASCII
        Write-Log "Wrote OLLAMA_API_KEY to $envPath"
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

    if ($InstallQwenCode -and -not (Test-Command 'rg.exe')) {
        Install-WingetPackage 'BurntSushi.ripgrep.MSVC' 'ripgrep'
    }

    if ($InstallQwenCode) {
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
        if (-not (Test-Command 'qwen.cmd')) {
            Write-Log 'Installing Qwen Code CLI...'
            & npm.cmd install -g '@qwen-code/qwen-code@latest'
            if ($LASTEXITCODE -ne 0) {
                throw 'npm failed to install Qwen Code CLI.'
            }
            Refresh-Path
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

    if ($InstallQwenCode) {
        Configure-QwenCode
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

    Write-Log 'Done. Start Qwen Code with: qwen'
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
