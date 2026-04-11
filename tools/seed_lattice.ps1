# seed_lattice.ps1 - Ghost Engine State Initializer
$ErrorActionPreference = "Stop"
$LatticeFile = "platforms/windows/x86_64/state/unified_lattice.bin"
$MonolithFile = "platforms/windows/x86_64/state/semantic_monolith.bin"
$LatticeSize = 1073741824
$MonolithSize = 1073741824

Write-Host "🧠 Ghost Engine: State Seeding..."

$StateDir = "platforms/windows/x86_64/state"
If (-Not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

Function Init-File($Path, $Size) {
    If (Test-Path $Path) {
        Write-Host "Already exists: $Path"
        Return
    }
    Write-Host "Creating 1GB file: $Path"
    $fs = [System.IO.File]::Create($Path)
    $fs.SetLength($Size)
    $fs.Close()
    Write-Host "Created $Path"
}

Init-File $LatticeFile $LatticeSize
Init-File $MonolithFile $MonolithSize

Write-Host "State Seeding Complete."
