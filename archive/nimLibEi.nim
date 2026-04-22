# ============================================================================
# nimLibEi.nim — Nim bindings for libei (Emulated Input library)
# ============================================================================
# Лицензия: MIT (совместима с libei)
# Источник API: https://libinput.pages.freedesktop.org/libei/api/libei_8h.html
# Версия libei: 1.6+
# ============================================================================

{.passC: "-I/usr/include/libei-1.0".}
{.passL: "-lei".}
{.pragma: ei_import, cdecl, importc, dynlib: "libei.so.0".}

# ============================================================================
# Базовые импорты и типы
# ============================================================================

import std/[strformat]

# Прозрачные указатели на C-структуры (opaque types)
type
  Ei* = object of RootObj    ## Основной контекст libei
  EiDevice* = object of RootObj    ## Устройство ввода
  EiSeat* = object of RootObj      ## Логический «сид» (группа устройств)
  EiEvent* = object of RootObj     ## Событие от EIS-сервера
  EiKeymap* = object of RootObj    ## Карта клавиш (XKB)
  EiRegion* = object of RootObj    ## Прямоугольная область на экране
  EiTouch* = object of RootObj     ## Активный тач-контакт
  EiPing* = object of RootObj      ## Объект для roundtrip-синхронизации
  EiLogContext* = object of RootObj  ## Контекст лог-сообщения

# ============================================================================
# Перечисления (Enums)
# ============================================================================

type
  EiDeviceType* {.pure.} = enum
    ## Тип устройства: виртуальное или физическое
    Virtual = 1,   ## Виртуальное: координаты в логических пикселях
    Physical       ## Физическое: координаты в миллиметрах
  EiDeviceCapability* {.pure.} = enum
    ## Возможности устройства (битовые флаги)
    Pointer          = (1 shl 0),  ## Относительное движение курсора
    PointerAbsolute  = (1 shl 1),  ## Абсолютные координаты
    Keyboard         = (1 shl 2),  ## Клавиатурные события (keycode)
    Touch            = (1 shl 3),  ## Мультитач
    Scroll           = (1 shl 4),  ## Прокрутка
    Button           = (1 shl 5),  ## Кнопки мыши
    Text             = (1 shl 6)   ## Текстовые события (keysym/UTF-8, libei ≥1.6)
  EiKeymapType* {.pure.} = enum
    ## Тип карты клавиш
    Xkb = 1  ## libxkbcommon-совместимая карта
  EiEventType* {.pure.} = enum
    ## Типы событий (не исчерпывающий список)
    ##
    ## === Базовые события соединения ===
    Connect = 1,              ## Сервер принял соединение
    Disconnect,               ## Сервер разорвал соединение
    ## === События сидов ===
    SeatAdded,                ## Добавлен новый сид
    SeatRemoved,              ## Сид удалён
    ## === События устройств ===
    DeviceAdded,              ## Добавлено новое устройство
    DeviceRemoved,            ## Устройство удалено
    DevicePaused,             ## Устройство приостановлено (события игнорируются)
    DeviceResumed,            ## Устройство возобновлено (можно отправлять события)
    ## === События клавиатуры ===
    KeyboardModifiers,        ## Изменилось состояние модификаторов
    ## === События синхронизации ===
    Pong = 90,                ## Ответ на ei_ping()
    Sync,                     ## Запрос синхронизации от сервера
    ## === События фреймов (только receiver) ===
    Frame = 100,              ## Группировка событий в один «аппаратный» кадр
    ## === События эмуляции (только receiver) ===
    DeviceStartEmulating = 200,  ## Сервер начал эмуляцию на устройстве
    DeviceStopEmulating,         ## Сервер остановил эмуляцию
    ## === События указателя ===
    PointerMotion = 300,         ## Относительное движение
    PointerMotionAbsolute = 400, ## Абсолютное позиционирование
    ## === События кнопок ===
    ButtonButton = 500,          ## Нажатие/отпускание кнопки
    ## === События прокрутки ===
    ScrollDelta = 600,    ## Плавная прокрутка (в пикселях/мм)
    ScrollStop,           ## Остановка прокрутки
    ScrollCancel,         ## Отмена прокрутки
    ScrollDiscrete,       ## Дискретная прокрутка (шаги колёсика)
    ## === События клавиатуры ===
    KeyboardKey = 700,    ## Нажатие/отпускание клавиши (keycode)
    ## === События тача ===
    TouchDown = 800,      ## Начало касания
    TouchUp,              ## Окончание касания
    TouchMotion,          ## Движение при касании
    ## === Текстовые события (libei ≥1.6) ===
    TextKeysym = 900,     ## Событие keysym (XKB, не keycode!)
    TextUtf8              ## Событие UTF-8 строки
  EiLogPriority* {.pure.} = enum
    ## Уровни логирования
    Debug = 10,
    Info = 20,
    Warning = 30,
    Error = 40

