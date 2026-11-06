## layout.nim — перекодировка текста между раскладками EN (QWERTY) и RU (ЙЦУКЕН).
##
## Для текста, набираемого «на лету», скан-коды известны, и достаточно
## повторить их после переключения раскладки. Для уже выделенного текста
## есть только готовая строка символов, поэтому каждый символ заменяется
## тем, который находится на той же физической клавише в другой раскладке
## (принцип Punto Switcher). Направление определяется автоматически.

import std/[tables, unicode]

const
  ## Нижний регистр: EN → RU по позициям клавиш. Знаки, делящие клавишу с
  ## русской буквой ([ ] ; ' , .), включены в таблицу; пара ('/', ".") —
  ## клавиша, которая в русской раскладке даёт точку.
  ## Таблица задана массивом пар, а не табличным литералом, чтобы символы
  ## вроде ' " { } не мешали читать синтаксис.
  EnToRuLowerPairs: array[33, (char, string)] = [
    ('q', "й"), ('w', "ц"), ('e', "у"), ('r', "к"), ('t', "е"), ('y', "н"),
    ('u', "г"), ('i', "ш"), ('o', "щ"), ('p', "з"),
    ('a', "ф"), ('s', "ы"), ('d', "в"), ('f', "а"), ('g', "п"), ('h', "р"),
    ('j', "о"), ('k', "л"), ('l', "д"),
    ('z', "я"), ('x', "ч"), ('c', "с"), ('v', "м"), ('b', "и"), ('n', "т"),
    ('m', "ь"),
    ('[', "х"), (']', "ъ"), (';', "ж"), (chr(39), "э"),   ## chr(39) = '
    (',', "б"), ('.', "ю"), ('/', ".")
  ]

  ## Верхний регистр: те же клавиши с зажатым Shift.
  ## chr(123) = '{', chr(125) = '}', chr(34) = '"'.
  EnToRuUpperPairs: array[33, (char, string)] = [
    ('Q', "Й"), ('W', "Ц"), ('E', "У"), ('R', "К"), ('T', "Е"), ('Y', "Н"),
    ('U', "Г"), ('I', "Ш"), ('O', "Щ"), ('P', "З"),
    ('A', "Ф"), ('S', "Ы"), ('D', "В"), ('F', "А"), ('G', "П"), ('H', "Р"),
    ('J', "О"), ('K', "Л"), ('L', "Д"),
    ('Z', "Я"), ('X', "Ч"), ('C', "С"), ('V', "М"), ('B', "И"), ('N', "Т"),
    ('M', "Ь"),
    (chr(123), "Х"), (chr(125), "Ъ"), (':', "Ж"), (chr(34), "Э"),
    ('<', "Б"), ('>', "Ю"), ('?', ",")
  ]

proc buildForward(pairs: openArray[(char, string)]): Table[char, string] =
  ## Таблица EN → RU для поиска по символу за O(1).
  result = initTable[char, string]()
  for (k, v) in pairs:
    result[k] = v

proc buildReverse(forward: Table[char, string]): Table[string, char] =
  ## Обратная таблица RU → EN. Ключ — string, так как кириллица в UTF-8
  ## занимает несколько байт. Значения в прямых таблицах уникальны,
  ## поэтому коллизий ключей нет.
  result = initTable[string, char]()
  for k, v in forward:
    result[v] = k

let
  EnToRuLower = buildForward(EnToRuLowerPairs)
  EnToRuUpper = buildForward(EnToRuUpperPairs)
  RuToEnLower = buildReverse(EnToRuLower)
  RuToEnUpper = buildReverse(EnToRuUpper)

proc detectDirection(text: string): bool =
  ## Определяет направление по преобладанию букв.
  ##   true  — латиницы больше (или поровну, или букв нет): EN → RU;
  ##   false — кириллицы больше: RU → EN.
  ## Цифры, пробелы и знаки препинания не учитываются. Равенство трактуется
  ## как EN → RU, потому что чаще всего русское слово набирают латиницей.
  var enCount, ruCount: int
  for r in runes(text):
    let cp = int(r)
    if (cp >= int('a') and cp <= int('z')) or (cp >= int('A') and cp <= int('Z')):
      inc enCount
    elif cp >= 0x0400 and cp <= 0x04FF:   ## блок «Кириллица» Unicode
      inc ruCount
  ruCount <= enCount

proc convertLayout*(text: string): string =
  ## Перекодирует строку между EN и RU, определяя направление автоматически.
  ## Обход идёт по рунам: кириллица в UTF-8 многобайтовая. Символы, которых
  ## нет в таблицах (цифры, пробелы, переводы строк и т.д.), копируются без
  ## изменений, поэтому многострочный текст сохраняет структуру.
  let toRu = detectDirection(text)
  result = ""
  for r in runes(text):
    let s = $r
    if toRu:
      if s.len == 1 and EnToRuLower.hasKey(s[0]): result.add(EnToRuLower[s[0]])
      elif s.len == 1 and EnToRuUpper.hasKey(s[0]): result.add(EnToRuUpper[s[0]])
      else: result.add(s)
    else:
      if RuToEnLower.hasKey(s): result.add($RuToEnLower[s])
      elif RuToEnUpper.hasKey(s): result.add($RuToEnUpper[s])
      else: result.add(s)
