#include <BraccioRobot.h>
#include <Position.h>

const uint8_t TRIGGER_PIN = 2;  // waits for HIGH
const uint8_t BUSY_PIN    = 3;  // HIGH while moving, LOW when ready

/*
  base -> shoulder -> elbow -> wrist -> rotate -> grip
 
  base      0–180
  shoulder  ~15–165
  elbow     ~0–180
  wristVer  ~0–180
  wristRot  ~0–180
  gripper   ~10–73 (Braccio gripper)
*/

void move(int base, int shoulder, int elbow, int wrist, int wristRotation, int gripper) {
  Position p;
  p.set(base, shoulder, elbow, wrist, wristRotation, gripper);
  BraccioRobot.moveToPosition(p, 60);  
}

void ready(bool grip) {
  if (grip) {
    move(90, 90, 90, 90, 90, 50);
  
  } else {
    move(90, 90, 90, 90, 90, 10);
  }
}

void take(bool reversed) {
  if (reversed) {
    // Window
    move(90, 90, 166, 150, 90, 10);    
    move(90, 90, 166, 150, 90, 70);
    ready(true);
    move(90, 90, 5, 30, 90, 70);
    move(90, 90, 5, 30, 90, 10);
    ready(false);
  } else {
    move(90, 90, 5, 25, 90, 10);
    move(90, 90, 5, 25, 90, 70);
    ready(true);
    move(90, 90, 166, 150, 90, 70);    
    move(90, 90, 166, 150, 90, 10);
    ready(false);
  }
}

void setup() {
  BraccioRobot.init();
  BraccioRobot.powerOn();
  BraccioRobot.setStartSpeed(20);
  pinMode(TRIGGER_PIN, INPUT); // or INPUT_PULLUP if needed
  pinMode(BUSY_PIN, OUTPUT);
  digitalWrite(BUSY_PIN, LOW);
  ready(false);
}

bool reversed = true;

void loop() {
  // wait for trigger
  while (digitalRead(TRIGGER_PIN) == LOW) {
    // do nothing, block
  }

  digitalWrite(BUSY_PIN, HIGH);

  //take(reversed);
  delay(4000);
  reversed = !reversed;

  digitalWrite(BUSY_PIN, LOW);

  // optional: wait for trigger to go LOW again to avoid retrigger
  while (digitalRead(TRIGGER_PIN) == HIGH) {
    // block
  }
}

/*
void loop() {
  delay(10000);
  take(reversed);
  reversed = !reversed;
}
*/

/*
void loop() {
  uint8_t reading = digitalRead(CONTACT_PIN);

  if (reading != lastReading) {
    lastChange = millis();
    lastReading = reading;
  }

  if ((millis() - lastChange) > DEBOUNCE_MS && reading != stableState) {
    stableState = reading;

    if (stableState == LOW) {
      if (!isGrabbed) {
        BraccioRobot.moveToPosition(grabPos, 100);
        isGrabbed = true;
      }
    } else {
      if (isGrabbed) {
        BraccioRobot.moveToPosition(readyPos, 100);
        BraccioRobot.moveToPosition(gripPos, 100);
        isGrabbed = false;
      }
    }
  }
}
*/
