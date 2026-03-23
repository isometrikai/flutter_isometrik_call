package io.isometrik.isometrik_flutter_call

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
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

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "isometrik_flutter_call")
        eventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, "isometrik_flutter_call/events")
        channel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "initialize",
            "updateUserSession",
            "registerForVoipPushes",
            "unregisterVoipToken",
            "reportIncomingCall",
            "startOutgoingCall",
            "endCurrentCall",
            "setMute",
            "setSpeaker",
            "reportOutgoingCallConnected",
            "scheduleHangup",
            "cancelScheduledHangup" -> {
                eventSink?.success(
                    mapOf(
                        "type" to "androidNoop",
                        "payload" to mapOf("method" to call.method)
                    )
                )
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
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
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
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
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
