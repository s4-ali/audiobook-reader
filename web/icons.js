"use strict";
/* ------------------------------------------------------------------ icons
 * A tiny, no-build SVG icon system shared by the static markup (index.html)
 * and the dynamically-rendered HTML in app.js. One source of truth here.
 *
 *   icon(name[, cls])     -> an <svg> string (embed in template literals)
 *   hydrateIcons(root)     -> replace every [data-icon] element's contents
 *                             with its icon (used for the static markup)
 *
 * Icons are 24x24, drawn in a clean stroke style (Lucide-like) that inherits
 * the surrounding text color via `currentColor`. A handful of media/transport
 * glyphs are filled — they set fill/stroke on their own elements, overriding
 * the wrapper's `fill:none; stroke:currentColor` defaults.
 * ------------------------------------------------------------------------- */
(function () {
  const ICONS = {
    /* --- navigation / chrome --- */
    "arrow-left":    '<path d="M19 12H5"/><path d="M12 19l-7-7 7-7"/>',
    "chevron-right": '<path d="M9 6l6 6-6 6"/>',
    "chevron-up":    '<path d="M6 15l6-6 6 6"/>',
    "chevron-down":  '<path d="M6 9l6 6 6-6"/>',
    "x":             '<path d="M18 6 6 18"/><path d="M6 6l12 12"/>',
    "plus":          '<path d="M12 5v14"/><path d="M5 12h14"/>',
    "check":         '<path d="M20 6 9 17l-5-5"/>',
    "keyboard":      '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M8 14h8"/>',
    "cloud":         '<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/>',
    "cloud-off":     '<path d="m2 2 20 20"/><path d="M5.8 5.8A7 7 0 0 0 9 19h8.5a4.5 4.5 0 0 0 1.3-.2"/><path d="M21.5 16.5A4.5 4.5 0 0 0 17.5 10h-1.8A7 7 0 0 0 10 5.2"/>',
    "smartphone":    '<rect x="6" y="2" width="12" height="20" rx="2.5"/><path d="M11 18h2"/>',

    /* --- actions --- */
    "download":  '<path d="M12 3v12"/><path d="M7 10l5 5 5-5"/><path d="M5 20h14"/>',
    "trash":     '<path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M10 11v6M14 11v6"/>',
    "bookmark":  '<path d="M6 3h12a1 1 0 0 1 1 1v17l-7-4.5L5 21V4a1 1 0 0 1 1-1Z" fill="currentColor" stroke="none"/>',
    "note":      '<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.4 2.6a2 2 0 0 1 2.83 2.83L12 14.66l-3.75 1 1-3.75Z"/>',
    "pen":       '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',

    /* --- status --- */
    "alert": '<path d="M10.3 3.9 2.4 17a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
    "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 7.5V12l3 2"/>',

    /* --- content / media meaning --- */
    "book-open": '<path d="M12 7v14"/><path d="M3 5h5a4 4 0 0 1 4 4 4 4 0 0 1 4-4h5v13h-6a3 3 0 0 0-3 3 3 3 0 0 0-3-3H3z"/>',
    "moon":      '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>',
    "volume":    '<path d="M11 5 6 9H2v6h4l5 4z" fill="currentColor" stroke-width="1.5"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/>',
    "rss":       '<path d="M4 11a9 9 0 0 1 9 9"/><path d="M4 4a16 16 0 0 1 16 16"/><circle cx="5" cy="19" r="1.4" fill="currentColor" stroke="none"/>',
    "file-text": '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z"/><path d="M14 2v6h6"/><path d="M8 13h8M8 17h8M8 9h2"/>',
    "captions":  '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 15h4M15 15h2M7 11h2M13 11h4"/>',
    "sparkles":  '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9Z" fill="currentColor" stroke="none"/><path d="M19 14.5l.75 2 2 .75-2 .75-.75 2-.75-2-2-.75 2-.75Z" fill="currentColor" stroke="none"/>',

    /* --- transport (filled) --- */
    "play":  '<path d="M6 4.2v15.6a.8.8 0 0 0 1.22.68l12.5-7.8a.8.8 0 0 0 0-1.36L7.22 3.52A.8.8 0 0 0 6 4.2Z" fill="currentColor" stroke-width="1.6"/>',
    "pause": '<rect x="6" y="4.5" width="4" height="15" rx="1.3" fill="currentColor" stroke="none"/><rect x="14" y="4.5" width="4" height="15" rx="1.3" fill="currentColor" stroke="none"/>',
    "stop":  '<rect x="5" y="5" width="14" height="14" rx="2.5" fill="currentColor" stroke="none"/>',
    "skip-back":    '<rect x="4.5" y="5" width="2.5" height="14" rx="1.1" fill="currentColor" stroke="none"/><path d="M20 5.6v12.8a.7.7 0 0 1-1.08.6L9.3 12.6a.7.7 0 0 1 0-1.2l9.62-6.4A.7.7 0 0 1 20 5.6Z" fill="currentColor" stroke-width="1.4"/>',
    "skip-forward": '<rect x="17" y="5" width="2.5" height="14" rx="1.1" fill="currentColor" stroke="none"/><path d="M4 5.6v12.8a.7.7 0 0 0 1.08.6l9.62-6.4a.7.7 0 0 0 0-1.2L5.08 5A.7.7 0 0 0 4 5.6Z" fill="currentColor" stroke-width="1.4"/>',

    /* --- replay / forward N seconds: a circular arrow with the seconds inside --- */
    "replay-10":  '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/><text x="12.4" y="15.2" text-anchor="middle" font-size="8.5" font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system,system-ui,sans-serif">10</text>',
    "forward-10": '<path d="M21 12a9 9 0 1 1-9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><text x="11.6" y="15.2" text-anchor="middle" font-size="8.5" font-weight="700" fill="currentColor" stroke="none" font-family="-apple-system,system-ui,sans-serif">10</text>',
  };

  // The brand logo — a self-contained, self-colored mark (gradient tile + open
  // book + a play badge). Not tied to currentColor, so it looks the same in
  // every theme. Uses its own viewBox and unique gradient id.
  function logoSvg(cls) {
    return '<svg class="icon brand-logo' + (cls ? " " + cls : "") + '" viewBox="0 0 32 32" ' +
      'aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg">' +
      '<defs><linearGradient id="abkLogoGrad" x1="0" y1="0" x2="1" y2="1">' +
        '<stop offset="0" stop-color="#cba6f7"/><stop offset="1" stop-color="#89b4fa"/>' +
      '</linearGradient></defs>' +
      '<rect width="32" height="32" rx="8" fill="url(#abkLogoGrad)"/>' +
      // open book (white pages), spine at center
      '<path d="M16 10.4C13.4 9 9.7 8.8 6.4 9.7v11.1c3.3-.9 7-.7 9.6.8z" fill="#fbf8ff"/>' +
      '<path d="M16 10.4C18.6 9 22.3 8.8 25.6 9.7v11.1c-3.3-.9-7-.7-9.6.8z" fill="#ffffff"/>' +
      '<rect x="15.2" y="10.2" width="1.6" height="11.9" rx="0.8" fill="url(#abkLogoGrad)"/>' +
      // play badge, bottom-right — signals "audio"
      '<circle cx="23.4" cy="23" r="5.6" fill="#7c3aed" stroke="#fff" stroke-width="1.6"/>' +
      '<path d="M21.9 20.6v4.8l4.1-2.4z" fill="#fff"/>' +
    '</svg>';
  }

  function icon(name, cls) {
    if (name === "logo") return logoSvg(cls);
    const body = ICONS[name];
    if (!body) return "";
    return '<svg class="icon icon-' + name + (cls ? " " + cls : "") + '" viewBox="0 0 24 24" ' +
      'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
      'stroke-linejoin="round" aria-hidden="true" focusable="false">' + body + '</svg>';
  }

  // Replace the contents of every [data-icon] element with its icon. An element
  // may carry extra text as siblings of the data-icon child (see index.html).
  function hydrateIcons(root) {
    (root || document).querySelectorAll("[data-icon]").forEach((el) => {
      el.innerHTML = icon(el.getAttribute("data-icon"));
    });
  }

  window.icon = icon;
  window.hydrateIcons = hydrateIcons;
  window.ICONS = ICONS;
})();
