import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mrdb/services/app_update_service.dart';

/// Abstraction for displaying MRDb app update progress & completion notifications.
abstract class AppUpdateNotificationSink {
  Future<void> showProgress({
    required AppUpdateInfo info,
    required int receivedBytes,
    required int totalBytes,
    required double bytesPerSecond,
    bool verifying = false,
  });

  Future<void> showFinished({
    required AppUpdateInfo info,
    required bool needsPermission,
    int? totalBytes,
  });

  Future<void> showStopped({
    required AppUpdateInfo info,
    required bool canceled,
    int receivedBytes = 0,
    int totalBytes = 0,
    String? errorMessage,
  });

  Future<void> cancel();
}

/// No-op sink used in unit tests when notifications are not under test.
class NoopAppUpdateNotificationSink implements AppUpdateNotificationSink {
  const NoopAppUpdateNotificationSink();

  @override
  Future<void> showProgress({
    required AppUpdateInfo info,
    required int receivedBytes,
    required int totalBytes,
    required double bytesPerSecond,
    bool verifying = false,
  }) async {}

  @override
  Future<void> showFinished({
    required AppUpdateInfo info,
    required bool needsPermission,
    int? totalBytes,
  }) async {}

  @override
  Future<void> showStopped({
    required AppUpdateInfo info,
    required bool canceled,
    int receivedBytes = 0,
    int totalBytes = 0,
    String? errorMessage,
  }) async {}

  @override
  Future<void> cancel() async {}
}

/// Android local notification manager for live MRDb APK update progress.
class LocalAppUpdateNotificationSink implements AppUpdateNotificationSink {
  LocalAppUpdateNotificationSink._();
  static final LocalAppUpdateNotificationSink instance =
      LocalAppUpdateNotificationSink._();

  static const int _notificationId = 88019;
  static const String _channelId = 'mrdb_app_updates';
  static const String _channelName = 'App Updates';
  static const String _channelDesc =
      'Download progress and installation status for MRDb updates';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _permissionChecked = false;
  bool _permitted = true;

  Future<bool> _ensureReady() async {
    if (!Platform.isAndroid) return false;
    try {
      if (!_initialized) {
        const androidSettings = AndroidInitializationSettings(
          '@mipmap/ic_launcher',
        );
        const settings = InitializationSettings(android: androidSettings);
        await _plugin.initialize(settings: settings);
        _initialized = true;
      }
      if (!_permissionChecked) {
        _permissionChecked = true;
        final androidImpl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final granted = await androidImpl?.requestNotificationsPermission();
        _permitted = granted ?? true;
      }
      return _permitted;
    } catch (e) {
      debugPrint('AppUpdateNotification init error: $e');
      return false;
    }
  }

  @override
  Future<void> showProgress({
    required AppUpdateInfo info,
    required int receivedBytes,
    required int totalBytes,
    required double bytesPerSecond,
    bool verifying = false,
  }) async {
    if (!await _ensureReady()) return;

    final int effectiveTotal =
        totalBytes > 0 ? totalBytes : (info.fileSizeBytes ?? 0);
    final bool hasTotal = effectiveTotal > 0;
    final int clampedReceived =
        hasTotal ? receivedBytes.clamp(0, effectiveTotal) : receivedBytes;
    final int remainingBytes =
        hasTotal ? (effectiveTotal - clampedReceived).clamp(0, effectiveTotal) : 0;
    final int pct = hasTotal
        ? ((clampedReceived / effectiveTotal) * 100).round().clamp(0, 100)
        : 0;

    final String title = verifying
        ? 'Verifying MRDb v${info.latestVersion}'
        : (hasTotal
            ? 'Updating MRDb v${info.latestVersion} • $pct%'
            : 'Updating MRDb v${info.latestVersion}');

    final String body;
    if (verifying) {
      body = hasTotal
          ? 'Checking ${AppUpdateState.formatBytes(effectiveTotal)} package...'
          : 'Checking downloaded package...';
    } else if (hasTotal) {
      final remStr = AppUpdateState.formatBytes(remainingBytes);
      final totalStr = AppUpdateState.formatBytes(effectiveTotal);
      final speedStr = bytesPerSecond > 0
          ? ' • ${AppUpdateState.formatBytes(bytesPerSecond.round())}/s'
          : '';
      body = '$remStr left of $totalStr$speedStr';
    } else if (receivedBytes > 0) {
      final dlStr = AppUpdateState.formatBytes(receivedBytes);
      final speedStr = bytesPerSecond > 0
          ? ' • ${AppUpdateState.formatBytes(bytesPerSecond.round())}/s'
          : '';
      body = '$dlStr downloaded$speedStr';
    } else {
      body = 'Starting download...';
    }

    final String? subText = hasTotal
        ? '${AppUpdateState.formatBytes(clampedReceived)} / ${AppUpdateState.formatBytes(effectiveTotal)}'
        : null;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.low,
        priority: Priority.low,
        icon: '@mipmap/ic_launcher',
        subText: subText,
        showProgress: true,
        maxProgress: 100,
        progress: verifying ? 100 : pct,
        indeterminate: verifying || !hasTotal,
        ongoing: true,
        autoCancel: false,
        onlyAlertOnce: true,
        playSound: false,
        enableVibration: false,
        showWhen: false,
      ),
    );

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('AppUpdateNotification progress error: $e');
    }
  }

  @override
  Future<void> showFinished({
    required AppUpdateInfo info,
    required bool needsPermission,
    int? totalBytes,
  }) async {
    if (!await _ensureReady()) return;

    final int knownTotal = totalBytes ?? info.fileSizeBytes ?? 0;
    final String sizePrefix = knownTotal > 0
        ? '${AppUpdateState.formatBytes(knownTotal)} ready • '
        : '';

    final String title = needsPermission
        ? 'MRDb v${info.latestVersion} Ready'
        : 'MRDb v${info.latestVersion} Downloaded';
    final String body = needsPermission
        ? '${sizePrefix}Tap to allow installs & finish updating'
        : '${sizePrefix}Tap Install on the prompt to update';

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
        ongoing: false,
        autoCancel: true,
      ),
    );

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('AppUpdateNotification finished error: $e');
    }
  }

  @override
  Future<void> showStopped({
    required AppUpdateInfo info,
    required bool canceled,
    int receivedBytes = 0,
    int totalBytes = 0,
    String? errorMessage,
  }) async {
    if (!await _ensureReady()) return;

    final int effectiveTotal =
        totalBytes > 0 ? totalBytes : (info.fileSizeBytes ?? 0);
    final String title = canceled
        ? 'MRDb Update Stopped'
        : 'MRDb Update Paused';

    final String body;
    if (canceled) {
      if (effectiveTotal > 0 && receivedBytes > 0) {
        final rem = (effectiveTotal - receivedBytes).clamp(0, effectiveTotal);
        body =
            'Canceled • ${AppUpdateState.formatBytes(rem)} left of ${AppUpdateState.formatBytes(effectiveTotal)}';
      } else {
        body = 'Download canceled for v${info.latestVersion}';
      }
    } else {
      body = errorMessage ?? 'Download stopped. Open MRDb to try again.';
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        icon: '@mipmap/ic_launcher',
        ongoing: false,
        autoCancel: true,
      ),
    );

    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('AppUpdateNotification stopped error: $e');
    }
  }

  @override
  Future<void> cancel() async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(id: _notificationId);
    } catch (_) {}
  }
}
