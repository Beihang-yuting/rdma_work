# 目录/层次：tests/unit，CMQ gate 清单与 core test runner 的单元门禁。
# 文件职责：检查 sim/cmq_gate.list 与 Makefile 计数一致、每项都注册为 UVM test，
#   以及 run_core_logical_test.sh 对 simulator/summary 失败的 all-of 判定。
# 主要依赖：Python unittest、临时文件系统、sim/Makefile 与 shell runner。
# 资源所有权：仓库输入只读；TemporaryDirectory 独占并回收伪 simulator、checker 与日志。
"""CMQ gate 清单与 core test runner 的完整性测试。"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run_core_logical_test.sh"


def gate_tests():
    rows = []
    for line in (ROOT / "sim" / "cmq_gate.list").read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            rows.append(line)
    return rows


def registered_tests():
    names = set()
    for path in (ROOT / "tests").rglob("*.sv"):
        names.update(re.findall(r"`uvm_component_utils\((\w+)\)", path.read_text()))
    return names


class CmqGateManifestTest(unittest.TestCase):
    def test_gate_list_is_unique_and_registered(self):
        rows = gate_tests()
        self.assertEqual(len(rows), len(set(rows)))
        self.assertIn("rdma_cmq_engine_test", rows)
        missing = sorted(set(rows) - registered_tests())
        self.assertEqual(missing, [])

    def test_makefile_count_matches_gate_list(self):
        makefile = (ROOT / "sim" / "Makefile").read_text()
        match = re.search(r"#cmq_tests\[@\]\}\s*==\s*(\d+)", makefile)
        self.assertIsNotNone(match, "cmq_gate count check is missing")
        self.assertEqual(int(match.group(1)), len(gate_tests()))

    def test_core_tests_are_registered(self):
        listed = subprocess.run(
            [str(ROOT / "scripts" / "run_queue_lifecycle_regression53.sh"), "--list"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        self.assertEqual(len(listed), len(set(listed)))
        self.assertEqual(sorted(set(listed) - registered_tests()), [])


class CoreRunnerTest(unittest.TestCase):
    def run_runner(self, sim_rc, checker_rc, test="rdma_demo_test"):
        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp)
            simv = build / "simv"
            simv.write_text(f"#!/usr/bin/env bash\necho \"$1\"\nexit {sim_rc}\n")
            simv.chmod(0o755)
            checker = build / "check.sh"
            checker.write_text(f"#!/usr/bin/env bash\ngrep -q UVM_TESTNAME \"$1\"\nexit {checker_rc}\n")
            checker.chmod(0o755)
            result = subprocess.run([str(RUNNER), test, str(build), str(checker)],
                                    capture_output=True, text=True)
            log = (build / f"{test}.log").read_text() if (build / f"{test}.log").exists() else ""
            return result, log

    def test_pass_writes_log(self):
        result, log = self.run_runner(0, 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("+UVM_TESTNAME=rdma_demo_test", log)
        self.assertIn("LOGICAL PASS logical=rdma_demo_test processes=1", result.stdout)

    def test_simulator_or_summary_failure_fails(self):
        for sim_rc, checker_rc in ((3, 0), (0, 1)):
            result, _ = self.run_runner(sim_rc, checker_rc)
            self.assertEqual(result.returncode, 1)
            self.assertIn("LOGICAL FAIL", result.stderr)

    def test_rejects_bad_arguments(self):
        result = subprocess.run([str(RUNNER), "a", "b"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        result, _ = self.run_runner(0, 0, test="bad/name")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
