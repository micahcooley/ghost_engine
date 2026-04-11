# seed_lattice.ps1 - Ghost Engine State Initializer

$ErrorActionPreference = "Stop"

$LatticeSize = 1024 * 1024 * 1024 # 1GB
$MonolithSize = 1024 * 1024 * 1024 # 1GB
$TagsSize = 1048576 * 8 # 8MB
$LatticeFile = "platforms/windows/x86_64/state/unified_lattice.bin"
$MonolithFile = "platforms/windows/x86_64/state/semantic_monolith.bin"
$TagsFile = "platforms/windows/x86_64/state/semantic_tags.bin"

Write-Host "Ghost Engine: State Seeding (~2.1 GB)" -ForegroundColor Cyan

# Ensure state directory exists
$StateDir = [System.IO.Path]::GetDirectoryName($LatticeFile)
If (-Not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    Write-Host "Created state directory: $StateDir" -ForegroundColor Gray
}

Function Initialize-File($Path, $Size) {
    If (Test-Path $Path) {
        Write-Host "  $Path already exists." -ForegroundColor Gray
        Return
    }

    Write-Host "  Creating $Path..." -ForegroundColor Yellow -NoNewline
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.SetLength($Size)
    $fs.Close()
    Write-Host " done." -ForegroundColor Green
}

Initialize-File $LatticeFile $LatticeSize
Initialize-File $MonolithFile $MonolithSize
Initialize-File $TagsFile $TagsSize

Write-Host "`nState Seeding Complete." -ForegroundColor Green
Write-Host "The Ghost is ready to begin ingestion." -ForegroundColor Cyan
