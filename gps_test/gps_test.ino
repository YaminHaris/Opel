void setup() {
  Serial.begin(115200);
  
  // Wait for the Serial monitor to open
  while (!Serial) {
    delay(10);
  }
  
  Serial.println("\n--- GPS Passthrough Test ---");
  Serial.println("Testing baud rate: 9600");
  Serial.println("If you see gibberish (), the baud rate is wrong.");
  Serial.println("If you see NOTHING, swap your TX and RX wires!");
  Serial.println("If you see $GNRMC or $GPGGA, it is working perfectly!");
  Serial.println("----------------------------\n");

  // Set up Serial1 for the GPS (GP0 = TX, GP1 = RX)
  Serial1.setRX(1);
  Serial1.setTX(0);
  Serial1.begin(9600); 
}

void loop() {
  // Read from GPS and print to Computer
  if (Serial1.available()) {
    Serial.write(Serial1.read());
  }
  
  // Read from Computer and send to GPS (useful for config)
  if (Serial.available()) {
    Serial1.write(Serial.read());
  }
}
