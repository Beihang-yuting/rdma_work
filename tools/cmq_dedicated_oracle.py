#!/usr/bin/env python3
"""
目录：tools；职责：把锁定驱动 cmq.c 中 21 个专用编码 opcode 的 SQE 填充函数（QPC、MRT、OCC_FLUSH、
CQC/CEQC/AEQC/SRFQC 的 CREATE/DELETE/QUERY、TQ_FLUSH）原样编译进用户态 harness，生成
hw/rdma/golden_vectors/cmq_requests_dedicated.hex，供 SV 专用编码器逐字节比对。
依赖：tools/cmq_request_oracle.py 的 shim 与抽取工具、gcc、驱动源码目录（只读）；
hw/rdma/golden_vectors/context.hex 提供 QPC 签名源与 CQ/EQ/SRQ 上下文字节（已由 SV 上下文 codec 验证）。
设计说明：每例的取值以驱动 info 结构体成员名记录；上下文类输入以 context.hex 用例名引用。
"""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmq_request_oracle as base  # noqa: E402

GOLDEN = Path("hw/rdma/golden_vectors/cmq_requests_dedicated.hex")
CONTEXT = Path("hw/rdma/golden_vectors/context.hex")

EXTRACTS = [
    ("qp.h", "define", "XTRDMA_ADDR_4096_BYTE_SHIFT"),
    ("qp.h", "enum", "xtrdma_qp_st"),
    ("qp.h", "enum", "xtrdma_modify_mode"),
    ("qp.h", "enum", "xtrdma_wbe_tpl_num"),
    ("qp.h", "struct", "xtrdma_cmdq_qp_info"),
    ("mr.h", "enum", "xtrdma_addressing_type"),
    ("mr.h", "enum", "xtrdma_host_page_size"),
    ("mr.h", "enum", "xtrdma_pbl_mode"),
    ("mr.h", "struct", "xtrdma_reg_mr_info"),
    ("cq.h", "struct", "xtrdma_cq_context"),
    ("debugfs_common.h", "struct", "xtrdma_qpc_query_param"),
    ("debugfs_common.h", "struct", "xtrdma_cqc_query_param"),
]

FUNCTIONS = [
    "xtrdma_sc_qp_create", "xtrdma_sc_qp_modify", "xtrdma_sc_qp_delete", "xtrdma_sc_qp_query",
    "xtrdma_sc_alloc_key", "xtrdma_sc_mr_register", "xtrdma_sc_mr_dereg", "xtrdma_sc_occ_flush",
    "xtrdma_sc_cq_create", "xtrdma_sc_cq_delete", "xtrdma_sc_cq_query",
    "xtrdma_sc_eq_ctx_create", "xtrdma_sc_eq_ctx_delete", "xtrdma_sc_eq_ctx_query",
    "xtrdma_sc_tq_flush", "xtrdma_sc_srfq_ctx_create", "xtrdma_sc_srfq_ctx_delete",
    "xtrdma_sc_srfq_ctx_query",
]

CALL = "{fn}(wqe, idx, op, &info, pol);"


def load_context(path: Path) -> dict[str, tuple[dict[str, str], bytes]]:
    """读取 context.hex：用例名 → (输入键值, 负载字节)。"""
    cases = {}
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("# case: "):
            name = line[len("# case: "):]
            inputs = dict(item.split("=", 1) for item in lines[i + 1][len("# inputs: "):].split(","))
            payload = bytes(int(x, 16) for x in lines[i + 3].split())
            cases[name] = (inputs, payload)
    return cases


def pv(seed: str, width: int) -> int:
    return base.pattern_value(seed, width)


def case(name, opcode, function, assigns, inputs, statics=(), call=CALL, declare=None):
    return dict(name=name, opcode=opcode, function=function, assigns=list(assigns),
                inputs=dict(inputs), statics=list(statics), call=call, declare=declare)


