#include <Wire.h>
#include <TinyGPSPlus.h>
#include <math.h>

const int MPU_ADDR = 0x68; 
TinyGPSPlus gps;
const uint32_t GPS_BAUD = 9600;

// --- HARDWARE PINS ---
const int IR_SENSOR_PIN = 15; // GP15 for IR Proximity OUT

// --- THRESHOLDS & CONSTANTS ---
const float G_FORCE_THRESHOLD = 4.0; // Wake up and start recording at 4G
const float DRAG_THRESHOLD = 1.5;    // Continuous noise threshold for sliding
const float TUMBLE_THRESHOLD = 300.0; // Degrees per second
const float PEAK_G_FATAL = 50.0;      // Instant fatality threshold

// --- STATE MACHINE ---
enum SystemState {
  ON_TABLE,         // IR = OUT, IMU = STILL
  ON_HEAD_NORMAL,   // IR = IN,  IMU = Normal
  IMPACT_DETECTED,  // Crash logic running
  SOS_TRIGGERED     // Alert active
};
SystemState currentState = ON_TABLE;

// --- CRASH PHYSICS BUFFERS ---
unsigned long impactStartTime = 0;
float maxGForce = 0.0;
float absorbedEnergy = 0.0; // Simplified Area Under Curve (Integral)
bool isTumbling = false;
bool isDragging = false;

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  pinMode(IR_SENSOR_PIN, INPUT); // IR Sensor
  
  Serial.begin(115200);
  
  // Set up GPS on Serial1 (GP0 for TX, GP1 for RX)
  Serial1.setRX(1);
  Serial1.setTX(0);
  Serial1.begin(GPS_BAUD);
  
  // Set up MPU6050
  Wire1.setSDA(6);
  Wire1.setSCL(7);
  Wire1.begin();

  Wire1.beginTransmission(MPU_ADDR);
  if (Wire1.endTransmission() == 0) {
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x6B); 
    Wire1.write(0);    // Wake up
    Wire1.endTransmission(true);

    // Set Accelerometer to +/- 16G (for crash detection)
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x1C); 
    Wire1.write(0x18); 
    Wire1.endTransmission(true);
  }
}

unsigned long lastSampleTime = 0;
unsigned long lastPrintTime = 0;

void loop() {
  // 1. Process GPS Data (Background)
  while (Serial1.available() > 0) {
    gps.encode(Serial1.read());
  }

  // 2. High-Speed Physics Polling (200Hz = every 5 milliseconds)
  unsigned long currentTime = millis();
  if (currentTime - lastSampleTime >= 5) {
    lastSampleTime = currentTime;
    
    // Read IR Sensor
    bool headInside = (digitalRead(IR_SENSOR_PIN) == LOW); // Assuming LOW = Obstacle detected
    
    // Read IMU
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x3B); 
    Wire1.endTransmission(false);
    Wire1.requestFrom(MPU_ADDR, 14, true); 
    
    if (Wire1.available() >= 14) {
      // Raw values
      int16_t AcX = Wire1.read() << 8 | Wire1.read(); 
      int16_t AcY = Wire1.read() << 8 | Wire1.read(); 
      int16_t AcZ = Wire1.read() << 8 | Wire1.read(); 
      Wire1.read(); Wire1.read(); // Skip Temp
      int16_t GyX = Wire1.read() << 8 | Wire1.read(); 
      int16_t GyY = Wire1.read() << 8 | Wire1.read(); 
      int16_t GyZ = Wire1.read() << 8 | Wire1.read(); 
      
      // Convert to Gs (16G scale = 2048 LSB/G)
      float ax = AcX / 2048.0;
      float ay = AcY / 2048.0;
      float az = AcZ / 2048.0;
      float gForce = sqrt(ax*ax + ay*ay + az*az);
      
      // Convert to Degrees per Second (250 dps scale = 131 LSB/dps)
      float gx = GyX / 131.0;
      float gy = GyY / 131.0;
      float gz = GyZ / 131.0;
      float rotSpeed = sqrt(gx*gx + gy*gy + gz*gz);

      // --- STATE MACHINE LOGIC ---
      if (currentState == ON_TABLE || currentState == ON_HEAD_NORMAL) {
        if (headInside) {
          currentState = ON_HEAD_NORMAL;
        } else {
          currentState = ON_TABLE;
        }

        // TRIGGER IMPACT PROTOCOL
        if (gForce > G_FORCE_THRESHOLD && currentState == ON_HEAD_NORMAL) {
          currentState = IMPACT_DETECTED;
          impactStartTime = currentTime;
          maxGForce = gForce;
          absorbedEnergy = 0.0;
          isTumbling = false;
          isDragging = false;
        }
      } 
      else if (currentState == IMPACT_DETECTED) {
        // We are currently in a crash. Calculate Physics for exactly 3 seconds.
        if (currentTime - impactStartTime < 3000) {
          // Track Peak Force
          if (gForce > maxGForce) maxGForce = gForce;
          
          // Track Tumbling
          if (rotSpeed > TUMBLE_THRESHOLD) isTumbling = true;
          
          // Track Dragging (Sustained noise > 1.5G after the initial hit)
          if (currentTime - impactStartTime > 500 && gForce > DRAG_THRESHOLD) {
            isDragging = true;
          }
          
          // Integrate Energy (Area under curve)
          // Simplified: Energy += G-Force * time_delta(0.005s)
          absorbedEnergy += (gForce * 0.005);
          
        } else {
          // 3 seconds have passed. Evaluate the crash.
          if (absorbedEnergy > 5.0 || isTumbling || isDragging || maxGForce > PEAK_G_FATAL) {
            currentState = SOS_TRIGGERED;
          } else {
            // It was a short bump, not a sustained crash.
            currentState = ON_HEAD_NORMAL; 
          }
        }
      }
    }
  }

  // 3. Low-Speed Output to Dashboard (10Hz)
  if (currentTime - lastPrintTime >= 100) {
    lastPrintTime = currentTime;
    
    if (currentState == SOS_TRIGGERED) {
      Serial.print("SOS_ALERT | ");
      Serial.print("MaxG: "); Serial.print(maxGForce);
      Serial.print(" | Energy: "); Serial.print(absorbedEnergy);
      Serial.print(" | Tumbling: "); Serial.print(isTumbling);
      Serial.print(" | Dragging: "); Serial.print(isDragging);
      
      if (gps.location.isValid()) {
        Serial.print(" | GPS: ");
        Serial.print(gps.location.lat(), 6); Serial.print(","); Serial.print(gps.location.lng(), 6);
      }
      Serial.println();
      
      delay(5000); // Pause to prevent spamming
      currentState = ON_HEAD_NORMAL; // Reset for testing
      
    } else {
      // Normal telemetry
      Serial.print("State: "); 
      if (currentState == ON_TABLE) Serial.print("TABLE");
      else if (currentState == ON_HEAD_NORMAL) Serial.print("ON_HEAD");
      else if (currentState == IMPACT_DETECTED) Serial.print("ANALYZING_IMPACT");
      Serial.println();
    }
  }
}
