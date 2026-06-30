package com.audiobook.audiobook_player

import com.ryanheise.audioservice.AudioServiceActivity

// just_audio_background (audio_service) needs the host Activity to be AudioServiceActivity
// so the playback service binds to the same FlutterEngine.
class MainActivity : AudioServiceActivity()
