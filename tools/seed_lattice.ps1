# seed_lattice.ps1 - Legacy Windows/x86_64 state seeder.
# Preferred workflow: zig build seed -Dtarget=x86_64-windows

$ErrorActionPreference = "Stop"

$LatticeSize = 1GB
$MonolithSize = 2GB
$TagsSize = 4MB
$LatticeFile = "platforms/windows/x86_64/state/unified_lattice.bin"
$MonolithFile = "platforms/windows/x86_64/state/semantic_monolith.bin"
$TagsFile = "platforms/windows/x86_64/state/semantic_tags.bin"
$TotalSize = $LatticeSize + $MonolithSize + $TagsSize

Write-Host "Ghost Engine: State Seeding ($([Math]::Round($TotalSize / 1GB, 2)) GiB total)" -ForegroundColor Cyan
Write-Host "Target layout: platforms/windows/x86_64/state" -ForegroundColor Gray
Write-Host "Preferred workflow: zig build seed -Dtarget=x86_64-windows" -ForegroundColor Gray
Write-Host "  unified_lattice.bin   $([Math]::Round($LatticeSize / 1GB, 2)) GiB" -ForegroundColor Gray
Write-Host "  semantic_monolith.bin $([Math]::Round($MonolithSize / 1GB, 2)) GiB" -ForegroundColor Gray
Write-Host "  semantic_tags.bin     $([Math]::Round($TagsSize / 1MB, 2)) MiB" -ForegroundColor Gray

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
