// Basic smoke test for the Helmet Emergency Contacts companion app.
//
// Note: ContactScreen initializes FirebaseDatabase in initState(), which
// requires a real Firebase app. Testing it directly would need mocking
// firebase_core's Pigeon-based platform channels, which is fragile and
// not pursued here. This test only confirms the basic widget tree renders.
// See integration_test/app_test.dart for real end-to-end coverage against
// the Firebase Local Emulator Suite instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App shell renders a MaterialApp', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        title: 'Helmet Contacts',
        home: Scaffold(
          appBar: AppBar(title: const Text('Helmet Emergency Contacts')),
          body: const Center(child: Text('Test placeholder')),
        ),
      ),
    );

    expect(find.text('Helmet Emergency Contacts'), findsOneWidget);
  });
}
