# Smart Helmet Crash Detection: System Design & Architecture Report

---

## 1. Algorithmic Architecture: Multi-Sensor Fusion
To eliminate false positives (e.g., dropping the helmet in a parking lot) and ensure commercial reliability, the system abandons simple "G-force thresholding" in favor of a robust state machine driven by the IMU and an IR proximity sensor.

*   **Primary Trigger: Gyroscopic Tumbling**
    *   **Logic:** High angular velocity (`> 300 dps`) indicates the rider has been thrown from the vehicle. A crash involves violent rotational velocity as the rider tumbles, which immediately differentiates it from a helmet simply falling off a table.
*   **Contextual Trigger: IR Head Detection**
    *   **Logic:** An inexpensive (`< ₹50`) IR Proximity sensor (e.g., TCRT5000) inside the inner foam padding provides binary, definitive proof that a human head is inside the helmet. If the helmet is dropped while empty (`HEAD_OUT`), the SOS protocol is hard-disabled, replacing the need for unreliable stillness tests.

---

## 2. IMU Impact Profiling
*This section details how the accelerometer distinguishes between the shape of different impacts.*

Instead of relying purely on a peak threshold, the algorithm analyzes the continuous shape of the acceleration curve to classify the event:
*   **Accidental Drop (False Positive):** Features a brief period of free-fall (near `0G` on all axes) followed by a single, instantaneous, massive spike on one axis when it hits the ground. It immediately returns to baseline `1G`.
*   **Vehicular Crash (True Positive):** Features continuous, chaotic spikes across all three axes (X, Y, Z) for several seconds as the rider slides, impacts the road multiple times, or tumbles. 
*   **Free-Fall Classification:** By calculating the time spent at `0G` prior to the impact spike, the system can calculate the exact fall height using the kinematic equation $d = 0.5 \cdot g \cdot t^2$.

---

## 3. Helmet Context & Power States
To intelligently manage power and assist the crash detection algorithm, the physical "States" of the helmet are mapped below. 

| State | Description | MPU6050 Signature | IR Sensor | Action / Power Mode |
| :--- | :--- | :--- | :--- | :--- |
| **ON_TABLE** | Placed down, totally unused. | Absolute stillness (`1G` straight down, `0` Gyro). | `HEAD_OUT` | **DEEP SLEEP**. Turn off GSM/WiFi. Wake on IMU interrupt. |
| **IN_HAND** | Carried by user walking. | Rhythmic, low-frequency swaying (1-2 Hz). Low/Medium Gyro. | `HEAD_OUT` | **STANDBY**. Keep systems warm, but don't actively broadcast. |
| **ON_HEAD_STOPPED** | Rider is wearing it, but stopped at a red light. | Micro-movements (breathing, looking around). Smooth Gyro. | `HEAD_IN` | **ACTIVE**. Monitor for rear-end collisions. |
| **ON_HEAD_RIDING** | Normal riding operation. | High-frequency vibrations (engine/road). Stable forward lean. | `HEAD_IN` | **ACTIVE**. Full monitoring and data transmission. |

---

## 4. Advanced Crash Physics & Severity Calculation
The firmware will poll the MPU6050 at **200Hz** (instead of 10Hz) to capture the microsecond physics of an impact. This allows the system to calculate true physical metrics rather than just arbitrary thresholds.

*   **Absorbed Kinetic Energy (Joules):**
    *   By integrating the acceleration spike over time ($v = \int a \cdot dt$), we calculate the exact change in velocity ($\Delta v$) during the impact.
    *   Using $KE = \frac{1}{2} m (\Delta v)^2$, the dashboard can output the exact energy absorbed by the helmet's EPS foam.

---

## 5. International Standards Compliance
The algorithm's thresholds are directly mapped to globally recognized automotive and medical safety standards, providing immense credibility.

| Metric | Measured By | Safe Threshold | Critical Threshold (SOS) | Governing Authority |
| :--- | :--- | :--- | :--- | :--- |
| **Peak Impact** | IMU (Acc) | `< 150 Gs` | `> 275 Gs` | ECE 22.06 (Europe) |
| **Dwell Time** | IMU (Acc + Timer) | `< 2.0 ms` | `> 2.0 ms @ 200 Gs` | DOT FMVSS 218 (USA) |
| **Brain Trauma**| IMU (Integral) | `HIC < 250` | `HIC > 1000` | NHTSA / FIM |

---

## 6. Prototype Bill of Materials (Cost in INR)
This table outlines the retail cost to build a single prototype unit in India. 
*Note: In mass manufacturing (10,000+ units), the cost of these bare IC components drops by roughly 40-60%.*

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

**Note on Telemetry:** The SIM800L 2G module is utilized to keep prototype costs minimal. For mass manufacturing, this will be replaced with an A7670C (4G LTE-M) module to ensure compatibility with modern networks like Jio and to dramatically lower power consumption.
