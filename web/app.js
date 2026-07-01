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
};
let manifestPoll = null;  // interval while a book is still generating
let libraryPoll = null;   // interval while the library has generating books

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
      ? `<a class="pkg" href="/api/books/${b.id}/package" download title="Download .abk package for the phone app">⤓</a>`
      : "";
    const rss = ready ? `<button class="rss" title="Copy podcast RSS feed URL">🎙</button>` : "";
    card.innerHTML = `
      <button class="del" title="Delete">🗑</button>
      ${pkg}
      ${rss}
      ${badge}
      <div class="cover">📖</div>
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
          .then(() => toast("🎙 Podcast feed URL copied — paste it into your podcast app."))
          .catch(() => toast(url));
      } else { toast(url); }
    });
    card.querySelector(".del").addEventListener("click", async (e) => {
      e.stopPropagation();
      if (confirm(`Delete "${b.title}" and its audio?`)) {
        await fetch(`/api/books/${b.id}`, { method: "DELETE" });
        localStorage.removeItem(`abk:pos:${b.id}`);   // drop saved position + bookmarks too
        localStorage.removeItem(`abk:bm:${b.id}`);
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
      <div class="cc-cover">📖</div>
      <div class="cc-body">
        <div class="cc-label">▶ Continue listening</div>
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
  audio.pause();      // 'pause' handler would otherwise run after bookId is nulled)
  state.bookId = null; state.manifest = null; state.waitingForNext = null; state.genstate = null;
  $("#libraryView").hidden = false;
  $("#readerView").hidden = true;
  $("#player").hidden = true;
  $("#backBtn").hidden = true;
  $("#bookMeta").textContent = "";
  loadLibrary().then(() => { state.anyGenerating ? startLibraryPolling() : stopLibraryPolling(); });
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
    body = `<span class="gb-ico">⏸</span>Paused — <b>${ready}/${total}</b>`;
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
    body = `<span class="gb-ico">⏹</span>${label} — <b>${ready}/${total}</b>`;
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
    const right = ready ? fmtTime(ch.duration) : errored ? "⚠" : "⏳";
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
  state.spanEls = [];
  let p = document.createElement("p");
  (ch.sentences || []).forEach((sent) => {
    const span = document.createElement("span");
    span.className = "sent";
    span.dataset.si = sent.i;
    span.textContent = sent.t + " ";
    span.addEventListener("click", () => seekTo(sent.s, true));
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

audio.addEventListener("play", () => { $("#playBtn").textContent = "❚❚"; });
audio.addEventListener("pause", () => { $("#playBtn").textContent = "▶"; savePos(); });
audio.addEventListener("ended", () => {
  savePos();
  if (sleepTimer.endOfChapter) {
    resetSleep();
    toast("😴 End of chapter — paused.");
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
  if (isFinite(audio.duration)) {
    audio.currentTime = Math.min(t, audio.duration - 0.05);
    if (play && audio.paused) audio.play().catch(() => {});
  } else {
    pendingSeek = t; pendingPlay = play;
  }
}

/* --------------------------------------------------------------- transport */
$("#playBtn").addEventListener("click", () => audio.paused ? audio.play() : audio.pause());
$("#back10Btn").addEventListener("click", () => seekTo(Math.max(0, audio.currentTime - 10)));
$("#fwd10Btn").addEventListener("click", () => seekTo(audio.currentTime + 10));
$("#prevChBtn").addEventListener("click", () => loadChapter(state.ci - 1, 0, true));
$("#nextChBtn").addEventListener("click", () => loadChapter(state.ci + 1, 0, true));
$("#backBtn").addEventListener("click", showLibrary);

const seekBar = $("#seekBar");
seekBar.addEventListener("input", () => {
  state.isScrubbing = true;
  $("#curTime").textContent = fmtTime(Number(seekBar.value));
});
seekBar.addEventListener("change", () => {
  audio.currentTime = Number(seekBar.value);
  state.isScrubbing = false;
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
  toast("😴 Sleep timer reached — paused.");
}

sleepSelect.addEventListener("change", (e) => {
  const v = e.target.value;
  disarmSleep();
  if (v === "0") return;
  if (v === "chapter") {
    sleepTimer.endOfChapter = true;
    toast("😴 Will pause at the end of this chapter.");
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
    const loc = (it.type === "nav" ? "▸ " : "") +
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
// Resume points live per-book in localStorage as { ci, t, frac, updated }: chapter index,
// in-chapter seconds, overall progress 0..1, and a save timestamp (used to pick the most
// recently played book for the "Continue listening" card).
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
  const m = state.manifest;
  // While restoring (before loadedmetadata seeks) audio.currentTime is still 0 but the
  // intended time lives in pendingSeek — prefer it so we never clobber a good position.
  const t = audio.currentTime || pendingSeek || 0;
  const total = m.total_duration || 0;
  const frac = total > 0 ? Math.min(1, (chapterStart(m, state.ci) + t) / total) : 0;
  localStorage.setItem(`abk:pos:${state.bookId}`,
    JSON.stringify({ ci: state.ci, t, frac, updated: Date.now() }));
}
function loadPos(bookId) {
  try { return JSON.parse(localStorage.getItem(`abk:pos:${bookId}`)) || {}; }
  catch { return {}; }
}
window.addEventListener("beforeunload", savePos);
document.addEventListener("visibilitychange", () => { if (document.hidden) savePos(); });

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
  toast("🔖 Bookmark added.");
}

function renderBookmarks() {
  const panel = $("#bookmarksPanel");
  const list = state.bookId ? loadBookmarks(state.bookId) : [];
  if (!list.length) { panel.hidden = true; panel.innerHTML = ""; return; }
  panel.hidden = false;
  panel.innerHTML = `<div class="bm-head">🔖 Bookmarks · ${list.length}</div>` +
    list.map((b, i) => `
      <div class="bm" data-idx="${i}">
        <div class="bm-main">
          <div class="bm-loc">${escapeHtml(b.ch || "")} · ${fmtTime(b.t)}</div>
          ${b.snip ? `<div class="bm-snip">${escapeHtml(b.snip)}</div>` : ""}
        </div>
        <button class="bm-del" title="Remove bookmark">✕</button>
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

