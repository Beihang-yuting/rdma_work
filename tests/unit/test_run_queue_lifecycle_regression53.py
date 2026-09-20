#!/usr/bin/env python3
"""Contract tests for the explicit VCS53 queue lifecycle regression runner."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "scripts" / "run_queue_lifecycle_regression53.sh"
CLASS_RE = re.compile(
    r"class\s+(\w+)\s+extends\s+(\w+)\s*;",
    flags=re.DOTALL,
)


def discover_uvm_tests(unit_root: Path) -> set[str]:
    """功能：扫描 unit 源码并收集直接或间接继承 uvm_test 的注册类。

    输入/输出及副作用：unit_root 为只读源码目录；函数读取 class 继承关系和
    ``uvm_component_utils`` 注册宏，返回测试类名集合，不修改源码或 runner。

    失败/边界：类声明或注册宏跨行时仍须识别；无法解析的孤立注册类不会被纳入
    结果，专用 expected-failure probe 按 runner 契约排除。
    """
    parents: dict[str, str] = {}
    registered: set[str] = set()
    for path in unit_root.glob("*.sv"):
        text = path.read_text(encoding="utf-8")
        parents.update(CLASS_RE.findall(text))
        registered.update(
            re.findall(
                r"`uvm_component_utils\(\s*(\w+)\s*\)",
                text,
                flags=re.DOTALL,
            )
        )

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
    # 功能：验证 queue lifecycle runner 的 --list 输出覆盖所有普通 UVM unit test。
    # 输入/输出及副作用：读取 runner 输出和 tests/unit 源码，比较两个集合，不修改
    # 仿真环境或 manifest 文件。
    # 失败/边界：不得列出 regression 聚合别名；任一跨行注册类遗漏或孤儿条目都会
    # 使断言失败，提示维护者同步清单与源码。
    def test_runner_lists_every_normal_unit_test(self) -> None:
        listed = set(
            subprocess.check_output([str(RUNNER), "--list"], text=True).splitlines()
        )
        self.assertNotIn("regression", listed)
        self.assertEqual(listed, discover_uvm_tests(REPO_ROOT / "tests" / "unit"))
