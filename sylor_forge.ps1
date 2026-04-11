# sylor_forge.ps1 - Hermetic Toolchain Bootstrapper for Ghost Engine

$ErrorActionPreference = "Stop"
$ToolchainDir = Join-Path $PSScriptRoot ".toolchain"
If (-Not (Test-Path $ToolchainDir)) {
    New-Item -ItemType Directory -Path $ToolchainDir | Out-Null
}

$ZigDir = Join-Path $ToolchainDir "zig"
$VulkanDir = Join-Path $ToolchainDir "Vulkan"

Write-Host "⚔️  SylorLabs: Hermetic Forge Initializing..." -ForegroundColor Cyan

# 1. Zig Toolchain (Portable)
If (-Not (Test-Path $ZigDir)) {
    Write-Host "📥 Downloading Zig 0.13.0..." -ForegroundColor Cyan
    $ZigZip = Join-Path $ToolchainDir "zig.zip"
    $ZigUrl = "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZigUrl -OutFile $ZigZip
    
    Write-Host "📦 Extracting Zig..." -ForegroundColor Cyan
    Expand-Archive -Path $ZigZip -DestinationPath $ToolchainDir
    
    $ExtractedZig = Join-Path $ToolchainDir "zig-windows-x86_64-0.13.0"
    Move-Item -Path $ExtractedZig -Destination $ZigDir
    Remove-Item -Path $ZigZip
    Write-Host "✅ Zig installed to .toolchain/zig" -ForegroundColor Green
} Else {
    Write-Host "✔️  Zig toolchain detected." -ForegroundColor Gray
}

# 2. Vulkan SDK (Portable)
If (-Not (Test-Path $VulkanDir)) {
    Write-Host "📥 Downloading Vulkan SDK 1.3.296.0 (Portable)..." -ForegroundColor Cyan
    $VulkanZip = Join-Path $ToolchainDir "vulkan.zip"
    $VulkanUrl = "https://sdk.lunarg.com/sdk/download/1.3.296.0/windows/vulkansdk-win64-1.3.296.0.zip"
    
    Invoke-WebRequest -Uri $VulkanUrl -OutFile $VulkanZip
    
    Write-Host "📦 Extracting Vulkan SDK... (This may take a minute)" -ForegroundColor Cyan
    Expand-Archive -Path $VulkanZip -DestinationPath $VulkanDir
    
    # LunarG zip usually has a top-level folder like '1.3.296.0'
    $ExtractedVulkan = Get-ChildItem -Path $VulkanDir -Directory | Select-Object -First 1
    If ($ExtractedVulkan) {
        $TempPath = Join-Path $ToolchainDir "Vulkan_Temp"
        Move-Item -Path $ExtractedVulkan.FullName -Destination $TempPath
        Remove-Item -Path $VulkanDir -Recurse -Force
        Rename-Item -Path $TempPath -NewName "Vulkan"
    }
    
    Remove-Item -Path $VulkanZip
    Write-Host "✅ Vulkan SDK installed to .toolchain/Vulkan" -ForegroundColor Green
} Else {
    Write-Host "✔️  Vulkan SDK detected." -ForegroundColor Gray
}

Write-Host "`n🚀 Hermetic Forge Ready." -ForegroundColor Green
Write-Host "------------------------------------------------"
Write-Host "To build the engine without global installs:" -ForegroundColor Gray
Write-Host "1. `$env:PATH = '$ZigDir;' + `$env:PATH" -ForegroundColor White
Write-Host "2. `$env:VULKAN_SDK = '$VulkanDir'" -ForegroundColor White
Write-Host "3. cd platforms/windows" -ForegroundColor White
Write-Host "4. zig build release -Doptimize=ReleaseFast" -ForegroundColor Yellow
Write-Host "------------------------------------------------"