# ============================================================================
# Типы колбэков и функций
# ============================================================================

type
  EiLogHandler* = proc(ei: ptr Ei; priority: EiLogPriority;
                       message: cstring; context: ptr EiLogContext) {.cdecl.}
    ## Обработчик логов библиотеки
  EiClockNowFunc* = proc(ei: ptr Ei): uint64 {.cdecl.}
    ## Функция получения текущего времени (микросекунды, CLOCK_MONOTONIC)

# ============================================================================
# Вспомогательные функции
# ============================================================================

proc ei_event_type_to_string*(eventType: EiEventType): cstring {.
  ei_import, importc: "ei_event_type_to_string".}
  ## Возвращает строковое имя типа события или NULL

# ============================================================================
# Управление контекстом (struct ei)
# ============================================================================

proc ei_new*(userData: pointer): ptr Ei {.ei_import, importc: "ei_new".}
  ## Алиас для ei_new_sender()
proc ei_new_sender*(userData: pointer): ptr Ei {.ei_import, importc: "ei_new_sender".}
  ## Создать контекст-отправитель (отправляет события EIS)
proc ei_new_receiver*(userData: pointer): ptr Ei {.ei_import, importc: "ei_new_receiver".}
  ## Создать контекст-получатель (получает события от EIS)
proc ei_ref*(ei: ptr Ei): ptr Ei {.ei_import, importc: "ei_ref".}
  ## Увеличить счётчик ссылок
proc ei_unref*(ei: ptr Ei): ptr Ei {.ei_import, importc: "ei_unref".}
  ## Уменьшить счётчик ссылок; при 0 — отключение и очистка
proc ei_set_user_data*(ei: ptr Ei; userData: pointer) {.ei_import, importc: "ei_set_user_data".}
  ## Сохранить пользовательские данные в контексте
proc ei_get_user_data*(ei: ptr Ei): pointer {.ei_import, importc: "ei_get_user_data".}
  ## Получить пользовательские данные из контекста
proc ei_is_sender*(ei: ptr Ei): bool {.ei_import, importc: "ei_is_sender".}
  ## true, если контекст создан через ei_new_sender()

# ----------------------------------------------------------------------------
# Логирование
# ----------------------------------------------------------------------------

proc ei_log_set_handler*(ei: ptr Ei; handler: EiLogHandler) {.
  ei_import, importc: "ei_log_set_handler".}
  ## Установить обработчик логов (NULL = использовать встроенный)
proc ei_log_set_priority*(ei: ptr Ei; priority: EiLogPriority) {.
  ei_import, importc: "ei_log_set_priority".}
  ## Установить минимальный уровень логирования
proc ei_log_get_priority*(ei: ptr Ei): EiLogPriority {.
  ei_import, importc: "ei_log_get_priority".}
proc ei_log_context_get_line*(ctx: ptr EiLogContext): cuint {.
  ei_import, importc: "ei_log_context_get_line".}
  ## Номер строки, где произошло лог-событие
proc ei_log_context_get_file*(ctx: ptr EiLogContext): cstring {.
  ei_import, importc: "ei_log_context_get_file".}
  ## Имя файла, где произошло лог-событие
proc ei_log_context_get_func*(ctx: ptr EiLogContext): cstring {.
  ei_import, importc: "ei_log_context_get_func".}
  ## Имя функции, где произошло лог-событие

# ----------------------------------------------------------------------------
# Настройка времени и имени клиента
# ----------------------------------------------------------------------------

proc ei_clock_set_now_func*(ei: ptr Ei; callback: EiClockNowFunc) {.
  ei_import, importc: "ei_clock_set_now_func".}
  ## Переопределить функцию получения времени (для тестов)
proc ei_configure_name*(ei: ptr Ei; name: cstring) {.
  ei_import, importc: "ei_configure_name".}
  ## Задать имя клиента (отображается в диалогах авторизации)
  ## Вызывать ДО ei_setup_backend_*()

# ============================================================================
# Инициализация бэкенда
# ============================================================================

proc ei_setup_backend_fd*(ei: ptr Ei; fd: cint): cint {.
  ei_import, importc: "ei_setup_backend_fd".}
  ## Инициализировать контекст на переданном файловом дескрипторе сокета
  ## Возвращает 0 при успехе или отрицательный errno
proc ei_setup_backend_socket*(ei: ptr Ei; socketpath: cstring): cint {.
  ei_import, importc: "ei_setup_backend_socket".}
  ## Подключиться к сокету по пути (для отладки; предпочтительнее ei_setup_backend_fd)
  ## Если socketpath = NULL, используется $LIBEI_SOCKET или $XDG_RUNTIME_DIR/libei
proc ei_get_fd*(ei: ptr Ei): cint {.ei_import, importc: "ei_get_fd".}
  ## Получить файловый дескриптор для мониторинга в event loop

# ============================================================================
# Синхронизация (ping/pong)
# ============================================================================

