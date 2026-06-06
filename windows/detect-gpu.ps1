#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Model = 'general',
    [switch]$Repair,
    [string]$KeepAlive = '30m'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =========================
# Configuration (edit here)
# =========================
$ApiUrl = 'http://127.0.0.1:11434'
$OllamaFlashAttention = '1'
$OllamaKvCacheType = 'q8_0'

function Write-Log([string]$Message) {
    Write-Host "[detect-gpu] $Message"
}

function Write-Pass([string]$Message) {
    Write-Host "[detect-gpu] PASS: $Message" -ForegroundColor Green
}

function Write-WarningLog([string]$Message) {
    Write-Host "[detect-gpu] WARNING: $Message" -ForegroundColor Yellow
}

function Get-OllamaExecutable {
    $command = Get-Command 'ollama.exe' -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notmatch '\\WindowsApps\\OpenAI\.Codex_') {
        return $command.Source
    }

    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return $null
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
    throw 'Ollama did not start within 30 seconds.'
}

function Start-Ollama([string]$OllamaExe) {
    $env:OLLAMA_FLASH_ATTENTION = $OllamaFlashAttention
    $env:OLLAMA_KV_CACHE_TYPE = $OllamaKvCacheType

    # PowerShell 5.1 can retain both Path and PATH after package installation.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$userPath", 'Process')

    $stdoutLog = Join-Path $env:TEMP 'ollama-gpu-check.log'
    $stderrLog = Join-Path $env:TEMP 'ollama-gpu-check-error.log'
    Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog | Out-Null
    Wait-ForOllama
}

function Restart-Ollama([string]$OllamaExe) {
    Write-Log 'Restarting Ollama to repeat GPU discovery...'
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @('ollama', 'ollama app', 'llama-server') } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Ollama $OllamaExe
}

function Get-NvidiaGpu {
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    $nvidiaSmiPath = if ($nvidiaSmi) {
        $nvidiaSmi.Source
    }
    else {
        $candidate = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $candidate) { $candidate } else { $null }
    }
    if (-not $nvidiaSmiPath) {
        return $null
    }

    try {
        $line = & $nvidiaSmiPath `
            '--query-gpu=name,driver_version,memory.total,memory.free' `
            '--format=csv,noheader,nounits' 2>$null |
            Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $line) {
            return $null
        }

        $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
        return [pscustomobject]@{
            Name = $parts[0]
            Driver = $parts[1]
            MemoryTotalMiB = [int]$parts[2]
            MemoryFreeMiB = [int]$parts[3]
        }
    }
    catch {
        return $null
    }
}

function Get-SmartAppControlState {
    return (
        Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
            -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue
    ).VerifiedAndReputablePolicyState
}

function Get-RecentOllamaCodeIntegrityBlock {
    try {
        return Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-CodeIntegrity/Operational'
            Id = 3033, 3077
            StartTime = (Get-Date).AddHours(-24)
        } -ErrorAction Stop |
            Where-Object {
                $_.Message -match '\\Programs\\Ollama\\' -and
                $_.Message -match '\\lib\\ollama\\(libmtmd\.dll|llama-server\.exe)'
            } |
            Select-Object -First 1
    }
    catch {
        return $null
    }
}

function Test-ModelInstalled([string]$Name) {
    $tags = Invoke-RestMethod -Uri "$ApiUrl/api/tags" -Method Get -TimeoutSec 10
    $names = @($tags.models | ForEach-Object {
        if ($_.name) { $_.name } else { $_.model }
    })
    return $names -contains $Name -or $names -contains "${Name}:latest"
}

