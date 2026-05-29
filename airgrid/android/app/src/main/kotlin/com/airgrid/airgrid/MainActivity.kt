package com.airgrid.airgrid

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val ACTION_EXIT_MESH = "com.airgrid.app.action.EXIT_MESH"
    private const val MESSAGE_CHANNEL_ID = "airgrid_messages"
    private const val PRIVATE_MESSAGE_NOTIFICATION_ID = 2001
    private const val PLAY_SERVICES_RESOLUTION_REQUEST = 9001
    }

    private val foregroundChannelName = "com.airgrid/foreground"
    private val playServicesChannelName = "com.airgrid/play_services"
    private val batteryOptimizationChannelName = "com.airgrid/battery_optimization"
    private var foregroundChannel: MethodChannel? = null
    private var playServicesChannel: MethodChannel? = null
    private var batteryOptimizationChannel: MethodChannel? = null
    private var pendingExitAction = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        foregroundChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            foregroundChannelName,
        )

        foregroundChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMeshService" -> {
                    val intent = Intent(this, NearbyForegroundService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopMeshService" -> {
                    stopService(Intent(this, NearbyForegroundService::class.java))
                    result.success(null)
                }
                "consumePendingExitAction" -> {
                    val wasPending = pendingExitAction
                    pendingExitAction = false
                    result.success(wasPending)
                }
                "ackExitAction" -> {
                    pendingExitAction = false
                    result.success(null)
                }
                "showPrivateMessageNotification" -> {
                    val senderName = call.argument<String>("senderName") ?: "Someone"
                    showPrivateMessageNotification(senderName)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        playServicesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            playServicesChannelName,
        )

        playServicesChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPlayServices" -> result.success(playServicesStatusMap())
                "resolvePlayServices" -> {
                    val status = GoogleApiAvailability.getInstance()
                        .isGooglePlayServicesAvailable(this)
                    val dialog = GoogleApiAvailability.getInstance()
                        .getErrorDialog(this, status, PLAY_SERVICES_RESOLUTION_REQUEST)
                    if (dialog != null) {
                        dialog.show()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        batteryOptimizationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            batteryOptimizationChannelName,
        )

        batteryOptimizationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "openSystemBatteryOptimizationSettings" ->
                    result.success(openSystemBatteryOptimizationSettings())
                else -> result.notImplemented()
            }
        }

        handleNotificationAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationAction(intent)
    }

    private fun handleNotificationAction(intent: Intent?) {
        if (intent?.action != ACTION_EXIT_MESH) return
        pendingExitAction = true
        foregroundChannel?.invokeMethod("exitMesh", null)
    }

    private fun playServicesStatusMap(): Map<String, Any> {
        val api = GoogleApiAvailability.getInstance()
        val status = api.isGooglePlayServicesAvailable(this)
        val available = status == ConnectionResult.SUCCESS
        val code = when (status) {
            ConnectionResult.SUCCESS -> "available"
            ConnectionResult.SERVICE_MISSING -> "missing"
            ConnectionResult.SERVICE_DISABLED -> "disabled"
            ConnectionResult.SERVICE_VERSION_UPDATE_REQUIRED -> "outdated"
            ConnectionResult.SERVICE_UPDATING -> "updating"
            ConnectionResult.SERVICE_INVALID -> "unsupported"
            else -> "unknown"
        }
        val message = when (code) {
            "available" -> "Google Play Services is available."
            "missing" -> "Google Play Services is missing."
            "disabled" -> "Google Play Services is disabled."
            "outdated" -> "Google Play Services is out of date."
            "updating" -> "Google Play Services is updating."
            "unsupported" -> "Google Play Services is not supported on this device."
            else -> api.getErrorString(status)
        }
        return mapOf(
            "available" to available,
            "code" to code,
            "message" to message,
            "canResolve" to (!available && api.isUserResolvableError(status)),
        )
    }

    private fun showPrivateMessageNotification(senderName: String) {
        createMessageNotificationChannel()

        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pendingIntent =
            PendingIntent.getActivity(this, 2, openIntent, pendingFlags)

        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setContentTitle("New private message")
            .setContentText("Message from $senderName")
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()

        getSystemService(NotificationManager::class.java)
            .notify(PRIVATE_MESSAGE_NOTIFICATION_ID, notification)
    }

    private fun createMessageNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "AirGrid Messages",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Private message alerts"
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun openSystemBatteryOptimizationSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
