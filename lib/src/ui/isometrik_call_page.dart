import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import 'isometrik_call_controller.dart';

/// Configuration for customising the SDK's default [IsometrikCallPage].
///
/// Every property is optional — sensible defaults are applied.  Host apps
/// can override individual sections (header, avatar, controls) via builder
/// callbacks while keeping the rest of the default UI.
class IsometrikCallPageConfig {
  const IsometrikCallPageConfig({
    this.backgroundColor = Colors.black,
    this.showEncryptionLabel = true,
    this.encryptionLabelText = 'End-to-end encrypted',
    this.showVideoUpgradeButton = true,
    this.showMeetingIdDebug = false,
    this.autoPopOnEnded = true,
    this.autoPopDelay = const Duration(seconds: 2),
    this.headerBuilder,
    this.avatarBuilder,
    this.controlsBuilder,
    this.statusTextStyle,
    this.peerNameTextStyle,
    this.onCallEnded,
  });

  final Color backgroundColor;

  /// Show the "End-to-end encrypted" label in the header.
  final bool showEncryptionLabel;
  final String encryptionLabelText;

  /// Show the "Request video call" button when audio-only and connected.
  final bool showVideoUpgradeButton;

  /// Show the raw meetingId below the peer name (debug / diagnostics).
  final bool showMeetingIdDebug;

  /// Auto-pop this route after the call ends.
  final bool autoPopOnEnded;
  final Duration autoPopDelay;

  /// Replace the default header row. Return `null` to fall back to default.
  final Widget Function(BuildContext context, IsometrikCallController ctrl)?
      headerBuilder;

  /// Replace the default avatar circle. Return `null` to fall back to default.
  final Widget Function(BuildContext context, IsometrikCallController ctrl)?
      avatarBuilder;

  /// Replace the default control buttons (mute / speaker / end).
  final Widget Function(BuildContext context, IsometrikCallController ctrl)?
      controlsBuilder;

  final TextStyle? statusTextStyle;
  final TextStyle? peerNameTextStyle;

  /// Fires after the call ends (and after auto-pop if enabled).
  final VoidCallback? onCallEnded;
}

/// Default in-call screen provided by the SDK.
///
/// Displays call status (calling → ringing → connected with timer → ended),
/// audio controls (mute, speaker, end), and video upgrade negotiation.
///
/// Mirrors Swift `ISMLiveCallView.swift` + `ISMCallControlsView.swift`.
///
/// **Quick start:**
/// ```dart
/// final controller = await sdk.startCall(
///   memberId: userId,
///   memberName: 'Alice',
/// );
/// if (controller != null) {
///   IsometrikCallPage.show(context, controller: controller);
/// }
/// ```
class IsometrikCallPage extends StatefulWidget {
  const IsometrikCallPage({
    super.key,
    required this.controller,
    this.config = const IsometrikCallPageConfig(),
  });

  final IsometrikCallController controller;
  final IsometrikCallPageConfig config;

  /// Convenience method to push the call page onto the navigator.
  static Future<void> show(
    BuildContext context, {
    required IsometrikCallController controller,
    IsometrikCallPageConfig config = const IsometrikCallPageConfig(),
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => IsometrikCallPage(
          controller: controller,
          config: config,
        ),
      ),
    );
  }

  @override
  State<IsometrikCallPage> createState() => _IsometrikCallPageState();
}

class _IsometrikCallPageState extends State<IsometrikCallPage> {
  bool _endedPopScheduled = false;

