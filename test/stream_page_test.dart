import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/home/navs/owner/telegram_videos_page.dart';
import 'package:mrdb/services/telegram_stream_service.dart';
import 'package:mrdb/services/video_frame_thumbnail_service.dart';
import 'package:mrdb/widgets/mkv_stream_player_page.dart';
import 'package:mrdb/widgets/movie_collection_sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // Prevent background ffmpeg/libmpv frame extraction from starting native players in unit tests.
    VideoFrameThumbnailService.instance.setPaused(true);
  });

  tearDown(() {
    VideoFrameThumbnailService.instance.clearQueueForTest();
    VideoFrameThumbnailService.instance.setPaused(false);
  });

  testWidgets(
    'TelegramVideosPage renders friendly Stream UI, Continue Watching played bar, and Code sheet',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'telegram_saved_stream_items': jsonEncode([
          {
            'msg_id': 42,
            'hash': 'abc123',
            'stream_code': 'MRDB-42-ABC123',
            'title': 'Inception.2010.1080p.mkv',
            'file_name': 'Inception.2010.1080p.mkv',
            'file_size': 1572864000,
            'mime_type': 'video/x-matroska',
            'stream_url': 'https://example.com/42/Inception.2010.1080p.mkv?hash=abc123',
          },
          {
            'msg_id': 43,
            'hash': 'def456',
            'stream_code': 'MRDB-43-DEF456',
            'title': 'Interstellar.2014.720p.mkv',
            'file_name': 'Interstellar.2014.720p.mkv',
            'file_size': 980000000,
            'mime_type': 'video/x-matroska',
            'stream_url': 'https://example.com/43/Interstellar.2014.720p.mkv?hash=def456',
          },
        ]),
        'telegram_watch_progress_v1': jsonEncode({
          'MRDB-42-ABC123': {
            'position_ms': 90000,
            'duration_ms': 600000,
            'updated_at_ms': 1700000000000,
          },
          'MRDB-43-DEF456': {
            'position_ms': 45000,
            'duration_ms': 0,
            'updated_at_ms': 1699999000000,
          },
        }),
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: TelegramVideosPage(),
        ),
      );

      // Header and search + Code bar render right away
      expect(find.text('Stream'), findsOneWidget);
      expect(find.text('Bot'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
      expect(find.text('Search movies or files...'), findsOneWidget);

      // Let async SharedPreferences + feed load complete
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // Continue Watching strip shows friendly cleaned title, resume clock, and played time bar
      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('Inception 2010 1080p'), findsOneWidget);
      expect(find.text('Resume • 01:30 / 10:00'), findsOneWidget);
      expect(find.text('Resume • 00:45'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

      // Tap Code button to open friendly bottom sheet
      await tester.tap(find.text('Code'));
      await tester.pumpAndSettle();

      expect(find.text('Stream with Code'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Stream Now'), findsOneWidget);

      // Submitting empty code shows helpful inline validation instead of closing
      await tester.tap(find.text('Stream Now'));
      await tester.pumpAndSettle();
      expect(
        find.text('Paste or type a stream code first (e.g. MRDB-...)'),
        findsOneWidget,
      );

      // Dismiss bottom sheet cleanly
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Stream with Code'), findsNothing);
    },
  );

  testWidgets(
    'TelegramVideosPage handles compact 320x480 viewport without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(
        const MaterialApp(
          home: TelegramVideosPage(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('Stream'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
    },
  );

  testWidgets(
    'MkvStreamThumbnailBackdrop shows thumbnail image when local path exists',
    (tester) async {
      // Minimal valid 1x1 PNG bytes
      const pngBytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];
      final tempDir = Directory.systemTemp.createTempSync('mrdb_thumb_test_');
      final thumbFile = File('${tempDir.path}/thumb.png')
        ..writeAsBytesSync(pngBytes);
      addTearDown(() {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MkvStreamThumbnailBackdrop(
              thumbnailPath: thumbFile.path,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'ContinueWatchResumeSheet renders last frame preview, progress, and resume actions without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const pngBytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];
      final tempDir = Directory.systemTemp.createTempSync('mrdb_last_frame_');
      final frameFile = File('${tempDir.path}/last_frame.png')
        ..writeAsBytesSync(pngBytes);
      addTearDown(() {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      var resumed = false;
      var startedOver = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ContinueWatchResumeSheet(
                title: 'Inception 2010 1080p',
                quality: '1080P',
                clock: '01:30',
                totalClock: '10:00',
                remainingLabel: '9 min left',
                fraction: 0.15,
                hasLastFrame: true,
                hasAnyFrame: true,
                previewChild: Image.file(frameFile, fit: BoxFit.cover),
                onClose: () {},
                onStartOver: () => startedOver = true,
                onResume: () => resumed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Continue Watching?'), findsOneWidget);
      expect(find.text('Last frame'), findsOneWidget);
      expect(find.text('1080P'), findsOneWidget);
      expect(find.text('Stopped at 01:30'), findsOneWidget);
      expect(find.text('10:00 • 15%'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      // Only the Resume button renders a play icon; none overlays the frame preview.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tester.tap(find.text('Resume (01:30)'));
      await tester.pump();
      expect(resumed, isTrue);

      await tester.tap(find.text('Start Over'));
      await tester.pump();
      expect(startedOver, isTrue);
    },
  );

  testWidgets(
    'Continue Watching horizontal cards display saved last frame and remaining label',
    (tester) async {
      const pngBytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];
      final tempDir = Directory.systemTemp.createTempSync('mrdb_cw_strip_');
      final frameFile = File('${tempDir.path}/cw_frame.png')
        ..writeAsBytesSync(pngBytes);
      addTearDown(() {
        try {
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      SharedPreferences.setMockInitialValues({
        'telegram_saved_stream_items': jsonEncode([
          {
            'msg_id': 99,
            'hash': 'xyz789',
            'stream_code': 'MRDB-99-XYZ789',
            'title': 'Dune.Part.Two.2024.1080p.mkv',
            'file_name': 'Dune.Part.Two.2024.1080p.mkv',
            'file_size': 2048000000,
            'mime_type': 'video/x-matroska',
            'stream_url': 'https://example.com/99/Dune.Part.Two.2024.1080p.mkv?hash=xyz789',
          },
        ]),
        'telegram_watch_progress_v1': jsonEncode({
          'MRDB-99-XYZ789': {
            'position_ms': 90000,
            'duration_ms': 600000,
            'updated_at_ms': 1700000000000,
          },
        }),
        'telegram_stream_last_frames_v1': jsonEncode({
          'MRDB-99-XYZ789': frameFile.path,
        }),
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: TelegramVideosPage(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('Dune Part Two 2024 1080p'), findsOneWidget);
      expect(find.text('Last frame'), findsNothing);
      expect(find.text('1080P'), findsOneWidget);
      expect(find.text('Resume • 01:30 / 10:00'), findsOneWidget);
      expect(find.text('9 min left'), findsOneWidget);
      expect(find.byType(Image), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'TmdbMoviePickerPage renders full-screen search page with unlink option without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TmdbMovieSelection? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await showTmdbMoviePickerSheet(
                      ctx,
                      initialQuery: 'Maaran.2022.1080p.mkv',
                      fileLabel: 'Maaran.2022.1080p.mkv',
                      currentTmdbId: 775544,
                      currentTmdbTitle: 'Maaran',
                    );
                  },
                  child: const Text('Open Picker'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Picker'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Add to Collection'), findsOneWidget);
      expect(find.text('Currently linked: Maaran'), findsOneWidget);
      expect(find.text('Unlink'), findsOneWidget);

      await tester.tap(find.text('Unlink'));
      await tester.pumpAndSettle();
      expect(popped?.unlink, isTrue);
    },
  );

  testWidgets(
    'TelegramVideosPage shows Owner/User mode toggle in AppBar for owners',
    (tester) async {
      SharedPreferences.setMockInitialValues({'is_owner': true});

      await tester.pumpWidget(
        const MaterialApp(
          home: TelegramVideosPage(),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('Owner'), findsOneWidget);
      await tester.tap(find.text('Owner'));
      await tester.pumpAndSettle();
      expect(find.text('User'), findsOneWidget);
    },
  );

  testWidgets(
    'Stream card shows info button only for collection-linked movies and opens animated dialog with View Profile',
    (tester) async {
      SharedPreferences.setMockInitialValues({'is_owner': false});

      const items = [
        TelegramVideoItem(
          msgId: 101,
          hash: 'col101',
          streamCode: 'MRDB-101-COL101',
          title: 'Fight Club',
          fileName: 'Fight.Club.1999.1080p.mkv',
          fileSize: 2147483648,
          mimeType: 'video/x-matroska',
          tmdbId: 550,
          tmdbTitle: 'Fight Club',
          tmdbYear: '1999',
          quality: '1080p',
          language: 'English',
          overview:
              'An insomniac office worker and a soap maker form an underground club.',
          streamUrl: 'https://example.com/col101101',
        ),
        TelegramVideoItem(
          msgId: 102,
          hash: 'raw102',
          streamCode: 'MRDB-102-RAW102',
          title: 'Random.Clip.720p.mkv',
          fileName: 'Random.Clip.720p.mkv',
          fileSize: 524288000,
          mimeType: 'video/x-matroska',
          streamUrl: 'https://example.com/raw102102',
        ),
      ];

      await tester.pumpWidget(
        const MaterialApp(
          home: TelegramVideosPage(initialBotVideos: items),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Only the collection-added movie (tmdb_id: 550) should show the Movie Info icon button.
      expect(find.byTooltip('Movie Info'), findsOneWidget);

      await tester.tap(find.byTooltip('Movie Info'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Fight Club'), findsWidgets);
      expect(find.text('1999 • English • 1080P • 2.0 GB'), findsOneWidget);
      expect(
        find.text(
          'An insomniac office worker and a soap maker form an underground club.',
        ),
        findsOneWidget,
      );
      expect(find.text('View Profile'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('View Profile'), findsNothing);
    },
  );
}
