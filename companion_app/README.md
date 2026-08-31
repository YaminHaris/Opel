# Companion App — Emergency Contact Manager

## What this is

A Flutter mobile app for the smart helmet: manages emergency contacts,
shows a live map with the helmet's last known location and the
nearest hospital, and syncs to the helmet over Firebase and/or
Bluetooth (BLE). See below for the full feature list — this has grown
well past the original "two fields and a save button" scope.

## Hardware target: ESP32 (confirmed)

This app assumes **ESP32**, and as of this update that's no longer
just an assumption — `firmware/iotsmarthelmetfinal.ino` in this folder
is real, working ESP32 firmware with BLE wired in to accept contact
updates from this app. The rest of the repo (`mpu_reader/`,
`gps_test/`) still targets a **Raspberry Pi Pico 2** and hasn't been
migrated — that's still a separate, tracked piece of work, not
resolved by this addition. The two firmware bases are not currently
unified into one; `firmware/iotsmarthelmetfinal.ino` is a standalone
ESP32 sketch covering crash detection + SIM800L SMS + BLE, built
independently of the Pico 2 telemetry/GUI pipeline described in the
root README.

## What's in `firmware/`

`iotsmarthelmetfinal.ino` — ESP32 sketch: MPU6050 crash detection
(impact + rotation-based confirmation, confidence scoring), NEO-M8N
GPS, SIM800L SMS alerts, and a BLE service that lets this app update
the emergency contact number over Bluetooth. The BLE addition is
purely additive on top of existing crash-detection logic — see the
comment block at the end of that file for exactly what was added and
why.

**BLE contract** (must match `lib/ble_helmet_service.dart` exactly):
- Service UUID: `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
- Emergency contact characteristic: `beb5483e-36e1-4688-b7f5-ea07361b26a8`
- Ambulance characteristic: `beb5483e-36e1-4688-b7f5-ea07361b26a9`
  (present for protocol compatibility; the firmware's ambulance number
  is currently a fixed constant, so writes to this one are logged and
  ignored rather than silently pretending to apply)
- Device advertises as `HELMET_01`

## Scope

Originally scoped to just contacts; has since grown to include a live
map, hospital lookup, offline queueing, and a debug/testing toolkit.
See the feature sections below for what's actually implemented.

## What's implemented and tested

- **Firebase Realtime Database sync**: writes to `helmet_01/contacts`,
  reads back on launch, listens to `helmet_01/status/last_seen`
- **10-digit phone validation** before anything is written
- **Bluetooth sync path** (`lib/ble_helmet_service.dart`): scans for a
  device advertising `HELMET_*`, connects, writes to two GATT
  characteristics. UUIDs in `HelmetBleContract` are **placeholders** —
  nothing on the firmware side implements this service yet
- **Integration tests** (`integration_test/app_test.dart`) run the real app
  against the Firebase Local Emulator Suite — save, load, and validation
  paths are covered end-to-end without touching production data

## What's NOT implemented

- ESP32 firmware that reads `helmet_01/contacts` and stores it to flash
- ESP32 firmware that exposes the BLE GATT service this app expects
- SIM800L SMS-sending logic
- Porting the existing Pico-2-targeted firmware to ESP32 (separate, larger issue)

## Setup

```bash
flutter pub get
dart pub global activate flutterfire_cli
flutterfire configure   # generates your own lib/firebase_options.dart
flutter run -d chrome
```

Realtime Database rules used during development (open, demo-only — do not
ship this to production):
```json
{
  "rules": { ".read": true, ".write": true }
}
```

### Running tests

```bash
# Unit/widget smoke test (no Firebase required)
flutter test

