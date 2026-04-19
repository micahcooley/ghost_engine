# Ghost OS Shell Launcher — Windows x86_64
# Installs ws dependency if needed, then starts the bridge server and opens the browser.

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebDir    = Join-Path $ScriptDir "web"
$Port      = 8080

Write-Host "`n  ╔═══════════════════════════════════════╗" -ForegroundColor DarkMagenta
Write-Host "  ║   GHOST OS SHELL — V28 SOVEREIGN      ║" -ForegroundColor Magenta
Write-Host "  ╚═══════════════════════════════════════╝`n" -ForegroundColor DarkMagenta

# Detect node
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Node.js not found. Please install Node.js >= 18." -ForegroundColor Red
    exit 1
}
$nodeVer = node --version
Write-Host "  [NODE]  $nodeVer" -ForegroundColor Gray

# Install ws if needed
$nmPath = Join-Path $WebDir "node_modules\ws"
if (-not (Test-Path $nmPath)) {
    Write-Host "  [SETUP] Installing WebSocket dependency..." -ForegroundColor Yellow
    Push-Location $WebDir
    npm install --silent
    Pop-Location
    Write-Host "  [SETUP] Done." -ForegroundColor Green
}

# Detect ghost binary
$BinDir   = Join-Path $ScriptDir "x86_64\bin"
$GhostBin = Join-Path $BinDir "ghost_sovereign.exe"
if (Test-Path $GhostBin) {
    Write-Host "  [GHOST] Found: $GhostBin" -ForegroundColor Green
} else {
    Write-Host "  [WARN]  ghost_sovereign.exe not found at $GhostBin" -ForegroundColor Yellow
    Write-Host "          Run 'zig build -Doptimize=ReleaseFast' and copy the binary." -ForegroundColor Gray
}

# Start bridge
Write-Host "  [SHELL] Starting bridge on http://localhost:$Port ..." -ForegroundColor Cyan

$bridgeArgs = @(
    (Join-Path $WebDir "bridge.js"),
    "--port=$Port",
    "--bin=$BinDir"
)

# Open browser after short delay
Start-Job -ScriptBlock {
    Start-Sleep 1.5
    Start-Process "http://localhost:$using:Port"
} | Out-Null

node @bridgeArgs
