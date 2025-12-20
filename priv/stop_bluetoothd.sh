#!/bin/sh
#
#   Terminate bluetoothd
#   setup hci for pure ble
#

sudo systemctl stop bluetooth
sudo rfkill unblock bluetooth

sudo hciconfig hci0 up
sudo btmgmt --index 0 power off
sudo btmgmt --index 0 le on
sudo btmgmt --index 0 bredr off
sudo btmgmt --index 0 power on
