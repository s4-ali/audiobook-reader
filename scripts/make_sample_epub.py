"""Generate a small multi-chapter sample EPUB (with a nav TOC) for testing.

    .venv/bin/python scripts/make_sample_epub.py
writes library/inbox/sample-book.epub
"""
from pathlib import Path

from ebooklib import epub

OUT = Path(__file__).resolve().parent.parent / "library" / "inbox" / "sample-book.epub"

CHAPTERS = [
    ("c1.xhtml", "Chapter 1: The Glass Garden",
     "<h1>Chapter 1: The Glass Garden</h1>"
     "<p>The garden slept under glass. Every morning the light slid across the panes "
     "and woke the ferns one by one.</p>"
     "<h2 id='rose'>A Quiet Corner</h2>"
     "<p>In the far corner grew a single white rose. It had no name, and no one came "
     "to see it but the rain.</p>"),
    ("c2.xhtml", "Chapter 2: Roots",
     "<h1>Chapter 2: Roots</h1>"
     "<p>Beneath the soil the roots remembered every season. They spread in silence, "
     "patient as stone.</p>"
     "<p>When the frost came, they held the whole garden together and waited for spring.</p>"),
    ("c3.xhtml", "Chapter 3: The Door in the Wall",
     "<h1>Chapter 3: The Door in the Wall</h1>"
     "<p>At the end of the path stood a small green door. It had been painted shut for "
     "as long as anyone could remember.</p>"
     "<p>One evening it swung open on its own, and the garden breathed out.</p>"),
]


def main():
    book = epub.EpubBook()
    book.set_identifier("sample-glass-garden")
    book.set_title("The Glass Garden")
    book.add_author("A. Sample")
    book.set_language("en")

    items = []
    for fname, title, html in CHAPTERS:
        c = epub.EpubHtml(title=title, file_name=fname, lang="en")
        c.content = f"<html><body>{html}</body></html>"
        book.add_item(c)
        items.append(c)

    # Chapter 1 has a nested sub-topic; the others are plain chapters.
    book.toc = [
        (epub.Section("Chapter 1: The Glass Garden", href="c1.xhtml"),
         [epub.Link("c1.xhtml#rose", "A Quiet Corner", "rose")]),
        epub.Link("c2.xhtml", "Chapter 2: Roots", "c2"),
        epub.Link("c3.xhtml", "Chapter 3: The Door in the Wall", "c3"),
    ]
    book.add_item(epub.EpubNcx())
    book.add_item(epub.EpubNav())
    book.spine = items

    OUT.parent.mkdir(parents=True, exist_ok=True)
    epub.write_epub(str(OUT), book)
    print(f"Wrote {OUT}  ({len(CHAPTERS)} chapters, 1 nested topic)")


if __name__ == "__main__":
    main()
