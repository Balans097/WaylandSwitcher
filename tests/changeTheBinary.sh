# 1. Остановить службу
sudo systemctl stop wayland-switcher

# 2. Заменить исполняемый файл
sudo cp ../WaylandSwitcher /bin/wayland-switcher

# 3. Восстановить права и владельца (должны совпадать с оригиналом)
sudo chown root:root /bin/wayland-switcher
sudo chmod +x /bin/wayland-switcher

# 4. ⚠️ Восстановить контекст SELinux (критично для Fedora!)
sudo restorecon -v /bin/wayland-switcher

# 5. Запустить службу
sudo systemctl start wayland-switcher

# 6. Проверить состояние и логи
sudo systemctl status wayland-switcher
journalctl -u wayland-switcher -n 30 --no-pager
