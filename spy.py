import socketio
import time

sio = socketio.Client()

@sio.event
def connect():
    print("Spy connected!")

@sio.on('sensor_data')
def on_message(data):
    print("Intercepted:", data)
    sio.disconnect()

sio.connect('http://127.0.0.1:5000')
sio.wait()
