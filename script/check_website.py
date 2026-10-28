#!/usr/bin/env python3
"""Small static checks for the standalone GitHub Pages website."""
from __future__ import annotations

import argparse
import html.parser
import re
import socket
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "website"
PAGES = (WEB / "index.html", WEB / "legal.html")
FORBIDDEN = ("MacDictate", "Whisper", "Windows", "releases/latest", "/Users/")


class PageParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.links: list[str] = []
        self.ids: set[str] = set()
        self.duplicate_ids: set[str] = set()
        self.scripts: list[str] = []
        self.in_script = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr = dict(attrs)
        for key in ("href", "src"):
            if value := attr.get(key):
                self.links.append(value)
        if ident := attr.get("id"):
            if ident in self.ids:
                self.duplicate_ids.add(ident)
            self.ids.add(ident)
        if tag == "script" and not attr.get("src"):
            self.in_script = True

    def handle_endtag(self, tag: str) -> None:
        if tag == "script":
            self.in_script = False

    def handle_data(self, data: str) -> None:
        if self.in_script:
            self.scripts.append(data)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def check_published_asset(url: str) -> None:
    request = Request(url, method="HEAD")
    try:
        with urlopen(request, timeout=20) as response:
            if response.status != 200:
                fail(f"published alpha.19 archive returned HTTP {response.status}")
            content_length = response.headers.get("Content-Length")
            if content_length is not None:
                try:
                    size = int(content_length)
                except ValueError:
                    fail("published alpha.19 archive has an invalid Content-Length")
                if size <= 0:
                    fail("published alpha.19 archive is empty")
    except HTTPError as error:
        fail(f"published alpha.19 archive returned HTTP {error.code}")
    except (TimeoutError, socket.timeout):
        fail("timed out checking published alpha.19 archive")
    except (URLError, OSError):
        fail("could not check published alpha.19 archive (network error)")


def main() -> None:
    args = argparse.ArgumentParser()
    args.add_argument("--javascript", action="store_true", help="also parse inline JavaScript with Node")
    args.add_argument("--published-release", action="store_true", help="require the linked alpha.19 archive to be published and nonempty")
    options = args.parse_args()
    parsed: dict[Path, PageParser] = {}
    for page in PAGES:
        if not page.is_file():
            fail(f"missing page: {page.relative_to(ROOT)}")
        source = page.read_text(encoding="utf-8")
        for marker in FORBIDDEN:
            if marker in source:
                fail(f"forbidden product/reference marker {marker!r} in {page.relative_to(ROOT)}")
        if "https://cdn.tailwindcss.com" in source:
            fail("website must not depend on Tailwind CDN")
        parser = PageParser()
        parser.feed(source)
        if parser.duplicate_ids:
            fail(f"duplicate IDs in {page.name}: {sorted(parser.duplicate_ids)}")
        parsed[page] = parser
    for page, parser in parsed.items():
        for raw in parser.links:
            url = urlparse(raw)
            if url.scheme or url.netloc:
                continue
            target = (page.parent / unquote(url.path or page.name)).resolve()
            if not target.is_relative_to(WEB.resolve()):
                fail(f"local link escapes website in {page.name}: {raw}")
            if not target.is_file():
                fail(f"broken local link in {page.name}: {raw}")
            if url.fragment:
                target_parser = parsed.get(target)
                if target_parser and unquote(url.fragment) not in target_parser.ids:
                    fail(f"broken anchor in {page.name}: {raw}")
    if not (WEB / "assets/MacSwitcher.svg").is_file():
        fail("missing product mark")
    canonical_mark = (ROOT / "assets/MacSwitcher.svg").read_bytes()
    website_mark = (WEB / "assets/MacSwitcher.svg").read_bytes()
    if canonical_mark != website_mark:
        fail("website product mark differs from canonical assets/MacSwitcher.svg")
    index_source = (WEB / "index.html").read_text(encoding="utf-8")
    download_url = "https://github.com/alexfisenkov/MacSwitcher/releases/download/v0.1.0-alpha.19/MacSwitcher-0.1.0-alpha.19-universal.zip"
    if index_source.count(download_url) != 2:
        fail("expected alpha.19 universal download link in hero and setup sections")
    if "releases/latest" in index_source or "MacSwitcher_Windows" in index_source:
        fail("release link must target the explicit prerelease and macOS archive")
    if options.published_release:
        check_published_asset(download_url)
    if options.javascript:
        node = __import__("shutil").which("node")
        if not node:
            fail("node is required for --javascript")
        for page, parser in parsed.items():
            for i, script in enumerate(parser.scripts, 1):
                result = subprocess.run([node, "--check", "--input-type=commonjs"], input=script, text=True, capture_output=True)
                if result.returncode:
                    fail(f"JavaScript syntax error in {page.name} inline script {i}: {result.stderr.strip()}")
    print(f"PASS: {len(PAGES)} HTML pages, local links, anchors, and product asset")
    if options.javascript:
        print("PASS: inline JavaScript syntax")
    if options.published_release:
        print("PASS: linked alpha.19 archive is published")


if __name__ == "__main__":
    main()
