import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';

/// Queues a contacts write locally when Firebase is unreachable, and
/// flushes it automatically once connectivity returns. Only ever holds
/// the single latest pending write (a newer save supersedes an older
/// unsent one — no point replaying stale contact lists in order).
class OfflineQueueService {
  static const _key = 'pending_contacts_write';

  Future<void> queue(List<String> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(contacts));
  }

  Future<List<String>?> peek() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Attempts to flush a queued write. Returns true if something was
  /// flushed successfully, false if there was nothing queued or the
  /// flush itself failed (still offline).
  Future<bool> tryFlush(DatabaseReference contactsRef) async {
    final pending = await peek();
    if (pending == null) return false;
    try {
      await contactsRef.set(pending);
      await clear();
      return true;
    } catch (_) {
      return false;
    }
  }
}