# Full integration test against Firebase Local Emulator Suite
firebase emulators:start --only database
flutter test integration_test/app_test.dart -d chrome --dart-define=USE_FIREBASE_EMULATOR=true
```

## Files

- `lib/main.dart` — the app, `ContactScreen`
- `lib/ble_helmet_service.dart` — BLE scan/connect/write logic (placeholder UUIDs)
- `lib/firebase_options.dart` — sanitized placeholder; run `flutterfire configure` for your own project
- `test/widget_test.dart` — smoke test
- `integration_test/app_test.dart` — real Firebase-emulator-backed tests

## Additional feature notes (dark-default redesign)

- **Dynamic contact list**: starts with Emergency (required) + Ambulance
  (optional), up to `kMaxContacts` (5) via "+ Add". Stored in Firebase as
  an array under `helmet_01/contacts`.
- **Call / test-text buttons** per contact: call opens the native dialer;
  the message icon opens the phone's native SMS composer with a test
  message pre-filled. **This sends from the rider's own phone, not the
  helmet's SIM800L** — there's no firmware yet that lets the helmet send
  texts, so this only verifies the number itself is valid and reachable.
- **Duplicate detection**: save is blocked if two contact slots hold the
  same number.
- **Offline queue**: if a save fails (no connection), it's queued locally
  via `shared_preferences` and auto-retried when `connectivity_plus`
  reports the connection is back.
- **Simulate SOS**: writes a test alert to `helmet_01/alerts/latest`
  (same shape a real crash-triggered write would use), behind a
  confirmation dialog. Useful for demoing the pipeline live without
  needing an actual crash. Nothing calls real contacts — it only writes
  to Firebase, for the dashboard to pick up.
- **Bluetooth limitation**: the placeholder BLE GATT contract only
  exposes two characteristics, so BLE sync only carries the first two
  contacts (Emergency + Ambulance) until firmware defines more.

### Android permissions needed for call/SMS
Add to `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.CALL_PHONE" />
```
(SMS composer via `sms:` URI doesn't require a manifest permission —
it hands off to the Messages app rather than sending directly.)

## Nearest hospital finder

Reads the helmet's last known GPS fix from `helmet_01/location/{lat,lng}`
and searches OpenStreetMap's free Overpass API for nearby hospitals,
sorted by distance, shown on a map (flutter_map + OSM tiles — no API key,
no billing) with a list underneath. Tapping the checkmark on a result
fills that number into the Ambulance/hospital contact slot on the main
screen.

**Honesty flag**: no firmware currently writes GPS coordinates anywhere
— the NEO-6M GPS code in this repo only prints to serial. This feature
reads from a path (`helmet_01/location`) that firmware will need to
write to eventually. Until then, the **"Simulate GPS"** button on the
finder screen uses the phone's own GPS as a stand-in, so the full flow
is demoable without real firmware.

**Data quality note**: hospital phone numbers come from OpenStreetMap
contributor data and are frequently missing — results without a number
show "no number listed" and won't offer a call/use button.

### Permissions needed
Android — `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.INTERNET" />
```
(`ACCESS_FINE_LOCATION` may already be present from the Bluetooth setup —
don't duplicate it, just confirm it's there.)

iOS — `ios/Runner/Info.plist`:
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Used to simulate a GPS fix for testing the hospital finder.</string>
```

## Nearest hospital finder

- **Data assumption (flag for the GPS/firmware side)**: this reads
  `helmet_01/status/lat` and `helmet_01/status/lon` as numbers. **No
  firmware currently writes this** — the NEO-6M GPS module exists in
  the repo's hardware plan, but nothing pushes its output to Firebase
  yet. This UI is built against that assumed shape so whoever wires up
  GPS reporting has a concrete target to write to.
- **Lookup**: uses OpenStreetMap's free Overpass API (no key, no
  billing) to find the nearest `amenity=hospital` node within 5km,
  widening to 15km if nothing's found. Distance computed via haversine.
- **Ambulance number**: if the hospital has a phone number tagged in
  OpenStreetMap, the Call button dials that. If not, it falls back to
  India's national ambulance number (108) — the UI says so explicitly
  rather than silently guessing.
