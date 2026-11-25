import 'package:amicons/amicons.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:mrdb/widgets/image_gallery_viewer.dart';
import 'package:mrdb/widgets/network_status_widgets.dart';
import 'package:readmore/readmore.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../constens/keys.dart';
import 'preview_page.dart';

class ActorPreviewPage extends StatefulWidget {
  final dynamic personId;
  final String? initialName;
  final String? initialProfilePath;
  final String? initialCharacter;

  const ActorPreviewPage({
    super.key,
    required this.personId,
    this.initialName,
    this.initialProfilePath,
    this.initialCharacter,
  });

  @override
  State<ActorPreviewPage> createState() => _ActorPreviewPageState();
}

class _ActorPreviewPageState extends State<ActorPreviewPage> {
  final ScrollController _scrollController = ScrollController();
  bool _showCollapsedTitle = false;
  bool isLoading = true;
  bool _isSlowConnection = false;
  NetworkFailureType _failureType = NetworkFailureType.none;
  String? _errorMessage;
  Map<String, dynamic> person = {};
  Map<String, List<dynamic>> _roleBuckets = {};
  List<dynamic> filmography = [];
  String _filmographyTab = 'all';
  Map<String, String> _socialLinks = {};
  List<String> _profileGallery = [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _fetchPersonDetails();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = _scrollController.hasClients && _scrollController.offset > 240;
    if (show != _showCollapsedTitle) {
      setState(() => _showCollapsedTitle = show);
    }
  }

  static const Map<String, String> _roleTabLabels = {
    'all': 'All',
    'acted': 'Acted',
    'directed': 'Directed',
    'written': 'Written',
    'produced': 'Produced',
    'music': 'Music',
    'other': 'Crew',
  };

  static const Map<String, String> _roleHeadings = {
    'all': 'Filmography',
    'acted': 'Acted Movies',
    'directed': 'Directed Movies',
    'written': 'Written Movies',
    'produced': 'Produced Movies',
    'music': 'Music Credits',
    'other': 'Crew Credits',
  };

  String _classifyCrewRole(String job, String dept) {
    final j = job.toLowerCase();
    final d = dept.toLowerCase();
    if (j == 'director' || j == 'co-director') return 'directed';
    if (d == 'writing' ||
        j.contains('writer') ||
        j.contains('screenplay') ||
        j.contains('story') ||
        j.contains('dialogue')) {
      return 'written';
    }
    if (d == 'production' || j.contains('producer')) return 'produced';
    if (d == 'sound' || j.contains('music') || j.contains('composer')) {
      return 'music';
    }
    return 'other';
  }

