"use strict";

/* ------------------------------------------------------------------ helpers */
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const api = async (path, opts) => {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.json();
};
const escapeHtml = (s) => s.replace(/[&<>"]/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const fmtTime = (sec) => {
  if (!isFinite(sec) || sec < 0) sec = 0;
  sec = Math.floor(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  const mm = h ? String(m).padStart(2, "0") : String(m);
  return (h ? h + ":" : "") + mm + ":" + String(s).padStart(2, "0");
};
// Compact total duration as "1h 53m" (or "45m" under an hour, "2h" on the hour).
const fmtHrMin = (sec) => {
  const total = Math.round((sec || 0) / 60);
  const h = Math.floor(total / 60), m = total % 60;
  return h ? (m ? `${h}h ${m}m` : `${h}h`) : `${m}m`;
};
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
// A chapter is playable when explicitly "ready", or (legacy manifests) when it has no status.
const isReady = (ch) => !!ch && (!ch.status || ch.status === "ready");

/* -------------------------------------------------------------------- state */
const audio = $("#audio");
const state = {
  books: [],
  bookId: null,
  manifest: null,
  ci: -1,            // current chapter index
  sentences: [],     // sentences of current chapter
  activeSi: -1,
  searchItems: [],
  isScrubbing: false,
  spanEls: [],       // DOM span per sentence index
  anyGenerating: false,
  waitingForNext: null,   // chapter index we're waiting on before auto-advancing
  pendingInitial: false,  // opened a book with no chapter ready yet
  genstate: null,         // latest /genstate response while generating
  notes: [],              // server-backed notes for the open book (see app/notes.py)
  remotePos: {},          // bookId -> Firestore progress doc (when signed in; see sync.js)
  syncUser: null,         // {uid,email} when signed in to cloud sync, else null
  localUpdated: 0,        // ms timestamp of our last local savePos (to dedupe remote echoes)
  unsubProgress: null,    // Firestore progress listener teardown for the open book
  unsubNotes: null,       // Firestore notes listener teardown for the open book
  readingMode: false,     // full-screen distraction-free reading
  following: false,       // mirroring another device's live playback (cross-device auto-follow)
  followTimer: null,      // stale timer: drop out of follow if the other device stops updating
};
let manifestPoll = null;  // interval while a book is still generating
let libraryPoll = null;   // interval while the library has generating books

// A stable per-browser id so a device can recognize (and ignore) the echo of its own cloud
// progress writes when they come back through the Firestore listener.
const DEVICE_ID = (() => {
  let d = localStorage.getItem("abk:device");
  if (!d) { d = (crypto.randomUUID ? crypto.randomUUID() : "d" + Date.now().toString(36)); localStorage.setItem("abk:device", d); }
  return d;
})();
const DEVICE_NAME = "Web";        // human label other devices show in the "playing on…" banner
const FOLLOW_WINDOW_MS = 12000;   // a remote update within this counts as "actively playing now"
const signedIn = () => !!(window.abkSync && window.abkSync.enabled && state.syncUser);
// Signed in with a real (email) account — not the anonymous baseline. Sync is active whenever
// signedIn() (any uid, incl. anonymous); the account UI keys off this instead.
const hasAccount = () => !!(state.syncUser && !state.syncUser.isAnonymous);

/* --------------------------------------------------------------- LIBRARY */
async function loadLibrary() {
  const { books } = await api("/api/library");
  state.books = books;
  state.anyGenerating = books.some((b) => b.status === "generating");
  const grid = $("#bookGrid");
  grid.innerHTML = "";
  $("#emptyLib").hidden = books.length > 0;
  for (const b of books) {
    const card = document.createElement("div");
    card.className = "book-card";
    const generating = b.status === "generating";
    const ready = (b.status || "ready") === "ready";
    const badge = generating
      ? `<div class="badge"><span class="spinner"></span>${b.chapters_ready || 0}/${b.n_chapters}</div>`
      : "";
    const pkg = ready
      ? `<a class="pkg" href="/api/books/${b.id}/package" download title="Download .abk package for the phone app">${icon("download")}</a>`
      : "";
    const rss = ready ? `<button class="rss" title="Copy podcast RSS feed URL">${icon("rss")}</button>` : "";
    card.innerHTML = `
      <button class="del" title="Delete">${icon("trash")}</button>
      ${pkg}
      ${rss}
      ${badge}
      <div class="cover">${icon("book-open")}</div>
      <h3>${escapeHtml(b.title || b.id)}</h3>
      <div class="author">${escapeHtml(b.author || "Unknown")}</div>
      <div class="stats"><span>${b.n_chapters} chapters</span><span>${fmtHrMin(b.duration)}</span>
        <span>${escapeHtml(b.voice || "")}</span></div>
      ${resumeBarHtml(b)}`;
    card.addEventListener("click", () => openBook(b.id));
    const pkgEl = card.querySelector(".pkg");
    if (pkgEl) pkgEl.addEventListener("click", (e) => e.stopPropagation());  // download, don't open
    const rssEl = card.querySelector(".rss");
    if (rssEl) rssEl.addEventListener("click", (e) => {
      e.stopPropagation();   // copy the feed URL, don't open the book
      const url = `${location.origin}/api/books/${b.id}/feed.xml`;
      if (navigator.clipboard) {
        navigator.clipboard.writeText(url)
          .then(() => toast("Podcast feed URL copied — paste it into your podcast app."))
          .catch(() => toast(url));
      } else { toast(url); }
    });
    card.querySelector(".del").addEventListener("click", async (e) => {
      e.stopPropagation();
      if (confirm(`Delete "${b.title}" and its audio?`)) {
        await fetch(`/api/books/${b.id}`, { method: "DELETE" });
        localStorage.removeItem(`abk:bm:${b.id}`);   // drop this book's bookmarks (progress is cloud-only now)
        loadLibrary();
      }
    });
    grid.appendChild(card);
  }
  renderContinue();
}

// A thin progress bar on a library card for a book with a saved position. Only a fully
// "ready" book can read as finished — a still-generating book's total_duration counts only
// the chapters rendered so far, which would otherwise inflate the fraction toward 100%.
function resumeBarHtml(b) {
  const p = loadPos(b.id);
  if (!p || !(p.frac > 0)) return "";
  const done = b.status === "ready" && p.frac >= 0.999;
  const pct = done ? 100 : Math.min(100, Math.max(2, Math.round(p.frac * 100)));
  return `<div class="card-progress${done ? " done" : ""}" title="${done ? "Finished" : pct + "% listened"}">
            <div class="card-progress-fill" style="width:${pct}%"></div></div>`;
}

// "Continue listening" hero: jump straight back into the most recently played, unfinished
// book at its saved spot (and start playing — the Resume click is the user gesture).
function renderContinue() {
  const sec = $("#continueSection");
  let best = null;
  for (const b of state.books) {
    const p = loadPos(b.id);
    if (!p || p.updated == null || p.ci == null) continue;
    // A fully-ready book at the end is finished; a generating book never is (its fraction
    // is measured against only the chapters rendered so far).
    if (b.status === "ready" && p.frac != null && p.frac >= 0.999) continue;
    if (!best || (p.updated || 0) > (best.p.updated || 0)) best = { b, p };
  }
  if (!best) { sec.hidden = true; sec.innerHTML = ""; return; }
  const { b, p } = best;
  const pct = Math.max(0, Math.min(100, Math.round((p.frac || 0) * 100)));
  sec.hidden = false;
  sec.innerHTML = `
    <div class="continue-card">
      <div class="cc-cover">${icon("book-open")}</div>
      <div class="cc-body">
        <div class="cc-label">${icon("play")} Continue listening</div>
        <h3>${escapeHtml(b.title || b.id)}</h3>
        <div class="cc-sub">Chapter ${(p.ci || 0) + 1} of ${b.n_chapters} · ${pct}%</div>
        <div class="cc-bar"><div class="cc-fill" style="width:${pct}%"></div></div>
      </div>
      <button class="cc-resume primary">Resume</button>
    </div>`;
  sec.querySelector(".continue-card")
     .addEventListener("click", () => openBook(b.id, { autoplay: true }));
}

function showLibrary() {
  stopGenPoll();
  resetSleep();       // disarm any running sleep timer when leaving the reader
  savePos();          // capture the exact spot before clearing reader state (the async
  window.abkSync?.flushProgress?.();   // push that spot to the cloud now, not 1.5s later
  audio.pause();      // 'pause' handler would otherwise run after bookId is nulled)
  teardownBookSync();
  if (state.readingMode) exitReadingMode();
  state.bookId = null; state.manifest = null; state.waitingForNext = null; state.genstate = null;
  state.notes = []; hideNotePopover(); $("#notesPanel").hidden = true;
  $("#libraryView").hidden = false;
  $("#readerView").hidden = true;
  $("#player").hidden = true;
  $("#backBtn").hidden = true;
  $("#bookMeta").textContent = "";
  refreshRemoteProgress().finally(() =>
    loadLibrary().then(() => { state.anyGenerating ? startLibraryPolling() : stopLibraryPolling(); }));
}

function startLibraryPolling() {
  stopLibraryPolling();
  libraryPoll = setInterval(() => {
    if ($("#libraryView").hidden) { stopLibraryPolling(); return; }
    loadLibrary().then(() => { if (!state.anyGenerating) stopLibraryPolling(); }).catch(() => {});
  }, 4000);
}
function stopLibraryPolling() { if (libraryPoll) { clearInterval(libraryPoll); libraryPoll = null; } }

/* ---------------------------------------------------------------- READER */
async function openBook(bookId, opts = {}) {
  stopLibraryPolling();
  const m = await api(`/api/books/${bookId}/manifest`);
  state.bookId = bookId;
  state.manifest = m;
  state.waitingForNext = null;
  state.pendingInitial = false;
  state.genstate = null;
  $("#libraryView").hidden = true;
  $("#readerView").hidden = false;
  $("#player").hidden = false;
  $("#backBtn").hidden = false;
  updateBookMeta();
  buildSearchIndex();
  renderOutline();
  renderBookmarks();
  clearSearch();
  updateGenBanner();
  await loadNotes(bookId);

  // Pull this book's cloud progress first so the resume point can reflect another device.
  if (signedIn() && !state.remotePos[bookId]) {
    try { const rp = await window.abkSync.fetchProgress(bookId); if (rp) state.remotePos[bookId] = rp; } catch (e) {}
  }
  const pos = loadPos(bookId);
  const chapters = m.chapters;
  // Restart a fully-heard book from the top — but only when it's done generating (a
  // generating book's fraction is measured against just the chapters rendered so far).
  const finished = m.status === "ready" && pos.frac != null && pos.frac >= 0.999;
  let target = -1;
  if (pos.ci != null && !finished && isReady(chapters[pos.ci])) target = pos.ci;
  if (target < 0) target = chapters.findIndex(isReady);
  if (target >= 0) {
    const resuming = target === pos.ci && !finished;
    loadChapter(target, resuming ? (pos.t || 0) : 0, resuming && !!opts.autoplay);
  } else {
    // Nothing ready yet — show a placeholder; polling loads chapter 1 when it lands.
    state.pendingInitial = true;
    $("#chapterHeader").innerHTML =
      `<h2>${escapeHtml(m.title)}</h2><div class="sub">Preparing the first chapter…</div>`;
    $("#reader").innerHTML = "";
    $("#npChapter").textContent = "Generating…";
    $("#npSentence").textContent = "";
  }
  await pollGenState(bookId);
  if (state.genstate && (state.genstate.active || state.genstate.manifest_status === "generating"))
    startGenPoll(bookId);
  setupBookSync(bookId);   // cloud progress + notes listeners (no-op unless signed in)
}

function updateBookMeta() {
  const m = state.manifest;
  $("#bookMeta").innerHTML =
    `<b>${escapeHtml(m.title)}</b> · ${escapeHtml(m.author || "")} · ` +
    `${escapeHtml(m.voice || "")} · ${fmtTime(m.total_duration)}`;
}

// The generation banner doubles as the control surface (pause/resume/cancel).
function updateGenBanner() {
  const el = $("#genBanner");
  if (!state.manifest) { el.hidden = true; return; }
  const g = state.genstate;
  const ready = g ? g.chapters_ready : state.manifest.chapters_ready;
  const total = g ? g.chapters_total : state.manifest.chapters_total;
  const mstatus = g ? g.manifest_status : state.manifest.status;
  const active = !!(g && g.active);
  const paused = !!(g && g.paused);

  let body = "", actions = "";
  if (active && paused) {
    body = `<span class="gb-ico">${icon("pause")}</span>Paused — <b>${ready}/${total}</b>`;
    actions = `<button class="gb-btn" data-act="resume">Resume</button>
               <button class="gb-btn danger" data-act="cancel">Cancel</button>`;
  } else if (active && g && g.cancelling) {
    body = `<span class="spinner"></span>Cancelling…`;
  } else if (active) {
    body = `<span class="spinner"></span>Generating — <b>${ready}/${total}</b>`;
    actions = `<button class="gb-btn" data-act="pause">Pause</button>
               <button class="gb-btn danger" data-act="cancel">Cancel</button>`;
  } else if (mstatus === "generating" || mstatus === "partial" || mstatus === "cancelled") {
    const label = mstatus === "cancelled" ? "Generation cancelled"
                : mstatus === "partial" ? "Generation incomplete" : "Generation stopped";
    body = `<span class="gb-ico">${icon("stop")}</span>${label} — <b>${ready}/${total}</b>`;
    actions = `<button class="gb-btn" data-act="resume">Resume generating</button>`;
  } else {
    el.hidden = true; return;  // fully ready
  }
  el.hidden = false;
  el.innerHTML = `<span class="gb-body">${body}</span><span class="gb-actions">${actions}</span>`;
  el.querySelectorAll(".gb-btn").forEach((b) =>
    b.addEventListener("click", () => controlAction(b.dataset.act)));
}

async function controlAction(act) {
  const id = state.bookId;
  if (!id) return;
  if (act === "cancel" && !confirm(
      "Cancel generation?\nChapters already finished stay; the rest stop. You can resume later.")) return;
  try {
    await api(`/api/books/${id}/${act}`, { method: "POST" });
  } catch (e) {
    toast(`Couldn't ${act}: ${e.message || "error"}`);
  }
  startGenPoll(id);
  await pollGenState(id);  // reflect the new state right away
}

// Poll the lightweight /genstate; only re-download the full manifest when a
// chapter actually finished. This keeps playback of the current chapter smooth.
function startGenPoll(bookId) {
  stopGenPoll();
  manifestPoll = setInterval(() => pollGenState(bookId), 3500);
}
function stopGenPoll() { if (manifestPoll) { clearInterval(manifestPoll); manifestPoll = null; } }

async function pollGenState(bookId) {
  if (state.bookId !== bookId) { stopGenPoll(); return; }
  let g;
  try { g = await api(`/api/books/${bookId}/genstate`); }
  catch (e) { return; }
  if (state.bookId !== bookId) return;
  state.genstate = g;
  const readyChanged = !state.manifest || g.chapters_ready !== state.manifest.chapters_ready;
  const statusChanged = !state.manifest || g.manifest_status !== state.manifest.status;
  if (readyChanged || statusChanged) {
    try {
      const m = await api(`/api/books/${bookId}/manifest`);
      if (state.bookId === bookId) applyManifestUpdate(m);
    } catch (e) { /* ignore */ }
  }
  updateGenBanner();
  if (!g.active && g.manifest_status !== "generating") stopGenPoll();
}

function applyManifestUpdate(m) {
  state.manifest = m;
  buildSearchIndex();
  renderOutline();
  updateBookMeta();
  updateGenBanner();
  // If we opened before anything was ready, start the first ready chapter (paused).
  if (state.pendingInitial) {
    const fr = m.chapters.findIndex(isReady);
    if (fr >= 0) { state.pendingInitial = false; loadChapter(fr, 0, false); }
  }
  // Auto-continue once the chapter we were waiting on has finished.
  if (state.waitingForNext != null) {
    const w = m.chapters[state.waitingForNext];
    if (isReady(w)) { const n = state.waitingForNext; state.waitingForNext = null; loadChapter(n, 0, true); }
  }
}

function renderOutline() {
  const nav = $("#outline");
  nav.innerHTML = "";
  state.manifest.chapters.forEach((ch, ci) => {
    const ready = isReady(ch);
    const errored = ch.status === "error";
    const row = document.createElement("div");
    row.className = "ch" + (ready ? "" : errored ? " pending error" : " pending");
    row.dataset.ci = ci;
    const right = ready ? fmtTime(ch.duration) : errored ? icon("alert") : icon("clock");
    row.innerHTML = `<span>${escapeHtml(ch.title)}</span><span class="dur">${right}</span>`;
    row.addEventListener("click", () => {
      if (ready) loadChapter(ci, 0, true);
      else toast(errored ? "This chapter failed to generate."
                         : "This chapter is still being generated…");
    });
    nav.appendChild(row);
    (ch.topics || []).forEach((tp) => {
      const tReady = ready && tp.time != null;
      const t = document.createElement("div");
      t.className = "topic" + (tp.level >= 3 ? " lvl3" : "") + (tReady ? "" : " pending");
      t.textContent = tp.title;
      t.addEventListener("click", () => {
        if (tReady) loadChapter(ci, tp.time, true);
        else if (ready) loadChapter(ci, 0, true);
        else toast("This section is still being generated…");
      });
      nav.appendChild(t);
    });
  });
  markCurrentChapter();
}

function markCurrentChapter() {
  $$("#outline .ch").forEach((el) =>
    el.classList.toggle("current", Number(el.dataset.ci) === state.ci));
}

let pendingSeek = 0, pendingPlay = false;

function loadChapter(ci, seekTime = 0, autoplay = false) {
  const chapters = state.manifest.chapters;
  if (ci < 0 || ci >= chapters.length) return;
  const ch = chapters[ci];
  if (!isReady(ch)) { toast("That chapter isn't ready yet."); return; }
  state.waitingForNext = null;
  state.pendingInitial = false;
  state.ci = ci;
  state.sentences = ch.sentences || [];
  state.activeSi = -1;

  audio.src = `/media/${state.bookId}/${ch.audio}`;
  audio.load();
  pendingSeek = seekTime; pendingPlay = autoplay;

  renderChapterText(ch);
  applyHighlights();
  markCurrentChapter();
  $("#npChapter").textContent = ch.title;
  $("#chapterHeader").innerHTML =
    `<h2>${escapeHtml(ch.title)}</h2><div class="sub">Chapter ${ci + 1} of ${chapters.length} · ${fmtTime(ch.duration)}</div>`;
  $("#content").scrollTop = 0;
  savePos();
  updateMediaSessionMetadata();
}

function renderChapterText(ch) {
  const reader = $("#reader");
  reader.innerHTML = "";
  hideNotePopover();
  state.spanEls = [];
  let p = document.createElement("p");
  (ch.sentences || []).forEach((sent) => {
    const span = document.createElement("span");
    span.className = "sent";
    span.dataset.si = sent.i;
    span.textContent = sent.t + " ";
    span.addEventListener("click", () => {
      if (!window.getSelection().isCollapsed) return;  // a drag-select just happened — don't seek
      seekTo(sent.s, true);
    });
    p.appendChild(span);
    state.spanEls[sent.i] = span;
    if (sent.p) { reader.appendChild(p); p = document.createElement("p"); }
  });
  if (p.childNodes.length) reader.appendChild(p);
}

/* -------------------------------------------------------- playback sync */
function findActiveIndex(t) {
  const s = state.sentences;
  let lo = 0, hi = s.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (s[mid].s <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
  }
  return ans;
}

function setActiveSentence(si) {
  if (si === state.activeSi) return;
  if (state.activeSi >= 0 && state.spanEls[state.activeSi])
    state.spanEls[state.activeSi].classList.remove("active");
  state.activeSi = si;
  if (si < 0) return;
  const el = state.spanEls[si];
  if (el) {
    el.classList.add("active");
    scrollIntoViewIfNeeded(el);
    $("#npSentence").textContent = state.sentences[si].t;
  }
  // Per-sentence progress: record + cloud-mirror the moment the active sentence advances
  // (not while scrubbing — the 'change' handler saves the landing spot instead).
  if (!state.isScrubbing) savePos();
}

function scrollIntoViewIfNeeded(el) {
  const container = $("#content");
  const cr = container.getBoundingClientRect();
  const er = el.getBoundingClientRect();
  if (er.top < cr.top + 80 || er.bottom > cr.bottom - 80) {
    el.scrollIntoView({ block: "center", behavior: "smooth" });
  }
}

let saveTick = 0;
audio.addEventListener("timeupdate", () => {
  const t = audio.currentTime;
  if (!state.isScrubbing) {
    $("#seekBar").value = t;
    $("#curTime").textContent = fmtTime(t);
  }
  setActiveSentence(findActiveIndex(t));
  if (++saveTick % 12 === 0) { savePos(); updateMediaPosition(); }
});

audio.addEventListener("loadedmetadata", () => {
  const dur = isFinite(audio.duration) ? audio.duration : state.manifest.chapters[state.ci].duration;
  $("#seekBar").max = dur;
  $("#durTime").textContent = fmtTime(dur);
  audio.playbackRate = Number($("#rateSelect").value);
  audio.volume = Number($("#volBar").value);
  if (pendingSeek > 0) audio.currentTime = Math.min(pendingSeek, dur - 0.1);
  if (pendingPlay) audio.play().catch(() => {});
  pendingSeek = 0; pendingPlay = false;
});

audio.addEventListener("play", () => { $("#playBtn").innerHTML = icon("pause"); });
audio.addEventListener("pause", () => { $("#playBtn").innerHTML = icon("play"); savePos(); window.abkSync?.flushProgress?.(); });
audio.addEventListener("ended", () => {
  savePos();
  if (sleepTimer.endOfChapter) {
    resetSleep();
    toast("End of chapter — paused.");
    return;                       // sleep armed for chapter-end: stop instead of advancing
  }
  const next = state.ci + 1;
  if (next >= state.manifest.chapters.length) return;
  if (isReady(state.manifest.chapters[next])) {
    loadChapter(next, 0, true);
  } else {
    state.waitingForNext = next;
    toast("Waiting for the next chapter to finish generating…");
    startGenPoll(state.bookId);
  }
});

function seekTo(t, play = false) {
  exitFollow();   // any deliberate seek is a take-over from cross-device follow
  if (isFinite(audio.duration)) {
    audio.currentTime = Math.min(t, audio.duration - 0.05);
    if (play && audio.paused) audio.play().catch(() => {});
  } else {
    pendingSeek = t; pendingPlay = play;
  }
}

/* --------------------------------------------------------------- transport */
$("#playBtn").addEventListener("click", () => { exitFollow(); audio.paused ? audio.play() : audio.pause(); });
$("#back10Btn").addEventListener("click", () => seekTo(Math.max(0, audio.currentTime - 10)));
$("#fwd10Btn").addEventListener("click", () => seekTo(audio.currentTime + 10));
$("#prevChBtn").addEventListener("click", () => { exitFollow(); loadChapter(state.ci - 1, 0, true); });
$("#nextChBtn").addEventListener("click", () => { exitFollow(); loadChapter(state.ci + 1, 0, true); });
$("#backBtn").addEventListener("click", showLibrary);

const seekBar = $("#seekBar");
seekBar.addEventListener("input", () => {
  state.isScrubbing = true;
  $("#curTime").textContent = fmtTime(Number(seekBar.value));
});
seekBar.addEventListener("change", () => {
  exitFollow();   // scrubbing is a take-over from cross-device follow
  audio.currentTime = Number(seekBar.value);
  state.isScrubbing = false;
  savePos();   // capture the landing spot immediately (per-sentence sync included)
});

$("#rateSelect").addEventListener("change", (e) => {
  audio.playbackRate = Number(e.target.value);
  localStorage.setItem("abk:rate", e.target.value);
});
$("#volBar").addEventListener("input", (e) => {
  audio.volume = Number(e.target.value);
  localStorage.setItem("abk:vol", e.target.value);
  // If a sleep countdown is running, treat the new level as the volume to fade from.
  if (sleepTimer.deadline) sleepTimer.baseVol = Number(e.target.value);
});

/* --------------------------------------------------------------- sleep timer */
// Pause playback after a chosen delay (or at the end of the current chapter). The last
// few seconds fade the volume down so it doesn't cut off abruptly. Session-only — a
// fresh book or a return to the library disarms it. Counts real time, like Audible.
const sleepTimer = { deadline: 0, endOfChapter: false, ticker: null, baseVol: 1 };
const sleepSelect = $("#sleepSelect");
const sleepLeft = $("#sleepLeft");
const SLEEP_FADE_MS = 5000;

function disarmSleep() {
  if (sleepTimer.ticker) { clearInterval(sleepTimer.ticker); sleepTimer.ticker = null; }
  // Undo a fade in progress so the next play isn't unexpectedly quiet.
  if (sleepTimer.deadline && audio.volume < sleepTimer.baseVol) audio.volume = sleepTimer.baseVol;
  sleepTimer.deadline = 0;
  sleepTimer.endOfChapter = false;
  sleepLeft.hidden = true;
  sleepLeft.textContent = "";
}
// Disarm and snap the menu back to "Off" (e.g. on book switch or after firing).
function resetSleep() { disarmSleep(); sleepSelect.value = "0"; }

function tickSleep() {
  const ms = sleepTimer.deadline - Date.now();
  if (ms <= 0) { fireSleep(); return; }
  if (ms < SLEEP_FADE_MS && !audio.paused) audio.volume = Math.max(0, sleepTimer.baseVol * (ms / SLEEP_FADE_MS));
  sleepLeft.textContent = fmtTime(ms / 1000);
}

function fireSleep() {
  const base = sleepTimer.baseVol;
  disarmSleep();
  audio.pause();
  audio.volume = base;          // restore so the next play is at full volume
  $("#volBar").value = base;
  sleepSelect.value = "0";
  toast("Sleep timer reached — paused.");
}

sleepSelect.addEventListener("change", (e) => {
  const v = e.target.value;
  disarmSleep();
  if (v === "0") return;
  if (v === "chapter") {
    sleepTimer.endOfChapter = true;
    toast("Will pause at the end of this chapter.");
    return;
  }
  sleepTimer.baseVol = audio.volume;
  sleepTimer.deadline = Date.now() + Number(v) * 60000;
  sleepLeft.hidden = false;
  tickSleep();
  sleepTimer.ticker = setInterval(tickSleep, 1000);
});

/* ------------------------------------------------------------------ search */
function buildSearchIndex() {
  const items = [];
  state.manifest.chapters.forEach((ch, ci) => {
    items.push({ type: "nav", ci, time: 0, title: ch.title, text: ch.title, lc: ch.title.toLowerCase() });
    (ch.topics || []).forEach((tp) =>
      items.push({ type: "nav", ci, time: tp.time, title: tp.title, text: tp.title, lc: tp.title.toLowerCase() }));
    (ch.sentences || []).forEach((s) =>
      items.push({ type: "line", ci, time: s.s, title: ch.title, text: s.t, lc: s.t.toLowerCase() }));
  });
  state.searchItems = items;
}

const runSearch = debounce((q) => {
  const box = $("#searchResults");
  q = q.trim().toLowerCase();
  if (!q) { box.hidden = true; box.innerHTML = ""; return; }
  const navHits = [], lineHits = [];
  for (const it of state.searchItems) {
    const idx = it.lc.indexOf(q);
    if (idx < 0) continue;
    (it.type === "nav" ? navHits : lineHits).push({ it, idx });
    if (navHits.length + lineHits.length > 200) break;
  }
  const hits = navHits.concat(lineHits).slice(0, 60);
  box.hidden = false;
  if (!hits.length) { box.innerHTML = `<div class="none">No matches for “${escapeHtml(q)}”.</div>`; return; }
  box.innerHTML = hits.map(({ it, idx }) => {
    const t = it.text;
    const a = Math.max(0, idx - 30), b = Math.min(t.length, idx + q.length + 50);
    const snip = (a > 0 ? "…" : "") +
      escapeHtml(t.slice(a, idx)) + "<mark>" + escapeHtml(t.slice(idx, idx + q.length)) +
      "</mark>" + escapeHtml(t.slice(idx + q.length, b)) + (b < t.length ? "…" : "");
    const loc = (it.type === "nav" ? icon("chevron-right", "loc-ico") + " " : "") +
      escapeHtml(state.manifest.chapters[it.ci].title) + " · " + fmtTime(it.time);
    return `<div class="res" data-ci="${it.ci}" data-time="${it.time}">
              <div class="loc">${loc}</div><div>${snip}</div></div>`;
  }).join("");
  $$(".res", box).forEach((el) => el.addEventListener("click", () =>
    loadChapter(Number(el.dataset.ci), Number(el.dataset.time), true)));
}, 160);

$("#searchInput").addEventListener("input", (e) => runSearch(e.target.value));
$("#searchClear").addEventListener("click", clearSearch);
function clearSearch() {
  $("#searchInput").value = "";
  $("#searchResults").hidden = true;
  $("#searchResults").innerHTML = "";
}

/* ------------------------------------------------------------- persistence */
// Resume points live only in Firestore as { ci, t, si, frac, updated } (chapter index, in-chapter
// seconds, active sentence, overall progress 0..1, and a save timestamp used to order the
// "Continue listening" card). There is no localStorage copy — Firestore's offline cache is the
// local store, so resume + realtime cross-device follow run off one mechanism (see sync.js).
// Seconds of audio before chapter `ci` in playback (array) order. We sum durations rather
// than trust each chapter's `start_global`, which reflects *generation* order and is wrong
// for books built with --resume (a regenerated chapter carries a later run's offset).
function chapterStart(m, ci) {
  let s = 0;
  for (let i = 0; i < ci && i < m.chapters.length; i++) s += m.chapters[i].duration || 0;
  return s;
}

function savePos() {
  if (!state.bookId || state.ci < 0 || !state.manifest) return;
  if (state.following) return;   // mirroring another device — don't claim its spot as ours
  const m = state.manifest;
  // While restoring (before loadedmetadata seeks) audio.currentTime is still 0 but the
  // intended time lives in pendingSeek — prefer it so we never clobber a good position.
  const t = audio.currentTime || pendingSeek || 0;
  const total = m.total_duration || 0;
  const frac = total > 0 ? Math.min(1, (chapterStart(m, state.ci) + t) / total) : 0;
  // The active sentence — the per-sentence granularity we sync. Fall back to a lookup when
  // playback hasn't set one yet (e.g. saving right after a seek/restore).
  const si = state.activeSi >= 0 ? state.activeSi : Math.max(0, findActiveIndex(t));
  const updated = Date.now();
  state.localUpdated = updated;
  const pos = { ci: state.ci, t, si, frac, updated };
  // Single source of truth: Firestore (debounced/coalesced in sync.js, with an offline cache) —
  // there is no localStorage copy; the on-disk cache IS the local copy. `device`/`deviceName`
  // stamp who wrote it, so other devices ignore our echo and can label the "playing on…" banner.
  window.abkSync?.pushProgress?.(state.bookId, { ...pos, device: DEVICE_ID, deviceName: DEVICE_NAME });
}
// Resume point comes only from Firestore now (mirrored into state.remotePos: cache-first at open
// time, then kept live by the realtime listener). No localStorage — the offline cache is the
// local copy. Empty object when we have nothing for this book yet.
function loadPos(bookId) {
  const remote = state.remotePos[bookId];
  if (remote && remote.updated != null) {
    return { ci: remote.ci, t: remote.t, si: remote.si, frac: remote.frac, updated: remote.updated };
  }
  return {};
}
window.addEventListener("beforeunload", () => { savePos(); window.abkSync?.flushProgress?.(); });
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { savePos(); window.abkSync?.flushProgress?.(); }
});

