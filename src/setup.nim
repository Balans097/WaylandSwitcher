## setup.nim — конфигурация, интерактивная настройка и управление systemd-юнитом.
##
## Объединяет бывшие config.nim, configure.nim и install.nim.
## Все три исходных модуля обслуживают «фазу настройки» приложения и
## не участвуют в горячем пути обработки событий.
##
## ── Конфигурация (config) ────────────────────────────────────────────────────
##
##   Формат файла: простой «key=value» без секций (INI-подмножество).
##   Функции: readIniKey, loadConfig, saveConfig.
##   loadConfig бросает ConfigError при любой ошибке валидации.
##
## ── Интерактивная настройка (configure) ──────────────────────────────────────
##
##   runConfig() проводит пользователя через три шага:
##     1. Автоопределение клавиатуры (параллельные потоки на каждый /dev/input/event*).
##     2. Захват клавиши/комбинации переключения раскладки.
##     3. Захват клавиши коррекции текста.
##   Результат записывается через saveConfig.
##
## ── Установка/удаление systemd-юнита (install) ───────────────────────────────
##
##   runInstall()   — создаёт /lib/systemd/system/wayland-switcher.service.
##   runUninstall() — удаляет его.
##   shellEscape()  — защищает путь с пробелами для поля ExecStart.

import posix, os, strutils, std/atomics
import types, core

# ── Тип ошибки конфигурации ───────────────────────────────────────────────────

type ConfigError* = object of CatchableError

# ── Аргумент потока определения клавиатуры ────────────────────────────────────

type
  ## Передаётся в kbdDetectFn. Поток записывает active=true при обнаружении
  ## нажатия Enter; главный поток читает — без гонки (Atomic[bool]).
  KbdDetectArgSafe* = object
    path*:   string          ## путь к /dev/input/event*
    active*: Atomic[bool]   ## атомарный флаг: поток пишет, главный — читает

# ── Вспомогательные функции конфигурации ─────────────────────────────────────

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
    kbdPath = readIniKey(path, "keyboard")
    mPath   = readIniKey(path, "mouse")
    lskRaw  = readIniKey(path, "layout-switch-key", "")
    rplRaw  = readIniKey(path, "replace-key",       "")
    revRaw  = readIniKey(path, "reverse-mode",      "false")
    delRaw  = readIniKey(path, "delay",             "10")

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

  result = AppConfig(
    kbdPath:     kbdPath,
    mousePath:   mPath,
    keysLs:      keysLs,
    strKeysLs:   strKeys,
    keyRpl:      keyRpl,
    reverseMode: reverseMode,
    delayMs:     delayMs)

# ── Запись конфигурации ───────────────────────────────────────────────────────

proc saveConfig*(cfg: AppConfig) =
  ## Записывает конфиг в CONFIG_FILE с подробными комментариями.
  ## Бросает CatchableError при ошибке ввода-вывода.
  createDir(parentDir(CONFIG_FILE))
  let cfgText = """
[WaylandSwitcher]
# Конфигурационный файл WaylandSwitcher.

# Путь к устройству клавиатуры.
# Команда '~$ hwinfo --keyboard --short' выводит список устройств.
# keyboard="/dev/input/event2"

keyboard="$1"


# Путь к устройству мыши.
# Команда '~$ hwinfo --mouse --short' выводит список устройств.
# mouse="/dev/input/mice"

mouse="$2"


# Скан-код клавиши (или комбинации), переключающей раскладку.
# '~$ sudo showkey' — посмотреть скан-коды.
# layout-switch-key=125
# layout-switch-key=29+42

layout-switch-key=$3


# Скан-код клавиши для коррекции введённого текста.
# Комбинации не поддерживаются. По умолчанию используется PAUSE/BREAK.
# '~$ sudo showkey' — посмотреть скан-коды.
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
""".strip() % [
    cfg.kbdPath,
    cfg.mousePath,
    cfg.strKeysLs,
    $cfg.keyRpl,
    (if cfg.reverseMode: "true" else: "false"),
    $cfg.delayMs]
  writeFile(CONFIG_FILE, cfgText & "\n")

# ── Поток определения клавиатуры ─────────────────────────────────────────────

proc pthread_cancel*(thread: Pthread): cint
    {.importc: "pthread_cancel", header: "<pthread.h>".}

