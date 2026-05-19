import AVFAudio
import Foundation
import WebRTC

// MARK: - Native VoIP audio (CallKit + WebRTC / LiveKit)
//
// **Why this exists:** Flutter timers are unreliable when backgrounded / locked. Native code handles
// CallKit `didActivate` and pre-LiveKit wake; after LiveKit connects, call [handoffToLiveKit] so we do
// not fight LiveKit's own `RTCAudioSession` configuration (causes 500ms–1500ms glitches on audio calls).
//
// **Reuse:** `iosBeginVoipCallAudio` / `iosRefreshVoipCallAudio` / `iosHandoffVoipCallAudioToLiveKit` /
// `iosEndVoipCallAudio` via `IsometrikFlutterCallPlugin`.

final class IsometrikVoipAudioCoordinator {
  static let shared = IsometrikVoipAudioCoordinator()

  private var watchdogTimer: Timer?
  private var watchdogTicks: Int = 0
  private var hasVideo: Bool = false
  /// `false` = earpiece/receiver (default for audio calls). `true` = loudspeaker (typical for video).
  private var preferSpeaker: Bool = false
  private var sessionArmed: Bool = false
  /// After LiveKit connects, only speaker route overrides are allowed — no category/mode churn.
  private var liveKitHandoff: Bool = false

  /// Plugin sets this so the watchdog stops when CallKit has no active call UUID.
  var isCallKitCallActive: (() -> Bool)?

  private init() {}

  // MARK: - Public API

  func beginCall(hasVideo: Bool, preferSpeaker: Bool) {
    if liveKitHandoff { return }
    self.hasVideo = hasVideo
    self.preferSpeaker = preferSpeaker
    guard !sessionArmed else { return }
    sessionArmed = true
    applyStableConfiguration(reason: "begin")
    // Audio: never poll — LiveKit + CallKit manage the session once connected.
    // Video: short burst only until handoff (background / locked wake).
    if hasVideo {
      startWatchdog()
    }
  }

  /// Idempotent session tune-up before LiveKit handoff. `hardReset` = one interruption cycle (video only).
  func refresh(hasVideo: Bool, preferSpeaker: Bool, hardReset: Bool) {
    self.hasVideo = hasVideo
    self.preferSpeaker = preferSpeaker
    sessionArmed = true
    if liveKitHandoff {
      applyOutputRouteOnly(reason: "refresh-handoff")
      return
    }
    if hardReset {
      guard hasVideo else {
        applyStableConfiguration(reason: "refresh-no-hardReset-audio")
        return
      }
      applyInterruptionRecoveryCycle(reason: "hardReset")
    } else {
      applyStableConfiguration(reason: "refresh")
    }
  }

  /// Dart calls after `Room.connect` / publish — stops watchdog and category/mode overrides.
  func handoffToLiveKit() {
    liveKitHandoff = true
    stopWatchdog()
    NSLog("[ISMCall][Audio] handoff to LiveKit (no more category/mode overrides)")
  }

  func endCall() {
    sessionArmed = false
    liveKitHandoff = false
    watchdogTicks = 0
    stopWatchdog()
  }

  /// User / Dart toggled speaker vs earpiece — route only (safe after LiveKit handoff).
  func setPreferSpeaker(_ enabled: Bool) {
    preferSpeaker = enabled
    applyOutputRouteOnly(reason: "setPreferSpeaker")
  }

