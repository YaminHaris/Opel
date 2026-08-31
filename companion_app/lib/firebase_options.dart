// GENERATED PLACEHOLDER — replace this entire file by running:
//   dart pub global activate flutterfire_cli
//   flutterfire configure
// from the project root, after creating your own Firebase project and
// enabling Realtime Database.
//
// NOTE FOR REVIEWERS: this file is not the version used during development
// — it has been sanitized back to placeholders before committing. The
// developer's real firebase_options.dart (with a live project's keys) is
// intentionally NOT included in this PR; each contributor should run
// `flutterfire configure` against their own Firebase project, or the team
// should agree on one shared project and rotate these placeholders out.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'Run `flutterfire configure` to generate real options before building for web.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform. '
          'Run `flutterfire configure`.',
        );
    }
  }

  // Replace all values below with the ones flutterfire configure generates.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'REPLACE_ME',
    databaseURL: 'https://REPLACE_ME.firebaseio.com',
    storageBucket: 'REPLACE_ME.appspot.com',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'REPLACE_ME',
    appId: 'REPLACE_ME',
    messagingSenderId: 'REPLACE_ME',
    projectId: 'REPLACE_ME',
    databaseURL: 'https://REPLACE_ME.firebaseio.com',
    storageBucket: 'REPLACE_ME.appspot.com',
    iosBundleId: 'com.example.companionApp',
  );
}
