import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../models/models.dart';
import 'isometrik_call_controller.dart';

const Size _kMinimizedWindowSize = Size(124, 176);

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
    this.canRevealIncomingBlur,
    this.unblurButtonText = 'Unblur',
    this.unblurButtonBackgroundColor,
    this.unblurButtonForegroundColor,
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

  /// Gate for the in-call blur reveal action.
  ///
  /// Return `true` for subscribed/allowed users; return `false` to keep blur.
  /// If omitted, reveal is allowed.
  final bool Function(IsometrikCallController ctrl)? canRevealIncomingBlur;

  /// Label for the blur reveal button.
  final String unblurButtonText;

  /// Optional background color for the unblur button.
  final Color? unblurButtonBackgroundColor;

  /// Optional foreground color for the unblur button text/icon.
  final Color? unblurButtonForegroundColor;
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
    bool useRootNavigator = true,
  }) {
    return Navigator.of(context, rootNavigator: useRootNavigator).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, __, ___) =>
            IsometrikCallPage(controller: controller, config: config),
        transitionsBuilder:
            (
              BuildContext routeContext,
              Animation<double> animation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              final viewport = MediaQuery.sizeOf(routeContext);
              final fullRect = Offset.zero & viewport;
              final pipOffset =
                  minimizedOffset ?? controller.minimizedWindowOffset;
              final pipRect = Rect.fromLTWH(
                pipOffset.dx,
                pipOffset.dy,
                _kMinimizedWindowSize.width,
                _kMinimizedWindowSize.height,
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
              final toRect = isReversing && controller.isMinimized
                  ? pipRect
                  : fullRect;
              final rect =
                  Rect.lerp(fromRect, toRect, curved.value) ?? fullRect;
              final rounded =
                  (animateFromMinimized && !isReversing) ||
                  (isReversing && controller.isMinimized);
              final radius = BorderRadius.circular(
                rounded ? 14 * (1 - curved.value) : 0,
              );

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
  bool _showLocalInFullscreen = false;
  Offset? _pipOffset;
  bool _isDraggingPip = false;
  Size? _lastPipCanvasSize;
  _PipCorner _pipCorner = _PipCorner.bottomRight;
  bool _incomingBlurRevealed = false;

  static const Size _pipSize = Size(122, 178);
  static const EdgeInsets _pipEdgePadding = EdgeInsets.fromLTRB(
    18,
    96,
    18,
    156,
  );

  IsometrikCallController get _ctrl => widget.controller;
  IsometrikCallPageConfig get _cfg => widget.config;
  bool get _isIncomingBlurEnabled => _ctrl.shouldBlurIncomingCallByDefault;
  bool get _showIncomingBlur =>
      _isIncomingBlurEnabled && !_incomingBlurRevealed;
  bool get _canRevealIncomingBlur =>
      _cfg.canRevealIncomingBlur?.call(_ctrl) ?? true;

  VideoTrack? _localPreviewTrack;

  Future<void> initLocalCamera() async {
    final track = await LocalVideoTrack.createCameraTrack();
    _localPreviewTrack = track;
    setState(() {});
  }

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
    initLocalCamera();
  }

  @override
  void didUpdateWidget(covariant IsometrikCallPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.meetingId != widget.controller.meetingId) {
      _incomingBlurRevealed = false;
    }
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

  void _swapVideoTiles() {
    setState(() {
      _showLocalInFullscreen = !_showLocalInFullscreen;
    });
  }

  Rect _pipBounds(Size canvasSize) {
    final left = _pipEdgePadding.left;
    final top = _pipEdgePadding.top;
    final right = math.max(
      left,
      canvasSize.width - _pipSize.width - _pipEdgePadding.right,
    );
    final bottom = math.max(
      top,
      canvasSize.height - _pipSize.height - _pipEdgePadding.bottom,
    );
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset _clampPipOffset(Offset offset, Size canvasSize) {
    final bounds = _pipBounds(canvasSize);
    return Offset(
      offset.dx.clamp(bounds.left, bounds.right).toDouble(),
      offset.dy.clamp(bounds.top, bounds.bottom).toDouble(),
    );
  }

  Offset _snapToNearestCorner(Offset current, Size canvasSize) {
    final bounds = _pipBounds(canvasSize);
    final corners = <Offset>[
      Offset(bounds.left, bounds.top),
      Offset(bounds.right, bounds.top),
      Offset(bounds.left, bounds.bottom),
      Offset(bounds.right, bounds.bottom),
    ];
    var nearest = corners.first;
    var bestDistance = double.infinity;
    for (final corner in corners) {
      final dx = current.dx - corner.dx;
      final dy = current.dy - corner.dy;
      final dist = dx * dx + dy * dy;
      if (dist < bestDistance) {
        bestDistance = dist;
        nearest = corner;
      }
    }
    return nearest;
  }

  _PipCorner _cornerForOffset(Offset current, Size canvasSize) {
    final bounds = _pipBounds(canvasSize);
    final corners = <(_PipCorner, Offset)>[
      (_PipCorner.topLeft, Offset(bounds.left, bounds.top)),
      (_PipCorner.topRight, Offset(bounds.right, bounds.top)),
      (_PipCorner.bottomLeft, Offset(bounds.left, bounds.bottom)),
      (_PipCorner.bottomRight, Offset(bounds.right, bounds.bottom)),
    ];
    var nearest = corners.first.$1;
    var bestDistance = double.infinity;
    for (final corner in corners) {
      final dx = current.dx - corner.$2.dx;
      final dy = current.dy - corner.$2.dy;
      final dist = dx * dx + dy * dy;
      if (dist < bestDistance) {
        bestDistance = dist;
        nearest = corner.$1;
      }
    }
    return nearest;
  }

  Offset _offsetForCorner(_PipCorner corner, Size canvasSize) {
    final bounds = _pipBounds(canvasSize);
    return switch (corner) {
      _PipCorner.topLeft => Offset(bounds.left, bounds.top),
      _PipCorner.topRight => Offset(bounds.right, bounds.top),
      _PipCorner.bottomLeft => Offset(bounds.left, bounds.bottom),
      _PipCorner.bottomRight => Offset(bounds.right, bounds.bottom),
    };
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
    final showVideoLayout = _ctrl.hasVideo;
    // && _ctrl.hasAnyVideoStreaming;
    final mediaPadding = MediaQuery.paddingOf(context);
    final topInset = mediaPadding.top;
    final bottomInset = mediaPadding.bottom;

    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
        backgroundColor: _cfg.backgroundColor,
        body: Stack(
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
            if (_showIncomingBlur && _ctrl.hasVideo)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.24),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: topInset + 12,
              left: 12,
              right: 12,
              child: _buildTopSection(showVideoLayout: showVideoLayout),
            ),
            Positioned(
              top: topInset + 14,
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
              Positioned.fill(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildVideoUpgradeBanner(videoReq),
                  ),
                ),
              ),
            // if (_cfg.showVideoUpgradeButton &&
            //     !_ctrl.hasVideo &&
            //     _ctrl.status == IsometrikCallStatus.connected &&
            //     videoReq == null &&
            //     !permissionBlocked)
            //   Positioned(
            //     left: 24,
            //     right: 24,
            //     bottom: 138,
            //     child: _buildVideoUpgradeRequestButton(),
            //   ),
            Positioned(
              left: 12,
              right: 12,
              bottom: bottomInset + 28,
              child:
                  _cfg.controlsBuilder?.call(context, _ctrl) ??
                  _buildModernControls(isEnded, permissionBlocked),
            ),
            if (_showIncomingBlur && _ctrl.hasVideo)
              Positioned(
                left: 12,
                right: 12,
                bottom: bottomInset + 128,
                child: Center(
                  child: FilledButton.icon(
                    onPressed: () {
                      if (!_canRevealIncomingBlur) {
                        return;
                      }
                      setState(() {
                        _incomingBlurRevealed = true;
                      });
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: _cfg.unblurButtonBackgroundColor,
                      foregroundColor: _cfg.unblurButtonForegroundColor,
                    ),
                    icon: const Icon(Icons.visibility_rounded),
                    label: Text(_cfg.unblurButtonText),
                  ),
                ),
              ),
          ],
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
                  _cfg.avatarBuilder?.call(context, _ctrl) ??
                      _buildDefaultAvatar(),
                  // if (_cfg.showMeetingIdDebug) ...<Widget>[
                  //   const SizedBox(height: 14),
                  //   Text(
                  //     _ctrl.meetingId,
                  //     textAlign: TextAlign.center,
                  //     style: const TextStyle(color: Colors.white30, fontSize: 11),
                  //   ),
                  // ],
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
    final localTrack = room == null
        ? _localPreviewTrack
        : _firstVideoTrack(room.localParticipant);
    final remoteParticipants =
        room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];
    final remoteTiles = <_ParticipantVideoTileData>[
      for (final p in remoteParticipants)
        _ParticipantVideoTileData(
          label: p.identity,
          track: _firstVideoTrack(p),
        ),
    ];

    if (remoteTiles.isEmpty && _ctrl.status != IsometrikCallStatus.connected) {
      return _buildCallingUI(localTrack);
    }
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

  Widget _buildCallingUI(VideoTrack? localTrack) {
    return Stack(
      fit: StackFit.expand, // ← ensures Stack fills its parent
      children: [
        //  Use VideoViewFit.cover directly — no FittedBox wrapper needed
        Positioned.fill(
          child: localTrack != null
              ? VideoTrackRenderer(localTrack, fit: VideoViewFit.cover)
              : Container(color: Colors.black),
        ),

        /// 🌫 Overlay
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.4),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.5),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOneToOneVideoBody({
    Key? key,
    required _ParticipantVideoTileData? remoteTile,
    required VideoTrack? localTrack,
  }) {
    final canFlipCamera =
        _ctrl.status != IsometrikCallStatus.ended &&
        !_ctrl.hasMissingPermissions &&
        _ctrl.isLocalVideoEnabled;
    final showLocalInFullscreen = _showLocalInFullscreen;
    final fullScreenLabel = showLocalInFullscreen
        ? 'You'
        : (remoteTile?.label ?? _ctrl.peerName);
    final fullScreenTrack = showLocalInFullscreen
        ? localTrack
        : remoteTile?.track;
    final fullScreenPlaceholder = showLocalInFullscreen
        ? 'Camera off'
        : 'Waiting for remote video…';
    final pipLabel = showLocalInFullscreen
        ? (remoteTile?.label ?? _ctrl.peerName)
        : 'You';
    final pipTrack = showLocalInFullscreen ? remoteTile?.track : localTrack;
    final pipPlaceholder = showLocalInFullscreen
        ? 'Waiting for remote video…'
        : 'Camera off';

    return LayoutBuilder(
      key: key,
      builder: (BuildContext context, BoxConstraints constraints) {
        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        final lastSize = _lastPipCanvasSize;
        final shouldReanchorFromCorner =
            !_isDraggingPip &&
            lastSize != null &&
            ((lastSize.width - canvasSize.width).abs() > 0.5 ||
                (lastSize.height - canvasSize.height).abs() > 0.5);
        final rawPipOffset = shouldReanchorFromCorner
            ? _offsetForCorner(_pipCorner, canvasSize)
            : (_pipOffset ?? _offsetForCorner(_pipCorner, canvasSize));
        final pipOffset = _clampPipOffset(rawPipOffset, canvasSize);
        if (_pipOffset == null ||
            pipOffset != rawPipOffset ||
            _lastPipCanvasSize != canvasSize) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _pipOffset = pipOffset;
              _lastPipCanvasSize = canvasSize;
            });
          });
        }

        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: _VideoTile(
                label: fullScreenLabel,
                track: fullScreenTrack,
                placeholder: fullScreenPlaceholder,
                borderRadius: 0,
                showLabelPill: false,
                ignoreVideoGestures: true,
              ),
            ),
            AnimatedPositioned(
              duration: _isDraggingPip
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              left: pipOffset.dx,
              top: pipOffset.dy,
              width: _pipSize.width,
              height: _pipSize.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _swapVideoTiles,
                onPanStart: (_) {
                  setState(() {
                    _isDraggingPip = true;
                  });
                },
                onPanUpdate: (DragUpdateDetails details) {
                  setState(() {
                    final current = _pipOffset ?? pipOffset;
                    _pipOffset = _clampPipOffset(
                      current + details.delta,
                      canvasSize,
                    );
                  });
                },
                onPanEnd: (_) {
                  setState(() {
                    _isDraggingPip = false;
                    final current = _pipOffset ?? pipOffset;
                    final snapped = _snapToNearestCorner(current, canvasSize);
                    _pipOffset = snapped;
                    _pipCorner = _cornerForOffset(snapped, canvasSize);
                  });
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _VideoTile(
                      label: pipLabel,
                      track: pipTrack,
                      placeholder: pipPlaceholder,
                      borderRadius: 16,
                      showLabelPill: false,
                      ignoreVideoGestures: true,
                    ),
                    if (!showLocalInFullscreen)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _VideoOverlayActionButton(
                          icon: Icons.cameraswitch_rounded,
                          enabled: canFlipCamera,
                          onTap: () => _runAction(
                            _ctrl.flipCamera,
                            label: 'flip_camera_overlay',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (showLocalInFullscreen)
              Positioned(
                top: 86,
                right: 20,
                child: _VideoOverlayActionButton(
                  icon: Icons.cameraswitch_rounded,
                  enabled: canFlipCamera,
                  onTap: () => _runAction(
                    _ctrl.flipCamera,
                    label: 'flip_camera_overlay',
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildGroupVideoBody({
    Key? key,
    required List<_ParticipantVideoTileData> remoteTiles,
    required VideoTrack? localTrack,
  }) {
    final canFlipCamera =
        _ctrl.status != IsometrikCallStatus.ended &&
        !_ctrl.hasMissingPermissions &&
        _ctrl.isLocalVideoEnabled;
    final tiles = <_ParticipantVideoTileData>[
      ...remoteTiles,
      _ParticipantVideoTileData(label: '', track: localTrack),
    ];
    return LayoutBuilder(
      key: key,
      builder: (BuildContext context, BoxConstraints constraints) {
        final participantCount = tiles.length;
        final spacing = 6.0;
        const tileRadius = 10.0;
        Widget buildParticipantTile(int index) {
          final tile = tiles[index];
          final isLocalTile = index == tiles.length - 1;
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(tileRadius),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(tileRadius),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _VideoTile(
                    label: tile.label,
                    track: tile.track,
                    placeholder: 'Video off',
                    borderRadius: tileRadius,
                    // WhatsApp-like group layout: no name pill overlays on tiles.
                    showLabelPill: false,
                  ),
                  if (isLocalTile)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _VideoOverlayActionButton(
                        icon: Icons.cameraswitch_rounded,
                        enabled: canFlipCamera,
                        onTap: () => _runAction(
                          _ctrl.flipCamera,
                          label: 'flip_camera_overlay_group',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }

        if (participantCount == 1) {
          return buildParticipantTile(0);
        }

        if (participantCount == 2) {
          return Column(
            children: <Widget>[
              Expanded(child: buildParticipantTile(0)),
              SizedBox(height: spacing),
              Expanded(child: buildParticipantTile(1)),
            ],
          );
        }

        if (participantCount == 3) {
          return Column(
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(child: buildParticipantTile(0)),
                    SizedBox(width: spacing),
                    Expanded(child: buildParticipantTile(1)),
                  ],
                ),
              ),
              SizedBox(height: spacing),
              Expanded(child: buildParticipantTile(2)),
            ],
          );
        }

        if (participantCount == 4) {
          return Column(
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(child: buildParticipantTile(0)),
                    SizedBox(width: spacing),
                    Expanded(child: buildParticipantTile(1)),
                  ],
                ),
              ),
              SizedBox(height: spacing),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Expanded(child: buildParticipantTile(2)),
                    SizedBox(width: spacing),
                    Expanded(child: buildParticipantTile(3)),
                  ],
                ),
              ),
            ],
          );
        }

        return GridView.builder(
          itemCount: tiles.length,
          physics: const BouncingScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            // Keep WhatsApp-like group grid with two columns for all larger rooms.
            crossAxisCount: 2,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: 0.82,
          ),
          itemBuilder: (BuildContext context, int index) =>
              buildParticipantTile(index),
        );
      },
    );
  }

  Widget _buildDefaultAvatar() {
    // Pulsing ring animation for calling/ringing states.
    final showPulse =
        _ctrl.status == IsometrikCallStatus.calling ||
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
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 300,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${meeting.senderName ?? 'Peer'} wants to switch to video',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black87, fontSize: 15),
              ),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _ctrl.isPublishBusy
                        ? null
                        : () => _runAction(
                            () => _ctrl.respondToVideoUpgrade(accept: false),
                            label: 'video_upgrade_decline',
                          ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: Colors.green),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _ctrl.isPublishBusy
                        ? null
                        : () => _runAction(
                            () => _ctrl.respondToVideoUpgrade(accept: true),
                            label: 'video_upgrade_accept',
                          ),
                    child: const Text(
                      'Switch',
                      style: TextStyle(color: Colors.green),
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

  // Widget _buildVideoUpgradeRequestButton() {
  //   return Material(
  //     color: Colors.black.withValues(alpha: 0.36),
  //     borderRadius: BorderRadius.circular(20),
  //     child: InkWell(
  //       borderRadius: BorderRadius.circular(20),
  //       onTap: _ctrl.isPublishBusy
  //           ? null
  //           : () => _runAction(
  //                 _ctrl.requestVideoUpgrade,
  //                 label: 'video_upgrade_request',
  //               ),
  //       child: Padding(
  //         padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  //         child: Row(
  //           mainAxisSize: MainAxisSize.min,
  //           mainAxisAlignment: MainAxisAlignment.center,
  //           children: <Widget>[
  //             const Icon(Icons.videocam_rounded, color: Colors.white70, size: 18),
  //             const SizedBox(width: 8),
  //             Text(
  //               _ctrl.isPublishBusy ? 'Sending request...' : 'Switch to video call',
  //               style: const TextStyle(color: Colors.white70, fontSize: 13),
  //             ),
  //           ],
  //         ),
  //       ),
  //     ),
  //   );
  // }

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
              _ctrl.permissionsMessage ??
                  'Required call permissions are missing.',
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
                    onPressed: () => _runAction(() async {
                      await _ctrl.openPermissionSettings();
                    }, label: 'open_settings'),
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
              ? (_ctrl.isLocalVideoEnabled
                    ? Icons.videocam
                    : Icons.videocam_off)
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
          icon: _ctrl.isSpeaker
              ? Icons.volume_up_rounded
              : Icons.volume_down_rounded,
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
          onTap: isDisabled
              ? null
              : () => _runAction(_ctrl.toggleMute, label: 'toggle_mute'),
        ),
        _CallControlItem(
          icon: Icons.call_end_rounded,
          isDanger: true,
          isDisabled: isEnded,
          onTap: isEnded
              ? null
              : () => _runAction(_ctrl.endCall, label: 'end_call'),
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

    // ── Build participant name line for group calls ──────────────────────────
    final room = _ctrl.liveKit.currentRoom;
    final remoteParticipants = room?.remoteParticipants.values.toList() ?? [];
    final isGroupCall = remoteParticipants.length > 1;

    // Collect names: show up to 3, then "+N more"
    String headerName;
    if (isGroupCall) {
      final names = remoteParticipants
          .map((p) => p.identity.isNotEmpty ? p.identity : 'Unknown')
          .toList();
      if (names.length <= 3) {
        headerName = names.join(', ');
      } else {
        final visible = names.take(3).join(', ');
        headerName = '$visible +${names.length - 3} more';
      }
    } else {
      headerName = _ctrl.peerName;
    }
    headerName = headerName.length > 26
        ? '${headerName.substring(0, 26)}…'
        : headerName;
    // ─────────────────────────────────────────────────────────────────────────

    return Column(
      children: <Widget>[
        const SizedBox(height: 10),
        Text(
          headerName,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
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
    //  Keep existing connected behavior
    if (_ctrl.status == IsometrikCallStatus.connected) {
      return _durationLine();
    }

    //  For audio calls → keep existing logic
    if (!showVideoLayout) {
      return _statusLineForAudio();
    }

    //  NEW: Handle video call states (this was missing)
    return switch (_ctrl.status) {
      IsometrikCallStatus.calling => 'Calling...',
      IsometrikCallStatus.ringing => 'Ringing...',
      IsometrikCallStatus.connecting => 'Connecting...',
      IsometrikCallStatus.ended => 'Call ended',
      IsometrikCallStatus.connected => '', // already handled above
    };
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
  const _ParticipantVideoTileData({required this.label, required this.track});

  final String label;
  final VideoTrack? track;
}

enum _PipCorner { topLeft, topRight, bottomLeft, bottomRight }

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.label,
    required this.track,
    required this.placeholder,
    this.borderRadius = 14,
    this.showLabelPill = true,
    this.ignoreVideoGestures = false,
  });

  final String label;
  final VideoTrack? track;
  final String placeholder;
  final double borderRadius;
  final bool showLabelPill;
  final bool ignoreVideoGestures;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Container(color: Colors.white10),
          if (track != null)
            IgnorePointer(
              // Prevent internal renderer from handling tap gestures
              // (some flutter_webrtc versions use taps for focus/exposure).
              ignoring: ignoreVideoGestures,
              child: VideoTrackRenderer(track!, fit: VideoViewFit.cover),
            )
          else
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  placeholder,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
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
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _IsometrikMinimizedCallOverlay {
  static final Map<String, _OverlayHandle> _handles =
      <String, _OverlayHandle>{};
  static final Set<String> _restoringMeetingIds = <String>{};

  static void show({
    required BuildContext context,
    required IsometrikCallController controller,
    required IsometrikCallPageConfig config,
  }) {
    if (_handles.containsKey(controller.meetingId)) return;
    if (controller.status == IsometrikCallStatus.ended) return;
    final overlay =
        Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
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
              _kMinimizedWindowSize,
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
                    _kMinimizedWindowSize,
                  );
                  controller.setMinimizedWindowOffset(next);
                  offset.value = next;
                },
                onPanEnd: (_) {
                  if (!isEntryActive) return;
                  final snapped = _snapToNearestSide(
                    offset.value,
                    mediaSize,
                    _kMinimizedWindowSize,
                  );
                  controller.setMinimizedWindowOffset(snapped);
                  offset.value = snapped;
                },
                onTap: () {
                  if (_restoringMeetingIds.contains(controller.meetingId))
                    return;
                  _restoringMeetingIds.add(controller.meetingId);
                  final restoreOffset = offset.value;
                  controller.setMinimizedWindowOffset(restoreOffset);
                  dismiss(controller.meetingId);
                  if (!_IsometrikCallViewRegistry.isVisible(
                        controller.meetingId,
                      ) &&
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
    final dx = value.dx.clamp(
      8.0,
      (canvas.width - box.width - 8).clamp(8.0, canvas.width),
    );
    final dy = value.dy.clamp(
      40.0,
      (canvas.height - box.height - 8).clamp(40.0, canvas.height),
    );
    return Offset(dx.toDouble(), dy.toDouble());
  }

  static Offset _snapToNearestSide(Offset value, Size canvas, Size box) {
    final constrained = _constrainOffset(value, canvas, box);
    const left = 8.0;
    final right = (canvas.width - box.width - 8)
        .clamp(8.0, canvas.width)
        .toDouble();
    final leftDistance = (constrained.dx - left).abs();
    final rightDistance = (right - constrained.dx).abs();
    final dx = leftDistance <= rightDistance ? left : right;
    return Offset(dx, constrained.dy);
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

  static void markVisible(String meetingId) =>
      _visibleMeetingIds.add(meetingId);

  static void markHidden(String meetingId) =>
      _visibleMeetingIds.remove(meetingId);

  static bool isVisible(String meetingId) =>
      _visibleMeetingIds.contains(meetingId);
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
    final selfInitial = _resolveSelfInitial(room?.localParticipant);
    final remoteParticipants =
        room?.remoteParticipants.values.toList() ?? <RemoteParticipant>[];
    final primaryRemoteTrack = remoteParticipants.isEmpty
        ? null
        : _firstParticipantTrack(
            remoteParticipants.first.videoTrackPublications,
          );
    final remoteNames = <String>[
      for (var i = 0; i < remoteParticipants.length; i++)
        _displayNameForParticipant(remoteParticipants[i], fallbackIndex: i + 1),
    ];
    final remoteCount = remoteNames.length;
    final isOneToOneMini = remoteCount <= 1;

    return Container(
      width: _kMinimizedWindowSize.width,
      height: _kMinimizedWindowSize.height,
      decoration: BoxDecoration(
        color: const Color(0xFF0B0E13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black54,
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: isOneToOneMini ? EdgeInsets.zero : const EdgeInsets.all(6),
          child: switch (remoteCount) {
            0 || 1 => _buildOneToOneLayout(
              remoteName: remoteCount == 0
                  ? controller.peerName
                  : remoteNames.first,
              remoteTrack: primaryRemoteTrack,
              localTrack: localTrack,
              selfInitial: selfInitial,
            ),
            _ => _buildGridRemoteLayout(
              remoteNames,
              localTrack: localTrack,
              selfInitial: selfInitial,
            ),
          },
        ),
      ),
    );
  }

  /// One-to-one minimized view: full remote feed + small self camera overlay.
  Widget _buildOneToOneLayout({
    required String remoteName,
    required VideoTrack? remoteTrack,
    required VideoTrack? localTrack,
    required String selfInitial,
  }) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: remoteTrack != null
                ? VideoTrackRenderer(remoteTrack, fit: VideoViewFit.cover)
                : _MiniProfileTile(name: remoteName, emphasize: true),
          ),
        ),
        Positioned(
          right: 6,
          bottom: 6,
          child: _MiniSelfPreview(
            localTrack: localTrack,
            selfInitial: selfInitial,
          ),
        ),
        Positioned(
          left: 6,
          bottom: 6,
          child: Text(
            controller.statusText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  /// More than two remotes: compact 2-column grid + small self camera preview.
  Widget _buildGridRemoteLayout(
    List<String> remoteNames, {
    required VideoTrack? localTrack,
    required String selfInitial,
  }) {
    final totalRemote = remoteNames.length;
    final visibleCount = math.min(totalRemote, 4);
    final hiddenCount = math.max(0, totalRemote - visibleCount);

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(right: 2, bottom: 2),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleCount,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
                childAspectRatio: 1.06,
              ),
              itemBuilder: (BuildContext context, int index) {
                final isOverflowCell =
                    index == visibleCount - 1 && hiddenCount > 0;
                return _MiniProfileTile(
                  name: remoteNames[index],
                  compact: true,
                  extraCount: isOverflowCell ? hiddenCount : 0,
                );
              },
            ),
          ),
        ),
        Positioned(
          right: 4,
          bottom: 4,
          child: _MiniSelfPreview(
            localTrack: localTrack,
            selfInitial: selfInitial,
          ),
        ),
      ],
    );
  }

  static String _displayNameForParticipant(
    RemoteParticipant participant, {
    required int fallbackIndex,
  }) {
    final dynamic p = participant;
    final rawName = (p.name as String?)?.trim() ?? '';
    final rawMetadata = (p.metadata as String?)?.trim() ?? '';
    final rawIdentity = participant.identity.trim();

    final candidates = <String>[
      _normalizedHumanToken(rawName),
      _nameFromMetadata(rawMetadata),
      _normalizedHumanToken(rawIdentity),
    ];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && !_looksLikeId(candidate)) {
        return candidate;
      }
    }
    return 'User $fallbackIndex';
  }

  static String _nameFromMetadata(String metadataRaw) {
    if (metadataRaw.isEmpty) return '';
    try {
      final decoded = jsonDecode(metadataRaw);
      if (decoded is Map<String, dynamic>) {
        const preferredKeys = <String>[
          'name',
          'userName',
          'username',
          'displayName',
          'memberName',
        ];
        for (final key in preferredKeys) {
          final value = (decoded[key] as String?)?.trim() ?? '';
          final normalized = _normalizedHumanToken(value);
          if (normalized.isNotEmpty && !_looksLikeId(normalized)) {
            return normalized;
          }
        }
      }
    } catch (_) {
      // Ignore malformed participant metadata.
    }
    return '';
  }

  static String _normalizedHumanToken(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';

    if (value.contains('@')) {
      value = value.split('@').first.trim();
    }

    final parts = value
        .split(RegExp(r'[|,:;/\\]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    for (final part in parts) {
      if (!_looksLikeId(part)) return part;
    }
    return value;
  }

  static bool _looksLikeId(String value) {
    final v = value.trim();
    if (v.isEmpty) return true;
    final uuidPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    if (uuidPattern.hasMatch(v)) return true;
    final longIdPattern = RegExp(r'^[a-z0-9_-]{12,}$', caseSensitive: false);
    if (longIdPattern.hasMatch(v)) return true;
    final digitsOnlyPattern = RegExp(r'^\d{8,}$');
    if (digitsOnlyPattern.hasMatch(v)) return true;
    return false;
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

  static String _resolveSelfInitial(LocalParticipant? participant) {
    if (participant == null) return 'U';
    final dynamic p = participant;
    final rawName = (p.name as String?)?.trim() ?? '';
    final rawMetadata = (p.metadata as String?)?.trim() ?? '';
    final rawIdentity = participant.identity.trim();
    final candidates = <String>[
      _normalizedHumanToken(rawName),
      _nameFromMetadata(rawMetadata),
      _normalizedHumanToken(rawIdentity),
    ];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && !_looksLikeId(candidate)) {
        return _MiniProfileTile._initials(candidate);
      }
    }
    return 'U';
  }
}

