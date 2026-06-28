## WaylandSwitcher.nim — главный модуль.
##
## Компиляция:
##   nim c --threads:on -d:release WaylandSwitcher.nim
##
## Версия:   0.10
## Дата:     2026-06-28
## Автор:    github.com/Balans097
##
## История изменений:
##   0.11 — коррекция выделенного текста (мышью / Shift+стрелками) реально
##          заработала. Было два бага:
##            1. emitSelectionCorrection сравнивала CLIPBOARD до и после
##               Ctrl+C и ложно прерывала коррекцию, если текст совпадал
##               с тем, что уже лежало в буфере (например, при повторной
##               коррекции одной и той же фразы) — проверка убрана.
##            2. Самого главного шага — перекодировки текста между
##               раскладками — не было вовсе: переключалась системная
##               раскладка, но в CLIPBOARD записывался тот же самый текст,
##               без изменений, так что видимый результат не менялся.
##               Добавлена посимвольная таблица соответствия EN(QWERTY) ↔
##               RU(ЙЦУКЕН) по позициям клавиш (input.nim: convertLayout) —
##               именно она теперь и выполняет коррекцию (2026-06-28)
##   0.10 — исправлено выделение текста мышью: раньше mouseSelActive
##          снимался в момент отпускания кнопки, то есть ровно тогда,
##          когда выделение фактически сформировано — selActive никогда
##          не взводился для drag-выделения мышью. Теперь mouseThreadFn
##          копит пройденный курсором путь и при отпускании отличает клик
##          от drag по порогу MouseDragThresholdPx; для drag выставляется
##          mouseSelDone, который главный цикл подхватывает один раз
##          (read-and-clear) на следующем событии клавиатуры (2026-06-28)
##   0.9 — рефакторинг кода модулей (2026-04-22)
##   0.8 — рефакторинг: разбивка на модули, исправление конкурентности,
##          валидации конфига и управления жизненным циклом (2026-04-22)
##   0.7 — приложение доведено до рабочего состояния (2026-04-22)
##   0.1 — начальная реализация (2026-04-18)
##
## Структура модулей:
##   types.nim  — общие типы, константы, утилиты
##   core.nim   — разделяемое состояние (Atomic-флаги) + подсистема логирования
##   input.nim  — буфер нажатий клавиш + виртуальная клавиатура uinput
##   setup.nim  — конфиг, интерактивная настройка, управление systemd-юнитом
##   (этот файл) — фоновые потоки, главный цикл, точка входа




import posix, os, std/atomics
import src/[types, core, input, setup]




# ── Фоновый поток мыши ────────────────────────────────────────────────────────

