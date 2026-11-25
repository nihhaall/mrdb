import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/telegram_stream_service.dart';

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
}
