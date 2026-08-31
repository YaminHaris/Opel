import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_helmet_service.dart';
import 'offline_queue.dart';
import 'hospital_finder.dart';
import 'map_view.dart';
import 'geocoding_service.dart';
import 'activity_log.dart';
import 'firebase_options.dart';

const String kHelmetId = 'helmet_01';
const int kMaxContacts = 5;

// Geocoding API key — separate from the Maps display key, restricted
// to the Geocoding API only. Used exclusively by the debug address
// tool below. Replace with your own key.
const String kGeocodingApiKey = 'YOUR_GEOCODING_API_KEY_HERE';

const bool kUseFirebaseEmulator =
    bool.fromEnvironment('USE_FIREBASE_EMULATOR', defaultValue: false);

// Neutral, professional health-app palette (Apollo/Practo-style):
// light off-white background, trustworthy medical blue as primary,
// teal-green for positive/status signals, warm red reserved strictly
// for emergency actions so it doesn't get diluted by overuse.
const _bgColor = Color(0xFFF7F8FA);
const _cardColor = Colors.white;
const _cardBorder = Color(0xFFE5E7EB);
const _inputFill = Color(0xFFF3F4F6);
const _primaryBlue = Color(0xFF0B5FA5);
const _primaryBlueDark = Color(0xFF08497F);
const _tealGreen = Color(0xFF0E9F6E);
const _emergencyRed = Color(0xFFDC2626);
const _warningAmber = Color(0xFFD97706);
const _textPrimary = Color(0xFF111827);
const _textSecondary = Color(0xFF6B7280);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (kUseFirebaseEmulator) {
    final host = defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : 'localhost';
    FirebaseDatabase.instance.useDatabaseEmulator(host, 9000);
  }

  runApp(const CompanionApp());
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseText = GoogleFonts.interTextTheme(ThemeData.light().textTheme);
    return MaterialApp(
      title: 'Helmet Guard',
      debugShowCheckedModeBanner: false,
      // Light, neutral theme by default — matches the clean, low-noise
      // look of health-app UIs (Apollo 24|7, Practo) rather than a
      // dark "tech gadget" aesthetic.
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: _bgColor,
        textTheme: baseText.apply(bodyColor: _textPrimary, displayColor: _textPrimary),
        colorScheme: ColorScheme.fromSeed(
          seedColor: _primaryBlue,
          brightness: Brightness.light,
          primary: _primaryBlue,
          surface: _cardColor,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: _bgColor,
          foregroundColor: _textPrimary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: GoogleFonts.inter(color: _textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _inputFill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _primaryBlue, width: 1.5),
          ),
          labelStyle: GoogleFonts.inter(color: _textSecondary, fontSize: 15),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        ),
      ),
      home: const ContactScreen(),
    );
  }
}

/// Formats digits as "XXXXX XXXXX" (Indian-style grouping) while typing,
/// preserving a leading + for country codes.
class _PhoneNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final hasPlus = newValue.text.startsWith('+');
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final capped = digits.length > 13 ? digits.substring(0, 13) : digits;

    String out = hasPlus ? '+' : '';
    if (hasPlus && capped.length > 2) {
      out += '${capped.substring(0, 2)} ';
      final rest = capped.substring(2);
      out += _group(rest);
    } else {
      out += _group(capped);
    }

    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: out.length),
    );
  }

  String _group(String digits) {
    if (digits.length <= 5) return digits;
    return '${digits.substring(0, 5)} ${digits.substring(5)}';
  }
}

class ContactEntry {
  final TextEditingController controller;
  String label;
  final IconData icon;
  final Color iconColor;
  final bool required;
  final bool removable;

  ContactEntry({
    required this.label,
    required this.icon,
    required this.iconColor,
    this.required = false,
    this.removable = true,
    String initialValue = '',
  }) : controller = TextEditingController(text: initialValue);
}

class ContactScreen extends StatefulWidget {
  final DatabaseReference? contactsRef;
  final DatabaseReference? statusRef;
  final DatabaseReference? alertsRef;

  const ContactScreen({super.key, this.contactsRef, this.statusRef, this.alertsRef});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _bleService = BleHelmetService();
  final _offlineQueue = OfflineQueueService();
  BleSyncStatus _bleStatus = BleSyncStatus.idle;
  StreamSubscription<BleSyncStatus>? _bleStatusSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  late final DatabaseReference _contactsRef;
  late final DatabaseReference _statusRef;
  late final DatabaseReference _alertsRef;

  final List<ContactEntry> _contacts = [];

  bool _loading = true;
  bool _saving = false;
  bool _sendingTest = false;
  bool _hasQueuedWrite = false;
  String? _loadError;
  int? _lastSeen;

