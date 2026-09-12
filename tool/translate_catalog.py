"""Generate offline draft translations of DALA UI (no user data).

Uses Google's public translation endpoint; existing entries are kept for review.
Run explicitly when updating the catalog, never during a game/build.
"""
import concurrent.futures
import collections
import json
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = 'uk de cs fr pl it es sk zh_CN tr bg pt_BR nl hu be id el nb sr lt hr ca lv'.split()
API_CODES = {'zh_CN': 'zh-CN', 'pt_BR': 'pt', 'nb': 'no'}
TOKEN = re.compile(r'\{\d+\}|\n|\.dalamod|\.dalamap|\.zip|\.tmx|\bDALA\b|\bLAN\b')
MARKER = re.compile(r'DALA\s*(\d{4})', re.I)
rows = {}
for line in (ROOT / 'lib/src/l10n/catalog.txt').read_text(encoding='utf-8').splitlines():
    if line and not line.startswith('#'):
        kk, ru, en = [x.replace(r'\n', '\n') for x in line.split('|')]
        rows[kk] = en


def request(text, lang):
    url = 'https://translate.googleapis.com/translate_a/single?' + urllib.parse.urlencode({
        'client': 'gtx', 'sl': 'en', 'tl': API_CODES.get(lang, lang), 'dt': 't', 'q': text})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=45) as response:
                data = json.load(response)
            return ''.join(part[0] for part in data[0] if part[0])
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise
            if attempt == 4:
                raise
            time.sleep(3 * (attempt + 1))
        except (OSError, ValueError):
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))


def protect(source):
    tokens = []
    def replace(match):
        tokens.append(match[0])
        return f'ZXQ{len(tokens)-1}QXZ'
    # English "turn" is ambiguous outside a strategy game.
    source = re.sub(r'\bturns\b', 'game rounds', source)
    source = re.sub(r'\bturn\b', 'game round', source)
    return TOKEN.sub(replace, source), tokens


def restore(text, tokens):
    for i, value in enumerate(tokens):
        pattern = re.compile(r'ZXQ\s*' + str(i) + r'\s*QXZ', re.I)
        if len(pattern.findall(text)) != 1:
            raise ValueError('Missing/repeated protected token')
        text = pattern.sub(lambda _: value, text)
    if re.search(r'ZXQ|QXZ|DALA\d{4}', text, re.I):
        raise ValueError('Leaked token')
    return text.strip()


def translate_single(original, lang):
    # Preserve paragraph structure explicitly; translation engines can discard
    # text following adjoining opaque tokens standing in for blank lines.
    result = []
    for paragraph in original.split('\n'):
        if not paragraph:
            result.append('')
            continue
        source, tokens = protect(paragraph)
        try:
            value = restore(request(source, lang), tokens)
        except ValueError:
            value = request(paragraph, lang)
            if collections.Counter(TOKEN.findall(value)) != collections.Counter(TOKEN.findall(paragraph)):
                # Last resort for an engine repeating a numeric placeholder:
                # keep data tokens untouched and translate their text spans.
                pieces = re.split('(' + TOKEN.pattern + ')', paragraph)
                value = ''.join(piece if TOKEN.fullmatch(piece) or not piece.strip() else
                    (' ' if piece.startswith(' ') else '') + request(piece.strip(), lang).strip() + (' ' if piece.endswith(' ') else '')
                    for piece in pieces)
                print(f'REVIEW fragmented phrase: {lang} {list(rows).index(next(k for k, v in rows.items() if v == original))}', flush=True)
        result.append(value)
    return '\n'.join(result)


def translate(lang):
    if lang == 'sr':
        return translate_serbian()
    path = ROOT / 'assets/l10n' / f'{lang}.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    catalog = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    pending = [(key, *protect(en)) for key, en in rows.items() if key not in catalog]
    # Short batches keep the URL bounded and allow strict row validation.
    for offset in range(0, len(pending), 35):
        batch = pending[offset:offset+35]
        query = '\n'.join(f'DALA{i:04d} {item[1]}' for i, item in enumerate(batch))
        translated = request(query, lang)
        found = {}
        for line in translated.splitlines():
            markers = list(MARKER.finditer(line))
            if len(markers) == 1:
                index = int(markers[0][1])
                if index not in found:
                    found[index] = MARKER.sub('', line).strip()
        for i, (key, source, tokens) in enumerate(batch):
            try:
                value = restore(found[i], tokens)
            except (KeyError, ValueError):
                value = translate_single(rows[key], lang)
            if not value:
                raise ValueError(f'Empty translation: {lang}/{i}')
            catalog[key] = value
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(f'{lang}: {len(catalog)}/{len(rows)}', flush=True)
    # Prune removed UI strings; preserve reviewed entries verbatim.
    catalog = {key: catalog[key] for key in rows}
    for key, value in catalog.items():
        assert collections.Counter(re.findall(r'\{\d+\}', key)) == collections.Counter(re.findall(r'\{\d+\}', value)), (lang, key)
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return lang


def translate_serbian():
    # Serbian transliterates Latin opaque markers. Numeric row markers and
    # native {0} placeholders survive intact; restore technical spellings.
    path = ROOT / 'assets/l10n/sr.json'
    catalog = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
    replacements = {'ДАЛА': 'DALA', 'ЛАН': 'LAN', '.даламод': '.dalamod', '.даламап': '.dalamap', '.зип': '.zip', '.тмк': '.tmx', '.тмкc': '.tmx'}
    def normalize(text):
        for old, new in replacements.items():
            text = text.replace(old, new)
        return text
    items = [(key, en) for key, en in rows.items() if key not in catalog]
    for offset in range(0, len(items), 30):
        batch = items[offset:offset+30]
        # Each paragraph has its own row so blank lines cannot be swallowed.
        parts = [part for key, en in batch for part in en.split('\n') if part]
        query = '\n'.join(f'[{i:04d}] ' + re.sub(r'\bturns?\b', 'game rounds', part) for i, part in enumerate(parts))
        translated = request(query, 'sr')
        matches = list(re.finditer(r'\[(\d{4})\]', translated))
        values = {int(m[1]): normalize(translated[m.end():matches[i+1].start() if i+1 < len(matches) else len(translated)].strip()) for i, m in enumerate(matches)}
        cursor = 0
        for key, en in batch:
            result = []
            for part in en.split('\n'):
                if not part:
                    result.append('')
                    continue
                value = values.get(cursor, '')
                cursor += 1
                expected = collections.Counter(re.findall(r'\{\d+\}', part))
                if not value or collections.Counter(re.findall(r'\{\d+\}', value)) != expected:
                    value = normalize(request(part, 'sr'))
                if collections.Counter(re.findall(r'\{\d+\}', value)) != expected:
                    raise ValueError('Serbian placeholders: ' + ascii(part))
                result.append(value)
            catalog[key] = '\n'.join(result)
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
        print(f'sr: {len(catalog)}/{len(rows)}', flush=True)
    catalog = {key: catalog[key] for key in rows}
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return 'sr'


if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for result in pool.map(translate, LANGUAGES):
            print(f'DONE {result}', flush=True)
