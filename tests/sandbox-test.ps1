# Tests install.ps1 on a clean Windows: a throwaway Windows Sandbox (Windows 10/11 Pro).
#
#   powershell -ExecutionPolicy Bypass -File tests\sandbox-test.ps1
#
# The sandbox gets: a copy of the repo's tracked files (read-only), the host's Ollama models folder
# (read-only, so the ~19 GB model is copied instead of downloaded), and a work folder on the host
# for the model copy and the log. Everything big lands in -WorkDir, not on the sandbox's disk:
# the sandbox disk lives on the host's system drive.
#
# Result: <WorkDir>\results\install-log.txt and exit.txt. Close the sandbox window to discard it.
# Needs ~28 GB free RAM while it runs: stop other big models (e.g. a loaded Ollama model) first.
# -Download: do not map the host's models; the installer downloads the model (~18 GB) from the
# internet, exactly as on a new user's PC.
param(
  [switch]$Download,
  [string]$ModelsSource = $(if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } else { Join-Path $env:USERPROFILE '.ollama\models' }),
  [string]$WorkDir = (Join-Path $env:TEMP 'claude-local-sandbox'),   # ~25 GB: pass a folder on a fast drive
  [int]$MemoryMB = 28672
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path "$env:windir\System32\WindowsSandbox.exe")) {
  throw 'Windows Sandbox is not enabled (Windows Features -> Windows Sandbox).'
}
if (Get-Process WindowsSandbox, WindowsSandboxClient -ErrorAction SilentlyContinue) {
  throw 'A Windows Sandbox is already running - close it first (only one can run at a time).'
}

# Exactly the last commit (what is published), never the live folder: it holds private chats and the
# MinerU database.
$src = Join-Path $WorkDir 'src'
if (Test-Path $src) { Remove-Item -LiteralPath $src -Recurse -Force }
New-Item -ItemType Directory -Force $src | Out-Null
$archive = Join-Path $WorkDir 'src.zip'
git -C $repo archive --format=zip -o $archive HEAD
& (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $archive -C $src
Remove-Item $archive -Force
Write-Host "Testing commit $(git -C $repo rev-parse --short HEAD)$(if (git -C $repo status --porcelain) { ' (the working folder has uncommitted changes - they are NOT tested)' })"
$results = Join-Path $WorkDir 'results'
New-Item -ItemType Directory -Force $results, (Join-Path $WorkDir 'models') | Out-Null
Remove-Item (Join-Path $results '*') -Force -ErrorAction SilentlyContinue

$modelArgs = if ($Download) { '' } else { '-ModelSource C:\ollama-src' }
$bootstrap = @'
$ErrorActionPreference = 'Continue'
robocopy C:\src C:\Claude-Local /E /NFL /NDL /NJH /NJS | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File C:\Claude-Local\install.ps1 `
    MODEL_ARGS -ModelsDir C:\work\models -NoSearxng *>&1 |
  Tee-Object -FilePath C:\work\results\install-log.txt
"EXIT=$LASTEXITCODE" | Out-File C:\work\results\exit.txt -Encoding ascii
Write-Host 'Finished. The log is in the host work folder (results\install-log.txt). Close this window to discard the sandbox.'
'@
[IO.File]::WriteAllText((Join-Path $src 'sandbox-bootstrap.ps1'), $bootstrap.Replace('MODEL_ARGS', $modelArgs), (New-Object Text.UTF8Encoding($true)))
$modelsMap = if ($Download) { '' } else {
  "<MappedFolder><HostFolder>$ModelsSource</HostFolder><SandboxFolder>C:\ollama-src</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>"
}

$wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <vGPU>Enable</vGPU>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$src</HostFolder><SandboxFolder>C:\src</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    $modelsMap
    <MappedFolder><HostFolder>$WorkDir</HostFolder><SandboxFolder>C:\work</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\src\sandbox-bootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $WorkDir 'claude-local.wsb'
[IO.File]::WriteAllText($wsbPath, $wsb, (New-Object Text.UTF8Encoding($false)))
Write-Host "Starting Windows Sandbox. Log: $results\install-log.txt"
Start-Process $wsbPath
# The sandbox runs its LogonCommand without a visible window, so show the progress on the host.
$log = Join-Path $results 'install-log.txt'
$tail = "`$host.UI.RawUI.WindowTitle = 'Sandbox install - live log'; " +
        "while (-not (Test-Path '$log')) { Start-Sleep 1 }; Get-Content '$log' -Wait -Encoding UTF8"
Start-Process powershell -ArgumentList '-NoProfile', '-NoExit', '-Command', $tail
