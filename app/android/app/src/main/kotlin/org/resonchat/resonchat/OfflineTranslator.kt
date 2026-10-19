package org.resonchat.resonchat

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import dev.davidv.translator.ErrorType
import dev.davidv.translator.ITranslationCallback
import dev.davidv.translator.ITranslationService
import dev.davidv.translator.TranslationError
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/// Binds Offline Translator's exported [ITranslationService] and waits for
/// one callback. The other app is Android-only; this is the whole client.
class OfflineTranslator(
    private val context: Context,
) {
    private val main = Handler(Looper.getMainLooper())

    fun translate(
        text: String,
        from: String,
        to: String,
        result: MethodChannel.Result,
    ) {
        val intent =
            Intent(ACTION).apply {
                setPackage(PACKAGE)
            }
        val finished = AtomicBoolean(false)
        lateinit var connection: ServiceConnection

        fun finish(block: () -> Unit) {
            if (!finished.compareAndSet(false, true)) return
            main.post {
                main.removeCallbacksAndMessages(finished)
                unbindQuietly(connection)
                block()
            }
        }

        val timeout =
            Runnable {
                finish {
                    result.error(
                        "timeout",
                        "Offline Translator did not respond",
                        null,
                    )
                }
            }

        connection =
            object : ServiceConnection {
                override fun onServiceConnected(
                    name: ComponentName?,
                    service: IBinder?,
                ) {
                    val api = ITranslationService.Stub.asInterface(service)
                    if (api == null) {
                        finish {
                            result.error(
                                "not_installed",
                                "Offline Translator is not installed",
                                null,
                            )
                        }
                        return
                    }
                    try {
                        api.translate(
                            text,
                            from,
                            to,
                            object : ITranslationCallback.Stub() {
                                override fun onTranslationResult(translatedText: String?) {
                                    finish { result.success(translatedText ?: "") }
                                }

                                override fun onTranslationError(error: TranslationError?) {
                                    finish {
                                        result.error(
                                            "translation_failed",
                                            describe(error),
                                            null,
                                        )
                                    }
                                }
                            },
                        )
                    } catch (e: RemoteException) {
                        finish {
                            result.error("translation_failed", e.message, null)
                        }
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {}

                override fun onNullBinding(name: ComponentName?) {
                    finish {
                        result.error(
                            "not_installed",
                            "Offline Translator is not installed",
                            null,
                        )
                    }
                }
            }

        val bound =
            try {
                context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            } catch (_: SecurityException) {
                false
            }
        if (!bound) {
            result.error(
                "not_installed",
                "Offline Translator is not installed",
                null,
            )
            return
        }
        main.postAtTime(timeout, finished, android.os.SystemClock.uptimeMillis() + TIMEOUT_MS)
    }

    private fun unbindQuietly(connection: ServiceConnection) {
        try {
            context.unbindService(connection)
        } catch (_: IllegalArgumentException) {
            // Already unbound, or bind never completed.
        }
    }

    private fun describe(error: TranslationError?): String {
        if (error == null) return "Offline Translator failed"
        return when (error.type) {
            ErrorType.COULD_NOT_DETECT_LANGUAGE -> "Could not detect language"
            ErrorType.DETECTED_BUT_UNAVAILABLE ->
                "Language not installed" +
                    (error.language?.let { ": $it" } ?: "")
            else -> error.message ?: "Offline Translator failed"
        }
    }

    companion object {
        const val ACTION = "dev.davidv.translator.ITranslationService"
        const val PACKAGE = "dev.davidv.translator"
        const val TIMEOUT_MS = 20_000L
    }
}
