"""Generate a small multi-chapter sample PDF (with a real outline) for testing.

    .venv/bin/python scripts/make_sample_pdf.py
writes library/inbox/sample-book.pdf
"""
from pathlib import Path

import fitz  # PyMuPDF

OUT = Path(__file__).resolve().parent.parent / "library" / "inbox" / "sample-book.pdf"

CHAPTERS = [
    ("Chapter 1: The Lighthouse", None, (
        "The lighthouse had stood on the cliff for over a hundred years. "
        "Every night its lamp swept the dark water, warning ships away from the rocks. "
        "Mara climbed the spiral stairs two at a time, counting each step under her breath.\n\n"
        "At the top she found the old keeper asleep in his chair. "
        "The great lamp behind him turned slowly, throwing long shadows across the room. "
        "She did not wake him; instead she watched the beam reach out into the night.")),
    ("A Letter from the Sea", 2, (
        "On the table lay a letter, its edges stained with salt. "
        "It had arrived that morning in a bottle, carried by the tide. "
        "The handwriting was small and careful, as if the writer had little paper to spare.\n\n"
        "Mara read it twice. It spoke of an island that did not appear on any map, "
        "and of a light that burned with no keeper at all.")),
    ("Chapter 2: The Crossing", None, (
        "They left before dawn, when the harbor was still and grey. "
        "The little boat rocked as Mara stepped aboard, and the rope hissed free of the post. "
        "For a long while there was only the sound of the oars and the cry of distant gulls.\n\n"
        "By midday the coast had vanished behind them. "
        "The sea grew wide and patient, and the sky held its breath. "
        "Mara kept her eyes on the horizon, waiting for the island to rise.")),
    ("Chapter 3: The Light Without a Keeper", None, (
        "The island came slowly into view, a dark shape crowned with a single tower. "
        "No smoke rose from it, and no figure moved along its shore. "
        "Yet the light at its summit turned and turned, bright even in the afternoon sun.\n\n"
        "Mara beached the boat and climbed toward the tower. "
        "The door stood open. Inside, the stairs rose into shadow, "
        "and somewhere above her the great lamp went on burning, faithful and alone.")),
]


def main():
    doc = fitz.open()
    toc = []
    for title, level, body in CHAPTERS:
        page = doc.new_page()
        pno = page.number + 1
        w = page.rect.width
        page.insert_textbox(fitz.Rect(72, 70, w - 72, 110), title,
                            fontsize=18, fontname="hebo")
        page.insert_textbox(fitz.Rect(72, 120, w - 72, page.rect.height - 72), body,
                            fontsize=12, fontname="helv", lineheight=1.6)
        toc.append([1 if level is None else level, title, pno])
    doc.set_metadata({"title": "The Light Without a Keeper", "author": "A. Sample"})
    doc.set_toc(toc)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(OUT))
    doc.close()
    print(f"Wrote {OUT}  ({len(CHAPTERS)} pages, {len(toc)} outline entries)")


if __name__ == "__main__":
    main()
