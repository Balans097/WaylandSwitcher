## WaylandSwitcher.nim — главный модуль.
##
## Компиляция:
##   nim c --threads:on -d:release WaylandSwitcher.nim
##
## Версия:   0.9
## Дата:     2026-04-22
## Автор:    github.com/Balans097
##
## История изменений:
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
  ## Отслеживает клики мыши для сброса буфера нажатий.
  ## Читает сырые пакеты по 3 байта из mouseFDGlobal (протокол PS/2).
  ##
  ## Протокол /dev/input/mice (PS/2):
  ##   байт 0: биты состояния кнопок; биты [2:0] = правая, средняя, левая
  ##   байты 1–2: смещение X, Y (знаковые)
  ## Любой ненулевой бит в маске 0x07 означает нажатие кнопки мыши.
  ##
  ## Условие реакции: поток реагирует на клик только тогда, когда
  ## главный поток накапливает буфер (needTrackMouse=true), чтобы не
  ## сбрасывать буфер при случайных кликах до начала набора.
  var d: array[3, uint8]
  while not stopAndExit.load():
    let n = read(mouseFDGlobal, addr d[0], 3)
    if n == 3 and needTrackMouse.load():
      if (d[0] and 0x07) != 0:
        logMsg(false, "mouse click",            stdOnly = true)
        logMsg(false, "buffer clearing queued", stdOnly = true)
        needTrackMouse.store(false)
        needClearKeyBuf.store(true)

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
  var keyBuf: seq[InputEvent]   ## буфер нажатий текущей «порции» текста

  while not stopAndExit.load():
    var ie: InputEvent
    if read(kfd, addr ie, sizeof(ie)) == sizeof(ie):

      # Поток мыши запросил сброс буфера
      if needClearKeyBuf.load():
        needClearKeyBuf.store(false)
        keyBuf = @[]
        logMsg(false, "буфер очищен", stdOnly = true)

      # Обрабатываем только key-down (1) и key-up (0);
      # autorepeat (2) здесь отбрасываем, но emitEvents учитывает его
      # при подсчёте BS (нажатая и удерживаемая клавиша = один символ).
      if ie.ie_type == EV_KEY and ie.value in [0'i32, 1]:
        logMsg(false, "input " & keyNameSafe(ie.code) & " " & KeyAction[ie.value],
               stdOnly = true)
        sleep(50)

        # Добавляем в буфер буквы, цифры, shift и клавишу замены
        if ie.code in Letters or ie.code in Shifts or ie.code == cfg.keyRpl:
          keyBuf.add(InputEvent(ie_type: ie.ie_type, code: ie.code, value: ie.value))
          needTrackMouse.store(true)

        # Служебные клавиши (Tab, Ctrl, Alt, стрелки…) сбрасывают буфер
        if ie.code in BufKillers and ie.value == 0:
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
  echo "   -h,   --help        показать эту справку"







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
    of "-c", "--configure": runConfig()
    of "-r", "--run":       run()
    of "-d", "--debug":     runDebug()
    of "-o", "--old-style": runOldStyleDaemon()
    of "-h", "--help":      runHelp()
    else:                   runHelp()

  c_closelog()







