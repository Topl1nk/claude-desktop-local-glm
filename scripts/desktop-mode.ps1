# -StartDocker: if Docker is not running, start Docker Desktop and wait (up to ~2 min) so the
#   self-hosted SearXNG container can come up. Without it the search adapter just uses DuckDuckGo.
# -KeepOther: do not close Claude windows that are already open, so the local (3p) and the
#   subscription (1p) window can run side by side. They use different user-data directories
#   (%LOCALAPPDATA%\Claude-3p vs the MSIX package cache), so Electron's single-instance lock
#   does not collide. The mode itself is read from Claude-3p\claude_desktop_config.json once at
#   startup, which is why this script writes it just before launching and then waits.
param([ValidateSet('qwen','subscription')][string]$Mode='qwen', [switch]$StartDocker, [switch]$KeepOther)
$ErrorActionPreference='Stop'
$api='http://127.0.0.1:11434'
# Everything this local setup owns lives under one folder: scripts, Claude Code config, MinerU models.
$LocalRoot=Split-Path $PSScriptRoot -Parent
# Claude Desktop's 3p/local path always requests these fixed model ids. Point each
# tier at a different real Ollama model so all three are reachable in one running
# app/chat via Desktop's own Opus/Sonnet/Haiku picker -- no relaunch needed.
$aliasModel=[ordered]@{
  # Sonnet is Desktop's default tier, so the fast MoE model goes there.
  # The *-tuned models are the library models with num_batch 2048 (work/Modelfile.*-tuned):
  # with Ollama's default batch a 25K-token Claude Code prompt takes 11 minutes instead of 33 seconds.
  # All three tiers point at ONE model on purpose: this PC has 8 GB VRAM, and a second distinct
  # model evicts the first (health probe and chat would keep kicking each other out of memory).
  # Aliases sharing one model share one loaded runner, so any tier answers instantly.
  'claude-sonnet-4-6'='glm-4.7-flash-tuned'
  'claude-opus-4-6'='glm-4.7-flash-tuned'
  'claude-haiku-4-5-20251001'='glm-4.7-flash-tuned'
}
$model=$aliasModel['claude-sonnet-4-6']

function Test-Ollama {
  try { Invoke-RestMethod "$api/api/version" -TimeoutSec 3 | Out-Null; $true } catch { $false }
}

function Show-Splash([string]$text) {
  Add-Type -AssemblyName System.Windows.Forms
  $form=New-Object Windows.Forms.Form
  $form.Text='Claude - Local'
  $form.Size=New-Object Drawing.Size(420,120)
  $form.StartPosition='CenterScreen'
  $form.FormBorderStyle='FixedToolWindow'
  $form.TopMost=$true
  $label=New-Object Windows.Forms.Label
  $label.Text=$text
  $label.Dock='Fill'
  $label.TextAlign='MiddleCenter'
  $form.Controls.Add($label)
  $form.Show()
  [Windows.Forms.Application]::DoEvents()
  $form
}

