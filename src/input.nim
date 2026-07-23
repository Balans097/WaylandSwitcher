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

import
  posix,
  os,
  osproc,
  strutils,
  unicode,
  std/tables
import
  types,
  core

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
  ## Анализирует ХВОСТ буфера набранных клавиш и решает, что делать.
  ##
  ## Идея: пользователь набирает текст обычным образом, и при каждом
  ## нажатии Shift или keyRpl (клавиша коррекции, по умолчанию Pause)
  ## эта функция вызывается, чтобы проверить — не образовался ли в конце
  ## буфера один из двух распознаваемых паттернов:
  ##
  ##   ReplaceWord — просто keyRpl (down, затем up). Пользователь набрал
  ##     слово в неправильной раскладке и нажал клавишу коррекции без
  ##     модификаторов → нужно заменить только последнее слово (то, что
  ##     после последнего пробела).
  ##
  ##   ReplaceAll — Shift+keyRpl+Shift, в любом из двух порядков нажатия
  ##     модификатора относительно keyRpl:
  ##       shiftDown → keyRplDown → shiftUp → keyRplUp   (полный паттерн,
  ##         Shift отжат раньше keyRpl — проверяется первым блоком ниже)
  ##       shiftDown → keyRplDown → keyRplUp             (Shift всё ещё
  ##         зажат в момент отпускания keyRpl — альтернативный блок)
  ##     В обоих случаях имеется в виду «зажми Shift и нажми клавишу
  ##     коррекции» → нужно заменить ВСЮ фразу, а не только слово.
  ##
  ## KeepBuffer возвращается, когда ни один из паттернов не подошёл —
  ## вызывающий код просто продолжает накапливать события в буфер.
  ##
  ## Почему явно разбито по длине буфера (< 2, < 4, иначе): чтобы
  ## безопасно индексировать keyBuf[last-1]..[last-3] без выхода за
  ## границы массива — паттерн ReplaceAll требует минимум 4 события,
  ## ReplaceWord — минимум 2.
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
  ## нажатий, которую затем можно повторно «проиграть» через виртуальную
  ## клавиатуру в новой раскладке (см. emitEvents). Все 4 этапа выполняются
  ## строго по порядку, каждый следующий работает уже над результатом
  ## предыдущего:
  ##
  ##   1. Удаление хвостовых событий replace-key (keyRpl и, если был, Shift
  ##      перед ним) — это служебная комбинация, которая запустила анализ
  ##      буфера, а не часть набранного пользователем текста, поэтому она
  ##      не должна попасть в повторный ввод.
  ##   2. Усечение до текста после последнего Enter — если пользователь
  ##      перешёл на новую строку и продолжил печатать, заменять нужно
  ##      только последнюю (текущую) строку, а не всё, что было набрано
  ##      с начала буфера.
  ##   3. Удаление смежных пар Shift+Shift — артефакт переключения
  ##      раскладки клавишей-модификатором, который сам по себе ничего
  ##      не печатает, но успевает попасть в буфер как Shift down +
  ##      Shift up без буквы между ними.
  ##   4. Применение Backspace — если пользователь уже что-то стирал
  ##      внутри текущей «порции» текста, каждый Backspace в буфере должен
  ##      убрать соответствующий предыдущий символ ИЗ БУФЕРА (а не просто
  ##      остаться записанным как отдельное событие) — иначе при повторном
  ##      воспроизведении в новой раскладке Backspace сработает ещё раз,
  ##      впустую стирая уже стёртое.
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
  # Обрабатываем только key-DOWN Backspace (value == 1); парный key-up того
  # же физического нажатия пропускаем без действия (continue).
  #
  # ИСТОРИЯ ОШИБКИ (важно, чтобы не повторить снова): раньше действие по
  # удалению символа выполнялось на КАЖДОЕ вхождение KEY_BACKSPACE в
  # буфере — то есть дважды на одно физическое нажатие клавиши (отдельно
  # на down и отдельно на up), потому что buf хранит оба события Backspace
  # (KEY_BACKSPACE входит в Letters, поэтому оба попадают в keyBuf наравне
  # с буквами). Старая компенсирующая проверка «если после удаления
  # наверху стека остался голый Shift — сдвинуть и снять» срабатывала не
  # в том месте стека и не устраняла проблему: при вводе заглавной буквы
  # (Shift-down, буква-down, буква-up, Shift-up) с последующим Backspace
  # результатом оставался ОДИНОКИЙ Shift-down без единого парного
  # Shift-up. При повторном воспроизведении такой «осиротевший»
  # Shift-down уходил в виртуальную клавиатуру без завершающего
  # Shift-up — композитор после этого навсегда считал Shift зажатым: весь
  # дальнейший ввод (в том числе с физической клавиатуры) шёл заглавными
  # буквами, Caps Lock/Shift это не исправляли, а клик в файловом
  # менеджере вёл себя как Shift+клик (выделялись все файлы до
  # выбранного) — именно так эта ошибка проявлялась «снаружи».
  #
  # Правильная логика: одно нажатие Backspace удаляет из res ровно один
  # предыдущий набранный символ — пару его key-down/key-up (2 события).
  # Если этот символ был напечатан с зажатым Shift, нажатым и отпущенным
  # именно ради него (то есть прямо перед символом лежит Shift-down,
  # а сразу после — Shift-up, «оборачивая» символ в одноразовую пару) —
  # удаляем вместе с символом и эту пару Shift целиком, а не одну её
  # половину, иначе как раз и остаётся несбалансированный Shift.
  for ev in buf:
    if ev.code == KEY_BACKSPACE:
      if ev.value != 1: continue      # key-up того же нажатия — игнорируем
      if len(res) == 0: continue
      # Если сверху стека лежит Shift-up — это, возможно, конец
      # «одноразовой» пары Shift вокруг удаляемого символа; запоминаем,
      # чтобы после удаления символа проверить и снять парный Shift-down.
      var closesShift = false
      if res[^1].code in Shifts and res[^1].value == 0:
        closesShift = true
        discard res.pop()
      if len(res) == 0: continue
      discard res.pop()               # key-up удаляемого символа
      if len(res) == 0: continue
      discard res.pop()               # key-down удаляемого символа
      if closesShift and len(res) > 0 and
         res[^1].code in Shifts and res[^1].value == 1:
        discard res.pop()             # парный Shift-down
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
  logMsg(false, "primary read code=" & $code & " len=" & $len(outp), stdOnly = true)
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
  logMsg(false, "clipboard read code=" & $code & " len=" & $len(outp), stdOnly = true)
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
#   В обычном режиме (emitEvents, обработка набора текста «на лету») у нас
#   есть СКАН-КОДЫ нажатых клавиш — после переключения системной раскладки
#   повтор тех же скан-кодов через uinput автоматически даёт верный символ,
#   независимо от направления EN↔RU: одна и та же физическая клавиша «J»
#   даёт «j» в EN-раскладке и «о» в RU-раскладке, поэтому достаточно просто
#   переключить раскладку и повторить те же нажатия.
#
#   Для текста, выделенного мышью или Shift+стрелками (Home/End/PageUp/
#   PageDown), скан-кодов нет — есть только готовая строка символов,
#   прочитанная из CLIPBOARD после Ctrl+C. У нас нет истории «какая клавиша
#   была нажата», есть только результат «какой символ получился». Чтобы
#   добиться того же эффекта («тот же физический ряд клавиш, но в другой
#   раскладке»), нужно посимвольно сопоставить каждый символ его «соседом»
#   по позиции клавиши в другой раскладке. Именно это делают таблицы ниже —
#   это классический принцип Punto Switcher: ЙЦУКЕН и QWERTY размещены на
#   одних и тех же физических клавишах стандартной 104-клавишной клавиатуры,
#   так что переход «символ → клавиша → символ в другой раскладке» однозначен.

