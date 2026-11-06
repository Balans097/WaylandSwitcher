## vkbd.nim — виртуальная клавиатура на базе Linux uinput.
##
## openVKbd регистрирует виртуальное устройство в /dev/uinput; остальные
## процедуры посылают на него события. Каждое событие отправляется парой
## [EV_KEY, SYN_REPORT] — SYN_REPORT сообщает получателю, что пакет
## завершён. После каждого события выдерживается пауза delayMs, чтобы
## композитор и приложение успевали обработать ввод.

import posix, os, std/tables
import types, core

proc c_ioctl(fd: cint; req: culong; arg: pointer): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

type VKbdError* = object of CatchableError

proc openVKbd*(): cint =
  ## Открывает /dev/uinput и создаёт виртуальное устройство, поддерживающее
  ## клавиши с кодами 0..248. Возвращает дескриптор; при ошибке бросает VKbdError.
  let vfd = open(cstring(UINPUT_FILE), O_WRONLY or O_NONBLOCK)
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
  ## Уничтожает виртуальное устройство и закрывает дескриптор.
  discard c_ioctl(vfd, culong(UI_DEV_DESTROY), nil)
  discard close(vfd)

proc sendKey*(vfd: cint; code: uint16; value: int32; delayMs: int) =
  ## Посылает одно событие клавиши (value: 1 — down, 0 — up) и SYN_REPORT,
  ## затем ждёт delayMs миллисекунд. Метки времени не заполняются: для
  ## uinput ядро проставляет их само.
  var pair: array[2, InputEvent]
  pair[0] = InputEvent(evType: EV_KEY, code: code, value: value)
  pair[1] = InputEvent(evType: EV_SYN, code: SYN_REPORT, value: 0)
  if write(vfd, addr pair[0], sizeof(InputEvent) * 2) != sizeof(InputEvent) * 2:
    logMsg(true, "Ошибка записи в uinput: " & $strerror(errno))
  logMsg(false, "output " & keyNameSafe(code) & " " & KeyAction[value],
         stdOnly = true)
  sleep(delayMs)

proc tapKey*(vfd: cint; code: uint16; delayMs: int) =
  ## Нажимает и отпускает клавишу.
  sendKey(vfd, code, 1, delayMs)
  sendKey(vfd, code, 0, delayMs)

proc pressChord*(vfd: cint; modifier, key: uint16; delayMs: int) =
  ## Нажимает сочетание «модификатор + клавиша» (например, Ctrl+C).
  sendKey(vfd, modifier, 1, delayMs)
  tapKey(vfd, key, delayMs)
  sendKey(vfd, modifier, 0, delayMs)

proc switchLayout*(vfd: cint; keysLs: seq[uint16]; delayMs: int) =
  ## Нажимает клавишу или сочетание из двух клавиш, переключающее раскладку.
  if len(keysLs) == 2:
    pressChord(vfd, keysLs[0], keysLs[1], delayMs)
  else:
    tapKey(vfd, keysLs[0], delayMs)

proc emitEvents*(vfd: cint; keyBuf: seq[InputEvent];
                 keysLs: seq[uint16]; singleWord: bool; delayMs: int) =
  ## Исправляет текст, набранный в неверной раскладке, тремя шагами:
  ##   1. Backspace по числу набранных символов (события down и autorepeat,
  ##      кроме Shift, который сам ничего не печатает).
  ##   2. Переключение раскладки (keysLs).
  ##   3. Повтор нажатий из keyBuf: те же клавиши дают уже другие символы.
  ##
  ## singleWord=true — берётся только последнее слово (то, что после
  ## последнего пробела), иначе вся фраза.
  var startIdx = 0
  if singleWord:
    for n in 0 ..< len(keyBuf):
      if keyBuf[n].value == 0 and keyBuf[n].code == KEY_SPACE and
         n != len(keyBuf) - 1:
        startIdx = n + 1

  for n in startIdx ..< len(keyBuf):
    if keyBuf[n].value in [1'i32, 2] and keyBuf[n].code notin Shifts:
      tapKey(vfd, KEY_BACKSPACE, delayMs)

  switchLayout(vfd, keysLs, delayMs)

  var held = initTable[uint16, bool]()
  for n in startIdx ..< len(keyBuf):
    let ev = keyBuf[n]
    sendKey(vfd, ev.code, ev.value, delayMs)
    if ev.value == 1:
      held[ev.code] = true
    elif ev.value == 0:
      held.del(ev.code)

  # Страховка. Воспроизводимые события — копия живого ввода, и prepareBuffer
  # не может гарантировать, что у каждого down есть свой up (например, Shift
  # физически ещё зажат, когда отпускается клавиша коррекции). Клавиша,
  # оставшаяся нажатой на виртуальном устройстве, считалась бы зажатой
  # навсегда («залипший Shift»), поэтому всё, что осталось нажатым по нашему
  # подсчёту, принудительно отпускается. Состояние физической клавиатуры это
  # не затрагивает.
  var stuck: seq[uint16]
  for code in held.keys:
    stuck.add(code)
  for code in stuck:
    sendKey(vfd, code, 0, delayMs)
    logMsg(false, "страховка: принудительно отпущена клавиша " & keyNameSafe(code),
           stdOnly = true)
