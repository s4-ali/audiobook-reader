package com.audiobook.audiobook_player.narrate

import android.content.Context
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKittenModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsVitsModelConfig
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * On-device voice models for "Narrate" (sherpa-onnx). A voice is one unpacked sherpa-onnx TTS
 * model folder under `<external files>/tts/<name>/` — the same layout the upstream
 * `tts-models` release tarballs unpack to, so a folder can be downloaded in-app or just
 * `adb push`ed. Nothing is bundled in the APK.
 */
object Voices {
    private const val RELEASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

    /** A downloadable voice: [name] is both the release tarball and the installed folder. */
    class Voice(val name: String, val title: String, val mb: Int, val note: String)

    /**
     * The voices offered in the panel's picker, in default-preference order. Kokoro-82M is what
     * the desktop narrates with, but on a phone CPU it only just reaches real time (and drops
     * below it once the phone warms up), so it isn't the default; the two small models render
     * several times faster than they play.
     */
    val CATALOG = listOf(
        Voice("vits-piper-en_US-lessac-medium", "Piper", 64, "fastest"),
        Voice("kitten-nano-en-v0_8-fp32", "Kitten", 61, "fast"),
        Voice("kokoro-en-v0_19", "Kokoro", 305, "best quality, slow"),
    )

    /** Kokoro v0.19 speaker ids → the familiar voice names. */
    val KOKORO_V019 = listOf(
        "af", "af_bella", "af_nicole", "af_sarah", "af_sky", "am_adam",
        "am_michael", "bf_emma", "bf_isabella", "bm_george", "bm_lewis",
    )

    fun title(name: String): String = CATALOG.firstOrNull { it.name == name }?.title ?: name

    fun label(dir: File, sid: Int): String =
        if (dir.name.startsWith("kokoro") && dir.name.endsWith("en-v0_19"))
            "Kokoro · ${KOKORO_V019.getOrElse(sid) { "voice $sid" }}"
        else title(dir.name)

    fun root(ctx: Context) = File(ctx.getExternalFilesDir(null), "tts")

    fun installed(ctx: Context): List<File> =
        root(ctx).listFiles { f -> f.isDirectory && File(f, "tokens.txt").exists() }
            ?.sortedBy { it.name } ?: emptyList()

    /** The voice to use: the requested/remembered one if installed, else the first catalog hit, else any. */
    fun pick(ctx: Context, name: String?): File? {
        val all = installed(ctx)
        return all.firstOrNull { it.name == name }
            ?: CATALOG.firstNotNullOfOrNull { v -> all.firstOrNull { it.name == v.name } }
            ?: all.firstOrNull()
    }

    /** Build the sherpa-onnx config for a model folder, inferring the family from its files. */
    fun config(dir: File, threads: Int): OfflineTtsConfig {
        val onnx = dir.listFiles { f -> f.name.endsWith(".onnx") }?.firstOrNull()
            ?: error("no .onnx model in ${dir.name}")
        val tokens = File(dir, "tokens.txt").path
        val data = File(dir, "espeak-ng-data").path
        val voices = File(dir, "voices.bin")
        val model = when {
            voices.exists() && dir.name.startsWith("kitten") -> OfflineTtsModelConfig(
                kitten = OfflineTtsKittenModelConfig(onnx.path, voices.path, tokens, data),
                numThreads = threads,
            )
            voices.exists() -> OfflineTtsModelConfig(
                kokoro = OfflineTtsKokoroModelConfig(onnx.path, voices.path, tokens, data),
                numThreads = threads,
            )
            else -> OfflineTtsModelConfig(
                vits = OfflineTtsVitsModelConfig(model = onnx.path, tokens = tokens, dataDir = data),
                numThreads = threads,
            )
        }
        return OfflineTtsConfig(model = model)
    }

