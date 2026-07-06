// Optional Firebase (Cloud Firestore + email/password auth) sync layer for the web player.
//
// This is the ONLY place Firebase is imported. It is loaded as a module
// (`<script type="module">`) and reaches Firebase v10 from the gstatic CDN, so the project's
// no-build-step convention holds. It is entirely additive: if `web/firebase-config.js` is
// absent / still holds placeholders, or the SDK can't load (offline first run), it installs a
// no-op `window.abkSync` and the player behaves exactly as it does today (localStorage
// progress, notes over the local server only).
//
// Contract with app.js (which is a classic script and runs first):
//   - app.js sets handlers on `window.ABK` (onAuthChange, applyRemoteProgress,
//     applyRemoteNotes) during init(); we call them.
//   - app.js calls `window.abkSync?.method(...)` guarded, so a not-yet-ready or disabled sync
//     is always a safe no-op.
//
// Firestore layout (mirrors the mobile app):
//   users/{uid}/books/{bookId}                    -> progress fields {ci,t,si,frac,updated,device}
//   users/{uid}/books/{bookId}/notes/{noteId}     -> one doc per note (id == noteId), + {deleted}
"use strict";

const CDN = "https://www.gstatic.com/firebasejs/10.12.0";
const PROGRESS_DEBOUNCE_MS = 1500;

// UTC, second precision, `Z` suffix — byte-for-byte the format app/notes.py and the Flutter
// app emit, so last-write-wins string comparison of `updated` stays consistent everywhere.
const isoNow = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

// A note may not exist remotely yet or may carry client-only fields (_orphan, tmp id). Keep
// only the durable record shape Firestore should hold; drop undefined (Firestore rejects it).
const NOTE_FIELDS = ["id", "ch", "si", "sj", "cs", "ce", "s", "e",
  "exact", "prefix", "suffix", "color", "tags", "note", "kind", "created", "updated", "deleted"];
function cleanNote(note) {
  const out = {};
  for (const k of NOTE_FIELDS) if (note[k] !== undefined) out[k] = note[k];
  return out;
}

// Notify app.js of an auth transition (signed-in user summary, or null). Guarded so a page
// without app.js, or one where init() hasn't defined ABK yet, never throws.
function notifyAuth(user) {
  try {
    window.ABK?.onAuthChange?.(
      user ? { uid: user.uid, email: user.email, isAnonymous: !!user.isAnonymous } : null);
  } catch (e) { /* app handler blew up — not our problem */ }
}

// The no-op surface. Installed when sync is unconfigured or fails to initialize, so every
// `window.abkSync?.x()` in app.js is a safe call. `enabled:false` lets the UI say "Local only".
function installDisabled(reason) {
  window.abkSync = {
    enabled: false,
    reason: reason || "not configured",
    user: () => null,
    signIn: async () => { throw new Error("Cloud sync isn't configured on this device."); },
    createAccount: async () => { throw new Error("Cloud sync isn't configured on this device."); },
    signOut: async () => {},
    pushProgress: () => {},
    flushProgress: async () => {},
    watchProgress: () => () => {},
    fetchAllProgress: async () => ({}),
    fetchProgress: async () => null,
    putNote: async () => {},
    deleteNote: async () => {},
    fetchNotes: async () => [],
    watchNotes: () => () => {},
  };
  notifyAuth(null);
}

function looksConfigured(cfg) {
  return !!(cfg && typeof cfg.apiKey === "string" && cfg.apiKey && !cfg.apiKey.startsWith("YOUR_")
    && cfg.projectId && !String(cfg.projectId).startsWith("YOUR_"));
}

