/// Filters and ranks YouTube Data API search/video results so only verified
/// songs belonging to a specific movie are shown.
class MovieSongContext {
  final String title;
  final String originalTitle;
  final int? releaseYear;
  final List<String> composers;
  final List<String> directors;
  final List<String> castNames;

  const MovieSongContext({
    required this.title,
    this.originalTitle = '',
    this.releaseYear,
    this.composers = const [],
    this.directors = const [],
    this.castNames = const [],
  });
}

class MovieSongCandidate {
  final String videoId;
  final String title;
  final String description;
  final String channelTitle;
  final List<String> tags;
  final String categoryId;
  final String thumbUrl;
  final DateTime? publishedAt;
  final int? durationSeconds;
  final bool embeddable;

  const MovieSongCandidate({
    required this.videoId,
    required this.title,
    required this.description,
    required this.channelTitle,
    this.tags = const [],
    this.categoryId = '',
    required this.thumbUrl,
    this.publishedAt,
    this.durationSeconds,
    this.embeddable = true,
  });
}

class MovieSongVerifier {
  MovieSongVerifier._();

  static const int _minDurationSeconds = 55;
  static const int _maxDurationSeconds = 45 * 60;

  static final RegExp _aposRegex = RegExp("['’]");
  static final RegExp _nonWordAsciiRegex = RegExp(r'[^a-z0-9\u00C0-\u024F\u0900-\u0D7F\u3040-\u30FF\u4E00-\u9FFF\uAC00-\uD7AF]+');
  static final RegExp _spaceRegex = RegExp(r'\s+');

  /// Builds a targeted YouTube query incorporating title, composer (when
  /// available), and release year to improve relevance on ambiguous titles.
  static String buildSearchQuery(MovieSongContext ctx) {
    final cleanTitle = _stripParenthetical(ctx.title).trim();
    final parts = <String>[];
    if (cleanTitle.split(RegExp(r'\s+')).length == 1 && cleanTitle.isNotEmpty) {
      parts.add('"$cleanTitle"');
    } else if (cleanTitle.isNotEmpty) {
      parts.add(cleanTitle);
    }

    final primaryComposer = ctx.composers
        .map((e) => e.trim())
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (primaryComposer.isNotEmpty) {
      parts.add(primaryComposer);
    }

    if (ctx.releaseYear != null && ctx.releaseYear! > 1900) {
      parts.add('${ctx.releaseYear}');
    }

    parts.add('movie songs');
    return parts.join(' ');
  }

