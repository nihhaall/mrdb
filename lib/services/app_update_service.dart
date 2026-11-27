import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/services/app_update_notification_service.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInfo {
  final String currentVersion;
  final int currentBuildNumber;
  final String latestVersion;
  final int latestBuildNumber;
  final String apkUrl;
  final String releaseNotes;
  final String? sha256;
  final bool forceUpdate;
  final int? fileSizeBytes;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.apkUrl,
    required this.releaseNotes,
    this.sha256,
    this.forceUpdate = false,
    this.fileSizeBytes,
  });

  String get versionKey => '$latestVersion+$latestBuildNumber';

  String get cacheFileName {
    final safeVer = latestVersion.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return 'mrdb_v${safeVer}_b$latestBuildNumber.apk';
  }

  bool get hasUpdate {
    if (apkUrl.trim().isEmpty) return false;
    if (latestBuildNumber > currentBuildNumber) return true;
    return _compareVersions(latestVersion, currentVersion) > 0;
  }

  static int _compareVersions(String a, String b) {
    final aParts = a
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final bParts = b
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < len; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}

enum AppUpdatePhase {
  idle,
  checking,
  available,
  downloading,
  verifying,
  needsPermission,
  readyToInstall,
  installing,
  error,
}

class AppUpdateState {
  final AppUpdatePhase phase;
  final AppUpdateInfo? info;
  final double? progress;
  final int receivedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final String? downloadedApkPath;
  final String? errorMessage;

  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.info,
    this.progress,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
    this.downloadedApkPath,
    this.errorMessage,
  });

  bool get isBusy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.verifying;

  bool get isDownloadingOrVerifying =>
      phase == AppUpdatePhase.downloading || phase == AppUpdatePhase.verifying;

  bool get hasAvailableUpdate => info != null && info!.hasUpdate;

  String get formattedProgress {
    if (receivedBytes <= 0) {
      final knownSize = info?.fileSizeBytes;
      if (knownSize != null && knownSize > 0) {
        return '0 MB / ${formatBytes(knownSize)}';
      }
      return 'Starting...';
    }
    if (totalBytes > 0) {
      return '${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}';
    }
    return '${formatBytes(receivedBytes)} downloaded';
  }

  String get formattedSpeed {
    if (bytesPerSecond <= 0) return '';
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    AppUpdateInfo? info,
    double? progress,
    bool clearProgress = false,
    int? receivedBytes,
    int? totalBytes,
    double? bytesPerSecond,
    String? downloadedApkPath,
    bool clearApkPath = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      info: info ?? this.info,
      progress: clearProgress ? null : (progress ?? this.progress),
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      downloadedApkPath:
          clearApkPath ? null : (downloadedApkPath ?? this.downloadedApkPath),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Bridge for Android native package install & permission helpers.
abstract class AppUpdatePlatformBridge {
  Future<String> getUpdateDir();
  Future<bool> canRequestPackageInstalls();
  Future<bool> openInstallPermissionSettings();
  Future<String?> sha256File(String path);
  Future<bool> installApk(String path);
}

class MethodChannelAppUpdateBridge implements AppUpdatePlatformBridge {
  static const MethodChannel _channel = MethodChannel('com.mrdb.flit/app_updater');

  @override
  Future<String> getUpdateDir() async {
    final path = await _channel.invokeMethod<String>('getUpdateDir');
    if (path == null || path.isEmpty) {
      throw StateError('Update storage folder is unavailable');
    }
    return path;
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    final allowed =
        await _channel.invokeMethod<bool>('canRequestPackageInstalls');
    return allowed ?? true;
  }

  @override
  Future<bool> openInstallPermissionSettings() async {
    final opened =
        await _channel.invokeMethod<bool>('openInstallPermissionSettings');
    return opened ?? false;
  }

  @override
  Future<String?> sha256File(String path) {
    return _channel.invokeMethod<String>('sha256File', {'path': path});
  }

  @override
  Future<bool> installApk(String path) async {
    final ok = await _channel.invokeMethod<bool>('installApk', {'path': path});
    return ok ?? false;
  }
}

class AppUpdateService extends ChangeNotifier {
  AppUpdateService._({
    AppUpdatePlatformBridge? bridge,
    Dio? dio,
    bool? isAndroidOverride,
    AppUpdateNotificationSink? notifications,
  })  : _bridge = bridge ?? MethodChannelAppUpdateBridge(),
        _notifications =
            notifications ?? LocalAppUpdateNotificationSink.instance,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                followRedirects: true,
                maxRedirects: 8,
                headers: const {
                  'Accept':
                      'application/vnd.android.package-archive, application/octet-stream, */*',
                },
              ),
            ),
        _isAndroidOverride = isAndroidOverride;

  @visibleForTesting
  factory AppUpdateService.forTest({
    required AppUpdatePlatformBridge bridge,
    Dio? dio,
    bool isAndroid = true,
    AppUpdateNotificationSink? notifications,
  }) {
    return AppUpdateService._(
      bridge: bridge,
      dio: dio,
      isAndroidOverride: isAndroid,
      notifications: notifications ?? const NoopAppUpdateNotificationSink(),
    );
  }

  static final AppUpdateService instance = AppUpdateService._();

  static const String _skippedVersionKey = 'skipped_update_version';

  final AppUpdatePlatformBridge _bridge;
  final AppUpdateNotificationSink _notifications;
  final Dio _dio;
  final bool? _isAndroidOverride;

  AppUpdateState _state = const AppUpdateState();
  AppUpdateState get state => _state;
  AppUpdateInfo? get availableUpdate => _state.info;

  bool _checkedThisSession = false;
  CancelToken? _cancelToken;

  bool get _isAndroid => _isAndroidOverride ?? Platform.isAndroid;

  void _setState(AppUpdateState next) {
    _state = next;
    notifyListeners();
  }

  Future<PackageInfo> getPackageInfo() => PackageInfo.fromPlatform();

  /// Parses Firestore `settings/config` (or `app_config/update`) fields into
  /// an [AppUpdateInfo].
  static AppUpdateInfo parseConfigMap(
    Map<String, dynamic> data, {
    required String currentVersion,
    required int currentBuildNumber,
  }) {
    final latestVersion =
        (data['version'] ?? data['latestVersion'] ?? currentVersion)
            .toString()
            .trim();
    final latestBuild = int.tryParse(
          (data['buildNumber'] ??
                  data['build_number'] ??
                  data['latestBuildNumber'] ??
                  '0')
              .toString(),
        ) ??
        0;
    final apkUrl =
        (data['update_url'] ?? data['apkUrl'] ?? '').toString().trim();
    final notes = (data['releaseNotes'] ??
            data['release_notes'] ??
            'Performance improvements and bug fixes.')
        .toString()
        .trim();
    final sha256 = data['sha256']?.toString().trim();
    final force = data['forceUpdate'] == true || data['force_update'] == true;
    final rawSize = data['fileSizeBytes'] ?? data['apkSizeBytes'];
    final sizeBytes =
        rawSize is num ? rawSize.toInt() : int.tryParse('$rawSize');

    return AppUpdateInfo(
      currentVersion: currentVersion,
      currentBuildNumber: currentBuildNumber,
      latestVersion: latestVersion,
      latestBuildNumber: latestBuild,
      apkUrl: apkUrl,
      releaseNotes:
          notes.isEmpty ? 'Performance improvements and bug fixes.' : notes,
      sha256: (sha256 != null && sha256.isNotEmpty) ? sha256 : null,
      forceUpdate: force,
      fileSizeBytes: sizeBytes,
    );
  }

  /// Checks Firestore `settings/config` (with fallback to `app_config/update`)
  /// for an available APK update.
  ///
  /// When [forceCheck] is false (startup auto-check), returns `null` if the
  /// user previously chose to skip this optional version, while still keeping
  /// [availableUpdate] populated so the About page can surface it.
  Future<AppUpdateInfo?> checkForUpdate({bool forceCheck = false}) async {
    if (!_isAndroid) return null;
    if (NetworkService.instance.isPlayerExclusiveActive) {
      return _state.info;
    }
    if (_state.isDownloadingOrVerifying) return _state.info;
    if (!forceCheck && _checkedThisSession) return _state.info;

    if (!await NetworkService.instance.hasInternet(forceRefresh: forceCheck)) {
      return null;
    }

    _checkedThisSession = true;

    try {
      final pkg = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(pkg.buildNumber) ?? 1;

      DocumentSnapshot<Map<String, dynamic>> doc = await FirebaseFirestore
          .instance
          .collection('settings')
          .doc('config')
          .get()
          .timeout(const Duration(seconds: 6));

      if (!doc.exists || doc.data() == null) {
        doc = await FirebaseFirestore.instance
            .collection('app_config')
            .doc('update')
            .get()
            .timeout(const Duration(seconds: 6));
      }

      if (!doc.exists || doc.data() == null) {
        _setState(const AppUpdateState(phase: AppUpdatePhase.idle));
        return null;
      }

      final info = parseConfigMap(
        doc.data()!,
        currentVersion: pkg.version,
        currentBuildNumber: currentBuild,
      );

      if (!info.hasUpdate) {
        unawaited(_cleanupCache(keepFileName: null));
        _setState(const AppUpdateState(phase: AppUpdatePhase.idle));
        return null;
      }

      unawaited(_cleanupCache(keepFileName: info.cacheFileName));
      await prepareInfo(info);

      if (forceCheck) {
        await clearSkippedVersion();
        return info;
      }

      if (!info.forceUpdate) {
        final prefs = await SharedPreferences.getInstance();
        final skipped = prefs.getString(_skippedVersionKey);
        if (skipped == info.versionKey) {
          return null;
        }
      }

      return info;
    } catch (e) {
      debugPrint('AppUpdateService check error: $e');
      return null;
    }
  }

  /// Syncs service state for [info] without interrupting an active download or
  /// losing an already-cached APK on disk.
  Future<void> prepareInfo(AppUpdateInfo info) async {
    if (_state.isDownloadingOrVerifying &&
        _state.info?.versionKey == info.versionKey) {
      return;
    }

    final cachedPath = await _findValidCachedApk(info);
    if (cachedPath != null) {
      final hasPerm = await _safeCanInstall();
      _setState(
        AppUpdateState(
          phase: hasPerm
              ? AppUpdatePhase.readyToInstall
              : AppUpdatePhase.needsPermission,
          info: info,
          progress: 1.0,
          downloadedApkPath: cachedPath,
        ),
      );
      return;
    }

    _setState(
      AppUpdateState(
        phase: AppUpdatePhase.available,
        info: info,
      ),
    );
  }

  /// Downloads (or reuses cached APK) and launches the Android installer.
  Future<void> startUpdate([AppUpdateInfo? overrideInfo]) async {
    final info = overrideInfo ?? _state.info;
    if (info == null || !_isAndroid) return;
    if (_state.isDownloadingOrVerifying) return;

    // 1. If a verified APK is already cached on disk, skip downloading.
    final cachedPath = await _findValidCachedApk(info);
    if (cachedPath != null) {
      await _proceedToInstall(info, cachedPath);
      return;
    }

    // 2. Check connectivity up front so offline users get immediate feedback.
    if (!await NetworkService.instance.hasInternet(forceRefresh: true)) {
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.error,
          info: info,
          errorMessage:
              'No internet connection. Please connect to Wi-Fi or mobile data and try again.',
        ),
      );
      return;
    }

    String partPath = '';
    try {
      final dirPath = await _bridge.getUpdateDir();
      final finalPath = '$dirPath${Platform.pathSeparator}${info.cacheFileName}';
      partPath = '$finalPath.part';

      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }

      _cancelToken?.cancel();
      final cancelToken = CancelToken();
      _cancelToken = cancelToken;

      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.downloading,
          info: info,
          progress: 0.0,
          totalBytes: info.fileSizeBytes ?? 0,
        ),
      );
      unawaited(
        _notifications.showProgress(
          info: info,
          receivedBytes: 0,
          totalBytes: info.fileSizeBytes ?? 0,
          bytesPerSecond: 0,
        ),
      );

      final stopwatch = Stopwatch()..start();
      int lastReportedMs = 0;
      int lastNotifMs = 0;
      int lastBytes = 0;
      double smoothedSpeed = 0;

      final response = await _dio.download(
        info.apkUrl,
        partPath,
        cancelToken: cancelToken,
        deleteOnError: true,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (code) => code != null && code >= 200 && code < 400,
        ),
        onReceiveProgress: (received, total) {
          if (cancelToken.isCancelled) return;
          final effectiveTotal = total > 0 ? total : (info.fileSizeBytes ?? 0);
          final nowMs = stopwatch.elapsedMilliseconds;
          final isComplete = effectiveTotal > 0 && received >= effectiveTotal;

          if (nowMs - lastReportedMs >= 160 || isComplete) {
            final dtMs = (nowMs - lastReportedMs).clamp(1, 60000);
            final dBytes = (received - lastBytes).clamp(0, 1 << 30);
            final instantSpeed = (dBytes * 1000) / dtMs;
            smoothedSpeed = smoothedSpeed == 0
                ? instantSpeed
                : (smoothedSpeed * 0.65 + instantSpeed * 0.35);

            lastReportedMs = nowMs;
            lastBytes = received;

            _setState(
              AppUpdateState(
                phase: AppUpdatePhase.downloading,
                info: info,
                progress: effectiveTotal > 0
                    ? (received / effectiveTotal).clamp(0.0, 1.0)
                    : null,
                receivedBytes: received,
                totalBytes: effectiveTotal,
                bytesPerSecond: smoothedSpeed,
              ),
            );

            if (nowMs - lastNotifMs >= 450 || isComplete) {
              lastNotifMs = nowMs;
              unawaited(
                _notifications.showProgress(
                  info: info,
                  receivedBytes: received,
                  totalBytes: effectiveTotal,
                  bytesPerSecond: smoothedSpeed,
                ),
              );
            }
          }
        },
      );

      if (cancelToken.isCancelled) return;

      final contentType =
          response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ?? '';
      if (contentType.contains('text/html')) {
        await _safeDelete(partPath);
        const msg =
            'The download link returned a web page instead of an app file. Try downloading in your browser.';
        _setState(
          AppUpdateState(
            phase: AppUpdatePhase.error,
            info: info,
            errorMessage: msg,
          ),
        );
        unawaited(
          _notifications.showStopped(
            info: info,
            canceled: false,
            errorMessage: msg,
          ),
        );
        return;
      }

      if (!await _isValidApkFile(partPath)) {
        await _safeDelete(partPath);
        const msg =
            'The downloaded update file looks incomplete. Please try again.';
        _setState(
          AppUpdateState(
            phase: AppUpdatePhase.error,
            info: info,
            errorMessage: msg,
          ),
        );
        unawaited(
          _notifications.showStopped(
            info: info,
            canceled: false,
            errorMessage: msg,
          ),
        );
        return;
      }

      if (info.sha256 != null && info.sha256!.isNotEmpty) {
        _setState(
          AppUpdateState(
            phase: AppUpdatePhase.verifying,
            info: info,
            progress: 1.0,
            receivedBytes: _state.receivedBytes,
            totalBytes: _state.totalBytes,
          ),
        );
        unawaited(
          _notifications.showProgress(
            info: info,
            receivedBytes: _state.receivedBytes,
            totalBytes: _state.totalBytes,
            bytesPerSecond: 0,
            verifying: true,
          ),
        );
        final actualHash = await _bridge.sha256File(partPath);
        if (actualHash == null ||
            actualHash.toLowerCase() != info.sha256!.toLowerCase()) {
          await _safeDelete(partPath);
          const msg =
              'File check failed. Please try downloading the update again.';
          _setState(
            AppUpdateState(
              phase: AppUpdatePhase.error,
              info: info,
              errorMessage: msg,
            ),
          );
          unawaited(
            _notifications.showStopped(
              info: info,
              canceled: false,
              errorMessage: msg,
            ),
          );
          return;
        }
      }

      await _safeDelete(finalPath);
      await File(partPath).rename(finalPath);

      await _proceedToInstall(info, finalPath, fromDownload: true);
    } on DioException catch (e) {
      await _safeDelete(partPath);
      if (CancelToken.isCancel(e)) {
        _setState(
          AppUpdateState(
            phase: AppUpdatePhase.available,
            info: info,
          ),
        );
        return;
      }
      final msg = _friendlyDioError(e);
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.error,
          info: info,
          errorMessage: msg,
        ),
      );
      unawaited(
        _notifications.showStopped(
          info: info,
          canceled: false,
          errorMessage: msg,
        ),
      );
    } catch (e) {
      await _safeDelete(partPath);
      const msg =
          'Something went wrong while preparing the update. Please try again.';
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.error,
          info: info,
          errorMessage: msg,
        ),
      );
      unawaited(
        _notifications.showStopped(
          info: info,
          canceled: false,
          errorMessage: msg,
        ),
      );
    } finally {
      _cancelToken = null;
    }
  }

  Future<void> _proceedToInstall(
    AppUpdateInfo info,
    String apkPath, {
    bool fromDownload = false,
  }) async {
    final downloadedTotal =
        _state.totalBytes > 0 ? _state.totalBytes : info.fileSizeBytes;
    final canInstall = await _safeCanInstall();
    if (!canInstall) {
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.needsPermission,
          info: info,
          progress: 1.0,
          downloadedApkPath: apkPath,
        ),
      );
      if (fromDownload) {
        unawaited(
          _notifications.showFinished(
            info: info,
            needsPermission: true,
            totalBytes: downloadedTotal,
          ),
        );
      }
      return;
    }

    _setState(
      AppUpdateState(
        phase: AppUpdatePhase.installing,
        info: info,
        progress: 1.0,
        downloadedApkPath: apkPath,
      ),
    );
    if (fromDownload) {
      unawaited(
        _notifications.showFinished(
          info: info,
          needsPermission: false,
          totalBytes: downloadedTotal,
        ),
      );
    }

    try {
      await _bridge.installApk(apkPath);
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        _setState(
          AppUpdateState(
            phase: AppUpdatePhase.needsPermission,
            info: info,
            progress: 1.0,
            downloadedApkPath: apkPath,
          ),
        );
        if (fromDownload) {
          unawaited(
            _notifications.showFinished(
              info: info,
              needsPermission: true,
              totalBytes: downloadedTotal,
            ),
          );
        }
        return;
      }
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.error,
          info: info,
          downloadedApkPath: apkPath,
          errorMessage:
              'Could not open Android installer. Tap Try Again or open in browser.',
        ),
      );
    } catch (_) {
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.error,
          info: info,
          downloadedApkPath: apkPath,
          errorMessage:
              'Could not open Android installer. Tap Try Again or open in browser.',
        ),
      );
    }
  }

  /// Re-checks install permission (e.g. when returning from Settings) and
  /// triggers installation immediately once allowed.
  Future<bool> retryInstallOrCheckPermission() async {
    final info = _state.info;
    final apkPath = _state.downloadedApkPath;
    if (info == null || apkPath == null) return false;

    if (!await File(apkPath).exists()) {
      _setState(AppUpdateState(phase: AppUpdatePhase.available, info: info));
      return false;
    }

    final allowed = await _safeCanInstall();
    if (!allowed) {
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.needsPermission,
          info: info,
          progress: 1.0,
          downloadedApkPath: apkPath,
        ),
      );
      return false;
    }

    await _proceedToInstall(info, apkPath);
    return true;
  }

  Future<void> openPermissionSettings() async {
    try {
      await _bridge.openInstallPermissionSettings();
    } catch (e) {
      debugPrint('openPermissionSettings error: $e');
    }
  }

  /// Stops an active background APK download while the video player is open so
  /// all device bandwidth stays available for playback.
  void pauseBackgroundWorkForPlayback() {
    if (_state.phase == AppUpdatePhase.downloading) {
      unawaited(cancelDownload());
    }
  }

  Future<void> cancelDownload() async {
    final prevInfo = _state.info;
    final prevReceived = _state.receivedBytes;
    final prevTotal = _state.totalBytes;
    final wasDownloading = _state.isDownloadingOrVerifying;

    final token = _cancelToken;
    _cancelToken = null;
    if (token != null && !token.isCancelled) {
      token.cancel('User canceled update');
    }
    if (prevInfo != null) {
      _setState(
        AppUpdateState(
          phase: AppUpdatePhase.available,
          info: prevInfo,
        ),
      );
      if (wasDownloading) {
        unawaited(
          _notifications.showStopped(
            info: prevInfo,
            canceled: true,
            receivedBytes: prevReceived,
            totalBytes: prevTotal,
          ),
        );
      }
    } else {
      _setState(const AppUpdateState(phase: AppUpdatePhase.idle));
      unawaited(_notifications.cancel());
    }
  }

  Future<void> skipThisVersion(AppUpdateInfo info) async {
    if (info.forceUpdate) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, info.versionKey);
  }

  Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skippedVersionKey);
  }

  Future<bool> openDownloadInBrowser(AppUpdateInfo info) async {
    try {
      final uri = Uri.parse(info.apkUrl);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _safeCanInstall() async {
    try {
      return await _bridge.canRequestPackageInstalls();
    } catch (_) {
      return true;
    }
  }

  Future<String?> _findValidCachedApk(AppUpdateInfo info) async {
    try {
      final dirPath = await _bridge.getUpdateDir();
      final candidate = '$dirPath${Platform.pathSeparator}${info.cacheFileName}';
      if (!await _isValidApkFile(candidate)) return null;

      if (info.sha256 != null && info.sha256!.isNotEmpty) {
        final actual = await _bridge.sha256File(candidate);
        if (actual == null ||
            actual.toLowerCase() != info.sha256!.toLowerCase()) {
          await _safeDelete(candidate);
          return null;
        }
      }
      return candidate;
    } catch (_) {
      return null;
    }
  }

  /// Checks that the file exists, is non-empty, and starts with ZIP/APK magic bytes (`PK`).
  Future<bool> _isValidApkFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final len = await file.length();
      if (len < 4) return false;
      final raf = await file.open();
      try {
        final header = await raf.read(2);
        return header.length == 2 && header[0] == 0x50 && header[1] == 0x4B;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _cleanupCache({required String? keepFileName}) async {
    try {
      final dirPath = await _bridge.getUpdateDir();
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (keepFileName != null && name == keepFileName) continue;
        await entity.delete().catchError((_) => entity);
      }
    } catch (_) {}
  }

  Future<void> _safeDelete(String path) async {
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Download timed out because the connection was slow. Please try again.';
      case DioExceptionType.connectionError:
        return 'Lost internet connection while downloading. Please check your network and retry.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 404) {
          return 'Update file was not found on the server. Try again later or open in browser.';
        }
        return 'Server could not send the update (HTTP ${code ?? 'error'}). Please try again.';
      case DioExceptionType.cancel:
        return 'Download canceled.';
      default:
        return 'Could not download the update. Please check your internet and try again.';
    }
  }
}
