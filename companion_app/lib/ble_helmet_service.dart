import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// PLACEHOLDER UUIDs — must match whatever the ESP32 firmware (Module 5)
/// actually advertises. Coordinate these with the firmware owner before
/// relying on this in a real demo.
class HelmetBleContract {
  static final Guid serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
  static final Guid emergencyCharUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');
  static final Guid ambulanceCharUuid =
      Guid('beb5483e-36e1-4688-b7f5-ea07361b26a9');

  /// The advertised local name the ESP32 broadcasts. Adjust to match firmware.
  static const String deviceNamePrefix = 'HELMET_';
}

enum BleSyncStatus { idle, scanning, connecting, writing, success, error }

class BleHelmetService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _emergencyChar;
  BluetoothCharacteristic? _ambulanceChar;

  final _statusController = StreamController<BleSyncStatus>.broadcast();
  Stream<BleSyncStatus> get statusStream => _statusController.stream;

  String? lastError;

  Future<bool> _ensureBluetoothOn() async {
    if (await FlutterBluePlus.isSupported == false) {
      lastError = 'Bluetooth not supported on this device';
      return false;
    }
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      lastError = 'Bluetooth is turned off — enable it and try again';
      return false;
    }
    return true;
  }

  /// Scans for a device advertising the helmet's name prefix, connects,
  /// and discovers the contact-sync characteristics. Returns true on success.
  Future<bool> connect({Duration timeout = const Duration(seconds: 10)}) async {
    lastError = null;
    if (!await _ensureBluetoothOn()) {
      _statusController.add(BleSyncStatus.error);
      return false;
    }

    _statusController.add(BleSyncStatus.scanning);
    BluetoothDevice? found;

    try {
      final sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          if (name.startsWith(HelmetBleContract.deviceNamePrefix)) {
            found = r.device;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      await sub.cancel();

      if (found == null) {
        lastError =
            'No helmet found nearby — make sure it is powered on and in range';
        _statusController.add(BleSyncStatus.error);
        return false;
      }

      _statusController.add(BleSyncStatus.connecting);
      _device = found;
      await _device!.connect(timeout: timeout);

      final services = await _device!.discoverServices();
      final targetService = services.firstWhere(
        (s) => s.uuid == HelmetBleContract.serviceUuid,
        orElse: () => throw Exception(
            'Helmet did not expose the expected contact service'),
      );

      _emergencyChar = targetService.characteristics.firstWhere(
        (c) => c.uuid == HelmetBleContract.emergencyCharUuid,
      );
      _ambulanceChar = targetService.characteristics.firstWhere(
        (c) => c.uuid == HelmetBleContract.ambulanceCharUuid,
      );

      return true;
    } catch (e) {
      lastError = 'Connection failed: $e';
      _statusController.add(BleSyncStatus.error);
      return false;
    }
  }

  /// Writes both numbers to the helmet over the already-connected link.
  Future<bool> writeContacts({
    required String emergency,
    required String ambulance,
  }) async {
    if (_emergencyChar == null || _ambulanceChar == null) {
      lastError = 'Not connected — call connect() first';
      _statusController.add(BleSyncStatus.error);
      return false;
    }

    _statusController.add(BleSyncStatus.writing);
    try {
      await _emergencyChar!
          .write(utf8.encode(emergency), withoutResponse: false);
      await _ambulanceChar!
          .write(utf8.encode(ambulance), withoutResponse: false);
      _statusController.add(BleSyncStatus.success);
      return true;
    } catch (e) {
      lastError = 'Write failed: $e';
      _statusController.add(BleSyncStatus.error);
      return false;
    }
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _emergencyChar = null;
    _ambulanceChar = null;
    _statusController.add(BleSyncStatus.idle);
  }

  void dispose() {
    _statusController.close();
  }
}
