#!/usr/bin/env python3
"""
目录：tools；职责：从锁定的 rdma-driver-0.1.34 源码（cmq.c 的 SQE 填充函数与 cmq.h/gid.h/
defs.h 的字段宏）提取通用 CMQ 请求字段表，生成 hw/rdma/cmq_request_fields.tsv 与
src/codec/rdma/rdma_cmq_request_fields.svh。
依赖：Python 标准库；输入为解压后的驱动源码目录，只读。
设计说明：只覆盖尚无专用 body 编码器的 opcode。信封字段（opcode/index/wrap/valid/
USE_VFID/VFID_OVERRIDE）由 envelope codec 负责，不进表。字段值语义为驱动 info 结构体的
成员值；transform 记录驱动在 FIELD_PREP 前做的变换。
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

# 驱动填充函数 → 使用它的 opcode（exec_cmq_cmd 分派表）。
FUNCTIONS = {
    "xtrdma_sc_mw_alloc": ["MW_ALLOC"],
    "xtrdma_sc_mw_dealloc": ["MW_DEALLOC"],
    "xtrdma_sc_query_key": ["KEY_QUERY"],
    "xtrdma_sc_cq_resize": ["CQC_RESIZE"],
    "xtrdma_sc_cq_modify": ["CQC_MODIFY"],
    "xtrdma_sc_update_sd": ["SD_UPDATE"],
    "xtrdma_sc_update_src_addr_table": ["SRC_ADDR_UPDATE"],
    "xtrdma_sc_query_src_addr_table": ["SRC_ADDR_QUERY"],
    "xtrdma_sc_stat_query": ["STAT_QUERY"],
    "xtrdma_sc_occ_key_search": [
        "OCC_QPC", "OCC_CQC", "OCC_MRT", "OCC_PBLE", "OCC_SQRQE",
        "OCC_SGB", "OCC_IRQE", "OCC_EIRQE", "OCC_ORQE", "OCC_UAQE"],
    "xtrdma_sc_occ_idx_search": [
        "IDX_OCC_QPC", "IDX_OCC_CQC", "IDX_OCC_MRT", "IDX_OCC_PBLE",
        "IDX_OCC_SQRQE", "IDX_OCC_SGB", "IDX_OCC_IRQE", "IDX_OCC_EIRQE",
        "IDX_OCC_ORQE", "IDX_OCC_UAQE"],
    "xtrdma_sc_update_ifa_info": ["IFA_UPDATE"],
    "xtrdma_sc_ifa_query": ["IFA_QUERY"],
    "xtrdma_sc_occ_key_kickout": [
        "OCC_QPC_KICKOUT", "OCC_CQC_KICKOUT", "OCC_MRT_KICKOUT",
        "OCC_PBLE_KICKOUT", "OCC_SQRQE_KICKOUT", "OCC_SGB_KICKOUT",
        "OCC_IRQE_KICKOUT", "OCC_EIRQE_KICKOUT", "OCC_ORQE_KICKOUT",
        "OCC_UAQE_KICKOUT"],
    "xtrdma_sc_occ_pd_kickout": ["OCC_PD_KICKOUT"],
}

# exec_cmq_cmd 中不调用任何填充函数的 opcode：驱动只 memset 并提交。
NO_FILL_OPCODES = [
    "CEQC_MODIFY", "AEQC_MODIFY", "SD_QUERY", "QPC_FORCE_DELETE",
    "CQC_FORCE_DELETE", "SRFQC_MODIFY", "NOP",
]

ENVELOPE_MACROS = {
    "XTRDMA_CMQCQ_OPCODE", "XTRDMA_CMQSQ_WQE_INDEX", "XTRDMA_CMQSQ_WQE_WRAP",
    "XTRDMA_CMQSQ_WQE_VALID", "XTRDMA_CMQSQ_USE_VFID", "XTRDMA_CMQSQ_VFID_OVERRIDE",
}

HEADERS = ("cmq.h", "gid.h", "defs.h", "rdma_type.h")


class GenError(Exception):
    """驱动源码不符合本生成器支持的填充模式。"""


def load_macros(root: Path) -> dict[str, str]:
    macros: dict[str, str] = {}
    for name in HEADERS:
        path = root / name
        if not path.exists():
            continue
        for match in re.finditer(r"^#define\s+(\w+)\s+([^\n]*)", path.read_text(), re.M):
            macros.setdefault(match.group(1), re.sub(r"/\*.*?\*/", "", match.group(2)).strip())
    return macros


def mask_bits(macros: dict[str, str], name: str) -> tuple[int, int]:
    """返回字段宏的 (lsb, width)。"""
    text = macros.get(name)
    if text is None:
        raise GenError(f"missing field macro {name}")
    match = re.fullmatch(r"GENMASK(?:_ULL)?\(\s*(\d+)\s*,\s*(\d+)\s*\)", text)
    if match:
        high, low = int(match.group(1)), int(match.group(2))
        return low, high - low + 1
    match = re.fullmatch(r"BIT_ULL\(\s*(\d+)\s*\)", text)
    if match:
        return int(match.group(1)), 1
    raise GenError(f"unsupported mask form for {name}: {text}")


def int_macro(macros: dict[str, str], token: str) -> int:
    token = token.strip()
    if re.fullmatch(r"0x[0-9a-fA-F]+|\d+", token):
        return int(token, 0)
    if token in macros:
        return int_macro(macros, macros[token])
    raise GenError(f"cannot resolve integer {token}")


def function_body(source: str, name: str) -> str:
    match = re.search(r"^static [^\n]*\b" + name + r"\(.*?^\}", source, re.M | re.S)
    if match is None:
        raise GenError(f"missing driver function {name}")
    return match.group(0)


def split_field_preps(expr: str) -> list[tuple[str, str]]:
    """把 `FIELD_PREP(M, v) | FIELD_PREP(...)` 拆为 (macro, value expr)。"""
    out = []
    for match in re.finditer(r"FIELD_PREP\(\s*(\w+)\s*,\s*((?:[^()]|\([^()]*\))*?)\s*\)", expr):
        out.append((match.group(1), re.sub(r"\s+", " ", match.group(2))))
    return out


def classify_value(expr: str) -> tuple[str, str]:
    """把 FIELD_PREP 的值表达式映射为 (param, transform)。"""
    expr = expr.strip()
    if re.fullmatch(r"0x[0-9a-fA-F]+|\d+", expr):
        return "", f"const:{int(expr, 0)}"
    match = re.fullmatch(r"ether_addr_to_u64\(\s*\w+->(\w+)\s*\)", expr)
    if match:
        return match.group(1), "mac48"
    match = re.fullmatch(r"\w+->(\w+)\s*-\s*1", expr)
    if match:
        return match.group(1), "minus_one"
    match = re.fullmatch(r"\*?\w+->(\w+)|\*(\w+)", expr)
    if match:
        return match.group(1) or match.group(2), "value"
    raise GenError(f"unsupported field value expression: {expr}")


def assignments(body: str) -> dict[str, str]:
    """收集 `var = <FIELD_PREP chain>;` 赋值（后出现者覆盖先出现者）。"""
    out: dict[str, str] = {}
    for match in re.finditer(r"^\s*(\w+)\s*=\s*([^;]*);", body, re.M):
        out[match.group(1)] = match.group(2)
    return out


def qword_rows(macros, body: str, function: str) -> list[dict]:
    rows = []
    pattern = r"set_64bit_val\(\s*wqe\s*,\s*(\w+)\s*,\s*((?:[^()]|\((?:[^()]|\([^()]*\))*\))*?)\);"
    for match in re.finditer(pattern, body, re.S):
        offset = int_macro(macros, match.group(1))
        expr = re.sub(r"\s+", " ", match.group(2)).strip()
        # 变量取调用点之前最后一次赋值（驱动会复用同一局部变量写多个 qword）。
        assigned = assignments(body[:match.start()])
        if expr in assigned:
            expr = re.sub(r"\s+", " ", assigned[expr])
        if "FIELD_PREP" in expr:
            for macro, value in split_field_preps(expr):
                if macro in ENVELOPE_MACROS:
                    continue
                lsb, width = mask_bits(macros, macro)
                param, transform = classify_value(value)
                rows.append(dict(function=function, param=param, qword_byte=offset,
                                 lsb=lsb, width=width, transform=transform, macro=macro))
        elif re.fullmatch(r"0", expr):
            continue
        else:
            param, transform = classify_value(expr)
            rows.append(dict(function=function, param=param, qword_byte=offset,
                             lsb=0, width=64, transform=transform, macro="QWORD"))
    return rows


def memcpy_rows(macros, body: str, function: str) -> list[dict]:
    rows = []
    pattern = r"memcpy\(\s*(\(void \*\)\s*)?wqe\s*\+\s*(\w+)\s*,\s*\w+->(\w+)\s*,\s*([^;]*)\);"
    for match in re.finditer(pattern, body, re.S):
        base = int_macro(macros, match.group(2))
        offset = base if match.group(1) else base * 8
        length_expr = re.sub(r"\s+", " ", match.group(4))
        length_match = re.fullmatch(r"sizeof\(u8\)\s*\*\s*(\w+)", length_expr)
        if length_match:
            length = int_macro(macros, length_match.group(1))
        elif length_expr == "first_two_sd_data_len":
            length = (int_macro(macros, "XTRDMA_CMQ_SQ_WQE_CARRIED_SD_NUM") *
                      int_macro(macros, "XTRDMA_CMQ_SQ_SD_CHUNK_SIZE"))
        else:
            raise GenError(f"unsupported memcpy length in {function}: {length_expr}")
        rows.append(dict(function=function, param=match.group(3), qword_byte=offset,
                         lsb=0, width=length * 8, transform=f"bytes:{length}", macro="MEMCPY"))
    return rows


def sd_update_rows(macros, body: str) -> list[dict]:
    """update_sd：sd_num 与前两块 SD 数据直接填写；sd_num 超过 2 时再写 sd_buf_addr 与签名。"""
    function = "xtrdma_sc_update_sd"
    rows = []
    for macro, value in split_field_preps(assignments(body)["ctrl_data"]):
        if macro in ENVELOPE_MACROS:
            continue
        lsb, width = mask_bits(macros, macro)
        param, transform = classify_value(value)
        rows.append(dict(function=function, param=param, qword_byte=0, lsb=lsb,
                         width=width, transform=transform, macro=macro))
    rows += memcpy_rows(macros, body, function)
    rows.append(dict(function=function, param="sd_buf_addr",
                     qword_byte=int_macro(macros, "XTRDMA_CMQ_SQ_WQE_SD_BUF_ADEDR_OFFSET"),
                     lsb=0, width=64, transform="sd_extended", macro="QWORD"))
    sign_offset = int_macro(macros, "XTRDMA_CMQ_SQ_WQE_SD_SIGN_DATA_OFFSET")
    lsb, width = mask_bits(macros, "XTRDMA_CQPSQ_WQE_SD_SIGNATURE")
    rows.append(dict(function=function, param="", qword_byte=sign_offset, lsb=lsb,
                     width=width, transform="sd_signature", macro="XTRDMA_CQPSQ_WQE_SD_SIGNATURE"))
    lsb, width = mask_bits(macros, "XTRDMA_CQPSQ_WQE_SD_SIGN_EN")
    rows.append(dict(function=function, param="", qword_byte=sign_offset, lsb=lsb,
                     width=width, transform="sd_sign_en", macro="XTRDMA_CQPSQ_WQE_SD_SIGN_EN"))
    return rows


def extract(root: Path) -> list[dict]:
    macros = load_macros(root)
    source = (root / "cmq.c").read_text()
    rows: list[dict] = []
    for function, opcodes in FUNCTIONS.items():
        body = function_body(source, function)
        if function == "xtrdma_sc_update_sd":
            fn_rows = sd_update_rows(macros, body)
        else:
            fn_rows = qword_rows(macros, body, function) + memcpy_rows(macros, body, function)
        for row in fn_rows:
            row["opcodes"] = ",".join(opcodes)
        rows += fn_rows
    for opcode in NO_FILL_OPCODES:
        rows.append(dict(function="(none)", param="", qword_byte=0, lsb=0, width=0,
                         transform="no_fill", macro="-", opcodes=opcode))
    return rows


COLUMNS = ("opcodes", "function", "param", "qword_byte", "lsb", "width", "transform", "macro")


def render_tsv(rows: list[dict]) -> str:
    lines = ["# Generated by tools/gen_cmq_request_fields.py from rdma-driver-0.1.34; do not edit.",
             "\t".join(COLUMNS)]
    for row in rows:
        lines.append("\t".join(str(row[c]) for c in COLUMNS))
    return "\n".join(lines) + "\n"


def render_svh(rows: list[dict]) -> str:
    out = [
        "// 目录：硬件编解码层 codec/rdma/rdma_cmq_request_fields.svh（生成文件，勿手改）。",
        "// 职责：由 tools/gen_cmq_request_fields.py 从驱动 cmq.c 填充函数生成的通用 CMQ 请求字段表。",
        "// 依赖：rdma_defs.svh 的 RDMA_OP_* 常量。",
        "// 所有权与生命周期：编译期常量函数，无运行期状态。",
        "",
        "typedef struct {",
        "  string param;",
        "  int unsigned qword_byte;",
        "  int unsigned lsb;",
        "  int unsigned width;",
        "  string transform;",
        "} rdma_cmq_field_spec_t;",
        "",
        "// 功能：返回 opcode 的驱动字段布局；不在表内返回 0。",
        "// 输入/输出及副作用：specs 输出字段规格 {param, qword_byte, lsb, width, transform}（按驱动写入顺序）。",
        "// 失败/边界：opcode 有专用编码器或驱动无该 opcode 时返回 0。",
        "function automatic bit rdma_cmq_request_field_specs(",
        "  input bit [7:0] opcode,",
        "  output rdma_cmq_field_spec_t specs[$]",
        ");",
        "  specs.delete();",
        "  case (opcode)",
    ]
    groups: dict[str, list[dict]] = {}
    for row in rows:
        groups.setdefault(row["opcodes"], []).append(row)
    for opcodes, group in groups.items():
        names = [f"RDMA_OP_{name}" for name in opcodes.split(",")]
        for start in range(0, len(names), 3):
            chunk = ", ".join(names[start:start + 3])
            last = start + 3 >= len(names)
            out.append(f"    {chunk}{': begin' if last else ','}")
        for row in group:
            if row["transform"] == "no_fill":
                continue
            out.append(
                f"      specs.push_back('{{\"{row['param']}\", {row['qword_byte']}, "
                f"{row['lsb']}, {row['width']}, \"{row['transform']}\"}});")
        out.append("    end")
    out += ["    default: return 1'b0;", "  endcase", "  return 1'b1;", "endfunction", ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-root", required=True, type=Path)
    parser.add_argument("--tsv", type=Path, default=Path("hw/rdma/cmq_request_fields.tsv"))
    parser.add_argument("--svh", type=Path,
                        default=Path("src/codec/rdma/rdma_cmq_request_fields.svh"))
    parser.add_argument("--check", action="store_true",
                        help="compare against existing outputs instead of writing")
    args = parser.parse_args(argv)
    try:
        rows = extract(args.driver_root)
    except GenError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    outputs = {args.tsv: render_tsv(rows), args.svh: render_svh(rows)}
    if args.check:
        stale = [str(p) for p, text in outputs.items() if not p.exists() or p.read_text() != text]
        if stale:
            print("stale generated files: " + ", ".join(stale), file=sys.stderr)
            return 1
        return 0
    for path, text in outputs.items():
        path.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