proc ei_new_ping*(ei: ptr Ei): ptr EiPing {.ei_import, importc: "ei_new_ping".}
  ## Создать объект для roundtrip-синхронизации (ожидать EI_EVENT_PONG)
proc ei_ping_get_id*(ping: ptr EiPing): uint64 {.
  ei_import, importc: "ei_ping_get_id".}
  ## Уникальный возрастущий ID объекта
proc ei_ping_ref*(ping: ptr EiPing): ptr EiPing {.ei_import, importc: "ei_ping_ref".}
proc ei_ping_unref*(ping: ptr EiPing): ptr EiPing {.ei_import, importc: "ei_ping_unref".}
proc ei_ping_set_user_data*(ping: ptr EiPing; userData: pointer) {.
  ei_import, importc: "ei_ping_set_user_data".}
proc ei_ping_get_user_data*(ping: ptr EiPing): pointer {.
  ei_import, importc: "ei_ping_get_user_data".}
proc ei_ping*(ping: ptr EiPing) {.ei_import, importc: "ei_ping".}
  ## Отправить запрос синхронизации; сервер ответит событием EI_EVENT_PONG

# ============================================================================
# Диспетчеризация событий
# ============================================================================

proc ei_dispatch*(ei: ptr Ei) {.ei_import, importc: "ei_dispatch".}
  ## Обработать доступные события с файлового дескриптора
  ## Вызывать при готовности fd от ei_get_fd()
proc ei_get_event*(ei: ptr Ei): ptr EiEvent {.ei_import, importc: "ei_get_event".}
  ## Получить следующее событие из очереди (удаляет из очереди)
  ## Возвращённый объект нужно освободить через ei_event_unref()
proc ei_peek_event*(ei: ptr Ei): ptr EiEvent {.ei_import, importc: "ei_peek_event".}
  ## Заглянуть в следующее событие без удаления из очереди
proc ei_now*(ei: ptr Ei): uint64 {.ei_import, importc: "ei_now".}
  ## Текущее время в микросекундах (CLOCK_MONOTONIC)
proc ei_disconnect*(ei: ptr Ei) {.ei_import, importc: "ei_disconnect".}
  ## Принудительно разорвать соединение с сервером

# ============================================================================
# Работа с сиду (struct ei_seat)
# ============================================================================

proc ei_seat_set_user_data*(seat: ptr EiSeat; userData: pointer) {.
  ei_import, importc: "ei_seat_set_user_data".}
proc ei_seat_get_user_data*(seat: ptr EiSeat): pointer {.
  ei_import, importc: "ei_seat_get_user_data".}
proc ei_seat_get_name*(seat: ptr EiSeat): cstring {.
  ei_import, importc: "ei_seat_get_name".}
  ## Имя сида (может быть NULL)
proc ei_seat_has_capability*(seat: ptr EiSeat; cap: EiDeviceCapability): bool {.
  ei_import, importc: "ei_seat_has_capability".}
  ## Проверить, поддерживает ли сид данную возможность
proc ei_seat_bind_capabilities*(seat: ptr EiSeat; caps: varargs[EiDeviceCapability, EiDeviceCapability(0)]) {.
  ei_import, importc: "ei_seat_bind_capabilities", varargs.}
  ## Забиндить клиент к возможностям сида (завершать 0 как sentinel)
  ## Пример: ei_seat_bind_capabilities(seat, Pointer, Keyboard, 0)
proc ei_seat_unbind_capabilities*(seat: ptr EiSeat; caps: varargs[EiDeviceCapability, EiDeviceCapability(0)]) {.
  ei_import, importc: "ei_seat_unbind_capabilities", varargs.}
  ## Отвязать ранее забинденные возможности
proc ei_seat_request_device_with_capabilities*(seat: ptr EiSeat;
    caps: varargs[EiDeviceCapability, EiDeviceCapability(0)]) {.
  ei_import, importc: "ei_seat_request_device_with_capabilities", varargs.}
  ## Запросить у сервера создание устройства с указанными возможностями
proc ei_seat_ref*(seat: ptr EiSeat): ptr EiSeat {.ei_import, importc: "ei_seat_ref".}
proc ei_seat_unref*(seat: ptr EiSeat): ptr EiSeat {.ei_import, importc: "ei_seat_unref".}
proc ei_seat_get_context*(seat: ptr EiSeat): ptr Ei {.
  ei_import, importc: "ei_seat_get_context".}
  ## Получить родительский контекст ei

# ============================================================================
# Работа с событиями (struct ei_event)
# ============================================================================

proc ei_event_ref*(event: ptr EiEvent): ptr EiEvent {.ei_import, importc: "ei_event_ref".}
proc ei_event_unref*(event: ptr EiEvent): ptr EiEvent {.ei_import, importc: "ei_event_unref".}
proc ei_event_get_type*(event: ptr EiEvent): EiEventType {.
  ei_import, importc: "ei_event_get_type".}
