## WaylandSwitcher.nim — главный модуль.
##
## Реализует:
##   • mouseThreadFn      — фоновый поток, отслеживающий левую кнопку
##                          мыши, чтобы отличить обычный клик от
##                          drag-выделения.
##   • sigHandler         — async-signal-safe обработчик SIGHUP/SIGINT/
##                          SIGQUIT/SIGTERM (только атомарная запись флага).
##   • run                — главный рабочий цикл: читает события
##                          клавиатуры, ведёт буфер набора текста,
##                          отслеживает выделение (мышью, Ctrl+A,
##                          Shift+навигация) и вызывает коррекцию
##                          раскладки (emitEvents/emitSelectionCorrection
##                          из input.nim) по нажатию клавиши коррекции.
##   • runDebug           — запуск в терминале без форка и без syslog
##                          (интерактивная отладка).
##   • runOldStyleDaemon  — классический Unix-демон без systemd:
##                          двойной fork, отрыв от управляющего
##                          терминала, вывод только в syslog.
##   • runHelp            — вывод справки по параметрам командной строки.
##   • точка входа (when isMainModule) — разбор параметров командной
##                          строки и диспетчеризация в setup.nim
##                          (install/uninstall/reinstall/configure) либо
##                          в один из режимов запуска выше.
##
## Компиляция:
##   nim c --threads:on -d:release WaylandSwitcher.nim
##
## Если сборка падает с "unknown hint: LineTooLong" (или похожей ошибкой
## про неизвестный hint) ещё до начала компиляции файлов проекта — это
## несовместимость системного /etc/nim/nim.cfg с установленной версией
## компилятора, а не ошибка в коде. Добавьте --skipParentCfg:
##   nim c --skipParentCfg --threads:on -d:release WaylandSwitcher.nim
##
## Версия и история изменений — см. changelog.md в корне проекта.
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

        # ── Обнаружение выделения: Ctrl+A («выделить всё») ──────────────────
        # Срабатывает на key-DOWN клавиши A при зажатом Ctrl — в отличие
        # от остальных способов обнаружения выделения в этом файле,
        # которые проверяются на key-up. Причина: порядок ОТЖАТИЯ клавиш
        # в сочетании Ctrl+A не гарантирован — многие (в т.ч. в логах
        # отладки этого проекта) отпускают Ctrl раньше A, и к моменту
        # "A up" ctrlHeld уже успевает стать false. Порядок НАЖАТИЯ же
        # гарантирован самой механикой сочетания: чтобы получить Ctrl+A,
        # Ctrl обязательно должен быть нажат раньше (или одновременно с)
        # A — поэтому проверка на "A down" надёжна, а на "A up" — нет.
        #
        # Стандартное сочетание «выделить всё» почти везде (текстовые
        # поля, редакторы, браузеры). До этого исправления Ctrl+A вообще
        # не распознавался как выделение: программа знала только про drag
        # мышью и Shift+навигационные клавиши, поэтому коррекция после
        # Ctrl+A не запускалась — selActive оставался false. selCount не
        # имеет смысла для «выделить всё» (выделение не привязано к числу
        # нажатий стрелок), поэтому, как и для мыши, оставляем 0 —
        # emitSelectionCorrection сама узнает длину из CLIPBOARD.
        if ctrlHeld and ie.code == KEY_A and ie.value == 1:
          selActive = true
          selCount  = 0
          # Явно очищаем keyBuf: после Ctrl+A пользователь обычно вообще
          # не возвращается к «дописыванию» текущей фразы — а если в
          # буфере оставались символы с момента ДО выделения, при отжатии
          # LEFTCTRL стандартный механизм BufKillers их не сбросит (он
          # срабатывает только в ветке elif not selActive, а selActive
          # уже true) — без явной очистки здесь они могли бы неожиданно
          # повлиять на следующую коррекцию обычного (не через выделение)
          # режима, если пользователь начнёт печатать сразу после Ctrl+A.
          keyBuf = @[]
          logMsg(false, "выделение активно (Ctrl+A)", stdOnly = true)

        # Выделение мышью: поток мыши выставляет mouseSelDone=true один раз,
        # в момент отпускания кнопки после реального drag (не клика).
        # Здесь делаем read-and-clear: подхватываем флаг и сразу гасим его,
        # чтобы не взвести selActive повторно на следующем же событии.
        # selCount не считаем — передадим 0 в emitSelectionCorrection: она
        # сама узнает фактическую длину выделения, прочитав CLIPBOARD после
        # своего собственного Ctrl+C (см. шаг 1-2 внутри emitSelectionCorrection
        # в input.nim) — этот selCount по нажатиям стрелок для мыши просто
        # не имеет смысла, выделение мышью не связано с клавишами-стрелками.
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

        # Небольшая пауза перед проверкой условия коррекции: даёт время
        # дойти предыдущим логам/событиям и не сливаться с последующими
        # sel-output событиями в отладочном выводе; также слегка разносит
        # по времени физическое key-up клавиши коррекции и последующий
        # программный Ctrl+C внутри emitSelectionCorrection.
        sleep(50)

        # ── Коррекция выделенного текста ────────────────────────────────────
        # Нажатие keyRpl при активном выделении запускает коррекцию.
        # Срабатывает на key-up, чтобы keyRpl не попал в буфер приложения
        # как обычный символ (мы не печатаем PAUSE, а используем его как
        # команду).
        if selActive and ie.code == cfg.keyRpl and ie.value == 0:
          logMsg(false, "коррекция выделенного текста", stdOnly = true)
          emitSelectionCorrection(vfd, cfg.keysLs, cfg.clipTool, cfg.delayMs, selCount)
          selActive = false
          selCount  = 0
          keyBuf    = @[]
          # Переоткрываем устройство клавиатуры: пока шла коррекция
          # (Ctrl+C/Delete/Ctrl+V через виртуальную клавиатуру, плюс
          # обращения к буферу обмена), ядро могло накопить в очереди
          # устройства события, которые мы не хотим обрабатывать как
          # новый пользовательский ввод (в частности — эхо собственных
          # sel-output нажатий, если они почему-то попадут на физическое
          # устройство, а не только на виртуальное). Закрыть и открыть
          # заново — самый надёжный способ сбросить накопленную очередь.
          discard close(kfd)
          kfd = open(cstring(cfg.kbdPath), O_RDONLY or O_SYNC)
          if kfd == -1:
            logMsg(true, "Критическая ошибка: не удалось переоткрыть клавиатуру: " &
                   $strerror(errno))
            stopAndExit.store(true)

        # ── Обычный режим: накопление и замена введённого текста ────────────
        elif not selActive:

          # Добавляем в буфер буквы, цифры, shift и клавишу замены.
          # Зажатый Ctrl исключаем: Ctrl+буква — это сочетание-команда
          # (Ctrl+A «выделить всё», Ctrl+S «сохранить», Ctrl+Z «отменить»
          # и т.д.), а не печатаемый символ — такая буква не должна
          # попадать в буфер набора текста как часть обычного слова.
          if (ie.code in Letters or ie.code in Shifts or ie.code == cfg.keyRpl) and
             not ctrlHeld:
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
              # накопленную очередь устройства — та же причина, что и
              # при коррекции выделения выше (см. комментарий там).
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
  echo ""
  echo "   Если в момент нажатия <replace-key> программа решила, что"
  echo "   выделение есть (например, был клик-перетаскивание мышью),"
  echo "   а на деле фокус уже сместился и выделения в приложении не"
  echo "   оказалось — WaylandSwitcher это обнаруживает и НИЧЕГО не"
  echo "   вставляет: прежнее содержимое буфера обмена остаётся"
  echo "   нетронутым, программа просто завершает попытку коррекции."







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







