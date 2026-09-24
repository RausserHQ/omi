#!/usr/bin/env python3
"""Unit tests for check_runner_cost_policy.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_runner_cost_policy import validate


def write_workflow(root: Path, name: str, runs_on: str) -> None:
    workflows = root / ".github" / "workflows"
    workflows.mkdir(parents=True, exist_ok=True)
    (workflows / name).write_text(
        f"name: fixture\njobs:\n  test:\n    runs-on: {runs_on}\n    steps: []\n",
        encoding="utf-8",
    )


class RunnerCostPolicyTests(unittest.TestCase):
    def test_accepts_standard_public_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "standard.yml", "ubuntu-latest")
            self.assertEqual(validate(root), [])

    def test_rejects_paid_runner_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "paid.yml", "ubuntu-latest-m")
            self.assertEqual(
                validate(root),
                [
                    ".github/workflows/paid.yml:4: paid runner label 'ubuntu-latest-m' "
                    "is forbidden; public-repository jobs must use a standard runner"
                ],
            )

    def test_rejects_archive_pr_trigger(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "ios-build-artifacts.yml", "macos-26")
            workflow = root / ".github/workflows/ios-build-artifacts.yml"
            workflow.write_text("on:\n  pull_request:\n" + workflow.read_text())
            self.assertIn("archive workflow must not run on pull requests", validate(root)[0])

    def test_rejects_self_hosted_pr_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "public.yml", "[self-hosted, macOS]")
            workflow = root / ".github/workflows/public.yml"
            workflow.write_text("on:\n  pull_request:\n" + workflow.read_text())
            self.assertIn("unapproved PR runner", validate(root)[0])

    def test_accepts_hosted_matrix_pr_runners(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workflow = root / ".github/workflows/public.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                "on:\n  pull_request:\njobs:\n  test:\n    strategy:\n"
                "      matrix:\n        os: [ubuntu-latest, macos-26]\n"
                "    runs-on: ${{ matrix.os }}\n"
            )
            self.assertEqual(validate(root), [])

    def test_rejects_self_hosted_matrix_pr_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workflow = root / ".github/workflows/public.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                "on:\n  pull_request:\njobs:\n  test:\n    strategy:\n"
                "      matrix:\n        include:\n          - os: ubuntu-latest\n"
                "          - os: self-hosted\n"
                "    runs-on: ${{ matrix.os }}\n"
            )
            self.assertIn("unapproved PR runner 'self-hosted'", validate(root)[0])

    def test_rejects_self_hosted_target_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "public.yml", "self-hosted")
            workflow = root / ".github/workflows/public.yml"
            workflow.write_text("on:\n  pull_request_target:\n" + workflow.read_text())
            self.assertIn("unapproved PR runner", validate(root)[0])

    def test_rejects_dynamic_pr_runner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "public.yml", "${{ vars.RUNNER }}")
            workflow = root / ".github/workflows/public.yml"
            workflow.write_text("on:\n  pull_request:\n" + workflow.read_text())
            self.assertIn("unapproved PR runner", validate(root)[0])

    def test_checks_yaml_extension(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_workflow(root, "paid.yaml", "ubuntu-latest-m")
            self.assertEqual(len(validate(root)), 1)


if __name__ == "__main__":
    unittest.main()