    /**
     * Download + unpack a release tarball into [root]. Unpacks to a temp folder and renames at
     * the end, so a half-finished download never looks installed. [progress] gets 0..1 of the
     * compressed stream; [cancelled] is polled between reads.
     */
    fun download(ctx: Context, name: String, cancelled: () -> Boolean, progress: (Float) -> Unit): File {
        val root = root(ctx).apply { mkdirs() }
        val tmp = File(root, ".partial").apply { deleteRecursively(); mkdirs() }
        val conn = URL("$RELEASE/$name.tar.bz2").openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            if (conn.responseCode != 200) error("download failed: HTTP ${conn.responseCode}")
            val total = conn.contentLengthLong.coerceAtLeast(1)
            val counting = object : FilterInputStream(conn.inputStream.buffered(1 shl 16)) {
                var seen = 0L
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (cancelled()) throw InterruptedException("download cancelled")
                    val n = super.read(b, off, len)
                    if (n > 0) { seen += n; progress(seen.toFloat() / total) }
                    return n
                }
            }
            TarArchiveInputStream(BZip2CompressorInputStream(counting as InputStream)).use { tar ->
                val base = tmp.canonicalPath + File.separator
                while (true) {
                    val e = tar.nextEntry ?: break
                    val out = File(tmp, e.name)
                    if (!out.canonicalPath.startsWith(base)) continue  // never write outside tmp
                    if (e.isDirectory) out.mkdirs()
                    else if (e.isFile) {
                        out.parentFile?.mkdirs()
                        out.outputStream().use { tar.copyTo(it, 1 shl 16) }
                    }
                }
            }
            val dest = File(root, name).apply { deleteRecursively() }
            if (!File(tmp, name).renameTo(dest)) error("could not install $name")
            return dest
        } finally {
            conn.disconnect()
            tmp.deleteRecursively()
        }
    }
}

/**
 * Split text into speakable chunks, one sentence each: synthesizing sentence-by-sentence is what
 * lets playback start after the first sentence instead of after the whole selection. Fragments
 * too short to carry prosody are merged forward and run-on sentences are cut at a clause break.
 */
fun splitForSpeech(text: String, maxChars: Int = 350): List<String> {
    val clean = text.replace(Regex("\\s+"), " ").trim()
    if (clean.isEmpty()) return emptyList()
    val it = java.text.BreakIterator.getSentenceInstance(java.util.Locale.US)
    it.setText(clean)
    val out = ArrayList<String>()
    var pending = ""
    var start = it.first()
    var end = it.next()
    while (end != java.text.BreakIterator.DONE) {
        pending = (pending + " " + clean.substring(start, end).trim()).trim()
        if (pending.length >= 25) {
            out += cutLong(pending, maxChars)
            pending = ""
        }
        start = end
        end = it.next()
    }
    if (pending.isNotEmpty()) {
        if (out.isNotEmpty() && pending.length < 25) out[out.size - 1] = out.last() + " " + pending
        else out += cutLong(pending, maxChars)
    }
    // Playback can't start until the first chunk is rendered, so keep that one short: open on
    // the first clause of a long opening sentence rather than making the listener wait for all of it.
    val first = out[0]
    if (first.length > 90) {
        val cut = first.substring(0, 90).lastIndexOfAny(charArrayOf(',', ';', ':', '—')) + 1
        if (cut >= 30) {
            out[0] = first.substring(0, cut).trim()
            out.add(1, first.substring(cut).trim())
        }
    }
    return out
}

private fun cutLong(s: String, max: Int): List<String> {
    if (s.length <= max) return listOf(s)
    val out = ArrayList<String>()
    var rest = s
    while (rest.length > max) {
        val window = rest.substring(0, max)
        var cut = window.lastIndexOfAny(charArrayOf(',', ';', ':', '—')) + 1
        if (cut < max / 3) cut = window.lastIndexOf(' ') + 1
        if (cut <= 0) cut = max
        out += rest.substring(0, cut).trim()
        rest = rest.substring(cut).trim()
    }
    if (rest.isNotEmpty()) out += rest
    return out
}
