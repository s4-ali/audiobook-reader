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
    const mins = Math.round((b.duration || 0) / 60);
    const generating = b.status === "generating";
    const badge = generating
      ? `<div class="badge"><span class="spinner"></span>${b.chapters_ready || 0}/${b.n_chapters}</div>`
      : "";
    card.innerHTML = `
      <button class="del" title="Delete">🗑</button>
      ${badge}
      <div class="cover">📖</div>
      <h3>${escapeHtml(b.title || b.id)}</h3>
      <div class="author">${escapeHtml(b.author || "Unknown")}</div>
      <div class="stats"><span>${b.n_chapters} chapters</span><span>${mins} min</span>
        <span>${escapeHtml(b.voice || "")}</span></div>`;
    card.addEventListener("click", () => openBook(b.id));
    card.querySelector(".del").addEventListener("click", async (e) => {
      e.stopPropagation();
      if (confirm(`Delete "${b.title}" and its audio?`)) {
        await fetch(`/api/books/${b.id}`, { method: "DELETE" });
        loadLibrary();
      }
    });
    grid.appendChild(card);
  }
}

function showLibrary() {
  stopGenPoll();
  audio.pause();
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
async function openBook(bookId) {
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
  clearSearch();
  updateGenBanner();

  const pos = loadPos(bookId);
  const chapters = m.chapters;
  let target = -1;
  if (pos.ci != null && isReady(chapters[pos.ci])) target = pos.ci;
  if (target < 0) target = chapters.findIndex(isReady);
  if (target >= 0) {
    loadChapter(target, target === pos.ci ? (pos.t || 0) : 0, false);
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
  if (++saveTick % 12 === 0) savePos();
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
function savePos() {
  if (!state.bookId) return;
  localStorage.setItem(`abk:pos:${state.bookId}`,
    JSON.stringify({ ci: state.ci, t: audio.currentTime || 0 }));
}
function loadPos(bookId) {
  try { return JSON.parse(localStorage.getItem(`abk:pos:${bookId}`)) || {}; }
  catch { return {}; }
}
window.addEventListener("beforeunload", savePos);
document.addEventListener("visibilitychange", () => { if (document.hidden) savePos(); });

/* --------------------------------------------------------------- keyboard */
document.addEventListener("keydown", (e) => {
  const tag = (e.target.tagName || "").toLowerCase();
  const typing = tag === "input" || tag === "textarea" || tag === "select";
  if (e.key === "Escape") {
    if ($("#modal").hidden === false) closeModal();
    else if ($("#searchInput").value) clearSearch();
    else if (!$("#readerView").hidden) showLibrary();
    return;
  }
  if (e.key === "/" && !typing) { e.preventDefault(); $("#searchInput").focus(); return; }
  if (typing || $("#readerView").hidden) return;
  switch (e.key) {
    case " ": e.preventDefault(); audio.paused ? audio.play() : audio.pause(); break;
    case "ArrowLeft": seekTo(Math.max(0, audio.currentTime - 10)); break;
    case "ArrowRight": seekTo(audio.currentTime + 10); break;
    case "ArrowUp": e.preventDefault(); jumpSentence(-1); break;
    case "ArrowDown": e.preventDefault(); jumpSentence(1); break;
    case "[": loadChapter(state.ci - 1, 0, true); break;
    case "]": loadChapter(state.ci + 1, 0, true); break;
  }
});
function jumpSentence(dir) {
  const cur = state.activeSi < 0 ? findActiveIndex(audio.currentTime) : state.activeSi;
  const ni = cur + dir;
  if (ni >= 0 && ni < state.sentences.length) seekTo(state.sentences[ni].s, true);
}

/* ----------------------------------------------------------- add-book modal */
async function openModal() {
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
  showLibrary();
})();
