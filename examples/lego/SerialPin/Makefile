# Simply use arduino-cli
#
FQBN=arduino:avr:uno
#DEV=/dev/ttyACM0
DEV=/dev/serial/by-id/usb-Arduino_Srl_Arduino_Uno_55431313038351C04281-if00

compile:
	arduino-cli compile -e --fqbn $(FQBN)

upload:
	arduino-cli upload -p $(DEV) --fqbn $(FQBN)
