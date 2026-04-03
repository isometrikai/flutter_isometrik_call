import AVFAudio
import CallKit
import Flutter
import PushKit
import UIKit

/// CallKit and PushKit only. MQTT uses the same broker/topics as ISMMQTT.swift but runs in
/// Dart (IsometrikMqttService + IsometrikMeetingRouter), matching MQTT+ISMCall.swift routing.
public class IsometrikFlutterCallPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?

  private var pushRegistry: PKPushRegistry?
  private let callController = CXCallController()
  private let provider: CXProvider = {
    let config = CXProviderConfiguration(localizedName: "Isometrik Call")
    config.supportsVideo = true
    config.maximumCallGroups = 1
    // Allow call waiting while an active call exists (End & Accept flow).
    config.maximumCallsPerCallGroup = 2
    config.supportedHandleTypes = [.generic]
    return CXProvider(configuration: config)
  }()

  private var activeCallUUID: UUID?
  private var activeCallId: String?
  private var outgoingCallUUID: UUID?
  private var callIdByUUID: [UUID: String] = [:]
  private var latestVoipToken: String?
  private var userId: String?
  private var userToken: String?
  private var configuration: [String: Any] = [:]
  private let callObserver = CXCallObserver()
  private var hangupWorkItem: DispatchWorkItem?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "isometrik_flutter_call",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "isometrik_flutter_call/events",
      binaryMessenger: registrar.messenger()
    )
    let instance = IsometrikFlutterCallPlugin()
    instance.methodChannel = methodChannel
    instance.eventChannel = eventChannel
    eventChannel.setStreamHandler(instance)
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    instance.provider.setDelegate(instance, queue: nil)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      configuration = call.arguments as? [String: Any] ?? [:]
      result(nil)
    case "updateUserSession":
      let args = call.arguments as? [String: Any] ?? [:]
      userId = args["userId"] as? String
      userToken = args["userToken"] as? String
      result(nil)
    case "registerForVoipPushes":
      registerForVoipPushes()
      result(nil)
    case "unregisterVoipToken":
      sendEvent(type: "voipTokenInvalidated", payload: ["token": latestVoipToken as Any])
      latestVoipToken = nil
      result(nil)
    case "reportIncomingCall":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let callerName = args["callerName"] as? String,
        let callId = args["callId"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "callerName and callId are required", details: nil))
        return
      }
      let hasVideo = args["hasVideo"] as? Bool ?? false
      let metadata = args["metadata"] as? [String: Any] ?? [:]
      let displayName = resolvedIncomingDisplayName(baseCallerName: callerName, metadata: metadata)
      reportIncomingCall(callerName: displayName, callId: callId, hasVideo: hasVideo, metadata: metadata, result: result)
    case "startOutgoingCall":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let calleeName = args["calleeName"] as? String,
        let callId = args["callId"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "calleeName and callId are required", details: nil))
        return
      }
      let hasVideo = args["hasVideo"] as? Bool ?? false
      startOutgoingCall(calleeName: calleeName, callId: callId, hasVideo: hasVideo, metadata: args["metadata"] as? [String: Any] ?? [:], result: result)
    case "endCurrentCall":
      endCurrentCall(result: result)
    case "setMute":
      let args = call.arguments as? [String: Any] ?? [:]
      setMute(args["isMuted"] as? Bool ?? false, result: result)
    case "setSpeaker":
      let args = call.arguments as? [String: Any] ?? [:]
      setSpeaker(args["isSpeakerOn"] as? Bool ?? false, result: result)
    case "canMakeOutgoingCall":
      result(canMakeOutgoingCall())
    case "reportOutgoingCallConnected":
      reportOutgoingCallConnected(result: result)
    case "scheduleHangup":
      let args = call.arguments as? [String: Any] ?? [:]
      let seconds = args["seconds"] as? Double ?? 60
      scheduleHangup(seconds: seconds)
      result(nil)
    case "cancelScheduledHangup":
      cancelScheduledHangup()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Mirrors `ISMCallManager.canMakeAOutgoingCall()`.
  private func canMakeOutgoingCall() -> Bool {
    // Ignore stale ended calls. Without this, iOS can keep historical calls in
    // CXCallObserver briefly and Flutter incorrectly sees "already on call".
    if callObserver.calls.contains(where: { !$0.hasEnded && ($0.hasConnected || $0.isOutgoing) }) {
      return false
    }
    return true
  }

  /// True on iOS Simulator. Uses compile-time `targetEnvironment` plus
  /// `SIMULATOR_DEVICE_NAME` so we skip CallKit when the runtime is the Simulator even
  /// if a specific build slice misreports the simulator flag (CallKit outgoing often fails
  /// on Simulator; Flutter should still open in-app call UI).
  private func isSimulatorEnvironment() -> Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      let name = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
      return !name.isEmpty
    #endif
  }

  /// Mirrors `startTheCall()` — report outgoing connected.
  private func reportOutgoingCallConnected(result: @escaping FlutterResult) {
    guard outgoingCallUUID != nil || activeCallUUID != nil else {
      result(nil)
      return
    }
    let connectedCallId = callIdForAction(uuid: outgoingCallUUID ?? activeCallUUID)
    if !isSimulatorEnvironment() {
      if let uuid = outgoingCallUUID ?? activeCallUUID {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
      }
    }
    outgoingCallUUID = nil
    sendEvent(type: "outgoingCallConnected", payload: ["callId": connectedCallId as Any])
    result(nil)
  }

  /// Mirrors `scheduleCallHangup`.
  private func scheduleHangup(seconds: TimeInterval) {
    cancelScheduledHangup()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if let uuid = self.outgoingCallUUID ?? self.activeCallUUID {
        self.endCall(uuid: uuid) {
          self.sendEvent(type: "scheduledHangupFired", payload: [:])
        }
      } else {
        self.sendEvent(type: "scheduledHangupFired", payload: [:])
      }
    }
    hangupWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func cancelScheduledHangup() {
    hangupWorkItem?.cancel()
    hangupWorkItem = nil
  }

  private func callId(for uuid: UUID?) -> String? {
    guard let uuid else { return nil }
    return callIdByUUID[uuid]
  }

  private func callIdForAction(uuid: UUID?) -> String? {
    guard let uuid else { return nil }
    if let mapped = callIdByUUID[uuid] {
      return mapped
    }
    // Never reuse activeCallId for a different UUID; that can misroute
    // waiting-call End/Accept actions to the wrong meeting.
    if activeCallUUID == uuid {
      return activeCallId
    }
    return nil
  }

  private func endCall(uuid: UUID, completion: (() -> Void)? = nil) {
    let endedCallId = callIdForAction(uuid: uuid)
    if isSimulatorEnvironment() {
      _ = uuid
      sendEvent(type: "callEnded", payload: ["callId": endedCallId as Any])
      callIdByUUID[uuid] = nil
      activeCallUUID = nil
      activeCallId = nil
      outgoingCallUUID = nil
      completion?()
      return
    }
    let action = CXEndCallAction(call: uuid)
    let transaction = CXTransaction(action: action)
    callController.request(transaction) { [weak self] error in
      if error != nil {
        self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      }
      self?.sendEvent(type: "callEnded", payload: ["callId": endedCallId as Any])
      self?.callIdByUUID[uuid] = nil
      if self?.activeCallUUID == uuid {
        self?.activeCallUUID = nil
        self?.activeCallId = nil
      }
      if self?.outgoingCallUUID == uuid {
        self?.outgoingCallUUID = nil
      }
      completion?()
    }
  }

  /// PushKit is not usable on Simulator; skip registration so Dart can still run.
  private func registerForVoipPushes() {
    if isSimulatorEnvironment() {
      return
    }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry
  }

  private func reportIncomingCall(
    callerName: String,
    callId: String,
    hasVideo: Bool,
    metadata: [String: Any],
    result: @escaping FlutterResult
  ) {
    // Simulator: skip CallKit UI; emit the same Dart events so the app can show in-app call UI.
    if isSimulatorEnvironment() {
      let uuid = UUID()
      callIdByUUID[uuid] = callId
      activeCallUUID = uuid
      activeCallId = callId
      sendEvent(type: "incomingCallReported", payload: [
        "callId": callId,
        "callerName": callerName,
        "hasVideo": hasVideo,
        "metadata": metadata,
      ])
      result(nil)
      return
    }
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.hasVideo = hasVideo
    let uuid = UUID()
    callIdByUUID[uuid] = callId
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      if let error {
        self?.callIdByUUID[uuid] = nil
        result(FlutterError(code: "callkit_error", message: error.localizedDescription, details: nil))
        return
      }
      self?.activeCallUUID = uuid
      self?.activeCallId = callId
      self?.sendEvent(type: "incomingCallReported", payload: [
        "callId": callId,
        "callerName": callerName,
        "hasVideo": hasVideo,
        "metadata": metadata,
      ])
      result(nil)
    }
  }

  private func resolvedIncomingDisplayName(
    baseCallerName: String,
    metadata: [String: Any]
  ) -> String {
    let isGroupFlag: Bool = {
      if let v = metadata["isGroupCall"] as? Bool { return v }
      if let v = metadata["isGroupCall"] as? Int { return v != 0 }
      if let v = metadata["isGroupCall"] as? String {
        let n = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "true" || n == "1"
      }
      return false
    }()
    let customType = (metadata["customType"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    let isGroupByType = customType == "groupcall" || customType == "group_call"
    let isGroupCall = isGroupFlag || isGroupByType
    if !isGroupCall { return baseCallerName }
    if baseCallerName.localizedCaseInsensitiveContains("(Group)") { return baseCallerName }
    return "\(baseCallerName) (Group)"
  }

  private func startOutgoingCall(
    calleeName: String,
    callId: String,
    hasVideo: Bool,
    metadata: [String: Any],
    result: @escaping FlutterResult
  ) {
    // Simulator: skip CallKit transactions; keep state + events aligned with device so Flutter can open call UI.
    if isSimulatorEnvironment() {
      let uuid = UUID()
      callIdByUUID[uuid] = callId
      activeCallUUID = uuid
      outgoingCallUUID = uuid
      activeCallId = callId
      sendEvent(type: "outgoingCallStarted", payload: [
        "callId": callId,
        "calleeName": calleeName,
        "hasVideo": hasVideo,
        "metadata": metadata,
      ])
      result(nil)
      return
    }
    let uuid = UUID()
    let handle = CXHandle(type: .generic, value: calleeName)
    let action = CXStartCallAction(call: uuid, handle: handle)
    action.isVideo = hasVideo
    let transaction = CXTransaction(action: action)
    callIdByUUID[uuid] = callId
    callController.request(transaction) { [weak self] error in
      if let error {
        self?.callIdByUUID[uuid] = nil
        result(FlutterError(code: "callkit_error", message: error.localizedDescription, details: nil))
        return
      }
      self?.provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
      self?.activeCallUUID = uuid
      self?.outgoingCallUUID = uuid
      self?.activeCallId = callId
      self?.sendEvent(type: "outgoingCallStarted", payload: [
        "callId": callId,
        "calleeName": calleeName,
        "hasVideo": hasVideo,
        "metadata": metadata,
      ])
      result(nil)
    }
  }

  private func endCurrentCall(result: @escaping FlutterResult) {
    cancelScheduledHangup()
    guard let uuid = activeCallUUID else {
      result(nil)
      return
    }
    endCall(uuid: uuid) {
      result(nil)
    }
  }

  private func setMute(_ isMuted: Bool, result: @escaping FlutterResult) {
    guard let uuid = activeCallUUID else {
      result(nil)
      return
    }
    if isSimulatorEnvironment() {
      _ = uuid
      sendEvent(type: "muteUpdated", payload: ["isMuted": isMuted, "callId": activeCallId as Any])
      result(nil)
      return
    }
    let action = CXSetMutedCallAction(call: uuid, muted: isMuted)
    let transaction = CXTransaction(action: action)
    callController.request(transaction) { [weak self] error in
      if let error {
        result(FlutterError(code: "callkit_error", message: error.localizedDescription, details: nil))
        return
      }
      self?.sendEvent(type: "muteUpdated", payload: ["isMuted": isMuted, "callId": self?.activeCallId as Any])
      result(nil)
    }
  }

  private func setSpeaker(_ isSpeakerOn: Bool, result: @escaping FlutterResult) {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
      try AVAudioSession.sharedInstance().setActive(true)
      try AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
      sendEvent(type: "speakerUpdated", payload: ["isSpeakerOn": isSpeakerOn, "callId": activeCallId as Any])
      result(nil)
    } catch {
      result(FlutterError(code: "audio_error", message: error.localizedDescription, details: nil))
    }
  }

  private func sendEvent(type: String, payload: [String: Any]) {
    eventSink?(["type": type, "payload": payload])
  }
}

