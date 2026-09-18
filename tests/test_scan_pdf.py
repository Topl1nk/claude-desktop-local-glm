# Runs the docs MCP server against one real PDF with both engines and reports only
# whether extraction worked plus a short, non-sensitive preview.
import shutil
import json
import os
import subprocess
import sys

PDF = sys.argv[1] if len(sys.argv) > 1 else ''
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'scripts', 'docs-mcp.py')
UV = shutil.which('uv') or os.path.expandvars(r'%USERPROFILE%\.local\bin\uv.EXE')

print('file exists:', os.path.isfile(PDF), '|', os.path.getsize(PDF) if os.path.isfile(PDF) else 0, 'bytes')

proc = subprocess.Popen([UV, 'run', '--no-project', '--with', 'pypdf', '--with', 'python-docx', 'python', SERVER],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)


def call(payload):
    proc.stdin.write(json.dumps(payload) + '\n')
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


try:
    call({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}}})
    for engine in ('fast', 'mineru'):
        r = call({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
                  'params': {'name': 'read_document', 'arguments': {'path': PDF, 'engine': engine, 'max_chars': 4000}}})
        res = r.get('result', {})
        text = res.get('content', [{}])[0].get('text', '')
        body = text.split('\n', 1)[1] if '\n' in text else ''
        words = [w for w in body.split() if w.strip()]
        print(f'--- engine={engine} | error={bool(res.get("isError"))} | chars={len(body)} | words={len(words)}')
        print('    first words:', ' '.join(words[:12])[:160])
finally:
    proc.stdin.close()
    proc.terminate()