def qp_cases(ops: dict[str, int], context) -> list[dict]:
    source_inputs, qpc = context["qpc_rc_boundary"]
    qpn = int(source_inputs["qpn"], 0)
    qpc_static = [f"static u8 qpc_buf[512] = {base.c_bytes(qpc)};"]
    out = []
    for name, mode, state in (("qpc_create", None, None), ("qpc_modify_full", 1, 3),
                              ("qpc_modify_state", 0, 1), ("qpc_modify_partial", 2, 2)):
        sq_cqn, rq_cqn = pv(f"{name}:sq", 21), pv(f"{name}:rq", 21)
        buffer = pv(f"{name}:buf", 39) << 9 if mode in (None, 1) else 0
        assigns = [("info.qpn", qpn), ("info.sq_cqn", sq_cqn), ("info.rq_cqn", rq_cqn),
                   ("info.qpc_buffer_addr_pa", buffer >> 9)]
        inputs = {"qpn": qpn, "sq_cqn": sq_cqn, "rq_cqn": rq_cqn, "qpc_buffer": buffer}
        if mode is not None:
            assigns += [("info.modify_mode", mode), ("info.nxt_qp_st", state),
                        ("info.wbe_tpl_num", 0)]
            inputs.update(modify_mode=mode, next_state=state, wbe_tpl_num=0)
        if mode == 2:
            for q in range(4):
                start, wbe, data = (pv(f"{name}:s{q}", 6), pv(f"{name}:w{q}", 8),
                                    pv(f"{name}:d{q}", 64))
                assigns += [(f"info.modify_start_qword_{q}", start),
                            (f"info.modify_wbe_{q}", wbe), (f"info.modify_data_{q}", data)]
                inputs.update({f"start_qword{q}": start, f"wbe{q}": wbe, f"data{q}": data})
        if mode in (None, 1):
            assigns.append(("info.qpc_buffer_addr_va", "qpc_buf"))
            inputs["qpc_source"] = "qpc_rc_boundary"
        opcode = ops["QPC_CREATE"] if mode is None else ops["QPC_MODIFY"]
        fn = "xtrdma_sc_qp_create" if mode is None else "xtrdma_sc_qp_modify"
        out.append(case(name, opcode, fn, assigns, inputs,
                        qpc_static if mode in (None, 1) else (),
                        declare="struct xtrdma_cmdq_qp_info info;"))
    qpn, sq_cqn, rq_cqn = pv("qpc_delete:qpn", 21), pv("qpc_delete:sq", 21), pv("qpc_delete:rq", 21)
    out.append(case("qpc_delete", ops["QPC_DELETE"], "xtrdma_sc_qp_delete",
                    [("info.qpn", qpn), ("info.sq_cqn", sq_cqn), ("info.rq_cqn", rq_cqn)],
                    {"qpn": qpn, "sq_cqn": sq_cqn, "rq_cqn": rq_cqn},
                    declare="struct xtrdma_cmdq_qp_info info;"))
    qpn, buffer = pv("qpc_query:qpn", 21), pv("qpc_query:buf", 39) << 9
    out.append(case("qpc_query", ops["QPC_QUERY"], "xtrdma_sc_qp_query",
                    [("info.qpn", qpn), ("info.buffer_addr", buffer)],
                    {"qpn": qpn, "qpc_buffer": buffer},
                    declare="struct xtrdma_qpc_query_param info;"))
    return out


def mrt_cases(ops: dict[str, int]) -> list[dict]:
    out = []
    for opname, fn in (("KEY_ALLOC", "xtrdma_sc_alloc_key"), ("MR_REGISTER", "xtrdma_sc_mr_register")):
        for pbl in range(3):
            name = f"{opname.lower()}_pbl{pbl}"
            v = {
                "stag_index": pv(f"{name}:stag", 24), "states": 2, "stag_key": pv(f"{name}:key", 8),
                "pd_idx": pv(f"{name}:pd", 16), "pld_vf_id": pv(f"{name}:vf", 8),
                "pld_vf_en": pv(f"{name}:vfen", 1), "right": 0x1f,
                "type": pv(f"{name}:type", 16) % 3, "host_pg_size": pv(f"{name}:pg", 16) % 3,
                "pbl_mode": pbl, "addr_mode": pv(f"{name}:am", 1),
                "invalidate_en": pv(f"{name}:inv", 1), "len": pv(f"{name}:len", 46),
                "odp": pv(f"{name}:odp", 1), "start_va": pv(f"{name}:va", 64),
                "mr_sn": pv(f"{name}:sn", 12),
            }
            if pbl == 2:
                v["first_pbl_idx"] = pv(f"{name}:first", 28)
            else:
                v["payload_pba_0"] = pv(f"{name}:pba0", 52) << 12
            if pbl == 1:
                v["payload_pba_1"] = pv(f"{name}:pba1", 52) << 12
            out.append(case(name, ops[opname], fn, [(f"info.{k}", x) for k, x in v.items()], v,
                            declare="struct xtrdma_reg_mr_info info;"))
    v = {"stag_index": pv("mr_dereg:stag", 24), "stag_key": pv("mr_dereg:key", 8), "states": 0}
    out.append(case("mr_deregister", ops["MR_DEREGISTER"], "xtrdma_sc_mr_dereg",
                    [(f"info.{k}", x) for k, x in v.items()], v,
                    declare="struct xtrdma_reg_mr_info info;"))
    return out