/* --------------------------------------------------------------- bookmarks */
// Per-book bookmarks in localStorage as [{ ci, t, ch, snip, created }] — the chapter index,
// in-chapter seconds, chapter title, and the sentence at that spot for a readable label.
function bmKey(id) { return `abk:bm:${id}`; }
function loadBookmarks(id) {
  try { return JSON.parse(localStorage.getItem(bmKey(id))) || []; } catch { return []; }
}
function saveBookmarks(id, list) { localStorage.setItem(bmKey(id), JSON.stringify(list)); }

function addBookmark() {
  if (!state.bookId || state.ci < 0 || !state.manifest) return;
  const t = audio.currentTime || pendingSeek || 0;
  const ch = state.manifest.chapters[state.ci];
  let si = state.activeSi < 0 ? findActiveIndex(t) : state.activeSi;
  const snip = (state.sentences[si] || {}).t || "";
  const list = loadBookmarks(state.bookId);
  list.push({ ci: state.ci, t, ch: ch.title, snip, created: Date.now() });
  list.sort((a, b) => (a.ci - b.ci) || (a.t - b.t));   // keep in reading order
  saveBookmarks(state.bookId, list);
  renderBookmarks();
  toast("Bookmark added.");
}

function renderBookmarks() {
  const panel = $("#bookmarksPanel");
  const list = state.bookId ? loadBookmarks(state.bookId) : [];
  if (!list.length) { panel.hidden = true; panel.innerHTML = ""; return; }
  panel.hidden = false;
  panel.innerHTML = `<div class="bm-head">${icon("bookmark")} Bookmarks · ${list.length}</div>` +
    list.map((b, i) => `
      <div class="bm" data-idx="${i}">
        <div class="bm-main">
          <div class="bm-loc">${escapeHtml(b.ch || "")} · ${fmtTime(b.t)}</div>
          ${b.snip ? `<div class="bm-snip">${escapeHtml(b.snip)}</div>` : ""}
        </div>
        <button class="bm-del" title="Remove bookmark">${icon("x")}</button>
      </div>`).join("");
  $$(".bm", panel).forEach((el) => {
    const i = Number(el.dataset.idx);
    el.addEventListener("click", () => {
      const b = loadBookmarks(state.bookId)[i];
      if (b) loadChapter(b.ci, b.t, true);
    });
    el.querySelector(".bm-del").addEventListener("click", (e) => {
      e.stopPropagation();
      const arr = loadBookmarks(state.bookId);
      arr.splice(i, 1);
      saveBookmarks(state.bookId, arr);
      renderBookmarks();
    });
  });
}
$("#bookmarkBtn").addEventListener("click", addBookmark);

