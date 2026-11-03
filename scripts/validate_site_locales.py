#!/usr/bin/env python3
"""Reject incomplete public-language editions before publishing GitHub Pages."""
from __future__ import annotations

import argparse
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import unquote, urljoin, urlsplit


DOCUMENTS = {
    "privacy": "privacy-policy.md",
    "terms": "terms-of-service.md",
    "workflows": "workflows.md",
    "email": "email-setup.md",
    "changes": "changes.md",
}
HANGUL = re.compile(r"[가-힣]")
FRONTMATTER = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.S)
EXTERNAL_LINK = re.compile(r"\]\((https?://[^)]+)\)")
INLINE_CODE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")


def document(path: Path) -> tuple[dict[str, str], str]:
    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER.match(text)
    if not match:
        raise ValueError(f"{path}: missing page metadata")
    metadata = {}
    for line in match[1].splitlines():
        if ":" in line and not line.startswith((" ", "#")):
            key, value = line.split(":", 1)
            metadata[key] = value.strip().strip("\"'")
    return metadata, text[match.end():]


def structure(body: str) -> tuple[Counter, int, int]:
    headings = Counter(len(m[1]) for m in re.finditer(r"^(#{1,6})\s", body, re.M))
    rows = len(re.findall(r"^\s*\|", body, re.M))
    bullets = len(re.findall(r"^\s*[-*]\s+", body, re.M))
    return headings, rows, bullets