const
  ## Нижний регистр: EN QWERTY → RU ЙЦУКЕН, по позициям клавиш (одна пара —
  ## одна физическая клавиша). Сюда входят все буквенные клавиши основного
  ## ряда плюс знаки, которые на стандартной клавиатуре делят позицию
  ## с русской буквой ([ ] ; ' , . /).
  ##
  ## Особый случай — пара ('/', "."): на стандартной русской клавиатуре
  ## клавиша с «/» в EN-раскладке в RU-раскладке даёт «.» (точку), а не
  ## букву. Поэтому единственная «несимметричная» по смыслу (но абсолютно
  ## штатная по механике) пара в таблице — это та, где EN-символ не буква,
  ## а RU-результат — знак, не буква. Для обратного преобразования
  ## (RU → EN) она работает точно так же: «.» → «/».
  ##
  ## Реализация через array[(char, string)], а не через {...}.toTable
  ## (table-literal): это сознательный выбор, не зависящий от тонких
  ## граней синтаксиса char-литералов вроде '{' / '}' / '"' внутри
  ## конструктора таблицы Nim — каждая пара здесь читается однозначно
  ## и не путается со скобками самого литерала массива.
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

  ## Верхний регистр — те же физические клавиши, но с зажатым Shift.
  ## Заглавные латинские буквы дают заглавные русские; знаковые клавиши
  ## дают вторую (верхнюю) гравировку: [ ] ; ' , . становятся при Shift
  ## { } : " < > ? — и именно их RU-эквиваленты здесь и записаны.
  ## chr(123)='{', chr(125)='}', chr(34)='"' — те же символы, что и
  ## выше, записаны через числовой код по той же причине (избежать
  ## char-литералов, совпадающих по начертанию со скобками самого кода).
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
  ## Превращает массив пар (char, string) в Table[char, string] для O(1)
  ## поиска при переборе текста символ за символом в convertLayout.
  result = initTable[char, string]()
  for (k, v) in pairs:
    result[k] = v

