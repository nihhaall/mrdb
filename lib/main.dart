import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_preview_plus/device_preview_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/firebase_options.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/mrdb_splash_screen.dart';
import 'package:mrdb/provider/client.dart';
import 'package:mrdb/provider/favorites_provider.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:provider/provider.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

List all = [];
String? userDeviceLanguageCode;

Future<void> initializeApp(BuildContext context) async {
  // Run language detection, movie pre-fetch, and device registration in parallel
  // with bounded timeouts so slow/blocked mobile data never stalls the splash screen.
  await Future.wait([
    _initUserLanguage(),
    _prefetchPopularMovies(),
    _registerDeviceInfo(context),
  ]);
}

Future<void> _initUserLanguage() async {
  // Detect & restore user/state language during splash screen load
  try {
    final preferences = await SharedPreferences.getInstance();
    final hasManualSelection =
        preferences.getBool('user_manual_selection') ?? false;
    final isCleared =
        preferences.getBool('selected_language_cleared') ?? false;

    const supported = [
      'en',
      'ml',
      'ta',
      'hi',
      'te',
      'kn',
      'ja',
      'ko',
      'es',
      'fr',
      'de',
      'pt',
    ];

    String? chosenLang;

    if (hasManualSelection) {
      if (!isCleared) {
        chosenLang = preferences.getString('selected_language');
      }
    } else {
      final hasNet = await NetworkService.instance.hasInternet();
      if (hasNet) {
        // 1. Detect state language via IP geolocation (Kerala -> 'ml', Tamil Nadu -> 'ta', etc.)
        try {
          final res = await http
              .get(Uri.parse('http://ip-api.com/json'))
              .timeout(const Duration(milliseconds: 2200));
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            final countryCode =
                (data['countryCode'] ?? '').toString().toUpperCase();
            final region = (data['regionName'] ?? '').toString().toLowerCase();
            final regionCode = (data['region'] ?? '').toString().toUpperCase();

            if (countryCode == 'IN') {
              if (region.contains('kerala') || regionCode == 'KL') {
                chosenLang = 'ml';
              } else if (region.contains('tamil') || regionCode == 'TN') {
                chosenLang = 'ta';
              } else if (region.contains('karnataka') || regionCode == 'KA') {
                chosenLang = 'kn';
              } else if (region.contains('andhra') ||
                  region.contains('telangana') ||
                  regionCode == 'AP' ||
                  regionCode == 'TG' ||
                  regionCode == 'TS') {
                chosenLang = 'te';
              } else {
                chosenLang = 'hi';
              }
            }
          }
        } catch (e) {
          debugPrint('ip-api state lookup error: $e');
        }

        // 2. HTTPS fallback if first IP detection failed
        if (chosenLang == null) {
          try {
            final res = await http
                .get(Uri.parse('https://ipwho.is/'))
                .timeout(const Duration(milliseconds: 2000));
            if (res.statusCode == 200) {
              final data = jsonDecode(res.body);
              final countryCode =
                  (data['country_code'] ?? '').toString().toUpperCase();
              final region = (data['region'] ?? '').toString().toLowerCase();
              final regionCode =
                  (data['region_code'] ?? '').toString().toUpperCase();

              if (countryCode == 'IN') {
                if (region.contains('kerala') || regionCode == 'KL') {
                  chosenLang = 'ml';
                } else if (region.contains('tamil') || regionCode == 'TN') {
                  chosenLang = 'ta';
                } else if (region.contains('karnataka') || regionCode == 'KA') {
                  chosenLang = 'kn';
                } else if (region.contains('andhra') ||
                    region.contains('telangana') ||
                    regionCode == 'AP' ||
                    regionCode == 'TG' ||
                    regionCode == 'TS') {
                  chosenLang = 'te';
                } else {
                  chosenLang = 'hi';
                }
              }
            }
          } catch (e) {
            debugPrint('ipwho.is state lookup error: $e');
          }
        }
      }

      // 3. If in India by locale or IST timezone (+05:30), default to state language (Malayalam 'ml')
      if (chosenLang == null) {
        final osLocale = Platform.localeName.toLowerCase();
        final isIndiaLocale =
            osLocale.contains('_in') || osLocale.contains('-in');
        final isIndiaTz =
            DateTime.now().timeZoneOffset.inMinutes == 330; // +05:30 IST
        if (isIndiaLocale || isIndiaTz) {
          final rawCode = osLocale.split(RegExp(r'[-_]')).first;
          if (['ml', 'ta', 'hi', 'te', 'kn'].contains(rawCode)) {
            chosenLang = rawCode;
          } else {
            // Default Indian state language
            chosenLang = 'ml';
          }
        }
      }

      // 4. Fallback to OS locale for international users
      if (chosenLang == null) {
        final osLocale = Platform.localeName;
        final rawCode = osLocale.split(RegExp(r'[-_]')).first.toLowerCase();
        if (supported.contains(rawCode)) {
          chosenLang = rawCode;
        }
      }

      // 5. Final fallback to platform dispatcher locale
      if (chosenLang == null) {
        final code = WidgetsBinding
            .instance.platformDispatcher.locale.languageCode
            .toLowerCase();
        if (supported.contains(code)) {
          chosenLang = code;
        }
      }
    }

    userDeviceLanguageCode = chosenLang ?? 'ml';
    debugPrint(
      'MRDb resolved state language: $userDeviceLanguageCode (OS: ${Platform.localeName})',
    );
  } catch (e) {
    debugPrint('Language detection error: $e');
    userDeviceLanguageCode = 'ml';
  }
}

