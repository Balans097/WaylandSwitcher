## core.nim — состояние, разделяемое между потоками, ожидание ввода и логирование.
##
## ── Разделяемое состояние ────────────────────────────────────────────────────
##
##   Переменные, к которым обращаются сразу несколько потоков, объявлены как
##   Atomic из std/atomics (по умолчанию — полный барьер памяти). Буфер
##   набранных клавиш принадлежит исключительно главному потоку и
##   синхронизации не требует.
##
## ── Логирование ──────────────────────────────────────────────────────────────
##
##   logMsg направляет сообщения так:
##     • daemonMode=true  — в syslog; сообщения с stdOnly=true отбрасываются;
##     • daemonMode=false — только в stdout, syslog не используется.
##
##   Вызывать logMsg из обработчика сигнала нельзя (async-signal-unsafe):
##   обработчик лишь взводит stopAndExit, а о завершении сообщает главный цикл.

import std/atomics
import types

# ── Разделяемое состояние ─────────────────────────────────────────────────────

const
  ## Жест мыши, зафиксированный потоком мыши и ещё не обработанный главным потоком.
  GestureNone* = 0   ## с момента последней обработки жестов не было
  GestureDrag* = 1   ## протаскивание с зажатой левой кнопкой (выделение текста)
  GestureClick* = 2  ## обычный клик (вероятная смена места ввода или фокуса)

var
  ## Запрос на остановку: взводится обработчиком сигнала, проверяется всеми
  ## рабочими циклами.
  stopAndExit*: Atomic[bool]

  ## Последний жест мыши. Поток мыши записывает его, главный поток забирает
  ## атомарным обменом на GestureNone; побеждает самый поздний жест.
  mouseGesture*: Atomic[int]

proc initSharedState*() =
  ## Приводит разделяемое состояние в исходное. Вызывать до запуска потоков.
  stopAndExit.store(false)
  mouseGesture.store(GestureNone)

# ── Ожидание ввода ────────────────────────────────────────────────────────────

type
  PollFd {.importc: "struct pollfd", header: "<poll.h>", bycopy.} = object
    fd: cint
    events: cshort
    revents: cshort

const PollIn = 0x0001.cshort

proc c_poll(fds: ptr PollFd; nfds: culong; timeout: cint): cint
    {.importc: "poll", header: "<poll.h>".}

proc waitReadable*(fd: cint; timeoutMs: int): bool =
  ## Ждёт до timeoutMs миллисекунд, пока из fd можно будет читать.
  ## Возвращает true, если устройство готово (или сообщает об ошибке —
  ## тогда последующий read() вернёт её), и false по таймауту либо при
  ## прерывании сигналом. Благодаря ограниченному ожиданию рабочие циклы
  ## регулярно проверяют stopAndExit и завершаются по SIGTERM, не дожидаясь
  ## очередного нажатия клавиши.
  var p = PollFd(fd: fd, events: PollIn, revents: 0)
  c_poll(addr p, 1, cint(timeoutMs)) > 0

# ── Логирование ───────────────────────────────────────────────────────────────

var
  ## true  — демон: вывод идёт в syslog.
  ## false — интерактивный режим: вывод идёт в stdout.
  daemonMode*: bool = true

proc c_openlog*(id: cstring; opt, fac: cint) {.importc: "openlog",  header: "<syslog.h>".}
proc c_syslog*(pri: cint; fmt: cstring)       {.importc: "syslog",   header: "<syslog.h>", varargs.}
proc c_closelog*()                             {.importc: "closelog", header: "<syslog.h>".}

proc logMsg*(isErr: bool; msg: string; stdOnly = false) =
  ## Записывает сообщение согласно текущему режиму работы.
  ##   isErr   — true: приоритет LOG_ERR, иначе LOG_INFO.
  ##   stdOnly — трассировочное сообщение: показывается только в
  ##             интерактивном режиме и не попадает в системный журнал.
  if daemonMode:
    if not stdOnly:
      c_syslog(if isErr: LOG_ERR else: LOG_INFO, "%s", cstring(msg))
  else:
    echo msg
