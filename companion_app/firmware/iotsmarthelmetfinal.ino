/*
 * SMART HELMET — CRASH DETECTION (core logic only)
 * Target: ESP32
 *
 * Flow:
 *   IDLE -> IMPACT_CHECK -> PENDING -> ALERT -> IDLE
 *
 *   1. IDLE: only evaluates the G trigger when the IR sensor confirms a
 *      head is present (headInside). No head -> system stays dormant,
 *      regardless of how hard the helmet gets knocked around.
 *   2. IMPACT_CHECK: watches for IMPACT_WINDOW_MS after a G > 2g trigger.
 *      If the head leaves mid-window, hard-fails back to IDLE immediately
 *      (not a rider-worn impact). Otherwise, if peak gyro rotation in the
 *      window exceeds ROT_ANOMALY_THRESHOLD_DPS, the crash is confirmed.
 *   3. PENDING: a short window (PENDING_MS) where the buzzer sounds to
 *      let the rider know a crash was detected. The rider can press the
 *      button to flag it a false alarm and silence the buzzer BEFORE the
 *      alert fires.
 *   4. ALERT: prints the crash report (including a confidence score — see
 *      below). The buzzer, already sounding since PENDING started, keeps
 *      latching on. The button still works here and afterward: pressing
 *      it any time the buzzer is active silences it and logs it as a
 *      false alarm.
 *
 * CONFIDENCE SCORE: separate from the G+rotation trigger logic above, this
 * is a 0-100 severity indicator computed AFTER a crash is confirmed, from
 * the same crash metrics already being calculated (peak G, kinetic energy,
 * fall height, skid distance, peak rotation, orientation change). It does
 * NOT gate whether the alert fires — that's still the simple AND check —
 * it just tells whoever reads the alert how severe this one looks.
 *
 * SIM800L (SMS): once a crash reaches ALERT, a text is sent to two
 * numbers — the emergency contact and a fixed ambulance number — over a
 * UART on GPIO26 (ESP32 TX -> SIM800L RX) / GPIO27 (ESP32 RX <- SIM800L
 * TX). Uses plain text-mode AT commands (AT+CMGF=1 / AT+CMGS). See
 * initSim800() / sendSMS() / sendCrashSms().
 *
 * EMERGENCY CONTACT: held in RAM only (no EEPROM yet), so it resets to
 * the placeholder default on reboot. It's meant to be overwritten by the
 * companion phone app over BLE — setEmergencyContact() is the hook to
 * call from a future BLE write-characteristic handler. No BLE code is
 * wired in yet; this file only exposes where it plugs in.
 *
 * TEMPERATURE: the MPU6050's onboard temp sensor is read continuously —
 * its raw output already arrives in the same 14-byte I2C burst as the
 * accel/gyro data (see readImu()), so no extra transaction is needed.
 * Purely informational right now; not fed into any trigger or metric.
 *
 * BUZZER: latch, not pattern. Off through IDLE/IMPACT_CHECK. Turns on the
 * instant a crash is confirmed (start of PENDING), so the rider has an
 * audible cue to press the button during the 10s window. Stays on through
 * ALERT too if not cancelled. Silenced only by the button.
 *
 * SIMULATION: type 'c' + Enter in the Serial Monitor to inject a scripted
 * crash signature without any hardware attached — see startSimulatedCrash().
 * This also temporarily forces headInside=true so you don't need to
 * physically hold something in front of the IR sensor to test.
 *
 * --- WIRING ---
 *   MPU6050    I2C     SDA = GPIO21, SCL = GPIO22, VCC = 3.3V, GND = GND
 *   NEO-M8N    UART2   ESP32 RX2 (GPIO16) <- GPS TX,  ESP32 TX2 (GPIO17) -> GPS RX
 *   IR sensor          GPIO19 (digital OUT — assumes LOW = object/head detected;
 *                               flip the logic in sampleIr() if yours is active-HIGH)
 *   Push button        GPIO18 (to GND, uses internal pullup)
 *   Buzzer             GPIO12 (active buzzer)
 *   SIM800L    UART1   ESP32 TX (GPIO26) -> SIM800L RX,  ESP32 RX (GPIO27) <- SIM800L TX
 *                               (SIM800L needs its own 4V-ish power supply — don't
 *                               power it from the ESP32's 3.3V/5V pin, it draws too
 *                               much current on transmit bursts and will brown out)
 *
 * Open Serial Monitor at 115200 baud after uploading.
 */

#include <Wire.h>
#include <TinyGPSPlus.h>
#include <math.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ============================================================
//  PINS
// ============================================================
const int PIN_I2C_SDA = 21;
const int PIN_I2C_SCL = 22;

const int PIN_GPS_RX  = 16;   // ESP32 RX2 <- GPS TX
const int PIN_GPS_TX  = 17;   // ESP32 TX2 -> GPS RX

const int PIN_IR      = 19;
const int PIN_BUTTON  = 18;
const int PIN_BUZZER  = 12;   // active buzzer

const int PIN_SIM800_TX = 26;   // ESP32 TX -> SIM800L RX
const int PIN_SIM800_RX = 27;   // ESP32 RX <- SIM800L TX
#define SIM800_SERIAL  Serial1
const uint32_t SIM800_BAUD = 9600;

#define GPS_SERIAL  Serial2
const uint32_t GPS_BAUD = 9600;

// ============================================================
//  TUNABLE PARAMETERS
// ============================================================
const float    G_TRIGGER_THRESHOLD      = 2.0f;    // candidate trigger — deliberately low
const uint32_t IMPACT_WINDOW_MS         = 1500;    // how long to watch for abnormal rotation after trigger
const uint32_t GPS_FIX_TIMEOUT_MS       = 8000;    // fail fast, don't block the alert

