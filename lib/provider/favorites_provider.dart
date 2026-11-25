import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/services/network_service.dart';

class FavoritesProvider extends ChangeNotifier {
  String? _clientId;
  List<Map<String, dynamic>> _favorites = [];
  final Set<String> _likedMovieIds = {};
  final Set<String> _loadingMovieIds = {};
  bool _isLoading = true;
  bool _hasError = false;
  NetworkFailureType _failureType = NetworkFailureType.none;
  String? _errorMessage;
  StreamSubscription<QuerySnapshot>? _subscription;
  Timer? _initialLoadTimer;

  String? get clientId => _clientId;
  List<Map<String, dynamic>> get favorites => List.unmodifiable(_favorites);
  int get count => _favorites.length;
  bool get isLoading => _isLoading;
  bool get isEmpty => _favorites.isEmpty;
  bool get hasError => _hasError;
  NetworkFailureType get failureType => _failureType;
  String? get errorMessage => _errorMessage;

  double get averageTmdbRating {
    if (_favorites.isEmpty) return 0.0;
    double total = 0;
    int rated = 0;
    for (final item in _favorites) {
      final raw = item['rating'];
      final val = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '') ?? 0.0;
      if (val > 0) {
        total += val;
        rated++;
      }
    }
    return rated > 0 ? total / rated : 0.0;
  }

  String get topDecade {
    if (_favorites.isEmpty) return '—';
    final counts = <String, int>{};
    for (final item in _favorites) {
      final yearStr = (item['year'] ?? '').toString();
      if (yearStr.length >= 4) {
        final y = int.tryParse(yearStr.substring(0, 4));
        if (y != null) {
          final decade = '${(y ~/ 10) * 10}s';
          counts[decade] = (counts[decade] ?? 0) + 1;
        }
      }
    }
    if (counts.isEmpty) return '—';
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return top.key;
  }

  bool isLiked(dynamic movieId) {
    if (movieId == null) return false;
    return _likedMovieIds.contains(movieId.toString());
  }

  bool isMovieLoading(dynamic movieId) {
    if (movieId == null) return false;
    return _loadingMovieIds.contains(movieId.toString());
  }

  void updateClient(String? newClientId) {
    if (newClientId == null || newClientId.isEmpty) return;
    if (_clientId == newClientId && _subscription != null) return;
    _clientId = newClientId;
    _subscribeToFavorites();
  }

  void _subscribeToFavorites() {
    if (_clientId == null || _clientId!.isEmpty) return;
    _subscription?.cancel();
    _initialLoadTimer?.cancel();

    // Prevent endless loading shimmer if offline on first launch
    _initialLoadTimer = Timer(const Duration(seconds: 6), () async {
      if (!_isLoading) return;
      final online = await NetworkService.instance.hasInternet();
      if (_isLoading) {
        _isLoading = false;
        if (!online && _favorites.isEmpty) {
          _hasError = true;
          _failureType = NetworkFailureType.noInternet;
          _errorMessage = 'No internet connection. Saved favorites will appear once online.';
        } else if (_favorites.isEmpty) {
          _hasError = true;
          _failureType = NetworkFailureType.slowOrTimeout;
          _errorMessage = 'Taking too long to sync favorites. Tap retry.';
        }
        notifyListeners();
      }
    });

    _subscription = FirebaseFirestore.instance
        .collection(AppConstants.phone)
        .doc(_clientId)
        .collection('liked')
        .where('delete', isEqualTo: false)
        .snapshots()
        .listen(
      (snapshot) {
        _initialLoadTimer?.cancel();
        final List<Map<String, dynamic>> items = [];
        final Set<String> ids = {};

        for (final doc in snapshot.docs) {
          final data = Map<String, dynamic>.from(doc.data());
          data['id'] = doc.id;
          final movId = (data['movId'] ?? doc.id).toString();
          data['movId'] = int.tryParse(movId) ?? movId;
          ids.add(movId);
          ids.add(doc.id);
          items.add(data);
        }

        // Sort descending by timeStamp if available
        items.sort((a, b) {
          final tA = a['timeStamp'];
          final tB = b['timeStamp'];
          if (tA is Timestamp && tB is Timestamp) {
            return tB.compareTo(tA);
          }
          return 0;
        });

        _favorites = items;
        _likedMovieIds
          ..clear()
          ..addAll(ids);
        _isLoading = false;
        _hasError = false;
        _failureType = NetworkFailureType.none;
        _errorMessage = null;
        notifyListeners();
      },
      onError: (e) async {
        _initialLoadTimer?.cancel();
        debugPrint('FavoritesProvider stream error: $e');
        final classified = await NetworkService.instance.classifyError(e);
        _isLoading = false;
        _hasError = _favorites.isEmpty;
        _failureType = classified.type;
        _errorMessage = classified.message;
        notifyListeners();
      },
    );
  }

  Future<void> refresh() async {
    if (_clientId == null || _clientId!.isEmpty) return;
    _hasError = false;
    _failureType = NetworkFailureType.none;
    _errorMessage = null;

    final hasNet = await NetworkService.instance.hasInternet(forceRefresh: true);
    if (!hasNet && _favorites.isEmpty) {
      _isLoading = false;
      _hasError = true;
      _failureType = NetworkFailureType.noInternet;
      _errorMessage = 'No internet connection. Please check Wi-Fi or mobile data.';
      notifyListeners();
      return;
    }

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_clientId)
          .collection('liked')
          .where('delete', isEqualTo: false)
          .get()
          .timeout(const Duration(seconds: 8));

      final List<Map<String, dynamic>> items = [];
      final Set<String> ids = {};

      for (final doc in snapshot.docs) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        final movId = (data['movId'] ?? doc.id).toString();
        data['movId'] = int.tryParse(movId) ?? movId;
        ids.add(movId);
        ids.add(doc.id);
        items.add(data);
      }

      items.sort((a, b) {
        final tA = a['timeStamp'];
        final tB = b['timeStamp'];
        if (tA is Timestamp && tB is Timestamp) {
          return tB.compareTo(tA);
        }
        return 0;
      });

      _favorites = items;
      _likedMovieIds
        ..clear()
        ..addAll(ids);
      _isLoading = false;
      _hasError = false;
      _failureType = NetworkFailureType.none;
      _errorMessage = null;
      notifyListeners();
    } catch (e) {
      debugPrint('FavoritesProvider refresh error: $e');
      final classified = await NetworkService.instance.classifyError(e);
      _isLoading = false;
      _hasError = _favorites.isEmpty;
      _failureType = classified.type;
      _errorMessage = classified.message;
      notifyListeners();
    }
  }

  /// Toggles favorite status for a movie.
  /// Returns `true` if movie is now liked, `false` if unliked.
  Future<bool> toggleFavorite({
    required dynamic movieId,
    required String title,
    String? posterPath,
    String? backdropPath,
    String? releaseDate,
    double? rating,
  }) async {
    if (movieId == null || _clientId == null || _clientId!.isEmpty) {
      return false;
    }
    final idStr = movieId.toString();
    final currentlyLiked = isLiked(idStr);

    _loadingMovieIds.add(idStr);
    notifyListeners();

    try {
      if (currentlyLiked) {
        await removeFavorite(movieId);
        return false;
      } else {
        await addFavorite(
          movieId: movieId,
          title: title,
          posterPath: posterPath,
          backdropPath: backdropPath,
          releaseDate: releaseDate,
          rating: rating,
        );
        return true;
      }
    } finally {
      _loadingMovieIds.remove(idStr);
      notifyListeners();
    }
  }

  Future<void> addFavorite({
    required dynamic movieId,
    required String title,
    String? posterPath,
    String? backdropPath,
    String? releaseDate,
    double? rating,
  }) async {
    if (movieId == null || _clientId == null || _clientId!.isEmpty) return;
    final idStr = movieId.toString();

    String formattedPoster = '';
    if (posterPath != null && posterPath.isNotEmpty) {
      if (posterPath.startsWith('http://') ||
          posterPath.startsWith('https://')) {
        formattedPoster = posterPath;
      } else {
        formattedPoster = '${AppConstants.baseImageUrl}$posterPath';
      }
    }

    final movieData = {
      'id': int.tryParse(idStr) ?? idStr,
      'movId': int.tryParse(idStr) ?? idStr,
      'title': title,
      'img': formattedPoster,
      'poster_path': posterPath,
      'backdrop_path': backdropPath,
      'year': releaseDate ?? '',
      'rating': rating ?? 0.0,
      'timeStamp': DateTime.now(),
      'delete': false,
    };

    // Optimistic local update
    _likedMovieIds.add(idStr);
    _favorites.removeWhere(
      (item) => (item['id'] ?? item['movId']).toString() == idStr,
    );
    _favorites.insert(0, movieData);
    notifyListeners();

    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_clientId)
          .collection('liked')
          .doc(idStr)
          .set(movieData, SetOptions(merge: true))
          .timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // Firestore offline persistence queues the write and syncs once back online.
      debugPrint('Favorite queued for offline/slow sync: $idStr');
    } catch (e) {
      debugPrint('Error adding favorite: $e');
      _likedMovieIds.remove(idStr);
      _favorites.removeWhere(
        (item) => (item['id'] ?? item['movId']).toString() == idStr,
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> removeFavorite(dynamic movieId) async {
    if (movieId == null || _clientId == null || _clientId!.isEmpty) return;
    final idStr = movieId.toString();

    // Optimistic local removal
    _likedMovieIds.remove(idStr);
    _favorites.removeWhere(
      (item) => (item['id'] ?? item['movId']).toString() == idStr,
    );
    notifyListeners();

    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_clientId)
          .collection('liked')
          .doc(idStr)
          .update({'delete': true})
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Error removing favorite (or offline queued): $e');
    }
  }

  Future<void> restoreFavorite(Map<String, dynamic> item, [int? index]) async {
    if (_clientId == null || _clientId!.isEmpty) return;
    final idStr = (item['id'] ?? item['movId'] ?? '').toString();
    if (idStr.isEmpty) return;

    // Optimistic local restore
    _likedMovieIds.add(idStr);
    final targetIndex =
        (index != null && index >= 0 && index <= _favorites.length)
            ? index
            : 0;
    _favorites.insert(targetIndex, item);
    notifyListeners();

    try {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_clientId)
          .collection('liked')
          .doc(idStr)
          .set({
        ...item,
        'delete': false,
        'timeStamp': DateTime.now(),
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 4));
    } catch (e) {
      debugPrint('Error restoring favorite (or offline queued): $e');
    }
  }

  Future<void> clearAll() async {
    if (_clientId == null || _clientId!.isEmpty) return;
    final oldFavorites = List<Map<String, dynamic>>.from(_favorites);

    // Optimistic local clear
    _likedMovieIds.clear();
    _favorites.clear();
    notifyListeners();

    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final fav in oldFavorites) {
        final docId = (fav['id'] ?? fav['movId'])?.toString();
        if (docId != null && docId.isNotEmpty) {
          final docRef = FirebaseFirestore.instance
              .collection(AppConstants.phone)
              .doc(_clientId)
              .collection('liked')
              .doc(docId);
          batch.update(docRef, {'delete': true});
        }
      }
      await batch.commit().timeout(const Duration(seconds: 4));
    } on TimeoutException {
      debugPrint('Clear all queued for offline/slow sync');
    } catch (e) {
      debugPrint('Error clearing all favorites: $e');
      _favorites = oldFavorites;
      for (final f in oldFavorites) {
        _likedMovieIds.add((f['id'] ?? f['movId']).toString());
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<({int count, double avgScore})> getPersonalRatingsSummary() async {
    if (_clientId == null || _clientId!.isEmpty) {
      return (count: 0, avgScore: 0.0);
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(_clientId)
          .collection('ratings')
          .get()
          .timeout(const Duration(seconds: 4));
      if (snap.docs.isEmpty) return (count: 0, avgScore: 0.0);
      double total = 0;
      int valid = 0;
      for (final d in snap.docs) {
        final data = d.data();
        final score = data['score'] is num
            ? (data['score'] as num).toDouble()
            : ((data['rating'] is num)
                ? (data['rating'] as num).toDouble() * 2
                : 0.0);
        if (score > 0) {
          total += score;
          valid++;
        }
      }
      return (count: valid, avgScore: valid > 0 ? total / valid : 0.0);
    } catch (_) {
      return (count: 0, avgScore: 0.0);
    }
  }

  @override
  void dispose() {
    _initialLoadTimer?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}
