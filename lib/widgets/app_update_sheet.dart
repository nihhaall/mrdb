import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/services/app_update_service.dart';
import 'package:ota_update/ota_update.dart';

class AppUpdateSheet extends StatefulWidget {
  final AppUpdateInfo info;

  const AppUpdateSheet({super.key, required this.info});

  static Future<void> show(BuildContext context, AppUpdateInfo info) {
    return showModalBottomSheet<void>(
      context: context,
      isDismissible: !info.forceUpdate,
      enableDrag: !info.forceUpdate,
      backgroundColor: Colors.transparent,
      builder: (_) => PopScope(
        canPop: !info.forceUpdate,
        child: AppUpdateSheet(info: info),
      ),
    );
  }

  @override
  State<AppUpdateSheet> createState() => _AppUpdateSheetState();
}

class _AppUpdateSheetState extends State<AppUpdateSheet> {
  StreamSubscription<OtaEvent>? _sub;
  OtaStatus? _status;
  double _progress = 0.0;
  String? _errorMsg;
  bool _isRunning = false;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _startUpdate() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isRunning = true;
      _errorMsg = null;
      _progress = 0;
      _status = OtaStatus.DOWNLOADING;
    });

    try {
      _sub?.cancel();
      _sub = AppUpdateService.instance.downloadAndInstall(widget.info).listen(
        (event) {
          if (!mounted) return;
          setState(() {
            _status = event.status;
            switch (event.status) {
              case OtaStatus.DOWNLOADING:
                final pct = double.tryParse(event.value ?? '0') ?? 0;
                _progress = (pct / 100.0).clamp(0.0, 1.0);
                break;
              case OtaStatus.INSTALLING:
                _progress = 1.0;
                break;
              case OtaStatus.INSTALLATION_DONE:
                _isRunning = false;
                _progress = 1.0;
                break;
              case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
                _isRunning = false;
                _errorMsg =
                    'Please allow "Install unknown apps" permission in Settings and retry.';
                break;
              case OtaStatus.DOWNLOAD_ERROR:
                _isRunning = false;
                _errorMsg =
                    'Download failed (${event.value ?? 'check internet'}).';
                break;
              case OtaStatus.CHECKSUM_ERROR:
                _isRunning = false;
                _errorMsg = 'Update file verification failed. Please retry.';
                break;
              case OtaStatus.INSTALLATION_ERROR:
                _isRunning = false;
                _errorMsg =
                    'Installation was canceled or failed. Tap retry to install.';
                break;
              case OtaStatus.INTERNAL_ERROR:
                _isRunning = false;
                _errorMsg = event.value ?? 'Unexpected update error.';
                break;
              case OtaStatus.ALREADY_RUNNING_ERROR:
                _errorMsg = 'Update is already downloading...';
                break;
              case OtaStatus.CANCELED:
                _isRunning = false;
                break;
            }
          });
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            _isRunning = false;
            _errorMsg = 'Update error: $err';
          });
        },
      );
    } catch (e) {
      setState(() {
        _isRunning = false;
        _errorMsg = 'Failed to start update: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00E5A0);
    final info = widget.info;

    String statusText = '';
    if (_status == OtaStatus.DOWNLOADING) {
      statusText = 'Downloading update... ${(_progress * 100).round()}%';
    } else if (_status == OtaStatus.INSTALLING) {
      statusText = 'Opening Android installer... Tap Install to finish.';
    } else if (_status == OtaStatus.INSTALLATION_DONE) {
      statusText = 'Update installed!';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF141722),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0xFF252A3B), width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.system_update_rounded,
                    color: accent,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'New Update Available',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'v${info.currentVersion}  →  v${info.latestVersion}',
                        style: const TextStyle(
                          color: accent,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFF0E1018),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Text(
                info.releaseNotes,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
            if (_isRunning || statusText.isNotEmpty) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _status == OtaStatus.INSTALLING ? null : _progress,
                  minHeight: 7,
                  backgroundColor: Colors.white10,
                  valueColor: const AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                statusText,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_errorMsg != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMsg!,
                style: const TextStyle(
                  color: Color(0xFFFF6B6B),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                if (!info.forceUpdate)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        if (_isRunning) {
                          AppUpdateService.instance.cancelDownload();
                        }
                        Navigator.pop(context);
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF2B3146)),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        _isRunning ? 'Cancel' : 'Later',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (!info.forceUpdate) const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _isRunning ? null : _startUpdate,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      _isRunning ? 'Updating...' : 'Download & Install',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: const Color(0xFF0A0D14),
                      disabledBackgroundColor: accent.withValues(alpha: 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
