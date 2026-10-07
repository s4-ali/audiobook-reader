package com.audiobook.audiobook_player.narrate

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ProgressBar
import android.widget.TextView
import com.audiobook.audiobook_player.narrate.NarrateSnapshot.Phase

/**
 * The entry point Android shows as **Narrate** in the text-selection toolbar of other apps
 * (`ACTION_PROCESS_TEXT`) and in the share sheet (`ACTION_SEND`, for apps whose custom selection
 * menu hides process-text actions). It hands the text to [NarrateService] and shows a small
 * bottom panel over the app the user was reading; tapping outside dismisses the panel while the
 * narration carries on (controls stay in the notification).
 */
class NarrateActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var sentence: TextView
    private lateinit var detail: TextView
    private lateinit var bar: ProgressBar
    private lateinit var primary: Button
    private lateinit var stop: Button
    private lateinit var voice: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildPanel()
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        NarrateState.listener = ::render
        render(NarrateState.current)
    }

    override fun onStop() {
        NarrateState.listener = null
        super.onStop()
    }

    private fun handle(intent: Intent) {
        val text = when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            Intent.ACTION_SEND -> intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
            else -> null   // reopened from the notification: just show the current state
        }?.toString()?.trim().orEmpty()
        if (text.isEmpty()) {
            if (intent.action != null && !NarrateState.current.active) finish()
            return
        }
        // Without this the foreground service still runs, but its pause/stop notification is hidden.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        NarrateService.speak(this, text, intent)
    }

    private fun render(s: NarrateSnapshot) {
        status.text = when (s.phase) {
            Phase.NEEDS_VOICE -> "Narration needs a voice"
            Phase.DOWNLOADING -> "Downloading ${s.detail}… ${(s.progress * 100).toInt()}%"
            Phase.LOADING -> "Preparing narration…"
            Phase.PLAYING -> "Narrating ${s.index + 1} of ${s.total}"
            Phase.PAUSED -> "Paused · ${s.index + 1} of ${s.total}"
            Phase.DONE -> "Finished"
            Phase.ERROR -> "Narration failed"
            Phase.IDLE -> "Narrate"
        }
        sentence.text = when (s.phase) {
            Phase.NEEDS_VOICE -> "Download a voice once. After that narration runs entirely on " +
                "this phone, with no connection needed."
            Phase.ERROR -> s.detail
            else -> s.sentence
        }
        sentence.visibility = if (sentence.text.isEmpty()) View.GONE else View.VISIBLE
        detail.text = if (s.phase == Phase.ERROR || s.phase == Phase.DOWNLOADING) "" else s.detail
        detail.visibility = if (detail.text.isEmpty()) View.GONE else View.VISIBLE

        bar.visibility = if (s.active) View.VISIBLE else View.GONE
        bar.isIndeterminate = s.phase == Phase.LOADING
        bar.max = 1000
        bar.progress = when (s.phase) {
            Phase.DOWNLOADING -> (s.progress * 1000).toInt()
            Phase.PLAYING, Phase.PAUSED -> (s.index + 1) * 1000 / s.total.coerceAtLeast(1)
            else -> 0
        }

        val playing = s.phase == Phase.PLAYING || s.phase == Phase.PAUSED
        primary.visibility = if (playing || s.phase == Phase.NEEDS_VOICE) View.VISIBLE else View.GONE
        primary.text = when (s.phase) {
            Phase.NEEDS_VOICE -> "Choose voice"
            Phase.PAUSED -> "Resume"
            else -> "Pause"
        }
        stop.text = if (s.active) "Stop" else "Close"
        voice.visibility =
            if (s.phase == Phase.NEEDS_VOICE || s.phase == Phase.DOWNLOADING) View.GONE else View.VISIBLE
    }

    private fun onPrimary() {
        if (NarrateState.current.phase == Phase.NEEDS_VOICE) pickVoice(primary)
        else NarrateService.send(this, NarrateService.ACTION_TOGGLE)
    }

    /** Installed voices switch at once (re-narrating the current text); the rest download first. */
    private fun pickVoice(anchor: View) {
        val installed = Voices.installed(this).map { it.name }
        val names = Voices.CATALOG.map { it.name } + installed.filter { n -> Voices.CATALOG.none { it.name == n } }
        val menu = PopupMenu(this, anchor)
        for ((i, name) in names.withIndex()) {
            val v = Voices.CATALOG.firstOrNull { it.name == name }
            menu.menu.add(0, i, i, when {
                v == null -> name
                name in installed -> "${v.title} · ${v.note}"
                else -> "Get ${v.title} · ${v.mb} MB"
            })
        }
        menu.setOnMenuItemClickListener {
            NarrateService.send(this, NarrateService.ACTION_VOICE, names[it.itemId])
            true
        }
        menu.show()
    }

    private fun onStopPressed() {
        NarrateService.send(this, NarrateService.ACTION_STOP)
        finish()
    }

    // Built in code: one small panel isn't worth a layout resource in a Flutter project.
    private fun buildPanel() {
        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        val base = Color.parseColor(if (night) "#1E1E2E" else "#EFF1F5")
        val text = Color.parseColor(if (night) "#CDD6F4" else "#4C4F69")
        val subtext = Color.parseColor(if (night) "#A6ADC8" else "#6C6F85")
        val accent = Color.parseColor(if (night) "#CBA6F7" else "#8839EF")
        val d = resources.displayMetrics.density
        fun dp(v: Int) = (v * d).toInt()

        fun label(size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
            textSize = size
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }
        status = label(16f, text, bold = true)
        sentence = label(14f, text).apply {
            maxLines = 4
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dp(8), 0, 0)
        }
        detail = label(12f, subtext).apply { setPadding(0, dp(6), 0, 0) }
        bar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            progressTintList = android.content.res.ColorStateList.valueOf(accent)
            indeterminateTintList = android.content.res.ColorStateList.valueOf(accent)
        }

        fun button(filled: Boolean, onClick: (View) -> Unit) = Button(this, null, 0).apply {
            isAllCaps = false
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(if (filled) base else accent)
            background = GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                if (filled) setColor(accent) else setStroke(dp(1), accent)
            }
            gravity = Gravity.CENTER
            minHeight = dp(44)
            minimumHeight = dp(44)
            setPadding(dp(22), 0, dp(22), 0)
            setOnClickListener { onClick(it) }
        }
        primary = button(filled = true) { onPrimary() }
        stop = button(filled = false) { onStopPressed() }
        voice = button(filled = false, ::pickVoice).apply { setText("Voice") }
        val buttons = LinearLayout(this).apply {
            gravity = Gravity.END
            setPadding(0, dp(14), 0, 0)
            addView(voice, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
            addView(View(context), LinearLayout.LayoutParams(0, 0, 1f))
            addView(stop, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
            addView(primary, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { marginStart = dp(10) })
        }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(base)
                cornerRadii = floatArrayOf(dp(24).toFloat(), dp(24).toFloat(), dp(24).toFloat(), dp(24).toFloat(), 0f, 0f, 0f, 0f)
            }
            elevation = dp(12).toFloat()
            isClickable = true   // taps on the card must not fall through to the dismiss scrim
            addView(status)
            addView(bar, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(8) })
            addView(sentence)
            addView(detail)
            addView(buttons, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
        val root = FrameLayout(this).apply {
            setOnClickListener { finish() }   // tap outside: hide the panel, keep narrating
            addView(card, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.BOTTOM))
        }
        // Edge-to-edge is enforced on recent Android: keep the card clear of the navigation bar.
        root.setOnApplyWindowInsetsListener { _, insets ->
            @Suppress("DEPRECATION")
            card.setPadding(dp(20), dp(18), dp(20), dp(16) + insets.systemWindowInsetBottom)
            insets
        }
        card.setPadding(dp(20), dp(18), dp(20), dp(16))
        setContentView(root)
    }
}
