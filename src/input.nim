## input.nim — обработка буфера нажатий клавиш и виртуальная клавиатура uinput.
##
## Объединяет бывшие buffer.nim и vkbd.nim: оба модуля работают с одним
## и тем же seq[InputEvent] и тесно взаимодействуют через emitEvents.
##
## ── Буфер (buffer) ───────────────────────────────────────────────────────────
##
##   Буфер — seq[InputEvent], накапливающий события клавиш текущей «порции»
##   набранного текста. Он принадлежит исключительно главному потоку,
##   синхронизация не требуется.
##
##   Жизненный цикл:
##     • Каждый key-down/key-up из Letters/Shifts/keyRpl добавляется в буфер.
##     • BufKillers (Tab, Ctrl, Alt, …) сбрасывают буфер в @[].
##     • Поток мыши устанавливает needClearKeyBuf → главный цикл тоже сбрасывает.
##     • getBufferAction анализирует хвост буфера и решает, что делать.
##     • prepareBuffer «чистит» буфер, убирая служебные события.
##     • emitEvents отправляет результат в виртуальную клавиатуру.
##
## ── Виртуальная клавиатура (vkbd) ───────────────────────────────────────────
##
##   Используется Linux uinput (/dev/uinput). Процедура openVKbd регистрирует
##   виртуальное устройство, emitEvents посылает туда пары [InputEvent + SYN].

import posix, os, osproc, strutils, unicode, std/tables
import types, core

# ── Привязки к libc ───────────────────────────────────────────────────────────

proc c_ioctl(fd: cint; req: culong; arg: pointer): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc c_clock_gettime(clk: cint; tp: pointer): cint
    {.importc: "clock_gettime", header: "<time.h>".}

type CFile = pointer

proc popen(cmd, mode: cstring): CFile
    {.importc: "popen", header: "<stdio.h>".}

proc fputs(s: cstring; stream: CFile): cint
    {.importc: "fputs", header: "<stdio.h>".}

proc pclose(stream: CFile): cint
    {.importc: "pclose", header: "<stdio.h>".}

proc execl(path: cstring; arg0: cstring): cint
    {.importc: "execl", header: "<unistd.h>", varargs.}
  ## execl заменяет образ текущего процесса. Первый аргумент — путь к
  ## исполняемому файлу; далее — argv[0], argv[1], …, nil (sentinel).
  ## При успехе не возвращается. Возвращает -1 при ошибке.