let
  EnToRuLower = buildLowerUpper(EnToRuLowerPairs)
  EnToRuUpper = buildLowerUpper(EnToRuUpperPairs)

proc buildRuToEn(enToRu: Table[char, string]): Table[string, char] =
  ## Строит обратную таблицу RU → EN, переворачивая прямую таблицу EN → RU
  ## (ключ становится значением и наоборот). Ключ обратной таблицы — string,
  ## а не char, потому что русские буквы в UTF-8 кодируются больше чем
  ## одним байтом — char (1 байт) для них не подходит, поэтому везде, где
  ## фигурирует кириллица как ключ поиска, используется string (на самом
  ## деле это ровно один Rune, просто хранимый в виде string).
  ##
  ## Не зацикливаемся на проверке дублей при построении: уникальность
  ## значений в EnToRuLowerPairs/EnToRuUpperPairs (33 уникальные пары
  ## в каждой таблице) гарантирует отсутствие коллизий ключей здесь.
  result = initTable[string, char]()
  for k, v in enToRu:
    result[v] = k

let
  RuToEnLower = buildRuToEn(EnToRuLower)
  RuToEnUpper = buildRuToEn(EnToRuUpper)

proc detectDirection(text: string): bool =
  ## Автоматически определяет направление перекодировки, считая отдельно
  ## латинские и кириллические буквы во всём тексте:
  ##   true  → в тексте больше латиницы → текст набран в EN-раскладке,
  ##           когда должен был быть на русском → конвертируем EN → RU.
  ##   false → в тексте больше кириллицы → текст набран в RU-раскладке,
  ##           когда должен был быть на английском → конвертируем RU → EN.
  ## При равенстве (включая «нет букв вообще» — например, выделены только
  ## цифры или знаки пунктуации) по умолчанию считаем направление EN → RU,
  ## так как этот сценарий («написал русское слово английскими буквами,
  ## забыв переключить раскладку») на практике встречается значительно
  ## чаще обратного.
  ##
  ## Знаки пунктуации, пробелы, переводы строк и цифры не считаются ни
  ## латиницей, ни кириллицей и не влияют на решение — они в любом случае
  ## копируются в результат без изменений (см. convertLayout), независимо
  ## от выбранного направления.
  var enCount, ruCount: int
  for r in runes(text):
    let cp = int(r)
    if (cp >= int('a') and cp <= int('z')) or (cp >= int('A') and cp <= int('Z')):
      inc enCount
    elif cp >= 0x0400 and cp <= 0x04FF:   ## диапазон кириллицы Unicode (Cyrillic)
      inc ruCount
  if ruCount > enCount: false else: true