proc ei_event_get_device*(event: ptr EiEvent): ptr EiDevice {.
  ei_import, importc: "ei_event_get_device".}
  ## Получить устройство, сгенерировавшее событие
proc ei_event_get_seat*(event: ptr EiEvent): ptr EiSeat {.
  ei_import, importc: "ei_event_get_seat".}
  ## Получить сид события (NULL для Connect/Disconnect)
proc ei_event_get_time*(event: ptr EiEvent): uint64 {.
  ei_import, importc: "ei_event_get_time".}
  ## Время события в микросекундах (для EI_EVENT_FRAME)

# ----------------------------------------------------------------------------
# Геттеры для конкретных типов событий (receiver API)
# ----------------------------------------------------------------------------

## === События эмуляции ===
proc ei_event_emulating_get_sequence*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_emulating_get_sequence".}
  ## Для EI_EVENT_DEVICE_START_EMULATING: номер последовательности
## === События модификаторов ===
proc ei_event_keyboard_get_xkb_mods_depressed*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_keyboard_get_xkb_mods_depressed".}
proc ei_event_keyboard_get_xkb_mods_latched*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_keyboard_get_xkb_mods_latched".}
proc ei_event_keyboard_get_xkb_mods_locked*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_keyboard_get_xkb_mods_locked".}
proc ei_event_keyboard_get_xkb_group*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_keyboard_get_xkb_group".}
## === События указателя ===
proc ei_event_pointer_get_dx*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_pointer_get_dx".}
proc ei_event_pointer_get_dy*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_pointer_get_dy".}
proc ei_event_pointer_get_absolute_x*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_pointer_get_absolute_x".}
proc ei_event_pointer_get_absolute_y*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_pointer_get_absolute_y".}
## === События кнопок ===
proc ei_event_button_get_button*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_button_get_button".}
  ## Код кнопки из linux/input-event-codes.h
proc ei_event_button_get_is_press*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_button_get_is_press".}
  ## true = нажатие, false = отпускание
## === События прокрутки ===
proc ei_event_scroll_get_dx*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_scroll_get_dx".}
proc ei_event_scroll_get_dy*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_scroll_get_dy".}
proc ei_event_scroll_get_stop_x*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_scroll_get_stop_x".}
proc ei_event_scroll_get_stop_y*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_scroll_get_stop_y".}
proc ei_event_scroll_get_discrete_dx*(event: ptr EiEvent): int32 {.
  ei_import, importc: "ei_event_scroll_get_discrete_dx".}
proc ei_event_scroll_get_discrete_dy*(event: ptr EiEvent): int32 {.
  ei_import, importc: "ei_event_scroll_get_discrete_dy".}
## === События клавиатуры ===
proc ei_event_keyboard_get_key*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_keyboard_get_key".}
  ## Код клавиши (evdev keycode из linux/input-event-codes.h)
proc ei_event_keyboard_get_key_is_press*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_keyboard_get_key_is_press".}
## === События тача ===
proc ei_event_touch_get_id*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_touch_get_id".}
  ## Уникальный трекинг-ид касания (действителен от down до up)
proc ei_event_touch_get_x*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_touch_get_x".}
proc ei_event_touch_get_y*(event: ptr EiEvent): cdouble {.
  ei_import, importc: "ei_event_touch_get_y".}
proc ei_event_touch_get_is_cancel*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_touch_get_is_cancel".}
  ## true, если касание было отменено, а не отпущено
## === Текстовые события (libei ≥1.6) ===
proc ei_event_text_get_keysym*(event: ptr EiEvent): uint32 {.
  ei_import, importc: "ei_event_text_get_keysym".}
  ## XKB-compatible keysym (не keycode!)
proc ei_event_text_get_keysym_is_press*(event: ptr EiEvent): bool {.
  ei_import, importc: "ei_event_text_get_keysym_is_press".}
proc ei_event_text_get_utf8*(event: ptr EiEvent): cstring {.
  ei_import, importc: "ei_event_text_get_utf8".}
  ## UTF-8 строка (только для EI_EVENT_TEXT_UTF8)
## === События ping ===
proc ei_event_pong_get_ping*(event: ptr EiEvent): ptr EiPing {.
  ei_import, importc: "ei_event_pong_get_ping".}
  ## Получить связанный EiPing для события EI_EVENT_PONG

# ============================================================================
# Работа с устройством (struct ei_device) — общие функции
# ============================================================================

proc ei_device_ref*(device: ptr EiDevice): ptr EiDevice {.
  ei_import, importc: "ei_device_ref".}
proc ei_device_unref*(device: ptr EiDevice): ptr EiDevice {.
  ei_import, importc: "ei_device_unref".}
proc ei_device_set_user_data*(device: ptr EiDevice; userData: pointer) {.
  ei_import, importc: "ei_device_set_user_data".}
