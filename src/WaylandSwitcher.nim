
################################################################
## Waylan Switcher — приложение для автоматической коррекции
##           символов, ошибочно набранных в другой раскладке.
## 
##   (keyboard layout switcher and input corrector for Linux)
## 
## Версия:   0.8
## Дата:     2026-04-22
## Автор:    github.com/Balans097
################################################################

# 0.8 — приложение доведено до рабочего состояния (2026-04-22)
# 0.1 — начальная реализация программы (2026-04-18)



## Компиляция:
## nim c --threads:on -d:release WaylandSwitcher.nim




import os, strutils, posix




const
  VERSION            = "0.8"
  SYSTEMD_UNIT_FILE  = "/lib/systemd/system/wayland-switcher.service"
  CONFIG_FILE        = "/etc/wayland-switcher/default.conf"
  INPUT_DEVICES_DIR  = "/dev/input/"
  UINPUT_FILE        = "/dev/uinput"

  EV_SYN:     uint16 = 0x00
  EV_KEY:     uint16 = 0x01
  SYN_REPORT: uint16 = 0x00
  BUS_USB:    uint16 = 0x03

  UI_SET_EVBIT:  uint = 0x40045564
  UI_SET_KEYBIT: uint = 0x40045565
  UI_DEV_SETUP:  uint = 0x405C5503
  UI_DEV_CREATE: uint = 0x00005501
  UI_DEV_DESTROY:uint = 0x00005502

  KEY_BACKSPACE: uint16 = 14
  KEY_SPACE:     uint16 = 57
  KEY_ENTER:     uint16 = 28
  KEY_KPENTER:   uint16 = 96

  Letters    = {2'u16, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19,
                20, 21, 22, 23, 24, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36,
                37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53,
                55, 57, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 96, 98}
  Shifts     = {42'u16, 54}
  BufKillers = {15'u16, 29, 56, 97, 100, 102, 103, 104, 105, 106, 107, 108, 109, 110}

  KeyName: array[249, string] = [
    "RESERVED","ESC","1","2","3","4","5","6","7","8","9","0","MINUS","EQUAL",
    "BACKSPACE","TAB","Q","W","E","R","T","Y","U","I","O","P","LEFTBRACE",
    "RIGHTBRACE","ENTER","LEFTCTRL","A","S","D","F","G","H","J","K","L",
    "SEMICOLON","APOSTROPHE","GRAVE","LEFTSHIFT","BACKSLASH","Z","X","C","V",
    "B","N","M","COMMA","DOT","SLASH","RIGHTSHIFT","KPASTERISK","LEFTALT",
    "SPACE","CAPSLOCK","F1","F2","F3","F4","F5","F6","F7","F8","F9","F10",
    "NUMLOCK","SCROLLLOCK","KP7","KP8","KP9","KPMINUS","KP4","KP5","KP6",
    "KPPLUS","KP1","KP2","KP3","KP0","KPDOT","(84)","ZENKAKUHANKAKU","102ND",
    "F11","F12","RO","KATAKANA","HIRAGANA","HENKAN","KATAKANAHIRAGANA",
    "MUHENKAN","KPJPCOMMA","KPENTER","RIGHTCTRL","KPSLASH","SYSRQ","RIGHTALT",
    "LINEFEED","HOME","UP","PAGEUP","LEFT","RIGHT","END","DOWN","PAGEDOWN",
    "INSERT","DELETE","MACRO","MUTE","VOLUMEDOWN","VOLUMEUP","POWER","KPEQUAL",
    "KPPLUSMINUS","PAUSE","SCALE","KPCOMMA","HANGEUL","HANJA","YEN","LEFTMETA",
    "RIGHTMETA","COMPOSE","STOP","AGAIN","PROPS","UNDO","FRONT","COPY","OPEN",
    "PASTE","FIND","CUT","HELP","MENU","CALC","SETUP","SLEEP","WAKEUP","FILE",
    "SENDFILE","DELETEFILE","XFER","PROG1","PROG2","WWW","MSDOS","COFFEE",
    "ROTATE_DISPLAY","CYCLEWINDOWS","MAIL","BOOKMARKS","COMPUTER","BACK",
    "FORWARD","CLOSECD","EJECTCD","EJECTCLOSECD","NEXTSONG","PLAYPAUSE",
    "PREVIOUSSONG","STOPCD","RECORD","REWIND","PHONE","ISO","CONFIG","HOMEPAGE",
    "REFRESH","EXIT","MOVE","EDIT","SCROLLUP","SCROLLDOWN","KPLEFTPAREN",
    "KPRIGHTPAREN","NEW","REDO","F13","F14","F15","F16","F17","F18","F19","F20",
    "F21","F22","F23","F24","(195)","(196)","(197)","(198)","(199)","PLAYCD",
    "PAUSECD","PROG3","PROG4","ALL_APPLICATIONS","SUSPEND","CLOSE","PLAY",
    "FASTFORWARD","BASSBOOST","PRINT","HP","CAMERA","SOUND","QUESTION","EMAIL",
    "CHAT","SEARCH","CONNECT","FINANCE","SPORT","SHOP","ALTERASE","CANCEL",
    "BRIGHTNESSDOWN","BRIGHTNESSUP","MEDIA","SWITCHVIDEOMODE","KBDILLUMTOGGLE",
    "KBDILLUMDOWN","KBDILLUMUP","SEND","REPLY","FORWARDMAIL","SAVE","DOCUMENTS",
    "BATTERY","BLUETOOTH","WLAN","UWB","UNKNOWN","VIDEO_NEXT","VIDEO_PREV",
    "BRIGHTNESS_CYCLE","BRIGHTNESS_AUTO","DISPLAY_OFF","WWAN","RFKILL","MICMUTE"
  ]
  KeyAction: array[3, string] = ["up", "down", "autorepeat"]

  LOG_PID    = 0x01.cint
  LOG_DAEMON = (3.cint shl 3)
  LOG_INFO   = 6.cint
  LOG_ERR    = 3.cint

type
  MyTimeVal = object
    tv_sec*:  int64
    tv_usec*: int64

  InputEvent = object
    time:    MyTimeVal
    ie_type: uint16
    code:    uint16
    value:   int32

  UInputId = object
    bustype, vendor, product, version: uint16

  UInputSetup = object
    id:             UInputId
    name:           array[80, char]
    ff_effects_max: uint32

  BufferAction = enum
    KeepBuffer, ReplaceAll, ReplaceWord

var
  daemonMode:      bool = true
  keyRpl:          uint16 = 0
  keysLs:          seq[uint16] = @[]
  strKeysLs:       string = ""
  needTrackMouse  {.volatile.}: bool = false
  needClearKeyBuf {.volatile.}: bool = false
  stopAndExit     {.volatile.}: bool = false
  keyBuf:          seq[InputEvent] = @[]
  mouseFDGlobal:   cint = -1

proc c_openlog(id: cstring; opt, fac: cint) {.importc:"openlog",  header:"<syslog.h>".}
proc c_syslog(pri: cint; fmt: cstring)       {.importc:"syslog",   header:"<syslog.h>", varargs.}
proc c_closelog()                             {.importc:"closelog", header:"<syslog.h>".}
proc c_ioctl(fd: cint; req: culong; arg: pointer): cint
    {.importc:"ioctl", header:"<sys/ioctl.h>", varargs.}
proc c_clock_gettime(clk: cint; tp: pointer): cint
    {.importc:"clock_gettime", header:"<time.h>".}
proc pthread_cancel(thread: Pthread): cint
    {.importc:"pthread_cancel", header:"<pthread.h>".}

proc logMsg(isErr: bool; msg: string; stdOnly = false) =
  if daemonMode:
    if not stdOnly:
      c_syslog(if isErr: LOG_ERR else: LOG_INFO, "%s", cstring(msg))
  else:
    echo msg
    if not stdOnly:
      c_syslog(if isErr: LOG_ERR else: LOG_INFO, "%s", cstring(msg))

proc fillName(a: var array[80, char]; s: string) =
  zeroMem(addr a[0], 80)
  for i in 0 ..< min(len(s), 79): a[i] = s[i]

proc keyNameSafe(code: uint16): string =
  ## Безопасный доступ к KeyName с проверкой диапазона
  if code <= 248: KeyName[code]
  else: "(" & $code & ")"

proc readIniKey(path, key: string; default = ""): string =
  if not fileExists(path): return default
  for line in lines(path):
    let t = strip(line)
    if startsWith(t, key & "="):
      var v = strip(t[len(key)+1 .. ^1])
      if len(v) >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 .. ^2]
      return v
  return default

proc runInstall() =
  daemonMode = false
  logMsg(false, "Installing WaylandSwitcher daemon...")
  try:
    writeFile(SYSTEMD_UNIT_FILE,
      "[Unit]\nDescription=WaylandSwitcher - keyboard layout switcher\n" &
      "Requires=local-fs.target\nAfter=local-fs.target\n" &
      "StartLimitIntervalSec=10\nStartLimitBurst=3\n\n" &
      "[Service]\nType=simple\nExecStart=" & getAppFilename() & " -r\n" &
      "#User=wayland-switcher\nRestart=on-failure\nRestartSec=3\n\n" &
      "[Install]\nWantedBy=sysinit.target \n")
    logMsg(false, "WaylandSwitcher daemon successfully installed, version: " & VERSION)
  except CatchableError as e:
    logMsg(true, "Error creating systemd control file. " & e.msg & ". Are you root?")

proc runUninstall() =
  daemonMode = false
  logMsg(false, "Uninstalling WaylandSwitcher daemon...")
  if fileExists(SYSTEMD_UNIT_FILE):
    try:
      removeFile(SYSTEMD_UNIT_FILE)
      logMsg(false, "WaylandSwitcher daemon is successfully uninstalled.")
    except:
      logMsg(true, "Error removing " & SYSTEMD_UNIT_FILE & ". Are you root?")
  else:
    logMsg(true, "Nothing to uninstall. Unit file not found " & SYSTEMD_UNIT_FILE & ".")

type KbdDetectArg = object
  path:   string
  active: bool

proc kbdDetectFn(argPtr: pointer) {.thread.} =
  ## Определяет клавиатуру по нажатию Enter: ждёт до ~60 секунд.
  ## O_NONBLOCK обязателен: блокирующий read() зависает на устройствах,
  ## которые не генерируют событий (мышь, джойстик и т.д.), и тогда
  ## главный поток никогда не дойдёт до readLine.
  let arg = cast[ptr KbdDetectArg](argPtr)
  let fd  = open(cstring(arg.path), O_RDONLY or O_NONBLOCK)
  if fd == -1: return
  var
    ie: InputEvent
    i  = 0
  while i < 5700:
    if read(fd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == 1 and (ie.code == KEY_ENTER or ie.code == KEY_KPENTER) and
         ie.value in [0'i32, 1, 2]:
        arg.active = true; break
    sleep(10); inc i
  discard close(fd)

proc mouseThreadFn(arg: pointer) {.thread.} =
  ## Отслеживает клики мыши для очистки буфера.
  ## Блокирующий read вызывается всегда; проверка needTrackMouse — внутри,
  ## после получения данных (как в оригинальном Pascal-коде).
  var d: array[3, uint8]
  while not stopAndExit:
    let n = read(mouseFDGlobal, addr d[0], 3)
    if n == 3 and needTrackMouse:
      if (d[0] and 0x07) != 0:
        logMsg(false, "mouse click", true)
        logMsg(false, "buffer clearing queued", true)
        needTrackMouse  = false
        needClearKeyBuf = true

proc runConfig() =
  daemonMode = false
  logMsg(false, "WaylandSwitcher keyboard configuration started.")
  var
    mousePath   = "/dev/input/mice"
    reverseMode = false
    delay       = 10
  try:
    createDir(parentDir(CONFIG_FILE))
  except:
    logMsg(true, "Cannot create directory " & parentDir(CONFIG_FILE)); quit(1)

  logMsg(false, "Trying to read existing config file...", true)
  if fileExists(CONFIG_FILE):
    mousePath   = readIniKey(CONFIG_FILE, "mouse", "/dev/input/mice")
    reverseMode = toLowerAscii(readIniKey(CONFIG_FILE, "reverse-mode", "false")) == "true"
    try: delay  = parseInt(readIniKey(CONFIG_FILE, "delay", "10")) except: discard
    logMsg(false, "Done.", true)

  logMsg(false, "", true)
  logMsg(false, "WaylandSwitcher will try to detect your keyboard automatically.", true)
  sleep(100)

  var kbdList: seq[KbdDetectArg]
  for kind, path in walkDir(INPUT_DEVICES_DIR):
    if kind != pcFile: continue
    if not startsWith(extractFilename(path), "event"): continue
    let fd = open(cstring(path), O_RDONLY or O_NONBLOCK)
    if fd == -1: continue
    discard close(fd)
    add(kbdList, KbdDetectArg(path: path))

  if len(kbdList) == 0:
    logMsg(true, "No input devices found. Are you root?"); quit(1)

  var
    tids = newSeq[Pthread](len(kbdList))
    attr: PthreadAttr
  discard pthread_attr_init(addr attr)
  for i in 0 ..< len(kbdList):
    discard pthread_create(addr tids[i], addr attr,
      cast[proc(p: pointer): pointer {.noconv.}](kbdDetectFn), addr kbdList[i])
  discard pthread_attr_destroy(addr attr)

  logMsg(false, "Please press ENTER...", true)
  discard readLine(stdin)

  # Ждём результата: опрашиваем флаги активности каждые 100 мс.
  # Потоки отменяем сразу после нахождения клавиатуры — не ждём их
  # штатного завершения (до 60 с), иначе конфигуратор зависнет.
  var keyboardPath = ""
  for _ in 0..600:
    sleep(100)
    for a in kbdList:
      if a.active: keyboardPath = a.path; break
    if keyboardPath != "": break
  for tid in tids:
    discard pthread_cancel(tid)
  for tid in tids:
    var rv: pointer
    discard pthread_join(tid, addr rv)

  if keyboardPath == "":
    logMsg(true, "Couldn't capture your keypress. Are you root?"); quit(1)
  logMsg(false, "Found keyboard at " & keyboardPath, true)
  logMsg(false, "", true)
  sleep(500)

  var kfd = open(cstring(keyboardPath), O_RDONLY or O_SYNC)
  if kfd == -1:
    logMsg(true, "Error attaching to keyboard."); quit(1)

  logMsg(false, "Press the key or combination of keys that changes layout in your system.", true)
  logMsg(false, "Waiting for your input...", true)
  keysLs = @[]
  var
    ie: InputEvent
    i  = 0
  while i < 6000:
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == EV_KEY and ie.value in [0'i32, 1]:
        add(keysLs, ie.code)
        if len(keysLs) == 2:
          strKeysLs = if ie.value == 0: $keysLs[0]
                      else: $keysLs[0] & "+" & $keysLs[1]
          break
    sleep(10); inc i

  if len(keysLs) == 0:
    logMsg(true, "Error reading the keyboard."); discard close(kfd); quit(1)

  if '+' in strKeysLs:
    let p = split(strKeysLs, '+')
    logMsg(false, "Key combination " & keyNameSafe(uint16(parseInt(p[0]))) & "+" &
                  keyNameSafe(uint16(parseInt(p[1]))) & " captured", true)
  else:
    logMsg(false, "Key " & keyNameSafe(keysLs[0]) & " captured", true)
  logMsg(false, "", true)

  sleep(500); discard close(kfd)
  kfd = open(cstring(keyboardPath), O_RDONLY or O_SYNC)

  logMsg(false, "Press the key you will use to correct the text you have entered.", true)
  logMsg(false, "Waiting for your input...", true)
  i = 0
  while i < 6000:
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if ie.ie_type == 1 and ie.value == 1: keyRpl = ie.code; break
    sleep(10); inc i
  discard close(kfd)
  if keyRpl == 0:
    logMsg(true, "Error reading the keyboard."); quit(1)
  logMsg(false, "Key " & keyNameSafe(keyRpl) & " captured", true)
  logMsg(false, "", true)
  sleep(500)

  logMsg(false, "Writing configuration file...", true)
  try:
    let cfg =
      "[WaylandSwitcher]\n" &
      "# This is WaylandSwitcher config file.\n\n" &
      "# Keyboard device path.\n" &
      "# Run '~$ hwinfo --keyboard --short' to get the list of your keyboard devices.\n" &
      "# keyboard=\"/dev/input/event2\"\n\n" &
      "keyboard=\"" & keyboardPath & "\"\n\n\n" &
      "# Mouse device path.\n" &
      "# Run '~$ hwinfo --mouse --short' to get the list of your mouse devices.\n" &
      "# mouse=\"/dev/input/mice\"\n\n" &
      "mouse=\"" & mousePath & "\"\n\n\n" &
      "# Scancode of the key or combination of keys used to\n" &
      "# switch the layout in your system.\n" &
      "# Run '~$ sudo showkey' to find out your key scancodes.\n" &
      "# layout-switch-key=125\n" &
      "# layout-switch-key=29+42\n\n" &
      "layout-switch-key=" & strKeysLs & "\n\n\n" &
      "# Scancode of the key to correct the text you have entered.\n" &
      "# Key combinations are not supported.\n" &
      "# PAUSE/BREAK key is used by default.\n" &
      "# Run '~$ sudo showkey' to find out your key scancodes.\n" &
      "# replace-key=119\n\n" &
      "replace-key=" & $keyRpl & "\n\n\n" &
      "# If reverse-mode is false, pressing <replace-key> corrects\n" &
      "# only last word you have entered. Pressing Shift + <replace-key> corrects\n" &
      "# the whole phrase.\n" &
      "# If reverse-mode is true, pressing <replace-key> corrects\n" &
      "# the whole phrase you have entered, and Shift + <replace-key> corrects\n" &
      "# only the last word.\n" &
      "# Default reverse-mode value is false\n" &
      "# reverse-mode=false\n\n" &
      "reverse-mode=" & (if reverseMode: "true" else: "false") & "\n\n\n" &
      "# WaylandSwitcher uses a delay to wait for your system to process the actions.\n" &
      "# The smaller delay is, the faster WaylandSwitcher works.\n" &
      "# However, your desktop environment may not be able to handle\n" &
      "# WaylandSwitcher output in a timely manner and you will get errors.\n" &
      "# Try to increase the delay if you get messy output.\n" &
      "# Default delay value is 10\n" &
      "# delay=10\n\n" &
      "delay=" & $delay & "\n"
    writeFile(CONFIG_FILE, cfg)
    logMsg(false, "Keyboard configuration successfully saved.")
    logMsg(false, "See " & CONFIG_FILE & " to edit additional parameters.")
  except CatchableError as e:
    logMsg(true, "Error writing configuration file " & CONFIG_FILE & " " & e.msg)

proc sigHandler(sig: cint) {.noconv.} =
  logMsg(false, "Got signal to exit (" & $sig & "). Bye.")
  stopAndExit = true

proc getBufferAction(): BufferAction =
  let last = len(keyBuf) - 1
  if len(keyBuf) < 2: return KeepBuffer
  if len(keyBuf) < 4:
    return if keyBuf[last].code == keyRpl and keyBuf[last].value == 0 and
              keyBuf[last-1].code == keyRpl and keyBuf[last-1].value == 1: ReplaceWord
           else: KeepBuffer
  # shiftd rpld shiftu rplu
  if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0   and
     keyBuf[last-1].code in Shifts and keyBuf[last-1].value == 0 and
     keyBuf[last-2].code == keyRpl and keyBuf[last-2].value == 1 and
     keyBuf[last-3].code in Shifts and keyBuf[last-3].value == 1: return ReplaceAll
  if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0 and
     keyBuf[last-1].code == keyRpl and keyBuf[last-1].value == 1:
    # shiftd rpld rplu  или  rpld rplu
    return if keyBuf[last-2].code in Shifts and keyBuf[last-2].value == 1: ReplaceAll
           else: ReplaceWord
  return KeepBuffer

proc getBufferStr(): string =
  for ev in keyBuf:
    add(result, keyNameSafe(ev.code) & " " & KeyAction[ev.value] & "; ")

proc prepareBuffer() =
  var
    buf  = keyBuf
    last = len(buf) - 1
  keyBuf = @[]

  # Убираем клавиши replace (и shift перед ними если есть)
  if last >= 3 and buf[last].code == keyRpl   and buf[last].value == 0   and
     buf[last-1].code in Shifts               and buf[last-1].value == 0 and
     buf[last-2].code == keyRpl               and buf[last-2].value == 1 and
     buf[last-3].code in Shifts               and buf[last-3].value == 1:
    last -= 4
  elif last >= 1 and buf[last].code == keyRpl and buf[last].value == 0 and
       buf[last-1].code == keyRpl             and buf[last-1].value == 1:
    last -= (if last >= 2 and buf[last-2].code in Shifts and buf[last-2].value == 1: 3 else: 2)
  buf = buf[0..last]

  # Оставляем только последнюю строку (после последнего Enter up)
  var res: seq[InputEvent] = @[]
  for idx, ev in buf:
    if (ev.code == KEY_ENTER or ev.code == KEY_KPENTER) and ev.value == 0 and
       idx != len(buf)-1:
      res = @[]
    else:
      add(res, ev)
  buf = res; res = @[]

  # Убираем смежные пары shift+shift (shift-down сразу за shift-down/up)
  for ev in buf:
    if ev.code in Shifts and len(res) > 0 and res[^1].code in Shifts:
      discard pop(res)
    else:
      add(res, ev)
  buf = res; res = @[]

  # Обрабатываем Backspace: точное воспроизведение Pascal-логики.
  # При BS удаляем последний элемент. Если новый последний — shift,
  # перемещаем его назад (перезаписываем элемент перед ним) и укорачиваем буфер.
  for ev in buf:
    if ev.code == KEY_BACKSPACE:
      if len(res) == 0: continue   # ведущий BS — игнорируем
      discard pop(res)             # убираем предыдущий символ
      if len(res) > 0 and res[^1].code in Shifts:
        # Pascal: oBuf[k-1] := oBuf[k] — shift сдвигается к предыдущей позиции
        if len(res) >= 2:
          res[^2] = res[^1]
        discard pop(res)
    else:
      add(res, ev)
  keyBuf = res
  sleep(10)

proc convert(vKbd: cint; singleWord: bool; delay: int) =
  var t: MyTimeVal
  discard c_clock_gettime(0, addr t)
  t.tv_usec = 0
  var startIdx = 0
  if singleWord:
    for n in 0 ..< len(keyBuf):
      if keyBuf[n].value == 0 and keyBuf[n].code == KEY_SPACE and n != len(keyBuf)-1:
        startIdx = n + 1

  var ieBuf: seq[InputEvent]
  template push(ev: InputEvent) =
    add(ieBuf, ev)
    t.tv_usec += 200

  # Отправляем BS для каждого нажатия (down/autorepeat) не-shift клавиши
  for n in startIdx ..< len(keyBuf):
    if keyBuf[n].value in [1'i32, 2] and keyBuf[n].code notin Shifts:
      push InputEvent(ie_type: EV_KEY, code: KEY_BACKSPACE, value: 1, time: t)
      push InputEvent(ie_type: EV_KEY, code: KEY_BACKSPACE, value: 0, time: t)

  # Переключение раскладки
  push InputEvent(ie_type: EV_KEY, code: keysLs[0], value: 1, time: t)
  if len(keysLs) == 2:
    push InputEvent(ie_type: EV_KEY, code: keysLs[1], value: 1, time: t)
    push InputEvent(ie_type: EV_KEY, code: keysLs[1], value: 0, time: t)
  push InputEvent(ie_type: EV_KEY, code: keysLs[0], value: 0, time: t)

  # Воспроизводим нажатия из буфера
  for n in startIdx ..< len(keyBuf):
    var ev = keyBuf[n]; ev.time = t; push ev

  # Эмитируем события попарно: key + SYN_REPORT
  for ev in ieBuf:
    var pair: array[2, InputEvent]
    pair[0] = ev
    pair[1] = InputEvent(ie_type: EV_SYN, code: SYN_REPORT, value: 0,
                         time: MyTimeVal(tv_sec:  ev.time.tv_sec,
                                         tv_usec: ev.time.tv_usec + 100))
    discard write(vKbd, addr pair[0], sizeof(InputEvent) * 2)
    logMsg(false, "output " & keyNameSafe(ev.code) & " " & KeyAction[ev.value], true)
    sleep(delay)

proc run() =
  logMsg(false, if daemonMode: "Starting WaylandSwitcher v" & VERSION & "..."
                else: "Starting WaylandSwitcher v" & VERSION & " in debug mode...")

  logMsg(false, "Setting up signal handlers...", true)
  signal(SIGHUP,  sigHandler)
  signal(SIGINT,  sigHandler)
  signal(SIGQUIT, sigHandler)
  signal(SIGTERM, sigHandler)
  logMsg(false, "Done.", true)

  logMsg(false, "Reading config...", true)
  if not fileExists(CONFIG_FILE):
    logMsg(true, "Missing config file " & CONFIG_FILE & ", run 'wayland-switcher -c' to configure.")
    quit(1)
  let
    kbdPath = readIniKey(CONFIG_FILE, "keyboard")
    mPath   = readIniKey(CONFIG_FILE, "mouse")
  strKeysLs = readIniKey(CONFIG_FILE, "layout-switch-key", "-1")
  keyRpl    = uint16(parseInt(readIniKey(CONFIG_FILE, "replace-key", "0")))
  let
    revMode = toLowerAscii(readIniKey(CONFIG_FILE, "reverse-mode", "false")) == "true"
    delay   = parseInt(readIniKey(CONFIG_FILE, "delay", "10"))
  if '+' in strKeysLs:
    let p = split(strKeysLs, '+')
    keysLs = @[uint16(parseInt(p[0])), uint16(parseInt(p[1]))]
  else:
    keysLs = @[uint16(parseInt(strKeysLs))]
  if kbdPath == "" or mPath == "" or len(keysLs) == 0 or keyRpl == 0:
    logMsg(true, "Error parsing config file."); quit(1)
  logMsg(false, "Done.", true)

  logMsg(false, "Opening keyboard...", true)
  var kfd = open(cstring(kbdPath), O_RDONLY or O_SYNC)
  if kfd == -1:
    logMsg(true, "Cannot open " & kbdPath & " " & $strerror(errno)); quit(1)
  logMsg(false, "Done.", true)

  logMsg(false, "Installing virtual keyboard...", true)
  let vfd = open(cstring(UINPUT_FILE), O_WRONLY or O_SYNC)
  if vfd == -1:
    logMsg(true, "Cannot open " & UINPUT_FILE & " " & $strerror(errno)); quit(1)
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
    logMsg(true, "Cannot install virtual keyboard. " & $strerror(errno)); quit(1)
  logMsg(false, "Done.", true)

  logMsg(false, "Getting mouse input...", true)
  mouseFDGlobal = open(cstring(mPath), O_RDONLY)
  if mouseFDGlobal == -1:
    logMsg(true, "Cannot open " & mPath & " " & $strerror(errno)); quit(1)
  var
    mTid:  Pthread
    mAttr: PthreadAttr
  discard pthread_attr_init(addr mAttr)
  discard pthread_create(addr mTid, addr mAttr,
    cast[proc(p: pointer): pointer {.noconv.}](mouseThreadFn), nil)
  discard pthread_attr_destroy(addr mAttr)
  logMsg(false, "Done.", true)

  logMsg(false, "WaylandSwitcher started successfully.")

  var ie: InputEvent
  while not stopAndExit:
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):
      if needClearKeyBuf:
        keyBuf = @[]; needClearKeyBuf = false
        logMsg(false, "buffer cleared", true)
      if ie.ie_type == EV_KEY and ie.value in [0'i32, 1]:
        logMsg(false, "input " & keyNameSafe(ie.code) & " " & KeyAction[ie.value], true)
        sleep(50)
        if ie.code in Letters or ie.code in Shifts or ie.code == keyRpl:
          add(keyBuf, InputEvent(ie_type: ie.ie_type, code: ie.code, value: ie.value))
          needTrackMouse = true
        if ie.code in BufKillers and ie.value == 0:
          keyBuf = @[]; needClearKeyBuf = false
          logMsg(false, "buffer cleared", true)
        if len(keyBuf) > 0 and
           ((ie.code == keyRpl and ie.value == 0) or
            (ie.code in Shifts and ie.value == 0)):
          let act = getBufferAction()
          if act != KeepBuffer:
            logMsg(false, "prepare buffer", true)
            logMsg(false, "  raw: " & getBufferStr(), true)
            prepareBuffer()
            logMsg(false, "  prepared: " & getBufferStr(), true)
            if (act == ReplaceAll) xor revMode:
              logMsg(false, "convert all", true); convert(vfd, false, delay)
            else:
              logMsg(false, "convert word", true); convert(vfd, true, delay)
            discard close(kfd)
            kfd = open(cstring(kbdPath), O_RDONLY or O_SYNC)
    else:
      sleep(10)

  discard close(kfd)
  discard close(mouseFDGlobal)
  discard c_ioctl(vfd, culong(UI_DEV_DESTROY), nil)
  discard close(vfd)

proc runDebug() =
  daemonMode = false
  run()

proc runOldStyleDaemon() =
  var pid = fork()
  if pid < 0: logMsg(true, "Failed to fork"); quit(1)
  if pid > 0: quit(0)
  let sid = setsid()
  if sid < 0: logMsg(true, "1st child process failed to become session leader"); quit(0)
  pid = fork()
  if pid < 0: logMsg(true, "Failed to fork from 1st child"); quit(1)
  if pid > 0: quit(0)
  discard umask(0)
  setCurrentDir("/")
  discard close(0); discard close(1); discard close(2)
  run()

proc runHelp() =
  daemonMode = false
  echo "WaylandSwitcher - keyboard layout switcher v" & VERSION
  echo ""
  echo "Usage: wayland-switcher [option]"
  echo ""
  echo "Options:"
  echo "   -i,   --install     install as systemd daemon"
  echo "   -u,   --uninstall   uninstall systemd daemon"
  echo "   -c,   --configure   configure WaylandSwitcher"
  echo "   -r,   --run         run"
  echo "   -d,   --debug       run in debug mode"
  echo "   -o,   --old-style   run as old-style (not systemd) daemon"
  echo "   -h,   --help        show this help"





when isMainModule:
  c_openlog("wayland-switcher", LOG_PID, LOG_DAEMON)
  if paramCount() != 1: runHelp()
  else:
    case paramStr(1)
    of "-i", "--install":   runInstall()
    of "-u", "--uninstall": runUninstall()
    of "-c", "--configure": runConfig()
    of "-r", "--run":       run()
    of "-d", "--debug":     runDebug()
    of "-o", "--old-style": runOldStyleDaemon()
    of "-h", "--help":      runHelp()
    else:                   runHelp()
  c_closelog()






