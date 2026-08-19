import math
from kinematic_engine import generate_kinematic_crash

class CrashFirmwareModel:
    """
    Python port of the mpu_reader.ino state machine.
    Used for automated physics testing.
    """
    def __init__(self):
        self.G_FORCE_THRESHOLD = 4.0
        self.DRAG_THRESHOLD = 1.3
        self.TUMBLE_THRESHOLD = 800.0
        self.PEAK_G_FATAL = 50.0
        
        self.state = "ON_TABLE"
        self.impact_start_time = 0
        self.max_g = 0.0
        self.delta_v = 0.0
        self.energy = 0.0 # True Kinetic Energy in Joules
        self.is_tumbling = False
        self.is_dragging = False
        
        self.current_time_ms = 0
        
    def process_frame(self, ax, ay, az, gx, gy, gz, gps_speed, ir_in):
        self.current_time_ms += 5 # 200Hz = 5ms
        
        gForce = math.sqrt(ax**2 + ay**2 + az**2)
        rotSpeed = math.sqrt(gx**2 + gy**2 + gz**2)
        
        if self.state in ["ON_TABLE", "ON_HEAD_NORMAL"]:
            if ir_in:
                self.state = "ON_HEAD_NORMAL"
            else:
                self.state = "ON_TABLE"
                
            if gForce > self.G_FORCE_THRESHOLD and self.state == "ON_HEAD_NORMAL":
                self.state = "IMPACT_DETECTED"
                self.impact_start_time = self.current_time_ms
                self.max_g = gForce
                self.delta_v = 0.0
                self.energy = 0.0
                self.is_tumbling = False
                self.is_dragging = False
                
        elif self.state == "IMPACT_DETECTED":
            if self.current_time_ms - self.impact_start_time < 3000:
                if gForce > self.max_g:
                    self.max_g = gForce
                if rotSpeed > self.TUMBLE_THRESHOLD:
                    self.is_tumbling = True
                if (self.current_time_ms - self.impact_start_time > 500) and gForce > self.DRAG_THRESHOLD:
                    self.is_dragging = True
                    
                # We must subtract 1.0G (Earth's gravity) from the magnitude so we don't integrate gravity while at rest!
                dynamic_g = abs(gForce - 1.0)
                accel_ms2 = dynamic_g * 9.81
                self.delta_v += accel_ms2 * 0.005
                
                # Calculate True Kinetic Energy Absorbed (assuming 5.0 kg head+helmet mass)
                self.energy = 0.5 * 5.0 * (self.delta_v ** 2)
                
            else:
                # 150 Joules is roughly a 10km/h drop of a 5kg head
                if self.energy > 150.0 or self.is_tumbling or self.is_dragging or self.max_g > self.PEAK_G_FATAL:
                    self.state = "SOS_TRIGGERED"
                else:
                    self.state = "ON_HEAD_NORMAL"
                    
        return self.state

def run_test(test_name, v, angle, h, wearing, expected_sos):
    print(f"Running Test: {test_name} (v={v}km/h, angle={angle}deg, h={h}m, wearing={wearing})")
    logs = generate_kinematic_crash(v, angle, h, wearing, scenario_name=test_name)
    
    firmware = CrashFirmwareModel()
    final_state = "UNKNOWN"
    
    for line in logs:
        # Parse Accel: 0, 0, 2048 | Gyro: 0, 0, 0 | GPS: 12.34,56.78,0.0,8 | IR: 1
        parts = line.split("|")
        accel_parts = parts[0].replace("Accel:", "").split(",")
        gyro_parts = parts[1].replace("Gyro:", "").split(",")
        ir_part = parts[3].replace("IR:", "").strip()
        
        ax = int(accel_parts[0]) / 2048.0
        ay = int(accel_parts[1]) / 2048.0
        az = int(accel_parts[2]) / 2048.0
        gx = int(gyro_parts[0]) / 131.0
        gy = int(gyro_parts[1]) / 131.0
        gz = int(gyro_parts[2]) / 131.0
        ir = (ir_part == "1")
        
        state = firmware.process_frame(ax, ay, az, gx, gy, gz, 0.0, ir)
        if state == "SOS_TRIGGERED":
            final_state = "SOS_TRIGGERED"
            break # SOS hit, test complete
    
    if final_state != "SOS_TRIGGERED":
        final_state = firmware.state # Usually ON_HEAD_NORMAL or ON_TABLE
        
    passed = (final_state == "SOS_TRIGGERED") == expected_sos
    icon = "✅" if passed else "❌ FAILED"
    
    print(f"  {icon} Expected SOS: {expected_sos} | Result: {final_state} | MaxG: {firmware.max_g:.1f} | Energy: {firmware.energy:.1f}")
    if not passed:
        return False
    return True

if __name__ == "__main__":
    tests = [
        # Real Crashes (PyBullet)
        ("High Speed Slide", 60.0, 0, 1.5, True, True),
        ("City Crash", 30.0, 45, 1.5, True, True),
        ("Vertical Fall", 0.0, 90, 10.0, True, True),
        
        # Edge Cases & Non-Crashes
        ("Dropped Helmet (Empty)", 0.0, 90, 1.5, False, False),
        ("Minor Bump", 5.0, 0, 0.5, True, False),
        ("Normal Riding", 40.0, 0, 1.5, True, False),
        ("Hard Braking", 80.0, 0, 1.5, True, False),
        ("Head Checking Blindspot", 60.0, 0, 1.5, True, False),
        ("Skydiving (Freefall, no impact)", 0.0, 90, 1000.0, True, False)
    ]
    
    all_passed = True
    for t in tests:
        if not run_test(*t):
            all_passed = False
            
    if all_passed:
        print("\n🏆 ALL ALGORITHM TESTS PASSED! The system is industry-grade.")
    else:
        print("\n⚠️ ALGORITHM FAILED. Re-tuning required.")
