package com.mrdb.flit

import android.content.Context
import android.media.AudioManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val channelName = "com.mrdb.flit/player_controls"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBrightness" -> {
                        val current = window.attributes.screenBrightness
                        val brightness = if (current >= 0f) {
                            current.toDouble()
                        } else {
                            val sys = Settings.System.getInt(
                                contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS,
                                128
                            )
                            (sys / 255.0).coerceIn(0.01, 1.0)
                        }
                        result.success(brightness)
                    }
                    "setBrightness" -> {
                        val value = call.argument<Double>("value") ?: -1.0
                        val lp = window.attributes
                        lp.screenBrightness = if (value < 0) {
                            -1f
                        } else {
                            value.toFloat().coerceIn(0.01f, 1.0f)
                        }
                        window.attributes = lp
                        result.success(null)
                    }
                    "getVolume" -> {
                        val audioManager =
                            getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            .coerceAtLeast(1)
                        val cur = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                        result.success(cur.toDouble() / max.toDouble())
                    }
                    "setVolume" -> {
                        val value = (call.argument<Double>("value") ?: 1.0).coerceIn(0.0, 1.0)
                        val audioManager =
                            getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            .coerceAtLeast(1)
                        val target = (value * max).roundToInt().coerceIn(0, max)
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
