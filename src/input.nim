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

import posix, os
import types, core

# ── Привязки к libc ───────────────────────────────────────────────────────────

proc c_ioctl(fd: cint; req: culong; arg: pointer): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc c_clock_gettime(clk: cint; tp: pointer): cint
    {.importc: "clock_gettime", header: "<time.h>".}

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
