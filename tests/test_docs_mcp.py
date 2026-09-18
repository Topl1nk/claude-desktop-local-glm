# Starts outputs/docs-mcp.py as Claude Desktop would and exercises it over stdio JSON-RPC.
import shutil
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_attachments import minimal_pdf  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.path.join(ROOT, 'scripts', 'docs-mcp.py')
UV = shutil.which('uv') or os.path.expandvars(r'%USERPROFILE%\.local\bin\uv.EXE')

pdf_path = os.path.join(tempfile.gettempdir(), 'docs-mcp-test.pdf')
with open(pdf_path, 'wb') as f:
    f.write(minimal_pdf())

proc = subprocess.Popen([UV, 'run', '--no-project', '--with', 'pypdf', '--with', 'python-docx', 'python', SERVER],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)


def call(payload):
    proc.stdin.write(json.dumps(payload) + '\n')
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())


try:
    r = call({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
              'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}})
    print('[OK]  initialize:', r['result']['serverInfo'])
    r = call({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}})
    print('[OK]  tools:', ', '.join(t['name'] for t in r['result']['tools']))
    r = call({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
              'params': {'name': 'read_document', 'arguments': {'path': pdf_path}}})
    text = r['result']['content'][0]['text']
    ok = 'KESTREL' in text
    print(f'[{"OK" if ok else "FAIL"}]  read_document(pdf): {text[:120]!r}')
    r = call({'jsonrpc': '2.0', 'id': 31, 'method': 'tools/call',
              'params': {'name': 'read_document', 'arguments': {'path': pdf_path, 'engine': 'mineru'}}})
    text = r['result']['content'][0]['text']
    ok = 'KESTREL' in text
    print(f'[{"OK" if ok else "FAIL"}]  read_document(mineru): {text[:140]!r}')
    r = call({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call',
              'params': {'name': 'list_documents', 'arguments': {'directory': tempfile.gettempdir(), 'pattern': '*.pdf'}}})
    print('[OK]  list_documents:', r['result']['content'][0]['text'].splitlines()[:2])
    r = call({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call',
              'params': {'name': 'read_document', 'arguments': {'path': 'C:\\nope\\missing.pdf'}}})
    print('[OK]  missing file handled:', r['result']['content'][0]['text'][:80], '| isError:', r['result'].get('isError'))
    r = call({'jsonrpc': '2.0', 'id': 6, 'method': 'tools/call',
              'params': {'name': 'web_search', 'arguments': {'query': 'GLM-4.7-Flash context length', 'max_results': 3}}})
    text = r['result']['content'][0]['text']
    ok = 'http' in text and not r['result'].get('isError')
    first = [l for l in text.splitlines() if l.strip()][:3]
    # On failure show the whole error: it names every source that was tried and why it failed.
    shown = ' | '.join(l.strip()[:70] for l in first) if ok else ' '.join(text.split())[:600]
    print(f'[{"OK" if ok else "FAIL"}]  web_search: ' + shown)
finally:
    proc.stdin.close()
    proc.terminate()
    err = proc.stderr.read()
    if err.strip():
        print('stderr:', err.strip()[:300])
