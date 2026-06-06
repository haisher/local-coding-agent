#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =========================
# Configuration (edit here)
# =========================
$ApiUrl = 'http://127.0.0.1:11434'

function Write-Log([string]$Message) {
    Write-Host "[stop-windows] $Message"
}

function Write-WarningLog([string]$Message) {
    Write-Warning "[stop-windows] $Message"
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

function Stop-OllamaProcesses {
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('ollama', 'ollama app', 'llama-server')
    })

    if ($processes.Count -eq 0) {
        return $false
    }

    Write-Log 'Stopping Ollama...'

    # Stop inference children first, then the API host.
    $processes |
        Sort-Object @{ Expression = { if ($_.ProcessName -eq 'llama-server') { 0 } else { 1 } } } |
        ForEach-Object {
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    return $true
}

try {
    if ($args.Count -ne 0) {
        throw 'No runtime arguments are supported.'
    }

    $apiWasRunning = Test-OllamaApi
    $stoppedProcess = Stop-OllamaProcesses

    if (-not $apiWasRunning -and -not $stoppedProcess) {
        Write-Log 'Ollama is not running.'
        exit 0
    }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (-not (Test-OllamaApi)) {
            Write-Log 'Stopped.'
            exit 0
        }
        Start-Sleep -Seconds 1
    }

    Write-WarningLog "Ollama still responds at $ApiUrl. The desktop app or another service may have restarted it."
    exit 1
}
catch {
    Write-Host ''
    Write-Host "[stop-windows] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
