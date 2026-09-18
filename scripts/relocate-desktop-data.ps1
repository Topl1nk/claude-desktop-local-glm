# Moves Claude Desktop's local-mode data directory (chats, profile, caches) into this folder and
# leaves a directory junction behind, so the app keeps finding it at its hardcoded path.
#
# Claude Desktop hardcodes %LOCALAPPDATA%\Claude-3p for local (3p) mode: the path cannot be
# configured away, but a junction is transparent to the app.
#
# Run with EVERY Claude window closed, including Claude Code sessions - Windows cannot move a
# directory a running process holds open. The script refuses to run otherwise.
#
#   powershell -ExecutionPolicy Bypass -File "<ROOT>\scripts\relocate-desktop-data.ps1"
#
# Safety: copies first, verifies file count and total bytes, and only then deletes the original.
param([string]$Target = (Join-Path (Split-Path $PSScriptRoot -Parent) 'desktop-data'))
$ErrorActionPreference = 'Stop'
$source = Join-Path $env:LOCALAPPDATA 'Claude-3p'

function Measure-Tree($path) {
  $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue)
  [pscustomobject]@{ Count = $files.Count; Bytes = ($files | Measure-Object Length -Sum).Sum }
}

# 1. Nothing may hold the directory open.
$running = @(Get-Process claude -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
  Write-Host "Claude is still running ($($running.Count) processes)." -ForegroundColor Yellow
  Write-Host 'Close both Claude windows (and any Claude Code session), then run this again.'
  exit 1
}

function New-DataJunction {
  $out = cmd /c mklink /J "$source" "$Target" 2>&1
  $link = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
  if (-not $link -or $link.LinkType -ne 'Junction') {
    Write-Host "Junction was not created: $out" -ForegroundColor Red
    Write-Host "Your data is safe in $Target." -ForegroundColor Red
    exit 1
  }
  $ok = (Test-Path -LiteralPath (Join-Path $source 'claude_desktop_config.json')) -and
        (Test-Path -LiteralPath (Join-Path $source 'configLibrary'))
  if (-not $ok) {
    Write-Host "Junction exists but the expected files are not visible through it - check $Target." -ForegroundColor Red
    exit 1
  }
  Write-Host ''
  Write-Host "Done: $source -> $($link.Target)" -ForegroundColor Green
  Write-Host 'Now start Claude with the "Claude - Local Qwen" shortcut and check that your local chats are in place.'
  exit 0
}

$targetHasData = (Test-Path -LiteralPath (Join-Path $Target 'claude_desktop_config.json')) -and
                 (Test-Path -LiteralPath (Join-Path $Target 'configLibrary'))

$item = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
if ($item -and $item.LinkType -eq 'Junction') {
  Write-Host "Already done: $source -> $($item.Target)" -ForegroundColor Green
  exit 0
}

# Repair: the data was already moved, but the junction is missing. Something (e.g. a plugin writing
# into its working directory) may have recreated a plain folder with a few new files in its place.
if ($targetHasData) {
  if ($item -and (Test-Path -LiteralPath (Join-Path $source 'claude_desktop_config.json'))) {
    Write-Host "Both $source and $Target contain Claude data. Resolve this by hand before re-running." -ForegroundColor Red
    exit 1
  }
  if ($item) {
    $keep = Join-Path $Target ('_leftover-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Host "Data is already in $Target; saving the few files that appeared in $source to $keep"
    robocopy $source $keep /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Write-Host "Could not save the leftovers (robocopy $LASTEXITCODE). Nothing deleted." -ForegroundColor Red; exit 1 }
    Remove-Item -LiteralPath $source -Recurse -Force
  }
  New-DataJunction
}

if (-not $item) { Write-Host "Nothing to move: $source does not exist."; exit 0 }

# 2. The target must be empty on the first run (a leftover half-copy would break verification).
if (Test-Path -LiteralPath $Target) {
  $existing = Measure-Tree $Target
  if ($existing.Count -gt 0) {
    Write-Host "$Target already contains $($existing.Count) files. Empty it or pass -Target <other path>." -ForegroundColor Red
    exit 1
  }
}

$before = Measure-Tree $source
$needGb = [math]::Round($before.Bytes / 1GB, 2)
$drive = Get-PSDrive -Name (Split-Path -Qualifier $Target).TrimEnd(':')
$freeGb = [math]::Round($drive.Free / 1GB, 2)
Write-Host "Moving $($before.Count) files, $needGb GB"
Write-Host "  from: $source"
Write-Host "    to: $Target  (free: $freeGb GB)"
if ($drive.Free -lt $before.Bytes * 1.05) {
  Write-Host "Not enough free space on $($drive.Name):" -ForegroundColor Red
  exit 1
}

# 3. Copy (not move), so the original stays intact until the copy is verified.
New-Item -ItemType Directory -Force $Target | Out-Null
robocopy $source $Target /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NP | Out-Null
$code = $LASTEXITCODE
if ($code -ge 8) {
  Write-Host "robocopy reported errors (exit $code). Nothing was deleted; $source is untouched." -ForegroundColor Red
  exit 1
}

# 4. Verify before deleting anything.
$after = Measure-Tree $Target
if ($after.Count -ne $before.Count -or $after.Bytes -ne $before.Bytes) {
  Write-Host 'Verification failed - the copy does not match the original:' -ForegroundColor Red
  Write-Host "  original: $($before.Count) files, $($before.Bytes) bytes"
  Write-Host "  copy:     $($after.Count) files, $($after.Bytes) bytes"
  Write-Host "Nothing was deleted; $source is untouched. Re-run with every Claude window closed." -ForegroundColor Red
  exit 1
}
Write-Host "Verified: $($after.Count) files, identical byte count." -ForegroundColor Green

# 5. Replace the original with a junction and prove the app's files are reachable through it.
Remove-Item -LiteralPath $source -Recurse -Force
New-DataJunction
