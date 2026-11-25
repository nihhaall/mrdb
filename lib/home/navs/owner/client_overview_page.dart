import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/home/navs/first_page/preview_page.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';
import 'package:shimmer/shimmer.dart';
import '../../../main.dart';

class ClientOverviewPage extends StatefulWidget {
  final String clientId;
  final Map<String, dynamic> clientData;

  const ClientOverviewPage({
    super.key,
    required this.clientId,
    required this.clientData,
  });

  @override
  State<ClientOverviewPage> createState() => _ClientOverviewPageState();
}

class _ClientOverviewPageState extends State<ClientOverviewPage> {
  static const Color _kBgColor = Color(0xFF0D0D14);
  static const Color _kCardBg = Color(0xFF151821);
  static const Color _kCardBorder = Color(0xFF222634);
  static const Color _kAccent = Color(0xFF00E5A0);
  static const Color _kTextPrimary = Color(0xFFE6EDF3);
  static const Color _kTextSecondary = Color(0xFF8B949E);
  static const Color _kTextMuted = Color(0xFF5A6270);

  late bool _isOwner;
  bool _isUpdatingOwner = false;

  @override
  void initState() {
    super.initState();
    _isOwner = widget.clientData['owner'] == true;
  }

  Future<void> _toggleOwnerStatus(bool value) async {
    if (!await NetworkService.instance.hasInternet(forceRefresh: true)) {
      if (mounted) {
        showScaffoldMsg(context, txt: 'No internet connection');
      }
      return;
    }
    setState(() => _isUpdatingOwner = true);
    HapticFeedback.mediumImpact();
    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(widget.clientId)
          .set({'owner': value}, SetOptions(merge: true))
          .timeout(const Duration(seconds: 6));

      if (mounted) {
        setState(() {
          _isOwner = value;
          _isUpdatingOwner = false;
        });
        showScaffoldMsg(
          context,
          txt: value ? 'Owner access granted' : 'Owner access revoked',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isUpdatingOwner = false);
        showScaffoldMsg(context, txt: 'Error updating status: $e');
      }
    }
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp is Timestamp) {
      final date = timestamp.toDate();
      return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return 'Unknown';
  }

  @override
  Widget build(BuildContext context) {
    final brand = (widget.clientData['brand'] ?? 'Unknown').toString().toUpperCase();
    final model = (widget.clientData['model'] ?? 'Unknown Model').toString();
    final version = (widget.clientData['version'] ?? 'N/A').toString();
    final createdAt = _formatTimestamp(widget.clientData['createdAt']);

    return Scaffold(
      backgroundColor: _kBgColor,
      appBar: AppBar(
        backgroundColor: _kBgColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$brand $model',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _kTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'Client Profile & Liked Movies',
              style: TextStyle(
                color: _kTextSecondary,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Device Overview Card ─────────────────────────────────────────
            _buildDeviceProfileCard(brand, model, version, createdAt),
            const SizedBox(height: 20),

            // ── Liked Movies Header ──────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.favorite_rounded, color: Color(0xFFFF4D6D), size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'Liked Movies',
                      style: TextStyle(
                        color: _kTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Liked Movies Stream ──────────────────────────────────────────
            _buildLikedMoviesSection(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceProfileCard(
    String brand,
    String model,
    String version,
    String createdAt,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kCardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kCardBorder),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF64D2FF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.smartphone_rounded, color: Color(0xFF64D2FF), size: 22),
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
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (_isOwner) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                      'Android $version',
                      style: const TextStyle(
                        color: _kTextSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFF1E2230)),
          const SizedBox(height: 12),
          _buildInfoRow(
            'Client ID',
            widget.clientId,
            isId: true,
            trailing: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () {
                HapticFeedback.lightImpact();
                Clipboard.setData(ClipboardData(text: widget.clientId));
                showScaffoldMsg(context, txt: 'Client ID copied to clipboard');
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Icon(Icons.copy_rounded, color: _kAccent, size: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildInfoRow('First Seen', createdAt),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFF1E2230)),
          const SizedBox(height: 10),

          // ── Owner toggle ─────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Owner Privileges',
                    style: TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Allows managing clients and viewing diagnostic data',
                    style: TextStyle(
                      color: _kTextSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              _isUpdatingOwner
                  ? SizedBox(
                      width: 32,
                      height: 32,
                      child: Center(
                        child: LoadingAnimationWidget.inkDrop(color: _kAccent, size: 14),
                      ),
                    )
                  : Switch.adaptive(
                      value: _isOwner,
                      activeTrackColor: _kAccent,
                      onChanged: _toggleOwnerStatus,
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isId = false, Widget? trailing}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: _kTextMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    color: _kTextPrimary,
                    fontSize: 12,
                    fontWeight: isId ? FontWeight.normal : FontWeight.w600,
                    fontFamily: isId ? 'monospace' : null,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing,
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Liked Movies List ──────────────────────────────────────────────────────
  Widget _buildLikedMoviesSection() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(widget.clientId)
          .collection('liked')
          .where('delete', isEqualTo: false)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: LoadingAnimationWidget.threeArchedCircle(color: _kAccent, size: 30),
            ),
          );
        }

        if (snapshot.hasError) {
          return NetworkStateView(
            compact: true,
            failureType: NetworkFailureType.serverOrBlocked,
            customMessage: 'Failed to load favorites. Check your connection and try again.',
            onRetry: () => setState(() {}),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
            decoration: BoxDecoration(
              color: _kCardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _kCardBorder),
            ),
            child: const Column(
              children: [
                Icon(Icons.movie_outlined, color: _kTextMuted, size: 40),
                SizedBox(height: 10),
                Text(
                  'No Liked Movies Yet',
                  style: TextStyle(
                    color: _kTextPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'This client has not added any favorites.',
                  style: TextStyle(
                    color: _kTextSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );
        }

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: docs.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 0.58,
            crossAxisSpacing: 10,
            mainAxisSpacing: 12,
          ),
          itemBuilder: (context, index) {
            final movie = Map<String, dynamic>.from(docs[index].data() as Map);
            final title = (movie['title'] ?? 'Movie').toString();
            final poster = (movie['img'] ?? movie['poster_path'] ?? '').toString();
            final rating = (movie['rating'] ?? 0.0).toString();
            final year = (movie['year'] ?? '').toString();
            final movieId = movie['id'] ?? movie['movId'] ?? docs[index].id;

            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                HapticFeedback.lightImpact();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MoviePreview(
                      movieId: movieId,
                      initialMovie: movie,
                      posterPath: poster,
                      title: title,
                      backdropPath: movie['backdrop_path']?.toString(),
                      subtitle: year,
                      heroTag: 'client_fav_${widget.clientId}_$movieId',
                    ),
                  ),
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  color: _kCardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kCardBorder),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Poster
                      Expanded(
                        child: Hero(
                          tag: 'client_fav_${widget.clientId}_$movieId',
                          child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (poster.isNotEmpty)
                              CachedNetworkImage(
                                imageUrl: poster.startsWith('http')
                                    ? poster
                                    : '${AppConstants.baseImageUrl}$poster',
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Shimmer.fromColors(
                                  baseColor: const Color(0xFF1E2230),
                                  highlightColor: const Color(0xFF282E40),
                                  child: Container(color: const Color(0xFF1E2230)),
                                ),
                                errorWidget: (context, url, error) => const Center(
                                  child: Icon(Icons.broken_image_rounded, color: _kTextMuted, size: 24),
                                ),
                              )
                            else
                              Container(
                                color: const Color(0xFF1E2230),
                                child: const Center(
                                  child: Icon(Icons.movie_rounded, color: _kTextMuted, size: 24),
                                ),
                              ),
                            if (rating != '0' && rating != '0.0')
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.75),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.star_rounded, color: Colors.amber, size: 11),
                                      const SizedBox(width: 2),
                                      Text(
                                        rating.length > 3 ? rating.substring(0, 3) : rating,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        ),
                      ),
                      // Title
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _kTextPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
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
      },
    );
  }
}
