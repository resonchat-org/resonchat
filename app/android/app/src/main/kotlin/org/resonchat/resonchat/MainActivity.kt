package org.resonchat.resonchat

import android.media.AudioManager
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
    }
}