- **Directions**: opens Google Maps (or whatever maps app is
  installed) with turn-by-turn directions to the hospital, via a
  standard `https://www.google.com/maps/dir/...` URL — no map SDK or
  API key embedded in the app itself.
- **Network dependency**: Overpass API needs a live network connection
  at lookup time; if the phone is offline, this fails gracefully with
  a retry option rather than crashing.

## Embedded map + automatic hospital number (latest update)

- **Ambulance/hospital number is no longer manually entered.** The
  contact list now has one required field (Emergency contact) plus
  optional extras. The hospital/ambulance number comes entirely from
  the automatic nearest-hospital lookup and appears in the Nearby Help
  card's Call button — removing the earlier redundant manual field.
- **Embedded interactive map** (`lib/map_view.dart`): shows the
  helmet's last known position and the nearest hospital as pins on a
  real pannable/zoomable map, using `flutter_map` with OpenStreetMap
  tiles (dark CARTO basemap to match the app's theme). **No Google
  Maps or Apple MapKit SDK is used** — those need a billed API key
  (Google) or are iOS-only (Apple), which doesn't fit a free,
  cross-platform hackathon build. Swapping the tile layer for Google
  Maps later (via `google_maps_flutter`, needs a billing-enabled API
  key) wouldn't require restructuring anything else.
- **"Test with my location" button**: since no real helmet GPS exists
  yet, this uses the *phone's own* GPS (via `geolocator`) and writes
  it to the exact same Firebase path (`helmet_01/status/lat`/`lon`)
  the helmet's firmware will eventually write to. This exercises the
  entire real pipeline — location update → hospital lookup → map →
  call/directions — on a real address, without any hardware. Needs
  location permission (see manifest changes below).

### Additional Android permission needed
Add to `android/app/src/main/AndroidManifest.xml`, alongside the
existing `CALL_PHONE` permission:
```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

## Latest update: Google Maps, professional theme, ambulance-on-demand

### Google Maps (replaces the earlier OpenStreetMap version)
- Uses `google_maps_flutter` with a muted/desaturated map style
  (closer to Apollo 24|7/Practo's clean look than Google's default
  saturated palette).
- **Needs a Google Maps API key you create yourself** — Google Cloud
  requires your own billing account; this can't be provisioned on your
  behalf. See the setup steps in this chat, or
  https://developers.google.com/maps/documentation/android-sdk/get-api-key.
  Free tier ($200/month credit) comfortably covers hackathon usage.
- Key goes in `android/app/src/main/AndroidManifest.xml` as the
  `com.google.android.geo.API_KEY` meta-data value (placeholder
  already in place, marked clearly).
- For iOS, the key also needs adding to `ios/Runner/AppDelegate.swift`
  via `GMSServices.provideAPIKey("YOUR_KEY")` — not included in this
  patch since the iOS project folder isn't part of what's been shared;
  only needed if you actually build for iOS.

### Visual redesign
- Switched from a dark, gradient-heavy look to a light, neutral,
  professional palette (off-white background, medical blue primary,
  teal-green for status, red reserved only for emergency actions) —
  closer to Apollo/Practo-style health apps.
- Added a row of small stat pills under the title (online/offline
  status, contact count, currently-selected ambulance) — a lighter
  version of the stat-badge pattern from the dashboard reference image
  you shared, adapted for a mobile screen rather than a desktop
  analytics layout.
- Buttons flattened from pill/gradient shapes to solid rounded
  rectangles — more consistent with how health apps present primary
  actions.

### Ambulance number is no longer auto-filled
This was a real behavior change, not just UI: the ambulance/hospital
number used to auto-populate from the nearest hospital the moment one
was found. Now:
- The hospital card shows a **"Use" button** — tapping it explicitly
  sets that hospital as the ambulance contact (shown with a
  "Selected" badge and in the stat pill row).
- **Or**, if none was manually selected, triggering **Simulate SOS**
  auto-selects the nearest hospital (or 108 fallback) at that exact
  moment — matching "filled out only when a hospital is selected or a
  crash is detected."

### What Simulate SOS actually does now
On confirming the dialog, it:
1. Writes a test alert to Firebase (as before)
2. Opens the phone's dialer, pre-filled to the ambulance number
   (voice call — dialer opens, you still tap the green call button
   yourself; nothing dials automatically)
3. If an emergency contact is saved and a location fix exists, opens
   the SMS composer to that contact with a Google Maps link to the
   current location

**Honest limitation, on purpose**: it does **not** attempt to text the
ambulance number itself when that number is the national 108 line —
108 is a voice-only emergency service in India and generally can't
process an automated SMS. If a hospital has its own direct listed
number (not the 108 fallback), you could reasonably text that number
too, but this build only auto-texts the emergency contact to keep the
behavior simple and reliable across phones.

## Latest update: dashboard-style layout + debug address tool

### Layout restructured
- The map is now a single, large, prominent panel right under the
  status card (previously it was small and buried inside the hospital
  info card). Matches the "map as primary content" pattern from the
  reference dashboard image, adapted for a phone screen.
- Added a stat-pill row (online/offline, contact count, ambulance
  status) — a lightweight mobile version of the top-bar stat badges
  in that reference.
- Added an **Activity Log** panel at the bottom — a session-only,
  in-memory list of what happened (contacts saved, SOS simulated,
  ambulance selected, debug address tested), styled like a compact
  version of the reference's ledger/log table. Not persisted anywhere;
  clears on app restart.

### New: debug address tool
Type any address (e.g. "Connaught Place, Delhi") and tap Test — the
app geocodes it via the Google Geocoding API and simulates the helmet
being at that location, using the exact same Firebase path a real GPS
fix would use. Lets you test the map, hospital lookup, and ambulance
flow against any city without travelling or needing hardware.

**Needs a third API key** (Geocoding API), separate from the two Maps
keys. See setup steps in chat — unlike the Maps keys, this one uses
"Application restrictions: None" since it's called via raw HTTP, not
through a browser or native SDK; it's still safely scoped because
"API restrictions" locks it to Geocoding API only.

Set your key in `lib/main.dart`:
```dart
const String kGeocodingApiKey = 'YOUR_GEOCODING_API_KEY_HERE';
```

## Latest update: map camera fix + real auto-dial on SOS (with a safety boundary)

### Map camera bug fix
The map wasn't visually following new locations (from GPS test or the
debug address tool) — the marker was actually moving, but Google
Maps' Flutter plugin only respects `initialCameraPosition` once, on
first creation. It doesn't automatically re-center on rebuild. Fixed
by holding a `GoogleMapController` and explicitly calling
`animateCamera()` whenever the helmet or hospital coordinates change.

### Real auto-dial — deliberately scoped to Simulate SOS only
The ask was "call automatically when a hospital is found." Built
exactly that would have meant a real phone call firing every time the
**debug address tool** is used to test a random location — since that
tool works by writing a location fix, which triggers hospital
detection just like a real GPS fix would. That would mean testing the
app with a random address could place a real, unwanted call to a real
hospital or to **India's 108 emergency line**.

Instead:
- **Ordinary hospital detection** (GPS test button, debug address
  tool) stays purely informational. Never calls anything.
- **Simulate SOS** is the only place a real, unconfirmed call can
  happen — and even there, tapping "Simulate" starts a **visible
  5-second countdown with a Cancel button** before the call is
  actually placed. This mirrors how Apple's own Emergency SOS on
  iPhone works (hold → countdown → auto-calls unless stopped).
- If not cancelled, the app places a **real call** using
  `flutter_phone_direct_caller` (needs `CALL_PHONE` permission,
  already in the manifest) — not just opening the dialer. If that
  permission is denied or the direct call fails, it falls back to
  opening the dialer instead (same as before).

**Practical warning**: test this with your own phone number or a
real ambulance/hospital line you're authorized to test with — not
108 — unless you specifically intend to place a real call to it. The
in-app confirmation dialog says this explicitly too.
