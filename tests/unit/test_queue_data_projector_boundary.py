"""目录/层次：tests/unit；职责：守卫 queue-data 值投影与业务 owner 的依赖边界。
依赖：unittest、SV 词法扫描器；只读生产/测试源码，不代替 VCS 的 factory/恢复验证。
所有权与生命周期：不创建仿真对象，不修改源码或依赖；静态无状态不代表无回调。
"""

from pathlib import Path
import re
import unittest

from tools.check_changed_sv_style import method_ranges, sanitize_source


ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "src/core"


def read_code(path):
    """功能：剥离注释和字符串后读取 SV，避免说明中的 owner 名称误触发门禁。
    输入输出及副作用：path 为仓库文件，返回保留行号的源码文本；只读。
    失败边界：文件缺失或无法解码即报错，不使用空文件作为替代。
    """
    return "".join(sanitize_source(path.read_text().splitlines(keepends=True)))


def methods(code):
    """功能：提取单一 projector/engine 的方法名及完整正文，检查静态声明和调用边界。
    输入输出及副作用：code 为净化原文，返回 name 到 (start, end, body) 的映射。
    失败边界：无法解析或名称重复即失败；调用方不得传含重名方法的多类测试文件。
    """
    lines = code.splitlines(keepends=True)
    result = {}
    for start, end, _ in method_ranges(lines):
        body = "".join(lines[start - 1:end])
        name = re.search(r"(\w+)\s*\(", body).group(1)
        if name in result:
            raise AssertionError(f"duplicate method: {name}")
        result[name] = (start, end, body)
    return result


class QueueDataProjectorBoundaryTest(unittest.TestCase):
    """结构验收只证明值层没有新增 owner，动态 factory 窗口继续由既有 VCS fixture 验证。"""

    def test_stateless_automatic_methods(self):
        """功能：禁止 projector 增加实例字段、缓存、锁、继承或 UVM 工厂注册。
        输入输出及副作用：读取全部 25 个方法并移除其正文，检查剩余类壳；只读。
        失败边界：方法数变化、非 static automatic 声明或类级状态均失败。
        """
        code = read_code(CORE / "rdma_queue_data_projector.sv")
        declared = methods(code)
        self.assertEqual(len(declared), 25)
        lines = code.splitlines(keepends=True)
        for start, end, body in declared.values():
            self.assertRegex(body.lstrip(), r"^static function automatic\b")
            lines[start - 1:end] = ["\n"] * (end - start + 1)
        self.assertEqual(" ".join("".join(lines).split()),
                         "class rdma_queue_data_projector; endclass")

    def test_no_owner_or_runtime_calls(self):
        """功能：阻止 projector 反向引用 engine/manager/adapter 或查询/修改 runtime 账本。
        输入输出及副作用：检查标识符与成员调用，允许 attachment 的 queue_h 等显式值字段。
        失败边界：owner 类型/索引/锁、runtime 引用访问或 admission/commit 操作出现即失败。
        """
        code = read_code(CORE / "rdma_queue_data_projector.sv")
        forbidden = set("""
            rdma_queue_data_engine rdma_resource_manager rdma_host_mem_api
            rdma_doorbell_scheduler rdma_queue_runtime manager binding host_mem
            doorbells registry context_backing backing_planner resize_lock configured
            attachments qp_links cq_resize_recoveries unclaimed_device_recoveries
            unclaimed_recovery_attachments last_urc_evidence semaphore runtime
        """.split())
        self.assertFalse(set(re.findall(r"\b\w+\b", code)) & forbidden)
        self.assertNotRegex(code, r"\.\s*(?:query_\w+|commit_\w+|enter_recovery)\s*\(")

    def test_engine_has_alias_not_forwarding_shells(self):
        """功能：冻结 engine 对值组件的显式依赖，防止迁移后再堆重复转发方法或第二实例。
        输入输出及副作用：读取两类方法集合，检查 value_ops 类型别名和生产调用限定。
        失败边界：重名方法、旧状态方法名称或未限定的迁移调用均失败。
        """
        projector = methods(read_code(CORE / "rdma_queue_data_projector.sv"))
        engine = read_code(CORE / "rdma_queue_data_engine.sv")
        self.assertIn("typedef rdma_queue_data_projector value_ops;", engine)
        self.assertFalse(projector.keys() & methods(engine).keys())
        self.assertNotRegex(engine, r"\b(?:make_engine_status_nonfatal|set_engine_status_noalloc)\b")
        for name in projector:
            self.assertNotRegex(engine, rf"(?<![\w:]){name}\s*\(")
        for name in ("prepare_cq_completion_candidate", "prepare_event_result_candidate_ex",
                     "identity_key", "copy_status_fields", "set_status_noalloc"):
            self.assertIn(f"value_ops::{name}(", engine)

    def test_package_orders_value_types_projector_engine(self):
        """功能：保证结果/attachment 类型先于 projector，projector 先于 engine，无反向 include。
        输入输出及副作用：读取完整 core package 的 include 顺序；不修改编译清单。
        失败边界：缺失/重复/逆序或组件自行 include 其它实现时失败。
        """
        package = (CORE / "rdma_core_pkg.sv").read_text()
        names = ("rdma_queue_data_transaction_models.sv", "rdma_queue_data_projector.sv",
                 "rdma_queue_data_engine.sv")
        positions = []
        for name in names:
            entry = f'`include "{name}"'
            self.assertEqual(package.count(entry), 1)
            positions.append(package.index(entry))
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("`include", read_code(CORE / "rdma_queue_data_projector.sv"))

    def test_noallocation_helpers_stay_separate_from_factory(self):
        """功能：防止字段原位更新被改成 factory/copy/clone，保留 barrier 后的无分配契约。
        输入输出及副作用：检查两个 helper 正文与 raw factory/AEQE profile 的真实调用；只读。
        失败边界：字段 helper 增加分配/虚拟复制，或 raw/profile 创建边界丢失时失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_projector.sv"))
        for name in ("copy_status_fields", "set_status_noalloc"):
            self.assertNotRegex(declared[name][2], r"\b(?:new|factory|create|copy|clone|do_copy)\b")
        self.assertIn("factory.create_object_by_type(", declared["factory_create_object_nonfatal"][2])
        self.assertIn("set_profile_owner_authority(", declared["prepare_event_result_candidate_ex"][2])
        self.assertIn("slot.consumed = 1'b1;", declared["prepare_cq_completion_candidate"][2])

    def test_value_fixture_does_not_construct_engine(self):
        """功能：保证 detached candidate 测试能独立运行，不再通过 engine 构造 planner/账本。
        输入输出及副作用：读取完整值测试，检查 probe 基类与 projector 调用限定；只读。
        失败边界：重新继承 engine、创建 engine/planner 或恢复裸 protected 调用时失败。
        """
        code = read_code(ROOT / "tests/unit/rdma_queue_detached_snapshot_test.sv")
        self.assertIn("class rdma_queue_detached_snapshot_probe extends uvm_object;", code)
        self.assertNotIn("rdma_queue_data_engine", code)
        self.assertNotIn("rdma_queue_backing_planner", code)
        for name in ("prepare_cq_completion_candidate", "prepare_event_result_candidate"):
            self.assertIn(f"rdma_queue_data_projector::{name}(", code)
            self.assertNotRegex(code, rf"(?<![\w:]){name}\s*\(")


if __name__ == "__main__":
    unittest.main()
