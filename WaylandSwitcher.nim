## WaylandSwitcher — переключатель раскладки клавиатуры для Linux/Wayland
## с автоматической коррекцией текста, набранного не в той раскладке.
##
## Этот файл — точка входа: разбор параметров командной строки и режимы
## запуска. Остальное находится в src/:
##
##   types      общие типы и константы
##   core       разделяемое состояние потоков, ожидание ввода, логирование
##   shellquote экранирование строк для shell и systemd
##   config     загрузка и запись файла конфигурации
##   configure  интерактивная настройка (-c)
##   install    установка и удаление systemd-юнита (-i, -u)
##   buffer     анализ буфера нажатий
##   layout     перекодировка текста EN <-> RU
##   vkbd       виртуальная клавиатура (uinput)
##   clipboard  буфер обмена сессии пользователя
##   selection  коррекция выделенного текста
##   mouse      поток мыши (клик или протаскивание)
##   daemon     главный рабочий цикл
##
## Сборка:
##   nim c -d:release WaylandSwitcher.nim
## Ключ --threads:on включён в WaylandSwitcher.nims.

import posix, os
import src/[types, core, daemon, install, configure]

proc runDebug() =
  ## Запуск в терминале: без форка и без syslog, с подробным выводом.
  daemonMode = false
  run()

proc runOldStyleDaemon() =
  ## Классический Unix-демон без systemd: двойной fork, новая сессия,
  ## стандартные потоки перенаправлены в /dev/null, вывод — в syslog.
  var pid = fork()
  if pid < 0: logMsg(true, "Ошибка fork()"); quit(1)
  if pid > 0: quit(0)
  if setsid() < 0:
    logMsg(true, "Первый дочерний процесс не смог стать лидером сессии"); quit(1)
  pid = fork()   # второй fork: процесс никогда не получит управляющий терминал
  if pid < 0: logMsg(true, "Ошибка второго fork()"); quit(1)
  if pid > 0: quit(0)
  discard umask(0)
  setCurrentDir("/")
  let devNull = open("/dev/null", O_RDWR)
  if devNull >= 0:
    discard dup2(devNull, 0)
    discard dup2(devNull, 1)
    discard dup2(devNull, 2)
    if devNull > 2: discard close(devNull)
  run()

proc runHelp() =
  daemonMode = false
  echo "WaylandSwitcher - переключатель раскладки клавиатуры v" & VERSION
  echo ""
  echo "Использование: wayland-switcher [параметр]"
  echo ""
  echo "Параметры:"
  echo "   -i,   --install     создать systemd-юнит"
  echo "   -u,   --uninstall   удалить systemd-юнит"
  echo "   -c,   --configure   настроить WaylandSwitcher"
  echo "   -r,   --run         запустить"
  echo "   -d,   --debug       запустить в режиме отладки"
  echo "   -o,   --old-style   запустить как классический (не systemd) демон"
  echo "   -h,   --help        показать эту справку"
  echo ""
  echo "Коррекция выделенного текста:"
  echo "   Выделите текст (мышью, Shift+стрелки, Shift+Home/End, Ctrl+A)"
  echo "   и нажмите клавишу коррекции: текст будет перекодирован между"
  echo "   раскладками EN и RU и вставлен на место выделения."
  echo "   Нужен wl-clipboard (Wayland) либо xclip/xsel (X11);"
  echo "   инструмент выбирается параметром clipboard-tool."
  echo ""
  echo "   Если выделения в приложении на самом деле нет, коррекция"
  echo "   прерывается, а содержимое буфера обмена остаётся прежним."

when isMainModule:
  c_openlog("wayland-switcher", LOG_PID, LOG_DAEMON)

  if paramCount() != 1:
    runHelp()
  else:
    case paramStr(1)
    # Команды обслуживания интерактивны: вывод идёт в терминал, не в syslog.
    of "-i", "--install":   daemonMode = false; runInstall()
    of "-u", "--uninstall": daemonMode = false; runUninstall()
    of "-c", "--configure": daemonMode = false; runConfig()
    of "-r", "--run":       run()
    of "-d", "--debug":     runDebug()
    of "-o", "--old-style": runOldStyleDaemon()
    else:                   runHelp()

  c_closelog()
