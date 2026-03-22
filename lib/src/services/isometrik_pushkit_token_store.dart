/// Mirrors Swift `ISMPushKitToken` — tracks VoIP token sync with backend.
class IsometrikPushKitTokenStore {
  String? newToken;
  String? lastSyncedToken;

  bool needToUpdate() => newToken != null && newToken != lastSyncedToken;

  void markSyncedFromNew() {
    lastSyncedToken = newToken;
  }

  void clear() {
    newToken = null;
    lastSyncedToken = null;
  }
}