proc convertLayout*(text: string): string =
  ## Перекодирует строку между EN(QWERTY) и RU(ЙЦУКЕН) по позициям клавиш.
  ## Направление определяется автоматически (detectDirection) по
  ## преобладающим символам во всём тексте — один и тот же вызов сам
  ## выбирает EN→RU или RU→EN, вызывающему коду об этом думать не нужно.
  ##
  ## Перебор идёт через runes(text), а не напрямую по char/byte: кириллица
  ## в UTF-8 — многобайтовая (как правило, 2 байта на букву), и обход по
  ## char исказил бы и разбил такие символы. runes() корректно возвращает
  ## по одному Unicode code point на итерацию независимо от кодировки.
  ##
  ## Символы, отсутствующие в таблицах (цифры, пробелы, знаки пунктуации
  ## без своей позиции в раскладке, переводы строк \n и \r и т.д.),
  ## копируются в результат БЕЗ изменений — это и обеспечивает корректную
  ## работу с многострочным текстом: \n просто проходит через else-ветку
  ## как обычный «нераспознанный» символ, структура строк сохраняется.
  let toRu = detectDirection(text)
  result = ""
  for r in runes(text):
    let s = $r
    if toRu:
      # EN → RU: ищем символ как char (однобайтовая латиница/ASCII-знак).
      if s.len == 1 and EnToRuLower.hasKey(s[0]): result.add(EnToRuLower[s[0]])
      elif s.len == 1 and EnToRuUpper.hasKey(s[0]): result.add(EnToRuUpper[s[0]])
      else: result.add(s)
    else:
      # RU → EN: ищем символ как string (кириллица — многобайтовый Rune,
      # представленный здесь строкой из одного символа).
      if RuToEnLower.hasKey(s): result.add($RuToEnLower[s])
      elif RuToEnUpper.hasKey(s): result.add($RuToEnUpper[s])
      else: result.add(s)

