import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Time-ordered UUID, safe to generate offline on any device.
String newId() => _uuid.v7();

/// Hybrid logical clock for `updated_at`: wall-clock milliseconds, but
/// never behind anything seen from other devices ([observe]), so a later
/// edit always gets a larger value even if this device's clock is slow.
class Clock {
  int _last = 0;

  int tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _last = now > _last ? now : _last + 1;
    return _last;
  }

  /// Called with each timestamp received from the server.
  void observe(int remote) {
    if (remote > _last) _last = remote;
  }
}

/// The sync server's comparable version string for a row: the server keeps
/// whichever version has the larger string (last writer wins, ties broken
/// by device id).
String hlcOf(int updatedAt, String deviceId) =>
    '${updatedAt.toString().padLeft(13, '0')}.0000.$deviceId';
