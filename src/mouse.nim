## mouse.nim — фоновый поток, различающий клик и протаскивание мышью.
##
## Читает сырые пакеты PS/2 из /dev/input/mice (по 3 байта):
##   байт 0 — состояние кнопок (бит 0 — левая);
##   байты 1–2 — знаковые смещения dx, dy с предыдущего пакета.
##
## Пока левая кнопка зажата, накапливается путь |dx|+|dy|. При отпускании:
##   • путь >= MouseDragThresholdPx — это протаскивание, то есть выделение
##     текста (GestureDrag);
##   • иначе — обычный клик (GestureClick): пользователь, вероятно, сменил
##     место ввода или окно, и накопленный буфер набора и выделение
##     устарели.
## Результат публикуется в core.mouseGesture; забирает его главный поток.

import posix, os, std/atomics
import types, core

proc mouseThreadFn*(fd: cint) {.thread.} =
  ## Тело потока. Работает, пока не взведён stopAndExit.
  var
    d:           array[3, uint8]
    leftWasDown  = false
    travelPx     = 0   ## путь курсора за время удержания кнопки

  while not stopAndExit.load():
    if not waitReadable(fd, 200): continue
    if read(fd, addr d[0], 3) != 3:
      sleep(10)   # ошибка чтения (например, устройство отключено)
      continue

    let leftDown = (d[0] and 0x01) != 0

    if leftDown and not leftWasDown:
      travelPx = 0
      logMsg(false, "mouse button down", stdOnly = true)

    elif leftDown and leftWasDown:
      travelPx += abs(int(cast[int8](d[1]))) + abs(int(cast[int8](d[2])))

    elif not leftDown and leftWasDown:
      logMsg(false, "mouse button up, travel=" & $travelPx & "px", stdOnly = true)
      if travelPx >= MouseDragThresholdPx:
        mouseGesture.store(GestureDrag)
        logMsg(false, "mouse drag", stdOnly = true)
      else:
        mouseGesture.store(GestureClick)
        logMsg(false, "mouse click", stdOnly = true)
      travelPx = 0

    leftWasDown = leftDown