class Page(HTMLParser):
    def __init__(self, source: str):
        super().__init__(convert_charrefs=True)
        self.lang = ""
        self.ids = set()
        self.duplicate_ids = set()
        self.links = []
        self.navigation = []
        self.alternates = {}
        self.canonical = ""
        self.visible = []
        self.hidden_depth = 0
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "html":
            self.lang = attrs.get("lang", "")
        if tag in ("script", "style"):
            self.hidden_depth += 1
        identity = attrs.get("id")
        if identity:
            if identity in self.ids:
                self.duplicate_ids.add(identity)
            self.ids.add(identity)
        if tag in ("a", "img", "script", "link"):
            url = attrs.get("href") or attrs.get("src")
            if url:
                self.links.append(url)
        if tag == "a" and attrs.get("href") and not attrs.get("hreflang"):
            self.navigation.append(attrs["href"])
        if tag == "link" and attrs.get("rel") == "alternate":
            self.alternates[attrs.get("hreflang", "")] = attrs.get("href", "")
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href", "")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.hidden_depth = max(0, self.hidden_depth - 1)

    def handle_data(self, data):
        if not self.hidden_depth:
            self.visible.append(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("docs"))
    parser.add_argument("--site", type=Path, help="Also validate the actual rendered site")
    parser.add_argument("--release-note", type=Path, action="append", default=[],
                        help="Also require translations for a prospective authored release before publication")
    args = parser.parse_args()
    root = args.source
    errors = []

    def require(condition, message):
        if not condition:
            errors.append(message)

    registry = json.loads((root / "_data/site_i18n.json").read_text())
    languages = registry["languages"]
    require({item["code"] for item in languages} == {"ko", "en", "es", "ja", "zh-Hans", "fr", "it", "de"},
            "Locale registry must match all eight shipped app languages")
    korean = json.loads((root / "_data/locales/ko.json").read_text())
    published = json.loads((root / "_data/published_releases.json").read_text())
    release_references = dict(korean["releases"])
    release_references.update({release["tag"]: release for release in published})
    note_paths = sorted((root.parent / "release-notes").glob("*.json")) + args.release_note
    for note_path in note_paths:
        note = json.loads(note_path.read_text(encoding="utf-8"))
        # Prerelease notes are excluded from public Pages by the release pipeline.
        if "-" not in note["tag"].split("+", 1)[0]:
            release_references[note["tag"]] = note
    source_docs = {key: document(root / name)[1] for key, name in DOCUMENTS.items()}
    rendered = {}
    paths = []

    for language in languages:
        code, prefix = language["code"], language["prefix"]
        locale_file = root / "_data/locales" / f"{code}.json"
        require(locale_file.is_file(), f"Missing locale data: {locale_file}")
        if not locale_file.is_file():
            continue
        data = json.loads(locale_file.read_text())
        for section in ("common", "home"):
            require(set(data.get(section, {})) == set(korean[section]), f"{code}: {section} keys do not match Korean")
            for key, original in korean[section].items():
                value = data.get(section, {}).get(key)
                require(isinstance(value, str) and bool(value.strip()), f"{code}: missing {section}.{key}")
                if code != "ko" and HANGUL.search(original):
                    require(value != original, f"{code}: untranslated {section}.{key}")
        for tag, release in release_references.items():
            translated = data.get("releases", {}).get(tag)
            require(isinstance(translated, dict), f"{code}: release {tag} needs a translation")
            if isinstance(translated, dict):
                summary = translated.get("summary")
                details = translated.get("details")
                require(isinstance(summary, str) and bool(summary.strip()), f"{code}: missing release summary {tag}")
                require(isinstance(details, list) and len(details) == len(release.get("details", []))
                        and all(isinstance(detail, str) and bool(detail.strip()) for detail in details),
                        f"{code}: release details omitted for {tag}")
                if code != "ko":
                    require(not HANGUL.search(json.dumps(translated, ensure_ascii=False)),
                            f"{code}: Korean prose in release {tag}")
        require((root / "assets/images" / f"app-store-{code}.svg").is_file(), f"{code}: missing localized App Store badge")
        for page_key, suffix in registry["pages"].items():
            filename = "index.md" if page_key == "home" else suffix.lstrip("/").replace(".html", ".md")
            source_path = root / prefix.lstrip("/") / filename
            require(source_path.is_file(), f"Missing public page: {source_path}")
            if not source_path.is_file():
                continue
            metadata, body = document(source_path)
            expected_url = prefix + suffix
            for key, value in {"locale": code, "lang": code, "page_key": page_key, "permalink": expected_url}.items():
                require(metadata.get(key) == value, f"{source_path}: {key} must be {value}")
            require(metadata.get("layout") == ("landing" if page_key == "home" else "redirect" if page_key == "outlook" else "default"),
                    f"{source_path}: incorrect layout")
            if page_key not in ("outlook",):
                require(bool(metadata.get("title")) and bool(metadata.get("description")), f"{source_path}: missing localized search metadata")
            if code != "ko" and page_key in DOCUMENTS:
                original = source_docs[page_key]
                require(structure(body) == structure(original), f"{source_path}: sections, table rows or bullets differ from source")
                require(Counter(EXTERNAL_LINK.findall(body)) == Counter(EXTERNAL_LINK.findall(original)),
                        f"{source_path}: external legal/help links differ from source")
                require(Counter(INLINE_CODE.findall(body)) == Counter(INLINE_CODE.findall(original)),
                        f"{source_path}: technical identifiers or code examples differ from source")
                require(not HANGUL.search(body), f"{source_path}: untranslated Korean prose")
            paths.append((code, expected_url))
            if args.site:
                output = args.site / expected_url.lstrip("/")
                if expected_url.endswith("/"):
                    output /= "index.html"
                require(output.is_file(), f"Rendered page missing: {expected_url}")
                if output.is_file():
                    page = Page(output.read_text())
                    rendered[expected_url] = page
                    require(page.lang == code, f"{expected_url}: wrong HTML language {page.lang}")
                    require(not page.duplicate_ids, f"{expected_url}: duplicate anchors {page.duplicate_ids}")
                    require("{{" not in output.read_text() and "{%" not in output.read_text(), f"{expected_url}: unrendered template")
                    if page_key != "outlook":
                        require(urlsplit(page.canonical).path == expected_url, f"{expected_url}: incorrect canonical URL")
                        for alternate in languages:
                            require(urlsplit(page.alternates.get(alternate["code"], "")).path == alternate["prefix"] + suffix,
                                    f"{expected_url}: missing/wrong hreflang {alternate['code']}")
                        require(urlsplit(page.alternates.get("x-default", "")).path == suffix, f"{expected_url}: missing Korean default")
                        if code != "ko":
                            visible = " ".join(page.visible)
                            for option in languages:
                                visible = visible.replace(option["name"], "")
                            require(not HANGUL.search(visible), f"{expected_url}: Korean visible content")

    if args.site:
        locale_paths = {
            language["code"]: {language["prefix"] + suffix for suffix in registry["pages"].values()}
            for language in languages
        }
        public_paths = set().union(*locale_paths.values())
        for code, page_url in paths:
            page = rendered.get(page_url)
            if not page:
                continue
            for link in page.links:
                target = urlsplit(urljoin("https://sift.pieroot.xyz" + page_url, link))
                if target.scheme not in ("http", "https") or target.netloc != "sift.pieroot.xyz":
                    continue
                target_path = unquote(target.path)
                output = args.site / target_path.lstrip("/")
                if target_path.endswith("/"):
                    output /= "index.html"
                require(output.is_file(), f"{page_url}: broken local link {link}")
                if target.fragment and output.is_file() and output.suffix == ".html":
                    target_page = rendered.get(target_path) or Page(output.read_text())
                    require(unquote(target.fragment) in target_page.ids, f"{page_url}: missing anchor {link}")
            for link in page.navigation:
                target = urlsplit(urljoin("https://sift.pieroot.xyz" + page_url, link))
                if target.netloc == "sift.pieroot.xyz" and target.path in public_paths:
                    require(target.path in locale_paths[code], f"{page_url}: changes language without explicit choice: {link}")
    if errors:
        for error in errors:
            print("ERROR:", error)
        return 1
    print(f"Validated {len(languages)} locales and {len(paths)} public pages" + (" with rendered links, anchors and metadata." if args.site else "."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