/* ------------------------------------------------------------------- notes */
// Notes are server-backed (a sibling notes.json per book — see app/notes.py). Each note
// anchors to a sentence range [si..sj] with a durable text quote (exact/prefix/suffix) plus
// fast-path hints (si/sj, cs/ce, s/e). A "highlight" is a note with an empty body.
const NOTE_COLORS = ["yellow", "green", "blue", "pink", "purple"];
const noteColor = (c) => (NOTE_COLORS.includes(c) ? c : "yellow");

async function loadNotes(bookId) {
  try {
    const { notes } = await api(`/api/books/${bookId}/notes`);
    state.notes = Array.isArray(notes) ? notes : [];
  } catch { state.notes = []; }
  renderNotes();
}
const notesForChapter = (ci) => state.notes.filter((n) => n.ch === ci);

/* --- re-anchoring: map a note's stored quote back onto the current chapter's sentences --- */
function joinSentences(a, b) {
  const s = state.sentences;
  if (a < 0 || b >= s.length || a > b) return null;
  const out = [];
  for (let i = a; i <= b; i++) out.push(s[i].t);
  return out.join(" ");
}
// Returns {si, sj} for the note in the current chapter, or null if it can't be placed
// (orphan — still listed in the panel, just not painted). `recon`/`starts` are the
// reconstructed chapter text + per-sentence start offsets, built once per applyHighlights.
function reanchor(note, recon, starts) {
  const exact = (note.exact || "").trim();
  const inRange = note.si >= 0 && note.sj < state.sentences.length && note.si <= note.sj;
  if (!exact) return inRange ? { si: note.si, sj: note.sj } : null;
  if (inRange && joinSentences(note.si, note.sj) === exact) return { si: note.si, sj: note.sj };
  let idx = recon.indexOf(exact);
  if (idx < 0) return null;
  if (note.prefix || note.suffix) {                     // disambiguate repeated quotes
    const norm = (x) => x.replace(/\s+/g, " ").trim();  // tolerate separator whitespace
    const wantPre = norm(note.prefix || ""), wantSuf = norm(note.suffix || "");
    for (let p = idx; p >= 0; p = recon.indexOf(exact, p + 1)) {
      const pre = norm(recon.slice(Math.max(0, p - wantPre.length - 4), p));
      const suf = norm(recon.slice(p + exact.length, p + exact.length + wantSuf.length + 4));
      if ((!wantPre || pre.endsWith(wantPre)) && (!wantSuf || suf.startsWith(wantSuf))) { idx = p; break; }
    }
  }
  const end = idx + exact.length;
  let si = 0, sj = 0;
  for (let i = 0; i < starts.length; i++) {
    if (starts[i] <= idx) si = i;
    if (starts[i] < end) sj = i;
  }
  return { si, sj };
}

