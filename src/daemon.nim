## daemon.nim — главный рабочий цикл службы.
##
## run() открывает физическую клавиатуру, создаёт виртуальную, запускает
## поток мыши и обрабатывает события клавиатуры, пока не придёт сигнал
## завершения. Состояние набора (буфер, модификаторы, признак выделения)
## хранится в Session и принадлежит главному потоку.

import posix, os, std/[atomics, typedthreads]
import types, core, config, buffer, vkbd, selection, mouse

type
  Session = object
    keyBuf:    seq[InputEvent]  ## буфер нажатий текущей «порции» текста
    shiftHeld: bool             ## Shift удерживается
    ctrlHeld:  bool             ## Ctrl удерживается
    selActive: bool             ## считается, что в приложении есть выделение

proc sigHandler(sig: cint) {.noconv.} =
  ## Только атомарная запись: всё остальное в обработчике сигнала небезопасно.
  stopAndExit.store(true)

proc openKeyboard(path: string): cint =
  ## Неблокирующее открытие: цикл ожидает ввод через poll с таймаутом.
  open(cstring(path), O_RDONLY or O_NONBLOCK)

proc handleKeyEvent(st: var Session; cfg: AppConfig; vfd: cint;
                    ie: InputEvent): bool =
  ## Обрабатывает одно событие клавиши (down или up). Возвращает true, если
  ## была выполнена коррекция и клавиатуру нужно переоткрыть, чтобы
  ## сбросить накопленную за это время очередь событий устройства.
  logMsg(false, "input " & keyNameSafe(ie.code) & " " & KeyAction[ie.value],
         stdOnly = true)

  # Жест мыши, случившийся с момента прошлого события клавиатуры.
  # Клик — универсальный признак смены места ввода: буфер и выделение
  # устарели. Протаскивание — пользователь выделил текст.
  case mouseGesture.exchange(GestureNone)
  of GestureClick:
    st.keyBuf    = @[]
    st.selActive = false
    logMsg(false, "буфер и выделение сброшены (клик мыши)", stdOnly = true)
  of GestureDrag:
    st.selActive = true
    logMsg(false, "выделение активно (мышь)", stdOnly = true)
  else:
    discard

  if ie.code in Shifts: st.shiftHeld = ie.value == 1
  if ie.code in Ctrls:  st.ctrlHeld  = ie.value == 1

  # Выделение Shift + навигационная клавиша: фиксируется на key-up.
  if st.shiftHeld and ie.code in SelectionKeys and ie.value == 0:
    st.selActive = true
    logMsg(false, "выделение активно (клавиатура)", stdOnly = true)

  # Выделение Ctrl+A: фиксируется на key-DOWN клавиши A. Порядок отпускания
  # клавиш в сочетании не гарантирован (Ctrl часто отпускают раньше A), а
  # порядок нажатия гарантирован. Буфер набора очищается: к дописыванию
  # прежней фразы после «выделить всё» обычно не возвращаются.
  if st.ctrlHeld and ie.code == KEY_A and ie.value == 1:
    st.selActive = true
    st.keyBuf    = @[]
    logMsg(false, "выделение активно (Ctrl+A)", stdOnly = true)

  # Escape и Enter снимают выделение. Клавиша коррекции и Shift не снимают:
  # они нужны для самой коррекции.
  if ie.value == 1 and ie.code in SelBreakers:
    st.selActive = false

  # Стрелки без Shift сдвигают курсор и снимают выделение.
  if ie.value == 1 and ie.code in SelectionKeys and not st.shiftHeld:
    st.selActive = false

  # Tab и Alt — единственный доступный косвенный признак смены окна или
  # поля без клика мышью (событий фокуса от композитора у нас нет).
  if ie.value == 1 and ie.code in FocusKeys:
    st.selActive = false

  # Обычный набор текста гарантированно означает, что прежнее выделение
  # уже не актуально (его заменил ввод или пользователь работает в другом
  # месте). Клавиша коррекции и сочетания с Ctrl исключены.
  if st.selActive and ie.value == 1 and ie.code in Letters and
     ie.code != cfg.keyRpl and not st.ctrlHeld:
    st.selActive = false

  # Коррекция выделенного текста запускается на key-up клавиши коррекции,
  # чтобы она не попала в приложение как обычный символ.
  if st.selActive and ie.code == cfg.keyRpl and ie.value == 0:
    logMsg(false, "коррекция выделенного текста", stdOnly = true)
    sleep(50)   # дать композитору обработать отпускание клавиши коррекции
    emitSelectionCorrection(vfd, cfg.keysLs, cfg.clipTool, cfg.delayMs)
    st.selActive = false
    st.keyBuf    = @[]
    return true

  if st.selActive:
    return false

  # Обычный режим: накопление и замена набранного текста. Буквы с зажатым
  # Ctrl не накапливаются: это команды (Ctrl+S, Ctrl+Z…), а не текст.
  if (ie.code in Letters or ie.code in Shifts or ie.code == cfg.keyRpl) and
     not st.ctrlHeld:
    st.keyBuf.add(InputEvent(evType: ie.evType, code: ie.code, value: ie.value))

  # Служебные клавиши (Tab, Ctrl, Alt, стрелки…) сбрасывают буфер; клавиша
  # коррекции управляет заменой и буфер не сбрасывает.
  if ie.code in BufKillers and ie.code != cfg.keyRpl and ie.value == 0:
    st.keyBuf = @[]
    logMsg(false, "буфер очищен", stdOnly = true)

  # Буфер анализируется на key-up клавиши коррекции или Shift.
  if len(st.keyBuf) > 0 and ie.value == 0 and
     (ie.code == cfg.keyRpl or ie.code in Shifts):
    let act = getBufferAction(st.keyBuf, cfg.keyRpl)
    if act != KeepBuffer:
      logMsg(false, "  сырой буфер: " & getBufferStr(st.keyBuf), stdOnly = true)
      prepareBuffer(st.keyBuf, cfg.keyRpl)
      logMsg(false, "  подготовленный буфер: " & getBufferStr(st.keyBuf),
             stdOnly = true)

      # singleWord=true — заменить только последнее слово.
      let singleWord = (act == ReplaceWord) xor cfg.reverseMode
      logMsg(false, if singleWord: "замена слова" else: "замена всей фразы",
             stdOnly = true)
      sleep(50)   # дать композитору обработать отпускание клавиши коррекции
      emitEvents(vfd, st.keyBuf, cfg.keysLs, singleWord, cfg.delayMs)
      return true

  return false

