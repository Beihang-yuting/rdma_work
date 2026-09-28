"""目录/层次：tests/unit；职责：守卫 resource 快照组件与 mutable manager 的结构边界。
依赖：Python unittest、仓库 SV 源码和既有词法扫描器；全部输入只读，不运行仿真。
所有权与生命周期：不构造 manager/adapter，不持有外部资源；动态 authority/reentry
语义仍由 VCS resource-manager、control-plane 和完整回归验证，本测试不替代仿真。
"""

from pathlib import Path
import re
import unittest

from tools.check_changed_sv_style import method_ranges, sanitize_source


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "src/core"


def read_code(path):
    """功能：读取 SV 并移除注释/字符串，避免边界测试把说明文字误识别为代码。
    输入输出及副作用：path 为仓库路径，返回保留行列位置的代码文本；只读文件。
    失败边界：缺失/无法解码文件直接使测试失败；不搜索备用源码或接受空替代输入。
    """
    return "".join(sanitize_source(path.read_text().splitlines(keepends=True)))


def declared_methods(code):
    """功能：提取完整 SV 方法名、声明与范围，供检查静态入口及类级残留状态。
    输入输出及副作用：code 为已净化源码，返回 name 到 (声明行, 起止行) 的映射。
    失败边界：调用方只传本项目完整 function/task 定义；无法辨认方法名时报错，不静默跳过。
    """
    lines = code.splitlines(keepends=True)
    result = {}
    for start, end, _ in method_ranges(lines):
        body = "".join(lines[start - 1:end])
        name = re.search(r"(\w+)\s*\(", body).group(1)
        if name in result:
            raise AssertionError(f"duplicate method: {name}")
        result[name] = (lines[start - 1].strip(), start, end)
    return result


class ResourceProjectorBoundaryTest(unittest.TestCase):
    """只读结构门禁：不把 static 或词法无状态视作无回调/无副作用的证明。"""

    def test_projector_has_only_static_automatic_methods(self):
        """功能：防止 projector 再引入实例字段、静态缓存、继承或隐藏生命周期 owner。
        输入输出及副作用：读取完整 projector，检查 47 个方法及移除方法后的类壳；只读。
        失败边界：非 static automatic 方法、类级变量/宏/继承或方法遗失均失败，局部变量允许。
        """
        code = read_code(CORE / "rdma_resource_projector.sv")
        methods = declared_methods(code)
        self.assertEqual(len(methods), 47)
        lines = code.splitlines(keepends=True)
        for declaration, start, end in methods.values():
            self.assertRegex(declaration, r"^static function automatic\b")
            lines[start - 1:end] = ["\n"] * (end - start + 1)
        self.assertEqual(
            " ".join("".join(lines).split()),
            "class rdma_resource_projector; endclass",
        )

    def test_projector_cannot_access_manager_ledger(self):
        """功能：阻止值投影组件反向引用 manager、guard 或 allocator/registry/recovery 账本。
        输入输出及副作用：读取 projector 标识符，对照已知 owner 字段；不执行函数或回调。
        失败边界：命中任一禁止标识符即失败；此扫描不声称能证明所有虚拟回调的行为。
        """
        identifiers = set(re.findall(r"\b\w+\b", read_code(CORE / "rdma_resource_projector.sv")))
        forbidden = set("""
            rdma_resource_manager registry staged_allocations recovery_records
            generation_sources binding_snapshots generation_high_water generation_exhausted
            known_generations retired_generations incarnation_owners incarnation_handles
            next_local_id free_local_ids fresh_local_id_exhausted next_object_serial
            qp_sequences publication_epoch mutation_guard semaphore
        """.split())
        self.assertFalse(identifiers & forbidden, identifiers & forbidden)

    def test_manager_uses_projector_without_duplicate_wrappers(self):
        """功能：保证 manager 不重新定义已迁移方法，也不留未限定的旧 protected helper 调用。
        输入输出及副作用：读取两类全部方法与调用 token；入口集覆盖 resource/recovery/binding 和身份检查。
        失败边界：重复定义、裸调用或关键入口缺失即失败；不禁止 manager 自己拥有的其它业务比较器。
        """
        projector = declared_methods(read_code(CORE / "rdma_resource_projector.sv"))
        manager = read_code(CORE / "rdma_resource_manager.sv")
        self.assertFalse(projector.keys() & declared_methods(manager).keys())
        for name in projector:
            self.assertNotRegex(manager, rf"(?<![\w:]){name}\s*\(")
        for name in (
            "project_resource_value", "project_public_resource_value",
            "project_recovery_value", "project_public_recovery_value",
            "project_binding_value", "publication_identity_status",
        ):
            self.assertIn(name, projector)
            self.assertIn(f"rdma_resource_projector::{name}(", manager)

    def test_package_orders_projector_before_manager(self):
        """功能：冻结 allocator policy→projector→manager 的单向 include 顺序。
        输入输出及副作用：读取 core package 原文以保留 include 字符串；不修改依赖或 lock。
        失败边界：任一 include 缺失/重复/逆序即失败，不能靠 manager 反向 include 补足类型。
        """
        package = (CORE / "rdma_core_pkg.sv").read_text()
        names = ("rdma_resource_allocator_policy.sv", "rdma_resource_projector.sv", "rdma_resource_manager.sv")
        positions = []
        for name in names:
            include = f'`include "{name}"'
            self.assertEqual(package.count(include), 1)
            positions.append(package.index(include))
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("`include", read_code(CORE / "rdma_resource_projector.sv"))

    def test_test_probes_use_explicit_projection_component(self):
        """功能：确保两个 manager 派生 probe 文件不再依赖已移走的 protected 投影入口。
        输入输出及副作用：读取 resource-manager/control-plane 测试，检查它们实际使用的四类入口。
        失败边界：裸 project 调用即失败；动态 fixture 的状态/authority 断言仍须通过 VCS。
        """
        for name in ("rdma_resource_manager_test.sv", "rdma_control_plane_test.sv"):
            code = read_code(ROOT / "tests/unit" / name)
            self.assertIn("rdma_resource_projector::", code)
            self.assertNotRegex(
                code,
                r"(?<![\w:])project_(?:public_)?(?:resource|recovery)_value\s*\(",
            )

    def test_owned_and_recovery_clone_contracts_stay_distinct(self):
        """功能：防止迁移后把普通 owned clone 与失败恢复 clone 错误统一，破坏 cleanup capability。
        输入输出及副作用：读取两种方法正文，检查 authority snapshot 与 completion query 的职责差异。
        失败边界：recovery 引入正常 authority hooks 或任一路丢失必要 hook 即失败；不证明回调执行结果。
        """
        code = read_code(CORE / "rdma_resource_projector.sv")
        lines = code.splitlines(keepends=True)
        methods = declared_methods(code)
        _, start, end = methods["clone_owned_mapping_value"]
        owned = "".join(lines[start - 1:end])
        _, start, end = methods["clone_recovery_mapping_value"]
        recovery = "".join(lines[start - 1:end])
        self.assertIn("snapshot_release_authority", owned)
        self.assertEqual(owned.count(".release_authority_status("), 2)
        self.assertEqual(recovery.count(".release_completion_status("), 2)
        self.assertNotIn("snapshot_release_authority", recovery)
        self.assertNotIn(".release_authority_status(", recovery)


if __name__ == "__main__":
    unittest.main()
