import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Bridges to the persistent, user-visible shared-storage folder where books live, so they
/// survive an app reinstall and show up in any file manager (unlike app-internal storage, which
/// the OS wipes on uninstall).
///
/// Two pieces: the real storage root comes from a tiny native MethodChannel (see
/// `MainActivity.kt`), and the access grant comes from `permission_handler` — "All files access"
/// (`MANAGE_EXTERNAL_STORAGE`) on Android 11+, the legacy storage permission below that.
class StorageAccess {
  static const _channel = MethodChannel('com.audiobook.audiobook_player/storage');

  static String? _externalRoot;
  static int? _sdkInt;
  static bool _loaded = false;

  static Future<void> _loadInfo() async {
    if (_loaded) return;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getStorageInfo');
      _externalRoot = info?['externalRoot'] as String?;
      _sdkInt = (info?['sdkInt'] as num?)?.toInt();
    } catch (_) {
      // Non-Android / channel missing: leave null so the library falls back to app-internal.
    }
    _loaded = true;
  }

  /// OS API level (0 if unknown / not Android).
  static Future<int> sdkInt() async {
    await _loadInfo();
    return _sdkInt ?? 0;
  }

  /// Absolute path of the persistent books folder (`<shared-root>/Audiobooks`), or null when the
  /// shared root can't be resolved (e.g. not Android).
  static Future<String?> audiobooksPath() async {
    await _loadInfo();
    final root = _externalRoot;
    if (root == null || root.isEmpty) return null;
    return '$root/Audiobooks';
  }

  /// The permission that unlocks the shared folder on this OS version.
  static Future<Permission> _permission() async =>
      (await sdkInt()) >= 30 ? Permission.manageExternalStorage : Permission.storage;

  /// Whether we currently hold the access needed to read/write the shared books folder.
  static Future<bool> hasAccess() async => (await _permission()).isGranted;

  /// Request access. On Android 11+ this opens the system "All files access" screen; the caller
  /// should re-check [hasAccess] afterwards (and on app resume). Returns the resulting grant.
  static Future<bool> requestAccess() async {
    final status = await (await _permission()).request();
    return status.isGranted;
  }
}