proc ei_device_get_user_data*(device: ptr EiDevice): pointer {.
  ei_import, importc: "ei_device_get_user_data".}
proc ei_device_get_seat*(device: ptr EiDevice): ptr EiSeat {.
  ei_import, importc: "ei_device_get_seat".}
proc ei_device_get_context*(device: ptr EiDevice): ptr Ei {.
  ei_import, importc: "ei_device_get_context".}
proc ei_device_get_name*(device: ptr EiDevice): cstring {.
  ei_import, importc: "ei_device_get_name".}
  ## Имя устройства (может быть NULL)
proc ei_device_get_type*(device: ptr EiDevice): EiDeviceType {.
  ei_import, importc: "ei_device_get_type".}
proc ei_device_get_width*(device: ptr EiDevice): uint32 {.
  ei_import, importc: "ei_device_get_width".}
  ## Ширина в мм (только для Physical-устройств, иначе 0)
proc ei_device_get_height*(device: ptr EiDevice): uint32 {.
  ei_import, importc: "ei_device_get_height".}
  ## Высота в мм (только для Physical-устройств, иначе 0)
proc ei_device_has_capability*(device: ptr EiDevice; cap: EiDeviceCapability): bool {.
  ei_import, importc: "ei_device_has_capability".}
proc ei_device_close*(device: ptr EiDevice) {.
  ei_import, importc: "ei_device_close".}
  ## Уведомить сервер, что клиент больше не интересуется этим устройством

# ============================================================================
# Работа с регионами (struct ei_region) — для Virtual-устройств
# ============================================================================

proc ei_device_get_region*(device: ptr EiDevice; index: csize_t): ptr EiRegion {.
  ei_import, importc: "ei_device_get_region".}
  ## Получить регион по индексу (не увеличивает refcount)
proc ei_device_get_region_at*(device: ptr EiDevice; x, y: cdouble): ptr EiRegion {.
  ei_import, importc: "ei_device_get_region_at".}
  ## Найти регион, содержащий точку (x, y) в глобальных координатах
proc ei_region_ref*(region: ptr EiRegion): ptr EiRegion {.
  ei_import, importc: "ei_region_ref".}
proc ei_region_unref*(region: ptr EiRegion): ptr EiRegion {.
  ei_import, importc: "ei_region_unref".}
proc ei_region_set_user_data*(region: ptr EiRegion; userData: pointer) {.
  ei_import, importc: "ei_region_set_user_data".}
proc ei_region_get_user_data*(region: ptr EiRegion): pointer {.
  ei_import, importc: "ei_region_get_user_data".}
proc ei_region_get_x*(region: ptr EiRegion): uint32 {.
  ei_import, importc: "ei_region_get_x".}
proc ei_region_get_y*(region: ptr EiRegion): uint32 {.
  ei_import, importc: "ei_region_get_y".}
proc ei_region_get_width*(region: ptr EiRegion): uint32 {.
  ei_import, importc: "ei_region_get_width".}
proc ei_region_get_height*(region: ptr EiRegion): uint32 {.
  ei_import, importc: "ei_region_get_height".}
proc ei_region_get_mapping_id*(region: ptr EiRegion): cstring {.
  ei_import, importc: "ei_region_get_mapping_id".}
  ## Внешний идентификатор региона (если поддерживается сервером, libei ≥1.1)
proc ei_region_contains*(region: ptr EiRegion; x, y: cdouble): bool {.
  ei_import, importc: "ei_region_contains".}
  ## Проверить, лежит ли точка (x, y) внутри региона
proc ei_region_convert_point*(region: ptr EiRegion; x, y: ptr cdouble): bool {.
  ei_import, importc: "ei_region_convert_point".}
  ## Преобразовать глобальные координаты (x, y) в локальные относительно региона
  ## Возвращает true, если точка внутри; модифицирует x и y на выходе
proc ei_region_get_physical_scale*(region: ptr EiRegion): cdouble {.
  ei_import, importc: "ei_region_get_physical_scale".}
  ## Физический масштаб региона (по умолчанию 1.0)

# ============================================================================
# Работа с keymap (struct ei_keymap)
# ============================================================================

proc ei_device_keyboard_get_keymap*(device: ptr EiDevice): ptr EiKeymap {.
  ei_import, importc: "ei_device_keyboard_get_keymap".}
  ## Получить keymap для клавиатурного устройства (может быть NULL)
proc ei_keymap_ref*(keymap: ptr EiKeymap): ptr EiKeymap {.
  ei_import, importc: "ei_keymap_ref".}
proc ei_keymap_unref*(keymap: ptr EiKeymap): ptr EiKeymap {.
  ei_import, importc: "ei_keymap_unref".}
proc ei_keymap_set_user_data*(keymap: ptr EiKeymap; userData: pointer) {.
  ei_import, importc: "ei_keymap_set_user_data".}
