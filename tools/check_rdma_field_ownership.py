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
MUTATION_HEADER = (
    "case_id\tentry\topcode\tdirection\tbyte_offset\tqword_index\tbit_index\t"
    "expected_class\texpected_field\tevidence_mode\tcorrelation_group\t"
    "driver_result_class\tmodel_consumer\texpected_outcome\t"
    "expected_status_code\texpected_ready\texpected_value_delta\toracle_case_id"
)

OWNERSHIP_COLUMNS = tuple(OWNERSHIP_HEADER.split("\t"))
EXCLUSION_COLUMNS = tuple(EXCLUSION_HEADER.split("\t"))
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

# 只有这些 case 具备 Task 5 的完整生产路径闭合证据。集合中的名称必须
# 同时出现在 canonical mutation candidate、实际 mutation report 和 source
# writer proof 中；它不是“把 TSV 改成 1”即可绕过的能力开关。
PROVEN_CAPABILITY_CASES = frozenset({
    "cmq_sqe_qpc_create_request",
    "cmq_cqe_qpc_create_response",
    "cmq_sq_doorbell",
})

CAPABILITY_CASE_BY_KEY = {
    ("XTRDMA_OP_QPC_CREATE", "REQUEST"):
        "cmq_sqe_qpc_create_request",
    ("XTRDMA_OP_QPC_CREATE", "RESPONSE"):
        "cmq_cqe_qpc_create_response",
    ("CMQ_SQ_DOORBELL", "REQUEST"):
        "cmq_sq_doorbell",
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


@dataclass(frozen=True)
class WriterRange:
    """功能：记录一个 production SV writer 在逻辑 image 中覆盖的位区间。
    输入输出及副作用：保存 case、来源、byte base、低位、宽度和证据 token；对象不可变且不拥有源码。
    失败边界：坐标必须由 C-derived mapping 校验，未知或无法解析的 writer 由调用方按整幅 image 保守处理。"""

    case_id: str
    source_path: str
    operation: str
    token: str
    base: int
    lsb: int
    width: int


# SV field names are intentionally only aliases.  The numeric coordinate used
# by the gate always comes from the locked C macro map; a mismatch between an
# alias's RDMA_FIELD declaration and that map is a hard failure.
SV_FIELD_ALIASES = {
    "RDMA_CMQ_VALID": "XTRDMA_CMQSQ_WQE_VALID",
    "RDMA_CMQ_VFID_OVERRIDE": "XTRDMA_CMQSQ_VFID_OVERRIDE",
    "RDMA_CMQ_USE_VFID": "XTRDMA_CMQSQ_USE_VFID",
    "RDMA_CMQ_WRAP": "XTRDMA_CMQSQ_WQE_WRAP",
    "RDMA_CMQ_WQE_INDEX": "XTRDMA_CMQSQ_WQE_INDEX",
    "RDMA_CMQ_OPCODE": "XTRDMA_CMQCQ_OPCODE",
    "RDMA_CMQ_CMD_ECODE": "XTRDMA_CMQCQ_CMD_ECODE",
    "RDMA_CMQ_QPN": "XTRDMA_CMQSQ_WQE_QPN",
    "RDMA_CMQ_SQ_CQN": "XTRDMA_CMQSQ_WQE_SQ_CQN",
    "RDMA_CMQ_SIGN_EN": "XTRDMA_CMQSQ_WQE_SIGN_EN",
    "RDMA_CMQ_SIGNATURE": "XTRDMA_CMQSQ_WQE_SIGNATURE",
    "RDMA_CMQ_RQ_CQN": "XTRDMA_CMQSQ_WQE_RQ_CQN",
    "RDMA_CMQ_QPC_BUFFER_ADDR": "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR",
    "RDMA_CMQ_DB_PI": "XTRDMA_CMQSQ_DB_PI",
    "RDMA_CMQ_DB_POLARITY": "XTRDMA_CMQSQ_DB_POL",
}

SUPPORTED_OPCODE_NAME_RE = re.compile(
    r"\b(?:RDMA|XTRDMA|TRDMA)_OP_[A-Z0-9_]+\b"
)


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


def _strip_sv_comments(text: str) -> str:
    """功能：按 SystemVerilog 词法移除行/块注释，同时保留字符串和换行供 source walk 定位。
    输入输出及副作用：返回只含非注释源码的文本；不修改输入文件，也不执行宏或字符串内容。
    失败边界：未闭合注释延伸到文本末尾；注释中的 writer、mask 或 opcode 永远不能成为证据。"""
    result: list[str] = []
    index = 0
    state = "normal"
    escaped = False
    while index < len(text):
        current = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "normal":
            if current == "/" and following == "/":
                result.extend((" ", " "))
                index += 2
                state = "line"
                continue
            if current == "/" and following == "*":
                result.extend((" ", " "))
                index += 2
                state = "block"
                continue
            if current == '"':
                result.append(current)
                index += 1
                state = "string"
                escaped = False
                continue
            result.append(current)
            index += 1
            continue
        if state == "line":
            if current == "\n":
                result.append(current)
                state = "normal"
            else:
                result.append(" ")
            index += 1
            continue
        if state == "block":
            if current == "*" and following == "/":
                result.extend((" ", " "))
                index += 2
                state = "normal"
                continue
            result.append("\n" if current == "\n" else " ")
            index += 1
            continue
        # string state: comments inside a quoted literal are data, not syntax.
        result.append(current)
        index += 1
        if escaped:
            escaped = False
        elif current == "\\":
            escaped = True
        elif current == '"':
            state = "normal"
    return "".join(result)


def _balanced_delimited_text(
    source: str,
    opening_index: int,
    opening: str,
    closing: str,
) -> tuple[str, int]:
    """功能：提取从 opening_index 开始的一段平衡括号/关键字区域。
    输入输出及副作用：返回不含外层定界符的文本及结束下标；只读 source，不执行其中代码。
    失败边界：起点不是 opening、嵌套未闭合或下标越界时抛 ContractError，禁止截断解析。"""
    if opening_index >= len(source) or source[opening_index] != opening:
        raise ContractError("balanced text does not start with opening delimiter")
    depth = 1
    index = opening_index + 1
    in_string = False
    escaped = False
    while index < len(source):
        current = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif current == "\\":
                escaped = True
            elif current == '"':
                in_string = False
            index += 1
            continue
        if current == '"':
            in_string = True
        elif current == opening:
            depth += 1
        elif current == closing:
            depth -= 1
            if depth == 0:
                return source[opening_index + 1:index], index + 1
        index += 1
    raise ContractError("unbalanced source delimiters")


def _sv_class_body(source: str, class_name: str) -> str:
    """功能：截取指定 SV class 的完整文本，供方法和 case writer 解析。
    输入输出及副作用：返回 class 关键字之后到 endclass 之前的只读文本；不展开继承或修改源码。
    失败边界：class 缺失、重复、endclass 缺失或声明被注释遮蔽时抛 ContractError。"""
    matches = list(re.finditer(
        r"\bclass\s+" + re.escape(class_name) + r"\b[^;]*;",
        source,
    ))
    if len(matches) != 1:
        raise ContractError(
            f"SV class {class_name} is not unique: {len(matches)}"
        )
    start = matches[0].end()
    end = source.find("endclass", start)
    if end < 0:
        raise ContractError(f"SV class {class_name} has no endclass")
    return source[start:end]


def _has_sv_class_declaration(source: str, class_name: str) -> bool:
    """功能：按完整 class 标识符判断 SV source 是否声明目标 production class。
    输入输出及副作用：source 与 class_name 输入；返回布尔值，不截取正文、不修改源码。
    失败边界：registry 前缀、相邻标识符或注释文本不得满足匹配；声明缺失时返回 False。"""
    return re.search(
        r"\bclass\s+" + re.escape(class_name) + r"\b",
        source,
    ) is not None


def _sv_function_body(source: str, function_name: str) -> str:
    """功能：从 SV class/source 中截取一个 function 的声明后正文，保留 begin/end 结构。
    输入输出及副作用：返回函数体文本；不执行函数，也不把相邻 overload 当作同一 writer。
    失败边界：函数不存在、重复、缺少声明分号或 endfunction 时抛 ContractError。"""
    # Do not search from one ``function`` token to the next ``endfunction``
    # with a broad regex: a call to ``encode_fields()`` inside ``encode()``
    # would then be mistaken for a second declaration.  Instead inspect only
    # the declaration text ending at its semicolon and require the requested
    # name there.  This also keeps overloads distinct and makes duplicate
    # declarations fail closed.
    declarations: list[tuple[int, int]] = []
    for function_match in re.finditer(r"\bfunction\b", source):
        declaration_end = source.find(";", function_match.end())
        if declaration_end < 0:
            continue
        declaration = source[function_match.end():declaration_end]
        if re.search(
            r"\b" + re.escape(function_name) + r"\s*\(", declaration
        ):
            declarations.append((function_match.start(), declaration_end))
    if len(declarations) != 1:
        raise ContractError(
            f"SV function {function_name} is not unique: {len(declarations)}"
        )
    start, declaration_end = declarations[0]
    # Find the closing parenthesis of the argument list before the declaration
    # semicolon; nested type expressions are accepted.
    open_index = source.find("(", start, declaration_end)
    if open_index < 0:
        raise ContractError(f"SV function {function_name} declaration is incomplete")
    _, after_args = _balanced_delimited_text(source, open_index, "(", ")")
    if after_args > declaration_end:
        raise ContractError(f"SV function {function_name} declaration is incomplete")
    end = source.find("endfunction", declaration_end + 1)
    if end < 0:
        raise ContractError(f"SV function {function_name} has no endfunction")
    return source[declaration_end + 1:end]


def _sv_case_branch(body: str, label: str) -> str:
    """功能：提取 case 中指定 label 的 begin/end 分支，隔离其他 opcode/variant writer。
    输入输出及副作用：返回该分支正文；只读已去注释的 SV 文本，不改变 case 状态。
    失败边界：label 缺失、重复、begin/end 不平衡或分支为空时抛 ContractError。"""
    # A quoted variant label (the doorbell codec uses ``"cmq_sq"``) has no
    # word-character boundary before its opening quote, so ``\b`` would miss
    # it.  Require a source/whitespace/statement boundary instead and keep the
    # label itself exact.
    pattern = re.compile(
        r"(?:^|[\s;])" + re.escape(label) + r"\s*:\s*begin\b"
    )
    matches = list(pattern.finditer(body))
    if len(matches) != 1:
        raise ContractError(f"SV case branch {label} is not unique: {len(matches)}")
    begin_index = body.find("begin", matches[0].start(), matches[0].end())
    token_re = re.compile(r"\bbegin\b|\bend\b")
    depth = 0
    end_index = None
    for token in token_re.finditer(body, begin_index):
        if token.group() == "begin":
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                end_index = token.start()
                break
    if end_index is None:
        raise ContractError(f"SV case branch {label} is unbalanced")
    branch = body[begin_index + len("begin"):end_index]
    if not branch.strip():
        raise ContractError(f"SV case branch {label} is empty")
    return branch


def _split_call_arguments(text: str) -> list[str]:
    """功能：按顶层逗号拆分 SV/C 调用参数，保留嵌套 cast、括号和字符串。
    输入输出及副作用：返回参数文本列表；不求值、不改变参数中的空白语义。
    失败边界：括号/字符串不平衡或空参数会抛 ContractError，避免错配 base/length。"""
    result: list[str] = []
    start = 0
    depth = 0
    in_string = False
    escaped = False
    for index, current in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif current == "\\":
                escaped = True
            elif current == '"':
                in_string = False
            continue
        if current == '"':
            in_string = True
        elif current == "(":
            depth += 1
        elif current == ")":
            depth -= 1
            if depth < 0:
                raise ContractError("call arguments have unbalanced parentheses")
        elif current == "," and depth == 0:
            value = text[start:index].strip()
            if not value:
                raise ContractError("call contains an empty argument")
            result.append(value)
            start = index + 1
    if in_string or depth:
        raise ContractError("call arguments are not balanced")
    value = text[start:].strip()
    if not value:
        raise ContractError("call contains an empty final argument")
    result.append(value)
    return result


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


def model_outcome(
    owner: int,
    expected_owner: int,
    opcode: int,
    supported_opcodes: Iterable[int] | None = None,
) -> tuple[str, int]:
    """功能：按 completion codec 的 source-derived supported set 给出 owner/ready 分层结果。
    输入输出及副作用：返回 (model_status, ready)，不写 driver request_error；可选集合来自 SV source walk。
    失败边界：owner 不匹配返回 OK/0；opcode 不在真实 supported_opcode 集合时返回 UNSUPPORTED_OPCODE/0；集合为空按默认冻结契约处理。"""
    if owner != expected_owner:
        return "OK", 0
    default_supported = {
        0, 1, 2, 3, 4, 5, 6, 9, 0x0A, 0x0C, 0x0E, 0x0F, 0x10,
        0x12, 0x13, 0x14, 0x16, 0x17, 0x20, 0x35, 0x37, 0x38,
        0x1C, 0x3A, 0x46, 0x47,
    }
    supported = set(supported_opcodes) if supported_opcodes is not None else default_supported
    if opcode not in supported:
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
    # Keep one frozen source of truth for both validation and CLI reporting.
    # Duplicating this map here would allow a future count change to make the
    # checker accept a report that its summary claims is invalid (or vice
    # versa).
    expected = dict(FROZEN_MUTATION_COUNTS)
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


def _parse_sv_literal(value: str) -> int:
    """功能：解析 SV 数值字面量为无符号 Python 整数，供 mask/坐标 source walk 使用。
    输入输出及副作用：返回整数；不调用仿真器或执行任意表达式。
    失败边界：非零宽十六进制、十进制或明确的全零 `'0` 之外的字面量均抛 ContractError。"""
    compact = "".join(value.split())
    if compact in {"'0", "'d0", "64'b0", "64'h0", "32'h0"}:
        return 0
    match = re.fullmatch(
        r"(?:[0-9]+)?'[hH]([0-9a-fA-F_]+)|(?:[0-9]+'[dD]([0-9_]+))",
        compact,
    )
    if match:
        hexadecimal, decimal = match.groups()
        return int((hexadecimal or decimal).replace("_", ""),
                   16 if hexadecimal is not None else 10)
    if re.fullmatch(r"(?:0[xX][0-9a-fA-F_]+|[0-9]+)", compact):
        return int(compact.replace("_", ""), 0)
    raise ContractError(f"unsupported SV literal: {value!r}")


def parse_sv_field_definitions(source: str) -> dict[str, tuple[int, int, int]]:
    """功能：读取 SV `RDMA_FIELD(name, byte, lsb, width)` 声明，作为 C 坐标漂移的对照证据。
    输入输出及副作用：返回 name 到 (byte,lsb,width) 的映射；数值仅用于比对，不反向生成 ABI 坐标。
    失败边界：同名声明不一致、超出 64-bit 范围或非法参数均抛 ContractError；注释/字符串不计入。"""
    text = _strip_sv_comments(source)
    result: dict[str, tuple[int, int, int]] = {}
    pattern = re.compile(r"\bRDMA_FIELD\s*\(")
    for match in pattern.finditer(text):
        args_start = text.find("(", match.start())
        args, _ = _balanced_delimited_text(text, args_start, "(", ")")
        values = _split_call_arguments(args)
        if len(values) != 4:
            # The macro declaration itself has symbolic parameter names; it is
            # not a field instance and is deliberately ignored.
            continue
        name = values[0].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            continue
        try:
            byte_offset = _parse_int(values[1], "SV field byte offset")
            lsb = _parse_int(values[2], "SV field lsb")
            width = _parse_int(values[3], "SV field width")
        except ContractError:
            continue
        if byte_offset % 8 or lsb > 63 or width <= 0 or width > 64 or lsb + width > 64:
            raise ContractError(f"invalid SV field declaration: {name}")
        current = (byte_offset, lsb, width)
        previous = result.get(name)
        if previous is not None and previous != current:
            raise ContractError(f"duplicate SV field declaration drift: {name}")
        result[name] = current
    return result


def parse_sv_derived_masks(source: str) -> dict[str, tuple[int, ...]]:
    """功能：解析 SV 64-bit 八 qword derived mask 数组，供 ownership 反向证明。
    输入输出及副作用：返回 mask 名称到八个整数的不可变元组；不采纳未知表达式或修改源码。
    失败边界：数组缺项、非法 literal、重复且不一致声明或超过 64 位均抛 ContractError。"""
    text = _strip_sv_comments(source)
    result: dict[str, tuple[int, ...]] = {}
    pattern = re.compile(
        r"\blocalparam\s+bit\s*\[\s*63\s*:\s*0\s*\]\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*0\s*:\s*7\s*\]"
        r"\s*=\s*'\s*\{(.*?)\}\s*;",
        re.S,
    )
    for match in pattern.finditer(text):
        name, body = match.groups()
        values = _split_call_arguments(body)
        if len(values) != 8:
            raise ContractError(f"SV derived mask {name} must contain eight qwords")
        parsed = tuple(_parse_sv_literal(value) for value in values)
        if any(value < 0 or value >= (1 << 64) for value in parsed):
            raise ContractError(f"SV derived mask {name} exceeds 64 bits")
        previous = result.get(name)
        if previous is not None and previous != parsed:
            raise ContractError(f"duplicate SV derived mask drift: {name}")
        result[name] = parsed
    return result


def validate_derived_masks(
    source: str,
    expected: Mapping[int, int] | Sequence[int],
    name: str,
) -> tuple[int, ...]:
    """功能：将命名 SV derived mask 与 C-derived expected qword union 精确比较。
    输入输出及副作用：返回实际八 qword mask；只读 source/expected，不启用任何 capability。
    失败边界：缺 mask、长度不为八、任一位与 C 坐标 union 不同均抛 ContractError。"""
    masks = parse_sv_derived_masks(source)
    actual = masks.get(name)
    if actual is None:
        raise ContractError(f"SV derived mask is missing: {name}")
    if isinstance(expected, Mapping):
        expected_values = tuple(int(expected[index]) for index in range(8))
    else:
        expected_values = tuple(int(value) for value in expected)
    if len(expected_values) != 8:
        raise ContractError(f"expected derived mask {name} must contain eight qwords")
    if actual != expected_values:
        raise ContractError(
            f"SV derived mask drift for {name}: {actual} != {expected_values}"
        )
    return actual


def _sv_macro_definitions(source: str) -> dict[str, tuple[tuple[str, ...], str]]:
    """功能：收集去注释 SV `define 的参数和续行正文，供宏展开 writer 扫描。
    输入输出及副作用：返回宏名到 (参数,正文) 映射；不执行预处理器或替换全局符号。
    失败边界：续行残缺、参数重复或同名正文漂移均抛 ContractError。"""
    text = _strip_sv_comments(source)
    logical_lines: list[str] = []
    pending = ""
    for raw_line in text.splitlines():
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
        raise ContractError("SV macro continuation is unterminated")
    result: dict[str, tuple[tuple[str, ...], str]] = {}
    pattern = re.compile(
        r"^\s*`define\s+([A-Za-z_][A-Za-z0-9_]*)"
        r"(?:\s*\(([^)]*)\))?\s*(.*?)\s*$"
    )
    for line in logical_lines:
        define_marker = re.match(r"^\s*`define\b", line)
        match = pattern.match(line)
        if match is None:
            if define_marker is not None:
                raise ContractError(
                    "malformed SV macro definition: " + line.strip()
                )
            continue
        name, parameter_text, body = match.groups()
        parameters = tuple(
            item.strip() for item in (parameter_text or "").split(",")
            if item.strip()
        )
        if len(parameters) != len(set(parameters)):
            raise ContractError(f"SV macro {name} has duplicate parameters")
        current = (parameters, body)
        previous = result.get(name)
        if previous is not None:
            if name in PRODUCTION_WRITER_MACROS:
                raise ContractError(
                    f"duplicate SV production macro definition: {name}"
                )
            if previous != current:
                raise ContractError(f"SV macro definition drift: {name}")
        result[name] = current
    return result


PRODUCTION_WRITER_MACROS = (
    "CMQ_QPC_PUT", "CMQ_ENVELOPE_PUT", "DB_PUT",
)


def _collect_sv_macro_definitions(
    sv_sources: Mapping[str, str],
) -> dict[str, tuple[tuple[str, ...], str]]:
    """功能：合并所有 SV source 的 production macro 定义并检查跨文件一致性。
    输入输出及副作用：返回宏名到参数/正文的只读映射；
    不执行预处理器或改写源码。
    失败边界：续行错误或同名正文漂移立即抛错；
    宏缺失由调用方拒绝。"""
    definitions: dict[str, tuple[tuple[str, ...], str]] = {}
    for source_path, source in sv_sources.items():
        parsed = _sv_macro_definitions(source)
        for name, current in parsed.items():
            previous = definitions.get(name)
            if previous is not None:
                if name in PRODUCTION_WRITER_MACROS:
                    raise ContractError(
                        "duplicate SV production macro definition: "
                        f"{name} in {source_path}"
                    )
                if previous != current:
                    raise ContractError(f"SV macro definition drift: {name}")
            definitions[name] = current
    return definitions


def _validate_production_macro_definitions(
    definitions: Mapping[str, tuple[tuple[str, ...], str]],
    required: Iterable[str],
) -> None:
    """功能：锁定 production writer macro 的二参数模板和唯一 typed put 调用。
    输入输出及副作用：只读 definitions；成功无返回值，不展开或执行
    SV 宏。
    失败边界：缺定义、参数漂移、坐标后缀缺失，或 put/put_field 非唯一均
    拒绝。"""
    for name in required:
        definition = definitions.get(name)
        if definition is None:
            raise ContractError(
                f"SV production macro definition is missing: {name}"
            )
        parameters, body = definition
        if parameters != ("STEM", "VALUE"):
            raise ContractError(f"SV production macro parameters drift: {name}")
        compact = _normalise_sv_expr(body)
        for suffix in ("STEM``_WORD_BYTE_OFFSET", "STEM``_LSB", "STEM``_WIDTH"):
            if suffix not in compact:
                raise ContractError(
                    f"SV production macro coordinate token is missing: {name}"
                )
        calls = []
        for call_name in ("put_field", "put"):
            calls.extend(_iter_sv_calls(body, call_name))
        if len(calls) != 1:
            raise ContractError(
                f"SV production macro typed writer is not unique: {name}"
            )


def _normalise_sv_expr(value: str) -> str:
    """功能：去除 SV/C 表达式无意义空白，供参数和 target-flow 精确比较。
    输入输出及副作用：返回紧凑字符串；不求值、不改变标识符或运算符。
    失败边界：空表达式返回空串，由调用方按缺失参数拒绝。"""
    return re.sub(r"\s+", "", value)


def _case_context_from_coordinates(
    coordinates: Mapping[tuple[str, str, str, str], int],
    entry: str,
    opcode: str,
    direction: str,
) -> dict[str, tuple[int, int, int]]:
    """功能：从 C-derived base map 构造当前 case 的 macro→(base,lsb,width) 坐标。
    输入输出及副作用：返回新映射；不读取 SV mask，也不修改传入坐标。
    失败边界：case 没有完整宏坐标时抛 ContractError，禁止由 SV 常量补齐 ABI。"""
    context: dict[str, tuple[int, int, int]] = {}
    for key, base in coordinates.items():
        if key[:3] != (entry, opcode, direction):
            continue
        macro = key[3]
        # Width/LSB are supplied later by the caller's macro range map.  A
        # sentinel here makes accidental use without that map fail closed.
        context[macro] = (int(base), -1, -1)
    return context


def parse_supported_opcode_values(
    sv_sources: Mapping[str, str],
    enum_members: Sequence[tuple[str, int]],
) -> frozenset[int]:
    """功能：从真实 completion codec 的 supported_opcode 函数解析可解码 opcode 集合。
    输入输出及副作用：返回 enum numeric value 的不可变集合；不引入 Python 独立 opcode 白名单。
    失败边界：函数/分支缺失、未知 enum symbol、重复或空集合均抛 ContractError，防止状态错报。"""
    joined = "\n".join(_strip_sv_comments(source) for source in sv_sources.values())
    try:
        body = _sv_function_body(joined, "supported_opcode")
    except ContractError as exc:
        raise ContractError(f"completion supported_opcode source is invalid: {exc}") from exc
    # 表驱动 opcode 经 rdma_cmq_request_field_specs 的 case 标签进入支持集合。
    if "rdma_cmq_request_field_specs(" in body:
        body += _sv_function_body(joined, "rdma_cmq_request_field_specs")
    by_symbol = {symbol: value for symbol, value in enum_members}
    values: set[int] = set()
    for token in SUPPORTED_OPCODE_NAME_RE.findall(body):
        candidates = [token]
        if token.startswith("RDMA_OP_"):
            candidates.append("XTRDMA_" + token[len("RDMA_"):])
            candidates.append("TRDMA_" + token[len("RDMA_"):])
        if token.startswith("TRDMA_OP_"):
            candidates.append("XTRDMA_" + token[len("TRDMA_"):])
        symbol = next((candidate for candidate in candidates if candidate in by_symbol), None)
        if symbol is None:
            raise ContractError(f"supported_opcode references unknown enum symbol: {token}")
        values.add(by_symbol[symbol])
    if not values:
        raise ContractError("supported_opcode source has no registered values")
    return frozenset(values)


def _sv_field_stem(value: str) -> str:
    """功能：把 SV writer 的字段常量或其 WORD_BYTE_OFFSET/LSB/WIDTH 后缀还原为 stem。
    输入输出及副作用：返回紧凑 stem；不把 stem 的数字坐标写回 C map。
    失败边界：空 token 或含非法字符返回空串，由 writer scanner 按未知写入保守拒绝。"""
    stem = value.strip().strip("`")
    stem = re.sub(r"_(?:WORD_BYTE_OFFSET|LSB|WIDTH)$", "", stem)
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", stem):
        return ""
    return stem


def _c_macro_for_sv_stem(stem: str) -> str | None:
    """功能：将 SV 字段 stem 映射为 C 驱动宏名，仅作为别名解析而不提供坐标。
    输入输出及副作用：返回 C macro 名或 None；不读取 SV mask、不修改映射。
    失败边界：未知 stem、宽度后缀或非字段 token 返回 None，调用方必须按未知 writer 处理。"""
    normalized = _sv_field_stem(stem)
    if not normalized:
        return None
    if normalized in SV_FIELD_ALIASES:
        return SV_FIELD_ALIASES[normalized]
    if normalized.startswith("XTRDMA_CMQ"):
        return normalized
    return None


def _coordinate_tuple(
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[object, tuple[int, int, int]] | None,
    context_key: tuple[str, str, str],
    macro: str,
) -> tuple[int, int, int] | None:
    """功能：读取指定 case 的 C-derived (byte,lsb,width) 坐标，支持验证 fixture 的 tuple map。
    输入输出及副作用：返回新 tuple；优先采用显式 macro_ranges，base 仍必须来自 coordinates。
    失败边界：缺少 base/lsb/width 或类型不符返回 None，禁止从 SV 常量猜测 ABI。"""
    key = (*context_key, macro)
    if key not in coordinates:
        return None
    raw_base = coordinates[key]
    base: int
    lsb: int | None = None
    width: int | None = None
    if isinstance(raw_base, (tuple, list)) and len(raw_base) == 3:
        base, lsb, width = (int(raw_base[0]), int(raw_base[1]), int(raw_base[2]))
    else:
        base = int(raw_base)
    range_value = None
    if macro_ranges:
        # Prefer a context-qualified range so a future case can legally place
        # the same C macro at a different qword.  The legacy macro-only form
        # remains accepted for small fixtures and current unique fields.
        range_value = macro_ranges.get((*context_key, macro))
        if range_value is None:
            range_value = macro_ranges.get(macro)
    if range_value is not None:
        range_base, range_lsb, range_width = range_value
        if range_base != base:
            raise ContractError(
                f"C coordinate base sources disagree for {macro}: {base} != {range_base}"
            )
        lsb, width = int(range_lsb), int(range_width)
    if lsb is None or width is None or lsb < 0 or width <= 0:
        return None
    if base < 0 or lsb + width > 64:
        raise ContractError(f"C-derived coordinate is outside qword for {macro}")
    return base, lsb, width


def _resolve_sv_coordinate(
    expression: str,
    role: str,
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[str, tuple[int, int, int]] | None,
    context_key: tuple[str, str, str],
) -> int | None:
    """功能：解析 writer call 的 base/lsb/width 参数并绑定到 C-derived 字段坐标。
    输入输出及副作用：返回对应整数或 None；只做受限字面量/后缀解析，不执行表达式。
    失败边界：未知符号、复杂算术、负数或字段不在 context 时返回 None，触发整图保守范围。"""
    compact = _normalise_sv_expr(expression)
    if compact.startswith("(") and compact.endswith(")"):
        compact = compact[1:-1]
    try:
        return _parse_sv_literal(compact)
    except ContractError:
        pass
    suffixes = {
        "base": "_WORD_BYTE_OFFSET",
        "lsb": "_LSB",
        "width": "_WIDTH",
    }
    suffix = suffixes[role]
    if compact.endswith(suffix):
        stem = compact[:-len(suffix)]
        macro = _c_macro_for_sv_stem(stem)
        if macro is None:
            return None
        coordinate = _coordinate_tuple(
            coordinates, macro_ranges, context_key, macro
        )
        if coordinate is None:
            return None
        return {"base": coordinate[0], "lsb": coordinate[1],
                "width": coordinate[2]}[role]
    # A simple parenthesised/additive byte expression is common for memcpy
    # destinations.  Only permit a numeric displacement; symbols remain
    # unresolved and therefore fail closed.
    match = re.fullmatch(r"([0-9]+)\+([0-9]+)", compact)
    if match and role == "base":
        return int(match.group(1), 10) + int(match.group(2), 10)
    return None


def _iter_sv_calls(text: str, name: str):
    """功能：迭代去注释 SV 文本中指定调用及其参数区间。
    输入输出及副作用：逐项 yield (start,end,args_text)；不执行调用或修改文本。
    失败边界：任一匹配的括号不平衡立即抛 ContractError，避免错读后续 writer。"""
    pattern = re.compile(r"(?<![A-Za-z0-9_])(?:`)?" + re.escape(name) + r"\s*\(")
    for match in pattern.finditer(text):
        open_index = text.find("(", match.start(), match.end())
        args, end = _balanced_delimited_text(text, open_index, "(", ")")
        yield match.start(), end, args


def _writer_range_from_call(
    call_name: str,
    args_text: str,
    case_id: str,
    source_path: str,
    token: str,
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[str, tuple[int, int, int]] | None,
    context_key: tuple[str, str, str],
    image_length: int,
) -> WriterRange:
    """功能：把一个 put/put_field 调用的参数解析成 writer 位区间。
    输入输出及副作用：返回不可变 WriterRange；C-derived 坐标是唯一数字依据。
    失败边界：参数数量、符号或范围无法闭合时返回整幅 image 的保守区间，供上层拒绝 static bit。"""
    try:
        args = _split_call_arguments(args_text)
    except ContractError:
        args = []
    if call_name == "put_field":
        if len(args) >= 4:
            fields = args[-4:]
        else:
            fields = []
    else:  # put(builder, base, lsb, width, value)
        if len(args) >= 5:
            fields = args[-4:]
        elif len(args) >= 4:
            fields = args[:3] + [args[3]]
        else:
            fields = []
    if len(fields) >= 3:
        base = _resolve_sv_coordinate(
            fields[0], "base", coordinates, macro_ranges, context_key
        )
        lsb = _resolve_sv_coordinate(
            fields[1], "lsb", coordinates, macro_ranges, context_key
        )
        width = _resolve_sv_coordinate(
            fields[2], "width", coordinates, macro_ranges, context_key
        )
        if base is not None and lsb is not None and width is not None:
            if base % 8 or lsb < 0 or width <= 0 or lsb + width > 64:
                raise ContractError(f"SV writer coordinate is invalid: {token}")
            return WriterRange(
                case_id, source_path, "PUT_FIELD", token, base, lsb, width
            )
    return WriterRange(
        case_id, source_path, "UNKNOWN_WRITER", token, 0, 0, image_length * 8
    )


def _expanded_macro_writer_ranges(
    macro_body: str,
    parameters: Sequence[str],
    values: Sequence[str],
    case_id: str,
    source_path: str,
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[str, tuple[int, int, int]] | None,
    context_key: tuple[str, str, str],
    image_length: int,
) -> list[WriterRange]:
    """功能：展开一次 production macro invocation 并解析其唯一 typed writer。
    输入输出及副作用：返回 writer ranges；只读宏模板和 C-derived 坐标，
    不执行 SV。
    失败边界：无 writer 或出现多个 put/put_field 时拒绝 alias-only 证明。"""
    expanded = _expand_sv_writer_macro(macro_body, parameters, values)
    calls: list[tuple[str, str, str]] = []
    for call_name in ("put_field", "put"):
        for start, end, args_text in _iter_sv_calls(expanded, call_name):
            calls.append((call_name, expanded[start:end], args_text))
    if len(calls) != 1:
        raise ContractError("SV production macro typed writer is not unique")
    call_name, token, args_text = calls[0]
    return [_writer_range_from_call(
        call_name, args_text, case_id, source_path, token,
        coordinates, macro_ranges, context_key, image_length,
    )]


def _expand_sv_writer_macro(
    body: str,
    parameters: Sequence[str],
    values: Sequence[str],
) -> str:
    """功能：以一次 invocation 的实际 stem/value 展开 SV writer macro 的 token 拼接。
    输入输出及副作用：返回局部展开文本；不执行宏副作用或修改定义。
    失败边界：参数数量不符时立即抛错，禁止把未展开模板当作 writer
    证据。"""
    if len(parameters) != len(values):
        raise ContractError("SV production macro invocation arity mismatch")
    expanded = body
    for parameter, value in zip(parameters, values):
        expanded = re.sub(
            re.escape(parameter) + r"``(?=_)|" + re.escape(parameter),
            lambda match: value if match.group().endswith(parameter) else value,
            expanded,
        )
    # The expression above intentionally handles both STEM``_FOO and VALUE;
    # normalize any residual token-concatenation punctuation for later parsing.
    return expanded.replace("``", "")


def _strip_sv_macro_definitions(text: str) -> str:
    """功能：移除 SV function 文本中的 `define 续行，避免宏模板被误报为 writer。
    输入输出及副作用：返回保留真实语句的新文本；不执行预处理器，也不改变调用方源码。
    失败边界：未闭合的宏续行会保留为无 writer 证据，随后由 source-walk 的缺失检查拒绝。"""
    kept: list[str] = []
    in_definition = False
    continuation = chr(92)
    for line in text.splitlines(keepends=True):
        if in_definition:
            in_definition = line.rstrip("\r\n").endswith(continuation)
            continue
        if re.match(r"^\s*`define\b", line):
            in_definition = line.rstrip("\r\n").endswith(continuation)
            continue
        kept.append(line)
    return "".join(kept)


def _sv_begin_block_body(source: str, begin_index: int) -> str:
    """功能：提取从指定 begin 到配对 end 的 SV 结构块正文。
    输入输出及副作用：返回不含外层 begin/end 的源码；只读文本，不执行
    语句或宏。
    失败边界：起点不是 begin、嵌套块不平衡或缺少闭合 end 时抛
    ContractError。"""
    if begin_index < 0 or not re.match(r"\bbegin\b", source[begin_index:]):
        raise ContractError("SV block does not start with begin")
    token_re = re.compile(r"\bbegin\b|\bend\b")
    depth = 0
    body_start = begin_index + len("begin")
    for token in token_re.finditer(source, begin_index):
        if token.group() == "begin":
            depth += 1
            continue
        depth -= 1
        if depth == 0:
            return source[body_start:token.start()]
    raise ContractError("SV begin/end block is unbalanced")


def _validate_compose_merge_assignments(
    body: str,
    merge_block: str,
) -> None:
    """功能：审计 compose_request 中 merged_word 的全部赋值和按位更新。
    输入输出及副作用：只读函数正文和 merge 节点；成功无返回值，不执行
    SV 表达式。
    失败边界：除一次 envelope|body OR 与一次 candidate image 读取外，其他赋值、
    复合更新或 bit-select 均抛 ContractError。"""
    compact = _normalise_sv_expr(body)
    assignment_pattern = re.compile(
        r"merged_word\s*(?P<index>\[[^]]+\])?\s*"
        r"(?P<operator><=|<<=|>>=|\|=|&=|\^=|\+=|-=|\*=|/=|%=|=|\+\+|--)",
    )
    allowed = {"envelope_word|body_word", "image_word(candidate,q)"}
    seen: list[tuple[str, int]] = []
    for match in assignment_pattern.finditer(compact):
        operator = match.group("operator")
        index = match.group("index")
        if index is not None or operator != "=":
            raise ContractError("compose_request mutates merged_word after merge")
        statement_end = compact.find(";", match.end())
        if statement_end < 0:
            raise ContractError("compose_request merged_word assignment is incomplete")
        value = compact[match.end():statement_end]
        if value not in allowed:
            raise ContractError("compose_request merged_word assignment is not canonical")
        seen.append((value, match.start()))

    or_assignments = [item for item in seen if item[0] == "envelope_word|body_word"]
    image_assignments = [
        item for item in seen if item[0] == "image_word(candidate,q)"
    ]
    if len(or_assignments) != 1 or len(image_assignments) != 1:
        raise ContractError("compose_request merged_word assignments are not unique")
    if _normalise_sv_expr(merge_block).count(
        "merged_word=envelope_word|body_word;"
    ) != 1:
        raise ContractError("compose_request merge OR is outside its canonical loop")


def _compose_image_declarations(body: str) -> set[str]:
    """功能：收集 compose_request 中显式声明的 rdma_hw_image 对象名称。
    输入输出及副作用：返回名称集合；只读函数正文，不执行 SV 或改变
    源码。
    失败边界：声明含数组、非法标识符或逗号结构不平衡时抛 ContractError，
    防止隐藏未审计的 image alias。"""
    declaration_text = re.sub(
        r'"(?:\\.|[^"\\])*"', '""', body
    )
    pattern = re.compile(r"\brdma_hw_image\s+([^;]+);")
    names: set[str] = set()
    for match in pattern.finditer(declaration_text):
        try:
            parts = _split_call_arguments(match.group(1))
        except ContractError as exc:
            raise ContractError(
                "compose_request image declaration is malformed"
            ) from exc
        for part in parts:
            item = part.strip()
            name_match = re.fullmatch(
                r"([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*.*)?",
                item,
                re.S,
            )
            if name_match is None:
                raise ContractError(
                    "compose_request image declaration is malformed"
                )
            name = name_match.group(1)
            if name in names:
                raise ContractError(
                    f"compose_request image declaration is duplicated: {name}"
                )
            names.add(name)
    return names


def _iter_compose_assignments(body: str):
    """功能：迭代 compose_request 中的简单变量赋值，供 image alias 流追踪。
    输入输出及副作用：逐项返回 (owner, operator, value)；不求值、不修改
    正文。
    失败边界：未闭合分号的赋值不会被当作合法 flow，调用方须检查必需
    发布点。"""
    pattern = re.compile(
        r"(?<![.A-Za-z0-9_])(?P<owner>[A-Za-z_][A-Za-z0-9_]*)\s*"
        r"(?P<operator><=|<<=|>>=|\|=|&=|\^=|\+=|-=|\*=|/=|%=|=(?!=))"
        r"\s*(?P<value>[^;]*);",
        re.S,
    )
    for match in pattern.finditer(body):
        yield (
            match.group("owner"),
            match.group("operator"),
            match.group("value"),
        )


def _validate_compose_image_mutators(
    body: str,
    merge_block: str,
) -> None:
    """功能：追踪 compose_request 内全部 image alias，锁定 candidate/result 的
    canonical flow 以及唯一 merged bytes writer。
    输入输出及副作用：只读函数正文和 merge 节点；成功无返回值，不执行
    SV。
    失败边界：未声明 alias、任何 alias rebind、bytes 方法/索引/容器写、
    对象重绑或 compound merge 均抛 ContractError；envelope canonical 输入
    链仅准许固定赋值。"""
    source = _strip_sv_comments(body)
    compact = _normalise_sv_expr(source)
    canonical_names = {
        "candidate", "result", "envelope_image", "canonical_envelope_image",
    }
    input_names = {"body", "qpc_signature_source"}
    allowed_names = canonical_names | input_names
    declared_names = _compose_image_declarations(source)
    unknown_declarations = declared_names - allowed_names
    if unknown_declarations:
        names = ", ".join(sorted(unknown_declarations))
        raise ContractError(
            f"compose_request declares an unapproved image alias: {names}"
        )
    image_names = allowed_names | declared_names
    image_name_pattern = "|".join(
        re.escape(name)
        for name in sorted(image_names, key=len, reverse=True)
    )
    qualified_member = re.compile(
        r"\b[A-Za-z_][A-Za-z0-9_]*\s*\.\s*(?:"
        + image_name_pattern
        + r")\s*\.\s*(?:bytes|length|alignment|endian|image_kind)\b"
    )
    if qualified_member.search(compact):
        raise ContractError("compose_request qualifies an image alias")

    qualified_assignment = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*"
        r"([A-Za-z_][A-Za-z0-9_]*)\s*"
        r"(?:<=|<<=|>>=|\|=|&=|\^=|\+=|-=|\*=|/=|%=|=(?!=))"
        r"\s*([^;]*);"
    )
    for match in qualified_assignment.finditer(compact):
        prefix, owner, value = match.groups()
        direct_name_match = re.fullmatch(
            r"\(*([A-Za-z_][A-Za-z0-9_]*)\)*", value
        )
        direct_name = (
            direct_name_match.group(1) if direct_name_match else None
        )
        if prefix not in image_names and (
            owner in image_names or direct_name in image_names
        ):
            raise ContractError("compose_request qualifies an image alias")
    object_update = re.compile(
        r"(?:\+\+|--)\s*(?:" + image_name_pattern + r")\b|"
        r"(?:" + image_name_pattern + r")\s*(?:\+\+|--)\b"
    )
    if object_update.search(compact):
        raise ContractError("compose_request updates an image object")

    member_pattern = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*bytes\b"
    )
    for owner in {match.group(1) for match in member_pattern.finditer(compact)}:
        if owner not in image_names:
            raise ContractError(
                f"compose_request references an undeclared image alias: {owner}"
            )

    constructor = (
        'rdma_hw_image::type_id::create("rdma_cmq_request")'
    )
    allowed_assignments = {
        ("result", "null"),
        ("result", "candidate"),
        ("candidate", constructor),
        ("envelope_image", "null"),
        ("canonical_envelope_image", "null"),
        ("envelope_image", "canonical_envelope_image"),
    }
    assignment_counts: Counter[tuple[str, str]] = Counter()
    for owner, operator, raw_value in _iter_compose_assignments(source):
        value = _normalise_sv_expr(raw_value)
        direct_name_match = re.fullmatch(
            r"\(*([A-Za-z_][A-Za-z0-9_]*)\)*", value
        )
        direct_name = (
            direct_name_match.group(1) if direct_name_match else None
        )
        if owner not in image_names:
            if direct_name in image_names:
                raise ContractError("compose_request rebinds an image alias")
            continue
        if owner in input_names:
            raise ContractError("compose_request rebinds an input image")
        if operator != "=" or (owner, value) not in allowed_assignments:
            raise ContractError("compose_request rebinds an image object")
        assignment_counts[(owner, value)] += 1

    if assignment_counts[("result", "null")] != 1:
        raise ContractError("compose_request result initialization is not unique")
    if assignment_counts[("result", "candidate")] != 1:
        raise ContractError("compose_request result publication is not unique")
    if assignment_counts[("candidate", constructor)] != 1:
        raise ContractError("compose_request candidate allocation is not unique")
    for owner in ("envelope_image", "canonical_envelope_image"):
        for value in ("null", "canonical_envelope_image"):
            if assignment_counts[(owner, value)] > 1:
                raise ContractError(
                    "compose_request canonical image assignment is not unique"
                )

    object_method_pattern = re.compile(
        r"\b(?:" + image_name_pattern + r")\s*\.\s*"
        r"(?!bytes\b)[A-Za-z_][A-Za-z0-9_]*\s*\("
    )
    if object_method_pattern.search(compact):
        raise ContractError("compose_request calls an image mutator")

    canonical_push = (
        "candidate.bytes.push_back(merged_word[63-(i*8)-:8]);"
    )
    method_pattern = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\.bytes\."
        r"([A-Za-z_][A-Za-z0-9_]*)\s*\("
    )
    push_count = 0
    for match in method_pattern.finditer(compact):
        owner = match.group(1)
        if owner not in image_names:
            raise ContractError(
                f"compose_request references an undeclared image alias: {owner}"
            )
        open_index = compact.find("(", match.start(), match.end())
        _, end = _balanced_delimited_text(compact, open_index, "(", ")")
        call = compact[match.start():end] + ";"
        if owner != "candidate" or call != canonical_push:
            raise ContractError("compose_request has an unapproved image mutator")
        push_count += 1
    if push_count != 1:
        raise ContractError("compose_request merged output writer is not unique")
    if _normalise_sv_expr(merge_block).count(canonical_push) != 1:
        raise ContractError("compose_request merged output writer is outside merge loop")

    direct_assignment = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\.bytes\s*"
        r"(?:<=|<<=|>>=|\|=|&=|\^=|\+=|-=|\*=|/=|%=|=(?!=))"
    )
    for match in direct_assignment.finditer(compact):
        owner = match.group(1)
        if owner not in image_names:
            raise ContractError(
                f"compose_request references an undeclared image alias: {owner}"
            )
        raise ContractError("compose_request assigns the image bytes container")

    index_pattern = re.compile(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\.bytes\s*\["
    )
    signature_writes = 0
    write_operators = re.compile(
        r"^(?:<=|<<=|>>=|\|=|&=|\^=|\+=|-=|\*=|/=|%=|=(?!=)|\+\+|--)"
    )
    for match in index_pattern.finditer(compact):
        owner = match.group(1)
        if owner not in image_names:
            raise ContractError(
                f"compose_request references an undeclared image alias: {owner}"
            )
        open_index = compact.find("[", match.start(), match.end())
        index_text, end = _balanced_delimited_text(compact, open_index, "[", "]")
        tail = compact[end:]
        operator_match = write_operators.match(tail)
        if operator_match is None:
            continue
        operator = operator_match.group()
        if (
            owner == "candidate"
            and index_text == "signature_byte"
            and operator == "="
        ):
            statement_end = compact.find(";", end + len(operator))
            if statement_end < 0:
                raise ContractError("compose_request signature writer is incomplete")
            value = compact[end + len(operator):statement_end]
            if value != "~signature":
                raise ContractError("compose_request signature writer value drift")
            signature_writes += 1
            continue
        raise ContractError("compose_request has an unapproved indexed image writer")
    if signature_writes > 1:
        raise ContractError("compose_request signature writer is not unique")

    prefix_update = re.compile(
        r"(?:\+\+|--)\s*\b([A-Za-z_][A-Za-z0-9_]*)\.bytes\s*\["
    )
    for match in prefix_update.finditer(compact):
        owner = match.group(1)
        if owner not in image_names:
            raise ContractError(
                f"compose_request references an undeclared image alias: {owner}"
            )
        raise ContractError("compose_request has a prefix indexed image writer")


def _validate_compose_request_writer(
    sv_sources: Mapping[str, str],
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[object, tuple[int, int, int]] | None,
    writer_ranges: Sequence[WriterRange],
) -> None:
    """功能：验证 request composer 的真实 output merge，并把其输入 writer
    绑定到 C 坐标。
    输入输出及副作用：只读 SV、coordinates 和已扫描 ranges；成功无返回值，
    不生成新 mask。
    失败边界：缺 composer/function/output、缺 envelope/body merge、静态 bytes
    绕写或 C writer 缺失均抛 ContractError。"""
    candidates: list[tuple[str, str, str]] = []
    production_context = False
    for source_path, raw_source in sv_sources.items():
        source = _strip_sv_comments(raw_source)
        if re.search(r"\bclass\s+rdma_hw_cmq_qpc_layout_codec\b", source):
            production_context = True
        if not re.search(
            r"\bclass\s+rdma_hw_cmq_request_composer\b", source
        ):
            continue
        production_context = True
        class_body = _sv_class_body(source, "rdma_hw_cmq_request_composer")
        function_body = _sv_function_body(class_body, "compose_request")
        candidates.append((source_path, class_body, function_body))
    if not production_context:
        return
    if len(candidates) != 1:
        raise ContractError(
            "CMQ production source must contain one request composer compose_request"
        )
    source_path, class_body, body = candidates[0]
    declaration_matches = list(re.finditer(
        r"\bfunction\b[^;]*\bcompose_request\s*\([^;]*\)\s*;",
        class_body,
        re.S,
    ))
    if len(declaration_matches) != 1:
        raise ContractError("compose_request declaration is not unique")
    declaration = declaration_matches[0].group()
    if not re.search(
        r"\boutput\s+rdma_hw_image\s+result\b", declaration
    ):
        raise ContractError("compose_request output result is not declared")

    compact = _normalise_sv_expr(body)

    def require_fragment(pattern: str, label: str) -> None:
        """功能：要求 compose_request 文本含一个结构化契约片段。
        输入输出及副作用：匹配 compact 文本并返回空值；不执行匹配内容。
        失败边界：片段缺失时抛 ContractError，防止相似字符串代替真实
        data flow。"""
        if re.search(pattern, compact) is None:
            raise ContractError(f"compose_request is missing {label}")

    require_fragment(r"result=null;", "output initialization")
    require_fragment(
        r"envelope_codec\.encode\(envelope,envelope_image\)",
        "envelope encode",
    )
    require_fragment(
        r"ownership\.lookup\(envelope_snapshot\.opcode,input_kind,masks\)",
        "C-derived ownership lookup",
    )
    require_fragment(
        r'candidate=rdma_hw_image::type_id::create\("rdma_cmq_request"\);',
        "candidate allocation",
    )
    require_fragment(r"result=candidate;", "output publication")
    # Keep accepting the original explicit complement while also recognizing
    # the shared helper used by the production composer.  Both spellings must
    # prove the same merged-word predicate; accepting only the helper name (or
    # either mask in isolation) would let a writer bypass the C-derived
    # envelope/body ownership contract.
    ownership_check_patterns = (
        r"merged_word&~\(request_envelope_mask\(q\)\|masks\[q\]\)",
        r"rdma_raw_qword_mask_is_valid\(merged_word,"
        r"request_envelope_mask\(q\)\|masks\[q\]\)",
    )
    if not any(re.search(pattern, compact) for pattern in ownership_check_patterns):
        raise ContractError("compose_request is missing C-derived ownership check")

    q_loop_pattern = re.compile(
        r"for\s*\(\s*int\s+unsigned\s+q\s*=\s*0\s*;"
        r"\s*q\s*<\s*8\s*;\s*q\+\+\s*\)\s*begin",
        re.S,
    )
    merge_blocks: list[str] = []
    for match in q_loop_pattern.finditer(body):
        begin_index = body.find("begin", match.start(), match.end())
        block = _sv_begin_block_body(body, begin_index)
        block_compact = _normalise_sv_expr(block)
        if "candidate.bytes.push_back" not in block_compact:
            continue
        merge_blocks.append(block_compact)
    if len(merge_blocks) != 1:
        raise ContractError(
            f"compose_request output merge loop is not unique: {len(merge_blocks)}"
        )
    merge_block = merge_blocks[0]
    for pattern, label in (
        (r"envelope_word=image_word\(envelope_image,q\);", "envelope image flow"),
        (r"body_word=image_word\(body,q\);", "body image flow"),
        (r"merged_word=envelope_word\|body_word;", "envelope/body merge"),
        (r"candidate\.bytes\.push_back\(merged_word\[63-\(i\*8\)-:8\]\);",
         "merged output write"),
    ):
        if re.search(pattern, merge_block) is None:
            raise ContractError(f"compose_request merge lacks {label}")

    _validate_compose_merge_assignments(body, merge_block)
    _validate_compose_image_mutators(body, merge_block)
    if "candidate.bytes[signature_byte]=~signature;" in compact:
        require_fragment(
            r"signature_byte=RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET\+"
            r"\(7-\(RDMA_CMQ_SIGNATURE_LSB>>3\)\);",
            "C-derived signature byte",
        )

    if macro_ranges is None:
        return
    qpc_context = ("CMQ_SQE", "QPC_CREATE", "REQUEST")
    required_macros = (
        "XTRDMA_CMQSQ_WQE_VALID", "XTRDMA_CMQSQ_VFID_OVERRIDE",
        "XTRDMA_CMQSQ_USE_VFID", "XTRDMA_CMQSQ_WQE_WRAP",
        "XTRDMA_CMQSQ_WQE_INDEX", "XTRDMA_CMQCQ_OPCODE",
        "XTRDMA_CMQSQ_WQE_QPN", "XTRDMA_CMQSQ_WQE_RQ_CQN",
        "XTRDMA_CMQSQ_WQE_SIGN_EN", "XTRDMA_CMQSQ_WQE_SIGNATURE",
        "XTRDMA_CMQSQ_WQE_SQ_CQN",
        "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR",
    )
    for macro in required_macros:
        coordinate = _coordinate_tuple(
            coordinates, macro_ranges, qpc_context, macro
        )
        if coordinate is None:
            raise ContractError(
                f"compose_request has no C-derived coordinate: {macro}"
            )
        if not any(
            item.case_id == "cmq_sqe_qpc_create_request" and
            (item.base, item.lsb, item.width) == coordinate
            for item in writer_ranges
        ):
            raise ContractError(
                f"compose_request input writer is missing: {macro}"
            )

def _scan_sv_writer_ranges(
    sv_sources: Mapping[str, str],
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[str, tuple[int, int, int]] | None = None,
) -> list[WriterRange]:
    """功能：扫描 QPC/CMQ-doorbell production branches 的 typed/direct writer 位区间。
    输入输出及副作用：返回去重后的 WriterRange 列表；注释和字符串不形成 writer 证据。
    失败边界：缺 class/function/branch、未知 writer 或不平衡宏均按整幅 image 记录或抛 ContractError，绝不漏报。"""
    ranges: list[WriterRange] = []
    production_context = False
    production_class_names = (
        "rdma_hw_cmq_qpc_layout_codec",
        "rdma_hw_cmq_request_composer",
        "rdma_hw_cmq_envelope_codec",
        "rdma_hw_doorbell_codec",
    )
    source_texts = {
        path: _strip_sv_comments(source)
        for path, source in sv_sources.items()
    }
    production_context = any(
        _has_sv_class_declaration(source, class_name)
        for source in source_texts.values()
        for class_name in production_class_names
    )
    all_sv_fields = parse_sv_field_definitions(
        "\n".join(_strip_sv_comments(source) for source in sv_sources.values())
    )
    contexts = {
        "cmq_sqe_qpc_create_request":
            (("CMQ_SQE", "QPC_CREATE", "REQUEST"),
             "rdma_hw_cmq_qpc_layout_codec", "RDMA_OP_QPC_CREATE", 64),
        "cmq_sq_doorbell":
            (("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST"),
             "rdma_hw_doorbell_codec", '"cmq_sq"', 8),
    }
    all_macros = _collect_sv_macro_definitions(sv_sources)
    if production_context:
        missing_classes = [
            class_name for class_name in production_class_names
            if not any(
                _has_sv_class_declaration(source, class_name)
                for source in source_texts.values()
            )
        ]
        if missing_classes:
            raise ContractError(
                "CMQ production class is missing: " + ", ".join(missing_classes)
            )
        _validate_production_macro_definitions(
            all_macros, PRODUCTION_WRITER_MACROS
        )
    for source_path, raw_source in sv_sources.items():
        source = source_texts[source_path]
        macros = all_macros
        sv_fields = all_sv_fields
        for case_id, (context_key, class_name, branch_label, image_length) in contexts.items():
            if not _has_sv_class_declaration(source, class_name):
                continue
            try:
                class_body = _sv_class_body(source, class_name)
                function_body = _sv_function_body(class_body, "encode_fields")
                branch = _sv_case_branch(function_body, branch_label)
            except ContractError as exc:
                # Once a production class is present, a malformed function or
                # branch is evidence of an invalid source walk—not an absent
                # writer.  Silently continuing would let a broken branch make
                # every bit look STATIC_UNWRITABLE and could enable a forged
                # capability through a stale table.
                raise ContractError(
                    f"CMQ production writer source is invalid in "
                    f"{source_path}/{class_name}: {exc}"
                ) from exc
            # Invocations of the two production macros are expanded and checked
            # against both their aliases and the actual C-derived coordinates.
            invocation_name = (
                "CMQ_QPC_PUT" if case_id.startswith("cmq_sqe") else "DB_PUT"
            )
            for invocation_start, invocation_end, args_text in _iter_sv_calls(
                branch, invocation_name
            ):
                args = _split_call_arguments(args_text)
                stem = args[0] if args else ""
                macro = _c_macro_for_sv_stem(stem)
                token = branch[invocation_start:invocation_end]
                coordinate = (
                    _coordinate_tuple(
                        coordinates, macro_ranges, context_key, macro
                    ) if macro else None
                )
                if coordinate is None:
                    ranges.append(WriterRange(
                        case_id, source_path, "UNKNOWN_WRITER", token,
                        0, 0, image_length * 8,
                    ))
                else:
                    sv_name = _sv_field_stem(stem)
                    sv_coordinate = sv_fields.get(sv_name)
                    if sv_coordinate is None:
                        ranges.append(WriterRange(
                            case_id, source_path, "UNKNOWN_WRITER", token,
                            0, 0, image_length * 8,
                        ))
                    elif sv_coordinate != coordinate:
                        raise ContractError(
                            f"SV writer alias coordinate drift for {sv_name}: "
                            f"{sv_coordinate} != {coordinate}"
                        )
                    else:
                        ranges.append(WriterRange(
                            case_id, source_path, "MACRO_PUT", token,
                            coordinate[0], coordinate[1], coordinate[2],
                        ))
                definition = macros.get(invocation_name)
                if definition is None:
                    raise ContractError(
                        f"SV production macro definition is missing: "
                        f"{invocation_name}"
                    )
                parameters, macro_body = definition
                ranges.extend(_expanded_macro_writer_ranges(
                    macro_body, parameters, args, case_id, source_path,
                    coordinates, macro_ranges, context_key, image_length,
                ))
            # The QPC request image is composed from a separately encoded
            # envelope.  Walk that production writer as well; otherwise an
            # envelope edit could silently acquire a supposedly static bit
            # while the body branch still looks unchanged.
            if case_id == "cmq_sqe_qpc_create_request":
                envelope_class = "rdma_hw_cmq_envelope_codec"
                if envelope_class in source:
                    try:
                        envelope_body = _sv_class_body(source, envelope_class)
                        envelope_function = _sv_function_body(
                            envelope_body, "encode"
                        )
                    except ContractError as exc:
                        raise ContractError(
                            f"CMQ envelope production path is invalid: {exc}"
                        ) from exc
                    if envelope_function:
                        # Macro templates are declarations, not runtime calls.
                        envelope_scan = _strip_sv_macro_definitions(
                            envelope_function
                        )
                        envelope_macro_name = "CMQ_ENVELOPE_PUT"
                        for invocation_start, invocation_end, args_text in _iter_sv_calls(
                            envelope_scan, envelope_macro_name
                        ):
                            args = _split_call_arguments(args_text)
                            stem = args[0] if args else ""
                            macro = _c_macro_for_sv_stem(stem)
                            token = envelope_scan[invocation_start:invocation_end]
                            coordinate = (
                                _coordinate_tuple(
                                    coordinates, macro_ranges, context_key, macro
                                ) if macro else None
                            )
                            if coordinate is None:
                                ranges.append(WriterRange(
                                    case_id, source_path, "UNKNOWN_WRITER", token,
                                    0, 0, image_length * 8,
                                ))
                            else:
                                sv_name = _sv_field_stem(stem)
                                sv_coordinate = sv_fields.get(sv_name)
                                if sv_coordinate is None:
                                    ranges.append(WriterRange(
                                        case_id, source_path, "UNKNOWN_WRITER",
                                        token, 0, 0, image_length * 8,
                                    ))
                                elif sv_coordinate != coordinate:
                                    raise ContractError(
                                        f"SV writer alias coordinate drift for {sv_name}: "
                                        f"{sv_coordinate} != {coordinate}"
                                    )
                                else:
                                    ranges.append(WriterRange(
                                        case_id, source_path, "MACRO_PUT", token,
                                        coordinate[0], coordinate[1], coordinate[2],
                                    ))
                            definition = macros.get(envelope_macro_name)
                            if definition is None:
                                raise ContractError(
                                    "SV production macro definition is missing: "
                                    f"{envelope_macro_name}"
                                )
                            parameters, macro_body = definition
                            ranges.extend(_expanded_macro_writer_ranges(
                                macro_body, parameters, args, case_id,
                                source_path, coordinates, macro_ranges,
                                context_key, image_length,
                            ))
                        for call_name in ("put_field", "put"):
                            for start, end, args_text in _iter_sv_calls(
                                envelope_scan, call_name
                            ):
                                token = envelope_scan[start:end]
                                ranges.append(_writer_range_from_call(
                                    call_name, args_text, case_id, source_path,
                                    token, coordinates, macro_ranges,
                                    context_key, image_length,
                                ))

            # Direct writer calls are intentionally scanned in addition to
            # macros so a newly added builder.put_field cannot hide behind the
            # existing alias set.
            for call_name in ("put_field", "put"):
                for start, end, args_text in _iter_sv_calls(branch, call_name):
                    token = branch[start:end]
                    ranges.append(_writer_range_from_call(
                        call_name, args_text, case_id, source_path, token,
                        coordinates, macro_ranges, context_key, image_length,
                    ))
            for start, end, args_text in _iter_sv_calls(branch, "put_memcpy"):
                token = branch[start:end]
                try:
                    args = _split_call_arguments(args_text)
                    base = _resolve_sv_coordinate(
                        args[0], "base", coordinates, macro_ranges, context_key
                    ) if args else None
                    # A memcpy's source length is not a field width.  It is
                    # therefore represented as all bits in the copied range;
                    # unresolved lengths conservatively cover the whole image.
                    length = _parse_sv_literal(args[1]) if len(args) > 1 else image_length
                    if base is None or length <= 0 or base + length > image_length:
                        raise ContractError("unresolved put_memcpy range")
                    ranges.append(WriterRange(
                        case_id, source_path, "PUT_MEMCPY", token,
                        base, 0, length * 8,
                    ))
                except (ContractError, ValueError):
                    ranges.append(WriterRange(
                        case_id, source_path, "UNKNOWN_WRITER", token,
                        0, 0, image_length * 8,
                    ))
            # Direct bytes/words writes have no typed field metadata.  Treat an
            # unknown index as a full-image writer and a numeric index as its
            # containing byte's eight bits.
            assignment = re.compile(
                r"(?:\b(?:bytes|words)\s*\[\s*([^]]+)\s*\]|"
                r"\b(?:bytes|words)\s*\([^)]*\))\s*="
            )
            for match in assignment.finditer(branch):
                index_text = match.group(1)
                try:
                    byte_index = _parse_sv_literal(index_text)
                    if byte_index >= image_length:
                        raise ContractError("direct writer byte index out of range")
                    base = (byte_index // 8) * 8
                    ranges.append(WriterRange(
                        case_id, source_path, "DIRECT_BYTES", match.group(0),
                        base, 0, 8,
                    ))
                except (ContractError, ValueError):
                    ranges.append(WriterRange(
                        case_id, source_path, "UNKNOWN_WRITER", match.group(0),
                        0, 0, image_length * 8,
                    ))
    if production_context:
        _validate_compose_request_writer(
            sv_sources, coordinates, macro_ranges, ranges
        )
    # Stable de-duplication keeps diagnostics deterministic while retaining
    # every distinct token/range needed for reverse proof.
    unique: dict[tuple[object, ...], WriterRange] = {}
    for item in ranges:
        key = (item.case_id, item.source_path, item.operation, item.token,
               item.base, item.lsb, item.width)
        unique[key] = item
    return list(unique.values())


def _mask_from_macro_ranges(
    coordinates: Mapping[tuple[str, str, str, str], object],
    macro_ranges: Mapping[str, tuple[int, int, int]] | None,
    context_key: tuple[str, str, str],
    macros: Iterable[str],
) -> tuple[int, ...]:
    """功能：按 C-derived 字段区间合成八 qword ownership mask。
    输入输出及副作用：返回八个整数；不读取或反推 SV mask 数值。
    失败边界：任一宏坐标缺失/跨 qword/越界均抛 ContractError。"""
    result = [0] * 8
    for macro in macros:
        coordinate = _coordinate_tuple(
            coordinates, macro_ranges, context_key, macro
        )
        if coordinate is None:
            raise ContractError(f"C-derived mask macro coordinate is missing: {macro}")
        base, lsb, width = coordinate
        if base % 8 or lsb + width > 64 or base // 8 >= 8:
            raise ContractError(f"C-derived mask macro range is invalid: {macro}")
        result[base // 8] |= ((1 << width) - 1) << lsb
    return tuple(result)


def _selected_mask_for_cmq_doorbell(source: str) -> int | None:
    """功能：限定在 selected_mask 方法内读取 CMQ SQ 的允许位 literal，与 C union 对照。
    输入输出及副作用：返回 selected_mask 的 64-bit 整数；只读 source，不把 literal 当作 ABI 坐标。
    失败边界：方法缺失/重复、cmq_sq 分支缺失/重复或 literal 非法时抛 ContractError。"""
    text = _strip_sv_comments(source)
    try:
        body = _sv_function_body(text, "selected_mask")
    except ContractError as exc:
        raise ContractError(
            f"selected_mask method is invalid: {exc}"
        ) from exc
    matches = list(re.finditer(
        r"\"cmq_sq\"\s*:\s*return\s*([^;]+);", body
    ))
    if len(matches) != 1:
        raise ContractError(
            f"cmq_sq selected_mask branch is not unique: {len(matches)}"
        )
    return _parse_sv_literal(matches[0].group(1))


def _range_covers_bit(item: WriterRange, qword: int, bit: int) -> bool:
    """功能：判断 writer range 是否覆盖一个逻辑 qword bit。
    输入输出及副作用：返回布尔值；只读不可变 range，不修改扫描结果。
    失败边界：负坐标或跨 image 的 range 返回 False，非法 range 由构造阶段拒绝。"""
    return item.base // 8 == qword and item.lsb <= bit < item.lsb + item.width


def validate_sv_writer_contract(
    sv_sources: Mapping[str, str],
    coordinates: Mapping[tuple[str, str, str, str], object],
    static_rows: Sequence[Mapping[str, str]],
    ownership_rows: Sequence[Mapping[str, str]] | None = None,
    capability_rows: Sequence[Mapping[str, str]] | None = None,
    *,
    macro_ranges: Mapping[str, tuple[int, int, int]] | None = None,
    canonical_images: Mapping[str, bytes] | None = None,
    proven_cases: Iterable[str] | None = None,
) -> list[WriterRange]:
    """功能：以 C-derived 坐标反向证明 request static-unwritable 位没有 production
    writer、ownership 或 capability 覆盖。
    输入输出及副作用：返回扫描到的 WriterRange；只读 SV/rows/images，不启用或修改任何 codec。
    失败边界：writer 坐标漂移、未知直接写、derived mask 漂移、canonical 非零、
    ownership 重叠或未被 proven_cases 覆盖的 capability 置位均抛 ContractError。"""
    if not sv_sources:
        raise ContractError("SV writer source set is empty")
    joined = "\n".join(_strip_sv_comments(source) for source in sv_sources.values())
    sv_fields = parse_sv_field_definitions(joined)
    ranges = _scan_sv_writer_ranges(sv_sources, coordinates, macro_ranges)
    contexts = {
        "cmq_sqe_qpc_create_request": ("CMQ_SQE", "QPC_CREATE", "REQUEST"),
        "cmq_cqe_qpc_create_response": ("CMQ_CQE", "QPC_CREATE", "RESPONSE"),
        "cmq_sq_doorbell": ("CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST"),
    }
    qpc_context = contexts["cmq_sqe_qpc_create_request"]
    qpc_body_macros = (
        "XTRDMA_CMQSQ_WQE_QPN", "XTRDMA_CMQSQ_WQE_SQ_CQN",
        "XTRDMA_CMQSQ_WQE_SIGN_EN", "XTRDMA_CMQSQ_WQE_SIGNATURE",
        "XTRDMA_CMQSQ_WQE_RQ_CQN", "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR",
    )
    expected_qpc_mask = _mask_from_macro_ranges(
        coordinates, macro_ranges, qpc_context, qpc_body_macros
    )
    envelope_macros = (
        "XTRDMA_CMQSQ_WQE_VALID", "XTRDMA_CMQSQ_VFID_OVERRIDE",
        "XTRDMA_CMQSQ_USE_VFID", "XTRDMA_CMQSQ_WQE_WRAP",
        "XTRDMA_CMQSQ_WQE_INDEX", "XTRDMA_CMQCQ_OPCODE",
    )
    expected_envelope = _mask_from_macro_ranges(
        coordinates, macro_ranges, qpc_context, envelope_macros
    )
    masks = parse_sv_derived_masks(joined)
    if masks.get("RDMA_QPC_CREATE_BODY_OWNERSHIP") != expected_qpc_mask:
        raise ContractError("SV QPC_CREATE ownership mask is not C-derived")
    if masks.get("RDMA_CMQ_ENVELOPE_MASK") != expected_envelope:
        raise ContractError("SV CMQ envelope mask is not C-derived")
    doorbell_context = contexts["cmq_sq_doorbell"]
    expected_doorbell = _mask_from_macro_ranges(
        coordinates, macro_ranges, doorbell_context,
        ("XTRDMA_CMQSQ_DB_PI", "XTRDMA_CMQSQ_DB_POL"),
    )
    selected_masks = [
        _selected_mask_for_cmq_doorbell(source)
        for source in sv_sources.values()
        if _has_sv_class_declaration(
            _strip_sv_comments(source), "rdma_hw_doorbell_codec"
        )
    ]
    if len(selected_masks) != 1 or selected_masks[0] != expected_doorbell[0]:
        raise ContractError("SV CMQ doorbell derived mask is not C-derived")

    # Every C-derived field expected in the production branch must have a
    # typed writer.  This also prevents a source edit from making all fields
    # appear static merely because the branch disappeared.
    required_ranges = {
        ("cmq_sqe_qpc_create_request", macro): _coordinate_tuple(
            coordinates, macro_ranges, qpc_context, macro
        )
        for macro in qpc_body_macros
    }
    required_ranges.update({
        ("cmq_sq_doorbell", macro): _coordinate_tuple(
            coordinates, macro_ranges, doorbell_context, macro
        )
        for macro in ("XTRDMA_CMQSQ_DB_PI", "XTRDMA_CMQSQ_DB_POL")
    })
    for (case_id, macro), coordinate in required_ranges.items():
        if coordinate is None:
            raise ContractError(f"missing C coordinate for production writer: {macro}")
        if not any(
            item.case_id == case_id and item.base == coordinate[0] and
            item.lsb == coordinate[1] and item.width == coordinate[2]
            for item in ranges
        ):
            raise ContractError(f"production writer is missing C field: {case_id}/{macro}")

    static_bits = [
        row for row in static_rows
        if row.get("evidence_mode") == "STATIC_UNWRITABLE"
    ]
    for row in static_bits:
        case_id = row.get("case_id", "")
        context = contexts.get(case_id)
        if context is None:
            continue
        try:
            qword = int(row["qword_index"], 0)
            bit = int(row["bit_index"], 0)
        except (KeyError, ValueError) as exc:
            raise ContractError("static row has invalid coordinate") from exc
        if canonical_images is not None and case_id in canonical_images:
            image = canonical_images[case_id]
            if qword * 8 >= len(image) or ((int.from_bytes(
                    image[qword * 8:qword * 8 + 8], "big"
                ) >> bit) & 1):
                raise ContractError(
                    f"static-unwritable canonical bit is nonzero: {case_id}/{qword}/{bit}"
                )
        if any(_range_covers_bit(item, qword, bit) for item in ranges
               if item.case_id == case_id):
            raise ContractError(
                f"production writer covers STATIC_UNWRITABLE bit: {case_id}/{qword}/{bit}"
            )
        for ownership in ownership_rows or ():
            if ownership.get("entry_kind") != context[0] or \
               ownership.get("opcode_or_variant") != context[1] or \
               ownership.get("direction") != context[2]:
                continue
            macro = ownership.get("macro_name", "")
            c_macro = _c_macro_for_sv_stem(macro) or macro
            coordinate = _coordinate_tuple(
                coordinates, macro_ranges, context, c_macro
            )
            if coordinate and coordinate[0] // 8 == qword and \
               coordinate[1] <= bit < coordinate[1] + coordinate[2]:
                raise ContractError(
                    f"ownership row covers STATIC_UNWRITABLE bit: "
                    f"{case_id}/{qword}/{bit}/{macro}"
                )
    proven = set(proven_cases or ())
    unknown_proven = proven - PROVEN_CAPABILITY_CASES
    if unknown_proven:
        raise ContractError(
            f"unknown proven capability cases: {sorted(unknown_proven)}"
        )
    for capability in capability_rows or ():
        case_id = capability.get("oracle_case_id", "-")
        if case_id == "-":
            case_id = CAPABILITY_CASE_BY_KEY.get(
                (capability.get("driver_symbol", ""),
                 capability.get("direction", "")),
                "-",
            )
        enabled = (
            capability.get("request_encodable") == "1"
            or capability.get("response_decodable") == "1"
        )
        if enabled and case_id in contexts and case_id not in proven:
            raise ContractError(
                f"capability enables unproven production path: {case_id}"
            )
    return ranges


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
    """功能：验证 ownership 行 concrete anchors 的实际 C 调用参数、坐标和目标数据流。
    输入输出及副作用：只读 manifest 覆盖的 C 文件；成功无返回值，不写回 ownership 表。
    失败边界：函数/token 非唯一、注释伪引用、container/buffer、operation、base/length、调用参数或 flow 任一漂移均拒绝。"""
    cache: dict[str, str] = {}
    for row in rows:
        values = _anchor_values(row)
        if all(value == "-" for value in values):
            continue
        function = row["anchor_function"]
        if row["anchor_operation"] not in ALLOWED_OPERATIONS:
            raise ContractError(f"unsupported anchor operation {row['anchor_operation']}")
        # The first four ownership columns identify cmq.h, while concrete
        # functions commonly live in cmq.c.  Resolve the function across the
        # locked manifest and require exactly one source candidate.
        candidates: list[tuple[str, str]] = []
        for source_path in sorted(records_by_path):
            if source_path not in cache:
                cache[source_path] = _strip_comments(
                    (kernel_root / source_path).read_text(encoding="utf-8")
                )
            source = cache[source_path]
            try:
                _function_body(source, function)
            except ContractError:
                continue
            candidates.append((source_path, source))
        if len(candidates) != 1:
            raise ContractError(
                f"anchor function is not unique in manifest: {function} ({len(candidates)})"
            )
        source_path, source = candidates[0]
        occurrence = _parse_int(row["anchor_occurrence"], "anchor occurrence")
        resolve_source_anchor(source, function, row["anchor_token"], occurrence)
        body = _function_body(source, function)
        _validate_anchor_call_arguments(row, body, source_path)


def _normalise_c_expr(value: str) -> str:
    """功能：规范化 C 调用表达式的空白，便于 anchor 参数与表中声明逐项比较。
    输入输出及副作用：返回去空白表达式；不求值、不改变字段名或指针层级。
    失败边界：空表达式返回空串，由调用参数校验按缺失参数拒绝。"""
    return re.sub(r"\s+", "", value)


def _anchor_token_call(
    body: str,
    call_name: str,
    token: str,
) -> tuple[list[str], str]:
    """功能：在函数体中定位唯一包含 anchor token 的指定 C 调用并解析参数。
    输入输出及副作用：返回参数列表和完整调用文本；只读 body，不执行宏/函数。
    失败边界：零/多调用、括号不平衡或 token 落在其他语句时抛 ContractError。"""
    token_norm = _normalise_c_expr(token)
    matches: list[tuple[list[str], str]] = []
    for start, end, args_text in _iter_sv_calls(body, call_name):
        call_text = body[start:end]
        if token_norm not in _normalise_c_expr(call_text):
            continue
        matches.append((_split_call_arguments(args_text), call_text))
    if len(matches) != 1:
        raise ContractError(
            f"anchor token is not unique in {call_name}: {len(matches)}"
        )
    return matches[0]


def _anchor_flow_nodes(flow: str) -> list[str]:
    """功能：按带空白的 flow 分隔符拆解 anchor 数据流并保留 C 成员箭头。
    输入输出及副作用：返回去空白节点列表；不执行表达式或改变原始
    flow。
    失败边界：少于两跳、空节点、Unicode 箭头或无空白分隔符均抛
    ContractError。"""
    if "->" not in flow or "→" in flow:
        raise ContractError("anchor target flow is not an ASCII data-flow chain")
    separator = re.compile(r"\s+->\s+")
    nodes = [item.strip() for item in separator.split(flow.strip())]
    if len(nodes) < 2 or any(not item for item in nodes):
        raise ContractError("anchor target flow has an empty hop")
    return nodes


def _flow_node_contains(node: str, expression: str) -> bool:
    """功能：判断单个 anchor flow 节点是否包含完整表达式而非标识符子串。
    输入输出及副作用：返回布尔值；只规范化输入文本，不执行 C
    表达式或修改节点。
    失败边界：空节点/表达式或被字母数字下划线包围的伪命中均返回
    False。"""
    compact_node = _normalise_c_expr(node)
    compact_expression = _normalise_c_expr(expression)
    if not compact_node or not compact_expression:
        return False
    pattern = (
        r"(?<![A-Za-z0-9_])" + re.escape(compact_expression) +
        r"(?![A-Za-z0-9_])"
    )
    return re.search(pattern, compact_node) is not None


def _flow_node_contains_exact(node: str, expression: str) -> bool:
    """功能：在 flow 节点中匹配完整 buffer/target 表达式并排除成员别名。
    输入输出及副作用：返回布尔值；只规范化节点和表达式，
    不求值或修改 flow。
    失败边界：表达式若被标识符、点号、箭头或下标前缀包围则视为
    未命中。
    """
    compact_node = _normalise_c_expr(node)
    compact_expression = _normalise_c_expr(expression)
    if not compact_node or not compact_expression:
        return False
    pattern = (
        r"(?<![A-Za-z0-9_.$>\]])" + re.escape(compact_expression) +
        r"(?![A-Za-z0-9_])"
    )
    return re.search(pattern, compact_node) is not None


def _require_anchor_range_in_flow(
    flow: str,
    buffer_expr: str,
    base: int,
    length: int,
    target_expr: str | None = None,
    *,
    target_must_be_final: bool = False,
    target_must_be_after: bool = False,
    container_expr: str | None = None,
) -> None:
    """功能：在结构化 data-flow 节点中绑定 buffer 的 byte base/length，并闭合
    最终 target。
    输入输出及副作用：成功无返回值；只读 flow 字符串并按 ASCII 箭头解析
    节点。
    失败边界：buffer 与 range 不在同一节点、range 重复/缺失、target 缺失或
    顺序错误均抛 ContractError。"""
    nodes = _anchor_flow_nodes(flow)
    buffer_compact = _normalise_c_expr(buffer_expr)
    if not buffer_compact:
        raise ContractError("anchor target flow has an empty buffer expression")

    def carries_range(node: str) -> bool:
        """功能：识别同一节点内 buffer 对应的精确 byte range 表达式。
        输入输出及副作用：返回布尔值；支持 qword index、显式 [base,length]/
        slice
        和指针位移。
        失败边界：range 只出现在其他节点、length 与索引语义不符或表达式不
        完整时返回 False。"""
        compact_node = _normalise_c_expr(node)
        if not _flow_node_contains_exact(compact_node, buffer_compact):
            return False
        escaped_buffer = re.escape(buffer_compact)
        range_end = r"(?![A-Za-z0-9_.$>\[])"
        indexed = rf"{escaped_buffer}\[{base}\]{range_end}"
        indexed_range = (
            rf"{escaped_buffer}\[{base}[,:]{length}\]{range_end}",
            rf"{escaped_buffer}\[{base}:{base + length}\]{range_end}",
            rf"{escaped_buffer}\[{base}:{base + length - 1}\]{range_end}",
        )
        if re.search(indexed, compact_node):
            # An indexed scalar denotes one qword in these anchors; do not let
            # a [0] token prove a different declared byte length.
            return length == 8
        if any(re.search(pattern, compact_node) for pattern in indexed_range):
            return True
        pointer_range = rf"{escaped_buffer}\+{base}{range_end}"
        if not re.search(pointer_range, compact_node):
            return False
        # Pointer displacement without an explicit span is only unambiguous
        # for the qword anchors used by this contract.
        if length == 8:
            return True
        return any(
            re.search(
                rf"{pointer_range}(?:\+|,|:)\s*{length}{range_end}",
                compact_node,
            )
            for _ in (0,)
        )

    range_indices = [
        index for index, node in enumerate(nodes) if carries_range(node)
    ]
    if not range_indices:
        raise ContractError(
            "anchor target flow does not bind buffer and declared byte range"
        )
    if len(range_indices) != 1:
        raise ContractError(
            "anchor target flow has multiple declared buffer range nodes"
        )
    range_index = range_indices[0]

    if container_expr is not None:
        container_indices = [
            index for index, node in enumerate(nodes)
            if _flow_node_contains_exact(node, container_expr)
        ]
        if not container_indices:
            raise ContractError(
                "anchor target flow omits declared container expression"
            )
        if range_index not in container_indices:
            raise ContractError(
                "anchor range is not attached to declared container node"
            )

    if target_expr is not None:
        target_indices = [
            index for index, node in enumerate(nodes)
            if _flow_node_contains_exact(node, target_expr)
        ]
        if not target_indices:
            raise ContractError("anchor target flow omits final data-flow target")
        if target_must_be_after and target_indices[0] <= range_index:
            raise ContractError("anchor target is not after declared buffer range")
        if target_indices[0] < range_index:
            raise ContractError("anchor target precedes declared buffer range")
        if target_must_be_final and target_indices[-1] != len(nodes) - 1:
            raise ContractError("anchor target flow does not end at final target")


def _flow_contains_value(flow: str, expression: str) -> bool:
    """功能：确认 anchor target flow 保留真实调用值表达式中的数据来源。
    输入输出及副作用：返回布尔值；只比较规范化文本和标识符，不执行表达式或改变 flow。
    失败边界：纯数字/空值不要求额外来源；含变量的表达式若在 flow 中没有任何可识别来源则拒绝。"""
    flow_compact = _normalise_c_expr(flow)
    expression_compact = _normalise_c_expr(expression)
    if not expression_compact or re.fullmatch(r"[0-9]+", expression_compact):
        return True
    if expression_compact in flow_compact:
        return True
    # A ternary, cast, or helper invocation is often represented in the
    # table by its meaningful source member rather than verbatim punctuation.
    # Ignore type/macro-looking constants and require one identifier/member
    # that actually occurs in the declared data-flow chain.
    identifiers = re.findall(
        r"[A-Za-z_][A-Za-z0-9_]*(?:->|\.)?[A-Za-z0-9_]*", expression_compact
    )
    meaningful = [
        item for item in identifiers
        if item not in {"true", "false"}
        and not re.fullmatch(r"(?:XTRDMA|RDMA)_[A-Z0-9_]+", item)
    ]
    return bool(meaningful) and any(item in flow_compact for item in meaningful)


def _field_prep_anchor(
    body: str,
    token: str,
    macro_name: str,
) -> tuple[list[str], str, str]:
    """功能：解析 assignment 中唯一 FIELD_PREP anchor，并找出其承载变量。
    输入输出及副作用：返回 FIELD_PREP 参数、所在语句和赋值左值；只读 C 函数体。
    失败边界：token 零/多匹配、宏名漂移、括号不平衡或缺少赋值均抛 ContractError。"""
    token_norm = _normalise_c_expr(token)
    compact_body = _normalise_c_expr(body)
    if compact_body.count(token_norm) != 1:
        raise ContractError("FIELD_PREP anchor token is not unique")
    # Locate the concrete statement containing the token.  QPC/CQC builders
    # construct ``hdr``/``sign_data`` over multiple lines before storing it.
    token_index = compact_body.find(token_norm)
    statement_start = max(
        compact_body.rfind(";", 0, token_index),
        compact_body.rfind("{", 0, token_index),
        compact_body.rfind("}", 0, token_index),
    ) + 1
    statement_end = compact_body.find(";", token_index)
    if statement_end < 0:
        raise ContractError("FIELD_PREP anchor statement is incomplete")
    statement = compact_body[statement_start:statement_end + 1]
    calls = list(_iter_sv_calls(statement, "FIELD_PREP"))
    matching: list[tuple[list[str], str]] = []
    for start, end, args_text in calls:
        call = statement[start:end]
        if token_norm in _normalise_c_expr(call):
            matching.append((_split_call_arguments(args_text), call))
    if len(matching) != 1 or len(matching[0][0]) != 2:
        raise ContractError("FIELD_PREP anchor call is not unique")
    args, call = matching[0]
    if _normalise_c_expr(args[0]) != _normalise_c_expr(macro_name):
        raise ContractError("FIELD_PREP macro argument drift")
    assignment = statement.split("=", 1)
    if len(assignment) != 2:
        raise ContractError("FIELD_PREP anchor has no assignment")
    lhs = assignment[0].strip()
    # Strip a declaration type and pointer punctuation while retaining the
    # actual variable at the end of the left side.
    lhs_match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", lhs)
    if lhs_match is None:
        raise ContractError("FIELD_PREP assignment left side is invalid")
    return args, call, lhs_match.group(1)


def _find_set_call_using_variable(
    body: str,
    variable: str,
    buffer_expr: str,
    base: int,
) -> tuple[list[str], str]:
    """功能：在函数体中闭合 assignment 变量到唯一目标 set_64bit_val 调用。
    输入输出及副作用：返回参数和调用文本；不执行宏或写入 buffer。
    失败边界：目标 buffer/base 无匹配或存在多条候选时抛 ContractError。"""
    candidates: list[tuple[list[str], str]] = []
    for start, end, args_text in _iter_sv_calls(body, "set_64bit_val"):
        args = _split_call_arguments(args_text)
        if len(args) != 3:
            continue
        if _normalise_c_expr(args[0]) != _normalise_c_expr(buffer_expr):
            continue
        try:
            call_base = _parse_int(args[1], "set_64bit_val base")
        except ContractError:
            continue
        if call_base != base or not re.search(
            r"\b" + re.escape(variable) + r"\b", args[2]
        ):
            continue
        candidates.append((args, body[start:end]))
    if not candidates:
        raise ContractError("FIELD_PREP assignment has no matching set_64bit_val")
    # sign_data is intentionally written twice for QPC signatures.  Both
    # calls represent the same declared qword range; accepting multiple
    # stores here would nevertheless weaken occurrence checks for a field.
    # The token itself remains unique, so choose the first exact data-flow
    # store and require all candidates to agree on buffer/base.
    return candidates[0]


def _validate_anchor_call_arguments(
    row: Mapping[str, str],
    body: str,
    source_path: str,
) -> None:
    """功能：按 anchor_operation 将表中 base/length/buffer 与真实 C 调用参数闭合。
    输入输出及副作用：成功无返回值；只读函数体和 row，不修改 source。
    失败边界：set/get/memcpy/offsetof/MMIO 参数、指针偏移、目标 flow 或长度不一致均抛 ContractError。"""
    operation = row["anchor_operation"]
    declared_buffer = _normalise_c_expr(row["anchor_buffer"])
    declared_container = _normalise_c_expr(row["anchor_container"])
    base = _parse_int(row["anchor_base"], "anchor base")
    length = _parse_int(row["anchor_length"], "anchor length")
    flow_nodes = _anchor_flow_nodes(row["anchor_target_flow"])
    flow_compact = _normalise_c_expr(row["anchor_target_flow"])
    if declared_container not in flow_compact or declared_buffer not in flow_compact:
        raise ContractError("anchor target flow omits declared container/buffer")
    if row.get("macro_name") and row["macro_name"] not in row["anchor_target_flow"]:
        raise ContractError("anchor target flow omits declared macro")
    if operation == "SET_64BIT_FIELD_PREP":
        token_norm = _normalise_c_expr(row["anchor_token"])
        # A FIELD_PREP may be passed directly as the third set_64bit_val
        # argument (the QPC buffer address) or first accumulated in ``hdr`` /
        # ``sign_data`` and stored by name (the envelope and CQN fields).
        direct_matches: list[tuple[list[str], str]] = []
        for start, end, args_text in _iter_sv_calls(body, "set_64bit_val"):
            call = body[start:end]
            if token_norm not in _normalise_c_expr(call):
                continue
            direct_matches.append((_split_call_arguments(args_text), call))
        if direct_matches:
            if len(direct_matches) != 1:
                raise ContractError("set_64bit_val anchor is not unique")
            args, call = direct_matches[0]
            if len(args) != 3 or _normalise_c_expr(args[0]) != declared_buffer:
                raise ContractError("set_64bit_val buffer argument drift")
            if _parse_int(args[1], "set_64bit_val base") != base:
                raise ContractError("set_64bit_val base argument drift")
            value_expression = args[2]
        else:
            prep_args, call, variable = _field_prep_anchor(
                body, row["anchor_token"], row["macro_name"]
            )
            args, store_call = _find_set_call_using_variable(
                body, variable, declared_buffer, base
            )
            value_expression = prep_args[1]
            call = f"{call} {store_call}"
        if length != 8 or "FIELD_PREP" not in call:
            raise ContractError("SET_64BIT_FIELD_PREP requires one qword FIELD_PREP")
        if not _flow_contains_value(row["anchor_target_flow"], value_expression):
            raise ContractError("SET_64BIT_FIELD_PREP source flow drift")
        _require_anchor_range_in_flow(
            row["anchor_target_flow"], row["anchor_buffer"], base, length,
            target_expr=f"{row['anchor_buffer']}[{base}]",
            target_must_be_final=True,
            container_expr=declared_container,
        )
        return
    if operation in {"GET_64BIT", "GET_64BIT_FIELD_GET"}:
        args, _ = _anchor_token_call(body, "get_64bit_val", row["anchor_token"])
        if len(args) != 3 or _normalise_c_expr(args[0]) != declared_buffer:
            raise ContractError("get_64bit_val buffer argument drift")
        if _parse_int(args[1], "get_64bit_val base") != base:
            raise ContractError("get_64bit_val base argument drift")
        if length != 8:
            raise ContractError("get_64bit_val anchor length must be eight")
        if not _normalise_c_expr(args[2]).startswith("&"):
            raise ContractError("get_64bit_val destination is not an output variable")
        destination = _normalise_c_expr(args[2]).lstrip("&")
        if destination not in flow_compact:
            raise ContractError("get_64bit_val destination flow drift")
        if row["macro_name"] not in row["anchor_target_flow"]:
            raise ContractError("get_64bit_val field flow omits macro")
        _require_anchor_range_in_flow(
            row["anchor_target_flow"], row["anchor_buffer"], base, length,
            target_expr=destination,
            target_must_be_after=True,
            container_expr=declared_container,
        )
        return
    if operation == "MEMCPY":
        args, _ = _anchor_token_call(body, "memcpy", row["anchor_token"])
        if len(args) != 3:
            raise ContractError("memcpy anchor must have destination/source/length")
        destination = _normalise_c_expr(args[0])
        if destination != declared_buffer:
            raise ContractError("memcpy destination drift")
        actual_length = _parse_int(args[2], "memcpy length")
        if actual_length != length:
            raise ContractError("memcpy length argument drift")
        destination_base = 0
        match = re.search(r"\+([0-9]+)$", destination)
        if match:
            destination_base = int(match.group(1), 10)
        if destination_base != base:
            raise ContractError("memcpy destination base drift")
        if declared_container not in destination:
            raise ContractError("memcpy destination omits container")
        if not _flow_contains_value(row["anchor_target_flow"], args[1]):
            raise ContractError("memcpy source flow drift")
        _require_anchor_range_in_flow(
            row["anchor_target_flow"], row["anchor_buffer"], base, length,
            target_expr=destination,
            target_must_be_after=True,
            container_expr=declared_container,
        )
        return
    if operation == "IOWRITE64BE":
        args, _ = _anchor_token_call(body, "xtrdma_iowrite64be", row["anchor_token"])
        if len(args) != 2:
            raise ContractError("xtrdma_iowrite64be anchor must have value/address")
        if _normalise_c_expr(args[0]) != declared_buffer:
            raise ContractError("xtrdma_iowrite64be value buffer drift")
        if base != 0 or length != 8:
            raise ContractError("IOWRITE64BE anchor must cover one byte-zero qword")
        if _normalise_c_expr(args[1]) not in flow_compact:
            raise ContractError("xtrdma_iowrite64be target flow drift")
        if not _flow_contains_value(row["anchor_target_flow"], args[0]):
            raise ContractError("xtrdma_iowrite64be value flow drift")
        _require_anchor_range_in_flow(
            row["anchor_target_flow"], row["anchor_buffer"], base, length,
            target_expr=args[1], target_must_be_final=True,
            container_expr=declared_container,
        )
        return
    if operation == "FIELD_PREP_OR":
        token_norm = _normalise_c_expr(row["anchor_token"])
        if _normalise_c_expr(body).count(token_norm) != 1:
            raise ContractError("FIELD_PREP_OR anchor token is not unique")
        statements = [item for item in re.split(r"(?<=[;{}])", body)
                      if token_norm in _normalise_c_expr(item)]
        if len(statements) != 1 or "FIELD_PREP" not in statements[0]:
            raise ContractError("FIELD_PREP_OR assignment token is not unique")
        assignment = statements[0]
        lhs = assignment.split("=", 1)[0].strip()
        if _normalise_c_expr(lhs) != declared_buffer:
            raise ContractError("FIELD_PREP_OR destination drift")
        if base != 0 or length != 8:
            raise ContractError("FIELD_PREP_OR anchor must cover one qword")
        prep_args, _ = _anchor_token_call(body, "FIELD_PREP", row["anchor_token"])
        if len(prep_args) != 2:
            raise ContractError("FIELD_PREP_OR call arguments are invalid")
        if _normalise_c_expr(prep_args[0]) != _normalise_c_expr(row["macro_name"]):
            raise ContractError("FIELD_PREP_OR macro argument drift")
        if not _flow_contains_value(row["anchor_target_flow"], prep_args[1]):
            raise ContractError("FIELD_PREP_OR source flow drift")
        _require_anchor_range_in_flow(
            row["anchor_target_flow"], row["anchor_buffer"], base, length,
            target_expr=f"{row['anchor_buffer']}[{base}]",
            container_expr=declared_container,
        )
        return
    if operation in {"ASSIGN_ADDRESS", "ASSIGN_SHIFT_RIGHT"}:
        token_norm = _normalise_c_expr(row["anchor_token"])
        matches = [item for item in re.split(r"(?<=[;{}])", body)
                   if token_norm in _normalise_c_expr(item)]
        if len(matches) != 1 or "=" not in matches[0]:
            raise ContractError("assignment anchor is not unique")
        lhs, rhs = matches[0].split("=", 1)
        lhs_norm, rhs_norm = _normalise_c_expr(lhs), _normalise_c_expr(rhs)
        if declared_buffer not in lhs_norm and declared_buffer not in rhs_norm:
            raise ContractError("assignment anchor omits declared buffer")
        if operation == "ASSIGN_SHIFT_RIGHT" and ">>" not in rhs_norm:
            raise ContractError("ASSIGN_SHIFT_RIGHT lacks shift operator")
        if operation == "ASSIGN_ADDRESS" and "&" not in rhs_norm:
            raise ContractError("ASSIGN_ADDRESS lacks address operator")
        if not flow_nodes[-1].replace(" ", "") in flow_compact:
            raise ContractError("assignment target flow does not end at assigned value")
        return
    # Remaining operations are helper-level semantic anchors.  They still
    # require a unique token and explicit operation text; no bare '->' pass is
    # accepted as evidence.
    token_norm = _normalise_c_expr(row["anchor_token"])
    if _normalise_c_expr(body).count(token_norm) != 1:
        raise ContractError(
            f"anchor token is not unique for {operation} in {source_path}"
        )
    if operation == "CPU_TO_BE64_STORE":
        if "cpu_to_be64" not in token_norm or length != 8:
            raise ContractError("CPU_TO_BE64_STORE parameters are not closed")
    elif operation == "XOR_U64_REMAINDER_FOLD":
        if "get_unaligned" not in token_norm or length <= 0:
            raise ContractError("XOR_U64_REMAINDER_FOLD parameters are not closed")
    elif operation in {"INDEX_LOOKUP", "COMPARE_WRAP", "COMPARE_OPCODE", "COMPARE_ECODE"}:
        if length <= 0:
            raise ContractError("comparison anchor length is invalid")
    else:
        raise ContractError(f"unsupported concrete anchor operation: {operation}")


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
    """功能：构造一条 macro-derived ownership row 的冻结列值并绑定真实 C anchor。
    输入输出及副作用：返回新字典；manifest identity、字段 owner/capability 和 concrete anchor 均写入新对象，不修改 record 或源码。
    失败边界：未知 case/macro 没有可证明的函数、调用参数或数据流时抛 ContractError，禁止回退为无证据的 '-' anchor。"""
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
    anchor = _ownership_anchor(case_id, macro_name)
    for column in ANCHOR_COLUMNS:
        row[column] = anchor.get(column, "-")
    return row


def _ownership_anchor(case_id: str, macro_name: str) -> dict[str, str]:
    """功能：为四个 Phase-0 ownership case 的每个宏选择锁定 C 函数中的实际调用 anchor。
    输入输出及副作用：返回独立 anchor 列字典；只描述 source function、buffer、坐标和数据流，不读取或修改 SV 常量。
    失败边界：宏未列入已审阅的 QPC/CQC/CQE/doorbell 集合时抛 ContractError，避免把不可定位字段伪装成 concrete 证据。"""
    def prep(function: str, macro: str, value: str, buffer: str,
             base: int, flow: str) -> dict[str, str]:
        """功能：把一个字段值与其 C writer 调用参数组装成 concrete anchor。
        输入输出及副作用：function、macro、value、buffer、base、flow 进入新字典；不修改源码或外部资源。
        失败边界：调用方若传入不存在的函数/宏或不一致的数据流，后续 anchor validator 必须拒绝该字典。"""
        return {
            "anchor_function": function,
            "anchor_token": f"FIELD_PREP({macro}, {value})",
            "anchor_occurrence": "1",
            "anchor_container": buffer.replace(" + 1", ""),
            "anchor_buffer": buffer,
            "anchor_operation": "SET_64BIT_FIELD_PREP",
            "anchor_base": str(base),
            "anchor_length": "8",
            "anchor_target_flow": flow,
        }

    qpc_values = {
        "XTRDMA_CMQSQ_WQE_VALID": ("polarity", 0,
            "polarity -> hdr -> XTRDMA_CMQSQ_WQE_VALID -> wqe[0]"),
        "XTRDMA_CMQSQ_VFID_OVERRIDE": ("0", 0,
            "0 -> hdr -> XTRDMA_CMQSQ_VFID_OVERRIDE -> wqe[0]"),
        "XTRDMA_CMQSQ_USE_VFID": ("0", 0,
            "0 -> hdr -> XTRDMA_CMQSQ_USE_VFID -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_WRAP": ("polarity ? 0 : 1", 0,
            "polarity -> hdr -> XTRDMA_CMQSQ_WQE_WRAP -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_INDEX": ("wqe_idx", 0,
            "wqe_idx -> hdr -> XTRDMA_CMQSQ_WQE_INDEX -> wqe[0]"),
        "XTRDMA_CMQCQ_OPCODE": ("opcode", 0,
            "opcode -> hdr -> XTRDMA_CMQCQ_OPCODE -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_QPN": ("info->qpn", 0,
            "info->qpn -> hdr -> XTRDMA_CMQSQ_WQE_QPN -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_RQ_CQN": ("info->rq_cqn", 8,
            "info->rq_cqn -> sign_data -> XTRDMA_CMQSQ_WQE_RQ_CQN -> wqe[8]"),
        "XTRDMA_CMQSQ_WQE_SIGN_EN": ("1", 8,
            "1 -> sign_data -> XTRDMA_CMQSQ_WQE_SIGN_EN -> wqe[8]"),
        "XTRDMA_CMQSQ_WQE_SIGNATURE": ("wqe_signature", 8,
            "wqe_signature -> FIELD_PREP(XTRDMA_CMQSQ_WQE_SIGNATURE) -> wqe[8]"),
        "XTRDMA_CMQSQ_WQE_SQ_CQN": ("info->sq_cqn", 8,
            "info->sq_cqn -> sign_data -> XTRDMA_CMQSQ_WQE_SQ_CQN -> wqe[8]"),
        "XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR": ("info->qpc_buffer_addr_pa", 24,
            "info->qpc_buffer_addr_pa -> FIELD_PREP(XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR) -> wqe[24]"),
    }
    cqc_values = {
        "XTRDMA_CMQSQ_WQE_VALID": ("polarity", 0,
            "polarity -> hdr -> XTRDMA_CMQSQ_WQE_VALID -> wqe[0]"),
        "XTRDMA_CMQSQ_VFID_OVERRIDE": ("0", 0,
            "0 -> hdr -> XTRDMA_CMQSQ_VFID_OVERRIDE -> wqe[0]"),
        "XTRDMA_CMQSQ_USE_VFID": ("0", 0,
            "0 -> hdr -> XTRDMA_CMQSQ_USE_VFID -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_WRAP": ("polarity ? 0 : 1", 0,
            "polarity -> hdr -> XTRDMA_CMQSQ_WQE_WRAP -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_INDEX": ("wqe_idx", 0,
            "wqe_idx -> hdr -> XTRDMA_CMQSQ_WQE_INDEX -> wqe[0]"),
        "XTRDMA_CMQCQ_OPCODE": ("opcode", 0,
            "opcode -> hdr -> XTRDMA_CMQCQ_OPCODE -> wqe[0]"),
        "XTRDMA_CMQSQ_WQE_CQC_WQE_CQN": ("cq_ctx->cqn", 0,
            "cq_ctx->cqn -> hdr -> XTRDMA_CMQSQ_WQE_CQC_WQE_CQN -> wqe[0]"),
    }
    if case_id == "cmq_sqe_qpc_create_request":
        if macro_name not in qpc_values:
            raise ContractError(f"no QPC ownership anchor for {macro_name}")
        value, base, flow = qpc_values[macro_name]
        return prep("xtrdma_sc_qp_create", macro_name, value, "wqe", base, flow)
    if case_id == "cmq_sqe_cqc_create_request":
        if macro_name not in cqc_values:
            raise ContractError(f"no CQC ownership anchor for {macro_name}")
        value, base, flow = cqc_values[macro_name]
        return prep("xtrdma_sc_cq_create", macro_name, value, "wqe", base, flow)
    if case_id == "cmq_cqe_qpc_create_response":
        if macro_name == "XTRDMA_CMQSQ_WQE_VALID":
            return {
                "anchor_function": "xtrdma_sc_cmq_next_cqe_valid",
                "anchor_token": "get_64bit_val(cqe, 0, &temp1)",
                "anchor_occurrence": "1",
                "anchor_container": "cqe",
                "anchor_buffer": "cqe",
                "anchor_operation": "GET_64BIT_FIELD_GET",
                "anchor_base": "0",
                "anchor_length": "8",
                "anchor_target_flow": (
                    "cq_base[CI].elem -> cqe[0] -> temp1 -> "
                    "XTRDMA_CMQSQ_WQE_VALID -> ready"
                ),
            }
        if macro_name not in {
            "XTRDMA_CMQSQ_WQE_WRAP", "XTRDMA_CMQSQ_WQE_INDEX",
            "XTRDMA_CMQCQ_OPCODE", "XTRDMA_CMQCQ_CMD_ECODE",
            "XTRDMA_CMQSQ_VFID_OVERRIDE", "XTRDMA_CMQSQ_USE_VFID",
        }:
            raise ContractError(f"no CQE ownership anchor for {macro_name}")
        return {
            "anchor_function": "xtrdma_get_cqe_common_info",
            "anchor_token": "get_64bit_val(*cqe, 0, &temp)",
            "anchor_occurrence": "1",
            "anchor_container": "cqe",
            "anchor_buffer": "*cqe",
            "anchor_operation": "GET_64BIT",
            "anchor_base": "0",
            "anchor_length": "8",
            "anchor_target_flow": (
                f"sc_cmq->cq_base[CI].elem -> *cqe[0] -> temp -> "
                f"{macro_name} -> decoded completion"
            ),
        }
    if case_id == "cmq_sq_doorbell":
        values = {
            "XTRDMA_CMQSQ_DB_PI": (
                "XTRDMA_RING_CURRENT_PI(sc_cmq->sq_ring)",
                (
                    "sc_cmq->sq_ring -> XTRDMA_CMQSQ_DB_PI -> cmq_db[0] -> "
                    "xtrdma_iowrite64be -> sc_cmq->sc_dev->cmq_db"
                ),
            ),
            "XTRDMA_CMQSQ_DB_POL": (
                "sc_cmq->sq_polarity ? 0 : 1",
                (
                    "sc_cmq->sq_polarity -> XTRDMA_CMQSQ_DB_POL -> cmq_db[0] -> "
                    "xtrdma_iowrite64be -> sc_cmq->sc_dev->cmq_db"
                ),
            ),
        }
        if macro_name not in values:
            raise ContractError(f"no doorbell ownership anchor for {macro_name}")
        value, flow = values[macro_name]
        return {
            "anchor_function": "xtrdma_sc_cmq_post_sq",
            "anchor_token": f"FIELD_PREP({macro_name}, {value})",
            "anchor_occurrence": "1",
            "anchor_container": "cmq_db",
            "anchor_buffer": "cmq_db",
            "anchor_operation": "FIELD_PREP_OR",
            "anchor_base": "0",
            "anchor_length": "8",
            "anchor_target_flow": flow,
        }
    raise ContractError(f"unknown ownership anchor case: {case_id}")


def build_expected_ownership(
    records_by_path: Mapping[str, Sequence[object]],
    proven_cases: Iterable[str] | None = None,
) -> list[dict[str, str]]:
    """功能：按已闭合的 C-derived proof 投影四个 CMQ case 的 ownership capability。
    输入输出及副作用：records_by_path 提供 manifest identity，proven_cases 提供已完成
    mutation/source-walk 的 case；返回新 rows，不注册 opcode、不修改输入。
    失败边界：未知 proof case、CMQ selector 不唯一或未证明方向试图变为 SUPPORTED 时拒绝。"""
    record = _cmq_manifest_record(records_by_path)
    proven = set(proven_cases or ())
    unknown = proven - PROVEN_CAPABILITY_CASES
    if unknown:
        raise ContractError(
            f"unknown proven capability cases: {sorted(unknown)}"
        )
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
        ownership, _, _ = QPC_REQUEST_POLICY[field]
        capability = (
            "SUPPORTED"
            if "cmq_sqe_qpc_create_request" in proven and
            ownership in {"HOST_TYPED", "HOST_FIXED"}
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
        capability = (
            "SUPPORTED"
            if "cmq_cqe_qpc_create_response" in proven and
            ownership == "HW_TYPED"
            else "UNSUPPORTED"
        )
        rows.append(_ownership_base(
            record, macro, "CMQ_CQE", "QPC_CREATE", "RESPONSE",
            ownership, capability, response_model_fields[field],
            "rdma_hw_cmq_completion_codec", "cmq_cqe_qpc_create_response",
        ))
    for field, macro in CASE_FIELD_MACROS["cmq_sq_doorbell"].items():
        model_field = "model.pi" if field == "pi_after" else "model.polarity"
        rows.append(_ownership_base(
            record, macro, "CMQ_SQ_DOORBELL", "CMQ_SQ", "REQUEST",
            "HOST_TYPED",
            "SUPPORTED" if "cmq_sq_doorbell" in proven else "UNSUPPORTED",
            model_field,
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
        # The CQC header fields are written into ``wqe`` while the embedded
        # context is copied to ``wqe + 1``.  Both destinations belong to the
        # same locked request image and must be admitted when scanning this
        # function; rejecting the second one would hide the Task-3 embed
        # anchor rather than prove it.
        expected_buffers={"wqe", "wqe + 1"},
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
    mutations = load_mutations(Path(args.mutation_manifest))
    _validate_identity_rows(ownership, records, lock.archive_id)
    _validate_identity_rows(exclusions, records, lock.archive_id)
    _validate_concrete_anchors(ownership, kernel_root, records)
    sv_sources = _read_sv_sources(Path(args.sv_root))
    coordinates = _derive_all_coordinates(kernel_root, oracle_root, macros)
    macro_ranges: dict[object, tuple[int, int, int]] = {}
    ranges_by_macro: defaultdict[str, set[tuple[int, int, int]]] = defaultdict(set)
    for key, base in coordinates.items():
        macro = key[3]
        definition = macros.get(macro)
        if definition is None:
            raise ContractError(f"C coordinate macro is not defined: {macro}")
        coordinate = (int(base), definition.lsb, definition.width)
        macro_ranges[key] = coordinate
        ranges_by_macro[macro].add(coordinate)
    for macro, values in ranges_by_macro.items():
        if len(values) == 1:
            macro_ranges[macro] = next(iter(values))
    validate_ownership_rows(
        ownership,
        macros=macros,
        exclusions=exclusions,
        sv_sources=sv_sources,
        coordinates=coordinates,
    )
    cmq_header = (kernel_root / "cmq.h").read_text(encoding="utf-8")
    enum_members = parse_opcode_enum(cmq_header)
    validate_oracle_case_references(
        [*ownership, *mutations],
        cases,
    )
    _validate_artifact_field_values(oracle_root)
    supported_opcodes = parse_supported_opcode_values(sv_sources, enum_members)
    expected_mutations = build_expected_mutations(
        oracle_root,
        supported_opcodes=supported_opcodes,
        sv_sources=sv_sources,
        coordinates=coordinates,
        macro_ranges=macro_ranges,
        ownership_rows=ownership,
        # Capability bits are checked only after the C-derived mutation
        # candidate has been rebuilt and compared.  Passing the hand-edited
        # table into source-walk here would make capability validation depend
        # on its own untrusted flags.
        capability_rows=None,
    )
    summary = validate_mutation_report(mutations)
    compare_mutation_report(mutations, expected_mutations)
    proven_cases = closed_proven_cases(mutations, expected_mutations)

    expected_ownership = build_expected_ownership(
        records,
        proven_cases=proven_cases,
    )
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
    evidence_macros: Mapping[str, Mapping[str, object]] | None = None,
) -> dict[str, int]:
    """功能：从 set/get/memcpy/offsetof 调用和赋值数据流推导字段 container byte base。
    输入输出及副作用：返回 macro 到唯一 C-derived base 的映射；expected_buffers 与 evidence_macros
    约束真实 buffer/operation 参数；只读锁定 C 函数体。
    失败边界：宏未流入受支持调用、buffer 不在允许集合、memcpy/offsetof 参数缺失、同一宏落到多 base
    或数值 base 非法均拒绝，绝不从 SV mask 猜坐标。"""
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

    # memcpy is a first-class coordinate witness for embedded contexts.  The
    # destination pointer's constant displacement determines its byte base;
    # callers may provide an explicit evidence_macros entry when the copied
    # payload itself contains no field macro token (as in CQC_CREATE).
    memcpy_pattern = re.compile(r"\bmemcpy\s*\(")
    for match in memcpy_pattern.finditer(body):
        args_text, end = _balanced_delimited_text(
            body, body.find("(", match.start()), "(", ")"
        )
        args = _split_call_arguments(args_text)
        if len(args) != 3:
            raise ContractError(f"malformed memcpy call in {function}")
        destination = re.sub(r"\s+", "", args[0])
        if allowed_buffers and destination not in allowed_buffers:
            raise ContractError(
                f"unexpected memcpy buffer in {function}: {args[0]}"
            )
        length_text = args[2].strip()
        try:
            copy_length = _parse_int(length_text, "memcpy length")
        except ContractError:
            copy_length = None
        displacement = 0
        displacement_match = re.search(r"\+([0-9]+)$", destination)
        if displacement_match:
            displacement = int(displacement_match.group(1), 10)
        names = {
            name for name in re.findall(r"\bXTRDMA_[A-Z0-9_]+\b", args_text)
            if name in wanted
        }
        for name in names:
            offsets[name].add(displacement)
        for name, evidence in (evidence_macros or {}).items():
            if name not in wanted:
                continue
            if str(evidence.get("kind", "")).upper() != "MEMCPY":
                continue
            expected_base = evidence.get("base")
            if expected_base is None:
                raise ContractError(f"memcpy evidence has no base: {name}")
            if copy_length is None:
                raise ContractError(f"memcpy length is not numeric: {name}")
            expected_length = evidence.get("length")
            if expected_length is not None and int(expected_length) != copy_length:
                raise ContractError(f"memcpy evidence length drift: {name}")
            expected_buffer = evidence.get("buffer")
            if expected_buffer is not None:
                normalized_buffer = re.sub(r"\s+", "", str(expected_buffer))
                if normalized_buffer != destination:
                    raise ContractError(f"memcpy evidence buffer drift: {name}")
            offsets[name].add(int(expected_base))

    # offsetof witnesses are accepted only when an explicit evidence mapping
    # names the macro and expected byte base.  This avoids treating a struct
    # layout expression as an implicit ABI coordinate.
    for match in re.finditer(r"\boffsetof\s*\(", body):
        args_text, _ = _balanced_delimited_text(
            body, body.find("(", match.start()), "(", ")"
        )
        args = _split_call_arguments(args_text)
        if len(args) != 2:
            raise ContractError(f"malformed offsetof call in {function}")
        nearby_start = max(0, match.start() - 160)
        nearby_end = min(len(body), match.end() + 160)
        nearby = body[nearby_start:nearby_end]
        for name, evidence in (evidence_macros or {}).items():
            if name not in wanted or str(evidence.get("kind", "")).upper() != "OFFSETOF":
                continue
            expected_member = evidence.get("member")
            if expected_member is not None and str(expected_member) not in args[1]:
                continue
            if name not in nearby and not evidence.get("allow_unmentioned", False):
                continue
            expected_base = evidence.get("base")
            if expected_base is None:
                raise ContractError(f"offsetof evidence has no base: {name}")
            offsets[name].add(int(expected_base))
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
    supported_opcodes: Iterable[int] | None = None,
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
            supported_opcodes=supported_opcodes,
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
    *,
    supported_opcodes: Iterable[int] | None = None,
    writer_ranges: Sequence[WriterRange] | None = None,
    ownership_rows: Sequence[Mapping[str, str]] | None = None,
    capability_rows: Sequence[Mapping[str, str]] | None = None,
    coordinates: Mapping[tuple[str, str, str, str], object] | None = None,
    macro_ranges: Mapping[str, tuple[int, int, int]] | None = None,
    sv_sources: Mapping[str, str] | None = None,
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
                    row = _response_mutation_row(
                        case_id, fields, qword, bit, supported_opcodes
                    )
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
    if sv_sources is not None:
        if coordinates is None:
            raise ContractError("SV writer proof requires C-derived coordinates")
        images = {
            case: _load_case_bytes(
                oracle_root, case, int(CASE_LAYOUTS[case]["length"])
            )
            for case in ("cmq_sqe_qpc_create_request", "cmq_sq_doorbell")
        }
        validate_sv_writer_contract(
            sv_sources,
            coordinates,
            rows,
            ownership_rows,
            capability_rows,
            macro_ranges=macro_ranges,
            canonical_images=images,
        )
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


def closed_proven_cases(
    actual: Sequence[Mapping[str, str]],
    expected: Sequence[Mapping[str, str]],
) -> frozenset[str]:
    """功能：从逐列相等的 mutation report 与 C-derived candidate 推导闭合 case 集合。
    输入输出及副作用：actual/expected 只读；返回不可变 proven case 集合，不修改报告或启用生产路径。
    失败边界：任一允许 case 缺失完整 8-bit image 行时不进入 proven 集合，避免以总量或手工 TSV 越过 proof gate。"""
    actual_counts = Counter(row["case_id"] for row in actual)
    expected_counts = Counter(row["case_id"] for row in expected)
    return frozenset(
        case_id
        for case_id in PROVEN_CAPABILITY_CASES
        if actual_counts.get(case_id, 0) == expected_counts.get(case_id, 0)
        and expected_counts.get(case_id, 0)
        == int(CASE_LAYOUTS[case_id]["length"]) * 8
    )


if __name__ == "__main__":
    raise SystemExit(main())
