"""CMQ 专用 gate 清单的静态完整性测试。"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class CmqGateManifestTest(unittest.TestCase):
    """验证 manifest 顺序、唯一性以及 UVM 注册闭合。"""

    # 功能：读取清单中的非注释测试名，保持与 shell gate 相同的过滤规则。
    # 输入输出及副作用：无显式输入；返回字符串列表，不写入文件或修改环境。
    # 失败边界：不存在文件时由 Path.read_text 抛出异常，测试明确失败。
    def _rows(self):
        lines = (ROOT / "sim" / "cmq_gate.list").read_text().splitlines()
        return [line.strip() for line in lines
                if line.strip() and not line.lstrip().startswith("#")]

    # 功能：确认 gate 清单与固定 CMQ 测试顺序完全一致，并拒绝重复或非法 token。
    # 输入输出及副作用：读取仓库文本；断言失败只影响当前 unittest，不产生外部副作用。
    # 失败边界：缺项、额外项、重复项或不符合 SV 标识符规则时测试失败。
    def test_exact_rows(self):
        expected = [
            "rdma_cmq_codec_test",
            "rdma_cmq_completion_test",
            "rdma_cmq_profile_test",
            "rdma_doorbell_codec_test",
            "rdma_cmq_engine_test",
            "rdma_cmq_driver_field_mutation_test",
        ]
        rows = self._rows()
        self.assertEqual(rows, expected)
        self.assertEqual(len(rows), len(set(rows)))
        self.assertTrue(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", row)
                            for row in rows))

    # 功能：确认每个清单测试已在 rdma_unit_test_pkg 中 include 且 mutation test 已进入 CORE_TESTS。
    # 输入输出及副作用：读取 package 与 regression shell 文本；不修改任何文件。
    # 失败边界：include 缺失、顺序不邻接或 CORE_TESTS 未注册时测试失败。
    def test_registration(self):
        package = (ROOT / "tests" / "rdma_unit_test_pkg.sv").read_text()
        regression = (ROOT / "scripts" / "run_queue_lifecycle_regression53.sh").read_text()
        for name in self._rows():
            self.assertRegex(package, rf'include "unit/{name}\.sv"')
        self.assertIn("rdma_cmq_driver_field_mutation_test", regression)
        profile_pos = regression.index("rdma_cmq_profile_test")
        mutation_pos = regression.index("rdma_cmq_driver_field_mutation_test")
        self.assertGreater(mutation_pos, profile_pos)


if __name__ == "__main__":
    unittest.main()
