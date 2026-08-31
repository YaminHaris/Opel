import 'dart:convert';
import 'package:http/http.dart' as http;

class GeocodeResult {
  final double lat;
  final double lon;
  final String formattedAddress;
  GeocodeResult({required this.lat, required this.lon, required this.formattedAddress});
}

class GeocodingException implements Exception {
  final String message;
  GeocodingException(this.message);
  @override
  String toString() => message;
}

/// Converts a free-text address into coordinates using the Google
/// Geocoding API. Used only by the in-app debug tool to simulate the
/// helmet being at an arbitrary address, without needing to physically
/// travel there or a real GPS fix.
Future<GeocodeResult?> geocodeAddress(String address, String apiKey) async {
  if (address.trim().isEmpty) return null;
  final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
    'address': address,
    'key': apiKey,
  });

  final response = await http.get(uri).timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    throw GeocodingException('Geocoding request failed (${response.statusCode})');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final status = data['status'] as String?;
  if (status != 'OK') {
    if (status == 'ZERO_RESULTS') return null;
    throw GeocodingException('Geocoding error: $status');
  }

  final results = data['results'] as List?;
  if (results == null || results.isEmpty) return null;

  final first = results.first as Map<String, dynamic>;
  final location = first['geometry']['location'] as Map<String, dynamic>;
  return GeocodeResult(
    lat: (location['lat'] as num).toDouble(),
    lon: (location['lng'] as num).toDouble(),
    formattedAddress: (first['formatted_address'] ?? address).toString(),
  );
}
