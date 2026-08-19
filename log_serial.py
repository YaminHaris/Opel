import serial
import time
import sys

# The Pico 2 usually enumerates as /dev/ttyACM0 on Linux
PORT = '/dev/ttyACM0'
BAUD_RATE = 115200
LOG_FILE = 'mpu_data.log'

try:
    # Open the serial port
    print(f"Connecting to Pico 2 on {PORT} at {BAUD_RATE} baud...")
    ser = serial.Serial(PORT, BAUD_RATE, timeout=1)
    
    with open(LOG_FILE, 'a') as f:
        print(f"Connected! Logging data to {LOG_FILE}. Press Ctrl+C to stop.")
        while True:
            # Read a line from the serial port
            if ser.in_waiting > 0:
                line = ser.readline().decode('utf-8', errors='ignore').strip()
                if line:
                    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
                    log_entry = f"[{timestamp}] {line}"
                    print(log_entry)
                    f.write(log_entry + '\n')
                    f.flush()
            time.sleep(0.01)

except serial.SerialException as e:
    print(f"Error connecting to serial port: {e}")
    print("Make sure the Pico 2 is connected and you have permission to read the port.")
    print("You may need to run: sudo usermod -a -G dialout $USER")
except KeyboardInterrupt:
    print("\nLogging stopped by user.")
finally:
    if 'ser' in locals() and ser.is_open:
        ser.close()
