package org.resonchat.resonchat

import android.content.ContentValues
import android.media.AudioManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