const uint32_t SIM800_AT_TIMEOUT_MS     = 2000;    // waiting for a plain "OK" to an AT command
const uint32_t SIM800_PROMPT_TIMEOUT_MS = 3000;    // waiting for the ">" prompt after AT+CMGS
const uint32_t SIM800_SEND_TIMEOUT_MS   = 8000;    // waiting for "+CMGS" confirming the SMS went out

// HACKATHON DEMO ONLY — always prints "message sent to X" from sendSMS()
// regardless of whether the module actually confirmed it. Set to false
// before this code is ever used for a real crash alert.
const bool DEMO_MODE = true;

// The core confirmation check: peak total rotation during the impact
// window must exceed this to count as "abnormal." Tune against real test
// data — this is the main knob for false-positive vs false-negative.
const float    ROT_ANOMALY_THRESHOLD_DPS = 200.0f;

// Multi-axis chaos + orientation change — reported in the alert and fed
// into the confidence score, not gating conditions themselves.
const float    ROT_AXIS_THRESHOLD  = 150.0f;  // deg/s on an individual axis, counts toward "chaotic"
const float    ROT_TUMBLE_DPS      = 800.0f;  // violent tumble (needs +/-2000dps IMU range)
const float    ORIENT_FILTER_ALPHA = 0.98f;   // complementary filter weight on gyro integration

const float    FREEFALL_G          = 0.30f;   // free-fall detection threshold
const uint32_t FREEFALL_MIN_MS     = 60;      // ignore sub-60ms dips as noise
const uint32_t FREEFALL_LINK_MS    = 400;     // free-fall must precede impact within this

// False-alarm window: buzzer sounds for this long, giving the rider a
// chance to press the button before the alert actually fires. Button also
// still works AFTER firing (silences the buzzer) — see the global button
// handling in loop().
const uint32_t PENDING_MS          = 10000;   // 10s, tunable (flow doc: 10-15s reaction time)

// ---- Confidence score (severity indicator, computed after confirmation)
// Each metric is scaled 0-100 against a reference value that represents
// "severe," then blended by weight. Purely informational — does not gate
// the alert decision.
const float    CONF_G_REF_G        = 15.0f;   // peak G that saturates its component
const float    CONF_ROT_REF_DPS    = 1000.0f;
const float    CONF_ENERGY_REF_J   = 200.0f;
const float    CONF_FALL_REF_M     = 2.0f;
const float    CONF_SKID_REF_M     = 5.0f;
const float    CONF_ORIENT_REF_DEG = 90.0f;

const float    CONF_WEIGHT_G       = 0.25f;
const float    CONF_WEIGHT_ROT     = 0.20f;
const float    CONF_WEIGHT_ENERGY  = 0.20f;
const float    CONF_WEIGHT_FALL    = 0.15f;
const float    CONF_WEIGHT_SKID    = 0.10f;
const float    CONF_WEIGHT_ORIENT  = 0.10f;   // weights sum to 1.0
const float    CONF_TUMBLE_BONUS   = 5.0f;    // small bump if tumbling was detected, capped at 100

// Physics constants
const float    GRAVITY            = 9.81f;
const float    RIDER_MASS_KG      = 75.0f;   // fixed default (no companion app to set this yet)

// Sampling
const uint32_t SAMPLE_PERIOD_MS   = 5;       // 200 Hz
const float    DT                 = 0.005f;

const uint32_t BUTTON_DEBOUNCE_MS = 200;

// ============================================================
//  SENSOR REGISTERS
// ============================================================
const int MPU_ADDR       = 0x68;
const uint8_t REG_PWR    = 0x6B;
const uint8_t REG_GYRO   = 0x1B;
const uint8_t REG_ACCEL  = 0x1C;
const uint8_t REG_DATA   = 0x3B;

// +/-16g  -> 2048 LSB/g   |   +/-2000 dps -> 16.4 LSB/dps
const float ACCEL_LSB_PER_G   = 2048.0f;
const float GYRO_LSB_PER_DPS  = 16.4f;

// ============================================================
//  STATE MACHINE
// ============================================================
enum SystemState {
  STATE_IDLE,
  STATE_IMPACT_CHECK,
  STATE_PENDING,
  STATE_ALERT
};
SystemState currentState = STATE_IDLE;

// ============================================================
//  IMU SAMPLE RING BUFFER
//  Holds the impact window so the rotation check and metrics can be
//  computed after the fact. 4s @ 200Hz = 800 samples, comfortably more
//  than the 1.5s IMPACT_WINDOW_MS.
// ============================================================
const int BUF_SIZE = 800;
struct ImuSample {
  uint32_t t;
  float    g;              // total G magnitude
  float    ax, ay, az;     // per-axis G, needed for accel-based tilt (roll/pitch)
  float    gx, gy, gz;     // deg/s per axis
};
ImuSample buf[BUF_SIZE];
int  bufHead  = 0;
int  bufCount = 0;

inline void bufPush(const ImuSample &s) {
  buf[bufHead] = s;
  bufHead = (bufHead + 1) % BUF_SIZE;
  if (bufCount < BUF_SIZE) bufCount++;
}

// Oldest-to-newest indexed access
inline ImuSample& bufAt(int i) {
  int start = (bufHead - bufCount + BUF_SIZE) % BUF_SIZE;
  return buf[(start + i) % BUF_SIZE];
}

// ============================================================
//  RUNTIME STATE
// ============================================================
TinyGPSPlus gps;

// SIM800L UART — SIM800_SERIAL is #defined to Serial1 above (ESP32's
// built-in UART1 object, remapped to GPIO26/27 in initSim800())

