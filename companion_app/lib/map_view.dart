import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

const String _mutedMapStyle = '''
[
  {"elementType": "geometry", "stylers": [{"color": "#f5f6f8"}]},
  {"elementType": "labels.icon", "stylers": [{"visibility": "off"}]},
  {"elementType": "labels.text.fill", "stylers": [{"color": "#6b7280"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#f5f6f8"}]},
  {"featureType": "administrative", "elementType": "geometry", "stylers": [{"color": "#d1d5db"}]},
  {"featureType": "poi", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "geometry", "stylers": [{"color": "#ffffff"}]},
  {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"color": "#e5e7eb"}]},
  {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#e8eaed"}]},
  {"featureType": "transit", "stylers": [{"visibility": "off"}]},
  {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#dbe9f4"}]}
]
''';

/// Embedded live map, styled closer to the reference dashboard: a
/// status overlay bar sitting on top of the map (like the SNAPSHOT bar
/// in the reference), and a map-style toggle row underneath it
/// (Standard/Satellite/Terrain, echoing DARK/SATELLITE/TERRAIN there).
class HelmetMapCard extends StatefulWidget {
  final double helmetLat;
  final double helmetLon;
  final double? hospitalLat;
  final double? hospitalLon;
  final double height;
  final String statusLabel;

  const HelmetMapCard({
    super.key,
    required this.helmetLat,
    required this.helmetLon,
    this.hospitalLat,
    this.hospitalLon,
    this.height = 200,
    this.statusLabel = 'LIVE',
  });

  @override
  State<HelmetMapCard> createState() => _HelmetMapCardState();
}

class _HelmetMapCardState extends State<HelmetMapCard> {
  MapType _mapType = MapType.normal;
  GoogleMapController? _controller;

  @override
  void didUpdateWidget(covariant HelmetMapCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GoogleMap only honours initialCameraPosition on first creation —
    // it does NOT re-center just because the widget rebuilds with new
    // coordinates. Without this, the marker moves but the camera stays
    // put, so a new location can end up invisible off-screen. Explicitly
    // command the camera to follow whenever coordinates actually change.
    final changed = oldWidget.helmetLat != widget.helmetLat ||
        oldWidget.helmetLon != widget.helmetLon ||
        oldWidget.hospitalLat != widget.hospitalLat ||
        oldWidget.hospitalLon != widget.hospitalLon;
    if (changed && _controller != null) {
      final hasHospital = widget.hospitalLat != null && widget.hospitalLon != null;
      final centerLat = hasHospital ? (widget.helmetLat + widget.hospitalLat!) / 2 : widget.helmetLat;
      final centerLon = hasHospital ? (widget.helmetLon + widget.hospitalLon!) / 2 : widget.helmetLon;
      _controller!.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(centerLat, centerLon), hasHospital ? 12.5 : 14),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasHospital = widget.hospitalLat != null && widget.hospitalLon != null;
    final centerLat = hasHospital ? (widget.helmetLat + widget.hospitalLat!) / 2 : widget.helmetLat;
    final centerLon = hasHospital ? (widget.helmetLon + widget.hospitalLon!) / 2 : widget.helmetLon;

    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('helmet'),
        position: LatLng(widget.helmetLat, widget.helmetLon),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: const InfoWindow(title: 'Last known location'),
      ),
      if (hasHospital)
        Marker(
          markerId: const MarkerId('hospital'),
          position: LatLng(widget.hospitalLat!, widget.hospitalLon!),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          infoWindow: const InfoWindow(title: 'Nearest hospital'),
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          child: SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(centerLat, centerLon),
                    zoom: hasHospital ? 12.5 : 14,
                  ),
                  onMapCreated: (controller) => _controller = controller,
                  markers: markers,
                  mapType: _mapType,
                  style: _mapType == MapType.normal ? _mutedMapStyle : null,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  mapToolbarEnabled: false,
                ),
                // Status overlay bar — echoes the SNAPSHOT bar sitting
                // on top of the map in the reference dashboard.
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Row(
                      children: [
                        Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF0E9F6E), shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Text(widget.statusLabel, style: GoogleFonts.robotoMono(fontSize: 10.5, fontWeight: FontWeight.w600, color: const Color(0xFF111827))),
                        const Spacer(),
                        Icon(CupertinoIcons.person_alt_circle_fill, color: Colors.red.shade400, size: 12),
                        const SizedBox(width: 3),
                        Text('Helmet', style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF6B7280))),
                        if (hasHospital) ...[
                          const SizedBox(width: 10),
                          const Icon(CupertinoIcons.building_2_fill, color: Color(0xFF0E9F6E), size: 12),
                          const SizedBox(width: 3),
                          Text('Hospital', style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF6B7280))),
                        ],
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(6)),
                    child: const Text('© Google Maps', style: TextStyle(color: Colors.white70, fontSize: 9)),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Map-style toggle row — echoes the DARK/SATELLITE/TERRAIN row
        // beneath the map in the reference dashboard.
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF3F4F6),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _MapTypeChip(label: 'Standard', selected: _mapType == MapType.normal, onTap: () => setState(() => _mapType = MapType.normal)),
              const SizedBox(width: 6),
              _MapTypeChip(label: 'Satellite', selected: _mapType == MapType.satellite, onTap: () => setState(() => _mapType = MapType.satellite)),
              const SizedBox(width: 6),
              _MapTypeChip(label: 'Terrain', selected: _mapType == MapType.terrain, onTap: () => setState(() => _mapType = MapType.terrain)),
            ],
          ),
        ),
      ],
    );
  }
}

class _MapTypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MapTypeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0B5FA5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }
}
