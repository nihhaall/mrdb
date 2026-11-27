package com.mrdb.flit

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val playerChannelName = "com.mrdb.flit/player_controls"
    private val playerNetworkChannelName = "com.mrdb.flit/player_network"
    private val updaterChannelName = "com.mrdb.flit/app_updater"
    private val videoThumbChannelName = "com.mrdb.flit/video_thumbnail"
    private val thumbExecutor = Executors.newFixedThreadPool(2)
    @Volatile
    private var playerActive = false
    private var wifiLock: WifiManager.WifiLock? = null
    private var networkSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private fun currentTransportLabel(): String {
        return try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return "Offline"
            val caps = cm.getNetworkCapabilities(network) ?: return "Offline"
            val hasInternet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            if (!hasInternet) return "Offline"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Cellular"
                else -> "Online"
            }
        } catch (_: Exception) {
            "Online"
        }
    }

    private fun setPlayerPerformanceMode(enabled: Boolean) {
        playerActive = enabled
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            try {
                if (wifiLock == null) {
                    val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                    } else {
                        @Suppress("DEPRECATION")
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    wifiLock = wm.createWifiLock(mode, "mrdb:player_wifi_lock").apply {
                        setReferenceCounted(false)
                    }
                }
                if (wifiLock?.isHeld == false) {
                    wifiLock?.acquire()
                }
            } catch (_: Exception) {
            }
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            try {
                if (wifiLock?.isHeld == true) {
                    wifiLock?.release()
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun registerNetworkListener() {
        unregisterNetworkListener()
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    runOnUiThread { networkSink?.success(currentTransportLabel()) }
                }

                override fun onLost(network: Network) {
                    runOnUiThread { networkSink?.success(currentTransportLabel()) }
                }

                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    runOnUiThread { networkSink?.success(currentTransportLabel()) }
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (_: Exception) {
        }
    }

    private fun unregisterNetworkListener() {
        val cb = networkCallback ?: return
        networkCallback = null
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, playerChannelName)
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
                    "setPlayerPerformanceMode" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setPlayerPerformanceMode(enabled)
                        result.success(currentTransportLabel())
                    }
                    "getNetworkType" -> {
                        result.success(currentTransportLabel())
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, playerNetworkChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    networkSink = events
                    events?.success(currentTransportLabel())
                    registerNetworkListener()
                }

                override fun onCancel(arguments: Any?) {
                    networkSink = null
                    unregisterNetworkListener()
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getUpdateDir" -> {
                        val dir = File(filesDir, "ota_update")
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "canRequestPackageInstalls" -> {
                        val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(allowed)
                    }
                    "openInstallPermissionSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                val fallback = Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(fallback)
                                result.success(true)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "sha256File" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARG", "Missing file path", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val file = File(path)
                                if (!file.exists()) {
                                    runOnUiThread { result.error("NOT_FOUND", "File not found", null) }
                                    return@Thread
                                }
                                val digest = MessageDigest.getInstance("SHA-256")
                                FileInputStream(file).use { input ->
                                    val buf = ByteArray(65536)
                                    while (true) {
                                        val read = input.read(buf)
                                        if (read <= 0) break
                                        digest.update(buf, 0, read)
                                    }
                                }
                                val hex = digest.digest().joinToString("") { "%02x".format(it) }
                                runOnUiThread { result.success(hex) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("HASH_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARG", "Missing file path", null)
                            return@setMethodCallHandler
                        }
                        val file = File(path)
                        if (!file.exists() || file.length() == 0L) {
                            result.error("NOT_FOUND", "APK file is missing or empty", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            result.error(
                                "PERMISSION_DENIED",
                                "Install unknown apps permission is not granted",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.ota_update_provider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message ?: "Could not open installer", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, videoThumbChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "extractVideoFrame") {
                    val url = call.argument<String>("url")?.trim()
                    val timeMs = (call.argument<Number>("timeMs")?.toLong() ?: 600000L).coerceAtLeast(0L)
                    if (url.isNullOrEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    thumbExecutor.execute {
                        val bytes = extractFrameJpeg(url, timeMs)
                        runOnUiThread { result.success(bytes) }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun extractFrameJpeg(url: String, timeMs: Long): ByteArray? {
        if (playerActive) return null
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(url, hashMapOf("User-Agent" to "MRDb/1.0"))
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val targetMs = when {
                durationMs > timeMs + 1000L -> timeMs
                durationMs > 2000L -> durationMs / 2L
                else -> timeMs
            }
            val rawBitmap = retriever.getFrameAtTime(
                targetMs * 1000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.getFrameAtTime(
                0L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.frameAtTime ?: return null

            val maxWidth = 480
            val scaled = if (rawBitmap.width > maxWidth && rawBitmap.height > 0) {
                val targetHeight = ((rawBitmap.height.toFloat() / rawBitmap.width) * maxWidth)
                    .roundToInt()
                    .coerceAtLeast(1)
                Bitmap.createScaledBitmap(rawBitmap, maxWidth, targetHeight, true)
            } else {
                rawBitmap
            }

            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            if (scaled !== rawBitmap) scaled.recycle()
            rawBitmap.recycle()
            out.toByteArray()
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        setPlayerPerformanceMode(false)
        unregisterNetworkListener()
        super.onDestroy()
    }
}