extension IsometrikFlutterCallPlugin: PKPushRegistryDelegate {
  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
    latestVoipToken = token
    sendEvent(type: "voipTokenUpdated", payload: [
      "token": token,
      "userId": userId as Any,
      "hasSession": userToken != nil,
    ])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    latestVoipToken = nil
    sendEvent(type: "voipTokenInvalidated", payload: [:])
  }

  public func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let payloadData = payload.dictionaryPayload
    sendEvent(type: "incomingVoipPush", payload: ["payload": payloadData])
    completion()
  }
}

extension IsometrikFlutterCallPlugin: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    callIdByUUID.removeAll()
    activeCallUUID = nil
    activeCallId = nil
    outgoingCallUUID = nil
    sendEvent(type: "providerReset", payload: [:])
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    let answeredCallId = callIdForAction(uuid: action.callUUID)
    activeCallUUID = action.callUUID
    activeCallId = answeredCallId
    sendEvent(type: "callAnswered", payload: ["callId": answeredCallId as Any])
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let endedCallId = callIdForAction(uuid: action.callUUID)
    sendEvent(type: "callEnded", payload: ["callId": endedCallId as Any])
    callIdByUUID[action.callUUID] = nil
    if activeCallUUID == action.callUUID {
      activeCallUUID = nil
      activeCallId = nil
    }
    if outgoingCallUUID == action.callUUID {
      outgoingCallUUID = nil
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    let connectingCallId = callIdForAction(uuid: action.callUUID)
    sendEvent(type: "callConnecting", payload: ["callId": connectingCallId as Any])
    action.fulfill()
  }
}
