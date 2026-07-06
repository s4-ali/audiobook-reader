package com.audiobook.audiobook_player

import android.os.Build
import android.os.Environment
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// just_audio_background (audio_service) needs the host Activity to be AudioServiceActivity
// so the playback service binds to the same FlutterEngine.
class MainActivity : AudioServiceActivity() {
    private val storageChannel = "com.audiobook.audiobook_player/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Tell Dart the real shared-storage root (/storage/emulated/0) and the OS level, so the
        // library can put books in a persistent, user-visible <root>/Audiobooks folder instead
        // of app-internal storage (which the OS wipes on uninstall). Path-only: no file IO here.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageInfo" -> result.success(
                        mapOf(
                            "externalRoot" to Environment.getExternalStorageDirectory()?.absolutePath,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
