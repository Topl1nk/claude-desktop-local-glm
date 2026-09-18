# Grey branding for the LOCAL Claude window, so it is never confused with the subscription one.
#
# Both modes run the same MSIX app with the same icons, and its files cannot be changed. So this
# helper, started by desktop-mode.ps1 in local mode, works from the outside while the local window
# is open:
#   - taskbar: gives each local window its own AppUserModelID with the grey icon, so it gets a
#     separate grey taskbar button (a pin of that button relaunches through desktop-mode.ps1);
#   - window / Alt+Tab icon: WM_SETICON with the grey icon;
#   - tray: shows a grey icon (the app's own tray icon is turned off for local mode only via
#     preferences.menuBarEnabled=false in Claude-3p\claude_desktop_config.json).
# It exits by itself when the local Claude closes. Only one copy runs at a time.
#
# The local instance is recognised by its renderer processes' --user-data-dir ...\Claude-3p;
# the subscription instance uses ...\Roaming\Claude and is never touched.
$ErrorActionPreference = 'Stop'
$LocalRoot = Split-Path $PSScriptRoot -Parent
$icoPath   = Join-Path $LocalRoot 'assets\claude-local-grey.ico'
$appId     = 'Claude.LocalOllama'
$relaunch  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -WindowStyle Hidden ' +
             "-ExecutionPolicy Bypass -File `"$PSScriptRoot\desktop-mode.ps1`" -Mode qwen -StartDocker -KeepOther"

# The icons are built locally from the installed Claude Desktop (the repository ships none).
if (-not (Test-Path -LiteralPath $icoPath)) {
  try { & (Join-Path $PSScriptRoot 'make-icons.ps1') | Out-Null } catch {}
  if (-not (Test-Path -LiteralPath $icoPath)) { exit 0 }
}

$mutex = New-Object Threading.Mutex($false, 'Local\ClaudeLocalBranding')
if (-not $mutex.WaitOne(0)) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'LocalBranding.cs')

function Get-LocalClaudePid {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'")
  foreach ($main in $all | Where-Object { $_.ExecutablePath -like '*\WindowsApps\*' -and $_.CommandLine -notmatch '--type=' }) {
    $child = $all | Where-Object { $_.ParentProcessId -eq $main.ProcessId -and $_.CommandLine -match '--user-data-dir=[^-]*\\Claude-3p' } |
             Select-Object -First 1
    if ($child) { return [int]$main.ProcessId }
  }
  0
}

# The launcher starts this right after Claude.exe: wait for the local instance to appear.
$claudePid = 0
for ($i = 0; $i -lt 90 -and $claudePid -eq 0; $i++) {
  $claudePid = Get-LocalClaudePid
  if ($claudePid -eq 0) { Start-Sleep -Seconds 1 }
}
if ($claudePid -eq 0) { exit 0 }

$branded = New-Object 'System.Collections.Generic.HashSet[long]'
function Update-Windows {
  foreach ($h in [LocalBranding]::TopWindows($claudePid)) {
    try {
      # The ID is set once per window; the icon is re-sent because Electron may reset it.
      if ($branded.Add([long]$h)) { [LocalBranding]::SetIdentity($h, $appId, $icoPath, $relaunch, 'Claude - Local') }
      [LocalBranding]::SetWindowIcon($h, $icoPath)
    } catch {}
  }
}

function Show-LocalWindow {
  $h = [LocalBranding]::TopWindows($claudePid) | Select-Object -First 1
  if ($h) {
    if ([LocalBranding]::IsIconic($h)) { [void][LocalBranding]::ShowWindow($h, 9) }  # SW_RESTORE
    [void][LocalBranding]::SetForegroundWindow($h)
  }
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = New-Object Drawing.Icon($icoPath, 32, 32)
$tray.Text = 'Claude - Local (GLM-4.7-Flash, Ollama)'
$menu = New-Object Windows.Forms.ContextMenuStrip
# Menu in the Windows display language, like install.ps1.
$labels = switch ((Get-UICulture).TwoLetterISOLanguageName) {
  'uk' { 'Відкрити Claude Local', 'Закрити Claude Local' }
  'ru' { 'Открыть Claude Local', 'Закрыть Claude Local' }
  default { 'Open Claude Local', 'Close Claude Local' }
}
[void]$menu.Items.Add($labels[0], $null, { Show-LocalWindow })
[void]$menu.Items.Add($labels[1], $null, {
  # With the app's own tray disabled, closing the main window quits the local instance.
  try { [void](Get-Process -Id $claudePid).CloseMainWindow() } catch {}
})
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-LocalWindow } })
$tray.Visible = $true

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1500
$timer.add_Tick({
  if (-not (Get-Process -Id $claudePid -ErrorAction SilentlyContinue)) {
    $timer.Stop(); $tray.Visible = $false; $tray.Dispose()
    [Windows.Forms.Application]::ExitThread()
    return
  }
  Update-Windows
})
Update-Windows
$timer.Start()
[Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
