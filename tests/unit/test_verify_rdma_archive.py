# 目录：tests/unit，RDMA archive verifier 契约单元测试。
# 职责：构造各类 tar 边界 fixture，验证锁定、路径安全与原子性。
# 资源所有权：TemporaryDirectory 拥有 fixture 生命周期，被测代码仅可读取。

from __future__ import annotations

import hashlib
from pathlib import Path
import tarfile
import tempfile
import unittest

from tools import rdma_driver_contract as contract
from tools import verify_rdma_archive as verifier


class ArchiveFixtureTest(unittest.TestCase):
    """功能：以小型 tar fixture 覆盖 archive gate 所有失败边界。
    输入输出及副作用：辅助函数输入 member 定义，输出临时文件和 lock。
    失败边界：任一不合法 member 或 digest 都应抛出 ContractError 且不留 staging。"""

    def make_archive(self, root: Path, members, *, lock_overrides=None):
        """功能：创建含指定 member 的 gzip tar 并生成配套 lock。
输入输出及副作用：members 是 (name, kind, bytes) 序列，返回 archive/lock/manifest 路径。
失败边界：members 重复名称仅用于构造拒绝 fixture，其他输入必须是 tarfile 支持的类型。"""
        archive = root / "driver.tar.gz"
        names = []
        with tarfile.open(archive, "w:gz") as tar:
            for name, kind, data in members:
                info = tarfile.TarInfo(name)
                if kind == "dir":
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.size = 0
                    tar.addfile(info)
                    names.append(name.rstrip("/") + "/")
                elif kind == "file":
                    payload = data or b""
                    info.size = len(payload)
                    tar.addfile(info, __import__("io").BytesIO(payload))
                    names.append(name)
                else:
                    type_map = {"symlink": tarfile.SYMTYPE, "hardlink": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE, "chr": tarfile.CHRTYPE}
                    info.type = type_map[kind]
                    tar.addfile(info)
                    names.append(name)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        try:
            member_digest = contract.canonical_member_list_digest(names)
        except contract.ContractError:
            payload = "\n".join(sorted(names, key=lambda name: name.encode("utf-8"))) + "\n"
            member_digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        lock_values = {
            "RDMA_ARCHIVE_ID": "fixture",
            "RDMA_ARCHIVE_SHA256": digest,
            "RDMA_ARCHIVE_SIZE_BYTES": str(archive.stat().st_size),
            "RDMA_ARCHIVE_PREFIX": "kernel",
            "RDMA_ARCHIVE_MEMBER_LIST_SHA256": member_digest,
            "RDMA_ARCHIVE_MEMBER_COUNT": str(len(names)),
        }
        if lock_overrides:
            lock_values.update(lock_overrides)
        lock = root / "lock.env"
        lock.write_text("".join(f"{k}={v}\n" for k, v in lock_values.items()), encoding="utf-8")
        manifest = root / "manifest.txt"
        manifest.write_text("fixture file.h any " + hashlib.sha256(b"x").hexdigest() + "\n", encoding="utf-8")
        return archive, lock, manifest

    def run_verify(self, members, **kwargs):
        """功能：在临时目录中调用 verify_archive。
输入输出及副作用：members 传至 make_archive，返回根目录、与异常相关的目录快照。
失败边界：测试仅在临时根下运行，不应触碰仓库路径。"""
        root = Path(tempfile.mkdtemp())
        archive, lock, manifest = self.make_archive(root, members, lock_overrides=kwargs.pop("lock_overrides", None))
        return root, archive, lock, manifest

    def test_valid_archive(self):
        root, archive, lock, manifest = self.run_verify([("kernel", "dir", None), ("kernel/file.h", "file", b"x")])
        try:
            out = verifier.verify_archive(archive, lock, manifest, root / "out")
            self.assertEqual((out / "file.h").read_bytes(), b"x")
        finally:
            import shutil; shutil.rmtree(root)

    def assert_rejected(self, members, **kwargs):
        """功能：断言构造的 archive 被契约拒绝。
输入输出及副作用：members 和 lock_overrides 指定故障，无返回值。
失败边界：异常必须是 ContractError 子类，且输出根不得留下。"""
        root, archive, lock, manifest = self.run_verify(members, lock_overrides=kwargs.pop("lock_overrides", None))
        try:
            with self.assertRaises(contract.ContractError):
                verifier.verify_archive(archive, lock, manifest, root / "out")
            self.assertFalse(any((root / "out").glob(".rdma-stage-*")))
        finally:
            import shutil; shutil.rmtree(root)

    def test_wrong_sha(self):
        """功能：验证归档摘要漂移被拒绝；输入输出及副作用：篡改 SHA，无输出；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None)], lock_overrides={"RDMA_ARCHIVE_SHA256": "0" * 64})
    def test_wrong_size(self):
        """功能：验证归档大小漂移被拒绝；输入输出及副作用：篡改 size；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None)], lock_overrides={"RDMA_ARCHIVE_SIZE_BYTES": "1"})
    def test_wrong_prefix(self):
        """功能：验证 prefix 漂移被拒绝；输入输出及副作用：篡改 prefix；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None)], lock_overrides={"RDMA_ARCHIVE_PREFIX": "other"})
    def test_two_top_level_directories(self):
        """功能：验证多顶层目录被拒绝；输入输出及副作用：构造双根归档；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None), ("other", "dir", None)])
    def test_member_list_drift(self):
        """功能：验证成员列表摘要漂移被拒绝；输入输出及副作用：篡改摘要；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None)], lock_overrides={"RDMA_ARCHIVE_MEMBER_LIST_SHA256": "0" * 64})
    def test_wrong_member_count(self):
        """功能：验证成员计数漂移被拒绝；输入输出及副作用：篡改 count；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None)], lock_overrides={"RDMA_ARCHIVE_MEMBER_COUNT": "2"})
    def test_duplicate_member_name(self):
        """功能：验证重复成员名被拒绝；输入输出及副作用：写入重复目录；失败边界：必须抛 ContractError。"""
        self.assert_rejected([("kernel", "dir", None), ("kernel", "dir", None)])

    def test_missing_manifest_member(self):
        """功能：验证 manifest 缺失成员被拒绝；输入输出及副作用：仅提供目录；失败边界：必须抛 ContractError。"""
        root, archive, lock, manifest = self.run_verify([("kernel", "dir", None)])
        try:
            with self.assertRaises(contract.ContractError): verifier.verify_archive(archive, lock, manifest, root / "out")
        finally:
            import shutil; shutil.rmtree(root)

    def test_unsafe_paths(self):
        """功能：验证绝对、遍历、空组件和反斜线路径均拒绝；输入输出及副作用：循环构造 fixture；失败边界：每项抛 ContractError。"""
        for path in ("/kernel/x", "kernel/../x", "kernel//x", "kernel/./x", "kernel\\x"):
            self.assert_rejected([("kernel", "dir", None), (path, "file", b"x")])

    def test_links_fifo_and_device_rejected(self):
        """功能：验证链接、FIFO、设备节点类型拒绝；输入输出及副作用：逐类构造；失败边界：每项抛 ContractError。"""
        for kind in ("symlink", "hardlink", "fifo", "chr"):
            self.assert_rejected([("kernel", "dir", None), ("kernel/x", kind, None)])

    def test_extraction_failure_is_atomic(self):
        """功能：验证提取失败清理 staging；输入输出及副作用：构造缺失 manifest；失败边界：不得残留私有目录。"""
        root, archive, lock, manifest = self.run_verify([("kernel", "dir", None)])
        try:
            with self.assertRaises(contract.ContractError): verifier.verify_archive(archive, lock, manifest, root / "out")
            self.assertFalse(any((root / "out").glob(".rdma-stage-*")))
        finally:
            import shutil; shutil.rmtree(root)


if __name__ == "__main__":
    unittest.main()
