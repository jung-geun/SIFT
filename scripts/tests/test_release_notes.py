"""Offline fixtures only: synthetic tags here are not release-history claims."""
import copy
import datetime as dt
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_notes as notes

ROOT = Path(__file__).resolve().parents[2]
HISTORICAL_FIXTURE_SHA = "0a4e29337262f402da4129cb090ca2833c78fcff"


def record(tag="9.8.7"):
    return {"tag": tag, "date": "2000-01-01", "summary": "할 일 입력을 개선했습니다.",
            "details": ["날짜를 편하게 선택할 수 있습니다."]}


def release(value=None, **overrides):
    value = value or record()
    # Independently shaped API response; never echo the request under test.
    body = (f'<!-- sift-release-notes:1 -->\n## SIFT {value["tag"]}\n\n'
            f'{value["date"]}\n\n{value["summary"]}\n')
    if value["details"]:
        body += "\n" + "".join(f"- {item}\n" for item in value["details"])
    return {"id": 73, "tag_name": value["tag"], "name": f'SIFT {value["tag"]}', "body": body,
            "published_at": "2000-01-02T00:00:00Z", "draft": False, "prerelease": False, **overrides}


class FakeGitHub:
    def __init__(self, commits, response=None, existing=None):
        self.commits = commits
        self.response = response or release()
        self.existing = existing
        self.posts = []

    def tag_commit(self, tag):
        if tag not in self.commits:
            raise ValueError("missing remote tag")
        return self.commits[tag]

    def request(self, path, payload=None, missing_ok=False):
        if path == "/releases/tags/" + self.response["tag_name"] and payload is None and missing_ok:
            return copy.deepcopy(self.existing)
        if path == "/releases" and payload is not None:
            self.posts.append(copy.deepcopy(payload))
            self.existing = copy.deepcopy(self.response)
            return copy.deepcopy(self.response)
        raise AssertionError(f"Unexpected API request: {path}")


class NotesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="sift-release-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.folder = self.root / "release-notes"
        self.folder.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Release fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.commits = {}
        self.snapshot(record())

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", *args],
            cwd=self.root, text=True, stderr=subprocess.PIPE,
        ).strip()

    def write_record(self, value):
        (self.folder / f'{value["tag"]}.json').write_text(json.dumps(value), encoding="utf-8")

    def commit(self):
        self.git("add", "release-notes")
        self.git("commit", "--allow-empty", "-qm", "Fixture snapshot")

    def snapshot(self, value, include_notes=True):
        if include_notes:
            self.write_record(value)
        self.commit()
        self.git("tag", value["tag"])
        self.commits[value["tag"]] = self.git("rev-parse", f'refs/tags/{value["tag"]}^{{commit}}')

    def export(self, values, required=None):
        return notes.public_records(values, FakeGitHub(self.commits).tag_commit, self.folder, required)

    def test_invalid_semver_tags_rejected(self):
        for tag in ["01.0.5", "v1.2", "v1.2.3-01", "../1.2.3", "1.2.3\n", "v1.2.3-", "v1.2.3+"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                notes.version(tag)

    def test_note_body_round_trip(self):
        for value in [record(), {**record(), "details": []}]:
            self.assertEqual(notes.parse_body(notes.body(value), value["tag"]), value)

    def test_invalid_records(self):
        for change in [{"tag": "9.8.6"}, {"date": "2099-01-01"}, {"date": "2000-02-30"},
                       {"date": "2000-1-1"}, {"summary": ""}, {"summary": "x" * 221},
                       {"details": ["x"] * 6}, {"details": "wrong"}, {"extra": "internal"}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                notes.validate({**record(), **change}, "9.8.7")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            notes.load_notes('{"tag":"9.8.7","tag":"9.8.6"}')

    def test_private_material_and_markup_rejected(self):
        for private in ["https://github.com/private/repo", "[private](url)", "<script>alert(1)</script>",
                        "ios/UI_TEST_PLAN.md", "/tmp/run.xcresult", "docs/internal/history.md",
                        "details\nnew line", "{{ site.secret }}", "x\u202ey", "x\u2028y"]:
            with self.subTest(private=private), self.assertRaises(ValueError):
                notes.validate({**record(), "summary": private}, "9.8.7")
        for extra in ["\nextra text", "\n<!-- hidden -->", "\n- https://github.com/private/repo", "\n"]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                notes.parse_body(notes.body(record()) + extra, "9.8.7")
        with self.assertRaises(ValueError):
            notes.parse_body(notes.body(record()).replace("## SIFT 9.8.7", "## SIFT 9.8.6"), "9.8.7")

    def test_ordinary_wording_and_unicode_are_not_editorially_filtered(self):
        for summary in ["테스트 기능을 개선했습니다.", "TODO 입력 & 알림", "iPhone/iPad에서 편하게 사용할 수 있습니다."]:
            value = {**record(), "summary": summary}
            self.assertEqual(notes.parse_body(notes.body(value), value["tag"]), value)

    def test_kst_calendar_boundary_is_consistent(self):
        frozen = dt.datetime(2026, 6, 29, 16, 30, tzinfo=dt.timezone.utc)
        class FrozenDatetime(dt.datetime):
            @classmethod
            def now(cls, tz=None):
                return frozen.astimezone(tz)
        value = {**record("9.8.8"), "date": "2026-06-30"}
        self.snapshot(value)
        with patch.object(notes.dt, "datetime", FrozenDatetime):
            for timestamp in ["2026-06-29T16:15:00Z", "2026-06-30T01:15:00+09:00"]:
                with self.subTest(timestamp=timestamp):
                    self.assertEqual(self.export([release(value, published_at=timestamp)]), [value])
            with self.assertRaisesRegex(ValueError, "future"):
                notes.validate({**value, "date": "2026-07-01"}, value["tag"])
            with self.assertRaisesRegex(ValueError, "after publication"):
                self.export([release(value, published_at="2026-06-29T14:59:00Z")])

    def test_only_published_releases_and_existing_tags(self):
        items = [release(), release(draft=True, body="private draft"),
                 release(prerelease=True, body="private beta"),
                 release(tag_name="development", body="internal log")]
        self.assertEqual(self.export(items, "9.8.7"), [record()])
        self.assertEqual(self.export([]), [])
        with self.assertRaisesRegex(ValueError, "absent"):
            self.export([], "9.8.7")
        self.commits.clear()
        with self.assertRaisesRegex(ValueError, "missing remote tag"):
            self.export([release()])

    def test_invalid_published_release_fails_closed(self):
        for change in [{"body": "unversioned development history"}, {"published_at": None},
                       {"published_at": "2000-01-02"}, {"published_at": "1999-01-01T00:00:00Z"},
                       {"published_at": "2099-01-01T00:00:00Z"}, {"draft": "false"},
                       {"tag_name": "9.8.7-rc.1"}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.export([release(**change)])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.export([release(), release()])

    def test_semantic_sort(self):
        values = [record("9.8.9"), record("9.8.10")]
        for value in values:
            self.snapshot(value)
        self.assertEqual([r["tag"] for r in self.export([release(v) for v in values])], ["9.8.10", "9.8.9"])

    def test_api_pagination_and_annotated_tags(self):
        api = notes.GitHub.__new__(notes.GitHub)
        expected = [{"id": number} for number in range(101)]
        responses = {"/releases?per_page=100&page=1": expected[:100],
                     "/releases?per_page=100&page=2": expected[100:],
                     "/git/ref/tags/v9.8.7": {"object": {"type": "tag", "sha": "b" * 40}},
                     "/git/tags/" + "b" * 40: {"object": {"type": "commit", "sha": "a" * 40}}}
        with patch.object(api, "request", side_effect=responses.__getitem__):
            self.assertEqual(api.releases(), expected)
            self.assertEqual(api.tag_commit("v9.8.7"), "a" * 40)

    def test_publish_is_idempotent_and_does_not_overwrite(self):
        api = FakeGitHub(self.commits)
        self.assertEqual(notes.publish(api, "9.8.7", self.folder)["id"], 73)
        notes.publish(api, "9.8.7", self.folder)
        expected = {key: release()[key] for key in ("tag_name", "name", "body", "draft", "prerelease")}
        self.assertEqual(api.posts, [{**expected, "generate_release_notes": False, "make_latest": "legacy"}])
        api.existing["body"] = "different notes"
        with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
            notes.publish(api, "9.8.7", self.folder)
        self.assertEqual(len(api.posts), 1)

    def test_missing_or_invalid_authored_notes_never_publish(self):
        api = FakeGitHub(self.commits)
        with self.assertRaisesRegex(ValueError, "Missing authored notes"):
            notes.publish(api, "9.8.8", self.folder)
        self.write_record({**record(), "summary": "https://github.com/private/repo"})
        with self.assertRaises(ValueError):
            notes.publish(api, "9.8.7", self.folder)
        self.assertEqual(api.posts, [])

    def test_remote_and_local_tag_mismatch_blocks_publish_and_export(self):
        api = FakeGitHub({"9.8.7": "b" * 40})
        with self.assertRaisesRegex(ValueError, "snapshots differ"):
            notes.publish(api, "9.8.7", self.folder)
        with self.assertRaisesRegex(ValueError, "snapshots differ"):
            notes.public_records([release()], api.tag_commit, self.folder)
        self.assertEqual(api.posts, [])

    def test_notes_added_after_tag_are_not_tagged_notes(self):
        value = record("9.8.8")
        self.snapshot(value, include_notes=False)
        self.write_record(value)
        self.commit()  # HEAD has notes, but the actual tag does not.
        api = FakeGitHub(self.commits, release(value))
        with self.assertRaisesRegex(ValueError, "included in the tagged snapshot"):
            notes.publish(api, value["tag"], self.folder)
        with self.assertRaisesRegex(ValueError, "included in the tagged snapshot"):
            self.export([release(value)])
        self.assertEqual(api.posts, [])

    def test_main_notes_changed_after_tag_block_publish_and_export(self):
        changed = {**record(), "summary": "태그 이후 수정한 설명입니다."}
        self.write_record(changed)
        self.commit()
        api = FakeGitHub(self.commits, release(changed))
        with self.assertRaisesRegex(ValueError, "tagged notes differ"):
            notes.publish(api, changed["tag"], self.folder)
        with self.assertRaisesRegex(ValueError, "tagged notes differ"):
            self.export([release(changed)])
        self.assertEqual(api.posts, [])

    def test_release_edit_cannot_replace_recorded_notes(self):
        changed = {**record(), "summary": "기록에 없는 릴리스 설명입니다."}
        with self.assertRaisesRegex(ValueError, "published notes differ"):
            self.export([release(changed)])
        self.assertEqual(self.export([release()]), [record()])

    def test_release_without_authored_main_notes_is_not_exported(self):
        value = record("9.8.8")
        self.snapshot(value, include_notes=False)
        with self.assertRaisesRegex(ValueError, "Missing authored notes"):
            self.export([release(value)])

    def test_historical_exception_requires_exact_known_commit(self):
        value = notes.authored(ROOT / "release-notes/1.0.5.json", "1.0.5")
        response = release(value, published_at="2026-10-01T00:00:00Z")
        api = FakeGitHub({"1.0.5": HISTORICAL_FIXTURE_SHA}, response)
        with patch.object(subprocess, "check_output", return_value=HISTORICAL_FIXTURE_SHA):
            self.assertEqual(notes.public_records([response], api.tag_commit, ROOT / "release-notes"), [value])
            notes.publish(api, "1.0.5", ROOT / "release-notes")
        self.assertEqual(api.posts[0]["make_latest"], "false")
        wrong = FakeGitHub({"1.0.5": "b" * 40}, response)
        with patch.object(subprocess, "check_output", return_value="b" * 40):
            with self.assertRaisesRegex(ValueError, "Historical 1.0.5 tag snapshot"):
                notes.publish(wrong, "1.0.5", ROOT / "release-notes")
            with self.assertRaisesRegex(ValueError, "Historical 1.0.5 tag snapshot"):
                notes.public_records([response], wrong.tag_commit, ROOT / "release-notes")
        self.assertEqual(wrong.posts, [])

    def test_tag_prerelease_is_not_public_or_latest(self):
        value = record("9.8.7-rc.1")
        self.snapshot(value)
        api = FakeGitHub(self.commits, release(value, prerelease=True))
        notes.publish(api, value["tag"], self.folder)
        self.assertTrue(api.posts[0]["prerelease"])
        self.assertEqual(api.posts[0]["make_latest"], "false")
        self.assertEqual(self.export([release(value, prerelease=True)], value["tag"]), [])


if __name__ == "__main__":
    unittest.main()
