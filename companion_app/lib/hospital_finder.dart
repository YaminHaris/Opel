import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

/// India's unified national emergency number — used as a fallback when
/// a nearby hospital has no phone number tagged in OpenStreetMap data.
const String kFallbackAmbulanceNumber = '112';

class Hospital {
  final String name;
  final double lat;
  final double lon;
  final String? phone;
  final double distanceKm;

  Hospital({
    required this.name,
    required this.lat,
    required this.lon,
    required this.phone,
    required this.distanceKm,
  });

  String get callNumber => (phone != null && phone!.trim().isNotEmpty) ? phone! : kFallbackAmbulanceNumber;
  bool get hasDirectHospitalNumber => phone != null && phone!.trim().isNotEmpty;
}

class HospitalFinderException implements Exception {
  final String message;
  HospitalFinderException(this.message);
  @override
  String toString() => message;
}

/// Queries OpenStreetMap's Overpass API (free, no key required) for
/// hospitals near the given coordinates and returns the closest one.
/// Tries a 5km radius first, then widens to 15km if nothing is found —
/// useful for helmet GPS fixes in less built-up areas. Tries the main
/// server first, then a community mirror if that times out or fails —
/// the main public instance can be slow/overloaded, especially over
/// mobile data from outside Europe.
const List<String> _overpassServers = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
];

Future<Hospital?> findNearestHospital(double lat, double lon) async {
  for (final radiusM in [5000, 15000]) {
    final query = '[out:json][timeout:20];'
        'node["amenity"="hospital"](around:$radiusM,$lat,$lon);'
        'out;';

    http.Response? response;
    Object? lastError;

    for (final server in _overpassServers) {
      final uri = Uri.parse(server).replace(queryParameters: {'data': query});
      try {
        // Overpass API's fair-use policy rejects requests without an
        // identifying User-Agent (returns 406 Not Acceptable) — Dart's
        // http package doesn't set one by default, so it's added here.
        response = await http.get(
          uri,
          headers: {
            'User-Agent': 'HelmetGuardApp/1.0 (SIH 2026 PS-06 smart helmet companion app)',
            'Accept': 'application/json',
          },
        ).timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) break;
        lastError = HospitalFinderException('Hospital lookup failed (${response.statusCode})');
        response = null;
      } catch (e) {
        lastError = e;
        response = null;
      }
    }

    if (response == null) {
      throw lastError ?? HospitalFinderException('Hospital lookup failed (all servers unreachable)');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final elements = (data['elements'] as List?) ?? [];
    if (elements.isEmpty) continue;

    Hospital? nearest;
    for (final el in elements) {
      final elLat = (el['lat'] as num?)?.toDouble();
      final elLon = (el['lon'] as num?)?.toDouble();
      if (elLat == null || elLon == null) continue;

      final tags = (el['tags'] as Map?) ?? {};
      final name = (tags['name'] ?? 'Unnamed hospital').toString();
      final phone = (tags['phone'] ?? tags['contact:phone'])?.toString();
      final dist = _haversineKm(lat, lon, elLat, elLon);

      if (nearest == null || dist < nearest.distanceKm) {
        nearest = Hospital(name: name, lat: elLat, lon: elLon, phone: phone, distanceKm: dist);
      }
    }
    if (nearest != null) return nearest;
  }
  return null;
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _deg2rad(lat2 - lat1);
  final dLon = _deg2rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return r * c;
}

double _deg2rad(double deg) => deg * (pi / 180);
