package io.isometrik.isometrik_flutter_call

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** IsometrikFlutterCallPlugin */
class IsometrikFlutterCallPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

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

            else -> result.notImplemented()
        }
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
}