function Load-Model([string]$Name) {
    Write-Log "Loading model '$Name' for GPU validation..."
    $body = @{
        model = $Name
        messages = @()
        keep_alive = $KeepAlive
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$ApiUrl/api/chat" -Method Post -ContentType 'application/json' `
        -Body $body -TimeoutSec 300 | Out-Null
}

function Get-LoadedModel([string]$Name) {
    $running = Invoke-RestMethod -Uri "$ApiUrl/api/ps" -Method Get -TimeoutSec 10
    return @($running.models | Where-Object {
        $_.name -eq $Name -or
        $_.model -eq $Name -or
        $_.name -eq "${Name}:latest" -or
        $_.model -eq "${Name}:latest"
    }) | Select-Object -First 1
}

function Show-Resolution {
    param(
        $Gpu,
        [Nullable[int]]$SmartAppControlState,
        $CodeIntegrityEvent,
        [bool]$ApiRunning,
        [bool]$OllamaInstalled
    )

    Write-Host ''
    Write-WarningLog "Model '$Model' is not running fully on the GPU."
    Write-Host '[detect-gpu] Resolution:'

    if (-not $OllamaInstalled) {
        Write-Host '  1. Run .\setup.ps1 to install Ollama.'
        return
    }

    if (-not $Gpu) {
        Write-Host '  1. Install or update the NVIDIA driver.'
        Write-Host '  2. Confirm that nvidia-smi works in a new PowerShell window.'
        Write-Host '  3. Restart Windows, then run this script again.'
        return
    }

    if ($SmartAppControlState -ne 0 -and $CodeIntegrityEvent) {
        Write-Host '  1. Windows Application Control is blocking Ollama inference binaries.'
        Write-Host '  2. Open Windows Security > App & browser control > Smart App Control.'
        Write-Host '  3. On a managed PC, ask the administrator for an Ollama App Control exception.'
        Write-Host '  4. Do not disable Smart App Control casually; turning it off reduces security'
        Write-Host '     and normally cannot be reversed without resetting or reinstalling Windows.'
        return
    }

    if (-not $ApiRunning) {
        Write-Host '  1. Start Ollama with .\start.ps1.'
        Write-Host "  2. Retry with: .\detect-gpu.ps1 -Model '$Model'"
        return
    }

    Write-Host '  1. Restart Ollama so it repeats CUDA discovery:'
    Write-Host "     .\detect-gpu.ps1 -Model '$Model' -Repair"
    Write-Host '  2. Close GPU-heavy applications if the model cannot fit in VRAM.'
    Write-Host '  3. Reduce the model context window in setup.ps1 if VRAM is exhausted.'
    Write-Host '  4. Recreate the model alias by rerunning .\setup.ps1.'
}

try {
    $ollamaExe = Get-OllamaExecutable
    $ollamaInstalled = $null -ne $ollamaExe
    $gpu = Get-NvidiaGpu
    $smartAppControlState = Get-SmartAppControlState
    $codeIntegrityEvent = Get-RecentOllamaCodeIntegrityBlock

    if ($gpu) {
        Write-Log "GPU: $($gpu.Name), driver $($gpu.Driver), $($gpu.MemoryTotalMiB) MiB VRAM"
    }
    else {
        Write-WarningLog 'No usable NVIDIA GPU was detected by nvidia-smi.'
    }

    if (-not $ollamaInstalled) {
        Show-Resolution -Gpu $gpu -SmartAppControlState $smartAppControlState `
            -CodeIntegrityEvent $codeIntegrityEvent -ApiRunning $false -OllamaInstalled $false
        exit 1
    }

    $apiRunning = Test-OllamaApi
    if (-not $apiRunning) {
        if ($Repair) {
            Write-Log 'Ollama is not running; starting it...'
            Start-Ollama $ollamaExe
            $apiRunning = $true
        }
        else {
            Show-Resolution -Gpu $gpu -SmartAppControlState $smartAppControlState `
                -CodeIntegrityEvent $codeIntegrityEvent -ApiRunning $false -OllamaInstalled $true
            exit 1
        }
    }

    if (-not (Test-ModelInstalled $Model)) {
        throw "Model '$Model' is not installed. Run setup.ps1 first."
    }

    Load-Model $Model
    $loadedModel = Get-LoadedModel $Model
    if (-not $loadedModel) {
        throw "Ollama did not report '$Model' as loaded."
    }

    $size = [double]$loadedModel.size
    $sizeVram = [double]$loadedModel.size_vram
    $gpuPercent = if ($size -gt 0) {
        [Math]::Round(($sizeVram / $size) * 100)
    }
    else {
        0
    }

    if ($gpuPercent -lt 100 -and $Repair) {
        Restart-Ollama $ollamaExe
        Load-Model $Model
        $loadedModel = Get-LoadedModel $Model
        $size = [double]$loadedModel.size
        $sizeVram = [double]$loadedModel.size_vram
        $gpuPercent = if ($size -gt 0) {
            [Math]::Round(($sizeVram / $size) * 100)
        }
        else {
            0
        }
    }

    if ($gpuPercent -ge 100) {
        Write-Pass "'$($loadedModel.name)' is 100% GPU-resident."
        Write-Log "Context: $($loadedModel.context_length), VRAM used by model: $([Math]::Round($sizeVram / 1GB, 2)) GiB"
        exit 0
    }

    if ($gpuPercent -gt 0) {
        Write-WarningLog "'$($loadedModel.name)' is only $gpuPercent% GPU-resident."
    }
    else {
        Write-WarningLog "'$($loadedModel.name)' is running on CPU."
    }

    Show-Resolution -Gpu $gpu -SmartAppControlState $smartAppControlState `
        -CodeIntegrityEvent $codeIntegrityEvent -ApiRunning $true -OllamaInstalled $true
    exit 1
}
catch {
    Write-Host ''
    Write-Host "[detect-gpu] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[detect-gpu] Retry automatic recovery with: .\detect-gpu.ps1 -Model '$Model' -Repair"
    exit 1
}