/* ----------------------------------------------------- OS media controls */
// Wire the page into the OS media session: lock-screen / notification controls, hardware
// media keys, Bluetooth & car controls, and a system scrubber — all feature-detected so
// browsers without the API are unaffected.
const hasMediaSession = "mediaSession" in navigator;

function setupMediaSession() {
  if (!hasMediaSession) return;
  const ms = navigator.mediaSession;
  const set = (action, fn) => { try { ms.setActionHandler(action, fn); } catch (e) { /* unsupported action */ } };
  set("play", () => audio.play().catch(() => {}));
  set("pause", () => audio.pause());
  set("stop", () => audio.pause());
  set("seekbackward", (d) => seekTo(Math.max(0, audio.currentTime - (d.seekOffset || 10))));
  set("seekforward", (d) => seekTo(audio.currentTime + (d.seekOffset || 10)));
  set("previoustrack", () => loadChapter(state.ci - 1, 0, true));
  set("nexttrack", () => loadChapter(state.ci + 1, 0, true));
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
    `<a download href="/api/books/${id}/transcript.txt">📄 Transcript (.txt)</a>`,
    `<a download href="/api/books/${id}/subtitles.vtt">💬 Subtitles (.vtt)</a>`,
    `<a download href="/api/books/${id}/subtitles.srt">💬 Subtitles (.srt)</a>`,
  ];
  if (state.ci >= 0 && state.manifest && isReady(state.manifest.chapters[state.ci])) {
    rows.push(`<div class="em-sep">This chapter</div>`,
      `<a download href="/api/books/${id}/chapter/${state.ci}/subtitles.vtt">💬 Chapter (.vtt)</a>`,
      `<a download href="/api/books/${id}/chapter/${state.ci}/subtitles.srt">💬 Chapter (.srt)</a>`);
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

/* --------------------------------------------------------------- keyboard */
document.addEventListener("keydown", (e) => {
  const tag = (e.target.tagName || "").toLowerCase();
  const typing = tag === "input" || tag === "textarea" || tag === "select";
  if (e.key === "Escape") {
    if (!$("#displayMenu").hidden) { $("#displayMenu").hidden = true; return; }
    if (!$("#exportMenu").hidden) { $("#exportMenu").hidden = true; return; }
    if (!$("#shortcutsModal").hidden) { closeShortcuts(); return; }
    if ($("#modal").hidden === false) closeModal();
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
      el.innerHTML = h.warnings.map((w) => "⚠ " + escapeHtml(w)).join("<br>");
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
  fd.append("engine", $("#engineSelect").value);
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
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, 3200);
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
  const rate = localStorage.getItem("abk:rate");
  if (rate) { $("#rateSelect").value = rate; audio.playbackRate = Number(rate); }
  const vol = localStorage.getItem("abk:vol");
  if (vol !== null) { $("#volBar").value = vol; audio.volume = Number(vol); }
  applyTheme(localStorage.getItem("abk:theme") || "dark");
  applyFont(Number(localStorage.getItem("abk:reader-size")) || 20);
  setupMediaSession();
  showLibrary();
})();
