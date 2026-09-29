"""目录/层次：tests/unit；职责：守卫 status 值操作唯一归属、完整字段和分配策略边界。
依赖：既有 SV 词法扫描器及 unittest；不替代 null/错型/回调的 VCS 验证。
所有权/生命周期：只读 types/core/test 源码，不创建运行时对象或修改依赖。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class StatusValueBoundaryTest(unittest.TestCase):
    """字段传输属于 types；业务 owner 与分配/拒绝策略不随值操作迁移。"""

    def test_helpers_cover_all_declared_diagnostic_fields(self):
        """功能：要求 set/copy 各按声明顺序完整写入全部诊断字段，防止新增字段只更新一处。
        输入输出及副作用：读取 status 声明和两个无分配 helper 的赋值列表；只读。
        失败边界：字段遗漏、重复、乱序，或 copy 不再使用 source 对应字段均失败。
        """
        code = read_code(ROOT / "src/types/rdma_status.sv")
        fields = re.findall(r"^  (?:rdma_\w+|bit(?: \[\d+:\d+\])?|string) (\w+);$", code, re.M)
        self.assertEqual(len(fields), 13)
        declared = methods(code)
        for name in ("set_fields_noalloc", "copy_fields_noalloc"):
            body = declared[name][2]
            self.assertEqual(re.findall(r"destination\.(\w+)\s*=", body), fields)
            self.assertRegex(body, r"^  static function automatic bit")
            self.assertNotRegex(body, r"\b(?:new|factory|create|clone|do_copy|copy)\b")
        self.assertEqual(re.findall(r"source\.(\w+);", declared["copy_fields_noalloc"][2]), fields)

    def test_types_cannot_depend_on_business_owners(self):
        """功能：禁止公共 status 引用 core projector、运行账本或外部服务，维持 package 单向依赖。
        输入输出及副作用：读取 status 标识符及 include；仅允许显式诊断字段与 UVM。
        失败边界：出现 owner 类型、锁、实例服务或新的源码 include 时失败。
        """
        code = read_code(ROOT / "src/types/rdma_status.sv")
        self.assertNotRegex(code, r"\brdma_(?:queue|resource|doorbell|host_mem|pcie)\w*\b")
        self.assertNotRegex(code, r"\b(?:semaphore|lock|registry)\b|`include")

    def test_projectors_have_no_status_forwarding_shells(self):
        """功能：确保原位状态操作已从两个 projector 移除，调用者直接依赖 types。
        输入输出及副作用：读取 projector/runtime/engine 的全部源码和方法声明；只读。
        失败边界：旧 helper 重现、转发壳、旧类型限定调用或遗漏直接调用均失败。
        """
        for filename in ("rdma_queue_runtime_projector.sv", "rdma_queue_data_projector.sv",
                         "rdma_queue_runtime.sv", "rdma_queue_data_engine.sv"):
            code = read_code(CORE / filename)
            self.assertNotRegex(code, r"\b(?:set_runtime_status_noalloc|set_status_noalloc|copy_status_fields)\b")
            self.assertIn("rdma_status::set_fields_noalloc(", code)

    def test_allocation_policies_and_names_remain_local(self):
        """功能：保持 runtime fallback、data null 和 typed/direct 构造的四种分配契约独立。
        输入输出及副作用：读取各创建入口完整方法及原始实例名；只读。
        失败边界：创建名丢失、data 添加 fallback、typed 改用 nullable setter 或 direct 调 factory 失败。
        """
        runtime = (CORE / "rdma_queue_runtime_projector.sv").read_text()
        data = (CORE / "rdma_queue_data_projector.sv").read_text()
        status = methods(read_code(ROOT / "src/types/rdma_status.sv"))
        self.assertIn('"runtime_status"', runtime)
        self.assertIn('new("runtime_status_fallback")', runtime)
        self.assertIn('"queue_data_engine_status"', data)
        make_data = methods(read_code(CORE / "rdma_queue_data_projector.sv"))["make_status_nonfatal"][2]
        self.assertIn("return null;", make_data)
        self.assertNotRegex(make_data, r"\bnew\b")
        self.assertIn("type_id::create(", status["make"][2])
        self.assertNotIn("set_fields_noalloc(", status["make"][2])
        self.assertIn("set_fields_noalloc(status, code, message)", status["make_direct"][2])
        self.assertNotRegex(status["make_direct"][2], r"\b(?:factory|create)\b")

    def test_matrix_and_hostile_hook_guards_remain(self):
        """功能：固定全部错误码、独立字段断言、工厂计数、重入和 hostile copy/clone 的动态验证入口。
        输入输出及副作用：读取已有 runtime/post test，不新增测试组件或修改注册；只读。
        失败边界：矩阵未调用、遗漏直接字段/工厂计数或虚拟 hook 计数断言时失败。
        """
        code = read_code(ROOT / "tests/unit/rdma_queue_runtime_projector_test.sv")
        for token in ("check_status_matrix(factory)", "code.num()", "cases != 162",
                      "status.hardware_code != 0", "status.command_id != 0",
                      "factory.calls != before_calls + 2", "status == factory.nested_status"):
            self.assertIn(token, code)
        post = read_code(ROOT / "tests/unit/rdma_queue_data_engine_post_test.sv")
        for token in ("source.clone_calls", "destination.copy_calls",
                      "rdma_status::copy_fields_noalloc(destination, destination)",
                      "rdma_status::copy_fields_noalloc(null, null)"):
            self.assertIn(token, post)


if __name__ == "__main__":
    unittest.main()