proc ei_keymap_get_user_data*(keymap: ptr EiKeymap): pointer {.
  ei_import, importc: "ei_keymap_get_user_data".}
proc ei_keymap_get_type*(keymap: ptr EiKeymap): EiKeymapType {.
  ei_import, importc: "ei_keymap_get_type".}
proc ei_keymap_get_size*(keymap: ptr EiKeymap): csize_t {.
  ei_import, importc: "ei_keymap_get_size".}
  ## Размер данных keymap в байтах
proc ei_keymap_get_fd*(keymap: ptr EiKeymap): cint {.
  ei_import, importc: "ei_keymap_get_fd".}
  ## Файловый дескриптор с mmap-able keymap данными (не закрывать!)
proc ei_keymap_get_device*(keymap: ptr EiKeymap): ptr EiDevice {.
  ei_import, importc: "ei_keymap_get_device".}
  ## Устройство, к которому привязан keymap

# ============================================================================
# Sender API: отправка событий (только для ei_new_sender)
# ============================================================================

proc ei_device_start_emulating*(device: ptr EiDevice; sequence: uint32) {.
  ei_import, importc: "ei_device_start_emulating".}
  ## Начать эмуляцию событий на устройстве
  ## sequence должен возрастать при каждом вызове
proc ei_device_stop_emulating*(device: ptr EiDevice) {.
  ei_import, importc: "ei_device_stop_emulating".}
  ## Остановить эмуляцию (сбросить состояние устройства при необходимости)
proc ei_device_frame*(device: ptr EiDevice; time: uint64) {.
  ei_import, importc: "ei_device_frame".}
  ## Завершить группу событий фреймом (обязательно вызывать после событий)
  ## time — время в микросекундах (использовать ei_now())
## === Указатель ===
proc ei_device_pointer_motion*(device: ptr EiDevice; x, y: cdouble) {.
  ei_import, importc: "ei_device_pointer_motion".}
  ## Относительное движение курсора
proc ei_device_pointer_motion_absolute*(device: ptr EiDevice; x, y: cdouble) {.
  ei_import, importc: "ei_device_pointer_motion_absolute".}
  ## Абсолютное позиционирование (координаты должны быть внутри региона)
## === Кнопки ===
proc ei_device_button_button*(device: ptr EiDevice; button: uint32; isPress: bool) {.
  ei_import, importc: "ei_device_button_button".}
  ## Нажатие/отпускание кнопки (button — код из linux/input-event-codes.h)
## === Прокрутка ===
proc ei_device_scroll_delta*(device: ptr EiDevice; x, y: cdouble) {.
  ei_import, importc: "ei_device_scroll_delta".}
  ## Плавная прокрутка (в пикселях/мм)
proc ei_device_scroll_discrete*(device: ptr EiDevice; x, y: int32) {.
  ei_import, importc: "ei_device_scroll_discrete".}
  ## Дискретная прокрутка (120 = один шаг колёсика)
proc ei_device_scroll_stop*(device: ptr EiDevice; stopX, stopY: bool) {.
  ei_import, importc: "ei_device_scroll_stop".}
  ## Остановка прокрутки (сервер может продолжить кинетическую прокрутку)
proc ei_device_scroll_cancel*(device: ptr EiDevice; cancelX, cancelY: bool) {.
  ei_import, importc: "ei_device_scroll_cancel".}
  ## Полная отмена прокрутки (сервер не должен эмулировать дальнейшие события)
## === Клавиатура ===
proc ei_device_keyboard_key*(device: ptr EiDevice; keycode: uint32; isPress: bool) {.
  ei_import, importc: "ei_device_keyboard_key".}
  ## Нажатие/отпускание клавиши (keycode — evdev scancode)
## === Текст (libei ≥1.6) ===
proc ei_device_text_keysym*(device: ptr EiDevice; keysym: uint32; isPress: bool) {.
  ei_import, importc: "ei_device_text_keysym".}
  ## Событие keysym (XKB, не зависит от keymap устройства)
proc ei_device_text_utf8*(device: ptr EiDevice; utf8: cstring) {.
  ei_import, importc: "ei_device_text_utf8".}
  ## Отправить UTF-8 строку (длина вычисляется автоматически)
proc ei_device_text_utf8_with_length*(device: ptr EiDevice; text: cstring; length: csize_t) {.
  ei_import, importc: "ei_device_text_utf8_with_length".}
  ## Отправить UTF-8 строку с явной длиной (без нуль-терминатора)
## === Тач ===
proc ei_device_touch_new*(device: ptr EiDevice): ptr EiTouch {.
  ei_import, importc: "ei_device_touch_new".}
  ## Создать новый объект касания (начальная ссылка = 1)
proc ei_touch_ref*(touch: ptr EiTouch): ptr EiTouch {.
  ei_import, importc: "ei_touch_ref".}
proc ei_touch_unref*(touch: ptr EiTouch): ptr EiTouch {.
  ei_import, importc: "ei_touch_unref".}