  /// Whether playback is on the built-in loudspeaker (vs receiver / BT / wired headset).
  func isBuiltInSpeakerActive() -> Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains {
      $0.portType == .builtInSpeaker
    }
  }

  // MARK: - Configuration

  private func categoryOptions() -> AVAudioSession.CategoryOptions {
    // Do **not** use `.defaultToSpeaker` — it prevents toggling to earpiece/headset.
    [
      .allowBluetooth,
      .allowBluetoothA2DP,
      .allowAirPlay,
    ]
  }

  private func applyStableConfiguration(reason: String) {
    if liveKitHandoff {
      applyOutputRouteOnly(reason: "\(reason)-handoff")
      return
    }

    let session = AVAudioSession.sharedInstance()
    let mode: AVAudioSession.Mode = hasVideo ? .videoChat : .voiceChat
    let options = categoryOptions()

    if reason == "watchdog", !needsSessionReconfiguration(session: session, mode: mode) {
      return
    }

    let rtc = RTCAudioSession.sharedInstance()
    rtc.lockForConfiguration()
    defer { rtc.unlockForConfiguration() }

    do {
      try rtc.setCategory(.playAndRecord, mode: mode, options: options)
      try rtc.setActive(true)
      rtc.audioSessionDidActivate(session)
      rtc.isAudioEnabled = true
      try applyOutputRoute(on: session)
      NSLog(
        "[ISMCall][Audio] stable \(reason) mode=\(mode.rawValue) speaker=\(preferSpeaker)"
      )
    } catch {
      NSLog("[ISMCall][Audio] stable \(reason) failed: \(error.localizedDescription)")
    }
  }

  private func applyOutputRouteOnly(reason: String) {
    let session = AVAudioSession.sharedInstance()
    do {
      try applyOutputRoute(on: session)
      NSLog("[ISMCall][Audio] route-only \(reason) speaker=\(preferSpeaker)")
    } catch {
      NSLog("[ISMCall][Audio] route-only \(reason) failed: \(error.localizedDescription)")
    }
  }

  private func needsSessionReconfiguration(session: AVAudioSession, mode: AVAudioSession.Mode) -> Bool {
    if session.category != .playAndRecord { return true }
    if session.mode != mode { return true }
    let rtc = RTCAudioSession.sharedInstance()
    if !rtc.isAudioEnabled { return true }
    return false
  }

  private func applyOutputRoute(on session: AVAudioSession) throws {
    if preferSpeaker {
      try session.overrideOutputAudioPort(.speaker)
    } else {
      try session.overrideOutputAudioPort(.none)
    }
  }

  // MARK: - Hard reset (video only, once before LiveKit handoff)

  private func applyInterruptionRecoveryCycle(reason: String) {
    let session = AVAudioSession.sharedInstance()
    NSLog("[ISMCall][Audio] interruption cycle \(reason)")

    NotificationCenter.default.post(
      name: AVAudioSession.interruptionNotification,
      object: session,
      userInfo: [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
      ]
    )

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.applyStableConfiguration(reason: "\(reason)-ended")

      var endedInfo: [AnyHashable: Any] = [
        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
      ]
      endedInfo[AVAudioSessionInterruptionOptionKey] =
        AVAudioSession.InterruptionOptions.shouldResume.rawValue
      NotificationCenter.default.post(
        name: AVAudioSession.interruptionNotification,
        object: session,
        userInfo: endedInfo
      )
    }
  }

  // MARK: - Watchdog (video only, pre-handoff, sparse + idempotent)

  private func startWatchdog() {
    stopWatchdog()
    watchdogTicks = 0
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
        guard let self else { return }
        if self.liveKitHandoff || !self.hasVideo {
          self.stopWatchdog()
          return
        }
        guard self.sessionArmed else {
          self.stopWatchdog()
          return
        }
        let callActive = self.isCallKitCallActive?() ?? false
        if !callActive {
          self.stopWatchdog()
          return
        }
        self.watchdogTicks += 1
        if self.watchdogTicks > 6 {
          self.stopWatchdog()
          NSLog("[ISMCall][Audio] watchdog stopped (max ticks)")
          return
        }
        self.applyStableConfiguration(reason: "watchdog")
      }
      self.watchdogTimer = timer
      RunLoop.main.add(timer, forMode: .common)
      NSLog("[ISMCall][Audio] video watchdog started (4s, max 6)")
    }
  }

  private func stopWatchdog() {
    watchdogTimer?.invalidate()
    watchdogTimer = nil
  }
}
