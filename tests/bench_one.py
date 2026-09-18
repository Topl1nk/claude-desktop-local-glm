# One measurement pass: load, generation speed, prompt-reading speed, GPU layer split.
# Usage: python bench_one.py <model>
import json
import os
import re
import sys
import time
import urllib.request

BASE = 'http://127.0.0.1:11434'
MODEL = sys.argv[1] if len(sys.argv) > 1 else 'glm-4.7-flash-tuned'
LOG = os.path.expandvars(r'%LOCALAPPDATA%\Ollama\server.log')
BIG = ' '.join(f'Line {i}: the quick brown fox jumps over the lazy dog.' for i in range(1700))


def gen(prompt, num_predict, timeout=3600):
    body = {'model': MODEL, 'prompt': prompt, 'stream': False, 'think': False, 'keep_alive': '10m',
            'options': {'num_predict': num_predict}}
    req = urllib.request.Request(f'{BASE}/api/generate', data=json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    t0 = time.time()
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read()), time.time() - t0


def split():
    try:
        with open(LOG, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()[-6000:]
        lay = [l for l in lines if 'layers to GPU' in l]
        vram = [l for l in lines if 'CUDA0 model buffer size' in l]
        kv = [l for l in lines if 'KV buffer size' in l]
        g = lambda arr, pat: (re.search(pat, arr[-1]).group(1) if arr and re.search(pat, arr[-1]) else '?')
        return g(lay, r'offloaded (\d+/\d+) layers'), g(vram, r'=\s*([\d.]+) MiB'), g(kv, r'=\s*([\d.]+) MiB')
    except Exception:
        return '?', '?', '?'


try:
    t0 = time.time()
    gen('Hello', 1)
    load = time.time() - t0
    layers, vram, kv = split()
    r, _ = gen('Write a detailed paragraph about the ocean.', 120)
    gen_tps = r.get('eval_count', 0) / max(r.get('eval_duration', 1) / 1e9, 0.001)
    r, _ = gen(BIG + '\nReply with OK.', 4)
    pre = r.get('prompt_eval_count', 0)
    pre_tps = pre / max(r.get('prompt_eval_duration', 1) / 1e9, 0.001)
    print(f'load {load:4.0f}s | GPU layers {layers} | weights on GPU {vram} MiB | KV {kv} MiB | '
          f'gen {gen_tps:6.2f} tok/s | prefill {pre_tps:7.1f} tok/s')
except Exception as e:
    print(f'FAILED: {type(e).__name__}: {e}')
