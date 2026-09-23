"""Mutation tests for scripts/check_ci_contract.py.

Each test copies the real workflow and meeting-api files into a temporary
directory, removes or breaks one invariant, and asserts that the specific check
ID fires. Every edit asserts that its target text exists exactly the expected
number of times, so a stale mutation fails loudly instead of passing as a no-op.

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

    def assertFires(self, check: str, path: str | None = None) -> None:
        violations = contract.check(self.root)
        hits = [v for v in violations if v.check == check and (path is None or v.path == path)]
        self.assertTrue(hits, f"expected {check} for {path or 'any file'}; got {[str(v) for v in violations]}")

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
        self.assertFires("CI-GATE", CI)

    def test_gate_continue_on_error_fails(self) -> None:
        self.mutate(
            CI,
            "      - name: Require executed tests\n        run: |\n",
            "      - name: Require executed tests\n        continue-on-error: true\n        run: |\n",
        )
        self.assertFires("CI-GATE", CI)
        self.assertFires("CONTINUE-ON-ERROR", CI)

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
        self.mutate(
            INTEGRATION,
            "import { defineConfig } from 'vitest/config';\n",
            "import { defineConfig, mergeConfig } from 'vitest/config';\nimport unit from './vitest.config';\n",
        )
        self.assertFires("VITEST-INTEGRATION", INTEGRATION)

    def test_unit_script_pointing_at_integration_config_fails(self) -> None:
        self.mutate(PACKAGE, '"test": "vitest run",', '"test": "vitest run --config vitest.integration.config.ts",')
        self.assertFires("NPM-SCRIPTS", PACKAGE)

    def test_meeting_api_without_unit_tests_fails(self) -> None:
        self.mutate(MEETING_API, "      - name: Test\n        run: npm test\n\n", "")
        self.assertFires("MEETING-API-STEPS", MEETING_API)

    def test_contract_workflow_without_mutation_tests_fails(self) -> None:
        self.mutate(CONTRACT, "python3 -m unittest discover", "echo skipped")
        self.assertFires("CONTRACT-JOB", CONTRACT)

    def test_conditional_contract_step_fails(self) -> None:
        self.mutate(CONTRACT, "      - name: Check CI contract\n", "      - name: Check CI contract\n        if: false\n")
        self.assertFires("CONTRACT-JOB", CONTRACT)

    # -- parser strictness (fail closed) ------------------------------------

    def test_unsupported_yaml_in_a_workflow_fails(self) -> None:
        self.mutate(CI, "permissions:\n  contents: read\n", "permissions: &perms\n  contents: read\n")
        self.assertFires("PARSE", CI)

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
