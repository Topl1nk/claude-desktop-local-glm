"""Web search for the local Claude Desktop setup - no API key, no quota.

Sources, in order:
  1. SearXNG on http://127.0.0.1:8888 (self-hosted metasearch: Google, DuckDuckGo, Brave, ...)
  2. DuckDuckGo's HTML endpoint - fallback when SearXNG/Docker is not running (retried once),
  3. DuckDuckGo's lite page - when the HTML endpoint answers with a bot check.
"""
import html
import json
import os
import re
import time
import urllib.parse
import urllib.request

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) claude-desktop-local-search/1.0'
SEARXNG = os.environ.get('SEARXNG_URL', 'http://127.0.0.1:8888')
TIMEOUT = 12


def _fetch(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers={'User-Agent': UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode('utf-8', 'replace')


def from_searxng(query, limit):
    url = f'{SEARXNG.rstrip("/")}/search?' + urllib.parse.urlencode(
        {'q': query, 'format': 'json', 'safesearch': '0', 'language': 'auto'})
    data = json.loads(_fetch(url))
    out = []
    for r in data.get('results', [])[:limit]:
        if r.get('url'):
            out.append({'title': r.get('title') or r['url'], 'url': r['url'],
                        'snippet': (r.get('content') or '')[:1000]})
    return out


def from_duckduckgo(query, limit):
    body = urllib.parse.urlencode({'q': query, 'kl': 'wt-wt'}).encode()
    page = _fetch('https://html.duckduckgo.com/html/', data=body,
                  headers={'Content-Type': 'application/x-www-form-urlencoded'})
    clean = lambda s: html.unescape(re.sub(r'<.*?>', '', s)).strip()
    out = []
    blocks = re.findall(
        r'<a rel="nofollow" class="result__a" href="(.*?)".*?>(.*?)</a>(.*?)(?=<a rel="nofollow" class="result__a"|\Z)',
        page, re.S)
    for href, title, tail in blocks[:limit]:
        url = html.unescape(href)
        if 'duckduckgo.com/l/?uddg=' in url:                     # unwrap redirector
            url = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get('uddg', [url])[0]
        if not url.startswith('http'):
            continue
        snippet = re.search(r'class="result__snippet".*?>(.*?)</a>', tail, re.S)
        out.append({'title': clean(title), 'url': url,
                    'snippet': clean(snippet.group(1))[:1000] if snippet else ''})
    return out


def from_duckduckgo_lite(query, limit):
    # DuckDuckGo's plain "lite" page: blocked less often than the HTML endpoint.
    body = urllib.parse.urlencode({'q': query, 'kl': 'wt-wt'}).encode()
    page = _fetch('https://lite.duckduckgo.com/lite/', data=body,
                  headers={'Content-Type': 'application/x-www-form-urlencoded'})
    clean = lambda s: html.unescape(re.sub(r'<.*?>', '', s)).strip()
    links = re.findall(r'<a rel="nofollow" href="(.*?)" class=\'result-link\'>(.*?)</a>', page, re.S)
    snippets = re.findall(r"<td class='result-snippet'>(.*?)</td>", page, re.S)
    out = []
    for i, (href, title) in enumerate(links[:limit]):
        url = html.unescape(href)
        if 'duckduckgo.com/l/?uddg=' in url:
            url = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get('uddg', [url])[0]
        if url.startswith('//'):
            url = 'https:' + url
        if not url.startswith('http'):
            continue
        out.append({'title': clean(title), 'url': url, 'snippet': clean(snippets[i])[:1000] if i < len(snippets) else ''})
    return out


def search(query, limit=10):
    """Returns (results, source, errors)."""
    errors = []
    # DuckDuckGo sometimes answers automated requests with a check page instead of results: one
    # retry after a pause, then its lite page.
    sources = (('searxng', from_searxng, 0), ('duckduckgo', from_duckduckgo, 0),
               ('duckduckgo', from_duckduckgo, 3), ('duckduckgo-lite', from_duckduckgo_lite, 0))
    for name, getter, pause in sources:
        time.sleep(pause)
        try:
            results = getter(query, limit)
            if results:
                return results, name, errors
            errors.append(f'{name}: no results')
        except Exception as e:
            errors.append(f'{name}: {type(e).__name__}: {e}')
    return [], None, errors