  Future<void> _openSocialUrl(String url) async {
    HapticFeedback.lightImpact();
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      }
    } catch (_) {}
  }

  Future<void> _fetchPersonDetails() async {
    if (mounted) {
      setState(() {
        isLoading = true;
        _isSlowConnection = false;
        _failureType = NetworkFailureType.none;
        _errorMessage = null;
      });
    }

    final hasNet = await NetworkService.instance.hasInternet();
    if (!hasNet) {
      if (mounted) {
        setState(() {
          isLoading = false;
          _isSlowConnection = false;
          _failureType = NetworkFailureType.noInternet;
          _errorMessage =
              'No internet connection. Turn on Wi-Fi or mobile data and try again.';
        });
      }
      return;
    }

    try {
      final resData = await NetworkService.instance.getTmdbJson(
        '/3/person/${widget.personId}?api_key=${AppConstants.apiKey}&language=en&append_to_response=movie_credits,external_ids,images',
        timeout: const Duration(seconds: 12),
        onSlowConnection: () {
          if (mounted && isLoading && !_isSlowConnection) {
            setState(() => _isSlowConnection = true);
          }
        },
      );
      if (resData is Map && mounted) {
        final data = Map<String, dynamic>.from(resData);
        final credits = data['movie_credits'] as Map<String, dynamic>? ?? {};
        final rawCast = credits['cast'] as List<dynamic>? ?? [];
        final rawCrew = credits['crew'] as List<dynamic>? ?? [];

        bool isValidMovie(dynamic m) {
          if (m is! Map) return false;
          final title = m['title']?.toString() ?? '';
          final poster = m['poster_path']?.toString() ?? '';
          return title.isNotEmpty && poster.isNotEmpty;
        }

        final actingList = rawCast
            .where(isValidMovie)
            .map((m) => Map<String, dynamic>.from(m as Map))
            .toList()
          ..sort((a, b) => (b['release_date']?.toString() ?? '')
              .compareTo(a['release_date']?.toString() ?? ''));

        // Bucket crew credits by role (directed, written, produced, music, other)
        final Map<String, Map<dynamic, Map<String, dynamic>>> crewRoleMaps = {
          'directed': {},
          'written': {},
          'produced': {},
          'music': {},
          'other': {},
        };

        for (final item in rawCrew) {
          if (!isValidMovie(item)) continue;
          final m = Map<String, dynamic>.from(item as Map);
          final mid = m['id'];
          final job = (m['job'] ?? m['department'] ?? '').toString().trim();
          final dept = (m['department'] ?? '').toString().trim();
          final roleKey = _classifyCrewRole(job, dept);
          final bucket = crewRoleMaps[roleKey]!;
          if (bucket.containsKey(mid)) {
            final existingJob = (bucket[mid]!['character'] ?? '').toString();
            if (job.isNotEmpty && !existingJob.contains(job)) {
              bucket[mid]!['character'] =
                  existingJob.isEmpty ? job : '$existingJob • $job';
            }
          } else {
            m['character'] = job;
            bucket[mid] = m;
          }
        }

        List<dynamic> sortMovies(Iterable<Map<String, dynamic>> items) {
          return items.toList()
            ..sort((a, b) => (b['release_date']?.toString() ?? '')
                .compareTo(a['release_date']?.toString() ?? ''));
        }

        // Merge combined unique filmography for 'all'
        final Map<dynamic, Map<String, dynamic>> combinedMap = {};
        for (final m in actingList) {
          combinedMap[m['id']] = m;
        }
        for (final bucket in crewRoleMaps.values) {
          for (final m in bucket.values) {
            if (!combinedMap.containsKey(m['id'])) {
              combinedMap[m['id']] = m;
            }
          }
        }

        final Map<String, List<dynamic>> buckets = {
          'all': sortMovies(combinedMap.values),
          if (actingList.isNotEmpty) 'acted': actingList,
          for (final key in ['directed', 'written', 'produced', 'music', 'other'])
            if (crewRoleMaps[key]!.isNotEmpty)
              key: sortMovies(crewRoleMaps[key]!.values),
        };

        // Extract social links from external_ids + homepage
        final ext = data['external_ids'] as Map? ?? {};
        final links = <String, String>{};
        void addId(String key, String prefix, String? id) {
          final clean = id?.trim() ?? '';
          if (clean.isNotEmpty && clean != 'null') {
            links[key] = '$prefix$clean';
          }
        }

        addId('instagram', 'https://www.instagram.com/', ext['instagram_id']?.toString());
        addId('imdb', 'https://www.imdb.com/name/', ext['imdb_id']?.toString());
        addId('twitter', 'https://x.com/', ext['twitter_id']?.toString());
        addId('facebook', 'https://www.facebook.com/', ext['facebook_id']?.toString());
        addId('youtube', 'https://www.youtube.com/@', ext['youtube_id']?.toString());
        final homepage = data['homepage']?.toString().trim() ?? '';
        if (homepage.isNotEmpty && homepage.startsWith('http')) {
          links['website'] = homepage;
        }

        // Extract HD profile images
        final imagesMap = data['images'] as Map? ?? {};
        final profiles = (imagesMap['profiles'] as List? ?? [])
            .map((e) => e is Map ? e['file_path']?.toString() : null)
            .whereType<String>()
            .where((p) => p.isNotEmpty)
            .take(15)
            .toList();

        final dept = (data['known_for_department'] ?? '').toString().toLowerCase();
        String defaultTab = 'all';
        if (dept == 'directing' && buckets.containsKey('directed')) {
          defaultTab = 'directed';
        } else if (dept == 'writing' && buckets.containsKey('written')) {
          defaultTab = 'written';
        } else if (dept == 'production' && buckets.containsKey('produced')) {
          defaultTab = 'produced';
        } else if (dept == 'sound' && buckets.containsKey('music')) {
          defaultTab = 'music';
        } else if (buckets.length == 2) {
          // Only 'all' + one role -> pick that role directly
          defaultTab = buckets.keys.firstWhere((k) => k != 'all');
        }

        setState(() {
          person = data;
          _roleBuckets = buckets;
          _socialLinks = links;
          _profileGallery = profiles;
          _filmographyTab = defaultTab;
          filmography = buckets[defaultTab] ?? const [];
          isLoading = false;
          _isSlowConnection = false;
          _failureType = NetworkFailureType.none;
          _errorMessage = null;
        });
      } else if (mounted) {
        setState(() {
          isLoading = false;
          _isSlowConnection = false;
        });
      }
    } catch (e) {
      final classified = await NetworkService.instance.classifyError(e);
      if (mounted) {
        setState(() {
          isLoading = false;
          _isSlowConnection = false;
          _failureType = classified.type;
          _errorMessage = classified.message;
        });
      }
    }
  }

  String _formatDate(dynamic dateString) {
    if (dateString == null) return '';
    try {
      final DateTime date = DateTime.parse(dateString.toString());
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${months[date.month - 1]} ${date.day}, ${date.year}';
    } catch (_) {
      return dateString.toString();
    }
  }

  int? _calculateAge(dynamic birthdayStr, dynamic deathdayStr) {
    if (birthdayStr == null) return null;
    try {
      final birthday = DateTime.parse(birthdayStr.toString());
      final end = deathdayStr != null
          ? DateTime.parse(deathdayStr.toString())
          : DateTime.now();
      int age = end.year - birthday.year;
      if (end.month < birthday.month ||
          (end.month == birthday.month && end.day < birthday.day)) {
        age--;
      }
      return age;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = person['name'] ?? widget.initialName ?? 'Actor Details';
    final profilePath = person['profile_path'] ?? widget.initialProfilePath;
    final biography = (person['biography']?.toString() ?? '').trim();
    final birthday = person['birthday'];
    final deathday = person['deathday'];
    final placeOfBirth = person['place_of_birth']?.toString();
    final knownFor = person['known_for_department']?.toString() ?? 'Acting';
    final age = _calculateAge(birthday, deathday);

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D14),
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // 1. Sleek Cinematic Actor Hero Header
          SliverAppBar(
            backgroundColor: const Color(0xFF0D0D14),
            surfaceTintColor: Colors.transparent,
            pinned: true,
            elevation: 0,
            expandedHeight: 360,
            title: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showCollapsedTitle ? 1.0 : 0.0,
              child: Row(
                children: [
                  if (profilePath != null && profilePath.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: CachedNetworkImage(
                        imageUrl: '${AppConstants.baseImageUrl}$profilePath',
                        width: 30,
                        height: 30,
                        fit: BoxFit.cover,
                        errorWidget: (context, url, error) => const Icon(
                          Icons.person,
                          size: 20,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.initialCharacter != null &&
                            widget.initialCharacter!.isNotEmpty)
                          Text(
                            widget.initialCharacter!,
                            style: const TextStyle(
                              color: Color(0xFF00E5A0),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            leading: Center(
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (profilePath != null && profilePath.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: '${AppConstants.baseImageUrl}$profilePath',
                      fit: BoxFit.cover,
                      alignment: const Alignment(0, -0.4),
                      errorWidget: (context, url, error) => Container(
                        color: const Color(0xFF14141E),
                      ),
                    )
                  else
                    Container(
                      color: const Color(0xFF14141E),
                      child: const Center(
                        child: Icon(
                          Icons.person,
                          size: 90,
                          color: Colors.white24,
                        ),
                      ),
                    ),

                  // Dark cinematic gradient scrims
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.5),
                          Colors.transparent,
                          const Color(0xFF0D0D14).withValues(alpha: 0.8),
                          const Color(0xFF0D0D14),
                        ],
                        stops: const [0.0, 0.35, 0.8, 1.0],
                      ),
                    ),
                  ),

                  // Actor Name & Role pinned at bottom of header
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00E5A0).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF00E5A0).withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                knownFor,
                                style: const TextStyle(
                                  color: Color(0xFF00E5A0),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (widget.initialCharacter != null &&
                                widget.initialCharacter!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'as ${widget.initialCharacter!}',
                                  style: TextStyle(
                                    color: Colors.grey.shade300,
                                    fontSize: 12.5,
                                    fontStyle: FontStyle.italic,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. Slow / Error Banner
          if (isLoading && _isSlowConnection)
            const SliverToBoxAdapter(
              child: NetworkStatusBanner(
                isSlow: true,
                message: 'Slow connection — loading actor profile...',
              ),
            )
          else if (!isLoading &&
              _failureType != NetworkFailureType.none &&
              (biography.isNotEmpty || filmography.isNotEmpty))
            SliverToBoxAdapter(
              child: NetworkStatusBanner(
                isOffline: _failureType == NetworkFailureType.noInternet,
                isSlow: _failureType == NetworkFailureType.slowOrTimeout,
                message: _errorMessage ?? 'Failed to load profile.',
                onRetry: _fetchPersonDetails,
              ),
            ),

          // 2b. Personal Info Stats Strip
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF14141E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    // Born / Age
                    Expanded(
                      child: _buildInfoItem(
                        icon: Icons.cake_rounded,
                        label: deathday != null ? 'Lived' : 'Born',
                        value: birthday != null
                            ? '${_formatDate(birthday)}${age != null ? ' ($age yrs)' : ''}'
                            : (isLoading ? 'Loading...' : 'N/A'),
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 38,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    const SizedBox(width: 12),
                    // Place of Birth
                    Expanded(
                      child: _buildInfoItem(
                        icon: Icons.location_on_rounded,
                        label: 'Birthplace',
                        value: placeOfBirth != null && placeOfBirth.isNotEmpty
                            ? placeOfBirth
                            : (isLoading ? 'Loading...' : 'N/A'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 2c. Social Links Row
          if (_socialLinks.isNotEmpty)
            SliverToBoxAdapter(child: _buildSocialLinksRow()),

          // 3. Biography Section
          if (biography.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Biography',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ReadMoreText(
                      biography,
                      trimLines: 4,
                      trimMode: TrimMode.Line,
                      trimCollapsedText: ' Read more',
                      trimExpandedText: '  Show less',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 14,
                        height: 1.6,
                        letterSpacing: 0.2,
                      ),
                      moreStyle: const TextStyle(
                        color: Color(0xFF00E5A0),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      lessStyle: const TextStyle(
                        color: Color(0xFF00E5A0),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 3b. Person HD Photo Gallery
          if (_profileGallery.length > 1)
            SliverToBoxAdapter(
              child: _buildProfileGallerySection(name.toString()),
            ),

          // 4. Known For / Filmography Header + Role Filter Tabs
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _roleHeadings[_filmographyTab] ?? 'Filmography',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (filmography.isNotEmpty)
                        Text(
                          '${filmography.length} Movies',
                          style: TextStyle(
                            color: Colors.grey.shade400,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  if (_roleBuckets.length > 2) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 34,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _roleBuckets.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (_, idx) {
                          final key = _roleBuckets.keys.elementAt(idx);
                          final count = _roleBuckets[key]?.length ?? 0;
                          final baseLabel = _roleTabLabels[key] ?? key;
                          return _buildRoleTabChip(
                            key,
                            '$baseLabel ($count)',
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // 5. Filmography Movies Grid
          if (isLoading)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: _buildFilmographyShimmer(),
              ),
            )
          else if (_failureType != NetworkFailureType.none &&
              filmography.isEmpty)
            SliverToBoxAdapter(
              child: NetworkStateView(
                compact: true,
                failureType: _failureType,
                customMessage: _errorMessage,
                onRetry: _fetchPersonDetails,
              ),
            )
          else if (filmography.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: Text(
                    'No filmography records found',
                    style: TextStyle(color: Colors.white54, fontSize: 13.5),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 32),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.54,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final movie = filmography[index];
                    final posterPath = movie['poster_path'];
                    final title = movie['title'] ?? 'Movie';
                    final character = movie['character']?.toString() ?? '';
                    final releaseDate = movie['release_date']?.toString() ?? '';
                    final year = releaseDate.length >= 4
                        ? releaseDate.substring(0, 4)
                        : '';
                    final rating = (movie['vote_average'] is num)
                        ? (movie['vote_average'] as num).toDouble()
                        : 0.0;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => MoviePreview(
                              movieId: movie['id'],
                              posterPath: posterPath,
                              title: title,
                              backdropPath: movie['backdrop_path'],
                              heroTag: 'actor_movie_hero_${movie['id']}',
                              titleHeroTag: 'actor_movie_title_${movie['id']}',
                            ),
                          ),
                        );
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Stack(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                    color: const Color(0xFF161622),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: posterPath != null
                                        ? CachedNetworkImage(
                                            imageUrl:
                                                '${AppConstants.baseImageUrl}$posterPath',
                                            width: double.infinity,
                                            height: double.infinity,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) => Container(
                                              color: const Color(0xFF161622),
                                            ),
                                            errorWidget: (context, url, error) =>
                                                const Center(
                                              child: Icon(
                                                Icons.movie_outlined,
                                                color: Colors.white24,
                                                size: 28,
                                              ),
                                            ),
                                          )
                                        : const Center(
                                            child: Icon(
                                              Icons.movie_outlined,
                                              color: Colors.white24,
                                              size: 28,
                                            ),
                                          ),
                                  ),
                                ),
                                // Rating Pill Badge
                                if (rating > 0)
                                  Positioned(
                                    top: 6,
                                    right: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.75),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.star_rounded,
                                            size: 11,
                                            color: Color(0xFFFFD166),
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            rating.toStringAsFixed(1),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (character.isNotEmpty)
                            Text(
                              character,
                              style: TextStyle(
                                color: Colors.grey.shade400,
                                fontSize: 10.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          else if (year.isNotEmpty)
                            Text(
                              year,
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 10.5,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                  childCount: filmography.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSocialLinksRow() {
    final configs = <String, ({String label, IconData icon, Color color})>{
      'instagram': (
        label: 'Instagram',
        icon: Amicons.lucide_instagram,
        color: const Color(0xFFFF6492),
      ),
      'imdb': (
        label: 'IMDb',
        icon: Icons.movie_rounded,
        color: const Color(0xFFF5C518),
      ),
      'twitter': (
        label: 'X / Twitter',
        icon: Icons.alternate_email_rounded,
        color: const Color(0xFF64D2FF),
      ),
      'youtube': (
        label: 'YouTube',
        icon: Icons.play_circle_outline_rounded,
        color: const Color(0xFFFF5252),
      ),
      'facebook': (
        label: 'Facebook',
        icon: Icons.public_rounded,
        color: const Color(0xFF5B9EFF),
      ),
      'website': (
        label: 'Website',
        icon: Icons.language_rounded,
        color: const Color(0xFF00E5A0),
      ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _socialLinks.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final entry = _socialLinks.entries.elementAt(index);
            final cfg = configs[entry.key] ??
                (
                  label: entry.key,
                  icon: Icons.link_rounded,
                  color: const Color(0xFF00E5A0),
                );
            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _openSocialUrl(entry.value),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: cfg.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: cfg.color.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(cfg.icon, color: cfg.color, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      cfg.label,
                      style: TextStyle(
                        color: cfg.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildProfileGallerySection(String personName) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Photos',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.2,
                  ),
                ),
                Text(
                  '${_profileGallery.length} Photos',
                  style: TextStyle(
                    color: Colors.grey.shade400,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 124,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              itemCount: _profileGallery.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final path = _profileGallery[index];
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageGalleryPage(
                          imagePaths: _profileGallery,
                          initialIndex: index,
                          title: personName,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    width: 88,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      color: const Color(0xFF14141E),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: CachedNetworkImage(
                        imageUrl: '${AppConstants.baseImageUrl}$path',
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: const Color(0xFF161824)),
                        errorWidget: (_, _, _) => const Center(
                          child: Icon(Icons.person, color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleTabChip(String key, String label) {
    final isSelected = _filmographyTab == key;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (_filmographyTab == key) return;
        HapticFeedback.selectionClick();
        setState(() {
          _filmographyTab = key;
          filmography = _roleBuckets[key] ?? const [];
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00E5A0).withValues(alpha: 0.16)
              : const Color(0xFF14141E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF00E5A0)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF00E5A0) : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, color: const Color(0xFF00E5A0), size: 16),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(color: Colors.grey.shade400, fontSize: 10.5),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilmographyShimmer() {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF161622),
      highlightColor: const Color(0xFF252538),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 16,
          childAspectRatio: 0.54,
        ),
        itemCount: 6,
        itemBuilder: (context, index) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF161622),
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 12,
                width: 70,
                decoration: BoxDecoration(
                  color: const Color(0xFF161622),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
