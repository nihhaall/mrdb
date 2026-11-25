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