def occ_cases(ops: dict[str, int]) -> list[dict]:
    """驱动调用方使用的 5 种 OCC_FLUSH 组合：VF、MR_SN、QPN、QPN+PD、PD。"""
    flags = ["qpc_flag", "cqc_flag", "mrt_flag", "pble_flag", "sqrqe_flag", "sgb_irqe_flag",
             "eirqe_flag", "orqe_flag", "uaqe_flag", "pd_flag"]
    patterns = {
        "vf": (dict.fromkeys(flags[:9], 1), dict(vf_flush=1)),
        "serial": ({"pble_flag": 1}, dict(mr_sn_flush=1, flush_mr_sn=pv("occ:sn", 12))),
        "qpn": ({"eirqe_flag": 1, "orqe_flag": 1, "uaqe_flag": 1},
                dict(flush_qpn=pv("occ:qpn", 21))),
        "qpn_pd": ({"pd_flag": 1}, dict(flush_qpn=pv("occ:qpnpd", 21),
                                        flush_pd_pba=pv("occ:pba1", 40) << 12)),
        "pd": ({"pd_flag": 1}, dict(flush_pd_pba=pv("occ:pba2", 40) << 12)),
    }
    out = []
    for suffix, (set_flags, extra) in patterns.items():
        v = {flag: set_flags.get(flag, 0) for flag in flags}
        v.update(dict(flush_qpn=0, flush_mr_sn=0, flush_pd_pba=0, vf_flush=0, mr_sn_flush=0))
        v.update(extra)
        out.append(case(f"occ_flush_{suffix}", ops["OCC_FLUSH"], "xtrdma_sc_occ_flush",
                        [(f"info.{k}", x) for k, x in v.items()], v,
                        declare="struct xtrdma_cmq_occ_flush_info info;"))
    return out


def context_cases(ops: dict[str, int], context) -> list[dict]:
    out = []
    cqc = context["cqc_create_body_boundary"][1][8:64]
    for name, op, fn in (("cqc_create", "CQC_CREATE", "xtrdma_sc_cq_create"),
                         ("cqc_delete", "CQC_DELETE", "xtrdma_sc_cq_delete")):
        cqn = pv(f"{name}:cqn", 21)
        out.append(case(name, ops[op], fn, [("info.cqn", cqn), ("info.ctx_addr.va", "ctx")],
                        {"cqn": cqn, "context": "cqc_create_body_boundary"},
                        [f"static u8 ctx[56] = {base.c_bytes(cqc)};"],
                        declare="struct xtrdma_cq_context info;"))
    cqn = pv("cqc_query:cqn", 21)
    out.append(case("cqc_query", ops["CQC_QUERY"], "xtrdma_sc_cq_query", [("info.cqn", cqn)],
                    {"cqn": cqn}, declare="struct xtrdma_cqc_query_param info;"))
    for kind, source in (("ceqc", "ceqc_create_body_boundary"), ("aeqc", "aeqc_create_body_boundary")):
        data = context[source][1][16:48]
        eqn = pv(f"{kind}_create:eqn", 12)
        out.append(case(f"{kind}_create", ops[f"{kind.upper()}_CREATE"], "xtrdma_sc_eq_ctx_create",
                        [("info.eqn", eqn)], {"eqn": eqn, "context": source},
                        [f"static const u8 eqc[32] = {base.c_bytes(data)};",
                         "memcpy(info.eqc_data, eqc, 32);"],
                        declare="struct xtrdma_cmq_eq_ctx_info info;"))
        for verb in ("delete", "query"):
            eqn = pv(f"{kind}_{verb}:eqn", 12)
            out.append(case(f"{kind}_{verb}", ops[f"{kind.upper()}_{verb.upper()}"],
                            f"xtrdma_sc_eq_ctx_{verb}", [("info", eqn)], {"eqn": eqn},
                            declare="u32 info;"))
    data = context["srqc_create_body_boundary"][1][16:48]
    srfqn = pv("srfqc_create:srfqn", 16)
    out.append(case("srfqc_create", ops["SRFQC_CREATE"], "xtrdma_sc_srfq_ctx_create",
                    [("info.srfqn", srfqn)], {"srfqn": srfqn, "context": "srqc_create_body_boundary"},
                    [f"static const u8 srq[32] = {base.c_bytes(data)};",
                     "memcpy(info.srfqc_data, srq, 32);"],
                    declare="struct xtrdma_cmq_srfqc_ctx_info info;"))
    for verb in ("delete", "query"):
        srfqn = pv(f"srfqc_{verb}:srfqn", 16)
        out.append(case(f"srfqc_{verb}", ops[f"SRFQC_{verb.upper()}"], f"xtrdma_sc_srfq_ctx_{verb}",
                        [("info", srfqn)], {"srfqn": srfqn}, declare="u32 info;"))
    out.append(case("tq_flush", ops["TQ_FLUSH"], "xtrdma_sc_tq_flush", [], {},
                    call="{fn}(wqe, idx, op, pol);", declare="u32 info = 0;"))
    return out