  /// Picks the highest-resolution YouTube thumbnail URL available.
  static String pickThumbnail(Map? snippet, String videoId) {
    final thumbs = snippet?['thumbnails'] as Map? ?? {};
    return (thumbs['high']?['url'] ??
            thumbs['medium']?['url'] ??
            thumbs['default']?['url'] ??
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg')
        .toString();
  }

  /// Parses an ISO-8601 YouTube duration (e.g., `PT3M45S`, `PT1H2M`) to seconds.
  static int? parseIsoDurationSeconds(String? iso) {
    if (iso == null || iso.trim().isEmpty) return null;
    final match = RegExp(
      r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
      caseSensitive: false,
    ).firstMatch(iso.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
    return hours * 3600 + minutes * 60 + seconds;
  }

  /// Returns verified, deduplicated songs sorted best-match first.
  static List<Map<String, String>> filterAndRank(
    List<MovieSongCandidate> candidates,
    MovieSongContext movie, {
    int limit = 10,
  }) {
    final titleVariants = _buildTitleVariants(movie);
    if (titleVariants.isEmpty) return const [];

    final anchorPeople = <String>{
      ...movie.composers,
      ...movie.directors,
      ...movie.castNames.take(6),
    }.map(normalizeText).where((s) => s.length >= 4).toList();

    final scored = <_ScoredSong>[];
    final seenIds = <String>{};

    for (final video in candidates) {
      if (video.videoId.isEmpty || !seenIds.add(video.videoId)) continue;
      if (!video.embeddable) continue;

      // Duration check filters out YouTube Shorts (<55s) & full movies (>45m)
      if (video.durationSeconds != null &&
          (video.durationSeconds! < _minDurationSeconds ||
              video.durationSeconds! > _maxDurationSeconds)) {
        continue;
      }

      // Release year plausibility check for movies released after YouTube existed
      if (movie.releaseYear != null &&
          movie.releaseYear! >= 2006 &&
          video.publishedAt != null &&
          video.publishedAt!.year < movie.releaseYear! - 2) {
        continue;
      }

      final score = _scoreCandidate(video, movie, titleVariants, anchorPeople);
      if (score == null) continue;
      scored.add(_ScoredSong(video: video, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored
        .take(limit)
        .map(
          (entry) => <String, String>{
            'videoId': entry.video.videoId,
            'title': entry.video.title,
            'channel': entry.video.channelTitle,
            'thumb': entry.video.thumbUrl,
          },
        )
        .toList();
  }

  static int? _scoreCandidate(
    MovieSongCandidate video,
    MovieSongContext movie,
    List<_TitleVariant> variants,
    List<String> anchorPeople,
  ) {
    final normVideoTitle = normalizeText(video.title);
    final normDesc = normalizeText(video.description);
    final normChannel = normalizeText(video.channelTitle);
    final normTags = normalizeText(video.tags.join(' '));
    final normAll = '$normVideoTitle $normTags $normDesc $normChannel';

    if (_isDisqualifiedNonSong(normVideoTitle, normTags, movie)) {
      return null;
    }

    // Sequel guard: reject obvious wrong part/chapter mismatches (e.g. Part 1 vs Part Two)
    final movieSequelNum = _extractSequelNumber(
      normalizeText('${movie.title} ${movie.originalTitle}'),
      variants,
    );
    final videoSequelNum = _extractSequelNumber(normVideoTitle, variants);
    if (movieSequelNum != null &&
        videoSequelNum != null &&
        movieSequelNum != videoSequelNum) {
      return null;
    }

    // Check which movie title variant matches where
    _TitleVariant? matchedVariant;
    var inVideoTitle = false;
    var inTags = false;
    var inDescLeadCredits = false;
    final normDescHead =
        normDesc.length > 260 ? normDesc.substring(0, 260) : normDesc;

    for (final variant in variants) {
      final tHit = _containsPhrase(normVideoTitle, variant.phrase);
      final tagHit = _containsPhrase(normTags, variant.phrase);
      final descCreditHit = _hasAnyPhrase(normDescHead, [
        'movie ${variant.phrase}',
        'film ${variant.phrase}',
        'from ${variant.phrase}',
        'album ${variant.phrase}',
        'soundtrack ${variant.phrase}',
        '${variant.phrase} movie',
        '${variant.phrase} ost',
      ]);
      if (tHit || tagHit || descCreditHit) {
        matchedVariant = variant;
        inVideoTitle = tHit;
        inTags = tagHit;
        inDescLeadCredits = descCreditHit;
        break;
      }
    }

    if (matchedVariant == null) return null;

    // Must look like actual music/song content rather than scenes/interviews
    final hasMusicKeywordInTitle = _hasAnyPhrase(normVideoTitle, _songKeywords);
    final hasMusicKeywordInMeta =
        hasMusicKeywordInTitle ||
        _hasAnyPhrase('$normTags $normDesc', _songKeywords);
    final isMusicCategory = video.categoryId == '10';
    if (!isMusicCategory && !hasMusicKeywordInMeta) {
      return null;
    }

    // Corroborating anchors prevent short/ambiguous titles or prefix-only
    // subtitle matches from picking up unrelated videos.
    final hasPersonAnchor = anchorPeople.any(
      (person) => _hasPersonMatch(normAll, person),
    );
    final hasYearAnchor =
        movie.releaseYear != null &&
        (_containsPhrase(normAll, '${movie.releaseYear}') ||
            _containsPhrase(normAll, '${movie.releaseYear! - 1}'));
    final hasFilmContextAnchor = _hasAnyPhrase(
      '$normVideoTitle $normTags ${normDesc.length > 500 ? normDesc.substring(0, 500) : normDesc}',
      _filmMusicContextKeywords,
    );

    final needsCorroboration =
        matchedVariant.isAmbiguousSingleWord || matchedVariant.isPrefixOnly;
    if (needsCorroboration &&
        !hasPersonAnchor &&
        !hasFilmContextAnchor) {
      return null;
    }

    // Also require person/year/film anchor if match came ONLY from tags/description credits
    if (!inVideoTitle &&
        (inTags || inDescLeadCredits) &&
        !hasPersonAnchor &&
        !hasYearAnchor &&
        !hasFilmContextAnchor) {
      return null;
    }

    var score = 0;
    if (inVideoTitle) {
      score += matchedVariant.isFull ? 12 : 8;
    } else if (inTags) {
      score += 7;
    } else if (inDescLeadCredits) {
      score += 5;
    }

    if (isMusicCategory) score += 4;
    if (hasMusicKeywordInTitle) {
      score += 5;
    } else if (hasMusicKeywordInMeta) {
      score += 2;
    }
    if (hasPersonAnchor) score += 5;
    if (hasYearAnchor) score += 3;
    if (hasFilmContextAnchor) score += 3;

    if (normVideoTitle.contains('official') || normVideoTitle.contains('video song')) {
      score += 2;
    }

    return score;
  }

  static bool _isDisqualifiedNonSong(
    String normVideoTitle,
    String normTags,
    MovieSongContext movie,
  ) {
    final normMovieTitle = normalizeText('${movie.title} ${movie.originalTitle}');

    // Hard block non-music videos unless the movie title itself includes that word
    for (final blocked in _hardNonSongKeywords) {
      if (!normMovieTitle.contains(blocked) &&
          _containsPhrase(normVideoTitle, blocked)) {
        return true;
      }
    }

    // Block covers, mashups, slowed+reverb, karaoke, ringtones, tutorials, status clips
    for (final derivative in _derivativeOrSpamKeywords) {
      if (!normMovieTitle.contains(derivative) &&
          _containsPhrase('$normVideoTitle $normTags', derivative)) {
        return true;
      }
    }

    // Block trailers/teasers/glimpses unless explicitly labeled as a song/audio/OST/BGM
    final hasTrailerWord = _hasAnyPhrase(normVideoTitle, _trailerOnlyKeywords);
    final hasExplicitSongWord = _hasAnyPhrase(
      normVideoTitle,
      const [
        'song',
        'songs',
        'lyrical',
        'lyric',
        'audio',
        'jukebox',
        'ost',
        'soundtrack',
        'bgm',
        'theme music',
        'music video',
      ],
    );
    if (hasTrailerWord && !hasExplicitSongWord) {
      return true;
    }

    return false;
  }

  static List<_TitleVariant> _buildTitleVariants(MovieSongContext movie) {
    final seen = <String>{};
    final result = <_TitleVariant>[];

    void addCandidate(String raw, {required bool isPrefixOnly}) {
      final clean = normalizeText(_stripParenthetical(raw));
      if (clean.length < 2 || !seen.add(clean)) return;
      final words = clean.split(' ').where((w) => w.isNotEmpty).toList();
      final isSingleWord = words.length <= 1;
      result.add(
        _TitleVariant(
          phrase: clean,
          isFull: !isPrefixOnly,
          isPrefixOnly: isPrefixOnly,
          isAmbiguousSingleWord: isSingleWord,
        ),
      );
    }

    if (movie.title.trim().isNotEmpty) {
      addCandidate(movie.title, isPrefixOnly: false);
      final colonIdx = movie.title.indexOf(':');
      if (colonIdx >= 3) {
        addCandidate(movie.title.substring(0, colonIdx), isPrefixOnly: true);
      }
    }
    if (movie.originalTitle.trim().isNotEmpty) {
      addCandidate(movie.originalTitle, isPrefixOnly: false);
      final colonIdx = movie.originalTitle.indexOf(':');
      if (colonIdx >= 3) {
        addCandidate(
          movie.originalTitle.substring(0, colonIdx),
          isPrefixOnly: true,
        );
      }
    }

    return result;
  }

  static bool _hasPersonMatch(String normText, String normPerson) {
    if (_containsPhrase(normText, normPerson)) return true;
    // Allow matching multi-part names where surname/distinctive part is >= 5 chars
    final parts = normPerson.split(' ').where((p) => p.length >= 5).toList();
    if (parts.length >= 2) {
      return _containsPhrase(normText, parts.last);
    }
    return false;
  }

  static bool _hasAnyPhrase(String haystack, List<String> phrases) {
    for (final p in phrases) {
      if (_containsPhrase(haystack, p)) return true;
    }
    return false;
  }

  static bool _containsPhrase(String haystack, String phrase) {
    if (haystack.isEmpty || phrase.isEmpty) return false;
    final hasAsciiOnly = RegExp(r'^[a-z0-9 ]+$').hasMatch(phrase);
    if (!hasAsciiOnly) {
      return haystack.contains(phrase);
    }
    final pattern = RegExp('(^| )${RegExp.escape(phrase)}( |\$)');
    return pattern.hasMatch(haystack);
  }

  static int? _extractSequelNumber(
    String norm,
    List<_TitleVariant> variants,
  ) {
    if (norm.isEmpty) return null;
    const tokenPattern = r'(1|2|3|4|5|one|two|three|four|five|i|ii|iii|iv|v)';
    final explicitMarker = RegExp(
      '(?:^| )(?:part|chapter|vol|volume) $tokenPattern(?: |\$)',
    ).firstMatch(norm);
    String? rawToken = explicitMarker?.group(1);

    if (rawToken == null) {
      for (final v in variants) {
        final baseWords = v.phrase.split(' ');
        // Strip trailing sequel token from full variant to get root title
        final stripped = v.phrase.replaceFirst(
          RegExp(' $tokenPattern\$'),
          '',
        );
        final root = stripped.length >= 3
            ? stripped
            : (baseWords.first.length >= 3 ? baseWords.first : '');
        if (root.isEmpty) continue;
        final afterTitle = RegExp(
          '(?:^| )${RegExp.escape(root)} $tokenPattern(?: |\$)',
        ).firstMatch(norm);
        if (afterTitle != null) {
          rawToken = afterTitle.group(1);
          break;
        }
      }
    }

    switch (rawToken) {
      case '1':
      case 'i':
      case 'one':
        return 1;
      case '2':
      case 'ii':
      case 'two':
        return 2;
      case '3':
      case 'iii':
      case 'three':
        return 3;
      case '4':
      case 'iv':
      case 'four':
        return 4;
      case '5':
      case 'v':
      case 'five':
        return 5;
      default:
        return int.tryParse(rawToken ?? '');
    }
  }

  static String _stripParenthetical(String input) {
    return input.replaceAll(RegExp(r'\([^)]*\)'), ' ').trim();
  }

  static String normalizeText(String input) {
    return input
        .toLowerCase()
        .replaceAll(_aposRegex, '')
        .replaceAll(_nonWordAsciiRegex, ' ')
        .replaceAll(_spaceRegex, ' ')
        .trim();
  }

  static const List<String> _songKeywords = [
    'song',
    'songs',
    'lyrical',
    'lyric video',
    'lyrics',
    'official audio',
    'audio song',
    'full audio',
    'full song',
    'video song',
    'music video',
    'jukebox',
    'soundtrack',
    'ost',
    'bgm',
    'theme song',
    'theme music',
    'album',
    'singer',
    'composed by',
    'music by',
  ];

  static const List<String> _filmMusicContextKeywords = [
    'movie',
    'film',
    'cinema',
    'motion picture',
    'original motion picture',
    'soundtrack',
    'ost',
    'bgm',
    'starring',
    'directed by',
    'music by',
    'composed by',
    'lyrics by',
    'jukebox',
    'lyrical',
    'song from',
    'from the film',
    'from the movie',
    't series',
    'sony music',
    'saregama',
    'think music',
    'aditya music',
    'lahari music',
    'muzikk',
    'muzik247',
    'sun tv',
    'zee music',
    'yrf',
    'tips official',
    'junglee music',
  ];

  static const List<String> _hardNonSongKeywords = [
    'reaction',
    'reacts to',
    'reacting',
    'movie review',
    'public review',
    'film review',
    'explained',
    'ending explained',
    'breakdown',
    'box office',
    'collection report',
    'interview',
    'press meet',
    'success meet',
    'full movie',
    'full film',
    'roast',
    'spoof',
    'parody',
    'making video',
    'behind the scenes',
    'deleted scene',
    'sneak peek',
    'episode',
  ];

  static const List<String> _derivativeOrSpamKeywords = [
    'dance cover',
    'piano cover',
    'guitar cover',
    'violin cover',
    'flute cover',
    'drum cover',
    'acoustic cover',
    'vocal cover',
    'song cover',
    'unplugged cover',
    'covered by',
    'ai cover',
    'fan made',
    'whatsapp status',
    'status video',
    'slowed',
    'reverb',
    '8d audio',
    'nightcore',
    'sped up',
    'karaoke',
    'piano tutorial',
    'guitar lesson',
    'choreography tutorial',
    'ringtone',
    'shorts',
    'mashup',
  ];

  static const List<String> _trailerOnlyKeywords = [
    'official trailer',
    'theatrical trailer',
    'trailer',
    'teaser',
    'first look',
    'glimpse',
  ];
}

class _TitleVariant {
  final String phrase;
  final bool isFull;
  final bool isPrefixOnly;
  final bool isAmbiguousSingleWord;

  const _TitleVariant({
    required this.phrase,
    required this.isFull,
    required this.isPrefixOnly,
    required this.isAmbiguousSingleWord,
  });
}

class _ScoredSong {
  final MovieSongCandidate video;
  final int score;

  const _ScoredSong({required this.video, required this.score});
}
