import 'dart:async';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'ble_helmet_service.dart';

import 'firebase_options.dart';

// Change this if you scale beyond one helmet (see spec section 4).
const String kHelmetId = 'helmet_01';

/// Set via --dart-define=USE_FIREBASE_EMULATOR=true so integration tests
/// never touch production Firebase data.
const bool kUseFirebaseEmulator =
    bool.fromEnvironment('USE_FIREBASE_EMULATOR', defaultValue: false);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (kUseFirebaseEmulator) {
    // 10.0.2.2 is the special alias Android emulators use to reach the
    // host machine's localhost. Real devices need your PC's LAN IP instead.
    final host = defaultTargetPlatform == TargetPlatform.android
        ? '10.0.2.2'
        : 'localhost';
    FirebaseDatabase.instance.useDatabaseEmulator(host, 9000);
  }

  runApp(const CompanionApp());
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Helmet Contacts',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        useMaterial3: true,
      ),
      home: const ContactScreen(),
    );
  }
}

/// Single screen: contact fields + save button + read-only status.
/// Deliberately no settings screen, no alerts-view screen (spec section 6).
class ContactScreen extends StatefulWidget {
  /// Injectable for testing. In the real app, leave both null and the
  /// screen builds its own refs against helmet_01 as before.
  final DatabaseReference? contactsRef;
  final DatabaseReference? statusRef;

  const ContactScreen({super.key, this.contactsRef, this.statusRef});

  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emergencyController = TextEditingController();
  final _ambulanceController = TextEditingController();
  final _bleService = BleHelmetService();
  BleSyncStatus _bleStatus = BleSyncStatus.idle;
  StreamSubscription<BleSyncStatus>? _bleStatusSub;

  String _bleLabel() {
    switch (_bleStatus) {
      case BleSyncStatus.scanning:
        return 'Scanning for helmet...';
      case BleSyncStatus.connecting:
        return 'Connecting...';
      case BleSyncStatus.writing:
        return 'Syncing...';
      default:
        return 'Sync via Bluetooth';
    }
  }

  late final DatabaseReference _contactsRef;
  late final DatabaseReference _statusRef;

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _saveMessage;
  int? _lastSeen;

  @override
  void initState() {
    super.initState();
    _bleStatusSub = _bleService.statusStream.listen((status) {
      setState(() => _bleStatus = status);
    });
    _contactsRef = widget.contactsRef ??
        FirebaseDatabase.instance.ref('$kHelmetId/contacts');
    _statusRef =
        widget.statusRef ?? FirebaseDatabase.instance.ref('$kHelmetId/status');
    _loadExisting();
    _listenToStatus();
  }

  Future<void> _loadExisting() async {
    try {
      final snapshot = await _contactsRef.get();
      if (snapshot.exists) {
        final raw = snapshot.value;
        String at(int index) {
          if (raw is List) {
            if (index < raw.length && raw[index] != null) {
              return raw[index].toString();
            }
            return '';
          }
          if (raw is Map) {
            final data = Map<dynamic, dynamic>.from(raw);
            return (data[index.toString()] ?? data[index] ?? '').toString();
          }
          return '';
        }

        _emergencyController.text = at(0);
        _ambulanceController.text = at(1);
      }
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = 'Could not load current contacts from Firebase: $e';
      });
    }
  }

  void _listenToStatus() {
    _statusRef.child('last_seen').onValue.listen((event) {
      if (event.snapshot.exists) {
        setState(() => _lastSeen = event.snapshot.value as int?);
      }
    }, onError: (_) {
      // Status is a nice-to-have per spec section 5; a listener error
      // shouldn't block the core save flow.
    });
  }

  /// 10-digit number, optionally prefixed with a country code (spec 6:
  /// "don't let a malformed number reach the ESP32 and silently fail
  /// an SMS send at crash time").
  String? _validatePhone(String? value, {required bool required}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return required ? 'Required' : null;
    }
    final digitsOnly = v.replaceAll(RegExp(r'[^0-9]'), '');
    final core = digitsOnly.length > 10
        ? digitsOnly.substring(digitsOnly.length - 10)
        : digitsOnly;
    if (core.length != 10) {
      return 'Enter a valid 10-digit number';
    }
    if (!RegExp(r'^\+?[0-9]{10,15}$').hasMatch(v)) {
      return 'Digits only, optional leading +country code';
    }
    return null;
  }

  Future<void> _syncViaBluetooth() async {
    if (!_formKey.currentState!.validate()) return;

    final connected = await _bleService.connect();
    if (!connected) {
      setState(() => _saveMessage =
          _bleService.lastError ?? 'Bluetooth connection failed');
      return;
    }

    final wrote = await _bleService.writeContacts(
      emergency: _emergencyController.text.trim(),
      ambulance: _ambulanceController.text.trim(),
    );

    await _bleService.disconnect();

    setState(() {
      _saveMessage = wrote
          ? 'Synced directly to helmet via Bluetooth.'
          : (_bleService.lastError ?? 'Bluetooth sync failed');
    });
  }

  Future<void> _save() async {
    setState(() => _saveMessage = null);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      await _contactsRef.update({
        '0': _emergencyController.text.trim(),
        '1': _ambulanceController.text.trim(),
      });
      setState(() => _saveMessage = 'Saved. Helmet will sync within ~15s.');
    } catch (e) {
      setState(
          () => _saveMessage = 'Save failed — not written to Firebase: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _emergencyController.dispose();
    _ambulanceController.dispose();
    _bleStatusSub?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Helmet Emergency Contacts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loadError != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.shade200),
                          ),
                          child: Text(_loadError!,
                              style: TextStyle(color: Colors.red.shade800)),
                        ),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        'Helmet: $kHelmetId',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _lastSeen != null
                            ? 'Last seen: ${DateTime.fromMillisecondsSinceEpoch(_lastSeen!)}'
                            : 'Last seen: unknown',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _emergencyController,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Emergency contact',
                          hintText: '+91XXXXXXXXXX',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => _validatePhone(v, required: true),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _ambulanceController,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Ambulance / hospital line',
                          hintText: '+91YYYYYYYYYY',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => _validatePhone(v, required: false),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Save to helmet'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _bleStatus == BleSyncStatus.scanning ||
                                _bleStatus == BleSyncStatus.connecting ||
                                _bleStatus == BleSyncStatus.writing
                            ? null
                            : _syncViaBluetooth,
                        icon: const Icon(Icons.bluetooth),
                        label: Text(_bleLabel()),
                      ),
                      if (_saveMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _saveMessage!,
                          style: TextStyle(
                            color: _saveMessage!.startsWith('Saved')
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