proc run*() =
  ## Запускает службу и работает до сигнала завершения.
  initSharedState()
  logMsg(false,
    if daemonMode: "Запуск WaylandSwitcher v" & VERSION & "..."
    else:          "Запуск WaylandSwitcher v" & VERSION & " в режиме отладки...")

  # SIGHUP, SIGINT, SIGQUIT и SIGTERM завершают работу. Конфиг
  # перечитывается перезапуском службы. SIGPIPE игнорируется: запись в
  # канал без читателя (см. clipboard.writeClipboard) не должна убивать службу.
  signal(SIGHUP,  sigHandler)
  signal(SIGINT,  sigHandler)
  signal(SIGQUIT, sigHandler)
  signal(SIGTERM, sigHandler)
  signal(SIGPIPE, SIG_IGN)

  let cfg =
    try: loadConfig(CONFIG_FILE)
    except ConfigError as e:
      logMsg(true, e.msg); quit(1)

  var kfd = openKeyboard(cfg.kbdPath)
  if kfd == -1:
    logMsg(true, "Не удалось открыть " & cfg.kbdPath & ": " & $strerror(errno))
    quit(1)

  let vfd =
    try: openVKbd()
    except VKbdError as e:
      logMsg(true, e.msg); discard close(kfd); quit(1)

  let mfd = open(cstring(cfg.mousePath), O_RDONLY or O_NONBLOCK)
  if mfd == -1:
    logMsg(true, "Не удалось открыть " & cfg.mousePath & ": " & $strerror(errno))
    closeVKbd(vfd); discard close(kfd); quit(1)
  var mouseThread: Thread[cint]
  createThread(mouseThread, mouseThreadFn, mfd)

  logMsg(false, "WaylandSwitcher запущен.")

  var st: Session
  while not stopAndExit.load():
    if not waitReadable(kfd, 200): continue
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) != sizeof(ie):
      sleep(10)   # ошибка чтения (например, устройство отключено)
      continue
    # Autorepeat (value=2) не обрабатывается; emitEvents учитывает его,
    # если он оказался в буфере.
    if ie.evType != EV_KEY or ie.value notin [0'i32, 1]: continue

    if handleKeyEvent(st, cfg, vfd, ie):
      # Пока шла коррекция, ядро накопило в очереди устройства события,
      # которые не должны считаться новым вводом. Переоткрытие сбрасывает очередь.
      discard close(kfd)
      kfd = openKeyboard(cfg.kbdPath)
      if kfd == -1:
        logMsg(true, "Не удалось переоткрыть клавиатуру: " & $strerror(errno))
        stopAndExit.store(true)

  logMsg(false, "Получен сигнал завершения. До свидания.")
  joinThread(mouseThread)
  discard close(kfd)
  discard close(mfd)
  closeVKbd(vfd)
