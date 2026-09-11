#!/usr/bin/env python3
"""
目录：tools；职责：把锁定驱动 C 字段、source anchors、consumer 和 CMQ 变异证据
收敛为只读机器门禁。
依赖：Task 1 archive lock、Task 2 source manifest、Task 3 C oracle artifacts 与
仓库 SV consumer；本模块不拥有外部源码，也不生成或修改 SV mask。
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
import hashlib
import re
from pathlib import Path
import sys
from typing import Iterable, Mapping, Sequence

try:
    from .rdma_driver_contract import (
        ContractError,
        load_archive_lock,
        load_source_manifest,
    )
except ImportError:  # pragma: no cover - direct script execution
    from rdma_driver_contract import (
        ContractError,
        load_archive_lock,
        load_source_manifest,
    )


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

OWNERSHIP_COLUMNS = tuple(OWNERSHIP_HEADER.split("\t"))
EXCLUSION_COLUMNS = tuple(EXCLUSION_HEADER.split("\t"))
CAPABILITY_COLUMNS = tuple(CAPABILITY_HEADER.split("\t"))
MUTATION_COLUMNS = tuple(MUTATION_HEADER.split("\t"))

OWNERSHIP_VALUES = {
    "HOST_TYPED", "HOST_FIXED", "HW_TYPED", "HW_OPAQUE", "RESERVED_ZERO"
}
CAPABILITY_VALUES = {"SUPPORTED", "UNSUPPORTED"}
EVIDENCE_VALUES = {
    "TYPED_RECOMPOSE", "CORRELATED_RECOMPOSE", "DRIVER_FIXED_REJECT",
    "STATIC_CANONICAL", "STATIC_UNWRITABLE", "RAW_DECODE_MUTATION",
}
DRIVER_RESULT_VALUES = {
    "ENCODED", "FIXED_ZERO", "STATIC_CANONICAL", "STATIC_UNWRITABLE",
    "NOT_READY", "REQUEST_LOOKUP_CHANGED", "WRAP_MISMATCH",
    "OPCODE_MISMATCH", "ECODE_ERROR", "READY_OK",
}
RAW_DRIVER_RESULTS = {
    "NOT_READY", "REQUEST_LOOKUP_CHANGED", "WRAP_MISMATCH",
    "OPCODE_MISMATCH", "ECODE_ERROR", "READY_OK",
}
STATIC_EVIDENCE = {"STATIC_CANONICAL", "STATIC_UNWRITABLE"}
EXECUTED_EVIDENCE = {
    "TYPED_RECOMPOSE", "CORRELATED_RECOMPOSE", "DRIVER_FIXED_REJECT",
    "RAW_DECODE_MUTATION",
}
GENERIC_EXCLUSION_REASONS = {"unused", "not needed"}
ANCHOR_COLUMNS = (
    "anchor_function", "anchor_token", "anchor_occurrence",
    "anchor_container", "anchor_buffer", "anchor_operation", "anchor_base",
    "anchor_length", "anchor_target_flow",
)
ALLOWED_OPERATIONS = {
    "SET_64BIT_FIELD_PREP", "CPU_TO_BE64_STORE", "XOR_U64_REMAINDER_FOLD",
    "MEMCPY", "ASSIGN_ADDRESS", "ASSIGN_SHIFT_RIGHT", "GET_64BIT_FIELD_GET",
    "GET_64BIT", "BE64_TO_CPU_LOAD", "INDEX_LOOKUP", "COMPARE_WRAP",
    "COMPARE_OPCODE", "COMPARE_ECODE", "FIELD_PREP_OR", "IOWRITE64BE",
}
VALID_DIRECTIONS = {"REQUEST", "RESPONSE"}
VALID_ENTRY_KINDS = {"CMQ_SQE", "CMQ_CQE", "CMQ_SQ_DOORBELL"}
VALID_MODEL_CONSUMERS = {
    "CMQ_REQUEST_COMPOSER", "CMQ_COMPLETION_CODEC", "CMQ_DOORBELL_ENCODER",
}

CASE_LAYOUTS = {
    "cmq_sqe_qpc_create_request": {
        "entry": "CMQ_SQE",
        "opcode": "QPC_CREATE",
        "direction": "REQUEST",
        "length": 64,
    },
    "cmq_cqe_qpc_create_response": {
        "entry": "CMQ_CQE",
        "opcode": "QPC_CREATE",
        "direction": "RESPONSE",
        "length": 64,
    },
    "cmq_sq_doorbell": {
        "entry": "CMQ_SQ_DOORBELL",
        "opcode": "CMQ_SQ",
        "direction": "REQUEST",
        "length": 8,
    },
}

CASE_FIELD_MACROS = {
    "cmq_sqe_qpc_create_request": {
        "valid": "XTRDMA_CMQSQ_WQE_VALID",
        "vf_id_override": "XTRDMA_CMQSQ_VFID_OVERRIDE",
        "use_vfid": "XTRDMA_CMQSQ_USE_VFID",
        "wrap": "XTRDMA_CMQSQ_WQE_WRAP",
        "index": "XTRDMA_CMQSQ_WQE_INDEX",
        "opcode": "XTRDMA_CMQCQ_OPCODE",
        "qpn": "XTRDMA_CMQSQ_WQE_QPN",
        "rq_cqn": "XTRDMA_CMQSQ_WQE_RQ_CQN",
        "sign_en": "XTRDMA_CMQSQ_WQE_SIGN_EN",
        "signature": "XTRDMA_CMQSQ_WQE_SIGNATURE",
        "sq_cqn": "XTRDMA_CMQSQ_WQE_SQ_CQN",
        "qpc_buffer_addr_pa": "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR",
    },
    "cmq_cqe_qpc_create_response": {
        "valid": "XTRDMA_CMQSQ_WQE_VALID",
        "wrap": "XTRDMA_CMQSQ_WQE_WRAP",
        "index": "XTRDMA_CMQSQ_WQE_INDEX",
        "opcode": "XTRDMA_CMQCQ_OPCODE",
        "ecode": "XTRDMA_CMQCQ_CMD_ECODE",
    },
    "cmq_sq_doorbell": {
        "pi_after": "XTRDMA_CMQSQ_DB_PI",
        "wire_polarity": "XTRDMA_CMQSQ_DB_POL",
    },
}

CQC_REQUEST_FIELDS = {
    "valid": "XTRDMA_CMQSQ_WQE_VALID",
    "vf_id_override": "XTRDMA_CMQSQ_VFID_OVERRIDE",
    "use_vfid": "XTRDMA_CMQSQ_USE_VFID",
    "wrap": "XTRDMA_CMQSQ_WQE_WRAP",
    "index": "XTRDMA_CMQSQ_WQE_INDEX",
    "opcode": "XTRDMA_CMQCQ_OPCODE",
    "cqn": "XTRDMA_CMQSQ_WQE_CQC_WQE_CQN",
}

QPC_REQUEST_POLICY = {
    "valid": ("HOST_TYPED", "valid", "CORRELATED_RECOMPOSE"),
    "wrap": ("HOST_TYPED", "wrap", "CORRELATED_RECOMPOSE"),
    "index": ("HOST_TYPED", "index", "TYPED_RECOMPOSE"),
    "qpn": ("HOST_TYPED", "qpn", "TYPED_RECOMPOSE"),
    "sq_cqn": ("HOST_TYPED", "sq_cqn", "TYPED_RECOMPOSE"),
    "rq_cqn": ("HOST_TYPED", "rq_cqn", "TYPED_RECOMPOSE"),
    "qpc_buffer_addr_pa": (
        "HOST_TYPED", "qpc_buffer_addr_pa", "TYPED_RECOMPOSE"
    ),
    "signature": ("HOST_TYPED", "signature", "TYPED_RECOMPOSE"),
    "vf_id_override": ("HOST_FIXED", "vf_id_override", "DRIVER_FIXED_REJECT"),
    "use_vfid": ("HOST_FIXED", "use_vfid", "DRIVER_FIXED_REJECT"),
    "opcode": ("HOST_FIXED", "opcode", "STATIC_CANONICAL"),
    "sign_en": ("HOST_FIXED", "sign_en", "STATIC_CANONICAL"),
}

RESPONSE_TYPED_FIELDS = {
    "valid": "owner",
    "wrap": "wrap",
    "index": "index",
    "opcode": "opcode",
    "ecode": "ecode",
}

FROZEN_MUTATION_COUNTS = {
    "TYPED_RECOMPOSE": 140,
    "CORRELATED_RECOMPOSE": 2,
    "DRIVER_FIXED_REJECT": 12,
    "RAW_DECODE_MUTATION": 512,
    "STATIC_CANONICAL": 9,
    "STATIC_UNWRITABLE": 413,
    "EXECUTED_TOTAL": 666,
    "STATIC_TOTAL": 422,
    "GRAND_TOTAL": 1088,
}


@dataclass(frozen=True)
class MacroDefinition:
    """功能：保存一个由 C BIT/GENMASK 宏解析出的逻辑位域。
    输入输出及副作用：字段记录宏名、表达式、低位和宽度；对象不可变且不拥有源码。
    失败边界：构造前必须通过 parse_field_expression，超出 64 位的表达式不得进入对象。"""

    name: str
    expression: str
    lsb: int
    width: int
    source_path: str = ""


@dataclass(frozen=True)
class OpcodeDefinition:
    """功能：保存 enum xtrdma_cmq_opcode 的精确成员拼写和值。
    输入输出及副作用：成员由结构化 enum 解析产生；对象不修改源文本或注册表。
    失败边界：MAX 作为边界由调用方排除，重复名称/值或非法表达式必须抛 ContractError。"""

    symbol: str
    value: int


def _sha256(path: Path) -> str:
    """功能：读取 path 并计算其 SHA-256，供 source identity 比对。
    输入输出及副作用：返回小写摘要；只读文件，不创建输出。
    失败边界：路径不可读、目录或读取中断时传播 OSError，调用方不得接受未验证来源。"""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _strip_comments(text: str) -> str:
    """功能：移除 C/C++ 块注释和行注释，保留真实 token 供 anchor 计数。
    输入输出及副作用：返回规范化前的无注释文本，不修改输入。
    失败边界：未闭合块注释按文件末尾结束；注释内 token 永远不能成为 anchor 命中。"""
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def _parse_int(text: str, label: str) -> int:
    """功能：解析十进制或十六进制整数 token，供宏位域和坐标校验使用。
    输入输出及副作用：返回 Python int；无外部副作用。
    失败边界：空值、尾随字符、负数或超出调用方范围时抛 ContractError。"""
    value = text.strip()
    if not re.fullmatch(r"(?:0[xX][0-9a-fA-F]+|[0-9]+)", value):
        raise ContractError(f"{label}: invalid integer {text!r}")
    return int(value, 0)


def parse_field_expression(expression: str) -> tuple[int, int]:
    """功能：把 BIT/BIT_ULL/GENMASK/GENMASK_ULL 表达式解析为低位和宽度。
    输入输出及副作用：返回 (lsb, width)，不执行 eval、不读取其他定义。
    失败边界：未知形式、位号不在 0..63、GENMASK 高位低于低位均抛 ContractError。"""
    compact = " ".join(expression.strip().split())
    match = re.fullmatch(
        r"(BIT(?:_ULL)?|GENMASK(?:_ULL)?)\(\s*([^,()]+)"
        r"(?:\s*,\s*([^,()]+))?\s*\)",
        compact,
    )
    if match is None:
        raise ContractError(f"unsupported C field expression: {expression}")
    kind, first_text, second_text = match.groups()
    first = _parse_int(first_text, "field bit")
    if kind.startswith("BIT"):
        if first > 63:
            raise ContractError(f"{kind} bit {first} exceeds 63")
        return first, 1
    if second_text is None:
        raise ContractError(f"{kind} requires high and low bits")
    low = _parse_int(second_text, "field low bit")
    if first > 63 or low > 63 or first < low:
        raise ContractError(f"invalid {kind} range {first},{low}")
    return low, first - low + 1


def parse_c_field_expression(expression: str) -> tuple[int, int]:
    """功能：提供字段表达式解析的公开别名，供单元 fixture 直接验证 C 语法。
    输入输出及副作用：参数和返回值与 parse_field_expression 相同；不缓存或改写表达式。
    失败边界：所有 parse_field_expression 的拒绝条件原样传播。"""
    return parse_field_expression(expression)


def validate_field_expression(
    name: str,
    expression: str,
    expected: tuple[int, int],
) -> tuple[int, int]:
    """功能：确认命名 C 宏的解析坐标与 ownership 期望完全一致。
    输入输出及副作用：返回实际 (lsb,width)；只读比较，不修改宏表。
    失败边界：表达式非法或实际坐标不同均抛 ContractError，阻断 BIT/GENMASK drift。"""
    actual = parse_field_expression(expression)
    if actual != expected:
        raise ContractError(
            f"field expression drift for {name}: {actual} != {expected}"
        )
    return actual


def parse_macro_definitions(
    text: str,
    source_path: str = "",
) -> dict[str, MacroDefinition]:
    """功能：从 C header 逐行解析 BIT/GENMASK 字段宏及其来源路径。
    输入输出及副作用：返回宏名到 MacroDefinition 的映射；不展开或推导其他 mask。
    失败边界：同名宏表达式漂移、宏表达式非法或续行残缺时抛 ContractError。"""
    source = _strip_comments(text)
    logical_lines: list[str] = []
    pending = ""
    for raw_line in source.splitlines():
        line = raw_line.rstrip()
        if pending:
            pending += line.lstrip()
        else:
            pending = line
        if pending.endswith("\\"):
            pending = pending[:-1]
            continue
        logical_lines.append(pending)
        pending = ""
    if pending:
        raise ContractError(f"{source_path}: unterminated macro continuation")
    definitions: dict[str, MacroDefinition] = {}
    pattern = re.compile(r"^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*$")
    for line in logical_lines:
        match = pattern.match(line)
        if match is None:
            continue
        name, expression = match.groups()
        try:
            lsb, width = parse_field_expression(expression)
        except ContractError:
            continue
        definition = MacroDefinition(name, expression, lsb, width, source_path)
        previous = definitions.get(name)
        if previous is not None and previous != definition:
            raise ContractError(f"duplicate C field macro {name}")
        definitions[name] = definition
    return definitions


def _enum_body(text: str) -> str:
    """功能：定位 enum xtrdma_cmq_opcode 的花括号内容供结构化解析。
    输入输出及副作用：返回去注释后的 body，不执行 C 预处理或名称过滤。
    失败边界：缺失 enum、花括号不平衡或空 body 均抛 ContractError。"""
    source = _strip_comments(text)
    match = re.search(
        r"\benum\s+xtrdma_cmq_opcode\s*\{", source
    )
    if match is None:
        raise ContractError("enum xtrdma_cmq_opcode is missing")
    start = match.end()
    depth = 1
    index = start
    while depth and index < len(source):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    if depth or not source[start:index - 1].strip():
        raise ContractError("enum xtrdma_cmq_opcode body is malformed")
    return source[start:index - 1]


def parse_opcode_enum(text: str) -> list[tuple[str, int]]:
    """功能：按 enum body 顺序解析所有 CMQ opcode 成员并保留精确拼写。
    输入输出及副作用：返回 [(symbol,value)]，包括 typo 成员但不删除 MAX。
    失败边界：重复成员/值、非整数显式值、空成员或非 enum 文本均抛 ContractError。"""
    body = _enum_body(text)
    members: list[OpcodeDefinition] = []
    previous = -1
    names: set[str] = set()
    values: set[int] = set()
    for raw_item in body.split(","):
        item = " ".join(raw_item.split())
        if not item:
            continue
        match = re.fullmatch(
            r"([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*(0[xX][0-9a-fA-F]+|[0-9]+))?",
            item,
        )
        if match is None:
            raise ContractError(f"malformed CMQ opcode enumerator: {item}")
        symbol, explicit = match.groups()
        value = _parse_int(explicit, symbol) if explicit is not None else previous + 1
        if symbol in names:
            raise ContractError(f"duplicate CMQ opcode symbol {symbol}")
        if value in values:
            raise ContractError(f"duplicate CMQ opcode value {value:#x}")
        names.add(symbol)
        values.add(value)
        members.append(OpcodeDefinition(symbol, value))
        previous = value
    if not members:
        raise ContractError("CMQ opcode enum is empty")
    return [(member.symbol, member.value) for member in members]


def _load_table(
    path: Path,
    header: str,
    columns: Sequence[str],
) -> list[dict[str, str]]:
    """功能：读取严格表头、列数和非空值的 TSV 文件并返回行映射。
    输入输出及副作用：只读 path，返回独立 dict 列表；注释/空行不进入结果。
    失败边界：表头重复、列数错误、空字段或重复数据行均抛 ContractError。"""
    lines = path.read_text(encoding="utf-8").splitlines()
    rows = [
        line.split("\t")
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    ]
    expected = list(columns)
    if not rows or rows[0] != expected:
        raise ContractError(f"{path}: unexpected TSV header")
    if any(row == expected for row in rows[1:]):
        raise ContractError(f"{path}: duplicate TSV header")
    data = rows[1:]
    if any(len(row) != len(expected) for row in data):
        raise ContractError(f"{path}: malformed TSV column count")
    if any(any(value == "" for value in row) for row in data):
        raise ContractError(f"{path}: empty TSV field")
    return [dict(zip(expected, row)) for row in data]


def load_ownership(path: Path) -> list[dict[str, str]]:
    """功能：加载 field_ownership.tsv 并保留 24 列 expanded anchor 记录。
    输入输出及副作用：返回逐行字典；不写表、不解析外部来源。
    失败边界：缺表、错误表头、错误列数或空值必须 fail-closed。"""
    rows = _load_table(path, OWNERSHIP_HEADER, OWNERSHIP_COLUMNS)
    if not rows:
        raise ContractError(f"{path}: ownership table is empty")
    return rows


def load_exclusions(path: Path) -> list[dict[str, str]]:
    """功能：加载 field_exclusions.tsv 的 reasoned macro exclusions。
    输入输出及副作用：返回逐行字典；只读输入，不补默认理由。
    失败边界：缺表、错误列数、空 macro 或空 reason 均抛 ContractError。"""
    rows = _load_table(path, EXCLUSION_HEADER, EXCLUSION_COLUMNS)
    if not rows:
        raise ContractError(f"{path}: exclusion table is empty")
    return rows


def load_capabilities(path: Path) -> list[dict[str, str]]:
    """功能：加载 CMQ capability 候选表并返回精确 driver symbol 行。
    输入输出及副作用：返回逐行字典；不按 XTRDMA 前缀筛选或改写 typo。
    失败边界：缺表、错误表头/列数或空值均抛 ContractError。"""
    rows = _load_table(path, CAPABILITY_HEADER, CAPABILITY_COLUMNS)
    if not rows:
        raise ContractError(f"{path}: capability table is empty")
    return rows


def load_mutations(path: Path) -> list[dict[str, str]]:
    """功能：加载逐 bit CMQ mutation evidence 报告。
    输入输出及副作用：返回逐行字典；不推导坐标、不生成缺失行。
    失败边界：缺表、错误表头/列数或空字段均抛 ContractError。"""
    rows = _load_table(path, MUTATION_HEADER, MUTATION_COLUMNS)
    if not rows:
        raise ContractError(f"{path}: mutation report is empty")
    return rows


def _function_body(source: str, function: str) -> str:
    """功能：从无注释 C 源中提取命名函数的完整 brace body。
    输入输出及副作用：返回函数体文本；不执行函数或展开宏。
    失败边界：函数不存在、声明不完整或花括号不平衡均抛 ContractError。"""
    match = re.search(
        r"(?:^|[;}])\s*(?:static\s+)?(?:inline\s+)?[^;{}]*\b"
        + re.escape(function)
        + r"\s*\([^;{}]*\)\s*\{",
        source,
    )
    if match is None:
        raise ContractError(f"source function missing: {function}")
    start = match.end()
    depth = 1
    index = start
    while depth and index < len(source):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    if depth:
        raise ContractError(f"source function body is unbalanced: {function}")
    return source[start:index - 1]


def resolve_source_anchor(
    source: str,
    function: str,
    token: str,
    occurrence: int,
) -> bool:
    """功能：在指定函数体中验证去注释 token 的唯一 occurrence。
    输入输出及副作用：成功返回 True；只读字符串，不写 source 文件。
    失败边界：零匹配、多匹配、非正 occurrence、函数缺失或注释-only token 均抛错。"""
    if occurrence < 1:
        raise ContractError("anchor occurrence must be positive")
    body = _function_body(_strip_comments(source), function)
    normalized_token = " ".join(token.split())
    compact_body = " ".join(body.split())
    matches = list(re.finditer(re.escape(normalized_token), compact_body))
    if len(matches) != occurrence:
        raise ContractError(
            f"anchor occurrence mismatch for {function}: "
            f"expected {occurrence}, got {len(matches)}"
        )
    return True


def validate_exclusion_reason(macro_name: str, reason: str) -> str:
    """功能：校验一个宏排除理由能够说明其未纳入当前闭合字段集合。
    输入输出及副作用：返回规范化后的理由；不修改 exclusion 表。
    失败边界：空理由、unused 或 not needed 等泛化文本均抛 ContractError。"""
    normalized = " ".join(reason.split()).strip()
    if not normalized or normalized.lower() in GENERIC_EXCLUSION_REASONS:
        raise ContractError(f"generic exclusion reason for {macro_name}")
    return normalized


def _anchor_values(row: Mapping[str, str]) -> tuple[str, ...]:
    """功能：提取 ownership 行的九个 anchor 列，统一检查 '-' 占位语义。
    输入输出及副作用：返回固定顺序字符串元组；不改变 row。
    失败边界：缺少列由调用方先拒绝；混合占位和真实值必须由 anchor 校验拒绝。"""
    return tuple(row.get(column, "") for column in ANCHOR_COLUMNS)


def _validate_anchor_shape(row: Mapping[str, str]) -> None:
    """功能：检查 macro-derived ownership 行的 anchor 列是否完整且可解析。
    输入输出及副作用：只读 row；成功无返回值。
    失败边界：仅允许整组 '-'（无适用 anchor）或九列全实值，数字/operation 非法均拒绝。"""
    values = _anchor_values(row)
    missing = [column for column, value in zip(ANCHOR_COLUMNS, values) if not value]
    if missing:
        raise ContractError(f"ownership anchor columns missing: {missing}")
    placeholders = [value == "-" for value in values]
    if any(placeholders) and not all(placeholders):
        raise ContractError("ownership anchor columns mix '-' and concrete values")
    if all(placeholders):
        return
    function, token, occurrence, container, buffer, operation, base, length, flow = values
    if not function or not token or not container or not buffer or not flow:
        raise ContractError("ownership anchor contains an empty concrete value")
    parsed_occurrence = _parse_int(occurrence, "anchor occurrence")
    if parsed_occurrence < 1:
        raise ContractError("anchor occurrence must be positive")
    if operation not in ALLOWED_OPERATIONS:
        raise ContractError(f"unsupported anchor operation {operation}")
    parsed_base = _parse_int(base, "anchor base")
    parsed_length = _parse_int(length, "anchor length")
    if parsed_base < 0 or parsed_length <= 0:
        raise ContractError("anchor base/length must be non-negative and non-zero")
    if container not in flow or buffer not in flow:
        raise ContractError("anchor target flow omits declared container/buffer")


def _row_coordinate(
    row: Mapping[str, str],
    macro: MacroDefinition | None,
    base_override: int | None = None,
):
    """功能：取得 ownership 行用于 overlap 检查的 (base,lsb,width) 坐标。
    输入输出及副作用：返回整数三元组；优先使用 C 宏解析结果，缺失时读取 anchor base。
    失败边界：无法解析任一坐标时抛 ContractError，禁止以字符串相等掩盖重叠。"""
    if base_override is not None and macro is not None:
        return base_override, macro.lsb, macro.width
    if macro is not None:
        base = _parse_int(row.get("anchor_base", "0"), "anchor base")
        return base, macro.lsb, macro.width
    base = _parse_int(row.get("anchor_base", "0"), "anchor base")
    length = _parse_int(row.get("anchor_length", "1"), "anchor length")
    return base, 0, length * 8


def _same_context(left: Mapping[str, str], right: Mapping[str, str]) -> bool:
    """功能：判断两 ownership 行是否属于同一 image/opcode/direction 坐标空间。
    输入输出及副作用：返回布尔值；只读行字段，不修改状态。
    失败边界：缺失上下文字段按空值比较，后续 schema 校验负责给出具体错误。"""
    keys = ("entry_kind", "opcode_or_variant", "direction")
    return all(left.get(key) == right.get(key) for key in keys)


def _validate_consumer(
    row: Mapping[str, str],
    sv_sources: Mapping[str, str] | None,
) -> None:
    """功能：确认 ownership 行声明的 owning_codec 在真实 SV consumer 中被引用。
    输入输出及副作用：只读 consumer 文本；成功无返回值。
    失败边界：缺 consumer、空 codec 或未发现类/方法引用均抛 ContractError。"""
    codec = row.get("owning_codec", "")
    if not codec or codec == "-":
        raise ContractError("ownership row omitted owning codec")
    if sv_sources is None:
        return
    joined = "\n".join(_strip_comments(source) for source in sv_sources.values())
    if codec not in joined:
        raise ContractError(f"owning codec consumer is missing: {codec}")
    entry = row.get("entry_kind")
    required = {
        "CMQ_SQE": ("compose_request", "compose_sqe"),
        "CMQ_CQE": ("inspect_completion", "inspect_cqe"),
        "CMQ_SQ_DOORBELL": ("encode_doorbell",),
    }.get(entry, ())
    if required and not any(token in joined for token in required):
        raise ContractError(f"consumer method is missing for {entry}: {codec}")


def validate_ownership_rows(
    rows: Sequence[Mapping[str, str]],
    macros: Mapping[str, MacroDefinition] | None = None,
    exclusions: Mapping[str, str] | Sequence[Mapping[str, str]] | None = None,
    sv_sources: Mapping[str, str] | None = None,
    coordinates: Mapping[tuple[str, str, str, str], int] | None = None,
) -> list[Mapping[str, str]]:
    """功能：校验 ownership 行的枚举、anchor、consumer、重叠和 writer 权限。
    输入输出及副作用：返回只读意义上的 rows 序列；不写 source、SV 或报告文件。
    失败边界：重复身份、非法 ownership/capability、未声明 overlap、越权 writer 或
    缺 consumer 均抛 ContractError。"""
    if not rows:
        raise ContractError("ownership table has no rows")
    macro_map = macros or {}
    coordinate_map = coordinates or {}
    seen: set[tuple[str, ...]] = set()
    for row in rows:
        missing = [column for column in OWNERSHIP_COLUMNS if column not in row]
        if missing:
            raise ContractError(f"ownership row missing columns: {missing}")
        identity = tuple(row[column] for column in (
            "archive_id", "source_path", "source_selector", "macro_name",
            "entry_kind", "opcode_or_variant", "direction",
            "model_field_or_raw_slice",
        ))
        if identity in seen:
            raise ContractError(f"duplicate ownership row: {identity}")
        seen.add(identity)
        if row["ownership"] not in OWNERSHIP_VALUES:
            raise ContractError(f"invalid ownership {row['ownership']}")
        if row["capability"] not in CAPABILITY_VALUES:
            raise ContractError(f"invalid field capability {row['capability']}")
        if row["direction"] not in VALID_DIRECTIONS:
            raise ContractError(f"invalid ownership direction {row['direction']}")
        if row["entry_kind"] not in VALID_ENTRY_KINDS:
            raise ContractError(f"invalid ownership entry kind {row['entry_kind']}")
        if not row["macro_name"] or row["macro_name"] == "-":
            raise ContractError("ownership row must name a C field macro")
        macro = macro_map.get(row["macro_name"])
        if macro is not None:
            actual = (macro.lsb, macro.width)
            declared = (
                _parse_int(row.get("anchor_token_lsb", str(macro.lsb)), "macro lsb"),
                _parse_int(row.get("anchor_token_width", str(macro.width)), "macro width"),
            )
            if actual != declared:
                raise ContractError(f"C field coordinate drift: {row['macro_name']}")
        _validate_anchor_shape(row)
        _validate_consumer(row, sv_sources)
        if row["ownership"] == "RESERVED_ZERO" and row["capability"] != "UNSUPPORTED":
            raise ContractError("reserved field cannot be supported")
        if row["direction"] == "REQUEST" and row["ownership"] in {
            "HW_TYPED", "HW_OPAQUE", "RESERVED_ZERO"
        } and row["capability"] == "SUPPORTED":
            raise ContractError("host encoder writes hardware/reserved field")
        if row["ownership"] == "HOST_FIXED" and not row["model_field_or_raw_slice"]:
            raise ContractError("HOST_FIXED field has no model field")

    for index, left in enumerate(rows):
        for right in rows[index + 1:]:
            if not _same_context(left, right):
                continue
            left_macro = macro_map.get(left["macro_name"])
            right_macro = macro_map.get(right["macro_name"])
            left_key = (
                left["entry_kind"], left["opcode_or_variant"], left["direction"],
                left["macro_name"],
            )
            right_key = (
                right["entry_kind"], right["opcode_or_variant"], right["direction"],
                right["macro_name"],
            )
            left_base, left_lsb, left_width = _row_coordinate(
                left, left_macro, coordinate_map.get(left_key)
            )
            right_base, right_lsb, right_width = _row_coordinate(
                right, right_macro, coordinate_map.get(right_key)
            )
            left_start = left_base * 8 + left_lsb
            right_start = right_base * 8 + right_lsb
            overlap = (
                left_start < right_start + right_width
                and right_start < left_start + left_width
            )
            if not overlap:
                continue
            group = left.get("overlay_group", "-")
            if group == "-" or group != right.get("overlay_group"):
                raise ContractError("undeclared ownership overlap")
            if not re.fullmatch(r"[A-Z][A-Z0-9_]*", group):
                raise ContractError(f"illegal overlay group {group}")
            if left.get("discriminator") != right.get("discriminator"):
                raise ContractError("overlay discriminator is not unique")
            for candidate in (left, right):
                discriminator = candidate.get("discriminator", "")
                if not re.fullmatch(r"[A-Z][A-Z0-9_]*", discriminator):
                    raise ContractError("overlay discriminator is missing or illegal")
    return list(rows)


def validate_macro_coverage(
    target_macros: Iterable[str],
    owned_macros: Iterable[str],
    exclusions: Mapping[str, str] | Iterable[str] | Sequence[Mapping[str, str]],
) -> None:
    """功能：确保每个目标 C 宏恰好进入 ownership 或有具体 exclusion 理由。
    输入输出及副作用：成功无返回值；只读集合和映射，不写 TSV。
    失败边界：重复 ownership/exclusion、两边同时出现或两边皆缺均抛 ContractError。"""
    targets = set(target_macros)
    owned = list(owned_macros)
    if len(owned) != len(set(owned)):
        raise ContractError("duplicate macro ownership")
    if isinstance(exclusions, Mapping):
        excluded_map = dict(exclusions)
    else:
        excluded_map: dict[str, str] = {}
        for item in exclusions:
            if isinstance(item, Mapping):
                name = str(item.get("macro_name", ""))
                reason = str(item.get("exclusion_reason", ""))
            else:
                name, reason = str(item), ""
            if name in excluded_map:
                raise ContractError(f"duplicate macro exclusion: {name}")
            excluded_map[name] = reason
    overlap = set(owned) & set(excluded_map)
    if overlap:
        raise ContractError(f"macro has both ownership and exclusion: {sorted(overlap)}")
    for name, reason in excluded_map.items():
        validate_exclusion_reason(name, reason)
    missing = targets - set(owned) - set(excluded_map)
    extra = (set(owned) | set(excluded_map)) - targets
    if missing:
        raise ContractError(f"target macro has neither ownership nor exclusion: {sorted(missing)}")
    if extra:
        raise ContractError(f"ownership/exclusion names unknown target macros: {sorted(extra)}")


def validate_oracle_case_references(
    rows: Sequence[Mapping[str, str]],
    case_ids: Iterable[str],
) -> None:
    """功能：校验 ownership/mutation 行的 oracle_case_id 引用存在且非空。
    输入输出及副作用：成功无返回值；只读 rows 与 case_ids。
    失败边界：除明确允许 '-' 的候选行外，未知 case ID 必须抛 ContractError。"""
    known = set(case_ids)
    for row in rows:
        case_id = row.get("oracle_case_id", "")
        if case_id != "-" and case_id not in known:
            raise ContractError(f"missing oracle case: {case_id}")


def _opcode_name(symbol: str) -> str:
    """功能：把驱动 enum symbol 映射为 capability 表中的短 opcode 名。
    输入输出及副作用：返回去掉 XTRDMA_OP_/TRDMA_OP_ 前缀的名称，不改写 typo 本体。
    失败边界：非驱动 opcode symbol 返回原字符串，调用方仍须校验 enum 成员身份。"""
    for prefix in ("XTRDMA_OP_", "TRDMA_OP_"):
        if symbol.startswith(prefix):
            return symbol[len(prefix):]
    return symbol


def _as_flag(value: str, label: str) -> int:
    """功能：解析 capability/mutation 中的二值标志。
    输入输出及副作用：返回 0 或 1；只读字符串。
    失败边界：任何非 0/1 文本、空值或额外位均抛 ContractError。"""
    if value not in {"0", "1"}:
        raise ContractError(f"{label} must be 0 or 1")
    return int(value)


def validate_capability_rows(
    rows: Sequence[Mapping[str, str]],
    enum_members: Sequence[tuple[str, int]] | None = None,
) -> list[Mapping[str, str]]:
    """功能：校验 enum capability 的完整双向记录、阻断原因和禁用位。
    输入输出及副作用：返回 rows 的独立列表；不注册 opcode、不启用 encoder。
    失败边界：缺失/重复成员、MAX 被执行、拼写过滤、unsupported 方向置位或 blocker 漂移均拒绝。"""
    if not rows:
        raise ContractError("capability table has no rows")
    members = list(enum_members or [])
    executable = [(symbol, value) for symbol, value in members
                  if symbol != "XTRDMA_OP_MAX"]
    expected_keys = {
        (symbol, direction)
        for symbol, _ in executable
        for direction in VALID_DIRECTIONS
    }
    seen: set[tuple[str, str]] = set()
    for row in rows:
        missing = [column for column in CAPABILITY_COLUMNS if column not in row]
        if missing:
            raise ContractError(f"capability row missing columns: {missing}")
        direction = row["direction"]
        if direction not in VALID_DIRECTIONS:
            raise ContractError(f"invalid capability direction {direction}")
        _as_flag(row["registered"], "registered")
        request = _as_flag(row["request_encodable"], "request_encodable")
        response = _as_flag(row["response_decodable"], "response_decodable")
        symbol = row["driver_symbol"]
        if symbol == "-":
            if row["opcode"] != "CMQ_SQ_DOORBELL" or row["opcode_value"] != "-":
                raise ContractError("synthetic capability has invalid driver columns")
            key = ("CMQ_SQ_DOORBELL", direction)
            if key in seen:
                raise ContractError("duplicate synthetic capability")
            seen.add(key)
            if direction != "REQUEST" or row["registered"] != "1":
                raise ContractError("CMQ doorbell capability must be registered request")
            if request or response:
                raise ContractError("CMQ doorbell capability is not executable in Task 4")
            if row["oracle_case_id"] != "cmq_sq_doorbell":
                raise ContractError("CMQ doorbell oracle case drift")
            if row["owning_codec"] != "rdma_hw_cmq_hw_profile":
                raise ContractError("CMQ doorbell owning codec drift")
            if row["blocker"] != "MISSING_PRODUCTION_PATH_EVIDENCE":
                raise ContractError("CMQ doorbell blocker drift")
            continue
        member = next((item for item in executable if item[0] == symbol), None)
        if member is None:
            raise ContractError(f"capability symbol is not an enum member: {symbol}")
        key = (symbol, direction)
        if key in seen:
            raise ContractError(f"duplicate capability row: {symbol}/{direction}")
        seen.add(key)
        expected_name = _opcode_name(symbol)
        if row["opcode"] != expected_name:
            raise ContractError(f"capability opcode spelling drift: {symbol}")
        if _parse_int(row["opcode_value"], "opcode value") != member[1]:
            raise ContractError(f"capability opcode value drift: {symbol}")
        if row["registered"] != "1":
            raise ContractError(f"registered enum member marked unregistered: {symbol}")
        if request or response:
            raise ContractError("Task 4 capability cannot enable production path")
        expected_case = "-"
        if symbol == "XTRDMA_OP_QPC_CREATE" and direction == "REQUEST":
            expected_case = "cmq_sqe_qpc_create_request"
        elif symbol == "XTRDMA_OP_QPC_CREATE" and direction == "RESPONSE":
            expected_case = "cmq_cqe_qpc_create_response"
        elif symbol == "XTRDMA_OP_CQC_CREATE" and direction == "REQUEST":
            expected_case = "cmq_sqe_cqc_create_request"
        if row["oracle_case_id"] != expected_case:
            raise ContractError(f"capability oracle case drift: {symbol}/{direction}")
        if symbol == "XTRDMA_OP_CQC_CREATE" and direction == "REQUEST":
            expected_blocker = "CONTEXT_EMBED_BASE_MISMATCH"
        elif symbol == "XTRDMA_OP_QPC_CREATE" and direction in VALID_DIRECTIONS:
            expected_blocker = "MISSING_PRODUCTION_PATH_EVIDENCE"
        else:
            expected_blocker = "MISSING_CLOSED_EVIDENCE"
        if row["blocker"] != expected_blocker:
            raise ContractError(f"capability blocker drift: {symbol}/{direction}")
        codec = row["owning_codec"]
        if not codec or codec == "-":
            raise ContractError(f"capability owning codec missing: {symbol}/{direction}")
    if enum_members:
        if seen != expected_keys and seen - {("CMQ_SQ_DOORBELL", "REQUEST")} != expected_keys:
            missing = expected_keys - seen
            extra = seen - expected_keys - {("CMQ_SQ_DOORBELL", "REQUEST")}
            raise ContractError(f"capability enum coverage mismatch: missing={missing} extra={extra}")
    return list(rows)


def cqe_driver_result(
    owner: int,
    expected_owner: int,
    request_index_changed: int,
    wrap_mismatch: int,
    opcode_mismatch: int,
    ecode_error: int,
) -> str:
    """功能：按驱动 READY→LOOKUP→WRAP→OPCODE→ECODE 顺序重放 CQE 结果分类。
    输入输出及副作用：返回独立 driver_result_class；不生成 model status 或修改 CQE。
    失败边界：owner 未就绪优先于后续错误，随后按参数顺序返回唯一分类。"""
    if owner != expected_owner:
        return "NOT_READY"
    if request_index_changed:
        return "REQUEST_LOOKUP_CHANGED"
    if wrap_mismatch:
        return "WRAP_MISMATCH"
    if opcode_mismatch:
        return "OPCODE_MISMATCH"
    if ecode_error:
        return "ECODE_ERROR"
    return "READY_OK"


def model_outcome(owner: int, expected_owner: int, opcode: int) -> tuple[str, int]:
    """功能：给出 raw completion codec 的 owner/ready 分层结果。
    输入输出及副作用：返回 (model_status, ready)，不写 driver request_error。
    失败边界：owner 不匹配返回 OK/0；未知 opcode 返回 UNSUPPORTED_OPCODE/0。"""
    if owner != expected_owner:
        return "OK", 0
    if opcode not in {0, 1, 2, 3, 4, 5, 6, 9, 0x0A, 0x0C, 0x0E, 0x0F, 0x10,
                      0x12, 0x13, 0x14, 0x16, 0x17, 0x35, 0x37, 0x38,
                      0x1C, 0x3A, 0x46, 0x47}:
        return "UNSUPPORTED_OPCODE", 0
    return "OK", 1


def validate_polarity_group(fields: Iterable[str]) -> bool:
    """功能：确认 QPC VALID/WRAP correlation 由恰好两行共同描述。
    输入输出及副作用：返回是否等于 {'valid','wrap'}；不改变 mutation rows。
    失败边界：独立一位、额外字段或缺失字段均返回 False。"""
    return set(fields) == {"valid", "wrap"}


def _parse_coordinate(value: str, label: str, upper: int | None = None) -> int:
    """功能：解析 mutation 坐标并执行可选上界检查。
    输入输出及副作用：返回非负整数；不修改 mutation 行。
    失败边界：负数、非整数或超过给定上界时抛 ContractError。"""
    parsed = _parse_int(value, label)
    if parsed < 0 or (upper is not None and parsed > upper):
        raise ContractError(f"{label} is outside allowed range: {value}")
    return parsed


def _validate_static_mutation(row: Mapping[str, str]) -> None:
    """功能：校验 static evidence 行不携带可执行状态或非零 delta。
    输入输出及副作用：只读 row；成功无返回值。
    失败边界：静态行若 status/ready 非 '-' 或 delta 非零即拒绝。"""
    if row["expected_status_code"] != "-" or row["expected_ready"] != "-":
        raise ContractError("static mutation row must not publish model status")
    if row["expected_value_delta"] != "0":
        raise ContractError("static mutation row has nonzero value delta")


def _validate_evidence_pair(row: Mapping[str, str]) -> None:
    """功能：执行 evidence_mode 与 driver_result_class 的精确配对校验。
    输入输出及副作用：只读 row；成功无返回值。
    失败边界：任何未列入冻结 pairing 的组合均抛 ContractError。"""
    mode = row["evidence_mode"]
    result = row["driver_result_class"]
    if mode not in EVIDENCE_VALUES or result not in DRIVER_RESULT_VALUES:
        raise ContractError("unknown mutation evidence or driver result class")
    expected = {
        "TYPED_RECOMPOSE": {"ENCODED"},
        "CORRELATED_RECOMPOSE": {"ENCODED"},
        "DRIVER_FIXED_REJECT": {"FIXED_ZERO"},
        "STATIC_CANONICAL": {"STATIC_CANONICAL"},
        "STATIC_UNWRITABLE": {"STATIC_UNWRITABLE"},
        "RAW_DECODE_MUTATION": RAW_DRIVER_RESULTS,
    }[mode]
    if result not in expected:
        raise ContractError(f"mutation evidence/result pairing drift: {mode}/{result}")
    if mode in STATIC_EVIDENCE:
        _validate_static_mutation(row)


def _validate_mutation_semantics(
    row: Mapping[str, str],
    layout: Mapping[str, object],
) -> None:
    """功能：校验 mutation 行的 case 身份、consumer 和字段语义闭合关系。
    输入输出及副作用：只读一行及其冻结 case layout；成功无返回值，不执行编解码器。
    失败边界：entry/opcode/direction、oracle case、consumer、字段分类、状态、结果或
    delta 与四种 Phase 0 case 契约不一致时抛出 ContractError。"""
    case_id = row["case_id"]
    expected_identity = {
        "entry": str(layout["entry"]),
        "opcode": str(layout["opcode"]),
        "direction": str(layout["direction"]),
    }
    for column, expected in expected_identity.items():
        if row[column] != expected:
            raise ContractError(
                f"mutation {case_id} {column} identity drift: "
                f"{row[column]} != {expected}"
            )
    if row["oracle_case_id"] != case_id:
        raise ContractError(f"mutation oracle case drift: {case_id}")

    expected_consumer = {
        "CMQ_SQE": "CMQ_REQUEST_COMPOSER",
        "CMQ_CQE": "CMQ_COMPLETION_CODEC",
        "CMQ_SQ_DOORBELL": "CMQ_DOORBELL_ENCODER",
    }[str(layout["entry"])]
    if row["model_consumer"] != expected_consumer:
        raise ContractError(f"mutation model consumer drift: {case_id}")

    def require(expected: Mapping[str, str]) -> None:
        """功能：逐列比对一行 mutation 的冻结语义期望。
        输入输出及副作用：只读 row/expected；成功无返回值，不改变 caller 映射。
        失败边界：任一 evidence、class、outcome、status、ready、delta 或 correlation
        列漂移即抛 ContractError，并标明具体列。"""
        for column, value in expected.items():
            if row[column] != value:
                raise ContractError(
                    f"mutation {case_id} {column} drift: "
                    f"{row[column]} != {value}"
                )

    if case_id == "cmq_sqe_qpc_create_request":
        contracts = {
            "valid": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "CORRELATED_RECOMPOSE",
                "correlation_group": "QPC_POLARITY_VALID_WRAP",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "wrap": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "CORRELATED_RECOMPOSE",
                "correlation_group": "QPC_POLARITY_VALID_WRAP",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "index": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "qpn": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "sq_cqn": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "rq_cqn": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "qpc_buffer_addr_pa": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "signature": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "correlation_group": "-",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "vf_id_override": {
                "expected_class": "HOST_FIXED",
                "evidence_mode": "DRIVER_FIXED_REJECT",
                "correlation_group": "-",
                "driver_result_class": "FIXED_ZERO",
                "expected_outcome": "REJECT",
                "expected_status_code": "INVALID_ARGUMENT",
                "expected_ready": "0",
                "expected_value_delta": "1",
            },
            "use_vfid": {
                "expected_class": "HOST_FIXED",
                "evidence_mode": "DRIVER_FIXED_REJECT",
                "correlation_group": "-",
                "driver_result_class": "FIXED_ZERO",
                "expected_outcome": "REJECT",
                "expected_status_code": "INVALID_ARGUMENT",
                "expected_ready": "0",
                "expected_value_delta": "1",
            },
            "opcode": {
                "expected_class": "HOST_FIXED",
                "evidence_mode": "STATIC_CANONICAL",
                "correlation_group": "-",
                "driver_result_class": "STATIC_CANONICAL",
                "expected_outcome": "CANONICAL",
                "expected_status_code": "-",
                "expected_ready": "-",
                "expected_value_delta": "0",
            },
            "sign_en": {
                "expected_class": "HOST_FIXED",
                "evidence_mode": "STATIC_CANONICAL",
                "correlation_group": "-",
                "driver_result_class": "STATIC_CANONICAL",
                "expected_outcome": "CANONICAL",
                "expected_status_code": "-",
                "expected_ready": "-",
                "expected_value_delta": "0",
            },
            "-": {
                "expected_class": "RESERVED_ZERO",
                "evidence_mode": "STATIC_UNWRITABLE",
                "correlation_group": "-",
                "driver_result_class": "STATIC_UNWRITABLE",
                "expected_outcome": "REJECT",
                "expected_status_code": "-",
                "expected_ready": "-",
                "expected_value_delta": "0",
            },
        }
        expected = contracts.get(row["expected_field"])
        if expected is None:
            raise ContractError(
                f"unknown QPC request mutation field: {row['expected_field']}"
            )
        require(expected)
        return

    if case_id == "cmq_cqe_qpc_create_response":
        response_contracts = {
            "owner": {
                "expected_class": "HW_TYPED",
                "driver_result_class": "NOT_READY",
                "expected_outcome": "NOT_READY",
                "expected_status_code": "OK",
                "expected_ready": "0",
            },
            "index": {
                "expected_class": "HW_TYPED",
                "driver_result_class": "REQUEST_LOOKUP_CHANGED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
            },
            "wrap": {
                "expected_class": "HW_TYPED",
                "driver_result_class": "WRAP_MISMATCH",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
            },
            "opcode": {
                "expected_class": "HW_TYPED",
                "driver_result_class": "OPCODE_MISMATCH",
            },
            "ecode": {
                "expected_class": "HW_TYPED",
                "driver_result_class": "ECODE_ERROR",
                "expected_outcome": "PUBLISH_ECODE",
                "expected_status_code": "OK",
                "expected_ready": "1",
            },
            "-": {
                "expected_class": "RESERVED_ZERO",
                "driver_result_class": "READY_OK",
                "expected_outcome": "REJECT",
                "expected_status_code": "CODEC_ERROR",
                "expected_ready": "0",
            },
        }
        expected = response_contracts.get(row["expected_field"])
        if expected is None:
            raise ContractError(
                f"unknown QPC response mutation field: {row['expected_field']}"
            )
        expected = dict(expected)
        expected.update({
            "evidence_mode": "RAW_DECODE_MUTATION",
            "correlation_group": "-",
            "expected_value_delta": "1",
        })
        if row["expected_field"] == "opcode":
            status = row["expected_status_code"]
            if status == "OK":
                expected.update({"expected_outcome": "ACCEPT", "expected_ready": "1"})
            elif status == "UNSUPPORTED_OPCODE":
                expected.update({"expected_outcome": "REJECT", "expected_ready": "0"})
            else:
                raise ContractError("QPC response opcode status is invalid")
        require(expected)
        return

    if case_id == "cmq_sq_doorbell":
        contracts = {
            "pi": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "polarity": {
                "expected_class": "HOST_TYPED",
                "evidence_mode": "TYPED_RECOMPOSE",
                "driver_result_class": "ENCODED",
                "expected_outcome": "ACCEPT",
                "expected_status_code": "OK",
                "expected_ready": "1",
                "expected_value_delta": "1",
            },
            "-": {
                "expected_class": "RESERVED_ZERO",
                "evidence_mode": "STATIC_UNWRITABLE",
                "driver_result_class": "STATIC_UNWRITABLE",
                "expected_outcome": "REJECT",
                "expected_status_code": "-",
                "expected_ready": "-",
                "expected_value_delta": "0",
            },
        }
        expected = contracts.get(row["expected_field"])
        if expected is None:
            raise ContractError(
                f"unknown doorbell mutation field: {row['expected_field']}"
            )
        expected = dict(expected)
        expected["correlation_group"] = "-"
        require(expected)
        return

    raise ContractError(f"unsupported mutation case: {case_id}")


def validate_mutation_rows(
    rows: Sequence[Mapping[str, str]],
) -> list[Mapping[str, str]]:
    """功能：校验 mutation 行的坐标、证据配对、状态分层和 correlation 约束。
    输入输出及副作用：返回 rows 的独立列表；不调用 SV、C 编码器或修改 artifact。
    失败边界：非法列/坐标、静态行发布状态、opaque 丢失 raw delta、跨层合并和
    单行 polarity group 均抛 ContractError。"""
    if not rows:
        raise ContractError("mutation report has no rows")
    seen: set[tuple[str, int, int]] = set()
    groups: defaultdict[str, list[Mapping[str, str]]] = defaultdict(list)
    for row in rows:
        missing = [column for column in MUTATION_COLUMNS if column not in row]
        if missing:
            raise ContractError(f"mutation row missing columns: {missing}")
        layout = CASE_LAYOUTS.get(row["case_id"])
        if layout is None:
            raise ContractError(f"unsupported mutation case: {row['case_id']}")
        case_length = int(layout["length"])
        qword = _parse_coordinate(
            row["qword_index"], "qword index", case_length // 8 - 1
        )
        bit = _parse_coordinate(row["bit_index"], "bit index", 63)
        byte = _parse_coordinate(
            row["byte_offset"], "byte offset", case_length - 1
        )
        expected_byte = 8 * qword + 7 - (bit // 8)
        if byte != expected_byte:
            raise ContractError("mutation byte coordinate drift")
        key = (row["case_id"], qword, bit)
        if key in seen:
            raise ContractError(f"duplicate mutation coordinate: {key}")
        seen.add(key)
        if row["direction"] not in VALID_DIRECTIONS:
            raise ContractError(f"invalid mutation direction {row['direction']}")
        if row["entry"] not in VALID_ENTRY_KINDS:
            raise ContractError(f"invalid mutation entry {row['entry']}")
        if row["expected_class"] not in OWNERSHIP_VALUES:
            raise ContractError(f"invalid mutation expected class {row['expected_class']}")
        if row["model_consumer"] not in VALID_MODEL_CONSUMERS:
            raise ContractError(f"invalid model consumer {row['model_consumer']}")
        _validate_evidence_pair(row)
        delta = _parse_coordinate(row["expected_value_delta"], "value delta")
        if row["evidence_mode"] not in STATIC_EVIDENCE and delta != 1:
            raise ContractError("executed mutation value delta must be one")
        if row["evidence_mode"] in STATIC_EVIDENCE and delta != 0:
            raise ContractError("static mutation value delta must be zero")
        if row["expected_class"] == "HW_OPAQUE" and row["expected_outcome"] in {
            "DROP", "REJECT"
        }:
            raise ContractError("opaque mutation drops raw value delta")
        _validate_mutation_semantics(row, layout)
        group = row["correlation_group"]
        if group != "-":
            if group != "QPC_POLARITY_VALID_WRAP":
                raise ContractError(f"illegal correlation group {group}")
            groups[group].append(row)
    for group, grouped in groups.items():
        if len(grouped) != 2 or not validate_polarity_group(
            row["expected_field"] for row in grouped
        ):
            raise ContractError(f"correlation group is not exactly VALID/WRAP pair: {group}")
        if any(row["evidence_mode"] != "CORRELATED_RECOMPOSE" for row in grouped):
            raise ContractError("polarity group must use CORRELATED_RECOMPOSE")
    return list(rows)


def validate_mutation_report(
    rows: Sequence[Mapping[str, str]],
    expected_counts: Mapping[str, int] | None = None,
) -> dict[str, int]:
    """功能：检查完整 mutation report 的固定总量、执行量和 evidence counts。
    输入输出及副作用：返回实际计数映射；只读 rows，不生成或覆盖报告。
    失败边界：总行数、case 分配、执行/静态计数或任一 mode count 漂移均抛错。"""
    validate_mutation_rows(rows)
    counts = Counter(row["evidence_mode"] for row in rows)
    summary = {
        "TYPED_RECOMPOSE": counts.get("TYPED_RECOMPOSE", 0),
        "CORRELATED_RECOMPOSE": counts.get("CORRELATED_RECOMPOSE", 0),
        "DRIVER_FIXED_REJECT": counts.get("DRIVER_FIXED_REJECT", 0),
        "RAW_DECODE_MUTATION": counts.get("RAW_DECODE_MUTATION", 0),
        "STATIC_CANONICAL": counts.get("STATIC_CANONICAL", 0),
        "STATIC_UNWRITABLE": counts.get("STATIC_UNWRITABLE", 0),
    }
    summary["EXECUTED_TOTAL"] = sum(
        summary[key] for key in (
            "TYPED_RECOMPOSE", "CORRELATED_RECOMPOSE", "DRIVER_FIXED_REJECT",
            "RAW_DECODE_MUTATION",
        )
    )
    summary["STATIC_TOTAL"] = summary["STATIC_CANONICAL"] + summary["STATIC_UNWRITABLE"]
    summary["GRAND_TOTAL"] = len(rows)
    frozen = {
        "TYPED_RECOMPOSE": 140,
        "CORRELATED_RECOMPOSE": 2,
        "DRIVER_FIXED_REJECT": 12,
        "RAW_DECODE_MUTATION": 512,
        "STATIC_CANONICAL": 9,
        "STATIC_UNWRITABLE": 413,
        "EXECUTED_TOTAL": 666,
        "STATIC_TOTAL": 422,
        "GRAND_TOTAL": 1088,
    }
    expected = dict(frozen)
    if expected_counts:
        expected.update(expected_counts)
    if any(summary[key] != expected[key] for key in expected):
        raise ContractError(
            "mutation report counts drift: "
            f"actual={summary} expected={expected}"
        )
    case_counts = Counter(row["case_id"] for row in rows)
    if case_counts != Counter({
        "cmq_sqe_qpc_create_request": 512,
        "cmq_cqe_qpc_create_response": 512,
        "cmq_sq_doorbell": 64,
    }):
        raise ContractError(f"mutation case counts drift: {case_counts}")
    return summary


def _manifest_records(kernel_root: Path, manifest_path: Path, archive_id: str):
    """功能：读取 manifest 并验证锁定 archive 身份、来源文件摘要和路径安全。
    输入输出及副作用：返回 path 到 manifest records 的映射；只读外部源码。
    失败边界：archive ID 不符、文件缺失或 SHA-256 漂移均抛 ContractError。"""
    records = load_source_manifest(manifest_path)
    by_path: dict[str, list[object]] = defaultdict(list)
    for record in records:
        if record.archive_id != archive_id:
            raise ContractError("source manifest archive ID does not match archive lock")
        source = kernel_root / record.path
        if not source.is_file():
            raise ContractError(f"manifest source is missing: {record.path}")
        if _sha256(source) != record.sha256:
            raise ContractError(f"manifest source hash mismatch: {record.path}")
        by_path[record.path].append(record)
    return by_path


def _validate_identity_rows(
    rows: Sequence[Mapping[str, str]],
    records_by_path: Mapping[str, Sequence[object]],
    archive_id: str,
) -> None:
    """功能：把 ownership/exclusion 前四列重建为 manifest 四元组并精确命中。
    输入输出及副作用：成功无返回值；只读表行和 manifest records。
    失败边界：不存在的 selector/hash、错误 archive ID 或重复 identity 均抛错。"""
    known = {
        (record.archive_id, record.path, record.selector, record.sha256)
        for values in records_by_path.values()
        for record in values
    }
    for row in rows:
        identity = tuple(row.get(column, "") for column in (
            "archive_id", "source_path", "source_selector", "source_sha256"
        ))
        if identity not in known or identity[0] != archive_id:
            raise ContractError(f"source identity is not locked: {identity}")


def _read_sv_sources(root: Path) -> dict[str, str]:
    """功能：读取 SV consumer 文本供 owning_codec 引用校验。
    输入输出及副作用：返回相对路径到 UTF-8 文本；只读 root，不生成缓存。
    失败边界：root 缺失、非文件或不可解码源码均抛 ContractError。"""
    if not root.is_dir():
        raise ContractError(f"SV root is missing: {root}")
    sources: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in {".sv", ".svh"}:
            continue
        try:
            sources[str(path.relative_to(root))] = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise ContractError(f"SV source is not UTF-8: {path}") from exc
    if not sources:
        raise ContractError(f"SV root has no source files: {root}")
    return sources


def _discover_macros(
    kernel_root: Path,
    records_by_path: Mapping[str, Sequence[object]],
    oracle_source: Path | None = None,
    anchor_rows: Sequence[Sequence[str]] | None = None,
) -> dict[str, MacroDefinition]:
    """功能：从锁定 headers 解析字段宏，并收集四个 C oracle 使用的目标成员。
    输入输出及副作用：返回目标宏定义映射；不读取 SV 常量或模型 mask。
    失败边界：同名定义漂移、目标宏找不到或表达式非法均抛 ContractError。"""
    all_macros: dict[str, MacroDefinition] = {}
    for relative_path in sorted(records_by_path):
        source = kernel_root / relative_path
        parsed = parse_macro_definitions(
            source.read_text(encoding="utf-8"), relative_path
        )
        for name, definition in parsed.items():
            previous = all_macros.get(name)
            if previous is not None and (
                previous.lsb != definition.lsb or previous.width != definition.width
            ):
                raise ContractError(f"C macro definition drift: {name}")
            all_macros[name] = definition
    used: set[str] = set()
    if oracle_source is not None and oracle_source.is_file():
        used.update(re.findall(
            r"\bXTRDMA_[A-Z0-9_]+\b",
            _strip_comments(oracle_source.read_text(encoding="utf-8")),
        ))
    for row in anchor_rows or ():
        used.update(re.findall(r"\bXTRDMA_[A-Z0-9_]+\b", " ".join(row)))
    targets = {
        name for name, definition in all_macros.items()
        if definition.source_path == "cmq.h" and name.startswith("XTRDMA_CMQ")
    }
    unresolved_used = {
        name for name in used
        if name.startswith("XTRDMA_CMQ") and name not in all_macros
    }
    unresolved_fields = {
        name for name in unresolved_used
        if any(token in name for token in ("WQE", "DB_", "OPCODE", "ECODE"))
    }
    if unresolved_fields:
        raise ContractError(f"oracle uses unresolved target macros: {sorted(unresolved_fields)}")
    if not targets:
        raise ContractError("C oracle has no target field macros")
    return {name: all_macros[name] for name in sorted(targets)}


def _validate_concrete_anchors(
    rows: Sequence[Mapping[str, str]],
    kernel_root: Path,
    records_by_path: Mapping[str, Sequence[object]],
) -> None:
    """功能：验证 ownership 行 concrete anchors 的函数、token、buffer 和 data-flow。
    输入输出及副作用：只读锁定 C 文件；成功无返回值。
    失败边界：零/多匹配、注释-only、错误 operation 或错误 buffer flow 均拒绝。"""
    cache: dict[str, str] = {}
    for row in rows:
        values = _anchor_values(row)
        if all(value == "-" for value in values):
            continue
        source_path = row["source_path"]
        if source_path not in records_by_path:
            raise ContractError(f"anchor source is not in manifest: {source_path}")
        source = cache.setdefault(
            source_path,
            _strip_comments((kernel_root / source_path).read_text(encoding="utf-8")),
        )
        occurrence = _parse_int(row["anchor_occurrence"], "anchor occurrence")
        resolve_source_anchor(
            source,
            row["anchor_function"],
            row["anchor_token"],
            occurrence,
        )
        body = _function_body(source, row["anchor_function"])
        normalized = " ".join(body.split())
        if row["anchor_container"] not in normalized:
            raise ContractError("anchor container is absent from function body")
        if row["anchor_buffer"] not in normalized:
            raise ContractError("anchor buffer is absent from function body")
        if row["anchor_operation"] not in ALLOWED_OPERATIONS:
            raise ContractError(f"unsupported anchor operation {row['anchor_operation']}")
        if "->" not in row["anchor_target_flow"]:
            raise ContractError("anchor target flow is not a data-flow chain")


def _cmq_manifest_record(records_by_path: Mapping[str, Sequence[object]]):
    """功能：选择 cmq.h 中覆盖 XTRDMA_CMQ* 字段族的唯一 manifest row。
    输入输出及副作用：返回 manifest record 引用；不修改来源列表。
    失败边界：选择器缺失或重复时抛 ContractError，禁止猜测相邻 selector。"""
    matches = [
        record for record in records_by_path.get("cmq.h", ())
        if record.selector == "XTRDMA_CMQ*|XTRDMA_OP_*"
    ]
    if len(matches) != 1:
        raise ContractError("CMQ field-family manifest identity is not unique")
    return matches[0]


def _ownership_base(
    record: object,
    macro_name: str,
    entry: str,
    opcode: str,
    direction: str,
    ownership: str,
    capability: str,
    model_field: str,
    codec: str,
    case_id: str,
) -> dict[str, str]:
    """功能：构造一条 macro-derived ownership row 的冻结列值。
    输入输出及副作用：返回新字典；anchor 不适用列统一为 '-'，不写表。
    失败边界：调用方必须传入已验证 manifest record 与允许枚举，后续 validator 复核。"""
    row = {
        "archive_id": record.archive_id,
        "source_path": record.path,
        "source_selector": record.selector,
        "source_sha256": record.sha256,
        "macro_name": macro_name,
        "entry_kind": entry,
        "opcode_or_variant": opcode,
        "direction": direction,
        "ownership": ownership,
        "capability": capability,
        "model_field_or_raw_slice": model_field,
        "owning_codec": codec,
        "overlay_group": "-",
        "discriminator": "-",
        "oracle_case_id": case_id,
    }
    for column in ANCHOR_COLUMNS:
        row[column] = "-"
    return row


def build_expected_ownership(
    records_by_path: Mapping[str, Sequence[object]],
) -> list[dict[str, str]]:
    """功能：构造四个 Task 3 case 所需字段的 canonical ownership rows。
    输入输出及副作用：返回新列表；只使用 manifest identity 和显式模型字段语义。
    失败边界：CMQ manifest selector 不唯一时拒绝，不回退到其他 source row。"""
    record = _cmq_manifest_record(records_by_path)
    rows: list[dict[str, str]] = []
    qpc_model_fields = {
        "valid": "envelope.valid",
        "vf_id_override": "envelope.vfid_override",
        "use_vfid": "envelope.use_vfid",
        "wrap": "envelope.wrap",
        "index": "envelope.wqe_index",
        "opcode": "envelope.opcode",
        "qpn": "body.qp_h.object_id",
        "rq_cqn": "body.recv_cq_h.object_id",
        "sign_en": "QPC_CREATE constant 1",
        "signature": "computed signature",
        "sq_cqn": "body.send_cq_h.object_id",
        "qpc_buffer_addr_pa": "body.qpc_buffer.value >> 9",
    }
    for field, macro in CASE_FIELD_MACROS["cmq_sqe_qpc_create_request"].items():
        ownership, _, mode = QPC_REQUEST_POLICY[field]
        capability = (
            "SUPPORTED"
            if mode in {"TYPED_RECOMPOSE", "CORRELATED_RECOMPOSE"}
            else "UNSUPPORTED"
        )
        rows.append(_ownership_base(
            record, macro, "CMQ_SQE", "QPC_CREATE", "REQUEST",
            ownership, capability, qpc_model_fields[field],
            "rdma_hw_cmq_request_composer", "cmq_sqe_qpc_create_request",
        ))
    cqc_model_fields = {
        "valid": "envelope.valid",
        "vf_id_override": "envelope.vfid_override",
        "use_vfid": "envelope.use_vfid",
        "wrap": "envelope.wrap",
        "index": "envelope.wqe_index",
        "opcode": "envelope.opcode",
        "cqn": "context.cqn",
    }
    for field, macro in CQC_REQUEST_FIELDS.items():
        ownership = "HOST_FIXED" if field in {
            "vf_id_override", "use_vfid", "opcode"
        } else "HOST_TYPED"
        rows.append(_ownership_base(
            record, macro, "CMQ_SQE", "CQC_CREATE", "REQUEST",
            ownership, "UNSUPPORTED", cqc_model_fields[field],
            "rdma_hw_cmq_request_composer", "cmq_sqe_cqc_create_request",
        ))
    response_fields = dict(CASE_FIELD_MACROS["cmq_cqe_qpc_create_response"])
    response_fields.update({
        "vf_id_override": "XTRDMA_CMQSQ_VFID_OVERRIDE",
        "use_vfid": "XTRDMA_CMQSQ_USE_VFID",
    })
    response_model_fields = {
        "valid": "completion.owner",
        "wrap": "completion.wrap",
        "index": "completion.wqe_index",
        "opcode": "completion.opcode",
        "ecode": "completion.command_ecode",
        "vf_id_override": "reserved[59]",
        "use_vfid": "reserved[58:48]",
    }
    for field, macro in response_fields.items():
        ownership = "HW_TYPED" if field in RESPONSE_TYPED_FIELDS else "RESERVED_ZERO"
        capability = "SUPPORTED" if ownership == "HW_TYPED" else "UNSUPPORTED"
        rows.append(_ownership_base(
            record, macro, "CMQ_CQE", "QPC_CREATE", "RESPONSE",
            ownership, capability, response_model_fields[field],
            "rdma_hw_cmq_completion_codec", "cmq_cqe_qpc_create_response",
        ))
    for field, macro in CASE_FIELD_MACROS["cmq_sq_doorbell"].items():
        model_field = "model.pi" if field == "pi_after" else "model.polarity"
        rows.append(_ownership_base(
            record, macro, "CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST",
            "HOST_TYPED", "SUPPORTED", model_field,
            "rdma_hw_cmq_hw_profile", "cmq_sq_doorbell",
        ))
    return rows


def build_expected_exclusions(
    records_by_path: Mapping[str, Sequence[object]],
    target_macros: Iterable[str],
    ownership_rows: Sequence[Mapping[str, str]],
) -> list[dict[str, str]]:
    """功能：为未进入四 case ownership 的每个 CMQ 字段宏构造 reasoned exclusion。
    输入输出及副作用：返回新行列表；不修改 target/ownership 集合。
    失败边界：manifest identity 缺失或同一宏重复 ownership 由调用方 validator 拒绝。"""
    record = _cmq_manifest_record(records_by_path)
    owned = {row["macro_name"] for row in ownership_rows}
    reason = "outside the four Task 3 Phase 0 CMQ case directions"
    return [
        {
            "archive_id": record.archive_id,
            "source_path": record.path,
            "source_selector": record.selector,
            "source_sha256": record.sha256,
            "macro_name": macro,
            "exclusion_reason": reason,
        }
        for macro in sorted(set(target_macros) - owned)
    ]


def _compare_rows(
    actual: Sequence[Mapping[str, str]],
    expected: Sequence[Mapping[str, str]],
    columns: Sequence[str],
    identity_columns: Sequence[str],
    label: str,
) -> None:
    """功能：按稳定 identity 建索引并逐列比较 canonical TSV rows。
    输入输出及副作用：成功无返回值；不排序或改写输入行。
    失败边界：重复/缺失/额外 identity 或任一字段漂移均抛 ContractError。"""
    def make_index(rows: Sequence[Mapping[str, str]]):
        """功能：为一组 TSV rows 创建唯一 identity 索引。
        输入输出及副作用：返回新 dict；不修改 rows。
        失败边界：identity 重复时立即抛 ContractError。"""
        result = {}
        for row in rows:
            key = tuple(row[column] for column in identity_columns)
            if key in result:
                raise ContractError(f"duplicate {label} identity: {key}")
            result[key] = row
        return result

    actual_index = make_index(actual)
    expected_index = make_index(expected)
    if set(actual_index) != set(expected_index):
        missing = set(expected_index) - set(actual_index)
        extra = set(actual_index) - set(expected_index)
        raise ContractError(f"{label} identity drift: missing={missing} extra={extra}")
    for key in sorted(expected_index):
        for column in columns:
            if actual_index[key][column] != expected_index[key][column]:
                raise ContractError(
                    f"{label} drift at {key}/{column}: "
                    f"{actual_index[key][column]} != {expected_index[key][column]}"
                )


def build_expected_capabilities(
    enum_members: Sequence[tuple[str, int]],
) -> list[dict[str, str]]:
    """功能：为每个 executable enum 成员生成 REQUEST/RESPONSE 候选及 doorbell 行。
    输入输出及副作用：返回新列表；保留 driver symbol/value，不注册或启用 production path。
    失败边界：MAX 只作为边界排除；重复 enum 由 parser 提前拒绝。"""
    rows: list[dict[str, str]] = []
    for symbol, value in enum_members:
        if symbol == "XTRDMA_OP_MAX":
            continue
        for direction in ("REQUEST", "RESPONSE"):
            case_id = "-"
            if symbol == "XTRDMA_OP_QPC_CREATE" and direction == "REQUEST":
                case_id = "cmq_sqe_qpc_create_request"
            elif symbol == "XTRDMA_OP_QPC_CREATE" and direction == "RESPONSE":
                case_id = "cmq_cqe_qpc_create_response"
            elif symbol == "XTRDMA_OP_CQC_CREATE" and direction == "REQUEST":
                case_id = "cmq_sqe_cqc_create_request"
            if symbol == "XTRDMA_OP_CQC_CREATE" and direction == "REQUEST":
                blocker = "CONTEXT_EMBED_BASE_MISMATCH"
            elif symbol == "XTRDMA_OP_QPC_CREATE":
                blocker = "MISSING_PRODUCTION_PATH_EVIDENCE"
            else:
                blocker = "MISSING_CLOSED_EVIDENCE"
            codec = (
                "rdma_hw_cmq_request_composer"
                if direction == "REQUEST"
                else "rdma_hw_cmq_completion_codec"
            )
            rows.append({
                "driver_symbol": symbol,
                "opcode": _opcode_name(symbol),
                "opcode_value": f"0x{value:02x}",
                "direction": direction,
                "registered": "1",
                "request_encodable": "0",
                "response_decodable": "0",
                "oracle_case_id": case_id,
                "owning_codec": codec,
                "blocker": blocker,
            })
    rows.append({
        "driver_symbol": "-",
        "opcode": "CMQ_SQ_DOORBELL",
        "opcode_value": "-",
        "direction": "REQUEST",
        "registered": "1",
        "request_encodable": "0",
        "response_decodable": "0",
        "oracle_case_id": "cmq_sq_doorbell",
        "owning_codec": "rdma_hw_cmq_hw_profile",
        "blocker": "MISSING_PRODUCTION_PATH_EVIDENCE",
    })
    return rows


def _load_oracle_contract(
    oracle_root: Path,
    kernel_root: Path,
    source_manifest: Path,
    archive_id: str,
):
    """功能：加载 Task 3 固定 cases/anchors 并复验完整 source closure。
    输入输出及副作用：返回 cases、anchors 与 closure；只读 C/TSV，不重编译 oracle。
    失败边界：case/role 顺序、token occurrence、source hash 或 flow 文本漂移均拒绝。"""
    try:
        from . import verify_rdma_cmq_oracle as oracle_verifier
    except ImportError:  # pragma: no cover - direct script execution
        import verify_rdma_cmq_oracle as oracle_verifier
    contract_root = oracle_root.parent
    cases_path = contract_root / "cmq_oracle_cases.tsv"
    anchors_path = contract_root / "cmq_oracle_source_anchors.tsv"
    cases = oracle_verifier.load_cases(cases_path)
    anchors = oracle_verifier.load_anchors(anchors_path)
    closure = oracle_verifier.source_digests(
        kernel_root,
        source_manifest,
        anchors,
        archive_id,
    )
    if cases["cmq_sqe_cqc_create_request"][10] != "8":
        raise ContractError("CQC_CREATE oracle embed base must remain 8")
    return cases, anchors, closure


def _validate_artifact_field_values(oracle_root: Path) -> None:
    """功能：确认 canonical bytes 中每个 mutation-relevant field 等于 fields.tsv 值。
    输入输出及副作用：只读 bytes/fields；成功无返回值。
    失败边界：位值、长度或字段范围漂移均抛 ContractError，防止报告自洽但脱离字节。"""
    for case_id, layout in CASE_LAYOUTS.items():
        fields = _load_case_fields(oracle_root, case_id)
        image = _load_case_bytes(oracle_root, case_id, int(layout["length"]))
        relevant = CASE_FIELD_MACROS[case_id]
        for name in relevant:
            offset, lsb, width, expected = fields[name]
            start = offset
            word = int.from_bytes(image[start:start + 8], "big")
            mask = (1 << width) - 1
            actual = (word >> lsb) & mask
            if actual != expected:
                raise ContractError(
                    f"oracle bytes/field value drift: {case_id}/{name} "
                    f"{actual:#x} != {expected:#x}"
                )


def _derive_all_coordinates(
    kernel_root: Path,
    oracle_root: Path,
    macros: Mapping[str, MacroDefinition],
) -> dict[tuple[str, str, str, str], int]:
    """功能：从锁定 cmq.c 的 set/get/MMIO flows 推导四 case 的字段 byte base。
    输入输出及副作用：返回 ownership context/macro 到 base 的映射；只读 C 与 fields。
    失败边界：任一字段无法唯一流入目标 buffer，或 Task 3 坐标与 C flow 不符均拒绝。"""
    source = (kernel_root / "cmq.c").read_text(encoding="utf-8")
    coordinate_map: dict[tuple[str, str, str, str], int] = {}
    qpc_case = "cmq_sqe_qpc_create_request"
    qpc_names = set(CASE_FIELD_MACROS[qpc_case].values())
    qpc_offsets = derive_macro_offsets(
        source,
        "xtrdma_sc_qp_create",
        qpc_names,
        expected_buffers={"wqe"},
    )
    qpc_fields = _load_case_fields(oracle_root, qpc_case)
    _validate_case_field_coordinates(qpc_case, qpc_fields, macros, qpc_offsets)
    for macro, offset in qpc_offsets.items():
        coordinate_map[("CMQ_SQE", "QPC_CREATE", "REQUEST", macro)] = offset

    cqc_case = "cmq_sqe_cqc_create_request"
    cqc_names = set(CQC_REQUEST_FIELDS.values())
    cqc_offsets = derive_macro_offsets(
        source,
        "xtrdma_sc_cq_create",
        cqc_names,
        expected_buffers={"wqe"},
    )
    cqc_fields = _load_case_fields(oracle_root, cqc_case)
    _validate_case_field_coordinates(cqc_case, cqc_fields, macros, cqc_offsets)
    for macro, offset in cqc_offsets.items():
        coordinate_map[("CMQ_SQE", "CQC_CREATE", "REQUEST", macro)] = offset

    response_case = "cmq_cqe_qpc_create_response"
    response_names = set(CASE_FIELD_MACROS[response_case].values())
    valid_macro = CASE_FIELD_MACROS[response_case]["valid"]
    common_names = response_names - {valid_macro}
    response_offsets = derive_macro_offsets(
        source,
        "xtrdma_get_cqe_common_info",
        common_names,
        expected_buffers={"*cqe", "sqe"},
    )
    response_offsets.update(derive_macro_offsets(
        source,
        "xtrdma_sc_cmq_next_cqe_valid",
        {valid_macro},
        expected_buffers={"cqe"},
    ))
    response_fields = _load_case_fields(oracle_root, response_case)
    _validate_case_field_coordinates(
        response_case, response_fields, macros, response_offsets
    )
    response_offsets["XTRDMA_CMQSQ_VFID_OVERRIDE"] = 0
    response_offsets["XTRDMA_CMQSQ_USE_VFID"] = 0
    for macro, offset in response_offsets.items():
        coordinate_map[("CMQ_CQE", "QPC_CREATE", "RESPONSE", macro)] = offset

    doorbell_case = "cmq_sq_doorbell"
    doorbell_names = set(CASE_FIELD_MACROS[doorbell_case].values())
    doorbell_offsets = derive_macro_offsets(
        source,
        "xtrdma_sc_cmq_post_sq",
        doorbell_names,
        doorbell_value="cmq_db",
    )
    doorbell_fields = _load_case_fields(oracle_root, doorbell_case)
    _validate_case_field_coordinates(
        doorbell_case, doorbell_fields, macros, doorbell_offsets
    )
    for macro, offset in doorbell_offsets.items():
        coordinate_map[("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST", macro)] = offset
    return coordinate_map


def verify(args) -> dict[str, int]:
    """功能：执行 archive/source、ownership、capability、consumer 与 mutation 全门禁。
    输入输出及副作用：只读 args 指定路径，返回 1,088-row 计数；不修改任何输入。
    失败边界：身份、C 坐标、anchor、enum、consumer、capability 或逐 bit 报告任一漂移均
    抛 ContractError。"""
    kernel_root = Path(args.kernel_root)
    oracle_root = Path(args.oracle_root)
    lock = load_archive_lock(Path(args.archive_lock))
    records = _manifest_records(
        kernel_root,
        Path(args.source_manifest),
        lock.archive_id,
    )
    cases, anchors, _ = _load_oracle_contract(
        oracle_root,
        kernel_root,
        Path(args.source_manifest),
        lock.archive_id,
    )
    anchor_rows = [row for rows in anchors.values() for row in rows]
    oracle_source = oracle_root.parent / "rdma_cmq_oracle.c"
    macros = _discover_macros(
        kernel_root,
        records,
        oracle_source,
        anchor_rows,
    )
    ownership = load_ownership(Path(args.ownership))
    exclusions = load_exclusions(Path(args.exclusions))
    capabilities = load_capabilities(Path(args.capabilities))
    mutations = load_mutations(Path(args.mutation_manifest))
    _validate_identity_rows(ownership, records, lock.archive_id)
    _validate_identity_rows(exclusions, records, lock.archive_id)
    _validate_concrete_anchors(ownership, kernel_root, records)
    sv_sources = _read_sv_sources(Path(args.sv_root))
    coordinates = _derive_all_coordinates(kernel_root, oracle_root, macros)
    validate_ownership_rows(
        ownership,
        macros=macros,
        exclusions=exclusions,
        sv_sources=sv_sources,
        coordinates=coordinates,
    )
    expected_ownership = build_expected_ownership(records)
    _compare_rows(
        ownership,
        expected_ownership,
        OWNERSHIP_COLUMNS,
        ("macro_name", "entry_kind", "opcode_or_variant", "direction"),
        "ownership",
    )
    expected_exclusions = build_expected_exclusions(
        records,
        macros,
        expected_ownership,
    )
    _compare_rows(
        exclusions,
        expected_exclusions,
        EXCLUSION_COLUMNS,
        ("macro_name",),
        "exclusion",
    )
    validate_macro_coverage(
        macros,
        {row["macro_name"] for row in ownership},
        {row["macro_name"]: row["exclusion_reason"] for row in exclusions},
    )
    cmq_header = (kernel_root / "cmq.h").read_text(encoding="utf-8")
    enum_members = parse_opcode_enum(cmq_header)
    validate_capability_rows(capabilities, enum_members)
    expected_capabilities = build_expected_capabilities(enum_members)
    _compare_rows(
        capabilities,
        expected_capabilities,
        CAPABILITY_COLUMNS,
        ("driver_symbol", "opcode", "direction"),
        "capability",
    )
    validate_oracle_case_references(
        [*ownership, *capabilities, *mutations],
        cases,
    )
    _validate_artifact_field_values(oracle_root)
    expected_mutations = build_expected_mutations(oracle_root)
    summary = validate_mutation_report(mutations)
    compare_mutation_report(mutations, expected_mutations)
    return summary


def main(argv: list[str] | None = None) -> int:
    """功能：解析只读 field gate CLI，成功打印 counts 并返回 0。
    输入输出及副作用：读取命令行路径；仅向 stdout/stderr 输出诊断，不写输入文件。
    失败边界：参数、I/O、UTF-8 或 ContractError 均以状态 1 失败，argparse 自行返回 2。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-root", required=True, type=Path)
    parser.add_argument("--archive-lock", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--ownership", required=True, type=Path)
    parser.add_argument("--exclusions", required=True, type=Path)
    parser.add_argument("--capabilities", required=True, type=Path)
    parser.add_argument("--oracle-root", required=True, type=Path)
    parser.add_argument("--mutation-manifest", required=True, type=Path)
    parser.add_argument("--sv-root", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        summary = verify(args)
    except (ContractError, OSError, UnicodeError, ValueError) as exc:
        print(f"RDMA field ownership verification failed: {exc}", file=sys.stderr)
        return 1
    ordered = " ".join(f"{key}={summary[key]}" for key in FROZEN_MUTATION_COUNTS)
    print(f"RDMA field ownership verification passed: {ordered}")
    return 0


def _load_case_fields(oracle_root: Path, case_id: str):
    """功能：读取 Task 3 case 的 fields.tsv 并解析固定五列字段记录。
    输入输出及副作用：返回 name 到 (qword,lsb,width,value)；只读 artifact。
    失败边界：缺文件、重复字段、非法坐标/值或空报告均抛 ContractError。"""
    path = oracle_root / f"{case_id}.fields.tsv"
    if not path.is_file():
        nested = oracle_root / case_id / f"{case_id}.fields.tsv"
        path = nested
    if not path.is_file():
        raise ContractError(f"oracle fields artifact is missing: {case_id}")
    result: dict[str, tuple[int, int, int, int]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        columns = line.split("\t")
        if len(columns) != 5:
            raise ContractError(f"{path}:{line_number}: malformed fields row")
        name, offset_text, lsb_text, width_text, value_text = columns
        if name in result or not name:
            raise ContractError(f"{path}:{line_number}: duplicate/empty field")
        offset = _parse_coordinate(offset_text, "field qword byte", 56)
        lsb = _parse_coordinate(lsb_text, "field lsb", 63)
        width = _parse_coordinate(width_text, "field width", 64)
        if offset % 8:
            raise ContractError(
                f"{path}:{line_number}: field qword byte is not aligned"
            )
        metadata_field = name in {
            "payload_length", "payload_source_byte", "payload_target_byte"
        }
        if (width == 0 and not metadata_field) or lsb + width > 64:
            raise ContractError(f"{path}:{line_number}: field range is invalid")
        if not re.fullmatch(r"[0-9a-fA-F]+", value_text):
            raise ContractError(f"{path}:{line_number}: field value is invalid")
        value = int(value_text, 16)
        if width and value >= (1 << width):
            raise ContractError(
                f"{path}:{line_number}: field value exceeds declared width"
            )
        result[name] = (offset, lsb, width, value)
    if not result:
        raise ContractError(f"{path}: fields artifact is empty")
    return result


def _load_case_bytes(oracle_root: Path, case_id: str, expected_length: int):
    """功能：读取并解析 canonical big-endian case bytes。
    输入输出及副作用：返回 bytes；只读 artifact，不改写 hex 文本。
    失败边界：缺失、非法字节或长度漂移均抛 ContractError。"""
    path = oracle_root / f"{case_id}.bytes.hex"
    if not path.is_file():
        path = oracle_root / case_id / f"{case_id}.bytes.hex"
    if not path.is_file():
        raise ContractError(f"oracle bytes artifact is missing: {case_id}")
    values = path.read_text(encoding="utf-8").split()
    if len(values) != expected_length or any(
        not re.fullmatch(r"[0-9a-fA-F]{2}", value) for value in values
    ):
        raise ContractError(f"oracle bytes length/format drift: {case_id}")
    return bytes(int(value, 16) for value in values)


def derive_macro_offsets(
    source: str,
    function: str,
    macro_names: Iterable[str],
    *,
    doorbell_value: str | None = None,
    expected_buffers: Iterable[str] | None = None,
) -> dict[str, int]:
    """功能：从 set/get 调用和赋值数据流推导函数内字段的 container byte base。
    输入输出及副作用：返回 macro 到唯一 base 的映射；可选 expected_buffers 约束每个
    set/get 调用的首个 buffer 表达式；只读锁定 C 函数体。
    失败边界：宏未流入 set/get/doorbell、buffer 不在允许集合、同一宏落到多 base 或
    数值 base 非法均拒绝。"""
    body = " ".join(_function_body(_strip_comments(source), function).split())
    wanted = set(macro_names)
    allowed_buffers = {
        re.sub(r"\s+", "", value)
        for value in (expected_buffers or ())
    }
    assignments: dict[str, set[str]] = defaultdict(set)
    assignment_pattern = re.compile(
        r"(?:^|;)\s*(?:[A-Za-z_][A-Za-z0-9_\s*]*\s+)?"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?);"
    )
    for match in assignment_pattern.finditer(body + ";"):
        variable, expression = match.groups()
        assignments[variable].update(
            name for name in re.findall(r"\bXTRDMA_[A-Z0-9_]+\b", expression)
            if name in wanted
        )
    offsets: defaultdict[str, set[int]] = defaultdict(set)
    set_pattern = re.compile(
        r"set_64bit_val\(\s*([^,]+),\s*([^,]+),\s*(.*?)\)\s*;"
    )
    for match in set_pattern.finditer(body):
        buffer_text, base_text, expression = match.groups()
        if allowed_buffers and re.sub(r"\s+", "", buffer_text) not in allowed_buffers:
            raise ContractError(
                f"unexpected set_64bit_val buffer in {function}: {buffer_text}"
            )
        base = _parse_int(base_text, "set_64bit_val base")
        names = {
            name for name in re.findall(r"\bXTRDMA_[A-Z0-9_]+\b", expression)
            if name in wanted
        }
        for variable, variable_macros in assignments.items():
            if re.search(r"\b" + re.escape(variable) + r"\b", expression):
                names.update(variable_macros)
        for name in names:
            offsets[name].add(base)
    loads: dict[str, int] = {}
    get_pattern = re.compile(
        r"get_64bit_val\(\s*([^,]+),\s*([^,]+),\s*&\s*"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*;"
    )
    for match in get_pattern.finditer(body):
        buffer_text, base_text, variable = match.groups()
        if allowed_buffers and re.sub(r"\s+", "", buffer_text) not in allowed_buffers:
            raise ContractError(
                f"unexpected get_64bit_val buffer in {function}: {buffer_text}"
            )
        loads[variable] = _parse_int(base_text, "get_64bit_val base")
    for macro, variable in re.findall(
        r"FIELD_GET\(\s*(XTRDMA_[A-Z0-9_]+)\s*,\s*"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\)",
        body,
    ):
        if macro in wanted and variable in loads:
            offsets[macro].add(loads[variable])
    if doorbell_value is not None:
        direct = assignments.get(doorbell_value, set())
        if direct and re.search(
            r"\bxtrdma_iowrite64be\s*\(\s*" + re.escape(doorbell_value) + r"\s*,",
            body,
        ):
            for name in direct:
                offsets[name].add(0)
    result: dict[str, int] = {}
    for name in wanted:
        candidates = offsets.get(name, set())
        if len(candidates) != 1:
            raise ContractError(
                f"macro container base is not unique in {function}: "
                f"{name} -> {sorted(candidates)}"
            )
        result[name] = next(iter(candidates))
    return result


def _validate_case_field_coordinates(
    case_id: str,
    fields: Mapping[str, tuple[int, int, int, int]],
    macros: Mapping[str, MacroDefinition],
    derived_offsets: Mapping[str, int],
) -> None:
    """功能：把 Task 3 fields.tsv 坐标与 C 宏范围、C data-flow base 三方闭合。
    输入输出及副作用：成功无返回值；只读 fields/macros/derived_offsets。
    失败边界：缺字段/宏、lsb/width drift 或 container base drift 均抛 ContractError。"""
    mapping = (
        CQC_REQUEST_FIELDS
        if case_id == "cmq_sqe_cqc_create_request"
        else CASE_FIELD_MACROS[case_id]
    )
    for field_name, macro_name in mapping.items():
        if field_name not in fields:
            raise ContractError(f"oracle field is missing: {case_id}/{field_name}")
        if macro_name not in macros:
            raise ContractError(f"target C macro is missing: {macro_name}")
        offset, lsb, width, _ = fields[field_name]
        definition = macros[macro_name]
        if (lsb, width) != (definition.lsb, definition.width):
            raise ContractError(f"C macro/oracle field drift: {case_id}/{field_name}")
        if derived_offsets.get(macro_name) != offset:
            raise ContractError(f"C anchor container base drift: {case_id}/{field_name}")


def _field_at_bit(
    fields: Mapping[str, tuple[int, int, int, int]],
    candidates: Iterable[str],
    qword: int,
    bit: int,
) -> str | None:
    """功能：查找给定 logical qword bit 所属的唯一 C oracle field。
    输入输出及副作用：返回字段名或 None；只读 field report。
    失败边界：两个候选字段在同一 bit 重叠时抛 ContractError，要求显式 overlay。"""
    matches = []
    for name in candidates:
        offset, lsb, width, _ = fields[name]
        if offset // 8 == qword and lsb <= bit < lsb + width:
            matches.append(name)
    if len(matches) > 1:
        raise ContractError(f"undeclared oracle field overlap: {matches}")
    return matches[0] if matches else None


def _base_mutation_row(
    case_id: str,
    qword: int,
    bit: int,
) -> dict[str, str]:
    """功能：创建一个只含稳定坐标和 case identity 的 mutation row 基础值。
    输入输出及副作用：返回新字典；不共享可变状态、不写 TSV。
    失败边界：调用方必须保证 qword/bit 落在 CASE_LAYOUTS 定义范围。"""
    layout = CASE_LAYOUTS[case_id]
    return {
        "case_id": case_id,
        "entry": str(layout["entry"]),
        "opcode": str(layout["opcode"]),
        "direction": str(layout["direction"]),
        "byte_offset": str(8 * qword + 7 - (bit // 8)),
        "qword_index": str(qword),
        "bit_index": str(bit),
        "expected_class": "RESERVED_ZERO",
        "expected_field": "-",
        "evidence_mode": "STATIC_UNWRITABLE",
        "correlation_group": "-",
        "driver_result_class": "STATIC_UNWRITABLE",
        "model_consumer": "CMQ_REQUEST_COMPOSER",
        "expected_outcome": "REJECT",
        "expected_status_code": "-",
        "expected_ready": "-",
        "expected_value_delta": "0",
        "oracle_case_id": case_id,
    }


def _request_mutation_row(
    case_id: str,
    fields: Mapping[str, tuple[int, int, int, int]],
    qword: int,
    bit: int,
) -> dict[str, str]:
    """功能：按 QPC_CREATE C fields 与 driver policy 生成一个 request bit 证据行。
    输入输出及副作用：返回新 row；不调用模型 encoder，不读取模型 mask。
    失败边界：未知 field 作为 canonical-zero static-unwritable；非零 reserved 由调用方拒绝。"""
    row = _base_mutation_row(case_id, qword, bit)
    field = _field_at_bit(fields, QPC_REQUEST_POLICY, qword, bit)
    if field is None:
        return row
    expected_class, expected_field, mode = QPC_REQUEST_POLICY[field]
    row["expected_class"] = expected_class
    row["expected_field"] = expected_field
    row["evidence_mode"] = mode
    if mode == "TYPED_RECOMPOSE":
        row["driver_result_class"] = "ENCODED"
        row["expected_outcome"] = "ACCEPT"
        row["expected_status_code"] = "OK"
        row["expected_ready"] = "1"
        row["expected_value_delta"] = "1"
    elif mode == "CORRELATED_RECOMPOSE":
        row["driver_result_class"] = "ENCODED"
        row["correlation_group"] = "QPC_POLARITY_VALID_WRAP"
        row["expected_outcome"] = "ACCEPT"
        row["expected_status_code"] = "OK"
        row["expected_ready"] = "1"
        row["expected_value_delta"] = "1"
    elif mode == "DRIVER_FIXED_REJECT":
        row["driver_result_class"] = "FIXED_ZERO"
        row["expected_outcome"] = "REJECT"
        row["expected_status_code"] = "INVALID_ARGUMENT"
        row["expected_ready"] = "0"
        row["expected_value_delta"] = "1"
    elif mode == "STATIC_CANONICAL":
        row["driver_result_class"] = "STATIC_CANONICAL"
        row["expected_outcome"] = "CANONICAL"
    return row


def _response_driver_class(field: str | None) -> str:
    """功能：把单 bit CQE 变异映射到独立 Linux driver result class。
    输入输出及副作用：返回分类字符串；不读取或复制 model status。
    失败边界：非 READY/LOOKUP/WRAP/OPCODE/ECODE 字段按 READY_OK 处理。"""
    if field == "valid":
        return "NOT_READY"
    if field == "index":
        return "REQUEST_LOOKUP_CHANGED"
    if field == "wrap":
        return "WRAP_MISMATCH"
    if field == "opcode":
        return "OPCODE_MISMATCH"
    if field == "ecode":
        return "ECODE_ERROR"
    return "READY_OK"


def _response_mutation_row(
    case_id: str,
    fields: Mapping[str, tuple[int, int, int, int]],
    qword: int,
    bit: int,
) -> dict[str, str]:
    """功能：生成一个 raw CQE bit mutation，分别记录 driver 与 completion codec 结果。
    输入输出及副作用：返回新 row；依据 C field baseline 计算 opcode/owner 变异。
    失败边界：reserved bit 只可记录 codec REJECT，ecode 行仍保持 model OK/ready。"""
    row = _base_mutation_row(case_id, qword, bit)
    row["model_consumer"] = "CMQ_COMPLETION_CODEC"
    row["evidence_mode"] = "RAW_DECODE_MUTATION"
    row["expected_status_code"] = "CODEC_ERROR"
    row["expected_ready"] = "0"
    row["expected_value_delta"] = "1"
    candidates = tuple(CASE_FIELD_MACROS[case_id])
    field = _field_at_bit(fields, candidates, qword, bit)
    row["driver_result_class"] = _response_driver_class(field)
    if field not in RESPONSE_TYPED_FIELDS:
        row["expected_outcome"] = "REJECT"
        return row
    row["expected_class"] = "HW_TYPED"
    row["expected_field"] = RESPONSE_TYPED_FIELDS[field]
    if field == "valid":
        row["expected_outcome"] = "NOT_READY"
        row["expected_status_code"] = "OK"
        row["expected_ready"] = "0"
    elif field == "opcode":
        _, _, _, baseline_opcode = fields[field]
        offset_in_field = bit - fields[field][1]
        status, ready = model_outcome(
            owner=fields["valid"][3],
            expected_owner=fields["valid"][3],
            opcode=baseline_opcode ^ (1 << offset_in_field),
        )
        row["expected_outcome"] = "ACCEPT" if status == "OK" else "REJECT"
        row["expected_status_code"] = status
        row["expected_ready"] = str(ready)
    elif field == "ecode":
        row["expected_outcome"] = "PUBLISH_ECODE"
        row["expected_status_code"] = "OK"
        row["expected_ready"] = "1"
    else:
        row["expected_outcome"] = "ACCEPT"
        row["expected_status_code"] = "OK"
        row["expected_ready"] = "1"
    return row


def _doorbell_mutation_row(
    case_id: str,
    fields: Mapping[str, tuple[int, int, int, int]],
    qword: int,
    bit: int,
) -> dict[str, str]:
    """功能：按 C big-endian doorbell 字段生成 PI/polarity typed 或 static 证据行。
    输入输出及副作用：返回新 row；不伪造 raw request injection。
    失败边界：仅 PI[4:0] 与 wire polarity 可执行，其余 58 位保持 static-unwritable。"""
    row = _base_mutation_row(case_id, qword, bit)
    row["model_consumer"] = "CMQ_DOORBELL_ENCODER"
    field = _field_at_bit(fields, ("pi_after", "wire_polarity"), qword, bit)
    if field is None:
        return row
    row["expected_class"] = "HOST_TYPED"
    row["expected_field"] = "pi" if field == "pi_after" else "polarity"
    row["evidence_mode"] = "TYPED_RECOMPOSE"
    row["driver_result_class"] = "ENCODED"
    row["expected_outcome"] = "ACCEPT"
    row["expected_status_code"] = "OK"
    row["expected_ready"] = "1"
    row["expected_value_delta"] = "1"
    return row


def build_expected_mutations(
    oracle_root: Path,
) -> list[dict[str, str]]:
    """功能：从 Task 3 canonical fields/bytes 生成固定 1,088 行 candidate evidence。
    输入输出及副作用：返回行字典列表；只读 oracle_root，不写 mutation TSV。
    失败边界：case bytes/fields 缺失、reserved baseline 非零或 counts 不符均抛错。"""
    rows: list[dict[str, str]] = []
    for case_id, layout in CASE_LAYOUTS.items():
        length = int(layout["length"])
        fields = _load_case_fields(oracle_root, case_id)
        image = _load_case_bytes(oracle_root, case_id, length)
        for qword in range(length // 8):
            logical = int.from_bytes(image[qword * 8:(qword + 1) * 8], "big")
            for bit in range(64):
                if case_id == "cmq_sqe_qpc_create_request":
                    row = _request_mutation_row(case_id, fields, qword, bit)
                elif case_id == "cmq_cqe_qpc_create_response":
                    row = _response_mutation_row(case_id, fields, qword, bit)
                else:
                    row = _doorbell_mutation_row(case_id, fields, qword, bit)
                if row["evidence_mode"] == "STATIC_UNWRITABLE" and (
                    (logical >> bit) & 1
                ):
                    raise ContractError(
                        f"static-unwritable canonical bit is nonzero: "
                        f"{case_id}/{qword}/{bit}"
                    )
                rows.append(row)
    validate_mutation_report(rows)
    return rows


def compare_mutation_report(
    actual: Sequence[Mapping[str, str]],
    expected: Sequence[Mapping[str, str]],
) -> None:
    """功能：按 case/qword/bit 键逐列比较提交报告与 C-derived candidate。
    输入输出及副作用：成功无返回值；只读两组 rows，不排序或写回原表。
    失败边界：键集合、任一列或重复坐标漂移均抛 ContractError。"""
    def index(rows: Sequence[Mapping[str, str]]):
        """功能：把 mutation rows 建为唯一坐标索引供逐列比较。
        输入输出及副作用：返回新字典；不修改 rows。
        失败边界：重复 key 立即抛 ContractError。"""
        result: dict[tuple[str, str, str], Mapping[str, str]] = {}
        for row in rows:
            key = (row["case_id"], row["qword_index"], row["bit_index"])
            if key in result:
                raise ContractError(f"duplicate mutation key: {key}")
            result[key] = row
        return result

    actual_index = index(actual)
    expected_index = index(expected)
    if set(actual_index) != set(expected_index):
        raise ContractError("mutation report coordinate set drift")
    for key in sorted(expected_index):
        for column in MUTATION_COLUMNS:
            if actual_index[key][column] != expected_index[key][column]:
                raise ContractError(
                    f"mutation report drift at {key}/{column}: "
                    f"{actual_index[key][column]} != {expected_index[key][column]}"
                )


if __name__ == "__main__":
    raise SystemExit(main())
