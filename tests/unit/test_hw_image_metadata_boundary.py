"""目录/层次：tests/unit；职责：固定 image 元数据操作和调用方的队列/回调边界。
依赖：unittest、既有只读 SV scanner；不替代 VCS factory/alias/恢复验证。
所有权/生命周期：只读取源码，不改写文件或建立仿真资源。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import ROOT, methods, read_code


FIELDS = ("length", "alignment", "endian", "image_kind", "hardware_version",
          "function_generation", "write_target_kind", "backing_target", "hmc_target", "bar_target")
CALL = "rdma_hw_image::copy_metadata_noalloc"
CALLERS = {
    "src/core/rdma_queue_data_engine.sv": 1,
    "src/core/rdma_queue_data_projector.sv": 1,
    "src/core/rdma_queue_runtime_projector.sv": 1,
    "src/core/rdma_queue_runtime_transaction_models.sv": 1,
    "src/model/rdma_cmq_execution_models.sv": 1,
    "src/model/rdma_cmq_typed_snapshot_contract.sv": 2,
    "src/core/rdma_cmq_engine.sv": 1,
}


class HwImageMetadataBoundaryTest(unittest.TestCase):
    """元数据集中到值模型，不为八个入口引入新的策略、状态或 owner。"""

    def test_helper_is_exact_ten_ordered_assignments(self):
        """功能：固定 helper 完整签名和十项赋值，不允许追加队列操作/分配/回调/校验。
        输入输出及副作用：读取 model 方法，只比较代码 token。
        失败边界：缺字段、换顺序、反向写源值或新增条件均失败。
        """
        declared = methods(read_code(ROOT / "src/model/rdma_hw_image.sv"))
        expected = ("static function automatic void copy_metadata_noalloc("
                    "rdma_hw_image source, rdma_hw_image destination);")
        expected += "".join(f"destination.{field} = source.{field};" for field in FIELDS)
        expected += "endfunction"
        self.assertEqual(re.findall(r"\w+|[^\w\s]", declared["copy_metadata_noalloc"][2]),
                         re.findall(r"\w+|[^\w\s]", expected))
        self.assertEqual(set(declared), {"new", "do_copy", "copy_metadata_noalloc"})

    def test_nine_copy_sites_and_model_order(self):
        """功能：固定八入口九处委托，model 的 bytes→metadata→summary 次序不变。
        输入输出及副作用：逐文件读取调用数，模型 do_copy 单独检查原隐式目标。
        失败边界：遗漏、重复或出现新的生产调用点均失败，不用名字计数代替动态测试。
        """
        actual = {}
        for path in (ROOT / "src").rglob("*.sv"):
            code = read_code(path)
            count = code.count(CALL + "(")
            if count:
                actual[str(path.relative_to(ROOT))] = count
        self.assertEqual(actual, CALLERS)
        model = methods(read_code(ROOT / "src/model/rdma_hw_image.sv"))["do_copy"][2]
        self.assertRegex(model, r"bytes = rhs_image.bytes;\s*"
                         r"copy_metadata_noalloc\(rhs_image, this\);\s*"
                         r"field_summary = rhs_image.field_summary;")

    def test_payload_and_restore_policies_stay_in_callers(self):
        """功能：保留 poll 追加、runtime/publish 清空和 checked snapshot 的捕获/clone/恢复。
        输入输出及副作用：只读完整方法，检查 shared call 周围的业务顺序。
        失败边界：错误清空 poll、删除 replace、移位 clone 或倒置 source/destination 均失败。
        """
        for file, name in (("rdma_queue_data_projector", "clone_poll_image_nonfatal"),
                           ("rdma_queue_runtime_projector", "clone_image_value_nonfatal"),
                           ("rdma_queue_data_engine", "clone_publish_image")):
            body = methods(read_code(ROOT / f"src/core/{file}.sv"))[name][2]
            self.assertIn(CALL + "(source, candidate);", body)
            if name == "clone_poll_image_nonfatal":
                self.assertNotIn(".delete()", body)
            else:
                self.assertLess(body.index("candidate.bytes.delete();"),
                                body.index("foreach (source.bytes[i])"))
                self.assertLess(body.index("candidate.field_summary.delete();"),
                                body.index("foreach (source.field_summary[i])"))
        checked = methods(read_code(ROOT / "src/model/rdma_cmq_typed_snapshot_contract.sv"))[
            "rdma_cmq_checked_image_snapshot"][2]
        markers = ("saved_value.bytes = source.bytes;", CALL + "(source, saved_value);",
                   "saved_value.field_summary = source.field_summary;", "source.clone();",
                   "source.bytes = saved_value.bytes;", CALL + "(saved_value, source);",
                   "source.field_summary = saved_value.field_summary;")
        positions = [checked.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))

    def test_characterization_is_registered_and_uses_old_entries(self):
        """功能：固定独立专项注册与八入口矩阵，确保旧生产能够编译同一份 fixture。
        输入输出及副作用：读取测试、package 和 core manifest；不执行仿真。
        失败边界：漏注册、调用新增 helper 自证、复跑父测试或删去边界矩阵均失败。
        """
        name = "rdma_hw_image_copy_contract_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(
            f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$", (ROOT /
            "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        code = read_code(ROOT / f"tests/unit/{name}.sv")
        self.assertNotIn("copy_metadata_noalloc(", code)
        self.assertNotIn("super.run_phase", code)
        for marker in ("api < 8", "tag < 16", "mode < 6", "fault <= 2", "cases != 153",
                       "copy.do_copy(source)", "clone_image_value_nonfatal(source, copy)",
                       "clone_poll_image_nonfatal(source, copy)", "clone_publish_image(source, copy)",
                       "pending_copy.do_copy(pending)", "rdma_cmq_try_snapshot_image_direct(",
                       "rdma_cmq_checked_image_snapshot(", "canonicalize_completion_raw_cqe(",
                       "source.do_copy(source)", "observer.alias_value = source"):
            self.assertIn(marker, code)


if __name__ == "__main__":
    unittest.main()