// Paint highlight washes + note markers onto the current chapter's spans.
function applyHighlights() {
  $$("#reader .note-marker").forEach((m) => m.remove());
  state.spanEls.forEach((el) => { if (el) el.className = "sent"; });
  const chNotes = notesForChapter(state.ci);
  if (chNotes.length) {
    const starts = []; let acc = 0;
    const recon = state.sentences.map((s, i) => { starts[i] = acc; acc += s.t.length + 1; return s.t; }).join(" ");
    for (const note of chNotes) {
      const a = reanchor(note, recon, starts);
      note._orphan = !a;
      if (!a) continue;
      const cls = "hl-" + noteColor(note.color);
      for (let i = a.si; i <= a.sj && i < state.spanEls.length; i++) {
        if (state.spanEls[i]) state.spanEls[i].classList.add(cls);
      }
      if ((note.note || "").trim()) {
        if (state.spanEls[a.si]) state.spanEls[a.si].classList.add("has-note");
        const last = state.spanEls[a.sj];
        if (last) {
          const mark = document.createElement("sup");
          mark.className = "note-marker";
          mark.innerHTML = icon("pen");
          mark.title = "Edit note";
          mark.addEventListener("click", (e) => { e.stopPropagation(); openNoteEditor({ note }); });
          last.after(mark);
        }
      }
    }
  }
  // Restore the karaoke class on whatever sentence is currently playing (.active wins by
  // source order over any highlight on the same span).
  if (state.activeSi >= 0 && state.spanEls[state.activeSi]) state.spanEls[state.activeSi].classList.add("active");
}

/* --- selecting text → a floating popover --- */
function selectionToAnchor() {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
  const range = sel.getRangeAt(0);
  const reader = $("#reader");
  if (!reader.contains(range.commonAncestorContainer)) return null;
  let si = -1, sj = -1;
  state.spanEls.forEach((el, i) => {
    if (el && range.intersectsNode(el)) { if (si < 0) si = i; sj = i; }
  });
  if (si < 0) return null;
  return buildAnchor(si, sj, range.getBoundingClientRect());
}

function buildAnchor(si, sj, rect) {
  const s = state.sentences;
  if (si < 0 || sj >= s.length || si > sj) return null;
  const exact = [];
  for (let i = si; i <= sj; i++) exact.push(s[i].t);
  return {
    ch: state.ci, si, sj, cs: s[si].cs, ce: s[sj].ce, s: s[si].s, e: s[sj].e,
    exact: exact.join(" "),
    prefix: s.slice(Math.max(0, si - 3), si).map((x) => x.t).join(" ").slice(-32),
    suffix: s.slice(sj + 1, sj + 4).map((x) => x.t).join(" ").slice(0, 32),
    rect,
  };
}
const anchorPayload = (a) =>
  ({ ch: a.ch, si: a.si, sj: a.sj, cs: a.cs, ce: a.ce, s: a.s, e: a.e,
     exact: a.exact, prefix: a.prefix, suffix: a.suffix });

let popoverAnchor = null;
function showNotePopover(anchor) {
  popoverAnchor = anchor;
  const pop = $("#notePopover");
  pop.hidden = false;
  const r = anchor.rect || { left: 0, top: 0, width: 0, height: 0, bottom: 0 };
  const pw = pop.offsetWidth || 240, ph = pop.offsetHeight || 36;
  let left = Math.max(8, Math.min(r.left + r.width / 2 - pw / 2, window.innerWidth - pw - 8));
  let top = r.top - ph - 8;
  if (top < 8) top = r.bottom + 8;              // flip below when there's no room above
  pop.style.left = left + "px";
  pop.style.top = top + "px";
}
function hideNotePopover() { const p = $("#notePopover"); if (p) p.hidden = true; popoverAnchor = null; }

function refreshSelectionPopover() {
  if ($("#readerView").hidden || !$("#noteEditor").hidden) return;
  const anchor = selectionToAnchor();
  if (anchor) showNotePopover(anchor); else hideNotePopover();
}
document.addEventListener("selectionchange", debounce(refreshSelectionPopover, 180));
$("#reader").addEventListener("mouseup", () => setTimeout(refreshSelectionPopover, 0));
$("#content").addEventListener("scroll", () => { if (!$("#notePopover").hidden) hideNotePopover(); });

// mousedown + preventDefault: act before the click collapses the selection.
$$("#notePopover .np-sw").forEach((btn) => btn.addEventListener("mousedown", (e) => {
  e.preventDefault();
  if (popoverAnchor) createHighlight(popoverAnchor, btn.dataset.color);
}));
$("#notePopNote").addEventListener("mousedown", (e) => {
  e.preventDefault();
  const a = popoverAnchor;
  hideNotePopover();
  if (a) openNoteEditor({ draft: a });
});

