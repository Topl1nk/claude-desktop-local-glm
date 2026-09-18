# Checks what Desktop-style attachments the local gateway accepts: PDF document block and image block.
import base64
import json
import urllib.error
import urllib.request
import zlib

BASE = 'http://127.0.0.1:11434/v1/messages'
HEADERS = {'Content-Type': 'application/json', 'Authorization': 'Bearer ollama-local',
           'anthropic-version': '2023-06-01'}


def minimal_pdf(text='Hello from a test PDF. The secret word is KESTREL.'):
    objs = []
    objs.append(b'<< /Type /Catalog /Pages 2 0 R >>')
    objs.append(b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
    objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
                b'/Resources << /Font << /F1 5 0 R >> >> >>')
    stream = f'BT /F1 18 Tf 72 700 Td ({text}) Tj ET'.encode()
    objs.append(b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream')
    objs.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    out = bytearray(b'%PDF-1.4\n')
    offsets = []
    for n, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += f'{n} 0 obj\n'.encode() + body + b'\nendobj\n'
    xref = len(out)
    out += f'xref\n0 {len(objs) + 1}\n0000000000 65535 f \n'.encode()
    for off in offsets:
        out += f'{off:010d} 00000 n \n'.encode()
    out += f'trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return bytes(out)


def png_1x1_red():
    def chunk(tag, data):
        return (len(data)).to_bytes(4, 'big') + tag + data + zlib.crc32(tag + data).to_bytes(4, 'big')
    ihdr = (1).to_bytes(4, 'big') + (1).to_bytes(4, 'big') + bytes([8, 2, 0, 0, 0])
    idat = zlib.compress(b'\x00\xff\x00\x00')
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')


def send(label, content):
    body = {'model': 'claude-sonnet-4-6', 'max_tokens': 200, 'messages': [{'role': 'user', 'content': content}]}
    req = urllib.request.Request(BASE, data=json.dumps(body).encode(), headers=HEADERS)
    try:
        r = json.loads(urllib.request.urlopen(req, timeout=900).read())
        text = ' '.join(b.get('text', '') for b in r.get('content', []) if b.get('type') == 'text').strip()
        print(f'[OK]   {label}: {text[:160]!r}', flush=True)
    except urllib.error.HTTPError as e:
        print(f'[FAIL] {label}: HTTP {e.code} {e.read().decode()[:200]}', flush=True)
    except Exception as e:
        print(f'[FAIL] {label}: {type(e).__name__}: {e}', flush=True)


if __name__ == '__main__':
    pdf_b64 = base64.b64encode(minimal_pdf()).decode()
    png_b64 = base64.b64encode(png_1x1_red()).decode()

    send('PDF as document block', [
        {'type': 'document', 'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': pdf_b64}},
        {'type': 'text', 'text': 'What is the secret word in this PDF?'}])

    send('image as image block', [
        {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': png_b64}},
        {'type': 'text', 'text': 'What colour is this image?'}])

    send('plain text (control)', 'Say OK')
