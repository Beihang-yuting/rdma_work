# 目录/层次：tests/unit，CMQ 请求字段表生成器的单元测试。
# 文件职责：用合成 C 片段验证字段宏解析、取值分类、局部变量复用与 memcpy 识别，并确认仓库中
#   生成的 TSV 与 SV 字段表互相一致（无需驱动源码）。
# 主要依赖：Python unittest、tools/gen_cmq_request_fields.py。
# 资源所有权：只读仓库文件，不写任何输出。
"""tools/gen_cmq_request_fields.py 的单元测试。"""

from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import gen_cmq_request_fields as gen  # noqa: E402

MACROS = {
    "XTRDMA_A": "GENMASK_ULL(23, 0)",
    "XTRDMA_B": "BIT_ULL(48)",
    "XTRDMA_C": "GENMASK(63, 52)",
    "XTRDMA_CMQCQ_OPCODE": "GENMASK_ULL(39, 32)",
    "XTRDMA_OFF": "0x18",
    "XTRDMA_LEN": "16",
}


def read_tsv_rows():
    rows = []
    lines = (ROOT / "hw/rdma/cmq_request_fields.tsv").read_text().splitlines()
    header = lines[1].split("\t")
    for line in lines[2:]:
        row = dict(zip(header, line.split("\t")))
        for key in ("qword_byte", "lsb", "width"):
            row[key] = int(row[key])
        rows.append(row)
    return rows


class FieldParsingTest(unittest.TestCase):
    def test_mask_forms(self):
        self.assertEqual(gen.mask_bits(MACROS, "XTRDMA_A"), (0, 24))
        self.assertEqual(gen.mask_bits(MACROS, "XTRDMA_B"), (48, 1))
        self.assertEqual(gen.mask_bits(MACROS, "XTRDMA_C"), (52, 12))
        with self.assertRaises(gen.GenError):
            gen.mask_bits(MACROS, "XTRDMA_MISSING")

    def test_value_classification(self):
        self.assertEqual(gen.classify_value("info->pd_idx"), ("pd_idx", "value"))
        self.assertEqual(gen.classify_value("idx_para->num - 1"), ("num", "minus_one"))
        self.assertEqual(gen.classify_value("ether_addr_to_u64(info->src_mac)"),
                         ("src_mac", "mac48"))
        self.assertEqual(gen.classify_value("1"), ("", "const:1"))
        self.assertEqual(gen.classify_value("*pd_pba"), ("pd_pba", "value"))
        with self.assertRaises(gen.GenError):
            gen.classify_value("info->a + info->b")

    def test_reused_local_resolves_latest_assignment(self):
        body = """
static void f(__be64 *wqe)
{
	v = FIELD_PREP(XTRDMA_A, info->first) | FIELD_PREP(XTRDMA_B, 1);
	set_64bit_val(wqe, 8, v);
	v = FIELD_PREP(XTRDMA_CMQCQ_OPCODE, opcode) | FIELD_PREP(XTRDMA_C, info->second);
	set_64bit_val(wqe, 0, v);
	set_64bit_val(wqe, XTRDMA_OFF, info->whole);
}
"""
        rows = gen.qword_rows(MACROS, body, "f")
        got = [(r["param"], r["qword_byte"], r["lsb"], r["width"], r["transform"]) for r in rows]
        self.assertEqual(got, [("first", 8, 0, 24, "value"), ("", 8, 48, 1, "const:1"),
                               ("second", 0, 52, 12, "value"), ("whole", 24, 0, 64, "value")])

    def test_memcpy_offsets(self):
        body = """
	memcpy(wqe + 2, info->ip, sizeof(u8)*XTRDMA_LEN);
	memcpy((void *)wqe + XTRDMA_OFF, info->raw, sizeof(u8)*XTRDMA_LEN);
"""
        rows = gen.memcpy_rows(MACROS, body, "f")
        self.assertEqual([(r["param"], r["qword_byte"], r["transform"]) for r in rows],
                         [("ip", 16, "bytes:16"), ("raw", 24, "bytes:16")])


class GeneratedArtifactsTest(unittest.TestCase):
    def test_svh_matches_committed_tsv(self):
        rendered = gen.render_svh(read_tsv_rows())
        committed = (ROOT / "src/codec/rdma/rdma_cmq_request_fields.svh").read_text()
        self.assertEqual(rendered, committed)

    def test_table_covers_driver_opcodes_without_dedicated_encoders(self):
        opcodes = set()
        for row in read_tsv_rows():
            opcodes.update(row["opcodes"].split(","))
        self.assertEqual(len(opcodes), 49)
        self.assertTrue(set(gen.NO_FILL_OPCODES) <= opcodes)
        for fn_opcodes in gen.FUNCTIONS.values():
            self.assertTrue(set(fn_opcodes) <= opcodes)

    def test_generated_lines_fit_style_limit(self):
        for line in (ROOT / "src/codec/rdma/rdma_cmq_request_fields.svh").read_text().splitlines():
            self.assertLessEqual(len(line), 100, line)


if __name__ == "__main__":
    unittest.main()
