"""目录：tests/unit，run_vcs53 同步 helper 的排除契约测试。"""
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts/run_vcs53.sh"


class RunVcs53SyncTest(unittest.TestCase):
    """功能：从脚本导入 sync_repo 并验证 rsync dry-run 只保留仿真输入。\n输入输出及副作用：构造临时 source/destination，调用 Bash helper；dry-run 保证 destination 不写入。\n失败边界：任何排除目录出现在 itemized 输出，或导入触发 SSH，均使测试失败。"""

    def test_guarded_source_and_exclusions(self):
        """功能：确认脚本被 source 时不执行 main，并检查精确排除数组。\n输入输出及副作用：写入临时 source 树并运行 bash source+sync；只产生 rsync dry-run 输出。\n失败边界：rsync 不可用、保留输入缺失或目标目录出现文件时失败。"""
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "src tree"
            dest = root / "dest"
            for rel in ["hw/rdma/input.sv", "src/a.sv", "tests/t.sv", "tools/x.py", "sim/filelists/core.f", "space name/in.sv"]:
                path = source / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x", encoding="utf-8")
            for rel in [".git/config", ".worktrees/x", "sim/build/x", "__pycache__/x.pyc", "nested/__pycache__/y.pyc", "bad.pyc"]:
                path = source / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x", encoding="utf-8")
            dest.mkdir()
            command = f"source {SCRIPT!s}; sync_repo {source.as_posix()!r} {dest.as_posix()!r} --dry-run"
            result = subprocess.run(["bash", "-c", command], text=True, capture_output=True, check=True)
            self.assertIn("input.sv", result.stdout)
            self.assertIn("space name/in.sv", result.stdout)
            self.assertNotIn(".git/config", result.stdout)
            self.assertFalse(any(dest.iterdir()))


if __name__ == "__main__":
    unittest.main()
