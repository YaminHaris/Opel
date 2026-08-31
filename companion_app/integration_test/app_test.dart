// Real end-to-end test: runs the actual app (not fakes) against a local
// Firebase Realtime Database emulator. Start the emulator first:
//   firebase emulators:start --only database
// Then run this with:
//   flutter test integration_test/app_test.dart -d chrome --dart-define=USE_FIREBASE_EMULATOR=true

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:firebase_database/firebase_database.dart';

import 'package:companion_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Clear helmet_01 in the emulator before each test so tests don't
    // leak state into each other.
    await FirebaseDatabase.instance.ref('helmet_01').remove();
  });

  testWidgets('saves a contact and it appears in the database',
      (WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '9876543210');
    await tester.tap(find.text('Save to helmet'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Saved'), findsOneWidget);

    final snapshot = await FirebaseDatabase.instance.ref('helmet_01/contacts/0').get();
    expect(snapshot.value, '9876543210');
  });

  testWidgets('loads an existing contact from the database on launch',
      (WidgetTester tester) async {
    await FirebaseDatabase.instance.ref('helmet_01/contacts').set({
      '0': '9998887770',
      '1': '1112223330',
    });

    app.main();
    await tester.pumpAndSettle();

    expect(find.text('9998887770'), findsOneWidget);
    expect(find.text('1112223330'), findsOneWidget);
  });

  testWidgets('rejects an invalid number and does not write to the database',
      (WidgetTester tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '123');
    await tester.tap(find.text('Save to helmet'));
    await tester.pump();

    expect(find.text('Enter a valid 10-digit number'), findsOneWidget);

    final snapshot = await FirebaseDatabase.instance.ref('helmet_01/contacts').get();
    expect(snapshot.exists, isFalse);
  });
}
