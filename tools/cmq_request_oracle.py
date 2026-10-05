#!/usr/bin/env python3
"""
目录：tools；职责：把锁定驱动 cmq.c 中表驱动 opcode 的 SQE 填充函数原样编译进用户态 harness，
为每个 opcode 生成 golden SQE（hw/rdma/golden_vectors/cmq_requests.hex），供 SV 字段 codec 逐字节比对。
依赖：Python 标准库、gcc；输入为解压后的驱动源码目录（只读），临时文件写入私有目录。
设计说明：harness 只提供用户态类型/宏 shim 与各 info 结构体的取值装配；被测的填充函数、
info 结构体定义、opcode 枚举与字段宏全部按原文取自驱动源码，不做改写。
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_cmq_request_fields as fields  # noqa: E402

GOLDEN = Path("hw/rdma/golden_vectors/cmq_requests.hex")

PRELUDE = r"""
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define __OSDEP_H
#define __DEBUGFS_H
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
typedef uint8_t __u8; typedef uint16_t __u16; typedef uint32_t __u32; typedef uint64_t __u64;
typedef uint64_t dma_addr_t; typedef uint64_t __be64; typedef uint32_t __be32;
#define __iomem
#define __packed __attribute__((packed))
struct list_head { struct list_head *next; struct list_head *prev; };
typedef struct { unsigned int refs; } refcount_t;
typedef struct { int unused; } wait_queue_head_t;
typedef struct { int unused; } spinlock_t;
struct xtrdma_dma_mem { void *va; dma_addr_t iova; u32 size; } __packed;
struct xtrdma_cmq_quanta;
struct xtrdma_ring { u32 head; u32 tail; u32 size; };
struct xtrdma_sc_dev;
struct xtrdma_sc_cmq {
	struct xtrdma_sc_dev *sc_dev; u64 sq_pa; struct xtrdma_ring sq_ring;
	struct xtrdma_cmq_quanta *sq_base; struct xtrdma_cmq_quanta *cq_base;
	u64 *request_array; u32 sq_size; u32 cq_size; u8 sq_polarity:1; u8 cq_polarity:1;
	u64 cmq_req_stats; u64 cmq_cmpl_stats;
};
struct xtrdma_sc_dev { struct xtrdma_sc_cmq *sc_cmq; };
static inline void refcount_inc(refcount_t *ref) { ++ref->refs; }
#define BIT(n) (1U << (n))
#define BIT_ULL(n) (1ULL << (n))
#define GENMASK(h, l) ((((uint64_t)~0ULL) >> (63 - (h))) & ((uint64_t)~0ULL << (l)))
#define GENMASK_ULL(h, l) (((uint64_t)~0ULL >> (63 - (h))) & ((uint64_t)~0ULL << (l)))
#define FIELD_PREP(mask, val) \
	((((uint64_t)(val)) << __builtin_ctzll((uint64_t)(mask))) & (uint64_t)(mask))
#define FIELD_GET(mask, val) \
	(((uint64_t)(val) & (uint64_t)(mask)) >> __builtin_ctzll((uint64_t)(mask)))
