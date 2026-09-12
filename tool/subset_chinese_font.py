"""Build the offline UI font subset from the official OFL Noto Sans SC font.

Input: build/NotoSansSC-full.ttf from google/fonts ofl/notosanssc.
Requires fontTools. Run after updating assets/l10n/zh_CN.json.
"""
import json
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

root = Path(__file__).resolve().parents[1]
catalog = json.loads((root / 'assets/l10n/zh_CN.json').read_text(encoding='utf-8'))
text = ''.join(catalog.values()) + '简体中文'
font = TTFont(root / 'build/NotoSansSC-full.ttf')
font = instantiateVariableFont(font, {'wght': 400}, inplace=True)
options = subset.Options()
options.name_IDs = ['*']
options.name_languages = ['*']
subsetter = subset.Subsetter(options=options)
subsetter.populate(text=text)
subsetter.subset(font)
for record in font['name'].names:
    if record.nameID in [1, 3, 4, 6, 16]:
        record.string = ('DalaChinese' if record.nameID == 6 else 'Dala Chinese').encode(record.getEncoding())
output = root / 'assets/dala/fonts/DalaChinese.ttf'
font.save(output)
print(f'{len(set(text))} UI characters, {output.stat().st_size} bytes')
