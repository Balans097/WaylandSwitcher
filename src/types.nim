## types.nim — общие типы, константы и вспомогательные утилиты WaylandSwitcher.
##
## Этот модуль не импортирует ничего из проекта; он является фундаментом,
## от которого зависят все остальные модули. Импортировать его следует первым.
##
## Структура данных:
##   InputEvent  — низкоуровневое событие Linux evdev (читается из /dev/input/*)
##   AppConfig   — конфигурация, загружаемая из файла
##   UInputSetup — параметры регистрации виртуального устройства через uinput
##   BufferAction — решение, что делать с буфером нажатий
##   KbdDetectArgSafe — аргумент для потока определения клавиатуры

import posix

# ── Пути и версия ─────────────────────────────────────────────────────────────
const
  VERSION*           = "0.9"
  SYSTEMD_UNIT_FILE* = "/lib/systemd/system/wayland-switcher.service"
  CONFIG_FILE*       = "/etc/wayland-switcher/default.conf"
  INPUT_DEVICES_DIR* = "/dev/input/"
  UINPUT_FILE*       = "/dev/uinput"

# ── Константы evdev ───────────────────────────────────────────────────────────
# Типы событий (ie_type в InputEvent)
const
  EV_SYN*: uint16 = 0x00   ## синхронизирующее событие
  EV_KEY*: uint16 = 0x01   ## событие клавиши

# Коды синхронизации
const
  SYN_REPORT*: uint16 = 0x00   ## разделитель пакета событий

# Тип шины устройства для uinput
const
  BUS_USB*: uint16 = 0x03

# ── Коды ioctl для /dev/uinput ────────────────────────────────────────────────
const
  UI_SET_EVBIT*:  uint = 0x40045564   ## разрешить тип событий
  UI_SET_KEYBIT*: uint = 0x40045565   ## разрешить конкретный код клавиши
  UI_DEV_SETUP*:  uint = 0x405C5503   ## передать UInputSetup
  UI_DEV_CREATE*: uint = 0x00005501   ## создать виртуальное устройство
  UI_DEV_DESTROY*:uint = 0x00005502   ## уничтожить виртуальное устройство

# ── Скан-коды отдельных клавиш ────────────────────────────────────────────────
const
  KEY_BACKSPACE*: uint16 = 14
  KEY_SPACE*:     uint16 = 57
  KEY_ENTER*:     uint16 = 28
  KEY_KPENTER*:   uint16 = 96

