#!/usr/bin/env python3
"""
目录：tools；职责：从锁定驱动 cmq.c 的 CQ 侧分派（xtrdma_exec_cmq_cq_cmd）得到每个 opcode 的 CQE 解析函数，
把这些 *_cqe_info 函数原样编译进用户态 harness，逐位翻转 CQE 测出驱动实际读取的位，生成
hw/rdma/golden_vectors/cmq_responses.hex（每个 opcode：读取位掩码 + 读取位全置 1 的 CQE）。
依赖：tools/cmq_request_oracle.py 的 shim 与抽取工具、gcc、驱动源码目录（只读）。
设计说明：公共头（owner/wrap/index/opcode/ecode）由 xtrdma_get_cqe_common_info 的字段宏给出；
payload 读取位由翻转实验得出，超出 64B CQE 的读取记为 overread。
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmq_request_oracle as base  # noqa: E402

GOLDEN = Path("hw/rdma/golden_vectors/cmq_responses.hex")
HEADER_MACROS = ("XTRDMA_CMQSQ_WQE_VALID", "XTRDMA_CMQSQ_WQE_WRAP", "XTRDMA_CMQSQ_WQE_INDEX",
                 "XTRDMA_CMQCQ_OPCODE", "XTRDMA_CMQCQ_CMD_ECODE")
EXTRACTS = [
    ("debugfs_common.h", "struct", "cmq_compl_occ_info"),
    ("debugfs_common.h", "struct", "cmq_compl_ifa_query"),
]
SCAN_BYTES = 128


def cq_dispatch(source: str) -> dict[str, str | None]:
    """xtrdma_exec_cmq_cq_cmd 的 switch：opcode 名 → *_cqe_info 函数（仅 break 的为 None）。"""
    body = base.fields.function_body(source, "xtrdma_exec_cmq_cq_cmd")
    body = body[body.index("switch"):]
    table: dict[str, str | None] = {}
    pending: list[str] = []
    for line in body.splitlines():
        label = re.search(r"case\s+X?TRDMA_OP_(\w+)\s*:", line)
        if label:
            pending.append(label.group(1))
            continue
        call = re.search(r"\b(xtrdma_sc_\w+_cqe_info)\s*\(", line)
        if call or re.search(r"\bbreak\s*;", line):
            for name in pending:
                table[name] = call.group(1) if call else None
            pending = []
    return table


def header_mask(root: Path) -> int:
    macros = base.fields.load_macros(root)
    mask = 0
    for name in HEADER_MACROS:
        lsb, width = base.fields.mask_bits(macros, name)
        mask |= ((1 << width) - 1) << lsb
    return mask


def render_harness(root: Path, extractors: list[str]) -> str:
    source = (root / "cmq.c").read_text()
    parts = [base.PRELUDE,
             "static void get_64bit_val(__be64 *w, u32 i, u64 *v) { *v = be64_to_cpu(w[i >> 3]); }"]
    for header, kind, name in base.EXTRACTS + EXTRACTS:
        parts.append(base.extract_text(root / header, kind, name))
    # 驱动在 debugfs.h 的 enum 中定义 OCC 尺寸；去掉 shim 里的同名宏后按原文引入。
    parts.append("#undef XTRDMA_OCC_QPC_SIZE")
    parts.append(base.extract_text(root / "debugfs.h", "enum", "xtrdma_occ_size_bytes"))
    for function in extractors:
        parts.append(base.fields.function_body(source, function))
    main = ["int main(void)", "{", f"\tstatic u8 cqe[{SCAN_BYTES}];",
            "\tstatic u8 ref[512], out[512];"]
    for function in extractors:
        main += [
            "\t{",
            f"\t\tprintf(\"{function}\");",
            "\t\tmemset(cqe, 0, sizeof(cqe)); memset(ref, 0, sizeof(ref));",
            f"\t\t{function}((__be64 *)cqe, ref);",
            f"\t\tfor (int byte = 0; byte < {SCAN_BYTES}; byte++) {{",
            "\t\t\tunsigned used = 0;",
            "\t\t\tfor (int bit = 0; bit < 8; bit++) {",
            "\t\t\t\tmemset(cqe, 0, sizeof(cqe)); memset(out, 0, sizeof(out));",
            "\t\t\t\tcqe[byte] = (u8)(1u << bit);",
            f"\t\t\t\t{function}((__be64 *)cqe, out);",
            "\t\t\t\tif (memcmp(out, ref, sizeof(out)))",
            "\t\t\t\t\tused |= 1u << bit;",
            "\t\t\t}",
            "\t\t\tprintf(\" %02x\", used);",
            "\t\t}",
            "\t\tprintf(\"\\n\");",
            "\t}",
        ]
    main += ["\treturn 0;", "}"]
    parts.append("\n".join(main))
    return "\n\n".join(parts) + "\n"


def consumed_bytes(root: Path, cc: str, extractors: list[str]) -> dict[str, list[int]]:
    with tempfile.TemporaryDirectory(prefix="cmq_response_oracle.") as tmp:
        c_path, exe = Path(tmp) / "harness.c", Path(tmp) / "harness"
        c_path.write_text(render_harness(root, extractors))
        build = subprocess.run([cc, "-std=gnu11", "-O1", "-w", "-I", str(root), "-o", str(exe),
                                str(c_path)], capture_output=True, text=True)
        if build.returncode != 0:
            raise base.OracleError("harness build failed:\n" + build.stderr[-4000:])
        output = subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout
    return {line.split()[0]: [int(x, 16) for x in line.split()[1:]] for line in output.splitlines()}


def render(root: Path, cc: str) -> str:
    source = (root / "cmq.c").read_text()
    opcodes = base.driver_opcodes(root)
    table = cq_dispatch(source)
    extractors = sorted({fn for fn in table.values() if fn})
    used = consumed_bytes(root, cc, extractors)
    header = header_mask(root)
    out = ["# xtr_v1-golden-v1"]
    for number, (name, function) in enumerate(table.items(), 1):
        if name not in opcodes:
            raise base.OracleError(f"driver enum lacks XTRDMA_OP_{name}")
        consumed = used[function] if function else [0] * SCAN_BYTES
        words = [int.from_bytes(bytes(consumed[q * 8:q * 8 + 8]), "big") for q in range(8)]
        words[0] |= header
        overread = sum(1 for b in consumed[64:] if b)
        index, wrap = number % 32, number & 1
        qword0 = (1 << 63) | (wrap << 45) | (index << 40) | (opcodes[name] << 32)
        qword0 |= words[0] & ~header
        cqe = [qword0] + words[1:]
        inputs = [f"opcode=0x{opcodes[name]:02x}", f"index=0x{index:02x}", f"wrap=0x{wrap:x}",
                  f"extractor={function or 'none'}"]
        inputs += [f"consumed{q}=0x{w:x}" for q, w in enumerate(words)]
        inputs.append(f"overread=0x{overread:x}")
        image = " ".join(f"{b:02x}" for w in cqe for b in w.to_bytes(8, "big"))
        out += [f"# case: {name.lower()}_response", "# inputs: " + ",".join(inputs),
                "# bytes: 64", image, ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-root", required=True, type=Path)
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("--golden", type=Path, default=GOLDEN)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        text = render(args.driver_root, args.cc)
    except (base.OracleError, base.fields.GenError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.check:
        if not args.golden.exists() or args.golden.read_text() != text:
            print(f"stale golden vectors: {args.golden}", file=sys.stderr)
            return 1
        return 0
    args.golden.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
