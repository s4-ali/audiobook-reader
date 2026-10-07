package com.audiobook.audiobook_player.narrate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.k2fsa.sherpa.onnx.OfflineTts
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.min

/** What the Narrate panel + notification render. Published on the main thread. */
data class NarrateSnapshot(
    val phase: Phase = Phase.IDLE,
    val index: Int = 0,          // sentence being spoken (0-based)
    val total: Int = 0,
    val sentence: String = "",
    val detail: String = "",     // voice + measured speed, or the error text
    val progress: Float = 0f,    // download progress 0..1
) {
    enum class Phase { IDLE, NEEDS_VOICE, DOWNLOADING, LOADING, PLAYING, PAUSED, DONE, ERROR }

    val active get() = phase == Phase.DOWNLOADING || phase == Phase.LOADING ||
        phase == Phase.PLAYING || phase == Phase.PAUSED
}

/** In-process state hand-off between [NarrateService] and [NarrateActivity] (same process). */
object NarrateState {
    private val main = Handler(Looper.getMainLooper())
    @Volatile var current = NarrateSnapshot()
        private set
    var listener: ((NarrateSnapshot) -> Unit)? = null

    fun publish(s: NarrateSnapshot) {
        current = s
        main.post { listener?.invoke(s) }
    }
}

/**
 * Speaks selected text with an on-device open TTS model (sherpa-onnx; Kokoro by default).
 *
 * A foreground media service so narration keeps going after the little panel is dismissed and
 * the user is back in their browser. One sentence at a time: a synth thread feeds a small
 * bounded queue, a playback thread drains it into a streaming [AudioTrack] — so audio starts
 * after the first sentence is ready and the rest renders ahead of the playhead.
 */
class NarrateService : Service() {
    companion object {
        const val ACTION_SPEAK = "narrate.SPEAK"
        const val ACTION_VOICE = "narrate.VOICE"   // switch to EXTRA_MODEL, downloading it if needed
        const val ACTION_TOGGLE = "narrate.TOGGLE"
        const val ACTION_STOP = "narrate.STOP"
        const val EXTRA_TEXT = "text"
        const val EXTRA_MODEL = "model"      // voice folder name (default: remembered/default)
        const val EXTRA_SID = "sid"          // speaker id within the model
        const val EXTRA_SPEED = "speed"
        const val EXTRA_THREADS = "threads"
        private const val TAG = "Narrate"
        private const val CHANNEL = "narrate"
        private const val NOTIFICATION_ID = 7201
        private const val PREFS = "narrate"

        // The loaded model outlives a single narration (and the service instance): loading
        // Kokoro costs seconds, so back-to-back selections should only pay it once.
        private val engineLock = Any()
        private var engine: OfflineTts? = null
        private var engineKey = ""

        // The last selection, so picking another voice (or finishing a download) can narrate it.
        private var lastRequest: Intent? = null

        fun speak(ctx: Context, text: String, from: Intent? = null) {
            val i = Intent(ctx, NarrateService::class.java).setAction(ACTION_SPEAK)
                .putExtra(EXTRA_TEXT, text)
            from?.extras?.let { i.putExtras(it) }   // model/sid/speed/threads overrides (adb)
            i.putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun send(ctx: Context, action: String, model: String? = null) {
            ctx.startService(Intent(ctx, NarrateService::class.java).setAction(action)
                .putExtra(EXTRA_MODEL, model))
        }
    }

    private var session: Session? = null
    private var downloading = false
    @Volatile private var downloadCancelled = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var pausedByFocus = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SPEAK -> startSpeaking(intent)
            ACTION_VOICE -> switchVoice(intent.getStringExtra(EXTRA_MODEL) ?: return START_NOT_STICKY)
            ACTION_TOGGLE -> session?.toggle()
            ACTION_STOP -> shutdown(NarrateSnapshot())
            else -> if (session == null) stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        session?.cancel()
        session = null
        downloadCancelled = true
        release()
        super.onDestroy()
    }

    // ── orchestration ────────────────────────────────────────────────────────────────────────

