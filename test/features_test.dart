import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/app_update_service.dart';
import 'package:mrdb/widgets/image_gallery_viewer.dart';
import 'package:mrdb/widgets/movie_share_card.dart';

void main() {
  test('AppUpdateInfo detects updates by buildNumber and semver', () {
    const newerBuild = AppUpdateInfo(
      currentVersion: '1.0.0',
      currentBuildNumber: 1,
      latestVersion: '1.0.0',
      latestBuildNumber: 2,
      apkUrl: 'https://example.com/mrdb.apk',
      releaseNotes: 'Fixes',
    );
    expect(newerBuild.hasUpdate, isTrue);

    const newerVersion = AppUpdateInfo(
      currentVersion: '1.0.0',
      currentBuildNumber: 1,
      latestVersion: '1.1.0',
      latestBuildNumber: 1,
      apkUrl: 'https://example.com/mrdb.apk',
      releaseNotes: 'New features',
    );
    expect(newerVersion.hasUpdate, isTrue);

    const sameVersion = AppUpdateInfo(
      currentVersion: '1.1.0',
      currentBuildNumber: 2,
      latestVersion: '1.1.0',
      latestBuildNumber: 2,
      apkUrl: 'https://example.com/mrdb.apk',
      releaseNotes: 'None',
    );
    expect(sameVersion.hasUpdate, isFalse);

    const emptyUrl = AppUpdateInfo(
      currentVersion: '1.0.0',
      currentBuildNumber: 1,
      latestVersion: '2.0.0',
      latestBuildNumber: 5,
      apkUrl: '',
      releaseNotes: 'None',
    );
    expect(emptyUrl.hasUpdate, isFalse);
  });

  testWidgets('MovieShareCard displays title, year, rating, and genres',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MovieShareCard(
              title: 'Inception',
              year: '2010',
              rating: '8.4/10',
              tagline: 'Your mind is the scene of the crime.',
              genres: ['Action', 'Sci-Fi'],
              posterUrl: '',
              backdropUrl: '',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Inception'), findsOneWidget);
    expect(find.text('2010'), findsOneWidget);
    expect(find.text('8.4/10'), findsOneWidget);
    expect(find.text('Action • Sci-Fi'), findsOneWidget);
    expect(find.text('MRDb Pick'), findsOneWidget);
  });

  testWidgets('ImageGalleryPage shows image counter and title', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ImageGalleryPage(
          imagePaths: ['/a.jpg', '/b.jpg', '/c.jpg'],
          initialIndex: 1,
          title: 'Test Gallery',
        ),
      ),
    );

    expect(find.text('Test Gallery'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
  });
}