# ── Наборы скан-кодов ─────────────────────────────────────────────────────────
const
  ## Буквы, цифры, пробел и печатаемые символы — всё, что попадает в буфер.
  Letters* = {2'u16, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19,
              20, 21, 22, 23, 24, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36,
              37, 38, 39, 40, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53,
              55, 57, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 96, 98}

  ## Левый и правый Shift.
  Shifts* = {42'u16, 54}

  ## Клавиши, нажатие которых сбрасывает буфер (Tab, Ctrl, Alt, стрелки и т.д.).
  BufKillers* = {15'u16, 29, 56, 97, 100, 102, 103, 104, 105, 106, 107,
                 108, 109, 110}

# ── Таблица имён клавиш (индекс = скан-код) ──────────────────────────────────
const
  KeyName*: array[249, string] = [
    "RESERVED","ESC","1","2","3","4","5","6","7","8","9","0","MINUS","EQUAL",
    "BACKSPACE","TAB","Q","W","E","R","T","Y","U","I","O","P","LEFTBRACE",
    "RIGHTBRACE","ENTER","LEFTCTRL","A","S","D","F","G","H","J","K","L",
    "SEMICOLON","APOSTROPHE","GRAVE","LEFTSHIFT","BACKSLASH","Z","X","C","V",
    "B","N","M","COMMA","DOT","SLASH","RIGHTSHIFT","KPASTERISK","LEFTALT",
    "SPACE","CAPSLOCK","F1","F2","F3","F4","F5","F6","F7","F8","F9","F10",
    "NUMLOCK","SCROLLLOCK","KP7","KP8","KP9","KPMINUS","KP4","KP5","KP6",
    "KPPLUS","KP1","KP2","KP3","KP0","KPDOT","(84)","ZENKAKUHANKAKU","102ND",
    "F11","F12","RO","KATAKANA","HIRAGANA","HENKAN","KATAKANAHIRAGANA",
    "MUHENKAN","KPJPCOMMA","KPENTER","RIGHTCTRL","KPSLASH","SYSRQ","RIGHTALT",
    "LINEFEED","HOME","UP","PAGEUP","LEFT","RIGHT","END","DOWN","PAGEDOWN",
    "INSERT","DELETE","MACRO","MUTE","VOLUMEDOWN","VOLUMEUP","POWER","KPEQUAL",
    "KPPLUSMINUS","PAUSE","SCALE","KPCOMMA","HANGEUL","HANJA","YEN","LEFTMETA",
    "RIGHTMETA","COMPOSE","STOP","AGAIN","PROPS","UNDO","FRONT","COPY","OPEN",
    "PASTE","FIND","CUT","HELP","MENU","CALC","SETUP","SLEEP","WAKEUP","FILE",
    "SENDFILE","DELETEFILE","XFER","PROG1","PROG2","WWW","MSDOS","COFFEE",
    "ROTATE_DISPLAY","CYCLEWINDOWS","MAIL","BOOKMARKS","COMPUTER","BACK",
    "FORWARD","CLOSECD","EJECTCD","EJECTCLOSECD","NEXTSONG","PLAYPAUSE",
    "PREVIOUSSONG","STOPCD","RECORD","REWIND","PHONE","ISO","CONFIG","HOMEPAGE",
    "REFRESH","EXIT","MOVE","EDIT","SCROLLUP","SCROLLDOWN","KPLEFTPAREN",
    "KPRIGHTPAREN","NEW","REDO","F13","F14","F15","F16","F17","F18","F19","F20",
    "F21","F22","F23","F24","(195)","(196)","(197)","(198)","(199)","PLAYCD",
    "PAUSECD","PROG3","PROG4","ALL_APPLICATIONS","SUSPEND","CLOSE","PLAY",
    "FASTFORWARD","BASSBOOST","PRINT","HP","CAMERA","SOUND","QUESTION","EMAIL",
    "CHAT","SEARCH","CONNECT","FINANCE","SPORT","SHOP","ALTERASE","CANCEL",
    "BRIGHTNESSDOWN","BRIGHTNESSUP","MEDIA","SWITCHVIDEOMODE","KBDILLUMTOGGLE",
    "KBDILLUMDOWN","KBDILLUMUP","SEND","REPLY","FORWARDMAIL","SAVE","DOCUMENTS",
    "BATTERY","BLUETOOTH","WLAN","UWB","UNKNOWN","VIDEO_NEXT","VIDEO_PREV",
    "BRIGHTNESS_CYCLE","BRIGHTNESS_AUTO","DISPLAY_OFF","WWAN","RFKILL","MICMUTE"
  ]

  ## Текстовые метки для поля value события EV_KEY.
  KeyAction*: array[3, string] = ["up", "down", "autorepeat"]

# ── Константы syslog ──────────────────────────────────────────────────────────
const
  LOG_PID*    = 0x01.cint       ## добавлять PID к каждому сообщению
  LOG_DAEMON* = (3.cint shl 3)  ## facility: системный демон
  LOG_INFO*   = 6.cint          ## уровень: информация
  LOG_ERR*    = 3.cint          ## уровень: ошибка

# ── Типы данных ───────────────────────────────────────────────────────────────

type
  ## Метка времени, совместимая с полем time структуры input_event ядра Linux.
  ## Используется вместо Posix Timeval для явного контроля размеров полей.
  MyTimeVal* = object
    tv_sec*:  int64   ## секунды с начала эпохи Unix
    tv_usec*: int64   ## микросекунды [0, 999999]

  ## Событие ввода в формате ядра Linux (struct input_event из <linux/input.h>).
  ## Читается побайтно из /dev/input/event* системным вызовом read().
  InputEvent* = object
    time*:    MyTimeVal  ## время возникновения события
    ie_type*: uint16     ## тип: EV_KEY, EV_SYN и т.д.
    code*:    uint16     ## скан-код клавиши или оси
    value*:   int32      ## 0=up, 1=down, 2=autorepeat

  ## Идентификатор устройства, передаваемый в uinput при создании.
  UInputId* = object
    bustype*, vendor*, product*, version*: uint16

  ## Параметры создания виртуального устройства через UI_DEV_SETUP.
  UInputSetup* = object
    id*:             UInputId
    name*:           array[80, char]  ## UTF-8 имя, завершается нулём
    ff_effects_max*: uint32           ## максимум эффектов force-feedback (0 = нет)

  ## Решение, принятое анализатором буфера нажатий.
  BufferAction* = enum
    KeepBuffer   ## недостаточно данных — продолжить накапливать
    ReplaceAll   ## заменить всю фразу в текущей раскладке
    ReplaceWord  ## заменить последнее слово в текущей раскладке

  ## Конфигурация приложения, загружаемая из CONFIG_FILE.
  AppConfig* = object
    kbdPath*:     string        ## путь к устройству клавиатуры
    mousePath*:   string        ## путь к устройству мыши
    keysLs*:      seq[uint16]   ## один или два скан-кода переключателя раскладки
    strKeysLs*:   string        ## строковое представление для записи в конфиг
    keyRpl*:      uint16        ## скан-код клавиши коррекции
    reverseMode*: bool          ## true — поменять местами «слово» и «фразу»
    delayMs*:     int           ## задержка (мс) между эмитируемыми событиями

# ── Вспомогательные процедуры ─────────────────────────────────────────────────

proc keyNameSafe*(code: uint16): string {.inline.} =
  ## Возвращает имя клавиши по скан-коду или "(N)" при выходе за границу таблицы.
  if code <= 248: KeyName[code]
  else: "(" & $code & ")"

proc fillName*(a: var array[80, char]; s: string) {.inline.} =
  ## Заполняет массив символов (имя устройства uinput) строкой s с нулём в конце.
  zeroMem(addr a[0], 80)
  for i in 0 ..< min(len(s), 79):
    a[i] = s[i]
