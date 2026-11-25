import 'package:flutter_test/flutter_test.dart';
import 'package:mrdb/services/movie_song_verifier.dart';

void main() {
  group('MovieSongVerifier', () {
    test('accepts official songs from the movie and rejects unrelated videos', () {
      const movie = MovieSongContext(
        title: 'Leo',
        originalTitle: 'Leo',
        releaseYear: 2023,
        composers: ['Anirudh Ravichander'],
        directors: ['Lokesh Kanagaraj'],
        castNames: ['Vijay', 'Trisha Krishnan'],
      );

      final query = MovieSongVerifier.buildSearchQuery(movie);
      expect(query, '"Leo" Anirudh Ravichander 2023 movie songs');

      final results = MovieSongVerifier.filterAndRank(
        [
          MovieSongCandidate(
            videoId: 'valid123456',
            title: 'Naa Ready Lyric Video | Leo | Thalapathy Vijay | Anirudh Ravichander',
            description: 'Presenting Naa Ready from Leo (2023) directed by Lokesh Kanagaraj',
            channelTitle: 'Sony Music South',
            categoryId: '10',
            thumbUrl: 'https://example.com/1.jpg',
            publishedAt: DateTime(2023, 6, 22),
            durationSeconds: 248,
            embeddable: true,
          ),
          MovieSongCandidate(
            videoId: 'wrongMovie1',
            title: 'Leo Messi Goals Tribute Song Remix 2023',
            description: 'Best goals compilation by Leo Messi fans',
            channelTitle: 'Football Edits',
            categoryId: '17',
            thumbUrl: 'https://example.com/2.jpg',
            publishedAt: DateTime(2023, 8, 1),
            durationSeconds: 210,
            embeddable: true,
          ),
          MovieSongCandidate(
            videoId: 'reaction123',
            title: 'Leo Naa Ready Song REACTION! | Vijay | Anirudh',
            description: 'Foreigner reacts to Leo movie song',
            channelTitle: 'React Channel',
            categoryId: '24',
            thumbUrl: 'https://example.com/3.jpg',
            publishedAt: DateTime(2023, 7, 1),
            durationSeconds: 420,
            embeddable: true,
          ),
          MovieSongCandidate(
            videoId: 'shortClip12',
            title: 'Leo BGM Ringtone Song',
            description: 'Leo Anirudh BGM',
            channelTitle: 'Ringtone Hub',
            categoryId: '10',
            thumbUrl: 'https://example.com/4.jpg',
            publishedAt: DateTime(2023, 10, 19),
            durationSeconds: 32,
            embeddable: true,
          ),
          MovieSongCandidate(
            videoId: 'noEmbed1234',
            title: 'Badass Lyrical | Leo | Anirudh Ravichander | 2023',
            description: 'From the movie Leo',
            channelTitle: 'Sony Music South',
            categoryId: '10',
            thumbUrl: 'https://example.com/5.jpg',
            publishedAt: DateTime(2023, 9, 28),
            durationSeconds: 229,
            embeddable: false,
          ),
        ],
        movie,
      );

      expect(results.length, 1);
      expect(results.first['videoId'], 'valid123456');
    });

    test('rejects songs from wrong release year or wrong sequel part', () {
      const movie = MovieSongContext(
        title: 'Pushpa 2: The Rule',
        releaseYear: 2024,
        composers: ['Devi Sri Prasad'],
        castNames: ['Allu Arjun', 'Rashmika Mandanna'],
      );

      final results = MovieSongVerifier.filterAndRank(
        [
          MovieSongCandidate(
            videoId: 'part2valid1',
            title: 'Pushpa Pushpa Lyrical | Pushpa 2 The Rule | Allu Arjun | DSP',
            description: 'Music by Devi Sri Prasad',
            channelTitle: 'T-Series',
            categoryId: '10',
            thumbUrl: 'https://example.com/p2.jpg',
            publishedAt: DateTime(2024, 5, 1),
            durationSeconds: 255,
          ),
          MovieSongCandidate(
            videoId: 'oldWrongYr1',
            title: 'Pushpa Old Movie Song 2018',
            description: 'Classic film song from 2018',
            channelTitle: 'Retro Music',
            categoryId: '10',
            thumbUrl: 'https://example.com/old.jpg',
            publishedAt: DateTime(2018, 3, 10),
            durationSeconds: 230,
          ),
          MovieSongCandidate(
            videoId: 'part3wrong1',
            title: 'Pushpa 3 Fan Song Music Video',
            description: 'Pushpa 3 fan soundtrack 2024',
            channelTitle: 'Fan Channel',
            categoryId: '10',
            thumbUrl: 'https://example.com/p3.jpg',
            publishedAt: DateTime(2024, 11, 1),
            durationSeconds: 180,
          ),
        ],
        movie,
      );

      expect(results.length, 1);
      expect(results.first['videoId'], 'part2valid1');
    });

    test('rejects unrelated videos mentioning movie only in description spam and accepts regional film uploads', () {
      const aavesham = MovieSongContext(
        title: 'Aavesham',
        originalTitle: 'ആവേശം',
        releaseYear: 2024,
        composers: ['Sushin Shyam'],
        directors: ['Jithu Madhavan'],
        castNames: ['Fahadh Faasil'],
      );

      final results = MovieSongVerifier.filterAndRank(
        [
          MovieSongCandidate(
            videoId: 'realAavesh1',
            title: 'Illuminati|Aavesham|Jithu Madhavan|Fahadh Faasil|Sushin Shyam|Think Originals',
            description: 'Presenting Illuminati from Aavesham',
            channelTitle: 'Think Music India',
            categoryId: '10',
            thumbUrl: 'https://example.com/illu.jpg',
            publishedAt: DateTime(2024, 3, 21),
            durationSeconds: 213,
          ),
          MovieSongCandidate(
            videoId: 'crossPromo1',
            title: 'Other Hit Song | Another Movie | Sushin Shyam',
            description: 'Music by Sushin Shyam. After blockbuster Aavesham watch this next hit!',
            channelTitle: 'Random Label',
            categoryId: '10',
            thumbUrl: 'https://example.com/cross.jpg',
            publishedAt: DateTime(2024, 9, 1),
            durationSeconds: 200,
          ),
          MovieSongCandidate(
            videoId: 'jokerSpam01',
            title: 'Aavesham - Unrelated Indie Rap Official Audio',
            description: 'Independent track released independently',
            channelTitle: 'Indie Rapper',
            categoryId: '10',
            thumbUrl: 'https://example.com/rap.jpg',
            publishedAt: DateTime(2024, 5, 1),
            durationSeconds: 185,
          ),
        ],
        aavesham,
      );

      expect(results.length, 1);
      expect(results.first['videoId'], 'realAavesh1');
    });

    test('parses YouTube ISO durations accurately', () {
      expect(MovieSongVerifier.parseIsoDurationSeconds('PT3M45S'), 225);
      expect(MovieSongVerifier.parseIsoDurationSeconds('PT1H2M5S'), 3725);
      expect(MovieSongVerifier.parseIsoDurationSeconds('PT42S'), 42);
      expect(MovieSongVerifier.parseIsoDurationSeconds('invalid'), isNull);
    });
  });
}
