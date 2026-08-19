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
