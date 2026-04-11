# sylor_forge.ps1 - Hermetic Toolchain Bootstrapper for Ghost Engine

$ErrorActionPreference = "Stop"
$ToolchainDir = Join-Path $PSScriptRoot ".toolchain"
If (-Not (Test-Path $ToolchainDir)) {
    New-Item -ItemType Directory -Path $ToolchainDir -Force | Out-Null
}

$ZigDir = Join-Path $ToolchainDir "zig"
$VulkanDir = Join-Path $ToolchainDir "Vulkan"

Write-Host "⚔️  SylorLabs: Hermetic Forge Initializing..." -ForegroundColor Cyan

# 1. Zig Toolchain (Portable - 0.13.0 Stable)
If (-Not (Test-Path $ZigDir)) {
    Write-Host "📥 Downloading Zig 0.13.0 Stable..." -ForegroundColor Cyan
    $ZigZip = Join-Path $ToolchainDir "zig.zip"
    $ZigUrl = "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Start-BitsTransfer -Source $ZigUrl -Destination $ZigZip -Description "Ghost Engine: Zig Toolchain"
    
    Write-Host "📦 Extracting Zig..." -ForegroundColor Cyan
    Expand-Archive -Path $ZigZip -DestinationPath $ToolchainDir
    
    $ExtractedZig = Get-ChildItem -Path $ToolchainDir -Directory | Where-Object { $_.Name -like "zig-windows*" } | Select-Object -First 1
    If ($ExtractedZig) {
        Move-Item -Path $ExtractedZig.FullName -Destination $ZigDir -Force
    }
    Remove-Item -Path $ZigZip -Force
    Write-Host "✅ Zig installed to .toolchain/zig" -ForegroundColor Green
} Else {
    Write-Host "✔️  Zig toolchain detected." -ForegroundColor Gray
}

# 2. Vulkan SDK (Portable - Latest available)
If (-Not (Test-Path $VulkanDir)) {
    Write-Host "📥 Fetching Latest Vulkan SDK Version..." -ForegroundColor Cyan
    # Trying to find the latest version dynamically
    $VulkanUrlBase = "https://sdk.lunarg.com/sdk/download"
    $LatestVulkan = "1.3.296.0" # Fallback
    
    # Actually, we'll use a known-good link structure for the zip
    # LunarG direct links for older versions are often: https://sdk.lunarg.com/sdk/download/1.3.296.0/windows/VulkanSDK-1.3.296.0-Installer.exe
    # For ZIPs, the naming is very specific. Let's use a version that is confirmed alive.
    $VulkanVersion = "1.3.296.0"
    $VulkanZip = Join-Path $ToolchainDir "vulkan.zip"
    # Note: LunarG Zip naming is sometimes case sensitive or includes "win64"
    $VulkanUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/vulkansdk-win64-$VulkanVersion.zip"

    Write-Host "📥 Downloading Vulkan SDK $VulkanVersion (Portable)..." -ForegroundColor Cyan
    Try {
        Start-BitsTransfer -Source $VulkanUrl -Destination $VulkanZip -Description "Ghost Engine: Vulkan SDK"
    } Catch {
        Write-Host "⚠️  Primary link failed. Trying secondary naming convention..." -ForegroundColor Yellow
        $VulkanUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/VulkanSDK-$VulkanVersion-win64.zip"
        Start-BitsTransfer -Source $VulkanUrl -Destination $VulkanZip -Description "Ghost Engine: Vulkan SDK (Retry)"
    }
    
    Write-Host "📦 Extracting Vulkan SDK... (This may take a minute)" -ForegroundColor Cyan
    $VulkanExtractPath = Join-Path $ToolchainDir "Vulkan_Extract"
    Expand-Archive -Path $VulkanZip -DestinationPath $VulkanExtractPath
    
    # LunarG zip structure flattening
    $ExtractedVulkan = Get-ChildItem -Path $VulkanExtractPath -Directory | Select-Object -First 1
    If ($ExtractedVulkan) {
        Move-Item -Path $ExtractedVulkan.FullName -Destination $VulkanDir -Force
    }
    
    Remove-Item -Path $VulkanExtractPath -Recurse -Force
    Remove-Item -Path $VulkanZip -Force
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
