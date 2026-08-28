#!/usr/bin/env python3
"""Turn HTML on stdin into readable plain text on stdout.

Standard library only, deliberately: this plugin already asks for ffmpeg,
jq and a TTS engine, and reading a web page is not worth another
dependency. Good enough to read an article, a changelog or a router status
page — not a browser, and no JavaScript.
"""
import re
import sys
from html.parser import HTMLParser

# Dropped entirely, contents and all. Only elements that actually have a
# closing tag belong here: a void element never fires handle_endtag, so
# putting one in this set would open a skip region that never closes and
# swallow the rest of the document.
SKIP = {"script", "style", "noscript", "svg", "canvas", "template",
        "iframe", "object", "nav", "footer"}

# Force a line break so the text keeps the page's shape.
BLOCK = {"p", "div", "section", "article", "header", "aside", "main",
         "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "br", "hr",
         "blockquote", "pre", "table", "ul", "ol", "dl", "dt", "dd", "form",
         "figure", "figcaption"}

# When a page marks its own content region we take that instead of the whole
# body. On a news front page the difference is the lead stories rather than
# forty lines of menus and an ad-feedback survey.
CONTENT = {"main", "article"}


class Extract(HTMLParser):
    def __init__(self):
        # convert_charrefs resolves &amp; and friends for us.
        super().__init__(convert_charrefs=True)
        self.out = []
        self.title = []
        self.content = []
        self.skip_depth = 0
        self.content_depth = 0
        self.in_title = False

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag == "title":
            self.in_title = True
            return
        if tag in CONTENT:
            self.content_depth += 1
        if tag in BLOCK:
            self.emit("\n")
        if tag == "li":
            self.emit("- ")

    def handle_startendtag(self, tag, attrs):
        # Self-closing: never opens a skip region.
        if tag in BLOCK and not self.skip_depth:
            self.emit("\n")

    def handle_endtag(self, tag):
        if tag in SKIP:
            self.skip_depth = max(0, self.skip_depth - 1)
            return
        if self.skip_depth:
            return
        if tag == "title":
            self.in_title = False
            return
        if tag in BLOCK:
            self.emit("\n")
        if tag in CONTENT:
            self.content_depth = max(0, self.content_depth - 1)

    def emit(self, text):
        self.out.append(text)
        if self.content_depth:
            self.content.append(text)

    def handle_data(self, data):
        if self.skip_depth:
            return
        if self.in_title:
            self.title.append(data)
            return
        self.emit(data)


def main():
    raw = sys.stdin.buffer.read()
    # Prefer the charset the document declares; fall back to utf-8 and
    # never fail on a stray byte.
    encoding = "utf-8"
    head = raw[:4096].decode("ascii", "replace").lower()
    m = re.search(r'charset=["\']?([a-z0-9_\-]+)', head)
    if m:
        encoding = m.group(1)
    try:
        text = raw.decode(encoding, "replace")
    except LookupError:
        text = raw.decode("utf-8", "replace")

    parser = Extract()
    try:
        parser.feed(text)
    except Exception:
        pass  # keep whatever parsed before the malformed markup

    # Prefer the page's own content region, but only when it actually holds
    # something — plenty of pages open a <main> and fill it from JavaScript.
    inner = "".join(parser.content)
    body = inner if len(inner.strip()) > 200 else "".join(parser.out)
    body = re.sub(r"[ \t\r\f\v]+", " ", body)
    body = re.sub(r" *\n *", "\n", body)
    body = re.sub(r"\n{3,}", "\n\n", body).strip()

    title = " ".join("".join(parser.title).split())
    if title:
        print(title)
        print("=" * min(len(title), 60))
    print(body)


if __name__ == "__main__":
    main()
