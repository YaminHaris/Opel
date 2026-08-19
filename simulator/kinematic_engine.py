import math
import random
import argparse

def generate_kinematic_crash(velocity_kmh, angle_deg, height_m, is_wearing, noise_level=0.1):
    """
    Generates a mathematically accurate 200Hz sensor log using projectile kinematics.
    velocity_kmh: Initial speed
    angle_deg: Launch angle (0 = horizontal slide, 90 = vertical drop)
    height_m: Starting height
    is_wearing: True if on head (adds biological damping and IR sensor = True)
    """
    sample_rate = 200
    dt = 1.0 / sample_rate
    
    v0 = velocity_kmh / 3.6 # convert to m/s
    angle_rad = math.radians(angle_deg)
    
    vx = v0 * math.cos(angle_rad)
    vz = v0 * math.sin(angle_rad)
    z = height_m
    x = 0.0
    
    g = 9.81
    
    # Physics parameters
    impact_duration = 0.015 # 15ms impact (standard hard surface)
    if is_wearing:
        impact_duration = 0.025 # Head padding softens impact slightly
        
    friction_mu = 0.6 # Asphalt friction
    
    log_lines = []
    
    state = "FLIGHT" if height_m > 0 else "SLIDING"
    time = 0.0
    
    # State tracking for generation
    impact_timer = 0.0
    impact_vz_start = 0.0
    
    gx, gy, gz = 0.0, 0.0, 0.0
    
    while time < 5.0:
        ax, ay, az = 0.0, 0.0, 0.0
        
        if state == "FLIGHT":
            # Freefall
            az = 0.0 # Accelerometer reads 0G in freefall
            ax, ay = 0.0, 0.0
            
            vz -= g * dt
            z += vz * dt
            x += vx * dt
            
            if z <= 0:
                z = 0
                state = "IMPACT"
                impact_timer = 0.0
                impact_vz_start = vz
                
        elif state == "IMPACT":
            # Violent deceleration on Z axis
            delta_v = abs(impact_vz_start)
            avg_a = delta_v / impact_duration
            az_g = (avg_a / g) + 1.0 # Add 1G for earth
            
            # Scatter force across axes based on tumbling
            ax = random.uniform(-az_g*0.2, az_g*0.2)
            ay = random.uniform(-az_g*0.2, az_g*0.2)
            az = az_g
            
            impact_timer += dt
            if impact_timer >= impact_duration:
                vz = 0
                state = "SLIDING"
                
        elif state == "SLIDING":
            az = 1.0 # Resting on ground
            
            if vx > 0:
                # Friction deceleration
                decel = friction_mu * g
                vx -= decel * dt
                if vx < 0:
                    vx = 0
                
                # Chaotic sliding noise
                ax = (-decel / g) + random.uniform(-1.0, 1.0)
                ay = random.uniform(-2.0, 2.0)
                az += random.uniform(-1.0, 2.0)
                
                # Tumbling rotation (proportional to speed)
                gx = random.uniform(-vx*50, vx*50)
                gy = random.uniform(-vx*50, vx*50)
                gz = random.uniform(-vx*10, vx*10)
            else:
                state = "REST"
                
        elif state == "REST":
            ax, ay, az = 0.0, 0.0, 1.0
            gx, gy, gz = 0.0, 0.0, 0.0
            
        # Add sensor noise
        ax += random.uniform(-noise_level, noise_level)
        ay += random.uniform(-noise_level, noise_level)
        az += random.uniform(-noise_level, noise_level)
        
        # Format output
        raw_ax = int(ax * 2048)
        raw_ay = int(ay * 2048)
        raw_az = int(az * 2048)
        raw_gx = int(gx * 131)
        raw_gy = int(gy * 131)
        raw_gz = int(gz * 131)
        
        # GPS Speed is roughly vx * 3.6 (ignoring y axis)
        gps_speed = vx * 3.6
        
        ir_val = 1 if is_wearing else 0
        
        line = f"Accel: {raw_ax}, {raw_ay}, {raw_az} | Gyro: {raw_gx}, {raw_gy}, {raw_gz} | GPS: 12.34,56.78,{gps_speed:.1f},8 | IR: {ir_val}\n"
        log_lines.append(line)
        
        time += dt

    # Return the lines
    return log_lines

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Kinematic Crash Simulator")
    parser.add_argument("--v", type=float, default=50.0, help="Initial Velocity (km/h)")
    parser.add_argument("--angle", type=float, default=0.0, help="Launch Angle (degrees. 0=Slide, 90=Drop)")
    parser.add_argument("--h", type=float, default=1.5, help="Starting height (meters)")
    parser.add_argument("--wearing", type=bool, default=True, help="Is the helmet on a head?")
    parser.add_argument("--out", type=str, default="custom_crash.log", help="Output file")
    
    args = parser.parse_args()
    
    lines = generate_kinematic_crash(args.v, args.angle, args.h, args.wearing)
    with open(args.out, "w") as f:
        f.writelines(lines)
    print(f"Generated physical simulation: {args.out} ({len(lines)} frames @ 200Hz)")
