## buffer.nim — анализ буфера нажатий клавиш.
##
## Буфер — seq[InputEvent] с событиями клавиш текущей «порции» набранного
## текста. Им владеет исключительно главный поток.
##
## Жизненный цикл:
##   • каждый key-down/key-up из Letters, Shifts и клавиши коррекции
##     добавляется в буфер;
##   • BufKillers (Tab, Ctrl, Alt, стрелки…) и клик мыши сбрасывают буфер;
##   • getBufferAction смотрит на хвост буфера и решает, что делать;
##   • prepareBuffer убирает из буфера служебные события;
##   • vkbd.emitEvents воспроизводит результат на виртуальной клавиатуре.

import types

proc getBufferAction*(keyBuf: seq[InputEvent]; keyRpl: uint16): BufferAction =
  ## Анализирует хвост буфера и определяет, не завершён ли в нём один из
  ## распознаваемых паттернов (rpl — клавиша коррекции, D/U — down/up):
  ##
  ##   ReplaceWord — rplD rplU: клавиша коррекции без модификаторов,
  ##     заменяется только последнее слово.
  ##   ReplaceAll — Shift вместе с клавишей коррекции, в одном из двух видов:
  ##       shiftD rplD shiftU rplU   (Shift отпущен раньше клавиши коррекции)
  ##       shiftD rplD rplU          (Shift ещё удерживается)
  ##     заменяется вся фраза.
  ##
  ## Во всех остальных случаях возвращается KeepBuffer. Длина буфера
  ## проверяется заранее, чтобы индексы last-1..last-3 не вышли за границы.
  let last = len(keyBuf) - 1
  if len(keyBuf) < 2:
    return KeepBuffer

  if len(keyBuf) < 4:
    return if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0 and
              keyBuf[last-1].code == keyRpl and keyBuf[last-1].value == 1:
             ReplaceWord
           else:
             KeepBuffer

  if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0   and
     keyBuf[last-1].code in Shifts and keyBuf[last-1].value == 0 and
     keyBuf[last-2].code == keyRpl and keyBuf[last-2].value == 1 and
     keyBuf[last-3].code in Shifts and keyBuf[last-3].value == 1:
    return ReplaceAll

  if keyBuf[last].code == keyRpl   and keyBuf[last].value == 0 and
     keyBuf[last-1].code == keyRpl and keyBuf[last-1].value == 1:
    return if keyBuf[last-2].code in Shifts and keyBuf[last-2].value == 1:
             ReplaceAll
           else:
             ReplaceWord

  return KeepBuffer

proc getBufferStr*(keyBuf: seq[InputEvent]): string =
  ## Читаемое представление буфера для отладочного вывода.
  for ev in keyBuf:
    result.add(keyNameSafe(ev.code) & " " & KeyAction[ev.value] & "; ")

proc prepareBuffer*(keyBuf: var seq[InputEvent]; keyRpl: uint16) =
  ## Оставляет в буфере только «чистую» последовательность нажатий, которую
  ## можно воспроизвести в другой раскладке. Четыре этапа выполняются по
  ## порядку, каждый работает с результатом предыдущего:
  ##
  ##   1. Срезаются хвостовые события самой комбинации коррекции (клавиша
  ##      коррекции и, если был, Shift перед ней).
  ##   2. Остаётся только текст после последнего Enter: заменяется текущая
  ##      строка.
  ##   3. Удаляются смежные пары Shift+Shift — они ничего не печатают.
  ##   4. Применяются Backspace (см. ниже).
  var buf  = keyBuf
  var last = len(buf) - 1
  keyBuf = @[]

  # Этап 1: хвост комбинации коррекции.
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

  # Этап 2: только последняя строка.
  var res: seq[InputEvent]
  for idx, ev in buf:
    if (ev.code == KEY_ENTER or ev.code == KEY_KPENTER) and ev.value == 0 and
       idx != len(buf) - 1:
      res = @[]
    else:
      res.add(ev)
  buf = res
  res = @[]

  # Этап 3: смежные пары Shift+Shift.
  for ev in buf:
    if ev.code in Shifts and len(res) > 0 and res[^1].code in Shifts:
      discard res.pop()
    else:
      res.add(ev)
  buf = res
  res = @[]

  # Этап 4: Backspace.
  # Обрабатывается только key-down (в буфере лежат оба события нажатия).
  # Один Backspace удаляет один предыдущий символ — пару его key-down/key-up.
  # Если символ был обёрнут одноразовой парой Shift (Shift-down перед ним,
  # Shift-up после), удаляется и эта пара целиком: иначе в буфере остался бы
  # Shift-down без парного Shift-up, а при воспроизведении на виртуальной
  # клавиатуре композитор счёл бы Shift зажатым навсегда.
  for ev in buf:
    if ev.code == KEY_BACKSPACE:
      if ev.value != 1: continue
      if len(res) == 0: continue
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
