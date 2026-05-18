import AVFAudio
import CallKit
import Flutter
import Foundation
import PushKit
import UIKit
import WebRTC

// MARK: - PushKit diagnostics (UserDefaults ring buffer)
//
/// Persists lightweight traces across crashes / force-quits so the example **Settings → diagnostics**
/// (or Dart `getIosPushKitDiagnostics`) can show last VoIP payloads (keys only), CallKit outcomes,
/// and app state — without streaming large secrets through the Flutter event sink.
///
/// **Rows:** `pushkit_delegate_invoked` (OS delivered to delegate, before main/CallKit), then
/// `pushkit` / `pushkit_simulator` / `pushkit_completion_timeout` as handling proceeds.
///
/// **Reuse:** Extend `appendPushKitDiag` fields if new failure modes need capture; keep records plist/JSON safe.
private enum IsometrikPushKitDiagnosticsStore {
  static let defaultsKey = "isometrik_flutter_call.pushkit_diag_v1"
  static let maxRecords = 40

  static func read() -> [[String: Any]] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return []
    }
    return arr
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }

  /// - Parameter record: Must be JSON-serializable (String, number, bool, array, dict of same).
  static func append(record: [String: Any]) {
    var rows = read()
    rows.insert(record, at: 0)
    if rows.count > maxRecords {
      rows = Array(rows.prefix(maxRecords))
    }
    guard JSONSerialization.isValidJSONObject(rows),
      let data = try? JSONSerialization.data(withJSONObject: rows)
    else {
      NSLog("[ISMCall] diagnostics: skipped append (invalid JSON)")
      return
    }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }

  /// ISO-8601 for JSON / Dart `DateTime.parse`.
  static func nowIso8601() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
  }
}

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
  /// Hex VoIP credential from PushKit `didUpdate`. Cleared **only** in `didInvalidatePushToken`.
  ///
  /// **Not cleared on Flutter `unregisterVoipToken`** (logout): the OS rarely calls `didUpdate` again until
  /// rotation, so retaining this lets us replay `voipTokenUpdated` once Dart reconnects listeners or calls
  /// `registerForVoipPushes` — matching Dart `PATCH /chat/user` after `updateUserSession`.
  private var lastPushKitVoipTokenHex: String?
  private var userId: String?
  private var userToken: String?
  private var configuration: [String: Any] = [:]
  private let callObserver = CXCallObserver()
  private var hangupWorkItem: DispatchWorkItem?
  /// True when PushKit path already called `reportNewIncomingCall` for this VoIP push.
  /// Dart reads via `wasCallKitReportedNatively` to avoid duplicate CallKit UI.
  private var nativeCallKitReported: Bool = false
  /// Last known call uses video — drives `AVAudioSession` mode during WebRTC reactivation.
  private var activeCallHasVideo: Bool = false

  /// Fires every foreground transition — Dart uses this when the in-call UI has no
  /// [WidgetsBindingObserver] (e.g. locked device + minimized PiP, or terminated → VoIP wake).
  private var didBecomeActiveObserver: NSObjectProtocol?

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
    // Foreground events are not delivered through CallKit — needed so LiveKit/WebRTC can
    // re-sync mic + speaker after unlock / app resume (PushKit answer from lock screen).
    instance.didBecomeActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak instance] _ in
      instance?.sendEvent(type: "iosAppBecameActive", payload: [
        "reason": "UIApplication.didBecomeActiveNotification",
      ])
    }
    /// **Critical:** `PKPushRegistry` must exist early (before Dart runs `registerForVoipPushes`), or a
    /// VoIP wake on a terminated app can miss the delegate and violate PushKit lifecycle expectations.
    instance.ensureVoipPushRegistryConfigured()
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    replayPushKitVoipTokenToDartIfAvailable()
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
      // Keep `lastPushKitVoipTokenHex` — see property note (replay after re-login).
      sendEvent(type: "voipTokenInvalidated", payload: [:])
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
    case "wasCallKitReportedNatively":
      result(nativeCallKitReported)
      nativeCallKitReported = false
    case "reactivateIosCallAudioSession":
      let args = call.arguments as? [String: Any] ?? [:]
      if let hv = args["hasVideo"] as? Bool {
        activeCallHasVideo = hv
      }
      reactivateAudioSessionForWebRTC()
      result(nil)
    case "getIosPushKitDiagnostics":
      let rows = IsometrikPushKitDiagnosticsStore.read()
      result(Self.sanitizeForStandardMessageCodec(rows))
    case "clearIosPushKitDiagnostics":
      IsometrikPushKitDiagnosticsStore.clear()
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

  /// Registers once on the **main queue** so CallKit-facing delegate work stays main-aligned.
  /// Idempotent — safe when Dart calls [registerForVoipPushes] after plugin startup.
  ///
  /// **Reuse:** Also invoked from `register(with:)` so terminated-app VoIP wakes always have a registry.
  private func ensureVoipPushRegistryConfigured() {
    if isSimulatorEnvironment() {
      return
    }
    guard pushRegistry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    pushRegistry = registry
    NSLog("[ISMCall] PKPushRegistry configured at plugin load (early VoIP readiness)")
  }

  /// PushKit is not usable on Simulator; skip registration so Dart can still run.
  private func registerForVoipPushes() {
    ensureVoipPushRegistryConfigured()
    replayPushKitVoipTokenToDartIfAvailable()
  }

  /// Re-emit PushKit credential if we already received one — typical after cold start subscribe or logout/login
  /// (OS usually does **not** call `didUpdate` again for the same credential).
  private func replayPushKitVoipTokenToDartIfAvailable() {
    if isSimulatorEnvironment() {
      return
    }
    guard let hex = lastPushKitVoipTokenHex else { return }
    sendEvent(type: "voipTokenUpdated", payload: [
      "token": hex,
      "userId": userId as Any,
      "hasSession": userToken != nil,
      "replay": true,
    ])
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
      activeCallHasVideo = hasVideo
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
    update.localizedCallerName = callerName
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
      self?.activeCallHasVideo = hasVideo
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
      activeCallHasVideo = hasVideo
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
      self?.activeCallHasVideo = hasVideo
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
    callController.request(transaction) { error in
      if let error {
        result(FlutterError(code: "callkit_error", message: error.localizedDescription, details: nil))
        return
      }
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
    let safePayload = Self.sanitizeForStandardMessageCodec(payload) as? [String: Any] ?? [:]
    eventSink?(["type": type, "payload": safePayload])
  }

  /// Flutter's `StandardMessageCodec` only accepts a narrow set of types. VoIP JSON often includes
  /// `Date`, non-string dictionary keys, or custom objects — those can **crash the engine** or drop events.
  ///
  /// **Reuse:** Any new `sendEvent` payloads should pass through this path (via `sendEvent`).
  private static func sanitizeForStandardMessageCodec(_ value: Any) -> Any {
    switch value {
    case let b as Bool:
      return b
    case let i as Int:
      return i
    case let i as Int64:
      return i
    case let d as Double:
      return d
    case let f as Float:
      return Double(f)
    case let n as NSNumber:
      return n
    case let s as String:
      return s
    case let d as Date:
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f.string(from: d)
    case let dict as [String: Any]:
      var out: [String: Any] = [:]
      out.reserveCapacity(dict.count)
      for (k, v) in dict {
        out[k] = sanitizeForStandardMessageCodec(v)
      }
      return out
    case let dict as [AnyHashable: Any]:
      var out: [String: Any] = [:]
      for (k, v) in dict {
        guard let ks = k as? String else { continue }
        out[ks] = sanitizeForStandardMessageCodec(v)
      }
      return out
    case let arr as [Any]:
      return arr.map { sanitizeForStandardMessageCodec($0) }
    case let arr as NSArray:
      return (0..<arr.count).map { sanitizeForStandardMessageCodec(arr.object(at: $0)) }
    case is NSNull:
      return NSNull()
    default:
      return String(describing: value)
    }
  }

  /// `PKPushPayload.dictionaryPayload` is `[AnyHashable: Any]` on some SDKs — normalize for string keys.
  private static func stringKeyedPayload(_ raw: [AnyHashable: Any]) -> [String: Any] {
    if let direct = raw as? [String: Any] { return direct }
    var out: [String: Any] = [:]
    for (k, v) in raw {
      if let ks = k as? String { out[ks] = v }
    }
    return out
  }

  /// Earliest hook: **OS invoked** our PushKit VoIP delegate — logged **before** optional
  /// `DispatchQueue.main.async` for CallKit. Persists a row with `incomingPath == pushkit_delegate_invoked`
  /// so Settings / the Dart `getIosPushKitDiagnostics` method can distinguish “no push” vs “push arrived but failed later”.
  private static func appendPushKitDelegateInvokedDiagnostic(payload: PKPushPayload) {
    let onMain = Thread.isMainThread
    let raw = payload.dictionaryPayload
    var keys = Set<String>()
    for k in raw.keys {
      if let s = k as? String { keys.insert(s) }
    }
    let sortedKeys = keys.sorted()
    let appState: String = {
      guard onMain else { return "n/a_off_main_delegate" }
      switch UIApplication.shared.applicationState {
      case .active: return "active"
      case .inactive: return "inactive"
      case .background: return "background"
      @unknown default: return "unknown"
      }
    }()
    IsometrikPushKitDiagnosticsStore.append(record: [
      "ts": IsometrikPushKitDiagnosticsStore.nowIso8601(),
      "incomingPath": "pushkit_delegate_invoked",
      "delegateOnMainThread": onMain,
      "willAsyncToMainForCallKit": !onMain,
      "appState": appState,
      "payloadTopLevelKeys": sortedKeys,
      "note":
        "OS delivered VoIP push to PKPushRegistryDelegate; handling continues on main when required for CallKit.",
    ])
  }

  /// Aligns with Dart [IsometrikMeeting.fromJson] / server VoIP payloads so CallKit shows the real caller.
  private static func resolvedVoipCallerDisplayName(from payload: [String: Any]) -> String {
    let stringKeys: [String] = [
      "callerName", "caller_name",
      "initiatorName", "initiatorUserName", "createdByName",
      "senderName",
      "name", "displayName", "display_name",
      "userName", "username", "memberName",
      "title", "label",
    ]
    for key in stringKeys {
      if let s = payload[key] as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
      }
    }
    if let user = payload["user"] as? [String: Any] {
      let nestedKeys = ["userName", "name", "displayName", "callerName"]
      for key in nestedKeys {
        if let s = user[key] as? String {
          let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
          if !t.isEmpty { return t }
        }
      }
    }
    var initiatorCandidates = Set<String>()
    for key in ["initiatorIdentifier", "initiatorId", "callerId", "senderId", "userId", "createdBy"] {
      if let s = payload[key] as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { initiatorCandidates.insert(t) }
      }
    }
    if let members = payload["members"] as? [[String: Any]] {
      func name(from m: [String: Any]) -> String {
        (m["memberName"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      }
      if !initiatorCandidates.isEmpty {
        for m in members {
          let mid = (m["memberId"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let mIdent = (m["memberIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let n = name(from: m)
          if n.isEmpty { continue }
          if (!mid.isEmpty && initiatorCandidates.contains(mid))
            || (!mIdent.isEmpty && initiatorCandidates.contains(mIdent))
          {
            return n
          }
        }
      }
      for m in members {
        let n = name(from: m)
        if !n.isEmpty { return n }
      }
    }
    return "Incoming Call"
  }

  /// Last-resort timeout only if `reportNewIncomingCall` never runs its completion (should be rare).
  /// Must be long enough not to beat CallKit on a slow / locked-device cold start.
  private static let voipPushKitCompletionFallbackSeconds: TimeInterval = 5.0

  /// PushKit: Apple requires `completion` to be called exactly once per VoIP push after handling.
  /// We complete immediately after CallKit’s `reportNewIncomingCall` callback (not after Flutter events).
  private func handleIncomingVoipPush(
    payload: PKPushPayload,
    pushCompletion: @escaping () -> Void
  ) {
    let payloadData = Self.stringKeyedPayload(payload.dictionaryPayload)
    let pushReceivedMono = CFAbsoluteTimeGetCurrent()
    let traceCallId =
      payloadData["callId"] as? String ?? payloadData["meetingId"] as? String ?? "?"
    let appStateLabel: String = {
      switch UIApplication.shared.applicationState {
      case .active: return "active"
      case .inactive: return "inactive"
      case .background: return "background"
      @unknown default: return "unknown"
      }
    }()
    NSLog(
      "[ISMCall] VoIP push handling on main=%@ callId=%@ appState=%@",
      Thread.isMainThread ? "yes" : "no",
      traceCallId,
      appStateLabel
    )

    var voipPushCompletionTimeout: DispatchWorkItem?
    var completed = false
    let completeVoipPushOnce: () -> Void = {
      if completed { return }
      completed = true
      voipPushCompletionTimeout?.cancel()
      voipPushCompletionTimeout = nil
      let elapsed = CFAbsoluteTimeGetCurrent() - pushReceivedMono
      NSLog("[ISMCall] VoIP PushKit completion() after %.4fs (must be once)", elapsed)
      pushCompletion()
    }

    let timeout = DispatchWorkItem {
      NSLog(
        "[ISMCall] VoIP PushKit completion FALLBACK — reportNewIncomingCall did not complete within %.0fs (complete anyway so iOS does not hang)",
        Self.voipPushKitCompletionFallbackSeconds
      )
      IsometrikPushKitDiagnosticsStore.append(record: [
        "ts": IsometrikPushKitDiagnosticsStore.nowIso8601(),
        "incomingPath": "pushkit_completion_timeout",
        "appState": appStateLabel,
        "traceCallIdHint": traceCallId,
        "callKitOk": false,
        "note":
          "Invoked PushKit completion() after \(Self.voipPushKitCompletionFallbackSeconds)s without CallKit callback — investigate main-thread contention or CallKit deadlock.",
      ])
      completeVoipPushOnce()
    }
    voipPushCompletionTimeout = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.voipPushKitCompletionFallbackSeconds,
      execute: timeout
    )

    let callerName: String = Self.resolvedVoipCallerDisplayName(from: payloadData)

    let explicitCallId: String? = {
      func nonEmpty(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
          return nil
        }
        return t
      }
      func stringFrom(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return nonEmpty(s) }
        if let n = v as? NSNumber { return nonEmpty("\(n)") }
        if let i = v as? Int { return nonEmpty("\(i)") }
        if let i = v as? Int64 { return nonEmpty("\(i)") }
        return nil
      }
      for key in ["callId", "call_id", "meetingId"] {
        if let s = stringFrom(payloadData[key]) { return s }
      }
      return nil
    }()
    let usedFallbackCallId = explicitCallId == nil
    let callId = explicitCallId ?? UUID().uuidString

    let hasVideo: Bool = {
      if let v = payloadData["hasVideo"] as? Bool { return v }
      if let v = payloadData["has_video"] as? Bool { return v }
      if let v = payloadData["isVideo"] as? Bool { return v }
      if let v = payloadData["hasVideo"] as? Int { return v != 0 }
      return false
    }()

    activeCallHasVideo = hasVideo

    if isSimulatorEnvironment() {
      completeVoipPushOnce()
      sendEvent(type: "incomingVoipPush", payload: ["payload": payloadData])
      IsometrikPushKitDiagnosticsStore.append(record: Self.makeVoipDiagRecord(
        incomingPath: "pushkit_simulator",
        payloadData: payloadData,
        appStateLabel: appStateLabel,
        callId: callId,
        callerName: callerName,
        hasVideo: hasVideo,
        usedFallbackCallId: usedFallbackCallId,
        nonEndedCxCallCount: 0,
        tookActivePointer: false,
        callKitOk: true,
        callKitError: nil,
        pushCompletionElapsedSec: CFAbsoluteTimeGetCurrent() - pushReceivedMono,
        extra: ["note": "CallKit/PushKit skipped on Simulator"]
      ))
      return
    }

    let nonEndedCxCallCount = callObserver.calls.filter { !$0.hasEnded }.count
    /// When another CallKit call is already present (ringing or connected), do not move the
    /// “active” pointer — call-waiting uses [CXAnswerCallAction] to repoint [activeCallUUID].
    let shouldTakeActiveSlot = nonEndedCxCallCount == 0

    let uuid = UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.hasVideo = hasVideo
    update.localizedCallerName = callerName

    callIdByUUID[uuid] = callId

    let reportStart = CFAbsoluteTimeGetCurrent()
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      let reportElapsed = CFAbsoluteTimeGetCurrent() - reportStart
      NSLog("[ISMCall] reportNewIncomingCall finished in %.4fs", reportElapsed)
      guard let self else {
        completeVoipPushOnce()
        return
      }
      if let error {
        NSLog("[ISMCall] CallKit rejected VoIP incoming call: \(error.localizedDescription)")
        self.callIdByUUID[uuid] = nil
        if self.activeCallUUID == uuid {
          self.activeCallUUID = nil
          self.activeCallId = nil
        }
        completeVoipPushOnce()
        IsometrikPushKitDiagnosticsStore.append(record: Self.makeVoipDiagRecord(
          incomingPath: "pushkit",
          payloadData: payloadData,
          appStateLabel: appStateLabel,
          callId: callId,
          callerName: callerName,
          hasVideo: hasVideo,
          usedFallbackCallId: usedFallbackCallId,
          nonEndedCxCallCount: nonEndedCxCallCount,
          tookActivePointer: false,
          callKitOk: false,
          callKitError: error.localizedDescription,
          pushCompletionElapsedSec: CFAbsoluteTimeGetCurrent() - pushReceivedMono,
          extra: ["reportElapsedSec": reportElapsed]
        ))
        self.sendEvent(type: "incomingVoipPush", payload: [
          "payload": payloadData,
          "callId": callId,
          "callerName": callerName,
          "hasVideo": hasVideo,
          "callkitError": error.localizedDescription,
        ])
        return
      }

      if shouldTakeActiveSlot {
        self.activeCallUUID = uuid
        self.activeCallId = callId
      }
      self.nativeCallKitReported = true

      completeVoipPushOnce()
      IsometrikPushKitDiagnosticsStore.append(record: Self.makeVoipDiagRecord(
        incomingPath: "pushkit",
        payloadData: payloadData,
        appStateLabel: appStateLabel,
        callId: callId,
        callerName: callerName,
        hasVideo: hasVideo,
        usedFallbackCallId: usedFallbackCallId,
        nonEndedCxCallCount: nonEndedCxCallCount,
        tookActivePointer: shouldTakeActiveSlot,
        callKitOk: true,
        callKitError: nil,
        pushCompletionElapsedSec: CFAbsoluteTimeGetCurrent() - pushReceivedMono,
        extra: ["reportElapsedSec": reportElapsed]
      ))
      self.sendEvent(type: "incomingVoipPush", payload: [
        "payload": payloadData,
        "callId": callId,
        "callerName": callerName,
        "hasVideo": hasVideo,
      ])
    }
  }

  /// JSON-safe row for [IsometrikPushKitDiagnosticsStore] — **keys only** from payload to limit PII / size.
  private static func makeVoipDiagRecord(
    incomingPath: String,
    payloadData: [String: Any],
    appStateLabel: String,
    callId: String,
    callerName: String,
    hasVideo: Bool,
    usedFallbackCallId: Bool,
    nonEndedCxCallCount: Int,
    tookActivePointer: Bool,
    callKitOk: Bool,
    callKitError: String?,
    pushCompletionElapsedSec: TimeInterval,
    extra: [String: Any] = [:]
  ) -> [String: Any] {
    let sortedKeys = payloadData.keys.sorted()
    var row: [String: Any] = [
      "ts": IsometrikPushKitDiagnosticsStore.nowIso8601(),
      "incomingPath": incomingPath,
      "appState": appStateLabel,
      "callId": callId,
      "callerName": callerName,
      "hasVideo": hasVideo,
      "usedFallbackCallId": usedFallbackCallId,
      "nonEndedCxCallCount": nonEndedCxCallCount,
      "tookActivePointer": tookActivePointer,
      "callKitOk": callKitOk,
      "pushCompletionElapsedSec": pushCompletionElapsedSec,
      "payloadTopLevelKeys": sortedKeys,
    ]
    if let callKitError {
      row["callKitError"] = callKitError
    }
    if !extra.isEmpty {
      row["extra"] = sanitizeForStandardMessageCodec(extra) as? [String: Any] ?? [:]
    }
    return row
  }

  /// WebRTC's `RTCAudioSession` observes `AVAudioSession.interruptionNotification`. A synthetic
  /// `.began` then `.ended(.shouldResume)` cycle restarts the audio unit when CallKit / background
  /// wake leaves capture or playback stuck (no mic / no remote audio).
  private func reactivateAudioSessionForWebRTC() {
    let session = AVAudioSession.sharedInstance()
    let hasVideo = activeCallHasVideo
    NSLog(
      "[ISMCall] reactivateAudioSession hasVideo=\(hasVideo) category=\(session.category.rawValue) mode=\(session.mode.rawValue)"
    )

    NotificationCenter.default.post(
      name: AVAudioSession.interruptionNotification,
      object: session,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
      ]
    )
    NSLog("[ISMCall] Posted synthetic interruption .began")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      let mode: AVAudioSession.Mode = hasVideo ? .videoChat : .voiceChat
      var options: AVAudioSession.CategoryOptions = [
        .allowBluetooth,
        .allowBluetoothA2DP,
        .allowAirPlay,
      ]
      if hasVideo {
        options.insert(.defaultToSpeaker)
      }

      // Must use `RTCAudioSession` + `lockForConfiguration` — raw `AVAudioSession` changes fail with
      // "Session activation failed" while WebRTC/LiveKit own the session (kRTCAudioSessionErrorLockRequired).
      let rtcSession = RTCAudioSession.sharedInstance()
      rtcSession.lockForConfiguration()
      defer { rtcSession.unlockForConfiguration() }
      do {
        try rtcSession.setCategory(.playAndRecord, mode: mode, options: options)
        NSLog("[ISMCall] RTCAudioSession setCategory ok mode=\(mode.rawValue)")
        do {
          try rtcSession.setActive(true)
          NSLog("[ISMCall] RTCAudioSession setActive ok")
        } catch {
          NSLog("[ISMCall] RTCAudioSession setActive (non-fatal): \(error.localizedDescription)")
        }
      } catch {
        NSLog("[ISMCall] RTCAudioSession setCategory failed: \(error.localizedDescription)")
      }

      var endedInfo: [AnyHashable: Any] = [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      ]
      endedInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue

      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: session,
        userInfo: endedInfo
      )
      NSLog("[ISMCall] Posted synthetic interruption .ended shouldResume — category=\(session.category.rawValue)")

      rtcSession.audioSessionDidActivate(session)
      rtcSession.isAudioEnabled = true
      NSLog("[ISMCall] RTCAudioSession re-synced after synthetic interruption")
    }
  }
}

