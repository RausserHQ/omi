#!/usr/bin/env python3
"""Reject paid GitHub-hosted runner labels in this public repository."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import yaml

PAID_RUNNER_LABELS = ("ubuntu-latest-m",)
HOSTED_RUNNERS = {"ubuntu-latest", "macos-26", "macos-15", "windows-latest"}
MATRIX_RUNNER = re.compile(r"^\$\{\{\s*matrix\.([a-zA-Z_][a-zA-Z_0-9]*)\s*\}\}$")


def runner_labels(job: dict) -> list[str]:
    runner = job.get("runs-on")
    if isinstance(runner, str):
        match = MATRIX_RUNNER.fullmatch(runner)
        if match:
            matrix = job.get("strategy", {}).get("matrix", {})
            key = match.group(1)
            if key in matrix:
                return matrix[key] if isinstance(matrix[key], list) else [str(matrix[key])]
            return [row.get(key) for row in matrix.get("include", [])] or [str(runner)]
        return [runner]
    return [str(runner)]


def validate(root: Path) -> list[str]:
    workflows = root / ".github" / "workflows"
    errors: list[str] = []
    for path in sorted((*workflows.glob("*.yml"), *workflows.glob("*.yaml"))):
        source = path.read_text(encoding="utf-8")
        workflow = yaml.load(source, Loader=yaml.BaseLoader) or {}
        events = workflow.get("on", {})
        if "pull_request" in events or "pull_request_target" in events:
            if path.name == "ios-build-artifacts.yml":
                errors.append(f"{path.relative_to(root)}: archive workflow must not run on pull requests")
            for job_name, job in workflow.get("jobs", {}).items():
                for label in runner_labels(job):
                    if label not in HOSTED_RUNNERS:
                        errors.append(
                            f"{path.relative_to(root)}: job {job_name} uses unapproved PR runner {label!r}; "
                            "self-hosted runners require an explicit reviewed exception"
                        )
        for line_number, line in enumerate(source.splitlines(), start=1):
            for label in PAID_RUNNER_LABELS:
                if label in line:
                    errors.append(
                        f"{path.relative_to(root)}:{line_number}: paid runner label {label!r} "
                        "is forbidden; public-repository jobs must use a standard runner"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    errors = validate(args.root.resolve())
    if errors:
        print("\n".join(errors))
        return 1
    print("GitHub runner cost policy check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