  // Nearest-hospital lookup. Reads the helmet's last known GPS fix from
  // helmet_01/status/lat and helmet_01/status/lon. NOTE: no firmware
  // writes this path yet (see README) — this is built against the
  // assumed data shape so the GPS firmware side has a concrete target.
  double? _lastLat;
  double? _lastLon;
  Hospital? _nearestHospital;
  bool _findingHospital = false;
  String? _hospitalError;

  // Ambulance contact is intentionally NOT auto-filled just because a
  // nearby hospital was found. It's only set when the rider explicitly
  // taps "Use as ambulance contact" on a hospital, OR automatically at
  // the moment a crash/SOS is triggered (see _confirmAndSendTestAlert).
  String? _selectedAmbulanceNumber;
  String? _selectedAmbulanceLabel;

  // Local, session-only activity log — mirrors the ledger-style panel
  // from the reference dashboard, adapted for a mobile screen. Not
  // persisted anywhere; resets on app restart.
  final List<ActivityEntry> _activityLog = [];

  void _log(String message, {ActivityKind kind = ActivityKind.info}) {
    setState(() {
      _activityLog.insert(0, ActivityEntry(message: message, kind: kind));
      if (_activityLog.length > 30) _activityLog.removeLast();
    });
  }

  // Debug tool: type any address, geocode it, and simulate the helmet
  // being there — writes to the same Firebase path a real GPS fix
  // would use, so the whole pipeline (map, hospital lookup) can be
  // tested against any location without travelling or needing hardware.
  final _debugAddressController = TextEditingController();
  bool _testingAddress = false;

