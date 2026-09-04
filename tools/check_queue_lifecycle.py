#!/usr/bin/env python3
"""Fail-closed static checks for queue lifecycle source boundaries."""
from pathlib import Path
import re
import subprocess
import sys


class ValidationError(Exception):
    pass


def read(repo_root: Path, relative: str) -> str:
    path = repo_root / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"missing/unreadable file: {relative}") from exc


def reject(text: str, pattern: str, message: str) -> None:
    if re.search(pattern, text, re.MULTILINE | re.DOTALL):
        raise ValidationError(message)


IOVA_CONSUMERS = (
    "src/core/rdma_queue_lifecycle_policy.sv",
    "src/core/rdma_queue_lifecycle_executor.sv",
    "src/codec/rdma/rdma_queue_page_codec.sv",
)


def validate_iova_only(repo_root: Path) -> None:
    for relative in IOVA_CONSUMERS:
        reject(read(repo_root, relative), r"\b\.backing_addr\b", f"IOVA-only boundary violated in {relative}")
    policy = read(repo_root, IOVA_CONSUMERS[0])
    policy_code = re.sub(r"//.*?$|/\*.*?\*/", "", policy, flags=re.MULTILINE | re.DOTALL)
    if not re.search(r"\brdma_queue_base_from_iova\s*\(", policy_code, re.MULTILINE):
        raise ValidationError("IOVA-only boundary requires rdma_queue_base_from_iova in policy")


REQUEST_CLASSES = ("rdma_create_cq_req", "rdma_create_srq_req", "rdma_create_ceq_req", "rdma_create_aeq_req")


def validate_public_api_shape(repo_root: Path) -> None:
    text = read(repo_root, "src/model/rdma_semantic_requests.sv")
    for name in REQUEST_CLASSES:
        start = re.search(rf"\bclass\s+{name}\b", text)
        if not start:
            raise ValidationError(f"public API boundary missing class {name}")
        tail = text[start.end():]
        next_class = re.search(r"\bclass\s+\w+\b", tail)
        end = re.search(r"\bendclass\b", tail)
        if end is None or (next_class is not None and next_class.start() < end.start()):
            raise ValidationError(f"public API boundary malformed class {name}")
        match = text[start.start(): start.end() + end.end()]
        reject(match, r"\brdma_(?:iova|backing_addr)_t\b", f"public API boundary violated in {name}")


def validate_core_dependencies(repo_root: Path) -> None:
    required = [
        "src/core/rdma_stag_key_policy.sv", "src/core/rdma_hmc_allocator.sv",
        "src/core/rdma_resource_manager.sv", "src/core/rdma_queue_lifecycle_policy.sv",
        "src/core/rdma_queue_backing_planner.sv", "src/core/rdma_doorbell_scheduler.sv",
        "src/core/rdma_cmq_port.sv", "src/core/rdma_queue_lifecycle_executor.sv",
        "src/core/rdma_control_plane.sv", "src/core/rdma_cmq_engine.sv",
        "src/core/rdma_cmq_engine_port_adapter.sv", "src/core/rdma_cmq_port.sv",
    ]
    paths = [repo_root / p for p in required] + [repo_root / "src/core/rdma_core_pkg.sv"]
    for path in paths:
        if not path.is_file():
            raise ValidationError(f"missing core dependency source: {path.relative_to(repo_root)}")
    # Scan every core source file, including newly added files, in addition to
    # the explicit required set above so an unlisted source cannot bypass checks.
    all_core = sorted(repo_root.joinpath("src/core").glob("*.sv"))
    scan_paths = list(dict.fromkeys(paths + all_core))
    try:
        text = "\n".join(path.read_text(encoding="utf-8") for path in scan_paths)
    except OSError as exc:
        raise ValidationError("missing/unreadable core dependency source") from exc
    for symbol in ("pcie_work", "axis_vip", "net_packet", "host_mem_manager"):
        reject(text, rf"\b{symbol}\b", f"core dependency boundary violated: {symbol}")


def _check_include_order(repo_root: Path, relative: str, expected: tuple[str, ...]) -> None:
    text = read(repo_root, relative)
    includes = re.findall(r'`include\s+"([^"]+)"', text)
    positions = []
    for item in expected:
        try:
            positions.append(includes.index(item))
        except ValueError as exc:
            raise ValidationError(f"package order missing {item} in {relative}") from exc
    if positions != sorted(positions):
        raise ValidationError(f"package order violated in {relative}")


def validate_package_order(repo_root: Path) -> None:
    _check_include_order(repo_root, "src/model/rdma_model_pkg.sv", ("rdma_resource_refs.sv", "rdma_queue_lifecycle_models.sv", "rdma_semantic_requests.sv", "rdma_resources.sv"))
    _check_include_order(repo_root, "src/core/rdma_core_pkg.sv", ("rdma_resource_manager.sv", "rdma_queue_lifecycle_policy.sv", "rdma_queue_backing_planner.sv", "rdma_queue_lifecycle_executor.sv", "rdma_control_plane.sv"))


FROZEN_ABI = (
    "src/codec/rdma/rdma_defs.svh",
    "src/codec/rdma/rdma_image_masks.svh",
    "src/codec/rdma/rdma_context_body_codecs.svh",
    "src/codec/rdma/rdma_cmq_codecs.svh",
)

# The codec implementations are source files now, but their ABI is frozen
# against the historical .svh paths.  Keep the baseline path separate from
# the current path so a pure rename is not reported as an ABI edit.
FROZEN_ABI_CURRENT = (
    "src/codec/rdma/rdma_defs.svh",
    "src/codec/rdma/rdma_image_masks.svh",
    "src/codec/rdma/rdma_context_body_codecs.sv",
    "src/codec/rdma/rdma_cmq_codecs.sv",
)


def validate_frozen_queue_abi(repo_root: Path) -> None:
    try:
        result = subprocess.run(
            ["git", "diff", "--name-status", "-M", "a0abd95", "--",
             *FROZEN_ABI, *FROZEN_ABI_CURRENT],
            cwd=repo_root, check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValidationError("frozen ABI differs from baseline or git unavailable") from exc
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        status = fields[0] if fields else ""
        # A pure R100 rename preserves the frozen bytes.  Any modification,
        # lower-similarity rename, addition, or deletion is an ABI violation.
        if status == "R100" and len(fields) == 3:
            old_path, new_path = fields[1], fields[2]
            if (old_path, new_path) in zip(FROZEN_ABI, FROZEN_ABI_CURRENT):
                continue
        raise ValidationError("frozen ABI differs from baseline or git unavailable")


def main() -> int:
    try:
        for validator in (validate_iova_only, validate_public_api_shape, validate_core_dependencies, validate_package_order, validate_frozen_queue_abi):
            validator(Path.cwd())
    except ValidationError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
