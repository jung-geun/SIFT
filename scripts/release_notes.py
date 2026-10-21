#!/usr/bin/env python3
"""Curated release publication and public Pages data (Python standard library only)."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


SEMVER = re.compile(
    r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
)
HISTORICAL_TAG = "1.0.5"
HISTORICAL_SHA = "0a4e29337262f402da4129cb090ca2833c78fcff"
HEADER = "<!-- sift-release-notes:1 -->\n"
RELEASE_TIMEZONE = dt.timezone(dt.timedelta(hours=9), name="KST")
INTERNAL_ARTIFACT = re.compile(
    r"https?://|www\.|github\.com|localhost|"
    r"(?:^|[\s(])(?:/?(?:docs|ios|android|scripts|backend|tmp|Users|\.github)/\S+)|"
    r"\b[\w.-]+\.(?:xcresult|swift|ya?ml|md|log)\b", re.IGNORECASE
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(tag):
    require(isinstance(tag, str) and SEMVER.fullmatch(tag), f"Invalid SemVer tag: {tag!r}")
    return SEMVER.fullmatch(tag)


def text(value, label, maximum):
    require(isinstance(value, str) and 1 <= len(value) <= maximum, f"Invalid {label} length")
    require(value == value.strip(), f"{label}: surrounding whitespace is not allowed")
    require(all(not unicodedata.category(c).startswith("C")
                and unicodedata.category(c) not in {"Zl", "Zp"} and c not in "<>[]{}\\`" for c in value),
            f"{label}: use single-line plain text without markup or control characters")
    require(not INTERNAL_ARTIFACT.search(value), f"{label}: links and source artifacts are not public release copy")
    return value


def validate(record, tag):
    version(tag)
    require(isinstance(record, dict) and set(record) == {"tag", "date", "summary", "details"},
            "Notes require exactly tag, date, summary and details")
    require(record["tag"] == tag, f"Notes tag must match {tag}")
    date = record["date"]
    require(isinstance(date, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date), "Invalid notes date")
    require(dt.date.fromisoformat(date) <= dt.datetime.now(RELEASE_TIMEZONE).date(), "Notes date is in the future")
    text(record["summary"], "summary", 220)
    require(isinstance(record["details"], list) and len(record["details"]) <= 5, "At most five details are allowed")
    for detail in record["details"]:
        text(detail, "detail", 240)
    return record


def body(record):
    validate(record, record["tag"])
    result = f'{HEADER}## SIFT {record["tag"]}\n\n{record["date"]}\n\n{record["summary"]}\n'
    if record["details"]:
        result += "\n" + "".join(f"- {item}\n" for item in record["details"])
    return result


def parse_body(value, tag):
    require(isinstance(value, str) and value.startswith(HEADER), f"{tag}: missing curated notes marker")
    lines = value[len(HEADER):].splitlines()
    require(len(lines) >= 5 and lines[0] == f"## SIFT {tag}" and lines[1] == lines[3] == "",
            f"{tag}: invalid curated release body")
    details = []
    if len(lines) > 5:
        require(lines[5] == "" and all(line.startswith("- ") for line in lines[6:]), f"{tag}: invalid details")
        details = [line[2:] for line in lines[6:]]
    record = validate({"tag": tag, "date": lines[2], "summary": lines[4], "details": details}, tag)
    require(value == body(record), f"{tag}: body must exactly match the curated format")
    return record


class GitHub:
    def __init__(self, repo):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "Invalid repository")
        self.base = f"https://api.github.com/repos/{repo}"
        self.token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        require(self.token, "GH_TOKEN or GITHUB_TOKEN is required")

    def request(self, path, payload=None, missing_ok=False):
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "sift-release-notes"}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        request = urllib.request.Request(self.base + path, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing_ok:
                return None
            raise ValueError(f"GitHub API {path}: HTTP {error.code}") from error

    def tag_commit(self, tag):
        ref = self.request("/git/ref/tags/" + urllib.parse.quote(tag, safe=""))
        obj = ref["object"]
        for _ in range(16):
            if obj["type"] == "commit":
                return obj["sha"]
            require(obj["type"] == "tag", f"{tag}: tag does not resolve to a commit")
            obj = self.request("/git/tags/" + obj["sha"])["object"]
        raise ValueError(f"{tag}: tag nesting is too deep")

    def releases(self):
        result = []
        page = 1
        while True:
            items = self.request(f"/releases?per_page=100&page={page}")
            require(isinstance(items, list), "Invalid releases API response")
            result.extend(items)
            if len(items) < 100:
                return result
            page += 1


def load_notes(value):
    def unique_fields(pairs):
        result = {}
        for key, item in pairs:
            require(key not in result, f"Duplicate notes field: {key}")
            result[key] = item
        return result
    return json.loads(value, object_pairs_hook=unique_fields)


def authored(path, tag):
    require(path.is_file(), f"Missing authored notes: {path}; author matching notes before publishing {tag}")
    return validate(load_notes(path.read_text(encoding="utf-8")), tag)


def authored_snapshot(tag, notes_dir, tag_commit):
    version(tag)
    record = authored(notes_dir / f"{tag}.json", tag)
    sha = tag_commit(tag)  # Never let the Releases API silently create a missing tag.
    try:
        local_sha = subprocess.check_output(
            ["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"],
            cwd=notes_dir.resolve().parent, text=True, stderr=subprocess.PIPE,
        ).strip()
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{tag}: the fetched tag snapshot is missing") from error
    require(sha == local_sha, f"{tag}: local and remote tag snapshots differ")
    if tag == HISTORICAL_TAG:
        require(sha == HISTORICAL_SHA, "Historical 1.0.5 tag snapshot has changed")
    else:
        try:
            tagged = subprocess.check_output(
                ["git", "show", f"refs/tags/{tag}:release-notes/{tag}.json"],
                cwd=notes_dir.resolve().parent, text=True, stderr=subprocess.PIPE,
            )
        except subprocess.CalledProcessError as error:
            raise ValueError(f"{tag}: authored notes must be included in the tagged snapshot") from error
        require(validate(load_notes(tagged), tag) == record, f"{tag}: tagged notes differ from main notes")
    return record


def publish(api, tag, notes_dir):
    record = authored_snapshot(tag, notes_dir, api.tag_commit)
    expected = {"tag_name": tag, "name": f"SIFT {tag}", "body": body(record),
                "draft": False, "prerelease": bool(version(tag)[4])}
    existing = api.request("/releases/tags/" + urllib.parse.quote(tag, safe=""), missing_ok=True)
    if existing is not None:
        require(all(existing.get(key) == value for key, value in expected.items()),
                f"{tag}: an existing release differs from authored notes; refusing to overwrite it")
        print(f"Release {tag} already matches; refreshing Pages")
        return existing
    latest = "false" if tag == HISTORICAL_TAG or expected["prerelease"] else "legacy"
    result = api.request("/releases", {**expected, "generate_release_notes": False, "make_latest": latest})
    require(all(result.get(key) == value for key, value in expected.items()), f"{tag}: unexpected published release")
    print(f"Published release {tag}; Pages must complete in the chained job")
    return result


def public_records(releases, tag_commit, notes_dir, required_tag=None):
    result = []
    seen = set()
    for release in releases:
        require(isinstance(release, dict) and type(release.get("draft")) is bool
                and type(release.get("prerelease")) is bool, "Invalid release visibility metadata")
        if release["draft"] or release["prerelease"]:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not SEMVER.fullmatch(tag):
            continue  # Non-version announcements are not app releases.
        require(not version(tag)[4], f"{tag}: prerelease tag must be marked prerelease")
        require(tag not in seen, f"Duplicate published release: {tag}")
        published = release.get("published_at")
        require(isinstance(published, str), f"{tag}: release is not published")
        timestamp = dt.datetime.fromisoformat(published.replace("Z", "+00:00"))
        require(timestamp.tzinfo is not None and timestamp <= dt.datetime.now(dt.timezone.utc),
                f"{tag}: invalid publication timestamp")
        record = parse_body(release.get("body"), tag)
        require(record == authored_snapshot(tag, notes_dir, tag_commit),
                f"{tag}: published notes differ from authored snapshot notes")
        require(dt.date.fromisoformat(record["date"]) <= timestamp.astimezone(RELEASE_TIMEZONE).date(),
                f"{tag}: notes date is after publication in KST")
        result.append(record)
        seen.add(tag)
    if required_tag and not version(required_tag)[4]:
        require(required_tag in seen, f"Required published release {required_tag} is absent; refusing a stale Pages build")
    return sorted(result, key=lambda r: (tuple(int(x) for x in version(r["tag"]).group(1, 2, 3)), r["tag"]), reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "publish", "fetch"])
    parser.add_argument("--tag")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "jung-geun/SIFT"))
    parser.add_argument("--notes-dir", type=Path, default=Path("release-notes"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--required-tag")
    args = parser.parse_args()
    if args.command in {"validate", "publish"}:
        require(args.tag, "--tag is required")
        if args.command == "validate":
            print(body(authored(args.notes_dir / f"{args.tag}.json", args.tag)), end="")
        else:
            publish(GitHub(args.repo), args.tag, args.notes_dir)
    else:
        require(args.output, "--output is required")
        api = GitHub(args.repo)
        records = public_records(api.releases(), api.tag_commit, args.notes_dir, args.required_tag)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Generated {len(records)} published release records")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        sys.exit(f"Release notes error: {error}")
