"""目录/层次：tests/unit；职责：守卫 backing 字节搬运与 DMA 权限策略的边界。
依赖：unittest 与既有 SV scanner；只读源码，不替代跨 span 故障仿真。
所有权与生命周期：不创建 mapping 或访问外部后端，不修改源码。
"""

import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class QueueBackingTransferBoundaryTest(unittest.TestCase):
    """公共循环只搬运字节；入口方向、诊断与 backend-started 仍有明确契约。"""

    def declared(self):
        """功能：只解析 access 类，排除同文件 span 的同名构造函数。
        输入输出及副作用：无输入，返回方法映射；只读。
        失败边界：access 声明缺失或方法重名由分割器/scanner 报错。
        """
        code = read_code(CORE / "rdma_queue_backing_access.sv")
        return methods(code.split("class rdma_queue_backing_access extends", 1)[1])

    def test_single_read_and_write_loop(self):
        """功能：禁止四个公开入口重新内联 backend 循环。
        输入输出及副作用：读取方法正文，检查唯一 host_mem.read/write 与公共委托次数。
        失败边界：重复循环、漏掉入口或直接调用后端均失败。
        """
        declared = self.declared()
        for name, helper in (("write", "write_spans"), ("write_device", "write_spans"),
                             ("read", "read_with_permission"), ("readback", "read_with_permission")):
            self.assertEqual(declared[name][2].count(helper + "("), 1)
            self.assertNotIn("host_mem.", declared[name][2])
        for helper, operation in (("write_spans", "write"), ("read_with_permission", "read")):
            self.assertEqual(declared[helper][2].count(f"host_mem.{operation}("), 1)

    def test_public_direction_policy(self):
        """功能：固定 host write/readback 为 DEVICE_READ、device write/consumer read 为 DEVICE_WRITE。
        输入输出及副作用：读取四个入口的枚举，不推测 queue kind；只读。
        失败边界：方向交换、双向扩大或把 preflight 放到写后均失败。
        """
        declared = self.declared()
        for name, direction in (("write", "READ"), ("readback", "READ"),
                                ("write_device", "WRITE"), ("read", "WRITE")):
            body = declared[name][2]
            self.assertIn("RDMA_DMA_DEVICE_" + direction, body)
            self.assertNotIn("RDMA_DMA_BIDIRECTIONAL", body)
            if name in ("write", "write_device"):
                self.assertLess(body.index("resolve("), body.index("preflight_spans("))
                self.assertLess(body.index("preflight_spans("), body.index("write_spans("))

    def test_write_started_and_null_policy(self):
        """功能：保护 device 预检前清零及 backend 调用前置位，保留普通 write 的既有 null 契约。
        输入输出及副作用：读取入口与公共写循环，检查 marker/调用位置；只读。
        失败边界：提前置位、后移清零、统一两种入口的 null 处理或写后额外预检均失败。
        """
        declared = self.declared()
        device, write = declared["write_device"][2], declared["write"][2]
        self.assertLess(device.index("backend_write_started = 1'b0;"), device.index("resolve("))
        self.assertEqual(device.count("status == null || !status.ok()"), 2)
        self.assertNotIn("status == null", write)
        shared = declared["write_spans"][2]
        self.assertLess(shared.index("backend_write_started = 1'b1;"), shared.index("host_mem.write("))
        self.assertNotIn("preflight_spans(", shared)

    def test_read_clears_failure_output(self):
        """功能：锁定预检先于读取、null/失败与短长读的输出清空。
        输入输出及副作用：扫描公共 read 的分支顺序与清空次数；只读。
        失败边界：先访问再校验、长度检查弱化为仅短读、删除任一清空或改为回滚写入均失败。
        """
        body = self.declared()["read_with_permission"][2]
        self.assertEqual(body.count("data = new[0];"), 3)
        self.assertLess(body.index("preflight_spans("), body.index("host_mem.read("))
        self.assertIn("chunk.size() != spans[i].length", body)
        self.assertNotIn("host_mem.write(", body)

    def test_helpers_do_not_acquire_owner(self):
        """功能：禁止搬运 helper 引入 runtime/recovery/资源释放或缓存 backend 字段。
        输入输出及副作用：读取两个 helper，检查外部提交名与每段 live 字段读取；只读。
        失败边界：新增账本操作、release、另一个 adapter 引用或提前缓存 mapping/length 即失败。
        """
        for name in ("write_spans", "read_with_permission"):
            body = self.declared()[name][2]
            self.assertNotRegex(body, r"\b(?:runtime|manager|release|recover\w*|commit\w*|"
                                r"rdma_host_mem_api|rdma_dma_mapping)\b")
            self.assertIn("spans[i].mapping, spans[i].mapping_offset", body)
            self.assertIn("position += spans[i].length;", body)

    def test_matrix_registered_and_complete(self):
        """功能：保证 80-case 三段访问矩阵仍属于完整 core，而非只编译未执行。
        输入输出及副作用：读取测试/package/manifest，检查维度与故障/前缀断言；只读。
        失败边界：注册缺失、删除任一方向、清空/started/内存前缀断言或 fixture 释放均失败。
        """
        name = "rdma_queue_backing_access_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        core = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text().split(
            "readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        self.assertEqual(core.split().count(name), 1)
        source = read_code(ROOT / f"tests/unit/{name}.sv")
        for contract in ("qp < 2", "operation < 4", "mode < 11", "mode inside {7, 8}",
                         "mappings[3]", "mem.fired !=", "started != (expected_calls != 0)",
                         "data.size() != 0", "i < completed_writes", "mem.live_allocations() != 0"):
            self.assertIn(contract, source)


if __name__ == "__main__":
    unittest.main()