proc kbdDetectFn*(argPtr: pointer) {.thread.} =
  ## Определяет клавиатуру по нажатию Enter: ждёт до ~57 секунд.
  ## O_NONBLOCK обязателен: блокирующий read() зависает на устройствах,
  ## которые не генерируют событий (мышь, джойстик и т.д.).
  let arg = cast[ptr KbdDetectArgSafe](argPtr)
  let fd  = open(cstring(arg.path), O_RDONLY or O_NONBLOCK)
  if fd == -1: return
  var
    ie: InputEvent
    i  = 0
  while i < 5700:
    if read(fd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == 1 and
         (ie.code == KEY_ENTER or ie.code == KEY_KPENTER) and
         ie.value in [0'i32, 1, 2]:
        arg.active.store(true)
        break
    sleep(10)
    inc i
  discard close(fd)

# ── Интерактивная настройка ───────────────────────────────────────────────────

proc runConfig*() =
  ## Проводит пользователя через интерактивную настройку:
  ##   1. Автоопределение клавиатуры.
  ##   2. Захват клавиши/комбинации переключения раскладки.
  ##   3. Захват клавиши коррекции текста.
  ## Сохраняет результат в CONFIG_FILE.
  logMsg(false, "Запуск настройки клавиатуры WaylandSwitcher.")

  # Читаем существующий конфиг для сохранения второстепенных полей
  var partial = AppConfig(
    mousePath:   "/dev/input/mice",
    reverseMode: false,
    delayMs:     10)
  if fileExists(CONFIG_FILE):
    logMsg(false, "Читаем существующий конфиг...", stdOnly = true)
    try:
      let existing = loadConfig(CONFIG_FILE)
      partial.mousePath   = existing.mousePath
      partial.reverseMode = existing.reverseMode
      partial.delayMs     = existing.delayMs
    except ConfigError:
      discard  # конфиг повреждён — продолжаем с дефолтами

  try: createDir(parentDir(CONFIG_FILE))
  except CatchableError as e:
    logMsg(true, "Не удалось создать директорию: " & e.msg); quit(1)

  # ── Шаг 1: определение клавиатуры ─────────────────────────────────────────
  logMsg(false, "")
  logMsg(false, "WaylandSwitcher попытается автоматически определить клавиатуру.")
  sleep(100)

  var kbdList: seq[KbdDetectArgSafe]
  for kind, path in walkDir(INPUT_DEVICES_DIR):
    if kind != pcFile: continue
    if not startsWith(extractFilename(path), "event"): continue
    let fd = open(cstring(path), O_RDONLY or O_NONBLOCK)
    if fd == -1: continue
    discard close(fd)
    kbdList.add(KbdDetectArgSafe(path: path))

  if len(kbdList) == 0:
    logMsg(true, "Устройства ввода не найдены. Нужны права root?"); quit(1)

  var
    tids = newSeq[Pthread](len(kbdList))
    attr: PthreadAttr
  discard pthread_attr_init(addr attr)
  for i in 0 ..< len(kbdList):
    discard pthread_create(addr tids[i], addr attr,
      cast[proc(p: pointer): pointer {.noconv.}](kbdDetectFn),
      addr kbdList[i])
  discard pthread_attr_destroy(addr attr)

  logMsg(false, "Нажмите ENTER...")
  discard readLine(stdin)

  var keyboardPath = ""
  for _ in 0..600:
    sleep(100)
    for i in 0 ..< kbdList.len:
      if kbdList[i].active.load():
        keyboardPath = kbdList[i].path
        break
    if keyboardPath != "": break
  for tid in tids:
    discard pthread_cancel(tid)
  for tid in tids:
    var rv: pointer
    discard pthread_join(tid, addr rv)

  if keyboardPath == "":
    logMsg(true, "Не удалось перехватить нажатие. Нужны права root?"); quit(1)
  logMsg(false, "Клавиатура найдена: " & keyboardPath)
  sleep(500)

  # ── Открытие клавиатуры для захвата клавиш ────────────────────────────────
  var kfd = open(cstring(keyboardPath), O_RDONLY or O_SYNC)
  if kfd == -1:
    logMsg(true, "Ошибка открытия клавиатуры: " & $strerror(errno)); quit(1)

  # ── Шаг 2: захват клавиши переключения раскладки ──────────────────────────
  logMsg(false, "")
  logMsg(false, "Нажмите клавишу (или комбинацию), которая переключает раскладку.")
  logMsg(false, "Ожидание нажатия...")

  ## Эвристика определения одной клавиши / комбинации:
  ##   Читаем два события EV_KEY (value 0 или 1).
  ##   Если второе — key-up (value 0): нажата одна клавиша (down + up).
  ##   Если key-down (value 1): удерживается первая, нажата вторая → комбинация.
  ## Ограничение: не работает с тремя и более клавишами, нестандартным порядком
  ## отпускания (down A, down B, up A, up B) или «sticky keys».
  var
    rawKeys:   seq[uint16]
    lastValue: int32 = -1
    i = 0
  while i < 6000:
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == EV_KEY and ie.value in [0'i32, 1]:
        rawKeys.add(ie.code)
        lastValue = ie.value
        if len(rawKeys) == 2: break
    sleep(10)
    inc i

  var
    keysLs:    seq[uint16]
    strKeysLs: string
  if len(rawKeys) == 0:
    logMsg(true, "Ошибка чтения клавиатуры (таймаут).")
    discard close(kfd); quit(1)
  elif len(rawKeys) == 1 or (len(rawKeys) == 2 and lastValue == 0):
    # Одна клавиша: получили одно событие или второе — это up той же клавиши
    keysLs    = @[rawKeys[0]]
    strKeysLs = $rawKeys[0]
    logMsg(false, "Захвачена клавиша: " & keyNameSafe(rawKeys[0]))
  else:
    # Комбинация: второе событие — down другой клавиши
    keysLs    = @[rawKeys[0], rawKeys[1]]
    strKeysLs = $rawKeys[0] & "+" & $rawKeys[1]
    logMsg(false, "Захвачена комбинация: " &
           keyNameSafe(rawKeys[0]) & "+" & keyNameSafe(rawKeys[1]))

  # Переоткрываем клавиатуру, чтобы сбросить накопленные события
  sleep(500)
  discard close(kfd)
  kfd = open(cstring(keyboardPath), O_RDONLY or O_SYNC)
  if kfd == -1:
    logMsg(true, "Ошибка повторного открытия клавиатуры: " & $strerror(errno))
    quit(1)

  # ── Шаг 3: захват клавиши коррекции текста ────────────────────────────────
  logMsg(false, "")
  logMsg(false, "Нажмите клавишу для коррекции введённого текста.")
  logMsg(false, "Ожидание нажатия...")
  var keyRpl: uint16 = 0
  i = 0
  while i < 6000:
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == EV_KEY and ie.value == 1:
        keyRpl = ie.code; break
    sleep(10)
    inc i
  discard close(kfd)

  if keyRpl == 0:
    logMsg(true, "Ошибка чтения клавиатуры (таймаут)."); quit(1)
  logMsg(false, "Захвачена клавиша: " & keyNameSafe(keyRpl))
  sleep(500)

  # ── Запись результата ──────────────────────────────────────────────────────
  logMsg(false, "Запись конфигурационного файла...")
  let cfg = AppConfig(
    kbdPath:     keyboardPath,
    mousePath:   partial.mousePath,
    keysLs:      keysLs,
    strKeysLs:   strKeysLs,
    keyRpl:      keyRpl,
    reverseMode: partial.reverseMode,
    delayMs:     partial.delayMs)
  try:
    saveConfig(cfg)
    logMsg(false, "Конфигурация сохранена.")
    logMsg(false, "Файл конфигурации: " & CONFIG_FILE)
  except CatchableError as e:
    logMsg(true, "Ошибка записи конфига: " & e.msg)

# ── Установка/удаление systemd-юнита ─────────────────────────────────────────

proc shellEscape(s: string): string =
  ## Оборачивает строку в одинарные кавычки для безопасного использования
  ## в shell и поле ExecStart юнита systemd (пробелы в пути не сломают файл).
  ## Внутренние одинарные кавычки заменяются на '\'' (close-quote, backslash-quote, open-quote).
  "'" & replace(s, "'", "'\\''") & "'"

proc runInstall*() =
  ## Создаёт systemd-юнит /lib/systemd/system/wayland-switcher.service.
  ## После записи выводит инструкции для активации.
  logMsg(false, "Установка демона WaylandSwitcher...")
  let execPath = shellEscape(getAppFilename())
  let unitContent = """
[Unit]
Description=WaylandSwitcher - keyboard layout switcher
Documentation=https://github.com/Balans097/WaylandSwitcher
Requires=local-fs.target
After=local-fs.target
StartLimitIntervalSec=10
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$1 -r
Restart=on-failure
RestartSec=3
# Базовый hardening для службы, работающей с правами root:
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/wayland-switcher
NoNewPrivileges=true
# Раскомментируйте и создайте пользователя для запуска без root:
# User=wayland-switcher
# Group=input

[Install]
WantedBy=multi-user.target
""".strip() % [execPath]

  try:
    writeFile(SYSTEMD_UNIT_FILE, unitContent & "\n")
    logMsg(false, "Демон WaylandSwitcher успешно установлен, версия: " & VERSION)
    logMsg(false, "Для активации выполните:")
    logMsg(false, "  systemctl daemon-reload")
    logMsg(false, "  systemctl enable --now wayland-switcher")
  except CatchableError as e:
    logMsg(true, "Ошибка создания systemd unit-файла: " & e.msg & ". Нужны права root?")

proc runUninstall*() =
  ## Удаляет systemd-юнит. Выводит напоминание о daemon-reload.
  logMsg(false, "Удаление демона WaylandSwitcher...")
  if fileExists(SYSTEMD_UNIT_FILE):
    try:
      removeFile(SYSTEMD_UNIT_FILE)
      logMsg(false, "Демон WaylandSwitcher успешно удалён.")
      logMsg(false, "Выполните 'systemctl daemon-reload' для применения изменений.")
    except CatchableError as e:
      logMsg(true, "Ошибка удаления " & SYSTEMD_UNIT_FILE & ": " & e.msg &
             ". Нужны права root?")
  else:
    logMsg(true, "Нечего удалять: unit-файл не найден: " & SYSTEMD_UNIT_FILE)
