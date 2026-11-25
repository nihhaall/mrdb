import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class ReleaseNotificationService {
  ReleaseNotificationService._();
  static final ReleaseNotificationService instance =
      ReleaseNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  static const String _channelId = 'mrdb_release_reminders';
  static const String _channelName = 'Movie Release Reminders';
  static const String _channelDesc =
      'Notifications when reminded upcoming movies release';

  static const String _prefsKeyIds = 'movie_reminders';
  static const String _prefsKeyDetails = 'movie_reminder_details';

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      tz_data.initializeTimeZones();
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const settings = InitializationSettings(android: androidSettings);
      await _plugin.initialize(settings: settings);
      _initialized = true;
    } catch (e) {
      debugPrint('ReleaseNotificationService init error: $e');
    }
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidImpl?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return true;
    }
  }

  int _notificationIdFor(String movieId) {
    final parsed = int.tryParse(movieId);
    if (parsed != null) return parsed & 0x7FFFFFFF;
    return movieId.hashCode & 0x7FFFFFFF;
  }

  /// Schedules a real local notification for [releaseDateStr] (YYYY-MM-DD at 9:00 AM local).
  /// Also shows an immediate confirmation notification so the user knows reminders are active.
  Future<bool> scheduleMovieReleaseReminder({
    required String movieId,
    required String movieTitle,
    required String? releaseDateStr,
  }) async {
    await initialize();
    final permitted = await _ensurePermission();
    if (!permitted) return false;

    final notifId = _notificationIdFor(movieId);
    final now = DateTime.now();

    DateTime targetLocal = now.add(const Duration(days: 1));
    String formattedDate = 'release day';

    if (releaseDateStr != null && releaseDateStr.isNotEmpty) {
      final parsed = DateTime.tryParse(releaseDateStr);
      if (parsed != null) {
        formattedDate =
            '${parsed.day}/${parsed.month}/${parsed.year}';
        final morning = DateTime(parsed.year, parsed.month, parsed.day, 9, 0);
        if (morning.isAfter(now)) {
          targetLocal = morning;
        } else {
          // If release day morning already passed (e.g. today), schedule shortly
          targetLocal = now.add(const Duration(seconds: 15));
        }
      }
    }

    final targetUtc = targetLocal.toUtc();
    final scheduledTz = tz.TZDateTime.utc(
      targetUtc.year,
      targetUtc.month,
      targetUtc.day,
      targetUtc.hour,
      targetUtc.minute,
      targetUtc.second,
    );

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    );

    try {
      await _plugin.zonedSchedule(
        id: notifId,
        title: 'Releasing Today: $movieTitle',
        body: '$movieTitle is out now! Open MRDb to check trailers & details.',
        scheduledDate: scheduledTz,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: movieId,
      );

      // Immediate confirmation notification
      await _plugin.show(
        id: notifId + 1000000,
        title: 'Release Reminder Set',
        body: 'We\'ll notify you on $formattedDate for "$movieTitle".',
        notificationDetails: details,
        payload: movieId,
      );
    } catch (e) {
      debugPrint('Failed to schedule notification: $e');
    }

    // Save reminder ID & metadata
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsKeyIds) ?? [];
    if (!ids.contains(movieId)) {
      ids.add(movieId);
      await prefs.setStringList(_prefsKeyIds, ids);
    }

    final rawDetails = prefs.getString(_prefsKeyDetails);
    final Map<String, dynamic> map = rawDetails != null
        ? Map<String, dynamic>.from(jsonDecode(rawDetails) as Map)
        : {};
    map[movieId] = {
      'title': movieTitle,
      'releaseDate': releaseDateStr ?? '',
      'scheduledAt': targetLocal.toIso8601String(),
    };
    await prefs.setString(_prefsKeyDetails, jsonEncode(map));

    return true;
  }

  Future<void> cancelMovieReminder(String movieId) async {
    await initialize();
    final notifId = _notificationIdFor(movieId);
    try {
      await _plugin.cancel(id: notifId);
      await _plugin.cancel(id: notifId + 1000000);
    } catch (e) {
      debugPrint('Failed to cancel notification: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsKeyIds) ?? [];
    ids.remove(movieId);
    await prefs.setStringList(_prefsKeyIds, ids);

    final rawDetails = prefs.getString(_prefsKeyDetails);
    if (rawDetails != null) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(rawDetails) as Map);
        map.remove(movieId);
        await prefs.setString(_prefsKeyDetails, jsonEncode(map));
      } catch (_) {}
    }
  }

  Future<int> getActiveReminderCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_prefsKeyIds) ?? []).length;
  }
}
