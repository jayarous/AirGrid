package com.airgrid.airgrid

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        const val ACTION_EXIT_MESH = "com.airgrid.app.action.EXIT_MESH"
        private const val ACTION_OPEN_PRIVATE_MESSAGE = "com.airgrid.app.action.OPEN_PRIVATE_MESSAGE"
        private const val EXTRA_PEER_NODE_ID = "peerNodeId"
        private const val EXTRA_PEER_NAME = "peerName"
        private const val MESSAGE_CHANNEL_ID = "airgrid_messages"
        private const val PRIVATE_MESSAGE_NOTIFICATION_ID = 2001
        private const val PLAY_SERVICES_RESOLUTION_REQUEST = 9001
    }

    private val foregroundChannelName = "com.airgrid/foreground"
    private val playServicesChannelName = "com.airgrid/play_services"
    private val batteryOptimizationChannelName = "com.airgrid/battery_optimization"
    private val platformChannelName = "com.airgrid/platform"
    private val riderAudioChannelName = "com.airgrid/rider_audio"
    private var foregroundChannel: MethodChannel? = null
    private var playServicesChannel: MethodChannel? = null
    private var batteryOptimizationChannel: MethodChannel? = null
    private var platformChannel: MethodChannel? = null
    private var riderAudioChannel: MethodChannel? = null
    private var riderAudioTrack: AudioTrack? = null
    private val riderAudioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var previousAudioMode: Int? = null
    private var previousSpeakerphoneOn: Boolean? = null
    private var riderWriteCount = 0
    private var pendingExitAction = false
    private var pendingPrivateMessageTap: HashMap<String, Any>? = null

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
                    val peerNodeId = call.argument<String>("peerNodeId") ?: ""
                    val senderName = call.argument<String>("senderName") ?: "Someone"
                    showPrivateMessageNotification(peerNodeId, senderName)
                    result.success(null)
                }
                "consumePendingPrivateMessageTap" -> {
                    val pending = pendingPrivateMessageTap
                    pendingPrivateMessageTap = null
                    result.success(pending)
                }
                "ackPrivateMessageNotificationTap" -> {
                    pendingPrivateMessageTap = null
                    result.success(null)
                }
                "startRiderService" -> {
                    val peerName = call.argument<String>("peerName") ?: "Rider"
                    val muted = call.argument<Boolean>("muted") ?: false
                    startRiderService(peerName, muted)
                    result.success(null)
                }
                "updateRiderServiceMuted" -> {
                    val muted = call.argument<Boolean>("muted") ?: false
                    val peerName = call.argument<String>("peerName") ?: "Rider"
                    startRiderService(peerName, muted)
                    result.success(null)
                }
                "stopRiderService" -> {
                    stopService(Intent(this, NearbyForegroundService::class.java))
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

        platformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformChannelName,
        )

        platformChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "androidSdkInt" -> result.success(Build.VERSION.SDK_INT)
                else -> result.notImplemented()
            }
        }

        riderAudioChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            riderAudioChannelName,
        )

        riderAudioChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startPlayback" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 8000
                    val channels = call.argument<Int>("channels") ?: 1
                    startRiderPlayback(sampleRate, channels)
                    result.success(null)
                }
                "enqueuePcm" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes != null) {
                        riderAudioExecutor.execute {
                            try {
                                val written = riderAudioTrack?.write(bytes, 0, bytes.size) ?: 0
                                riderWriteCount++
                                if (riderWriteCount % 20 == 0) {
                                    Log.d("AirGridRiderAudio", "wrote $written/${bytes.size} PCM bytes")
                                }
                            } catch (_: IllegalStateException) {
                            }
                        }
                    }
                    result.success(null)
                }
                "stopPlayback" -> {
                    stopRiderPlayback()
                    result.success(null)
                }
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
        val action = intent?.action ?: return
        if (action == NearbyForegroundService.ACTION_RIDER_MUTE) {
            foregroundChannel?.invokeMethod("riderMute", null)
            return
        }
        if (action == NearbyForegroundService.ACTION_RIDER_END) {
            foregroundChannel?.invokeMethod("riderEnd", null)
            return
        }
        if (action == ACTION_OPEN_PRIVATE_MESSAGE) {
            val peerNodeId = intent.getStringExtra(EXTRA_PEER_NODE_ID) ?: return
            val peerName = intent.getStringExtra(EXTRA_PEER_NAME) ?: "Private chat"
            val payload = hashMapOf<String, Any>(
                "peerNodeId" to peerNodeId,
                "peerName" to peerName,
            )
            pendingPrivateMessageTap = payload
            foregroundChannel?.invokeMethod("privateMessageNotificationTapped", payload)
            return
        }
        if (action != ACTION_EXIT_MESH) return
        pendingExitAction = true
        foregroundChannel?.invokeMethod("exitMesh", null)
    }

    private fun startRiderService(peerName: String, muted: Boolean) {
        val intent = Intent(this, NearbyForegroundService::class.java).apply {
            putExtra("riderMode", true)
            putExtra("peerName", peerName)
            putExtra("muted", muted)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun startRiderPlayback(sampleRate: Int, channels: Int) {
        stopRiderPlayback()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        previousAudioMode = audioManager.mode
        previousSpeakerphoneOn = audioManager.isSpeakerphoneOn
        audioManager.mode = AudioManager.MODE_NORMAL
        audioManager.isSpeakerphoneOn = true
        riderWriteCount = 0
        val channelConfig = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            channelConfig,
            AudioFormat.ENCODING_PCM_16BIT,
        ).coerceAtLeast(sampleRate / 2)
        riderAudioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(channelConfig)
                    .build(),
            )
            .setBufferSizeInBytes(minBuffer)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        riderAudioTrack?.setVolume(AudioTrack.getMaxVolume())
        riderAudioTrack?.play()
        Log.d("AirGridRiderAudio", "started playback sampleRate=$sampleRate channels=$channels buffer=$minBuffer")
    }

    private fun stopRiderPlayback() {
        try {
            riderAudioTrack?.stop()
        } catch (_: IllegalStateException) {
        }
        riderAudioTrack?.release()
        riderAudioTrack = null
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        previousSpeakerphoneOn?.let { audioManager.isSpeakerphoneOn = it }
        previousAudioMode?.let { audioManager.mode = it }
        previousSpeakerphoneOn = null
        previousAudioMode = null
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

    private fun showPrivateMessageNotification(peerNodeId: String, senderName: String) {
        createMessageNotificationChannel()

        val openIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_OPEN_PRIVATE_MESSAGE
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_PEER_NODE_ID, peerNodeId)
            putExtra(EXTRA_PEER_NAME, senderName)
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
