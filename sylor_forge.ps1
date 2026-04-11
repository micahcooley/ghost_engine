# sylor_forge.ps1 - Hermetic Toolchain Bootstrapper for Ghost Engine

$ErrorActionPreference = "Stop"
$ToolchainDir = Join-Path $PSScriptRoot ".toolchain"
If (-Not (Test-Path $ToolchainDir)) {
    New-Item -ItemType Directory -Path $ToolchainDir -Force | Out-Null
}

$ZigDir = Join-Path $ToolchainDir "zig"
$VulkanDir = Join-Path $ToolchainDir "Vulkan"

Write-Host "⚔️  SylorLabs: Hermetic Forge Initializing..." -ForegroundColor Cyan

# Speed Optimization: Use curl.exe if available (Standard on Win10/11)
$Downloader = "curl"
If (!(Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    $Downloader = "bits"
}

Function Fast-Download($Url, $Dest) {
    If ($Downloader -eq "curl") {
        # -L follows redirects, -f fails silently on 404, -# shows progress bar
        curl.exe -L -f -# -o $Dest $Url
    } Else {
        Start-BitsTransfer -Source $Url -Destination $Dest -Priority Foreground
    }
}

# 1. Zig Toolchain (Portable - 0.13.0 Stable)
If (-Not (Test-Path $ZigDir)) {
    Write-Host "📥 Downloading Zig 0.13.0 (Fast Stream)..." -ForegroundColor Cyan
    $ZigZip = Join-Path $ToolchainDir "zig.zip"
    $ZigUrl = "https://ziglang.org/download/0.13.0/zig-windows-x86_64-0.13.0.zip"
    
    Fast-Download $ZigUrl $ZigZip
    
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

# 2. Vulkan SDK (Portable)
If (-Not (Test-Path $VulkanDir)) {
    $VulkanVersion = "1.3.296.0"
    $VulkanZip = Join-Path $ToolchainDir "vulkan.zip"
    
    # We use the 'Configurable' SDK zip which is the portable version.
    # Note: LunarG URLs are sensitive. 
    $VulkanUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/vulkansdk-win64-$VulkanVersion.zip"

    Write-Host "📥 Downloading Vulkan SDK $VulkanVersion (Fast Stream)..." -ForegroundColor Cyan
    Try {
        Fast-Download $VulkanUrl $VulkanZip
    } Catch {
        Write-Host "⚠️  Primary link failed. Trying stable secondary..." -ForegroundColor Yellow
        $VulkanUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/VulkanSDK-$VulkanVersion-win64.zip"
        Fast-Download $VulkanUrl $VulkanZip
    }
    
    Write-Host "📦 Extracting Vulkan SDK... (This is the slow part, please wait)" -ForegroundColor Cyan
    $VulkanExtractPath = Join-Path $ToolchainDir "Vulkan_Extract"
    Expand-Archive -Path $VulkanZip -DestinationPath $VulkanExtractPath
    
    # LunarG zip structure flattening
    $ExtractedVulkan = Get-ChildItem -Path $VulkanExtractPath -Directory | Select-Object -First 1
    If ($ExtractedVulkan) {
        Move-Item -Path $ExtractedVulkan.FullName -Destination $VulkanDir -Force
    }
    
    Remove-Item -Path $VulkanExtractPath -Recurse -Force
    Remove-Item -Path $VulkanZip -Force
    
    # ── VERIFICATION ──
    Write-Host "`n🔍 Verifying Hermetic Toolchain..." -ForegroundColor Cyan
    $ZigExe = Join-Path $ZigDir "zig.exe"
    $GlslcExe = Join-Path $VulkanDir "Bin/glslc.exe"
    
    If (Test-Path $ZigExe) {
        $ZigVer = & $ZigExe version
        Write-Host "✔️  Zig $ZigVer verified." -ForegroundColor Green
    } Else {
        Write-Error "❌ Zig verification FAILED. Binaries missing."
    }
    
    If (Test-Path $GlslcExe) {
        Write-Host "✔️  Vulkan SDK (glslc) verified." -ForegroundColor Green
    } Else {
        Write-Error "❌ Vulkan SDK verification FAILED. Binaries missing or nested incorrectly."
    }

    Write-Host "`n🚀 Hermetic Forge Ready." -ForegroundColor Green
Write-Host "------------------------------------------------"
Write-Host "To build the engine without global installs:" -ForegroundColor Gray
Write-Host "1. `$env:PATH = '$ZigDir;' + `$env:PATH" -ForegroundColor White
Write-Host "2. `$env:VULKAN_SDK = '$VulkanDir'" -ForegroundColor White
Write-Host "3. (from project root) zig build -Doptimize=ReleaseFast" -ForegroundColor Yellow
Write-Host "------------------------------------------------"