class _MiniProfileTile extends StatelessWidget {
  const _MiniProfileTile({
    required this.name,
    this.emphasize = false,
    this.extraCount = 0,
    this.compact = false,
  });

  final String name;
  final bool emphasize;
  final int extraCount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final bg = _avatarColor(name);
    final double avatarRadius;
    final double letterSize;
    if (compact) {
      avatarRadius = 10;
      letterSize = 11;
    } else if (emphasize) {
      avatarRadius = 26;
      letterSize = 18;
    } else {
      avatarRadius = 22;
      letterSize = 15;
    }
    final borderRadius = compact ? 8.0 : 10.0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF171C24),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: Colors.white10),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: CircleAvatar(
              radius: avatarRadius,
              backgroundColor: bg,
              child: Text(
                _initials(name),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: letterSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (extraCount > 0)
            compact
                ? Positioned(
                    right: 3,
                    bottom: 3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        '+$extraCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.52),
                        borderRadius: BorderRadius.circular(borderRadius),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '+$extraCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
        ],
      ),
    );
  }

  static String _initials(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    return parts.first[0].toUpperCase();
  }

  static Color _avatarColor(String seed) {
    final colors = <Color>[
      const Color(0xFF5E60CE),
      const Color(0xFF3A86FF),
      const Color(0xFF2A9D8F),
      const Color(0xFFE76F51),
      const Color(0xFFB5179E),
      const Color(0xFF577590),
    ];
    final index = seed.hashCode.abs() % colors.length;
    return colors[index];
  }
}

class _MiniSelfPreview extends StatelessWidget {
  const _MiniSelfPreview({required this.localTrack, required this.selfInitial});

  final VideoTrack? localTrack;
  final String selfInitial;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 50,
      decoration: BoxDecoration(
        color: const Color(0xFF171C24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (localTrack != null)
            VideoTrackRenderer(localTrack!, fit: VideoViewFit.cover)
          else
            Container(
              color: Colors.white10,
              child: Center(
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: Color(0xFFE76F51),
                  child: Text(
                    selfInitial,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
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
          children: items
              .map(
                (item) => Expanded(
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _ControlIconButton(item: item),
                    ),
                  ),
                ),
              )
              .toList(),
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
  const _TopOverlayIconButton({required this.icon, required this.onTap});

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
