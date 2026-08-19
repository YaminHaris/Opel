# SIH-Helmet Project

This repository contains the software, firmware, and tools developed so far for the SIH-Helmet telemetry system. The project uses a Raspberry Pi Pico 2, an MPU6050 (Accelerometer + Gyroscope), and a NEO-6M GPS module to transmit real-time telemetry data to a local Python Flask dashboard.

## What has been done so far
1. **GPS Passthrough Testing**: Created `gps_test` to verify the NEO-6M GPS wiring and check NMEA sentences.
2. **MPU6050 & GPS Integration**: Created `mpu_reader` firmware that reads data from the MPU6050 via I2C and from the NEO-6M via UART, formatting the output over USB Serial at a high refresh rate.
3. **Data Logging**: Wrote `log_serial.py` to record the serial output from the helmet into a text file with timestamps.
4. **Real-time Web GUI**: Developed a Flask and SocketIO-based application (`gui/app.py`) that reads the telemetry data from the serial port, parses it with Regex, and emits it to a web frontend for live visualization.

---

## Pin Connections & Architecture Diagram

### Pinout Table (Raspberry Pi Pico 2 to Sensors)

| Pico 2 Pin (GPIO) | Sensor Pin | Sensor Type | Function |
| :--- | :--- | :--- | :--- |
| **GP6** (Pin 9) | **SDA** | MPU6050 | I2C Data line (Wire1) |
| **GP7** (Pin 10) | **SCL** | MPU6050 | I2C Clock line (Wire1) |
| **3V3(OUT)** (Pin 36)| **VCC** | MPU6050 | Power (3.3V) |
| **GND** (Pin 38) | **GND** | MPU6050 | Ground |
| **GP0** (Pin 1) | **RX** | NEO-6M GPS | Pico TX -> GPS RX |
| **GP1** (Pin 2) | **TX** | NEO-6M GPS | Pico RX <- GPS TX |
| **3V3(OUT)** (Pin 36)| **VCC** | NEO-6M GPS | Power (3.3V) |
| **GND** (Pin 23) | **GND** | NEO-6M GPS | Ground |

### Wiring Diagram (ASCII)

```text
                                Raspberry Pi Pico 2
                               +-------------------+
                          TX0  | GP0 (Pin 1)       | 
                          RX0  | GP1 (Pin 2)       |
                               | ...               | 
                          SDA1 | GP6 (Pin 9)       |------[ SDA ] MPU6050
                          SCL1 | GP7 (Pin 10)      |------[ SCL ] MPU6050
                               | ...               |
                               |                   |
                               | 3V3(OUT) (Pin 36) |--+---[ VCC ] MPU6050
                               |                   |  |
                               | GND (Pin 38)      |--|---[ GND ] MPU6050
                               +-------------------+  |
                                                      |
                          GP0 (TX) ------> [ RX ] NEO-6M GPS
                          GP1 (RX) <------ [ TX ] NEO-6M GPS
                          3V3(OUT) ------> [ VCC ] NEO-6M GPS
                          GND -----------> [ GND ] NEO-6M GPS
```

---

## System Configuration & Baud Rates
- **USB Serial (PC Communication)**: `115200` baud. Used by the Pico to send parsed text strings to the PC.
- **GPS UART (Serial1)**: `9600` baud. The default operating frequency of the NEO-6M module.
- **MPU6050 I2C**: Operating on Pico's `Wire1` hardware I2C bus at the default 100kHz standard mode, device address `0x68`.

---

## Sensor Test Code Snippets

### 1. GPS Passthrough Test Code (`gps_test/gps_test.ino`)
This script acts as a bridge between the Pico's USB Serial (115200 baud) and the Hardware Serial1 (9600 baud). It allows you to see the raw NMEA sentences sent by the GPS module.

```cpp
void setup() {
  Serial.begin(115200);
  
  // Wait for the Serial monitor to open
  while (!Serial) { delay(10); }
  
  Serial.println("\n--- GPS Passthrough Test ---");
  Serial.println("Testing baud rate: 9600");
  
  // Set up Serial1 for the GPS (GP0 = TX, GP1 = RX)
  Serial1.setRX(1);
  Serial1.setTX(0);
  Serial1.begin(9600); 
}

void loop() {
  // Read from GPS and print to Computer
  if (Serial1.available()) {
    Serial.write(Serial1.read());
  }
  
  // Read from Computer and send to GPS (useful for config)
  if (Serial.available()) {
    Serial1.write(Serial.read());
  }
}
```