proc ei_touch_set_user_data*(touch: ptr EiTouch; userData: pointer) {.
  ei_import, importc: "ei_touch_set_user_data".}
proc ei_touch_get_user_data*(touch: ptr EiTouch): pointer {.
  ei_import, importc: "ei_touch_get_user_data".}
proc ei_touch_get_device*(touch: ptr EiTouch): ptr EiDevice {.
  ei_import, importc: "ei_touch_get_device".}
proc ei_touch_down*(touch: ptr EiTouch; x, y: cdouble) {.
  ei_import, importc: "ei_touch_down".}
  ## Начать касание в точке (x, y); можно вызвать только один раз на объект
proc ei_touch_motion*(touch: ptr EiTouch; x, y: cdouble) {.
  ei_import, importc: "ei_touch_motion".}
  ## Переместить активное касание
proc ei_touch_up*(touch: ptr EiTouch) {.
  ei_import, importc: "ei_touch_up".}
  ## Отпустить касание; после этого объект становится неактивным
proc ei_touch_cancel*(touch: ptr EiTouch) {.
  ei_import, importc: "ei_touch_cancel".}
  ## Отменить касание (эквивалентно ei_touch_up, если сервер не поддерживает v2+)

# ============================================================================
# Идиоматичные обёртки для Nim (RAII-паттерны)
# ============================================================================

type
  EiContext* = ref object
    ## RAII-обёртка для ptr Ei с автоматическим unref
    raw*: ptr Ei
  EiDeviceHandle* = ref object
    raw*: ptr EiDevice
  EiEventHandle* = ref object
    raw*: ptr EiEvent

# ----------------------------------------------------------------------------
# Конструкторы и деструкторы
# ----------------------------------------------------------------------------

proc newEiSender*(userData: pointer = nil): EiContext =
  ## Создать контекст-отправитель с автоматическим управлением памятью
  result = EiContext(raw: ei_new_sender(userData))

proc newEiReceiver*(userData: pointer = nil): EiContext =
  ## Создать контекст-получатель с автоматическим управлением памятью
  result = EiContext(raw: ei_new_receiver(userData))

proc `destroy`*(ctx: EiContext) =
  ## Автоматический деструктор: вызвать ei_unref
  if ctx.raw != nil: discard ei_unref(ctx.raw)

proc setupBackendFd*(ctx: EiContext; fd: cint): bool =
  ## Инициализировать бэкенд на файловом дескрипторе
  result = ei_setup_backend_fd(ctx.raw, fd) == 0

proc setupBackendSocket*(ctx: EiContext; socketPath: string): bool =
  ## Инициализировать бэкенд на сокете по пути
  result = ei_setup_backend_socket(ctx.raw, socketPath.cstring) == 0

proc getFd*(ctx: EiContext): cint =
  ## Получить fd для мониторинга в event loop
  result = ei_get_fd(ctx.raw)

proc dispatch*(ctx: EiContext) =
  ## Обработать доступные события
  ei_dispatch(ctx.raw)

proc getNextEvent*(ctx: EiContext): EiEventHandle =
  ## Получить следующее событие (с автоматическим unref при уничтожении)
  let raw = ei_get_event(ctx.raw)
  if raw != nil:
    result = EiEventHandle(raw: raw)
  else:
    result = nil

proc `destroy`*(event: EiEventHandle) =
  ## Автоматический unref для события
  if event.raw != nil: discard ei_event_unref(event.raw)

# ----------------------------------------------------------------------------
# Удобные методы для обработки событий
# ----------------------------------------------------------------------------

proc `$`*(eventType: EiEventType): string =
  ## Строковое представление типа события
  let cstr = ei_event_type_to_string(eventType)
  if cstr != nil: $cstr else: $int(eventType)

proc isKeyboardEvent*(event: EiEventHandle): bool =
  ## Быстрая проверка: является ли событие клавиатурным
  event.raw != nil and ei_event_get_type(event.raw) in [
    EiEventType.KeyboardKey, EiEventType.KeyboardModifiers]

proc getKeyboardKey*(event: EiEventHandle): tuple[keycode: uint32, isPress: bool] =
  ## Извлечь keycode и состояние из клавиатурного события
  result.keycode = ei_event_keyboard_get_key(event.raw)
  result.isPress = ei_event_keyboard_get_key_is_press(event.raw)

proc getPointerMotion*(event: EiEventHandle): tuple[dx, dy: float] =
  ## Извлечь относительное движение указателя
  result.dx = ei_event_pointer_get_dx(event.raw)
  result.dy = ei_event_pointer_get_dy(event.raw)

# ----------------------------------------------------------------------------
# Утилиты для отправки событий (sender)
# ----------------------------------------------------------------------------

