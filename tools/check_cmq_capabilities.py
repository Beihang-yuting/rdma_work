#!/usr/bin/env python3
"""
目录：tools；职责：由锁定驱动源码与驱动 golden 重建 CMQ 能力表 hw/rdma/cmq_capabilities.tsv 并比对。
依赖：Python 标准库、tools/cmq_request_oracle.py（opcode 枚举与函数抽取）、
hw/rdma/cmq_request_fields.tsv（表驱动 opcode）、三份驱动 golden（请求/专用请求/响应）。
设计说明：一个方向闭环 = 驱动在该方向分派此 opcode，且仓库内有该 opcode 的驱动 golden 用例；
驱动不分派的方向标记 DRIVER_NOT_DISPATCHED。golden 本身由各 oracle 的 --check 对锁定归档复核。
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmq_request_oracle as base  # noqa: E402

COLUMNS = ("driver_symbol", "opcode", "opcode_value", "direction", "registered",
           "request_encodable", "response_decodable", "oracle_case_id", "owning_codec", "blocker")
REQUEST_GOLDENS = ("cmq_requests.hex", "cmq_requests_dedicated.hex")
RESPONSE_GOLDEN = "cmq_responses.hex"
DOORBELL_CASE = "cmq_sq_doorbell"


class CapabilityError(Exception):
    """能力表与驱动/golden 不一致。"""


def enum_symbols(root: Path) -> list[tuple[str, str, int]]:
    """cmq.h 中 opcode 枚举：(驱动符号, 短名, 值)，不含 MAX。"""
    text = (root / "cmq.h").read_text()
    out = []
    for match in re.finditer(r"\b((X?TRDMA)_OP_(\w+))\s*=\s*(0x[0-9a-fA-F]+|\d+)", text):
        if match.group(3) != "MAX":
            out.append((match.group(1), match.group(3), int(match.group(4), 0)))
    return out


def switch_labels(source: str, function: str) -> set[str]:
    body = base.fields.function_body(source, function)
    body = body[body.index("switch"):]
    return set(re.findall(r"case\s+X?TRDMA_OP_(\w+)\s*:", body))


def golden_cases(path: Path) -> dict[int, str]:
    """golden 文件中每个 opcode 的首个用例名。"""
    first: dict[int, str] = {}
    lines = path.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("# case: "):
            match = re.search(r"\bopcode=0x([0-9a-f]+)", lines[i + 1])
            if match:
                first.setdefault(int(match.group(1), 16), line[len("# case: "):])
    return first


def field_table_opcodes(path: Path) -> set[str]:
    names = set()
    for line in path.read_text().splitlines()[2:]:
        names.update(line.split("\t")[0].split(","))
    return names


def expected_rows(root: Path, repo: Path) -> list[dict[str, str]]:
    source = (root / "cmq.c").read_text()
    submitted = switch_labels(source, "xtrdma_exec_cmq_cmd")
    completed = switch_labels(source, "xtrdma_exec_cmq_cq_cmd")
    goldens = repo / "hw/rdma/golden_vectors"
    requests: dict[int, str] = {}
    for name in REQUEST_GOLDENS:
        for opcode, case in golden_cases(goldens / name).items():
            requests.setdefault(opcode, case)
    responses = golden_cases(goldens / RESPONSE_GOLDEN)
    table_driven = field_table_opcodes(repo / "hw/rdma/cmq_request_fields.tsv")
    rows = []
    for symbol, name, value in enum_symbols(root):
        for direction in ("REQUEST", "RESPONSE"):
            dispatched = name in (submitted if direction == "REQUEST" else completed)
            evidence = (requests if direction == "REQUEST" else responses).get(value)
            if dispatched and evidence is None:
                raise CapabilityError(f"{name} {direction} is dispatched but has no driver golden")
            if direction == "REQUEST":
                codec = ("rdma_hw_cmq_field_codec" if name in table_driven
                         else "rdma_hw_cmq_request_composer")
            else:
                codec = "rdma_hw_cmq_completion_codec"
            rows.append(dict(
                driver_symbol=symbol, opcode=name, opcode_value=f"0x{value:02x}",
                direction=direction, registered="1",
                request_encodable="1" if dispatched and direction == "REQUEST" else "0",
                response_decodable="1" if dispatched and direction == "RESPONSE" else "0",
                oracle_case_id=evidence if dispatched else "-", owning_codec=codec,
                blocker="-" if dispatched else "DRIVER_NOT_DISPATCHED"))
    doorbell = repo / "hw/rdma/c_oracle/cases" / f"{DOORBELL_CASE}.bytes.hex"
    rows.append(dict(driver_symbol="-", opcode="CMQ_SQ_DOORBELL", opcode_value="-",
                     direction="REQUEST", registered="1",
                     request_encodable="1" if doorbell.exists() else "0", response_decodable="0",
                     oracle_case_id=DOORBELL_CASE, owning_codec="rdma_hw_cmq_hw_profile",
                     blocker="-" if doorbell.exists() else "MISSING_CLOSED_EVIDENCE"))
    return rows


def render(rows: list[dict[str, str]]) -> str:
    return "\n".join(["\t".join(COLUMNS)] + ["\t".join(r[c] for c in COLUMNS) for r in rows]) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver-root", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path("."))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    target = args.repo / "hw/rdma/cmq_capabilities.tsv"
    try:
        text = render(expected_rows(args.driver_root, args.repo))
    except (CapabilityError, base.OracleError, base.fields.GenError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.check:
        if not target.exists() or target.read_text() != text:
            print(f"capability table differs from driver evidence: {target}", file=sys.stderr)
            return 1
        return 0
    target.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
