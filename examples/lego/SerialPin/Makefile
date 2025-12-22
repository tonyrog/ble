# Simply use arduino-cli
#
FQBN=arduino:avr:uno
DEV=/dev/ttyACM0

compile:
	arduino-cli compile --fqbn $(FQBN)

upload:
	arduino-cli upload -p $(DEV) --fqbn $(FQBN)
