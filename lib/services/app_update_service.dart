import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final String currentVersion;
  final int currentBuildNumber;
  final String latestVersion;
  final int latestBuildNumber;
  final String apkUrl;
  final String releaseNotes;
  final String? sha256;
  final bool forceUpdate;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.latestVersion,
    required this.latestBuildNumber,
    required this.apkUrl,
    required this.releaseNotes,
    this.sha256,
    this.forceUpdate = false,
  });

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

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const String _providerAuthority = 'com.mrdb.flit.ota_update_provider';
  bool _checkedThisSession = false;

  Future<PackageInfo> getPackageInfo() => PackageInfo.fromPlatform();

  /// Checks Firestore `app_config/update` for an available APK update.
  Future<AppUpdateInfo?> checkForUpdate({bool forceCheck = false}) async {
    if (!Platform.isAndroid) return null;
    if (!forceCheck && _checkedThisSession) return null;
    if (!await NetworkService.instance.hasInternet(forceRefresh: forceCheck)) {
      return null;
    }

    _checkedThisSession = true;

    try {
      final pkg = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(pkg.buildNumber) ?? 1;

      final doc = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('update')
          .get()
          .timeout(const Duration(seconds: 5));

      if (!doc.exists || doc.data() == null) return null;
      final data = doc.data()!;

      final latestVersion =
          (data['latestVersion'] ?? data['version'] ?? pkg.version).toString();
      final latestBuild = int.tryParse(
            (data['latestBuildNumber'] ?? data['buildNumber'] ?? '0')
                .toString(),
          ) ??
          0;
      final apkUrl = (data['apkUrl'] ?? '').toString().trim();
      final notes = (data['releaseNotes'] ??
              'Performance improvements and bug fixes.')
          .toString();
      final sha256 = data['sha256']?.toString().trim();
      final force = data['forceUpdate'] == true;

      final info = AppUpdateInfo(
        currentVersion: pkg.version,
        currentBuildNumber: currentBuild,
        latestVersion: latestVersion,
        latestBuildNumber: latestBuild,
        apkUrl: apkUrl,
        releaseNotes: notes,
        sha256: (sha256 != null && sha256.isNotEmpty) ? sha256 : null,
        forceUpdate: force,
      );

      return info.hasUpdate ? info : null;
    } catch (e) {
      debugPrint('AppUpdateService check error: $e');
      return null;
    }
  }

  /// Streams APK download progress and triggers Android PackageInstaller
  /// automatically once the download completes.
  Stream<OtaEvent> downloadAndInstall(AppUpdateInfo info) {
    return OtaUpdate().execute(
      info.apkUrl,
      destinationFilename: 'mrdb_v${info.latestVersion}.apk',
      androidProviderAuthority: _providerAuthority,
      sha256checksum: info.sha256,
      usePackageInstaller: true,
    );
  }

  Future<void> cancelDownload() async {
    try {
      await OtaUpdate().cancel();
    } catch (_) {}
  }
}
