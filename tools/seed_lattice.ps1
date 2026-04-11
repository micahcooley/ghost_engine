# seed_lattice.ps1 - Ghost Engine State Initializer
# Part of the Collaborator-Zero onboarding suite.

$ErrorActionPreference = "Stop"

$LatticeSize = 1024 * 1024 * 1024 # 1GB
$MonolithSize = 1024 * 1024 * 1024 # 1GB
$LatticeFile = "platforms/windows/x86_64/state/unified_lattice.bin"
$MonolithFile = "platforms/windows/x86_64/state/semantic_monolith.bin"

Write-Host "🧠 Ghost Engine: State Seeding..." -ForegroundColor Cyan

# Ensure state directory exists
$StateDir = [System.IO.Path]::GetDirectoryName($LatticeFile)
If (-Not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    Write-Host "📁 Created state directory: $StateDir" -ForegroundColor Gray
}

Function Initialize-Lattice($Path, $Size) {
    If (Test-Path $Path) {
        Write-Host "✔️  $Path already exists." -ForegroundColor Gray
        Return
    }

    Write-Host "🔨 Initializing 1GB Genesis Monolith: $Path" -ForegroundColor Yellow
    
    # We use a fast .NET method to create a zero-filled file. 
    # This is much faster than writing bytes in a loop.
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.SetLength($Size)
    
    # Optional: Write Genesis Header (0x5A5A5A5A...)
    # In the current architecture, the engine handles zero-filled files as 'tabula rasa'.
    # But we can etch a 'Genesis Pulse' if needed.
    
    $fs.Close()
    Write-Host "✅ Created $Path" -ForegroundColor Green
}

# Check for 'Genesis' Download Option
$DownloadSeed = $false
# Placeholder URL for pre-trained weights
$SeedUrl = "https://sylorlabs.io/ghost/seeds/genesis_v22_x64.bin" 

If (-Not (Test-Path $LatticeFile)) {
    $Choice = Read-Host "Lattice not found. [I]nitialize tabula rasa (1GB) or [D]ownload Genesis Seed? (I/D)"
    If ($Choice -eq 'D' -or $Choice -eq 'd') {
        $DownloadSeed = $true
    }
}

If ($DownloadSeed) {
    Write-Host "📥 Downloading Genesis Seed (Placeholder)..." -ForegroundColor Cyan
    Write-Host "⚠️  Note: sylorlabs.io placeholder active. Falling back to local init." -ForegroundColor Yellow
    Initialize-Lattice $LatticeFile $LatticeSize
} Else {
    Initialize-Lattice $LatticeFile $LatticeSize
}

Initialize-Lattice $MonolithFile $MonolithSize

Write-Host "`n🚀 State Seeding Complete." -ForegroundColor Green
Write-Host "The Ghost is ready to begin ingestion." -ForegroundColor Cyan
