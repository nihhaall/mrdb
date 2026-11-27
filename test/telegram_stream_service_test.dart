import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';

void main() {
  group('TelegramStreamService', () {
    test('normalizes /watch/ links into direct byte-range stream URLs', () {
      const watchUrl =
          'https://instant-dierdre-fsharebot.koyeb.app/watch/42/sample_movie.mkv?hash=a1b2c3';
      const directUrl =
          'https://instant-dierdre-fsharebot.koyeb.app/42/sample_movie.mkv?hash=a1b2c3';

      expect(
        TelegramStreamService.normalizeDirectStreamUrl(watchUrl),
        directUrl,
      );
      expect(
        TelegramStreamService.normalizeDirectStreamUrl(directUrl),
        directUrl,
      );
    });

    test('parses TelegramVideoItem with stream_code and MKV metadata', () {
      final item = TelegramVideoItem.fromJson(
        {
          'msg_id': 88,
          'hash': 'xyz123',
          'stream_code': 'MRDB-88-XYZ123',
          'title': 'Inception Test Clip',
          'file_name': 'Inception.1080p.mkv',
          'file_size': 1572864000,
          'mime_type': 'video/x-matroska',
          'tmdb_id': 27205,
          'stream_url':
              'https://instant-dierdre-fsharebot.koyeb.app/88/Inception.1080p.mkv?hash=xyz123',
        },
      );

      expect(item.isMkv, isTrue);
      expect(item.formatBadge, 'MKV');
      expect(item.streamCode, 'MRDB-88-XYZ123');
      expect(item.tmdbId, 27205);
      expect(TelegramStreamService.formatBytes(item.fileSize), '1.5 GB');
    });

    test('synthesizes streamCode when missing in legacy JSON payloads', () {
      final item = TelegramVideoItem.fromJson(
        {
          'msg_id': 12,
          'hash': 'ab12cd',
          'file_name': 'Sample.mp4',
          'stream_url': 'http://127.0.0.1:8080/12/Sample.mp4?hash=ab12cd',
        },
      );
      expect(item.streamCode, 'MRDB-12-AB12CD');
      expect(item.formatBadge, 'MP4');
    });

    test('analyzeFileNameLocally extracts clean title, year, quality, and languages', () {
      final res = TelegramStreamService.analyzeFileNameLocally(
        '[MS] Ranabaali (2026) WEB-DL 1080p [Hin + Mal + Kan] @MovieShopLinks.mkv',
      );
      expect(res.title, 'Ranabaali');
      expect(res.year, 2026);
      expect(res.quality, '1080p');
      expect(res.language, 'Hindi, Malayalam, Kannada');

      final res2 = TelegramStreamService.analyzeFileNameLocally(
        'Sumathi.Valavu.2025.Malayalam.HDRip.1080p.HEVC.mkv.mkv',
      );
      expect(res2.title, 'Sumathi Valavu');
      expect(res2.year, 2025);
      expect(res2.quality, '1080p');
      expect(res2.language, 'Malayalam');

      final res3 = TelegramStreamService.analyzeFileNameLocally(
        'Breaking.Bad.S02E05.2009.1080p.WEB-DL.mkv',
      );
      expect(res3.isSeries, isTrue);
      expect(res3.season, 2);
      expect(res3.episode, 5);
      expect(res3.title, 'Breaking Bad S02E05');
      expect(res3.searchQuery, 'Breaking Bad');
      expect(res3.year, 2009);

      final res4 = TelegramStreamService.analyzeFileNameLocally(
        '[MS] Spider Man Brand New Day (2026) HDRip [Tamil + .mkv',
        existingTitle: 'Spider-Man: Brand New Day (2026) Tamil, Telugu, Hindi HDRip',
      );
      expect(res4.searchQuery, 'Spider-Man: Brand New Day');

      final res5 = TelegramStreamService.analyzeFileNameLocally(
        'Agent.Kim.Reactivated.S01E01.1080p.mkv',
        existingTitle: 'Agent Kim Reactivated S01E01 (2026) Korean 1080p',
      );
      expect(res5.searchQuery, 'Agent Kim Reactivated');
    });

    test('parseAiSuggestionJson parses fenced AI JSON and series season/episode', () {
      const aiReply = '''
```json
{"title": "Pushpa 2: The Rule", "media_type": "movie", "season": null, "episode": null, "year": 2024, "quality": "2160p", "language": ["Malayalam", "Tamil"]}
```
''';
      final parsed = TelegramStreamService.parseAiSuggestionJson(
        aiReply,
        rawFileName: '@TamilMV_Pushpa_2_The_Rule_2024_Mal_Tam_4K.mkv',
        aiProvider: 'Gemini',
      );
      expect(parsed, isNotNull);
      expect(parsed!.usedAi, isTrue);
      expect(parsed.aiProvider, 'Gemini');
      expect(parsed.isSeries, isFalse);
      expect(parsed.title, 'Pushpa 2: The Rule (2024) Malayalam, Tamil 4K');
      expect(parsed.year, 2024);
      expect(parsed.quality, '4K');
      expect(parsed.language, 'Malayalam, Tamil');

      const seriesReply =
          '{"title": "Panchayat", "formatted_name": "Panchayat S03E04 (2024) Hindi 1080p", "media_type": "tv", "season": 3, "episode": 4, "year": 2024, "quality": "1080p", "language": "Hindi"}';
      final seriesParsed = TelegramStreamService.parseAiSuggestionJson(
        seriesReply,
        rawFileName: 'Panchayat.S03E04.2024.Hindi.1080p.mkv',
      );
      expect(seriesParsed, isNotNull);
      expect(seriesParsed!.isSeries, isTrue);
      expect(seriesParsed.season, 3);
      expect(seriesParsed.episode, 4);
      expect(seriesParsed.title, 'Panchayat S03E04 (2024) Hindi 1080p');
      expect(seriesParsed.searchQuery, 'Panchayat');
      expect(seriesParsed.year, 2024);

      const fallbackLangReply =
          '{"title": "Kantara", "media_type": "movie", "year": 2022, "quality": "1080p", "language": null, "original_language": "Kannada"}';
      final origLangParsed = TelegramStreamService.parseAiSuggestionJson(
        fallbackLangReply,
        rawFileName: 'Kantara.2022.1080p.HEVC.mkv',
      );
      expect(origLangParsed, isNotNull);
      expect(origLangParsed!.language, 'Kannada');
      expect(origLangParsed.title, 'Kantara (2022) Kannada 1080p');
      expect(TelegramStreamService.mapLanguageCode('kn'), 'Kannada');
      expect(TelegramStreamService.mapLanguageCode('ml'), 'Malayalam');
    });

    test('validates HTTP/HTTPS stream URLs and base URLs', () {
      expect(
        TelegramStreamService.normalizeBaseUrl('instant-dierdre-fsharebot.koyeb.app/'),
        'https://instant-dierdre-fsharebot.koyeb.app',
      );
      expect(
        TelegramStreamService.isValidStreamUrl('https://instant-dierdre-fsharebot.koyeb.app/1/a.mkv'),
        isTrue,
      );
      expect(TelegramStreamService.isValidStreamUrl('MRDB-12-AB12CD'), isFalse);
    });

    test('parses edited metadata, linked TMDB fields, audio tracks, and cleanSearchTitle', () {
      final item = TelegramVideoItem.fromJson(
        {
          'msg_id': 90,
          'hash': 'm90abc',
          'stream_code': 'MRDB-90-M90ABC',
          'title': 'Maaran (Extended Cut)',
          'file_name': 'Maaran.2022.1080p.WEB-DL.x265.mkv',
          'file_size': 1850000000,
          'mime_type': 'video/x-matroska',
          'year': 2022,
          'quality': '4K',
          'language': 'Tamil • Malayalam',
          'overview': 'Clean master audio',
          'metadata_edited': true,
          'hidden_for_users': true,
          'tmdb_id': 775544,
          'tmdb_title': 'Maaran',
          'tmdb_poster': '/poster.jpg',
          'tmdb_year': '2022',
          'disabled_audio_indices': [1],
          'audio_tracks': [
            {
              'index': 0,
              'stream_index': 1,
              'language': 'tam',
              'codec': 'eac3',
              'channels': '5.1',
              'title': 'Tamil',
              'is_default': true,
            },
            {
              'index': 1,
              'stream_index': 2,
              'language': 'hin',
              'codec': 'aac',
              'channels': 'stereo',
              'title': 'Hindi',
              'is_default': false,
            },
          ],
          'stream_url': 'http://127.0.0.1:8080/90/Maaran.mkv?hash=m90abc',
        },
      );

      expect(item.metadataEdited, isTrue);
      expect(item.hiddenForUsers, isTrue);
      expect(item.year, 2022);
      expect(item.formatBadge, '4K');
      expect(item.language, 'Tamil • Malayalam');
      expect(item.tmdbTitle, 'Maaran');
      expect(item.tmdbPoster, '/poster.jpg');
      expect(item.disabledAudioIndices, [1]);
      expect(item.audioTracks.length, 2);
      expect(item.audioTracks.first.displayLabel, 'Tamil • EAC3 • 5.1');

      final roundTrip = TelegramVideoItem.fromJson(item.toJson());
      expect(roundTrip.tmdbId, 775544);
      expect(roundTrip.disabledAudioIndices, [1]);
      expect(roundTrip.audioTracks.length, 2);

      final unlinked = item.copyWith(clearTmdb: true, clearYear: true);
      expect(unlinked.tmdbId, isNull);
      expect(unlinked.year, isNull);

      expect(
        TelegramStreamService.cleanSearchTitle('Dune.Part.Two.2024.1080p.WEB-DL.x265.HEVC.mkv'),
        'Dune Part Two 2024',
      );
      expect(
        TelegramStreamService.cleanSearchTitle(
          '🎬🔥 @MV_Rockers - Maaran (2022) [1080p WEB-DL HEVC] ❤️ @channel_id.mkv',
        ),
        'Maaran (2022)',
      );
      expect(
        TelegramStreamService.cleanSearchTitle(
          '[@Channel_Hub] Avatar https://t.me/movies ⚡✅.mp4',
        ),
        'Avatar',
      );
    });

    test('dedupeVideos prefers owner-edited entries and drops pre-edit duplicates', () {
      const oldUnedited = TelegramVideoItem(
        msgId: 1804639,
        hash: 'AgADhS',
        streamCode: 'MRDB-1804639-AGADHS',
        title: '[MS] I\'m Game (2026) Malayalam HDRip 720p HEVC .mkv',
        fileName: '[MS] I\'m Game (2026) Malayalam HDRip 720p HEVC .mkv',
        metadataEdited: false,
        streamUrl: 'http://127.0.0.1:8080/1804639/game.mkv?hash=AgADhS',
      );
      const editedUpdated = TelegramVideoItem(
        msgId: 1804643,
        hash: 'AgADhS',
        streamCode: 'MRDB-1804643-AGADHS',
        title: 'I\'m Game (2026)',
        fileName: '[MS] I\'m Game (2026) Malayalam HDRip 720p HEVC .mkv',
        metadataEdited: true,
        streamUrl: 'http://127.0.0.1:8080/1804643/game.mkv?hash=AgADhS',
      );

      final deduped = TelegramStreamService.dedupeVideos([oldUnedited, editedUpdated]);
      expect(deduped.length, 1);
      expect(deduped.first.msgId, 1804643);
      expect(deduped.first.title, 'I\'m Game (2026)');
    });

    test(
        'pickBestTmdbMatch rejects unrelated +/-1 year hits like Children of Blood and Bone when matching Kandan',
        () {
      final results = <Map<String, dynamic>>[
        {
          'id': 1806987,
          'title': 'Kandan',
          'original_title': 'Kandan',
          'original_language': 'ml',
          'release_date': '',
          'popularity': 0.1,
        },
        {
          'id': 621304,
          'title': 'Children of Blood and Bone',
          'original_title': 'Children of Blood and Bone',
          'original_language': 'en',
          'release_date': '2027-01-14',
          'popularity': 5.3954,
        },
      ];

      final picked = TelegramStreamService.pickBestTmdbMatch(
        results,
        'Kandan',
        expectedYear: 2026,
        expectedLanguage: 'Malayalam',
      );
      expect(picked, isNotNull);
      expect(picked!['id'], 1806987);
      expect(picked['title'], 'Kandan');

      final noOverlap = TelegramStreamService.pickBestTmdbMatch(
        [results[1]],
        'Kandan',
        expectedYear: 2026,
        expectedLanguage: 'Malayalam',
      );
      expect(noOverlap, isNull);
    });
  });

  group('VideoFrameThumbnailService', () {
    test('deduplicates requests and falls back when primary returns null',
        () async {
      int primaryCalls = 0;
      int fallbackCalls = 0;
      int notifyCount = 0;

      final service = VideoFrameThumbnailService.forTest(
        primaryExtractor: (_) async {
          primaryCalls++;
          return null;
        },
        fallbackExtractor: (_) async {
          fallbackCalls++;
          return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
        },
        saveFrame: (key, bytes) async => '/tmp/frame_$key.jpg',
      );
      service.addListener(() => notifyCount++);

      const item = TelegramVideoItem(
        msgId: 101,
        hash: 'abc123',
        streamCode: 'MRDB-101-ABC123',
        title: 'Test Movie',
        fileName: 'Test.Movie.mkv',
        streamUrl: 'https://example.com/101/Test.Movie.mkv?hash=abc123',
      );

      service.requestFrame(item);
      service.requestFrame(item); // Duplicate while in-flight/cached

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(primaryCalls, 1);
      expect(fallbackCalls, 1);
      expect(service.pathFor('MRDB-101-ABC123'), '/tmp/frame_MRDB-101-ABC123.jpg');
      expect(service.isExtracting('MRDB-101-ABC123'), isFalse);
      expect(notifyCount, greaterThanOrEqualTo(2));
    });

    test('caches failures until clearFailedCache is called', () async {
      int attempts = 0;
      final service = VideoFrameThumbnailService.forTest(
        primaryExtractor: (_) async {
          attempts++;
          return null;
        },
      );

      const item = TelegramVideoItem(
        msgId: 202,
        hash: 'def456',
        streamCode: 'MRDB-202-DEF456',
        title: 'Broken Movie',
        fileName: 'Broken.mkv',
        streamUrl: 'https://example.com/202/Broken.mkv?hash=def456',
      );

      service.requestFrame(item);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, 1);

      // Should not retry while cached as failed
      service.requestFrame(item);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, 1);

      // Clearing failed cache allows retry
      service.clearFailedCache();
      service.requestFrame(item);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, 2);
    });
  });
}