### 2. MPU6050 & GPS Integrated Telemetry (`mpu_reader/mpu_reader.ino`)
This script reads the raw I2C registers of the MPU6050, continuously polls the GPS for incoming data using `TinyGPSPlus`, and outputs a formatted string over USB every 100ms (10Hz).

```cpp
#include <Wire.h>
#include <TinyGPSPlus.h>

const int MPU_ADDR = 0x68; 
TinyGPSPlus gps;
const uint32_t GPS_BAUD = 9600;

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
  
  // Set up GPS on Serial1
  Serial1.setRX(1);
  Serial1.setTX(0);
  Serial1.begin(GPS_BAUD);
  
  // Set up MPU6050 on I2C Wire1 (GP6=SDA, GP7=SCL)
  Wire1.setSDA(6);
  Wire1.setSCL(7);
  Wire1.begin();

  // Wake up MPU6050
  Wire1.beginTransmission(MPU_ADDR);
  Wire1.write(0x6B); 
  Wire1.write(0);    
  Wire1.endTransmission(true);
}

unsigned long lastPrintTime = 0;

void loop() {
  // 1. Process GPS data
  while (Serial1.available() > 0) {
    gps.encode(Serial1.read());
  }

  // 2. Output data at 10Hz
  if (millis() - lastPrintTime >= 100) {
    lastPrintTime = millis();
    
    // Read 14 bytes from MPU (Accel, Temp, Gyro)
    Wire1.beginTransmission(MPU_ADDR);
    Wire1.write(0x3B); 
    Wire1.endTransmission(false);
    Wire1.requestFrom(MPU_ADDR, 14, true); 
    
    if (Wire1.available() >= 14) {
      int16_t AcX = Wire1.read() << 8 | Wire1.read(); 
      int16_t AcY = Wire1.read() << 8 | Wire1.read(); 
      // ... (reads remaining registers)
      
      Serial.print("Accel: "); Serial.print(AcX);
      Serial.print(", "); Serial.print(AcY);
      // Append GPS Data
      Serial.print(" | GPS: ");
      if (gps.location.isValid()) {
        Serial.print(gps.location.lat(), 6);
        Serial.print(",");
        Serial.print(gps.location.lng(), 6);
      }
      Serial.println();
    }
  }
}
```

---

## Explanation of the GUI Application

The real-time dashboard is built using Python, Flask, and Flask-SocketIO. It consists of a backend server (`gui/app.py`) and a frontend HTML file (`gui/templates/index.html`).

### How it Works:
1. **Background Serial Reading Thread**: 
   When the Flask application starts, it launches an asynchronous background thread using `eventlet`. This thread attempts to connect to the Pico 2 via `/dev/ttyACM0` at `115200` baud.
2. **Regex Data Parsing**:
   The thread continuously reads incoming lines of text from the serial port. It uses Regular Expressions (Regex) to extract the specific telemetry values:
   - Accelerometer (`ax`, `ay`, `az`)
   - Gyroscope (`gx`, `gy`, `gz`)
   - Temperature (optional)
   - GPS (`lat`, `lon`, `speed`, `sats`)
3. **WebSockets (Socket.IO) Emission**:
   Once parsed, the values are packaged into a JSON dictionary and instantly broadcasted to the frontend using the `socketio.emit('sensor_data', data)` channel. This bypasses the need for the web browser to constantly refresh or poll the server.
4. **Resiliency**:
   The script includes try-catch blocks to handle scenarios where the USB serial cable is temporarily disconnected. It waits and automatically re-attempts connection if it gets dropped.
5. **Frontend Rendering**:
   When a user visits `http://127.0.0.1:5000/`, the Flask app serves `index.html`. The client-side JavaScript listens to the WebSocket event and updates the DOM elements on the screen in real-time, completing the loop.