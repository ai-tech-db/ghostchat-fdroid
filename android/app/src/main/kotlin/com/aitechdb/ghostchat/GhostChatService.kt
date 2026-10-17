package com.aitechdb.ghostchat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground Service per tenere vivo il processo GhostChat anche quando
 * l'app va in background.
 *
 * Su Android 10 / EMUI 10 il sistema uccide le app in background in pochi
 * secondi. Un Foreground Service con notifica persistente è l'unico modo
 * affidabile per mantenere attivo il server HTTP locale e il tunnel
 * Cloudflare.
 */
class GhostChatService : Service() {

    companion object {
        const val CHANNEL_ID = "ghostchat_tunnel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.aitechdb.ghostchat.START"
        const val ACTION_STOP = "com.aitechdb.ghostchat.STOP"
        const val EXTRA_URL = "url"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var currentUrl: String? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                currentUrl = intent?.getStringExtra(EXTRA_URL)
                startForegroundInternal()
                isRunning = true
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundInternal() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        isRunning = false
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingOpen = PendingIntent.getActivity(
            this, 0, openIntent, pendingFlags
        )

        val text = if (!currentUrl.isNullOrEmpty()) {
            "Tunnel attivo: $currentUrl"
        } else {
            "Tunnel Cloudflare in esecuzione"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GhostChat attivo")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(pendingOpen)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "GhostChat Tunnel",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Mantiene il tunnel Cloudflare attivo in background"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }
}