    private fun startSpeaking(intent: Intent) {
        val text = intent.getStringExtra(EXTRA_TEXT).orEmpty()
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        val dir = Voices.pick(this, intent.getStringExtra(EXTRA_MODEL) ?: prefs.getString("model", null))
        lastRequest = intent
        if (downloading) return   // selected something else mid-download: it's spoken afterwards
        session?.cancel()
        session = null
        goForeground(NarrateSnapshot(NarrateSnapshot.Phase.LOADING))
        // No voice yet: the panel offers the picker, and the parked request is spoken after it.
        if (dir == null) return shutdown(NarrateSnapshot(NarrateSnapshot.Phase.NEEDS_VOICE), stop = false)
        val sentences = splitForSpeech(text)
        if (sentences.isEmpty()) return shutdown(NarrateSnapshot())
        acquire()
        session = Session(
            dir, sentences,
            sid = intent.getIntExtra(EXTRA_SID, prefs.getInt("sid", 0)),
            speed = intent.getFloatExtra(EXTRA_SPEED, prefs.getFloat("speed", 1f)),
            threads = intent.getIntExtra(EXTRA_THREADS, 4),
        ).also { it.start() }
    }

    private fun switchVoice(name: String) {
        if (downloading) return
        if (Voices.installed(this).none { it.name == name }) return startDownload(name)
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString("model", name).apply()
        val again = lastRequest?.apply { removeExtra(EXTRA_MODEL) }
        if (again != null) startSpeaking(again) else if (session == null) stopSelf()
    }

    private fun startDownload(name: String) {
        session?.cancel()
        session = null
        downloading = true
        downloadCancelled = false
        val title = Voices.title(name)
        goForeground(NarrateSnapshot(NarrateSnapshot.Phase.DOWNLOADING, detail = title))
        acquire()
        val main = Handler(Looper.getMainLooper())
        Thread({
            try {
                var last = 0L
                Voices.download(this, name, { downloadCancelled }) { p ->
                    val now = SystemClock.elapsedRealtime()
                    if (now - last > 250) {
                        last = now
                        publish(NarrateSnapshot(NarrateSnapshot.Phase.DOWNLOADING, detail = title, progress = p))
                    }
                }
                main.post {
                    if (downloadCancelled) return@post
                    downloading = false
                    switchVoice(name)
                    if (session == null) shutdown(NarrateSnapshot())
                }
            } catch (e: Throwable) {
                Log.e(TAG, "voice download failed", e)
                main.post {
                    val cancelled = downloadCancelled
                    downloading = false
                    if (!cancelled) shutdown(NarrateSnapshot(
                        NarrateSnapshot.Phase.ERROR, detail = "Voice download failed: ${e.message}"))
                }
            }
        }, "narrate-download").start()
    }

    private fun fail(from: Session, message: String) = Handler(Looper.getMainLooper()).post {
        if (session === from) shutdown(NarrateSnapshot(NarrateSnapshot.Phase.ERROR, detail = message))
    }

    private fun finished(from: Session, detail: String) = Handler(Looper.getMainLooper()).post {
        if (session === from) shutdown(NarrateSnapshot(NarrateSnapshot.Phase.DONE, detail = detail))
    }

    private fun shutdown(last: NarrateSnapshot, stop: Boolean = true) {
        session?.cancel()
        session = null
        if (downloading) { downloadCancelled = true; downloading = false }
        release()
        NarrateState.publish(last)
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
        if (stop) stopSelf()
    }