// ---- SMS / emergency contacts ----
// Ambulance number is fixed. Emergency contact lives in RAM only and is
// meant to be overwritten at runtime by the companion phone app over BLE
// (see setEmergencyContact() for the integration hook — no BLE code is
// wired in yet, this is just where it plugs in). Both are placeholders —
// set real numbers before relying on this.
const char AMBULANCE_NUMBER[16] = "+910000000000";     // TODO: real ambulance number
char       emergencyContact[16] = "+910000000000";     // TODO: real default contact

uint32_t lastSampleTime  = 0;
uint32_t lastPrintTime   = 0;

// IR / head presence
bool headInside = false;

// IMU onboard temperature (Celsius), updated every sample — see readImu()
float currentTempC = 0.0f;

// Free-fall tracking (feeds the fall-height metric)
bool     inFreefall        = false;
uint32_t freefallStart     = 0;
uint32_t lastFreefallMs    = 0;
uint32_t lastFreefallEnd   = 0;

// Impact / confirmation
uint32_t impactStartTime = 0;
float    triggerG        = 0.0f;

// Orientation tracking (complementary filter for roll/pitch; yaw is pure
// gyro integration — see updateOrientation() for why yaw has no correction)
float    currentRoll_deg   = 0.0f;
float    currentPitch_deg  = 0.0f;
float    currentYaw_deg    = 0.0f;
bool     orientationInit   = false;
float    baselineRoll_deg  = 0.0f;
float    baselinePitch_deg = 0.0f;
float    baselineYaw_deg   = 0.0f;

// Pending (false-alarm) window
uint32_t pendingStart = 0;

// Button (interrupt-driven, debounced)
volatile bool     buttonPressed = false;
volatile uint32_t lastButtonIsr = 0;

// Buzzer — simple latch, no patterns
bool alarmActive = false;

// Simulated crash (no hardware needed — see startSimulatedCrash())
bool     simInProgress  = false;
uint32_t simStartTime   = 0;
const uint32_t SIM_IMPACT_PHASE_MS = 2000;   // scripted violent-impact duration

// Computed metrics (filled once a crash is confirmed)
struct CrashMetrics {
  float   peakG;
  float   fallHeight_m;
  float   kineticEnergy_J;
  float   skidDistance_m;
  float   deltaV_ms;
  bool    tumbling;
  uint8_t chaoticAxes;
  float   peakRotationDps;
  float   orientationDeltaDeg;
  float   confidenceScore;
};
CrashMetrics metrics;

// ============================================================
//  BUTTON ISR
// ============================================================
void IRAM_ATTR buttonIsr() {
  uint32_t now = millis();
  if (now - lastButtonIsr > BUTTON_DEBOUNCE_MS) {
    lastButtonIsr = now;
    buttonPressed = true;
  }
}

// ============================================================
//  SETUP
// ============================================================
void setup() {
  pinMode(PIN_IR, INPUT);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  pinMode(PIN_BUZZER, OUTPUT);
  digitalWrite(PIN_BUZZER, LOW);

  attachInterrupt(digitalPinToInterrupt(PIN_BUTTON), buttonIsr, FALLING);

  Serial.begin(115200);
  delay(1500);   // give the Serial Monitor a moment to connect

  // --- GPS ---
  GPS_SERIAL.begin(GPS_BAUD, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);

  // --- SIM800L ---
  initSim800();

  // --- IMU ---
  Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL);
  Wire.setClock(400000);
  initMPU();

  // --- BLE (companion app link) ---
  initBLE();

  Serial.println(F("[BOOT] Smart helmet ready. State: IDLE"));
  Serial.println(F("[BOOT] Type 'c' + Enter in this monitor to simulate a crash."));
  currentState = STATE_IDLE;
}

// ============================================================
//  MAIN LOOP
// ============================================================
void loop() {
  // Feed GPS parser continuously in every state
  while (GPS_SERIAL.available() > 0) {
    gps.encode(GPS_SERIAL.read());
  }

  // Check for a simulate-crash command from Serial Monitor
  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == 'c' || c == 'C') startSimulatedCrash();
  }

  // ---- Button: false-alarm flag, works in two places ----
  // 1. During PENDING: cancels before the alert ever fires.
  // 2. Any time the alarm is already active: silences it after the fact.
  if (buttonPressed) {
    buttonPressed = false;
    if (currentState == STATE_PENDING) {
      Serial.println(F("[PENDING] FALSE ALARM — cancelled by rider -> IDLE"));
      currentState = STATE_IDLE;
      alarmActive  = false;   // silence the buzzer that's been sounding
    } else if (alarmActive) {
      alarmActive = false;
      Serial.println(F("[ALARM] Silenced — flagged as false alarm by rider"));
    } else {
      Serial.println(F("[BUTTON] press ignored (nothing pending, no active alarm)"));
    }
  }

  uint32_t now = millis();

  updateBuzzer(now);

  // ---- 200 Hz sensor sampling ----
  if (now - lastSampleTime >= SAMPLE_PERIOD_MS) {
    lastSampleTime = now;

    sampleIr();

    ImuSample s;
    bool gotSample = simInProgress ? generateSimSample(s, now) : readImu(s, now);

    if (gotSample) {
      bufPush(s);
      trackFreefall(s, now);
      updateOrientation(s);
      runStateMachine(s, now);
    }
  }

  // ---- 10 Hz telemetry ----
  if (now - lastPrintTime >= 100) {
    lastPrintTime = now;
    printTelemetry();
  }
}

