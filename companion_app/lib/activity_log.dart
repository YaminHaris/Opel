/// A single entry in the in-app activity log — a lightweight, local,
/// in-memory record of things that happened during this session
/// (contact saved, location updated, hospital selected, SOS
/// triggered, etc). Not persisted to Firebase or disk; resets on
/// app restart. Modelled loosely on the "ledger" style log panel
/// from the reference dashboard design.
class ActivityEntry {
  final DateTime time;
  final String message;
  final ActivityKind kind;

  ActivityEntry({required this.message, required this.kind, DateTime? time}) : time = time ?? DateTime.now();

  String get timeLabel {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

enum ActivityKind { info, success, warning, danger }