proc emitSelectionCorrection*(vfd: cint; keysLs: seq[uint16];
                               clipTool: ClipboardTool; delayMs: int;
                               selLen: int) =
  ## Корректирует выделенный текст (выделен мышью или Shift+стрелками/
  ## Home/End/PageUp/PageDown), который был набран в неправильной
  ## раскладке клавиатуры — перекодирует его в нужную раскладку и
  ## заменяет выделение результатом. Подробное описание алгоритма и
  ## порядка шагов — см. комментарий «Порядок шагов коррекции» ниже,
  ## непосредственно перед шагом 1.
  ##
  ## selLen сейчас не используется внутри функции (оставлен в сигнатуре
  ## для совместимости вызова и отладочных целей у вызывающей стороны) —
  ## фактическая длина определяется по факту прочитанного из CLIPBOARD
  ## текста, а не по количеству нажатий клавиш-стрелок.

  let actualTool =
    if clipTool == ClipAuto: detectClipboardTool()
    else: clipTool

  # Запоминаем то, что лежало в CLIPBOARD ДО вмешательства этой функции —
  # понадобится на шаге 2, чтобы вернуть всё как было, если окажется, что
  # реального выделения в приложении не было и Ctrl+C ничего не скопировал
  # (см. подробное объяснение в комментарии перед шагом 2 ниже).
  let prevClipboard = readClipboard(actualTool)

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

  ## Порядок шагов коррекции (почему именно такой):
  ##   Сначала кажется логичным: переключить раскладку → Ctrl+C → перевести
  ##   прочитанный текст программно → записать в CLIPBOARD → Delete → Ctrl+V.
  ##   Но это не нужно: copy/paste работает с готовым ТЕКСТОМ (символами),
  ##   а не со скан-кодами, поэтому момент переключения системной раскладки
  ##   относительно Ctrl+C значения не имеет — раскладка влияет только на
  ##   то, какой символ получится при нажатии физической клавиши, а не на
  ##   то, что уже скопировано в буфер обмена. Поэтому порядок ниже —
  ##   рабочий и при этом самый простой:
  ##     0. Пишем в CLIPBOARD заведомо уникальную метку-маркер — нужна
  ##        на шаге 2, чтобы надёжно отличить «Ctrl+C реально скопировал
  ##        выделение» от «Ctrl+C ничего не скопировал, в CLIPBOARD так
  ##        и осталось то, что было записано туда ДО вызова этой функции».
  ##     1. Ctrl+C — копируем выделение в CLIPBOARD как есть, выделение
  ##        остаётся активным (Ctrl+C не снимает выделение).
  ##        Почему не PRIMARY selection (буфер, который Wayland/X11 сами
  ##        заполняют при выделении текста, без Ctrl+C): GTK4
  ##        (gnome-text-editor и другие современные приложения) не
  ##        реализует PRIMARY selection на Wayland — разработчики GNOME
  ##        намеренно отказались от него как от «X11-концепции», и
  ##        wl-paste --primary в таких приложениях всегда возвращает
  ##        устаревшее значение. Ctrl+C через uinput работает надёжно:
  ##        виртуальное устройство получает фокус ввода наравне с
  ##        физической клавиатурой.
  ##     2. Читаем CLIPBOARD — получаем исходный («неправильный») текст.
  ##        Если там до сих пор лежит метка-маркер из шага 0 — значит,
  ##        Ctrl+C ничего не скопировал (реального выделения на уровне
  ##        приложения не возникло — клик пришёлся не туда, фокус успел
  ##        уйти, приложение перехватило Ctrl+C само и т.п.) — прерываем
  ##        коррекцию, восстанавливаем прежнее содержимое CLIPBOARD
  ##        (prevClipboard) и ничего не вставляем (см. подробности
  ##        в комментарии прямо перед шагом 2 ниже).
  ##     3. Переключаем системную раскладку — нужно для следующего набора
  ##        текста пользователем; на сам процесс коррекции не влияет.
  ##     4. Перекодируем текст программно (convertLayout, посимвольно по
  ##        позициям клавиш) и записываем результат в CLIPBOARD.
  ##     5. Delete — удаляем всё ещё активное выделение.
  ##     6. Ctrl+V — вставляем скорректированный текст.
  ##     7. Восстанавливаем в CLIPBOARD то, что было записано туда ДО
  ##        вызова этой функции (prevClipboard). Без этого шага CLIPBOARD
  ##        после удачной коррекции навсегда остаётся со скорректированным
  ##        текстом — он используется только как промежуточный носитель
  ##        для шага 6 и не должен подменять то, что пользователь скопировал
  ##        туда раньше вручную.

  # ── Шаг 0: метка-маркер в CLIPBOARD ──────────────────────────────────────
  # Записываем заведомо уникальную строку (pid + текущее время в микро-
  # секундах — случайное совпадение с реальным выделением пользователя
  # исключено). Если после Ctrl+C в CLIPBOARD будет лежать ровно эта
  # строка — значит, Ctrl+C не записал туда ничего нового, и читать
  # «выделенный текст» дальше нельзя: это будет тот самый старый текст,
  # скопированный пользователем когда-то раньше, который раньше по ошибке
  # конвертировался и вставлялся обратно поверх документа.
  let marker = "WS_MARKER_" & $getpid() & "_" & $t.tv_sec & $t.tv_usec
  logMsg(false, "sel-correction: шаг 0 — метка-маркер в CLIPBOARD", stdOnly = true)
  writeClipboard(actualTool, marker)
  sleep(100)

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
  # ИСТОРИЯ ОШИБКИ (важно, чтобы не повторить её снова):
  #   Раньше здесь сравнивался CLIPBOARD до и после Ctrl+C, и при совпадении
  #   коррекция прерывалась как «Ctrl+C не сработал». Эту проверку убрали,
  #   потому что она ложно прерывала повторную коррекцию ОДНОГО И ТОГО ЖЕ
  #   текста (когда новое выделение совпадает с тем, что уже лежало
  #   в CLIPBOARD, — это законный случай, а не сбой).
  #   Но вместе с проверкой убрали и единственную защиту от другого,
  #   гораздо более частого случая: Ctrl+C не сработал ВООБЩЕ (например,
  #   главный цикл взвёл selActive по drag мыши, а реального выделения
  #   в приложении не возникло). Тогда readClipboard возвращал старое
  #   содержимое буфера обмена (то, что пользователь скопировал когда-то
  #   раньше, до запуска коррекции), оно благополучно проходило проверку
  #   на пустую строку, конвертировалось convertLayout и вставлялось
  #   поверх документа — внешне это выглядело как «вместо исправленного
  #   текста после набора в неправильной раскладке появился прежний,
  #   ранее скопированный текст».
  #   Решение — метка-маркер из шага 0 ВМЕСТО сравнения «до/после»:
  #   сравнение «до/после» не отличает «текст совпал случайно» от
  #   «Ctrl+C не сработал», а уникальный маркер отличает однозначно —
  #   совпадение с маркером возможно только если Ctrl+C ничего не записал.
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
  selText = strip(selText, leading = false, chars = {'\r', '\n'})
  if selText == marker:
    # Ctrl+C ничего не скопировал — реального выделения не было.
    # В CLIPBOARD сейчас лежит наш собственный маркер, а не текст
    # пользователя — возвращаем то, что было записано туда до вызова
    # этой функции, иначе маркер навсегда подменил бы пользователю
    # буфер обмена.
    logMsg(false,
      "sel-correction: в CLIPBOARD маркер — Ctrl+C не скопировал выделение, прерываем",
      stdOnly = true)
    writeClipboard(actualTool, prevClipboard)
    return
  if selText == "":
    logMsg(false, "sel-correction: clipboard пуст после Ctrl+C — прерываем", stdOnly = true)
    writeClipboard(actualTool, prevClipboard)
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
  # Пауза перед шагом 7: даём приложению время забрать содержимое CLIPBOARD
  # на вставку, прежде чем мы перезапишем буфер обратно — если поторопиться,
  # можно перезаписать CLIPBOARD раньше, чем Ctrl+V успеет его прочитать,
  # и тогда вставится prevClipboard вместо исправленного текста.
  sleep(150)

  # ── Шаг 7: восстанавливаем прежнее содержимое CLIPBOARD ──────────────────
  # Коррекция выделения по своей природе временно занимает CLIPBOARD —
  # без этого вставить исправленный текст шагом 6 было бы нечем. Но без
  # этого шага CLIPBOARD после удачной коррекции навсегда остаётся с
  # исправленным текстом, подменяя то, что пользователь скопировал туда
  # раньше (вручную, до запуска коррекции) — пользователь, ожидая увидеть
  # при следующем Ctrl+V старое содержимое буфера обмена, неожиданно
  # получает текст, который только что был исправлен программой.
  # Возвращаем prevClipboard — то, что было записано в CLIPBOARD до
  # вызова этой функции (см. самое начало, объявление actualTool выше).
  logMsg(false, "sel-correction: шаг 7 — восстанавливаем прежний CLIPBOARD",
         stdOnly = true)
  writeClipboard(actualTool, prevClipboard)

  logMsg(false, "sel-correction: завершено", stdOnly = true)