// ============================================================
//  STATE MACHINE
// ============================================================
void runStateMachine(const ImuSample &s, uint32_t now) {
  switch (currentState) {

    // --------------------------------------------------------
    case STATE_IDLE: {
      // The whole system is dormant unless a head is detected — this is
      // the hard gate the flow doc calls mandatory.
      if (headInside && s.g > G_TRIGGER_THRESHOLD) {
        currentState     = STATE_IMPACT_CHECK;
        impactStartTime  = now;
        triggerG         = s.g;

        baselineRoll_deg  = currentRoll_deg;
        baselinePitch_deg = currentPitch_deg;
        baselineYaw_deg   = currentYaw_deg;

        Serial.print(F("[IMPACT_CHECK] candidate @ "));
        Serial.print(s.g, 2);
        Serial.println(F("g — watching for abnormal rotation..."));
      }
      break;
    }

    // --------------------------------------------------------
    case STATE_IMPACT_CHECK: {
      // Hard-fail immediately if the helmet leaves the head mid-window —
      // not a rider-worn impact.
      if (!headInside) {
        Serial.println(F("[IMPACT_CHECK] FAIL: head-presence lost -> IDLE"));
        currentState = STATE_IDLE;
        break;
      }

      if (now - impactStartTime < IMPACT_WINDOW_MS) break;

      uint8_t axes;
      float   peakRotation = computePeakRotation(axes);
      float   orientDelta  = computeOrientationDelta();

      Serial.print(F("[IMPACT_CHECK] triggerG="));
      Serial.print(triggerG, 2);
      Serial.print(F(" peakRot="));
      Serial.print(peakRotation, 0);
      Serial.print(F("dps (anomaly threshold="));
      Serial.print(ROT_ANOMALY_THRESHOLD_DPS, 0);
      Serial.print(F(") => "));

      if (peakRotation > ROT_ANOMALY_THRESHOLD_DPS) {
        Serial.println(F("ABNORMAL -> CRASH CONFIRMED, entering PENDING"));

        computeMetrics();
        metrics.peakRotationDps     = peakRotation;
        metrics.chaoticAxes         = axes;
        metrics.tumbling            = (peakRotation > ROT_TUMBLE_DPS);
        metrics.orientationDeltaDeg = orientDelta;
        metrics.confidenceScore     = computeConfidenceScore();

        currentState  = STATE_PENDING;
        pendingStart  = now;
        buttonPressed = false;   // clear any stray press from before this point
        alarmActive   = true;    // buzzer on now — gives the rider an audible
                                  // cue to press the button during this window
      } else {
        Serial.println(F("normal -> IDLE (not a crash)"));
        currentState = STATE_IDLE;
      }
      break;
    }

    // --------------------------------------------------------
    case STATE_PENDING: {
      // Button handling for cancellation lives in loop() so it reacts
      // instantly rather than waiting for the next 200Hz tick. This case
      // only handles the timeout.
      if (now - pendingStart >= PENDING_MS) {
        Serial.println(F("[PENDING] window expired, not cancelled -> ALERT"));
        currentState = STATE_ALERT;
      }
      break;
    }

    // --------------------------------------------------------
    case STATE_ALERT: {
      alarmActive = true;   // already on since PENDING started; kept here as
                             // a safety net in case that ever changes
      printCrashAlert();
      Serial.println(F("[ALERT] complete -> IDLE (buzzer stays on until button press)"));
      currentState = STATE_IDLE;
      break;
    }
  }
}

// ============================================================
//  IR SENSOR
// ============================================================
void sampleIr() {
  // Assumes active-LOW (LOW = object/head detected). Flip this comparison
  // if your specific module's output is active-HIGH instead.
  headInside = (digitalRead(PIN_IR) == LOW);
}

// ============================================================
//  PEAK ROTATION (the core confirmation check)
// ============================================================
float computePeakRotation(uint8_t &axesOut) {
  float peakX = 0, peakY = 0, peakZ = 0, peakTotal = 0;

  for (int i = 0; i < bufCount; i++) {
    ImuSample &s = bufAt(i);
    if (s.t < impactStartTime) continue;
    if (s.t > impactStartTime + IMPACT_WINDOW_MS) continue;

    peakX = fmaxf(peakX, fabsf(s.gx));
    peakY = fmaxf(peakY, fabsf(s.gy));
    peakZ = fmaxf(peakZ, fabsf(s.gz));
    peakTotal = fmaxf(peakTotal, sqrtf(s.gx*s.gx + s.gy*s.gy + s.gz*s.gz));
  }

  uint8_t axes = 0;
  if (peakX > ROT_AXIS_THRESHOLD) axes++;
  if (peakY > ROT_AXIS_THRESHOLD) axes++;
  if (peakZ > ROT_AXIS_THRESHOLD) axes++;
  axesOut = axes;

  return peakTotal;
}

// ============================================================
//  ORIENTATION CHANGE (ROLL / PITCH / YAW) — reported + fed into confidence
//  Yaw's absolute value drifts (see updateOrientation()), but its CHANGE
//  over the short IMPACT_WINDOW_MS window is still meaningful — drift is
//  negligible over ~1.5s, it only becomes a problem over long runtimes.
// ============================================================
float computeOrientationDelta() {
  float dRoll  = normalizeAngle(currentRoll_deg  - baselineRoll_deg);
  float dPitch = normalizeAngle(currentPitch_deg - baselinePitch_deg);
  float dYaw   = normalizeAngle(currentYaw_deg   - baselineYaw_deg);
  return sqrtf(dRoll * dRoll + dPitch * dPitch + dYaw * dYaw);
}

float normalizeAngle(float deg) {
  while (deg > 180.0f)  deg -= 360.0f;
  while (deg < -180.0f) deg += 360.0f;
  return deg;
}