proc mouseThreadFn*(arg: pointer) {.thread.} =
  ## Отслеживает левую кнопку мыши, чтобы отличить:
  ##   • обычный клик   — нажал и отпустил почти не двигая курсор;
  ##   • drag-выделение — нажал, протащил курсор дальше порога, отпустил.
  ## Читает сырые пакеты по 3 байта из mouseFDGlobal (протокол PS/2).
  ##
  ## Протокол /dev/input/mice (PS/2):
  ##   байт 0: биты состояния кнопок; биты [2:0] = левая, правая, средняя
  ##   байты 1–2: знаковые смещения X, Y с прошлого пакета (int8)
  ## Бит 0 байта состояния (BTL_LEFT) означает, что левая кнопка нажата.
  ##
  ## Различение клика и drag:
  ##   Пока кнопка зажата, в travelPx накапливается сумма |dx|+|dy| по всем
  ##   пакетам. В момент отпускания сравниваем накопленное смещение
  ##   с MouseDragThresholdPx:
  ##     • смещение <  порога → это клик. Если в этот момент главный поток
  ##       накапливал буфер набора текста (needTrackMouse=true) — это был
  ##       случайный клик посреди набора, просим главный поток сбросить буфер.
  ##     • смещение >= порога → это drag, то есть пользователь выделил
  ##       текст. Выставляем mouseSelDone=true; главный поток подхватит
  ##       флаг на следующем событии клавиатуры и взведёт selActive.
  ##
  ## mouseSelActive отражает только «кнопка зажата прямо сейчас» — это
  ## отдельное от mouseSelDone состояние, используется лишь для логов.
  var
    d:            array[3, uint8]
    leftWasDown:  bool = false
    travelPx:     int  = 0   ## суммарный путь курсора за время удержания кнопки

  while not stopAndExit.load():
    let n = read(mouseFDGlobal, addr d[0], 3)
    if n == 3:
      let leftDown = (d[0] and 0x01) != 0   ## бит 0 = левая кнопка

      if leftDown and not leftWasDown:
        # Нажатие — начало возможного drag-выделения. Сбрасываем счётчик пути.
        travelPx = 0
        mouseSelActive.store(true)
        logMsg(false, "mouse btn down → mouseSelActive=true", stdOnly = true)

      elif leftDown and leftWasDown:
        # Кнопка удерживается — накапливаем пройденный путь.
        # Байты 1 и 2 — знаковые int8 со смещением dx, dy с прошлого пакета.
        let dx = cast[int8](d[1])
        let dy = cast[int8](d[2])
        travelPx += abs(int(dx)) + abs(int(dy))

      elif not leftDown and leftWasDown:
        # Отпускание — решаем, был это клик или drag-выделение.
        mouseSelActive.store(false)
        logMsg(false, "mouse btn up, travel=" & $travelPx & "px", stdOnly = true)

        if travelPx >= MouseDragThresholdPx:
          # Drag: текст выделен. Главный поток подхватит на следующем
          # событии клавиатуры. needTrackMouse трогать не нужно — drag не
          # связан с сохранённым буфером набора текста.
          mouseSelDone.store(true)
          logMsg(false, "mouse drag → mouseSelDone=true", stdOnly = true)
        elif needTrackMouse.load():
          # Клик (не drag) во время накопления буфера — случайный клик,
          # сбрасываем буфер набора текста.
          needTrackMouse.store(false)
          needClearKeyBuf.store(true)
          logMsg(false, "mouse click: buffer clearing queued", stdOnly = true)

        travelPx = 0

      leftWasDown = leftDown


# ── Обработчик сигналов ───────────────────────────────────────────────────────

## Проблема, решённая здесь:
##   Оригинальный sigHandler строил строки и вызывал logMsg (syslog) прямо
##   в контексте обработки сигнала — это async-signal-unsafe UB.
##   Исправление: только атомарная запись флага. Логирование — в главном цикле.
proc sigHandler(sig: cint) {.noconv.} =
  stopAndExit.store(true)

# ── Главный рабочий цикл ─────────────────────────────────────────────────────

