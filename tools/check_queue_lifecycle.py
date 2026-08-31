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
    "src/core/rdma_queue_lifecycle_policy.svh",
    "src/core/rdma_queue_lifecycle_executor.svh",
    "src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh",
)


def validate_iova_only(repo_root: Path) -> None:
    for relative in IOVA_CONSUMERS:
        reject(read(repo_root, relative), r"\b\.backing_addr\b", f"IOVA-only boundary violated in {relative}")
    policy = read(repo_root, IOVA_CONSUMERS[0])
    if "rdma_queue_base_from_iova" not in policy:
        raise ValidationError("IOVA-only boundary requires rdma_queue_base_from_iova in policy")


REQUEST_CLASSES = ("rdma_create_cq_req", "rdma_create_srq_req", "rdma_create_ceq_req", "rdma_create_aeq_req")


def validate_public_api_shape(repo_root: Path) -> None:
    text = read(repo_root, "src/model/rdma_semantic_requests.svh")
    for name in REQUEST_CLASSES:
        match = re.search(rf"\bclass\s+{name}\b.*?\bendclass\b", text, re.MULTILINE | re.DOTALL)
        if not match:
            raise ValidationError(f"public API boundary missing class {name}")
        reject(match.group(0), r"\brdma_(?:iova|backing_addr)_t\b", f"public API boundary violated in {name}")


def validate_core_dependencies(repo_root: Path) -> None:
    paths = sorted(repo_root.joinpath("src/core").glob("*.svh"))
    paths.append(repo_root / "src/core/rdma_core_pkg.sv")
    if not paths:
        raise ValidationError("missing core dependency sources")
    try:
        text = "\n".join(path.read_text(encoding="utf-8") for path in paths)
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
    _check_include_order(repo_root, "src/model/rdma_model_pkg.sv", ("rdma_resource_refs.svh", "rdma_queue_lifecycle_models.svh", "rdma_semantic_requests.svh", "rdma_resources.svh"))
    _check_include_order(repo_root, "src/core/rdma_core_pkg.sv", ("rdma_resource_manager.svh", "rdma_queue_lifecycle_policy.svh", "rdma_queue_backing_planner.svh", "rdma_queue_lifecycle_executor.svh", "rdma_control_plane.svh"))


FROZEN_ABI = (
    "src/codec/xtr_v1/rdma_xtr_v1_defs.svh",
    "src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh",
    "src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh",
    "src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh",
)


def validate_frozen_queue_abi(repo_root: Path) -> None:
    try:
        subprocess.run(["git", "diff", "--exit-code", "a0abd95", "--", *FROZEN_ABI], cwd=repo_root, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ValidationError("frozen ABI differs from baseline or git unavailable") from exc


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
