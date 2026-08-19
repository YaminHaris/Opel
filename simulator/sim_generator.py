import math
import random
import time

def generate_crash_log(crash_type, duration_sec=5.0, sample_rate_hz=200):
    """
    Generates synthetic 200Hz IMU data for testing the crash dashboard.
    """
    samples = int(duration_sec * sample_rate_hz)
    log_file = f"sim_{crash_type}.log"
    
    with open(log_file, "w") as f:
        for i in range(samples):
            t = i / sample_rate_hz
            
            # Base stillness
            ax, ay, az = 0.0, 0.0, 1.0 # 1G down
            gx, gy, gz = 0.0, 0.0, 0.0
            
            if crash_type == "vertical_drop":
                # Freefall from 1.0s to 1.5s
                if 1.0 <= t < 1.5:
                    ax, ay, az = 0.0, 0.0, 0.0
                # Instant spike at 1.5s
                elif 1.5 <= t < 1.52:
                    ax, ay, az = 0.0, 0.0, 25.0 # 25G hit
                    
            elif crash_type == "scooter_drag":
                # Hit ground at 1.0s
                if 1.0 <= t < 1.05:
                    ax, ay, az = 15.0, 5.0, 5.0
                # Drag across asphalt from 1.05s to 4.0s
                elif 1.05 <= t < 4.0:
                    ax = random.uniform(-4.0, 4.0)
                    ay = random.uniform(-4.0, 4.0)
                    az = random.uniform(0.0, 5.0)
                    # Tumbling initially, then stops rotating but still dragging
                    if t < 2.0:
                        gx = random.uniform(-400, 400)
                    else:
                        gx = 0.0
            
            # Write to mock serial format
            # Format expected by dashboard: Accel: X, Y, Z | Gyro: X, Y, Z | GPS: ...
            # Converting Gs back to raw LSB (approximate) for the mock
            raw_ax = int(ax * 2048)
            raw_ay = int(ay * 2048)
            raw_az = int(az * 2048)
            raw_gx = int(gx * 131)
            raw_gy = int(gy * 131)
            raw_gz = int(gz * 131)
            
            line = f"Accel: {raw_ax}, {raw_ay}, {raw_az} | Gyro: {raw_gx}, {raw_gy}, {raw_gz} | GPS: 12.34,56.78,25.0,8\n"
            f.write(line)
            
        # At the end of the crash, the firmware outputs an SOS summary
        if crash_type == "vertical_drop":
            f.write("SOS_ALERT | MaxG: 25.0 | Energy: 12.5 | Tumbling: 0 | Dragging: 0 | GPS: 12.34,56.78\n")
        elif crash_type == "scooter_drag":
            f.write("SOS_ALERT | MaxG: 15.0 | Energy: 45.2 | Tumbling: 1 | Dragging: 1 | GPS: 12.34,56.78\n")

    print(f"✅ Generated synthetic crash log: {log_file}")

if __name__ == "__main__":
    generate_crash_log("vertical_drop")
    generate_crash_log("scooter_drag")
    print("Done! You can pipe these into your dashboard to test the logic.")