  @override
  void initState() {
    super.initState();
    _contacts.add(ContactEntry(
      label: 'Emergency contact',
      icon: CupertinoIcons.phone_fill,
      iconColor: _emergencyRed,
      required: true,
      removable: false,
    ));
    // No manual "Ambulance / hospital" field anymore — that number now
    // comes automatically from the nearest-hospital lookup below.

    _bleStatusSub = _bleService.statusStream.listen((status) {
      setState(() => _bleStatus = status);
    });

    _contactsRef = widget.contactsRef ?? FirebaseDatabase.instance.ref('$kHelmetId/contacts');
    _statusRef = widget.statusRef ?? FirebaseDatabase.instance.ref('$kHelmetId/status');
    _alertsRef = widget.alertsRef ?? FirebaseDatabase.instance.ref('$kHelmetId/alerts/latest');

    _loadExisting();
    _listenToStatus();
    _listenToLocation();
    _checkQueuedWrite();

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online) _flushQueueIfAny();
    });
  }

  Future<void> _checkQueuedWrite() async {
    final pending = await _offlineQueue.peek();
    if (mounted) setState(() => _hasQueuedWrite = pending != null);
  }

  Future<void> _flushQueueIfAny() async {
    final flushed = await _offlineQueue.tryFlush(_contactsRef);
    if (flushed && mounted) {
      setState(() => _hasQueuedWrite = false);
      _showBanner('Queued contacts synced now that you\'re back online');
    }
  }

  Future<void> _loadExisting() async {
    try {
      final snapshot = await _contactsRef.get();
      if (snapshot.exists) {
        final raw = snapshot.value;
        List<String> values = [];
        if (raw is List) {
          values = raw.map((e) => (e ?? '').toString()).toList();
        } else if (raw is Map) {
          final data = Map<dynamic, dynamic>.from(raw);
          final keys = data.keys.map((k) => int.tryParse(k.toString()) ?? 0).toList()..sort();
          values = keys.map((k) => (data[k.toString()] ?? data[k] ?? '').toString()).toList();
        }

        if (values.isNotEmpty) _contacts[0].controller.text = values[0];
        for (var i = 1; i < values.length && i < kMaxContacts; i++) {
          _contacts.add(ContactEntry(
            label: 'Contact ${i + 1}',
            icon: CupertinoIcons.person_fill,
            iconColor: _textSecondary,
            initialValue: values[i],
          ));
        }
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = 'Could not load current contacts';
      });
    }
  }

  void _listenToStatus() {
    _statusRef.child('last_seen').onValue.listen((event) {
      if (event.snapshot.exists) {
        setState(() => _lastSeen = event.snapshot.value as int?);
      }
    }, onError: (_) {});
  }

  void _listenToLocation() {
    _statusRef.onValue.listen((event) {
      if (!event.snapshot.exists) return;
      final raw = event.snapshot.value;
      if (raw is! Map) return;
      final data = Map<dynamic, dynamic>.from(raw);
      final lat = (data['lat'] as num?)?.toDouble();
      final lon = (data['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      // Only re-look-up if the fix actually moved meaningfully, so we
      // don't hammer the Overpass API on every minor GPS jitter.
      final moved = _lastLat == null || (lat - _lastLat!).abs() > 0.002 || (lon - _lastLon!).abs() > 0.002;
      _lastLat = lat;
      _lastLon = lon;
      if (moved && mounted) _lookUpNearestHospital();
    }, onError: (_) {});
  }

  Future<void> _lookUpNearestHospital() async {
    if (_lastLat == null || _lastLon == null) return;
    setState(() {
      _findingHospital = true;
      _hospitalError = null;
    });
    try {
      final hospital = await findNearestHospital(_lastLat!, _lastLon!);
      if (!mounted) return;
      setState(() {
        _nearestHospital = hospital;
        _findingHospital = false;
        if (hospital == null) _hospitalError = 'No hospitals found nearby';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _findingHospital = false;
        _hospitalError = 'Hospital lookup failed';
      });
    }
  }

  void _selectAmbulanceContact(Hospital h) {
    setState(() {
      _selectedAmbulanceNumber = h.callNumber;
      _selectedAmbulanceLabel = h.hasDirectHospitalNumber ? h.name : '${h.name} (via 108)';
    });
    HapticFeedback.selectionClick();
    _showBanner('${h.name} set as ambulance contact');
    _log('Ambulance contact set: ${h.name}', kind: ActivityKind.success);
  }

  Future<void> _openDirections(Hospital h) async {
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${h.lat},${h.lon}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showBanner('Could not open maps', isError: true);
    }
  }

  bool _simulatingGps = false;

  /// Testing aid: no real helmet GPS exists yet (see README), so this
  /// grabs the *phone's own* current location via the device's GPS and
  /// writes it to the exact same Firebase path the helmet's firmware
  /// will eventually write to (helmet_01/status/lat, lon). This lets
  /// the whole pipeline — location update, hospital lookup, map,
  /// call/directions — be tested for real, on a real address, without
  /// any hardware.
  Future<void> _simulateGpsFromPhone() async {
    setState(() => _simulatingGps = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _showBanner('Location permission denied — enable it to test', isError: true);
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showBanner('Turn on location services to test this', isError: true);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );

      await _statusRef.update({
        'lat': position.latitude,
        'lon': position.longitude,
      });
      _showBanner('Using your phone\'s location as a test GPS fix');
      _log('Simulated GPS from phone (${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)})', kind: ActivityKind.info);
      // _listenToLocation() picks this up automatically via the Firebase
      // listener already in place — no extra call needed here.
    } catch (e) {
      _showBanner('Could not get your location: $e', isError: true);
    } finally {
      if (mounted) setState(() => _simulatingGps = false);
    }
  }

  Future<void> _testDebugAddress() async {
    final address = _debugAddressController.text.trim();
    if (address.isEmpty) return;
    if (kGeocodingApiKey == 'YOUR_GEOCODING_API_KEY_HERE') {
      _showBanner('Add your Geocoding API key in main.dart first', isError: true);
      return;
    }

    setState(() => _testingAddress = true);
    try {
      final result = await geocodeAddress(address, kGeocodingApiKey);
      if (result == null) {
        _showBanner('No location found for "$address"', isError: true);
        _log('Address lookup failed: "$address" — no results', kind: ActivityKind.warning);
        return;
      }
      await _statusRef.update({'lat': result.lat, 'lon': result.lon});
      _showBanner('Simulating helmet at: ${result.formattedAddress}');
      _log('Debug address set: ${result.formattedAddress}', kind: ActivityKind.info);
    } catch (e) {
      _showBanner('Address lookup failed: $e', isError: true);
      _log('Address lookup error: $e', kind: ActivityKind.warning);
    } finally {
      if (mounted) setState(() => _testingAddress = false);
    }
  }

  bool get _isOnline =>
      _lastSeen != null &&
      DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(_lastSeen!)) < const Duration(minutes: 2);

  String? _validatePhone(String? value, {required bool required}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return required ? 'Required' : null;
    final digitsOnly = v.replaceAll(RegExp(r'[^0-9]'), '');
    final core = digitsOnly.length > 10 ? digitsOnly.substring(digitsOnly.length - 10) : digitsOnly;
    if (core.length != 10) return 'Enter a valid 10-digit number';
    return null;
  }

  /// Cross-field check: same number entered in two slots. Returns the
  /// index pair as an error message, or null if no duplicates.
  String? _findDuplicate() {
    final normalized = _contacts
        .map((c) => c.controller.text.replaceAll(RegExp(r'[^0-9]'), ''))
        .toList();
    for (var i = 0; i < normalized.length; i++) {
      if (normalized[i].isEmpty) continue;
      for (var j = i + 1; j < normalized.length; j++) {
        if (normalized[i] == normalized[j]) {
          return '${_contacts[i].label} and ${_contacts[j].label} have the same number';
        }
      }
    }
    return null;
  }

  void _showBanner(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(isError ? CupertinoIcons.exclamationmark_circle_fill : CupertinoIcons.checkmark_circle_fill,
                color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500))),
          ],
        ),
        backgroundColor: isError ? _emergencyRed : _tealGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _callNumber(String raw) async {
    final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: digits);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _showBanner('Could not open dialer', isError: true);
    }
  }

  /// Opens the phone's own SMS composer as a way to confirm a number is
  /// real and reachable. NOTE: this sends from the rider's own phone —
  /// it does not go through the helmet's SIM800L, which doesn't have
  /// firmware for this yet. Labelled clearly in the UI for that reason.
  Future<void> _sendTestText(String raw) async {
    final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    final uri = Uri(
      scheme: 'sms',
      path: digits,
      queryParameters: {'body': 'Test message from Helmet Guard — confirming this number is reachable.'},
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _showBanner('Could not open messages', isError: true);
    }
  }

  Future<void> _syncViaBluetooth() async {
    if (!_formKey.currentState!.validate()) return;
    final dup = _findDuplicate();
    if (dup != null) {
      _showBanner(dup, isError: true);
      return;
    }
    HapticFeedback.selectionClick();
    final connected = await _bleService.connect();
    if (!connected) {
      _showBanner(_bleService.lastError ?? 'Bluetooth connection failed', isError: true);
      return;
    }
    // BLE contract still exposes two characteristics (emergency +
    // ambulance). Ambulance is only populated if the rider explicitly
    // selected a hospital, or a crash/SOS already set it — never
    // auto-filled just because a nearby hospital was found.
    final wrote = await _bleService.writeContacts(
      emergency: _contacts[0].controller.text.trim(),
      ambulance: _selectedAmbulanceNumber ?? '',
    );
    await _bleService.disconnect();
    if (wrote) {
      HapticFeedback.lightImpact();
      _showBanner('Synced via Bluetooth (emergency contact + nearest hospital)');
    } else {
      _showBanner(_bleService.lastError ?? 'Bluetooth sync failed', isError: true);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final dup = _findDuplicate();
    if (dup != null) {
      _showBanner(dup, isError: true);
      return;
    }

    HapticFeedback.selectionClick();
    setState(() => _saving = true);
    final values = _contacts.map((c) => c.controller.text.trim()).toList();

    try {
      await _contactsRef.set(values);
      HapticFeedback.lightImpact();
      _showBanner('Saved — syncing to helmet');
      _log('Contacts saved (${values.length})', kind: ActivityKind.success);
      await _offlineQueue.clear();
      if (mounted) setState(() => _hasQueuedWrite = false);
    } catch (e) {
      // Likely offline — queue locally instead of just failing silently.
      await _offlineQueue.queue(values);
      _log('Save failed — queued offline', kind: ActivityKind.warning);
      if (mounted) setState(() => _hasQueuedWrite = true);
      _showBanner('Offline — saved locally, will sync automatically', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Opens the SMS composer to the emergency contact with a Google Maps
  /// link to the given coordinates. Like _sendTestText, this requires
  /// the rider to tap Send themselves — nothing is sent silently.
  Future<void> _sendLocationText(String toNumber, double lat, double lon) async {
    final digits = toNumber.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.isEmpty) return;
    final mapsLink = 'https://maps.google.com/?q=$lat,$lon';
    final uri = Uri(
      scheme: 'sms',
      path: digits,
      queryParameters: {'body': 'Helmet Guard SOS: crash detected. My last known location: $mapsLink'},
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Timer? _sosCountdownTimer;

  Future<void> _confirmAndSendTestAlert() async {
    final ambulanceNumber = _selectedAmbulanceNumber ?? _nearestHospital?.callNumber ?? kFallbackAmbulanceNumber;
    final hasEmergencyContact = _contacts.isNotEmpty && _contacts[0].controller.text.trim().isNotEmpty;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Simulate a crash?'),
        content: Text(
          'This writes a test alert to the dashboard, then starts a 5-second countdown. '
          'If you don\'t cancel it, the app will actually call $ambulanceNumber and '
          '${hasEmergencyContact ? "text your emergency contact your current location." : "would text your emergency contact, but none is saved yet."}\n\n'
          'This places a REAL call — use a real ambulance/hospital number or your own test number, not 108, unless you mean it.',
        ),
        actions: [
          CupertinoDialogAction(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx, false)),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: const Text('Simulate'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _sendingTest = true);
    try {
      await _alertsRef.set({
        'type': 'test',
        'triggered_at': ServerValue.timestamp,
        'source': 'companion_app',
        'ambulance_dialed': ambulanceNumber,
      });

      // Ambulance contact is filled at the moment of the crash if the
      // rider hadn't already picked one — matches the "only filled on
      // selection or crash" rule.
      if (_selectedAmbulanceNumber == null && _nearestHospital != null) {
        setState(() {
          _selectedAmbulanceNumber = _nearestHospital!.callNumber;
          _selectedAmbulanceLabel = _nearestHospital!.hasDirectHospitalNumber
              ? _nearestHospital!.name
              : '${_nearestHospital!.name} (via 108)';
        });
      }

      _log('SOS confirmed — auto-call countdown started', kind: ActivityKind.danger);
      final proceed = await _showAutoCallCountdown(ambulanceNumber);

      if (!proceed) {
        _showBanner('Auto-call cancelled');
        _log('Auto-call cancelled by rider', kind: ActivityKind.warning);
        return;
      }

      HapticFeedback.heavyImpact();
      final permission = await Permission.phone.request();
      if (!permission.isGranted) {
        _showBanner('Phone permission denied — opening dialer instead', isError: true);
        await _callNumber(ambulanceNumber);
      } else {
        final placed = await FlutterPhoneDirectCaller.callNumber(ambulanceNumber);
        if (placed != true) {
          _showBanner('Auto-call failed — opening dialer instead', isError: true);
          await _callNumber(ambulanceNumber);
        }
      }

      if (hasEmergencyContact && _lastLat != null && _lastLon != null) {
        await _sendLocationText(_contacts[0].controller.text.trim(), _lastLat!, _lastLon!);
      }

      _showBanner('Ambulance called automatically');
      _log('Auto-called $ambulanceNumber', kind: ActivityKind.danger);
    } catch (e) {
      _showBanner('Could not complete the SOS flow — check connection', isError: true);
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  /// Shows a non-dismissible countdown with a Cancel button. Returns
  /// true if the countdown ran to completion (proceed with the real
  /// call), false if the rider tapped Cancel.
  Future<bool> _showAutoCallCountdown(String ambulanceNumber) async {
    int secondsLeft = 5;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            _sosCountdownTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
              secondsLeft--;
              if (secondsLeft <= 0) {
                timer.cancel();
                _sosCountdownTimer = null;
                Navigator.of(ctx).pop(true);
              } else {
                setDialogState(() {});
              }
            });
            return CupertinoAlertDialog(
              title: const Text('Calling ambulance'),
              content: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$secondsLeft',
                      style: GoogleFonts.inter(fontSize: 40, fontWeight: FontWeight.w800, color: _emergencyRed),
                    ),
                    const SizedBox(height: 6),
                    Text('Calling $ambulanceNumber unless cancelled', style: GoogleFonts.inter(fontSize: 13)),
                  ],
                ),
              ),
              actions: [
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  child: const Text('Cancel'),
                  onPressed: () {
                    _sosCountdownTimer?.cancel();
                    _sosCountdownTimer = null;
                    Navigator.of(ctx).pop(false);
                  },
                ),
              ],
            );
          },
        );
      },
    );
    return result ?? false;
  }

  void _addContact() {
    if (_contacts.length >= kMaxContacts) {
      _showBanner('Maximum $kMaxContacts contacts', isError: true);
      return;
    }
    setState(() {
      _contacts.add(ContactEntry(
        label: 'Contact ${_contacts.length + 1}',
        icon: CupertinoIcons.person_fill,
        iconColor: _textSecondary,
      ));
    });
  }

  void _removeContact(int index) {
    setState(() {
      _contacts[index].controller.dispose();
      _contacts.removeAt(index);
      for (var i = 2; i < _contacts.length; i++) {
        if (_contacts[i].removable) _contacts[i].label = 'Contact ${i + 1}';
      }
    });
  }

  @override
  void dispose() {
    for (final c in _contacts) {
      c.controller.dispose();
    }
    _bleStatusSub?.cancel();
    _connSub?.cancel();
    _bleService.dispose();
    _debugAddressController.dispose();
    _sosCountdownTimer?.cancel();
    super.dispose();
  }

  bool get _bleBusy =>
      _bleStatus == BleSyncStatus.scanning ||
      _bleStatus == BleSyncStatus.connecting ||
      _bleStatus == BleSyncStatus.writing;

  String _bleLabel() {
    switch (_bleStatus) {
      case BleSyncStatus.scanning:
        return 'Scanning…';
      case BleSyncStatus.connecting:
        return 'Connecting…';
      case BleSyncStatus.writing:
        return 'Syncing…';
      default:
        return 'Sync via Bluetooth';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CupertinoActivityIndicator(radius: 14))
          : SafeArea(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        'Helmet Guard',
                        style: GoogleFonts.inter(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: _textPrimary),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _StatPill(
                            label: _isOnline ? 'Online' : 'Offline',
                            color: _isOnline ? _tealGreen : _textSecondary,
                            dot: true,
                          ),
                          _StatPill(label: '${_contacts.length} contact${_contacts.length == 1 ? '' : 's'}', color: _primaryBlue),
                          if (_selectedAmbulanceLabel != null)
                            _StatPill(label: 'Ambulance: $_selectedAmbulanceLabel', color: _emergencyRed),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    sliver: SliverToBoxAdapter(child: _HeroStatusCard(online: _isOnline, lastSeen: _lastSeen)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Text('LIVE MAP', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverToBoxAdapter(
                      child: Container(
                        decoration: BoxDecoration(
                          color: _cardColor,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _cardBorder),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: (_lastLat != null && _lastLon != null)
                            ? HelmetMapCard(
                                helmetLat: _lastLat!,
                                helmetLon: _lastLon!,
                                hospitalLat: _nearestHospital?.lat,
                                hospitalLon: _nearestHospital?.lon,
                                height: 260,
                                statusLabel: _isOnline ? 'LIVE' : (_lastSeen != null ? 'LAST FIX' : 'LIVE'),
                              )
                            : _MapPlaceholder(),
                      ),
                    ),
                  ),
                  if (_loadError != null)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: _InlineNotice(text: _loadError!, color: _emergencyRed, icon: CupertinoIcons.wifi_slash),
                      ),
                    ),
                  if (_hasQueuedWrite)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: _InlineNotice(
                          text: 'A save is queued and will sync once you\'re back online',
                          color: _warningAmber,
                          icon: CupertinoIcons.clock_fill,
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('EMERGENCY CONTACTS',
                              style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                          if (_contacts.length < kMaxContacts)
                            GestureDetector(
                              onTap: _addContact,
                              child: Row(
                                children: [
                                  const Icon(CupertinoIcons.add_circled_solid, color: _primaryBlue, size: 16),
                                  const SizedBox(width: 4),
                                  Text('Add', style: GoogleFonts.inter(color: _primaryBlue, fontSize: 13, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverToBoxAdapter(
                      child: Form(
                        key: _formKey,
                        child: _SoftCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var i = 0; i < _contacts.length; i++) ...[
                                if (i > 0) const SizedBox(height: 12),
                                _ContactRow(
                                  entry: _contacts[i],
                                  formatter: _PhoneNumberFormatter(),
                                  validator: (v) => _validatePhone(v, required: _contacts[i].required),
                                  onCall: () => _callNumber(_contacts[i].controller.text),
                                  onTestText: () => _sendTestText(_contacts[i].controller.text),
                                  onRemove: _contacts[i].removable ? () => _removeContact(i) : null,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: _GradientPillButton(
                        label: _saving ? 'Saving…' : 'Save to Helmet',
                        icon: CupertinoIcons.cloud_upload_fill,
                        busy: _saving,
                        onTap: _saving ? null : _save,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: _OutlinePillButton(
                        label: _bleLabel(),
                        icon: CupertinoIcons.antenna_radiowaves_left_right,
                        busy: _bleBusy,
                        onTap: _bleBusy ? null : _syncViaBluetooth,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('NEARBY HELP', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                          GestureDetector(
                            onTap: _simulatingGps ? null : _simulateGpsFromPhone,
                            child: Row(
                              children: [
                                _simulatingGps
                                    ? const SizedBox(width: 12, height: 12, child: CupertinoActivityIndicator(radius: 6))
                                    : const Icon(CupertinoIcons.location_circle, color: _primaryBlue, size: 15),
                                const SizedBox(width: 4),
                                Text('Test with my location', style: GoogleFonts.inter(color: _primaryBlue, fontSize: 12.5, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverToBoxAdapter(
                      child: _NearestHospitalCard(
                        lat: _lastLat,
                        lon: _lastLon,
                        hospital: _nearestHospital,
                        loading: _findingHospital,
                        error: _hospitalError,
                        onCall: (number) => _callNumber(number),
                        onDirections: _openDirections,
                        onRetry: _lookUpNearestHospital,
                        onSelectAsAmbulance: _selectAmbulanceContact,
                        isSelected: _nearestHospital != null && _selectedAmbulanceNumber == _nearestHospital!.callNumber,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text('DEMO', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: _OutlinePillButton(
                        label: _sendingTest ? 'Sending…' : 'Simulate SOS',
                        icon: CupertinoIcons.exclamationmark_triangle_fill,
                        busy: _sendingTest,
                        accentColor: _emergencyRed,
                        onTap: _sendingTest ? null : _confirmAndSendTestAlert,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    sliver: SliverToBoxAdapter(
                      child: Center(
                        child: Text(
                          'Numbers are used automatically if a crash is detected.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(fontSize: 12, color: _textSecondary),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Text('DEBUG', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverToBoxAdapter(
                      child: _SoftCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Test with any address',
                              style: GoogleFonts.inter(color: _textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Simulates the helmet being at this address — useful for testing without travelling or hardware.',
                              style: GoogleFonts.inter(color: _textSecondary, fontSize: 11.5),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _debugAddressController,
                                    style: GoogleFonts.inter(fontSize: 14, color: _textPrimary),
                                    decoration: const InputDecoration(
                                      hintText: 'e.g. Connaught Place, Delhi',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                    ),
                                    onSubmitted: (_) => _testDebugAddress(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _SmallActionButton(
                                  icon: CupertinoIcons.location_solid,
                                  label: _testingAddress ? '...' : 'Test',
                                  color: _primaryBlue,
                                  onTap: _testingAddress ? () {} : _testDebugAddress,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
                    sliver: SliverToBoxAdapter(
                      child: Text('ACTIVITY LOG', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: _textSecondary)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    sliver: SliverToBoxAdapter(
                      child: _ActivityLogCard(entries: _activityLog),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final ContactEntry entry;
  final TextInputFormatter formatter;
  final String? Function(String?) validator;
  final VoidCallback onCall;
  final VoidCallback onTestText;
  final VoidCallback? onRemove;

  const _ContactRow({
    required this.entry,
    required this.formatter,
    required this.validator,
    required this.onCall,
    required this.onTestText,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: entry.controller,
            keyboardType: TextInputType.phone,
            inputFormatters: [formatter],
            style: GoogleFonts.inter(fontSize: 16, color: _textPrimary),
            decoration: InputDecoration(
              labelText: entry.label,
              hintText: '+91 XXXXX XXXXX',
              prefixIcon: Icon(entry.icon, color: entry.iconColor, size: 20),
            ),
            validator: validator,
          ),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            children: [
              Row(
                children: [
                  _MiniIconButton(icon: CupertinoIcons.phone_fill, color: _tealGreen, onTap: onCall),
                  const SizedBox(width: 4),
                  _MiniIconButton(icon: CupertinoIcons.chat_bubble_fill, color: _primaryBlue, onTap: onTestText),
                  if (onRemove != null) ...[
                    const SizedBox(width: 4),
                    _MiniIconButton(icon: CupertinoIcons.minus_circle_fill, color: _emergencyRed, onTap: onRemove!),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _MiniIconButton({required this.icon, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
          child: Icon(icon, color: color, size: 16),
        ),
      ),
    );
  }
}

class _HeroStatusCard extends StatelessWidget {
  final bool online;
  final int? lastSeen;

  const _HeroStatusCard({required this.online, required this.lastSeen});

  @override
  Widget build(BuildContext context) {
    final statusText = online
        ? 'Connected'
        : lastSeen != null
            ? 'Last synced ${_relativeTime(lastSeen!)}'
            : 'Not yet connected';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: _primaryBlue,
      ),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), shape: BoxShape.circle),
            child: const Icon(CupertinoIcons.shield_fill, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(kHelmetId, style: GoogleFonts.inter(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: online ? Colors.white : Colors.white.withOpacity(0.5), shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text(statusText, style: GoogleFonts.inter(color: Colors.white.withOpacity(0.9), fontSize: 13)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _relativeTime(int millis) {
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _ActivityLogCard extends StatelessWidget {
  final List<ActivityEntry> entries;
  const _ActivityLogCard({required this.entries});

  Color _colorFor(ActivityKind kind) {
    switch (kind) {
      case ActivityKind.success:
        return _tealGreen;
      case ActivityKind.warning:
        return _warningAmber;
      case ActivityKind.danger:
        return _emergencyRed;
      case ActivityKind.info:
        return _primaryBlue;
    }
  }

  String _statusLabelFor(ActivityKind kind) {
    switch (kind) {
      case ActivityKind.success:
        return 'DONE';
      case ActivityKind.warning:
        return 'WARN';
      case ActivityKind.danger:
        return 'ALERT';
      case ActivityKind.info:
        return 'INFO';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _cardBorder),
        ),
        padding: const EdgeInsets.all(16),
        child: Text('No activity yet this session.', style: GoogleFonts.inter(color: _textSecondary, fontSize: 12.5)),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row — mirrors the column-header style of the
          // reference dashboard's ledger table.
          Container(
            color: const Color(0xFFF3F4F6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                SizedBox(width: 62, child: Text('TIME', style: _headerStyle())),
                const SizedBox(width: 14),
                Expanded(child: Text('EVENT', style: _headerStyle())),
                Text('STATUS', style: _headerStyle()),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: entries.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: _cardBorder),
              itemBuilder: (context, i) {
                final e = entries[i];
                final color = _colorFor(e.kind);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 62,
                        child: Text(e.timeLabel, style: GoogleFonts.robotoMono(fontSize: 10.5, color: _textSecondary)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          e.message,
                          style: GoogleFonts.inter(fontSize: 12.5, color: _textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                        child: Text(
                          _statusLabelFor(e.kind),
                          style: GoogleFonts.robotoMono(fontSize: 9.5, fontWeight: FontWeight.w600, color: color),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _headerStyle() => GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: _textSecondary);
}

class _MapPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFEFF1F4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.map, color: _textSecondary, size: 32),
          const SizedBox(height: 8),
          Text(
            'No location fix yet',
            style: GoogleFonts.inter(color: _textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 2),
          Text(
            'Use the debug tools below to test with an address or your own location',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(color: _textSecondary, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool dot;

  const _StatPill({required this.label, required this.color, this.dot = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Text(label, style: GoogleFonts.inter(color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SoftCard extends StatelessWidget {
  final Widget child;
  const _SoftCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      child: child,
    );
  }
}

class _InlineNotice extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  const _InlineNotice({required this.text, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: GoogleFonts.inter(color: color, fontSize: 13, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }
}

class _GradientPillButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onTap;

  const _GradientPillButton({required this.label, required this.icon, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: onTap == null ? const Color(0xFFD1D5DB) : _primaryBlue,
          ),
          child: Center(
            child: busy
                ? const CupertinoActivityIndicator(color: Colors.white)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 19),
                      const SizedBox(width: 8),
                      Text(label, style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _NearestHospitalCard extends StatelessWidget {
  final double? lat;
  final double? lon;
  final Hospital? hospital;
  final bool loading;
  final String? error;
  final void Function(String number) onCall;
  final void Function(Hospital h) onDirections;
  final VoidCallback onRetry;
  final void Function(Hospital h) onSelectAsAmbulance;
  final bool isSelected;

  const _NearestHospitalCard({
    required this.lat,
    required this.lon,
    required this.hospital,
    required this.loading,
    required this.error,
    required this.onCall,
    required this.onDirections,
    required this.onRetry,
    required this.onSelectAsAmbulance,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (lat == null || lon == null) {
      return _SoftCard(
        child: Row(
          children: [
            const Icon(CupertinoIcons.location_slash, color: _textSecondary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No location data from the helmet yet — the nearest hospital will show up here once a GPS fix comes in.',
                style: GoogleFonts.inter(color: _textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    if (loading) {
      return _SoftCard(
        child: Row(
          children: [
            const CupertinoActivityIndicator(color: _primaryBlue),
            const SizedBox(width: 12),
            Text('Finding nearest hospital…', style: GoogleFonts.inter(color: _textSecondary, fontSize: 14)),
          ],
        ),
      );
    }

    if (error != null || hospital == null) {
      return _SoftCard(
        child: Row(
          children: [
            const Icon(CupertinoIcons.exclamationmark_triangle, color: _warningAmber, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(error ?? 'No hospitals found nearby', style: GoogleFonts.inter(color: _textSecondary, fontSize: 13))),
            GestureDetector(
              onTap: onRetry,
              child: Text('Retry', style: GoogleFonts.inter(color: _primaryBlue, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
    }

    final h = hospital!;
    return _SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: _tealGreen.withOpacity(0.15), shape: BoxShape.circle),
                child: const Icon(CupertinoIcons.building_2_fill, color: _tealGreen, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.name, style: GoogleFonts.inter(color: _textPrimary, fontSize: 15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${h.distanceKm.toStringAsFixed(1)} km away', style: GoogleFonts.inter(color: _textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              if (isSelected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: _tealGreen.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.checkmark_circle_fill, color: _tealGreen, size: 13),
                      const SizedBox(width: 4),
                      Text('Selected', style: GoogleFonts.inter(color: _tealGreen, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
          if (!h.hasDirectHospitalNumber) ...[
            const SizedBox(height: 10),
            Text(
              'No listed number for this hospital — Call and ambulance-select will use the national line (108) instead.',
              style: GoogleFonts.inter(color: _textSecondary, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _SmallActionButton(
                  icon: CupertinoIcons.phone_fill,
                  label: 'Call',
                  color: _tealGreen,
                  onTap: () => onCall(h.callNumber),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SmallActionButton(
                  icon: CupertinoIcons.location_fill,
                  label: 'Directions',
                  color: _primaryBlue,
                  onTap: () => onDirections(h),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SmallActionButton(
                  icon: isSelected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.add_circled,
                  label: isSelected ? 'Selected' : 'Use',
                  color: isSelected ? _tealGreen : _warningAmber,
                  onTap: isSelected ? () {} : () => onSelectAsAmbulance(h),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _SmallActionButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 42,
          decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(label, style: GoogleFonts.inter(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinePillButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onTap;
  final Color accentColor;

  const _OutlinePillButton({required this.label, required this.icon, required this.busy, required this.onTap, this.accentColor = _primaryBlue});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _cardColor,
            border: Border.all(color: _cardBorder),
          ),
          child: Center(
            child: busy
                ? CupertinoActivityIndicator(color: accentColor)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: accentColor, size: 19),
                      const SizedBox(width: 8),
                      Text(label, style: GoogleFonts.inter(color: _textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