proc emitEvents*(vfd: cint; keyBuf: seq[InputEvent];
                 keysLs: seq[uint16]; singleWord: bool; delayMs: int) =
  ## Отправляет в виртуальную клавиатуру три группы событий подряд:
  ##   1. Backspace × N — стирает ровно столько символов, сколько в буфере
  ##      (считаются события с value 1 «down» и 2 «autorepeat», кроме Shift,
  ##      потому что Shift сам по себе не печатает символ и не должен
  ##      стираться отдельной клавишей).
  ##   2. Комбинация переключения раскладки (один или два скан-кода из
  ##      keysLs — например, для Right Ctrl это один код, а для Ctrl+Shift
  ##      это два кода нажатых вместе).
  ##   3. Повтор нажатий из буфера — те же самые скан-коды, что хранятся
  ##      в keyBuf, отправляются повторно. Поскольку раскладка уже
  ##      переключена (группа 2 отправлена раньше), те же физические
  ##      клавиши теперь дают другие символы — это и есть «коррекция»
  ##      для текста, который пользователь только что набирал вживую.
  ##
  ## singleWord=true → начинаем не с начала буфера, а с позиции после
  ## последнего пробела (заменяем только последнее слово, не всю фразу) —
  ## вызывается из главного цикла, когда getBufferAction вернула
  ## ReplaceWord (а не ReplaceAll).
  ##
  ## Каждое событие отправляется парой [InputEvent, SYN_REPORT] — таков
  ## протокол evdev/uinput: SYN_REPORT сигнализирует получателю, что
  ## очередной пакет событий завершён и можно его обработать. После
  ## каждой пары — пауза delayMs мс, чтобы compositor / приложение успели
  ## обработать событие до прихода следующего (без паузы события могут
  ## слипаться или восприниматься с потерями на медленных системах).

  var t: MyTimeVal
  discard c_clock_gettime(0, addr t)
  ## Метки времени в InputEvent не обязаны быть «настоящими» — drivers
  ## и compositor используют их в основном для упорядочивания событий
  ## и измерения дребезга, а не как точное время. Поэтому здесь берём
  ## реальное «сейчас» только как стартовую точку, а дальше двигаем
  ## tv_usec вручную на фиксированный шаг (200 мкс на событие, push)
  ## просто чтобы метки шли строго по возрастанию в правильном порядке —
  ## этого достаточно для корректной обработки на принимающей стороне.
  t.tv_usec = 0   ## начинаем с целой секунды, смещения будем добавлять по 200 мкс

  # Определяем стартовую позицию в буфере: вся фраза или только последнее
  # слово. Если singleWord — ищем индекс последнего пробела (key-up, не
  # в самом конце буфера) и начинаем с символа после него; если пробелов
  # не было вовсе, startIdx остаётся 0 и обрабатывается весь буфер целиком
  # (то есть «последнее слово» совпадает со всей фразой).
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
