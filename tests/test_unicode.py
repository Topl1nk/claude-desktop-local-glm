# Reproduces the two encoding bugs seen in a real local session:
#   1. a path with an umlaut arrived as "PersÃ¶nliches" -> file not found
#   2. a Cyrillic search query died with UnicodeEncodeError (surrogates)
# The client speaks UTF-8 over stdio, exactly like Claude Desktop does.
import shutil
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'scripts', 'docs-mcp.py')
UV = shutil.which('uv') or os.path.expandvars(r'%USERPROFILE%\.local\bin\uv.EXE')
PDF = sys.argv[1] if len(sys.argv) > 1 else ''

proc = subprocess.Popen([UV, 'run', '--no-project', '--with', 'pypdf', '--with', 'python-docx', 'python', SERVER],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, encoding='utf-8', bufsize=1)


def call(payload):
    proc.stdin.write(json.dumps(payload, ensure_ascii=False) + '\n')
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


try:
    call({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}}})

    r = call({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
              'params': {'name': 'read_document', 'arguments': {'path': PDF, 'max_chars': 1500}}})
    res = r['result']
    text = res['content'][0]['text']
    ok = not res.get('isError')
    print(f'[{"OK" if ok else "FAIL"}]  umlaut path: {text[:110]!r}')

    r = call({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
              'params': {'name': 'web_search', 'arguments': {'query': 'рецепт пиццы в домашних условиях', 'max_results': 3}}})
    res = r['result']
    text = res['content'][0]['text']
    ok = not res.get('isError') and 'http' in text
    first = [l.strip() for l in text.splitlines() if l.strip()][:2]
    print(f'[{"OK" if ok else "FAIL"}]  cyrillic query: ' + ' | '.join(x[:80] for x in first))
finally:
    proc.stdin.close()
    proc.terminate()
