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

# Point to the log file in the simulator folder (adjust as needed)
SIM_LOG_FILE = os.path.join(os.path.dirname(__file__), '../simulator/sim_scooter_drag.log')

def file_reader():
    """
    Reads the synthetic log file exactly as if it was a serial port, 
    but automatically loops the crash sequence for GUI testing.
    """
    while True:
        try:
            if not os.path.exists(SIM_LOG_FILE):
                print(f"Waiting for {SIM_LOG_FILE} to be generated...")
                time.sleep(2)
                continue

            with open(SIM_LOG_FILE, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line:
                        # Expected format: Accel: X, Y, Z | Gyro: X, Y, Z [| Temp: T] [| GPS: lat,lon,speed,sats]
                        match = re.search(r"Accel:\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\|\s*Gyro:\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)(?:\s*\|\s*Temp:\s*(-?\d+))?(?:\s*\|\s*GPS:\s*(-?\d+\.\d+),(-?\d+\.\d+),(-?\d+\.\d+),(\d+))?", line)
                        if match:
                            data = {
                                'ax': int(match.group(1)),
                                'ay': int(match.group(2)),
                                'az': int(match.group(3)),
                                'gx': int(match.group(4)),
                                'gy': int(match.group(5)),
                                'gz': int(match.group(6))
                            }
                            if match.group(7) is not None:
                                data['temp'] = int(match.group(7))
                            if match.group(8) is not None:
                                data['lat'] = float(match.group(8))
                                data['lon'] = float(match.group(9))
                                data['speed'] = float(match.group(10))
                                data['sats'] = int(match.group(11))
                            
                            socketio.emit('sensor_data', data)
                    
                    if "SOS_ALERT" in line:
                        print(f"EMITTING CRASH: {line}")
                        socketio.emit('crash_report', {'message': line})
                            
                    time.sleep(0.005) # Playback at 200Hz
                    
            print(f"End of simulation log. Restarting in 3 seconds...")
            time.sleep(3)
            
        except Exception as e:
            print(f"Error reading sim file: {e}")
            time.sleep(1)

@app.route('/')
def index():
    return render_template('index.html')

if __name__ == '__main__':
    print(f"=== SIMULATION SERVER STARTED ===")
    print(f"Playing back log: {SIM_LOG_FILE}")
    print(f"Open http://127.0.0.1:5000 in your browser")
    
    thread = threading.Thread(target=file_reader)
    thread.daemon = True
    thread.start()
    
    socketio.run(app, host='0.0.0.0', port=5000, debug=False)
