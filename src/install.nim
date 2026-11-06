## install.nim — установка и удаление systemd-юнита.
##
## Сам бинарник копирует reinstall.sh из корня проекта; этот модуль только
## пишет и удаляет файл юнита (wayland-switcher -i / -u). Юнит ссылается на
## путь к тому бинарнику, из которого запущена команда установки.

import os, strutils
import types, core, shellquote

const UnitTemplate = """
[Unit]
Description=WaylandSwitcher - keyboard layout switcher
Documentation=https://github.com/Balans097/WaylandSwitcher
Requires=local-fs.target
After=local-fs.target
StartLimitIntervalSec=10
StartLimitBurst=3

[Service]
Type=simple
ExecStart=$1 -r
Restart=on-failure
RestartSec=3
# Базовая изоляция для службы, работающей от root:
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/etc/wayland-switcher
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
"""

proc runInstall*() =
  ## Создаёт systemd-юнит и объясняет, как его активировать.
  logMsg(false, "Установка демона WaylandSwitcher...")
  let binPath = getAppFilename()
  if not binPath.startsWith("/usr/"):
    logMsg(false, "Предупреждение: бинарник находится вне /usr (" & binPath &
           "). Служба может не запуститься (например, из-за SELinux). " &
           "Рекомендуется установка через reinstall.sh.")
  let unitContent = UnitTemplate.strip() % [shellQuote(binPath)]
  try:
    writeFile(SYSTEMD_UNIT_FILE, unitContent & "\n")
    logMsg(false, "Юнит создан: " & SYSTEMD_UNIT_FILE & ", версия: " & VERSION)
    logMsg(false, "Для активации выполните:")
    logMsg(false, "  systemctl daemon-reload")
    logMsg(false, "  systemctl enable --now wayland-switcher")
  except CatchableError as e:
    logMsg(true, "Ошибка создания systemd unit-файла: " & e.msg & ". Нужны права root?")

proc runUninstall*() =
  ## Удаляет systemd-юнит.
  logMsg(false, "Удаление демона WaylandSwitcher...")
  if fileExists(SYSTEMD_UNIT_FILE):
    try:
      removeFile(SYSTEMD_UNIT_FILE)
      logMsg(false, "Юнит удалён.")
      logMsg(false, "Выполните 'systemctl daemon-reload' для применения изменений.")
    except CatchableError as e:
      logMsg(true, "Ошибка удаления " & SYSTEMD_UNIT_FILE & ": " & e.msg &
             ". Нужны права root?")
  else:
    logMsg(true, "Нечего удалять: unit-файл не найден: " & SYSTEMD_UNIT_FILE)
