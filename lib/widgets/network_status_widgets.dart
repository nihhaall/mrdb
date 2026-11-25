import 'package:flutter/material.dart';
import 'package:mrdb/services/network_service.dart';

/// Full-section error/offline/slow-connection view with retry button.
class NetworkStateView extends StatelessWidget {
  final NetworkFailureType failureType;
  final VoidCallback onRetry;
  final String? customMessage;
  final bool compact;

  const NetworkStateView({
    super.key,
    required this.failureType,
    required this.onRetry,
    this.customMessage,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool isOffline = failureType == NetworkFailureType.noInternet;
    final bool isSlow = failureType == NetworkFailureType.slowOrTimeout;

    final IconData icon = isOffline
        ? Icons.wifi_off_rounded
        : (isSlow
            ? Icons.network_check_rounded
            : Icons.cloud_off_rounded);

    final Color accentColor = isOffline
        ? const Color(0xFFFF6B6B)
        : (isSlow ? const Color(0xFFFF9F1C) : const Color(0xFF00E5A0));

    final String title = isOffline
        ? 'No Internet Connection'
        : (isSlow ? 'Slow Connection' : 'Unable to Load');

    final String subtitle = customMessage ??
        (isOffline
            ? 'Turn on Wi-Fi or mobile data and tap retry to continue.'
            : (isSlow
                ? 'Your internet connection is taking too long to respond. Please try again.'
                : 'Could not reach the server right now. Please try again.'));

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 28,
          vertical: compact ? 20 : 36,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: compact ? 60 : 76,
              height: compact ? 60 : 76,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: accentColor.withValues(alpha: 0.3),
                  width: 1.4,
                ),
              ),
              child: Icon(
                icon,
                color: accentColor,
                size: compact ? 28 : 34,
              ),
            ),
            SizedBox(height: compact ? 14 : 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 16 : 18.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: compact ? 12.5 : 13.5,
                height: 1.45,
              ),
            ),
            SizedBox(height: compact ? 18 : 22),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                'Try Again',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: const Color(0xFF0B0E16),
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim inline status banner for slow internet or offline cached-data mode.
class NetworkStatusBanner extends StatelessWidget {
  final bool isOffline;
  final bool isSlow;
  final String message;
  final VoidCallback? onRetry;

  const NetworkStatusBanner({
    super.key,
    this.isOffline = false,
    this.isSlow = false,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = isOffline
        ? const Color(0xFFFF6B6B)
        : (isSlow ? const Color(0xFFFF9F1C) : const Color(0xFF00E5A0));

    final IconData icon = isOffline
        ? Icons.wifi_off_rounded
        : (isSlow
            ? Icons.hourglass_bottom_rounded
            : Icons.info_outline_rounded);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onRetry != null)
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Retry',
                  style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
