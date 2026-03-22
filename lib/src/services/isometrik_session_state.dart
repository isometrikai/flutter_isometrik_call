import '../configuration/isometrik_call_configuration.dart';

/// Mutable session aligned with Swift `UserDefaults` + `ISMCallConfiguration.userToken` / `userId`.
class IsometrikSessionState {
  IsometrikCallConfiguration? configuration;
  String? userId;
  String? userToken;
  String? deviceId;

  bool get hasSession =>
      userId != null &&
      userToken != null &&
      userId!.isNotEmpty &&
      userToken!.isNotEmpty;

  void updateSession({required String userId, required String userToken}) {
    this.userId = userId;
    this.userToken = userToken;
  }

  void clearSession() {
    userId = null;
    userToken = null;
  }
}