proc exitnow(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  ## _exit завершает процесс немедленно, минуя деструкторы C++ и fflush —
  ## обязателен в дочернем процессе после fork, чтобы не сбросить буферы
  ## родителя (особенно важно для stdio).

proc dup2(oldfd, newfd: cint): cint
    {.importc: "dup2", header: "<unistd.h>".}
  ## Дублирует файловый дескриптор oldfd в newfd. Если newfd уже открыт —
  ## закрывает его. Используется для перенаправления stdin/stdout/stderr.

# ── Тип ошибки виртуальной клавиатуры ────────────────────────────────────────

type VKbdError* = object of CatchableError

# ── Анализ буфера ─────────────────────────────────────────────────────────────

proc getBufferAction*(keyBuf: seq[InputEvent]; keyRpl: uint16): BufferAction =
  ## Анализирует хвост буфера и возвращает действие:
  ##   KeepBuffer  — паттерн не распознан, продолжаем накапливать.
  ##   ReplaceWord — нажат keyRpl (±Shift перед ним).
  ##   ReplaceAll  — нажата комбинация Shift+keyRpl+Shift (shiftD rpLD shiftU rplU).
  let last = len(keyBuf) - 1
  if len(keyBuf) < 2:
    return KeepBuffer

  if len(keyBuf) < 4:
    # Минимальный паттерн: rplD rplU → ReplaceWord
    return if keyBuf[last].code == keyRpl    and keyBuf[last].value == 0 and
              keyBuf[last-1].code == keyRpl  and keyBuf[last-1].value == 1:
             ReplaceWord
           else:
             KeepBuffer

  # Полная комбинация: shiftD rplD shiftU rplU → ReplaceAll
  if keyBuf[last].code == keyRpl    and keyBuf[last].value == 0   and
     keyBuf[last-1].code in Shifts  and keyBuf[last-1].value == 0 and
     keyBuf[last-2].code == keyRpl  and keyBuf[last-2].value == 1 and
     keyBuf[last-3].code in Shifts  and keyBuf[last-3].value == 1:
    return ReplaceAll

  # Альтернатива: shiftD rplD rplU → ReplaceAll; rplD rplU → ReplaceWord
  if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0 and
     keyBuf[last-1].code == keyRpl and keyBuf[last-1].value == 1:
    return if keyBuf[last-2].code in Shifts and keyBuf[last-2].value == 1:
             ReplaceAll
           else:
             ReplaceWord

  return KeepBuffer

proc getBufferStr*(keyBuf: seq[InputEvent]): string =
  ## Возвращает читаемое представление буфера для отладочного вывода.
  for ev in keyBuf:
    result.add(keyNameSafe(ev.code) & " " & KeyAction[ev.value] & "; ")

proc prepareBuffer*(keyBuf: var seq[InputEvent]; keyRpl: uint16) =
  ## Убирает служебные события из буфера, оставляя «чистую» последовательность
  ## нажатий для повтора в новой раскладке. Этапы очистки:
  ##   1. Удаление хвостовых событий replace-key (и shift перед ними).
  ##   2. Усечение до текста после последнего Enter (только последняя строка).
  ##   3. Удаление смежных пар Shift+Shift (артефакты переключения раскладки).
  ##   4. Применение Backspace: каждый BS удаляет предыдущий символ из буфера.
  var buf  = keyBuf
  var last = len(buf) - 1
  keyBuf = @[]

  # ── Этап 1: срезаем хвостовые служебные события ───────────────────────────
  if last >= 3 and buf[last].code == keyRpl    and buf[last].value == 0   and
     buf[last-1].code in Shifts               and buf[last-1].value == 0 and
     buf[last-2].code == keyRpl               and buf[last-2].value == 1 and
     buf[last-3].code in Shifts               and buf[last-3].value == 1:
    last -= 4
  elif last >= 1 and buf[last].code == keyRpl  and buf[last].value == 0 and
       buf[last-1].code == keyRpl              and buf[last-1].value == 1:
    last -= (if last >= 2 and buf[last-2].code in Shifts and
                buf[last-2].value == 1: 3 else: 2)
  buf = buf[0..last]

  # ── Этап 2: оставляем только последнюю строку ─────────────────────────────
  var res: seq[InputEvent]
  for idx, ev in buf:
    if (ev.code == KEY_ENTER or ev.code == KEY_KPENTER) and ev.value == 0 and
       idx != len(buf) - 1:
      res = @[]   # встретили Enter не в конце — сбрасываем накопленное
    else:
      res.add(ev)
  buf = res
  res = @[]

  # ── Этап 3: убираем смежные пары Shift+Shift ──────────────────────────────
  for ev in buf:
    if ev.code in Shifts and len(res) > 0 and res[^1].code in Shifts:
      discard res.pop()
    else:
      res.add(ev)
  buf = res
  res = @[]

  # ── Этап 4: применяем Backspace ───────────────────────────────────────────
  # Каждый BS удаляет предыдущую запись; если перед ней был Shift, двигаем
  # его на позицию удалённого символа (сохраняем информацию о регистре).
  for ev in buf:
    if ev.code == KEY_BACKSPACE:
      if len(res) == 0: continue
      discard res.pop()
      if len(res) > 0 and res[^1].code in Shifts:
        if len(res) >= 2: res[^2] = res[^1]
        discard res.pop()
    else:
      res.add(ev)
  keyBuf = res

# ── Виртуальная клавиатура ────────────────────────────────────────────────────

proc openVKbd*(): cint =
  ## Открывает /dev/uinput и регистрирует виртуальное устройство,
  ## поддерживающее все клавиши с кодами 0..248.
  ## Возвращает файловый дескриптор. Бросает VKbdError при неудаче.
  let vfd = open(cstring(UINPUT_FILE), O_WRONLY or O_SYNC)
  if vfd == -1:
    raise newException(VKbdError,
      "Не удалось открыть " & UINPUT_FILE & ": " & $strerror(errno))

  var ioRes: cint
  ioRes += c_ioctl(vfd, culong(UI_SET_EVBIT),  cast[pointer](int(EV_SYN)))
  ioRes += c_ioctl(vfd, culong(UI_SET_EVBIT),  cast[pointer](int(EV_KEY)))
  for i in 0..248:
    ioRes += c_ioctl(vfd, culong(UI_SET_KEYBIT), cast[pointer](i))

  var vs: UInputSetup
  vs.id.bustype = BUS_USB
  vs.id.vendor  = 0x0777
  vs.id.product = 0x0777
  fillName(vs.name, "WaylandSwitcher virtual input device")
  ioRes += c_ioctl(vfd, culong(UI_DEV_SETUP),  addr vs)
  ioRes += c_ioctl(vfd, culong(UI_DEV_CREATE), nil)

  if ioRes != 0:
    discard close(vfd)
    raise newException(VKbdError,
      "Ошибка настройки виртуальной клавиатуры: " & $strerror(errno))

  return vfd


proc closeVKbd*(vfd: cint) =
  ## Уничтожает виртуальное устройство и закрывает дескриптор uinput.
  discard c_ioctl(vfd, culong(UI_DEV_DESTROY), nil)
  discard close(vfd)

# ── Буфер обмена ─────────────────────────────────────────────────────────────

proc getSessionEnv*(): tuple[user: string; waylandDisplay: string; xdgRuntime: string; display: string] =
  ## Определяет параметры графической сессии активного (не-root) пользователя.
  ## Читает /proc/*/environ чтобы найти процесс с WAYLAND_DISPLAY или DISPLAY,
  ## принадлежащий реальному пользователю.
  result = (user: "", waylandDisplay: "", xdgRuntime: "", display: "")
  try:
    for kind, path in walkDir("/proc"):
      if kind != pcDir: continue
      let base = path.splitPath.tail
      var isNum = true
      for c in base:
        if c notin {'0'..'9'}: isNum = false; break
      if not isNum: continue
      let envFile = path / "environ"
      if not fileExists(envFile): continue
      try:
        # /proc/PID/environ разделён нулевыми байтами
        let raw = readFile(envFile)
        var env: seq[string] = @[]
        for part in raw.split(char(0)):
          if part.len > 0: env.add(part)
        var wd, xdg, disp, user2: string
        for e in env:
          if e.startsWith("WAYLAND_DISPLAY="):  wd    = e[16..^1]
          elif e.startsWith("XDG_RUNTIME_DIR="): xdg   = e[16..^1]
          elif e.startsWith("DISPLAY="):         disp  = e[8..^1]
          elif e.startsWith("USER="):            user2 = e[5..^1]
        # Интересует только процесс реального пользователя (не root, не системные)
        if user2 != "" and user2 != "root" and (wd != "" or disp != "") and xdg != "":
          result = (user: user2, waylandDisplay: wd, xdgRuntime: xdg, display: disp)
          return
      except CatchableError:
        continue
  except CatchableError:
    discard

proc buildEnvPrefix*(env: tuple[user, waylandDisplay, xdgRuntime, display: string]): string =
  ## Формирует префикс для shell-команд вида:
  ##   WAYLAND_DISPLAY=... XDG_RUNTIME_DIR=... su -c '...' USER
  ## Если пользователь не определён — возвращает пустую строку.
  if env.user == "": return ""
  result = ""
  if env.waylandDisplay != "":
    result &= "WAYLAND_DISPLAY=" & env.waylandDisplay & " "
  if env.xdgRuntime != "":
    result &= "XDG_RUNTIME_DIR=" & env.xdgRuntime & " "
  if env.display != "":
    result &= "DISPLAY=" & env.display & " "

proc detectClipboardTool*(): ClipboardTool =
  ## Автоматически определяет доступный инструмент буфера обмена.
  ## Проверяет наличие wl-paste, xclip, xsel в PATH (в порядке приоритета).
  if execShellCmd("command -v wl-paste >/dev/null 2>&1") == 0:
    return ClipWayland
  if execShellCmd("command -v xclip >/dev/null 2>&1") == 0:
    return ClipXclip
  if execShellCmd("command -v xsel >/dev/null 2>&1") == 0:
    return ClipXsel
  return ClipAuto  ## не найдено — функция недоступна

proc runAsUser*(env: tuple[user, waylandDisplay, xdgRuntime, display: string];
                innerCmd: string): tuple[output: string; code: int] =
  ## Выполняет команду от имени пользователя сессии с нужным окружением.
  let prefix = buildEnvPrefix(env)
  let cmd =
    if env.user != "" and env.user != "root":
      prefix & "su -c '" & innerCmd & "' " & env.user & " 2>/dev/null"
    else:
      prefix & innerCmd & " 2>/dev/null"
  logMsg(false, "run cmd: " & cmd, stdOnly = true)
  let (outp, code) = execCmdEx(cmd)
  (output: outp, code: int(code))

proc readPrimarySelection*(tool: ClipboardTool): string =
  ## Читает PRIMARY SELECTION — буфер, который Wayland/X11 заполняет
  ## автоматически при выделении текста, без нажатия Ctrl+C.
  ## Это ключевое отличие от clipboard (Ctrl+C/V).
  if tool == ClipAuto: return ""
  let env = getSessionEnv()
  logMsg(false, "primary sel env: user=" & env.user &
         " WAYLAND_DISPLAY=" & env.waylandDisplay, stdOnly = true)
  let innerCmd =
    case tool
    of ClipWayland: "wl-paste --no-newline --primary"
    of ClipXclip:   "xclip -selection primary -o"
    of ClipXsel:    "xsel --primary --output"
    of ClipAuto:    return ""
  let (outp, code) = runAsUser(env, innerCmd)
  logMsg(false, "primary read code=" & $code & " len=" & $outp.len, stdOnly = true)
  if code == 0: outp else: ""

proc readClipboard*(tool: ClipboardTool): string =
  ## Читает CLIPBOARD буфер (Ctrl+C).
  if tool == ClipAuto: return ""
  let env = getSessionEnv()
  let innerCmd =
    case tool
    of ClipWayland: "wl-paste --no-newline"
    of ClipXclip:   "xclip -selection clipboard -o"
    of ClipXsel:    "xsel --clipboard --output"
    of ClipAuto:    return ""
  let (outp, code) = runAsUser(env, innerCmd)
  logMsg(false, "clipboard read code=" & $code & " len=" & $outp.len, stdOnly = true)
  if code == 0: outp else: ""

proc writeClipboard*(tool: ClipboardTool; text: string) =
  ## Записывает text в CLIPBOARD через временный файл + двойной fork без waitpid.
  ##
  ## Почему не execCmdEx:
  ##   wl-copy/xclip/xsel демонизируются и живут в фоне, обслуживая запросы
  ##   вставки. execCmdEx вызывает waitpid и ждёт завершения ВСЕГО дерева
  ##   процессов — в том числе демонизированного clipboard-сервера. Это
  ##   приводит к зависанию на неопределённое время.
  ##
  ##   Предыдущий обходной путь — 'su -c "setsid sh ... &"' — тоже не помогал:
  ##   амперсанд фонит только внутри sub-shell порождённого su, но сам su
  ##   всё равно ждёт завершения своего дочернего процесса.
  ##
  ## Решение — двойной fork (классический Unix-демон):
  ##   1. Первый fork: родитель делает waitpid только за промежуточным
  ##      child-1, который тут же завершается. Никакого зависания.
  ##   2. child-1 вызывает setsid() и делает второй fork.
  ##   3. child-2 (внук) отвязан от сессии, перенаправляет stdio в /dev/null
  ##      и запускает sh -c "...". Его усыновляет init (PID 1) после
  ##      завершения child-1 — родитель его никогда не ждёт.
  ##   После waitpid(child-1) родитель немедленно возвращается.
  ##
  ## tmpFile удаляется изнутри shell-команды (после чтения инструментом),
  ## чтобы не возникало гонки: файл должен существовать пока wl-copy его читает.
  if tool == ClipAuto: return
  let env = getSessionEnv()
  let innerCmd =
    case tool
    of ClipWayland: "wl-copy"
    of ClipXclip:   "xclip -selection clipboard"
    of ClipXsel:    "xsel --clipboard --input"
    of ClipAuto:    return

  # Пишем текст во временный файл, чтобы избежать проблем с экранированием
  # спецсимволов при передаче через аргументы shell.
  let tmpFile = "/tmp/.ws_clip_" & $getpid()
  try:
    writeFile(tmpFile, text)
  except CatchableError as e:
    logMsg(false, "clipboard write: не удалось создать tmpfile: " & e.msg, stdOnly = true)
    return

  # Shell-команда для внука: читает файл, отдаёт инструменту, удаляет файл.
  # rm сработает строго после того, как инструмент дочитает stdin.
  let bgPayload = "cat " & tmpFile & " | " & innerCmd & "; rm -f " & tmpFile

  # Если мы root, а сессия принадлежит другому пользователю — оборачиваем
  # через su -s /bin/sh, чтобы wl-copy имел доступ к wayland-сокету
  # пользователя. Переменные окружения прописываем явно: su сбрасывает их.
  let shellCmd =
    if env.user != "" and env.user != "root":
      buildEnvPrefix(env) & "su -s /bin/sh -c '" & bgPayload & "' " & env.user
    else:
      buildEnvPrefix(env) & "sh -c '" & bgPayload & "'"

  logMsg(false, "clipboard write cmd (grandchild): " & shellCmd, stdOnly = true)

  # ── Двойной fork ─────────────────────────────────────────────────────────
  let child1 = fork()
  if child1 < 0:
    logMsg(false, "clipboard write: fork() failed", stdOnly = true)
    return

  if child1 == 0:
    # child-1: создаём новую сессию и сразу порождаем внука.
    discard setsid()
    let child2 = fork()
    if child2 < 0:
      exitnow(1)
    if child2 == 0:
      # child-2 (внук): перенаправляем stdio в /dev/null и вызываем exec.
      let devNull = open("/dev/null", O_RDWR)
      if devNull >= 0:
        discard dup2(devNull, 0)
        discard dup2(devNull, 1)
        discard dup2(devNull, 2)
        if devNull > 2: discard close(devNull)
      discard execl("/bin/sh", "sh", "-c", cstring(shellCmd), nil)
      exitnow(127)   # exec не удался
    # child-1 завершается немедленно → внук усыновляется init.
    exitnow(0)

  # Родитель: ждём только child-1 (завершается мгновенно).
  var wstatus: cint = 0
  discard waitpid(child1, wstatus, 0)
  logMsg(false, "clipboard write: grandchild launched", stdOnly = true)

  # Пауза, чтобы внук успел запустить sh и wl-copy объявил себя
  # владельцем CLIPBOARD до перехода к следующему шагу (Ctrl+V).
  sleep(150)

# ── Перекодировка текста между раскладками (EN QWERTY ↔ RU ЙЦУКЕН) ──────────
#
# Зачем это нужно:
#   В обычном режиме (emitEvents) у нас есть СКАН-КОДЫ нажатых клавиш — после
#   переключения системной раскладки повтор тех же скан-кодов через uinput
#   автоматически даёт верный символ, независимо от направления EN↔RU.
#
#   Для текста, выделенного мышью или Shift+стрелками, скан-кодов нет — есть
#   только готовая строка символов, прочитанная из CLIPBOARD. Чтобы получить
#   тот же эффект («тот же физический ряд клавиш, но в другой раскладке»),
#   нужно посимвольно сопоставить каждый символ его «соседом» по позиции
#   клавиши в другой раскладке — это и делает таблица ниже (классический
#   принцип Punto Switcher: ЙЦУКЕН и QWERTY расположены на одних и тех же
#   физических клавишах).

const
  ## Нижний регистр: EN QWERTY → RU ЙЦУКЕН, по позициям клавиш.
  ## Используем массив пар вместо table-literal, чтобы не зависеть от
  ## тонких граней синтаксиса char-литералов вроде '{' / '"' внутри
  ## конструктора таблицы — здесь каждая пара читается однозначно.
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

proc buildLowerUpper(pairs: openArray[(char, string)]): Table[char, string] =
  result = initTable[char, string]()
  for (k, v) in pairs:
    result[k] = v

let
  EnToRuLower = buildLowerUpper(EnToRuLowerPairs)
  EnToRuUpper = buildLowerUpper(EnToRuUpperPairs)

proc buildRuToEn(enToRu: Table[char, string]): Table[string, char] =
  ## Строит обратную таблицу RU → EN из прямой таблицы EN → RU.
  result = initTable[string, char]()
  for k, v in enToRu:
    result[v] = k

let
  RuToEnLower = buildRuToEn(EnToRuLower)
  RuToEnUpper = buildRuToEn(EnToRuUpper)

proc detectDirection(text: string): bool =
  ## Возвращает true, если в тексте больше латинских букв (значит текст
  ## набран в EN-раскладке и нужно конвертировать EN → RU), false — если
  ## больше кириллических букв (нужно RU → EN). При равенстве/отсутствии
  ## букв по умолчанию считаем, что текст EN (true).
  var enCount, ruCount: int
  for r in runes(text):
    let cp = int(r)
    if (cp >= int('a') and cp <= int('z')) or (cp >= int('A') and cp <= int('Z')):
      inc enCount
    elif cp >= 0x0400 and cp <= 0x04FF:   ## диапазон кириллицы Unicode
      inc ruCount
  if ruCount > enCount: false else: true

proc convertLayout*(text: string): string =
  ## Перекодирует строку между EN(QWERTY) и RU(ЙЦУКЕН) по позициям клавиш.
  ## Направление определяется автоматически по преобладающим символам.
  ## Работает через руны (а не байты), так как кириллица в UTF-8 — это
  ## многобайтовые символы.
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

proc emitSelectionCorrection*(vfd: cint; keysLs: seq[uint16];
                               clipTool: ClipboardTool; delayMs: int;
                               selLen: int) =
  ## Корректирует выделенный текст в другой раскладке клавиатуры.
  ##
  ## Алгоритм:
  ##   1. Ctrl+C — копируем выделение в CLIPBOARD.
  ##      Почему не PRIMARY: GTK4 (gnome-text-editor и другие современные
  ##      приложения) не реализует PRIMARY selection на Wayland. Разработчики
  ##      GNOME намеренно отказались от него как от «X11-концепции».
  ##      wl-paste --primary всегда возвращает устаревшее значение.
  ##      Ctrl+C через uinput работает надёжно: уинпут-устройство получает
  ##      фокус ввода наравне с физической клавиатурой.
  ##   2. Читаем CLIPBOARD через wl-paste (без --primary).
  ##   3. Переключаем раскладку.
  ##   4. Записываем скорректированный текст обратно в CLIPBOARD через wl-copy.
  ##   5. Delete удаляет выделение (оно ещё активно — Ctrl+C его не снимает).
  ##   6. Ctrl+V вставляет скорректированный текст.

  let actualTool =
    if clipTool == ClipAuto: detectClipboardTool()
    else: clipTool

  var t: MyTimeVal
  discard c_clock_gettime(0, addr t)
  t.tv_usec = 0

  proc sendKey(evType: uint16; code: uint16; value: int32) =
    var pair: array[2, InputEvent]
    pair[0] = InputEvent(ie_type: evType, code: code, value: value, time: t)
    pair[1] = InputEvent(ie_type: EV_SYN, code: SYN_REPORT, value: 0,
                         time: MyTimeVal(tv_sec: t.tv_sec, tv_usec: t.tv_usec + 100))
    discard write(vfd, addr pair[0], sizeof(InputEvent) * 2)
    logMsg(false, "sel-output " & keyNameSafe(code) & " " & KeyAction[int(value)],
           stdOnly = true)
    sleep(delayMs)
    t.tv_usec += 200

  ## Новый порядок шагов:
  ##   1. Переключаем раскладку — ДО Ctrl+C, чтобы выделение не сбросилось.
  ##      RCtrl сам по себе не снимает выделение в GTK4.
  ##   2. Ctrl+C — копируем выделенный (неисправленный) текст в CLIPBOARD.
  ##   3. Читаем CLIPBOARD — получаем исходный текст в неправильной раскладке.
  ##   4. Переключаем исходный текст в правильную раскладку программно
  ##      (через таблицу keymap: каждый scancode → символ в новой раскладке).
  ##      НО это сложно — проще просто сохранить текст и не трогать раскладку
  ##      здесь, а переключить уже ПОСЛЕ чтения.
  ##
  ## Упрощённый рабочий порядок:
  ##   1. Ctrl+C (копируем выделение в CLIPBOARD, выделение остаётся)
  ##   2. Читаем CLIPBOARD
  ##   3. Переключаем раскладку
  ##   4. Пишем текст в CLIPBOARD через wl-copy
  ##   5. Delete (удаляем выделение — оно всё ещё активно)
  ##   6. Ctrl+V

  # ── Шаг 1: Ctrl+C ────────────────────────────────────────────────────────
  # Пауза перед Ctrl+C: даём compositor'у время полностью обработать
  # отпускание Pause и убедиться что фокус остался в целевом приложении.
  sleep(150)
  logMsg(false, "sel-correction: шаг 1 — Ctrl+C (копируем выделение)", stdOnly = true)
  sendKey(EV_KEY, KEY_LEFTCTRL, 1)
  sendKey(EV_KEY, KEY_C,        1)
  sendKey(EV_KEY, KEY_C,        0)
  sendKey(EV_KEY, KEY_LEFTCTRL, 0)
  # Пауза: GTK4 обрабатывает Ctrl+C асинхронно через Wayland-протокол.
  sleep(400)

  # ── Шаг 2: читаем CLIPBOARD ──────────────────────────────────────────────
  # ВАЖНО: раньше здесь сравнивался CLIPBOARD до и после Ctrl+C, и при
  # совпадении коррекция прерывалась как «Ctrl+C не сработал». Эта проверка
  # ошибочна: если пользователь выделяет и корректирует один и тот же текст
  # повторно (или просто новый выделенный текст совпал с тем, что уже было
  # в CLIPBOARD), содержимое буфера после Ctrl+C закономерно совпадает с
  # тем, что было до — это успешный случай, а не сбой. Сравнение удалено;
  # единственный надёжный признак отсутствия выделения — пустой CLIPBOARD.
  logMsg(false, "sel-correction: шаг 2 — читаем CLIPBOARD", stdOnly = true)
  var selText = readClipboard(actualTool)
  logMsg(false, "sel-correction: CLIPBOARD после Ctrl+C [" & selText & "]", stdOnly = true)
  # wl-paste --no-newline всё равно иногда отдаёт хвостовой \r\n/\n — это
  # не часть выделенного текста, а лишний символ конца строки, добавленный
  # инструментом буфера обмена (или приложением при копировании выделения,
  # заканчивающегося на конце строки). Срезаем его, иначе он попадёт
  # в скорректированный текст и будет виден как лишний перевод строки
  # после вставки. Внутренние переводы строк (настоящий многострочный
  # текст) не трогаем — убираем только хвостовые.
  selText = selText.strip(leading = false, chars = {'\r', '\n'})
  if selText == "":
    logMsg(false, "sel-correction: clipboard пуст после Ctrl+C — прерываем", stdOnly = true)
    return
  logMsg(false, "sel-correction: прочитано " & $len(selText) &
         " символов: [" & selText & "]", stdOnly = true)

  # ── Шаг 3: переключаем раскладку ─────────────────────────────────────────
  logMsg(false, "sel-correction: шаг 3 — переключение раскладки", stdOnly = true)
  sendKey(EV_KEY, keysLs[0], 1)
  if len(keysLs) == 2:
    sendKey(EV_KEY, keysLs[1], 1)
    sendKey(EV_KEY, keysLs[1], 0)
  sendKey(EV_KEY, keysLs[0], 0)
  sleep(80)

  # ── Шаг 4: пишем скорректированный текст в CLIPBOARD ─────────────────────
  # Здесь и происходит сама коррекция: selText — это исходный текст,
  # набранный в неправильной раскладке, как он есть. convertLayout
  # перекодирует его посимвольно (по позициям клавиш EN QWERTY ↔
  # RU ЙЦУКЕН), получая тот текст, который должен был быть набран.
  # Раньше здесь записывался selText без изменений — именно поэтому
  # коррекция «работала» (доходила до конца, ничего не падало), но
  # видимый текст не менялся: переключалась только системная раскладка
  # на будущее, а уже введённый текст вставлялся обратно как есть.
  logMsg(false, "sel-correction: шаг 4 — записываем в CLIPBOARD", stdOnly = true)
  let correctedText = convertLayout(selText)
  logMsg(false, "sel-correction: скорректированный текст: [" & correctedText & "]",
         stdOnly = true)
  writeClipboard(actualTool, correctedText)
  sleep(300)

  # ── Шаг 5: Delete — удаляем выделение ────────────────────────────────────
  # Ctrl+C не снял выделение; Delete сотрёт именно его одной клавишей.
  logMsg(false, "sel-correction: шаг 5 — Delete (удаляем выделение)", stdOnly = true)
  sendKey(EV_KEY, KEY_DELETE, 1)
  sendKey(EV_KEY, KEY_DELETE, 0)
  sleep(50)

  # ── Шаг 6: Ctrl+V — вставляем ────────────────────────────────────────────
  logMsg(false, "sel-correction: шаг 6 — Ctrl+V", stdOnly = true)
  sendKey(EV_KEY, KEY_LEFTCTRL, 1)
  sendKey(EV_KEY, KEY_V,        1)
  sendKey(EV_KEY, KEY_V,        0)
  sendKey(EV_KEY, KEY_LEFTCTRL, 0)
  sleep(50)

  logMsg(false, "sel-correction: завершено", stdOnly = true)

proc emitEvents*(vfd: cint; keyBuf: seq[InputEvent];
                 keysLs: seq[uint16]; singleWord: bool; delayMs: int) =
  ## Отправляет в виртуальную клавиатуру три группы событий:
  ##   1. Backspace × N — стирает ровно столько символов, сколько в буфере
  ##      (считаются события с value 1 «down» и 2 «autorepeat», кроме Shift).
  ##   2. Комбинация переключения раскладки (один или два скан-кода из keysLs).
  ##   3. Повтор нажатий из буфера — воспроизводим текст в новой раскладке.
  ##
  ## singleWord=true → начинаем не с начала буфера, а с позиции после последнего
  ## пробела (заменяем только последнее слово, не всю фразу).
  ##
  ## Каждое событие отправляется парой [InputEvent, SYN_REPORT], после чего
  ## делается пауза delayMs мс, чтобы X/Wayland успел обработать событие.

  var t: MyTimeVal
  discard c_clock_gettime(0, addr t)
  t.tv_usec = 0   ## начинаем с целой секунды, смещения будем добавлять по 200 мкс

  # Определяем стартовую позицию в буфере: вся фраза или только последнее слово
  var startIdx = 0
  if singleWord:
    for n in 0 ..< len(keyBuf):
      if keyBuf[n].value == 0 and keyBuf[n].code == KEY_SPACE and
         n != len(keyBuf) - 1:
        startIdx = n + 1

  var ieBuf: seq[InputEvent]

  # Вспомогательный шаблон: добавляем событие в очередь, сдвигая метку времени
  template push(ev: InputEvent) =
    ieBuf.add(ev)
    t.tv_usec += 200

  # ── Группа 1: Backspace ──────────────────────────────────────────────────
  for n in startIdx ..< len(keyBuf):
    if keyBuf[n].value in [1'i32, 2] and keyBuf[n].code notin Shifts:
      push InputEvent(ie_type: EV_KEY, code: KEY_BACKSPACE, value: 1, time: t)
      push InputEvent(ie_type: EV_KEY, code: KEY_BACKSPACE, value: 0, time: t)

  # ── Группа 2: переключение раскладки ────────────────────────────────────
  push InputEvent(ie_type: EV_KEY, code: keysLs[0], value: 1, time: t)
  if len(keysLs) == 2:
    push InputEvent(ie_type: EV_KEY, code: keysLs[1], value: 1, time: t)
    push InputEvent(ie_type: EV_KEY, code: keysLs[1], value: 0, time: t)
  push InputEvent(ie_type: EV_KEY, code: keysLs[0], value: 0, time: t)

  # ── Группа 3: воспроизведение текста ────────────────────────────────────
  for n in startIdx ..< len(keyBuf):
    var ev = keyBuf[n]
    ev.time = t
    push ev

  # ── Отправка: каждое событие + SYN_REPORT ────────────────────────────────
  for ev in ieBuf:
    var pair: array[2, InputEvent]
    pair[0] = ev
    pair[1] = InputEvent(
      ie_type: EV_SYN,
      code:    SYN_REPORT,
      value:   0,
      time:    MyTimeVal(tv_sec: ev.time.tv_sec, tv_usec: ev.time.tv_usec + 100))
    discard write(vfd, addr pair[0], sizeof(InputEvent) * 2)
    logMsg(false, "output " & keyNameSafe(ev.code) & " " & KeyAction[ev.value],
           stdOnly = true)
    sleep(delayMs)
