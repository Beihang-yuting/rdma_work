# 目录/层次：tests/unit，CMQ 能力表门禁的单元测试。
# 文件职责：用合成驱动源码与合成 golden 验证能力表的闭环判定、驱动未分派标记与证据缺失拒绝。
# 主要依赖：Python unittest、tempfile、tools/check_cmq_capabilities.py。
# 资源所有权：只在临时目录中读写，测试结束自动删除。
"""tools/check_cmq_capabilities.py 的单元测试。"""

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import check_cmq_capabilities as caps  # noqa: E402

CMQ_H = """
enum xtrdma_cmq_op {
	XTRDMA_OP_A = 0x00,
	XTRDMA_OP_B = 0x01,
	XTRDMA_OP_C = 0x02,
	XTRDMA_OP_MAX = 0x03,
};
"""
CMQ_C = """
static int xtrdma_exec_cmq_cmd(int x)
{
	switch (x) {
	case XTRDMA_OP_A:
		fill_a();
		break;
	case XTRDMA_OP_B:
		break;
	default:
		return -EINVAL;
	}
}

static int xtrdma_exec_cmq_cq_cmd(int x)
{
	switch (x) {
	case XTRDMA_OP_A:
		break;
	case XTRDMA_OP_B:
	case XTRDMA_OP_C:
		break;
	default:
		break;
	}
}
"""


def golden(cases):
    out = ["# xtr_v1-golden-v1"]
    for name, opcode in cases:
        out += [f"# case: {name}", f"# inputs: opcode=0x{opcode:02x}", "# bytes: 64", "00", ""]
    return "\n".join(out)


class CapabilityGateTest(unittest.TestCase):
    def build(self, tmp: Path, requests, responses):
        driver = tmp / "drv"
        driver.mkdir()
        (driver / "cmq.h").write_text(CMQ_H)
        (driver / "cmq.c").write_text(CMQ_C)
        vectors = tmp / "repo/hw/rdma/golden_vectors"
        vectors.mkdir(parents=True)
        (vectors / "cmq_requests.hex").write_text(golden(requests))
        (vectors / "cmq_requests_dedicated.hex").write_text(golden([]))
        (vectors / "cmq_responses.hex").write_text(golden(responses))
        (tmp / "repo/hw/rdma/cmq_request_fields.tsv").write_text(
            "# generated\nopcodes\tfunction\nB\t(none)\n")
        return driver, tmp / "repo"

    def test_rows_follow_dispatch_and_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            driver, repo = self.build(Path(tmp), [("a_req", 0), ("b_req", 1)],
                                      [("a_rsp", 0), ("b_rsp", 1), ("c_rsp", 2)])
            rows = {(r["opcode"], r["direction"]): r for r in caps.expected_rows(driver, repo)}
        self.assertEqual(len(rows), 7)
        self.assertEqual(rows[("A", "REQUEST")]["oracle_case_id"], "a_req")
        self.assertEqual(rows[("A", "REQUEST")]["owning_codec"], "rdma_hw_cmq_request_composer")
        self.assertEqual(rows[("B", "REQUEST")]["owning_codec"], "rdma_hw_cmq_field_codec")
        self.assertEqual(rows[("C", "REQUEST")]["blocker"], "DRIVER_NOT_DISPATCHED")
        self.assertEqual(rows[("C", "REQUEST")]["request_encodable"], "0")
        self.assertEqual(rows[("C", "RESPONSE")]["response_decodable"], "1")
        self.assertEqual(rows[("CMQ_SQ_DOORBELL", "REQUEST")]["blocker"], "MISSING_CLOSED_EVIDENCE")

    def test_dispatched_direction_without_golden_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            driver, repo = self.build(Path(tmp), [("a_req", 0)], [("a_rsp", 0)])
            with self.assertRaises(caps.CapabilityError):
                caps.expected_rows(driver, repo)


if __name__ == "__main__":
    unittest.main()
