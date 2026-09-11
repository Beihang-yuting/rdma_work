#!/usr/bin/env python3
"""
目录：tools；职责：验证可重建 CMQ C oracle 与不可变 canonical artifacts。
依赖：Task 1 archive lock、Task 2 source manifest、gcc 和 oracle C 源码；本模块只写
私有临时目录。
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

try:
    from .rdma_driver_contract import ContractError, load_archive_lock, load_source_manifest
except ImportError:  # pragma: no cover
    from rdma_driver_contract import ContractError, load_archive_lock, load_source_manifest

FLAGS = (
    "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
    "-fno-common", "-fno-strict-aliasing",
)
EXPECTED_COMPILER_PATH = "/usr/bin/x86_64-linux-gnu-gcc-9"
EXPECTED_COMPILER_SHA256 = "6cb2d84ccd9fd3485d4e47ba032e626be65692601c38fad46866a6b565f3100f"
EXPECTED_COMPILER_VERSION = "gcc (Ubuntu 9.4.0-1ubuntu1~20.04.2) 9.4.0"
EXPECTED_COMPILER_TARGET = "x86_64-linux-gnu"
EXPECTED_TARGET_ENDIAN = "little"
EXPECTED_TARGET_BITS = "64"
CASE_HEADER = (
    "case_id\tentry\topcode\tdirection\tsource_path\tsource_function\t"
    "total_bytes\tc_type_alignment\timage_required_alignment\tendian\tembed_base"
)
ANCHOR_HEADER = (
    "case_id\trole\tsource_path\tsource_function\tanchor_token\t"
    "token_occurrence\tbuffer_expression\toperation\ttarget_flow"
)
METADATA_KEYS = {
    "RDMA_ARCHIVE_SHA256", "RDMA_SOURCE_CLOSURE_SHA256", "RDMA_ARCHIVE_PREFIX",
    "RDMA_PRIMARY_SOURCE_ANCHOR", "RDMA_SOURCE_ANCHORS_SHA256", "RDMA_PROBE_SOURCE_SHA256",
    "RDMA_COMPILER_PATH", "RDMA_COMPILER_SHA256", "RDMA_COMPILER_VERSION",
    "RDMA_COMPILER_TARGET", "RDMA_TARGET_ENDIAN", "RDMA_TARGET_BITS", "RDMA_COMPILER_FLAGS",
    "RDMA_INPUT_SHA256", "RDMA_BYTES_SHA256", "RDMA_FIELDS_SHA256",
}
ROLE_ORDER = {
    "cmq_sqe_qpc_create_request": ["PREPARE", "BUILD", "STORE", "CHECKSUM"],
    "cmq_sqe_cqc_create_request": ["PREPARE", "BUILD", "STORE"],
    "cmq_cqe_qpc_create_response": [
        "READY", "LOOKUP", "PARSE", "LOAD", "VALIDATE_WRAP",
        "VALIDATE_OPCODE", "VALIDATE_ECODE",
    ],
    "cmq_sq_doorbell": ["POST", "WRITE"],
}
EXPECTED_CASE_ROWS = {
    "cmq_sqe_qpc_create_request": (
        "cmq_sqe_qpc_create_request",
        "CMQ_SQE",
        "QPC_CREATE",
        "REQUEST",
        "cmq.c",
        "xtrdma_sc_qp_create",
        "64",
        "8",
        "64",
        "big",
        "0",
    ),
    "cmq_sqe_cqc_create_request": (
        "cmq_sqe_cqc_create_request",
        "CMQ_SQE",
        "CQC_CREATE",
        "REQUEST",
        "cmq.c",
        "xtrdma_sc_cq_create",
        "64",
        "8",
        "64",
        "big",
        "8",
    ),
    "cmq_cqe_qpc_create_response": (
        "cmq_cqe_qpc_create_response",
        "CMQ_CQE",
        "QPC_CREATE",
        "RESPONSE",
        "cmq.c",
        "xtrdma_get_cqe_common_info",
        "64",
        "8",
        "64",
        "big",
        "0",
    ),
    "cmq_sq_doorbell": (
        "cmq_sq_doorbell",
        "CMQ_SQ_DOORBELL",
        "CMQ_SQ",
        "REQUEST",
        "cmq.c",
        "xtrdma_sc_cmq_post_sq",
        "8",
        "8",
        "8",
        "big",
        "0",
    ),
}
EXPECTED_ANCHOR_ROWS = {
    "cmq_sqe_qpc_create_request": [
        (
            "cmq_sqe_qpc_create_request",
            "PREPARE",
            "qp.c",
            "xtrdma_hw_create_qp",
            "create_qp_info.qpc_buffer_addr_pa = xtqp->cmdq_qpc_buf.iova >> "
            "XTRDMA_ADDR_512_BYTE_SHIFT;",
            "1",
            "create_qp_info.qpc_buffer_addr_pa",
            "ASSIGN_SHIFT_RIGHT",
            "xtqp->cmdq_qpc_buf.iova -> create_qp_info.qpc_buffer_addr_pa -> "
            "cmq_request->req_param",
        ),
        (
            "cmq_sqe_qpc_create_request",
            "BUILD",
            "cmq.c",
            "xtrdma_sc_qp_create",
            "set_64bit_val(wqe, 24, FIELD_PREP(XTRDMA_CMQSQ_WQE_QPC_BUFFER_ADDR, "
            "info->qpc_buffer_addr_pa));",
            "1",
            "wqe",
            "SET_64BIT_FIELD_PREP",
            "info->qpn/sq_cqn/rq_cqn/qpc_buffer_addr_{pa,va} -> "
            "hdr/sign_data/signature -> wqe[0,8,24]",
        ),
        (
            "cmq_sqe_qpc_create_request",
            "STORE",
            "defs.h",
            "set_64bit_val",
            "wqe_words[byte_index >> 3] = cpu_to_be64(val);",
            "1",
            "wqe_words",
            "CPU_TO_BE64_STORE",
            "val -> cpu_to_be64 -> wqe_words[byte_index >> 3]",
        ),
        (
            "cmq_sqe_qpc_create_request",
            "CHECKSUM",
            "defs.h",
            "xtrdma_bytes_xor",
            "acc ^= get_unaligned((u64 *)ptr);",
            "1",
            "ptr",
            "XOR_U64_REMAINDER_FOLD",
            "hdr/wqe/qpc bytes -> acc -> folded u8 -> complemented signature",
        ),
    ],
    "cmq_sqe_cqc_create_request": [
        (
            "cmq_sqe_cqc_create_request",
            "PREPARE",
            "cq.c",
            "xtrdma_hw_create_cq",
            "cmq_request->req_param = (void *)&xt_cq->cq_ctx;",
            "1",
            "cmq_request->req_param",
            "ASSIGN_ADDRESS",
            "xt_cq->cq_ctx -> cmq_request->req_param -> cq_ctx->ctx_addr.va",
        ),
        (
            "cmq_sqe_cqc_create_request",
            "BUILD",
            "cmq.c",
            "xtrdma_sc_cq_create",
            "memcpy(wqe + 1, cq_ctx->ctx_addr.va, 56);",
            "1",
            "wqe + 1",
            "MEMCPY",
            "cq_ctx->ctx_addr.va[0:56] -> wqe[8:64]",
        ),
        (
            "cmq_sqe_cqc_create_request",
            "STORE",
            "defs.h",
            "set_64bit_val",
            "wqe_words[byte_index >> 3] = cpu_to_be64(val);",
            "1",
            "wqe_words",
            "CPU_TO_BE64_STORE",
            "hdr -> cpu_to_be64 -> wqe[0]",
        ),
    ],
    "cmq_cqe_qpc_create_response": [
        (
            "cmq_cqe_qpc_create_response",
            "READY",
            "cmq.c",
            "xtrdma_sc_cmq_next_cqe_valid",
            "get_64bit_val(cqe, 0, &temp1);",
            "1",
            "cqe",
            "GET_64BIT_FIELD_GET",
            "cq_base[CI].elem -> temp1 -> polarity -> cq_polarity -> ready/not-ready",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "LOOKUP",
            "cmq.c",
            "xtrdma_sc_cmq_next_cqe_valid",
            "*cmq_request = (struct xtrdma_cmq_request *)sc_cmq->request_array[wqe_idx];",
            "1",
            "sc_cmq->request_array",
            "INDEX_LOOKUP",
            "cqe.index -> request_array[wqe_idx] -> cmq_request",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "PARSE",
            "cmq.c",
            "xtrdma_get_cqe_common_info",
            "get_64bit_val(*cqe, 0, &temp);",
            "1",
            "*cqe",
            "GET_64BIT",
            "(sc_cmq->cq_base[CI].elem -> *cqe -> temp) -> FIELD_GET(opcode,ecode,wrap,index)",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "LOAD",
            "rdma_type.h",
            "get_64bit_val",
            "*val = be64_to_cpu(wqe_words[byte_index >> 3]);",
            "1",
            "wqe_words",
            "BE64_TO_CPU_LOAD",
            "wqe_words[byte_index >> 3] -> be64_to_cpu -> val",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "VALIDATE_WRAP",
            "cmq.c",
            "xtrdma_get_cqe_common_info",
            "cq_wqe_wrap != sq_wqe_wrap",
            "1",
            "status",
            "COMPARE_WRAP",
            "cqe.wrap/sqe.wrap -> status/request_error",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "VALIDATE_OPCODE",
            "cmq.c",
            "xtrdma_get_cqe_common_info",
            "opcode != cmq_request->cmq_cmd",
            "1",
            "status",
            "COMPARE_OPCODE",
            "cqe.opcode/request.opcode -> status/request_error",
        ),
        (
            "cmq_cqe_qpc_create_response",
            "VALIDATE_ECODE",
            "cmq.c",
            "xtrdma_get_cqe_common_info",
            "ecode != 0",
            "1",
            "status",
            "COMPARE_ECODE",
            "cqe.ecode -> status/request_error",
        ),
    ],
    "cmq_sq_doorbell": [
        (
            "cmq_sq_doorbell",
            "POST",
            "cmq.c",
            "xtrdma_sc_cmq_post_sq",
            "cmq_db = FIELD_PREP(XTRDMA_CMQSQ_DB_PI, XTRDMA_RING_CURRENT_PI(sc_cmq->sq_ring)) |",
            "1",
            "cmq_db",
            "FIELD_PREP_OR",
            "sc_cmq->sq_ring/sq_polarity -> cmq_db -> xtrdma_iowrite64be",
        ),
        (
            "cmq_sq_doorbell",
            "WRITE",
            "rdma_main.h",
            "xtrdma_iowrite64be",
            "iowrite64be(val, db_addr);",
            "1",
            "db_addr",
            "IOWRITE64BE",
            "cmq_db -> iowrite64be -> CMQ doorbell MMIO bytes",
        ),
    ],
}


def _sha256(path: Path) -> str:
    """功能：计算文件 SHA-256 摘要。
    输入输出及副作用：读取 path 返回小写摘要。
    失败边界：路径不可读时传播 OSError。"""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_table(path: Path, header: str, width: int) -> list[list[str]]:
    """功能：读取固定列 TSV 表。
    输入输出及副作用：返回数据行列值。
    失败边界：缺失/重复表头、错误列数或空表抛 ContractError。"""
    lines = path.read_text(encoding="utf-8").splitlines()
    rows = [line.split("\t") for line in lines if line.strip() and not line.startswith("#")]
    if not rows or rows[0] != header.split("\t"):
        raise ContractError(f"{path}: unexpected TSV header")
    data = rows[1:]
    if not data or any(len(row) != width for row in data):
        raise ContractError(f"{path}: malformed TSV row")
    return data


def load_cases(path: Path) -> dict[str, list[str]]:
    """功能：加载四种 oracle case 定义并检查唯一 case_id。
    输入输出及副作用：返回 case_id 到行字段映射。
    失败边界：数量不是四、重复 ID 或列值非法时拒绝。"""
    rows = _parse_table(path, CASE_HEADER, 11)
    result: dict[str, list[str]] = {}
    for row in rows:
        if row[0] in result or row[0] not in ROLE_ORDER:
            raise ContractError(f"{path}: unsupported or duplicate case {row[0]}")
        if tuple(row) != EXPECTED_CASE_ROWS[row[0]]:
            raise ContractError(f"{path}: case contract drift for {row[0]}")
        result[row[0]] = row
    if set(result) != set(ROLE_ORDER):
        raise ContractError(f"{path}: case set mismatch")
    return result


def load_anchors(path: Path) -> dict[str, list[list[str]]]:
    """功能：加载并按 case 分组 source-anchor hops。
    输入输出及副作用：返回有序行组。
    失败边界：角色缺失、重复、额外或 occurrence 非 1 均拒绝。"""
    rows = _parse_table(path, ANCHOR_HEADER, 9)
    result: dict[str, list[list[str]]] = {case: [] for case in ROLE_ORDER}
    for row in rows:
        case, role = row[0], row[1]
        if case not in result or role not in ROLE_ORDER[case]:
            raise ContractError(f"{path}: unexpected anchor {case}/{role}")
        if row[5] != "1" or any(existing[1] == role for existing in result[case]):
            raise ContractError(f"{path}: duplicate/invalid anchor {case}/{role}")
        result[case].append(row)
    for case, expected in ROLE_ORDER.items():
        if [row[1] for row in result[case]] != expected:
            raise ContractError(f"{path}: anchor order mismatch for {case}")
        if [tuple(row) for row in result[case]] != EXPECTED_ANCHOR_ROWS[case]:
            raise ContractError(f"{path}: anchor contract drift for {case}")
    return result


def _strip_comments(text: str) -> str:
    """功能：移除 C/C++ 注释以便进行唯一 source-anchor 计数。
    输入输出及副作用：返回去注释文本。
    失败边界：未闭合注释按注释尾处理。"""
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def _manifest_sources(kernel_root: Path, manifest_path: Path, lock_id: str):
    """功能：解析 manifest 并验证每个来源文件 hash 与 archive 身份。
    输入输出及副作用：返回路径到 record 列表。
    失败边界：缺文件、摘要漂移或 archive ID 不匹配均拒绝。"""
    records = load_source_manifest(manifest_path)
    by_path = {}
    for record in records:
        if record.archive_id != lock_id:
            raise ContractError("source manifest archive ID does not match lock")
        source = kernel_root / record.path
        if not source.is_file() or _sha256(source) != record.sha256:
            raise ContractError(f"source manifest hash mismatch: {record.path}")
        by_path.setdefault(record.path, []).append(record)
    return by_path


def source_digests(
    kernel_root: Path,
    manifest_path: Path,
    anchors: dict[str, list[list[str]]],
    lock_id: str,
):
    """功能：校验 anchors 所有 hop 可由 manifest 闭合，并计算 anchor/closure
    摘要。
    输入输出及副作用：返回每 case 的 (anchor_sha, closure_sha, source rows)。
    失败边界：路径、函数、token 不能唯一解析。"""
    by_path = _manifest_sources(kernel_root, manifest_path, lock_id)
    result = {}
    for case, rows in anchors.items():
        selected = []
        paths = set()
        for row in rows:
            _, _, path, function, token, occurrence, *_ = row
            if path not in by_path:
                raise ContractError(f"anchor path absent from source manifest: {path}")
            # Selector rows may be wildcard expressions; check each alternative literally/glob-like.
            selectors = [part for record in by_path[path] for part in record.selector.split("|")]
            if not any(
                part == function or fnmatch_selector(part, function)
                for part in selectors
            ):
                raise ContractError(
                    f"anchor function absent from source manifest: {path}:{function}"
                )
            text = _strip_comments((kernel_root / path).read_text(encoding="utf-8"))
            function_match = re.search(
                r"(?:static\s+)?(?:inline\s+)?[^{;]+\b"
                + re.escape(function)
                + r"\s*\([^;{]*\)\s*\{",
                text,
            )
            if not function_match:
                raise ContractError(f"source function missing: {path}:{function}")
            start = function_match.end()
            depth = 1
            pos = start
            while depth and pos < len(text):
                if text[pos] == "{": depth += 1
                elif text[pos] == "}": depth -= 1
                pos += 1
            body = text[start:pos]
            normalized = " ".join(token.split())
            compact_body = " ".join(body.split())
            occurrences = [
                match.start() for match in re.finditer(re.escape(normalized), compact_body)
            ]
            if len(occurrences) != int(occurrence):
                raise ContractError(f"anchor occurrence mismatch: {path}:{function}")
            selected.append("\t".join(row) + "\n")
            paths.add(path)
        anchor_payload = "".join(selected).encode("utf-8")
        anchor_sha = hashlib.sha256(anchor_payload).hexdigest()
        source_payload = b"".join(
            f"{path}\0{_sha256(kernel_root / path)}\n".encode("utf-8")
            for path in sorted(paths, key=lambda item: item.encode("utf-8"))
        )
        closure_sha = hashlib.sha256(
            f"anchors={anchor_sha}\n".encode() + source_payload
        ).hexdigest()
        result[case] = (anchor_sha, closure_sha, selected)
    return result


def fnmatch_selector(selector: str, value: str) -> bool:
    """功能：匹配 manifest 的星号 selector。
    输入输出及副作用：返回 selector 是否覆盖 value。
    失败边界：空 selector 不匹配。"""
    import fnmatch
    return bool(selector) and fnmatch.fnmatchcase(value, selector)


def _compiler_facts(cc: Path):
    """功能：读取固定编译器 realpath、摘要、版本、目标与 ABI。
    输入输出及副作用：返回 facts 字典。
    失败边界：命令失败或身份不是锁定 GCC 时抛 ContractError。"""
    try:
        real = Path(os.path.realpath(cc))
        digest = _sha256(real)
        version = subprocess.run(
            [str(cc), "--version"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.splitlines()[0]
        target = subprocess.run(
            [str(cc), "-dumpmachine"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
        bits = subprocess.run(
            ["getconf", "LONG_BIT"],
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError, IndexError) as exc:
        raise ContractError(f"compiler probe failed: {exc}") from exc
    facts = {
        "path": str(real),
        "sha": digest,
        "version": version,
        "target": target,
        "bits": bits,
        "endian": EXPECTED_TARGET_ENDIAN,
    }
    expected = (
        EXPECTED_COMPILER_PATH,
        EXPECTED_COMPILER_SHA256,
        EXPECTED_COMPILER_VERSION,
        EXPECTED_COMPILER_TARGET,
        EXPECTED_TARGET_BITS,
    )
    actual = (
        facts["path"],
        facts["sha"],
        facts["version"],
        facts["target"],
        facts["bits"],
    )
    if actual != expected:
        raise ContractError("compiler identity does not match locked GCC")
    return facts


def _build_and_run(
    cc: Path,
    kernel_root: Path,
    source: Path,
    case: str,
    input_path: Path,
    work: Path,
) -> tuple[str, str]:
    """功能：在私有目录编译并运行 oracle case。
    输入输出及副作用：返回 stdout/stderr。
    失败边界：编译器返回非零或任一 stderr 字节均拒绝。"""
    binary = work / "rdma_cmq_oracle"
    command = [
        str(cc),
        *FLAGS,
        "-I",
        str(kernel_root),
        str(source),
        "-o",
        str(binary),
    ]
    compiled = subprocess.run(command, text=True, capture_output=True)
    if compiled.returncode != 0 or compiled.stderr:
        raise ContractError(
            f"oracle compiler rejected: {compiled.stderr.strip() or compiled.returncode}"
        )
    run = subprocess.run(
        [str(binary), "--case", case, "--input", str(input_path)],
        text=True,
        capture_output=True,
    )
    if run.returncode != 0 or run.stderr:
        raise ContractError(f"oracle execution rejected: {run.stderr.strip() or run.returncode}")
    return run.stdout, run.stderr


def canonical_reports(stdout: str) -> tuple[str, str]:
    """功能：规范化 oracle stdout 的 BYTES/FIELD 记录。
    输入输出及副作用：返回 bytes.hex 与排序 fields.tsv 文本。
    失败边界：重复/缺失 bytes 或 malformed field 行拒绝。"""
    bytes_rows = []
    fields = []
    for raw in stdout.splitlines():
        cols = raw.split("\t")
        if not cols:
            continue
        if cols[0] == "BYTES":
            if bytes_rows:
                raise ContractError("oracle emitted duplicate BYTES")
            if any(
                not re.fullmatch(r"[0-9a-fA-F]{2}", value)
                for value in cols[1:]
            ):
                raise ContractError("malformed bytes")
            bytes_rows = [value.lower() for value in cols[1:]]
        elif cols[0] == "FIELD" and len(cols) == 6:
            try:
                offset, lsb, width = (
                    int(cols[2]),
                    int(cols[3]),
                    int(cols[4]),
                )
            except ValueError as exc:
                raise ContractError("malformed field position") from exc
            if not cols[1] or not re.fullmatch(r"[0-9a-fA-F]+", cols[5]):
                raise ContractError("malformed field")
            fields.append((offset, lsb, cols[1], width, cols[5].lower()))
        else:
            raise ContractError("unexpected oracle output row")
    if not bytes_rows:
        raise ContractError("oracle omitted BYTES")
    fields.sort(key=lambda row: (row[0], row[1], row[2]))
    field_text = "".join(
        "\t".join((name, str(offset), str(lsb), str(width), value)) + "\n"
        for offset, lsb, name, width, value in fields
    )
    return " ".join(bytes_rows) + "\n", field_text


def _metadata(path: Path) -> dict[str, str]:
    """功能：读取 canonical metadata 精确键集合。
    输入输出及副作用：返回字符串映射。
    失败边界：未知、重复、缺失键拒绝。"""
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line:
            continue
        if "=" not in line:
            raise ContractError(f"{path}: malformed metadata")
        key, value = line.split("=", 1)
        if key not in METADATA_KEYS or key in values:
            raise ContractError(f"{path}: invalid metadata key")
        values[key] = value
    if set(values) != METADATA_KEYS:
        raise ContractError(f"{path}: metadata key set mismatch")
    return values


def _artifact_paths(root: Path, case: str) -> tuple[Path, Path, Path, Path]:
    """功能：解析 canonical artifact 的扁平目录或 capture 候选子目录布局。
    输入输出及副作用：返回 input/bytes/fields/metadata 路径，不创建文件。
    失败边界：两种布局均缺失时返回扁平路径，供调用者给出 artifact missing
    诊断。
    """
    flat = root
    nested = root / case
    base = nested if nested.is_dir() else flat
    suffixes = ("input.tsv", "bytes.hex", "fields.tsv", "metadata.env")
    return tuple(base / f"{case}.{suffix}" for suffix in suffixes)


def capture_candidate(args) -> Path:
    """功能：维护者专用地在指定目录生成四 case 候选 artifacts 与 metadata。
    输入输出及副作用：仅写 output_dir（必须位于 worktree 外），返回候选
    目录。
    失败边界：输入契约、编译、运行或路径安全失败均拒绝。"""
    lock = load_archive_lock(args.archive_lock)
    cases = load_cases(args.cases)
    anchors = load_anchors(args.source_anchors)
    closure = source_digests(
        Path(args.kernel_root),
        args.source_manifest,
        anchors,
        lock.archive_id,
    )
    facts = _compiler_facts(Path(args.cc))
    output = Path(args.output_dir).resolve()
    repo = Path(__file__).resolve().parents[1]
    if repo == output or repo in output.parents:
        raise ContractError("candidate output must be outside git worktree")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ContractError("candidate output directory must be empty")
    try:
        for case, row in cases.items():
            case_dir = output / case
            case_dir.mkdir()
            input_path = (
                Path(args.input_root) / f"{case}.input.tsv"
                if getattr(args, "input_root", None)
                else repo / "hw/rdma/c_oracle/cases" / f"{case}.input.tsv"
            )
            source = Path(args.oracle_source)
            with tempfile.TemporaryDirectory(prefix="rdma-oracle-build-") as work_name:
                stdout, _ = _build_and_run(
                    Path(args.cc),
                    Path(args.kernel_root),
                    source,
                    case,
                    input_path,
                    Path(work_name),
                )
            bytes_text, fields_text = canonical_reports(stdout)
            (case_dir / f"{case}.bytes.hex").write_text(bytes_text, encoding="utf-8")
            (case_dir / f"{case}.fields.tsv").write_text(fields_text, encoding="utf-8")
            metadata_lines = [
                f"RDMA_ARCHIVE_SHA256={lock.sha256}",
                f"RDMA_SOURCE_CLOSURE_SHA256={closure[case][1]}",
                f"RDMA_ARCHIVE_PREFIX={lock.prefix}",
                f"RDMA_PRIMARY_SOURCE_ANCHOR={row[4]}:{row[5]}",
                f"RDMA_SOURCE_ANCHORS_SHA256={closure[case][0]}",
                f"RDMA_PROBE_SOURCE_SHA256={_sha256(source)}",
                f"RDMA_COMPILER_PATH={facts['path']}",
                f"RDMA_COMPILER_SHA256={facts['sha']}",
                f"RDMA_COMPILER_VERSION={facts['version']}",
                f"RDMA_COMPILER_TARGET={facts['target']}",
                f"RDMA_TARGET_ENDIAN={facts['endian']}",
                f"RDMA_TARGET_BITS={facts['bits']}",
                f"RDMA_COMPILER_FLAGS={' '.join(FLAGS)}",
                f"RDMA_INPUT_SHA256={_sha256(input_path)}",
                f"RDMA_BYTES_SHA256={hashlib.sha256(bytes_text.encode()).hexdigest()}",
                f"RDMA_FIELDS_SHA256={hashlib.sha256(fields_text.encode()).hexdigest()}",
                "",
            ]
            (case_dir / f"{case}.metadata.env").write_text(
                "\n".join(metadata_lines),
                encoding="utf-8",
            )
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise
    print(f"candidate={output}")
    for path in sorted(output.rglob("*")):
        if path.is_file():
            print(f"{path.relative_to(output)} sha256={_sha256(path)}")
    return output


def verify(args) -> None:
    """功能：重编译四 case 并逐字节比较提交 artifacts 与 source closure/
    编译器元数据。
    输入输出及副作用：只创建并清理私有临时目录；成功无返回值。
    失败边界：任何来源、编译诊断、ABI、输入/bytes/fields/metadata 漂移均抛
    ContractError。"""
    lock = load_archive_lock(args.archive_lock)
    cases = load_cases(args.cases)
    anchors = load_anchors(args.source_anchors)
    closure = source_digests(
        Path(args.kernel_root),
        args.source_manifest,
        anchors,
        lock.archive_id,
    )
    facts = _compiler_facts(Path(args.cc))
    source = Path(args.oracle_source)
    if not source.is_file():
        raise ContractError("oracle source missing")
    with tempfile.TemporaryDirectory(prefix="rdma-cmq-oracle-") as work_name:
        for case, row in cases.items():
            paths = _artifact_paths(Path(args.artifact_root), case)
            input_path, bytes_path, fields_path, metadata_path = paths
            for required in (input_path, bytes_path, fields_path, metadata_path):
                if not required.is_file():
                    raise ContractError(f"artifact missing: {required}")
            metadata = _metadata(metadata_path)
            if (
                metadata["RDMA_ARCHIVE_SHA256"] != lock.sha256
                or metadata["RDMA_ARCHIVE_PREFIX"] != lock.prefix
            ):
                raise ContractError("archive metadata drift")
            if (
                metadata["RDMA_SOURCE_CLOSURE_SHA256"] != closure[case][1]
                or metadata["RDMA_SOURCE_ANCHORS_SHA256"] != closure[case][0]
            ):
                raise ContractError("source closure drift")
            if metadata["RDMA_PROBE_SOURCE_SHA256"] != _sha256(source):
                raise ContractError("probe source drift")
            expected_compiler = (
                facts["path"],
                facts["sha"],
                facts["version"],
                facts["target"],
                facts["bits"],
                " ".join(FLAGS),
            )
            compiler_keys = (
                "RDMA_COMPILER_PATH",
                "RDMA_COMPILER_SHA256",
                "RDMA_COMPILER_VERSION",
                "RDMA_COMPILER_TARGET",
                "RDMA_TARGET_BITS",
                "RDMA_COMPILER_FLAGS",
            )
            actual_compiler = tuple(metadata[key] for key in compiler_keys)
            if (
                actual_compiler != expected_compiler
                or metadata["RDMA_TARGET_ENDIAN"] != EXPECTED_TARGET_ENDIAN
            ):
                raise ContractError("compiler metadata drift")
            if metadata["RDMA_PRIMARY_SOURCE_ANCHOR"] != f"{row[4]}:{row[5]}":
                raise ContractError("primary anchor drift")
            if metadata["RDMA_INPUT_SHA256"] != _sha256(input_path):
                raise ContractError("input digest drift")
            with tempfile.TemporaryDirectory(prefix="rdma-case-") as case_work:
                stdout, _ = _build_and_run(
                    Path(args.cc),
                    Path(args.kernel_root),
                    source,
                    case,
                    input_path,
                    Path(case_work),
                )
            bytes_text, fields_text = canonical_reports(stdout)
            if (
                bytes_text != bytes_path.read_text(encoding="utf-8")
                or fields_text != fields_path.read_text(encoding="utf-8")
            ):
                raise ContractError(f"artifact report drift: {case}")
            if (
                metadata["RDMA_BYTES_SHA256"]
                != hashlib.sha256(bytes_text.encode()).hexdigest()
                or metadata["RDMA_FIELDS_SHA256"]
                != hashlib.sha256(fields_text.encode()).hexdigest()
            ):
                raise ContractError(f"artifact digest drift: {case}")


def main(argv: list[str] | None = None) -> int:
    """功能：解析只读 oracle verifier 命令行并返回状态码。
    输入输出及副作用：成功打印 PASS；不提供 update/record 选项。
    失败边界：argparse、契约、编译或比较失败打印 stderr 并返回 1。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--kernel-root", required=True, type=Path)
    parser.add_argument("--archive-lock", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--source-anchors", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--oracle-source", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument("--cc", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        verify(args)
    except (ContractError, OSError, UnicodeError, subprocess.SubprocessError) as exc:
        print(f"RDMA CMQ oracle verification failed: {exc}", file=sys.stderr)
        return 1
    print("RDMA CMQ oracle verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
