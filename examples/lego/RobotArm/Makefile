# Simply use arduino-cli
#
FQBN=arduino:avr:uno
#DEV=/dev/ttyACM1
DEV=/dev/serial/by-id/usb-Arduino__www.arduino.cc__0043_7413234343035171D1B0-if00

compile:
	arduino-cli compile --fqbn $(FQBN)

upload:
	arduino-cli upload -p $(DEV) --fqbn $(FQBN)
