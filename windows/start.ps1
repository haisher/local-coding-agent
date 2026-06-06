#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =========================
# Configuration (edit here)
# =========================
$DefaultModel = 'general'
$AvailableModels = @('general')
$KeepAlive = '30m'
$OllamaFlashAttention = '1'
$OllamaKvCacheType = 'q8_0'
$ApiUrl = 'http://127.0.0.1:11434'

function Write-Log([string]$Message) {
    Write-Host "[start-windows] $Message"
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

    throw 'Ollama is not installed. Run setup.ps1 first.'
}

function Test-OllamaApi {
    try {
        Invoke-RestMethod -Uri "$ApiUrl/api/version" -Method Get -TimeoutSec 5 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Wait-ForOllama {
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        if (Test-OllamaApi) {
            return
        }
        Start-Sleep -Seconds 1
    }

    $errorLog = Join-Path $env:TEMP 'ollama-start-error.log'
    throw "Ollama did not start. Check $errorLog."
}

function Start-Ollama([string]$OllamaExe) {
    if (Test-OllamaApi) {
        Write-Log 'Ollama is already running.'
        return
    }

    $env:OLLAMA_FLASH_ATTENTION = $OllamaFlashAttention
    $env:OLLAMA_KV_CACHE_TYPE = $OllamaKvCacheType

    # Avoid a PowerShell 5.1 Start-Process failure when both Path and PATH exist.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$userPath", 'Process')

    $outputLog = Join-Path $env:TEMP 'ollama-start.log'
    $errorLog = Join-Path $env:TEMP 'ollama-start-error.log'
    Write-Log 'Starting Ollama...'
    Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden `
        -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog | Out-Null
    Wait-ForOllama
    Write-Log 'Ollama is running.'
}

function Preload-Model([string]$Model) {
    $installed = Invoke-RestMethod -Uri "$ApiUrl/api/tags" -Method Get -TimeoutSec 10
    $installedNames = @($installed.models | ForEach-Object {
        if ($_.name) { $_.name } else { $_.model }
    })
    if ($installedNames -notcontains $Model -and $installedNames -notcontains "${Model}:latest") {
        throw "Model '$Model' is not installed. Run setup.ps1 first."
    }

    Write-Log "Preloading model: $Model"
    $body = @{
        model = $Model
        messages = @()
        keep_alive = $KeepAlive
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$ApiUrl/api/chat" -Method Post -ContentType 'application/json' `
        -Body $body -TimeoutSec 300 | Out-Null
}

try {
    $warm = $false
    if ($args.Count -gt 1 -or ($args.Count -eq 1 -and $args[0] -ne '--warm')) {
        throw 'Only --warm is supported.'
    }
    if ($args.Count -eq 1) {
        $warm = $true
    }

    $ollamaExe = Get-OllamaExecutable
    Start-Ollama $ollamaExe

    if ($warm) {
        Preload-Model $DefaultModel
    }

    Write-Log 'Ready. Use qwen in your project.'
    Write-Log "Models: $($AvailableModels -join ', ')"
}
catch {
    Write-Host ''
    Write-Host "[start-windows] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