#define cpu_to_be64(v) (__builtin_bswap64((uint64_t)(v)))
#define be64_to_cpu(v) (__builtin_bswap64((uint64_t)(v)))
#define get_unaligned(ptr) ({ uint64_t _v; memcpy(&_v, (ptr), sizeof(_v)); _v; })
#define WARN_ON(x) ((void)(x))
#define ETH_ALEN 6
#define XTRDMA_64BIT_TO_BYTE 8
#define XTRDMA_ADDR_512_BYTE_SHIFT 9
#define XTRDMA_OCC_QPC_SIZE 512
#include <cmq.h>
static void set_64bit_val(__be64 *wqe_words, u32 byte_index, u64 val)
{
	wqe_words[byte_index >> 3] = cpu_to_be64(val);
}
static inline u64 ether_addr_to_u64(const u8 *addr)
{
	u64 u = 0;
	int i;

	for (i = 0; i < ETH_ALEN; i++)
		u = u << 8 | addr[i];
	return u;
}
"""

# 驱动头中需要按原文抽取的定义：(文件, 种类, 名字)。
EXTRACTS = [
    ("defs.h", "define", "XTRDMA_IPV6_ADDR_LENGTH"),
    ("defs.h", "function", "xtrdma_bytes_xor"),
    ("gid.h", "define", "XTRDMA_SRCADDR_WQE_OFFSET"),
    ("gid.h", "struct", "xtrdma_hw_src_addr_info"),
    ("mr.h", "enum", "xtrdma_mr_state"),
    ("mr.h", "enum", "xtrdma_mem_type"),
    ("mr.h", "struct", "xtrdma_mw_alloc_info"),
    ("cq.h", "struct", "xtrdma_resize_cq_cmd_wqe_ctx"),
    ("debugfs_common.h", "struct", "xtrdma_mrt_query_param"),
    ("debugfs_common.h", "struct", "xtrdma_stat_query_param"),
    ("debugfs_common.h", "struct", "xtrdma_occ_key_param"),
    ("debugfs_common.h", "struct", "xtrdma_occ_idx_param"),
    ("debugfs_common.h", "struct", "xtrdma_ifa_param"),
    ("debugfs.h", "struct", "cmq_req_occ_key"),
    ("debugfs.h", "struct", "cmq_req_occ_idx"),
]

SRC_ADDR_SETUP = ("struct xtrdma_hw_src_addr_info info = {0}; struct xtrdma_sc_cmq cmq = {0}; "
                  "struct xtrdma_sc_dev dev = {&cmq}; cmq.sq_polarity = pol;",
                  "info.{p}", "{fn}(&dev, &info, wqe, idx);")
OCC_KEY_SETUP = ("struct xtrdma_occ_key_param kp = {0}; struct cmq_req_occ_key info = {&kp, 0};",
                 "kp.{p}", "{fn}(wqe, idx, op, &info, pol);")


def plain_setup(c_type: str) -> tuple[str, str, str]:
    return (f"{c_type} info; memset(&info, 0, sizeof(info));", "info.{p}",
            "{fn}(wqe, idx, op, &info, pol);")


# 每个填充函数的 info 装配：C 声明、成员 lvalue 模板与调用表达式。
SETUP = {
    "xtrdma_sc_mw_alloc": plain_setup("struct xtrdma_mw_alloc_info"),
    "xtrdma_sc_mw_dealloc": plain_setup("struct xtrdma_mw_alloc_info"),
    "xtrdma_sc_query_key": plain_setup("struct xtrdma_mrt_query_param"),
    "xtrdma_sc_cq_resize": plain_setup("struct xtrdma_resize_cq_cmd_wqe_ctx"),
    "xtrdma_sc_cq_modify": plain_setup("struct xtrdma_cmq_modify_cqc_info"),
    "xtrdma_sc_update_sd": plain_setup("struct xtrdma_cmq_hmc_sd_info"),
    "xtrdma_sc_update_src_addr_table": SRC_ADDR_SETUP,
    "xtrdma_sc_query_src_addr_table": SRC_ADDR_SETUP,
    "xtrdma_sc_stat_query": plain_setup("struct xtrdma_stat_query_param"),
    "xtrdma_sc_occ_key_search": OCC_KEY_SETUP,
    "xtrdma_sc_occ_key_kickout": OCC_KEY_SETUP,
    "xtrdma_sc_occ_idx_search": (
        "struct xtrdma_occ_idx_param ip = {0}; struct cmq_req_occ_idx info = {&ip, 0};",
        "ip.{p}", "{fn}(wqe, idx, op, &info, pol);"),
    "xtrdma_sc_update_ifa_info": plain_setup("struct xtrdma_cmq_hmc_ifa_info"),
    "xtrdma_sc_ifa_query": plain_setup("struct xtrdma_ifa_param"),
    "xtrdma_sc_occ_pd_kickout": ("u64 pd_pba = 0;", "{p}", "{fn}(wqe, idx, op, &pd_pba, pol);"),
}
# 成员不在 SETUP 默认 lvalue 上的特例。
LVALUE_OVERRIDES = {"buf_pa": "info.buf_pa", "sd_buf_addr": "info.sd_mem.iova"}

# 取值约束：SV 所有权掩码比驱动 FIELD_PREP 更严或 C 成员更窄时取严者。
VALUE_MASKS = {
    ("xtrdma_sc_update_sd", "sd_buf_addr"): 0xffff_ffff_ffff_fe00,
    ("xtrdma_sc_update_ifa_info", "data"): 0x03ff_ffff_ffff_ffff,
    ("xtrdma_sc_query_key", "stag_idx"): 0xffff,
}
# SD 数据块（16B = sd_idx qword + data_info qword）的允许位，见 request_mask(SD_UPDATE)。
SD_CHUNK_MASKS = (0x0000_0000_0000_0fff, 0xffff_ffff_ffff_fff1)


class OracleError(Exception):
    """驱动源码抽取或 harness 构建失败。"""


def extract_text(path: Path, kind: str, name: str) -> str:
    text = path.read_text()
    if kind == "define":
        match = re.search(r"^#define\s+" + name + r"\b[^\n]*", text, re.M)
    elif kind == "function":
        match = re.search(r"^static [^\n]*\b" + name + r"\(.*?^\}", text, re.M | re.S)
    else:
        match = re.search(r"^" + kind + r"\s+" + name + r"\s*\{.*?^\}[^;]*;", text, re.M | re.S)
    if match is None:
        raise OracleError(f"{path.name}: missing {kind} {name}")
    return match.group(0)


def driver_opcodes(root: Path) -> dict[str, int]:
    """从 cmq.h 的 XTRDMA_OP_* 枚举读取 opcode 值。"""
    text = (root / "cmq.h").read_text()
    values = {}
    for match in re.finditer(r"\bX?TRDMA_OP_(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)", text):
        values[match.group(1)] = int(match.group(2), 0)
    return values


def pattern_value(seed: str, width: int) -> int:
    value = int.from_bytes(hashlib.sha256(seed.encode()).digest()[:8], "big")
    return value & ((1 << width) - 1) if width < 64 else value


def build_cases(root: Path) -> list[dict]:
    """每个 opcode 一例（SD_UPDATE 分 2 个与 4 个 SD 两例），取值为确定性伪随机。"""
    opcodes = driver_opcodes(root)
    groups: dict[str, list[dict]] = {}
    for row in fields.extract(root):
        groups.setdefault(row["opcodes"], []).append(row)
    cases = []
    for opcode_list, group in groups.items():
        for name in opcode_list.split(","):
            if name not in opcodes:
                raise OracleError(f"driver enum lacks XTRDMA_OP_{name}")
            for sd_num in ([2, 4] if name == "SD_UPDATE" else [None]):
                number = len(cases) + 1
                case = dict(name=name.lower() + (f"_sd{sd_num}" if sd_num else ""),
                            opcode=opcodes[name], function=group[0]["function"],
                            index=number % 32, polarity=number & 1, values={}, blobs={})
                for row in group:
                    fill_case_value(case, row, sd_num)
                cases.append(case)
    return cases


def fill_case_value(case: dict, row: dict, sd_num: int | None) -> None:
    param, transform, width = row["param"], row["transform"], row["width"]
    if (not param or transform.startswith("const:") or transform.startswith("sd_sign")
            or param in case["values"] or param in case["blobs"]):
        return
    seed = f"{case['name']}:{param}"
    if transform == "mac48":
        case["blobs"][param] = pattern_value(seed, 48).to_bytes(6, "big")
    elif transform.startswith("bytes:"):
        length = int(transform.split(":")[1])
        if param == "sd_data":
            data = b"".join((pattern_value(f"{seed}:{i}", 64) & SD_CHUNK_MASKS[i % 2]).to_bytes(8, "big")
                            for i in range(length // 8))
        else:
            data = b"".join(pattern_value(f"{seed}:{i}", 64).to_bytes(8, "big")
                            for i in range(length // 8))
        case["blobs"][param] = data
    elif param == "sd_num":
        case["values"][param] = sd_num
        extra = (sd_num - 2) * 16 if sd_num > 2 else 0
        case["blobs"]["sd_extra_data"] = b"".join(
            pattern_value(f"{seed}:extra:{i}", 64).to_bytes(8, "big") for i in range(extra // 8))
    elif transform == "sd_extended":
        value = pattern_value(seed, 64) & VALUE_MASKS[(row["function"], param)]
        case["values"][param] = value if sd_num and sd_num > 2 else 0
    elif transform == "minus_one":
        case["values"][param] = 1  # 驱动 WARN_ON(num != 1)
    else:
        mask = VALUE_MASKS.get((row["function"], param), (1 << width) - 1 if width < 64 else -1)
        case["values"][param] = pattern_value(seed, width) & mask


def c_bytes(data: bytes) -> str:
    return "{" + ", ".join(f"0x{b:02x}" for b in data) + "}"


def render_case(case: dict) -> list[str]:
    lines = ["\t{", f"\t\tu32 idx = {case['index']}; u8 op = 0x{case['opcode']:02x};"
                    f" u8 pol = {case['polarity']};",
             "\t\tmemset(wqe, 0, sizeof(wqe));"]
    if case["function"] != "(none)":
        declare, lvalue, call = SETUP[case["function"]]
        lines.append("\t\t" + declare)
        for param, value in case["values"].items():
            target = LVALUE_OVERRIDES.get(param, lvalue.format(p=param))
            lines.append(f"\t\t{target} = 0x{value:x}ULL;")
        for param, data in case["blobs"].items():
            if param == "sd_extra_data":
                lines.append(f"\t\tstatic u8 extra[{max(len(data), 1)}] = {c_bytes(data or b'0')};")
                lines.append("\t\tinfo.sd_mem.va = extra;")
            else:
                lines.append(f"\t\tstatic const u8 {param}_v[{len(data)}] = {c_bytes(data)};")
                lines.append(f"\t\tmemcpy(&{lvalue.format(p=param)}, {param}_v, {len(data)});")
        lines.append("\t\t" + call.format(fn=case["function"]))
    lines += ["\t\t(void)idx; (void)op; (void)pol;",
              f"\t\tprintf(\"{case['name']}\");",
              "\t\tfor (int i = 0; i < 64; i++) printf(\" %02x\", b[i]);",
              "\t\tprintf(\"\\n\");", "\t}"]
    return lines


def render_harness(root: Path, cases: list[dict]) -> str:
    parts = [PRELUDE]
    for header, kind, name in EXTRACTS:
        parts.append(extract_text(root / header, kind, name))
    source = (root / "cmq.c").read_text()
    for function in fields.FUNCTIONS:
        parts.append(fields.function_body(source, function))
    body = ["int main(void)", "{", "\t__be64 wqe[8];", "\tu8 *b = (u8 *)wqe;"]
    for case in cases:
        body += render_case(case)
    body += ["\treturn 0;", "}"]
    parts.append("\n".join(body))
    return "\n\n".join(parts) + "\n"


def run_harness(root: Path, cc: str) -> tuple[list[dict], dict[str, str]]:
    cases = build_cases(root)
    source = render_harness(root, cases)
    with tempfile.TemporaryDirectory(prefix="cmq_request_oracle.") as tmp:
        c_path = Path(tmp) / "harness.c"
        exe = Path(tmp) / "harness"
        c_path.write_text(source)
        build = subprocess.run([cc, "-std=gnu11", "-O1", "-w", "-I", str(root),
                                "-o", str(exe), str(c_path)], capture_output=True, text=True)
        if build.returncode != 0:
            raise OracleError("harness build failed:\n" + build.stderr[-4000:])
        run = subprocess.run([str(exe)], capture_output=True, text=True, check=True)
    images = {}
    for line in run.stdout.splitlines():
        name, *hex_bytes = line.split()
        images[name] = " ".join(hex_bytes)
    return cases, images


def render_golden(cases: list[dict], images: dict[str, str]) -> str:
    out = ["# xtr_v1-golden-v1"]
    for case in cases:
        inputs = [f"opcode=0x{case['opcode']:02x}", f"index=0x{case['index']:02x}",
                  f"polarity=0x{case['polarity']:x}"]
        inputs += [f"{k}=0x{v:x}" for k, v in case["values"].items()]
        inputs += [f"{k}=0x{v.hex()}" for k, v in case["blobs"].items() if v]
        out += [f"# case: {case['name']}", "# inputs: " + ",".join(inputs), "# bytes: 64",
                images[case["name"]], ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-root", required=True, type=Path)
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("--golden", type=Path, default=GOLDEN)
    parser.add_argument("--emit-source", type=Path, help="also write the generated harness")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.emit_source:
            args.emit_source.write_text(render_harness(args.driver_root,
                                                       build_cases(args.driver_root)))
        cases, images = run_harness(args.driver_root, args.cc)
    except (OracleError, fields.GenError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    text = render_golden(cases, images)
    if args.check:
        if not args.golden.exists() or args.golden.read_text() != text:
            print(f"stale golden vectors: {args.golden}", file=sys.stderr)
            return 1
        return 0
    args.golden.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
