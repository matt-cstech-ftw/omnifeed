class TikTokLiveClient {
  final String handle;
  TikTokLiveClient(this.handle);
  void on(dynamic eventType, Function(dynamic) callback) {}
  Future<void> connect() async {}
  void disconnect() {}
}

enum EventType {
  connected,
  chat,
  gift,
}

class RoomCheckResult {
  final String? roomId;
  RoomCheckResult(this.roomId);
}

Future<RoomCheckResult> checkOnline(String handle) async {
  return RoomCheckResult(null);
}
