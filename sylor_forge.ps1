# sylor_forge.ps1 - Hermetic Toolchain Bootstrapper for Ghost Engine

$ErrorActionPreference = "Stop"
$ToolchainDir = Join-Path $PSScriptRoot ".toolchain"
If (-Not (Test-Path $ToolchainDir)) {
    New-Item -ItemType Directory -Path $ToolchainDir -Force | Out-Null
}

$ZigDir = Join-Path $ToolchainDir "zig"
$VulkanDir = Join-Path $ToolchainDir "Vulkan"

Write-Host "SylorLabs: Hermetic Forge Initializing..." -ForegroundColor Cyan

# 1. Zig Toolchain (Portable)
If (-Not (Test-Path $ZigDir)) {
    Write-Host "Downloading Zig 0.13.0 (Stable)..." -ForegroundColor Cyan
    $ZigZip = Join-Path $ToolchainDir "zig.zip"
    $ZigUrl = "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZigUrl -OutFile $ZigZip
    
    Write-Host "Extracting Zig..." -ForegroundColor Cyan
    Expand-Archive -Path $ZigZip -DestinationPath $ToolchainDir
    
    $ExtractedZig = Get-ChildItem -Path $ToolchainDir -Directory | Where-Object { $_.Name -like "zig-windows*" } | Select-Object -First 1
    If ($ExtractedZig) {
        Move-Item -Path $ExtractedZig.FullName -Destination $ZigDir -Force
    }
    Remove-Item -Path $ZigZip -Force
    Write-Host "Zig installed to .toolchain/zig" -ForegroundColor Green
} Else {
    Write-Host "Zig toolchain detected." -ForegroundColor Gray
}

# 2. Vulkan Components (Portable)
If (-Not (Test-Path $VulkanDir)) {
    Write-Host "Downloading Vulkan Runtime Components 1.3.296.0..." -ForegroundColor Cyan
    $VulkanZip = Join-Path $ToolchainDir "vulkan.zip"
    $VulkanUrl = "https://sdk.lunarg.com/sdk/download/1.3.296.0/windows/VulkanRT-1.3.296.0-Components.zip"
    
    Invoke-WebRequest -Uri $VulkanUrl -OutFile $VulkanZip -UseBasicParsing
    
    Write-Host "Extracting Vulkan..." -ForegroundColor Cyan
    Expand-Archive -Path $VulkanZip -DestinationPath $VulkanDir
    
    Remove-Item -Path $VulkanZip -Force
    Write-Host "Vulkan components installed to .toolchain/Vulkan" -ForegroundColor Green
} Else {
    Write-Host "Vulkan components detected." -ForegroundColor Gray
}

Write-Host "Hermetic Forge Ready." -ForegroundColor Green
Write-Host "------------------------------------------------"
Write-Host "To build the engine without global installs:" -ForegroundColor Gray
Write-Host "1. `$env:PATH = '$ZigDir;' + `$env:PATH" -ForegroundColor White
Write-Host "2. `$env:VULKAN_SDK = '$VulkanDir'" -ForegroundColor White
Write-Host "3. cd platforms/windows" -ForegroundColor White
Write-Host "4. zig build release -Doptimize=ReleaseFast" -ForegroundColor Yellow
Write-Host "------------------------------------------------"
