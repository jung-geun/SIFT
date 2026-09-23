"""Mutation tests for scripts/check_ci_contract.py.

Each test copies the real workflow and meeting-api files into a temporary
directory, removes or breaks one invariant, and asserts that the specific check
ID fires. Where several branches share a check ID, the test also matches the
message of the branch it targets (`contains=`), so disabling that one branch
fails the test even when another branch reports the same ID. Every edit asserts
that its target text exists exactly the expected number of times, so a stale
mutation fails loudly instead of passing as a no-op.

Run: python3 -m unittest discover -s scripts -p 'test_check_ci_contract.py' -v
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_ci_contract as contract  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
CI = contract.CI
MEETING_API = contract.MEETING_API
CONTRACT = contract.CONTRACT
DEPLOY = contract.DEPLOY
UNIT = contract.UNIT_VITEST
INTEGRATION = contract.INTEGRATION_VITEST
PACKAGE = contract.PACKAGE_JSON

PIPED_NEW_WORKFLOW = """name: Copy
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: macos-26
    steps:
      - name: Build
        run: |
          xcodebuild build -project ios/todo.xcodeproj -scheme todo | xcpretty || xcodebuild build -project ios/todo.xcodeproj -scheme todo
"""


class LiveRepositoryTest(unittest.TestCase):
    def test_repository_satisfies_contract(self) -> None:
        self.assertEqual([str(v) for v in contract.check(REPO)], [])


class MutationTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        sources = sorted((REPO / contract.WORKFLOW_DIR).glob("*.y*ml")) + [REPO / p for p in (UNIT, INTEGRATION, PACKAGE)]
        for source in sources:
            target = self.root / source.relative_to(REPO)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def mutate(self, rel: str, old: str, new: str, count: int = 1) -> None:
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), count, f"mutation target not found {count}x in {rel}: {old!r}")
        path.write_text(text.replace(old, new), encoding="utf-8")

    def move(self, rel: str, start: str, end: str, before: str) -> None:
        """Move the text from `start` up to (not including) `end` so it sits right before `before`."""
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        for marker in (start, end, before):
            self.assertEqual(text.count(marker), 1, f"move marker not found once in {rel}: {marker!r}")
        i = text.index(start)
        block = text[i : text.index(end, i)]
        text = text.replace(block, "")
        path.write_text(text.replace(before, block + before), encoding="utf-8")

    def mutations(self, rel: str, cases: list[tuple[str, str]], check: str, contains: str | None = None) -> None:
        """Apply each (old, new) edit to a fresh copy of `rel` and assert that `check` fires."""
        path = self.root / rel
        original = path.read_text(encoding="utf-8")
        for old, new in cases:
            with self.subTest(old=old, new=new):
                self.mutate(rel, old, new)
                self.assertFires(check, rel, contains)
            path.write_text(original, encoding="utf-8")

    def assertFires(self, check: str, path: str | None = None, contains: str | None = None) -> None:
        violations = contract.check(self.root)
        hits = [
            v
            for v in violations
            if v.check == check and (path is None or v.path == path) and (contains is None or contains in v.message)
        ]
        self.assertTrue(
            hits,
            f"expected {check} for {path or 'any file'} containing {contains!r}; got {[str(v) for v in violations]}",
        )

    def assertClean(self) -> None:
        self.assertEqual([str(v) for v in contract.check(self.root)], [])

    # -- baseline ---------------------------------------------------------

    def test_unmodified_copy_passes(self) -> None:
        self.assertEqual([str(v) for v in contract.check(self.root)], [])

    # -- pipefail / fallback ----------------------------------------------

    def test_removing_workflow_bash_default_fails(self) -> None:
        self.mutate(CI, "defaults:\n  run:\n    shell: bash\n", "")
        self.assertFires("SHELL", CI)
        self.assertFires("PIPEFAIL", CI)

    def test_step_shell_without_pipefail_fails(self) -> None:
        self.mutate(
            CI,
            "      - name: Build for testing (app + test bundles)\n        run: |\n",
            "      - name: Build for testing (app + test bundles)\n        shell: bash {0}\n        run: |\n",
        )
        self.assertFires("SHELL", CI)
        self.assertFires("PIPEFAIL", CI)

    def test_or_fallback_after_xcodebuild_fails(self) -> None:
        self.mutate(
            CI,
            "            -skipMacroValidation \\\n            CODE_SIGNING_ALLOWED=NO \\\n            | xcbeautify\n",
            "            -skipMacroValidation \\\n            CODE_SIGNING_ALLOWED=NO \\\n            | xcbeautify || true\n",
        )
        self.assertFires("NO-FALLBACK", CI)

    def test_set_plus_e_before_xcodebuild_fails(self) -> None:
        self.mutate(CI, "          xcodebuild test-without-building \\\n", "          set +e\n          xcodebuild test-without-building \\\n")
        self.assertFires("NO-FALLBACK", CI)

    def test_combined_set_flags_disabling_errors_fail(self) -> None:
        target = "          xcodebuild test-without-building \\\n"
        cases = [
            (target, f"          {command}\n{target}")
            for command in ("set +eo pipefail", "set +ex", "set +xe", "set -x +e", "set +o errexit", "set +xo pipefail")
        ]
        self.mutations(CI, cases, "NO-FALLBACK", "disables errexit/pipefail")

    def test_set_flags_keeping_errors_on_pass(self) -> None:
        target = "          xcodebuild test-without-building \\\n"
        path = self.root / CI
        original = path.read_text(encoding="utf-8")
        for command in ("set -eo pipefail", "set -euo pipefail", "set +x", "set +u", "set -o pipefail"):
            with self.subTest(command=command):
                self.mutate(CI, target, f"          {command}\n{target}")
                self.assertClean()
            path.write_text(original, encoding="utf-8")

    def test_pipe_on_a_later_line_needs_pipefail(self) -> None:
        workflow = PIPED_NEW_WORKFLOW.replace(
            "          xcodebuild build -project ios/todo.xcodeproj -scheme todo | xcpretty || xcodebuild build -project ios/todo.xcodeproj -scheme todo\n",
            "          {\n            xcodebuild build -project ios/todo.xcodeproj -scheme todo\n          } | xcpretty\n",
        )
        self.assertNotEqual(workflow, PIPED_NEW_WORKFLOW)
        (self.root / ".github/workflows/group.yml").write_text(workflow, encoding="utf-8")
        self.assertFires("PIPEFAIL", ".github/workflows/group.yml")

    def test_copying_the_old_pattern_into_a_new_workflow_fails(self) -> None:
        (self.root / ".github/workflows/copy.yml").write_text(PIPED_NEW_WORKFLOW, encoding="utf-8")
        self.assertFires("NO-FALLBACK", ".github/workflows/copy.yml")
        self.assertFires("PIPEFAIL", ".github/workflows/copy.yml")

    def test_fixing_known_debt_requires_removing_the_entry(self) -> None:
        self.mutate(DEPLOY, "            | xcpretty || xcodebuild archive \\\n", "            | xcpretty\n          xcodebuild archive \\\n")
        self.assertFires("KNOWN-DEBT-STALE", DEPLOY)

    # -- test gate ----------------------------------------------------------

    def test_removing_gate_fails(self) -> None:
        self.mutate(CI, "      - name: Require executed tests\n", "      - name: Show test results\n")
        self.assertFires("CI-GATE", CI)

    def test_conditional_gate_fails(self) -> None:
        self.mutate(
            CI,
            "      - name: Require executed tests\n        run: |\n",
            "      - name: Require executed tests\n        if: ${{ success() }}\n        run: |\n",
        )
        self.assertFires("CI-GATE", CI, "must not have an `if:`")

    def test_gate_continue_on_error_fails(self) -> None:
        self.mutate(
            CI,
            "      - name: Require executed tests\n        run: |\n",
            "      - name: Require executed tests\n        continue-on-error: true\n        run: |\n",
        )
        self.assertFires("CI-GATE", CI, "must not set continue-on-error")
        self.assertFires("CONTINUE-ON-ERROR", CI)

    def test_gate_before_test_step_fails(self) -> None:
        self.move(CI, "      - name: Require executed tests\n", "      # runner 가 끝나면", "      # 테스트 호스트가 멈추면")
        self.assertFires("CI-GATE", CI, "must run after the test step")

    def test_gate_shape_mutations_fail(self) -> None:
        bundle = '--path "$RUNNER_TEMP/todoTests.xcresult")"'
        cases = [
            # The finding's cases: `and` -> `or`, an always-true minimum, and an `exit 1` that never exits.
            ('.result == "Passed" and .passedTests >= 1', '.result == "Passed" or .passedTests >= 1'),
            (".passedTests >= 1'", ".passedTests >= 1 or true'"),
            ('결과 불명 포함)."\n            exit 1\n', '결과 불명 포함)."\n            echo exit 1\n'),
            ('결과 불명 포함)."\n            exit 1\n', '결과 불명 포함)."\n            exit 0\n'),
            ("if ! jq -e '.result", "if ! jq '.result"),
            ("if ! jq -e '.result", "if jq -e '.result"),
            (bundle, '--path "$RUNNER_TEMP/other.xcresult")"'),
            ("summary=\"$(xcrun xcresulttool get test-results summary " + bundle, "summary=\"$(cat " + bundle[len("--path ") :]),
            ('<<< "$summary" > /dev/null; then', '<<< "$summary" > /dev/null || true; then'),
        ]
        self.mutations(CI, cases, "CI-GATE", "pinned shape")

    def test_gate_accepting_zero_tests_fails(self) -> None:
        self.mutate(CI, ".passedTests >= 1", ".passedTests >= 0")
        self.assertFires("CI-GATE", CI)

    def test_gate_without_passed_result_fails(self) -> None:
        self.mutate(CI, '.result == "Passed" and ', "")
        self.assertFires("CI-GATE", CI)

    def test_test_step_continue_on_error_fails(self) -> None:
        self.mutate(CI, "        id: test\n", "        id: test\n        continue-on-error: true\n")
        self.assertFires("CONTINUE-ON-ERROR", CI)
        self.assertFires("NO-FALLBACK", CI)

    # -- xcodebuild shape ---------------------------------------------------

    def test_narrowed_selector_fails(self) -> None:
        self.mutate(CI, "-only-testing:todoTests \\\n", "-only-testing:todoTests/FMRankingsSmokeTests \\\n")
        self.assertFires("CI-TEST-CMD", CI)

    def test_skip_selector_fails(self) -> None:
        self.mutate(CI, "-only-testing:todoTests \\\n", "-only-testing:todoTests \\\n            -skip-testing:todoTests/GmailServiceTests \\\n")
        self.assertFires("CI-TEST-CMD", CI)

    def test_other_result_bundle_fails(self) -> None:
        self.mutate(CI, '-resultBundlePath "$RUNNER_TEMP/todoTests.xcresult"', '-resultBundlePath "$RUNNER_TEMP/other.xcresult"')
        self.assertFires("CI-TEST-CMD", CI)

    def test_unpinned_worker_count_fails(self) -> None:
        self.mutate(CI, "            -parallel-testing-worker-count 1 \\\n", "")
        self.assertFires("CI-PARALLEL", CI)

    def test_other_worker_count_fails(self) -> None:
        self.mutate(CI, "-parallel-testing-worker-count 1 \\\n", "-parallel-testing-worker-count 2 \\\n")
        self.assertFires("CI-PARALLEL", CI, "-parallel-testing-worker-count 1`")

    def test_repeated_parallel_flags_fail(self) -> None:
        target = "            -parallel-testing-worker-count 1 \\\n"
        cases = [
            (target, target + "            -parallel-testing-worker-count 4 \\\n"),
            (target, target + "            -maximum-parallel-testing-workers 4 \\\n"),
        ]
        self.mutations(CI, cases, "CI-PARALLEL", "exactly once each")

    def test_conditional_build_step_fails(self) -> None:
        self.mutate(
            CI,
            "      - name: Build for testing (app + test bundles)\n        run: |\n",
            "      - name: Build for testing (app + test bundles)\n        if: always()\n        run: |\n",
        )
        self.assertFires("CI-BUILD-CMD", CI, "must not have an `if:`")

    def test_build_after_test_step_fails(self) -> None:
        self.move(CI, "      - name: Build for testing (app + test bundles)\n", "      # 테스트 호스트가 멈추면", "      # 진단 전용")
        self.assertFires("CI-BUILD-CMD", CI, "must run before the test step")

    def test_conditional_test_step_fails(self) -> None:
        self.mutate(CI, "        id: test\n", "        id: test\n        if: always()\n")
        self.assertFires("CI-TEST-CMD", CI, "must not have an `if:`")

    def test_test_step_rebuilding_fails(self) -> None:
        self.mutate(CI, "          xcodebuild test-without-building \\\n", "          xcodebuild test \\\n")
        self.assertFires("CI-TEST-CMD", CI, "test-without-building`")

    def test_serial_testing_fails(self) -> None:
        self.mutate(CI, "            -parallel-testing-enabled YES \\\n", "            -parallel-testing-enabled NO \\\n")
        self.assertFires("CI-PARALLEL", CI)

    def test_mismatched_derived_data_fails(self) -> None:
        self.mutate(CI, '"$RUNNER_TEMP/DerivedData"', '"$RUNNER_TEMP/Other"', count=2)
        self.assertFires("CI-BUILD-CMD", CI)
        self.assertFires("CI-TEST-CMD", CI)

    def test_removing_integrity_step_fails(self) -> None:
        self.mutate(CI, "      - name: Verify Package.resolved integrity\n        run: sh ci_scripts/ci_pre_xcodebuild.sh\n", "")
        self.assertFires("CI-MACRO", CI)

    def test_integrity_step_after_build_fails(self) -> None:
        self.move(CI, "      - name: Verify Package.resolved integrity\n", "      # 이름만으로는", "      # 테스트 호스트가 멈추면")
        self.assertFires("CI-MACRO", CI, "before the integrity step")

    def test_conditional_integrity_step_fails(self) -> None:
        target = "        run: sh ci_scripts/ci_pre_xcodebuild.sh\n"
        cases = [(target, "        if: always()\n" + target), (target, "        continue-on-error: true\n" + target)]
        self.mutations(CI, cases, "CI-MACRO", "must be unconditional")

    # -- triggers, permissions, concurrency, checkout ------------------------

    def test_ci_paths_drift_fails(self) -> None:
        self.mutate(CI, "      - 'ci_scripts/**'\n", "", count=2)
        self.assertFires("TRIGGERS", CI)

    def test_meeting_api_dispatch_removed_fails(self) -> None:
        self.mutate(MEETING_API, "  workflow_dispatch:\n", "")
        self.assertFires("TRIGGERS", MEETING_API)

    def test_contract_trigger_path_removed_fails(self) -> None:
        self.mutate(CONTRACT, "      - 'backend/meeting-api/vitest*.ts'\n", "", count=2)
        self.assertFires("TRIGGERS", CONTRACT)

    def test_write_permission_fails(self) -> None:
        self.mutate(MEETING_API, "permissions:\n  contents: read\n", "permissions:\n  contents: write\n")
        self.assertFires("PERMISSIONS", MEETING_API)

    def test_job_level_permissions_fail(self) -> None:
        self.mutate(CI, "    runs-on: macos-26\n", "    runs-on: macos-26\n    permissions:\n      contents: write\n")
        self.assertFires("PERMISSIONS", CI)

    def test_renamed_ci_job_fails(self) -> None:
        self.mutate(CI, "  build-test:\n", "  build:\n")
        self.assertFires("CI-JOB", CI)

    def test_missing_permissions_fails(self) -> None:
        self.mutate(CI, "permissions:\n  contents: read\n", "")
        self.assertFires("PERMISSIONS", CI)

    def test_cancelling_main_runs_fails(self) -> None:
        self.mutate(CI, "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", "  cancel-in-progress: true\n")
        self.assertFires("CONCURRENCY", CI)

    def test_shared_push_group_fails(self) -> None:
        self.mutate(MEETING_API, "|| github.run_id }}", "|| github.ref }}")
        self.assertFires("CONCURRENCY", MEETING_API)

    def test_persisted_checkout_credentials_fail(self) -> None:
        self.mutate(CI, "        with:\n          persist-credentials: false\n", "")
        self.assertFires("CHECKOUT-CREDENTIALS", CI)

    def test_workflow_without_checkout_fails(self) -> None:
        self.mutate(MEETING_API, "      - uses: actions/checkout@v4\n        with:\n          persist-credentials: false\n\n", "")
        self.assertFires("CHECKOUT-CREDENTIALS", MEETING_API, "no actions/checkout step")

    def test_workflow_without_jobs_fails(self) -> None:
        self.mutate(MEETING_API, "jobs:\n", "x-jobs:\n")
        self.assertFires("CI-JOB", MEETING_API, "no jobs")

    def test_job_shell_override_fails(self) -> None:
        self.mutate(CI, "    runs-on: macos-26\n", "    runs-on: macos-26\n    defaults:\n      run:\n        shell: sh\n")
        self.assertFires("SHELL", CI, "job build-test overrides the default shell")

    def test_job_continue_on_error_fails(self) -> None:
        self.mutate(CI, "    runs-on: macos-26\n", "    runs-on: macos-26\n    continue-on-error: true\n")
        self.assertFires("CONTINUE-ON-ERROR", CI, "job build-test sets continue-on-error")

    # -- jobs always run (rules 3 and 9) ------------------------------------

    def test_conditional_jobs_fail(self) -> None:
        cases = {
            CI: ["false", "github.actor != 'dependabot[bot]'"],
            MEETING_API: ["false", "github.actor != 'dependabot[bot]'"],
            CONTRACT: ["false"],
        }
        for rel, conditions in cases.items():
            runs_on = "    runs-on: macos-26\n" if rel == CI else "    runs-on: ubuntu-latest\n"
            self.mutations(
                rel,
                [(runs_on, f"    if: {condition}\n{runs_on}") for condition in conditions],
                "JOB-UNCONDITIONAL",
                "must not have an `if:`",
            )

    def test_job_needing_a_skipped_job_fails(self) -> None:
        self.mutate(
            CI,
            "jobs:\n  build-test:\n    runs-on: macos-26\n",
            "jobs:\n  version-check:\n    if: false\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n"
            "  build-test:\n    needs: version-check\n    runs-on: macos-26\n",
        )
        self.assertFires("JOB-UNCONDITIONAL", CI, "job build-test must not use `needs:`")
        self.assertFires("JOB-UNCONDITIONAL", CI, "job version-check must not have an `if:`")

    # -- runners, expressions, secrets (rule 10, injection) ------------------

    def test_self_hosted_runners_fail(self) -> None:
        self.mutations(CI, [("    runs-on: macos-26\n", "    runs-on: [self-hosted, macOS]\n")], "RUNS-ON")
        self.mutations(MEETING_API, [("    runs-on: ubuntu-latest\n", "    runs-on: self-hosted\n")], "RUNS-ON")

    def test_contract_job_on_a_list_runner_fails(self) -> None:
        self.mutate(CONTRACT, "    runs-on: ubuntu-latest\n", "    runs-on: [ubuntu-latest]\n")
        self.assertFires("RUNS-ON", CONTRACT)
        self.assertFires("CONTRACT-JOB", CONTRACT, "ubuntu-* runner")

    def test_contract_job_on_macos_fails(self) -> None:
        self.mutate(CONTRACT, "    runs-on: ubuntu-latest\n", "    runs-on: macos-26\n")
        self.assertFires("CONTRACT-JOB", CONTRACT, "ubuntu-* runner")
        self.assertFalse([v for v in contract.check(self.root) if v.check == "RUNS-ON"])

    def test_expression_in_run_body_fails(self) -> None:
        cases = [
            ("        run: xcodebuild -version\n", '        run: echo "${{ github.head_ref }}"\n'),
            (
                "      - name: Resolve simulator\n        run: |\n",
                "      - name: Resolve simulator\n        run: |\n          # ${{ github.head_ref }}\n",
            ),
        ]
        self.mutations(CI, cases, "RUN-EXPRESSION")

    def test_secret_references_fail(self) -> None:
        self.mutations(
            CI,
            [("      SIM_RUNTIME: 'iOS-26-5'\n", "      SIM_RUNTIME: 'iOS-26-5'\n      TOKEN: ${{ secrets.GITHUB_TOKEN }}\n")],
            "SECRETS",
        )
        self.mutations(
            MEETING_API,
            [("          persist-credentials: false\n", "          persist-credentials: false\n          token: ${{ github.token }}\n")],
            "SECRETS",
        )

    # -- meeting-api suites -------------------------------------------------

    def test_unit_config_running_integration_tests_fails(self) -> None:
        self.mutate(UNIT, "exclude: [...configDefaults.exclude, 'test/integration/**']", "exclude: [...configDefaults.exclude]")
        self.assertFires("VITEST-UNIT", UNIT)

    def test_unit_config_without_exclude_fails(self) -> None:
        self.mutate(UNIT, "    exclude: [...configDefaults.exclude, 'test/integration/**']\n", "")
        self.assertFires("VITEST-UNIT", UNIT)

    def test_integration_config_including_unit_tests_fails(self) -> None:
        self.mutate(INTEGRATION, "include: ['test/integration/**/*.test.ts']", "include: ['test/**/*.test.ts']")
        self.assertFires("VITEST-INTEGRATION", INTEGRATION)

    def test_integration_config_merging_unit_config_fails(self) -> None:
        target = "import { defineConfig } from 'vitest/config';\n"
        cases = [
            (target, "import { defineConfig, mergeConfig } from 'vitest/config';\n"),
            (target, target + "import unit from './vitest.config';\n"),
        ]
        self.mutations(INTEGRATION, cases, "VITEST-INTEGRATION", "must stay standalone")

    def test_unit_config_other_include_fails(self) -> None:
        self.mutate(UNIT, "include: ['test/**/*.test.ts']", "include: ['test/unit/**/*.test.ts']")
        self.assertFires("VITEST-UNIT", UNIT, "include must be exactly")

    def test_unit_config_dropping_default_excludes_fails(self) -> None:
        self.mutate(UNIT, "exclude: [...configDefaults.exclude, 'test/integration/**']", "exclude: ['test/integration/**']")
        self.assertFires("VITEST-UNIT", UNIT, "configDefaults")

    def test_pass_with_no_tests_fails(self) -> None:
        for rel, check in ((UNIT, "VITEST-UNIT"), (INTEGRATION, "VITEST-INTEGRATION")):
            self.mutations(
                rel,
                [("    environment: 'node',\n", "    environment: 'node',\n    passWithNoTests: true,\n")],
                check,
                "passWithNoTests",
            )

    def test_missing_vitest_config_fails(self) -> None:
        (self.root / UNIT).unlink()
        self.assertFires("VITEST-UNIT", UNIT, "cannot read")

    def test_unit_script_pointing_at_integration_config_fails(self) -> None:
        self.mutate(PACKAGE, '"test": "vitest run",', '"test": "vitest run --config vitest.integration.config.ts",')
        self.assertFires("NPM-SCRIPTS", PACKAGE)

    def test_integration_script_changed_fails(self) -> None:
        self.mutate(
            PACKAGE,
            '"test:integration": "vitest run --config vitest.integration.config.ts"',
            '"test:integration": "vitest run"',
        )
        self.assertFires("NPM-SCRIPTS", PACKAGE, "'test:integration'")

    def test_invalid_package_json_fails(self) -> None:
        self.mutate(PACKAGE, '"test": "vitest run",', '"test": "vitest run",,')
        self.assertFires("NPM-SCRIPTS", PACKAGE, "invalid JSON")

    def test_meeting_api_without_unit_tests_fails(self) -> None:
        self.mutate(MEETING_API, "      - name: Test\n        run: npm test\n\n", "")
        self.assertFires("MEETING-API-STEPS", MEETING_API)

    def test_meeting_api_without_install_or_build_fails(self) -> None:
        cases = [
            ("      - name: Install dependencies\n        run: npm ci\n\n", ""),
            ("\n      - name: Build\n        run: npm run build\n", "\n"),
        ]
        self.mutations(MEETING_API, cases, "MEETING-API-STEPS", "expected exactly one")

    def test_meeting_api_step_order_fails(self) -> None:
        self.mutate(
            MEETING_API,
            "      - name: Test\n        run: npm test\n\n      - name: Build\n        run: npm run build",
            "      - name: Build\n        run: npm run build\n\n      - name: Test\n        run: npm test",
        )
        self.assertFires("MEETING-API-STEPS", MEETING_API, "in order")

    def test_conditional_meeting_api_step_fails(self) -> None:
        self.mutate(MEETING_API, "      - name: Test\n        run: npm test\n", "      - name: Test\n        if: false\n        run: npm test\n")
        self.assertFires("MEETING-API-STEPS", MEETING_API, "must not have an `if:`")

    def test_meeting_api_working_directory_fails(self) -> None:
        self.mutate(MEETING_API, "    working-directory: backend/meeting-api\n", "")
        self.assertFires("MEETING-API-STEPS", MEETING_API, "working-directory")

    def test_contract_workflow_without_checker_fails(self) -> None:
        self.mutate(CONTRACT, "        run: python3 scripts/check_ci_contract.py\n", "        run: echo skipped\n")
        self.assertFires("CONTRACT-JOB", CONTRACT, "scripts/check_ci_contract.py`")

    def test_contract_workflow_without_mutation_tests_fails(self) -> None:
        self.mutate(CONTRACT, "python3 -m unittest discover", "echo skipped")
        self.assertFires("CONTRACT-JOB", CONTRACT, "mutation tests")

    def test_conditional_contract_step_fails(self) -> None:
        self.mutate(CONTRACT, "      - name: Check CI contract\n", "      - name: Check CI contract\n        if: false\n")
        self.assertFires("CONTRACT-JOB", CONTRACT, "must not have an `if:`")

    # -- parser strictness (fail closed) ------------------------------------

    def test_unsupported_yaml_in_a_workflow_fails(self) -> None:
        self.mutate(CI, "permissions:\n  contents: read\n", "permissions: &perms\n  contents: read\n")
        self.assertFires("PARSE", CI)

    def test_unsupported_yaml_in_another_workflow_fails(self) -> None:
        (self.root / ".github/workflows/other.yml").write_text("name: &x Other\n", encoding="utf-8")
        self.assertFires("PARSE", ".github/workflows/other.yml")

    def test_missing_pinned_workflow_fails(self) -> None:
        (self.root / MEETING_API).unlink()
        self.assertFires("PARSE", MEETING_API)


class ParserTest(unittest.TestCase):
    def test_supported_subset(self) -> None:
        text = (
            "on:\n"
            "  push:\n"
            '    branches: [ "main", \'dev\' ]\n'
            "  workflow_dispatch:\n"
            "jobs:\n"
            "  a:\n"
            "    steps:\n"
            "      - uses: x@v1 # pinned\n"
            "        with:\n"
            "          k: 'it''s'\n"
            "      - name: Run\n"
            "        run: |\n"
            "          echo a \\\n"
            "            | cat\n"
            "\n"
            "          # shell comment\n"
            "list:\n"
            "- one\n"
            "- \"two\\tx\"\n"
        )
        self.assertEqual(
            contract.parse_yaml(text),
            {
                "on": {"push": {"branches": ["main", "dev"]}, "workflow_dispatch": None},
                "jobs": {
                    "a": {
                        "steps": [
                            {"uses": "x@v1", "with": {"k": "it's"}},
                            {"name": "Run", "run": "echo a \\\n  | cat\n\n# shell comment\n"},
                        ]
                    }
                },
                "list": ["one", "two\tx"],
            },
        )

    def test_nested_sequences(self) -> None:
        self.assertEqual(contract.parse_yaml("a:\n- - x\n  - y\n- z\n"), {"a": [["x", "y"], "z"]})

    def test_rejects_constructs_outside_the_subset(self) -> None:
        for text in (
            "a: &x 1\n",
            "a: *x\n",
            "a: !tag 1\n",
            "a: >\n  folded\n",
            "a: {b: 1}\n",
            "a:\n\tb: 1\n",
            "a: 1\na: 2\n",
            "a: b: c\n",
            "a:\n  b: 1\n    c: 2\n",
            "a: 'unterminated\n",
            "---\na: 1\n",
            "a: |2\n  x\n",
            "a: b:\n",
            "a: [x, , y]\n",
            "a: [x #y]\n",
            "a: [k: v]\n",
        ):
            with self.subTest(text=text), self.assertRaises(contract.YamlSubsetError):
                contract.parse_yaml(text)

    def test_shell_literals_are_not_commands(self) -> None:
        code = contract.shell_code('echo "xcodebuild failed ($x)" || true\nv="$(xcodebuild -version)"\n')
        self.assertNotIn("xcodebuild failed", code)
        self.assertIn("$(xcodebuild -version)", code)

    def test_ts_comment_stripping_keeps_globs(self) -> None:
        code = contract.strip_ts_comments("// mergeConfig\n/* x */ include: ['test/**/*.test.ts'] // tail\n")
        self.assertNotIn("mergeConfig", code)
        self.assertIn("'test/**/*.test.ts'", code)


if __name__ == "__main__":
    unittest.main()
