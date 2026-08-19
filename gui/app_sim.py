import eventlet
eventlet.monkey_patch()

import time
import threading
import re
import os
from flask import Flask, render_template
from flask_socketio import SocketIO

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret!'
socketio = SocketIO(app, async_mode='eventlet', cors_allowed_origins="*")

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '../simulator'))
from kinematic_engine import generate_kinematic_crash
from run_tests import CrashFirmwareModel
import random

def file_reader():
    """
    Dynamically generates physics scenarios and runs them through the algorithm.
    """
    scenarios = [
        {"name": "High Speed Slide", "v": 60.0, "angle": 0, "h": 1.5, "wearing": True},
        {"name": "City Crash", "v": 30.0, "angle": 45, "h": 1.5, "wearing": True},
        {"name": "Vertical Fall", "v": 0.0, "angle": 90, "h": 10.0, "wearing": True},
        {"name": "Dropped Helmet (Empty)", "v": 0.0, "angle": 90, "h": 1.5, "wearing": False},
        {"name": "Minor Bump", "v": 5.0, "angle": 0, "h": 0.5, "wearing": True},
        {"name": "Normal Riding", "v": 40.0, "angle": 0, "h": 1.5, "wearing": True},
        {"name": "Hard Braking", "v": 80.0, "angle": 0, "h": 1.5, "wearing": True},
        {"name": "Head Checking Blindspot", "v": 60.0, "angle": 0, "h": 1.5, "wearing": True},
        {"name": "Skydiving (Freefall, no impact)", "v": 0.0, "angle": 90, "h": 1000.0, "wearing": True}
    ]

    while True:
        scenario = random.choice(scenarios)
        print(f"\n--- STARTING SIMULATION: {scenario['name']} ---")
        logs = generate_kinematic_crash(scenario['v'], scenario['angle'], scenario['h'], scenario['wearing'], scenario_name=scenario['name'])
        
        firmware = CrashFirmwareModel()
        sos_emitted = False
        
        for line in logs:
            # Parse line
            parts = line.split("|")
            accel_parts = parts[0].replace("Accel:", "").split(",")
            gyro_parts = parts[1].replace("Gyro:", "").split(",")
            gps_parts = parts[2].replace("GPS:", "").split(",")
            ir_part = parts[3].replace("IR:", "").strip()
            pos_parts = parts[4].replace("POS:", "").split(",")
            
            raw_ax = int(accel_parts[0])
            raw_ay = int(accel_parts[1])
            raw_az = int(accel_parts[2])
            raw_gx = int(gyro_parts[0])
            raw_gy = int(gyro_parts[1])
            raw_gz = int(gyro_parts[2])
            gps_speed = float(gps_parts[2])
            
            px = float(pos_parts[0])
            py = float(pos_parts[1])
            pz = float(pos_parts[2])
            
            ax = raw_ax / 2048.0
            ay = raw_ay / 2048.0
            az = raw_az / 2048.0
            gx = raw_gx / 131.0
            gy = raw_gy / 131.0
            gz = raw_gz / 131.0
            ir = (ir_part == "1")
            
            # Emit raw data to front-end for visualization
            socketio.emit('sensor_data', {
                'ax': raw_ax, 'ay': raw_ay, 'az': raw_az,
                'gx': raw_gx, 'gy': raw_gy, 'gz': raw_gz,
                'px': px, 'py': py, 'pz': pz,
                'lat': 12.34, 'lon': 56.78, 'speed': gps_speed, 'sats': 8
            })
            
            # Run Algorithm
            state = firmware.process_frame(ax, ay, az, gx, gy, gz, gps_speed, ir)
            
            if state == "SOS_TRIGGERED" and not sos_emitted:
                msg = f"SOS_ALERT | MaxG: {firmware.max_g:.1f} | Energy: {firmware.energy:.1f} | Tumbling: {1 if firmware.is_tumbling else 0} | Dragging: {1 if firmware.is_dragging else 0} | GPS: 12.34,56.78 | Scenario: {scenario['name']}"
                print(f"EMITTING CRASH: {msg}")
                socketio.emit('crash_report', {'message': msg})
                sos_emitted = True
                
            time.sleep(0.005) # Playback at 200Hz
            
        # If the 5 second simulation finishes without triggering an SOS, log it as a SAFE event!
        if not sos_emitted:
            msg = f"SAFE_EVENT | MaxG: {firmware.max_g:.1f} | Energy: {firmware.energy:.1f} | Tumbling: {1 if firmware.is_tumbling else 0} | Dragging: {1 if firmware.is_dragging else 0} | GPS: 12.34,56.78 | Scenario: {scenario['name']}"
            print(f"EMITTING SAFE EVENT: {msg}")
            socketio.emit('crash_report', {'message': msg})
            
        print(f"Simulation finished. Restarting in 3 seconds...")
        time.sleep(3)

@app.route('/')
def index():
    return render_template('index.html')

if __name__ == '__main__':
    print(f"=== SIMULATION SERVER STARTED ===")
    print(f"Dynamic Kinematic Physics Engine Active")
    print(f"Open http://127.0.0.1:5000 in your browser")
    
    thread = threading.Thread(target=file_reader)
    thread.daemon = True
    thread.start()
    
    socketio.run(app, host='0.0.0.0', port=5000, debug=False)
