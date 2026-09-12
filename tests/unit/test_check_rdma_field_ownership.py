#!/usr/bin/env python3
"""
目录：tests/unit；职责：锁定 CMQ ownership/capability/mutation gate 的拒绝边界。
依赖：tools.check_rdma_field_ownership 的公开解析与验证接口；临时目录拥有 fixture
生命周期，被测 checker 只读输入，不写回仓库。
"""

from __future__ import annotations

import inspect
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

try:
    from tools import check_rdma_field_ownership as checker
    IMPORT_ERROR = None
except (ImportError, OSError) as exc:  # RED 阶段允许 checker 尚未创建。
    checker = None
    IMPORT_ERROR = exc


OWNERSHIP_HEADER = (
    "archive_id\tsource_path\tsource_selector\tsource_sha256\tmacro_name\t"
    "anchor_function\tanchor_token\tanchor_occurrence\tanchor_container\t"
    "anchor_buffer\tanchor_operation\tanchor_base\tanchor_length\t"
    "anchor_target_flow\tentry_kind\topcode_or_variant\tdirection\t"
    "ownership\tcapability\tmodel_field_or_raw_slice\towning_codec\t"
    "overlay_group\tdiscriminator\toracle_case_id"
)
EXCLUSION_HEADER = (
    "archive_id\tsource_path\tsource_selector\tsource_sha256\tmacro_name\t"
    "exclusion_reason"
)
CAPABILITY_HEADER = (
    "driver_symbol\topcode\topcode_value\tdirection\tregistered\t"
    "request_encodable\tresponse_decodable\toracle_case_id\towning_codec\t"
    "blocker"
)
MUTATION_HEADER = (
    "case_id\tentry\topcode\tdirection\tbyte_offset\tqword_index\tbit_index\t"
    "expected_class\texpected_field\tevidence_mode\tcorrelation_group\t"
    "driver_result_class\tmodel_consumer\texpected_outcome\t"
    "expected_status_code\texpected_ready\texpected_value_delta\toracle_case_id"
)


