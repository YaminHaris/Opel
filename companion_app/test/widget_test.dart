// Widget tests for ContactScreen, using fake DatabaseReferences instead of
// real Firebase (see firebase_mocks.dart and fake_database_reference.dart).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:companion_app/main.dart';

import 'firebase_mocks.dart';
import 'fake_database_reference.dart';

void main() {
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  testWidgets('shows saved contact numbers loaded from Firebase',
      (WidgetTester tester) async {
    final contactsRef = FakeDatabaseReference(
      seedContacts: {'0': '9876543210', '1': '1234567890'},
    );
    final statusRef = FakeDatabaseReference(
      seedStatus: {'last_seen': null},
    );

    await tester.pumpWidget(MaterialApp(
      home: ContactScreen(contactsRef: contactsRef, statusRef: statusRef),
    ));
    await tester.pumpAndSettle();

    expect(find.text('9876543210'), findsOneWidget);
    expect(find.text('1234567890'), findsOneWidget);
  });

  testWidgets('shows error banner when Firebase read fails',
      (WidgetTester tester) async {
    final contactsRef = FakeDatabaseReference(throwOnGet: true);
    final statusRef = FakeDatabaseReference();

    await tester.pumpWidget(MaterialApp(
      home: ContactScreen(contactsRef: contactsRef, statusRef: statusRef),
    ));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Could not load current contacts'), findsOneWidget);
  });

  testWidgets('rejects an invalid phone number on save',
      (WidgetTester tester) async {
    final contactsRef = FakeDatabaseReference();
    final statusRef = FakeDatabaseReference();

    await tester.pumpWidget(MaterialApp(
      home: ContactScreen(contactsRef: contactsRef, statusRef: statusRef),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '123');
    await tester.tap(find.text('Save to helmet'));
    await tester.pump();

    expect(find.text('Enter a valid 10-digit number'), findsOneWidget);
    expect(contactsRef.lastWrite, isNull);
  });

  testWidgets('saves a valid 10-digit number to Firebase',
      (WidgetTester tester) async {
    final contactsRef = FakeDatabaseReference();
    final statusRef = FakeDatabaseReference();

    await tester.pumpWidget(MaterialApp(
      home: ContactScreen(contactsRef: contactsRef, statusRef: statusRef),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '9876543210');
    await tester.tap(find.text('Save to helmet'));
    await tester.pumpAndSettle();

    expect(contactsRef.lastWrite, isNotNull);
    expect(contactsRef.lastWrite!['0'], '9876543210');
    expect(find.textContaining('Saved'), findsOneWidget);
  });
}
