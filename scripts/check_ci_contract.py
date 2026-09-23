#!/usr/bin/env python3
"""CI shape contract checker (CI rule 11: pin the CI shape with a repository test).

The iOS CI was falsely green for months because `xcodebuild ... | xcpretty ||
xcodebuild ...` ran without pipefail. This checker pins the invariants that the
fix relies on, so reverting one of them fails a check instead of silently
turning CI green again:

  * ci.yml runs every step with `bash` (GitHub runs it as `bash -eo pipefail`).
  * No workflow step that runs xcodebuild uses `||` or continue-on-error, or
    turns errexit/pipefail off with `set` (a `+` option cluster that contains
    `e`, such as `set +e`, `set +ex` or `set +eo pipefail`, or `set +o errexit`
    / `set +o pipefail`). A step that runs xcodebuild and contains any pipe
    (also one on a later line, as in `{ xcodebuild ...; } | cat`) must run
    with pipefail.
  * The fail-closed 'Require executed tests' gate exists, has no `if:` or
    continue-on-error, runs after the test step and has exactly the pinned
    shape: read the result bundle, `if ! jq -e '.result == "Passed" and
    .passedTests >= N' ...; then` with N >= 1, optional `echo "..."` lines,
    `exit 1` as its own line, `fi`.
  * The test selector, result bundle path, parallel-testing shape and the
    integrity-check -> -skipMacroValidation order in ci.yml.
  * ci.yml, meeting-api.yml and ci-contract.yml: the exact trigger paths,
    `permissions: contents: read`, concurrency, `persist-credentials: false`,
    no job-level `if:` or `needs:`, a GitHub-hosted `runs-on` label
    (`macos-*` / `ubuntu-*`), no `${{ }}` expression inside a `run:` body and
    no `secrets` / `github.token` expression anywhere.
  * backend/meeting-api: the unit vitest config excludes test/integration/**,
    the integration config includes only test/integration/**, neither config
    sets passWithNoTests, and the npm scripts and meeting-api.yml steps (with
    no `if:`) still run them.

It uses only the Python standard library (3.9+). The YAML reader accepts only
the block-style subset these workflows use and raises on anything else
(anchors, tags, folded scalars, flow mappings, tabs, duplicate keys, ...), so an
unsupported construct fails the check instead of being skipped.

Usage: python3 scripts/check_ci_contract.py [--root DIR]
Exit status: 0 when the contract holds, 1 when any violation is found.
Mutation tests: scripts/test_check_ci_contract.py.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, NamedTuple, NoReturn, Optional, Tuple

# --------------------------------------------------------------------------
# Strict YAML subset reader
# --------------------------------------------------------------------------


class YamlSubsetError(ValueError):
    """The text uses YAML outside the supported subset (fail closed)."""


_KEY_RE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_.\-/]*) *:(?: +(.*))?")
_DQ_ESCAPES = {'"': '"', "\\": "\\", "/": "/", "n": "\n", "t": "\t"}


class _Parser:
    def __init__(self, text: str, source: str) -> None:
        self.lines = text.split("\n")
        self.source = source
        self.i = 0

    def fail(self, message: str, line: Optional[int] = None) -> NoReturn:
        number = (self.i if line is None else line) + 1
        raise YamlSubsetError(f"{self.source}:{number}: {message}")

    # Returns (indent, body) of the next significant line without consuming it.
    def peek(self) -> Optional[Tuple[int, str]]:
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                self.i += 1
                continue
            body = raw.lstrip(" ")
            if body.startswith("\t"):
                self.fail("tab indentation is not supported")
            if stripped in ("---", "...") or stripped.startswith("--- "):
                self.fail("document markers are not supported")
            return len(raw) - len(body), body.rstrip()
        return None

    @staticmethod
    def _is_item(body: str) -> bool:
        return body == "-" or body.startswith("- ")

    def parse_document(self) -> Dict[str, Any]:
        first = self.peek()
        if first is None:
            self.fail("empty document")
        if first[0] != 0:
            self.fail("the top-level mapping must start at column 0")
        if self._is_item(first[1]):
            self.fail("the top level must be a mapping")
        node = self.parse_mapping(0)
        if self.peek() is not None:
            self.fail("unexpected content after the top-level mapping")
        return node

    def parse_block(self, indent: int, body: str) -> Any:
        if self._is_item(body):
            return self.parse_sequence(indent)
        return self.parse_mapping(indent)

    def parse_mapping(self, indent: int) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        while True:
            nxt = self.peek()
            if nxt is None or nxt[0] < indent:
                return result
            current, body = nxt
            if current > indent:
                self.fail("unexpected indentation")
            if self._is_item(body):
                self.fail("unexpected sequence item inside a mapping")
            match = _KEY_RE.fullmatch(body)
            if not match:
                self.fail('expected "key: value" (quoted keys, "?" keys and "key:value" are not supported)')
            key, rest = match.group(1), match.group(2)
            if key in result:
                self.fail(f"duplicate key {key!r}")
            line = self.i
            self.i += 1
            result[key] = self.parse_value(rest, indent, line)

    def parse_sequence(self, indent: int) -> List[Any]:
        items: List[Any] = []
        while True:
            nxt = self.peek()
            if nxt is None or nxt[0] < indent:
                return items
            current, body = nxt
            if current > indent:
                self.fail("unexpected indentation")
            if not self._is_item(body):
                return items
            if body == "-":
                self.fail("empty sequence items are not supported")
            inner = body[2:].lstrip(" ")
            item_indent = current + (len(body) - len(inner))
            line = self.i
            if _KEY_RE.fullmatch(inner) or self._is_item(inner):
                # "- key: value" / "- - x": re-read the rest of the line as a
                # block node that starts at the item's content column.
                self.lines[self.i] = " " * item_indent + inner
                items.append(self.parse_block(item_indent, inner))
            else:
                self.i += 1
                if inner.startswith("|"):
                    items.append(self.parse_block_scalar(inner, current, line))
                else:
                    items.append(self.parse_inline(inner, line))

    def parse_value(self, rest: Optional[str], indent: int, line: int) -> Any:
        if rest is not None and rest.startswith("#"):
            rest = None
        if rest is None:
            nxt = self.peek()
            if nxt is None:
                return None
            current, body = nxt
            if current > indent:
                return self.parse_block(current, body)
            if current == indent and self._is_item(body):
                return self.parse_sequence(current)
            return None
        if rest.startswith("|"):
            return self.parse_block_scalar(rest, indent, line)
        return self.parse_inline(rest, line)

    def parse_block_scalar(self, header: str, indent: int, line: int) -> str:
        header = re.sub(r"\s+#.*$", "", header)
        if header not in ("|", "|-", "|+"):
            self.fail(f"unsupported block scalar header {header!r}", line)
        out: List[str] = []
        content_indent: Optional[int] = None
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            if raw.strip() == "":
                out.append("")
                self.i += 1
                continue
            body = raw.lstrip(" ")
            current = len(raw) - len(body)
            if content_indent is None:
                if current <= indent:
                    break
                if body.startswith("\t"):
                    self.fail("tab indentation is not supported")
                content_indent = current
            elif current < content_indent:
                if current > indent:
                    self.fail("block scalar line is less indented than its first line")
                break
            out.append(raw[content_indent:])
            self.i += 1
        if header == "|+":
            return "\n".join(out) + ("\n" if out else "")
        while out and out[-1] == "":
            out.pop()
        if not out:
            return ""
        return "\n".join(out) + ("" if header == "|-" else "\n")

    def parse_inline(self, text: str, line: int) -> Any:
        if text in ("{}", "[]"):
            return {} if text == "{}" else []
        if text.startswith("["):
            value, rest = self._flow_sequence(text, line)
        elif text.startswith('"'):
            value, rest = self._double_quoted(text, line)
        elif text.startswith("'"):
            value, rest = self._single_quoted(text, line)
        elif text[0] in "{&*!%@`>|?":
            self.fail(f"unsupported YAML construct starting with {text[0]!r}", line)
        else:
            return self._plain(text, line)
        rest = rest.strip()
        if rest and not rest.startswith("#"):
            self.fail(f"unexpected text after a value: {rest!r}", line)
        return value

    def _plain(self, text: str, line: int) -> str:
        comment = re.search(r"\s#", text)
        if comment:
            text = text[: comment.start()]
        text = text.rstrip()
        if ": " in text or text.endswith(":"):
            self.fail('":" inside a plain scalar is not supported; quote the value', line)
        return text

    def _double_quoted(self, text: str, line: int) -> Tuple[str, str]:
        out: List[str] = []
        i = 1
        while i < len(text):
            char = text[i]
            if char == "\\":
                escape = text[i + 1 : i + 2]
                if escape not in _DQ_ESCAPES:
                    self.fail(f"unsupported escape \\{escape}", line)
                out.append(_DQ_ESCAPES[escape])
                i += 2
                continue
            if char == '"':
                return "".join(out), text[i + 1 :]
            out.append(char)
            i += 1
        self.fail("unterminated double-quoted scalar (multi-line quotes are not supported)", line)

    def _single_quoted(self, text: str, line: int) -> Tuple[str, str]:
        out: List[str] = []
        i = 1
        while i < len(text):
            char = text[i]
            if char == "'":
                if text[i + 1 : i + 2] == "'":
                    out.append("'")
                    i += 2
                    continue
                return "".join(out), text[i + 1 :]
            out.append(char)
            i += 1
        self.fail("unterminated single-quoted scalar (multi-line quotes are not supported)", line)

    def _flow_sequence(self, text: str, line: int) -> Tuple[List[str], str]:
        items: List[str] = []
        i = 1
        while True:
            while i < len(text) and text[i] == " ":
                i += 1
            if i >= len(text):
                self.fail("unterminated flow sequence", line)
            if text[i] == "]":
                return items, text[i + 1 :]
            if text[i] in "[{":
                self.fail("nested flow collections are not supported", line)
            if text[i] in "\"'":
                parse = self._double_quoted if text[i] == '"' else self._single_quoted
                value, rest = parse(text[i:], line)
                i = len(text) - len(rest)
            else:
                end = i
                while end < len(text) and text[end] not in ",]":
                    end += 1
                value = text[i:end].strip()
                if not value or "#" in value or ": " in value:
                    self.fail("unsupported plain item in a flow sequence", line)
                i = end
            items.append(value)
            while i < len(text) and text[i] == " ":
                i += 1
            if i < len(text) and text[i] == ",":
                i += 1
            elif i < len(text) and text[i] == "]":
                return items, text[i + 1 :]
            else:
                self.fail('expected "," or "]" in a flow sequence', line)


def parse_yaml(text: str, source: str = "<string>") -> Dict[str, Any]:
    """Parse the supported YAML subset. Every scalar is returned as a string."""
    return _Parser(text, source).parse_document()


# --------------------------------------------------------------------------
# Contract
# --------------------------------------------------------------------------

WORKFLOW_DIR = ".github/workflows"
CI = ".github/workflows/ci.yml"
MEETING_API = ".github/workflows/meeting-api.yml"
CONTRACT = ".github/workflows/ci-contract.yml"
DEPLOY = ".github/workflows/deploy.yml"
UNIT_VITEST = "backend/meeting-api/vitest.config.ts"
INTEGRATION_VITEST = "backend/meeting-api/vitest.integration.config.ts"
PACKAGE_JSON = "backend/meeting-api/package.json"

EXPECTED_PATHS = {
    CI: ["ios/**", "ci_scripts/**", ".package-resolved.sha256", ".github/workflows/ci.yml"],
    MEETING_API: ["backend/meeting-api/**", ".github/workflows/meeting-api.yml"],
    CONTRACT: [
        ".github/**",
        "backend/meeting-api/vitest*.ts",
        "backend/meeting-api/package.json",
        "scripts/check_ci_contract.py",
        "scripts/test_check_ci_contract.py",
    ],
}
PINNED_WORKFLOWS = (CI, MEETING_API, CONTRACT)
EXPECTED_PERMISSIONS = {"contents": "read"}
# PR runs share a group per PR and cancel superseded runs; push and dispatch
# runs get a group per run, so no main commit is queued behind or cancelled by
# another one (a shared group cancels the older *pending* run even when
# cancel-in-progress is false).
EXPECTED_CONCURRENCY = {
    "group": (
        "${{ github.workflow }}-${{ github.event_name == 'pull_request'"
        " && format('pr-{0}', github.event.pull_request.number) || github.run_id }}"
    ),
    "cancel-in-progress": "${{ github.event_name == 'pull_request' }}",
}
CI_JOB = "build-test"
GATE_STEP = "Require executed tests"
RESULT_BUNDLE = '"$RUNNER_TEMP/todoTests.xcresult"'
DERIVED_DATA = '-derivedDataPath "$RUNNER_TEMP/DerivedData"'
# The whole gate script, one line per entry after stripping indentation. Only
# the minimum (N >= 1) and plain `echo "..."` messages (no `$`, backquote or
# backslash) may vary; `exit 1` must be its own command line.
GATE_SHAPE = re.compile(
    "\n".join(
        (
            re.escape(f'summary="$(xcrun xcresulttool get test-results summary --path {RESULT_BUNDLE})"'),
            re.escape("if ! jq -e '.result == \"Passed\" and .passedTests >= ")
            + "[1-9][0-9]*"
            + re.escape("' <<< \"$summary\" > /dev/null; then"),
            r'(?:echo "[^"$`\\\n]*"\n)*exit 1',
            "fi",
        )
    )
)
# Rule 10: pinned jobs run on GitHub-hosted runners only (no self-hosted label,
# list or runner group). A pull_request run uses the PR's own YAML (and the PR
# can edit this check too), so this check reports such a change but cannot stop
# that PR's run; the settings-level control is the repository owner's (see the
# ci-contract.yml header).
HOSTED_RUNNER = re.compile(r"(?:macos|ubuntu)-[0-9a-z.\-]+")
# Values reach `run:` bodies only through `env:`; an expression inside a body is
# substituted into the script text before bash runs (script injection).
_EXPRESSION = re.compile(r"\$\{\{")
_SECRET_EXPRESSION = re.compile(r"\$\{\{(?:(?!\}\}).)*?\b(?:secrets|github\.token)\b")

# Steps that break a workflow-wide rule today and are tracked for their owner
# (the TestFlight release workflow). An entry that no longer matches fails as
# KNOWN-DEBT-STALE, so the list can only shrink.
KNOWN_DEBT = frozenset(
    {
        (DEPLOY, "Archive", "NO-FALLBACK"),
        (DEPLOY, "Archive", "PIPEFAIL"),
    }
)

CHECK_IDS = (
    "PARSE",
    "NO-FALLBACK",
    "PIPEFAIL",
    "KNOWN-DEBT-STALE",
    "TRIGGERS",
    "PERMISSIONS",
    "CONCURRENCY",
    "SHELL",
    "CONTINUE-ON-ERROR",
    "CHECKOUT-CREDENTIALS",
    "JOB-UNCONDITIONAL",
    "RUNS-ON",
    "RUN-EXPRESSION",
    "SECRETS",
    "CI-JOB",
    "CI-BUILD-CMD",
    "CI-TEST-CMD",
    "CI-PARALLEL",
    "CI-MACRO",
    "CI-GATE",
    "MEETING-API-STEPS",
    "CONTRACT-JOB",
    "VITEST-UNIT",
    "VITEST-INTEGRATION",
    "NPM-SCRIPTS",
)


class Violation(NamedTuple):
    check: str
    path: str
    message: str

    def __str__(self) -> str:
        return f"[{self.check}] {self.path}: {self.message}"


class _Report:
    def __init__(self) -> None:
        self.violations: List[Violation] = []

    def add(self, check: str, path: str, message: str) -> None:
        assert check in CHECK_IDS, check
        self.violations.append(Violation(check, path, message))


def shell_logic(script: str) -> str:
    """Drop shell comment lines and join backslash-continued lines."""
    kept = [line for line in script.split("\n") if not line.strip().startswith("#")]
    return re.sub(r"\\\n", " ", "\n".join(kept))


# Single-quoted strings and double-quoted strings without command substitution
# are data (messages, paths), not commands; blank them before looking for
# xcodebuild invocations so `echo "... xcodebuild ..."` is not a match.
_SHELL_LITERAL = re.compile(r"'[^'\n]*'|\"(?:[^\"\\$\n]|\\.|\$(?!\())*\"")


def shell_code(script: str) -> str:
    return _SHELL_LITERAL.sub('""', shell_logic(script))


_XCODEBUILD = re.compile(r"\bxcodebuild\b")
# Any pipe in the step, not only one on the xcodebuild line: a group such as
# `{ xcodebuild ...\n} | cat` also hides xcodebuild's exit status.
_PIPE = re.compile(r"(?<!\|)\|(?!\|)")
# `set` with a `+` option cluster that contains `e` (+e, +ex, +xe, +eo pipefail)
# or `+o errexit` / `+o pipefail` (also as `+xo pipefail`), anywhere in the
# same `set` command.
_DISABLES_ERRORS = re.compile(r"\bset\b[^\n;&|]*?(?<!\S)\+(?:[A-Za-z]*e|[A-Za-z]*o\s+(?:pipefail|errexit)\b)")
_SETS_PIPEFAIL = re.compile(r"\bset\s+-\w*o\s+pipefail\b")


def _mapping(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _jobs(workflow: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {name: job for name, job in _mapping(workflow.get("jobs")).items() if isinstance(job, dict)}


def _steps(job: Dict[str, Any]) -> List[Dict[str, Any]]:
    steps = job.get("steps")
    if not isinstance(steps, list):
        return []
    return [step for step in steps if isinstance(step, dict)]


def _step_label(step: Dict[str, Any], index: int) -> str:
    name = step.get("name")
    return name if isinstance(name, str) and name else f"steps[{index}]"


def _script(step: Dict[str, Any]) -> str:
    run = step.get("run")
    return shell_logic(run) if isinstance(run, str) else ""


def _default_shell(node: Dict[str, Any]) -> Optional[str]:
    return _mapping(_mapping(node.get("defaults")).get("run")).get("shell")


def _continue_on_error(node: Dict[str, Any]) -> bool:
    return "continue-on-error" in node and node.get("continue-on-error") != "false"


def _scalars(node: Any, where: str) -> List[Tuple[str, str]]:
    """Every string scalar under `node`, with a dotted location."""
    if isinstance(node, dict):
        return [item for key, value in node.items() for item in _scalars(value, f"{where}.{key}" if where else key)]
    if isinstance(node, list):
        return [item for index, value in enumerate(node) for item in _scalars(value, f"{where}[{index}]")]
    return [(where, node)] if isinstance(node, str) else []


def _load_workflows(root: Path, report: _Report) -> Dict[str, Dict[str, Any]]:
    workflows: Dict[str, Dict[str, Any]] = {}
    directory = root / WORKFLOW_DIR
    files = sorted(list(directory.glob("*.yml")) + list(directory.glob("*.yaml"))) if directory.is_dir() else []
    for path in files:
        rel = path.relative_to(root).as_posix()
        try:
            workflows[rel] = parse_yaml(path.read_text(encoding="utf-8"), rel)
        except (OSError, UnicodeDecodeError, YamlSubsetError) as error:
            report.add("PARSE", rel, str(error))
    for rel in PINNED_WORKFLOWS:
        if rel not in workflows and not any(v.path == rel for v in report.violations):
            report.add("PARSE", rel, "required workflow file is missing")
    return workflows


def _check_all_workflows(workflows: Dict[str, Dict[str, Any]], report: _Report) -> None:
    seen_debt = set()
    for rel, workflow in workflows.items():
        for job_name, job in _jobs(workflow).items():
            for index, step in enumerate(_steps(job)):
                run = step.get("run")
                script = shell_code(run) if isinstance(run, str) else ""
                if not _XCODEBUILD.search(script):
                    continue
                label = _step_label(step, index)
                problems = []
                if "||" in script:
                    problems.append("uses `||`")
                if _DISABLES_ERRORS.search(script):
                    problems.append("disables errexit/pipefail")
                if _continue_on_error(step):
                    problems.append("sets continue-on-error")
                if problems:
                    if (rel, label, "NO-FALLBACK") in KNOWN_DEBT:
                        seen_debt.add((rel, label, "NO-FALLBACK"))
                    else:
                        report.add(
                            "NO-FALLBACK",
                            rel,
                            f"job {job_name} step {label!r} runs xcodebuild and {', '.join(problems)}; "
                            "a failing build must fail the step",
                        )
                if _PIPE.search(script):
                    shell = step.get("shell") or _default_shell(job) or _default_shell(workflow)
                    if shell != "bash" and not _SETS_PIPEFAIL.search(script):
                        if (rel, label, "PIPEFAIL") in KNOWN_DEBT:
                            seen_debt.add((rel, label, "PIPEFAIL"))
                        else:
                            report.add(
                                "PIPEFAIL",
                                rel,
                                f"job {job_name} step {label!r} runs xcodebuild and a pipe with shell {shell!r}; "
                                "use `shell: bash` (bash -eo pipefail) or `set -o pipefail`",
                            )
    for rel, label, check in sorted(KNOWN_DEBT - seen_debt):
        report.add(
            "KNOWN-DEBT-STALE",
            rel,
            f"known-debt entry ({label!r}, {check}) no longer matches; remove it from KNOWN_DEBT",
        )


def _check_pinned_workflow(rel: str, workflow: Dict[str, Any], report: _Report) -> None:
    trigger = {"branches": ["main"], "paths": EXPECTED_PATHS[rel]}
    expected_on = {"push": trigger, "pull_request": trigger, "workflow_dispatch": None}
    if workflow.get("on") != expected_on:
        report.add("TRIGGERS", rel, f"`on` must be exactly {expected_on!r}, got {workflow.get('on')!r}")

    if workflow.get("permissions") != EXPECTED_PERMISSIONS:
        report.add("PERMISSIONS", rel, f"workflow permissions must be {EXPECTED_PERMISSIONS!r}")
    if workflow.get("concurrency") != EXPECTED_CONCURRENCY:
        report.add("CONCURRENCY", rel, f"concurrency must be exactly {EXPECTED_CONCURRENCY!r}")
    if _default_shell(workflow) != "bash":
        report.add("SHELL", rel, "workflow `defaults.run.shell` must be `bash` (bash -eo pipefail)")

    for where, value in _scalars(workflow, ""):
        if _SECRET_EXPRESSION.search(value):
            report.add("SECRETS", rel, f"{where} references secrets or github.token; these workflows use none")

    jobs = _jobs(workflow)
    if not jobs:
        report.add("CI-JOB", rel, "workflow has no jobs")
    checkouts = 0
    for job_name, job in jobs.items():
        if "permissions" in job:
            report.add("PERMISSIONS", rel, f"job {job_name} must not override permissions")
        if _default_shell(job) not in (None, "bash"):
            report.add("SHELL", rel, f"job {job_name} overrides the default shell")
        if _continue_on_error(job):
            report.add("CONTINUE-ON-ERROR", rel, f"job {job_name} sets continue-on-error")
        # A job skipped by `if:`, or by a skipped `needs:` job, runs nothing and
        # still reports success (also as a required check), and `needs:` puts
        # the tests behind another job (rule 3). These workflows publish
        # nothing, so no job has to wait: publishing and deploys, which rule 3
        # gates on the whole test result, belong in their own workflow.
        if "if" in job:
            report.add("JOB-UNCONDITIONAL", rel, f"job {job_name} must not have an `if:`")
        if "needs" in job:
            report.add("JOB-UNCONDITIONAL", rel, f"job {job_name} must not use `needs:`")
        runs_on = job.get("runs-on")
        if not HOSTED_RUNNER.fullmatch(runs_on if isinstance(runs_on, str) else ""):
            report.add(
                "RUNS-ON",
                rel,
                f"job {job_name} must use a GitHub-hosted `runs-on` label (macos-* / ubuntu-*), got {runs_on!r}",
            )
        for index, step in enumerate(_steps(job)):
            label = _step_label(step, index)
            if step.get("shell") not in (None, "bash"):
                report.add("SHELL", rel, f"job {job_name} step {label!r} overrides the shell")
            if _continue_on_error(step):
                report.add("CONTINUE-ON-ERROR", rel, f"job {job_name} step {label!r} sets continue-on-error")
            run = step.get("run")
            if isinstance(run, str) and _EXPRESSION.search(run):
                report.add(
                    "RUN-EXPRESSION",
                    rel,
                    f"job {job_name} step {label!r} has `${{{{` in its run body (also in comments); pass values via env",
                )
            uses = step.get("uses")
            if isinstance(uses, str) and uses.startswith("actions/checkout@"):
                checkouts += 1
                if _mapping(step.get("with")).get("persist-credentials") != "false":
                    report.add(
                        "CHECKOUT-CREDENTIALS",
                        rel,
                        f"job {job_name} step {label!r} must set `with: persist-credentials: false`",
                    )
    if checkouts == 0:
        report.add("CHECKOUT-CREDENTIALS", rel, "no actions/checkout step found")


def _single(steps: List[Tuple[int, Dict[str, Any]]], report: _Report, check: str, what: str) -> Optional[int]:
    if len(steps) != 1:
        report.add(check, CI, f"expected exactly one {what}, found {len(steps)}")
        return None
    return steps[0][0]


def _check_ci(workflow: Dict[str, Any], report: _Report) -> None:
    job = _jobs(workflow).get(CI_JOB)
    steps = _steps(job) if job else []
    if not steps:
        report.add("CI-JOB", CI, f"job {CI_JOB!r} with steps is missing")
        return
    scripts = [_script(step) for step in steps]

    # Compile step.
    build_index = _single(
        [(i, s) for i, s in enumerate(steps) if "xcodebuild build-for-testing" in scripts[i]],
        report,
        "CI-BUILD-CMD",
        "`xcodebuild build-for-testing` step",
    )
    # Test step, found by id because its display name is free text.
    test_index = _single(
        [(i, s) for i, s in enumerate(steps) if s.get("id") == "test"], report, "CI-TEST-CMD", "step with `id: test`"
    )
    if build_index is not None:
        build = steps[build_index]
        if "if" in build:
            report.add("CI-BUILD-CMD", CI, "the build-for-testing step must not have an `if:`")
        if DERIVED_DATA not in scripts[build_index]:
            report.add("CI-BUILD-CMD", CI, f"build-for-testing must use {DERIVED_DATA}")
        if test_index is not None and build_index > test_index:
            report.add("CI-BUILD-CMD", CI, "build-for-testing must run before the test step")

    if test_index is not None:
        test, script = steps[test_index], scripts[test_index]
        if "if" in test:
            report.add("CI-TEST-CMD", CI, "the test step must not have an `if:`")
        if "xcodebuild test-without-building" not in script:
            report.add("CI-TEST-CMD", CI, "the test step must run `xcodebuild test-without-building`")
        selectors = re.findall(r"-(?:only|skip)-testing:\S+", script)
        if selectors != ["-only-testing:todoTests"]:
            report.add("CI-TEST-CMD", CI, f"test selectors must be exactly ['-only-testing:todoTests'], got {selectors}")
        if f"-resultBundlePath {RESULT_BUNDLE}" not in script:
            report.add("CI-TEST-CMD", CI, f"the test step must write -resultBundlePath {RESULT_BUNDLE}")
        if DERIVED_DATA not in script:
            report.add("CI-TEST-CMD", CI, f"the test step must use {DERIVED_DATA} (same as build-for-testing)")
        # Rule 7: an explicit worker count; no reliance on the autocreated scheme's defaults.
        if not re.search(r"(?<!\S)-parallel-testing-enabled\s+YES(?!\S)", script) or not re.search(
            r"(?<!\S)-parallel-testing-worker-count\s+1(?!\S)", script
        ):
            report.add(
                "CI-PARALLEL",
                CI,
                "the test step must pass `-parallel-testing-enabled YES -parallel-testing-worker-count 1`",
            )
        if len(re.findall(r"-parallel-testing-(?:enabled|worker-count)|-maximum-parallel-testing-workers", script)) != 2:
            report.add("CI-PARALLEL", CI, "the test step must set the parallel-testing flags exactly once each")

    # -skipMacroValidation is only safe after the Package.resolved integrity check.
    integrity = [i for i, script in enumerate(scripts) if "ci_scripts/ci_pre_xcodebuild.sh" in script]
    skip_macro = [i for i, script in enumerate(scripts) if "-skipMacroValidation" in script]
    if len(integrity) != 1:
        report.add("CI-MACRO", CI, f"expected exactly one Package.resolved integrity step, found {len(integrity)}")
    else:
        check = steps[integrity[0]]
        if "if" in check or _continue_on_error(check):
            report.add("CI-MACRO", CI, "the integrity step must be unconditional")
        if any(i < integrity[0] for i in skip_macro):
            report.add("CI-MACRO", CI, "-skipMacroValidation is used before the integrity step")

    # Fail-closed gate on the result bundle.
    gate_index = _single(
        [(i, s) for i, s in enumerate(steps) if s.get("name") == GATE_STEP], report, "CI-GATE", f"{GATE_STEP!r} step"
    )
    if gate_index is not None:
        gate, script = steps[gate_index], scripts[gate_index]
        if "if" in gate:
            report.add("CI-GATE", CI, "the gate must not have an `if:`")
        if _continue_on_error(gate):
            report.add("CI-GATE", CI, "the gate must not set continue-on-error")
        if test_index is not None and gate_index < test_index:
            report.add("CI-GATE", CI, "the gate must run after the test step")
        lines = "\n".join(line.strip() for line in script.split("\n") if line.strip())
        if not GATE_SHAPE.fullmatch(lines):
            report.add(
                "CI-GATE",
                CI,
                "the gate script must have exactly the pinned shape (xcresulttool summary of "
                f"{RESULT_BUNDLE}, `if ! jq -e '.result == \"Passed\" and .passedTests >= N'` with N >= 1, "
                "`exit 1` on its own line); got:\n" + lines,
            )


def _check_meeting_api(workflow: Dict[str, Any], report: _Report) -> None:
    working_directory = _mapping(_mapping(workflow.get("defaults")).get("run")).get("working-directory")
    if working_directory != "backend/meeting-api":
        report.add("MEETING-API-STEPS", MEETING_API, "`defaults.run.working-directory` must be backend/meeting-api")
    steps = [step for job in _jobs(workflow).values() for step in _steps(job)]
    runs = [step.get("run") for step in steps]
    positions = []
    for command in ("npm ci", "npm test", "npm run build"):
        if runs.count(command) != 1:
            report.add("MEETING-API-STEPS", MEETING_API, f"expected exactly one `run: {command}` step")
        else:
            positions.append(runs.index(command))
            if "if" in steps[positions[-1]]:
                report.add("MEETING-API-STEPS", MEETING_API, f"the `run: {command}` step must not have an `if:`")
    if len(positions) == 3 and positions != sorted(positions):
        report.add("MEETING-API-STEPS", MEETING_API, "steps must run npm ci, npm test, npm run build in order")


def _check_contract_workflow(workflow: Dict[str, Any], report: _Report) -> None:
    jobs = _jobs(workflow)
    steps = [step for job in jobs.values() for step in _steps(job)]
    checker = [s for s in steps if s.get("run") == "python3 scripts/check_ci_contract.py"]
    mutation = [
        s
        for s in steps
        if isinstance(s.get("run"), str)
        and "python3 -m unittest" in s["run"]
        and "test_check_ci_contract.py" in s["run"]
    ]
    if not checker:
        report.add("CONTRACT-JOB", CONTRACT, "a step must run `python3 scripts/check_ci_contract.py`")
    if not mutation:
        report.add("CONTRACT-JOB", CONTRACT, "a step must run the mutation tests with `python3 -m unittest`")
    if any("if" in s for s in checker + mutation):
        report.add("CONTRACT-JOB", CONTRACT, "the checker and mutation-test steps must not have an `if:`")
    for job_name, job in jobs.items():
        runs_on = job.get("runs-on")
        if not str(runs_on).startswith("ubuntu-"):
            report.add("CONTRACT-JOB", CONTRACT, f"job {job_name} must run on a cheap ubuntu-* runner")


def strip_ts_comments(text: str) -> str:
    """Remove // and /* */ comments outside string literals (globs contain "/**/")."""
    out: List[str] = []
    i, quote = 0, ""
    while i < len(text):
        char = text[i]
        if quote:
            out.append(char)
            if char == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 2
                continue
            if char == quote:
                quote = ""
            i += 1
        elif char in "'\"`":
            quote = char
            out.append(char)
            i += 1
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
            out.append(" ")
        else:
            out.append(char)
            i += 1
    return "".join(out)


