# Installer for Claude Desktop on the local GLM-4.7-Flash model (Ollama), Windows 10/11.
#
# Run it from the folder the repository was downloaded to (any path; ASCII-only is safest):
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# What it does (every step is safe to re-run):
#   1. checks the hardware and picks the thread count and context length;
#   2. installs Ollama, uv and the Visual C++ runtime if missing (winget, or the vendors' installers);
#   3. sets the Ollama and MinerU environment variables (current user);
#   4. gets GLM-4.7-Flash (~18 GB) and creates the tuned glm-4.7-flash-tuned;
#   5. installs MinerU (PDF/scan reading) and turns its cloud parsing off;
#   6. creates the Claude Desktop local-mode profile with the "docs" MCP server;
#   7. puts the model's rules into claude-config;
#   8. starts the SearXNG search engine when Docker is available (otherwise search uses DuckDuckGo);
#   9. creates the "Claude - Local" (grey) and "Claude - Subscription" (orange) shortcuts;
#  10. checks that everything works.
#
# Messages follow the Windows display language (English, Ukrainian, Russian); override with -Lang.
# Everything, the ~18 GB model included, goes into this folder (<ROOT>\models), unless Ollama already
# has a models folder with the model - then that one is reused.
# Advanced: -ModelsDir (another models folder), -ModelSource (a folder where glm-4.7-flash is already
# downloaded: copy instead of download), -ContextLength, -Threads, -NoSearxng, -Skip<Step>.
# Testing without touching a working setup: -DesktopDataDir and -ShortcutDir.
param(
  [ValidateSet('auto', 'en', 'uk', 'ru')][string]$Lang = 'auto',
  [string]$ModelsDir = '',
  [string]$ModelSource = '',
  [int]$ContextLength = 0,
  [int]$Threads = 0,
  [switch]$NoSearxng,
  [switch]$SkipPrereqs,
  [switch]$SkipEnv,
  [switch]$SkipModel,
  [switch]$SkipMinerU,
  [switch]$SkipProfile,
  [switch]$SkipShortcuts,
  [switch]$SkipChecks,
  [string]$DesktopDataDir = (Join-Path $env:LOCALAPPDATA 'Claude-3p'),
  [string]$ShortcutDir = [Environment]::GetFolderPath('Desktop')
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Model = 'glm-4.7-flash'
$TunedModel = 'glm-4.7-flash-tuned'
$ProfileName = 'Claude-Local (GLM-4.7-Flash)'
$results = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- Messages
if ($Lang -eq 'auto') {
  $Lang = switch ((Get-UICulture).TwoLetterISOLanguageName) { 'uk' { 'uk' } 'ru' { 'ru' } default { 'en' } }
}
# Each entry: English, Ukrainian, Russian. {0}, {1}... are filled in by T.
$Messages = @{
  'header'          = @('Installing local Claude into {0}', 'Встановлення локального Claude у {0}', 'Установка локального Claude в {0}')
  'nonAscii'        = @('Warning: the path has non-Latin characters. It should work, but a folder like C:\AI\Claude-Local is safer.', 'Увага: у шляху є нелатинські символи. Має працювати, але надійніше тека на кшталт C:\AI\Claude-Local.', 'Внимание: в пути есть не-латинские символы. Работать должно, но надёжнее папка вроде C:\AI\Claude-Local.')
  'skipped'         = @('skipped', 'пропущено', 'пропущено')
  'error'           = @('ERROR', 'ПОМИЛКА', 'ОШИБКА')
  'step.hw'         = @('Hardware', 'Обладнання', 'Железо')
  'hw.info'         = @('RAM: {0} GB, cores: {1}, graphics: {2}', "ОЗП: {0} ГБ, ядер: {1}, відеокарта: {2}", 'ОЗУ: {0} ГБ, ядер: {1}, видеокарта: {2}')
  'hw.nogpu'        = @('no NVIDIA GPU found (the model will run on the CPU, slower)', 'NVIDIA не знайдено (модель працюватиме на процесорі, повільніше)', 'NVIDIA не найдена (модель пойдёт на процессоре, медленнее)')
  'hw.plan'         = @('The model will use {0} threads and a {1}-token context', 'Модель буде налаштовано: {0} потоків, контекст {1} токенів', 'Модель будет настроена: {0} потоков, контекст {1} токенов')
  'hw.models'       = @('Models folder: {0}', 'Тека моделей: {0}', 'Папка моделей: {0}')
  'hw.lowram'       = @('Warning: less than 24 GB of RAM. GLM-4.7-Flash (~18 GB) may not fit.', 'Увага: менше 24 ГБ ОЗП. GLM-4.7-Flash (~18 ГБ) може не вміститися.', 'Внимание: меньше 24 ГБ ОЗУ. GLM-4.7-Flash (~18 ГБ) может не поместиться.')
  'hw.nospace'      = @('Not enough space for the model in {0}: {1} GB free, ~25 GB needed.', 'Замало місця для моделі в {0}: вільно {1} ГБ, потрібно ~25 ГБ.', 'Мало места для модели в {0}: свободно {1} ГБ, нужно ~25 ГБ.')
  'hw.unknownspace' = @('Could not read the free space in {0} - make sure ~25 GB are available.', 'Не вдалося дізнатися вільне місце в {0} - переконайтеся, що там є ~25 ГБ.', 'Не удалось узнать свободное место в {0} - проверьте, что там есть ~25 ГБ.')
  'step.prereq'     = @('Programs (Ollama, uv, Claude Desktop)', 'Програми (Ollama, uv, Claude Desktop)', 'Программы (Ollama, uv, Claude Desktop)')
  'pre.have'        = @('{0}: already installed', '{0}: вже встановлено', '{0}: уже установлен')
  'pre.winget'      = @('Installing {0} with winget...', 'Встановлюю {0} через winget...', 'Ставлю {0} через winget...')
  'pre.direct'      = @('No winget - installing {0} with its official installer...', 'winget немає - встановлюю {0} офіційним інсталятором...', 'winget нет - ставлю {0} официальным установщиком...')
  'pre.notfound'    = @('{0} was not found after installing. Restart PowerShell and run the installer again.', '{0} не знайдено після встановлення. Перезапустіть PowerShell і запустіть інсталятор знову.', '{0} не нашёлся после установки. Перезапустите PowerShell и запустите установщик снова.')
  'pre.vc'          = @('Visual C++ Redistributable is missing ({0}) - installing (Windows may ask for permission)...', 'Немає Visual C++ Redistributable ({0}) - встановлюю (Windows може запитати дозвіл)...', 'Нет Visual C++ Redistributable ({0}) - ставлю (Windows может спросить разрешение)...')
  'pre.vcdl'        = @('could not download the Visual C++ Redistributable', 'не вдалося завантажити Visual C++ Redistributable', 'не удалось скачать Visual C++ Redistributable')
  'pre.vctimeout'   = @('the Visual C++ Redistributable installer did not finish in 10 minutes', 'інсталятор Visual C++ Redistributable не завершився за 10 хвилин', 'установщик Visual C++ Redistributable не завершился за 10 минут')
  'pre.vcfail'      = @('the Visual C++ Redistributable did not install ({0} missing). Install it by hand: {1}', 'Visual C++ Redistributable не встановився (немає {0}). Встановіть його вручну: {1}', 'Visual C++ Redistributable не установился (нет {0}). Поставьте его вручную: {1}')
  'pre.noclaude'    = @('Claude Desktop is not installed: get it from https://claude.ai/download and run the installer again.', 'Claude Desktop не встановлено: завантажте його з https://claude.ai/download і запустіть інсталятор знову.', 'Claude Desktop не установлен: скачайте его с https://claude.ai/download и запустите установщик снова.')
  'pre.noclaude.n'  = @('Claude Desktop must be installed by hand', 'Claude Desktop потрібно встановити вручну', 'Claude Desktop нужно поставить вручную')
  'pre.ok'          = @('Ollama, uv, Claude Desktop are in place', 'Ollama, uv, Claude Desktop на місці', 'Ollama, uv, Claude Desktop на месте')
  'ollama.dl'       = @('Downloading Ollama (portable build, ~1.5 GB)...', 'Завантажую Ollama (портативна версія, ~1.5 ГБ)...', 'Скачиваю Ollama (портативная версия, ~1.5 ГБ)...')
  'ollama.unpack'   = @('Unpacking into {0}...', 'Розпаковую в {0}...', 'Распаковываю в {0}...')
  'dl.fail'         = @('could not download {0} (curl {1})', 'не вдалося завантажити {0} (curl {1})', 'не удалось скачать {0} (curl {1})')
  'unzip.fail'      = @('could not unpack {0} (tar {1})', 'не вдалося розпакувати {0} (tar {1})', 'не удалось распаковать {0} (tar {1})')
  'ollama.down'     = @('Ollama did not start (http://127.0.0.1:11434 does not answer).', 'Ollama не запустилася (http://127.0.0.1:11434 не відповідає).', 'Ollama не запустилась (http://127.0.0.1:11434 не отвечает).')
  'step.env'        = @('Environment variables', 'Змінні середовища', 'Переменные окружения')
  'env.restart'     = @('Restarting Ollama so it reads the new settings...', 'Перезапускаю Ollama, щоб вона прочитала нові налаштування...', 'Перезапускаю Ollama, чтобы она прочитала новые настройки...')
  'env.changed'     = @('changed: {0}', 'змінено: {0}', 'изменены: {0}')
  'env.same'        = @('already set', 'вже налаштовано', 'уже настроены')
  'step.model'      = @('Model GLM-4.7-Flash', 'Модель GLM-4.7-Flash', 'Модель GLM-4.7-Flash')
  'model.nosrc'     = @('{0} has no model {1} ({2})', 'у {0} немає моделі {1} ({2})', 'в {0} нет модели {1} ({2})')
  'model.copy'      = @('Copying {0} ({1} GB)...', 'Копіюю {0} ({1} ГБ)...', 'Копирую {0} ({1} ГБ)...')
  'model.copyfail'  = @('could not copy {0} (robocopy {1})', 'не вдалося скопіювати {0} (robocopy {1})', 'не удалось скопировать {0} (robocopy {1})')
  'model.pull'      = @('Downloading the model (~18 GB, this takes a while)...', 'Завантажую модель (~18 ГБ, це надовго)...', 'Скачиваю модель (~18 ГБ, это надолго)...')
  'model.pullfail'  = @('ollama pull {0} failed with code {1}', 'ollama pull {0} завершився з помилкою {1}', 'ollama pull {0} завершился с ошибкой {1}')
  'model.same'      = @('{0} is already set up', '{0} вже налаштована', '{0} уже настроена')
  'model.mkfail'    = @('ollama create {0} failed with code {1}', 'ollama create {0} завершився з помилкою {1}', 'ollama create {0} завершился с ошибкой {1}')
  'model.made'      = @('{0} created', '{0} створено', '{0} создана')
  'step.mineru'     = @('MinerU (PDFs and scans)', 'MinerU (PDF і скани)', 'MinerU (PDF и сканы)')
  'no.uv'           = @('uv not found (see the "Programs" step).', 'uv не знайдено (крок «Програми»).', 'uv не найден (шаг «Программы»).')
  'mineru.install'  = @('Installing MinerU...', 'Встановлюю MinerU...', 'Ставлю MinerU...')
  'mineru.notfound' = @('MinerU was not found after installing.', 'MinerU не знайдено після встановлення.', 'MinerU не нашёлся после установки.')
  'mineru.models'   = @('Downloading the MinerU recognition models (~0.8 GB)...', 'Завантажую моделі розпізнавання MinerU (~0.8 ГБ)...', 'Скачиваю модели MinerU для распознавания (~0.8 ГБ)...')
  'mineru.mfail'    = @('could not download the MinerU models: {0}', 'не вдалося завантажити моделі MinerU: {0}', 'не удалось скачать модели MinerU: {0}')
  'mineru.setfail'  = @('mineru config set {0} failed: {1}', 'mineru config set {0} не спрацював: {1}', 'mineru config set {0} не сработал: {1}')
  'mineru.cloud'    = @('could not turn off MinerU cloud parsing (remote.url = {0})', 'не вдалося вимкнути хмарний розбір MinerU (remote.url = {0})', 'не удалось отключить облачный разбор MinerU (remote.url = {0})')
  'mineru.ok'       = @('installed, models downloaded, cloud parsing off and verified', 'встановлено, моделі завантажено, хмарний розбір вимкнено й перевірено', 'установлен, модели скачаны, облачный разбор отключён и проверен')
  'step.profile'    = @('Claude Desktop profile', 'Профіль Claude Desktop', 'Профиль Claude Desktop')
  'profile.other'   = @('profile {0} written, but another one is active ({1}) - choose "{2}" in the Desktop settings', 'профіль {0} записано, але активний інший ({1}) - виберіть «{2}» у налаштуваннях Desktop', 'профиль {0} записан, но активен другой ({1}) - выберите «{2}» в настройках Desktop')
  'profile.ok'      = @('profile {0} is active', 'профіль {0} активний', 'профиль {0} активен')
  'step.rules'      = @('Model rules (claude-config)', 'Правила для моделі (claude-config)', 'Правила для модели (claude-config)')
  'rules.made'      = @('created: {0}', 'створено: {0}', 'созданы: {0}')
  'rules.kept'      = @('already in place, left untouched', 'вже на місці, не чіпав', 'уже на месте, не трогал')
  'step.searxng'    = @('SearXNG search engine', 'Пошуковик SearXNG', 'Поисковик SearXNG')
  'sx.nodocker'     = @('Docker not found - search will use DuckDuckGo (that is enough)', 'Docker не знайдено - пошук працюватиме через DuckDuckGo (цього достатньо)', 'Docker не найден - поиск будет работать через DuckDuckGo (этого достаточно)')
  'sx.down'         = @('Docker is not running - the "Claude - Local" shortcut will start SearXNG once Docker runs', 'Docker не запущено - ярлик «Claude - Local» підніме SearXNG сам, коли Docker працюватиме', 'Docker не запущен - ярлык «Claude - Local» поднимет SearXNG сам, когда Docker будет работать')
  'sx.fail'         = @('docker compose up failed: {0}', 'docker compose up завершився з помилкою: {0}', 'docker compose up завершился с ошибкой: {0}')
  'sx.ok'           = @('running on http://127.0.0.1:8888', 'працює на http://127.0.0.1:8888', 'запущен на http://127.0.0.1:8888')
  'step.shortcuts'  = @('Shortcuts', 'Ярлики', 'Ярлыки')
  'sc.ok'           = @('in {0}', 'у {0}', 'в {0}')
  'sc.noicons'      = @('no Claude Desktop to take the icons from yet - re-run after installing it', 'ще немає Claude Desktop, з якого взяти іконки - запустіть знову після його встановлення', 'ещё нет Claude Desktop, из которого взять иконки - запустите снова после его установки')
  'rules.karpathy'  = @('coding guidelines downloaded from {0}', 'правила кодування завантажено з {0}', 'правила кодирования скачаны с {0}')
  'rules.nokarpathy'= @('could not download the coding guidelines ({0}) - the rest works without them', 'не вдалося завантажити правила кодування ({0}) - решта працює і без них', 'не удалось скачать правила кодирования ({0}) - остальное работает и без них')
  'step.checks'     = @('Check', 'Перевірка', 'Проверка')
  'chk.nomodel'     = @('Ollama has no model {0}', 'в Ollama немає моделі {0}', 'в Ollama нет модели {0}')
  'chk.ask'         = @('Asking the model (the first load into memory takes up to a couple of minutes, longer without a GPU)...', 'Питаю модель (перше завантаження в пам''ять - до кількох хвилин, без відеокарти довше)...', 'Спрашиваю модель (первая загрузка в память - до пары минут, без видеокарты дольше)...')
  'chk.empty'       = @('the model loaded but returned an empty answer', 'модель завантажилася, але повернула порожню відповідь', 'модель загрузилась, но вернула пустой ответ')
  'chk.reply'       = @('the model answered: {0}', 'модель відповіла: {0}', 'модель ответила: {0}')
  'chk.tests'       = @('Running the docs MCP server tests...', 'Запускаю тести MCP-сервера docs...', 'Прогоняю тесты MCP-сервера docs...')
  'chk.notrun'      = @('the tests did not run: {0}', 'тести не запустилися: {0}', 'тесты не запустились: {0}')
  'chk.failed'      = @('tests failed: {0}', 'не пройшли тести: {0}', 'не прошли тесты: {0}')
  'chk.ok'          = @('the model answers, the docs MCP works', 'модель відповідає, MCP docs працює', 'модель отвечает, MCP docs работает')
  'summary'         = @('Summary', 'Підсумок', 'Итог')
  'sum.fail'        = @('There are errors - fix them and run the installer again (finished steps are skipped).', 'Є помилки - виправте їх і запустіть інсталятор знову (готові кроки він пропустить).', 'Есть ошибки - исправьте их и запустите установщик снова (готовые шаги он пропустит).')
  'sum.ok'          = @('Done. Start the "Claude - Local" shortcut. The first start of the model takes up to a minute.', 'Готово. Запускайте ярлик «Claude - Local». Перший старт моделі триває до хвилини.', 'Готово. Запускайте ярлык «Claude - Local». Первый старт модели занимает до минуты.')
}
$LangIndex = @{ en = 0; uk = 1; ru = 2 }[$Lang]
function T([string]$key) {
  $text = $Messages[$key][$LangIndex]
  if ($args.Count) { $text = $text -f $args }
  $text
}

# ---------------------------------------------------------------- Helpers
function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step([string]$name, [scriptblock]$body) {
  Say "`n=== $name" 'Cyan'
  try {
    $note = & $body
    $results.Add([pscustomobject]@{ Step = $name; Result = 'OK'; Note = "$note" })
    Say "    OK $note" 'Green'
  } catch {
    $results.Add([pscustomobject]@{ Step = $name; Result = 'FAIL'; Note = $_.Exception.Message })
    Say "    $(T 'error'): $($_.Exception.Message)" 'Red'
  }
}
function Skip([string]$name) {
  $results.Add([pscustomobject]@{ Step = $name; Result = 'skip'; Note = '' })
  Say "`n=== $name ($(T 'skipped'))" 'DarkGray'
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Find-Exe([string]$name, [string[]]$candidates) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  $null
}
function Find-Ollama { Find-Exe 'ollama' @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe") }
function Find-Uv { Find-Exe 'uv' @("$env:USERPROFILE\.local\bin\uv.exe", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\uv.exe") }
function Test-OllamaApi { try { Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 3 | Out-Null; $true } catch { $false } }
function Start-OllamaApi {
  if (Test-OllamaApi) { return }
  $app = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
  if (Test-Path -LiteralPath $app) { Start-Process $app } else { Start-Process (Find-Ollama) -ArgumentList 'serve' -WindowStyle Hidden }
  for ($i = 0; $i -lt 30 -and -not (Test-OllamaApi); $i++) { Start-Sleep -Seconds 2 }
  if (-not (Test-OllamaApi)) { throw (T 'ollama.down') }
}
function Invoke-Native([string]$exe, [string[]]$arguments) {
  # PowerShell 5.1 turns a native tool's stderr into a terminating error under "Stop"; judge by exit code.
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $text = (& $exe @arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  [pscustomobject]@{ Code = $code; Text = $text }
}
function Get-File([string]$url, [string]$path) {
  # Windows PowerShell's Invoke-WebRequest with its progress bar is many times slower on big files.
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (Test-Path $curl) {
    & $curl -L --fail --silent --show-error -o $path $url
    if ($LASTEXITCODE -ne 0) { throw (T 'dl.fail' $url $LASTEXITCODE) }
  } else {
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest $url -OutFile $path -UseBasicParsing } finally { $ProgressPreference = $old }
  }
}
function Import-OllamaModel([string]$source, [string]$target, [string]$name) {
  # Offline "ollama pull": copy the manifest and the blobs it references.
  $rel = "manifests\registry.ollama.ai\library\$name\latest"
  $manifestPath = Join-Path $source $rel
  if (-not (Test-Path -LiteralPath $manifestPath)) { throw (T 'model.nosrc' $source $name $rel) }
  $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
  $digests = @($manifest.config.digest) + @($manifest.layers | ForEach-Object { $_.digest })
  New-Item -ItemType Directory -Force (Join-Path $target 'blobs') | Out-Null
  foreach ($d in $digests) {
    $file = $d.Replace(':', '-')
    $src = Join-Path $source "blobs\$file"; $dst = Join-Path $target "blobs\$file"
    if ((Test-Path -LiteralPath $dst) -and (Get-Item $dst).Length -eq (Get-Item $src).Length) { continue }
    Say "    $(T 'model.copy' $file ([math]::Round((Get-Item $src).Length / 1GB, 1)))"
    robocopy (Join-Path $source 'blobs') (Join-Path $target 'blobs') $file /J /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw (T 'model.copyfail' $file $LASTEXITCODE) }
  }
  New-Item -ItemType Directory -Force (Split-Path (Join-Path $target $rel)) | Out-Null
  Copy-Item -LiteralPath $manifestPath (Join-Path $target $rel) -Force
}
function Install-Direct([string]$name) {
  # Fallback when winget is missing (e.g. Windows Sandbox).
  switch ($name) {
    'uv' { & powershell -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex' | Out-Host }
    'Ollama' {
      # The portable build, not OllamaSetup.exe: the setup hung unattended (Windows Sandbox) with no
      # visible window to answer. The zip is just unpacked; desktop-mode.ps1 runs "ollama serve".
      $zip = Join-Path $env:TEMP 'ollama-windows-amd64.zip'
      Say "    $(T 'ollama.dl')"
      Get-File 'https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip' $zip
      $dir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
      Say "    $(T 'ollama.unpack' $dir)"
      New-Item -ItemType Directory -Force $dir | Out-Null
      & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $zip -C $dir   # much faster than Expand-Archive
      if ($LASTEXITCODE -ne 0) { throw (T 'unzip.fail' $zip $LASTEXITCODE) }
      Remove-Item $zip -Force -ErrorAction SilentlyContinue
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      if ($userPath -notlike "*$dir*") { [Environment]::SetEnvironmentVariable('Path', "$userPath;$dir", 'User') }
      Refresh-Path
    }
  }
}
function Write-Utf8([string]$path, [string]$text) {
  New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

Say (T 'header' $Root) 'White'
# Files unpacked from a downloaded zip carry Windows' "downloaded from the internet" mark, which can
# block the helper scripts and the C# helper the launcher compiles. The user chose to run this folder.
Get-ChildItem -LiteralPath $Root -Recurse -File -Include *.ps1, *.cs, *.py, *.cmd -ErrorAction SilentlyContinue |
  Unblock-File -ErrorAction SilentlyContinue
if ($Root -match '[^\x00-\x7F]') { Say (T 'nonAscii') 'Yellow' }

# ---------------------------------------------------------------- Models folder
# Portable by default: the models live in <ROOT>\models next to everything else. An Ollama that is
# already set up keeps its folder, so an existing download is reused instead of fetched again.
if (-not $ModelsDir) {
  $existingModels = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
  $defaultModels = Join-Path $env:USERPROFILE '.ollama\models'
  $ModelsDir = if ($existingModels) { $existingModels }
               elseif (Test-Path (Join-Path $defaultModels "manifests\registry.ollama.ai\library\$Model")) { $defaultModels }
               else { Join-Path $Root 'models' }
}

# ---------------------------------------------------------------- 1. Hardware
# WMI can be denied (restricted accounts, Windows Sandbox right after logon): fall back to .NET.
try {
  $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $cores = (Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum
} catch {
  Add-Type -AssemblyName Microsoft.VisualBasic
  $ramGb = [math]::Round((New-Object Microsoft.VisualBasic.Devices.ComputerInfo).TotalPhysicalMemory / 1GB)
  $cores = [Environment]::ProcessorCount   # logical processors: an upper bound for the thread count
}
$gpu = ''
try { $gpu = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null | Select-Object -First 1) } catch {}
if ($Threads -le 0) { $Threads = [int]$cores }
if ($ContextLength -le 0) {
  $ContextLength = if ($ramGb -ge 48) { 131072 } elseif ($ramGb -ge 32) { 65536 } else { 32768 }
}
Step (T 'step.hw') {
  Say "    $(T 'hw.info' $ramGb $cores $(if ($gpu) { $gpu } else { T 'hw.nogpu' }))"
  Say "    $(T 'hw.plan' $Threads $ContextLength)"
  if ($ramGb -lt 24) { Say "    $(T 'hw.lowram')" 'Yellow' }
  # Free space of the folder itself, not of its drive letter: it can be a mount or a mapped folder.
  $dir = $ModelsDir
  Say "    $(T 'hw.models' $dir)"
  New-Item -ItemType Directory -Force $dir | Out-Null
  Add-Type -Namespace Win32 -Name Disk -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool GetDiskFreeSpaceEx(string d, out ulong a, out ulong t, out ulong f);'
  $avail = [uint64]0; $total = [uint64]0; $freeAll = [uint64]0
  if ([Win32.Disk]::GetDiskFreeSpaceEx($dir, [ref]$avail, [ref]$total, [ref]$freeAll)) {
    $free = $avail / 1GB
    if ($free -lt 25) { throw (T 'hw.nospace' $dir ([math]::Round($free))) }
  } else { Say "    $(T 'hw.unknownspace' $dir)" 'Yellow' }
  "threads=$Threads ctx=$ContextLength"
}

# ---------------------------------------------------------------- 2. Prerequisites
if ($SkipPrereqs) { Skip (T 'step.prereq') } else {
  Step (T 'step.prereq') {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    foreach ($p in @(@{ Name = 'Ollama'; Id = 'Ollama.Ollama'; Find = { Find-Ollama } },
                     @{ Name = 'uv'; Id = 'astral-sh.uv'; Find = { Find-Uv } })) {
      if (& $p.Find) { Say "    $(T 'pre.have' $p.Name)"; continue }
      if ($winget) {
        Say "    $(T 'pre.winget' $p.Name)"
        & winget install -e --id $p.Id --accept-source-agreements --accept-package-agreements | Out-Host
      } else {
        Say "    $(T 'pre.direct' $p.Name)"
        Install-Direct $p.Name
      }
      Refresh-Path
      if (-not (& $p.Find)) { throw (T 'pre.notfound' $p.Name) }
    }
    # MinerU's OCR (onnxruntime) needs the Visual C++ runtime; a clean Windows does not have it
    # ("DLL load failed while importing onnxruntime_pybind11_state").
    $vcFiles = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
    $vc = $vcFiles | Where-Object { -not (Test-Path (Join-Path $env:SystemRoot "System32\$_")) }
    if ($vc) {
      Say "    $(T 'pre.vc' ($vc -join ', '))"
      $redistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
      if ($winget) {
        & winget install -e --id Microsoft.VCRedist.2015+.x64 --accept-source-agreements --accept-package-agreements | Out-Host
      } else {
        $redist = Join-Path $env:TEMP 'vc_redist.x64.exe'
        try { Get-File $redistUrl $redist } catch { throw (T 'pre.vcdl') }
        $proc = Start-Process $redist -ArgumentList '/install', '/quiet', '/norestart' -PassThru
        if (-not $proc.WaitForExit(600000)) { throw (T 'pre.vctimeout') }
      }
      $vc = $vcFiles | Where-Object { -not (Test-Path (Join-Path $env:SystemRoot "System32\$_")) }
      if ($vc) { throw (T 'pre.vcfail' ($vc -join ', ') $redistUrl) }
    }
    if (-not (Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue)) {
      Say "    $(T 'pre.noclaude')" 'Yellow'
      return (T 'pre.noclaude.n')
    }
    T 'pre.ok'
  }
}

# ---------------------------------------------------------------- 3. Environment
if ($SkipEnv) { Skip (T 'step.env') } else {
  Step (T 'step.env') {
    $wanted = [ordered]@{
      OLLAMA_MAX_LOADED_MODELS = '1'           # one model in memory: a second one would evict it from VRAM
      OLLAMA_NUM_PARALLEL      = '1'
      OLLAMA_FLASH_ATTENTION   = '1'
      OLLAMA_KV_CACHE_TYPE     = 'q4_0'        # 4-bit context cache: a long context fits in memory
      OLLAMA_GPU_OVERHEAD      = '1073741824'  # leave 1 GB of VRAM to the system
      MINERU_HOME              = (Join-Path $Root 'mineru')
    }
    $wanted['OLLAMA_MODELS'] = $ModelsDir
    $changed = @()
    foreach ($k in $wanted.Keys) {
      if ([Environment]::GetEnvironmentVariable($k, 'User') -ne $wanted[$k]) {
        [Environment]::SetEnvironmentVariable($k, $wanted[$k], 'User'); $changed += $k
      }
      Set-Item "env:$k" $wanted[$k]
    }
    if ($changed.Count -gt 0 -and (Get-Process ollama -ErrorAction SilentlyContinue)) {
      # Ollama reads these only at startup.
      Say "    $(T 'env.restart')"
      Get-Process 'ollama app', ollama -ErrorAction SilentlyContinue | Stop-Process -Force
      Start-Sleep -Seconds 2
    }
    if ($changed.Count) { T 'env.changed' ($changed -join ', ') } else { T 'env.same' }
  }
}

# ---------------------------------------------------------------- 4. Model
if ($SkipModel) { Skip (T 'step.model') } else {
  Step (T 'step.model') {
    Start-OllamaApi
    $ollama = Find-Ollama
    $names = @((Invoke-RestMethod 'http://127.0.0.1:11434/api/tags').models.name)
    if ($ModelSource -and "$Model`:latest" -notin $names -and $Model -notin $names) {
      Import-OllamaModel $ModelSource $ModelsDir $Model
      $names = @((Invoke-RestMethod 'http://127.0.0.1:11434/api/tags').models.name)
    }
    if ("$Model`:latest" -notin $names -and $Model -notin $names) {
      Say "    $(T 'model.pull')"
      & $ollama pull $Model | Out-Host
      if ($LASTEXITCODE -ne 0) { throw (T 'model.pullfail' $Model $LASTEXITCODE) }
    }
    $modelfile = (Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'config-templates\Modelfile.glm-tuned')).
      Replace('{{NUM_CTX}}', "$ContextLength").Replace('{{NUM_THREAD}}', "$Threads")
    # Recreate only when the parameters differ: "ollama create" on a loaded model is cheap but not free.
    $current = ''
    try { $current = (Invoke-RestMethod 'http://127.0.0.1:11434/api/show' -Method Post -Body (@{ model = $TunedModel } | ConvertTo-Json) -ContentType 'application/json').parameters } catch {}
    if ($current -match "num_ctx\s+$ContextLength\b" -and $current -match "num_thread\s+$Threads\b" -and $current -match 'num_batch\s+2048\b') {
      return (T 'model.same' $TunedModel)
    }
    $tmp = Join-Path $env:TEMP 'Modelfile.glm-tuned'
    Write-Utf8 $tmp $modelfile
    & $ollama create $TunedModel -f $tmp | Out-Host
    if ($LASTEXITCODE -ne 0) { throw (T 'model.mkfail' $TunedModel $LASTEXITCODE) }
    T 'model.made' $TunedModel
  }
}

# ---------------------------------------------------------------- 5. MinerU
if ($SkipMinerU) { Skip (T 'step.mineru') } else {
  Step (T 'step.mineru') {
    $env:MINERU_HOME = Join-Path $Root 'mineru'
    New-Item -ItemType Directory -Force $env:MINERU_HOME | Out-Null
    $mineru = Find-Exe 'mineru' @("$env:USERPROFILE\.local\bin\mineru.exe")
    if (-not $mineru) {
      $uv = Find-Uv; if (-not $uv) { throw (T 'no.uv') }
      Say "    $(T 'mineru.install')"
      & $uv tool install 'mineru>=4.0,<5' | Out-Host
      Refresh-Path
      $mineru = Find-Exe 'mineru' @("$env:USERPROFILE\.local\bin\mineru.exe")
      if (-not $mineru) { throw (T 'mineru.notfound') }
    }
    # "mineru config" talks to the local MinerU server, so it must be running first.
    Invoke-Native $mineru @('server', 'start') | Out-Null
    for ($i = 0; $i -lt 30 -and (Invoke-Native $mineru @('server', 'status')).Code -ne 0; $i++) { Start-Sleep -Seconds 2 }
    # Models first (~0.8 GB): MinerU refuses both the tier and "managed" mode while they are missing.
    $kit = Join-Path (Split-Path $mineru) 'mineru-kit.exe'
    Say "    $(T 'mineru.models')"
    $r = Invoke-Native $kit @('models', 'download', '--tier', 'basic')
    if ($r.Code -ne 0) { throw (T 'mineru.mfail' $r.Text) }
    # Local parsing only: never upload documents to MinerU's cloud (the remote URL is a dead local port).
    $settings = [ordered]@{ 'parse_server.local.managed_tier' = 'basic'; 'parse_server.local.mode' = 'managed'; 'parse_server.remote.url' = 'http://127.0.0.1:9' }
    foreach ($k in $settings.Keys) {
      $r = Invoke-Native $mineru @('config', 'set', $k, $settings[$k])
      if ($r.Code -ne 0 -and $r.Text -match 'different MinerU server instance|server is not running') {
        # Stale endpoint file (e.g. a server left from an earlier install): restart once and retry.
        Invoke-Native $mineru @('server', 'restart') | Out-Null
        $r = Invoke-Native $mineru @('config', 'set', $k, $settings[$k])
      }
      if ($r.Code -ne 0) { throw (T 'mineru.setfail' $k $r.Text) }
    }
    # Documents can be private: prove the cloud is off instead of assuming it.
    $url = (Invoke-Native $mineru @('config', 'get', 'parse_server.remote.url')).Text
    if ($url -notmatch '127\.0\.0\.1:9') { throw (T 'mineru.cloud' $url) }
    T 'mineru.ok'
  }
}

# ---------------------------------------------------------------- 6. Desktop profile
if ($SkipProfile) { Skip (T 'step.profile') } else {
  Step (T 'step.profile') {
    $uv = Find-Uv; if (-not $uv) { throw (T 'no.uv') }
    $docs = Join-Path $Root 'scripts\docs-mcp.py'
    $lib = Join-Path $DesktopDataDir 'configLibrary'
    New-Item -ItemType Directory -Force $lib | Out-Null
    $metaPath = Join-Path $lib '_meta.json'
    $meta = if (Test-Path $metaPath) { Get-Content -Raw $metaPath | ConvertFrom-Json } else { [pscustomobject]@{ appliedId = $null; entries = @() } }
    # Reuse the profile that already runs docs-mcp.py (a re-run updates it instead of adding another).
    $id = $null
    foreach ($f in Get-ChildItem $lib -Filter '*.json' | Where-Object Name -ne '_meta.json') {
      if ((Get-Content -Raw $f.FullName) -match 'docs-mcp\.py') { $id = $f.BaseName; break }
    }
    if (-not $id) { $id = [guid]::NewGuid().ToString() }
    $prof = [ordered]@{
      inferenceProvider             = 'gateway'
      inferenceGatewayBaseUrl       = 'http://127.0.0.1:11434'
      inferenceGatewayApiKey        = 'ollama-local'
      inferenceCredentialKind       = 'static'
      inferenceStreamIdleTimeoutSec = 1800
      deploymentDisplayName         = 'Local models (Ollama)'
      modelDiscoveryEnabled         = $false
      # Desktop always asks for these fixed ids; desktop-mode.ps1 points them at glm-4.7-flash-tuned.
      inferenceModels               = @([ordered]@{ name = 'claude-sonnet-4-6'; labelOverride = 'GLM-4.7-Flash (local)'; anthropicFamilyTier = 'sonnet'; isFamilyDefault = $true })
      # All tools stay in the prompt: with deferred loading the local model never finds the MCP tools.
      toolSearchEnabled             = $false
      autoModeEnabled               = $true
      chatTabEnabled                = $true
      sessionRetentionHold          = $false
      isDesktopExtensionEnabled     = $true
      userPluginMarketplacesEnabled = $true
      userPluginUploadsEnabled      = $true
      allowedPluginMarketplaces     = @([ordered]@{ source = 'github'; repo = 'anthropics/claude-plugins-official'; installationPreference = 'available' })
      managedMcpServers             = @([ordered]@{
        name = 'docs'; transport = 'stdio'; command = $uv
        args = @('run', '--no-project', '--with', 'pypdf', '--with', 'python-docx', 'python', $docs)
      })
      banner                        = [ordered]@{ enabled = $false; backgroundColor = '#F5F5F5'; textColor = '#000000' }
    }
    Write-Utf8 (Join-Path $lib "$id.json") ($prof | ConvertTo-Json -Depth 10)
    $entries = @($meta.entries | Where-Object { $_.id -ne $id }) + @([pscustomobject]@{ id = $id; name = $ProfileName })
    $applied = if ($meta.appliedId) { $meta.appliedId } else { $id }
    Write-Utf8 $metaPath ([pscustomobject]@{ appliedId = $applied; entries = $entries } | ConvertTo-Json -Depth 5)
    $modeFile = Join-Path $DesktopDataDir 'claude_desktop_config.json'
    if (-not (Test-Path $modeFile)) { Write-Utf8 $modeFile '{"deploymentMode": "3p"}' }
    if ($applied -ne $id) { return (T 'profile.other' $id $applied $ProfileName) }
    T 'profile.ok' $id
  }
}

# ---------------------------------------------------------------- 7. Claude Code config
Step (T 'step.rules') {
  $cfg = Join-Path $Root 'claude-config'
  $tpl = Join-Path $Root 'config-templates'
  $made = @()
  # Existing files are the user's: never overwrite them.
  foreach ($n in 'CLAUDE.md', 'settings.json') {
    $dst = Join-Path $cfg $n
    if (Test-Path $dst) { continue }
    Write-Utf8 $dst ((Get-Content -Raw -Encoding UTF8 (Join-Path $tpl $n)).Replace('{{ROOT}}', $Root))
    $made += $n
  }
  # Karpathy's coding guidelines are not ours to redistribute (their repository has no licence), so
  # they are fetched from the original at install time; CLAUDE.md imports them when present.
  $karpathy = Join-Path $cfg 'karpathy-guidelines.md'
  if (-not (Test-Path $karpathy)) {
    $url = 'https://raw.githubusercontent.com/multica-ai/andrej-karpathy-skills/main/CLAUDE.md'
    try {
      Get-File $url $karpathy
      $text = Get-Content -Raw -Encoding UTF8 $karpathy
      Write-Utf8 $karpathy ("<!-- Source: $url (downloaded $(Get-Date -Format yyyy-MM-dd) by install.ps1). Update by deleting this file and re-running the installer. -->`n" + $text)
      $made += 'karpathy-guidelines.md'
      Say "    $(T 'rules.karpathy' $url)"
    } catch {
      Remove-Item $karpathy -Force -ErrorAction SilentlyContinue
      Say "    $(T 'rules.nokarpathy' $_.Exception.Message)" 'Yellow'
    }
  }
  if ($made.Count) { T 'rules.made' ($made -join ', ') } else { T 'rules.kept' }
}

# ---------------------------------------------------------------- 8. SearXNG
if ($NoSearxng) { Skip (T 'step.searxng') } else {
  Step (T 'step.searxng') {
    $docker = Find-Exe 'docker' @('C:\Program Files\Docker\Docker\resources\bin\docker.exe')
    $envFile = Join-Path $Root 'scripts\searxng\.env'
    if (-not (Test-Path $envFile)) {
      $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
      Write-Utf8 $envFile ("SEARXNG_SECRET=" + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '') + "`n")
    }
    if (-not $docker) { return (T 'sx.nodocker') }
    & $docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return (T 'sx.down') }
    $r = Invoke-Native $docker @('compose', '-f', (Join-Path $Root 'scripts\searxng\docker-compose.yml'), 'up', '-d')
    if ($r.Code -ne 0) { throw (T 'sx.fail' $r.Text) }
    T 'sx.ok'
  }
}

# ---------------------------------------------------------------- 9. Shortcuts
if ($SkipShortcuts) { Skip (T 'step.shortcuts') } else {
  Step (T 'step.shortcuts') {
    # The repository ships no Claude logo (Anthropic's trademark): build the icons from the Claude
    # Desktop installed here. Without it the shortcuts still work, just with a generic icon.
    $iconNote = ''
    try { & (Join-Path $Root 'scripts\make-icons.ps1') | Out-Null } catch { $iconNote = " ($(T 'sc.noicons'))" }
    New-Item -ItemType Directory -Force $ShortcutDir | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher = Join-Path $Root 'scripts\desktop-mode.ps1'
    foreach ($s in @(@{ Name = 'Claude - Local'; Args = '-Mode qwen -StartDocker -KeepOther'; Icon = 'claude-local-grey.ico'; Desc = 'Claude Desktop on the local GLM-4.7-Flash model (Ollama). Grey icons = local.' },
                     @{ Name = 'Claude - Subscription'; Args = '-Mode subscription -KeepOther'; Icon = 'claude-subscription-orange.ico'; Desc = 'Claude Desktop with the Anthropic subscription.' })) {
      $lnk = $shell.CreateShortcut((Join-Path $ShortcutDir "$($s.Name).lnk"))
      $lnk.TargetPath = $ps
      $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcher`" $($s.Args)"
      $lnk.IconLocation = (Join-Path $Root "assets\$($s.Icon)") + ',0'
      $lnk.Description = $s.Desc
      $lnk.WindowStyle = 7
      $lnk.Save()
    }
    # Explorer caches shortcut icons: refresh it, or a re-run after installing Claude Desktop would
    # keep showing the generic icon for a while.
    try { & (Join-Path $env:SystemRoot 'System32\ie4uinit.exe') -show } catch {}
    (T 'sc.ok' $ShortcutDir) + $iconNote
  }
}

# ---------------------------------------------------------------- 10. Checks
if ($SkipChecks) { Skip (T 'step.checks') } else {
  Step (T 'step.checks') {
    Start-OllamaApi
    $names = @((Invoke-RestMethod 'http://127.0.0.1:11434/api/tags').models.name)
    if ("$TunedModel`:latest" -notin $names) { throw (T 'chk.nomodel' $TunedModel) }
    Say "    $(T 'chk.ask')"
    $body = @{ model = $TunedModel; prompt = 'Reply with the single word OK.'; stream = $false; think = $false; options = @{ num_predict = 16 } } | ConvertTo-Json
    $reply = (Invoke-RestMethod 'http://127.0.0.1:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1200).response
    if (-not "$reply".Trim()) { throw (T 'chk.empty') }
    Say "      $(T 'chk.reply' ("$reply".Trim()))"
    $uv = Find-Uv
    Say "    $(T 'chk.tests')"
    $r = Invoke-Native $uv @('run', '--no-project', '--with', 'pypdf', '--with', 'python-docx', 'python', (Join-Path $Root 'tests\test_docs_mcp.py'))
    $out = @($r.Text -split "`n")
    $out | ForEach-Object { Say "      $_" }
    $fails = @($out | Where-Object { $_ -match '^\[FAIL\]' })
    if ($r.Code -ne 0 -and -not ($out -match '^\[OK\]')) { throw (T 'chk.notrun' $r.Text) }
    if ($fails.Count) { throw (T 'chk.failed' $fails.Count) }
    T 'chk.ok'
  }
}

Say "`n=== $(T 'summary')" 'White'
$results | Format-Table -AutoSize -Wrap | Out-Host
if ($results | Where-Object Result -eq 'FAIL') {
  Say (T 'sum.fail') 'Yellow'
  exit 1
}
Say (T 'sum.ok') 'Green'
