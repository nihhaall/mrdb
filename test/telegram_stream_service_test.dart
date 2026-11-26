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
