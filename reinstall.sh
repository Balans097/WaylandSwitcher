#!/bin/sh
#
# reinstall.sh — устанавливает собранный бинарник WaylandSwitcher
# (лежащий рядом со скриптом), проверяет и запускает systemd-службу.
#
# Сборка выполняется отдельно:
#   nim c --threads:on -d:release WaylandSwitcher.nim
#
# Использование:
#   ./reinstall.sh          (sudo будет вызван автоматически)
#
# Что делает скрипт:
#   1. Проверяет, что рядом лежит исполняемый ./WaylandSwitcher.
#   2. Останавливает службу, если она запущена.
#   3. Копирует бинарник в /usr/local/bin/wayland-switcher
#      (во временный файл + mv — атомарная замена), права 0755 root:root,
#      восстанавливает контекст SELinux.
#   4. Создаёт/обновляет systemd-юнит (wayland-switcher -i) и делает daemon-reload.
#   5. Проверяет наличие конфига; если его нет — предлагает настроить (-c).
#   6. Включает автозапуск, запускает службу и проверяет, что она
#      действительно работает; при ошибке показывает журнал.

set -eu

BIN_NAME="wayland-switcher"
DST="/usr/local/bin/$BIN_NAME"          # путь установки бинарника
CONF="/etc/wayland-switcher/default.conf"
UNIT="wayland-switcher.service"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/WaylandSwitcher"

# ── Права root ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Нужны права root, перезапускаю через sudo..."
  exec sudo -- "$0" "$@"
fi

# ── Проверка исходного бинарника ──────────────────────────────────────────────
if [ ! -f "$SRC" ]; then
  echo "Ошибка: $SRC не найден." >&2
  echo "Сначала соберите проект: nim c --threads:on -d:release WaylandSwitcher.nim" >&2
  exit 1
fi
if [ ! -x "$SRC" ]; then
  echo "Ошибка: $SRC не является исполняемым файлом (chmod +x)." >&2
  exit 1
fi
# Бинарник должен запускаться (быстрая проверка, что это не битый файл)
if ! "$SRC" -h >/dev/null 2>&1; then
  echo "Ошибка: $SRC не запускается (пересоберите проект)." >&2
  exit 1
fi

# ── Остановка службы ──────────────────────────────────────────────────────────
if systemctl is-active --quiet "$UNIT"; then
  echo "Останавливаю службу..."
  systemctl stop "$UNIT"
fi

# ── Копирование бинарника ─────────────────────────────────────────────────────
echo "Копирую $SRC -> $DST"
mkdir -p "$(dirname "$DST")"
TMP="$DST.new"
trap 'rm -f "$TMP"' EXIT
install -m 0755 -o root -g root "$SRC" "$TMP"
mv -f "$TMP" "$DST"
trap - EXIT

if command -v restorecon >/dev/null 2>&1; then
  restorecon -v "$DST" || true
fi

if ! cmp -s "$SRC" "$DST"; then
  echo "Ошибка: установленный файл отличается от исходного." >&2
  exit 1
fi
echo "Бинарник установлен."

# ── systemd-юнит ──────────────────────────────────────────────────────────────
# -i пишет юнит с ExecStart, указывающим на путь запущенного бинарника,
# поэтому вызываем уже установленную копию.
echo "Создаю systemd-юнит..."
"$DST" -i
systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null || true

# ── Конфиг ────────────────────────────────────────────────────────────────────
if [ ! -f "$CONF" ]; then
  echo
  echo "Конфиг $CONF не найден — служба без него не запустится."
  if [ -t 0 ]; then
    echo "Запускаю интерактивную настройку..."
    "$DST" -c
  fi
  if [ ! -f "$CONF" ]; then
    echo "Настройте вручную: sudo $BIN_NAME -c" >&2
    echo "Затем: sudo systemctl enable --now $UNIT" >&2
    exit 1
  fi
fi

# ── Запуск и проверка ─────────────────────────────────────────────────────────
echo "Включаю автозапуск и запускаю службу..."
systemctl enable "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT"

# Даём службе время стартовать и убеждаемся, что она не упала
sleep 2
if systemctl is-active --quiet "$UNIT"; then
  echo "Готово: служба $UNIT работает."
  systemctl --no-pager --lines=5 status "$UNIT" || true
else
  echo "ОШИБКА: служба $UNIT не запущена." >&2
  systemctl --no-pager --lines=0 status "$UNIT" >&2 || true
  echo "--- последние записи журнала ---" >&2
  journalctl -u "$UNIT" -b --no-pager -n 25 >&2 || true
  exit 1
fi
