package com.airgrid.airgrid

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class NearbyForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "airgrid_mesh"
        const val NOTIFICATION_ID = 1001
        const val ACTION_RIDER_MUTE = "com.airgrid.app.action.RIDER_MUTE"
        const val ACTION_RIDER_END = "com.airgrid.app.action.RIDER_END"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val isRider = intent?.getBooleanExtra("riderMode", false) == true
        val peerName = intent?.getStringExtra("peerName") ?: "Rider"
        val muted = intent?.getBooleanExtra("muted", false) == true
        val notification = if (isRider) {
            buildRiderNotification(peerName, muted)
        } else {
            buildNotification()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val serviceType = if (isRider) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            }
            startForeground(NOTIFICATION_ID, notification, serviceType)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AirGrid Mesh",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "AirGrid mesh network is active"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent =
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)

        val exitIntent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_EXIT_MESH
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val exitPendingIntent =
            PendingIntent.getActivity(this, 1, exitIntent, pendingFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("AirGrid mesh active")
            .setContentText("Running in background")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Exit",
                exitPendingIntent,
            )
            .build()
    }

    private fun buildRiderNotification(peerName: String, muted: Boolean): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent =
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)

        val muteIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_RIDER_MUTE
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val mutePendingIntent =
            PendingIntent.getActivity(this, 3, muteIntent, pendingFlags)

        val endIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_RIDER_END
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val endPendingIntent =
            PendingIntent.getActivity(this, 4, endIntent, pendingFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Rider Mode active")
            .setContentText("${if (muted) "Muted" else "Live"} with $peerName")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(
                android.R.drawable.ic_btn_speak_now,
                if (muted) "Unmute" else "Mute",
                mutePendingIntent,
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "End",
                endPendingIntent,
            )
            .build()
    }
}
