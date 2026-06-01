param(
    [string]$EA = "",
    [switch]$MT5,
    [switch]$MT4,
    [switch]$All,
    [string]$ApiUrl = "https://mt5-production-1d95.up.railway.app"
)

$ErrorActionPreference = "Stop"
$SMC_DIR = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

if ($All) { $MT5 = $true; $MT4 = $true }
if (-not $MT5 -and -not $MT4) { $MT5 = $true } # default

Write-Host "=== SMC Cloud Deploy ===" -ForegroundColor Cyan
Write-Host "Railway URL: $ApiUrl" -ForegroundColor Gray

# Check API
try {
    $null = Invoke-WebRequest -Uri "$ApiUrl/status" -TimeoutSec 10
    Write-Host "[OK] API reachable" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Cannot reach $ApiUrl" -ForegroundColor Red
    Write-Host "Make sure the Railway service is running."
    exit 1
}

# MT5 deployment
if ($MT5) {
    if ($EA) {
        $eaPath = "$SMC_DIR\SMC_M1\EAs\$EA.ex5"
        if (-not (Test-Path $eaPath)) {
            $eaPath = "$SMC_DIR\SMC_M1\EAs\$EA.mq5"
        }
        if (Test-Path $eaPath) {
            Write-Host "[MT5] Uploading $EA..." -ForegroundColor Yellow
            $form = @{ file = Get-Item -Path $eaPath }
            Invoke-WebRequest -Uri "$ApiUrl/upload/ea" -Method Post -Form $form | Out-Null
            Write-Host "[OK] EA uploaded" -ForegroundColor Green
        } else {
            Write-Host "[WARN] EA not found: $EA" -ForegroundColor Yellow
        }
    }
    # Upload includes
    $includeDirs = @("$SMC_DIR\SMC_M1\INCLUDE", "$SMC_DIR\SMC_M1\CORE")
    foreach ($dir in $includeDirs) {
        if (Test-Path $dir) {
            Get-ChildItem "$dir\*.mqh" | ForEach-Object {
                $form = @{ file = $_ }
                Invoke-WebRequest -Uri "$ApiUrl/upload/include" -Method Post -Form $form -OutVariable null | Out-Null
                Write-Host "  include: $($_.Name)" -ForegroundColor Gray
            }
        }
    }
    # Restart MT5
    Invoke-WebRequest -Uri "$ApiUrl/restart/mt5" -Method Post | Out-Null
    Write-Host "[OK] MT5 restarted" -ForegroundColor Green
}

# MT4 deployment
if ($MT4) {
    if ($EA) {
        $ea4Path = "$SMC_DIR\M1_MT4\EAs\$EA.ex4"
        if (-not (Test-Path $ea4Path)) {
            $ea4Path = "$SMC_DIR\M1_MT4\EAs\$EA.mq4"
        }
        if (Test-Path $ea4Path) {
            Write-Host "[MT4] Uploading $EA..." -ForegroundColor Yellow
            $form = @{ file = Get-Item -Path $ea4Path }
            Invoke-WebRequest -Uri "$ApiUrl/upload/ea4" -Method Post -Form $form | Out-Null
            Write-Host "[OK] EA uploaded" -ForegroundColor Green
        } else {
            Write-Host "[WARN] MT4 EA not found: $EA" -ForegroundColor Yellow
        }
    }
    # Upload includes
    $includeDirs = @("$SMC_DIR\M1_MT4\STRUCTURE", "$SMC_DIR\M1_MT4\CORE")
    foreach ($dir in $includeDirs) {
        if (Test-Path $dir) {
            Get-ChildItem "$dir\*.mqh" | ForEach-Object {
                $form = @{ file = $_ }
                Invoke-WebRequest -Uri "$ApiUrl/upload/include" -Method Post -Form $form | Out-Null
                Write-Host "  include: $($_.Name)" -ForegroundColor Gray
            }
        }
    }
    # Restart MT4
    Invoke-WebRequest -Uri "$ApiUrl/restart/mt4" -Method Post | Out-Null
    Write-Host "[OK] MT4 restarted" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Deploy complete! ===" -ForegroundColor Cyan
Write-Host "VNC: $ApiUrl/vnc.html" -ForegroundColor White
