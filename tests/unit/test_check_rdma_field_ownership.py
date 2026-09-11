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


if __name__ == "__main__":
    unittest.main()
