## config.nim — загрузка, проверка и запись файла конфигурации.
##
## Формат файла — простой «ключ=значение» (подмножество INI), значения можно
## заключать в двойные кавычки. loadConfig при любой ошибке проверки
## бросает ConfigError с понятным сообщением.

import os, strutils
import types

type ConfigError* = object of CatchableError

proc readIniKey*(path, key: string; default = ""): string =
  ## Минималистичный чтец «key=value» без секций.
  ## Возвращает default, если файл отсутствует или ключ не найден.
  ## Опциональные кавычки вокруг значения снимаются автоматически.
  if not fileExists(path): return default
  for line in lines(path):
    let t = strip(line)
    if startsWith(t, key & "="):
      var v = strip(t[len(key)+1 .. ^1])
      if len(v) >= 2 and v[0] == '"' and v[^1] == '"':
        v = v[1 .. ^2]
      return v
  return default

proc tryParseUint16(s: string; v: var uint16): bool =
  ## Парсит строку s в uint16. Возвращает false при переполнении или
  ## нечисловом вводе — вместо исключения.
  try:
    let n = parseInt(strip(s))
    if n < 0 or n > 65535: return false
    v = uint16(n)
    return true
  except ValueError:
    return false

proc parseLayoutSwitchKey(raw: string): (seq[uint16], string, string) =
  ## Парсит строку «29+42» (комбинация) или «125» (одна клавиша).
  ## Возвращает (keysLs, strKeysLs, errMsg); errMsg == "" означает успех.
  if '+' in raw:
    let parts = split(raw, '+')
    if len(parts) != 2:
      return (@[], "", "layout-switch-key: ожидается ровно два кода через '+', получено: " & raw)
    var
      k0: uint16
      k1: uint16
    if not tryParseUint16(parts[0], k0):
      return (@[], "", "layout-switch-key: некорректный первый код: " & parts[0])
    if not tryParseUint16(parts[1], k1):
      return (@[], "", "layout-switch-key: некорректный второй код: " & parts[1])
    if k0 == 0 or k1 == 0:
      return (@[], "", "layout-switch-key: коды клавиш не могут быть нулевыми")
    return (@[k0, k1], raw, "")
  else:
    var k0: uint16
    if not tryParseUint16(raw, k0):
      return (@[], "", "layout-switch-key: некорректный код: " & raw)
    if k0 == 0:
      return (@[], "", "layout-switch-key: код клавиши не может быть нулевым (не задан?)")
    return (@[k0], raw, "")

# ── Загрузка конфигурации ─────────────────────────────────────────────────────

proc loadConfig*(path: string): AppConfig =
  ## Загружает и валидирует конфиг из path. Бросает ConfigError при любой ошибке.
  if not fileExists(path):
    raise newException(ConfigError,
      "Конфиг не найден: " & path & ". Запустите 'wayland-switcher -c' для настройки.")

  let
    kbdPath  = readIniKey(path, "keyboard")
    mPath    = readIniKey(path, "mouse")
    lskRaw   = readIniKey(path, "layout-switch-key", "")
    rplRaw   = readIniKey(path, "replace-key",       "")
    revRaw   = readIniKey(path, "reverse-mode",      "false")
    delRaw   = readIniKey(path, "delay",             "10")
    clipRaw  = readIniKey(path, "clipboard-tool",    "auto")

  if kbdPath == "":
    raise newException(ConfigError, "Отсутствует параметр 'keyboard' в конфиге.")
  if mPath == "":
    raise newException(ConfigError, "Отсутствует параметр 'mouse' в конфиге.")
  if lskRaw == "":
    raise newException(ConfigError, "Отсутствует параметр 'layout-switch-key' в конфиге.")
  if rplRaw == "":
    raise newException(ConfigError, "Отсутствует параметр 'replace-key' в конфиге.")

  let (keysLs, strKeys, lskErr) = parseLayoutSwitchKey(lskRaw)
  if lskErr != "":
    raise newException(ConfigError, lskErr)

  var keyRpl: uint16
  if not tryParseUint16(rplRaw, keyRpl) or keyRpl == 0:
    raise newException(ConfigError, "replace-key: некорректное значение: " & rplRaw)

  var delayMs = 10
  try:
    delayMs = parseInt(strip(delRaw))
  except ValueError:
    raise newException(ConfigError, "delay: некорректное значение: " & delRaw)
  if delayMs < 0 or delayMs > 5000:
    raise newException(ConfigError,
      "delay: значение вне допустимого диапазона (0..5000): " & delRaw)

  let reverseMode = toLowerAscii(strip(revRaw)) == "true"

  let clipTool =
    case toLowerAscii(strip(clipRaw))
    of "wayland", "wl-clipboard", "wl": ClipWayland
    of "xclip":                          ClipXclip
    of "xsel":                           ClipXsel
    else:                                ClipAuto  ## "auto" или нераспознанное значение

  result = AppConfig(
    kbdPath:     kbdPath,
    mousePath:   mPath,
    keysLs:      keysLs,
    strKeysLs:   strKeys,
    keyRpl:      keyRpl,
    reverseMode: reverseMode,
    delayMs:     delayMs,
    clipTool:    clipTool)

# ── Запись конфигурации ───────────────────────────────────────────────────────

proc saveConfig*(cfg: AppConfig) =
  ## Записывает конфиг в CONFIG_FILE с подробными комментариями.
  ## Бросает CatchableError при ошибке ввода-вывода.
  createDir(parentDir(CONFIG_FILE))
  let cfgText = """
[WaylandSwitcher]
# Конфигурационный файл WaylandSwitcher.

# Путь к устройству клавиатуры.
# Список устройств выводит команда: hwinfo --keyboard --short
# keyboard="/dev/input/event2"

keyboard="$1"


# Путь к устройству мыши.
# Список устройств выводит команда: hwinfo --mouse --short
# mouse="/dev/input/mice"

mouse="$2"


# Скан-код клавиши (или комбинации), переключающей раскладку.
# Скан-коды клавиш показывает команда: sudo showkey
# layout-switch-key=125
# layout-switch-key=29+42

layout-switch-key=$3


# Скан-код клавиши для коррекции введённого текста.
# Комбинации не поддерживаются. По умолчанию используется PAUSE/BREAK.
# Скан-коды клавиш показывает команда: sudo showkey
# replace-key=119

replace-key=$4


# reverse-mode=false: <replace-key> исправляет последнее слово,
#   Shift+<replace-key> — всю фразу.
# reverse-mode=true: поведение обратное.
# По умолчанию: false.
# reverse-mode=false

reverse-mode=$5


# Задержка (мс) между эмитируемыми событиями.
# Увеличьте, если получаете некорректный вывод.
# По умолчанию: 10.
# delay=10

delay=$6


# Инструмент буфера обмена для коррекции выделенного текста.
# Значения: auto, wayland (wl-clipboard), xclip, xsel.
# auto — автоопределение: wl-paste → xclip → xsel.
# Используется при нажатии <replace-key> с активным выделением текста.
# По умолчанию: auto.
# clipboard-tool=auto

clipboard-tool=$7
""".strip() % [
    cfg.kbdPath,
    cfg.mousePath,
    cfg.strKeysLs,
    $cfg.keyRpl,
    (if cfg.reverseMode: "true" else: "false"),
    $cfg.delayMs,
    (case cfg.clipTool
     of ClipWayland: "wayland"
     of ClipXclip:   "xclip"
     of ClipXsel:    "xsel"
     of ClipAuto:    "auto")]
  writeFile(CONFIG_FILE, cfgText & "\n")