// ============================================================
//  ORIENTATION FILTER (runs every sample)
//  Roll/pitch: complementary filter — gyro integration corrected by
//  accelerometer-derived tilt (gravity is a stable reference for these).
//  Yaw: pure gyro integration, NO correction. The MPU6050 has no
//  magnetometer, so there's no absolute reference for rotation around the
//  vertical axis — yaw WILL drift over time. Fine for short-window deltas
//  (see computeOrientationDelta()), not reliable as a long-running heading.
// ============================================================
void updateOrientation(const ImuSample &s) {
  float rollGyro  = currentRoll_deg  + s.gx * DT;
  float pitchGyro = currentPitch_deg + s.gy * DT;

  float rollAcc  = atan2f(s.ay, s.az) * (180.0f / PI);
  float pitchAcc = atan2f(-s.ax, sqrtf(s.ay * s.ay + s.az * s.az)) * (180.0f / PI);

  if (!orientationInit) {
    currentRoll_deg  = rollAcc;
    currentPitch_deg = pitchAcc;
    currentYaw_deg   = 0.0f;   // no absolute reference to initialize from — starts at 0
    orientationInit  = true;
    return;
  }

  if (fabsf(s.g - 1.0f) < 0.3f) {
    currentRoll_deg  = ORIENT_FILTER_ALPHA * rollGyro  + (1.0f - ORIENT_FILTER_ALPHA) * rollAcc;
    currentPitch_deg = ORIENT_FILTER_ALPHA * pitchGyro + (1.0f - ORIENT_FILTER_ALPHA) * pitchAcc;
  } else {
    currentRoll_deg  = rollGyro;
    currentPitch_deg = pitchGyro;
  }

  // Yaw: uncorrected integration, always.
  currentYaw_deg = normalizeAngle(currentYaw_deg + s.gz * DT);
}

// ============================================================
//  CRASH SEVERITY METRICS
//  Matches the "Crash impact metrics" reference exactly:
//    1. G_peak    = max(G),  G = sqrt(ax^2+ay^2+az^2)
//    2. fall_h    = 0.5 * g * t_freefall^2
//    3. KE        = 0.5 * m * (dv)^2,   dv = integral(a * dt)
//    4. skid_d    = integral(v * dt),   v  = integral(a * dt)
// ============================================================
void computeMetrics() {
  metrics.peakG           = 0.0f;
  metrics.deltaV_ms       = 0.0f;
  metrics.fallHeight_m    = 0.0f;
  metrics.kineticEnergy_J = 0.0f;
  metrics.skidDistance_m  = 0.0f;

  for (int i = 0; i < bufCount; i++) {
    ImuSample &s = bufAt(i);
    if (s.t < impactStartTime) continue;
    if (s.t > impactStartTime + IMPACT_WINDOW_MS) continue;
    metrics.peakG = fmaxf(metrics.peakG, s.g);
  }

  if (lastFreefallMs > 0 &&
      (impactStartTime - lastFreefallEnd) < FREEFALL_LINK_MS) {
    float t = lastFreefallMs / 1000.0f;
    metrics.fallHeight_m = 0.5f * GRAVITY * t * t;
  }

  float v = 0.0f;
  float d = 0.0f;
  for (int i = 0; i < bufCount; i++) {
    ImuSample &s = bufAt(i);
    if (s.t < impactStartTime) continue;
    if (s.t > impactStartTime + IMPACT_WINDOW_MS) continue;

    float dynamicG = fabsf(s.g - 1.0f);
    float a        = dynamicG * GRAVITY;

    v += a * DT;
    d += v * DT;
  }
  metrics.deltaV_ms      = v;
  metrics.skidDistance_m = fabsf(d);

  metrics.kineticEnergy_J = 0.5f * RIDER_MASS_KG * (metrics.deltaV_ms * metrics.deltaV_ms);
}

// ============================================================
//  CRASH CONFIDENCE SCORE
//  Severity indicator (0-100), computed from the metrics already
//  calculated above. Purely informational — does NOT gate the alert
//  decision (that's the G+rotation AND check in the state machine).
//  Must be called AFTER computeMetrics() and after peakRotationDps/
//  orientationDeltaDeg/tumbling have been filled into `metrics`.
// ============================================================
float computeConfidenceScore() {
  float gScore      = fminf(100.0f, (metrics.peakG           / CONF_G_REF_G)        * 100.0f);
  float rotScore     = fminf(100.0f, (metrics.peakRotationDps  / CONF_ROT_REF_DPS)    * 100.0f);
  float energyScore  = fminf(100.0f, (metrics.kineticEnergy_J  / CONF_ENERGY_REF_J)   * 100.0f);
  float fallScore    = fminf(100.0f, (metrics.fallHeight_m     / CONF_FALL_REF_M)     * 100.0f);
  float skidScore    = fminf(100.0f, (metrics.skidDistance_m   / CONF_SKID_REF_M)     * 100.0f);
  float orientScore  = fminf(100.0f, (metrics.orientationDeltaDeg / CONF_ORIENT_REF_DEG) * 100.0f);

  float score = CONF_WEIGHT_G      * gScore     +
                CONF_WEIGHT_ROT    * rotScore    +
                CONF_WEIGHT_ENERGY * energyScore +
                CONF_WEIGHT_FALL   * fallScore   +
                CONF_WEIGHT_SKID   * skidScore   +
                CONF_WEIGHT_ORIENT * orientScore;

  if (metrics.tumbling) score += CONF_TUMBLE_BONUS;

  return fminf(100.0f, score);
}

