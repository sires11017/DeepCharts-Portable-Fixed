param(
    [switch]$Remove
)

$ip = "127.0.0.1"
$entries = @(
    "demoapi.cqg.com",
    "api.cqg.com",
    "depth-it.historical.deepcharts.com",
    "data-b.historical.deepcharts.com"
)
$hostsPath = Join-Path $env:SYSTEMROOT 'System32\drivers\etc\hosts'
$lines = @(Get-Content $hostsPath -Encoding ASCII)

# Match pattern: whitespace + escaped hostname + end/whitespace/comment
# [regex]::Escape ensures dots in hostnames match literal dots only
function MatchEntry([string]$line, [string]$escaped) {
    return $line -match "\s+$escaped($|\s|#)"
}

if ($Remove) {
    $count = 0
    foreach ($hostname in $entries) {
        $escaped = [regex]::Escape($hostname)
        $before = $lines.Count
        $lines = @($lines | Where-Object { -not (MatchEntry $_ $escaped) })
        $count += ($before - $lines.Count)
    }
    $lines | Out-File $hostsPath -Encoding ascii -Force
    & ipconfig /flushdns 2>&1 | Out-Null
    Write-Host "Removed $count host entries. DNS cache flushed. Direct mode restored." -ForegroundColor Cyan
} else {
    $added = 0; $fixed = 0
    foreach ($hostname in $entries) {
        $escaped = [regex]::Escape($hostname)
        $correctEntry = "$ip $hostname"
        # Skip commented lines — only count active entries
        $existingLines = @($lines | Where-Object { $_ -notmatch '^\s*#' -and (MatchEntry $_ $escaped) })
        if ($existingLines.Count -gt 0) {
            $wrongIp = $existingLines | Where-Object { $_.Trim() -ne $correctEntry }
            if ($wrongIp) {
                $lines = @($lines | Where-Object { -not (MatchEntry $_ $escaped) })
                $lines += $correctEntry
                Write-Host "  [FIXED] $hostname -> $correctEntry" -ForegroundColor Green
                $fixed++
                $added++
            } else {
                Write-Host "  [EXISTS] $correctEntry" -ForegroundColor DarkGray
            }
        } else {
            $lines += $correctEntry
            Write-Host "  [ADDED] $correctEntry" -ForegroundColor Green
            $added++
        }
    }
    $lines | Out-File $hostsPath -Encoding ascii -Force
    Write-Host "Done: $added added, $fixed fixed." -ForegroundColor Cyan
}

Write-Host "Current hosts file entries:" -ForegroundColor DarkGray
Get-Content $hostsPath -Encoding ASCII | Where-Object { $_ -match 'cqg\.com|deepcharts\.com' } | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
