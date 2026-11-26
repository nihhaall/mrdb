import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/navs/owner/client_overview_page.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';

class ManageClientsPage extends StatefulWidget {
  const ManageClientsPage({super.key});

  @override
  State<ManageClientsPage> createState() => _ManageClientsPageState();
}

class _ManageClientsPageState extends State<ManageClientsPage> {
  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF151821);
  static const Color _kCardBorder = Color(0xFF222634);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFE6EDF3);
  static const Color _kTextSecondary = Color(0xFF8B949E);
  static const Color _kTextMuted = Color(0xFF5A6270);

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp is Timestamp) {
      final date = timestamp.toDate();
      return '${date.day}/${date.month}/${date.year}';
    }
    return '';
  }

  Widget _buildAppReleaseCard() {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('settings')
          .doc('config')
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? const <String, dynamic>{};
        final version =
            (data['version'] ?? data['latestVersion'] ?? '').toString().trim();
        final buildRaw = data['buildNumber'] ??
            data['build_number'] ??
            data['latestBuildNumber'];
        final buildStr = buildRaw == null ? '' : buildRaw.toString().trim();
        final apkUrl =
            (data['update_url'] ?? data['apkUrl'] ?? '').toString().trim();
        final forceUpdate =
            data['forceUpdate'] == true || data['force_update'] == true;
        final isLoading = snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData;
        final hasConfig = version.isNotEmpty && apkUrl.isNotEmpty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: isLoading
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    _showReleaseEditorDialog(data);
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hasConfig
                      ? _kAccent.withValues(alpha: 0.35)
                      : Colors.amber.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: (hasConfig ? _kAccent : Colors.amber)
                          .withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.system_update_alt_rounded,
                      color: hasConfig ? _kAccent : Colors.amber,
                      size: 20,
                    ),
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
                                hasConfig
                                    ? 'App Release • v$version${buildStr.isNotEmpty ? ' ($buildStr)' : ''}'
                                    : (isLoading
                                        ? 'Loading App Release...'
                                        : 'App Release Not Set'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _kTextPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (forceUpdate) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: const Text(
                                  'Forced',
                                  style: TextStyle(
                                    color: Colors.amber,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          apkUrl.isNotEmpty
                              ? apkUrl
                              : 'Tap to set latest APK version & download URL',
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
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _kAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _kAccent.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      hasConfig ? 'Edit' : 'Set',
                      style: const TextStyle(
                        color: _kAccent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showReleaseEditorDialog(Map<String, dynamic> initial) async {
    await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Manage App Release',
      barrierColor: Colors.black.withValues(alpha: 0.78),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (_, anim, _, child) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1.0).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
      pageBuilder: (_, _, _) => _ReleaseEditorDialog(initial: initial),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Manage Clients',
          style: TextStyle(
            color: _kTextPrimary,
            fontSize: 19,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: Column(
        children: [
          // ── Owner App Release Config Card ────────────────────────────────
          _buildAppReleaseCard(),

          // ── Search Bar ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              decoration: BoxDecoration(
                color: _kCardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _kCardBorder),
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
                style: const TextStyle(color: _kTextPrimary, fontSize: 13.5),
                decoration: InputDecoration(
                  hintText: 'Search by model, brand, or ID...',
                  hintStyle: const TextStyle(color: _kTextMuted, fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded, color: _kTextSecondary, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, color: _kTextSecondary, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                ),
              ),
            ),
          ),

          // ── Clients List Stream ──────────────────────────────────────────
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection(AppConstants.phone)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(
                    child: LoadingAnimationWidget.threeArchedCircle(
                      color: _kAccent,
                      size: 34,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return NetworkStateView(
                    failureType: NetworkFailureType.serverOrBlocked,
                    customMessage: 'Failed to load clients. Check your connection and try again.',
                    onRetry: () => setState(() {}),
                  );
                }

                final rawDocs = snapshot.data?.docs ?? [];
                if (rawDocs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No registered clients found.',
                      style: TextStyle(color: _kTextSecondary),
                    ),
                  );
                }

                // Filter docs by search query
                final filteredDocs = rawDocs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final brand = (data['brand'] ?? '').toString().toLowerCase();
                  final model = (data['model'] ?? '').toString().toLowerCase();
                  final id = doc.id.toLowerCase();
                  if (_searchQuery.isEmpty) return true;
                  return brand.contains(_searchQuery) ||
                      model.contains(_searchQuery) ||
                      id.contains(_searchQuery);
                }).toList();

                // Sort: owners first, then most recent
                filteredDocs.sort((a, b) {
                  final dataA = a.data() as Map<String, dynamic>;
                  final dataB = b.data() as Map<String, dynamic>;
                  final isOwnerA = dataA['owner'] == true ? 1 : 0;
                  final isOwnerB = dataB['owner'] == true ? 1 : 0;
                  if (isOwnerA != isOwnerB) {
                    return isOwnerB.compareTo(isOwnerA);
                  }
                  final tA = dataA['createdAt'];
                  final tB = dataB['createdAt'];
                  if (tA is Timestamp && tB is Timestamp) {
                    return tB.compareTo(tA);
                  }
                  return 0;
                });

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: filteredDocs.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final doc = filteredDocs[index];
                    final data = Map<String, dynamic>.from(doc.data() as Map);
                    final brand = (data['brand'] ?? 'Unknown').toString().toUpperCase();
                    final model = (data['model'] ?? 'Unknown Model').toString();
                    final version = (data['version'] ?? 'N/A').toString();
                    final isOwner = data['owner'] == true;
                    final dateStr = _formatTimestamp(data['createdAt']);

                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        HapticFeedback.lightImpact();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ClientOverviewPage(
                              clientId: doc.id,
                              clientData: data,
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: _kCardBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isOwner
                                ? Colors.amber.withValues(alpha: 0.35)
                                : _kCardBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: isOwner
                                    ? Colors.amber.withValues(alpha: 0.12)
                                    : const Color(0xFF64D2FF).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                isOwner ? Icons.verified_user_rounded : Icons.phone_android_rounded,
                                color: isOwner ? Colors.amber : const Color(0xFF64D2FF),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 14),
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
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      if (isOwner) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                                          ),
                                          child: const Text(
                                            'Owner',
                                            style: TextStyle(
                                              color: Colors.amber,
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Android $version • ID: ${doc.id.length > 12 ? "${doc.id.substring(0, 12)}..." : doc.id}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _kTextSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                  if (dateStr.isNotEmpty) ...[
                                    const SizedBox(height: 1),
                                    Text(
                                      'Joined $dateStr',
                                      style: const TextStyle(
                                        color: _kTextMuted,
                                        fontSize: 10.5,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(
                              Icons.arrow_forward_ios_rounded,
                              color: _kTextMuted,
                              size: 13,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseEditorDialog extends StatefulWidget {
  final Map<String, dynamic> initial;

  const _ReleaseEditorDialog({required this.initial});

  @override
  State<_ReleaseEditorDialog> createState() => _ReleaseEditorDialogState();
}

class _ReleaseEditorDialogState extends State<_ReleaseEditorDialog> {
  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF151821);
  static const Color _kCardBorder = Color(0xFF222634);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFE6EDF3);
  static const Color _kTextSecondary = Color(0xFF8B949E);
  static const Color _kTextMuted = Color(0xFF5A6270);

  late final TextEditingController _versionCtrl;
  late final TextEditingController _buildCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _shaCtrl;
  late bool _forceUpdate;
  bool _saving = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _versionCtrl = TextEditingController(
      text: (initial['version'] ?? initial['latestVersion'] ?? '').toString(),
    );
    _buildCtrl = TextEditingController(
      text: (initial['buildNumber'] ??
              initial['build_number'] ??
              initial['latestBuildNumber'] ??
              '')
          .toString(),
    );
    _urlCtrl = TextEditingController(
      text: (initial['update_url'] ?? initial['apkUrl'] ?? '').toString(),
    );
    _notesCtrl = TextEditingController(
      text: (initial['releaseNotes'] ?? initial['release_notes'] ?? '')
          .toString(),
    );
    _shaCtrl = TextEditingController(
      text: (initial['sha256'] ?? '').toString(),
    );
    _forceUpdate =
        initial['forceUpdate'] == true || initial['force_update'] == true;
  }

  @override
  void dispose() {
    _versionCtrl.dispose();
    _buildCtrl.dispose();
    _urlCtrl.dispose();
    _notesCtrl.dispose();
    _shaCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    final version = _versionCtrl.text.trim();
    final apkUrl = _urlCtrl.text.trim();
    final buildText = _buildCtrl.text.trim();
    final notes = _notesCtrl.text.trim();
    final sha = _shaCtrl.text.trim();

    if (version.isEmpty) {
      setState(() => _errorMsg = 'Enter a version (e.g. 1.2.0).');
      return;
    }
    final uri = Uri.tryParse(apkUrl);
    if (apkUrl.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      setState(() => _errorMsg = 'Enter a valid http/https APK URL.');
      return;
    }
    int? parsedBuild;
    if (buildText.isNotEmpty) {
      parsedBuild = int.tryParse(buildText);
      if (parsedBuild == null || parsedBuild < 1) {
        setState(() => _errorMsg = 'Build number must be a positive integer.');
        return;
      }
    }

    setState(() {
      _saving = true;
      _errorMsg = null;
    });

    try {
      final payload = <String, dynamic>{
        'version': version,
        'update_url': apkUrl,
        'releaseNotes': notes.isEmpty
            ? 'Performance improvements and bug fixes.'
            : notes,
        'forceUpdate': _forceUpdate,
        'buildNumber': parsedBuild ?? FieldValue.delete(),
        'sha256': sha.isNotEmpty ? sha : FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('settings')
          .doc('config')
          .set(payload, SetOptions(merge: true));

      if (!mounted) return;
      Navigator.pop(context, version);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMsg = 'Could not save release config. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          24,
          18,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: _kAccent.withValues(alpha: 0.35),
                width: 1.2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _kAccent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.system_update_alt_rounded,
                        color: _kAccent,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Manage App Release',
                        style: TextStyle(
                          color: _kTextPrimary,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: _kTextSecondary,
                        size: 20,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildDialogField(
                        controller: _versionCtrl,
                        label: 'Latest Version',
                        hint: '1.2.0',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _buildDialogField(
                        controller: _buildCtrl,
                        label: 'Build # (opt)',
                        hint: '3',
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _buildDialogField(
                  controller: _urlCtrl,
                  label: 'APK Download URL',
                  hint: 'https://github.com/.../mrdb.apk',
                  keyboardType: TextInputType.url,
                  suffix: IconButton(
                    tooltip: 'Paste URL',
                    icon: const Icon(
                      Icons.content_paste_rounded,
                      color: _kAccent,
                      size: 18,
                    ),
                    onPressed: () async {
                      final clip = await Clipboard.getData('text/plain');
                      final text = clip?.text?.trim() ?? '';
                      if (text.isNotEmpty) {
                        _urlCtrl.text = text;
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                _buildDialogField(
                  controller: _notesCtrl,
                  label: 'Release Notes (optional)',
                  hint: 'Bug fixes & faster streaming...',
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                _buildDialogField(
                  controller: _shaCtrl,
                  label: 'SHA-256 (optional)',
                  hint: 'Leave empty to skip checksum',
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _kBgColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _kCardBorder),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Force Update',
                          style: TextStyle(
                            color: _kTextPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Switch.adaptive(
                        value: _forceUpdate,
                        activeTrackColor: Colors.amber,
                        onChanged: _saving
                            ? null
                            : (val) => setState(() => _forceUpdate = val),
                      ),
                    ],
                  ),
                ),
                if (_errorMsg != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _errorMsg!,
                    style: const TextStyle(
                      color: Color(0xFFFF6B6B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _saving ? null : () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: _kCardBorder),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            color: _kTextSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _saveConfig,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kAccent,
                          foregroundColor: const Color(0xFF0A0D14),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF0A0D14),
                                ),
                              )
                            : const Text(
                                'Save Release',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialogField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
    int maxLines = 1,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: _kTextSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          decoration: BoxDecoration(
            color: _kBgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kCardBorder),
          ),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLines: maxLines,
            style: const TextStyle(color: _kTextPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: _kTextMuted, fontSize: 12.5),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              suffixIcon: suffix,
            ),
          ),
        ),
      ],
    );
  }
}
