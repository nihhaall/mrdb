import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/mrdb_splash_screen.dart';

void main() {
  testWidgets(
    'MrdbSplashScreen renders MRDb branding and transitions smoothly to nextScreen',
    (tester) async {
      var initCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: MrdbSplashScreen(
            minDisplayDuration: const Duration(milliseconds: 900),
            onInit: () async {
              initCalled = true;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            },
            nextScreen: const Scaffold(
              body: Center(child: Text('MRDb Home Ready')),
            ),
          ),
        ),
      );

      expect(initCalled, isTrue);
      expect(find.text('MRDb', findRichText: true), findsOneWidget);
      expect(find.text('Movie Research Database'), findsOneWidget);
      expect(find.text('Getting things ready'), findsOneWidget);
      expect(find.text('Discover Movies'), findsOneWidget);

      // Advance past tag timer (850ms) to verify friendly capability cycling
      await tester.pump(const Duration(milliseconds: 880));
      expect(find.text('Ratings & Soundtracks'), findsOneWidget);

      // Finish remaining display duration + exit/route transition (580ms)
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('MRDb Home Ready'), findsOneWidget);
      expect(find.text('Getting things ready'), findsNothing);
    },
  );

  testWidgets(
    'MrdbSplashScreen proceeds to nextScreen even if onInit throws',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MrdbSplashScreen(
            minDisplayDuration: const Duration(milliseconds: 300),
            onInit: () async {
              throw Exception('Simulated startup error');
            },
            nextScreen: const Scaffold(
              body: Center(child: Text('Recovered Home')),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.text('Recovered Home'), findsOneWidget);
    },
  );

  testWidgets(
    'MrdbSplashScreen fits compact viewports without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final completer = Completer<void>();

      await tester.pumpWidget(
        MaterialApp(
          home: MrdbSplashScreen(
            minDisplayDuration: const Duration(milliseconds: 200),
            onInit: () => completer.future,
            nextScreen: const Scaffold(body: Text('Done')),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);

      completer.complete();
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
    },
  );
}
