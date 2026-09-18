@echo off
setlocal
rem Console Claude Code on the local GLM-4.7-Flash served by Ollama.
rem Everything this setup owns lives in the folder above this script (<ROOT>):
rem   claude-config\  - Claude Code config for local mode (no plugins, no user MCP servers)
rem   mineru\         - MinerU models and database
rem   scripts\        - this file, desktop-mode.ps1, docs-mcp.py, local_search.py, searxng\
set "CLAUDE_LOCAL_ROOT=%~dp0.."
set "CLAUDE_CONFIG_DIR=%CLAUDE_LOCAL_ROOT%\claude-config"
set "MINERU_HOME=%CLAUDE_LOCAL_ROOT%\mineru"
set "ANTHROPIC_BASE_URL=http://127.0.0.1:11434"
set "ANTHROPIC_AUTH_TOKEN=ollama"
set "ANTHROPIC_API_KEY="
set "CLAUDE_CODE_OAUTH_TOKEN="
set "ANTHROPIC_MODEL=claude-sonnet-4-6"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=claude-sonnet-4-6"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-sonnet-4-6"
set "CLAUDE_CODE_SUBAGENT_MODEL=claude-sonnet-4-6"
set "API_TIMEOUT_MS=1800000"
ollama list >nul 2>&1
if errorlevel 1 exit /b 1
claude.exe --model claude-sonnet-4-6 %*
exit /b %errorlevel%
