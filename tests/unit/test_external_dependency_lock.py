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

    def test_parser_rejects_extra_tsv_field(self):
        """功能：确认数据行增加第十列时不会被 DictReader 静默丢弃。\n输入输出及副作用：写入一个带额外字段的临时锁并调用 parser；不修改仓库。\n失败边界：未抛出 extra lock fields 表示 schema 未严格锁定。"""
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "lock.tsv"
            path.write_text("\t".join(LOCK.SCHEMA) + "\n" + "dep\tUNAPPROVED\tROOT\t-\t-\tsrc\tDIRECT\tsrc/a.sv\t-\textra\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "extra lock fields"):
                LOCK.parse_lock(path)

    def test_closure_rejects_symlink_shadow_and_cycle(self):
        """功能：覆盖 include 文件/目录符号链接、ambiguous shadow 和循环 include 拒绝。\n输入输出及副作用：构造三个独立临时快照并调用 closure；fixture 仅存在于临时目录。\n失败边界：任何非法闭包未抛 ValueError 都表示外部输入可绕过锁。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "src/a.sv").write_text('`include "b.sv"\n', encoding="utf-8")
            (root / "src/real.sv").write_text("module real; endmodule\n", encoding="utf-8")
            (root / "src/b.sv").symlink_to("real.sv")
            with self.assertRaises(ValueError):
                LOCK.closure(root, ["src/a.sv"], ("src",))

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "inc").mkdir()
            (root / "src/a.sv").write_text('`include "b.sv"\n', encoding="utf-8")
            (root / "src/b.sv").write_text("module b; endmodule\n", encoding="utf-8")
            (root / "inc/b.sv").write_text("module b2; endmodule\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "ambiguous"):
                LOCK.closure(root, ["src/a.sv"], ("src", "inc"))

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "src/a.sv").write_text('`include "b.sv"\n', encoding="utf-8")
            (root / "src/b.sv").write_text('`include "a.sv"\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "cycle"):
                LOCK.closure(root, ["src/a.sv"], ("src",))

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "real-inc").mkdir()
            (root / "src/a.sv").write_text('`include "b.sv"\n', encoding="utf-8")
            (root / "real-inc/b.sv").write_text("module b; endmodule\n", encoding="utf-8")
            (root / "inc").symlink_to("real-inc", target_is_directory=True)
            with self.assertRaises(ValueError):
                LOCK.closure(root, ["src/a.sv"], ("inc",))

    def test_capture_rejects_approved_and_dangling_candidate(self):
        """功能：确认 capture 不接受 APPROVED 组且拒绝悬空候选符号链接。\n输入输出及副作用：使用最小 Row 夹具调用 capture；不触碰正式锁文件。\n失败边界：批准依赖或 dangling symlink 被覆盖即测试失败。"""
        row = LOCK.Row("dep", "APPROVED", "ROOT", "a" * 40, "b" * 64, ("src",), "DIRECT", "src/a.sv", "c" * 64)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "src/a.sv").write_text("module a; endmodule\n", encoding="utf-8")
            candidate = Path(tempfile.mkdtemp(prefix="rdma-candidate-", dir="/tmp")) / "out.tsv"
            with self.assertRaisesRegex(ValueError, "capture requires unapproved"):
                LOCK.capture([row], "dep", str(root), str(candidate))
            unapproved = LOCK.Row("dep", "UNAPPROVED", "ROOT", "-", "-", ("src",), "DIRECT", "src/a.sv", "-")
            candidate.unlink(missing_ok=True)
            candidate.symlink_to("missing-target")
            with self.assertRaisesRegex(ValueError, "candidate is symlink"):
                LOCK.capture([unapproved], "dep", str(root), str(candidate))

    def test_unresolved_include_and_unapproved_fail_before_root(self):
        """功能：验证未知 include 被拒绝，且 UNAPPROVED 在访问不存在 root 前 fail closed。\n输入输出及副作用：构造最小快照并调用 closure/verify；不创建外部资源。\n失败边界：错误顺序或未解析 include 被接受都会使测试失败。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            (root / "src/a.sv").write_text('`include "missing.sv"\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unresolved include"):
                LOCK.closure(root, ["src/a.sv"], ("src",))
            row = LOCK.Row("dep", "UNAPPROVED", "ROOT", "-", "-", ("src",), "DIRECT", "src/a.sv", "-")
            with self.assertRaisesRegex(ValueError, "external dependency is not approved"):
                LOCK.verify([row], "dep", str(Path(temp) / "does-not-exist"))

    def test_approved_plain_snapshot_uses_tree_digest(self):
        """功能：确认 approved 快照保留 40 位 provenance 时仍按文件摘要和 tree digest 验证。\n输入输出及副作用：构造普通非 Git root，先验证匹配摘要，再修改文件验证 drift 拒绝。\n失败边界：快照因 git_commit 非 '-' 被错误拒绝，或文件漂移未被检测，均表示身份契约错误。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "root"
            (root / "src").mkdir(parents=True)
            source = root / "src/a.sv"
            source.write_text("module a; endmodule\n", encoding="utf-8")
            digest = LOCK._hash(source)
            tree = LOCK.tree_digest(root, ["src/a.sv"])
            row = LOCK.Row("dep", "APPROVED", "ROOT", "a" * 40, tree, ("src",), "DIRECT", "src/a.sv", digest)
            LOCK.verify([row], "dep", str(root))
            source.write_text("module changed; endmodule\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash drift|snapshot identity drift"):
                LOCK.verify([row], "dep", str(root))

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
