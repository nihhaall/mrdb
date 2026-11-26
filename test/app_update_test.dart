import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/app_update_notification_service.dart';
import 'package:mrdb/services/app_update_service.dart';
import 'package:mrdb/widgets/app_update_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotificationSink implements AppUpdateNotificationSink {
  final List<String> events = [];
  int? lastReceived;
  int? lastTotal;
  bool? lastNeedsPermission;
  bool? lastCanceled;

  @override
  Future<void> showProgress({
    required AppUpdateInfo info,
    required int receivedBytes,
    required int totalBytes,
    required double bytesPerSecond,
    bool verifying = false,
  }) async {
    lastReceived = receivedBytes;
    lastTotal = totalBytes;
    events.add(verifying ? 'verifying' : 'progress:$receivedBytes/$totalBytes');
  }

  @override
  Future<void> showFinished({
    required AppUpdateInfo info,
    required bool needsPermission,
    int? totalBytes,
  }) async {
    lastNeedsPermission = needsPermission;
    lastTotal = totalBytes;
    events.add('finished:$needsPermission');
  }

  @override
  Future<void> showStopped({
    required AppUpdateInfo info,
    required bool canceled,
    int receivedBytes = 0,
    int totalBytes = 0,
    String? errorMessage,
  }) async {
    lastCanceled = canceled;
    events.add('stopped:$canceled');
  }

  @override
  Future<void> cancel() async {
    events.add('cancel');
  }
}

class _FakeBridge implements AppUpdatePlatformBridge {
  final String dirPath;
  bool canInstall = true;
  bool openSettingsCalled = false;
  int installCallCount = 0;
  String? lastInstalledPath;
  String fakeHash = 'abc123';

  _FakeBridge(this.dirPath);

  @override
  Future<bool> canRequestPackageInstalls() async => canInstall;

  @override
  Future<String> getUpdateDir() async => dirPath;

  @override
  Future<bool> installApk(String path) async {
    installCallCount++;
    lastInstalledPath = path;
    return true;
  }

  @override
  Future<bool> openInstallPermissionSettings() async {
    openSettingsCalled = true;
    return true;
  }

  @override
  Future<String?> sha256File(String path) async => fakeHash;
}

class _FakeApkAdapter implements HttpClientAdapter {
  final List<int> bytes;
  final Map<String, List<String>> headers;
  final int statusCode;

  _FakeApkAdapter({
    required this.bytes,
    this.headers = const {
      'content-type': ['application/vnd.android.package-archive'],
    },
    this.statusCode = 200,
  });

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final map = <String, List<String>>{
      ...headers,
      'content-length': ['${bytes.length}'],
    };
    return ResponseBody.fromBytes(
      bytes,
      statusCode,
      headers: map,
    );
  }
}

