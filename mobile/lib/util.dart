/// Format a duration as H:MM:SS (or M:SS when under an hour) — matches the web player.
String fmtClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Compact total duration as "1h 53m" (or "45m" under an hour, "2h" on the hour).
String fmtHm(double seconds) {
  final total = (seconds / 60).round();
  final h = total ~/ 60;
  final m = total % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}
