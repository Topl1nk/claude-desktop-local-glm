# Design decisions and measurements

Why the local setup looks the way it does. Numbers were measured on the reference PC
(i9-12900KS, 64 GB DDR5-5200, RTX 3070 8 GB) with a ~25K-token Claude Code prompt.

## Architecture

Claude Desktop → Ollama `http://127.0.0.1:11434` (Anthropic-compatible `/v1/messages`). No gateway in
between and no engine restarts while working.

In local mode Desktop always asks for three fixed model names, one per tier. `desktop-mode.ps1`
re-points them at the real model on every start through Ollama's HTTP API (`/api/copy` — an alias, no
weights are copied):

| Desktop tier | Name Desktop sends | Real model |
|---|---|---|
| Sonnet (default, the only one in the menu) | `claude-sonnet-4-6` | `glm-4.7-flash-tuned` |
| Opus | `claude-opus-4-6` | `glm-4.7-flash-tuned` |
| Haiku (connection check, background tasks) | `claude-haiku-4-5-20251001` | `glm-4.7-flash-tuned` |

All three names must exist, or Desktop fails with `model not found`.

### Why Haiku points at the same model

On start Desktop checks the gateway with a request to the **haiku** alias and waits ~10 seconds. With
8 GB of VRAM Ollama cannot hold two different models: loading the second evicts the first
(`llama-server model predicted to exceed available memory, evicting`). A separate Haiku model and the
chat then keep evicting each other, loading is aborted (`client connection closed before llama-server
finished loading`) and Desktop shows "Can't reach 127.0.0.1:11434". With both aliases on one model,
Ollama reuses the loaded instance and the check answers in 0.7 s.

## Speed tuning (GLM-4.7-Flash)

| Variant | Generation, tok/s | Prompt reading, tok/s | Weights on GPU |
|---|---|---|---|
| 12 threads, batch 2048 | 29.5 | 842 | 3134 MB |
| 8 threads | 30.0 | 836 | 3134 MB |
| **16 threads (chosen)** | **30–32** | **700–930** | 3134 MB |
| 8 threads, batch 1024 | 30.1 | 654 | 3568 MB |
| 8 threads, batch 4096 | 28.2 | 930 | 2223 MB |
| No VRAM reserve (`fit-target 256`) | 30.0 | 746 | 2657 MB |
| Experts of 40 layers on CPU (`-ncmoe 40`) | 19.4 | 650 | 785 MB |
| Experts of 32 layers on CPU | 16.1 | 28 | 3134 MB |
| Experts of 24 layers on CPU | out of memory | | |

- Only the thread count helps (one thread per physical core; `install.ps1` uses the core count).
- Manual expert placement (`LLAMA_ARG_N_CPU_MOE`) and removing the VRAM reserve make things worse:
  Ollama's automatic fitting is better.
- The batch size is a trade-off: 4096 reads prompts faster but takes VRAM from the weights and slows
  generation.
- "Limit the context to 2048–4096 tokens" is harmful advice: the KV cache for all 131 072 tokens is
  1.9 GB, while Claude Code's system prompt alone is 18K tokens.
- Dense models are hopeless on this class of hardware: a 27B dense model fit 2 of 66 layers on the
  GPU and ran at ~4 tok/s, bound by DDR5 bandwidth.

### `num_batch 2048` is required

The tuned model is the library model with an explicit batch size, context and thread count
(`config-templates\Modelfile.glm-tuned`). With Ollama's default batch the Claude Code prompt is read
many times slower:

| Model | 25K-token prompt, default batch | With `num_batch 2048` |
|---|---|---|
| GLM-4.7-Flash | 665 s (38 tok/s) | **33 s (755 tok/s)** |

### An explicit `num_ctx` is required

Ollama's app-wide default context can exceed a model's limit, and loading then fails with
`requested context size too large for model`. The Modelfile sets it explicitly.

### Orphaned engines hold VRAM

After an Ollama crash its `llama-server` can keep running and holding VRAM; the next load fails with
`CUDA error: out of memory`. `desktop-mode.ps1` kills `llama-server` processes that started before the
current Ollama server.

## What works in local mode

Checked with requests to the gateway (`tests\test_attachments.py`):