/* --- create / persist --- */
async function saveNewNote(payload) {
  const on = signedIn();
  const now = window.abkSync?.isoNow ? window.abkSync.isoNow() : new Date().toISOString().replace(/\.\d+Z$/, "Z");
  const tags = Array.isArray(payload.tags) ? payload.tags : parseTags(payload.tags || "");
  const kind = (payload.note || "").trim() ? "note" : "highlight";
  // When signed in, mint the id client-side so notes.json and the Firestore doc share it
  // (POST /notes reassigns ids; POST /notes/sync honors ours). Offline keeps the tmp: id.
  const id = on ? (crypto.randomUUID ? crypto.randomUUID()
                                     : "n" + Date.now().toString(36) + Math.random().toString(16).slice(2))
                : "tmp:" + Date.now();
  const temp = { ...payload, id, tags, kind, created: now, updated: now };
  state.notes.push(temp);
  applyHighlights(); renderNotes();
  try {
    let saved;
    if (on) {
      const record = { ...payload, tags, id, kind, created: now, updated: now };
      const res = await api(`/api/books/${state.bookId}/notes/sync`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ notes: [record] }),
      });
      saved = (res.notes || []).find((n) => n.id === id) || record;
      await window.abkSync.putNote(state.bookId, saved);
    } else {
      saved = await api(`/api/books/${state.bookId}/notes`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
      });
    }
    const i = state.notes.findIndex((n) => n.id === id);
    if (i >= 0) state.notes[i] = saved; else state.notes.push(saved);
    toast(kind === "note" ? "Note saved." : "Highlighted.");
  } catch (e) {
    state.notes = state.notes.filter((n) => n.id !== id);
    toast("Couldn't save note: " + (e.message || "error"));
  }
  applyHighlights(); renderNotes();
}
function createHighlight(anchor, color) {
  window.getSelection().removeAllRanges();
  hideNotePopover();
  saveNewNote({ ...anchorPayload(anchor), color: noteColor(color), note: "" });
}

/* --- the note editor --- */
let editingNote = null;   // note being edited, or null when creating
let editorDraft = null;   // anchor when creating
let editorColor = "yellow";

function syncEditorSwatches() {
  $$("#noteSwatches .sw").forEach((b) => b.classList.toggle("active", b.dataset.color === editorColor));
}
$$("#noteSwatches .sw").forEach((b) =>
  b.addEventListener("click", () => { editorColor = b.dataset.color; syncEditorSwatches(); }));

function openNoteEditor(target) {
  window.getSelection().removeAllRanges();
  hideNotePopover();
  editingNote = target.note || null;
  editorDraft = target.draft || null;
  const n = editingNote, a = editorDraft;
  const quote = (n ? n.exact : a ? a.exact : "") || "";
  const q = $("#noteQuote");
  q.hidden = !quote; q.textContent = quote;
  const ci = n ? n.ch : a ? a.ch : state.ci;
  const sec = n ? n.s : a ? a.s : 0;
  const chTitle = (state.manifest.chapters[ci] || {}).title || `Chapter ${ci + 1}`;
  $("#noteLoc").textContent = `${chTitle} · ${fmtTime(sec)}`;
  $("#noteBody").value = n ? (n.note || "") : "";
  $("#noteTags").value = n ? (n.tags || []).join(", ") : "";
  editorColor = noteColor(n ? n.color : "yellow");
  syncEditorSwatches();
  $("#noteEditorTitle").textContent = n ? "Edit note" : "Add note";
  $("#noteDelete").hidden = !n;
  $("#noteEditor").hidden = false;
  setTimeout(() => $("#noteBody").focus(), 0);
}
function closeNoteEditor() { $("#noteEditor").hidden = true; editingNote = null; editorDraft = null; }

async function saveNoteEditor() {
  const body = $("#noteBody").value;
  const tags = $("#noteTags").value;
  if (editingNote) {
    const id = editingNote.id;
    const idx = state.notes.findIndex((n) => n.id === id);
    if (idx >= 0) state.notes[idx] = { ...state.notes[idx], note: body, color: editorColor,
      tags: parseTags(tags), kind: body.trim() ? "note" : "highlight" };
    closeNoteEditor(); applyHighlights(); renderNotes();
    if (String(id).startsWith("tmp:")) return;   // not persisted yet; optimistic copy stands
    try {
      const saved = await api(`/api/books/${state.bookId}/notes/${id}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ note: body, tags, color: editorColor }),
      });
      const i = state.notes.findIndex((n) => n.id === id);
      if (i >= 0) state.notes[i] = saved;
      applyHighlights(); renderNotes();
      if (signedIn()) await window.abkSync.putNote(state.bookId, saved);
    } catch (e) { toast("Couldn't update note: " + (e.message || "error")); loadNotes(state.bookId); }
  } else if (editorDraft) {
    const a = editorDraft;
    closeNoteEditor();
    await saveNewNote({ ...anchorPayload(a), color: editorColor, note: body, tags });
  } else {
    closeNoteEditor();
  }
}
const parseTags = (v) =>
  String(v || "").split(/[,\n]+/).map((t) => t.trim().replace(/^#/, "")).filter(Boolean);

async function removeNote(note) {
  if (!note) return;
  const id = note.id;
  if ((note.note || "").trim() && !confirm("Delete this note?")) return;
  state.notes = state.notes.filter((n) => n.id !== id);
  if (editingNote && editingNote.id === id) closeNoteEditor();
  applyHighlights(); renderNotes();
  if (String(id).startsWith("tmp:")) return;
  try { await api(`/api/books/${state.bookId}/notes/${id}`, { method: "DELETE" }); }
  catch (e) { toast("Couldn't delete note: " + (e.message || "error")); loadNotes(state.bookId); }
  if (signedIn()) window.abkSync.deleteNote(state.bookId, id);   // soft-delete tombstone for peers
}

$("#noteSave").addEventListener("click", saveNoteEditor);
$("#noteCancel").addEventListener("click", closeNoteEditor);
$("#noteDelete").addEventListener("click", () => removeNote(editingNote));
$("#noteEditor").addEventListener("click", (e) => { if (e.target.id === "noteEditor") closeNoteEditor(); });

/* --- note at the current playback spot (great while listening) --- */
function startNoteAtCurrent() {
  if (!state.bookId || state.ci < 0 || !state.sentences.length) { toast("Open a chapter first."); return; }
  let si = state.activeSi >= 0 ? state.activeSi : findActiveIndex(audio.currentTime);
  if (si < 0) si = 0;
  const anchor = buildAnchor(si, si, null);
  if (anchor) openNoteEditor({ draft: anchor });
}
$("#noteBtn").addEventListener("click", startNoteAtCurrent);

/* --- the sidebar notes panel --- */
function jumpToNote(n) {
  const ch = state.manifest.chapters[n.ch];
  if (!ch) { toast("That chapter isn't in this book anymore."); return; }
  if (!isReady(ch)) { toast("That chapter isn't ready yet."); return; }
  loadChapter(n.ch, n.s || 0, true);
  setTimeout(() => { const el = state.spanEls[n.si]; if (el) scrollIntoViewIfNeeded(el); }, 150);
}

function renderNotes() {
  const panel = $("#notesPanel");
  const list = state.bookId
    ? [...state.notes].sort((a, b) => (a.ch - b.ch) || (a.si - b.si) || (a.s - b.s)) : [];
  if (!list.length) { panel.hidden = true; panel.innerHTML = ""; return; }
  panel.hidden = false;
  panel.innerHTML =
    `<div class="np-head"><span class="np-head-title">${icon("note")} Notes · ${list.length}</span><button class="np-export text-icon" title="Export notes">${icon("download")} Export</button></div>` +
    list.map((n) => {
      const chTitle = (state.manifest.chapters[n.ch] || {}).title || `Chapter ${n.ch + 1}`;
      const body = (n.note || "").trim();
      const tags = (n.tags || []).map((t) => `<span class="tag">#${escapeHtml(t)}</span>`).join("");
      return `<div class="note" data-id="${escapeHtml(n.id)}">
        <span class="note-chip np-${noteColor(n.color)}"></span>
        <div class="note-main">
          ${n.exact ? `<div class="note-quote">${escapeHtml(n.exact)}</div>` : ""}
          ${body ? `<div class="note-body">${escapeHtml(body)}</div>` : ""}
          <div class="note-loc">${escapeHtml(chTitle)} · ${fmtTime(n.s)}</div>
          ${tags ? `<div class="note-tags">${tags}</div>` : ""}
          ${n._orphan ? `<div class="note-orphan text-icon">${icon("alert")} passage moved — jump by time</div>` : ""}
        </div>
        <button class="note-del" title="Delete note">${icon("x")}</button>
      </div>`;
    }).join("");
  $(".np-export", panel).addEventListener("click", (e) => {
    e.stopPropagation();
    buildExportMenu();
    $("#exportMenu").hidden = false;
  });
  $$(".note", panel).forEach((el) => {
    const n = state.notes.find((x) => x.id === el.dataset.id);
    el.addEventListener("click", () => { if (n) jumpToNote(n); });
    el.querySelector(".note-del").addEventListener("click", (e) => { e.stopPropagation(); removeNote(n); });
  });
}

/* ------------------------------------------------------------ cloud sync */
// Optional Firebase sync (see web/sync.js). When signed in, Firestore is the shared source of
// truth for progress + notes and notes.json is kept as an identical mirror (so exports/.abk
// keep working). Everything here is a no-op when signed out — the app stays fully local.
const noteStamp = (n) => String((n && (n.updated || n.created)) || "");
const notesSig = (list) => (list || []).map((n) => n.id + ":" + noteStamp(n)).sort().join("|");

// Merge two note lists by id, newest `updated` wins (ties → `b`); split into live notes and
// the ids whose winner is a soft-delete tombstone. Mirrors app/notes.py merge_notes semantics.
function mergeNotesById(a, b) {
  const win = new Map();
  const consider = (n) => {
    if (!n || !n.id) return;
    const prev = win.get(n.id);
    if (!prev || noteStamp(n) >= noteStamp(prev)) win.set(n.id, n);
  };
  (a || []).forEach(consider);
  (b || []).forEach(consider);
  const live = [], deadIds = new Set();
  for (const n of win.values()) { if (n.deleted) deadIds.add(n.id); else live.push(n); }
  return { live, deadIds };
}

async function refreshRemoteProgress() {
  if (!signedIn()) { state.remotePos = {}; return; }
  try { state.remotePos = await window.abkSync.fetchAllProgress(); } catch { state.remotePos = {}; }
}

// One-time reconcile of a book's server notes.json with its Firestore notes, then keep both
// mirrored. Called when a signed-in user opens a book.
async function reconcileNotes(bookId) {
  if (!signedIn()) return;
  let serverNotes = [];
  try { serverNotes = (await api(`/api/books/${bookId}/notes`)).notes || []; } catch { serverNotes = []; }
  let remoteDocs = [];
  try { remoteDocs = await window.abkSync.fetchNotes(bookId); } catch { remoteDocs = []; }
  const { live, deadIds } = mergeNotesById(serverNotes, remoteDocs);
  const remoteById = new Map(remoteDocs.map((d) => [d.id, d]));
  // Firestore: push only the live winners that are missing or newer remotely; ensure a
  // tombstone for dead ids not already tombstoned. (Avoids re-writing every note each open.)
  await Promise.all(live.map((n) => {
    const r = remoteById.get(n.id);
    return (!r || noteStamp(r) < noteStamp(n)) ? window.abkSync.putNote(bookId, n) : null;
  }));
  await Promise.all([...deadIds].map((id) =>
    (remoteById.get(id) && remoteById.get(id).deleted) ? null : window.abkSync.deleteNote(bookId, id)));
  // Server notes.json: merge the live set in, and delete anything the merge marked dead.
  try {
    await api(`/api/books/${bookId}/notes/sync`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ notes: live }),
    });
  } catch (e) { /* server offline — Firestore still holds the truth */ }
  await Promise.all([...deadIds].map((id) =>
    fetch(`/api/books/${bookId}/notes/${id}`, { method: "DELETE" }).catch(() => {})));
  if (state.bookId === bookId) { state.notes = live; renderNotes(); applyHighlights(); }
}

