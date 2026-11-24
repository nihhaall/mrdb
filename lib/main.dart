import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_preview_plus/device_preview_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:mrdb/constens/keys.dart';
import 'package:mrdb/firebase_options.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/mrdb_splash_screen.dart';
import 'package:mrdb/provider/client.dart';
import 'package:provider/provider.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

List all = [];

Future<void> initializeApp(BuildContext context) async {
  // Pre-fetch popular movies
  final pageNum = DateTime.now().second;
  final url = Uri.parse(
    'https://api.themoviedb.org/3/movie/popular'
    '?api_key=${AppConstants.apiKey}'
    '&sort_by=popularity.desc'
    '&page=$pageNum',
  );

  try {
    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      if (data['results'] != null) {
        all.addAll(data['results']);
      }
    }
  } catch (e) {
    debugPrint('Movie fetch error: $e');
  }

  // Register device info
  try {
    final deviceInfo = DeviceInfoPlugin();
    final preferences = await SharedPreferences.getInstance();
    final oldSavedDev = preferences.getStringList('phone') ?? [];
    final androidInfo = await deviceInfo.androidInfo;

    bool isAlreadySaved =
        oldSavedDev.isNotEmpty &&
        oldSavedDev.length > 3 &&
        oldSavedDev[3] == androidInfo.id;

    if (context.mounted) {
      p.Provider.of<ClientProvider>(
        context,
        listen: false,
      ).setClientId(androidInfo.id);
    }

    if (!isAlreadySaved) {
      await FirebaseFirestore.instance
          .collection(AppConstants.phone)
          .doc(androidInfo.id.toString())
          .set({
            "brand": androidInfo.brand,
            "model": androidInfo.model,
            "version": androidInfo.version.release,
            "id": androidInfo.id,
            "createdAt": FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    }

    await preferences.setStringList('phone', [
      androidInfo.brand,
      androidInfo.model,
      androidInfo.version.release,
      androidInfo.id,
    ]);
  } catch (e) {
    debugPrint('Device registration error: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(
    p.ChangeNotifierProvider(
      create: (_) => ClientProvider(),
      child: DevicePreview(
        builder: (context) => ProviderScope(child: MRDb()),
        enabled: false,
      ),
    ),
  );
}

var wt;
var ht;
void showScaffoldMsg(BuildContext context, {required String txt}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: Duration(seconds: 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadiusGeometry.circular(wt * 0.1),
      ),
      width: wt * 0.95,
      showCloseIcon: true,
      closeIconColor: Colors.black.withOpacity(0.5),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.white.withOpacity(0.8),
      content: Center(
        child: Text(
          txt,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.black.withOpacity(0.8),
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}

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
          bottomSheetTheme: const BottomSheetThemeData(
            backgroundColor: Colors.transparent,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.black,
          ),
          scaffoldBackgroundColor: Colors.white,
        ),
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          wt = MediaQuery.of(context).size.width;
          ht = MediaQuery.of(context).size.height;
          return child ?? const SizedBox();
        },
        home: MrdbSplashScreen(
          nextScreen: const MainScreen(),
          minDisplayDuration: const Duration(milliseconds: 3200),
          onInit: () => initializeApp(context),
        ),
      ),
    );
  }
}
