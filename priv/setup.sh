
start)
      sudo systemctl start bluetooth.service
      sudo hciconfig hci0 down
      sudo hciconfig hci0 reset
      sudo hcitool -i hci0 cmd 08 09
stop)
      sudo systemctl start bluetooth.service
      sudo hciconfig hci0 down && sudo hciconfig hci0 up
      sudo hciconfig hci0 reset
      sudo hcitool -i hci0 cmd 08 09	   