// Live Firestore notes listener → reflect a peer's changes, mirroring them into notes.json.
function onRemoteNotes(bookId, docs) {
  if (state.bookId !== bookId) return;
  const { live, deadIds } = mergeNotesById(state.notes, docs);
  const changed = notesSig(live) !== notesSig(state.notes);
  const deletions = [...deadIds].filter((id) => state.notes.some((n) => n.id === id));
  if (!changed && !deletions.length) return;   // our own write echoed back — nothing to do
  deletions.forEach((id) => fetch(`/api/books/${bookId}/notes/${id}`, { method: "DELETE" }).catch(() => {}));
  state.notes = live;
  renderNotes(); applyHighlights();
  if (changed) api(`/api/books/${bookId}/notes/sync`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ notes: live }),
  }).catch(() => {});
}

// Live Firestore progress listener → cross-device auto-follow: when another device is actively
// playing and we're idle/paused, mirror its position live (karaoke highlight + scroll). Never
// hijacks our own playback.
function onRemoteProgress(bookId, rp) {
  if (!rp || state.bookId !== bookId) return;
  state.remotePos[bookId] = rp;
  if (rp.device === DEVICE_ID) return;                 // our own echo
  if ((rp.updated || 0) <= state.localUpdated) return; // not newer than what we've adopted/authored
  if (!audio.paused) return;                           // never hijack our own playback
  followRemote(rp);
}

// Mirror a remote position onto our (paused) view. state.following suppresses our own writes for
// the whole operation, so the seek's echo never bounces back as ours.
function followRemote(rp) {
  const ch = (state.manifest.chapters || [])[rp.ci];
  if (rp.ci != null && rp.ci !== state.ci && !isReady(ch)) return;  // can't mirror an unready chapter
  state.localUpdated = rp.updated || 0;
  setFollowing((Date.now() - (rp.updated || 0)) < FOLLOW_WINDOW_MS, rp.deviceName);
  if (rp.ci != null && rp.ci !== state.ci) {
    loadChapter(rp.ci, rp.t || 0, false);
  } else if (isFinite(audio.duration)) {
    audio.currentTime = Math.min(rp.t || 0, audio.duration - 0.05);
  } else {
    pendingSeek = rp.t || 0;
  }
  if (rp.si != null && rp.si >= 0) setActiveSentence(rp.si);
}

// Enter/refresh follow mode. Always suppresses our writes while mirroring; only shows the banner
// (and arms the stale timer) when the other device is actively playing (a fresh update). A
// non-fresh update is a silent resume-adopt — write-suppressed until we take over, no banner.
function setFollowing(fresh, deviceName) {
  state.following = true;
  clearTimeout(state.followTimer);
  if (fresh) {
    showFollowBanner(deviceName);
    state.followTimer = setTimeout(exitFollow, FOLLOW_WINDOW_MS);
  } else {
    hideFollowBanner();
  }
}

// Leave follow mode — the other device stopped updating, or we took over (any transport action).
function exitFollow() {
  clearTimeout(state.followTimer);
  state.followTimer = null;
  if (!state.following) return;
  state.following = false;
  hideFollowBanner();
}

function showFollowBanner(name) {
  const txt = $("#followText"), el = $("#followBanner");
  if (!el) return;
  if (txt) txt.textContent = `Playing on ${name || "another device"} — following live`;
  el.hidden = false;
}
function hideFollowBanner() { const el = $("#followBanner"); if (el) el.hidden = true; }

function teardownBookSync() {
  exitFollow();   // stop mirroring another device when we leave / switch books
  if (state.unsubProgress) { try { state.unsubProgress(); } catch (e) {} state.unsubProgress = null; }
  if (state.unsubNotes) { try { state.unsubNotes(); } catch (e) {} state.unsubNotes = null; }
}
async function setupBookSync(bookId) {
  teardownBookSync();
  if (!signedIn()) return;
  state.unsubProgress = window.abkSync.watchProgress(bookId, (rp) => onRemoteProgress(bookId, rp));
  await reconcileNotes(bookId);
  if (state.bookId === bookId)
    state.unsubNotes = window.abkSync.watchNotes(bookId, (docs) => onRemoteNotes(bookId, docs));
}

/* --- account / auth UI --- */
let authMode = "signin";   // "signin" | "signup" — which form the signed-out modal shows

function updateAccountUI() {
  const btn = $("#accountBtn");
  if (!btn) return;
  if (!window.abkSync || !window.abkSync.enabled) { btn.innerHTML = icon("cloud-off") + " Local"; btn.title = "Cloud sync isn't configured — running locally"; return; }
  if (hasAccount()) { btn.innerHTML = icon("cloud") + " " + escapeHtml(state.syncUser.email || "Synced"); btn.title = "Cloud sync on — click to manage"; }
  else { btn.innerHTML = icon("cloud") + " Sign in"; btn.title = "Sign in to sync progress & notes across devices"; }
}

// Reflect the sign-in / create-account choice across header, confirm field, submit label and
// the switch line. Called by the tab buttons and the switch link.
function setAuthMode(mode) {
  authMode = mode === "signup" ? "signup" : "signin";
  const up = authMode === "signup";
  document.querySelectorAll(".auth-tab").forEach((t) => t.classList.toggle("active", t.dataset.mode === authMode));
  $("#authTitle").textContent = up ? "Create your account" : "Welcome back";
  $("#authSubtitle").textContent = up
    ? "Sync your reading progress & notes across every device."
    : "Sign in to sync your progress & notes across devices.";
  $("#confirmField").hidden = !up;
  $("#acctSubmit").textContent = up ? "Create account" : "Sign in";
  $("#authSwitchText").textContent = up ? "Already have an account?" : "New to Audiobook Reader?";
  $("#authSwitchBtn").textContent = up ? "Sign in" : "Create an account";
  $("#acctPassword").setAttribute("autocomplete", up ? "new-password" : "current-password");
  $("#acctError").hidden = true;
}

function updateAccountModal() {
  const inEl = $("#acctSignedIn"), outEl = $("#acctSignedOut");
  if (!inEl || !outEl) return;
  const on = hasAccount();
  outEl.hidden = on; inEl.hidden = !on;
  if (on) $("#acctWho").textContent = state.syncUser.email || state.syncUser.uid;
}

function openAccountModal() {
  if (!window.abkSync || !window.abkSync.enabled) {
    toast("Cloud sync isn't configured. See the README ‘Optional cloud sync’ section.");
    return;
  }
  updateAccountModal();
  if (!hasAccount()) {
    setAuthMode("signin");
    $("#acctPassword").value = "";
    $("#acctConfirm").value = "";
  }
  $("#accountModal").hidden = false;
  if (!hasAccount()) setTimeout(() => $("#acctEmail").focus(), 0);
}
function closeAccountModal() { $("#accountModal").hidden = true; }

function togglePasswordVisibility() {
  const pw = $("#acctPassword"), cf = $("#acctConfirm"), btn = $("#pwToggle");
  const reveal = pw.type === "password";
  pw.type = cf.type = reveal ? "text" : "password";
  btn.textContent = reveal ? "Hide" : "Show";
  btn.setAttribute("aria-label", reveal ? "Hide password" : "Show password");
}

function authErrorText(e) {
  const c = (e && e.code) || "";
  if (c.includes("invalid-credential") || c.includes("wrong-password") || c.includes("user-not-found"))
    return "Wrong email or password.";
  if (c.includes("email-already-in-use")) return "That email already has an account — sign in instead.";
  if (c.includes("weak-password")) return "Password should be at least 6 characters.";
  if (c.includes("invalid-email")) return "That doesn't look like a valid email.";
  if (c.includes("too-many-requests")) return "Too many attempts — wait a moment and try again.";
  if (c.includes("network")) return "Network error — check your connection.";
  return (e && e.message) || "Couldn't sign in.";
}
function showAuthError(msg) { const el = $("#acctError"); el.textContent = msg; el.hidden = false; }

function setAuthBusy(busy) {
  const up = authMode === "signup";
  $("#acctSubmit").disabled = busy;
  $("#acctSubmit").textContent = busy ? (up ? "Creating account…" : "Signing in…") : (up ? "Create account" : "Sign in");
  $("#acctEmail").disabled = busy;
  $("#acctPassword").disabled = busy;
  $("#acctConfirm").disabled = busy;
  $("#pwToggle").disabled = busy;
  document.querySelectorAll(".auth-tab").forEach((t) => { t.disabled = busy; });
}

async function submitAuth() {
  const up = authMode === "signup";
  const email = $("#acctEmail").value.trim();
  const pw = $("#acctPassword").value;
  $("#acctError").hidden = true;
  if (!email || !pw) { showAuthError("Enter an email and password."); return; }
  if (up) {
    if (pw.length < 6) { showAuthError("Password should be at least 6 characters."); return; }
    if (pw !== $("#acctConfirm").value) { showAuthError("Those passwords don't match."); return; }
  }
  setAuthBusy(true);
  try {
    if (up) await window.abkSync.createAccount(email, pw);
    else await window.abkSync.signIn(email, pw);
    $("#acctPassword").value = "";
    $("#acctConfirm").value = "";
    closeAccountModal();
    toast(up ? "Account created — syncing progress & notes." : "Signed in — syncing progress & notes.");
  } catch (e) {
    showAuthError(authErrorText(e));
  } finally {
    setAuthBusy(false);
  }
}

async function doSignOut() {
  try { await window.abkSync.signOut(); } catch (e) {}
  closeAccountModal();
  toast("Signed out.");   // drops back to a fresh anonymous session (see sync.js)
}