class FieldOwnershipFixtureTest(unittest.TestCase):
    """功能：以命名 fixture 覆盖字段门禁的每个拒绝分支。
    输入输出及副作用：测试只创建临时文本和内存映射，期望 checker 抛 ContractError。
    失败边界：任一故障被接受、被错误分类或跨层状态被合并都必须使测试失败。"""

    def require_checker(self):
        """功能：取得待测 checker 模块，确保 RED 阶段以明确断言失败。
        输入输出及副作用：无输入；返回模块对象，不写文件或修改全局状态。
        失败边界：模块尚不存在时报告可定位的缺失实现，而不是吞掉 fixture。"""
        if checker is None:
            self.fail(f"field ownership checker is missing: {IMPORT_ERROR}")
        return checker

    def assert_rejected(self, callback):
        """功能：断言一个 ownership fixture 被 ContractError 拒绝。
        输入输出及副作用：callback 是不带参数的真实验证调用；不创建持久资源。
        失败边界：漏报、返回普通值或抛出无关异常均视为门禁失效。"""
        module = self.require_checker()
        with self.assertRaises(module.ContractError):
            callback(module)

    def write_table(self, directory: Path, name: str, header: str, rows):
        """功能：在临时目录写入指定表头和行，构造可重复的 malformed-table fixture。
        输入输出及副作用：directory/name/header/rows 是输入；返回文件路径并仅写临时目录。
        失败边界：调用方负责提供字符串行；本 helper 不替 checker 放宽列数或空值规则。"""
        path = directory / name
        payload = header + "\n"
        payload += "\n".join(rows)
        payload += "\n"
        path.write_text(payload, encoding="utf-8")
        return path

    def minimal_ownership(self, **overrides):
        """功能：构造一条完整 ownership 记录供语义拒绝 fixture 定点变异。
        输入输出及副作用：overrides 覆盖列名到值的映射；返回独立字典，不写文件。
        失败边界：缺列、非法枚举或空 anchor 由 checker 负责拒绝，不能在 helper 中预修正。"""
        row = {
            "archive_id": "fixture",
            "source_path": "cmq.h",
            "source_selector": "XTRDMA_CMQ*",
            "source_sha256": "0" * 64,
            "macro_name": "XTRDMA_CMQSQ_WQE_QPN",
            "anchor_function": "xtrdma_sc_qp_create",
            "anchor_token": "FIELD_PREP(XTRDMA_CMQSQ_WQE_QPN, info->qpn)",
            "anchor_occurrence": "1",
            "anchor_container": "wqe",
            "anchor_buffer": "wqe",
            "anchor_operation": "SET_64BIT_FIELD_PREP",
            "anchor_base": "0",
            "anchor_length": "8",
            "anchor_target_flow": "info->qpn -> wqe[0]",
            "entry_kind": "CMQ_SQE",
            "opcode_or_variant": "QPC_CREATE",
            "direction": "REQUEST",
            "ownership": "HOST_TYPED",
            "capability": "SUPPORTED",
            "model_field_or_raw_slice": "qpn",
            "owning_codec": "rdma_hw_cmq_request_composer",
            "overlay_group": "-",
            "discriminator": "-",
            "oracle_case_id": "cmq_sqe_qpc_create_request",
        }
        row.update(overrides)
        return row

    def minimal_mutation(self, **overrides):
        """功能：构造一条完整 mutation 记录供证据配对 fixture 定点变异。
        输入输出及副作用：overrides 覆盖列名到值的映射；返回独立字典，不写文件。
        失败边界：非法 evidence/class、静态状态或坐标由 checker 负责拒绝。"""
        row = {
            "case_id": "cmq_sqe_qpc_create_request",
            "entry": "CMQ_SQE",
            "opcode": "QPC_CREATE",
            "direction": "REQUEST",
            "byte_offset": "7",
            "qword_index": "0",
            "bit_index": "0",
            "expected_class": "HOST_TYPED",
            "expected_field": "qpn",
            "evidence_mode": "TYPED_RECOMPOSE",
            "correlation_group": "-",
            "driver_result_class": "ENCODED",
            "model_consumer": "CMQ_REQUEST_COMPOSER",
            "expected_outcome": "ACCEPT",
            "expected_status_code": "OK",
            "expected_ready": "1",
            "expected_value_delta": "1",
            "oracle_case_id": "cmq_sqe_qpc_create_request",
        }
        row.update(overrides)
        return row

    # 功能：构造带真实 CMQ manifest 身份的最小 record，供 expected projection 测试使用。
    # 输入输出及副作用：无输入；返回只含 archive_id/path/selector/sha256 的内存对象，不写文件。
    # 失败边界：字段缺失会让 ownership anchor 选择失败，测试不得用伪造的 fallback record 掩盖错误。
    def cmq_manifest_records(self):
        return {
            "cmq.h": [
                SimpleNamespace(
                    archive_id="fixture",
                    path="cmq.h",
                    selector="XTRDMA_CMQ*|XTRDMA_OP_*",
                    sha256="0" * 64,
                )
            ]
        }

    # 功能：索引四个 CMQ case 的 expected ownership rows，便于逐方向检查 capability 投影。
    # 输入输出及副作用：rows 输入；返回按 entry/opcode/direction 分组的只读映射，不修改 rows。
    # 失败边界：重复 identity 由测试显式失败，禁止以最后一行覆盖前一行。
    def expected_ownership_by_case(self, rows):
        result = {}
        for row in rows:
            key = (
                row["entry_kind"],
                row["opcode_or_variant"],
                row["direction"],
                row["macro_name"],
            )
            self.assertNotIn(key, result)
            result[key] = row
        return result

    def minimal_compose_source(self, merge_extra="", pre_merge_extra=""):
        """功能：构造含 canonical envelope/body merge 的 composer fixture。
        输入输出及副作用：merge_extra 写入 merge loop，pre_merge_extra 写在
        candidate 分配后；返回源码字符串，不执行 SV 或写文件。
        失败边界：fixture 保留必要 data-flow；额外 image alias/mutator
        应被拒绝。"""
        return (
            "class rdma_hw_cmq_request_composer;\n"
            "function rdma_status compose_request(\n"
            "  rdma_hw_cmq_envelope envelope, rdma_hw_image body,\n"
            "  output rdma_hw_image result);\n"
            "  result = null;\n"
            "  status = envelope_codec.encode(envelope, envelope_image);\n"
            "  status = ownership.lookup(envelope_snapshot.opcode, input_kind, masks);\n"
            "  candidate = rdma_hw_image::type_id::create(\"rdma_cmq_request\");\n"
            f"  {pre_merge_extra}\n"
            "  for (int unsigned q = 0; q < 8; q++) begin\n"
            "    envelope_word = image_word(envelope_image, q);\n"
            "    body_word = image_word(body, q);\n"
            "    merged_word = envelope_word | body_word;\n"
            "    candidate.bytes.push_back(merged_word[63 - (i * 8) -: 8]);\n"
            f"    {merge_extra}\n"
            "  end\n"
            "  for (int unsigned q = 0; q < 8; q++) begin\n"
            "    merged_word = image_word(candidate, q);\n"
            "    if ((merged_word & ~(request_envelope_mask(q) | masks[q])) != 0)\n"
            "      return status;\n"
            "  end\n"
            "  result = candidate;\n"
            "endfunction\nendclass\n"
        )

    def complete_production_compose_source(
        self, merge_extra="", pre_merge_extra=""
    ):
        """功能：补齐 QPC、envelope、doorbell 三个 production class，供 composer
        source-walk 在完整上下文中命中目标规则。
        输入输出及副作用：参数仅插入 composer fixture；返回 SV 文本，不执行
        或写入生产源码。
        失败边界：任一 production class、branch 或 typed macro 缺失时由 checker
        拒绝。"""
        return (
            "`define CMQ_QPC_PUT(STEM, VALUE) \\\n"
            "  status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "               STEM``_WIDTH, VALUE); \\\n"
            "  if (!status.ok()) return status;\n"
            "`define CMQ_ENVELOPE_PUT(STEM, VALUE) \\\n"
            "  status = builder.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "                             STEM``_WIDTH, VALUE);\n"
            "`define DB_PUT(STEM, VALUE) \\\n"
            "  status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "               STEM``_WIDTH, VALUE);\n"
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "  case (opcode)\n"
            "    RDMA_OP_QPC_CREATE: begin\n"
            "      `CMQ_QPC_PUT(RDMA_CMQ_QPN, value)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
            "class rdma_hw_cmq_envelope_codec;\n"
            "function void encode();\n"
            "  `CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, value)\n"
            "endfunction\nendclass\n"
            "class rdma_hw_doorbell_codec;\n"
            "function void encode_fields();\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": begin\n"
            "      `DB_PUT(RDMA_CMQ_DB_PI, value)\n"
            "      `DB_PUT(RDMA_CMQ_DB_POLARITY, value)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
            + self.minimal_compose_source(
                merge_extra=merge_extra,
                pre_merge_extra=pre_merge_extra,
            )
        )

    def assert_compose_rejected(self, source, message_pattern):
        """功能：在完整 production source 上断言 composer 拒绝并命中指定规则。
        输入输出及副作用：source 是待扫描 SV 文本，message_pattern 是错误
        正则；只读扫描，不创建持久资源。
        失败边界：缺 class 等前置错误或未抛 ContractError 均使断言失败。"""
        module = self.require_checker()
        with self.assertRaises(module.ContractError) as raised:
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})
        self.assertRegex(str(raised.exception), message_pattern)

    def test_rejects_bit_genmask_drift(self):
        """功能：拒绝 C BIT/GENMASK 展开值与 ownership 坐标不一致。
        输入输出及副作用：传入同名宏的漂移表达式，期望 ContractError；不写仓库。
        失败边界：checker 若接受漂移，坐标权威会错误回退到模型常量。"""
        self.assert_rejected(
            lambda module: module.validate_field_expression(
                "XTRDMA_CMQSQ_WQE_QPN", "GENMASK(22, 0)", expected=(0, 24)
            )
        )

    def test_rejects_malformed_expanded_manifest_anchor_columns(self):
        """功能：拒绝 ownership 表头或 expanded anchor 列数漂移。
        输入输出及副作用：临时表少一列并调用 load_ownership；不触碰生产文件。
        失败边界：列数放宽会允许伪造 source identity 或 anchor data-flow。"""
        with tempfile.TemporaryDirectory() as name:
            path = self.write_table(
                Path(name), "ownership.tsv", OWNERSHIP_HEADER, ["x\t" * 23]
            )
            self.assert_rejected(lambda module: module.load_ownership(path))

    def test_rejects_zero_match_anchor(self):
        """功能：拒绝在命名函数体中找不到 anchor token 的零匹配。
        输入输出及副作用：传入无 token 的 C 函数文本；返回值不可作为成功证据。
        失败边界：零匹配必须 fail-closed，不能把 occurrence=1 当作声明本身。"""
        self.assert_rejected(
            lambda module: module.resolve_source_anchor(
                "static void f(void) { return; }", "f", "FIELD_PREP(X)", 1
            )
        )

    def test_rejects_multi_match_anchor(self):
        """功能：拒绝 anchor token 在函数体内多次出现而表中声明单次。
        输入输出及副作用：C 文本含两个真实 token；不写入任何 source 文件。
        失败边界：多匹配不能通过选择任一 occurrence 冒充唯一数据流。"""
        source = "void f(void) { X(); X(); }"
        self.assert_rejected(
            lambda module: module.resolve_source_anchor(source, "f", "X()", 1)
        )

    def test_rejects_comment_only_anchor(self):
        """功能：忽略注释中的 token，并拒绝仅注释匹配的 anchor。
        输入输出及副作用：C 文本只有注释副本；解析器不得把注释算作真实 occurrence。
        失败边界：若接受注释匹配，source closure 可被无效文本伪造。"""
        source = "void f(void) { /* FIELD_PREP(X) */ return; }"
        self.assert_rejected(
            lambda module: module.resolve_source_anchor(
                source, "f", "FIELD_PREP(X)", 1
            )
        )

    def test_rejects_wrong_buffer_data_flow(self):
        """功能：拒绝 anchor buffer/container 与 declared target flow 不一致。
        输入输出及副作用：ownership row 声称 wqe 但 anchor buffer 改为 shadow；不写文件。
        失败边界：错误 buffer 若被接受会把非目标图像的写入当作证据。"""
        row = self.minimal_ownership(anchor_buffer="shadow", anchor_target_flow="shadow -> qpn")
        self.assert_rejected(lambda module: module.validate_ownership_rows([row]))

    def test_rejects_omitted_codec_consumer(self):
        """功能：拒绝 owning_codec 在 --sv-root 中没有真实 consumer 引用。
        输入输出及副作用：row 指向不存在的 codec 名称；验证只读传入文本映射。
        失败边界：缺少 consumer 时不能把 ownership 宣称为已闭合生产路径。"""
        row = self.minimal_ownership(owning_codec="missing_codec")
        self.assert_rejected(
            lambda module: module.validate_ownership_rows(
                [row], sv_sources={"rdma_cmq_codecs.sv": "class real_codec; endclass"}
            )
        )

    def test_rejects_comment_only_codec_consumer(self):
        """功能：拒绝仅在 SV 注释中出现的 owning_codec consumer。
        输入输出及副作用：把 codec 与 required method 放入注释文本；不写生产源码。
        失败边界：consumer 证据必须来自可执行 SV token，注释副本不能闭合 ownership。"""
        row = self.minimal_ownership(owning_codec="ghost_codec")
        sv_sources = {
            "rdma_cmq_codecs.sv": (
                "// ghost_codec compose_request\n"
                "class real_codec; endclass"
            )
        }
        self.assert_rejected(
            lambda module: module.validate_ownership_rows(
                [row], sv_sources=sv_sources
            )
        )

    def test_rejects_unowned_unexcluded_target_macro(self):
        """功能：拒绝目标宏既无 ownership 又无 reasoned exclusion 的漏项。
        输入输出及副作用：目标集合含 GHOST 而 rows/exclusions 均无该成员。
        失败边界：漏项会让新增驱动位静默逃过 ABI 审计。"""
        self.assert_rejected(
            lambda module: module.validate_macro_coverage(
                {"XTRDMA_CMQSQ_WQE_QPN", "XTRDMA_CMQSQ_GHOST"},
                {"XTRDMA_CMQSQ_WQE_QPN"},
                {},
            )
        )

    def test_rejects_generic_exclusion_reason(self):
        """功能：拒绝 exclusion reason 为泛化 unused/not needed 的掩饰文本。
        输入输出及副作用：传入目标宏与 generic reason；不创建持久资源。
        失败边界：排除理由必须能说明该宏为何不属于当前闭合 case。"""
        self.assert_rejected(
            lambda module: module.validate_exclusion_reason("X", "unused")
        )

    def test_rejects_undeclared_overlap(self):
        """功能：拒绝两个 ownership 字段重叠却没有 overlay_group 声明。
        输入输出及副作用：传入同一坐标的两条 row；验证只读内存对象。
        失败边界：未声明 overlap 不能被当作合法 union 或覆盖顺序。"""
        first = self.minimal_ownership(macro_name="A", model_field_or_raw_slice="a")
        second = self.minimal_ownership(macro_name="B", model_field_or_raw_slice="b")
        self.assert_rejected(lambda module: module.validate_ownership_rows([first, second]))

    def test_rejects_missing_or_illegal_discriminator(self):
        """功能：拒绝 overlay row 缺失 discriminator 或使用非法选择器。
        输入输出及副作用：传入重叠 rows 的空/非法 discriminator；不写仓库。
        失败边界：overlay 没有恰好一个合法 discriminator 时必须 fail-closed。"""
        first = self.minimal_ownership(
            macro_name="A", overlay_group="G", discriminator=""
        )
        second = self.minimal_ownership(
            macro_name="B", overlay_group="G", discriminator="BAD"
        )
        self.assert_rejected(lambda module: module.validate_ownership_rows([first, second]))

    def test_rejects_mismatched_overlay_discriminators(self):
        """功能：拒绝同一 overlay group 的重叠 rows 使用不同 discriminator。
        输入输出及副作用：两个合法格式但不相同的 discriminator 共享坐标；不写文件。
        失败边界：一个重叠集合必须由唯一选择器解释，不能同时宣称两个分支。"""
        first = self.minimal_ownership(
            macro_name="A", overlay_group="G", discriminator="MODE_A"
        )
        second = self.minimal_ownership(
            macro_name="B", overlay_group="G", discriminator="MODE_B"
        )
        self.assert_rejected(
            lambda module: module.validate_ownership_rows([first, second])
        )

    def test_rejects_host_encode_writing_hw_or_reserved_bits(self):
        """功能：拒绝 HOST encoder row 声称写入 HW_TYPED/RESERVED_ZERO 位。
        输入输出及副作用：改变 ownership 为 RESERVED_ZERO 并保留 HOST_TYPED capability。
        失败边界：caller writer 不能越权覆盖硬件或保留位。"""
        row = self.minimal_ownership(ownership="RESERVED_ZERO", capability="SUPPORTED")
        self.assert_rejected(lambda module: module.validate_ownership_rows([row]))

    def test_rejects_decode_dropping_opaque_bits(self):
        """功能：拒绝 HW_OPAQUE 响应位声明 decode 丢弃原始 delta。
        输入输出及副作用：传入 opaque row 与 DROP 结果；不创建真实 codec。
        失败边界：opaque 位必须保留 raw delta，不能被 typed decoder 静默清零。"""
        row = self.minimal_mutation(
            case_id="cmq_cqe_qpc_create_response",
            entry="CMQ_CQE",
            direction="RESPONSE",
            expected_class="HW_OPAQUE",
            expected_field="-",
            evidence_mode="RAW_DECODE_MUTATION",
            driver_result_class="READY_OK",
            model_consumer="CMQ_COMPLETION_CODEC",
            expected_outcome="DROP",
            expected_status_code="CODEC_ERROR",
            expected_ready="0",
            oracle_case_id="cmq_cqe_qpc_create_response",
        )
        module = self.require_checker()
        with self.assertRaisesRegex(module.ContractError, "opaque mutation"):
            module.validate_mutation_rows([row])

    def test_rejects_nonzero_reserved_accepted(self):
        """功能：拒绝 reserved bit 的 canonical image 非零却宣称可接受。
        输入输出及副作用：静态 row 使用 ACCEPT 和非零 delta；不写文件。
        失败边界：保留位必须 canonical-zero 且不可由模型状态接受。"""
        row = self.minimal_mutation(
            byte_offset="4",
            bit_index="31",
            expected_class="RESERVED_ZERO",
            expected_field="-",
            evidence_mode="STATIC_UNWRITABLE",
            driver_result_class="STATIC_UNWRITABLE",
            expected_outcome="ACCEPT",
            expected_value_delta="1",
            expected_status_code="OK",
            expected_ready="1",
        )
        module = self.require_checker()
        with self.assertRaisesRegex(module.ContractError, "static mutation"):
            module.validate_mutation_rows([row])

    def test_rejects_unsupported_direction_marked_encodable(self):
        """功能：拒绝 unsupported direction 的 request/response capability 位为 1。
        输入输出及副作用：传入 CQC_CREATE RESPONSE 的 encodable 标志；不写仓库。
        失败边界：decoder-only 或未闭合方向不得反向启用 encoder。"""
        row = {
            "driver_symbol": "XTRDMA_OP_CQC_CREATE",
            "opcode": "CQC_CREATE",
            "opcode_value": "0x0c",
            "direction": "RESPONSE",
            "registered": "1",
            "request_encodable": "1",
            "response_decodable": "0",
            "oracle_case_id": "-",
            "owning_codec": "rdma_hw_cmq_request_composer",
            "blocker": "MISSING_CLOSED_EVIDENCE",
        }
        self.assert_rejected(lambda module: module.validate_capability_rows([row]))

    def test_accepts_only_capability_with_explicit_closed_case_proof(self):
        """功能：允许已由完整 mutation case 闭合证明的 QPC request capability。
        输入输出及副作用：传入一个 QPC_CREATE request 行和显式 proven case 集合；验证只读 row。
        失败边界：blocker 为 ``-`` 但没有闭合证明时必须拒绝；提供精确 case 证明后才可通过。"""
        module = self.require_checker()
        row = {
            "driver_symbol": "XTRDMA_OP_QPC_CREATE",
            "opcode": "QPC_CREATE",
            "opcode_value": "0x00",
            "direction": "REQUEST",
            "registered": "1",
            "request_encodable": "1",
            "response_decodable": "0",
            "oracle_case_id": "cmq_sqe_qpc_create_request",
            "owning_codec": "rdma_hw_cmq_request_composer",
            "blocker": "-",
        }
        with self.assertRaises(module.ContractError):
            module.validate_capability_rows([row])
        response = dict(row)
        response["direction"] = "RESPONSE"
        response["request_encodable"] = "0"
        response["response_decodable"] = "1"
        response["oracle_case_id"] = "cmq_cqe_qpc_create_response"
        response["owning_codec"] = "rdma_hw_cmq_completion_codec"
        doorbell = {
            "driver_symbol": "-",
            "opcode": "CMQ_SQ_DOORBELL",
            "opcode_value": "-",
            "direction": "REQUEST",
            "registered": "1",
            "request_encodable": "1",
            "response_decodable": "0",
            "oracle_case_id": "cmq_sq_doorbell",
            "owning_codec": "rdma_hw_cmq_hw_profile",
            "blocker": "-",
        }
        self.assertEqual(
            module.validate_capability_rows(
                [row, response, doorbell],
                enum_members=[("XTRDMA_OP_QPC_CREATE", 0)],
                proven_cases={
                    "cmq_sqe_qpc_create_request",
                    "cmq_cqe_qpc_create_response",
                    "cmq_sq_doorbell",
                },
            ),
            [row, response, doorbell],
        )

    def test_requires_synthetic_doorbell_in_enum_coverage(self):
        """功能：要求 capability 完整覆盖 enum 双向行及独立 CMQ doorbell 行。
        输入输出及副作用：传入一个完整 enum 的两条方向记录但省略 doorbell；不写入表。
        失败边界：仅依赖 enum keys 的覆盖不能隐藏 register writer capability 的缺失。"""
        module = self.require_checker()
        rows = []
        for direction in ("REQUEST", "RESPONSE"):
            rows.append({
                "driver_symbol": "XTRDMA_OP_QPC_CREATE",
                "opcode": "QPC_CREATE",
                "opcode_value": "0x00",
                "direction": direction,
                "registered": "1",
                "request_encodable": "0",
                "response_decodable": "0",
                "oracle_case_id": "-",
                "owning_codec": "rdma_hw_cmq_request_composer",
                "blocker": "MISSING_CLOSED_EVIDENCE",
            })
        with self.assertRaises(module.ContractError):
            module.validate_capability_rows(
                rows, enum_members=[("XTRDMA_OP_QPC_CREATE", 0)]
            )

    def test_rejects_missing_oracle_case(self):
        """功能：拒绝 ownership/mutation row 引用不存在的 oracle_case_id。
        输入输出及副作用：传入 unknown case；验证不得自行创建或推断 artifact。
        失败边界：缺失 C oracle 时必须保持 capability fail-closed。"""
        row = self.minimal_ownership(oracle_case_id="missing_case")
        self.assert_rejected(
            lambda module: module.validate_oracle_case_references(
                [row], {"cmq_sqe_qpc_create_request"}
            )
        )

    def test_rejects_mutation_report_drift(self):
        """功能：拒绝 mutation report 的总行数或 evidence counts 漂移。
        输入输出及副作用：传入空 rows 与冻结 counts；不写入报告文件。
        失败边界：任何缺行/多行都必须使 1,088-row evidence gate 失败。"""
        self.assert_rejected(
            lambda module: module.validate_mutation_report(
                [], {"GRAND_TOTAL": 1088, "EXECUTED_TOTAL": 666}
            )
        )

    def test_rejects_mutation_case_geometry_drift(self):
        """功能：拒绝 mutation qword 超出所属 case 的 canonical 图像范围。
        输入输出及副作用：构造 doorbell 的第二个 qword 记录；只读校验内存 row。
        失败边界：case 长度只有 8 字节时，qword=1 必须 fail-closed。"""
        row = self.minimal_mutation(
            case_id="cmq_sq_doorbell",
            entry="CMQ_SQ_DOORBELL",
            opcode="CMQ_SQ",
            byte_offset="15",
            qword_index="1",
            bit_index="0",
            expected_class="RESERVED_ZERO",
            expected_field="-",
            evidence_mode="STATIC_UNWRITABLE",
            driver_result_class="STATIC_UNWRITABLE",
            model_consumer="CMQ_DOORBELL_ENCODER",
            expected_outcome="REJECT",
            expected_status_code="-",
            expected_ready="-",
            expected_value_delta="0",
            oracle_case_id="cmq_sq_doorbell",
        )
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_mutation_case_identity_drift(self):
        """功能：拒绝 case 行的 entry/opcode 与冻结 case 几何不一致。
        输入输出及副作用：把 QPC request 行伪装为 CQC opcode；不写 artifact。
        失败边界：坐标相同但身份漂移时不得借助通用枚举校验通过。"""
        row = self.minimal_mutation(opcode="CQC_CREATE")
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_mutation_consumer_oracle_case_drift(self):
        """功能：拒绝 mutation 行把结果交给错误 consumer 或 oracle case。
        输入输出及副作用：将 request row 指向 completion codec 与另一 case；不修改文件。
        失败边界：driver result、model consumer 和 oracle artifact 必须保持同一 case。"""
        row = self.minimal_mutation(
            model_consumer="CMQ_COMPLETION_CODEC",
            oracle_case_id="cmq_cqe_qpc_create_response",
        )
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_non_unit_executed_mutation_delta(self):
        """功能：拒绝可执行 mutation 报告非单位 value delta。
        输入输出及副作用：把 typed recomposition 的 delta 改为 2；只读校验 row。
        失败边界：每个逐 bit 执行证据必须描述恰好一次翻转，不能用任意非零值代替。"""
        row = self.minimal_mutation(expected_value_delta="2")
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_mutation_field_semantics_drift(self):
        """功能：拒绝 qword 坐标对应字段与 evidence 语义不一致。
        输入输出及副作用：把 QPN typed 行改报为 WRAP；不调用生产编解码器。
        失败边界：字段名、ownership class 和 evidence mode 必须共同描述同一位。"""
        row = self.minimal_mutation(expected_field="wrap")
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_unaligned_or_overwide_oracle_field(self):
        """功能：拒绝 fields.tsv 的非 qword 对齐坐标和超出字段宽度的值。
        输入输出及副作用：在临时 oracle 根写入两个 malformed field fixtures；不触碰仓库。
        失败边界：byte offset 必须 8 对齐，且非 metadata 值不得设置 width 之外的位。"""
        case_id = "cmq_sqe_qpc_create_request"
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            path = root / f"{case_id}.fields.tsv"
            path.write_text("qpn\t1\t0\t1\t1\n", encoding="utf-8")
            self.assert_rejected(
                lambda module: module._load_case_fields(root, case_id)
            )
            path.write_text("qpn\t0\t0\t1\t2\n", encoding="utf-8")
            self.assert_rejected(
                lambda module: module._load_case_fields(root, case_id)
            )

    def test_rejects_same_offset_from_unexpected_c_buffer(self):
        """功能：拒绝字段宏从非目标 C buffer 写入但伪装为相同 byte base。
        输入输出及副作用：构造 shadow buffer 的 set_64bit_val 源片段并要求 wqe；不写仓库。
        失败边界：derive_macro_offsets 必须提供 expected_buffers 契约并抛 ContractError。"""
        module = self.require_checker()
        signature = inspect.signature(module.derive_macro_offsets)
        self.assertIn("expected_buffers", signature.parameters)
        source = (
            "void xtrdma_sc_qp_create(void) {"
            " set_64bit_val(shadow, 0, FIELD_PREP(XTRDMA_TEST_FIELD, value));"
            " }"
        )
        self.assert_rejected(
            lambda checker_module: checker_module.derive_macro_offsets(
                source,
                "xtrdma_sc_qp_create",
                {"XTRDMA_TEST_FIELD"},
                expected_buffers={"wqe"},
            )
        )

    def test_preserves_typo_enum_member(self):
        """功能：结构化解析必须保留 TRDMA_OP_SRFQC_MODIFY，而非按 XTRDMA 前缀过滤。
        输入输出及副作用：传入含拼写错误 enumerator 的 enum body；返回值只读。
        失败边界：成员丢失会造成 capability 表与驱动注册值不一致。"""
        module = self.require_checker()
        members = module.parse_opcode_enum(
            "enum xtrdma_cmq_opcode { XTRDMA_OP_NOP = 0x45, "
            "TRDMA_OP_SRFQC_MODIFY = 0x36, XTRDMA_OP_MAX };"
        )
        self.assertIn(("TRDMA_OP_SRFQC_MODIFY", 0x36), members)

    def test_rejects_collapsed_driver_result_and_model_status(self):
        """功能：拒绝把 driver_result_class 与 model status/consumer 合并为一列。
        输入输出及副作用：mutation row 的两列被置为同一伪字段；不写仓库。
        失败边界：Linux request_error 与 raw codec status 必须分别记录。"""
        row = self.minimal_mutation(
            driver_result_class="OK", model_consumer="OK",
            expected_status_code="OK",
        )
        self.assert_rejected(lambda module: module.validate_mutation_rows([row]))

    def test_rejects_malformed_correlation_group(self):
        """功能：拒绝只出现一行或未成对的 correlation_group。
        输入输出及副作用：单条 VALID row 声称 QPC polarity group；不写文件。
        失败边界：VALID/WRAP 必须由同一合法极性迁移同时解释两位 XOR。"""
        row = self.minimal_mutation(
            byte_offset="0",
            bit_index="63",
            expected_field="valid",
            evidence_mode="CORRELATED_RECOMPOSE",
            correlation_group="QPC_POLARITY_VALID_WRAP",
        )
        module = self.require_checker()
        with self.assertRaisesRegex(module.ContractError, "exactly VALID/WRAP pair"):
            module.validate_mutation_rows([row])

    def test_rejects_decoder_only_request_encoder(self):
        """功能：拒绝 decoder-only evidence 把 request_encodable 置一。
        输入输出及副作用：能力 row 标为 RESPONSE-only 却启用 request；不写仓库。
        失败边界：没有真实 typed encoder 的方向始终保持 0。"""
        row = {
            "driver_symbol": "XTRDMA_OP_QPC_CREATE",
            "opcode": "QPC_CREATE",
            "opcode_value": "0x00",
            "direction": "RESPONSE",
            "registered": "1",
            "request_encodable": "1",
            "response_decodable": "0",
            "oracle_case_id": "cmq_cqe_qpc_create_response",
            "owning_codec": "rdma_hw_cmq_completion_codec",
            "blocker": "MISSING_PRODUCTION_PATH_EVIDENCE",
        }
        self.assert_rejected(lambda module: module.validate_capability_rows([row]))

    def test_cqe_driver_result_order_is_locked(self):
        """功能：验证 CQE driver-result 严格遵循 owner→lookup→wrap→opcode→ecode 顺序。
        输入输出及副作用：传入 owner-not-ready 与 ecode fixtures；只返回分类结果。
        失败边界：若后置错误覆盖前置结果，Linux driver 语义会被错误报告。"""
        module = self.require_checker()
        self.assertEqual(
            module.cqe_driver_result(0, 1, 0, 0, 0, 0), "NOT_READY"
        )
        self.assertEqual(
            module.cqe_driver_result(1, 1, 1, 0, 0, 0),
            "REQUEST_LOOKUP_CHANGED",
        )
        self.assertEqual(
            module.cqe_driver_result(1, 1, 0, 1, 0, 0), "WRAP_MISMATCH"
        )
        self.assertEqual(
            module.cqe_driver_result(1, 1, 0, 0, 1, 0), "OPCODE_MISMATCH"
        )
        self.assertEqual(
            module.cqe_driver_result(1, 1, 0, 0, 0, 1), "ECODE_ERROR"
        )

    def test_model_owner_not_ready_is_distinct_from_driver_error(self):
        """功能：确认 owner 不匹配可产生 model OK/ready=0 而 driver 为 NOT_READY。
        输入输出及副作用：调用分层结果 helper；不修改 image 或外部状态。
        失败边界：若两层状态被合并，ready 与 request_error 证据会互相污染。"""
        module = self.require_checker()
        model = module.model_outcome(owner=0, expected_owner=1, opcode=0)
        self.assertEqual(model, ("OK", 0))
        self.assertEqual(module.cqe_driver_result(0, 1, 0, 0, 0, 0), "NOT_READY")

    def test_qpc_valid_wrap_require_one_polarity_xor(self):
        """功能：验证 VALID/WRAP 两行 correlation 必须由单一 polarity XOR 迁移驱动。
        输入输出及副作用：传入两位变化集合；不写任何 artifact。
        失败边界：独立翻转一位或零/三位翻转都应拒绝相关性声明。"""
        module = self.require_checker()
        self.assertTrue(module.validate_polarity_group({"valid", "wrap"}))
        self.assertFalse(module.validate_polarity_group({"valid"}))
        self.assertFalse(module.validate_polarity_group({"wrap", "valid", "extra"}))

    def test_rejects_typed_writer_covering_static_request_bit(self):
        """功能：拒绝生产 QPC writer 通过 put_field 覆盖 C 保留位。
        输入输出及副作用：向最小 SV encode_fields fixture 注入 qword0 bit24 的直接写入；
        source-walk 必须返回 ContractError，不修改临时输入。
        失败边界：若只看 canonical zero 而忽略 typed writer，伪造的 STATIC_UNWRITABLE 证据会被接受。"""
        module = self.require_checker()
        coordinates = {
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_QPN"): 0,
        }
        source = (
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "  builder.put_field(0, 24, 1, fake_bit);\n"
            "endfunction\nendclass\n"
        )
        self.assert_rejected(
            lambda checker_module: checker_module.validate_sv_writer_contract(
                {"rdma_cmq_codecs.sv": source}, coordinates,
                [{"case_id": "cmq_sqe_qpc_create_request", "qword_index": "0",
                  "bit_index": "24", "evidence_mode": "STATIC_UNWRITABLE"}],
                [], [],
            )
        )

    def test_rejects_derived_mask_drift_into_static_bit(self):
        """功能：拒绝 QPC_CREATE derived ownership mask 把 C 保留 bit 置一。
        输入输出及副作用：提供含 bit24 的伪造 RDMA_QPC_CREATE_BODY_OWNERSHIP；只读解析文本。
        失败边界：mask 漂移必须在未执行任何 model encoder 前 fail-closed。"""
        module = self.require_checker()
        source = (
            "localparam bit [63:0] RDMA_QPC_CREATE_BODY_OWNERSHIP [0:7] = '{\n"
            "64'h0000000001ffffff, 64'h0000000000000000, 64'h0, 64'h0, "
            "64'h0, 64'h0, 64'h0, 64'h0};\n"
        )
        self.assert_rejected(
            lambda checker_module: checker_module.validate_derived_masks(
                source,
                {0: 0x0000000000ffffff, 1: 0, 2: 0, 3: 0,
                 4: 0, 5: 0, 6: 0, 7: 0},
                "RDMA_QPC_CREATE_BODY_OWNERSHIP",
            )
        )

    def test_rejects_writer_coordinate_drift_from_c_map(self):
        """功能：拒绝 SV symbolic writer 坐标与 C 派生坐标不一致。
        输入输出及副作用：把 QPN alias 映射到错误的 qword/bit 区间；验证只读映射并抛错。
        失败边界：不能以 SV 常量或字段名覆盖 C source 的唯一坐标权威。"""
        module = self.require_checker()
        source = (
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "  `CMQ_QPC_PUT(RDMA_CMQ_QPN, value)\n"
            "endfunction\nendclass\n"
            "`define CMQ_QPC_PUT(STEM, VALUE) \\\n"
            "  put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, STEM``_WIDTH, VALUE);\n"
        )
        coordinates = {
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_QPN"): 0,
        }
        # A malformed C map with the same alias but a non-zero base must not be
        # silently reconciled with the SV field name.
        bad_coordinates = {
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_QPN"): 8,
        }
        self.assert_rejected(
            lambda checker_module: checker_module.validate_sv_writer_contract(
                {"rdma_cmq_codecs.sv": source}, bad_coordinates, [], [], [],
            )
        )

    def test_source_walk_collects_body_envelope_and_doorbell_macro_writers(self):
        """功能：确认 source-walk 分别收集 QPC body、envelope 和 CMQ doorbell 的宏 writer。
        输入输出及副作用：传入含宏定义与三个 production class 的最小 SV fixture；返回每个 C 坐标的 range。
        失败边界：宏定义文本不能被当成未知 writer，且任一 case 的成功分支缺失都必须被发现。"""
        module = self.require_checker()
        source = (
            "`define CMQ_QPC_PUT(STEM, VALUE) \\\n"
            "  status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "               STEM``_WIDTH, VALUE); \\\n"
            "  if (!status.ok()) return status;\n"
            "`define CMQ_ENVELOPE_PUT(STEM, VALUE) \\\n"
            "  status = builder.put_field(STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "                             STEM``_WIDTH, VALUE);\n"
            "`define DB_PUT(STEM, VALUE) \\\n"
            "  status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "               STEM``_WIDTH, VALUE);\n"
            "RDMA_FIELD(RDMA_CMQ_QPN, 0, 0, 8)\n"
            "RDMA_FIELD(RDMA_CMQ_VALID, 0, 63, 1)\n"
            "RDMA_FIELD(RDMA_CMQ_DB_PI, 0, 32, 5)\n"
            "RDMA_FIELD(RDMA_CMQ_DB_POLARITY, 0, 37, 1)\n"
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function rdma_status encode_fields(bit [7:0] opcode, "
            "rdma_hw_model model, rdma_hw_qword_builder builder);\n"
            "  rdma_status status;\n"
            "  case (opcode)\n"
            "    RDMA_OP_QPC_CREATE: begin\n"
            "      `CMQ_QPC_PUT(RDMA_CMQ_QPN, model.qpn)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
            "class rdma_hw_cmq_request_composer;\n"
            "function rdma_status compose_request(\n"
            "  rdma_hw_cmq_envelope envelope, rdma_hw_image body,\n"
            "  output rdma_hw_image result);\n"
            "  result = null;\n"
            "  status = envelope_codec.encode(envelope, envelope_image);\n"
            "  status = ownership.lookup(envelope_snapshot.opcode, input_kind, masks);\n"
            "  candidate = rdma_hw_image::type_id::create(\"rdma_cmq_request\");\n"
            "  for (int unsigned q = 0; q < 8; q++) begin\n"
            "    envelope_word = image_word(envelope_image, q);\n"
            "    body_word = image_word(body, q);\n"
            "    merged_word = envelope_word | body_word;\n"
            "    for (int unsigned i = 0; i < 8; i++)\n"
            "      candidate.bytes.push_back(merged_word[63 - (i * 8) -: 8]);\n"
            "  end\n"
            "  for (int unsigned q = 0; q < 8; q++) begin\n"
            "    merged_word = image_word(candidate, q);\n"
            "    if ((merged_word & ~(request_envelope_mask(q) | masks[q])) != 0)\n"
            "      return status;\n"
            "  end\n"
            "  result = candidate;\n"
            "endfunction\nendclass\n"
            "class rdma_hw_cmq_envelope_codec;\n"
            "function rdma_status encode(rdma_hw_cmq_envelope envelope, "
            "output rdma_hw_image image);\n"
            "  rdma_status status;\n"
            "  `CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, envelope.valid)\n"
            "endfunction\nendclass\n"
            "class rdma_hw_doorbell_codec;\n"
            "function rdma_status encode_fields(rdma_hw_model model, "
            "rdma_hw_qword_builder builder);\n"
            "  rdma_status status;\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": begin\n"
            "      `DB_PUT(RDMA_CMQ_DB_PI, model.pi)\n"
            "      `DB_PUT(RDMA_CMQ_DB_POLARITY, model.polarity)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
        )
        coordinates = {
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_QPN"):
                (0, 0, 8),
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_VALID"):
                (0, 63, 1),
            ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST", "XTRDMA_CMQSQ_DB_PI"):
                (0, 32, 5),
            ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST", "XTRDMA_CMQSQ_DB_POL"):
                (0, 37, 1),
        }
        ranges = module._scan_sv_writer_ranges(
            {"fixture.sv": source}, coordinates
        )
        observed = {
            (item.case_id, item.operation, item.base, item.lsb, item.width)
            for item in ranges
        }
        self.assertIn(
            ("cmq_sqe_qpc_create_request", "MACRO_PUT", 0, 0, 8),
            observed,
        )
        self.assertIn(
            ("cmq_sqe_qpc_create_request", "MACRO_PUT", 0, 63, 1),
            observed,
        )
        self.assertIn(
            ("cmq_sq_doorbell", "MACRO_PUT", 0, 32, 5),
            observed,
        )
        self.assertIn(
            ("cmq_sq_doorbell", "MACRO_PUT", 0, 37, 1),
            observed,
        )
        self.assertFalse(any(item.operation == "UNKNOWN_WRITER" for item in ranges))

    def test_rejects_malformed_production_macro_in_source_walk(self):
        """功能：source-walk 遇到残缺的生产宏续行时必须立即拒绝。
        输入输出及副作用：传入未闭合 CMQ_QPC_PUT 定义；不写入任何
        源码文件。
        失败边界：宏解析错误不得降级为空表并丢失 writer 证据。"""
        module = self.require_checker()
        source = "`define CMQ_QPC_PUT(STEM, VALUE) " + chr(92) + "\n"
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})

    def test_rejects_duplicate_production_macro_definition(self):
        """功能：拒绝同名 production macro 即使正文相同也被重复定义。
        输入输出及副作用：在完整 production fixture 前重复 CMQ_QPC_PUT；只读扫描文本。
        失败边界：重复定义若被折叠成一个 dict 项，会让 include/拼接顺序
        改变实际 writer 而不触发 ABI gate。"""
        module = self.require_checker()
        macro = (
            "`define CMQ_QPC_PUT(STEM, VALUE) \\\n"
            "  status = put(builder, STEM``_WORD_BYTE_OFFSET, STEM``_LSB, \\\n"
            "               STEM``_WIDTH, VALUE); \\\n"
            "  if (!status.ok()) return status;\n"
        )
        source = macro + self.complete_production_compose_source()
        with self.assertRaises(module.ContractError):
            module._collect_sv_macro_definitions({"fixture.sv": source})

    def test_rejects_missing_compose_request_writer(self):
        """功能：缺少真实 compose_request 输出合并路径时拒绝 QPC writer 证明。
        输入输出及副作用：传入只有 QPC body class 的 source；只返回错误，
        不改文件。
        失败边界：body/envelope writer 不能替代 composer 的 output/data-flow 证据。"""
        module = self.require_checker()
        source = (
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "  builder.put_field(0, 0, 8, value);\n"
            "endfunction\nendclass\n"
        )
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})

    def test_rejects_compose_request_static_bit_bypass(self):
        """功能：compose_request 不能以静态位赋值绕过 envelope/body merge 证明。
        输入输出及副作用：传入伪造 composer 的 candidate bytes 写入；不执行
        SV。
        失败边界：缺少逐 qword envelope/body merge 或 C-derived masks 时必须
        拒绝。"""
        module = self.require_checker()
        source = (
            "class rdma_hw_cmq_request_composer;\n"
            "function rdma_status compose_request(\n"
            "  input rdma_hw_image body, output rdma_hw_image result);\n"
            "  result = null;\n"
            "  result = rdma_hw_image::type_id::create(\"result\");\n"
            "  result.bytes[0] = 1'b1;\n"
            "endfunction\nendclass\n"
        )
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})

    def test_rejects_compose_request_image_mutator_bypass(self):
        """功能：拒绝 candidate/result image 的非 canonical mutator 绕过 merge 证明。
        输入输出及副作用：逐一注入 push/delete/insert 或索引自增；不执行
        SV。
        失败边界：除逐字节 merged_word push 外的 image 修改均抛 ContractError。"""
        mutators = (
            "candidate.bytes.push_back(8'hff);",
            "candidate.bytes.delete();",
            "candidate.bytes.push_front(8'hff);",
            "candidate.bytes.insert(0, 8'hff);",
            "candidate.bytes[0]++;",
        )
        for mutator in mutators:
            with self.subTest(mutator=mutator):
                source = self.complete_production_compose_source(
                    merge_extra=mutator
                )
                self.assert_compose_rejected(
                    source, r"compose_request .*image|compose_request .*writer"
                )

    def test_rejects_compose_request_merge_post_mutation(self):
        """功能：拒绝 canonical envelope/body OR 后对 merged_word 的静态复写或
        按位修改。
        输入输出及副作用：逐一注入 |=、^=、标量赋值和 bit-select；不执行
        SV。
        失败边界：merge 后任何未证明修改都必须 fail-closed。"""
        mutations = (
            "merged_word |= 64'h1;",
            "merged_word ^= 64'h1;",
            "merged_word = 1'b1;",
            "merged_word[0] = 1'b1;",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                source = self.complete_production_compose_source(
                    merge_extra=mutation
                )
                self.assert_compose_rejected(
                    source, r"compose_request .*merged_word"
                )

    def test_rejects_compose_request_alias_image_mutator(self):
        """功能：拒绝 candidate 的 rdma_hw_image alias 及其 bytes 变异。
        输入输出及副作用：构造 alias=candidate 后注入 push/delete/insert/bit 写；
        仅扫描完整 production fixture，不执行 SV。
        失败边界：alias rebind 或任一 alias bytes mutator 必须命中 image
        规则。"""
        mutators = (
            "alias.bytes.push_back(8'hff);",
            "alias.bytes.delete();",
            "alias.bytes.push_front(8'hff);",
            "alias.bytes.insert(0, 8'hff);",
            "alias.bytes[0] = 1'b1;",
            "alias.bytes[0] |= 1'b1;",
            "alias |= merged_word;",
            "alias = envelope_word | body_word;",
        )
        for mutator in mutators:
            with self.subTest(mutator=mutator):
                source = self.complete_production_compose_source(
                    merge_extra=mutator,
                    pre_merge_extra=(
                        "rdma_hw_image alias; alias = candidate;"
                    ),
                )
                self.assert_compose_rejected(
                    source,
                    r"compose_request .*image alias|compose_request .*image",
                )

    def test_rejects_missing_production_writer_macro(self):
        """功能：缺失任一 production writer macro 定义时拒绝 source-walk 证明。
        输入输出及副作用：传入调用点但删除对应定义；只读 fixture，不改
        源码。
        失败边界：三类 macro 均不得退化为 alias-only range。"""
        module = self.require_checker()
        source = (
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "  case (opcode)\n"
            "    RDMA_OP_QPC_CREATE: begin\n"
            "      `CMQ_QPC_PUT(RDMA_CMQ_QPN, value)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
            "class rdma_hw_cmq_envelope_codec;\n"
            "function void encode();\n"
            "  `CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, value)\n"
            "endfunction\nendclass\n"
            "class rdma_hw_doorbell_codec;\n"
            "function void encode_fields();\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": begin\n"
            "      `DB_PUT(RDMA_CMQ_DB_PI, value)\n"
            "    end\n"
            "  endcase\n"
            "endfunction\nendclass\n"
            + self.minimal_compose_source()
        )
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})

    def test_rejects_production_macro_without_typed_writer(self):
        """功能：拒绝只保留 alias invocation、没有实际 put writer 的生产宏。
        输入输出及副作用：构造三个 production class，并将宏正文替换为 status
        赋值；不执行 SV。
        失败边界：alias range 不能单独证明字段可写，缺失 writer 必须
        fail-closed。"""
        module = self.require_checker()
        source = (
            "`define CMQ_QPC_PUT(STEM, VALUE) status = status;\n"
            "`define CMQ_ENVELOPE_PUT(STEM, VALUE) status = status;\n"
            "`define DB_PUT(STEM, VALUE) status = status;\n"
            "RDMA_FIELD(RDMA_CMQ_QPN, 0, 0, 8)\n"
            "RDMA_FIELD(RDMA_CMQ_VALID, 0, 63, 1)\n"
            "RDMA_FIELD(RDMA_CMQ_DB_PI, 0, 32, 5)\n"
            "RDMA_FIELD(RDMA_CMQ_DB_POLARITY, 0, 37, 1)\n"
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "case (opcode) RDMA_OP_QPC_CREATE: begin\n"
            "`CMQ_QPC_PUT(RDMA_CMQ_QPN, value) end endcase\n"
            "endfunction endclass\n"
            "class rdma_hw_cmq_envelope_codec;\n"
            "function void encode();\n"
            "`CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, value)\n"
            "endfunction endclass\n"
            "class rdma_hw_doorbell_codec;\n"
            "function void encode_fields();\n"
            "case (variant_name) \"cmq_sq\": begin\n"
            "`DB_PUT(RDMA_CMQ_DB_PI, value)\n"
            "`DB_PUT(RDMA_CMQ_DB_POLARITY, value) end endcase\n"
            "endfunction endclass\n"
            + self.minimal_compose_source()
        )
        coordinates = {
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_QPN"):
                (0, 0, 8),
            ("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_VALID"):
                (0, 63, 1),
            ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST", "XTRDMA_CMQSQ_DB_PI"):
                (0, 32, 5),
            ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST", "XTRDMA_CMQSQ_DB_POL"):
                (0, 37, 1),
        }
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, coordinates)

    def test_rejects_production_macro_missing_without_invocation(self):
        """功能：即使 production branch 暂无 invocation，也要求三类宏定义齐全。
        输入输出及副作用：删除 DB_PUT 定义但保留 class/function 结构；不执行
        或写入源码。
        失败边界：未使用宏的缺定义不能被空 branch 掩盖，source-walk 必须
        拒绝。"""
        module = self.require_checker()
        source = (
            "`define CMQ_QPC_PUT(STEM, VALUE) status = put(builder, 0, 0, 1, VALUE);\n"
            "`define CMQ_ENVELOPE_PUT(STEM, VALUE) status = builder.put_field(0, 63, 1, VALUE);\n"
            "class rdma_hw_cmq_qpc_layout_codec;\n"
            "function void encode_fields();\n"
            "case (opcode) RDMA_OP_QPC_CREATE: begin\n"
            "`CMQ_QPC_PUT(RDMA_CMQ_QPN, value) end endcase\n"
            "endfunction endclass\n"
            "class rdma_hw_cmq_envelope_codec;\n"
            "function void encode();\n"
            "`CMQ_ENVELOPE_PUT(RDMA_CMQ_VALID, value)\n"
            "endfunction endclass\n"
            "class rdma_hw_doorbell_codec;\n"
            "function void encode_fields();\n"
            "case (variant_name) \"cmq_sq\": begin end endcase\n"
            "endfunction endclass\n"
            + self.minimal_compose_source()
        )
        with self.assertRaises(module.ContractError):
            module._scan_sv_writer_ranges({"fixture.sv": source}, {})

    def test_rejects_get_target_in_same_range_node(self):
        """功能：GET anchor 的目标必须位于 buffer/range 节点之后，不能同节点
        伪造闭合流。
        输入输出及副作用：把 destination 与 cqe[0] 放在同一节点；不执行 C
        函数。
        失败边界：target 与 range 同节点或先于 range 时抛 ContractError。"""
        module = self.require_checker()
        row = self.minimal_ownership(
            anchor_token="get_64bit_val(cqe, 0, &temp)",
            anchor_container="cqe",
            anchor_buffer="cqe",
            anchor_operation="GET_64BIT",
            anchor_target_flow=(
                "cqe[0] temp -> XTRDMA_CMQSQ_WQE_QPN -> ready"
            ),
        )
        body = "get_64bit_val(cqe, 0, &temp);"
        with self.assertRaises(module.ContractError):
            module._validate_anchor_call_arguments(row, body, "fixture.c")

    def test_rejects_range_on_buffer_member_instead_of_declared_buffer(self):
        """功能：拒绝把 buffer 的成员字段 range 冒充为 declared buffer 自身的
        范围。
        输入输出及副作用：传入 foo->wqe[0] 节点与后置 target；只读 flow，不
        执行 C。
        失败边界：range 必须绑定完整 buffer 表达式，成员/别名不能闭合
        GET/MEMCPY。"""
        module = self.require_checker()
        with self.assertRaises(module.ContractError):
            module._require_anchor_range_in_flow(
                "wqe -> foo->wqe[0] -> X -> target",
                "wqe", 0, 8, target_expr="target", target_must_be_after=True,
            )

    def test_rejects_anchor_range_on_unrelated_flow_node(self):
        """功能：range/base/length 必须与 declared buffer 位于同一 flow 节点。
        输入输出及副作用：把 wqe 的 [0] 范围伪造到 foo 节点；不写入 source。
        失败边界：全局字符串同时出现 buffer、range 和 target 时仍须拒绝。"""
        module = self.require_checker()
        row = self.minimal_ownership(
            anchor_target_flow=(
                "info->qpn -> wqe -> foo[0] -> "
                "XTRDMA_CMQSQ_WQE_QPN -> target"
            )
        )
        body = (
            "set_64bit_val(wqe, 0, "
            "FIELD_PREP(XTRDMA_CMQSQ_WQE_QPN, info->qpn));"
        )
        with self.assertRaises(module.ContractError):
            module._validate_anchor_call_arguments(row, body, "fixture.c")

    def test_rejects_nested_index_that_only_prefix_matches_declared_range(self):
        """功能：拒绝把 wqe[0][1] 这样的嵌套索引冒充 declared wqe[0] qword。
        输入输出及副作用：直接传入含嵌套索引的 flow；不执行 C 调用或修改表。
        失败边界：range 匹配若只做前缀搜索，会把不同 buffer 元素误认成同一
        base/length，进而伪造 anchor 的目标绑定。"""
        module = self.require_checker()
        with self.assertRaises(module.ContractError):
            module._require_anchor_range_in_flow(
                "wqe[0][1] -> temp -> target",
                "wqe",
                0,
                8,
                target_expr="temp",
                target_must_be_after=True,
            )

    def test_selected_mask_ignores_other_cmq_sq_case_returns(self):
        """功能：只从 selected_mask 方法读取 CMQ SQ 的允许位 literal。
        输入输出及副作用：fixture 另含 offset/target 方法的同名 case 分支；返回 selected_mask 的整数值。
        失败边界：跨方法正则匹配会把多个合法 cmq_sq 分支误报为重复并阻断 source-walk。"""
        module = self.require_checker()
        source = (
            "function bit [63:0] expected_relative_offset();\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": return 64'h10;\n"
            "  endcase\n"
            "endfunction\n"
            "function bit [63:0] selected_mask();\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": return 64'h0000_003f_0000_0000;\n"
            "  endcase\n"
            "endfunction\n"
            "function bit [63:0] another_target();\n"
            "  case (variant_name)\n"
            "    \"cmq_sq\": return 64'h20;\n"
            "  endcase\n"
            "endfunction\n"
        )
        self.assertEqual(
            module._selected_mask_for_cmq_doorbell(source),
            0x0000003F00000000,
        )

    def test_model_accepts_tq_flush_from_sv_supported_set(self):
        """功能：确认 TQ_FLUSH opcode 属于 completion codec 的真实 supported_opcode 集合。
        输入输出及副作用：传入 owner-ready 与 0x20；返回 OK/ready=1，不修改状态。
        失败边界：硬编码集合漏项会把合法 opcode 错误标成 UNSUPPORTED_OPCODE。"""
        module = self.require_checker()
        self.assertEqual(module.model_outcome(1, 1, 0x20), ("OK", 1))

    def test_derive_memcpy_and_offset_evidence(self):
        """功能：从 memcpy/offsetof 调用推导目标 buffer 的 byte base。
        输入输出及副作用：fixture 仅含一个 memcpy 与 offsetof 赋值；返回 C-derived 坐标映射。
        失败边界：缺少调用参数、目标 buffer 不符或多个 base 时必须拒绝而非猜测。"""
        module = self.require_checker()
        source = (
            "void f(void) {\n"
            "  size_t off = offsetof(struct packet, payload);\n"
            "  memcpy(wqe + 1, src, 56);\n"
            "}\n"
        )
        self.assertEqual(
            module.derive_macro_offsets(
                source, "f", {"XTRDMA_TEST_FIELD"}, expected_buffers={"wqe + 1"},
                evidence_macros={"XTRDMA_TEST_FIELD": {"kind": "MEMCPY", "base": 8}},
            )["XTRDMA_TEST_FIELD"],
            8,
        )

    # 功能：确认未闭合的 response、doorbell、CQC 方向不会因候选字段存在而提前开放。
    # 输入输出及副作用：调用 expected ownership projection；只读取内存 fixture，不写仓库或启用 capability。
    # 失败边界：任何未证明方向出现 SUPPORTED，或已证明 request 的 static/fixed 字段仍为 UNSUPPORTED，测试失败。
    def test_expected_ownership_is_fail_closed_by_proven_case(self):
        module = self.require_checker()
        rows = module.build_expected_ownership(
            self.cmq_manifest_records(),
            proven_cases={"cmq_sqe_qpc_create_request"},
        )
        indexed = self.expected_ownership_by_case(rows)

        qpc_request = {
            row["macro_name"]: row
            for row in rows
            if row["entry_kind"] == "CMQ_SQE"
            and row["opcode_or_variant"] == "QPC_CREATE"
            and row["direction"] == "REQUEST"
        }
        self.assertTrue(qpc_request)
        self.assertTrue(all(
            row["capability"] == "SUPPORTED"
            for row in qpc_request.values()
            if row["ownership"] in {"HOST_TYPED", "HOST_FIXED"}
        ))

        for key, row in indexed.items():
            entry, opcode, direction, _ = key
            if (entry, opcode, direction) in {
                ("CMQ_CQE", "QPC_CREATE", "RESPONSE"),
                ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST"),
                ("CMQ_SQE", "CQC_CREATE", "REQUEST"),
            }:
                self.assertEqual(row["capability"], "UNSUPPORTED")

    # 功能：确认三条 proven case 全部闭合后只开放对应方向，且 response reserved 位仍保持关闭。
    # 输入输出及副作用：基于 C-derived proven case 集合生成 expected rows；不触碰实际 TSV 或外部资源。
    # 失败边界：CQC、reserved 或任何没有 case 映射的方向被错误提升为 SUPPORTED 时测试失败。
    def test_expected_ownership_promotes_only_owned_proven_fields(self):
        module = self.require_checker()
        rows = module.build_expected_ownership(
            self.cmq_manifest_records(),
            proven_cases=set(module.PROVEN_CAPABILITY_CASES),
        )
        indexed = self.expected_ownership_by_case(rows)

        for row in rows:
            identity = (
                row["entry_kind"],
                row["opcode_or_variant"],
                row["direction"],
            )
            if identity == ("CMQ_SQE", "QPC_CREATE", "REQUEST"):
                self.assertEqual(row["capability"], "SUPPORTED")
            elif identity == ("CMQ_CQE", "QPC_CREATE", "RESPONSE"):
                expected = (
                    "SUPPORTED"
                    if row["ownership"] == "HW_TYPED"
                    else "UNSUPPORTED"
                )
                self.assertEqual(row["capability"], expected)
            elif identity == ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST"):
                self.assertEqual(row["capability"], "SUPPORTED")
            elif identity == ("CMQ_SQE", "CQC_CREATE", "REQUEST"):
                self.assertEqual(row["capability"], "UNSUPPORTED")

        self.assertEqual(
            indexed[("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQCQ_OPCODE")]["capability"],
            "SUPPORTED",
        )
        self.assertEqual(
            indexed[("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_WQE_SIGN_EN")]["capability"],
            "SUPPORTED",
        )
        self.assertEqual(
            indexed[("CMQ_SQE", "QPC_CREATE", "REQUEST", "XTRDMA_CMQSQ_VFID_OVERRIDE")]["capability"],
            "SUPPORTED",
        )


if __name__ == "__main__":
    unittest.main()
