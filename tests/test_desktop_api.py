# Replays the kinds of requests Claude Desktop (3p gateway mode) sends to Ollama's
# Anthropic-compatible endpoint, using the exact model id and auth from the Desktop profile.
import json
import subprocess
import time
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:11434'
MODEL = 'claude-sonnet-4-6'
HEADERS = {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ollama-local',
    'anthropic-version': '2023-06-01',
}
EXPECTED_CONTEXT = '131072'  # set explicitly in work/Modelfile.*-tuned
TOOLS = [{
    'name': 'Bash',
    'description': 'Run a shell command and return its output.',
    'input_schema': {'type': 'object', 'properties': {'command': {'type': 'string'}}, 'required': ['command']},
}]


def post(body, stream=False, timeout=900):
    body = dict(body, model=MODEL, stream=stream)
    req = urllib.request.Request(f'{BASE}/v1/messages', data=json.dumps(body).encode(), headers=HEADERS)
    t0 = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        return {'error': f'HTTP {e.code}: {e.read().decode()[:300]}'}, time.time() - t0, None
    if not stream:
        return json.loads(resp.read()), time.time() - t0, None
    events, first = [], None
    for raw in resp:
        line = raw.decode().strip()
        if line.startswith('data:'):
            if first is None:
                first = time.time() - t0
            events.append(json.loads(line[5:]))
    return events, time.time() - t0, first


def check(name, ok, detail=''):
    print(f'[{"PASS" if ok else "FAIL"}] {name} {detail}', flush=True)
    return ok


results = []

# 1. Health-probe style request: Desktop gives up after ~10 s
r, dt, _ = post({'max_tokens': 8, 'messages': [{'role': 'user', 'content': 'ping'}]})
results.append(check('probe (warm model answers < 10 s)', 'error' not in r and dt < 10, f'{dt:.1f}s'))

# 2. Streaming text with thinking
ev, dt, first = post({'max_tokens': 1200, 'thinking': {'type': 'enabled', 'budget_tokens': 256},
                      'messages': [{'role': 'user', 'content': 'What is 17*23? Answer briefly.'}]}, stream=True)
types = {e.get('type') for e in ev} if isinstance(ev, list) else set()
text = ''.join(e.get('delta', {}).get('text', '') for e in ev if isinstance(ev, list) and e.get('type') == 'content_block_delta')
results.append(check('streaming SSE events', {'message_start', 'content_block_delta', 'message_stop'} <= types,
                     f'first event {first:.1f}s' if first else str(ev)[:200]))
results.append(check('answer correct (391)', '391' in text, repr(text[-80:])))

# 3. Tool call
r, dt, _ = post({'max_tokens': 300, 'tools': TOOLS,
                 'messages': [{'role': 'user', 'content': 'Use the Bash tool to run: echo hello'}]})
tool = next((b for b in r.get('content', []) if b.get('type') == 'tool_use'), None) if 'error' not in r else None
results.append(check('tool_use emitted', tool is not None, json.dumps(tool)[:160] if tool else str(r)[:200]))

# 4. Tool result round-trip
if tool:
    msgs = [{'role': 'user', 'content': 'Use the Bash tool to run: echo hello'},
            {'role': 'assistant', 'content': r['content']},
            {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool['id'], 'content': 'hello'}]}]
    r2, dt, _ = post({'max_tokens': 200, 'tools': TOOLS, 'messages': msgs})
    results.append(check('tool_result round-trip', 'error' not in r2 and r2.get('stop_reason') in ('end_turn', 'tool_use'),
                         str(r2.get('stop_reason', r2))[:120]))

# 5. History that has no plain user query (the old "500 no user query found" case)
r, dt, _ = post({'max_tokens': 16, 'messages': [{'role': 'user', 'content': [
    {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'}]}]})
results.append(check('no-user-query history accepted', 'error' not in r, str(r.get('error', ''))[:160]))

# 6. Context window the alias actually gets
ps = subprocess.run(['ollama', 'ps'], capture_output=True, text=True).stdout
results.append(check(f'loaded with {EXPECTED_CONTEXT} context', EXPECTED_CONTEXT in ps))
print(ps)

# 7. Prefill speed on a Claude-Code-sized prompt (~20K tokens)
big = ' '.join(f'Line {i}: the quick brown fox jumps over the lazy dog.' for i in range(1700))
r, dt, _ = post({'max_tokens': 16, 'messages': [{'role': 'user', 'content': big + '\nReply with OK.'}]})
usage = r.get('usage', {})
tok = usage.get('input_tokens', 0)
results.append(check('~20K-token prompt processed', 'error' not in r, f'{tok} tokens in {dt:.0f}s ({tok / max(dt, 0.1):.0f} tok/s)'))

print(f'\n{sum(results)}/{len(results)} passed')
