# Reproduces Claude Desktop's local-mode startup: preload the probed (haiku) and default (sonnet)
# aliases, then run Desktop's health probe against haiku with its ~10 s timeout.
import json
import subprocess
import time
import urllib.request

BASE = 'http://127.0.0.1:11434'
HEADERS = {'Content-Type': 'application/json', 'Authorization': 'Bearer ollama-local',
           'anthropic-version': '2023-06-01'}


def post(path, body, timeout):
    req = urllib.request.Request(f'{BASE}{path}', data=json.dumps(body).encode(), headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


for alias in ('claude-haiku-4-5-20251001', 'claude-sonnet-4-6'):
    t0 = time.time()
    post('/api/generate', {'model': alias, 'prompt': '', 'keep_alive': '30m'}, 900)
    print(f'preload {alias:<28} {time.time() - t0:5.0f}s', flush=True)

for alias in ('claude-haiku-4-5-20251001', 'claude-sonnet-4-6'):
    t0 = time.time()
    try:
        r = post('/v1/messages', {'model': alias, 'max_tokens': 16,
                                  'messages': [{'role': 'user', 'content': 'ping'}]}, 10)
        print(f'[PASS] probe {alias:<28} {time.time() - t0:4.1f}s (Desktop allows ~10 s)', flush=True)
    except Exception as e:
        print(f'[FAIL] probe {alias:<28} {time.time() - t0:4.1f}s {type(e).__name__}: {e}', flush=True)

print(subprocess.run(['ollama', 'ps'], capture_output=True, text=True).stdout)
