import time
import math

class CrashDetector:
    def __init__(self):
        # Configuration Thresholds
        self.ACCEL_IMPACT_THRESHOLD = 8.0  # Gs (Depends on MPU scale, e.g., 16G max)
        self.GYRO_TUMBLE_THRESHOLD = 300.0 # Degrees per second
        self.GPS_SPEED_THRESHOLD = 10.0    # km/h
        
        self.POST_CRASH_WAIT_TIME = 10.0   # seconds to wait to check for stillness
        self.STILLNESS_THRESHOLD = 0.5     # Gs of variance considered "still"

        # State Variables
        self.state = "NORMAL" # States: NORMAL, IMPACT_DETECTED, EVALUATING, TRIGGER_SOS
        self.impact_time = 0.0
        self.crash_score = 0
        
        # History buffers (to remember pre-crash data)
        self.last_known_speed = 0.0
        self.recent_accel = []
        
    def calculate_magnitude(self, x, y, z):
        return math.sqrt(x**2 + y**2 + z**2)

    def process_telemetry(self, ax_g, ay_g, az_g, gx, gy, gz, gps_speed):
        """
        Feed this function continuously with data from the sensors.
        ax_g, ay_g, az_g should be converted to G-forces.
        gx, gy, gz should be in degrees/sec.
        gps_speed in km/h.
        """
        current_time = time.time()
        
        # Keep track of speed when not crashing
        if self.state == "NORMAL":
            self.last_known_speed = gps_speed
            
        accel_mag = self.calculate_magnitude(ax_g, ay_g, az_g)
        gyro_mag = self.calculate_magnitude(gx, gy, gz)

        # STATE MACHINE
        if self.state == "NORMAL":
            if accel_mag > self.ACCEL_IMPACT_THRESHOLD:
                print(f"[!] MASSIVE IMPACT DETECTED! ({accel_mag:.2f} Gs)")
                self.state = "IMPACT_DETECTED"
                self.impact_time = current_time
                self.crash_score = 50 # Base points for hitting the threshold
                self.recent_accel.clear()

        elif self.state == "IMPACT_DETECTED":
            # 1. Check GPS Context
            if self.last_known_speed > self.GPS_SPEED_THRESHOLD:
                print(f"[!] High Speed Impact confirmed! (Speed: {self.last_known_speed} km/h)")
                self.crash_score += 50
                
            # 2. Check Gyroscope Context (Tumbling)
            if gyro_mag > self.GYRO_TUMBLE_THRESHOLD:
                print(f"[!] Violent Tumbling detected! (Gyro: {gyro_mag:.2f} dps)")
                self.crash_score += 50
                
            if self.crash_score >= 100:
                self.state = "TRIGGER_SOS"
            else:
                self.state = "EVALUATING_STILLNESS"
                
        elif self.state == "EVALUATING_STILLNESS":
            # Collect accel data to check if rider is moving after crash
            self.recent_accel.append(accel_mag)
            
            # Wait for the post-crash time window to expire
            if current_time - self.impact_time >= self.POST_CRASH_WAIT_TIME:
                # Calculate variance to see if they are completely still
                avg_accel = sum(self.recent_accel) / len(self.recent_accel)
                variance = sum((x - avg_accel) ** 2 for x in self.recent_accel) / len(self.recent_accel)
                
                if variance < self.STILLNESS_THRESHOLD:
                    print("[!] Rider is completely motionless. Triggering SOS!")
                    self.state = "TRIGGER_SOS"
                else:
                    print("[-] Rider is moving. Likely dropped helmet. False alarm.")
                    self.state = "NORMAL" # Reset
                    
        elif self.state == "TRIGGER_SOS":
            print("🚨 SOS TRIGGERED! SENDING TELEGRAM/SMS 🚨")
            # In real life, trigger an API call here, then prevent re-triggering immediately
            time.sleep(5) 
            self.state = "NORMAL" # Reset for testing purposes

        return self.state

# Example usage (Mock Test)
if __name__ == "__main__":
    detector = CrashDetector()
    
    print("Simulating dropping helmet off a table...")
    detector.process_telemetry(1.0, 1.0, 1.0, 0, 0, 0, 0) # Normal
    detector.process_telemetry(9.0, 2.0, 1.0, 50, 20, 10, 0) # Spike, but low gyro, 0 speed
    time.sleep(1)
    # moving around picking it up
    for _ in range(11):
        detector.process_telemetry(1.5, 1.2, 1.0, 10, 10, 10, 0) 
        time.sleep(1)
    
    print("\nSimulating red light crash...")
    detector.process_telemetry(1.0, 1.0, 1.0, 0, 0, 0, 0) # Normal
    detector.process_telemetry(12.0, 5.0, 5.0, 400, 200, 100, 0) # Spike + Tumbling, 0 speed
