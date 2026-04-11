# Ghost Engine: start - Sovereign Bridge (Windows)
# This script is platform-aware and arch-aware.

Write-Host "`n[GHOST] Initializing Sovereign Bridge..." -ForegroundColor Cyan

# 1. Check for Node.js
if (!(Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Node.js not found. Please install Node.js to run the Sovereign Bridge." -ForegroundColor Red
    exit 1
}

# 2. Check for the Engine Binary (Arch detection)
$Arch = if ([IntPtr]::Size -eq 8) { "x86_64" } else { "x86" }
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $Arch = "arm64" }

$BinaryPath = Join-Path $PSScriptRoot "..\$Arch\bin\ghost_pulse.exe"

if (!(Test-Path $BinaryPath)) {
    Write-Host "[WARNING] Ghost Engine binary (ghost_pulse.exe) not found for $Arch at: $BinaryPath" -ForegroundColor Yellow
    Write-Host "[INFO] Attempting to build engine via zig build..." -ForegroundColor Gray
    
    # Build from the Local Platform Silo
    $PlatformPath = Resolve-Path "$PSScriptRoot\.."
    Push-Location $PlatformPath
    # Zig will build for the host and install into the correct arch folder (handled by build.zig)
    zig build -Doptimize=ReleaseFast
    Pop-Location

    if (!(Test-Path $BinaryPath)) {
        Write-Host "[FATAL] Build failed. Build the engine manually before starting the UI." -ForegroundColor Red
        exit 1
    }
}

Write-Host "[INFO] Platform: Windows | Architecture: $Arch" -ForegroundColor Gray
Write-Host "[INFO] Igniting Bridge Server..." -ForegroundColor Gray

# 3. Launch the Bridge Server
$ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
$ProcessInfo.FileName = "node"
$ProcessInfo.Arguments = "server.js"
$ProcessInfo.WorkingDirectory = $PSScriptRoot
$ProcessInfo.RedirectStandardOutput = $true
$ProcessInfo.UseShellExecute = $false
$ProcessInfo.CreateNoWindow = $true

$Process = [System.Diagnostics.Process]::Start($ProcessInfo)
$LaunchUrl = ""

# Read output to find the LAUNCH_URL
while (!$Process.StandardOutput.EndOfStream) {
    $Line = $Process.StandardOutput.ReadLine()
    Write-Host $Line -ForegroundColor DarkGray
    if ($Line -match "LAUNCH_URL: (.*)") {
        $LaunchUrl = $Matches[1]
        break
    }
}

if ($LaunchUrl) {
    Write-Host "`n[SUCCESS] Sovereign UI online at $LaunchUrl" -ForegroundColor Green
    Start-Process $LaunchUrl
}

$Process.WaitForExit()
