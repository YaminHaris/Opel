# Helmet Context & Power States

To intelligently manage power (e.g., turning off GPS when the helmet is sitting on a table) and to assist the crash detection algorithm, we can map out the physical "States" of the helmet. 

Currently, we rely on the IMU (MPU6050) and GPS (NEO-6M), but distinguishing some states accurately requires additional cheap sensors.

## State Matrix

| State | Description | MPU6050 Signature | GPS Signature | Action / Power Mode |
| :--- | :--- | :--- | :--- | :--- |
| **ON_TABLE** | Placed down, totally unused. | Absolute stillness (`1G` straight down, `0` Gyro). No vibrations. | Speed = `0`. (Can lose fix indoors). | **DEEP SLEEP**. Turn off GPS and WiFi. Wake on IMU interrupt. |
| **IN_HAND** | Carried by user walking. | Rhythmic, low-frequency swaying (1-2 Hz). Low/Medium Gyro. | Speed = `3-5 km/h` or erratic. | **STANDBY**. Keep GPS warm, but don't actively broadcast data. |
| **ON_HEAD_STOPPED** | Rider is wearing it, but stopped at a red light or talking. | Micro-movements (breathing, looking around). Smooth Gyro. | Speed = `0`. | **ACTIVE**. Monitor for rear-end collisions. |
| **ON_HEAD_RIDING** | Normal riding operation. | High-frequency vibrations (engine/road). Stable forward lean. | Speed > `5 km/h`. | **ACTIVE**. Full monitoring and data transmission. |
| **LEFT_ON_BIKE** | Hung on the handlebars while bike is parked. | Similar to ON_TABLE, but might pick up wind shakes. | Speed = `0`. | **ANTI-THEFT**. Alert if moved. |

---

## The "Head vs. Table" Ambiguity

With just an IMU and a GPS, there is a blind spot: **How do you definitively know a human head is inside the helmet?** 

If a user leaves the helmet on the seat of an idling motorcycle, the IMU will feel the engine vibrations, and the GPS might read 0. The helmet might assume "ON_HEAD_STOPPED". If it falls off the seat, it might trigger a false crash because it thought someone was wearing it.

### Recommended Hardware Additions
To build a truly commercial-grade system, consider adding one of these very cheap (<$1) sensors inside the helmet foam padding:

1. **IR Proximity Sensor (TCRT5000)**
   - *How it works:* Shines an invisible IR light. If a forehead/hair is within 2cm, it reflects back. 
   - *Why it's great:* Foolproof binary indicator (`HEAD_IN` vs `HEAD_OUT`). If `HEAD_OUT`, you immediately disable crash alerts and go to sleep.
2. **Capacitive Touch Pad**
   - *How it works:* A small strip of conductive tape inside the padding senses the electrical capacitance of human skin.
   - *Why it's great:* Cannot be fooled by objects (e.g. if the helmet is stuffed into a backpack with clothes).
3. **Temperature Sensor (Thermistor)**
   - *How it works:* Reads the inside ambient temperature.
   - *Why it's great:* Human heads run at 37°C. If the inside of the helmet is 35°C, someone is wearing it.

## Next Steps for Implementation
1. **Wake-on-Motion:** Configure the MPU6050's internal hardware interrupt pin (INT). This allows the Pico 2 to completely go to sleep and only wake up when the helmet is picked up, saving massive amounts of battery.
2. **Implement the State Machine:** Add a loop to `app.py` or the Pico that samples the average variance of the IMU over a 5-second sliding window to determine if it's `ON_TABLE` or `IN_HAND`.