extension IsometrikFlutterCallPlugin: PKPushRegistryDelegate {
  public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
    lastPushKitVoipTokenHex = token
    sendEvent(type: "voipTokenUpdated", payload: [
      "token": token,
      "userId": userId as Any,
      "hasSession": userToken != nil,
    ])
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    lastPushKitVoipTokenHex = nil
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
    Self.appendPushKitDelegateInvokedDiagnostic(payload: payload)
    // CallKit must run on the main queue. Funnel here so PushKit always reaches `handleIncomingVoipPush`
    // on main (background / locked wake may call the delegate off-main depending on OS behavior).
    let run: () -> Void = { [weak self] in
      guard let self else {
        NSLog("[ISMCall] VoIP push: plugin deallocated before handling — completing PushKit to satisfy API contract")
        completion()
        return
      }
      self.handleIncomingVoipPush(payload: payload, pushCompletion: completion)
    }
    if Thread.isMainThread {
      run()
    } else {
      NSLog("[ISMCall] VoIP push: delegate off main — async to main for CallKit")
      DispatchQueue.main.async(execute: run)
    }
  }
}

extension IsometrikFlutterCallPlugin: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    nativeCallKitReported = false
    callIdByUUID.removeAll()
    activeCallUUID = nil
    activeCallId = nil
    outgoingCallUUID = nil
    activeCallHasVideo = false
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

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    let mutedCallId = callIdForAction(uuid: action.callUUID)
    let resolvedCallId = mutedCallId ?? activeCallId
    sendEvent(type: "muteUpdated", payload: [
      "isMuted": action.isMuted,
      "callId": resolvedCallId as Any,
    ])
    action.fulfill()
  }

  /// WebRTC/LiveKit must be told when CallKit activates the shared `AVAudioSession` (answer from lock
  /// screen / background); otherwise capture and playback often stay silent.
  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(audioSession)
    rtc.isAudioEnabled = true
    // Do not run `reactivateAudioSessionForWebRTC()` here: posting `.began` stops WebRTC’s audio
    // unit before LiveKit has opened the mic (background answer), which can leave capture dead.
    // Reactivation runs from Dart after `Room.connect` + local track setup (see `reactivateIosCallAudioSession`).
    sendEvent(type: "callAudioSessionActivated", payload: [
      "reason": "callKit",
    ])
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
  }
}