async function boot() {
  // 1) Load the (git-ignored) config. Missing file → dynamic import rejects → stay local.
  let cfg = null;
  try { cfg = (await import("./firebase-config.js"))?.default ?? null; }
  catch (e) { installDisabled("no firebase-config.js"); return; }
  if (!looksConfigured(cfg)) { installDisabled("firebase-config.js has placeholder values"); return; }

  // 2) Load the SDK (only now, so an unconfigured install never hits the network).
  const [{ initializeApp }, authSdk, fsSdk] = await Promise.all([
    import(`${CDN}/firebase-app.js`),
    import(`${CDN}/firebase-auth.js`),
    import(`${CDN}/firebase-firestore.js`),
  ]);
  const { getAuth, onAuthStateChanged, signInAnonymously, signInWithEmailAndPassword,
          createUserWithEmailAndPassword, signOut, EmailAuthProvider, linkWithCredential } = authSdk;
  const { initializeFirestore, getFirestore, persistentLocalCache, persistentMultipleTabManager,
          doc, collection, setDoc, getDoc, getDocFromCache, getDocs, onSnapshot } = fsSdk;

  const app = initializeApp(cfg);
  const auth = getAuth(app);
  // Offline persistence: read/write keep working without a network once loaded; writes queue
  // and flush on reconnect. Falls back to the in-memory default if IndexedDB is unavailable
  // (private windows, multi-tab conflicts, etc.).
  let db;
  try {
    db = initializeFirestore(app, {
      localCache: persistentLocalCache({ tabManager: persistentMultipleTabManager() }),
    });
  } catch (e) { db = getFirestore(app); }

  let user = null;
  const uid = () => user && user.uid;
  const available = () => !!user;   // enabled implicitly (we only get here when configured)

  const bookRef = (id) => doc(db, "users", uid(), "books", id);
  const notesCol = (id) => collection(db, "users", uid(), "books", id, "notes");
  const noteRef = (id, nid) => doc(db, "users", uid(), "books", id, "notes", nid);

  // --- progress: coalesced writes -------------------------------------------------
  // Per the "sync per sentence" requirement we push on every active-sentence change, but a
  // single debounce coalesces bursts (fast scrubbing) into one write — Firestore comfortably
  // sustains ~1 write/s/doc and this stays well under that.
  const pending = new Map();  // bookId -> latest progress payload
  let flushTimer = null;
  function pushProgress(bookId, pos) {
    if (!available() || !bookId) return;
    pending.set(bookId, pos);
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = setTimeout(flushProgress, PROGRESS_DEBOUNCE_MS);
  }
  async function flushProgress() {
    if (flushTimer) { clearTimeout(flushTimer); flushTimer = null; }
    if (!available() || !pending.size) { pending.clear(); return; }
    const entries = [...pending.entries()];
    pending.clear();
    await Promise.all(entries.map(([bookId, pos]) =>
      setDoc(bookRef(bookId), pos, { merge: true }).catch(() => {})));
  }
  function watchProgress(bookId, cb) {
    if (!available()) return () => {};
    return onSnapshot(bookRef(bookId), (snap) => {
      if (snap.metadata.hasPendingWrites) return;   // our own echo — ignore
      const d = snap.data();
      if (d && d.updated != null) cb(d);
    }, () => {});
  }
  async function fetchAllProgress(_ids) {
    if (!available()) return {};
    try {
      const qs = await getDocs(collection(db, "users", uid(), "books"));
      const out = {};
      qs.forEach((d) => { const v = d.data(); if (v && v.updated != null) out[d.id] = v; });
      return out;
    } catch (e) { return {}; }
  }
  // Cache-first so open-time resume is instant + offline-safe (the on-disk cache is the local
  // source of truth — there's no localStorage progress); watchProgress delivers any newer server
  // position (another device) a moment later.
  async function fetchProgress(bookId) {
    if (!available() || !bookId) return null;
    try { const c = await getDocFromCache(bookRef(bookId)); const d = c.data(); if (d && d.updated != null) return d; }
    catch (e) { /* nothing cached yet — fall through to a normal (server) read */ }
    try { const s = await getDoc(bookRef(bookId)); const d = s.data(); return (d && d.updated != null) ? d : null; }
    catch (e) { return null; }
  }

  // --- notes ----------------------------------------------------------------------
  async function putNote(bookId, note) {
    if (!available() || !note || !note.id) return;
    try { await setDoc(noteRef(bookId, note.id), cleanNote(note), { merge: true }); }
    catch (e) { /* offline write is queued by the cache; a hard failure is non-fatal */ }
  }
  async function deleteNote(bookId, id) {
    if (!available() || !id) return;
    // Soft-delete: a tombstone with a fresh `updated` so the deletion wins LWW and propagates
    // to peers. Readers filter `deleted` out before it ever reaches notes.json.
    try { await setDoc(noteRef(bookId, id), { id, deleted: true, updated: isoNow() }, { merge: true }); }
    catch (e) { /* non-fatal */ }
  }
  async function fetchNotes(bookId) {
    if (!available()) return [];
    try { return (await getDocs(notesCol(bookId))).docs.map((d) => d.data()); }
    catch (e) { return []; }
  }
  function watchNotes(bookId, cb) {
    if (!available()) return () => {};
    return onSnapshot(notesCol(bookId), (qs) => cb(qs.docs.map((d) => d.data())), () => {});
  }

  // Sign in / create — carrying the anonymous reading history along. When we're anonymous (the
  // default), *link* the email credential onto this uid so its Firestore data becomes the
  // account's; if that email already exists, fall back to signing into it (the anonymous uid is
  // left behind). A brand-new email therefore creates the account in place, keeping progress.
  async function signIn(email, pw) {
    const cur = auth.currentUser;
    if (cur && cur.isAnonymous) {
      try { await linkWithCredential(cur, EmailAuthProvider.credential(email, pw)); return; }
      catch (e) {
        const c = (e && e.code) || "";
        if (c !== "auth/email-already-in-use" && c !== "auth/credential-already-in-use") throw e;
        // account already exists → switch to it below
      }
    }
    await signInWithEmailAndPassword(auth, email, pw);
  }
  async function createAccount(email, pw) {
    const cur = auth.currentUser;
    if (cur && cur.isAnonymous) {
      await linkWithCredential(cur, EmailAuthProvider.credential(email, pw));
      return;
    }
    await createUserWithEmailAndPassword(auth, email, pw);
  }

  // --- public surface -------------------------------------------------------------
  window.abkSync = {
    enabled: true,
    user: () => (user ? { uid: user.uid, email: user.email, isAnonymous: !!user.isAnonymous } : null),
    signIn,
    createAccount,
    signOut: () => signOut(auth),   // onAuthStateChanged re-signs-in anonymously (keeps a uid)
    pushProgress, flushProgress, watchProgress, fetchAllProgress, fetchProgress,
    putNote, deleteNote, fetchNotes, watchNotes,
    isoNow,
  };

  // Best-effort flush of any queued progress when the tab goes away.
  window.addEventListener("pagehide", () => { flushProgress(); });

  // Anonymous baseline: keep a uid at all times so Firestore (+ its offline cache) is the single
  // source of truth for progress from first load (no localStorage), and sign-out drops straight
  // back to a fresh anonymous session. When a real (email) account links/replaces it, isAnonymous
  // flips and the account UI updates.
  onAuthStateChanged(auth, (u) => {
    user = u || null;
    notifyAuth(user);
    if (!user) signInAnonymously(auth).catch(() => {/* offline first load → no uid until reconnect */});
  });
}

boot().catch((e) => {
  console.warn("[abkSync] cloud sync disabled:", (e && e.message) || e);
  installDisabled("initialization error");
});