proc sendKey*(device: ptr EiDevice; keycode: uint32; press: bool; frameTime: uint64) =
  ## Отправить событие клавиши с автоматическим фреймом
  ei_device_keyboard_key(device, keycode, press)
  ei_device_frame(device, frameTime)

proc sendText*(device: ptr EiDevice; text: string; frameTime: uint64) =
  ## Отправить UTF-8 текст с автоматическим фреймом (libei ≥1.6)
  ei_device_text_utf8(device, text.cstring)
  ei_device_frame(device, frameTime)

proc sendPointerMotion*(device: ptr EiDevice; dx, dy: float; frameTime: uint64) =
  ## Отправить относительное движение с фреймом
  ei_device_pointer_motion(device, dx, dy)
  ei_device_frame(device, frameTime)

# ============================================================================
# Константы из linux/input-event-codes.h (часто используемые)
# ============================================================================

const
  # Клавиши-модификаторы
  KEY_LEFTCTRL* = 29
  KEY_RIGHTCTRL* = 97
  KEY_LEFTSHIFT* = 42
  KEY_RIGHTSHIFT* = 54
  KEY_LEFTALT* = 56
  KEY_RIGHTALT* = 100
  KEY_LEFTMETA* = 125
  KEY_RIGHTMETA* = 126
  
  # Специальные клавиши
  KEY_PAUSE* = 119      # Для WaylandSwitcher: триггер конвертации
  KEY_ENTER* = 28
  KEY_BACKSPACE* = 14
  KEY_SPACE* = 57
  KEY_ESC* = 1
  
  # Кнопки мыши
  BTN_LEFT* = 272
  BTN_RIGHT* = 273
  BTN_MIDDLE* = 274
  
  # Колёсико (для дискретной прокрутки)
  REL_WHEEL* = 8
  REL_HWHEEL* = 6
  WHEEL_CLICK_VALUE* = 120  # Одно «клик» колёсика

# ============================================================================
# Пример использования (псевдокод для WaylandSwitcher)
# ============================================================================
#
# let ctx = newEiSender()
# ctx.configureName("WaylandSwitcher")
# if not ctx.setupBackendSocket(""):  # Использовать $LIBEI_SOCKET
#   quit("Failed to connect to EIS", 1)
#
# # В главном цикле:
# while true:
#   if poll(ctx.getFd(), timeout=100):  # Ваш event loop
#     ctx.dispatch()
#     while let event = ctx.getNextEvent():
#       case event.raw.ei_event_get_type()
#       of EiEventType.Connect:
#         echo "Connected to EIS"
#       of EiEventType.SeatAdded:
#         let seat = event.raw.ei_event_get_seat()
#         seat.ei_seat_bind_capabilities(Keyboard, Pointer, 0)
#       of EiEventType.DeviceAdded:
#         let dev = event.raw.ei_event_get_device()
#         if dev.ei_device_has_capability(Keyboard):
#           # Запомнить устройство для отправки клавиш
#           keyboardDevice = dev
#       of EiEventType.DeviceResumed:
#         # Можно отправлять события
#         if keyboardDevice != nil:
#           keyboardDevice.ei_device_start_emulating(sequence=1)
#       else: discard
#
# # При нажатии PAUSE в evdev-мониторе:
# proc convertAndInject(rawText: string) =
#   let converted = convertLayout(rawText)  # Ваша логика RU↔EN
#   if keyboardDevice != nil:
#     # Вариант 1: через keysym (libei ≥1.6)
#     for ch in converted:
#       let keysym = charToKeysym(ch)  # Ваша функция
#       keyboardDevice.ei_device_text_keysym(keysym, true)
#       keyboardDevice.ei_device_text_keysym(keysym, false)
#       keyboardDevice.ei_device_frame(ei_now(ctx.raw))
#
#     # Вариант 2: через UTF-8 (проще, но может не работать в некоторых IME)
#     # keyboardDevice.ei_device_text_utf8(converted.cstring)
#     # keyboardDevice.ei_device_frame(ei_now(ctx.raw))
#
# ============================================================================
# Примечания по использованию в WaylandSwitcher
# ============================================================================
#
# 1. libei требует, чтобы клиент был авторизован через xdg-desktop-portal
#    или запущен с соответствующими правами. В личном окружении можно
#    использовать ei_setup_backend_socket() с сокетом от Mutter.
#
# 2. Для глобального перехвата клавиши PAUSE используйте libevdev на уровне
#    /dev/input/event* (требует root или CAP_DAC_READ_SEARCH).
#
# 3. Конвертация раскладки должна учитывать:
#    - Регистр первого символа и заглавных букв
#    - Пунктуацию и цифры (опционально)
#    - Направление автоопределения (по первому символу)
#
# 4. Всегда вызывайте ei_device_frame() после отправки событий — иначе
#    сервер может не обработать их корректно.
#
# 5. Для синхронизации состояния модификаторов используйте ei_ping()
#    и ожидайте EI_EVENT_PONG перед критическими действиями.
#
# ============================================================================