// The inversion-of-control surface sync.js calls once auth resolves (see web/sync.js).
window.ABK = {
  onAuthChange(user) {
    state.syncUser = user;
    updateAccountUI();
    updateAccountModal();
    if (user) {
      refreshRemoteProgress().then(() => { if (!$("#libraryView").hidden) loadLibrary().catch(() => {}); });
      if (state.bookId) setupBookSync(state.bookId);
    } else {
      state.remotePos = {};
      teardownBookSync();
    }
  },
};

/* ----------------------------------------------------- OS media controls */
// Wire the page into the OS media session: lock-screen / notification controls, hardware
// media keys, Bluetooth & car controls, and a system scrubber — all feature-detected so
// browsers without the API are unaffected.
const hasMediaSession = "mediaSession" in navigator;

function setupMediaSession() {
  if (!hasMediaSession) return;
  const ms = navigator.mediaSession;
  const set = (action, fn) => { try { ms.setActionHandler(action, fn); } catch (e) { /* unsupported action */ } };
  set("play", () => { exitFollow(); audio.play().catch(() => {}); });
  set("pause", () => audio.pause());
  set("stop", () => audio.pause());
  set("seekbackward", (d) => seekTo(Math.max(0, audio.currentTime - (d.seekOffset || 10))));
  set("seekforward", (d) => seekTo(audio.currentTime + (d.seekOffset || 10)));
  set("previoustrack", () => { exitFollow(); loadChapter(state.ci - 1, 0, true); });
  set("nexttrack", () => { exitFollow(); loadChapter(state.ci + 1, 0, true); });
  set("seekto", (d) => {
    if (d.seekTime == null) return;
    if (d.fastSeek && audio.fastSeek) audio.fastSeek(d.seekTime);
    else audio.currentTime = d.seekTime;
    updateMediaPosition();
  });
}

function updateMediaPosition() {
  if (!hasMediaSession || !navigator.mediaSession.setPositionState) return;
  const d = audio.duration;
  if (!isFinite(d) || d <= 0) return;
  try {
    navigator.mediaSession.setPositionState({
      duration: d,
      playbackRate: audio.playbackRate || 1,
      position: Math.min(Math.max(0, audio.currentTime), d),
    });
  } catch (e) { /* invalid values mid-load — ignore */ }
}

// A small generated cover so the lock screen isn't blank: accent band + wrapped title + author.
function bookArtwork(m) {
  if (state.artworkFor === state.bookId && state.artworkUrl)
    return [{ src: state.artworkUrl, sizes: "512x512", type: "image/png" }];
  try {
    const c = document.createElement("canvas");
    c.width = c.height = 512;
    const x = c.getContext("2d");
    x.fillStyle = "#1e1e2e"; x.fillRect(0, 0, 512, 512);
    x.fillStyle = "#cba6f7"; x.fillRect(0, 0, 512, 96);
    x.fillStyle = "#cdd6f4"; x.textBaseline = "top";
    x.font = "bold 44px Georgia, serif";
    let y = 150;
    for (const line of wrapLines(x, m.title || "", 432, 5)) { x.fillText(line, 40, y); y += 56; }
    x.fillStyle = "#a6adc8"; x.font = "26px sans-serif";
    x.fillText((m.author || "").slice(0, 48), 40, 452);
    state.artworkUrl = c.toDataURL("image/png");
    state.artworkFor = state.bookId;
    return [{ src: state.artworkUrl, sizes: "512x512", type: "image/png" }];
  } catch (e) { return []; }
}
function wrapLines(ctx, text, maxW, maxLines) {
  const words = String(text).split(/\s+/).filter(Boolean);
  const lines = []; let line = "";
  for (const w of words) {
    const test = line ? line + " " + w : w;
    if (ctx.measureText(test).width > maxW && line) {
      lines.push(line); line = w;
      if (lines.length === maxLines - 1) break;
    } else line = test;
  }
  if (line && lines.length < maxLines) lines.push(line);
  return lines.length ? lines : [""];
}

function updateMediaSessionMetadata() {
  if (!hasMediaSession || !window.MediaMetadata) return;
  const m = state.manifest;
  if (!m || state.ci < 0) return;
  const ch = m.chapters[state.ci];
  try {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: ch ? ch.title : m.title,
      artist: m.author || "Audiobook",
      album: m.title || "",
      artwork: bookArtwork(m),
    });
  } catch (e) { /* ignore */ }
}

if (hasMediaSession) {
  audio.addEventListener("play", () => { navigator.mediaSession.playbackState = "playing"; updateMediaPosition(); });
  audio.addEventListener("pause", () => { navigator.mediaSession.playbackState = "paused"; });
  audio.addEventListener("loadedmetadata", updateMediaPosition);
  audio.addEventListener("ratechange", updateMediaPosition);
}

/* ------------------------------------------------------ display settings */
// Reading comfort: theme (dark/sepia/light, via a data-theme palette swap) and reader font
// size (a --reader-size CSS var). Both persist in localStorage and apply on load.
const THEMES = ["dark", "sepia", "light"];
const FONT_MIN = 15, FONT_MAX = 32;
let fontPx = 20;

function applyTheme(t) {
  if (!THEMES.includes(t)) t = "dark";
  document.documentElement.setAttribute("data-theme", t);
  localStorage.setItem("abk:theme", t);
  $$(".dm-theme").forEach((b) => b.classList.toggle("active", b.dataset.theme === t));
}
function applyFont(px) {
  px = Math.max(FONT_MIN, Math.min(FONT_MAX, Math.round(px)));
  fontPx = px;
  document.documentElement.style.setProperty("--reader-size", px + "px");
  localStorage.setItem("abk:reader-size", String(px));
  $("#fontVal").textContent = Math.round((px / 20) * 100) + "%";
}

$("#displayBtn").addEventListener("click", (e) => {
  e.stopPropagation();
  $("#displayMenu").hidden = !$("#displayMenu").hidden;
});
$$(".dm-theme").forEach((b) => b.addEventListener("click", () => applyTheme(b.dataset.theme)));
$("#fontUp").addEventListener("click", () => applyFont(fontPx + 2));
$("#fontDown").addEventListener("click", () => applyFont(fontPx - 2));
// Click anywhere outside the popover closes it.
document.addEventListener("click", (e) => {
  const menu = $("#displayMenu");
  if (!menu.hidden && !e.target.closest(".display-wrap")) menu.hidden = true;
});

/* --------------------------------------------------------------- export menu */
// Download a transcript (.txt) or synced subtitles (.srt/.vtt) — whole book or the
// current chapter — built server-side from the manifest's per-sentence timings.
function buildExportMenu() {
  const menu = $("#exportMenu");
  const id = state.bookId;
  if (!id) { menu.innerHTML = ""; return; }
  const rows = [
    `<div class="em-sep">Whole book</div>`,
    `<a download href="/api/books/${id}/transcript.txt">${icon("file-text")} Transcript (.txt)</a>`,
    `<a download href="/api/books/${id}/subtitles.vtt">${icon("captions")} Subtitles (.vtt)</a>`,
    `<a download href="/api/books/${id}/subtitles.srt">${icon("captions")} Subtitles (.srt)</a>`,
    `<div class="em-sep">Notes</div>`,
    `<a download href="/api/books/${id}/notes.md">${icon("note")} Notes (Markdown)</a>`,
    `<a download href="/api/books/${id}/notes.md?flavor=obsidian">${icon("sparkles")} Notes (Obsidian)</a>`,
  ];
  if (state.ci >= 0 && state.manifest && isReady(state.manifest.chapters[state.ci])) {
    rows.push(`<div class="em-sep">This chapter</div>`,
      `<a download href="/api/books/${id}/chapter/${state.ci}/subtitles.vtt">${icon("captions")} Chapter (.vtt)</a>`,
      `<a download href="/api/books/${id}/chapter/${state.ci}/subtitles.srt">${icon("captions")} Chapter (.srt)</a>`);
  }
  menu.innerHTML = rows.join("");
}
$("#exportBtn").addEventListener("click", (e) => {
  e.stopPropagation();
  const menu = $("#exportMenu");
  if (menu.hidden) { buildExportMenu(); menu.hidden = false; } else menu.hidden = true;
});
$("#exportMenu").addEventListener("click", (e) => { if (e.target.closest("a")) $("#exportMenu").hidden = true; });
document.addEventListener("click", (e) => {
  const menu = $("#exportMenu");
  if (!menu.hidden && !e.target.closest(".export-wrap")) menu.hidden = true;
});

/* ----------------------------------------------------------- reading mode */
// Full-screen, distraction-free reading: hide the topbar/sidebar/player and widen the text,
// while audio, the karaoke highlight and click-to-seek keep working on the same .sent spans.
// A floating control (play/pause · prev/next sentence · exit) auto-hides after a few idle
// seconds and reappears on any pointer/scroll activity. `f` toggles, `Esc` exits.
let readingHideTimer = null;
function enterReadingMode() {
  if (state.readingMode || !state.bookId || $("#readerView").hidden) return;
  state.readingMode = true;
  $("#app").classList.add("reading");
  $("#readingControls").hidden = false;
  showReadingControls();
  if (state.activeSi >= 0 && state.spanEls[state.activeSi]) scrollIntoViewIfNeeded(state.spanEls[state.activeSi]);
}
function exitReadingMode() {
  if (!state.readingMode) return;
  state.readingMode = false;
  $("#app").classList.remove("reading");
  $("#readingControls").hidden = true;
  clearTimeout(readingHideTimer);
}
function toggleReadingMode() { state.readingMode ? exitReadingMode() : enterReadingMode(); }
function showReadingControls() {
  if (!state.readingMode) return;
  $("#readingControls").classList.remove("faded");
  clearTimeout(readingHideTimer);
  readingHideTimer = setTimeout(() => { if (state.readingMode) $("#readingControls").classList.add("faded"); }, 3000);
}
["mousemove", "touchstart"].forEach((ev) =>
  document.addEventListener(ev, () => { if (state.readingMode) showReadingControls(); }, { passive: true }));

$("#readingBtn").addEventListener("click", toggleReadingMode);
$("#rcExit").addEventListener("click", exitReadingMode);
$("#rcPlay").addEventListener("click", () => audio.paused ? audio.play() : audio.pause());
$("#rcPrev").addEventListener("click", () => jumpSentence(-1));
$("#rcNext").addEventListener("click", () => jumpSentence(1));
audio.addEventListener("play", () => { const b = $("#rcPlay"); if (b) b.innerHTML = icon("pause"); });
audio.addEventListener("pause", () => { const b = $("#rcPlay"); if (b) b.innerHTML = icon("play"); });

