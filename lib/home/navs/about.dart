import 'package:amicons/amicons.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/home/navs/owner/admin_page.dart';
import 'package:mrdb/home/navs/owner/telegram_videos_page.dart';
import 'package:mrdb/services/app_update_service.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/app_update_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../main.dart';

class About extends ConsumerStatefulWidget {
  const About({super.key});

  @override
  ConsumerState<About> createState() => _AboutState();
}

class _AboutState extends ConsumerState<About> {
  bool _isLoading = true;
  bool _isOwner = false;
  bool _isCheckingUpdate = false;
  String _appVersion = '2.0.0';
  List<String> _device = ['Unknown', 'Unknown Model', 'Unknown Version', 'Unknown ID'];

  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF151821);
  static const Color _kCardBorder = Color(0xFF202534);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFE6EDF3);
  static const Color _kTextSecondary = Color(0xFF8B949E);

  @override
  void initState() {
    super.initState();
    _loadDeviceDetails();
  }

  Future<void> _loadDeviceDetails() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final phoneData = preferences.getStringList('phone');
      final cachedOwner = preferences.getBool('is_owner') ?? false;
      final pkg = await AppUpdateService.instance.getPackageInfo();

      if (mounted) {
        setState(() {
          _appVersion = pkg.version;
          _isOwner = cachedOwner;
          if (phoneData != null && phoneData.isNotEmpty) {
            _device = List<String>.from(phoneData);
            while (_device.length < 4) {
              _device.add('Unknown');
            }
          }
          _isLoading = false;
        });
      }

      // Check Firestore client document for owner field
      final clientId = _device.length > 3 ? _device[3] : null;
      if (clientId != null &&
          clientId != 'Unknown' &&
          clientId.isNotEmpty &&
          await NetworkService.instance.hasInternet()) {
        final doc = await FirebaseFirestore.instance
            .collection(AppConstants.phone)
            .doc(clientId)
            .get()
            .timeout(const Duration(seconds: 5));
        if (doc.exists) {
          final data = doc.data();
          final isOwner = data?['owner'] == true;
          await preferences.setBool('is_owner', isOwner);
          if (mounted && _isOwner != isOwner) {
            setState(() {
              _isOwner = isOwner;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Owner check error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _launchExternalUrl(String url) async {
    HapticFeedback.lightImpact();
    try {
      Uri uri;
      if (url.contains('@') && !url.startsWith('http')) {
        uri = Uri(
          scheme: 'mailto',
          path: url,
          queryParameters: {
            'subject': 'MRDb App Feedback',
            'body': 'Hi Nihal,\n\nI am reaching out regarding MRDb...',
          },
        );
      } else {
        if (!await NetworkService.instance.hasInternet()) {
          if (mounted) {
            showScaffoldMsg(context, txt: 'No internet connection');
          }
          return;
        }
        uri = Uri.parse(url);
      }
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          showScaffoldMsg(context, txt: 'Could not open link');
        }
      }
    } catch (_) {
      if (mounted) {
        showScaffoldMsg(context, txt: 'Error opening link');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        ref.read(currentIndexProvider.notifier).state = 0;
      },
      child: Scaffold(
        backgroundColor: _kBgColor,
        appBar: AppBar(
          backgroundColor: _kBgColor,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'About',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        body: _isLoading
            ? Center(
                child: LoadingAnimationWidget.threeArchedCircle(
                  color: _kAccent,
                  size: 36,
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    _buildHeader(),
                    const SizedBox(height: 22),
                    _buildQuickContactRow(),
                    const SizedBox(height: 18),
                    _buildUpdateCheckCard(),
                    const SizedBox(height: 12),
                    _buildTelegramStreamButton(),
                    const SizedBox(height: 16),
                    _buildDetailsCard(),
                    if (_isOwner) ...[
                      const SizedBox(height: 16),
                      _buildAdminButton(),
                      const SizedBox(height: 12),
                      _buildDeviceCompactCard(),
                    ],
                    const SizedBox(height: 26),
                    _buildFooterSignature(),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
      ),
    );
  }

  // ── Footer Signature (Minimal Dark Brandmark) ──────────────────────────────
  Widget _buildFooterSignature() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF11131A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E222D), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.asset(
              'assets/images/mrdb_logo.png',
              width: 15,
              height: 15,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => const Icon(
                Icons.movie_rounded,
                color: Color(0xFF8B949E),
                size: 14,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'MRDb',
            style: TextStyle(
              color: Color(0xFFE6EDF3),
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            width: 1,
            height: 10,
            color: const Color(0xFF2C3240),
          ),
          const Text(
            'Made by Nihal M',
            style: TextStyle(
              color: Color(0xFF8B949E),
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ── Header: Logo & Title ──────────────────────────────────────────────────
  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 74,
          height: 74,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF11131A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF202432), width: 1.2),
          ),
          child: Image.asset(
            'assets/images/mrdb_logo.png',
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Icon(Icons.movie_rounded, color: _kAccent, size: 36),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'MRDb',
              style: TextStyle(
                color: _kTextPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: _kAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _kAccent.withValues(alpha: 0.25), width: 0.8),
              ),
              child: Text(
                'v$_appVersion',
                style: const TextStyle(
                  color: _kAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Movie Research Database',
          style: TextStyle(
            color: _kTextSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // ── 3 Quick Connect Buttons in a Row ───────────────────────────────────────
  Widget _buildQuickContactRow() {
    return Row(
      children: [
        Expanded(
          child: _buildConnectButton(
            icon: Amicons.lucide_mail,
            label: 'Email',
            color: const Color(0xFF64D2FF),
            onTap: () => _launchExternalUrl('nihalthoppil16@gmail.com'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildConnectButton(
            icon: Amicons.remix_whatsapp,
            label: 'WhatsApp',
            color: const Color(0xFF25D366),
            onTap: () => _launchExternalUrl('https://wa.me/919605945341'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildConnectButton(
            icon: Amicons.lucide_instagram,
            label: 'Instagram',
            color: const Color(0xFFFF6492),
            onTap: () => _launchExternalUrl('https://www.instagram.com/nihh____al'),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kCardBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCheckForUpdates() async {
    if (_isCheckingUpdate) return;
    HapticFeedback.lightImpact();

    final current = AppUpdateService.instance.state;
    if (current.hasAvailableUpdate && current.info != null) {
      AppUpdateCapsuleController.instance.expand();
      return;
    }

    setState(() => _isCheckingUpdate = true);

    try {
      final hasNet = await NetworkService.instance.hasInternet(
        forceRefresh: true,
      );
      if (!hasNet) {
        if (mounted) {
          showScaffoldMsg(context, txt: 'No internet connection');
        }
        return;
      }

      final update = await AppUpdateService.instance.checkForUpdate(
        forceCheck: true,
      );
      if (!mounted) return;
      if (update != null) {
        AppUpdateCapsuleController.instance.expand();
      } else {
        showScaffoldMsg(
          context,
          txt: 'MRDb is up to date (v$_appVersion)',
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  Widget _buildUpdateCheckCard() {
    return ListenableBuilder(
      listenable: AppUpdateService.instance,
      builder: (context, _) {
        final state = AppUpdateService.instance.state;
        final info = state.info;
        final hasUpdate = state.hasAvailableUpdate && info != null;
        final isDownloading = state.isDownloadingOrVerifying;
        final isReady = state.phase == AppUpdatePhase.readyToInstall ||
            state.phase == AppUpdatePhase.installing;
        final needsPermission = state.phase == AppUpdatePhase.needsPermission;

        final Color accentColor = needsPermission ? const Color(0xFFFFB74D) : _kAccent;

        String title = 'Check for App Updates';
        String subtitle = 'Current version v$_appVersion';
        if (isDownloading) {
          final pct = state.progress != null
              ? '${(state.progress! * 100).round()}% • '
              : '';
          title = 'Downloading Update...';
          subtitle = '$pct${state.formattedProgress}';
        } else if (isReady && info != null) {
          title = 'Update Ready to Install';
          subtitle = 'Tap to install v${info.latestVersion}';
        } else if (needsPermission && info != null) {
          title = 'Finish App Update';
          subtitle = 'Permission needed for v${info.latestVersion}';
        } else if (hasUpdate) {
          title = 'Update Available';
          subtitle = 'v$_appVersion  →  v${info.latestVersion}';
        }

        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: _isCheckingUpdate ? null : _handleCheckForUpdates,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
            decoration: BoxDecoration(
              gradient: hasUpdate
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        accentColor.withValues(alpha: 0.13),
                        _kCardBg,
                      ],
                    )
                  : null,
              color: hasUpdate ? null : _kCardBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: hasUpdate
                    ? accentColor.withValues(alpha: 0.5)
                    : _kCardBorder,
                width: hasUpdate ? 1.2 : 1,
              ),
              boxShadow: hasUpdate
                  ? [
                      BoxShadow(
                        color: accentColor.withValues(alpha: 0.1),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: hasUpdate ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accentColor.withValues(alpha: hasUpdate ? 0.35 : 0.15),
                    ),
                  ),
                  child: Icon(
                    isReady
                        ? Icons.install_mobile_rounded
                        : (hasUpdate
                            ? Icons.auto_awesome_rounded
                            : Icons.system_update_rounded),
                    color: accentColor,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: hasUpdate ? accentColor : _kTextSecondary,
                          fontSize: 11.5,
                          fontWeight:
                              hasUpdate ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isCheckingUpdate)
                  LoadingAnimationWidget.threeArchedCircle(
                    color: _kAccent,
                    size: 18,
                  )
                else if (isDownloading)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      value: state.progress,
                      strokeWidth: 2.3,
                      color: accentColor,
                      backgroundColor: Colors.white12,
                    ),
                  )
                else if (hasUpdate)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isReady ? 'Install' : 'Update',
                      style: const TextStyle(
                        color: Color(0xFF0A0D14),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: _kTextSecondary,
                    size: 14,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Combined App Credits ───────────────────────────────────────────────────
  Widget _buildDetailsCard() {
    return Container(
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(
        children: [
          _buildRowItem(
            icon: Amicons.remix_admin,
            iconColor: const Color(0xFFFF9F1C),
            label: 'Developer',
            value: 'Nihal M',
          ),
          const Divider(height: 1, indent: 52, endIndent: 16, color: Color(0xFF1E2230)),
          _buildRowItem(
            icon: Icons.movie_filter_rounded,
            iconColor: _kAccent,
            label: 'Movie Metadata',
            value: 'The Movie Database (TMDB)',
          ),
          const Divider(height: 1, indent: 52, endIndent: 16, color: Color(0xFF1E2230)),
          _buildRowItem(
            icon: Amicons.remix_flutter,
            iconColor: const Color(0xFF54C5F8),
            label: 'Framework',
            value: 'Flutter & Material 3',
          ),
        ],
      ),
    );
  }

  // ── Admin Section Button (Owner Only) ────────────────────────────────────
  Widget _buildAdminButton() {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const AdminPage(),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _kAccent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: _kAccent.withValues(alpha: 0.08),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.admin_panel_settings_rounded,
                color: Colors.amber,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Admin',
                    style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Manage clients & FileToLink bot controls',
                    style: TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: _kAccent,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  // ── Telegram Cloud Stream Button (Owner Only) ────────────────────────────
  Widget _buildTelegramStreamButton() {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        HapticFeedback.lightImpact();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => const TelegramVideosPage(),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _kCardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF64D2FF).withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF64D2FF).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.cloud_download_rounded,
                color: Color(0xFF64D2FF),
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Telegram Cloud Stream',
                    style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Stream .mkv & video links from @FileToSpeedLink_Bot',
                    style: TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: Color(0xFF64D2FF),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  // ── Compact Device Info ────────────────────────────────────────────────────
  Widget _buildDeviceCompactCard() {
    final brand = _device[0].toUpperCase();
    final model = _device[1];
    final androidVer = _device[2];
    final deviceId = _device[3];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kCardBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF64D2FF).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.phone_android_rounded, color: Color(0xFF64D2FF), size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '$brand $model',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _kTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: Colors.amber.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: const Text(
                        'Owner',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  'Android $androidVer • $deviceId',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _kTextSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.copy_rounded, color: _kAccent.withValues(alpha: 0.8), size: 17),
            tooltip: 'Copy device details',
            onPressed: () {
              HapticFeedback.lightImpact();
              Clipboard.setData(
                ClipboardData(text: 'Brand: $brand\nModel: $model\nOS: Android $androidVer\nDevice ID: $deviceId'),
              );
              showScaffoldMsg(context, txt: 'Device info copied');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRowItem({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 14),
          Text(
            label,
            style: const TextStyle(
              color: _kTextSecondary,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: _kTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
