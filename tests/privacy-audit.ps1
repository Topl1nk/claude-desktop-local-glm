# Privacy audit: scans every file git would publish - the current index AND every commit in the
# history - for personal data and secrets. Run it before every push:
#
#   powershell -ExecutionPolicy Bypass -File tests\privacy-audit.ps1
#
# Personal patterns are NOT written in this file (that would leak them). They are derived from this
# machine at run time - Windows user name, computer name, git e-mail, the folders around the
# repository, Ollama/MinerU paths - plus one pattern per line from <ROOT>\.privacy-patterns
# (never committed). Secrets are matched by the formats of common API keys and tokens.
# Exit code 0 = clean, 1 = findings.
#
# -CurrentOnly: scan only the staged files (what the next commit contains), not the history.
# The GitHub account name is public anyway as the repository owner, so the GitHub no-reply address
# and the licence's copyright line are allowed.
param([switch]$CurrentOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

# ---------------------------------------------------------------- personal patterns
$personal = New-Object System.Collections.Generic.List[string]
function Add-Literal([string]$text) {
  if ($text -and $text.Trim().Length -ge 3) { $personal.Add([regex]::Escape($text.Trim())) }
}
Add-Literal $env:USERNAME
foreach ($part in ($env:USERNAME -split '\s+')) { if ($part.Length -ge 4) { Add-Literal $part } }
Add-Literal $env:COMPUTERNAME
Add-Literal (git config user.email)
Add-Literal (git config --global user.email)
foreach ($p in @((git config --global user.email) -split '@')[0]) { if ($p.Length -ge 5) { Add-Literal $p } }
# Folders above the repository (e.g. C:\Something\AI\<repo>): their names identify this machine.
$parent = Split-Path $repo -Parent
while ($parent -and (Split-Path $parent -Parent)) {
  $leaf = Split-Path $parent -Leaf
  # Generic system folder names are not personal (and "Temp" would match "config-templates").
  $systemFolders = @('AI', 'Users', 'home', 'src', 'dev', 'Projects', 'Documents', 'Desktop', 'Downloads',
                     'AppData', 'Local', 'LocalLow', 'Roaming', 'Temp', 'tmp', 'Program Files', 'repos', 'git', 'code')
  if ($leaf.Length -ge 3 -and $leaf -notin $systemFolders) { Add-Literal $leaf }
  $parent = Split-Path $parent -Parent
}
foreach ($v in 'OLLAMA_MODELS', 'MINERU_HOME') {
  $val = [Environment]::GetEnvironmentVariable($v, 'User')
  if ($val -and $val -notlike "$repo*") { Add-Literal $val }
}
$extra = Join-Path $repo '.privacy-patterns'
if (Test-Path $extra) {
  Get-Content $extra -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $personal.Add($_) }
}
$personalRegex = ($personal | Select-Object -Unique) -join '|'

# ---------------------------------------------------------------- generic patterns
$generic = [ordered]@{
  'e-mail address'          = '[A-Za-z0-9._%+-]+@(?!users\.noreply\.github\.com|anthropic\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  'path on a drive other than C: (use <folder> in examples)' = '(?<![A-Za-z])[D-Zd-z]:\\[A-Za-z0-9_]'
  'user profile path with a real name' = 'C:\\Users\\(?!<|%|WDAGUtilityAccount|Public)[A-Za-z]'
  'Anthropic key'           = 'sk-ant-[A-Za-z0-9_-]{20,}'
  'OpenAI-style key'        = 'sk-[A-Za-z0-9]{32,}'
  'GitHub token'            = 'gh[pousr]_[A-Za-z0-9]{30,}'
  'AWS access key'          = 'AKIA[0-9A-Z]{16}'
  'Google API key'          = 'AIza[0-9A-Za-z_-]{35}'
  'Slack token'             = 'xox[abpr]-[A-Za-z0-9-]{10,}'
  'Hugging Face token'      = 'hf_[A-Za-z0-9]{30,}'
  'Bearer token'            = 'Bearer\s+[A-Za-z0-9._-]{20,}'
  'private key'             = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'long hex secret'         = '(?i)(secret|token|key|password)[^\n]{0,20}[=:]\s*["'']?[0-9a-f]{32,}'
  'key/password assignment' = '(?i)(api[_-]?key|secret|password|passwd|token)\s*[=:]\s*["''][^"''<>{}$\s]{12,}["'']'
  'public IP address'       = '(?<![\d.])(?!127\.|10\.|192\.168\.|0\.0\.|255\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.])'
}
# Known placeholders that look like secrets but are not.
$allow = 'ollama-local|<random hex>|set-by-SEARXNG_SECRET|@users\.noreply\.github\.com|^Copyright \(c\) \d{4} \S+$'

# ---------------------------------------------------------------- scan
$findings = New-Object System.Collections.Generic.List[string]
function Scan([string]$label, [string]$text) {
  $lines = $text -split "`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match $allow) { continue }
    if ($personalRegex -and $line -match "(?i)($personalRegex)") {
      $findings.Add("$label`:$($i + 1)  [personal: $($Matches[0])]  $($line.Trim())")
    }
    foreach ($name in $generic.Keys) {
      if ($line -match $generic[$name]) { $findings.Add("$label`:$($i + 1)  [$name]  $($line.Trim())") }
    }
  }
}

# 1. Every blob reachable from any commit, plus the staged index.
$blobs = @{}
$revs = if ($CurrentOnly) { @() } else { @(git rev-list --all 2>$null) }
foreach ($rev in $revs) {
  foreach ($row in (git ls-tree -r $rev)) {
    $parts = $row -split '\s+', 4
    if ($parts[1] -eq 'blob' -and -not $blobs.ContainsKey($parts[2])) { $blobs[$parts[2]] = "$($parts[3]) @ $($rev.Substring(0, 7))" }
  }
}
foreach ($row in (git ls-files -s)) {
  $parts = $row -split '\s+', 4
  if (-not $blobs.ContainsKey($parts[1])) { $blobs[$parts[1]] = "$($parts[3]) @ index" }
}
foreach ($sha in $blobs.Keys) {
  $name = $blobs[$sha]
  Scan "$name (file name)" $name
  $raw = (git cat-file -p $sha) -join "`n"
  if ($raw.IndexOf([char]0) -ge 0) {
    # Screenshots in docs/ are expected; their pixels cannot be scanned, so check them by eye.
    if ($name -match '^docs/[^ ]+\.(png|jpg|jpeg|gif|webp) @') { continue }
    $findings.Add("$name  [binary file - check that it is yours to publish]"); continue
  }
  Scan $name $raw
}

# 2. Commit metadata: author, committer, messages.
foreach ($rev in $revs) {
  Scan "commit $($rev.Substring(0, 7)) (metadata)" ((git log -1 --format='%an <%ae>%n%cn <%ce>%n%B' $rev) -join "`n")
}

Write-Host "Scanned $($blobs.Count) file versions in $($revs.Count) commits + the index."
Write-Host "Personal patterns checked: $(($personal | Select-Object -Unique).Count) (from this machine and .privacy-patterns)."
if ($findings.Count) {
  Write-Host "`nFINDINGS ($($findings.Count)):" -ForegroundColor Red
  $findings | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
  exit 1
}
Write-Host 'CLEAN: nothing personal or secret found.' -ForegroundColor Green
