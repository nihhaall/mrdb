import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';

void main() {
  test('AppHttpOverrides configures HttpClient with safe timeouts', () {
    final overrides = AppHttpOverrides();
    final client = overrides.createHttpClient(null);
    expect(client.connectionTimeout, const Duration(seconds: 8));
    expect(client.idleTimeout, const Duration(seconds: 15));
    client.close(force: true);
  });

  test('NetworkService.classifyError preserves TmdbFetchException', () async {
    const original = TmdbFetchException(
      type: NetworkFailureType.noInternet,
      message: 'No internet',
    );
    final classified = await NetworkService.instance.classifyError(original);
    expect(classified.type, NetworkFailureType.noInternet);
    expect(classified.message, 'No internet');
  });

  test('NetworkService.classifyError handles TimeoutException gracefully', () async {
    final classified = await NetworkService.instance.classifyError(
      TimeoutException('timed out'),
    );
    expect(
      classified.type == NetworkFailureType.slowOrTimeout ||
          classified.type == NetworkFailureType.noInternet,
      isTrue,
    );
  });

  testWidgets('NetworkStateView renders offline and slow states and triggers retry',
      (tester) async {
    bool retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworkStateView(
            failureType: NetworkFailureType.noInternet,
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('No Internet Connection'), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    expect(retried, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworkStateView(
            failureType: NetworkFailureType.slowOrTimeout,
            onRetry: () {},
          ),
        ),
      ),
    );

    expect(find.text('Slow Connection'), findsOneWidget);
  });

  testWidgets('NetworkStatusBanner renders slow banner and retry callback',
      (tester) async {
    bool retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NetworkStatusBanner(
            isSlow: true,
            message: 'Slow connection detected',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Slow connection detected'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });
}