def _string_list(text: str, key: str) -> Optional[List[str]]:
    """Return the items of the single `key: [...]` array literal, or None."""
    found = re.findall(r"\b" + re.escape(key) + r"\s*:\s*\[([^\]]*)\]", text)
    if len(found) != 1:
        return None
    items = [item.strip() for item in found[0].split(",") if item.strip()]
    return [re.sub(r"^(['\"`])(.*)\1$", r"\2", item) for item in items]


def _check_meeting_api_sources(root: Path, report: _Report) -> None:
    def read(rel: str, check: str) -> Optional[str]:
        try:
            return (root / rel).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            report.add(check, rel, f"cannot read: {error}")
            return None

    unit = read(UNIT_VITEST, "VITEST-UNIT")
    if unit is not None:
        unit = strip_ts_comments(unit)
        include, exclude = _string_list(unit, "include"), _string_list(unit, "exclude")
        if include != ["test/**/*.test.ts"]:
            report.add("VITEST-UNIT", UNIT_VITEST, f"include must be exactly ['test/**/*.test.ts'], got {include}")
        if exclude is None or "test/integration/**" not in exclude or "...configDefaults.exclude" not in exclude:
            report.add(
                "VITEST-UNIT",
                UNIT_VITEST,
                f"exclude must keep ...configDefaults.exclude and 'test/integration/**', got {exclude}",
            )
        # vitest fails a run that finds no test files; passWithNoTests would turn
        # a broken include or deleted tests into a green 0-test run.
        if re.search(r"\bpassWithNoTests\b", unit):
            report.add("VITEST-UNIT", UNIT_VITEST, "must not set passWithNoTests")

    integration = read(INTEGRATION_VITEST, "VITEST-INTEGRATION")
    if integration is not None:
        integration = strip_ts_comments(integration)
        include = _string_list(integration, "include")
        if include != ["test/integration/**/*.test.ts"]:
            report.add(
                "VITEST-INTEGRATION",
                INTEGRATION_VITEST,
                f"include must be exactly ['test/integration/**/*.test.ts'], got {include}",
            )
        if re.search(r"\bmergeConfig\b", integration) or re.search(r"""from\s+['"]\./vitest\.config""", integration):
            report.add(
                "VITEST-INTEGRATION",
                INTEGRATION_VITEST,
                "must stay standalone: mergeConfig() concatenates include/exclude with the unit config",
            )
        if re.search(r"\bpassWithNoTests\b", integration):
            report.add("VITEST-INTEGRATION", INTEGRATION_VITEST, "must not set passWithNoTests")

    package = read(PACKAGE_JSON, "NPM-SCRIPTS")
    if package is not None:
        try:
            scripts = _mapping(json.loads(package).get("scripts"))
        except (ValueError, AttributeError) as error:
            report.add("NPM-SCRIPTS", PACKAGE_JSON, f"invalid JSON: {error}")
            scripts = None
        if scripts is not None:
            expected = {"test": "vitest run", "test:integration": "vitest run --config vitest.integration.config.ts"}
            for name, command in expected.items():
                if scripts.get(name) != command:
                    report.add("NPM-SCRIPTS", PACKAGE_JSON, f"script {name!r} must be {command!r}")


def check(root: Path) -> List[Violation]:
    """Return every contract violation under `root` (empty when the contract holds)."""
    report = _Report()
    workflows = _load_workflows(root, report)
    _check_all_workflows(workflows, report)
    for rel in PINNED_WORKFLOWS:
        if rel in workflows:
            _check_pinned_workflow(rel, workflows[rel], report)
    if CI in workflows:
        _check_ci(workflows[CI], report)
    if MEETING_API in workflows:
        _check_meeting_api(workflows[MEETING_API], report)
    if CONTRACT in workflows:
        _check_contract_workflow(workflows[CONTRACT], report)
    _check_meeting_api_sources(root, report)
    return report.violations


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)
    violations = check(args.root)
    for violation in violations:
        print(violation)
    if violations:
        print(f"CI contract: {len(violations)} violation(s)", file=sys.stderr)
        return 1
    print("CI contract: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
