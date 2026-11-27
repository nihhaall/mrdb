import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';
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

  test('NetworkService exclusive player mode ref-counts and suspends cleanly', () async {
    expect(NetworkService.instance.isPlayerExclusiveActive, isFalse);
    NetworkService.instance.enterPlayerExclusiveMode();
    NetworkService.instance.enterPlayerExclusiveMode();
    expect(NetworkService.instance.isPlayerExclusiveActive, isTrue);

    var released = false;
    final waitFuture = NetworkService.instance.waitUntilPlayerExits().then((_) {
      released = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(released, isFalse);

    NetworkService.instance.exitPlayerExclusiveMode();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(NetworkService.instance.isPlayerExclusiveActive, isTrue);
    expect(released, isFalse);

    NetworkService.instance.exitPlayerExclusiveMode();
    await waitFuture;
    expect(NetworkService.instance.isPlayerExclusiveActive, isFalse);
    expect(released, isTrue);
  });

  test('VideoFrameThumbnailService pauses queue during playback and resumes cleanly', () async {
    var calls = 0;
    final service = VideoFrameThumbnailService.forTest(
      primaryExtractor: (_) async {
        calls++;
        return Uint8List.fromList([1, 2, 3]);
      },
      saveFrame: (key, _) async => '/tmp/$key.jpg',
    );
    service.setPaused(true);
    service.requestFrame(
      const TelegramVideoItem(
        msgId: 1,
        hash: 'abc123',
        streamCode: 'CODE1',
        title: 'Test Movie',
        fileName: 'test.mkv',
        fileSize: 1000,
        streamUrl: 'https://example.com/1/test.mkv?hash=abc123',
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 0);

    service.setPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 1);
    expect(service.pathFor('CODE1'), '/tmp/CODE1.jpg');
  });
}
