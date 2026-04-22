# Wayland Switcher — let Linux be beautiful!
Keyboard layout switcher and input corrector for Linux on Wayland


<video src="test/screencast.mp4" controls width="640" preload="metadata"></video>


# Установка Wayland Switcher на Fedora Linux (GNOME, Wayland)

## Требования

- Fedora 44+, рабочий стол GNOME 50+ на Wayland
- Права `root` (все команды ниже выполняются через `sudo`)
- Nim 2.x и компилятор C (`gcc`) — только для сборки из исходников

---


## Клавиши управления и коррекции раскладки
**PAUSE** — исправление раскладки последнего набранного слова из всей фразы (до ближайшего левого пробела)

**Shift + PAUSE** — исправление раскладки всей набранной фразы

**Shift (с удержанием) + PAUSE** — исправление раскладки всей набранной фразы + смена регистра символов

---



## Сборка из исходников

```bash
nim c --threads:on -d:release WaylandSwitcher.nim
```

Результат — исполняемый файл `WaylandSwitcher` в текущей директории.

---

## Установка бинарного файла

Программа должна находиться в стандартном системном пути, чтобы SELinux разрешил
её запуск от имени системного сервиса. Рекомендуется `/usr/bin/`:

```bash
sudo cp WaylandSwitcher /usr/bin/wayland-switcher
sudo chmod +x /usr/bin/wayland-switcher
```

---

## Установка systemd-сервиса

WaylandSwitcher умеет установить unit-файл самостоятельно:

```bash
sudo wayland-switcher -i
```

Команда создаёт файл `/lib/systemd/system/wayland-switcher.service` и прописывает
в него путь к текущему исполняемому файлу. Если установка прошла успешно, вы
увидите сообщение:

```
WaylandSwitcher daemon successfully installed, version: 0.x
```

---

## Настройка

Запустите интерактивный конфигуратор:

```bash
sudo wayland-switcher -c
```

Конфигуратор последовательно попросит:

1. **Нажать Enter** — для автоматического определения клавиатуры среди устройств `/dev/input/event*`
2. **Нажать клавишу (или комбинацию)** переключения раскладки в вашей системе
3. **Нажать клавишу** для исправления ввода (по умолчанию рекомендуется Pause/Break)

---