void main() {
  const sampleInfo = AppUpdateInfo(
    currentVersion: '1.1.0',
    currentBuildNumber: 2,
    latestVersion: '1.2.0',
    latestBuildNumber: 3,
    apkUrl: 'https://127.0.0.1/mrdb_v1.2.0.apk',
    releaseNotes: '• Faster streaming\n• Smoother search',
    fileSizeBytes: 5 * 1024 * 1024,
  );

  test('parseConfigMap reads settings/config update_url and version', () {
    final parsed = AppUpdateService.parseConfigMap(
      {
        'update_url': 'https://github.com/nihhal/mrdb/releases/download/v1.1.1/app.apk',
        'version': '1.1.1',
      },
      currentVersion: '1.1.0',
      currentBuildNumber: 2,
    );
    expect(parsed.latestVersion, '1.1.1');
    expect(parsed.apkUrl,
        'https://github.com/nihhal/mrdb/releases/download/v1.1.1/app.apk');
    expect(parsed.hasUpdate, isTrue);
  });

  test('AppUpdateState formats bytes and progress cleanly', () {
    expect(AppUpdateState.formatBytes(512), '512 B');
    expect(AppUpdateState.formatBytes(15 * 1024), '15 KB');
    expect(AppUpdateState.formatBytes(12 * 1024 * 1024), '12.0 MB');

    const downloading = AppUpdateState(
      phase: AppUpdatePhase.downloading,
      info: sampleInfo,
      receivedBytes: 2 * 1024 * 1024,
      totalBytes: 10 * 1024 * 1024,
      bytesPerSecond: 1.5 * 1024 * 1024,
    );
    expect(downloading.formattedProgress, '2.0 MB / 10.0 MB');
    expect(downloading.formattedSpeed, '1.5 MB/s');
  });

  test('Cached valid APK skips download and checks install permission',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('mrdb_update_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final bridge = _FakeBridge(tempDir.path)..canInstall = false;
    final apkFile = File('${tempDir.path}${Platform.pathSeparator}${sampleInfo.cacheFileName}');
    await apkFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04, 0x00, 0x01]);

    final service = AppUpdateService.forTest(bridge: bridge);
    await service.prepareInfo(sampleInfo);

    expect(service.state.phase, AppUpdatePhase.needsPermission);
    expect(service.state.downloadedApkPath, apkFile.path);
    expect(bridge.installCallCount, 0);

    // User grants permission in Android settings and returns to app
    bridge.canInstall = true;
    final continued = await service.retryInstallOrCheckPermission();
    expect(continued, isTrue);
    expect(bridge.installCallCount, 1);
    expect(bridge.lastInstalledPath, apkFile.path);
    expect(service.state.phase, AppUpdatePhase.installing);
  });

  test('Dio download validates APK bytes and sha256 then launches installer',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('mrdb_update_dl_');
    addTearDown(() => tempDir.delete(recursive: true));

    final bridge = _FakeBridge(tempDir.path)
      ..canInstall = true
      ..fakeHash = 'deadbeef';
    final dio = Dio()
      ..httpClientAdapter = _FakeApkAdapter(
        bytes: [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00],
      );

    final infoWithHash = AppUpdateInfo(
      currentVersion: sampleInfo.currentVersion,
      currentBuildNumber: sampleInfo.currentBuildNumber,
      latestVersion: sampleInfo.latestVersion,
      latestBuildNumber: sampleInfo.latestBuildNumber,
      apkUrl: sampleInfo.apkUrl,
      releaseNotes: sampleInfo.releaseNotes,
      sha256: 'DEADBEEF',
    );

    final service = AppUpdateService.forTest(bridge: bridge, dio: dio);
    await service.startUpdate(infoWithHash);

    expect(service.state.phase, AppUpdatePhase.installing);
    expect(bridge.installCallCount, 1);
    expect(File(bridge.lastInstalledPath!).existsSync(), isTrue);
  });

  test('HTML response or HTTP 404 produces friendly error', () async {
    final tempDir = await Directory.systemTemp.createTemp('mrdb_err_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final bridge = _FakeBridge(tempDir.path);
    final htmlDio = Dio()
      ..httpClientAdapter = _FakeApkAdapter(
        bytes: '<html>error</html>'.codeUnits,
        headers: const {
          'content-type': ['text/html; charset=utf-8'],
        },
        statusCode: 200,
      );

    final service = AppUpdateService.forTest(bridge: bridge, dio: htmlDio);
    await service.startUpdate(sampleInfo);
    expect(service.state.phase, AppUpdatePhase.error);
    expect(service.state.errorMessage, contains('web page'));

    final notFoundDio = Dio()
      ..httpClientAdapter = _FakeApkAdapter(
        bytes: const [],
        statusCode: 404,
      );
    final service404 =
        AppUpdateService.forTest(bridge: bridge, dio: notFoundDio);
    await service404.startUpdate(sampleInfo);
    expect(service404.state.phase, AppUpdatePhase.error);
    expect(service404.state.errorMessage, contains('not found'));
  });

  testWidgets('AppUpdateCapsule shows compact pill and morphs across phases',
      (tester) async {
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('mrdb_capsule_test_'),
    );
    addTearDown(() => tempDir!.delete(recursive: true));

    final bridge = _FakeBridge(tempDir!.path)..canInstall = false;
    final service = AppUpdateService.forTest(bridge: bridge);
    final controller = AppUpdateCapsuleController(visible: true);
    await tester.runAsync(() => service.prepareInfo(sampleInfo));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateCapsule(service: service, controller: controller),
        ),
      ),
    );

    // Starts as a sleek compact pill without any blocking modal sheet
    expect(find.text('v1.2.0'), findsOneWidget);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('New Update Available'), findsNothing);

    // Tap the pill to morph smoothly into the expanded card
    await tester.tap(find.text('v1.2.0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('MRDb v1.2.0 is Ready'), findsOneWidget);
    expect(find.text('v1.1.0  →  v1.2.0'), findsOneWidget);
    expect(find.text("What's New"), findsOneWidget);
    expect(find.text('Update Now'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Skip v1.2.0'), findsOneWidget);

    // Collapse back to the compact pill
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.isExpanded, isFalse);
    expect(find.text('Update'), findsOneWidget);

    // Simulate cached APK ready but permission missing
    await tester.runAsync(() async {
      final apkFile = File(
        '${tempDir.path}${Platform.pathSeparator}${sampleInfo.cacheFileName}',
      );
      await apkFile.writeAsBytes([0x50, 0x4B, 0x03, 0x04]);
      await service.prepareInfo(sampleInfo);
    });
    await tester.pump();

    expect(find.text('Allow install'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);

    // Expand to view friendly permission step
    await tester.tap(find.text('Allow install'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Allow App Installs'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(find.text('Already enabled? Continue'), findsOneWidget);

    // Tap Open Settings
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(bridge.openSettingsCalled, isTrue);

    // Grant permission and continue -> moves to Installing
    bridge.canInstall = true;
    await tester.runAsync(() => service.retryInstallOrCheckPermission());
    await tester.pump();
    expect(find.text('Opening Installer...'), findsOneWidget);
    expect(find.text('Install Now'), findsOneWidget);
  });

  testWidgets('AppUpdateCapsule supports close dismiss and skip version',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('mrdb_dismiss_test_'),
    );
    addTearDown(() => tempDir!.delete(recursive: true));

    final bridge = _FakeBridge(tempDir!.path);
    final service = AppUpdateService.forTest(bridge: bridge);
    final controller = AppUpdateCapsuleController(visible: true);
    await tester.runAsync(() => service.prepareInfo(sampleInfo));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateCapsule(service: service, controller: controller),
        ),
      ),
    );

    // Tap close button on compact pill
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(controller.isVisible, isFalse);
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.text('Update'), findsNothing);

    // Re-open expanded (as from About card): Later minimizes to pill, Skip dismisses
    controller.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Later'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.isVisible, isTrue);
    expect(controller.isExpanded, isFalse);

    // Re-open and skip version permanently for this release
    controller.expand();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Skip v1.2.0'), findsOneWidget);

    await tester.tap(find.text('Skip v1.2.0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.isVisible, isFalse);
  });

  testWidgets('AppUpdateCapsule locks forceUpdate and hides dismiss controls',
      (tester) async {
    final tempDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('mrdb_force_test_'),
    );
    addTearDown(() => tempDir!.delete(recursive: true));

    const forcedInfo = AppUpdateInfo(
      currentVersion: '1.1.0',
      currentBuildNumber: 2,
      latestVersion: '2.0.0',
      latestBuildNumber: 5,
      apkUrl: 'https://127.0.0.1/mrdb_v2.0.0.apk',
      releaseNotes: 'Critical fix',
      forceUpdate: true,
    );

    final bridge = _FakeBridge(tempDir!.path);
    final service = AppUpdateService.forTest(bridge: bridge);
    final controller = AppUpdateCapsuleController(visible: true, expanded: true);
    await tester.runAsync(() => service.prepareInfo(forcedInfo));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateCapsule(service: service, controller: controller),
        ),
      ),
    );

    expect(find.text('Update Required'), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Update Now'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(find.text('Skip v2.0.0'), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  test('Update notifications emit start, progress, finish, and stop events',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('mrdb_notif_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final bridge = _FakeBridge(tempDir.path)
      ..canInstall = true
      ..fakeHash = 'deadbeef';
    final notif = _FakeNotificationSink();
    final dio = Dio()
      ..httpClientAdapter = _FakeApkAdapter(
        bytes: [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00],
      );

    final infoWithHash = AppUpdateInfo(
      currentVersion: sampleInfo.currentVersion,
      currentBuildNumber: sampleInfo.currentBuildNumber,
      latestVersion: sampleInfo.latestVersion,
      latestBuildNumber: sampleInfo.latestBuildNumber,
      apkUrl: sampleInfo.apkUrl,
      releaseNotes: sampleInfo.releaseNotes,
      sha256: 'DEADBEEF',
    );

    final service = AppUpdateService.forTest(
      bridge: bridge,
      dio: dio,
      notifications: notif,
    );
    await service.startUpdate(infoWithHash);

    expect(notif.events.first, startsWith('progress:0/'));
    expect(notif.events, contains('verifying'));
    expect(notif.events.last, 'finished:false');
    expect(notif.lastNeedsPermission, isFalse);

    // Error stops notification
    final errTempDir =
        await Directory.systemTemp.createTemp('mrdb_notif_err_test_');
    addTearDown(() => errTempDir.delete(recursive: true));

    final errNotif = _FakeNotificationSink();
    final errDio = Dio()
      ..httpClientAdapter = _FakeApkAdapter(bytes: const [], statusCode: 404);
    final errService = AppUpdateService.forTest(
      bridge: _FakeBridge(errTempDir.path),
      dio: errDio,
      notifications: errNotif,
    );
    await errService.startUpdate(sampleInfo);
    expect(errNotif.events.last, 'stopped:false');
    expect(errNotif.lastCanceled, isFalse);
  });
}
