import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/stream_proxy_service.dart';

void main() {
  group('StreamProxyService.normalizeUpstreamUri', () {
    test('rewrites FileToLinkBot mkv path with hash query to hash+id path', () {
      final input = Uri.parse(
        'https://instant-dierdre-fsharebot.koyeb.app/1804655/Sumathi%20Valavu%20HEVC.mkv?hash=AgADax',
      );
      final normalized = StreamProxyService.normalizeUpstreamUri(input);
      expect(
        normalized.toString(),
        'https://instant-dierdre-fsharebot.koyeb.app/AgADax1804655',
      );
    });

    test('preserves port and extra query parameters', () {
      final input = Uri.parse(
        'http://127.0.0.1:8080/1804651/Movie.mkv?hash=AgAD8y&dl=1',
      );
      final normalized = StreamProxyService.normalizeUpstreamUri(input);
      expect(
        normalized.toString(),
        'http://127.0.0.1:8080/AgAD8y1804651?dl=1',
      );
    });

    test('leaves transcode and non-bot URLs untouched', () {
      final transcode = Uri.parse(
        'https://instant-dierdre-fsharebot.koyeb.app/transcode/1804651/remux?hash=AgAD8y&fmt=mp4',
      );
      final generic = Uri.parse('https://cdn.example.com/movies/sample.mkv');
      expect(
        StreamProxyService.normalizeUpstreamUri(transcode).toString(),
        transcode.toString(),
      );
      expect(
        StreamProxyService.normalizeUpstreamUri(generic).toString(),
        generic.toString(),
      );
    });
  });

  group('StreamProxyService disk chunk cache', () {
    test('serves backward seek from disk cache after RAM eviction', () async {
      const chunkSz = 1024;
      const totalChunks = 5;
      final payload = Uint8List.fromList(
        List<int>.generate(chunkSz * totalChunks, (i) => i % 251),
      );
      final requestedRanges = <String>[];

      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
        requestedRanges.add(range);
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        final start = match != null ? int.parse(match.group(1)!) : 0;
        final end = (match != null && match.group(2)!.isNotEmpty)
            ? int.parse(match.group(2)!)
            : payload.length - 1;
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${payload.length}',
        );
        req.response.headers.contentLength = end - start + 1;
        req.response.add(payload.sublist(start, end + 1));
        await req.response.close();
      });

      final proxy = StreamProxyService(
        chunkSize: chunkSz,
        maxCachedChunks: 2,
        maxDiskCachedChunks: 10,
        enableDiskCache: true,
      );

      try {
        final proxyUrl = await proxy.start(
          'http://127.0.0.1:${upstream.port}/AgADax1804655',
        );
        final client = HttpClient();

        Future<List<int>> fetchRange(int start, int end) async {
          final req = await client.getUrl(Uri.parse(proxyUrl));
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
          final resp = await req.close();
          final builder = BytesBuilder(copy: false);
          await for (final chunk in resp) {
            builder.add(chunk);
          }
          return builder.takeBytes();
        }

        // Stream all 5 chunks; RAM cache (max 2) will evict chunk 0.
        final firstPass = await fetchRange(0, payload.length - 1);
        expect(firstPass, payload);
        expect(requestedRanges.length, 1);

        // Give async disk write a moment to flush, then seek back to chunk 0.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final rewindBytes = await fetchRange(0, chunkSz - 1);
        expect(rewindBytes, payload.sublist(0, chunkSz));
        // Served from disk cache without another upstream request.
        expect(requestedRanges.length, 1);

        client.close(force: true);
      } finally {
        await proxy.dispose();
        await upstream.close(force: true);
      }
    });
  });
}
