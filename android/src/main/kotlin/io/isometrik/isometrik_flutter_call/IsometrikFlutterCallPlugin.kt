package io.isometrik.isometrik_flutter_call

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.pm.PackageManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlin.math.absoluteValue
import java.lang.ref.WeakReference

internal class IsometrikIncomingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        IsometrikFlutterCallPlugin.dispatchIncomingAction(intent)
    }
}

/** IsometrikFlutterCallPlugin */
class IsometrikFlutterCallPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: Result? = null
    private val permissionRequestCode = 9107
    private val notificationPermissionRequestCode = 9108
    private var activeCallId: String? = null
    private var outgoingCallId: String? = null
    private var hangupRunnable: Runnable? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var incomingRingtone: Ringtone? = null
    private var applicationContext: Context? = null
    private var incomingCallerName: String? = null
    private var incomingHasVideo: Boolean = false
    private var incomingMetadata: Map<String, Any?> = emptyMap()
    private var pendingIncomingNotificationAfterPermission = false
    private var configuredIncomingRingtoneUri: String? = null
    private val pendingEvents: MutableList<Map<String, Any?>> = mutableListOf()

    companion object {
        private const val logTag = "IsometrikFlutterCall"
        private const val notificationChannelId = "isometrik_flutter_call_incoming"
        private const val incomingNotificationId = 48120
        private const val actionAccept = "io.isometrik.isometrik_flutter_call.ACTION_ACCEPT_INCOMING"
        private const val actionReject = "io.isometrik.isometrik_flutter_call.ACTION_REJECT_INCOMING"
        private const val extraDecision = "decision"
        private const val decisionAccept = "accept"
        private const val decisionReject = "reject"
        @Volatile
        private var activePluginRef: WeakReference<IsometrikFlutterCallPlugin>? = null

        internal fun dispatchIncomingAction(intent: Intent?) {
            activePluginRef?.get()?.handleIncomingActionIntent(intent)
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "isometrik_flutter_call")
        eventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "isometrik_flutter_call/events")
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        activePluginRef = WeakReference(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "initialize" -> {
                configuredIncomingRingtoneUri = call.argument<String>("androidIncomingRingtoneUri")?.trim()
                result.success(null)
            }
            "updateUserSession" -> result.success(null)
            "registerForVoipPushes" -> result.success(null)
            "unregisterVoipToken" -> result.success(null)
            "reportIncomingCall" -> handleReportIncomingCall(call, result)
            "startOutgoingCall" -> handleStartOutgoingCall(call, result)
            "endCurrentCall" -> handleEndCurrentCall(result)
            "setMute" -> handleSetMute(call, result)
            "setSpeaker" -> handleSetSpeaker(call, result)
            "reportOutgoingCallConnected" -> handleReportOutgoingCallConnected(result)
            "scheduleHangup" -> handleScheduleHangup(call, result)
            "cancelScheduledHangup" -> {
                cancelScheduledHangup()
                result.success(null)
            }

            "canMakeOutgoingCall" -> {
                result.success(true)
            }

            "requestRuntimePermissions" -> {
                handleRequestRuntimePermissions(call, result)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleReportIncomingCall(call: MethodCall, result: Result) {
        val callerName = call.argument<String>("callerName")
        val callId = call.argument<String>("callId")
        if (callerName.isNullOrBlank() || callId.isNullOrBlank()) {
            result.error("invalid_args", "callerName and callId are required", null)
            return
        }
        val hasVideo = call.argument<Boolean>("hasVideo") ?: false
        val metadata = normalizeMetadata(call.argument<Any?>("metadata"))
        val incomingDisplayName = resolveIncomingDisplayName(callerName, metadata)
        activeCallId = callId
        outgoingCallId = null
        incomingCallerName = incomingDisplayName
        incomingHasVideo = hasVideo
        incomingMetadata = metadata
        startIncomingRingtone()
        showIncomingCallNotificationOrRequestPermission()
        sendEvent(
            "incomingCallReported",
            mapOf(
                "callId" to callId,
                "callerName" to incomingDisplayName,
                "hasVideo" to hasVideo,
                "metadata" to metadata
            )
        )
        result.success(null)
    }

    private fun handleStartOutgoingCall(call: MethodCall, result: Result) {
        val calleeName = call.argument<String>("calleeName")
        val callId = call.argument<String>("callId")
        if (calleeName.isNullOrBlank() || callId.isNullOrBlank()) {
            result.error("invalid_args", "calleeName and callId are required", null)
            return
        }
        val hasVideo = call.argument<Boolean>("hasVideo") ?: false
        val metadata = normalizeMetadata(call.argument<Any?>("metadata"))
        activeCallId = callId
        outgoingCallId = callId
        stopIncomingRingtone()
        cancelIncomingCallNotification()
        sendEvent(
            "outgoingCallStarted",
            mapOf(
                "callId" to callId,
                "calleeName" to calleeName,
                "hasVideo" to hasVideo,
                "metadata" to metadata
            )
        )
        result.success(null)
    }

    private fun handleEndCurrentCall(result: Result) {
        cancelScheduledHangup()
        stopIncomingRingtone()
        cancelIncomingCallNotification()
        if (activeCallId != null) {
            sendEvent("callEnded", mapOf("callId" to activeCallId))
        }
        activeCallId = null
        outgoingCallId = null
        result.success(null)
    }

    private fun handleSetMute(call: MethodCall, result: Result) {
        val isMuted = call.argument<Boolean>("isMuted") ?: false
        sendEvent(
            "muteUpdated",
            mapOf(
                "isMuted" to isMuted,
                "callId" to activeCallId
            )
        )
        result.success(null)
    }

    private fun handleSetSpeaker(call: MethodCall, result: Result) {
        val isSpeakerOn = call.argument<Boolean>("isSpeakerOn") ?: false
        sendEvent(
            "speakerUpdated",
            mapOf(
                "isSpeakerOn" to isSpeakerOn,
                "callId" to activeCallId
            )
        )
        result.success(null)
    }

    private fun handleReportOutgoingCallConnected(result: Result) {
        stopIncomingRingtone()
        cancelIncomingCallNotification()
        sendEvent("outgoingCallConnected", mapOf("callId" to (outgoingCallId ?: activeCallId)))
        outgoingCallId = null
        result.success(null)
    }

    private fun handleScheduleHangup(call: MethodCall, result: Result) {
        val seconds = (call.argument<Number>("seconds") ?: 60).toDouble()
        scheduleHangup(seconds)
        result.success(null)
    }

    private fun scheduleHangup(seconds: Double) {
        cancelScheduledHangup()
        val runnable = Runnable {
            stopIncomingRingtone()
            cancelIncomingCallNotification()
            sendEvent("scheduledHangupFired", emptyMap<String, Any>())
            if (activeCallId != null) {
                sendEvent("callEnded", mapOf("callId" to activeCallId))
            }
            activeCallId = null
            outgoingCallId = null
            hangupRunnable = null
        }
        hangupRunnable = runnable
        mainHandler.postDelayed(runnable, (seconds * 1000).toLong())
    }

    private fun cancelScheduledHangup() {
        val runnable = hangupRunnable ?: return
        mainHandler.removeCallbacks(runnable)
        hangupRunnable = null
    }

    private fun resolveIncomingRingtoneUri(): Uri? {
        val customUri = configuredIncomingRingtoneUri
            ?.takeIf { it.isNotBlank() }
            ?.let { raw ->
                try {
                    Uri.parse(raw)
                } catch (_: Throwable) {
                    null
                }
            }
        val resolved =
            customUri
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        if (customUri != null && resolved == null) {
            Log.w(logTag, "Custom ringtone URI invalid/unavailable, falling back to default")
        }
        return resolved
    }

    private fun startIncomingRingtone() {
        stopIncomingRingtone()
        val context = applicationContext ?: activity ?: return
        val uri = resolveIncomingRingtoneUri() ?: return

        // Ensure ringtone playback happens on the main thread.
        mainHandler.post {
            try {
                stopIncomingRingtone()
                val ringtone = RingtoneManager.getRingtone(context, uri) ?: return@post
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    ringtone.isLooping = true
                }
                // Ensure the ringtone is routed through the "ring" audio stream.
                ringtone.audioAttributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .apply {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            setLegacyStreamType(android.media.AudioManager.STREAM_RING)
                        }
                    }
                    .build()
                ringtone.play()
                incomingRingtone = ringtone
            } catch (t: Throwable) {
                Log.e(logTag, "startIncomingRingtone failed", t)
                incomingRingtone = null
            }
        }
    }

    private fun stopIncomingRingtone() {
        try {
            incomingRingtone?.stop()
        } catch (_: Throwable) {
            // Ignore stop errors from device-specific ringtone implementations.
        } finally {
            incomingRingtone = null
        }
    }

    private fun showIncomingCallNotificationOrRequestPermission() {
        val context = applicationContext ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted =
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                val hostActivity = activity
                if (hostActivity != null) {
                    pendingIncomingNotificationAfterPermission = true
                    ActivityCompat.requestPermissions(
                        hostActivity,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        notificationPermissionRequestCode
                    )
                }
                // Fall back to event-driven in-app UI if host denies/hasn't granted permission.
                sendEvent(
                    "incomingNotificationPermissionRequired",
                    mapOf("callId" to activeCallId, "callerName" to incomingCallerName)
                )
                return
            }
        }
        showIncomingCallNotification()
    }

    private fun showIncomingCallNotification() {
        val context = applicationContext ?: return
        val callId = activeCallId ?: return

        ensureIncomingChannel(context)
        val launchActivityPendingIntent = createLaunchActivityPendingIntent(context)

        val acceptIntent =
            Intent(context, IsometrikIncomingActionReceiver::class.java)
                .setAction(actionAccept)
                .setData(Uri.parse("isometrik://incoming/$callId/accept"))
                .putExtra(extraDecision, decisionAccept)
                .putExtra("callId", callId)
        val acceptPendingIntent =
            PendingIntent.getBroadcast(
                context,
                101 + (callId.hashCode().absoluteValue % 900),
                acceptIntent,
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

        val rejectIntent =
            Intent(context, IsometrikIncomingActionReceiver::class.java)
                .setAction(actionReject)
                .setData(Uri.parse("isometrik://incoming/$callId/reject"))
                .putExtra(extraDecision, decisionReject)
                .putExtra("callId", callId)
        val rejectPendingIntent =
            PendingIntent.getBroadcast(
                context,
                2001 + (callId.hashCode().absoluteValue % 900),
                rejectIntent,
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

        val caller = incomingCallerName ?: "Isometrik Call"
        val ringtoneUri = resolveIncomingRingtoneUri()
        val builder = NotificationCompat.Builder(context, notificationChannelId)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("Incoming ${if (incomingHasVideo) "video" else "audio"} call")
            .setContentText(caller)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            // Must alert on every incoming notification update.
            // Using a fixed notification id would otherwise suppress the sound.
            .setOnlyAlertOnce(false)
            .setContentIntent(acceptPendingIntent)
            .setFullScreenIntent(launchActivityPendingIntent ?: acceptPendingIntent, true)

        if (ringtoneUri != null) {
            builder.setSound(ringtoneUri)
        } else {
            // Pre-O fallback when no explicit URI is available.
            builder.setDefaults(android.app.Notification.DEFAULT_SOUND)
        }

        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Reject",
                rejectPendingIntent
            )
        )
        builder.addAction(
            NotificationCompat.Action(
                android.R.drawable.ic_menu_call,
                "Accept",
                acceptPendingIntent
            )
        )
        try {
            NotificationManagerCompat.from(context).notify(incomingNotificationId, builder.build())
        } catch (e: Throwable) {
            // Never crash host app from notification posting.
            Log.e(logTag, "Failed to post incoming notification", e)
        }

        // Keep payload reference available for Accept event parity.
        incomingMetadata = incomingMetadata + mapOf(
            "meetingId" to callId
        )
    }

    private fun createLaunchActivityPendingIntent(context: Context): PendingIntent? {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launchIntent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        )
        return PendingIntent.getActivity(
            context,
            103,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun cancelIncomingCallNotification() {
        val context = applicationContext ?: return
        NotificationManagerCompat.from(context).cancel(incomingNotificationId)
    }

    private fun ensureIncomingChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val existing = manager.getNotificationChannel(notificationChannelId)
        val desiredUri = resolveIncomingRingtoneUri()

        // If channel exists but sound differs from what we want, recreate it so
        // Android doesn't keep the old sound configuration.
        if (existing != null) {
            val currentUri = existing.sound
            if (desiredUri != null) {
                if (currentUri == desiredUri) return
                manager.deleteNotificationChannel(notificationChannelId)
            } else {
                // No desired sound URI (unexpected). Keep existing channel to avoid churn.
                return
            }
        }

        val channel = NotificationChannel(
            notificationChannelId,
            "Incoming Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming call alerts from Isometrik"
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            setShowBadge(false)
            enableVibration(true)
            val attrs =
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            setSound(desiredUri, attrs)
        }
        manager.createNotificationChannel(channel)
    }

    private fun handleIncomingActionIntent(intent: Intent?) {
        val context = applicationContext ?: return
        val action = intent?.action
        val decision = intent?.getStringExtra(extraDecision)
        Log.d(logTag, "Incoming action raw: action=$action decision=$decision")
        try {
            when {
                decision == decisionAccept || action == actionAccept -> {
                    Log.d(logTag, "Incoming action: ACCEPT")
                    cancelScheduledHangup()
                    stopIncomingRingtone()
                    cancelIncomingCallNotification()
                    val callId = activeCallId
                    if (callId != null) {
                        sendEvent(
                            "callAnswered",
                            mapOf(
                                "callId" to callId,
                                "meetingId" to callId,
                                "metadata" to incomingMetadata
                            )
                        )
                    }
                    val launchIntent =
                        context.packageManager.getLaunchIntentForPackage(context.packageName)
                    if (launchIntent != null) {
                        launchIntent.addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                        )
                        context.startActivity(launchIntent)
                    }
                }

                decision == decisionReject || action == actionReject -> {
                    Log.d(logTag, "Incoming action: REJECT")
                    cancelScheduledHangup()
                    stopIncomingRingtone()
                    cancelIncomingCallNotification()
                    val callId = activeCallId
                    if (callId != null) {
                        sendEvent("callEnded", mapOf("callId" to callId, "meetingId" to callId))
                    }
                    activeCallId = null
                    outgoingCallId = null
                }
            }
        } catch (t: Throwable) {
            Log.e(logTag, "Failed to handle incoming notification action", t)
        }
    }

    private fun unregisterIncomingActionReceiver() {
        // No-op; static manifest receiver used.
    }

    private fun sendEvent(type: String, payload: Map<String, Any?>) {
        val event = mapOf("type" to type, "payload" to payload)
        val sink = eventSink
        if (sink == null) {
            pendingEvents.add(event)
            return
        }
        try {
            sink.success(event)
        } catch (_: Throwable) {
            pendingEvents.add(event)
        }
    }

    private fun normalizeMetadata(raw: Any?): Map<String, Any?> {
        return if (raw is Map<*, *>) {
            raw.entries.associate { (k, v) -> (k?.toString() ?: "") to v }
        } else {
            emptyMap()
        }
    }

    private fun resolveIncomingDisplayName(baseCallerName: String, metadata: Map<String, Any?>): String {
        val isGroupCallFromMetadata = when (val raw = metadata["isGroupCall"]) {
            is Boolean -> raw
            is String -> raw.equals("true", ignoreCase = true) || raw == "1"
            is Number -> raw.toInt() != 0
            else -> false
        }
        val customType = metadata["customType"]?.toString()?.trim()?.lowercase() ?: ""
        val isGroupByType = customType == "groupcall" || customType == "group_call"
        val isGroupCall = isGroupCallFromMetadata || isGroupByType
        if (!isGroupCall) return baseCallerName
        return if (baseCallerName.contains("(Group)", ignoreCase = true)) {
            baseCallerName
        } else {
            "$baseCallerName (Group)"
        }
    }

    private fun handleRequestRuntimePermissions(call: MethodCall, result: Result) {
        val hostActivity = activity
            ?: run {
                result.error(
                    "no_activity",
                    "Cannot request permissions without an attached Activity.",
                    null
                )
                return
            }

        if (pendingPermissionResult != null) {
            result.error("permission_in_progress", "Another permission request is in progress.", null)
            return
        }

        val requestMicrophone = call.argument<Boolean>("requestMicrophone") ?: false
        val requestCamera = call.argument<Boolean>("requestCamera") ?: false
        val requestedPermissions = mutableListOf<String>()
        if (requestMicrophone) requestedPermissions.add(Manifest.permission.RECORD_AUDIO)
        if (requestCamera) requestedPermissions.add(Manifest.permission.CAMERA)

        if (requestedPermissions.isEmpty()) {
            result.success(
                mapOf(
                    "microphoneGranted" to true,
                    "cameraGranted" to true,
                    "requiresSettingsAction" to false
                )
            )
            return
        }

        var allAlreadyGranted = true
        for (permission in requestedPermissions) {
            if (ContextCompat.checkSelfPermission(hostActivity, permission) != PackageManager.PERMISSION_GRANTED) {
                allAlreadyGranted = false
                break
            }
        }
        if (allAlreadyGranted) {
            result.success(
                mapOf(
                    "microphoneGranted" to true,
                    "cameraGranted" to true,
                    "requiresSettingsAction" to false
                )
            )
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            hostActivity,
            requestedPermissions.toTypedArray(),
            permissionRequestCode
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        cancelScheduledHangup()
        stopIncomingRingtone()
        cancelIncomingCallNotification()
        unregisterIncomingActionReceiver()
        activePluginRef = null
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        applicationContext = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val sink = eventSink ?: return
        if (pendingEvents.isEmpty()) return
        val snapshot = pendingEvents.toList()
        pendingEvents.clear()
        for (event in snapshot) {
            try {
                sink.success(event)
            } catch (_: Throwable) {
                pendingEvents.add(event)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        cancelScheduledHangup()
        stopIncomingRingtone()
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        cancelScheduledHangup()
        stopIncomingRingtone()
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode == notificationPermissionRequestCode) {
            val granted =
                grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            if (granted && pendingIncomingNotificationAfterPermission && activeCallId != null) {
                showIncomingCallNotification()
            }
            pendingIncomingNotificationAfterPermission = false
            if (!granted) {
                sendEvent(
                    "incomingNotificationPermissionDenied",
                    mapOf("callId" to activeCallId, "callerName" to incomingCallerName)
                )
            }
            return true
        }
        if (requestCode != permissionRequestCode) return false

        val result = pendingPermissionResult ?: return false
        pendingPermissionResult = null

        var microphoneGranted = true
        var cameraGranted = true
        var requiresSettingsAction = false

        for (i in permissions.indices) {
            val permission = permissions[i]
            val granted = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
            if (permission == Manifest.permission.RECORD_AUDIO) {
                microphoneGranted = granted
            } else if (permission == Manifest.permission.CAMERA) {
                cameraGranted = granted
            }
            if (!granted && activity != null && !ActivityCompat.shouldShowRequestPermissionRationale(activity!!, permission)) {
                requiresSettingsAction = true
            }
        }

        result.success(
            mapOf(
                "microphoneGranted" to microphoneGranted,
                "cameraGranted" to cameraGranted,
                "requiresSettingsAction" to requiresSettingsAction
            )
        )
        return true
    }
}