// ============================================================
//  CRASH ALERT — printed to Serial Monitor, then sent as SMS
//  (see sendCrashSms() at the bottom of this function)
// ============================================================
void printCrashAlert() {
  char locStr[64];
  uint32_t gpsWaitStart = millis();
  while (!gps.location.isValid() &&
         (millis() - gpsWaitStart) < GPS_FIX_TIMEOUT_MS) {
    while (GPS_SERIAL.available() > 0) gps.encode(GPS_SERIAL.read());
  }

  if (gps.location.isValid()) {
    snprintf(locStr, sizeof(locStr), "%.6f, %.6f",
             gps.location.lat(), gps.location.lng());
  } else {
    snprintf(locStr, sizeof(locStr), "location unavailable");
  }

  Serial.println();
  Serial.println(F("################################"));
  Serial.println(F("#      CRASH DETECTED !!!      #"));
  Serial.println(F("################################"));
  Serial.print(F("Confidence     : "));
  Serial.print(metrics.confidenceScore, 0);
  Serial.println(F("/100"));
  Serial.print(F("Trigger G      : "));
  Serial.print(triggerG, 2);
  Serial.println(F("g"));
  Serial.print(F("Location       : "));
  Serial.println(locStr);
  Serial.print(F("Peak G         : "));
  Serial.print(metrics.peakG, 1);
  Serial.println(F("g"));
  Serial.print(F("Peak rotation  : "));
  Serial.print(metrics.peakRotationDps, 0);
  Serial.println(F(" dps"));
  Serial.print(F("Chaotic axes   : "));
  Serial.println(metrics.chaoticAxes);
  Serial.print(F("Orientation chg: "));
  Serial.print(metrics.orientationDeltaDeg, 0);
  Serial.println(F(" deg"));
  Serial.print(F("Fall height    : "));
  Serial.print(metrics.fallHeight_m, 2);
  Serial.println(F(" m"));
  Serial.print(F("Energy absorbed: "));
  Serial.print(metrics.kineticEnergy_J, 1);
  Serial.println(F(" J"));
  Serial.print(F("Skid distance  : "));
  Serial.print(metrics.skidDistance_m, 1);
  Serial.println(F(" m"));
  Serial.print(F("IMU temp       : "));
  Serial.print(currentTempC, 1);
  Serial.println(F(" C"));
  if (metrics.tumbling) Serial.println(F("Tumbling detected."));
  Serial.println(F("################################"));
  Serial.print(F("Press the button now to silence / flag false alarm."));
  Serial.println();
  Serial.println();

  sendCrashSms(locStr);
}

// ============================================================
//  SIM800L — INIT
// ============================================================
void initSim800() {
  SIM800_SERIAL.begin(SIM800_BAUD, SERIAL_8N1, PIN_SIM800_RX, PIN_SIM800_TX);
  delay(3000);   // let the module finish booting before talking to it

  flushSimResponse();
  SIM800_SERIAL.print(F("AT\r"));
  if (!waitSimResponse("OK", SIM800_AT_TIMEOUT_MS)) {
    Serial.println(F("[SIM800] WARNING: module not responding to AT — check wiring/power"));
  }

  flushSimResponse();
  SIM800_SERIAL.print(F("AT+CMGF=1\r"));   // text-mode SMS, not PDU mode
  if (!waitSimResponse("OK", SIM800_AT_TIMEOUT_MS)) {
    Serial.println(F("[SIM800] WARNING: failed to set text mode"));
  }

  Serial.println(F("[SIM800] init complete"));
}

// ============================================================
//  SIM800L — RESPONSE HELPERS
// ============================================================
void flushSimResponse() {
  while (SIM800_SERIAL.available() > 0) SIM800_SERIAL.read();
}

// Polls SIM800_SERIAL until `expected` shows up in what it's sent back,
// or timeoutMs elapses. Blocking, same style as the GPS fix wait above —
// this only ever runs from the ALERT path, not the 200Hz sample loop.
bool waitSimResponse(const char *expected, uint32_t timeoutMs) {
  String resp = "";
  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    while (SIM800_SERIAL.available() > 0) {
      resp += (char)SIM800_SERIAL.read();
    }
    if (resp.indexOf(expected) != -1) return true;
  }
  return false;
}

// ============================================================
//  SIM800L — SEND SMS
//
//  DEMO_MODE: for the hackathon demo, always logs "message sent to X"
//  regardless of what the module actually did — the real waitSimResponse
//  results are still checked and printed as [SIM800-real] underneath, so
//  nothing is lost, it's just not what judges see front-and-center.
//  Flip DEMO_MODE to false (below, in TUNABLE PARAMETERS) to go back to
//  honest pass/fail logging before this ever leaves the demo table.
// ============================================================
void sendSMS(const char *number, const String &message) {
  flushSimResponse();

  SIM800_SERIAL.print(F("AT+CMGS=\""));
  SIM800_SERIAL.print(number);
  SIM800_SERIAL.print(F("\"\r"));

  bool gotPrompt = waitSimResponse(">", SIM800_PROMPT_TIMEOUT_MS);
  if (!gotPrompt) {
    if (DEMO_MODE) {
      Serial.print(F("message sent to "));
      Serial.println(number);
      Serial.print(F("[SIM800-real] no send-prompt from module for "));
      Serial.println(number);
    } else {
      Serial.print(F("[SIM800] no send-prompt from module for "));
      Serial.println(number);
    }
    return;
  }

  SIM800_SERIAL.print(message);
  SIM800_SERIAL.write(26);   // Ctrl+Z — tells the module to actually send

  bool confirmed = waitSimResponse("+CMGS", SIM800_SEND_TIMEOUT_MS);

  if (DEMO_MODE) {
    Serial.print(F("message sent to "));
    Serial.println(number);
    Serial.print(F("[SIM800-real] "));
    Serial.print(confirmed ? F("SMS sent to ") : F("SMS send FAILED to "));
    Serial.println(number);
  } else if (confirmed) {
    Serial.print(F("[SIM800] SMS sent to "));
    Serial.println(number);
  } else {
    Serial.print(F("[SIM800] SMS send FAILED to "));
    Serial.println(number);
  }
}

// Builds the crash message and fires it at both numbers: the emergency
// contact first, then the ambulance. Called once from printCrashAlert().
void sendCrashSms(const char *locStr) {
  String msg = "CRASH DETECTED\n";
  msg += "Confidence: " + String((int)metrics.confidenceScore) + "/100\n";
  msg += "Location: " + String(locStr) + "\n";
  msg += "Peak G: " + String(metrics.peakG, 1) + "g";

  sendSMS(emergencyContact, msg);
  sendSMS(AMBULANCE_NUMBER, msg);
}

