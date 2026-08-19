#include <Wire.h>

const int MPU_ADDR = 0x68; // Standard I2C address for MPU6050

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
  
  // Wait for serial connection
  while (!Serial) {
    digitalWrite(LED_BUILTIN, HIGH);
    delay(100);
    digitalWrite(LED_BUILTIN, LOW);
    delay(100);
  }
  
  Serial.println("Starting MPU6050 program on Pico 2...");
  
  // GPIO 6 (SDA) and GPIO 7 (SCL) belong to I2C1, so we use Wire1
  Wire1.setSDA(6);
  Wire1.setSCL(7);
  Wire1.begin();

  // Try to find the MPU
  Serial.println("Attempting to talk to MPU6050...");
  Wire1.beginTransmission(MPU_ADDR);
  uint8_t error = Wire1.endTransmission();
  
  if (error == 0) {
    Serial.println("MPU6050 found! Waking it up...");
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x6B); // PWR_MGMT_1 register
    Wire1.write(0);    // set to zero (wakes up the MPU-6050)
    Wire1.endTransmission(true);

    // Set Accelerometer to +/- 16G (for crash detection)
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x1C); // ACCEL_CONFIG register
    Wire1.write(0x18); // Set to 16G (0x18)
    Wire1.endTransmission(true);
  } else {
    Serial.print("Error communicating with MPU6050. I2C error code: ");
    Serial.println(error);
  }
}

void loop() {
  // Toggle LED so we know it's running
  digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));
  
  Wire1.beginTransmission(MPU_ADDR);
  Wire1.write(0x3B); // Start with register 0x3B (ACCEL_XOUT_H)
  Wire1.endTransmission(false);
  
  // Request 14 bytes (Accelerometer, Temperature, and Gyroscope)
  Wire1.requestFrom(MPU_ADDR, 14, true); 
  
  if (Wire1.available() >= 14) {
    int16_t AcX = Wire1.read() << 8 | Wire1.read(); 
    int16_t AcY = Wire1.read() << 8 | Wire1.read(); 
    int16_t AcZ = Wire1.read() << 8 | Wire1.read(); 
    int16_t Tmp = Wire1.read() << 8 | Wire1.read(); // Temperature
    int16_t GyX = Wire1.read() << 8 | Wire1.read(); 
    int16_t GyY = Wire1.read() << 8 | Wire1.read(); 
    int16_t GyZ = Wire1.read() << 8 | Wire1.read(); 
    
    // Print the output over serial
    Serial.print("Accel: "); Serial.print(AcX);
    Serial.print(", "); Serial.print(AcY);
    Serial.print(", "); Serial.print(AcZ);
    Serial.print(" | Gyro: "); Serial.print(GyX);
    Serial.print(", "); Serial.print(GyY);
    Serial.print(", "); Serial.print(GyZ);
    Serial.print(" | Temp: "); Serial.println(Tmp);
  }
  
  delay(100);
}
