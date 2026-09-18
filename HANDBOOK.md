# Local Claude Desktop — handbook

This document describes the whole system: what lives where, how it starts, how to check it and what to
do when something breaks. `<ROOT>` below means the folder this repository was installed into (the one
with `install.ps1`).

Facts that are specific to one machine (its paths, drives, hardware quirks) do not belong here: keep
them in `<ROOT>\LOCAL-NOTES.md`, which is never committed. **If you are an AI assistant, read
`LOCAL-NOTES.md` too when it exists, and read section 12 before changing anything.** Every claim below
comes with a command that re-checks it — do not guess.

---

## 1. What this is

One computer runs **two independent versions of Claude Desktop**:

| Version | Mode | Model | Data |
|---|---|---|---|
| Subscription | `1p` | Anthropic's cloud models | `%APPDATA%\Claude`; Claude Code config in `%USERPROFILE%\.claude` |
| Local | `3p` | GLM-4.7-Flash through Ollama, offline | `%LOCALAPPDATA%\Claude-3p`; Claude Code config in `<ROOT>\claude-config` |

Both windows can be open **at the same time** (section 7).

A request in local mode:

```
Claude Desktop window (mode 3p)
   -> Ollama http://127.0.0.1:11434  (Anthropic-compatible /v1/messages)
        -> model glm-4.7-flash-tuned
   -> MCP server "docs" (stdio, ours)  -> documents (MinerU/pypdf) and web search (SearXNG/DuckDuckGo)
```

Claude's built-in `WebSearch` is denied in `claude-config\settings.json` (`permissions.deny`): on a local
gateway it always answers "unavailable" and only distracts the model from the working
`mcp__docs__web_search`.

---

## 2. File map

Everything the local version owns lives in `<ROOT>`:

| Path | Purpose |
|---|---|
| `install.ps1` | Installs the whole system (section 12a) |
| `scripts\desktop-mode.ps1` | Behind both shortcuts: switches the mode, starts the dependencies, warms the model, opens the window |
| `scripts\docs-mcp.py` | MCP server: `read_document`, `list_documents`, `web_search` |
| `scripts\local_search.py` | Search: SearXNG, DuckDuckGo when SearXNG is down |
| `scripts\claude-qwen.cmd` | Console Claude Code on the local model |
| `scripts\searxng\docker-compose.yml` | Self-hosted search engine in Docker (127.0.0.1:8888) |
| `scripts\searxng\config\settings.yml` | SearXNG config: JSON API on, rate limiter off |
| `scripts\searxng\.env` | SearXNG secret key (created by `install.ps1`, never committed) |
| `scripts\relocate-desktop-data.ps1` | Optional one-off move of the Desktop window data into `<ROOT>\desktop-data` (all Claude windows must be closed) |
| `scripts\local-branding.ps1` + `scripts\LocalBranding.cs` | Grey icons for the local window: taskbar, window, tray (section 7a) |
| `assets\*.ico` | Grey (local) and orange (subscription) icons, **built locally** by `scripts\make-icons.ps1` from the installed Claude Desktop (the logo is Anthropic's trademark, so the repository ships none; not committed) |
| `config-templates\` | Sources for `claude-config\` and the tuned Modelfile. Karpathy's coding guidelines are downloaded by `install.ps1` from the original repository (no licence to redistribute them) |
| `scripts\README.md` | Design decisions and measurements (why things are the way they are) |
| `tests\` | Checks (section 10) |
| `claude-config\` | Claude Code config of the local mode, via `CLAUDE_CONFIG_DIR` (not committed) |
| `claude-config\CLAUDE.md` | Rules for the local model: use the MCP tools, never guess file contents |
| `models\` | Ollama models (~18 GB), via `OLLAMA_MODELS` (not committed) |
| `mineru\` | MinerU models and database (~0.8 GB), via `MINERU_HOME` (not committed) |
| `desktop-data\` | Desktop window data if it was relocated; `%LOCALAPPDATA%\Claude-3p` is then a junction to it (not committed) |
| `backup\` | Backups of earlier settings (not committed) |

Outside `<ROOT>` (shared software, not configuration):

| Path | What it is |
|---|---|
| `C:\Program Files\WindowsApps\Claude_*` | Claude Desktop, an MSIX package. It **cannot** be copied or made portable |
| `%LOCALAPPDATA%\Claude-3p` | Local-mode window data. The path is **hard-coded in the app** |
| `%LOCALAPPDATA%\Programs\Ollama` | Ollama |
| `%USERPROFILE%\.local\bin\` | `uv.exe`, `mineru.exe`, `claude.exe` |
| `%USERPROFILE%\.claude` | Claude Code config of the **subscription**. The local version does not touch it |

User environment variables set by `install.ps1`:

```
OLLAMA_MAX_LOADED_MODELS = 1
OLLAMA_NUM_PARALLEL      = 1
OLLAMA_FLASH_ATTENTION   = 1
OLLAMA_KV_CACHE_TYPE     = q4_0
OLLAMA_GPU_OVERHEAD      = 1073741824
MINERU_HOME              = <ROOT>\mineru
OLLAMA_MODELS            = <ROOT>\models by default (portable); an existing Ollama models folder that
                           already has the model is kept; -ModelsDir overrides
```

---

## 3. Starting it

Two desktop shortcuts, both with `-KeepOther` (they never close the other window):

| Shortcut | Command |
|---|---|
| **Claude - Local** | `desktop-mode.ps1 -Mode qwen -StartDocker -KeepOther` |
| **Claude - Subscription** | `desktop-mode.ps1 -Mode subscription -KeepOther` |

What the script does in local mode, in order:

1. Writes `deploymentMode: "3p"` to `%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json` and makes the
   file read-only (otherwise an already open window rewrites it back).
2. Kills orphaned `llama-server` processes left over from an Ollama crash.
3. Starts Ollama if it is not running (the tray app, or `ollama serve` for the portable build).
4. Points three alias names at the real model through Ollama's HTTP API.
5. Starts SearXNG when Docker runs; with `-StartDocker` it starts Docker Desktop and waits up to ~2
   minutes. If that fails, search simply uses DuckDuckGo.
6. Starts the MinerU server in the background.
7. Warms the model (`claude-sonnet-4-6`) — otherwise Desktop's ~10 s connection check times out.
8. Sets `CLAUDE_CONFIG_DIR`, `MINERU_HOME`, `API_TIMEOUT_MS` and opens the Desktop window.
9. Starts `local-branding.ps1`, waits 20 seconds and removes the read-only flag.

Console: `scripts\claude-qwen.cmd` (Claude Code on the local model with the same settings).

**Do not start Claude Desktop directly (from its own icon):** it opens in whatever mode was written
last, without a warm model. Always use the shortcuts.

---

## 4. Model

One model for every tier: **GLM-4.7-Flash** (MoE, 30B total / ~3B active per token).

| What | Value |
|---|---|
| Ollama model | `glm-4.7-flash-tuned` (built from `glm-4.7-flash` by `install.ps1`) |
| Aliases (Desktop asks for these) | `claude-sonnet-4-6`, `claude-opus-4-6`, `claude-haiku-4-5-20251001` |
| Context | chosen by RAM: 131 072 (48 GB+), 65 536 (32 GB+), 32 768 otherwise |
| Prompt batch | `num_batch 2048` |
| Threads | physical cores |
| Speed on the reference PC (i9-12900KS, RTX 3070 8 GB) | 30–32 tokens/s generation, 700–930 tokens/s prompt reading |
| Memory used | ~22 GB (RAM + VRAM) |

**Why all three tiers point at one model.** Desktop checks the connection with a request to the
`haiku` alias and a ~10 s timeout. With 8 GB of VRAM a second model evicts the first, neither
finishes loading, and the window shows "Can't reach 127.0.0.1:11434". When the aliases point at one
file, Ollama reuses the loaded instance and the check answers in 0.6 s.

Rebuild the model (for example after `glm-4.7-flash` was updated): run `install.ps1` again — it
recreates `glm-4.7-flash-tuned` when its parameters differ. Then start the shortcut, which re-points
the aliases.

---

## 5. Documents (the `docs` MCP server)

The model **cannot see attachments or images**: GLM-4.7-Flash has no vision, and Ollama silently drops
attached documents. Files are therefore read from disk by a tool.

| Tool | Purpose |
|---|---|
| `read_document(path, max_chars, pages, engine)` | Text of a document |
| `list_documents(directory, pattern)` | What in a folder can be read |
| `web_search(query, max_results)` | Web search |

`read_document` engines:

| `engine` | What it does | When |
|---|---|---|
| `fast` | pypdf / python-docx / plain text | ordinary PDFs with a text layer |
| `mineru` | MinerU 4: Markdown with tables and formulas, **OCR for scans** | scans, images, complex layout |
| `auto` (default) | `fast`, then `mineru` when there is no text | always, unless there is a reason not to |

MinerU runs **locally only**: the `basic` tier models live in `<ROOT>\mineru`, and cloud parsing is
deliberately broken (`parse_server.remote.url = http://127.0.0.1:9`, a dead port). `install.ps1`
verifies this. Check:

```powershell
mineru server status
```

Expected: `Home` points to `<ROOT>\mineru`, the `Local` parse server is healthy, `Remote` is `no`.
Right after the server starts, its OCR worker needs a minute or two to load models; `docs-mcp.py`
waits for it.

---

## 6. Web search

Desktop's built-in search is **not used**: the Brave/Tavily/Exa providers need a paid key, and the
`custom` provider accepts only `https` and silently drops a local address
(`customUrl: must use https`). Search lives in our MCP server (`web_search`) instead.

Sources, in order:

1. **SearXNG** at `http://127.0.0.1:8888` — a self-hosted metasearch engine in Docker, no keys, no limits;
2. **DuckDuckGo** — the fallback when SearXNG is not running.

Start SearXNG by hand:

```powershell
docker compose -f "<ROOT>\scripts\searxng\docker-compose.yml" up -d
```

The container is named `claude-local-searxng` (compose project `claude-local`) — a unique name on
purpose: with a plain `searxng` name, a container of another compose project with that name blocked
ours and search silently fell back to DuckDuckGo.

Check:

```powershell
curl "http://127.0.0.1:8888/search?q=test&format=json"
```

---

## 7. Two windows at once

- The mode (`1p`/`3p`) is read **once, when a window starts**, from
  `%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json`, key `deploymentMode`.
- The modes use different data folders, so Electron's single-instance lock does not collide.
- **Pitfall:** an open window rewrites that file to its own mode within seconds. That is why the
  script makes the file read-only while the new window starts.
- Clicking the same shortcut again does not start a second copy; the open window gets focus.

**A portable copy of the app is impossible:** Claude Desktop is an MSIX package. The packaged build
deletes `CLAUDE_USER_DATA_DIR` at startup and overrides `--user-data-dir`. Configuration and data are
separated, the program itself is not.

---

## 7a. Colours: orange = subscription, grey = local

| Where | Subscription | Local | How |
|---|---|---|---|
| Shortcut | orange | grey | shortcut `IconLocation` → `assets\*.ico` |
| Taskbar button | orange | grey, **a separate button** | `local-branding.ps1` gives the window its own AppUserModelID `Claude.LocalOllama` with the grey icon |
| Window icon / Alt+Tab | orange | grey | `local-branding.ps1`: `WM_SETICON` |
| Tray | Claude's own icon | grey icon (click opens the window; menu: open/close) | the app's tray icon is off in local mode (`preferences.menuBarEnabled=false` in `Claude-3p\claude_desktop_config.json`); `local-branding.ps1` shows the grey one |

- The app's files (MSIX) cannot be changed, and both modes share its icons, so `desktop-mode.ps1`
  starts a hidden helper, `local-branding.ps1`, that repaints the local window **from outside** and
  exits when the local Claude closes.
- The helper recognises the local window by child processes with `--user-data-dir=...\Claude-3p`; the
  subscription window (`...\Roaming\Claude`) is never touched. Only one helper runs (a mutex).
- With the app's tray icon off, **the close button quits the local Claude** instead of hiding it in the
  tray. This affects the local mode only.
- Windows 11 hides new tray icons behind the `^` arrow: drag the grey icon onto the taskbar once.
- The grey taskbar button can be pinned; the pin starts `desktop-mode.ps1 -Mode qwen`.
- If the grey button is missing after a Claude update, run the helper by hand:
  `powershell -ExecutionPolicy Bypass -File "<ROOT>\scripts\local-branding.ps1"`. It cannot break
  anything: on failure the window just stays orange.
- The Start menu entry stays orange — it belongs to the shared package.

---

## 8. Configuration files

### Local-mode profile

`%LOCALAPPDATA%\Claude-3p\configLibrary\<id>.json`, registered in `configLibrary\_meta.json`
(`appliedId`). Written by `install.ps1`; a re-run updates the same profile.

| Field | Value | Why |
|---|---|---|
| `inferenceGatewayBaseUrl` | `http://127.0.0.1:11434` | Ollama |
| `inferenceModels` | one entry `claude-sonnet-4-6` labelled "GLM-4.7-Flash (local)" | what the model menu shows |
| `managedMcpServers` | `docs` only | MCP servers of the local window |
| `toolSearchEnabled` | **`false`** | otherwise the MCP tools are hidden from the model (section 11) |
| `inferenceStreamIdleTimeoutSec` | `1800` | long answers are not cut off |

The app **rewrites this file itself** (key order, some fields). That is fine; the important fields stay.

### Start mode

`%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json`, key `deploymentMode`: `"3p"` or `"1p"`.

### Claude Code config of the local mode

`<ROOT>\claude-config` (via `CLAUDE_CONFIG_DIR`). No plugins on purpose: with a large plugin set the
system prompt was 115 195 tokens, without them 18 350.

**Rule for any JSON edit: UTF-8 without a BOM.** The app cannot parse a file with a BOM
(`Failed to parse settings file (SyntaxError)`) and silently ignores it. In PowerShell:

```powershell
[IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
```

---

## 9. Do not

| Don't | Why |
|---|---|
| Set `num_ctx` to 2048–4096 "to keep the KV cache small" | Harmful advice. The KV cache for all 131 072 tokens is 1.9 GB, while Claude Code's system prompt alone is 18K tokens: at 2048 no request fits |
| Put different models on different tiers | With 8 GB of VRAM they evict each other and the window loses the gateway |
| Enable `toolSearchEnabled` | The MCP tools become "deferred"; the local model never finds them and falls back to Bash |
| Set `LLAMA_ARG_N_CPU_MOE` / remove the VRAM reserve | Measured: worse (generation 30 → 16–19 tok/s, prompt reading 790 → 28 tok/s) |
| Keep the models on a slow or DRAM-less SSD | Long 20 GB writes can freeze the whole system |
| Write configs with a BOM | The app silently skips such files |
| Set `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | These variables do not exist in Claude Code |
| Start Claude Desktop bypassing the shortcuts | It starts in the other mode and without a warm model |
| Run `/code-review max` (or other many-agent commands) on the local model | They start 10+ subagents that queue on one model; a run takes hours. Use `low`/`medium` locally, `max` on the subscription |

---

## 10. Checks

```powershell
$env:MINERU_HOME = '<ROOT>\mineru'
uv run --no-project --with pypdf --with python-docx python "<ROOT>\tests\<file>"
```

| Script | Checks | Expected |
|---|---|---|
| `test_docs_mcp.py` | the whole MCP server | 3 tools; a PDF read by both engines; an error for a missing file; search returns links |
| `test_unicode.py <PDF path>` | non-ASCII paths and non-English queries | both lines `[OK]`; `engine: mineru` for a scan |
| `test_desktop_api.py` | Desktop-style requests to Ollama | `8/8 passed` |
| `test_probe.py` | Desktop's connection check (10 s timeout) | both checks `[PASS]`, 0.5–0.6 s |
| `bench_one.py <model>` | speed | ~30 tok/s generation, 700–930 tok/s prompt on the reference PC |
| `test_scan_pdf.py <path>` | a scan | `fast` gives 0 words, `mineru` real text |
| `sandbox-test.ps1` | `install.ps1` on a clean Windows (Windows Sandbox) | all steps OK, 7 of 7 checks |
| `privacy-audit.ps1` | every file and commit git would publish, for personal data and secrets (run before each push; `-CurrentOnly` for the staged files only) | `CLEAN` |

Health of the local window, from its log:

```powershell
Get-Content "$env:LOCALAPPDATA\Claude-3p\logs\main.log" -Tail 60 |
  Select-String '3P mode active|ConfigHealth|custom3p-mcp|configuration warning'
```

Expected: `3P mode active`, `ConfigHealth ... state: 'healthy'`, `connected { name: 'docs', toolCount: 3 }`
and **no** `configuration warning` line.

---

## 11. Troubleshooting: symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| `read_document` → "The discovered endpoint belongs to a different MinerU server instance" | MinerU looked in the wrong home folder (Desktop gives MCP servers a reduced environment) | `docs-mcp.py` pins `MINERU_HOME` to `<ROOT>\mineru` itself; check that line, restart the local window, delete a stray `%USERPROFILE%\.mineru` |
| `read_document` → "Local parse-server is not ready" | MinerU's OCR worker is still loading models | `docs-mcp.py` waits up to 4 minutes; if it persists: `mineru server status` |
| MinerU: "DLL load failed while importing onnxruntime_pybind11_state" | Visual C++ runtime missing | `install.ps1` installs it; by hand: https://aka.ms/vs/17/release/vc_redist.x64.exe |
| Shortcut: "Claude's local data is in …\desktop-data, but the link … is missing" | the data was relocated but the `Claude-3p` junction is gone | close **every** Claude window (including Claude Code sessions) and run `scripts\relocate-desktop-data.ps1` again |
| Window: "Can't reach 127.0.0.1:11434" | model not warm, or different models on the tiers | start the shortcut (it warms the model); `ollama ps` must list it |
| `Error: model 'claude-opus-4-6' not found` | the Ollama aliases are gone | start the shortcut (it recreates them); by hand: `ollama cp glm-4.7-flash-tuned claude-opus-4-6` |
| `CUDA error: out of memory` on load | orphaned `llama-server` processes hold VRAM | `Get-Process llama-server \| Stop-Process -Force`, then the shortcut |
| The first answer takes 5+ minutes | the model was built without `num_batch 2048` | re-run `install.ps1` |
| `read_document`: "file not found" although the file exists | non-ASCII path with an old `docs-mcp.py` | update the server (stdio is UTF-8 now) and restart the window |
| `no text could be extracted from this file` | a scan without a text layer and MinerU unavailable | `mineru server status`; re-run `install.ps1` |
| Search returns an error | SearXNG down and DuckDuckGo unreachable | start SearXNG (section 6) or check the internet connection |
| The local window uses ~116K prompt tokens | Desktop's own built-in tools, not Claude Code plugins | expected |
| The subscription window lost its settings; `%APPDATA%\Claude\claude_desktop_config.json` holds only `mcpServers` (maybe UTF-16) | Something (e.g. the local model adding an MCP server in the wrong place) overwrote the subscription's config | While a subscription window that started before the damage is still open: toggle any setting in it (Settings → Claude Code → "Keep computer awake" off and on) — the app writes its in-memory settings back. Local MCP servers belong in the local profile (section 8), never in that file |
| "Additional setup needed … Feature enablement failed" in Desktop | Desktop's Cowork workspace needs the Windows feature Virtual Machine Platform | optional; admin PowerShell: `Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All`, reboot |

---

## 12. Rules for AI assistants working on this system

1. **Never guess file contents.** Never infer what a document says from its name or path. If it cannot
   be read, say so.
2. **Documents: `mcp__docs__read_document` only.** Do not install `pdfplumber`, `pdf2image`,
   `pytesseract`: OCR is already in MinerU.
3. **Search: `mcp__docs__web_search`.** Anthropic's server-side search does not exist in local mode.
4. **Prove it.** Before saying "it works", show the command output or the log line. Section 10 lists
   the checks.
5. **Do not move things.** `%LOCALAPPDATA%\Claude-3p` is hard-coded in the app; it can only be
   redirected with a junction.
6. **Back up before editing configs** (into `<ROOT>\backup`) and write UTF-8 without a BOM.
7. **Follow section 9.** Those rules come from measurements, not from general advice.
8. **Personal documents stay local.** Never send their contents to external services and never enable
   MinerU's cloud parsing.
9. **Nothing personal in the repository.** Machine-specific paths and facts go to `LOCAL-NOTES.md`,
   never into committed files.
10. **Nothing third-party in the repository.** No logos, models, binaries or unlicensed texts: build or
    download them at install time from the original source.
11. **Run `tests\privacy-audit.ps1` before every push.** Extra personal words for it go to
    `<ROOT>\.privacy-patterns` (one regex per line, never committed).

---

## 12a. Installer and repository

- `install.ps1` installs the whole system on another computer: Ollama, uv and the Visual C++ runtime
  (winget, or the vendors' installers — the portable Ollama zip when winget is missing), the model
  with threads and context chosen for the hardware, MinerU (models downloaded, cloud parsing off and
  verified), the Desktop profile, the rules from `config-templates\`, SearXNG when Docker exists, the
  shortcuts and a final check. Messages follow the Windows display language (English, Ukrainian,
  Russian; `-Lang` forces one). A re-run is safe. To test without touching a working setup:
  `-SkipEnv -NoSearxng -DesktopDataDir <temp folder> -ShortcutDir <temp folder>`.
- `tests\sandbox-test.ps1` runs the installer in a throwaway Windows Sandbox. Pass `-WorkDir` on a fast
  drive with ~25 GB free: the model copy and the log go there.
- `.gitignore` is a **whitelist**: everything is ignored except the listed files. Private data
  (`desktop-data\`, `claude-config\`, `mineru\`, `backup\`, `scripts\searxng\.env`, `LOCAL-NOTES.md`)
  cannot end up in the repository. Add new shareable files to the whitelist explicitly.
- Two MinerU servers cannot run on one machine (shared port 15980). When testing the installer in
  another folder, stop the working one first: `mineru server stop` with the working `MINERU_HOME`.