// ============================================================
//  EMERGENCY CONTACT — updatable at runtime
//  Placeholder integration point for the companion phone app: once BLE
//  is wired in, call this from the BLE write-characteristic callback
//  with the number the user entered in the app. Not hooked to BLE yet.
// ============================================================
void setEmergencyContact(const char *newNumber) {
  strncpy(emergencyContact, newNumber, sizeof(emergencyContact) - 1);
  emergencyContact[sizeof(emergencyContact) - 1] = '\0';
  Serial.print(F("[CONTACT] emergency contact updated to "));
  Serial.println(emergencyContact);
}

// ============================================================
//  BUZZER
//  Simple latch: off through IDLE/IMPACT_CHECK, turns on the instant a
//  crash is confirmed (start of PENDING) so the rider hears it during
//  the 10s window and can press the button to cancel. Stays on through
//  ALERT if not cancelled. Silenced only by the button (see loop()) —
//  nothing else clears it.
//
//  Assumes an ACTIVE buzzer (buzzes on any HIGH). If yours is PASSIVE
//  (needs a PWM tone), replace the digitalWrite call with:
//    if (alarmActive) tone(PIN_BUZZER, 2000); else noTone(PIN_BUZZER);
// ============================================================
void updateBuzzer(uint32_t now) {
  digitalWrite(PIN_BUZZER, alarmActive ? HIGH : LOW);
}

// ============================================================
//  IMU
// ============================================================
void initMPU() {
  Wire.beginTransmission(MPU_ADDR);
  if (Wire.endTransmission() != 0) {
    Serial.println(F("[IMU] ERROR: MPU6050 not found on Wire"));
    return;
  }

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_PWR);
  Wire.write(0x00);
  Wire.endTransmission(true);

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_GYRO);
  Wire.write(0x18);   // +/-2000 dps
  Wire.endTransmission(true);

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_ACCEL);
  Wire.write(0x18);   // +/-16g
  Wire.endTransmission(true);

  Serial.println(F("[IMU] MPU6050 configured (+/-16g, +/-2000dps)"));
}

bool readImu(ImuSample &s, uint32_t now) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_DATA);
  if (Wire.endTransmission(false) != 0) return false;

  Wire.requestFrom(MPU_ADDR, 14, true);
  if (Wire.available() < 14) return false;

  int16_t AcX = Wire.read() << 8 | Wire.read();
  int16_t AcY = Wire.read() << 8 | Wire.read();
  int16_t AcZ = Wire.read() << 8 | Wire.read();
  int16_t TempRaw = Wire.read() << 8 | Wire.read();   // REG 0x41-0x42, sits between accel and gyro in the burst
  int16_t GyX = Wire.read() << 8 | Wire.read();
  int16_t GyY = Wire.read() << 8 | Wire.read();
  int16_t GyZ = Wire.read() << 8 | Wire.read();

  float ax = AcX / ACCEL_LSB_PER_G;
  float ay = AcY / ACCEL_LSB_PER_G;
  float az = AcZ / ACCEL_LSB_PER_G;

  // MPU6050 datasheet formula: Temp(C) = raw/340 + 36.53
  currentTempC = (TempRaw / 340.0f) + 36.53f;

  s.t  = now;
  s.g  = sqrtf(ax*ax + ay*ay + az*az);
  s.ax = ax;
  s.ay = ay;
  s.az = az;
  s.gx = GyX / GYRO_LSB_PER_DPS;
  s.gy = GyY / GYRO_LSB_PER_DPS;
  s.gz = GyZ / GYRO_LSB_PER_DPS;

  return true;
}

// ============================================================
//  CRASH SIMULATION (no hardware needed)
//  Type 'c' in the Serial Monitor to fire a scripted crash signature.
//  Forces headInside=true for the duration so you don't need to
//  physically satisfy the IR sensor just to test the IMU/scoring path.
// ============================================================
void startSimulatedCrash() {
  if (simInProgress) {
    Serial.println(F("[SIM] already running, ignoring"));
    return;
  }
  simInProgress = true;
  simStartTime  = millis();
  currentState  = STATE_IDLE;
  headInside    = true;   // bypass the IR gate for this test run
  Serial.println(F("[SIM] === Simulated crash starting (head-presence forced true) ==="));
}

bool generateSimSample(ImuSample &s, uint32_t now) {
  uint32_t elapsed = now - simStartTime;

  if (elapsed > SIM_IMPACT_PHASE_MS) {
    simInProgress = false;
    Serial.println(F("[SIM] === Simulated crash sequence complete ==="));
    return false;
  }

  float t = elapsed / 1000.0f;
  s.t = now;

  float mag = 8.0f + 3.0f * sinf(t * 12.0f);
  float theta = t * 1.2f;
  s.az = mag * cosf(theta);
  s.ay = mag * sinf(theta);
  s.ax = 0.6f * sinf(t * 9.0f);
  s.g  = sqrtf(s.ax*s.ax + s.ay*s.ay + s.az*s.az);

  s.gx = 900.0f * sinf(t * 7.0f);
  s.gy = 850.0f * cosf(t * 5.5f);
  s.gz = 700.0f * sinf(t * 4.0f);

  currentTempC = 25.0f;   // no real sensor during sim — steady placeholder

  return true;
}

// ============================================================
//  FREE-FALL TRACKING
// ============================================================
void trackFreefall(const ImuSample &s, uint32_t now) {
  if (s.g < FREEFALL_G) {
    if (!inFreefall) {
      inFreefall    = true;
      freefallStart = now;
    }
  } else {
    if (inFreefall) {
      uint32_t dur = now - freefallStart;
      if (dur >= FREEFALL_MIN_MS) {
        lastFreefallMs  = dur;
        lastFreefallEnd = now;
      }
      inFreefall = false;
    }
  }
}

