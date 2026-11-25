class AppConstants{
  static String phone='clints';
  static const String apiKey = '38ed19dab876e12b797aaa54db51b633';
  /// Optional: paste your free Google Cloud YouTube Data API v3 key here
  /// (or store it in Firestore `app_config/keys` -> `youtubeApiKey`)
  /// to load full playable movie song videos directly in-app.
  static const String youtubeApiKey = 'AIzaSyAYlKAPRQCuc9ymPiVa4iMZ1LqbRyLZNOg';
  /// Default base URL for your FileToLinkBot (`@FileToSpeedLink_Bot`) server.
  /// Can be overridden remotely via Firestore `app_config/keys` -> `streamBotUrl`.
  static const String defaultStreamBotUrl =
      'https://instant-dierdre-fsharebot.koyeb.app';
  static const String baseImageUrl = 'https://image.tmdb.org/t/p/w500';
  static const String noImageUrl = 'https://bioapdps.com.my/malayamedicalcentre/images/no-image/No-Image-Found-400x264.png';
  static const int maxRetries = 3;
}
