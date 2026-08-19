import pybullet as p
import numpy as np
import math
import random

def generate_kinematic_crash(velocity_kmh, angle_deg, height_m, is_wearing, noise_level=0.1, scenario_name=""):
    """
    Uses PyBullet (a real C++ headless physics engine) to simulate the crash dynamically.
    Also handles special procedural non-crash scenarios for thorough algorithm testing.
    """
    log_lines = []
    dt = 1.0 / 200.0
    ir_val = 1 if is_wearing else 0

    # --- PROCEDURAL NON-CRASH SCENARIOS ---
    if scenario_name == "Normal Riding":
        # Constant speed, engine vibrations, 1G gravity
        for i in range(int(5.0 / dt)):
            ax = random.uniform(-0.5, 0.5)
            ay = random.uniform(-0.5, 0.5)
            az = 1.0 + random.uniform(-0.5, 0.5)
            gx = random.uniform(-10, 10)
            gy = random.uniform(-10, 10)
            gz = random.uniform(-10, 10)
            gps_speed = velocity_kmh
            line = f"Accel: {int(ax*2048)}, {int(ay*2048)}, {int(az*2048)} | Gyro: {int(gx*131)}, {int(gy*131)}, {int(gz*131)} | GPS: 12.34,56.78,{gps_speed:.1f},8 | IR: {ir_val} | POS: 0.0,0.0,1.5\n"
            log_lines.append(line)
        return log_lines
        
    elif scenario_name == "Hard Braking":
        # High deceleration on X axis, GPS speed drops to 0 smoothly, no Z impact
        speed = velocity_kmh
        pos_x = 0.0
        for i in range(int(5.0 / dt)):
            decel = 0
            if speed > 0:
                decel = 0.8 # 0.8G braking force
                speed -= (decel * 9.81 * 3.6) * dt
                if speed < 0: speed = 0
                
            pos_x += (speed / 3.6) * dt
                
            ax = -decel + random.uniform(-0.2, 0.2)
            ay = random.uniform(-0.1, 0.1)
            az = 1.0 + random.uniform(-0.1, 0.1)
            gx, gy, gz = random.uniform(-5, 5), random.uniform(-5, 5), random.uniform(-5, 5)
            line = f"Accel: {int(ax*2048)}, {int(ay*2048)}, {int(az*2048)} | Gyro: {int(gx*131)}, {int(gy*131)}, {int(gz*131)} | GPS: 12.34,56.78,{speed:.1f},8 | IR: {ir_val} | POS: {pos_x:.3f},0.0,1.5\n"
            log_lines.append(line)
        return log_lines
        
    elif scenario_name == "Head Checking Blindspot":
        # Rapid YAW rotation (Z-axis gyro), no G-force spikes
        for i in range(int(5.0 / dt)):
            ax, ay, az = random.uniform(-0.1, 0.1), random.uniform(-0.1, 0.1), 1.0 + random.uniform(-0.1, 0.1)
            gx, gy = random.uniform(-5, 5), random.uniform(-5, 5)
            # Simulate a head turn to the left, then back
            if 1.0 < (i*dt) < 1.5: gz = 200.0 # 200 deg/sec turn
            elif 2.0 < (i*dt) < 2.5: gz = -200.0
            else: gz = random.uniform(-5, 5)
            line = f"Accel: {int(ax*2048)}, {int(ay*2048)}, {int(az*2048)} | Gyro: {int(gx*131)}, {int(gy*131)}, {int(gz*131)} | GPS: 12.34,56.78,{velocity_kmh:.1f},8 | IR: {ir_val} | POS: 0.0,0.0,1.5\n"
            log_lines.append(line)
        return log_lines
        
    elif scenario_name == "Skydiving (Freefall, no impact)":
        # Endless 0G on all axes (terminal velocity reached, or just freefall)
        pos_z = 1000.0
        for i in range(int(5.0 / dt)):
            pos_z -= 50.0 * dt # falling at 50 m/s
            ax, ay, az = random.uniform(-0.05, 0.05), random.uniform(-0.05, 0.05), random.uniform(-0.05, 0.05)
            gx, gy, gz = random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-1, 1)
            line = f"Accel: {int(ax*2048)}, {int(ay*2048)}, {int(az*2048)} | Gyro: {int(gx*131)}, {int(gy*131)}, {int(gz*131)} | GPS: 12.34,56.78,{velocity_kmh:.1f},8 | IR: {ir_val} | POS: 0.0,0.0,{pos_z:.3f}\n"
            log_lines.append(line)
        return log_lines
        
    # --- PYBULLET PHYSICS SCENARIOS (Actual Crashes) ---
    
    # Initialize headless PyBullet
    physicsClient = p.connect(p.DIRECT)
    
    # 200Hz simulation
    dt = 1.0 / 200.0
    p.setTimeStep(dt)
    p.setGravity(0, 0, -9.81)
    
    # Create Ground
    ground_shape = p.createCollisionShape(p.GEOM_PLANE)
    ground = p.createMultiBody(baseMass=0, baseCollisionShapeIndex=ground_shape)
    p.changeDynamics(ground, -1, lateralFriction=0.8, restitution=0.2) # Asphalt
    
    # Create Helmet (Sphere)
    mass = 5.0 if is_wearing else 1.5 # 5kg with head, 1.5kg empty
    radius = 0.15 # 15cm radius
    helmet_shape = p.createCollisionShape(p.GEOM_SPHERE, radius=radius)
    helmet = p.createMultiBody(baseMass=mass, baseCollisionShapeIndex=helmet_shape, basePosition=[0, 0, height_m])
    
    # Material properties of the helmet (EPS foam / plastic shell)
    # Wearing it makes it slightly less bouncy (head absorbs energy)
    restitution = 0.2 if is_wearing else 0.4 
    p.changeDynamics(helmet, -1, lateralFriction=0.6, restitution=restitution, rollingFriction=0.01)
    
    # Apply initial velocity
    v0 = velocity_kmh / 3.6
    angle_rad = math.radians(angle_deg)
    vx = v0 * math.cos(angle_rad)
    vz = -v0 * math.sin(angle_rad) # Negative because drop angle usually points down
    
    # Induce a slight random spin if thrown
    spin_x = random.uniform(-10, 10) if v0 > 0 else 0
    spin_y = random.uniform(-10, 10) if v0 > 0 else 0
    
    p.resetBaseVelocity(helmet, linearVelocity=[vx, 0, vz], angularVelocity=[spin_x, spin_y, 0])
    
    log_lines = []
    
    # State tracking for acceleration (a = dv/dt)
    prev_vel, _ = p.getBaseVelocity(helmet)
    
    # Simulate for 5 seconds
    for _ in range(int(5.0 / dt)):
        p.stepSimulation()
        
        lin_vel, ang_vel = p.getBaseVelocity(helmet)
        
        # Calculate acceleration in m/s^2
        ax = (lin_vel[0] - prev_vel[0]) / dt
        ay = (lin_vel[1] - prev_vel[1]) / dt
        az = (lin_vel[2] - prev_vel[2]) / dt
        
        # In a real IMU, the Z axis reads +1G when resting on the ground due to normal force.
        # Convert to Gs and add 1G to Z
        ax_g = ax / 9.81
        ay_g = ay / 9.81
        az_g = (az / 9.81) + 1.0 
        
        # Convert Angular Velocity (rad/s) to Degrees/Sec
        gx = math.degrees(ang_vel[0])
        gy = math.degrees(ang_vel[1])
        gz = math.degrees(ang_vel[2])
        
        # Add realistic sensor noise
        ax_g += random.uniform(-noise_level, noise_level)
        ay_g += random.uniform(-noise_level, noise_level)
        az_g += random.uniform(-noise_level, noise_level)
        
        gx += random.uniform(-2.0, 2.0)
        gy += random.uniform(-2.0, 2.0)
        gz += random.uniform(-2.0, 2.0)
        
        # Format for output
        raw_ax = int(ax_g * 2048)
        raw_ay = int(ay_g * 2048)
        raw_az = int(az_g * 2048)
        raw_gx = int(gx * 131)
        raw_gy = int(gy * 131)
        raw_gz = int(gz * 131)
        
        # Calculate GPS speed (ignoring Z)
        gps_speed = math.sqrt(lin_vel[0]**2 + lin_vel[1]**2) * 3.6
        ir_val = 1 if is_wearing else 0
        
        pos, _ = p.getBasePositionAndOrientation(helmet)
        px, py, pz = pos
        
        line = f"Accel: {raw_ax}, {raw_ay}, {raw_az} | Gyro: {raw_gx}, {raw_gy}, {raw_gz} | GPS: 12.34,56.78,{gps_speed:.1f},8 | IR: {ir_val} | POS: {px:.3f},{py:.3f},{pz:.3f}\n"
        log_lines.append(line)
        
        prev_vel = lin_vel

    p.disconnect()
    return log_lines

if __name__ == "__main__":
    logs = generate_kinematic_crash(60.0, 0.0, 1.5, True)
    print(f"Generated {len(logs)} frames from PyBullet engine.")
