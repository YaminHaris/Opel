import 'package:firebase_database/firebase_database.dart';

/// Minimal fake DatabaseReference for widget tests. Only the methods
/// ContactScreen actually calls (get, update, child, onValue) are
/// implemented — everything else throws via noSuchMethod, which is fine
/// since the screen never calls them.
class FakeDatabaseReference implements DatabaseReference {
  final Map<String, dynamic>? seedContacts;
  final Map<String, dynamic>? seedStatus;
  final bool throwOnGet;
  Map<String, dynamic>? lastWrite;

  FakeDatabaseReference({
    this.seedContacts,
    this.seedStatus,
    this.throwOnGet = false,
  });

  @override
  Future<DataSnapshot> get() async {
    if (throwOnGet) {
      throw Exception('Simulated Firebase read failure');
    }
    return FakeDataSnapshot(seedContacts);
  }

  @override
  Future<void> update(Map<String, Object?> value) async {
    lastWrite = Map<String, dynamic>.from(value);
  }

  @override
  DatabaseReference child(String path) {
    if (path == 'last_seen') {
      return FakeDatabaseReference(seedContacts: seedStatus);
    }
    return FakeDatabaseReference();
  }

  @override
  Stream<DatabaseEvent> get onValue => Stream.value(
      FakeDatabaseEvent(FakeDataSnapshot(seedStatus?['last_seen'])));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDataSnapshot implements DataSnapshot {
  final dynamic _value;
  FakeDataSnapshot(this._value);

  @override
  dynamic get value => _value;

  @override
  bool get exists => _value != null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeDatabaseEvent implements DatabaseEvent {
  final DataSnapshot _snapshot;
  FakeDatabaseEvent(this._snapshot);

  @override
  DataSnapshot get snapshot => _snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
