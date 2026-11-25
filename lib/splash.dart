import 'dart:async';
import 'package:amicons/amicons.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:mrdb/home/bottom_nav.dart';
import 'package:mrdb/provider/client.dart';
import 'package:mrdb/services/network_service.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';
import 'constens/keys.dart';

class Splash extends StatefulWidget {
  const Splash({super.key});

  @override
  State<Splash> createState() => _SplashState();
}

int pageNum = DateTime.now().second;

class _SplashState extends State<Splash> {
  bool isLoading = true;
  bool hasError = false;

  Future<void> shClear() async {
    SharedPreferences preferences = await SharedPreferences.getInstance();
    preferences.clear();
  }

  Future<void> getDeviceDetails() async {
    // Reset states
    if (mounted) {
      setState(() {
        isLoading = true;
        hasError = false;
      });
    }

    final done = await getMovie();

    if (!done) {
      if (mounted) {
        setState(() {
          isLoading = false;
          hasError = true;
        });
        showScaffoldMsg(context, txt: 'please try again...');
      }
      return;
    }

    try {
      final deviceInfo = DeviceInfoPlugin();
      SharedPreferences preferences = await SharedPreferences.getInstance();
      final oldSavedDev = preferences.getStringList('phone') ?? [];
      final androidInfo = await deviceInfo.androidInfo;

      bool isAlreadySaved =
          oldSavedDev.isNotEmpty &&
          oldSavedDev.length > 3 &&
          oldSavedDev[3] == androidInfo.id;

      if (isAlreadySaved) {
        if (mounted) {
          Provider.of<ClientProvider>(
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

        if (mounted) {
          setState(() {
            isLoading = false;
            hasError = false;
          });
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => MainScreen()),
          );
        }
      } else {
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

        await preferences.setStringList('phone', [
          androidInfo.brand,
          androidInfo.model,
          androidInfo.version.release,
          androidInfo.id,
        ]);

        if (mounted) {
          Provider.of<ClientProvider>(
            context,
            listen: false,
          ).setClientId(androidInfo.id);
        }

        if (mounted) {
          setState(() {
            isLoading = false;
            hasError = false;
          });
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => MainScreen()),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
          hasError = true;
        });
        showScaffoldMsg(context, txt: 'Device info error: $e');
      }
    }
  }

  Future<bool> getMovie() async {
    final safePage = pageNum < 1 ? 1 : pageNum;
    try {
      final data = await NetworkService.instance.getTmdbJson(
        '/3/movie/popular?api_key=${AppConstants.apiKey}&sort_by=popularity.desc&page=$safePage',
        timeout: const Duration(seconds: 8),
        maxAttempts: 2,
      );
      if (data is Map && data['results'] is List) {
        all.addAll(data['results'] as List);
        return true;
      }
    } catch (e) {
      debugPrint('Movie fetch error: $e');
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    // shClear(); // Uncomment if you need to clear preferences
    getDeviceDetails();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(),

              // Logo Container
              Container(
                width: wt * 0.45,
                height: ht * 0.2,
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(wt * 0.03),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.6),
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(
                        Amicons.iconly_video,
                        color: Colors.green,
                        size: wt * 0.15,
                      ),
                      Text(
                        'MRDB',
                        style: TextStyle(
                          fontSize: wt * 0.1,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Loading or Error State
              if (hasError)
                Padding(
                  padding: EdgeInsets.only(bottom: ht * 0.05),
                  child: Column(
                    children: [
                      Text(
                        'Oops! Movie Load Failed.',
                        style: TextStyle(
                          color: Colors.orange.shade400,
                          fontSize: wt * 0.04,
                        ),
                      ),
                      SizedBox(height: ht * 0.005),
                      Text(
                        'Please try with VPN',
                        style: TextStyle(
                          color: Colors.orange.shade300,
                          fontSize: wt * 0.035,
                        ),
                      ),
                      SizedBox(height: ht * 0.02),
                      GestureDetector(
                        onTap: () {
                          getDeviceDetails();
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(wt * 0.02),
                            border: Border.all(color: Colors.red, width: 1.5),
                          ),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: ht * 0.015,
                              horizontal: wt * 0.08,
                            ),
                            child: Text(
                              'Retry',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: wt * 0.045,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Padding(
                  padding: EdgeInsets.only(bottom: ht * 0.05),
                  child: Column(
                    children: [
                      LoadingAnimationWidget.newtonCradle(
                        color: Colors.green,
                        size: wt * 0.25,
                      ),
                      Text(
                        'Loading movies...',
                        style: TextStyle(
                          color: Colors.green.shade300,
                          fontSize: wt * 0.035,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
