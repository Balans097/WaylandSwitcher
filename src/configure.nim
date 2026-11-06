## configure.nim — интерактивная настройка (wayland-switcher -c).
##
## runConfig проводит пользователя через три шага:
##   1. автоопределение клавиатуры: на каждое устройство /dev/input/event*
##      запускается поток, ожидающий нажатия Enter;
##   2. захват клавиши (или сочетания из двух клавиш), переключающей раскладку;
##   3. захват клавиши коррекции.
## Результат записывается через config.saveConfig.

import posix, os, strutils, std/[atomics, typedthreads]
import types, core, config

type
  ## Аргумент потока определения клавиатуры. Поток взводит active при
  ## нажатии Enter на «своём» устройстве.
  KbdProbe = object
    path:   string
    active: Atomic[bool]

var
  ## Просит потоки определения клавиатуры завершиться.
  probeStop: Atomic[bool]

proc probeKeyboard(probe: ptr KbdProbe) {.thread.} =
  ## Ждёт нажатия Enter на устройстве probe.path. Открытие неблокирующее:
  ## блокирующий read() зависал бы на устройствах, не дающих событий.
  let fd = open(cstring(probe.path), O_RDONLY or O_NONBLOCK)
  if fd == -1: return
  var ie: InputEvent
  while not probeStop.load():
    if read(fd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.evType == EV_KEY and
         (ie.code == KEY_ENTER or ie.code == KEY_KPENTER) and
         ie.value in [0'i32, 1, 2]:
        probe.active.store(true)
        break
    sleep(10)
  discard close(fd)

proc openForCapture(path: string): cint =
  ## Открывает клавиатуру для захвата клавиш; при ошибке завершает программу.
  ## Неблокирующий режим нужен, чтобы ожидание нажатия имело таймаут.
  result = open(cstring(path), O_RDONLY or O_NONBLOCK)
  if result == -1:
    logMsg(true, "Ошибка открытия клавиатуры: " & $strerror(errno))
    quit(1)

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
    delayMs:     10,
    clipTool:    ClipAuto)
  if fileExists(CONFIG_FILE):
    logMsg(false, "Читаем существующий конфиг...", stdOnly = true)
    try:
      let existing = loadConfig(CONFIG_FILE)
      partial.mousePath   = existing.mousePath
      partial.reverseMode = existing.reverseMode
      partial.delayMs     = existing.delayMs
      partial.clipTool    = existing.clipTool
    except ConfigError:
      discard  # конфиг повреждён — продолжаем с дефолтами

  try: createDir(parentDir(CONFIG_FILE))
  except CatchableError as e:
    logMsg(true, "Не удалось создать директорию: " & e.msg); quit(1)

  # ── Шаг 1: определение клавиатуры ─────────────────────────────────────────
  logMsg(false, "")
  logMsg(false, "WaylandSwitcher попытается автоматически определить клавиатуру.")
  sleep(100)

  var kbdList: seq[KbdProbe]
  for kind, path in walkDir(INPUT_DEVICES_DIR):
    if kind != pcFile: continue
    if not startsWith(extractFilename(path), "event"): continue
    let fd = open(cstring(path), O_RDONLY or O_NONBLOCK)
    if fd == -1: continue
    discard close(fd)
    kbdList.add(KbdProbe(path: path))

  if len(kbdList) == 0:
    logMsg(true, "Устройства ввода не найдены. Нужны права root?"); quit(1)

  probeStop.store(false)
  var probeThreads = newSeq[Thread[ptr KbdProbe]](len(kbdList))
  for i in 0 ..< len(kbdList):
    createThread(probeThreads[i], probeKeyboard, addr kbdList[i])

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
  probeStop.store(true)
  for i in 0 ..< len(probeThreads):
    joinThread(probeThreads[i])

  if keyboardPath == "":
    logMsg(true, "Не удалось перехватить нажатие. Нужны права root?"); quit(1)
  logMsg(false, "Клавиатура найдена: " & keyboardPath)
  sleep(500)

  # ── Открытие клавиатуры для захвата клавиш ────────────────────────────────
  var kfd = openForCapture(keyboardPath)

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
      if ie.evType == EV_KEY and ie.value in [0'i32, 1]:
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
  kfd = openForCapture(keyboardPath)

  # ── Шаг 3: захват клавиши коррекции текста ────────────────────────────────
  logMsg(false, "")
  logMsg(false, "Нажмите клавишу для коррекции введённого текста.")
  logMsg(false, "Ожидание нажатия...")
  var keyRpl: uint16 = 0
  i = 0
  while i < 6000:
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.evType == EV_KEY and ie.value == 1:
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
    delayMs:     partial.delayMs,
    clipTool:    partial.clipTool)
  try:
    saveConfig(cfg)
    logMsg(false, "Конфигурация сохранена.")
    logMsg(false, "Файл конфигурации: " & CONFIG_FILE)
  except CatchableError as e:
    logMsg(true, "Ошибка записи конфига: " & e.msg)