$splash=$null
try {
  $package=Get-AppxPackage -Name Claude | Select-Object -First 1
  if (!$package) { throw 'Claude Desktop package was not found.' }
  $exe=Join-Path $package.InstallLocation 'app/Claude.exe'
  if (!(Test-Path -LiteralPath $exe)) { throw 'Claude Desktop executable was not found.' }

  # Claude Desktop may have been installed after install.ps1 ran: build the shortcut icons now
  # (they come from the app's own logo) and refresh Explorer's icon cache. Best effort.
  if (-not (Test-Path -LiteralPath (Join-Path $LocalRoot 'assets\claude-local-grey.ico'))) {
    try {
      & (Join-Path $PSScriptRoot 'make-icons.ps1') | Out-Null
      & (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -show
    } catch {}
  }

  if (-not $KeepOther) {
    $running=@(Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    foreach ($proc in $running) { if ($proc.MainWindowHandle -ne 0) { [void]$proc.CloseMainWindow() } }
    Start-Sleep -Seconds 3
    Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process
    Start-Sleep -Seconds 1
  }

  $file=Join-Path $env:LOCALAPPDATA 'Claude-3p/claude_desktop_config.json'
  if (-not (Test-Path -LiteralPath $file)) {
    $moved = Join-Path $LocalRoot 'desktop-data\claude_desktop_config.json'
    if (Test-Path -LiteralPath $moved) {
      throw ("Claude's local data is in $LocalRoot\desktop-data, but the link from " +
             "$env:LOCALAPPDATA\Claude-3p is missing.`n`nClose EVERY Claude window and run:`n" +
             "$PSScriptRoot\relocate-desktop-data.ps1")
    }
    # Fresh install: the app has never run in local mode. The mode file only needs deploymentMode.
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, '{"deploymentMode": "3p"}', (New-Object Text.UTF8Encoding($false)))
  }
  Set-ItemProperty -LiteralPath $file -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
  $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  $cfg | Add-Member -NotePropertyName deploymentMode -NotePropertyValue $(if($Mode -eq 'subscription'){'1p'}else{'3p'}) -Force
  if ($Mode -ne 'subscription') {
    # Local mode only (these preferences belong to the 3p data dir; the subscription keeps its own
    # in %APPDATA%\Claude): hide the app's orange tray icon - local-branding.ps1 shows a grey one.
    if (-not $cfg.preferences) { $cfg | Add-Member -NotePropertyName preferences -NotePropertyValue ([pscustomobject]@{}) -Force }
    $cfg.preferences | Add-Member -NotePropertyName menuBarEnabled -NotePropertyValue $false -Force
  }
  [IO.File]::WriteAllText($file,($cfg | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
  if ($KeepOther) {
    # A Claude window that is already running rewrites this file within seconds, and the new
    # instance would then start in the wrong mode (and collide on the other mode's data dir).
    # Keep it read-only until the new instance has read it.
    Set-ItemProperty -LiteralPath $file -Name IsReadOnly -Value $true
  }

  # After a crash or a forced restart of Ollama its engine can stay alive and keep holding VRAM;
  # the next load then dies with "CUDA error: out of memory". Kill engines older than their server.
  $ollamaStart = (Get-Process ollama -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending | Select-Object -First 1).StartTime
  if ($ollamaStart) {
    Get-Process llama-server -ErrorAction SilentlyContinue |
      Where-Object { $_.StartTime -lt $ollamaStart } |
      Stop-Process -Force -ErrorAction SilentlyContinue
  }

  if ($Mode -ne 'subscription') {
    if (!(Test-Ollama)) {
      $ollamaApp = Join-Path $env:LOCALAPPDATA 'Programs/Ollama/ollama app.exe'
      if (Test-Path -LiteralPath $ollamaApp) { Start-Process $ollamaApp }
      else {
        # Portable Ollama (install.ps1 without winget) has no tray app: run the server directly.
        Start-Process (Join-Path $env:LOCALAPPDATA 'Programs/Ollama/ollama.exe') -ArgumentList 'serve' -WindowStyle Hidden
      }
      for ($i=0; $i -lt 30 -and !(Test-Ollama); $i++) { Start-Sleep -Seconds 2 }
      if (!(Test-Ollama)) { throw 'Ollama is not running.' }
    }
    $splash=Show-Splash 'Wiring up the local model (all tiers -> GLM-4.7-Flash)...'
    # Re-point the fixed alias names, one per tier, at their real model (cheap: shares blobs, no extra disk).
    # Done over Ollama's HTTP API: the CLI writes "model not found" to stderr, which PowerShell
    # turns into a terminating error when the alias does not exist yet.
    $installed=@((Invoke-RestMethod "$api/api/tags" -TimeoutSec 30).models | ForEach-Object { $_.name })
    $missing=@($aliasModel.Values | Where-Object { $_ -notin $installed -and "$($_):latest" -notin $installed })
    if ($missing.Count -gt 0) {
      throw ("These local models are missing in Ollama: {0}. Pull them, or fix the alias map at the top of desktop-mode.ps1." -f ($missing -join ', '))
    }
    foreach ($alias in $aliasModel.Keys) {
      if ($alias -in $installed -or "$($alias):latest" -in $installed) {
        Invoke-RestMethod "$api/api/delete" -Method Delete -Body (@{model=$alias} | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 60 | Out-Null
      }
      $body=@{source=$aliasModel[$alias]; destination=$alias} | ConvertTo-Json
      Invoke-RestMethod "$api/api/copy" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120 | Out-Null
    }
    # Desktop's gateway health check probes the HAIKU alias and gives up after ~10 s, while a cold
    # load takes 20-40 s. Preload the probed tier first, then the default (Sonnet) tier, so the
    # health check passes and the first chat message does not wait for a load.
    $splash.Close()
    # Self-hosted SearXNG behind the search adapter. Best effort and time-boxed: if Docker is not
    # running the adapter falls back to DuckDuckGo, so Desktop must never wait on this.
    $searxUp = $false
    try { $searxUp = [bool](Invoke-WebRequest 'http://127.0.0.1:8888/' -TimeoutSec 2 -UseBasicParsing) } catch {}
    if (-not $searxUp) {
      $compose = Join-Path $PSScriptRoot 'searxng\docker-compose.yml'
      $docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
      if ((Test-Path $compose) -and (Test-Path $docker)) {
        $dockerReady = $false
        try { & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $dockerReady = $LASTEXITCODE -eq 0 } catch {}
        if (-not $dockerReady -and $StartDocker) {
          $desktopExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
          if (Test-Path $desktopExe) {
            $splash = Show-Splash 'Starting Docker for the local search engine...'
            Start-Process $desktopExe
            for ($i = 0; $i -lt 60 -and -not $dockerReady; $i++) {
              Start-Sleep -Seconds 2
              try { & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $dockerReady = $LASTEXITCODE -eq 0 } catch {}
            }
            $splash.Close(); $splash = $null
          }
        }
        if ($dockerReady) {
          $splash = Show-Splash 'Starting the local search engine (SearXNG)...'
          Start-Process -FilePath $docker -ArgumentList "compose -f `"$compose`" up -d" -WindowStyle Hidden -Wait
          for ($i = 0; $i -lt 30 -and -not $searxUp; $i++) {
            Start-Sleep -Seconds 2
            try { $searxUp = [bool](Invoke-WebRequest 'http://127.0.0.1:8888/' -TimeoutSec 2 -UseBasicParsing) } catch {}
          }
          $splash.Close(); $splash = $null
        }
      }
    }

    # Web search is served by the docs MCP server (web_search tool), which uses SearXNG above and
    # falls back to DuckDuckGo. Desktop's built-in websearch server is not used: it requires an
    # https endpoint and drops http://127.0.0.1 entries ("customUrl: must use https").

    # MinerU's local parse server (used by the docs MCP server for scanned PDFs, tables, OCR).
    # Started in the background: the first parse would otherwise wait ~25 s for it.
    # MINERU_HOME keeps its models and database inside this folder instead of the user profile.
    $env:MINERU_HOME=Join-Path $LocalRoot 'mineru'
    $mineru = Join-Path $env:USERPROFILE '.local\bin\mineru.exe'
    if (Test-Path $mineru) {
      Start-Process -FilePath $mineru -ArgumentList 'server start' -WindowStyle Hidden
    }

    # Warm the ALIAS name: Ollama keeps a model in memory per requested name, and Desktop asks by alias.
    # Haiku shares this model, so the health probe is served by the same warm runner.
    foreach ($preload in @('claude-sonnet-4-6')) {
      $splash=Show-Splash "Loading $preload into memory (up to a minute)..."
      $body=@{model=$preload; prompt=''; keep_alive='30m'} | ConvertTo-Json
      Invoke-RestMethod "$api/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600 | Out-Null
      $splash.Close(); $splash=$null
    }
    # The first turn of a new session processes Claude Code's whole system prompt (~2 min on this PC)
    $env:API_TIMEOUT_MS='1800000'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5-20251001'
    # Separate Claude Code config without the 70+ plugins and user MCP servers: keeps the local prompt
    # small and makes this setup independent. The subscription keeps using %USERPROFILE%\.claude.
    $env:CLAUDE_CONFIG_DIR=Join-Path $LocalRoot 'claude-config'
  } elseif (Test-Ollama) {
    # Free the RAM held by local models while on the subscription
    foreach ($m in @((Invoke-RestMethod "$api/api/ps").models)) {
      $body=@{model=$m.name; keep_alive=0} | ConvertTo-Json
      Invoke-RestMethod "$api/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 60 | Out-Null
    }
  }

  Start-Process -FilePath $exe
  if ($Mode -ne 'subscription') {
    # Grey taskbar button, window icon and tray icon for the local window (exits with it).
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList (
      "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\local-branding.ps1`"")
  }
  if ($KeepOther) {
    # Give this instance time to read deploymentMode, then let the app manage the file again.
    Start-Sleep -Seconds 20
    Set-ItemProperty -LiteralPath $file -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
  }
} catch {
  if ($file) { Set-ItemProperty -LiteralPath $file -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
  if ($splash) { $splash.Close() }
  Add-Type -AssemblyName PresentationFramework
  [Windows.MessageBox]::Show($_.Exception.Message,'Claude Desktop setup') | Out-Null
  exit 1
}
