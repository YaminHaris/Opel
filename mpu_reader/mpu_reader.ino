#include <Wire.h>
#include <TinyGPSPlus.h>

const int MPU_ADDR = 0x68; 
TinyGPSPlus gps;

// The NEO-6M GPS module defaults to 9600 baud
const uint32_t GPS_BAUD = 9600;

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
  
  // Set up GPS on Serial1 (GP0 for TX, GP1 for RX)
  Serial1.setRX(1);
  Serial1.setTX(0);
  Serial1.begin(GPS_BAUD);
  
  while (!Serial) {
    digitalWrite(LED_BUILTIN, HIGH);
    delay(100);
    digitalWrite(LED_BUILTIN, LOW);
    delay(100);
  }
  
  Serial.println("Starting Helmet Telemetry (MPU6050 + GPS)...");
  
  Wire1.setSDA(6);
  Wire1.setSCL(7);
  Wire1.begin();

  Wire1.beginTransmission(MPU_ADDR);
  uint8_t error = Wire1.endTransmission();
  
  if (error == 0) {
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x6B); 
    Wire1.write(0);    
    Wire1.endTransmission(true);

    // Set Accelerometer to +/- 16G (for crash detection)
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x1C); 
    Wire1.write(0x18); 
    Wire1.endTransmission(true);
  }
}

unsigned long lastPrintTime = 0;

void loop() {
  // 1. Constantly feed the GPS object with any new data from the NEO-6M
  while (Serial1.available() > 0) {
    gps.encode(Serial1.read());
  }

  // 2. Only print the data out every 100ms (10Hz) to keep the dashboard smooth
  if (millis() - lastPrintTime >= 100) {
    lastPrintTime = millis();
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
    
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x3B); 
    Wire1.endTransmission(false);
    
    Wire1.requestFrom(MPU_ADDR, 14, true); 
    
    if (Wire1.available() >= 14) {
      int16_t AcX = Wire1.read() << 8 | Wire1.read(); 
      int16_t AcY = Wire1.read() << 8 | Wire1.read(); 
      int16_t AcZ = Wire1.read() << 8 | Wire1.read(); 
      int16_t Tmp = Wire1.read() << 8 | Wire1.read(); 
      int16_t GyX = Wire1.read() << 8 | Wire1.read(); 
      int16_t GyY = Wire1.read() << 8 | Wire1.read(); 
      int16_t GyZ = Wire1.read() << 8 | Wire1.read(); 
      
      Serial.print("Accel: "); Serial.print(AcX);
      Serial.print(", "); Serial.print(AcY);
      Serial.print(", "); Serial.print(AcZ);
      Serial.print(" | Gyro: "); Serial.print(GyX);
      Serial.print(", "); Serial.print(GyY);
      Serial.print(", "); Serial.print(GyZ);
      Serial.print(" | Temp: "); Serial.print(Tmp);
      
      // Append GPS Data
      Serial.print(" | GPS: ");
      if (gps.location.isValid()) {
        Serial.print(gps.location.lat(), 6);
        Serial.print(",");
        Serial.print(gps.location.lng(), 6);
      } else {
        Serial.print("0.0,0.0");
      }
      Serial.print(",");
      if (gps.speed.isValid()) {
        Serial.print(gps.speed.kmph());
      } else {
        Serial.print("0.0");
      }
      Serial.print(",");
      Serial.println(gps.satellites.value());
    }
  }
}
