# SIH-Helmet Project

This repository contains the software, firmware, and tools developed so far for the SIH-Helmet telemetry system. The project uses a Raspberry Pi Pico 2, an MPU6050 (Accelerometer + Gyroscope), and a NEO-6M GPS module to transmit real-time telemetry data to a local Python Flask dashboard.

## Hardware

1. **Raspberry Pi Pico 2**: Main Micrcontroller
2. **MPU650**: IMU 6DOF, Termometer
3. **NEO-6M GPS**: GPS


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
# Prototype Bill of Materials (Cost in INR)

This table outlines the retail cost to build a single prototype unit in India. 

*Note: In mass manufacturing (10,000+ units), the cost of these bare IC components drops by roughly 40-60%, making the commercial viability of this product incredibly strong.*

| Component | Function | Estimated Retail Cost (INR) |
| :--- | :--- | :--- |
| **Raspberry Pi Pico 2** | Microcontroller / Brain | ₹ 500 - 600 |
| **NEO-6M GPS Module** | Velocity & Location Tracking | ₹ 350 - 450 |
| **SIM800L GSM Module** | Cellular Communication (SOS) | ₹ 350 - 450 |
| **MPU6050 IMU** | Crash / Tumbling Detection | ₹ 150 - 200 |
| **18650 Li-ion Battery (2000mAh)** | Power Supply | ₹ 150 - 250 |
| **IR Proximity Sensor (TCRT5000)** | Head Detection | ₹ 30 - 50 |
| **TP4056 Module** | Battery Charging Circuit | ₹ 30 - 50 |
| **Misc (Wires, Custom PCB, Case)** | Assembly | ₹ 100 - 200 |
| **TOTAL PROTOTYPE COST** | | **₹ 1,660 - ₹ 2,250** |

---

### Important Note on the SIM800L (The "Final Nail")
You mentioned you aren't sure if the SIM800L is the final choice. You have excellent instincts. 

**For the Hackathon:** The SIM800L is perfect. It is cheap, easy to wire, and sends SMS messages reliably over 2G networks (Airtel/Bsnl/Vi). The judges will respect it as a valid prototype proof-of-concept.

**For the Final Commercial Product:** The SIM800L is a **2G-only** module. 2G networks are being phased out globally, and Jio (India's largest network) is entirely 4G/5G and does not support 2G at all. 
*   **The Upgrade Path:** If judges ask about commercialization, tell them: *"For this prototype, we used a ₹400 SIM800L 2G module to keep development costs low. In our final production roadmap, we will replace this with an **A7670C (4G LTE)** or an **NB-IoT module** which costs roughly ₹1,200. This guarantees it works on modern networks like Jio and dramatically lowers power consumption."* 

Having this answer ready will prove to the judges that you understand both hardware limitations and the telecommunications market in India.

---

## Companion App (Flutter, `companion_app/`)

A mobile app the rider uses to manage the helmet's safety features
from their phone: setting emergency contacts, seeing the helmet's
last known location on a live map, finding and calling the nearest
hospital, and testing the whole crash-alert flow without needing a
real crash (or even the physical helmet) to try it.

### What it does

- **Emergency contacts**: one required contact plus up to 5 optional
  ones, each with call/text buttons and phone-number validation.
- **Live map**: shows the helmet's last known GPS fix and the nearest
  hospital found for it, using Google Maps. Updates in real time as
  new location data comes in from Firebase.
- **Nearest hospital lookup**: automatically finds nearby hospitals
  (via the Google Geocoding/Places-style lookup), shows distance, and
  lets the rider call or get directions. A hospital only becomes the
  active "ambulance contact" if the rider explicitly selects it, or
  if a crash/SOS is triggered — it's never silently auto-filled just
  because one was found nearby.
- **SOS test flow**: simulates a crash end-to-end — writes a test
  alert, starts a 5-second cancellable countdown, then (if not
  cancelled) places a real call to the ambulance number and texts the
  emergency contact the current location. Scoped deliberately so this
  can only fire from an explicit "Simulate SOS" action, never from
  routine location updates or the address-testing tool below.
- **Debug tools**: a GPS simulator (uses the phone's own location) and
  an address-lookup tester (type any address to simulate the helmet
  being there) — both let the whole pipeline be tested without a
  physical helmet or travelling anywhere.

### How it connects to the ESP32 firmware

Two independent sync paths, both ending at the same place in the
firmware:

1. **Firebase (cloud)** — the app writes contacts to a Firebase
   Realtime Database path (`helmet_01/contacts`); firmware with
   Firebase connectivity would read from the same path. This is the
   path used for the live map too — the firmware is expected to write
   its GPS fix to `helmet_01/status/lat` / `lon`, which the app
   listens to and reacts to automatically. No firmware currently
   writes this — it's built against this shape so the GPS-reporting
   side has a concrete target once someone wires it up.

2. **Bluetooth (BLE), direct phone-to-helmet** — no internet needed.
   The app scans for a device advertising as `HELMET_01`, connects to
   a GATT service, and writes the emergency contact number directly.
   **This path is real and working** — see
   `companion_app/firmware/iotsmarthelmetfinal.ino` below.

Both paths write to the exact same place in the firmware: the
`emergencyContact` variable, via the existing `setEmergencyContact()`
function — the same one the SMS-sending code already reads from when
a crash fires. The app doesn't bypass or duplicate any of that logic;
it just gives the rider a way to update the value that function holds.

### ESP32 firmware (`companion_app/firmware/`)

`iotsmarthelmetfinal.ino` — crash detection (MPU6050 impact + rotation
confirmation, confidence scoring), GPS, SIM800L SMS alerts, and a BLE
service that accepts emergency contact updates from the companion app.

The BLE addition is intentionally minimal and additive on top of the
existing crash-detection logic — nothing in the original file was
modified, only a few `#include` lines, one `initBLE()` call added to
`setup()`, and the BLE service code itself appended at the end. See
the comment block at the end of that file for the exact UUIDs and
what each characteristic does.

This is a separate ESP32-targeted sketch, independent of the Pico 2
telemetry pipeline (`mpu_reader/`, `gui/`) described above — the two
haven't been unified yet.

### Setup

The app needs its own Firebase project and Google Maps/Geocoding API
keys to run — none are committed to this repo (placeholders only, for
security). Full setup steps are in `companion_app/README.md`.
