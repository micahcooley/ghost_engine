[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$binRoot = Join-Path $repoRoot "zig-out\bin"
$patterns = @("*.log", "*.json", "*.out", "*.exe")
$targets = foreach ($pattern in $patterns) {
    $rootMatches = Get-ChildItem -LiteralPath $repoRoot -File -Filter $pattern -ErrorAction SilentlyContinue
    $binMatches = if (Test-Path -LiteralPath $binRoot) {
        Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
    }
    $rootMatches + $binMatches
}

$targets = $targets | Sort-Object FullName -Unique

if (-not $targets) {
    Write-Host "Scrub complete: no matching artifacts found in root or zig-out/bin."
    exit 0
}

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target.FullName, "Remove build artifact")) {
        Remove-Item -LiteralPath $target.FullName -Force
        Write-Host ("Removed {0}" -f $target.FullName)
    }
}
