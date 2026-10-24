package org.resonchat.resonchat

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var keepaliveChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.resonchat.resonchat/audio",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isMicrophoneMute" -> {
                    val am = getSystemService(AUDIO_SERVICE) as AudioManager
                    result.success(am.isMicrophoneMute)
                }
                else -> result.notImplemented()
            }
        }
        keepaliveChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.resonchat.resonchat/keepalive",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "ResonChat"
                        val text = call.argument<String>("text") ?: "Connected"
                        ConnectionKeepAliveService.start(this, title, text)
                        result.success(null)
                    }
                    "stop" -> {
                        ConnectionKeepAliveService.stop(this)
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations())
                    }
                    "scheduleWake" -> {
                        val millis = (call.argument<Number>("millis") ?: 1000).toLong()
                        val requestCode = call.argument<Int>("requestCode") ?: 0
                        scheduleWake(millis, requestCode)
                        result.success(null)
                    }
                    "cancelWake" -> {
                        val requestCode = call.argument<Int>("requestCode") ?: 0
                        cancelWake(requestCode)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        val offlineTranslator = OfflineTranslator(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.resonchat.resonchat/offline_translator",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "translate" -> {
                    val text = call.argument<String>("text")
                    if (text.isNullOrEmpty()) {
                        result.error("bad_args", "text is required", null)
                    } else {
                        offlineTranslator.translate(
                            text,
                            call.argument<String>("from") ?: "",
                            call.argument<String>("to") ?: "",
                            result,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.resonchat.resonchat/logs",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val name = call.argument<String>("name")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (name == null || bytes == null) {
                        result.error("bad_args", "name and bytes are required", null)
                    } else {
                        try {
                            result.success(saveToDownloads(name, bytes))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /** Opens the system allow-list dialog when not already exempt. */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoringBatteryOptimizations()) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        startActivity(intent)
        return false
    }

    /**
     * Conversations [XmppConnectionService.scheduleWakeUpCall]: wake the process
     * so Dart can run processAccountState (ping due / reconnect backoff).
     */
    private fun scheduleWake(millis: Long, requestCode: Int) {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        val triggerAt = SystemClock.elapsedRealtime() + millis.coerceAtLeast(1L)
        val pending = wakePendingIntent(requestCode)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pending)
            } else {
                @Suppress("DEPRECATION")
                am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pending)
            }
        } catch (e: RuntimeException) {
            // Some OEMs deny alarms; Dart Timer remains as fallback.
        }
    }

    private fun cancelWake(requestCode: Int) {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        am.cancel(wakePendingIntent(requestCode))
    }

    private fun wakePendingIntent(requestCode: Int): PendingIntent {
        val intent = Intent(this, ConnectionWakeReceiver::class.java).apply {
            action = ConnectionWakeReceiver.ACTION_PING
            putExtra(ConnectionWakeReceiver.EXTRA_REQUEST_CODE, requestCode)
        }
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    companion object {
        @Volatile private var instance: MainActivity? = null

        fun notifyConnectionWake(requestCode: Int) {
            instance?.keepaliveChannel?.invokeMethod(
                "onWake",
                mapOf("requestCode" to requestCode),
            )
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    /**
     * Writes [bytes] into the public Downloads collection.
     *
     * MediaStore is the only way to reach Downloads on Android 10+ without a
     * storage permission, and this app requests none on purpose (see the
     * `tools:node="remove"` block in AndroidManifest.xml). Before 10 there is
     * no Downloads collection and no permission to write the legacy
     * directory, so this reports nothing saved rather than pretending.
     *
     * Returns a human-readable location, or null when unsupported.
     */
    private fun saveToDownloads(name: String, bytes: ByteArray): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val relative = "${Environment.DIRECTORY_DOWNLOADS}/resonchat"
        val values =
            ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                put(MediaStore.Downloads.RELATIVE_PATH, relative)
                // A half-written log must not be visible to a file manager or
                // a share sheet picking up the folder.
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = contentResolver.insert(collection, values) ?: return null
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
        } finally {
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        }
        return "$relative/$name"
    }
}
