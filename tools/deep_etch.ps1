param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$BaseUri = "http://127.0.0.1:8080",
    [int]$MaxLines = 20,
    [int]$MaxChars = 1200,
    [int]$EtchWeight = 2,
    [int]$SleepMs = 50,
    [int]$StatusEvery = 25,
    [double]$StopSlotUsagePct = 97.25
)

$ErrorActionPreference = "Stop"

function Get-TargetFiles {
    param([string]$Root)

    $includeExt = @(".zig", ".cpp", ".md", ".sigil")
    $excludeDirNames = @(
        ".git",
        ".zig-cache",
        ".zig-out-check",
        "zig-out",
        "platforms",
        "logs",
        "scratch",
        "state",
        "corpus"
    )

    Get-ChildItem -Path $Root -Recurse -File | Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        if ($includeExt -notcontains $ext) { return $false }

        foreach ($part in $_.FullName.Split([IO.Path]::DirectorySeparatorChar)) {
            if ($excludeDirNames -contains $part) { return $false }
        }
        return $true
    } | Sort-Object FullName
}

function Split-SemanticChunks {
    param(
        [string]$Text,
        [int]$LineCap,
        [int]$CharCap
    )

    $lines = $Text -split "`r?`n"
    $chunks = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Collections.Generic.List[string]
    $currentChars = 0

    foreach ($line in $lines) {
        $lineChars = $line.Length + 1
        $wouldOverflow = ($current.Count -ge $LineCap) -or (($currentChars + $lineChars) -gt $CharCap)

        if ($wouldOverflow -and $current.Count -gt 0) {
            $chunks.Add(($current -join "`n"))
            $current.Clear()
            $currentChars = 0
        }

        if ($line.Length -gt $CharCap) {
            if ($current.Count -gt 0) {
                $chunks.Add(($current -join "`n"))
                $current.Clear()
                $currentChars = 0
            }

            for ($i = 0; $i -lt $line.Length; $i += $CharCap) {
                $span = [Math]::Min($CharCap, $line.Length - $i)
                $chunks.Add($line.Substring($i, $span))
            }
            continue
        }

        $current.Add($line)
        $currentChars += $lineChars

        if ([string]::IsNullOrWhiteSpace($line) -and $current.Count -gt 0) {
            $chunks.Add(($current -join "`n"))
            $current.Clear()
            $currentChars = 0
        }
    }

    if ($current.Count -gt 0) {
        $chunks.Add(($current -join "`n"))
    }

    return $chunks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Escape-SigilString {
    param([string]$Text)

    return $Text.Replace("\", "\\").Replace('"', '\"')
}

function Normalize-EtchText {
    param([string]$Text)

    $normalized = $Text.Replace('"', "'").Replace("`0", " ")
    $normalized = [regex]::Replace($normalized, "[^\u0009\u000A\u000D\u0020-\u007E]", " ")
    return $normalized
}

function Invoke-Sigil {
    param(
        [string]$Uri,
        [string]$Script
    )

    $body = @{ sigil = $Script } | ConvertTo-Json -Compress
    return Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json" -Body $body
}

function Get-Stats {
    param([string]$Uri)

    return Invoke-RestMethod -Uri $Uri -Method Get
}

function Send-JanitorPulse {
    param([string]$Base)

    $script = @(
        'MOOD "focused"',
        'LOCK "fn"',
        'LOCK "const"',
        'LOCK "struct"',
        'LOCK "return"',
        'LOCK "if"'
    ) -join "`n"

    Invoke-Sigil -Uri "$Base/api/sigil" -Script $script | Out-Null
}

$targetFiles = Get-TargetFiles -Root $RepoRoot
if (-not $targetFiles -or $targetFiles.Count -eq 0) {
    throw "No target files found for Deep Etch."
}

$initialStats = Get-Stats -Uri "$BaseUri/api/stats"
$initialSlotUsage = [double]$initialStats.stats.slotUsagePct
if ($initialSlotUsage -ge $StopSlotUsagePct) {
    throw "Refusing to etch: slot usage is already $initialSlotUsage% (threshold $StopSlotUsagePct%)."
}

$logDir = Join-Path $RepoRoot "logs\deep_etch_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logPath = Join-Path $logDir "etch.jsonl"

$fileCount = 0
$chunkCount = 0

foreach ($file in $targetFiles) {
    $fileCount += 1
    $relative = Resolve-Path -Relative $file.FullName
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $chunks = Split-SemanticChunks -Text $content -LineCap $MaxLines -CharCap $MaxChars
    $chunkIndex = 0

    foreach ($chunk in $chunks) {
        $chunkIndex += 1
        $chunkCount += 1
        $normalized = Normalize-EtchText -Text $chunk
        $payload = "FILE $relative`nCHUNK $chunkIndex/$($chunks.Count)`n$normalized"
        $sigilText = 'ETCH "' + (Escape-SigilString -Text $payload) + '" @' + $EtchWeight
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Invoke-Sigil -Uri "$BaseUri/api/sigil" -Script $sigilText
        } catch {
            $snippetLen = [Math]::Min(160, $normalized.Length)
            $snippet = if ($snippetLen -gt 0) { $normalized.Substring(0, $snippetLen) } else { "" }
            throw "Etch failed for $relative chunk $chunkIndex/$($chunks.Count). Snippet: $snippet"
        }
        $sw.Stop()

        $entry = [pscustomobject]@{
            ts = (Get-Date).ToString("o")
            file = $relative
            chunk = $chunkIndex
            total_chunks = $chunks.Count
            chars = $chunk.Length
            ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $logPath -Value $entry

        if (($chunkCount % $StatusEvery) -eq 0) {
            $stats = Get-Stats -Uri "$BaseUri/api/stats"
            $slotUsage = [double]$stats.stats.slotUsagePct
            $emaAvg = [double]$stats.stats.emaAverage
            $emaDev = [double]$stats.stats.emaDeviation

            if ($slotUsage -ge $StopSlotUsagePct) {
                throw "Stopping etch at chunk ${chunkCount}: slot usage reached $slotUsage%."
            }

            if ($emaDev -ge 24.0) {
                Send-JanitorPulse -Base $BaseUri
                Start-Sleep -Milliseconds 200
            }
        }

        if ($SleepMs -gt 0) {
            Start-Sleep -Milliseconds $SleepMs
        }
    }
}

$finalStats = Get-Stats -Uri "$BaseUri/api/stats"
[pscustomobject]@{
    files = $fileCount
    chunks = $chunkCount
    log = $logPath
    slotUsagePctBefore = [double]$initialStats.stats.slotUsagePct
    slotUsagePctAfter = [double]$finalStats.stats.slotUsagePct
    emaAverageAfter = [double]$finalStats.stats.emaAverage
    emaDeviationAfter = [double]$finalStats.stats.emaDeviation
} | ConvertTo-Json -Depth 4
