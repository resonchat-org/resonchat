package org.resonchat.resonchat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Conversations [SystemEventReceiver] / ACTION_PING equivalent: AlarmManager
 * wakes the process so Dart can run [processAccountState].
 */
class ConnectionWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_PING) return
        Log.d(TAG, "wake alarm fired requestCode=${intent.getIntExtra(EXTRA_REQUEST_CODE, -1)}")
        // Keep the process visible; Flutter engine (if alive) is notified via the channel.
        ConnectionKeepAliveService.ensureRunning(context)
        MainActivity.notifyConnectionWake(intent.getIntExtra(EXTRA_REQUEST_CODE, 0))
    }

    companion object {
        const val TAG = "ConnectionWake"
        const val ACTION_PING = "org.resonchat.resonchat.ACTION_PING"
        const val EXTRA_REQUEST_CODE = "request_code"
    }
}