proc run() =
  logMsg(false,
    if daemonMode: "Запуск WaylandSwitcher v" & VERSION & "..."
    else:          "Запуск WaylandSwitcher v" & VERSION & " в режиме отладки...")

  # Установка обработчиков: SIGHUP (перезагрузка конфига), SIGINT, SIGQUIT, SIGTERM
  logMsg(false, "Установка обработчиков сигналов...", stdOnly = true)
  signal(SIGHUP,  sigHandler)
  signal(SIGINT,  sigHandler)
  signal(SIGQUIT, sigHandler)
  signal(SIGTERM, sigHandler)
  logMsg(false, "Готово.", stdOnly = true)

  # Загрузка конфигурации — прерываем запуск при любой ошибке
  logMsg(false, "Чтение конфига...", stdOnly = true)
  let cfg =
    try: loadConfig(CONFIG_FILE)
    except ConfigError as e:
      logMsg(true, e.msg); quit(1)
  logMsg(false, "Готово.", stdOnly = true)

  # Открытие физической клавиатуры
  logMsg(false, "Открытие клавиатуры...", stdOnly = true)
  var kfd = open(cstring(cfg.kbdPath), O_RDONLY or O_SYNC)
  if kfd == -1:
    logMsg(true, "Не удалось открыть " & cfg.kbdPath & ": " & $strerror(errno))
    quit(1)
  logMsg(false, "Готово.", stdOnly = true)

  # Создание виртуальной клавиатуры через /dev/uinput
  logMsg(false, "Установка виртуальной клавиатуры...", stdOnly = true)
  let vfd =
    try: openVKbd()
    except VKbdError as e:
      logMsg(true, e.msg); discard close(kfd); quit(1)
  logMsg(false, "Готово.", stdOnly = true)

  # Подключение мыши и запуск фонового потока-монитора
  logMsg(false, "Подключение мыши...", stdOnly = true)
  mouseFDGlobal = open(cstring(cfg.mousePath), O_RDONLY)
  if mouseFDGlobal == -1:
    logMsg(true, "Не удалось открыть " & cfg.mousePath & ": " & $strerror(errno))
    closeVKbd(vfd); discard close(kfd); quit(1)
  var
    mTid:  Pthread
    mAttr: PthreadAttr
  discard pthread_attr_init(addr mAttr)
  discard pthread_create(addr mTid, addr mAttr,
    cast[proc(p: pointer): pointer {.noconv.}](mouseThreadFn), nil)
  discard pthread_attr_destroy(addr mAttr)
  logMsg(false, "Готово.", stdOnly = true)

  logMsg(false, "WaylandSwitcher запущен.")

  # ── Главный цикл чтения событий ───────────────────────────────────────────
  var
    keyBuf:    seq[InputEvent]  ## буфер нажатий текущей «порции» текста
    shiftHeld: bool = false     ## удерживается ли Shift прямо сейчас
    ctrlHeld:  bool = false     ## удерживается ли Ctrl
    selActive: bool = false     ## есть ли активное выделение (Shift+стрелка)
    selCount:  int  = 0         ## количество символов в выделении

  while not stopAndExit.load():
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):

      # Поток мыши запросил сброс буфера
      if needClearKeyBuf.load():
        needClearKeyBuf.store(false)
        keyBuf    = @[]
        selActive = false
        selCount  = 0
        logMsg(false, "буфер очищен", stdOnly = true)

      # Обрабатываем только key-down (1) и key-up (0);
      # autorepeat (2) здесь отбрасываем, но emitEvents учитывает его
      # при подсчёте BS (нажатая и удерживаемая клавиша = один символ).
      if ie.ie_type == EV_KEY and ie.value in [0'i32, 1]:
        logMsg(false, "input " & keyNameSafe(ie.code) & " " & KeyAction[ie.value],
               stdOnly = true)

        # ── Отслеживание состояния модификаторов ────────────────────────────
        if ie.code in Shifts: shiftHeld = ie.value == 1
        if ie.code in Ctrls:  ctrlHeld  = ie.value == 1

        # ── Обнаружение выделения: Shift + навигационная клавиша ────────────
        # Фиксируем выделение на key-up навигационной клавиши при Shift.
        # ВНИМАНИЕ: selCount считает только события key-up — по одному на
        # каждое «отдельное» нажатие стрелки. При удержании стрелки ядро
        # генерирует autorepeat (value=2), которые здесь отброшены фильтром
        # ie.value in [0, 1]; из-за этого selCount занижен при удержании.
        # selCount НЕ используется для подсчёта Backspace в коррекции —
        # там длина берётся из runeLen(selText). Поле оставлено для отладки.
        if shiftHeld and ie.code in SelectionKeys and ie.value == 0:
          if not selActive:
            selActive = true
            selCount  = 0
          inc selCount
          logMsg(false, "выделение активно (клавиатура), key-up счётчик: " & $selCount &
                 " (при удержании стрелки может быть занижен)", stdOnly = true)

        # Выделение мышью: поток мыши выставляет mouseSelDone=true один раз,
        # в момент отпускания кнопки после реального drag (не клика).
        # Здесь делаем read-and-clear: подхватываем флаг и сразу гасим его,
        # чтобы не взвести selActive повторно на следующем же событии.
        # selCount не считаем — передадим 0 в emitSelectionCorrection,
        # она сама определит длину по факту прочитанного PRIMARY selection.
        if mouseSelDone.load():
          mouseSelDone.store(false)
          selActive = true
          selCount  = 0
          logMsg(false, "выделение активно (мышь, drag завершён)", stdOnly = true)

        # Сбрасываем выделение только на key-down клавиш, которые
        # гарантированно его снимают (стрелки без Shift, Escape, Enter).
        # keyRpl и Shift НЕ сбрасывают — они нужны для работы коррекции.
        const SelBreakers = {1'u16,   ## KEY_ESC
                             28'u16,  ## KEY_ENTER
                             96'u16}  ## KEY_KPENTER
        if ie.value == 1 and ie.code in SelBreakers:
          if selActive:
            logMsg(false, "выделение сброшено", stdOnly = true)
          selActive = false
          selCount  = 0

        # Стрелки без Shift — курсор сдвинулся, выделение снято
        if ie.value == 1 and ie.code in SelectionKeys and not shiftHeld:
          if selActive:
            logMsg(false, "выделение сброшено (стрелка без Shift)", stdOnly = true)
          selActive = false
          selCount  = 0

        sleep(50)

        # ── Коррекция выделенного текста ────────────────────────────────────
        # Нажатие keyRpl при активном выделении запускает коррекцию.
        # Срабатывает на key-up, чтобы keyRpl не попал в буфер приложения.
        if selActive and ie.code == cfg.keyRpl and ie.value == 0:
          logMsg(false, "коррекция выделенного текста", stdOnly = true)
          emitSelectionCorrection(vfd, cfg.keysLs, cfg.clipTool, cfg.delayMs, selCount)
          selActive = false
          selCount  = 0
          keyBuf    = @[]
          discard close(kfd)
          kfd = open(cstring(cfg.kbdPath), O_RDONLY or O_SYNC)
          if kfd == -1:
            logMsg(true, "Критическая ошибка: не удалось переоткрыть клавиатуру: " &
                   $strerror(errno))
            stopAndExit.store(true)

        # ── Обычный режим: накопление и замена введённого текста ────────────
        elif not selActive:

          # Добавляем в буфер буквы, цифры, shift и клавишу замены
          if ie.code in Letters or ie.code in Shifts or ie.code == cfg.keyRpl:
            keyBuf.add(InputEvent(ie_type: ie.ie_type, code: ie.code, value: ie.value))
            needTrackMouse.store(true)

          # Служебные клавиши (Tab, Ctrl, Alt, стрелки…) сбрасывают буфер.
          # keyRpl исключён — он управляет заменой, а не сбросом.
          if ie.code in BufKillers and ie.code != cfg.keyRpl and ie.value == 0:
            keyBuf = @[]
            logMsg(false, "буфер очищен", stdOnly = true)

          # Анализируем буфер при key-up клавиши замены или shift
          if len(keyBuf) > 0 and
             ((ie.code == cfg.keyRpl and ie.value == 0) or
              (ie.code in Shifts     and ie.value == 0)):
            let act = getBufferAction(keyBuf, cfg.keyRpl)
            if act != KeepBuffer:
              logMsg(false, "подготовка буфера",                   stdOnly = true)
              logMsg(false, "  сырой: " & getBufferStr(keyBuf),    stdOnly = true)
              prepareBuffer(keyBuf, cfg.keyRpl)
              logMsg(false, "  подготовлен: " & getBufferStr(keyBuf), stdOnly = true)

              # singleWord=true → заменить только последнее слово
              let singleWord = (act == ReplaceWord) xor cfg.reverseMode
              logMsg(false,
                if singleWord: "замена слова" else: "замена всей фразы",
                stdOnly = true)

              emitEvents(vfd, keyBuf, cfg.keysLs, singleWord, cfg.delayMs)

              # После эмиссии переоткрываем клавиатуру, чтобы сбросить
              # буфер ядра. Проверяем успешность open() — критическая ошибка.
              discard close(kfd)
              kfd = open(cstring(cfg.kbdPath), O_RDONLY or O_SYNC)
              if kfd == -1:
                logMsg(true, "Критическая ошибка: не удалось переоткрыть клавиатуру: " &
                       $strerror(errno))
                stopAndExit.store(true)
    else:
      sleep(10)   ## нет данных — уступаем CPU

  # Сигнал завершения получен; логируем здесь (async-signal-safe)
  logMsg(false, "Получен сигнал завершения. До свидания.")

  discard close(kfd)
  discard close(mouseFDGlobal)
  closeVKbd(vfd)

# ── Режим отладки ─────────────────────────────────────────────────────────────

proc runDebug() =
  ## Запускает главный цикл в терминале без форка и без syslog.
  daemonMode = false
  initSharedState()
  run()

# ── Классический Unix-демон (не systemd) ──────────────────────────────────────

proc runOldStyleDaemon() =
  ## Двойной fork по рекомендации POSIX:
  ##   1-й fork: родитель завершается, дочерний вызывает setsid() → новая сессия.
  ##   2-й fork: гарантирует, что процесс никогда не получит управляющий терминал.
  var pid = fork()
  if pid < 0: logMsg(true, "Ошибка fork()"); quit(1)
  if pid > 0: quit(0)
  let sid = setsid()
  if sid < 0: logMsg(true, "Первый дочерний процесс не смог стать лидером сессии"); quit(1)
  pid = fork()
  if pid < 0: logMsg(true, "Ошибка второго fork()"); quit(1)
  if pid > 0: quit(0)
  discard umask(0)
  setCurrentDir("/")
  # Закрываем стандартные дескрипторы: терминал нам больше не нужен
  discard close(0)
  discard close(1)
  discard close(2)
  initSharedState()
  run()

# ── Справка ───────────────────────────────────────────────────────────────────

proc runHelp() =
  daemonMode = false
  echo "WaylandSwitcher - переключатель раскладки клавиатуры v" & VERSION
  echo ""
  echo "Использование: wayland-switcher [параметр]"
  echo ""
  echo "Параметры:"
  echo "   -i,   --install     установить как systemd-демон"
  echo "   -u,   --uninstall   удалить systemd-демон"
  echo "   -c,   --configure   настроить WaylandSwitcher"
  echo "   -r,   --run         запустить"
  echo "   -d,   --debug       запустить в режиме отладки"
  echo "   -o,   --old-style   запустить как классический (не systemd) демон"
  echo "   -R,   --reinstall   переустановить бинарник (требует root)"
  echo "   -h,   --help        показать эту справку"
  echo ""
  echo "Коррекция выделенного текста:"
  echo "   Выделите текст (Shift+стрелки / Shift+Home/End / мышью),"
  echo "   затем нажмите <replace-key> — WaylandSwitcher скопирует"
  echo "   выделение, переключит раскладку и вставит текст обратно."
  echo "   Требуется wl-clipboard (wl-paste/wl-copy) для Wayland"
  echo "   или xclip/xsel для X11. Настраивается параметром clipboard-tool."







# ── Точка входа ───────────────────────────────────────────────────────────────

when isMainModule:
  c_openlog("wayland-switcher", LOG_PID, LOG_DAEMON)
  initSharedState()

  if paramCount() != 1:
    runHelp()
  else:
    case paramStr(1)
    of "-i", "--install":   runInstall()
    of "-u", "--uninstall": runUninstall()
    of "-R", "--reinstall": runReinstall()
    of "-c", "--configure": runConfig()
    of "-r", "--run":       run()
    of "-d", "--debug":     runDebug()
    of "-o", "--old-style": runOldStyleDaemon()
    of "-h", "--help":      runHelp()
    else:                   runHelp()

  c_closelog()