| Feature | Local mode | Why |
|---|---|---|
| Text chat, tools, agent work | works | |
| Images in attachments | **HTTP 400** | GLM-4.7-Flash has no vision (`capabilities = completion, tools, thinking`) |
| PDFs attached to a chat | **silently lost** | Ollama drops the Anthropic `document` block; the model sees ~20 input tokens |
| Documents from disk | works | the `docs` MCP server (`read_document`) |
| Web search | works | the `docs` MCP server (`web_search`) |

## Two windows at once

- The mode (`1p`/`3p`) is read **once at start** from `%LOCALAPPDATA%\Claude-3p\claude_desktop_config.json`.
- The data folders differ (`%APPDATA%\Claude` vs `%LOCALAPPDATA%\Claude-3p`), so Electron's
  single-instance locks do not collide.
- **Pitfall:** a running window rewrites the mode file within seconds. With `-KeepOther`,
  `desktop-mode.ps1` writes the mode and makes the file read-only until the new window has read it
  (20 s). Without that, the second window starts in the wrong mode, hits the busy data folder and
  quietly exits.
- A portable copy of the app is impossible (MSIX package: `CLAUDE_USER_DATA_DIR` is deleted at
  startup and `--user-data-dir` is overridden).

## Web search without keys

Desktop's built-in search server (`server: "websearch"`) is not used: `brave`, `tavily` and `exa` need
a paid key, and `custom` accepts **https only** — Desktop silently drops a local address:

```
configuration warning: managedMcpServers entry "Web search" dropped — customUrl: must use https
```

So search lives in the `docs` MCP server, which has no such rule:

1. **SearXNG** on 127.0.0.1:8888 — self-hosted metasearch, no keys, no limits; the config turns the
   JSON API on (SearXNG serves only HTML by default) and the rate limiter off; bound to 127.0.0.1 only.
2. **DuckDuckGo** directly — the fallback when SearXNG/Docker is not running.

No API keys are needed or stored anywhere in this setup.

## Documents: the `docs` MCP server and MinerU

| engine | What it does | Formats |
|---|---|---|
| `fast` | the text layer directly (pypdf / python-docx) | pdf, docx, text files |
| `mineru` | [MinerU](https://github.com/opendatalab/MinerU) 4: Markdown, tables, formulas, **OCR for scans** | pdf, docx, pptx, xlsx, epub, html, images |
| `auto` (default) | `fast` first, `mineru` when it returns nothing | all of the above |

In a chat, instead of attaching a file, ask: "read `C:\path\file.pdf`".

**MinerU runs locally only.** By default MinerU 4 sends documents to its cloud
(`https://mineru.net/api`). The installer switches that off and verifies it:

```
parse_server.local.mode         = managed
parse_server.local.managed_tier = basic
parse_server.remote.url         = http://127.0.0.1:9   # a dead end: documents never leave the PC
```

MinerU needs its own local server (`mineru server start`); `desktop-mode.ps1` starts it, and
`docs-mcp.py` restarts it when its endpoint is stale and waits while its OCR worker warms up.

Fixes found on a real session with a scanned PDF:

1. **The tools were hidden.** The profile had `toolSearchEnabled: true`, so every MCP tool was
   "deferred" and the model never requested them. Now `false`; `CLAUDE.md` also tells the model to use
   `read_document`/`web_search` and never guess from a file name.
2. **Non-ASCII paths broke.** stdin was read in the Windows code page, so `ö` in a path arrived
   mangled ("file not found") and non-English search queries failed. stdio is UTF-8 now.
3. **A scan counted as text.** The fast engine returned `--- page N ---` markers without text, so
   `auto` did not switch to MinerU. It now returns nothing for an empty text layer and OCR kicks in.

## A minimal toolset for the local model

The local mode has its own Claude Code config folder (`claude-config`, via `CLAUDE_CONFIG_DIR`): no
plugins, no user MCP servers, no skills; Claude Code's built-in tools stay. This cut the system prompt
from **115 195 to 18 350 tokens**. Rules come from `config-templates\` (the Karpathy coding guidelines
plus local-mode rules).

## Dropped approaches

- **ik_llama.cpp behind a custom gateway.** The gateway restarted the engine whenever the model
  variant changed; requests timed out and retried, and no generation request ever reached the model.
- **`CLAUDE_CODE_MAX_CONTEXT_TOKENS` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW`** — these variables do not
  exist in Claude Code.
- **A 1M-token context through YaRN** on a Qwen MoE model — it worked, but that much context is never
  reached on this hardware.
- **Several models on the tiers** — they evict each other on 8 GB of VRAM (see above).
