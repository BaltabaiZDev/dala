"""Review corrections for short game controls where context-free MT is ambiguous."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sources = {}
for line in (ROOT/'lib/src/l10n/catalog.txt').read_text(encoding='utf-8').splitlines():
    if line and not line.startswith('#'):
        kk, ru, en = line.split('|')
        sources[en.replace(r'\n', '\n')] = kk.replace(r'\n', '\n')

keys = ['End turn', 'End this turn?', 'Your turn', '{0}, begin your turn', 'Turn timer', 'Turn timer disabled', 'Turn time: {0} minutes', 'Turn time: {0} min {1} sec', 'Hold to end turn']
corrections = {
    'uk': ['Завершити хід', 'Завершити цей хід?', 'Ваш хід', '{0}, почніть свій хід', 'Таймер ходу', 'Таймер ходу вимкнено', 'Час ходу: {0} хвилин', 'Час ходу: {0} хв {1} с', 'Утримуйте, щоб завершити хід'],
    'de': ['Zug beenden', 'Diesen Zug beenden?', 'Du bist am Zug', '{0}, du bist am Zug', 'Zugtimer', 'Zugtimer deaktiviert', 'Zugzeit: {0} Minuten', 'Zugzeit: {0} Min. {1} Sek.', 'Gedrückt halten, um den Zug zu beenden'],
    'cs': ['Ukončit tah', 'Ukončit tento tah?', 'Jste na tahu', '{0}, začněte svůj tah', 'Časovač tahu', 'Časovač tahu vypnut', 'Čas na tah: {0} minut', 'Čas na tah: {0} min {1} s', 'Podržením ukončíte tah'],
    'fr': ['Terminer le tour', 'Terminer ce tour ?', 'À vous de jouer', '{0}, à vous de jouer', 'Minuteur de tour', 'Minuteur de tour désactivé', 'Durée du tour : {0} minutes', 'Durée du tour : {0} min {1} s', 'Maintenez pour terminer le tour'],
    'pl': ['Zakończ turę', 'Zakończyć tę turę?', 'Twoja tura', '{0}, rozpocznij swoją turę', 'Limit czasu tury', 'Limit czasu tury wyłączony', 'Czas tury: {0} minut', 'Czas tury: {0} min {1} s', 'Przytrzymaj, aby zakończyć turę'],
    'it': ['Termina turno', 'Terminare questo turno?', 'È il tuo turno', '{0}, inizia il tuo turno', 'Timer del turno', 'Timer del turno disattivato', 'Tempo del turno: {0} minuti', 'Tempo del turno: {0} min {1} s', 'Tieni premuto per terminare il turno'],
    'es': ['Terminar turno', '¿Terminar este turno?', 'Es tu turno', '{0}, empieza tu turno', 'Temporizador de turno', 'Temporizador de turno desactivado', 'Tiempo del turno: {0} minutos', 'Tiempo del turno: {0} min {1} s', 'Mantén pulsado para terminar el turno'],
    'sk': ['Ukončiť ťah', 'Ukončiť tento ťah?', 'Ste na ťahu', '{0}, začnite svoj ťah', 'Časovač ťahu', 'Časovač ťahu vypnutý', 'Čas na ťah: {0} minút', 'Čas na ťah: {0} min {1} s', 'Podržaním ukončíte ťah'],
    'zh_CN': ['结束回合', '结束本回合？', '轮到你了', '{0}，开始你的回合', '回合计时器', '回合计时器已关闭', '回合时间：{0} 分钟', '回合时间：{0} 分 {1} 秒', '长按结束回合'],
    'tr': ['Turu bitir', 'Bu tur bitirilsin mi?', 'Sıra sende', '{0}, turuna başla', 'Tur sayacı', 'Tur sayacı kapalı', 'Tur süresi: {0} dakika', 'Tur süresi: {0} dk {1} sn', 'Turu bitirmek için basılı tut'],
    'bg': ['Край на хода', 'Да приключи ли този ход?', 'Ваш ред е', '{0}, започнете своя ход', 'Таймер за ход', 'Таймерът за ход е изключен', 'Време за ход: {0} минути', 'Време за ход: {0} мин {1} сек', 'Задръжте, за да приключите хода'],
    'pt_BR': ['Encerrar turno', 'Encerrar este turno?', 'É sua vez', '{0}, comece seu turno', 'Temporizador do turno', 'Temporizador do turno desativado', 'Tempo do turno: {0} minutos', 'Tempo do turno: {0} min {1} s', 'Segure para encerrar o turno'],
    'nl': ['Beurt beëindigen', 'Deze beurt beëindigen?', 'Jij bent aan de beurt', '{0}, begin je beurt', 'Beurttimer', 'Beurttimer uitgeschakeld', 'Beurttijd: {0} minuten', 'Beurttijd: {0} min {1} sec', 'Ingedrukt houden om de beurt te beëindigen'],
    'hu': ['Kör befejezése', 'Befejezed ezt a kört?', 'Te következel', '{0}, kezdd el a körödet', 'Köridőzítő', 'Köridőzítő kikapcsolva', 'Köridő: {0} perc', 'Köridő: {0} perc {1} mp', 'Tartsd nyomva a kör befejezéséhez'],
    'be': ['Скончыць ход', 'Скончыць гэты ход?', 'Ваш ход', '{0}, пачніце свой ход', 'Таймер ходу', 'Таймер ходу выключаны', 'Час ходу: {0} хвілін', 'Час ходу: {0} хв {1} с', 'Утрымлівайце, каб скончыць ход'],
    'id': ['Akhiri giliran', 'Akhiri giliran ini?', 'Giliranmu', '{0}, mulai giliranmu', 'Pengatur waktu giliran', 'Pengatur waktu giliran dinonaktifkan', 'Waktu giliran: {0} menit', 'Waktu giliran: {0} mnt {1} dtk', 'Tahan untuk mengakhiri giliran'],
    'el': ['Τέλος γύρου', 'Να τελειώσει αυτός ο γύρος;', 'Η σειρά σου', '{0}, ξεκίνα τον γύρο σου', 'Χρονόμετρο γύρου', 'Το χρονόμετρο γύρου είναι ανενεργό', 'Χρόνος γύρου: {0} λεπτά', 'Χρόνος γύρου: {0} λ {1} δ', 'Κράτησε πατημένο για να τελειώσεις τον γύρο'],
    'nb': ['Avslutt tur', 'Avslutte denne turen?', 'Din tur', '{0}, start turen din', 'Turtidtaker', 'Turtidtaker deaktivert', 'Turtid: {0} minutter', 'Turtid: {0} min {1} sek', 'Hold inne for å avslutte turen'],
    'sr': ['Заврши потез', 'Завршити овај потез?', 'Ваш потез', '{0}, започните свој потез', 'Тајмер потеза', 'Тајмер потеза је искључен', 'Време потеза: {0} минута', 'Време потеза: {0} мин {1} сек', 'Држите да завршите потез'],
    'lt': ['Baigti ėjimą', 'Baigti šį ėjimą?', 'Jūsų ėjimas', '{0}, pradėkite savo ėjimą', 'Ėjimo laikmatis', 'Ėjimo laikmatis išjungtas', 'Ėjimo laikas: {0} minučių', 'Ėjimo laikas: {0} min {1} s', 'Palaikykite, kad baigtumėte ėjimą'],
    'hr': ['Završi potez', 'Završiti ovaj potez?', 'Vaš potez', '{0}, započnite svoj potez', 'Mjerač vremena poteza', 'Mjerač vremena poteza je isključen', 'Vrijeme poteza: {0} minuta', 'Vrijeme poteza: {0} min {1} s', 'Držite za završetak poteza'],
    'ca': ['Acaba el torn', 'Vols acabar aquest torn?', 'És el teu torn', '{0}, comença el teu torn', 'Temporitzador del torn', 'Temporitzador del torn desactivat', 'Temps del torn: {0} minuts', 'Temps del torn: {0} min {1} s', 'Mantén premut per acabar el torn'],
    'lv': ['Beigt gājienu', 'Beigt šo gājienu?', 'Jūsu gājiens', '{0}, sāciet savu gājienu', 'Gājiena taimeris', 'Gājiena taimeris izslēgts', 'Gājiena laiks: {0} minūtes', 'Gājiena laiks: {0} min {1} s', 'Turiet nospiestu, lai beigtu gājienu'],
}
extra = {
    'uk': {'Continue': 'Продовжити'},
    'be': {'Continue': 'Працягнуць', '{0} land cells · {1} sea assets · value {2}': '{0} зямельных клетак · {1} марскіх аб’ектаў · кошт {2}', 'This side cannot transfer this sea asset': 'Гэты бок не можа перадаць гэты марскі аб’ект', 'This land is already assigned to another ally': 'Гэтая зямля ўжо прызначана іншаму саюзніку', 'This cell is not part of this land settlement': 'Гэтая клетка не ўваходзіць у гэты падзел зямлі', 'The host sent an invalid LAN response.': 'Хост даслаў няправільны адказ LAN.', 'The host did not respond to the action in time.': 'Хост не адказаў на дзеянне своечасова.'},
    'sr': {'Continue': 'Настави', 'Humans: {0} · Bots: {1}': 'Људи: {0} · Ботови: {1}', 'No languages found': 'Ниједан језик није пронађен', 'Bots control the remaining factions.': 'Ботови управљају преосталим фракцијама.', 'ATLAS OF THE STEPPE': 'АТЛАС СТЕПЕ'},
    'lt': {'Battle': 'Mūšis', 'Tap a cell: land ↔ water': 'Bakstelėkite langelį: žemė ↔ vanduo', 'Apply and regenerate': 'Taikyti ir sugeneruoti iš naujo'},
    'lv': {'Battle': 'Kauja'},
    'fr': {'New trade offer': 'Nouvelle offre d’échange'},
    'nl': {'Could not open map: {0}': 'Kan kaart niet openen: {0}'},
    'bg': {'{0} troops sent here': 'Тук са изпратени {0} войници', 'Choose the next troops to disembark': 'Изберете следващите войници за слизане', 'Troops disembarked': 'Войниците слязоха на брега', 'Selection cleared': 'Изборът е изчистен', 'This move is not possible': 'Този ход е невъзможен', 'Choose a green cell': 'Изберете зелена клетка', 'Province selected': 'Провинцията е избрана', 'Border captured immediately': 'Границата е превзета веднага', 'Building constructed': 'Сградата е построена', 'Cannot launch a ship here': 'Тук не може да се пусне кораб', 'Cannot build here': 'Тук не може да се строи', 'Sea region deselected': 'Изборът на морска област е отменен'},
    'zh_CN': {'Humans: {0} · Bots: {1}': '玩家：{0} · 电脑：{1}', 'Humans: {0}': '玩家：{0}', 'Human players': '玩家人数', 'Bots control the remaining factions.': '其余阵营由电脑控制。', 'Order runs top to bottom. The later mod wins when settings overlap.': '模组按从上到下的顺序加载。设置冲突时，以后加载的模组为准。'},
}
for code, values in corrections.items():
    path = ROOT/'assets/l10n'/f'{code}.json'
    catalog = json.loads(path.read_text(encoding='utf-8'))
    for en, value in list(zip(keys, values)) + list(extra.get(code, {}).items()):
        catalog[sources[en]] = value
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print('Reviewed turn controls for 23 languages')
