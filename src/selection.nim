## selection.nim — коррекция раскладки уже выделенного текста.
##
## Для выделенного текста скан-кодов нет, поэтому коррекция идёт через
## буфер обмена CLIPBOARD: программное Ctrl+C, перекодировка строки и вставка
## результата по Ctrl+V. PRIMARY selection не используется: GTK4-приложения
## (в том числе gnome-text-editor) на Wayland его не поддерживают, а Ctrl+C
## через uinput срабатывает надёжно.

import posix, os, strutils, std/monotimes
import types, core, layout, vkbd, clipboard

proc emitSelectionCorrection*(vfd: cint; keysLs: seq[uint16];
                              clipTool: ClipboardTool; delayMs: int) =
  ## Перекодирует выделенный текст и заменяет им выделение.
  ##
  ## Шаги:
  ##   0. В CLIPBOARD записывается уникальная метка-маркер.
  ##   1. Ctrl+C копирует выделение, не снимая его.
  ##   2. CLIPBOARD читается. Если там всё ещё маркер, Ctrl+C ничего не
  ##      скопировал (выделения в приложении фактически нет) — коррекция
  ##      прерывается, прежнее содержимое CLIPBOARD восстанавливается.
  ##      Маркер надёжнее сравнения «до/после»: тот не отличает случайно
  ##      совпавший текст от несработавшего Ctrl+C.
  ##   3. Переключается раскладка (для дальнейшего набора).
  ##   4. Текст перекодируется (convertLayout) и записывается в CLIPBOARD.
  ##   5. Delete удаляет выделение.
  ##   6. Ctrl+V вставляет исправленный текст.
  ##   7. Прежнее содержимое CLIPBOARD восстанавливается, чтобы коррекция
  ##      не подменяла то, что пользователь скопировал раньше.
  let tool =
    if clipTool == ClipAuto: detectClipboardTool()
    else: clipTool
  let env = getSessionEnv()
  let prevClipboard = readClipboard(tool, env)

  # Шаг 0.
  let marker = "WS_MARKER_" & $getpid() & "_" & $getMonoTime().ticks
  logMsg(false, "sel-correction: шаг 0 — маркер в CLIPBOARD", stdOnly = true)
  writeClipboard(tool, env, marker)
  sleep(100)

  # Шаг 1. Пауза перед Ctrl+C: композитор должен обработать отпускание
  # клавиши коррекции, а фокус — остаться в целевом приложении.
  sleep(150)
  logMsg(false, "sel-correction: шаг 1 — Ctrl+C", stdOnly = true)
  pressChord(vfd, KEY_LEFTCTRL, KEY_C, delayMs)
  sleep(400)   # приложение обрабатывает Ctrl+C асинхронно

  # Шаг 2. Хвостовой перевод строки добавляет инструмент буфера обмена
  # или приложение, это не часть выделения; внутренние переводы строк
  # остаются.
  logMsg(false, "sel-correction: шаг 2 — чтение CLIPBOARD", stdOnly = true)
  let selText = strip(readClipboard(tool, env), leading = false,
                      chars = {'\r', '\n'})
  if selText == marker:
    logMsg(false, "sel-correction: Ctrl+C не скопировал выделение, прерываем",
           stdOnly = true)
    writeClipboard(tool, env, prevClipboard)
    return
  if selText == "":
    logMsg(false, "sel-correction: CLIPBOARD пуст после Ctrl+C, прерываем",
           stdOnly = true)
    writeClipboard(tool, env, prevClipboard)
    return
  logMsg(false, "sel-correction: прочитано символов: " & $len(selText) &
         " [" & selText & "]", stdOnly = true)

  # Шаг 3.
  logMsg(false, "sel-correction: шаг 3 — переключение раскладки", stdOnly = true)
  switchLayout(vfd, keysLs, delayMs)
  sleep(80)

  # Шаг 4.
  let correctedText = convertLayout(selText)
  logMsg(false, "sel-correction: шаг 4 — результат [" & correctedText & "]",
         stdOnly = true)
  writeClipboard(tool, env, correctedText)
  sleep(300)

  # Шаг 5.
  logMsg(false, "sel-correction: шаг 5 — Delete", stdOnly = true)
  tapKey(vfd, KEY_DELETE, delayMs)
  sleep(50)

  # Шаг 6.
  logMsg(false, "sel-correction: шаг 6 — Ctrl+V", stdOnly = true)
  pressChord(vfd, KEY_LEFTCTRL, KEY_V, delayMs)
  # Приложение должно успеть забрать CLIPBOARD, прежде чем он будет
  # перезаписан; иначе вставится прежнее содержимое.
  sleep(150)

  # Шаг 7.
  logMsg(false, "sel-correction: шаг 7 — восстановление CLIPBOARD", stdOnly = true)
  writeClipboard(tool, env, prevClipboard)
  logMsg(false, "sel-correction: завершено", stdOnly = true)
