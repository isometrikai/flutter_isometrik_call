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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // --- Header ---
              _cfg.headerBuilder?.call(context, _ctrl) ?? _buildDefaultHeader(),

              // --- Permission fallback card ---
              if (permissionBlocked) _buildPermissionFallbackCard(),

              // --- Video upgrade incoming request banner ---
              if (videoReq != null) _buildVideoUpgradeBanner(videoReq),

              Expanded(
                child: showVideoLayout ? _buildVideoCallBody() : _buildAudioCallBody(),
              ),

              // --- Video upgrade request button (audio-only + connected) ---
              if (_cfg.showVideoUpgradeButton &&
                  !_ctrl.hasVideo &&
                  _ctrl.status == IsometrikCallStatus.connected &&
                  videoReq == null &&
                  !permissionBlocked)
                _buildVideoUpgradeRequestButton(),

              // --- Controls ---
              _cfg.controlsBuilder?.call(context, _ctrl) ??
                  _buildDefaultControls(isEnded, permissionBlocked),

              const SizedBox(height: 32),
            ],
          ),
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
            onPressed: () => unawaited(_minimizeCallView()),
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

  Widget _buildAudioCallBody() {
    return Column(
      children: <Widget>[
        const Spacer(),
        _cfg.avatarBuilder?.call(context, _ctrl) ?? _buildDefaultAvatar(),
        const SizedBox(height: 28),
        if (_ctrl.hasVideo && !_ctrl.hasAnyVideoStreaming) ...<Widget>[
          const Text(
            'No video stream right now. Call is continuing in audio mode.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(height: 14),
        ],
        _buildStatusText(),
        const SizedBox(height: 8),
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
      ],
    );
  }

  Widget _buildVideoCallBody() {
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
        remoteTile: remoteTiles.isEmpty ? null : remoteTiles.first,
        localTrack: localTrack,
      );
    }

    return _buildGroupVideoBody(remoteTiles: remoteTiles, localTrack: localTrack);
  }

  Widget _buildOneToOneVideoBody({
    required _ParticipantVideoTileData? remoteTile,
    required VideoTrack? localTrack,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: _VideoTile(
              label: remoteTile?.label ?? _ctrl.peerName,
              track: remoteTile?.track,
              placeholder: 'Waiting for remote video…',
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            width: 110,
            height: 170,
            child: _VideoTile(
              label: 'You',
              track: localTrack,
              placeholder: 'Camera off',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupVideoBody({
    required List<_ParticipantVideoTileData> remoteTiles,
    required VideoTrack? localTrack,
  }) {
    final tiles = <_ParticipantVideoTileData>[
      ...remoteTiles,
      _ParticipantVideoTileData(label: 'You', track: localTrack),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: GridView.builder(
        itemCount: tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
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

  Widget _buildPermissionFallbackCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: Colors.red.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                _ctrl.permissionsMessage ??
                    'Required call permissions are missing.',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _ctrl.retryPermissionFlow,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white30),
                      ),
                      child: const Text('Retry'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _ctrl.openPermissionSettings,
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
      ),
    );
  }

  Widget _buildDefaultControls(bool isEnded, bool permissionBlocked) {
    void safeAction(Future<void> Function() action) {
      unawaited(
        action().catchError((Object error, StackTrace stackTrace) {
          debugPrint('IsometrikCallPage control action failed: $error');
        }),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _CallControlButton(
            icon: _ctrl.isMuted ? Icons.mic_off : Icons.mic,
            label: _ctrl.isMuted ? 'Unmute' : 'Mute',
            isActive: _ctrl.isMuted,
            onTap: (isEnded || permissionBlocked)
                ? null
                : () => safeAction(_ctrl.toggleMute),
          ),
          if (_ctrl.hasVideo)
            _CallControlButton(
              icon: _ctrl.isLocalVideoEnabled ? Icons.videocam : Icons.videocam_off,
              label: _ctrl.isLocalVideoEnabled ? 'Video Off' : 'Video On',
              isActive: !_ctrl.isLocalVideoEnabled,
              onTap: (isEnded || permissionBlocked)
                  ? null
                  : () => safeAction(_ctrl.toggleLocalVideo),
            ),
          if (_ctrl.hasVideo)
            _CallControlButton(
              icon: Icons.cameraswitch,
              label: _ctrl.isFrontCamera ? 'Switch Rear' : 'Switch Front',
              onTap: (isEnded || permissionBlocked || !_ctrl.isLocalVideoEnabled)
                  ? null
                  : () => safeAction(_ctrl.flipCamera),
            ),
          _CallControlButton(
            icon: _ctrl.isSpeaker ? Icons.volume_up : Icons.volume_down,
            label: _ctrl.isSpeaker ? 'Speaker' : 'Earpiece',
            isActive: _ctrl.isSpeaker,
            onTap: (isEnded || permissionBlocked)
                ? null
                : () => safeAction(_ctrl.toggleSpeaker),
          ),
          _CallControlButton(
            icon: Icons.call_end,
            label: 'End',
            backgroundColor: Colors.red,
            onTap: isEnded ? null : () => safeAction(_ctrl.endCall),
          ),
        ],
      ),
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
  });

  final String label;
  final VideoTrack? track;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
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
                      style: const TextStyle(color: Colors.white, fontSize: 14),
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
