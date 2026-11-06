## clipboard.nim — доступ к буферу обмена графической сессии пользователя.
##
## Служба работает от root, а буфер обмена принадлежит сессии обычного
## пользователя, поэтому команды wl-paste/wl-copy/xclip/xsel выполняются
## через su с окружением этой сессии (WAYLAND_DISPLAY, XDG_RUNTIME_DIR,
## DISPLAY). Параметры сессии берутся из /proc/*/environ чужих процессов,
## то есть это недоверенные данные: имя пользователя проверяется, а все
## значения перед подстановкой в команду shell проходят через shellQuote.

import posix, os, osproc, strutils
import types, core, shellquote

proc execl(path: cstring; arg0: cstring): cint
    {.importc: "execl", header: "<unistd.h>", varargs.}
  ## Заменяет образ процесса; список аргументов завершается nil.

proc exitnow(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
  ## Немедленное завершение без сброса буферов stdio — обязательно в
  ## дочернем процессе после fork, чтобы не сбросить буферы родителя.

type
  SessionEnv* = object
    ## Параметры графической сессии пользователя. Пустой user означает,
    ## что сессия не найдена.
    user*:           string
    waylandDisplay*: string
    xdgRuntime*:     string
    display*:        string

proc isSafeUserName(s: string): bool =
  ## Допускает только обычные имена учётных записей.
  if s.len == 0 or s.len > 32 or s[0] == '-': return false
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}: return false
  true

proc getSessionEnv*(): SessionEnv =
  ## Ищет процесс обычного (не root) пользователя с графической сессией —
  ## то есть с WAYLAND_DISPLAY или DISPLAY и XDG_RUNTIME_DIR в окружении —
  ## и возвращает параметры его сессии.
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
        var wd, xdg, disp, user: string
        for e in readFile(envFile).split(char(0)):
          if e.startsWith("WAYLAND_DISPLAY="):  wd   = e[16..^1]
          elif e.startsWith("XDG_RUNTIME_DIR="): xdg  = e[16..^1]
          elif e.startsWith("DISPLAY="):         disp = e[8..^1]
          elif e.startsWith("USER="):            user = e[5..^1]
        if user != "root" and isSafeUserName(user) and
           (wd != "" or disp != "") and xdg != "":
          return SessionEnv(user: user, waylandDisplay: wd,
                            xdgRuntime: xdg, display: disp)
      except CatchableError:
        continue
  except CatchableError:
    discard

proc detectClipboardTool*(): ClipboardTool =
  ## Определяет доступный инструмент: wl-paste, затем xclip, затем xsel.
  ## ClipAuto в результате означает, что ничего не найдено.
  if execShellCmd("command -v wl-paste >/dev/null 2>&1") == 0:
    return ClipWayland
  if execShellCmd("command -v xclip >/dev/null 2>&1") == 0:
    return ClipXclip
  if execShellCmd("command -v xsel >/dev/null 2>&1") == 0:
    return ClipXsel
  return ClipAuto

proc shellCommandFor(env: SessionEnv; innerCmd: string): string =
  ## Строит команду для `sh -c`: innerCmd от имени пользователя сессии и с
  ## её окружением. Если сессия не найдена, команда выполняется как есть.
  if env.user == "": return innerCmd
  var prefix = ""
  if env.waylandDisplay != "":
    prefix &= "WAYLAND_DISPLAY=" & shellQuote(env.waylandDisplay) & " "
  if env.xdgRuntime != "":
    prefix &= "XDG_RUNTIME_DIR=" & shellQuote(env.xdgRuntime) & " "
  if env.display != "":
    prefix &= "DISPLAY=" & shellQuote(env.display) & " "
  prefix & "su -s /bin/sh -c " & shellQuote(innerCmd) & " " & shellQuote(env.user)

proc readClipboard*(tool: ClipboardTool; env: SessionEnv): string =
  ## Возвращает содержимое CLIPBOARD (то, что копируется по Ctrl+C) или
  ## пустую строку при ошибке.
  let innerCmd =
    case tool
    of ClipWayland: "wl-paste --no-newline"
    of ClipXclip:   "xclip -selection clipboard -o"
    of ClipXsel:    "xsel --clipboard --output"
    of ClipAuto:    return ""
  let cmd = shellCommandFor(env, innerCmd) & " 2>/dev/null"
  logMsg(false, "run cmd: " & cmd, stdOnly = true)
  let (outp, code) = execCmdEx(cmd)
  logMsg(false, "clipboard read code=" & $code & " len=" & $len(outp), stdOnly = true)
  if code == 0: outp else: ""

proc writeClipboard*(tool: ClipboardTool; env: SessionEnv; text: string) =
  ## Записывает text в CLIPBOARD.
  ##
  ## wl-copy, xclip и xsel остаются работать в фоне, обслуживая запросы на
  ## вставку, поэтому execCmdEx, ожидающий завершения всего дерева процессов,
  ## здесь зависает. Вместо него применяется двойной fork:
  ##   • родитель ждёт только child-1, который сразу завершается;
  ##   • child-1 вызывает setsid() и порождает child-2;
  ##   • child-2 запускает команду и усыновляется init.
  ## Текст передаётся через канал (pipe) на стандартный ввод команды — ни
  ## временных файлов, ни проблем с экранированием. Запись в канал, у
  ## которого нет читателя, не должна убить службу, поэтому SIGPIPE
  ## игнорируется (см. daemon.run).
  let innerCmd =
    case tool
    of ClipWayland: "wl-copy"
    of ClipXclip:   "xclip -selection clipboard"
    of ClipXsel:    "xsel --clipboard --input"
    of ClipAuto:    return
  let shellCmd = shellCommandFor(env, innerCmd)
  logMsg(false, "clipboard write cmd: " & shellCmd, stdOnly = true)

  var fds: array[0..1, cint]
  if pipe(fds) != 0:
    logMsg(false, "clipboard write: pipe() failed", stdOnly = true)
    return

  let child1 = fork()
  if child1 < 0:
    logMsg(false, "clipboard write: fork() failed", stdOnly = true)
    discard close(fds[0])
    discard close(fds[1])
    return

  if child1 == 0:
    discard close(fds[1])      # иначе команда не дождётся конца ввода
    discard setsid()
    let child2 = fork()
    if child2 < 0:
      exitnow(1)
    if child2 == 0:
      discard dup2(fds[0], 0)
      if fds[0] > 2: discard close(fds[0])
      let devNull = open("/dev/null", O_RDWR)
      if devNull >= 0:
        discard dup2(devNull, 1)
        discard dup2(devNull, 2)
        if devNull > 2: discard close(devNull)
      discard execl("/bin/sh", "sh", "-c", cstring(shellCmd), nil)
      exitnow(127)             # exec не удался
    exitnow(0)

  # Родитель: передаёт текст и дожидается child-1.
  discard close(fds[0])
  var off = 0
  while off < text.len:
    let n = write(fds[1], unsafeAddr text[off], text.len - off)
    if n <= 0: break
    off += n
  discard close(fds[1])
  var wstatus: cint = 0
  discard waitpid(child1, wstatus, 0)

  # Даём команде время объявить себя владельцем CLIPBOARD до следующего шага.
  sleep(150)
