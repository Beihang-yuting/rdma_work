#!/usr/bin/env python3
"""Contract tests for the explicit VCS53 queue lifecycle regression runner."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "scripts" / "run_queue_lifecycle_regression53.sh"
CLASS_RE = re.compile(r"class\s+(\w+)\s+extends\s+(\w+)\s*;")


def discover_uvm_tests(unit_root: Path) -> set[str]:
    parents: dict[str, str] = {}
    registered: set[str] = set()
    for path in unit_root.glob("*.sv"):
        text = path.read_text(encoding="utf-8")
        parents.update(CLASS_RE.findall(text))
        registered.update(re.findall(r"`uvm_component_utils\((\w+)\)", text))

    tests: set[str] = set()
    for class_name in registered:
        ancestor = class_name
        seen: set[str] = set()
        while ancestor in parents and ancestor not in seen:
            seen.add(ancestor)
            ancestor = parents[ancestor]
        if ancestor == "uvm_test":
            tests.add(class_name)
    tests.discard("rdma_harness_expected_failure_probe")
    return tests


class RunnerManifestTest(unittest.TestCase):
    def test_runner_lists_every_normal_unit_test(self) -> None:
        listed = set(
            subprocess.check_output([str(RUNNER), "--list"], text=True).splitlines()
        )
        self.assertNotIn("regression", listed)
        self.assertEqual(listed, discover_uvm_tests(REPO_ROOT / "tests" / "unit"))