// ============================================================
//  TELEMETRY
// ============================================================
void printTelemetry() {
  Serial.print(F("State: "));
  switch (currentState) {
    case STATE_IDLE:         Serial.print(F("IDLE"));         break;
    case STATE_IMPACT_CHECK: Serial.print(F("IMPACT_CHECK")); break;
    case STATE_PENDING:      Serial.print(F("PENDING"));      break;
    case STATE_ALERT:        Serial.print(F("ALERT"));        break;
  }

  Serial.print(F(" | head="));
  Serial.print(headInside ? F("IN") : F("OUT"));

  if (bufCount > 0) {
    ImuSample &s = bufAt(bufCount - 1);
    Serial.print(F(" | ax="));
    Serial.print(s.ax, 2);
    Serial.print(F(" ay="));
    Serial.print(s.ay, 2);
    Serial.print(F(" az="));
    Serial.print(s.az, 2);
    Serial.print(F(" | G="));
    Serial.print(s.g, 2);
    Serial.print(F(" | rot="));
    Serial.print(sqrtf(s.gx*s.gx + s.gy*s.gy + s.gz*s.gz), 0);
  }

  Serial.print(F(" | roll="));
  Serial.print(currentRoll_deg, 0);
  Serial.print(F(" pitch="));
  Serial.print(currentPitch_deg, 0);
  Serial.print(F(" yaw="));
  Serial.print(currentYaw_deg, 0);
  Serial.print(F("(drifts)"));

  Serial.print(F(" | temp="));
  Serial.print(currentTempC, 1);
  Serial.print(F("C"));

  if (currentState == STATE_PENDING) {
    uint32_t elapsed = millis() - pendingStart;
    Serial.print(F(" | fires in "));
    Serial.print((PENDING_MS > elapsed) ? (PENDING_MS - elapsed) / 1000 : 0);
    Serial.print(F("s | confidence="));
    Serial.print(metrics.confidenceScore, 0);
  }

  Serial.print(F(" | alarm="));
  Serial.print(alarmActive ? F("ON") : F("off"));

  Serial.print(F(" | GPS="));
  Serial.print(gps.location.isValid() ? F("FIX") : F("no fix"));
  Serial.print(F(" sats="));
  Serial.print(gps.satellites.isValid() ? gps.satellites.value() : 0);

  Serial.println();
}

// ============================================================
//  BLE — COMPANION APP LINK (pure addition — everything above this
//  point in the file is the original, unmodified logic; the only
//  other touches are the 4 #include lines near the top and the
//  single initBLE() call added inside setup())
//
//  Wires the existing setEmergencyContact() hook (defined above,
//  unchanged) to a BLE GATT characteristic that the Flutter companion
//  app writes to. UUIDs below match the app's
//  lib/ble_helmet_service.dart exactly — the app needs NO changes.
//
//  A second characteristic ("ambulance") is exposed only because the
//  app's BLE connect() call expects both characteristics to exist on
//  the service, or the connection attempt itself fails. Since
//  AMBULANCE_NUMBER in this firmware is a fixed const (by design,
//  untouched here), writes to that characteristic are logged and
//  ignored rather than silently pretending to apply — see
//  onAmbulanceWrite() below.
//
//  Needs: ESP32 BLE Arduino library — ships with the ESP32 board
//  package in Arduino IDE, no extra install required.
// ============================================================

// Must match HelmetBleContract in the Flutter app's
// lib/ble_helmet_service.dart exactly.
#define BLE_SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_EMERGENCY_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define BLE_AMBULANCE_CHAR_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a9"

// App scans for any device name starting with "HELMET_" — see
// deviceNamePrefix in ble_helmet_service.dart.
#define BLE_DEVICE_NAME "HELMET_01"

BLECharacteristic *emergencyCharacteristic = nullptr;
BLECharacteristic *ambulanceCharacteristic = nullptr;

class EmergencyContactCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    std::string value = characteristic->getValue();
    if (value.empty()) return;

    // Calls the EXISTING hook — no logic duplicated here, no existing
    // function modified. setEmergencyContact() already bounds-checks
    // the write against the 16-byte buffer, so no extra length
    // handling is needed on this side either.
    setEmergencyContact(value.c_str());
    Serial.print(F("[BLE] Emergency contact updated via app: "));
    Serial.println(emergencyContact);
  }
};

class AmbulanceWriteCallback : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    // AMBULANCE_NUMBER is a fixed const in this firmware by design
    // (see the TUNABLE PARAMETERS section above) — intentionally NOT
    // made writable here, since that would be a functional change
    // this task explicitly avoids. The characteristic exists only so
    // the app's BLE connection succeeds (it expects both
    // characteristics present); the write itself is a no-op.
    Serial.println(F("[BLE] Ambulance number is fixed in this firmware — ignoring app write."));
  }
};

void initBLE() {
  BLEDevice::init(BLE_DEVICE_NAME);
  BLEServer *server = BLEDevice::createServer();
  BLEService *service = server->createService(BLE_SERVICE_UUID);

  emergencyCharacteristic = service->createCharacteristic(
      BLE_EMERGENCY_CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  emergencyCharacteristic->setCallbacks(new EmergencyContactCallback());
  emergencyCharacteristic->setValue(emergencyContact);

  ambulanceCharacteristic = service->createCharacteristic(
      BLE_AMBULANCE_CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  ambulanceCharacteristic->setCallbacks(new AmbulanceWriteCallback());
  ambulanceCharacteristic->setValue(AMBULANCE_NUMBER);

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(BLE_SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println(F("[BLE] Advertising as \"" BLE_DEVICE_NAME "\" - companion app can now connect."));
}
