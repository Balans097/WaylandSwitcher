#!/bin/sh

sudo systemctl stop wayland-switcher
sudo cp ./WaylandSwitcher /usr/local/bin/wayland-switcher
sudo chmod 755 /usr/local/bin/wayland-switcher
sudo chown root:root /usr/local/bin/wayland-switcher
sudo systemctl start wayland-switcher



