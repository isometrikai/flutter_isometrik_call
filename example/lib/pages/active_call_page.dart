/// This file is kept for backward compatibility.
///
/// The active call page has been moved into the SDK as
/// [IsometrikCallPage] + [IsometrikCallController].
///
/// Host apps should import directly from the SDK:
/// ```dart
/// import 'package:isometrik_flutter_call/isometrik_flutter_call.dart';
/// ```
///
/// See [IsometrikCallSdk.startCall] for outgoing calls and
/// [IsometrikCallSdk.enableAutoCallHandling] for incoming calls.
library;

export 'package:isometrik_flutter_call/isometrik_flutter_call.dart'
    show IsometrikCallPage, IsometrikCallPageConfig, IsometrikCallController, IsometrikCallStatus;