/* --------------------------------------------------------- account button */
$("#accountBtn").addEventListener("click", openAccountModal);
$("#followStop").addEventListener("click", exitFollow);   // leave cross-device follow
$("#authForm").addEventListener("submit", (e) => { e.preventDefault(); submitAuth(); });
document.querySelectorAll(".auth-tab").forEach((t) =>
  t.addEventListener("click", () => setAuthMode(t.dataset.mode)));
$("#authSwitchBtn").addEventListener("click", () => setAuthMode(authMode === "signup" ? "signin" : "signup"));
$("#pwToggle").addEventListener("click", togglePasswordVisibility);
$("#acctSignOut").addEventListener("click", doSignOut);
$("#acctDone").addEventListener("click", closeAccountModal);
$("#acctClose").addEventListener("click", closeAccountModal);
$("#accountModal").addEventListener("click", (e) => { if (e.target.id === "accountModal") closeAccountModal(); });

/* --------------------------------------------------- connect-phone (mobile pairing) */
// Shows a QR + address of this computer's LAN URL so the phone app can scan to connect.
// The address (and the whole reachability question) is answered by /api/server-info.
async function openPairModal() {
  $("#pairModal").hidden = false;
  $("#pairWarn").hidden = true;
  try {
    renderPairInfo(await api("/api/server-info"));
  } catch (e) {
    $("#pairBody").hidden = true;
    const warn = $("#pairWarn");
    warn.hidden = false;
    warn.innerHTML = icon("alert") + " Couldn't read this computer's network address.";
  }
}
function renderPairInfo(info) {
  const warn = $("#pairWarn");
  const url = info.primary;
  $("#pairBody").hidden = false;
  if (!info.lan_reachable) {
    warn.hidden = false;
    warn.innerHTML = icon("alert") +
      " Your phone can't connect yet — the server is only listening on this computer. " +
      "Restart it with <code>HOST=0.0.0.0 ./scripts/run.sh</code>, then reopen this panel.";
  } else if (!url) {
    warn.hidden = false;
    warn.innerHTML = icon("alert") + " No Wi-Fi address found — connect this computer to a network.";
  } else {
    warn.hidden = true;
  }
  const qr = $("#pairQr");
  if (url) { qr.src = "/api/pair.svg?t=" + Date.now(); qr.hidden = false; }   // cache-bust per open
  else { qr.removeAttribute("src"); qr.hidden = true; }
  const btn = $("#pairUrl");
  btn.textContent = url ? url.replace(/^https?:\/\//, "") : "—";
  btn.dataset.url = url || "";
  const others = (info.urls || []).filter((u) => u !== url);
  $("#pairAlt").innerHTML = others.length
    ? "Also at " + others.map((u) => `<code>${escapeHtml(u.replace(/^https?:\/\//, ""))}</code>`).join(" · ")
    : "";
}
function closePairModal() { $("#pairModal").hidden = true; }
$("#pairBtn").addEventListener("click", openPairModal);
$("#pairClose").addEventListener("click", closePairModal);
$("#pairModal").addEventListener("click", (e) => { if (e.target.id === "pairModal") closePairModal(); });
$("#pairUrl").addEventListener("click", () => {
  const u = $("#pairUrl").dataset.url;
  if (u && navigator.clipboard) navigator.clipboard.writeText(u).then(() => toast("Address copied.")).catch(() => {});
});

/* --------------------------------------------------------------- keyboard */
document.addEventListener("keydown", (e) => {
  const tag = (e.target.tagName || "").toLowerCase();
  const typing = tag === "input" || tag === "textarea" || tag === "select";
  if (e.key === "Escape") {
    if (!$("#displayMenu").hidden) { $("#displayMenu").hidden = true; return; }
    if (!$("#exportMenu").hidden) { $("#exportMenu").hidden = true; return; }
    if (!$("#noteEditor").hidden) { closeNoteEditor(); return; }   // before the typing guard, so it closes from the textarea
    if (!$("#notePopover").hidden) { hideNotePopover(); return; }
    if (!$("#shortcutsModal").hidden) { closeShortcuts(); return; }
    if (!$("#accountModal").hidden) { closeAccountModal(); return; }
    if (!$("#pairModal").hidden) { closePairModal(); return; }
    if ($("#modal").hidden === false) closeModal();
    else if (state.readingMode) exitReadingMode();
    else if ($("#searchInput").value) clearSearch();
    else if (!$("#readerView").hidden) showLibrary();
    return;
  }
  if (e.key === "/" && !typing) { e.preventDefault(); $("#searchInput").focus(); return; }
  if (e.key === "?" && !typing) { e.preventDefault(); openShortcuts(); return; }
  if (typing || $("#readerView").hidden) return;
  switch (e.key) {
    case " ": e.preventDefault(); audio.paused ? audio.play() : audio.pause(); break;
    case "ArrowLeft": seekTo(Math.max(0, audio.currentTime - 10)); break;
    case "ArrowRight": seekTo(audio.currentTime + 10); break;
    case "ArrowUp": e.preventDefault(); jumpSentence(-1); break;
    case "ArrowDown": e.preventDefault(); jumpSentence(1); break;
    case "[": loadChapter(state.ci - 1, 0, true); break;
    case "]": loadChapter(state.ci + 1, 0, true); break;
    case "b": case "B": addBookmark(); break;
    case "n": case "N": startNoteAtCurrent(); break;
    case "f": case "F": e.preventDefault(); toggleReadingMode(); break;
  }
});
function jumpSentence(dir) {
  const cur = state.activeSi < 0 ? findActiveIndex(audio.currentTime) : state.activeSi;
  const ni = cur + dir;
  if (ni >= 0 && ni < state.sentences.length) seekTo(state.sentences[ni].s, true);
}

/* ----------------------------------------------------------- add-book modal */
// Show any setup warnings (missing ffmpeg/kokoro/espeak) from /api/health, right where
// the user is about to generate — so a WAV-fallback or dummy-only situation isn't a surprise.
async function loadHealthWarnings() {
  const el = $("#healthWarn");
  try {
    const h = await api("/api/health");
    if (h.warnings && h.warnings.length) {
      el.innerHTML = h.warnings.map((w) => icon("alert") + " " + escapeHtml(w)).join("<br>");
      el.hidden = false;
    } else { el.hidden = true; }
  } catch { el.hidden = true; }
}

async function openModal() {
  loadHealthWarnings();
  const sel = $("#voiceSelect");
  if (!sel.options.length) {
    try {
      const { voices, default: def } = await api("/api/voices");
      sel.innerHTML = voices.map((v) =>
        `<option value="${v.id}" ${v.id === def ? "selected" : ""}>${escapeHtml(v.label)}</option>`).join("");
    } catch { sel.innerHTML = `<option value="af_heart">Heart (US, female)</option>`; }
  }
  $("#modal").hidden = false;
}
function closeModal() {
  $("#modal").hidden = true;
  $("#ingestProgress").hidden = true;
  $("#ingestBar").style.width = "0";
  $("#ingestForm").reset();
  $("#startIngest").disabled = false;
}
$("#addBookBtn").addEventListener("click", openModal);
$("#cancelModal").addEventListener("click", closeModal);

/* ---------------------------------------------------------- shortcuts help */
function openShortcuts() { $("#shortcutsModal").hidden = false; }
function closeShortcuts() { $("#shortcutsModal").hidden = true; }
$("#helpBtn").addEventListener("click", openShortcuts);
$("#closeShortcuts").addEventListener("click", closeShortcuts);
$("#shortcutsModal").addEventListener("click", (e) => {
  if (e.target.id === "shortcutsModal") closeShortcuts();   // click the backdrop to dismiss
});

$("#ingestForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const file = $("#pdfFile").files[0];
  if (!file) return;
  const fd = new FormData();
  fd.append("file", file);
  fd.append("voice", $("#voiceSelect").value);
  fd.append("speed", $("#ingestSpeed").value);
  $("#startIngest").disabled = true;
  $("#ingestProgress").hidden = false;
  $("#ingestMsg").textContent = "Uploading…";
  try {
    const { job_id } = await api("/api/ingest", { method: "POST", body: fd });
    pollJob(job_id);
  } catch (err) {
    $("#ingestMsg").textContent = "Failed: " + err.message;
    $("#startIngest").disabled = false;
  }
});

async function pollJob(jobId) {
  try {
    const j = await api(`/api/jobs/${jobId}`);
    const ready = j.chapters_ready || 0, total = j.chapters_total || 0;
    $("#ingestBar").style.width = (j.percent || 0) + "%";
    $("#ingestMsg").textContent = total
      ? `${j.message || ""} · ${ready}/${total} chapters ready`
      : (j.message || j.stage || "Working…");
    if (j.status === "error") {
      $("#ingestMsg").textContent = "Error: " + j.message;
      $("#startIngest").disabled = false;
      return;
    }
    // Open the book the moment the first chapter is listenable; the rest keep
    // generating in the background and stream into the player automatically.
    if (j.book_id && (ready >= 1 || j.status === "done")) {
      const bid = j.book_id;
      closeModal();
      await loadLibrary();
      openBook(bid);
      return;
    }
  } catch (err) {
    $("#ingestMsg").textContent = "Lost job: " + err.message;
    return;
  }
  setTimeout(() => pollJob(jobId), 1000);
}

let toastTimer = null;
function toast(msg, onClick) {
  const el = $("#toast");
  el.textContent = msg;
  el.hidden = false;
  el.classList.toggle("clickable", !!onClick);
  el.onclick = onClick ? () => { el.hidden = true; el.onclick = null; el.classList.remove("clickable"); try { onClick(); } catch (e) {} } : null;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; el.onclick = null; el.classList.remove("clickable"); }, onClick ? 6000 : 3200);
}

/* ----------------------------------------------------------- drag and drop */
window.addEventListener("dragover", (e) => { e.preventDefault(); });
window.addEventListener("drop", (e) => {
  e.preventDefault();
  const f = e.dataTransfer.files[0];
  if (f && /\.(pdf|epub)$/i.test(f.name)) {
    openModal().then(() => {
      const dt = new DataTransfer();
      dt.items.add(f);
      $("#pdfFile").files = dt.files;
    });
  }
});

/* ------------------------------------------------------------------- init */
(function init() {
  hydrateIcons(document);   // fill every [data-icon] in the static markup with its SVG
  const rate = localStorage.getItem("abk:rate");
  if (rate) { $("#rateSelect").value = rate; audio.playbackRate = Number(rate); }
  const vol = localStorage.getItem("abk:vol");
  if (vol !== null) { $("#volBar").value = vol; audio.volume = Number(vol); }
  applyTheme(localStorage.getItem("abk:theme") || "dark");
  applyFont(Number(localStorage.getItem("abk:reader-size")) || 20);
  setupMediaSession();
  updateAccountUI();   // reflects "Local" until sync.js reports auth (see window.ABK)
  showLibrary();
})();
