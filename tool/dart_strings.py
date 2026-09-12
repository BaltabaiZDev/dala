"""Read Dart string literals (including nested interpolation) for l10n review."""
from pathlib import Path
import re

def string_at(s, start):
    raw = s[start] == 'r'
    i = start + raw
    q = s[i]
    quote = q * 3 if s[i:i+3] == q * 3 else q
    i += len(quote)
    result = ''
    args = 0
    while i < len(s):
        if s.startswith(quote, i):
            return i + len(quote), result, args
        c = s[i]
        if c == '\\' and not raw:
            n = s[i+1]
            result += {'n':'\n', 'r':'\r', 't':'\t'}.get(n, n)
            i += 2
        elif c == '$' and not raw:
            if s[i+1] == '{':
                i = balanced_end(s, i+1)
            else:
                m = re.match(r'\$\w+', s[i:])
                if not m:
                    result += c
                    i += 1
                    continue
                i += len(m[0])
            result += '{' + str(args) + '}'
            args += 1
        else:
            result += c
            i += 1
    raise ValueError(f'Unterminated string at {start}')

def balanced_end(s, start):
    stack = [s[start]]
    i = start + 1
    pairs = {')':'(', ']':'[', '}':'{'}
    while stack:
        if s[i] in "'\"" or (s[i] == 'r' and s[i+1] in "'\""):
            i = string_at(s, i)[0]
            continue
        if s[i] in '([{': stack.append(s[i])
        elif s[i] in pairs:
            assert stack.pop() == pairs[s[i]]
        i += 1
    return i

def strings(s):
    i = 0
    while i < len(s):
        if s.startswith('//', i):
            i = s.find('\n', i)
            if i < 0: break
        elif s.startswith('/*', i):
            i = s.index('*/', i) + 2
        elif s[i] in "'\"" or (s[i] == 'r' and i+1 < len(s) and s[i+1] in "'\""):
            start = i
            i, value, args = string_at(s, i)
            while True:
                j = i
                while j < len(s) and s[j].isspace(): j += 1
                if j < len(s) and s[j] in "'\"":
                    i, part, n = string_at(s, j)
                    part = re.sub(r'\{(\d+)\}', lambda m:'{' + str(int(m[1]) + args) + '}', part)
                    args += n
                    value += part
                else: break
            yield start, i, value
        else: i += 1

if __name__ == '__main__':
    known = {line.split('|')[0].replace(r'\n','\n') for line in Path('lib/src/l10n/catalog.txt').read_text(encoding='utf-8').splitlines()}
    result = []
    for p in list(Path('lib/src/ui').glob('*.dart')) + list(Path('lib/src/lan').glob('*.dart')) + [Path('lib/src/game/game_controller.dart')]:
        values = []
        for _, _, value in strings(p.read_text(encoding='utf-8')):
            if re.search('[А-Яа-яӘәҒғҚқҢңӨөҰұҮүҺһІі]', value) and value not in known and value not in values:
                values.append(value)
        result.append(str(p) + '\n' + '\n'.join(v.replace('\n',r'\n') for v in values))
    Path('build/missing-translations.txt').write_text('\n\n'.join(result), encoding='utf-8')
