import eventlet
eventlet.monkey_patch()

import serial
import time
import threading
import re
from flask import Flask, render_template
from flask_socketio import SocketIO

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret!'
socketio = SocketIO(app, async_mode='eventlet', cors_allowed_origins="*")

PORT = '/dev/ttyACM0'
BAUD = 115200
ser = None

def serial_reader():
    global ser
    while True:
        try:
            if ser is None or not ser.is_open:
                ser = serial.Serial(PORT, BAUD, timeout=1)
                print(f"Connected to {PORT}")
            
            line = ser.readline().decode('utf-8', errors='ignore').strip()
            if line:
                # Expected format: Accel: X, Y, Z | Gyro: X, Y, Z [| Temp: T]
                match = re.search(r"Accel:\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\|\s*Gyro:\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)(?:\s*\|\s*Temp:\s*(-?\d+))?", line)
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
                    socketio.emit('sensor_data', data)
                    
        except serial.SerialException as e:
            print(f"Serial disconnected: {e}")
            if ser:
                ser.close()
                ser = None
            time.sleep(2)
        except Exception as e:
            print(f"Error reading: {e}")
            time.sleep(1)

@app.route('/')
def index():
    return render_template('index.html')

if __name__ == '__main__':
    thread = threading.Thread(target=serial_reader)
    thread.daemon = True
    thread.start()
    print("Starting server on http://127.0.0.1:5000")
    socketio.run(app, host='0.0.0.0', port=5000, debug=False)