  IsometrikCallController get _ctrl => widget.controller;
  IsometrikCallPageConfig get _cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});

    if (_ctrl.status == IsometrikCallStatus.ended &&
        _cfg.autoPopOnEnded &&
        !_endedPopScheduled) {
      _endedPopScheduled = true;
      Future<void>.delayed(_cfg.autoPopDelay, () {
        if (mounted) {
          _cfg.onCallEnded?.call();
          Navigator.of(context).maybePop();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final videoReq = _ctrl.videoUpgradeRequest;
    final isEnded = _ctrl.status == IsometrikCallStatus.ended;

    return Scaffold(
      backgroundColor: _cfg.backgroundColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // --- Header ---
            _cfg.headerBuilder?.call(context, _ctrl) ?? _buildDefaultHeader(),

            // --- Video upgrade incoming request banner ---
            if (videoReq != null) _buildVideoUpgradeBanner(videoReq),

            const Spacer(),

            // --- Avatar ---
            _cfg.avatarBuilder?.call(context, _ctrl) ?? _buildDefaultAvatar(),

            const SizedBox(height: 28),

            // --- Status text (Calling… / Ringing… / 01:23 / Call Ended) ---
            _buildStatusText(),

            const SizedBox(height: 8),

            // --- Peer name ---
            Text(
              _ctrl.peerName,
              textAlign: TextAlign.center,
              style: _cfg.peerNameTextStyle ??
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                  ),
            ),

            if (_cfg.showMeetingIdDebug) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                _ctrl.meetingId,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white24, fontSize: 11),
              ),
            ],

            const Spacer(),

            // --- Video upgrade request button (audio-only + connected) ---
            if (_cfg.showVideoUpgradeButton &&
                !_ctrl.hasVideo &&
                _ctrl.status == IsometrikCallStatus.connected &&
                videoReq == null)
              _buildVideoUpgradeRequestButton(),

            // --- Controls ---
            _cfg.controlsBuilder?.call(context, _ctrl) ??
                _buildDefaultControls(isEnded),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Default sub-widgets
  // ---------------------------------------------------------------------------

  Widget _buildDefaultHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: Colors.white70,
              size: 20,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (_cfg.showEncryptionLabel)
                  Text(
                    _cfg.encryptionLabelText,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white38),
                  ),
                Text(
                  _ctrl.hasVideo ? 'Video Call' : 'Audio Call',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    final initials = _ctrl.peerName
        .split(' ')
        .where((String s) => s.isNotEmpty)
        .take(2)
        .map((String s) => s[0].toUpperCase())
        .join();

    // Pulsing ring animation for calling/ringing states.
    final showPulse = _ctrl.status == IsometrikCallStatus.calling ||
        _ctrl.status == IsometrikCallStatus.ringing;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (showPulse) _PulsingRing(diameter: 120),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white12,
              border: Border.all(color: Colors.white24, width: 2),
            ),
            alignment: Alignment.center,
            child: Text(
              initials.isEmpty ? '?' : initials,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusText() {
    final color = switch (_ctrl.status) {
      IsometrikCallStatus.calling => Colors.white54,
      IsometrikCallStatus.ringing => Colors.amber.shade200,
      IsometrikCallStatus.connecting => Colors.white54,
      IsometrikCallStatus.connected => Colors.white,
      IsometrikCallStatus.ended => Colors.red.shade200,
    };

    final fontSize =
        _ctrl.status == IsometrikCallStatus.connected ? 44.0 : 18.0;

    return Text(
      _ctrl.statusText,
      textAlign: TextAlign.center,
      style: _cfg.statusTextStyle?.copyWith(color: color, fontSize: fontSize) ??
          TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: _ctrl.status == IsometrikCallStatus.connected
                ? FontWeight.w300
                : FontWeight.w400,
          ),
    );
  }

  Widget _buildVideoUpgradeBanner(IsometrikMeeting meeting) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '${meeting.senderName ?? 'Peer'} wants to switch to video',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: _ctrl.isPublishBusy
                          ? null
                          : () => _ctrl.respondToVideoUpgrade(accept: true),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                      child: const Text('Accept'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _ctrl.isPublishBusy
                          ? null
                          : () => _ctrl.respondToVideoUpgrade(accept: false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      child: const Text('Decline'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoUpgradeRequestButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Center(
        child: TextButton.icon(
          onPressed: _ctrl.isPublishBusy ? null : _ctrl.requestVideoUpgrade,
          icon: const Icon(Icons.videocam, color: Colors.white60),
          label: Text(
            _ctrl.isPublishBusy ? 'Sending…' : 'Request video call',
            style: const TextStyle(color: Colors.white60),
          ),
        ),
      ),
    );
  }

  Widget _buildDefaultControls(bool isEnded) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _CallControlButton(
            icon: _ctrl.isMuted ? Icons.mic_off : Icons.mic,
            label: _ctrl.isMuted ? 'Unmute' : 'Mute',
            isActive: _ctrl.isMuted,
            onTap: isEnded ? null : _ctrl.toggleMute,
          ),
          _CallControlButton(
            icon: _ctrl.isSpeaker ? Icons.volume_up : Icons.volume_down,
            label: _ctrl.isSpeaker ? 'Speaker' : 'Earpiece',
            isActive: _ctrl.isSpeaker,
            onTap: isEnded ? null : _ctrl.toggleSpeaker,
          ),
          _CallControlButton(
            icon: Icons.call_end,
            label: 'End',
            backgroundColor: Colors.red,
            onTap: isEnded ? null : _ctrl.endCall,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Private helper widgets
// -----------------------------------------------------------------------------

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.backgroundColor,
    this.isActive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? (isActive ? Colors.white24 : Colors.white12);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Material(
          color: onTap == null ? bg.withValues(alpha: 0.3) : bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ],
    );
  }
}

/// Animated pulsing ring around the avatar during calling/ringing states.
class _PulsingRing extends StatefulWidget {
  const _PulsingRing({required this.diameter});

  final double diameter;

  @override
  State<_PulsingRing> createState() => _PulsingRingState();
}

class _PulsingRingState extends State<_PulsingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (BuildContext context, Widget? child) {
        final scale = 1.0 + _anim.value * 0.25;
        final opacity = 1.0 - _anim.value;
        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Container(
              width: widget.diameter,
              height: widget.diameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24, width: 2),
              ),
            ),
          ),
        );
      },
    );
  }
}
