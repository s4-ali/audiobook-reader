/// Format a duration as H:MM:SS (or M:SS when under an hour) — matches the web player.
String fmtClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Round a number of seconds to whole minutes, e.g. "42 min".
String fmtMinutes(double seconds) => '${(seconds / 60).round()} min';
