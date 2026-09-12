"""目录：tests/unit，外部依赖锁工具的最小回归夹具和契约断言。"""
import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
SPEC = importlib.util.spec_from_file_location("lock", ROOT / "tools/check_external_dependency_lock.py")
LOCK = importlib.util.module_from_spec(SPEC)
sys.modules["lock"] = LOCK
SPEC.loader.exec_module(LOCK)


class ExternalDependencyLockTest(unittest.TestCase):
    """功能：覆盖 parser 的关键拒绝条件和 capture 的原子输出。\n输入输出及副作用：测试在临时目录构造普通快照，断言异常及候选字节；结束后删除 fixture。\n失败边界：任一锁字段校验或候选权限偏离契约都会使测试失败。"""

    def test_parser_rejects_duplicate_and_bad_path(self):
        """功能：验证重复键和绝对路径不能进入依赖模型。\n输入输出及副作用：写入临时 TSV 并调用 parse_lock；不修改仓库文件。\n失败边界：parser 未抛 ValueError 表示校验过宽。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "lock.tsv"
            path.write_text("\t".join(LOCK.SCHEMA) + "\n" + "x\tUNAPPROVED\tX\t-\t-\tsrc\tDIRECT\t/a\t-\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                LOCK.parse_lock(path)

    def test_capture_snapshot_is_sorted_and_private(self):
        """功能：确认非 Git 快照候选按路径排序并使用 0600 权限。\n输入输出及副作用：构造含 include 的临时 root 和 unapproved lock，capture 写入 /tmp 候选。\n失败边界：候选内容、权限或源锁发生变化时测试失败。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "src/a.sv").write_text('`include "b.sv"\n', encoding="utf-8")
            (root / "src/b.sv").write_text("module b; endmodule\n", encoding="utf-8")
            digest = hashlib.sha256
            lock = Path(temp) / "lock.tsv"
            lock.write_text("\t".join(LOCK.SCHEMA) + "\n" + "dep\tUNAPPROVED\tDEP_ROOT\t-\t-\tsrc\tDIRECT\tsrc/a.sv\t-\n", encoding="utf-8")
            before = lock.read_bytes()
            candidate = Path(tempfile.mkdtemp(prefix="rdma-test-", dir="/tmp")) / "candidate.tsv"
            LOCK.capture(LOCK.parse_lock(lock), "dep", str(root), str(candidate))
            self.assertEqual(candidate.stat().st_mode & 0o777, 0o600)
            self.assertEqual(lock.read_bytes(), before)
            rows = candidate.read_text(encoding="utf-8").splitlines()[1:]
            self.assertEqual([line.split("\t")[7] for line in rows], ["src/a.sv", "src/b.sv"])


if __name__ == "__main__":
    unittest.main()
