// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.ukpratik.kickfile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps kickFile alive while a transfer runs and shows its progress (US-006).
 * Type dataSync; started only while a transfer is active (A-08, Play policy).
 */
class TransferService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val n = build(
            this,
            intent?.getStringExtra("title") ?: "kickFile",
            intent?.getStringExtra("text") ?: "",
            intent?.getIntExtra("progress", -1) ?: -1,
        )
        try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                n,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
            )
        } catch (_: Exception) {
            // Not allowed from the background (Android 12+): the transfer continues while the app is open.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15: dataSync has a daily limit. Stop cleanly; the sender can resume later.
        stopSelf()
    }

    companion object {
        private const val CHANNEL = "transfer_progress"
        private const val NOTIFICATION_ID = 4742
        private var running = false

        fun update(context: Context, title: String, text: String, progress: Int) {
            if (!running) {
                running = true
                val i = Intent(context, TransferService::class.java)
                    .putExtra("title", title).putExtra("text", text).putExtra("progress", progress)
                try {
                    context.startForegroundService(i)
                } catch (_: Exception) {
                    running = false
                }
                return
            }
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, build(context, title, text, progress))
        }

        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, TransferService::class.java))
        }

        private fun build(context: Context, title: String, text: String, progress: Int): Notification {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Transfer progress", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shows progress while files are moving"
                    },
                )
            }
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_kickfile)
                .setContentTitle(title)
                .setContentText(text)
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setContentIntent(open)
                .setProgress(100, progress.coerceIn(0, 100), progress < 0)
                .build()
        }
    }
}