def build_cases(root: Path, context_path: Path) -> list[dict]:
    ops = base.driver_opcodes(root)
    context = load_context(context_path)
    cases = qp_cases(ops, context) + mrt_cases(ops) + occ_cases(ops) + context_cases(ops, context)
    for number, item in enumerate(cases, 1):
        item["index"], item["polarity"] = number % 32, number & 1
    return cases


def render_harness(root: Path, cases: list[dict]) -> str:
    parts = [base.PRELUDE]
    for header, kind, name in base.EXTRACTS + EXTRACTS:
        parts.append(base.extract_text(root / header, kind, name))
    source = (root / "cmq.c").read_text()
    for function in FUNCTIONS:
        parts.append(base.fields.function_body(source, function))
    body = ["int main(void)", "{", "\t__be64 wqe[8];", "\tu8 *b = (u8 *)wqe;"]
    for item in cases:
        body += ["\t{", f"\t\tu32 idx = {item['index']}; u8 op = 0x{item['opcode']:02x};"
                        f" u8 pol = {item['polarity']};",
                 "\t\tmemset(wqe, 0, sizeof(wqe));", "\t\t" + item["declare"],
                 "\t\tmemset(&info, 0, sizeof(info));"]
        body += ["\t\t" + line for line in item["statics"]]
        for lvalue, value in item["assigns"]:
            rhs = value if isinstance(value, str) else f"0x{value:x}ULL"
            body.append(f"\t\t{lvalue} = {rhs};")
        body += ["\t\t" + item["call"].format(fn=item["function"]),
                 "\t\t(void)idx; (void)op; (void)pol;",
                 f"\t\tprintf(\"{item['name']}\");",
                 "\t\tfor (int i = 0; i < 64; i++) printf(\" %02x\", b[i]);",
                 "\t\tprintf(\"\\n\");", "\t}"]
    body += ["\treturn 0;", "}"]
    parts.append("\n".join(body))
    return "\n\n".join(parts) + "\n"


def run(root: Path, cc: str, context_path: Path) -> str:
    cases = build_cases(root, context_path)
    with tempfile.TemporaryDirectory(prefix="cmq_dedicated_oracle.") as tmp:
        c_path, exe = Path(tmp) / "harness.c", Path(tmp) / "harness"
        c_path.write_text(render_harness(root, cases))
        build = subprocess.run([cc, "-std=gnu11", "-O1", "-w", "-I", str(root), "-o", str(exe),
                                str(c_path)], capture_output=True, text=True)
        if build.returncode != 0:
            raise base.OracleError("harness build failed:\n" + build.stderr[-4000:])
        output = subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout
    images = {line.split()[0]: " ".join(line.split()[1:]) for line in output.splitlines()}
    out = ["# xtr_v1-golden-v1"]
    for item in cases:
        inputs = [f"opcode=0x{item['opcode']:02x}", f"index=0x{item['index']:02x}",
                  f"polarity=0x{item['polarity']:x}"]
        inputs += [f"{k}={v}" if isinstance(v, str) else f"{k}=0x{v:x}"
                   for k, v in item["inputs"].items()]
        out += [f"# case: {item['name']}", "# inputs: " + ",".join(inputs), "# bytes: 64",
                images[item["name"]], ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-root", required=True, type=Path)
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("--golden", type=Path, default=GOLDEN)
    parser.add_argument("--context", type=Path, default=CONTEXT)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        text = run(args.driver_root, args.cc, args.context)
    except (base.OracleError, base.fields.GenError, KeyError) as error:
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
