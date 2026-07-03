#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =========================================================
# cleanup.ps1 - remove ALL local Ollama models so
# you can start fresh. Aliases and base models are deleted.
# Does NOT uninstall Ollama or OpenCode.
#
# Usage:
#   .\cleanup.ps1         # list models and confirm
#   .\cleanup.ps1 --yes   # skip confirmation
# =========================================================

$ApiUrl = 'http://127.0.0.1:11434'

function Write-Log([string]$Message) {
    Write-Host "[cleanup-windows] $Message"
}

function Write-WarningLog([string]$Message) {
    Write-Host "[cleanup-windows] WARNING: $Message" -ForegroundColor Yellow
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

function Get-OllamaModels {
    $response = Invoke-RestMethod -Uri "$ApiUrl/api/tags" -Method Get -TimeoutSec 15
    return @($response.models | ForEach-Object {
        if ($_.name) { $_.name } else { $_.model }
    } | Where-Object { $_ } | Sort-Object -Unique)
}

function Remove-OllamaModel([string]$Name) {
    $body = @{ model = $Name } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$ApiUrl/api/delete" -Method Delete `
        -ContentType 'application/json' -Body $body -TimeoutSec 300 | Out-Null
}

try {
    $assumeYes = $false
    if ($args.Count -gt 1) {
        throw 'Only --yes is supported.'
    }
    if ($args.Count -eq 1) {
        if ($args[0] -notin @('-y', '--yes', '--force')) {
            throw 'Only --yes is supported.'
        }
        $assumeYes = $true
    }

    if (-not (Test-OllamaApi)) {
        throw 'Cannot reach Ollama. Start it with .\start.ps1, then rerun this script.'
    }

    $models = @(Get-OllamaModels)
    if ($models.Count -eq 0) {
        Write-Log 'No local models found. Already clean.'
        exit 0
    }

    Write-Log "The following $($models.Count) model(s) will be removed:"
    $models | ForEach-Object { Write-Host "  - $_" }

    if (-not $assumeYes) {
        $reply = Read-Host '[cleanup-windows] Remove all of these? [y/N]'
        if ($reply -notmatch '^(?i:y|yes)$') {
            Write-Log 'Aborted. Nothing removed.'
            exit 0
        }
    }

    $failedModels = [Collections.Generic.List[string]]::new()
    foreach ($model in $models) {
        try {
            Remove-OllamaModel $model
            Write-Log "Removed $model"
        }
        catch {
            Write-WarningLog "Failed to remove ${model}: $($_.Exception.Message)"
            $failedModels.Add($model)
        }
    }

    if ($failedModels.Count -gt 0) {
        throw "One or more models could not be removed: $($failedModels -join ', ')"
    }

    Write-Log 'Done. All local models removed. Run .\setup.ps1 to start fresh.'
}
catch {
    Write-Host ''
    Write-Host "[cleanup-windows] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
