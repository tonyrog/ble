// General Pincontrol over serial port
#define UART_BAUD 9600

int pin_map[8] = {2,3,4,5,6,7,8,13};
uint8_t input  = 0;
uint8_t output = 0;
uint8_t event  = 0;
uint8_t timer  = 0;
uint8_t rmask  = 0;
uint8_t wmask  = 0;
uint8_t emask  = 0;
unsigned long last_tick;

#define RMASK 1  // <mask> 8 - bit mask for input pins
#define WMASK 2  // <mask> 8 - bit mask for output pins (prio over rmask)
#define WRITE 3  // <value> write command followed by byte with output bits
#define READ  4  // 
#define TIMER 5  // <time>*100ms report input interval
#define EVENT 6  // <mask>

void setup()
{
    Serial.begin(UART_BAUD);
    last_tick = millis();
}

uint8_t read_pins(uint8_t rm)
{
    int i;
    uint8_t in = 0;
    
    rm &= ~wmask;  // do not read outputs
    for (i = 0; i < 8; i++) {
	if (rm & (1 << i)) {
	    int val = digitalRead(pin_map[i]) == HIGH ? 1 : 0;
	    in |= (val << i);
	}
    }
    return in;
}

void write_pins(uint8_t wm, uint8_t out)
{
    int i;

    for (i = 0; i < 8; i++) {
	if (wm & (1 << i)) {
	    int val = (out & (1 << i)) ? HIGH : LOW;
	    digitalWrite(pin_map[i], val);
	}
    }
}

void set_mode(uint8_t wm, uint8_t rm)
{
    int i;

    rm &= ~wm;  // do not read outputs
    for (i = 0; i < 8; i++) {
	if (wm & (1 << i))
	    pinMode(pin_map[i], OUTPUT);
	else if (rm & (1 << i))
	    pinMode(pin_map[i], INPUT);
    }
}

void loop()
{
    unsigned long tick;

    input = read_pins(rmask);
    
    if (Serial.available()) {
	uint8_t c = Serial.read();
	switch(c) {
	case RMASK:
	    while (!Serial.available());
	    rmask = Serial.read();
	    set_mode(wmask, rmask);
	    break;
	case WMASK:
	    while (!Serial.available());
	    wmask = Serial.read();
	    set_mode(wmask, rmask);
	    write_pins(wmask, output);
	    break;
	case WRITE:
	    while (!Serial.available());
	    output = Serial.read();
	    write_pins(wmask, output);
	    break;
	case READ:
	    Serial.write(input);
	    break;
	case TIMER:
	    while (!Serial.available());
	    if (timer == 0)
	       last_tick = millis();
	    timer = Serial.read();
	    break;
	case EVENT:
	    while (!Serial.available());
	    emask = Serial.read();
	    break;
	default:
	    break;
	}
    }

    // we probably select either EVENT or TIMER, choice of user
    if (emask && ((event & emask) != (input & emask))) { // trigger event
       Serial.write(input & emask);
       event = input;
    }

    tick = millis();
    if (timer && ((tick - last_tick) >= timer*100)) {
	last_tick = tick;
	Serial.write(input);
    }
}
