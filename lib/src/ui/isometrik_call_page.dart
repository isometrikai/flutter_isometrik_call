import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

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
    bool animateFromMinimized = false,
    Offset? minimizedOffset,
  }) {
    const minimizedSize = Size(170, 220);
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, __, ___) => IsometrikCallPage(
          controller: controller,
          config: config,
        ),
        transitionsBuilder: (BuildContext routeContext, Animation<double> animation,
            Animation<double> secondaryAnimation, Widget child) {
          final viewport = MediaQuery.sizeOf(routeContext);
          final fullRect = Offset.zero & viewport;
          final pipOffset = minimizedOffset ?? controller.minimizedWindowOffset;
          final pipRect = Rect.fromLTWH(
            pipOffset.dx,
            pipOffset.dy,
            minimizedSize.width,
            minimizedSize.height,
          );

          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final isReversing = animation.status == AnimationStatus.reverse;
          final fromRect = isReversing
              ? fullRect
              : (animateFromMinimized ? pipRect : fullRect);
          final toRect = isReversing && controller.isMinimized ? pipRect : fullRect;
          final rect = Rect.lerp(fromRect, toRect, curved.value) ?? fullRect;
          final rounded = (animateFromMinimized && !isReversing) ||
              (isReversing && controller.isMinimized);
          final radius = BorderRadius.circular(rounded ? 14 * (1 - curved.value) : 0);

          if (rect == fullRect && radius == BorderRadius.zero) {
            return child;
          }
          return Stack(
            children: <Widget>[
              Positioned.fromRect(
                rect: rect,
                child: ClipRRect(borderRadius: radius, child: child),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  State<IsometrikCallPage> createState() => _IsometrikCallPageState();
}

class _IsometrikCallPageState extends State<IsometrikCallPage> {
  bool _endedPopScheduled = false;
  bool _allowNextPop = false;

  IsometrikCallController get _ctrl => widget.controller;
  IsometrikCallPageConfig get _cfg => widget.config;

  void _runAction(Future<void> Function() action, {String? label}) {
    unawaited(
      action().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          'IsometrikCallPage action${label != null ? ' [$label]' : ''} failed: $error',
        );
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    _IsometrikCallViewRegistry.markVisible(_ctrl.meetingId);
    _ctrl.addListener(_onControllerChanged);
    unawaited(_requestPermissionsOnPageOpen());
  }

  @override
  void dispose() {
    _IsometrikCallViewRegistry.markHidden(_ctrl.meetingId);
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
      _IsometrikMinimizedCallOverlay.dismiss(_ctrl.meetingId);
      Future<void>.delayed(_cfg.autoPopDelay, () {
        if (mounted) {
          _cfg.onCallEnded?.call();
          Navigator.of(context).maybePop();
        }
      });
    }
  }

  Future<void> _requestPermissionsOnPageOpen() async {
    // Keeps backward compatibility for hosts that rely on page-level preflight.
    await _ctrl.preflightPermissionsIfNeeded();
  }

  Future<bool> _onBackPressed() async {
    if (_allowNextPop) return true;
    if (_ctrl.status == IsometrikCallStatus.ended) return true;
    final minimized = await _minimizeCallView();
    return !minimized;
  }

  Future<bool> _minimizeCallView() async {
    if (_ctrl.isMinimized) return true;
    final overlayAnchorContext =
        Navigator.maybeOf(context, rootNavigator: true)?.context ?? context;
    _ctrl.setMinimized(true);
    final popped = await _popCallRoute();
    if (!popped) {
      _ctrl.setMinimized(false);
    } else {
      _IsometrikMinimizedCallOverlay.show(
        context: overlayAnchorContext,
        controller: _ctrl,
        config: _cfg,
      );
    }
    return popped;
  }

  Future<bool> _popCallRoute() async {
    final pageNavigator = Navigator.maybeOf(context);
    if (pageNavigator != null) {
      _allowNextPop = true;
      final didPop = await pageNavigator.maybePop();
      _allowNextPop = false;
      if (didPop) return true;
    }

    final rootNavigator = Navigator.maybeOf(context, rootNavigator: true);
    if (rootNavigator != null && !identical(rootNavigator, pageNavigator)) {
      _allowNextPop = true;
      final didPop = await rootNavigator.maybePop();
      _allowNextPop = false;
      if (didPop) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final videoReq = _ctrl.videoUpgradeRequest;
    final isEnded = _ctrl.status == IsometrikCallStatus.ended;
    final permissionBlocked = _ctrl.hasMissingPermissions;
    final showVideoLayout = _ctrl.hasVideo && _ctrl.hasAnyVideoStreaming;

    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
        backgroundColor: _cfg.backgroundColor,
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: showVideoLayout
                      ? _buildVideoCallBody(key: const ValueKey('video_layout'))
                      : _buildAudioCallBody(key: const ValueKey('audio_layout')),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.black.withValues(alpha: 0.45),
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.52),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: _buildTopSection(showVideoLayout: showVideoLayout),
              ),
              Positioned(
                top: 14,
                left: 14,
                child: _TopOverlayIconButton(
                  icon: Icons.close_fullscreen_rounded,
                  onTap: () => unawaited(_minimizeCallView()),
                ),
              ),
              if (permissionBlocked)
                Positioned(
                  top: 122,
                  left: 12,
                  right: 12,
                  child: _buildPermissionFallbackCard(),
                ),
              if (videoReq != null)
                Positioned(
                  top: permissionBlocked ? 252 : 122,
                  left: 12,
                  right: 12,
                  child: _buildVideoUpgradeBanner(videoReq),
                ),
              if (_cfg.showVideoUpgradeButton &&
                  !_ctrl.hasVideo &&
                  _ctrl.status == IsometrikCallStatus.connected &&
                  videoReq == null &&
                  !permissionBlocked)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 138,
                  child: _buildVideoUpgradeRequestButton(),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 28,
                child: _cfg.controlsBuilder?.call(context, _ctrl) ??
                    _buildModernControls(isEnded, permissionBlocked),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Default sub-widgets
  // ---------------------------------------------------------------------------

  Widget _buildAudioCallBody({Key? key}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            const Color(0xFF05070D),
            const Color(0xFF0D1019),
            const Color(0xFF141A23),
          ],
        ),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Opacity(
              opacity: 0.08,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topRight,
                    radius: 1.2,
                    colors: <Color>[
                      Colors.white.withValues(alpha: 0.24),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _cfg.avatarBuilder?.call(context, _ctrl) ?? _buildDefaultAvatar(),
                  if (_cfg.showMeetingIdDebug) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _ctrl.meetingId,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white30, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoCallBody({Key? key}) {
    final room = _ctrl.liveKit.currentRoom;
    final localTrack = room == null ? null : _firstVideoTrack(room.localParticipant);
    final remoteParticipants = room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];
    final remoteTiles = <_ParticipantVideoTileData>[
      for (final p in remoteParticipants)
        _ParticipantVideoTileData(
          label: p.identity,
          track: _firstVideoTrack(p),
        ),
    ];

    if (remoteTiles.length <= 1) {
      return _buildOneToOneVideoBody(
        key: key,
        remoteTile: remoteTiles.isEmpty ? null : remoteTiles.first,
        localTrack: localTrack,
      );
    }

    return _buildGroupVideoBody(
      key: key,
      remoteTiles: remoteTiles,
      localTrack: localTrack,
    );
  }

  Widget _buildOneToOneVideoBody({
    Key? key,
    required _ParticipantVideoTileData? remoteTile,
    required VideoTrack? localTrack,
  }) {
    final canFlipCamera = _ctrl.status != IsometrikCallStatus.ended &&
        !_ctrl.hasMissingPermissions &&
        _ctrl.isLocalVideoEnabled;

    return Stack(
      key: key,
      children: <Widget>[
        Positioned.fill(
          child: _VideoTile(
            label: remoteTile?.label ?? _ctrl.peerName,
            track: remoteTile?.track,
            placeholder: 'Waiting for remote video…',
            borderRadius: 0,
            showLabelPill: false,
          ),
        ),
        Positioned(
          right: 18,
          bottom: 156,
          width: 122,
          height: 178,
          child: _VideoTile(
            label: 'You',
            track: localTrack,
            placeholder: 'Camera off',
            borderRadius: 16,
            showLabelPill: false,
          ),
        ),
        Positioned(
          right: 25,
          bottom: 278,
          child: _VideoOverlayActionButton(
            icon: Icons.cameraswitch_rounded,
            enabled: canFlipCamera,
            onTap: () => _runAction(_ctrl.flipCamera, label: 'flip_camera_overlay'),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupVideoBody({
    Key? key,
    required List<_ParticipantVideoTileData> remoteTiles,
    required VideoTrack? localTrack,
  }) {
    final tiles = <_ParticipantVideoTileData>[
      ...remoteTiles,
      _ParticipantVideoTileData(label: 'You', track: localTrack),
    ];
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: GridView.builder(
        itemCount: tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.72,
        ),
        itemBuilder: (BuildContext context, int index) {
          final tile = tiles[index];
          return _VideoTile(
            label: tile.label,
            track: tile.track,
            placeholder: 'Video off',
          );
        },
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    // Pulsing ring animation for calling/ringing states.
    final showPulse = _ctrl.status == IsometrikCallStatus.calling ||
        _ctrl.status == IsometrikCallStatus.ringing;

    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (showPulse) _PulsingRing(diameter: 190),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF8B0054),
              border: Border.all(color: Colors.white10, width: 1.2),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.person_rounded,
              size: 86,
              color: Colors.pink.shade200,
            ),
          ),
        ],
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
                          : () => _runAction(
                                () => _ctrl.respondToVideoUpgrade(accept: true),
                                label: 'video_upgrade_accept',
                              ),
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
                          : () => _runAction(
                                () => _ctrl.respondToVideoUpgrade(accept: false),
                                label: 'video_upgrade_decline',
                              ),
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
    return Material(
      color: Colors.black.withValues(alpha: 0.36),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _ctrl.isPublishBusy
            ? null
            : () => _runAction(
                  _ctrl.requestVideoUpgrade,
                  label: 'video_upgrade_request',
                ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.videocam_rounded, color: Colors.white70, size: 18),
              const SizedBox(width: 8),
              Text(
                _ctrl.isPublishBusy ? 'Sending request...' : 'Switch to video call',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionFallbackCard() {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _ctrl.permissionsMessage ?? 'Required call permissions are missing.',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _runAction(
                      _ctrl.retryPermissionFlow,
                      label: 'permission_retry',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    child: const Text('Retry'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _runAction(
                      () async {
                        await _ctrl.openPermissionSettings();
                      },
                      label: 'open_settings',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.orange,
                    ),
                    child: const Text('Open Settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernControls(bool isEnded, bool permissionBlocked) {
    final isDisabled = isEnded || permissionBlocked;
    final canToggleVideo = _ctrl.hasVideo;
    return _CallControlBar(
      items: <_CallControlItem>[
        _CallControlItem(
          icon: canToggleVideo
              ? (_ctrl.isLocalVideoEnabled ? Icons.videocam : Icons.videocam_off)
              : Icons.videocam_outlined,
          isDisabled: isDisabled,
          onTap: isDisabled
              ? null
              : () {
                  if (canToggleVideo) {
                    _runAction(
                      _ctrl.toggleLocalVideo,
                      label: 'toggle_local_video',
                    );
                  } else {
                    _runAction(
                      _ctrl.requestVideoUpgrade,
                      label: 'video_upgrade_request',
                    );
                  }
                },
        ),
        _CallControlItem(
          icon: _ctrl.isSpeaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          isActive: _ctrl.isSpeaker,
          isDisabled: isDisabled,
          onTap: isDisabled
              ? null
              : () => _runAction(_ctrl.toggleSpeaker, label: 'toggle_speaker'),
        ),
        _CallControlItem(
          icon: _ctrl.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          isActive: _ctrl.isMuted,
          isDisabled: isDisabled,
          onTap:
              isDisabled ? null : () => _runAction(_ctrl.toggleMute, label: 'toggle_mute'),
        ),
        _CallControlItem(
          icon: Icons.call_end_rounded,
          isDanger: true,
          isDisabled: isEnded,
          onTap: isEnded ? null : () => _runAction(_ctrl.endCall, label: 'end_call'),
        ),
      ],
    );
  }

  VideoTrack? _firstVideoTrack(Participant? participant) {
    if (participant == null) return null;
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track is VideoTrack) return track;
    }
    return null;
  }

  Widget _buildTopSection({required bool showVideoLayout}) {
    final subtitleText = _topSubtitle(showVideoLayout: showVideoLayout);
    final chipText = _statusChipText(showVideoLayout: showVideoLayout);
    return Column(
      children: <Widget>[
        const SizedBox(height: 10),
        Text(
          _ctrl.peerName,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        if (subtitleText.isNotEmpty)
          Text(
            subtitleText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w400,
            ),
          )
        else
          const SizedBox(height: 22),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: chipText.isEmpty
              ? const SizedBox(height: 30, key: ValueKey('empty_status'))
              : Padding(
                  key: const ValueKey('status_chip'),
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      chipText,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
        ),
        if (showVideoLayout) const SizedBox(height: 4),
      ],
    );
  }

  String _durationLine() {
    if (_ctrl.status == IsometrikCallStatus.connected) {
      return _ctrl.statusText;
    }
    return '';
  }

  String _statusChipText({required bool showVideoLayout}) {
    if (!showVideoLayout) return '';
    if (_ctrl.status == IsometrikCallStatus.connected && _ctrl.isMuted) {
      return 'You are muted';
    }
    return '';
  }

  String _topSubtitle({required bool showVideoLayout}) {
    if (_ctrl.status == IsometrikCallStatus.connected) return _durationLine();
    if (!showVideoLayout) return _statusLineForAudio();
    return '';
  }

  String _statusLineForAudio() {
    return switch (_ctrl.status) {
      IsometrikCallStatus.calling => 'Calling...',
      IsometrikCallStatus.ringing => 'Ringing...',
      IsometrikCallStatus.connecting => 'Connecting...',
      IsometrikCallStatus.connected => _ctrl.statusText,
      IsometrikCallStatus.ended => 'Call ended',
    };
  }
}

// -----------------------------------------------------------------------------
// Private helper widgets
// -----------------------------------------------------------------------------

class _ParticipantVideoTileData {
  const _ParticipantVideoTileData({
    required this.label,
    required this.track,
  });

  final String label;
  final VideoTrack? track;
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.label,
    required this.track,
    required this.placeholder,
    this.borderRadius = 14,
    this.showLabelPill = true,
  });

  final String label;
  final VideoTrack? track;
  final String placeholder;
  final double borderRadius;
  final bool showLabelPill;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(color: Colors.white10),
          if (track != null)
            VideoTrackRenderer(
              track!,
              fit: VideoViewFit.cover,
            )
          else
            Center(
              child: Text(
                placeholder,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          if (showLabelPill)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IsometrikMinimizedCallOverlay {
  static final Map<String, _OverlayHandle> _handles = <String, _OverlayHandle>{};
  static final Set<String> _restoringMeetingIds = <String>{};

  static void show({
    required BuildContext context,
    required IsometrikCallController controller,
    required IsometrikCallPageConfig config,
  }) {
    if (_handles.containsKey(controller.meetingId)) return;
    if (controller.status == IsometrikCallStatus.ended) return;
    final overlay = Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
        Navigator.maybeOf(context)?.overlay;
    if (overlay == null) return;
    final offset = ValueNotifier<Offset>(controller.minimizedWindowOffset);
    var isEntryActive = true;

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (BuildContext overlayContext) {
        final mediaSize = MediaQuery.sizeOf(overlayContext);
        return ValueListenableBuilder<Offset>(
          valueListenable: offset,
          builder: (BuildContext context, Offset pos, Widget? child) {
            final constrained = _constrainOffset(
              pos,
              mediaSize,
              const Size(170, 220),
            );
            return Positioned(
              left: constrained.dx,
              top: constrained.dy,
              child: GestureDetector(
                onPanUpdate: (DragUpdateDetails details) {
                  if (!isEntryActive) return;
                  final next = _constrainOffset(
                    offset.value + details.delta,
                    mediaSize,
                    const Size(170, 220),
                  );
                  controller.setMinimizedWindowOffset(next);
                  offset.value = next;
                },
                onTap: () {
                  if (_restoringMeetingIds.contains(controller.meetingId)) return;
                  _restoringMeetingIds.add(controller.meetingId);
                  final restoreOffset = offset.value;
                  controller.setMinimizedWindowOffset(restoreOffset);
                  dismiss(controller.meetingId);
                  if (!_IsometrikCallViewRegistry.isVisible(controller.meetingId) &&
                      controller.status != IsometrikCallStatus.ended) {
                    controller.setMinimized(false);
                    IsometrikCallPage.show(
                      context,
                      controller: controller,
                      config: config,
                      animateFromMinimized: true,
                      minimizedOffset: restoreOffset,
                    ).whenComplete(() {
                      _restoringMeetingIds.remove(controller.meetingId);
                    });
                  } else {
                    _restoringMeetingIds.remove(controller.meetingId);
                  }
                },
                child: Material(
                  color: Colors.transparent,
                  child: _MinimizedCallWindow(controller: controller),
                ),
              ),
            );
          },
        );
      },
    );

    void onControllerChanged() {
      if (controller.status == IsometrikCallStatus.ended) {
        dismiss(controller.meetingId);
        config.onCallEnded?.call();
      }
    }

    controller.addListener(onControllerChanged);
    overlay.insert(entry);
    _handles[controller.meetingId] = _OverlayHandle(
      entry: entry,
      listener: onControllerChanged,
      controller: controller,
      offset: offset,
      deactivateEntry: () {
        isEntryActive = false;
      },
    );
  }

  static void dismiss(String meetingId) {
    final handle = _handles.remove(meetingId);
    if (handle == null) return;
    handle.deactivateEntry();
    handle.controller.removeListener(handle.listener);
    // Do not dispose immediately; pending gesture callbacks can still arrive
    // for this frame and would otherwise crash with "used after disposed".
    Future<void>.microtask(handle.offset.dispose);
    handle.entry.remove();
  }

  static Offset _constrainOffset(Offset value, Size canvas, Size box) {
    final dx = value.dx.clamp(8.0, (canvas.width - box.width - 8).clamp(8.0, canvas.width));
    final dy = value.dy.clamp(40.0, (canvas.height - box.height - 8).clamp(40.0, canvas.height));
    return Offset(dx.toDouble(), dy.toDouble());
  }
}

class _OverlayHandle {
  _OverlayHandle({
    required this.entry,
    required this.listener,
    required this.controller,
    required this.offset,
    required this.deactivateEntry,
  });

  final OverlayEntry entry;
  final VoidCallback listener;
  final IsometrikCallController controller;
  final ValueNotifier<Offset> offset;
  final VoidCallback deactivateEntry;
}

class _IsometrikCallViewRegistry {
  static final Set<String> _visibleMeetingIds = <String>{};

  static void markVisible(String meetingId) => _visibleMeetingIds.add(meetingId);

  static void markHidden(String meetingId) => _visibleMeetingIds.remove(meetingId);

  static bool isVisible(String meetingId) => _visibleMeetingIds.contains(meetingId);
}

class _MinimizedCallWindow extends StatelessWidget {
  const _MinimizedCallWindow({required this.controller});

  final IsometrikCallController controller;

  @override
  Widget build(BuildContext context) {
    final room = controller.liveKit.currentRoom;
    final localTrack = room == null
        ? null
        : _firstParticipantTrack(room.localParticipant?.videoTrackPublications);
    final remoteParticipants = room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];
    final remote = remoteParticipants.isEmpty ? null : remoteParticipants.first;
    final remoteTrack = remote == null
        ? null
        : _firstParticipantTrack(remote.videoTrackPublications);

    return Container(
      width: 170,
      height: 220,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: controller.hasVideo
            ? Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: _VideoTile(
                      label: remote?.identity ?? controller.peerName,
                      track: remoteTrack,
                      placeholder: 'Video off',
                    ),
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    width: 54,
                    height: 84,
                    child: _VideoTile(
                      label: 'You',
                      track: localTrack,
                      placeholder: '',
                    ),
                  ),
                ],
              )
            : Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.call, color: Colors.white70, size: 28),
                    const SizedBox(height: 8),
                    Text(
                      controller.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      controller.statusText,
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  static VideoTrack? _firstParticipantTrack(
    Iterable<TrackPublication<Track>>? publications,
  ) {
    if (publications == null) return null;
    for (final publication in publications) {
      final track = publication.track;
      if (track is VideoTrack) return track;
    }
    return null;
  }
}

class _CallControlBar extends StatelessWidget {
  const _CallControlBar({required this.items});

  final List<_CallControlItem> items;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: items.map((item) => _ControlIconButton(item: item)).toList(),
        ),
      ),
    );
  }
}

class _CallControlItem {
  const _CallControlItem({
    required this.icon,
    this.onTap,
    this.isActive = false,
    this.isDanger = false,
    this.isDisabled = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool isActive;
  final bool isDanger;
  final bool isDisabled;
}

class _ControlIconButton extends StatelessWidget {
  const _ControlIconButton({required this.item});

  final _CallControlItem item;

  @override
  Widget build(BuildContext context) {
    final bgColor = item.isDanger
        ? Colors.red
        : item.isActive
            ? Colors.white
            : Colors.white.withValues(alpha: 0.18);
    final iconColor = item.isDanger
        ? Colors.white
        : item.isActive
            ? Colors.black
            : Colors.white;

    return Material(
      color: item.isDisabled ? bgColor.withValues(alpha: 0.35) : bgColor,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: item.isDisabled ? null : item.onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Icon(item.icon, color: iconColor, size: 24),
        ),
      ),
    );
  }
}

class _TopOverlayIconButton extends StatelessWidget {
  const _TopOverlayIconButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.38),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Icon(icon, color: Colors.white70, size: 19),
        ),
      ),
    );
  }
}

class _VideoOverlayActionButton extends StatelessWidget {
  const _VideoOverlayActionButton({
    required this.icon,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled
          ? Colors.black.withValues(alpha: 0.5)
          : Colors.black.withValues(alpha: 0.26),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(
            icon,
            color: enabled ? Colors.white : Colors.white54,
            size: 20,
          ),
        ),
      ),
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