    private fun publish(s: NarrateSnapshot) {
        NarrateState.publish(s)
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(s))
    }

    // ── one narration ────────────────────────────────────────────────────────────────────────

    private class Chunk(val index: Int, val samples: FloatArray)

    private inner class Session(
        val dir: File, val sentences: List<String>,
        val sid: Int, val speed: Float, val threads: Int,
    ) {
        @Volatile var cancelled = false
        @Volatile var paused = false
        private val pauseLock = Object()
        private val queue = LinkedBlockingQueue<Chunk>(4)   // bounds how far synth runs ahead
        private val end = Chunk(-1, FloatArray(0))
        @Volatile private var track: AudioTrack? = null
        @Volatile private var sampleRate = 24000
        @Volatile private var label = Voices.label(dir, sid)
        private val t0 = SystemClock.elapsedRealtime()
        private var loadMs = 0L
        private var audioSec = 0.0
        private var synthSec = 0.0
        private val synth = Thread(::synthesize, "narrate-synth")
        private val player = Thread(::play, "narrate-play")

        // sherpa-onnx's native side calls `invoke([F)Ljava/lang/Integer;` by exact signature; a
        // Kotlin lambda only gets the erased `invoke(Object)`, so this has to be a real class
        // (kept from R8 in proguard-rules.pro). Returning 0 aborts the sentence being rendered.
        private val keepGoing = object : Function1<FloatArray, Int> {
            override fun invoke(samples: FloatArray): Int = if (cancelled) 0 else 1
        }

        fun start() {
            publish(NarrateSnapshot(NarrateSnapshot.Phase.LOADING, total = sentences.size, detail = label))
            synth.start()
        }

        fun cancel() {
            cancelled = true
            synchronized(pauseLock) { pauseLock.notifyAll() }
            synth.interrupt()
            player.interrupt()
            runCatching { track?.pause(); track?.flush() }
        }

        fun toggle() {
            if (track == null) return
            paused = !paused
            if (paused) runCatching { track?.pause() }
            synchronized(pauseLock) { pauseLock.notifyAll() }
            val s = NarrateState.current
            publish(s.copy(phase = if (paused) NarrateSnapshot.Phase.PAUSED else NarrateSnapshot.Phase.PLAYING))
        }

        private fun synthesize() {
            try {
                // Serialized on the shared engine: a superseded session bails at its next
                // callback, then this one proceeds.
                synchronized(engineLock) {
                    val key = "${dir.path}|$threads"
                    if (engine == null || engineKey != key) {
                        engine?.release()
                        engine = null
                        val t = SystemClock.elapsedRealtime()
                        engine = OfflineTts(config = Voices.config(dir, threads))
                        engineKey = key
                        loadMs = SystemClock.elapsedRealtime() - t
                        Log.i(TAG, "loaded ${dir.name} in $loadMs ms (threads=$threads, speakers=${engine!!.numSpeakers()})")
                    }
                    val tts = engine!!
                    sampleRate = tts.sampleRate()
                    val speaker = sid.coerceIn(0, (tts.numSpeakers() - 1).coerceAtLeast(0))
                    label = Voices.label(dir, speaker)
                    player.start()
                    for ((i, sentence) in sentences.withIndex()) {
                        if (cancelled) return
                        val t = SystemClock.elapsedRealtime()
                        val audio = tts.generateWithCallback(sentence, speaker, speed, keepGoing)
                        if (cancelled) return
                        val took = (SystemClock.elapsedRealtime() - t) / 1000.0
                        val secs = audio.samples.size.toDouble() / sampleRate
                        audioSec += secs
                        synthSec += took
                        Log.i(TAG, "sentence ${i + 1}/${sentences.size}: ${sentence.length} chars, " +
                            "%.2fs audio in %.2fs (RTF %.2f)".format(secs, took, took / secs.coerceAtLeast(0.01)))
                        queue.put(Chunk(i, audio.samples))
                    }
                    queue.put(end)
                }
            } catch (_: InterruptedException) {
            } catch (e: Throwable) {
                Log.e(TAG, "synthesis failed", e)
                if (!cancelled) fail(this, "Couldn't narrate: ${e.message}")
            }
        }

        private fun play() {
            try {
                val t = AudioTrack.Builder()
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(maxOf(
                        AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT),
                        sampleRate / 4 * 4))   // ≥ 250 ms; must be a whole number of 4-byte frames
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track = t
                requestFocus()
                t.play()
                var written = 0L
                var underruns = 0
                var first = true
                while (!cancelled) {
                    if (!first && queue.isEmpty()) underruns++   // playhead caught up with synth
                    val chunk = queue.take()
                    if (chunk === end) break
                    if (first) {
                        first = false
                        Log.i(TAG, "first audio after ${SystemClock.elapsedRealtime() - t0} ms (model load $loadMs ms)")
                    }
                    publish(NarrateSnapshot(
                        if (paused) NarrateSnapshot.Phase.PAUSED else NarrateSnapshot.Phase.PLAYING,
                        chunk.index, sentences.size, sentences[chunk.index], stats()))
                    var off = 0
                    val slice = sampleRate / 10
                    while (off < chunk.samples.size && !cancelled) {
                        awaitResume(t)
                        val n = t.write(chunk.samples, off, min(slice, chunk.samples.size - off), AudioTrack.WRITE_BLOCKING)
                        if (n < 0) error("AudioTrack write failed ($n)")
                        if (n == 0) Thread.sleep(10)
                        off += n
                    }
                    written += chunk.samples.size
                }
                // Let the tail drain before tearing the track down.
                var head = -1L
                var stalled = 0
                while (!cancelled && stalled < 50) {
                    awaitResume(t)
                    val now = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                    if (now >= written) break
                    stalled = if (now == head) stalled + 1 else 0
                    head = now
                    Thread.sleep(40)
                }
                if (!cancelled) {
                    Log.i(TAG, "done: %.1fs audio, synth RTF %.2f, underruns=%d".format(
                        audioSec, synthSec / audioSec.coerceAtLeast(0.01), underruns))
                    finished(this, stats())
                }
            } catch (_: InterruptedException) {
            } catch (e: Throwable) {
                Log.e(TAG, "playback failed", e)
                if (!cancelled) fail(this, "Playback failed: ${e.message}")
            } finally {
                runCatching { track?.release() }
                track = null
            }
        }

        private fun awaitResume(t: AudioTrack) {
            if (!paused) return
            synchronized(pauseLock) { while (paused && !cancelled) pauseLock.wait() }
            if (!cancelled) t.play()
        }

        // How fast the phone renders this voice relative to playback: under 1× it can't keep
        // up, and the listener hears it as pauses between sentences.
        private fun stats(): String {
            if (audioSec <= 0) return label
            val x = audioSec / synthSec.coerceAtLeast(0.01)
            return "$label · renders at %.1f× real time".format(x) +
                if (x < 1.0) " — expect pauses between sentences" else ""
        }
    }

    // ── audio focus / wake lock ──────────────────────────────────────────────────────────────

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        val s = session ?: return@OnAudioFocusChangeListener
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> if (pausedByFocus && s.paused) { pausedByFocus = false; s.toggle() }
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                if (!s.paused) { pausedByFocus = change != AudioManager.AUDIOFOCUS_LOSS; s.toggle() }
        }
    }

    private fun requestFocus() {
        val am = getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setOnAudioFocusChangeListener(focusListener, Handler(Looper.getMainLooper()))
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun acquire() {
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "audiobook:narrate")
        }
        wakeLock?.takeIf { !it.isHeld }?.acquire(60 * 60 * 1000L)
    }

    private fun release() {
        wakeLock?.takeIf { it.isHeld }?.release()
        val am = getSystemService(AudioManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { am.abandonAudioFocusRequest(it) }
        else @Suppress("DEPRECATION") am.abandonAudioFocus(focusListener)
        focusRequest = null
        pausedByFocus = false
    }

    // ── notification ─────────────────────────────────────────────────────────────────────────

    private fun goForeground(s: NarrateSnapshot) {
        NarrateState.publish(s)
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "Narration", NotificationManager.IMPORTANCE_LOW))
        }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification(s), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification(s))
        }
    }

    private fun action(action: String, code: Int): PendingIntent = PendingIntent.getService(
        this, code, Intent(this, NarrateService::class.java).setAction(action),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun notification(s: NarrateSnapshot): Notification {
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val title = when (s.phase) {
            NarrateSnapshot.Phase.DOWNLOADING -> "Downloading ${s.detail}… ${(s.progress * 100).toInt()}%"
            NarrateSnapshot.Phase.LOADING -> "Preparing narration…"
            NarrateSnapshot.Phase.PAUSED -> "Narration paused"
            else -> "Narrating ${s.index + 1} of ${s.total}"
        }
        b.setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setContentTitle(title)
            .setContentText(s.sentence)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(PendingIntent.getActivity(
                this, 0, Intent(this, NarrateActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        if (s.phase == NarrateSnapshot.Phase.PLAYING || s.phase == NarrateSnapshot.Phase.PAUSED) {
            val pausedNow = s.phase == NarrateSnapshot.Phase.PAUSED
            b.addAction(Notification.Action.Builder(null, if (pausedNow) "Resume" else "Pause",
                action(ACTION_TOGGLE, 1)).build())
        }
        b.addAction(Notification.Action.Builder(null, "Stop", action(ACTION_STOP, 2)).build())
        return b.build()
    }
}
