#include <Wire.h>

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
  while (!Serial);
  Serial.println("\n--- Simple I2C Scanner for GPIO 6 and 7 ---");
}

void loop() {
  Wire1.setSDA(6);
  Wire1.setSCL(7);
  Wire1.begin();
  
  byte error, address;
  int nDevices = 0;
  
  Serial.println("Scanning GPIO 6 and 7...");
  
  for(address = 1; address < 127; address++) {
    Wire1.beginTransmission(address);
    error = Wire1.endTransmission();
    
    if (error == 0) {
      Serial.print("SUCCESS! Found device at 0x");
      Serial.println(address, HEX);
      nDevices++;
    }
  }
  
  if (nDevices == 0) {
    Serial.println("Nothing found on GPIO 6 and 7.");
  } else {
    Serial.println("Scan complete.");
  }
  
  digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
  delay(3000);
}