Future<void> _prefetchPopularMovies() async {
  // Pre-fetch popular movies (page must be >= 1)
  final pageNum = (DateTime.now().second % 50) + 1;
  try {
    final data = await NetworkService.instance.getTmdbJson(
      '/3/movie/popular?api_key=${AppConstants.apiKey}&sort_by=popularity.desc&page=$pageNum',
      timeout: const Duration(seconds: 4),
      maxAttempts: 1,
    );
    if (data is Map && data['results'] is List) {
      all.addAll(data['results'] as List);
    }
  } catch (e) {
    debugPrint('Movie fetch error: $e');
  }
}

Future<void> _registerDeviceInfo(BuildContext context) async {
  // Register device info
  try {
    final deviceInfo = DeviceInfoPlugin();
    final preferences = await SharedPreferences.getInstance();
    final syncedId = preferences.getString('phone_synced_id');
    final oldSavedDev = preferences.getStringList('phone') ?? [];
    final androidInfo = await deviceInfo.androidInfo;

    if (context.mounted) {
      p.Provider.of<ClientProvider>(
        context,
        listen: false,
      ).setClientId(androidInfo.id);
    }

    await preferences.setStringList('phone', [
      androidInfo.brand,
      androidInfo.model,
      androidInfo.version.release,
      androidInfo.id,
    ]);

    final bool isAlreadySynced =
        syncedId == androidInfo.id ||
        (oldSavedDev.isNotEmpty &&
            oldSavedDev.length > 3 &&
            oldSavedDev[3] == androidInfo.id &&
            syncedId != null);

    if (!isAlreadySynced && await NetworkService.instance.hasInternet()) {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(androidInfo.id.toString())
          .set({
            "brand": androidInfo.brand,
            "model": androidInfo.model,
            "version": androidInfo.version.release,
            "id": androidInfo.id,
            "createdAt": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 4));
      await preferences.setString('phone_synced_id', androidInfo.id);
    }
  } catch (e) {
    debugPrint('Device registration error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  HttpOverrides.global = AppHttpOverrides();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(
    p.MultiProvider(
      providers: [
        p.ChangeNotifierProvider(create: (_) => ClientProvider()),
        p.ChangeNotifierProxyProvider<ClientProvider, FavoritesProvider>(
          create: (_) => FavoritesProvider(),
          update: (_, client, favorites) =>
              (favorites ?? FavoritesProvider())..updateClient(client.clientId),
        ),
      ],
      child: DevicePreview(
        builder: (context) => ProviderScope(child: MRDb()),
        enabled: false,
      ),
    ),
  );
}

dynamic wt;
dynamic ht;
void showScaffoldMsg(BuildContext context, {required String txt}) {}

class MRDb extends StatelessWidget {
  const MRDb({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        FocusManager.instance.primaryFocus!.unfocus();
      },
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          canvasColor: const Color(0xFF0D0D14),
          scaffoldBackgroundColor: const Color(0xFF0D0D14),
          colorScheme: const ColorScheme.dark(
            surface: Color(0xFF0D0D14),
            primary: Color(0xFF00E5A0),
          ),
          bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: Colors.transparent,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0D0D14),
            surfaceTintColor: Colors.transparent,
          ),
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: ZoomPageTransitionsBuilder(),
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        debugShowCheckedModeBanner: false,
        supportedLocales: const [
          Locale('en'),
          Locale('ml'),
          Locale('ta'),
          Locale('hi'),
          Locale('te'),
          Locale('kn'),
          Locale('ja'),
          Locale('ko'),
          Locale('es'),
          Locale('fr'),
          Locale('de'),
          Locale('pt'),
        ],
        builder: (context, child) {
          wt = MediaQuery.of(context).size.width;
          ht = MediaQuery.of(context).size.height;
          return child ?? const SizedBox();
        },
        home: MrdbSplashScreen(
          nextScreen: const MainScreen(),
          minDisplayDuration: const Duration(milliseconds: 2100),
          onInit: () => initializeApp(context),
        ),
      ),
    );
  }
}
