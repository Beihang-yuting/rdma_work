import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER_PATH = REPO_ROOT / "tools" / "check_queue_lifecycle.py"
SPEC = importlib.util.spec_from_file_location("check_queue_lifecycle", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)

REQUIRED_SOURCE_FILES = [
    Path("src/core/rdma_queue_lifecycle_policy.sv"),
    Path("src/core/rdma_queue_lifecycle_executor.sv"),
    Path("src/codec/rdma/rdma_queue_page_codec.sv"),
    Path("src/model/rdma_semantic_requests.sv"),
    Path("src/model/rdma_model_pkg.sv"),
    Path("src/core/rdma_core_pkg.sv"),
    *sorted(Path("src/core").glob("*.sv")),
    Path("src/codec/rdma/rdma_defs.svh"),
    Path("src/codec/rdma/rdma_image_masks.svh"),
    Path("src/codec/rdma/rdma_context_body_codecs.sv"),
    Path("src/codec/rdma/rdma_cmq_codecs.sv"),
]


def copied_repo(tmp_path: Path) -> Path:
    for relative in REQUIRED_SOURCE_FILES:
        destination = tmp_path / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text((REPO_ROOT / relative).read_text(encoding="utf-8"), encoding="utf-8")
    return tmp_path


class QueueLifecycleCheckerTest(unittest.TestCase):
    def test_normal_repository_passes_all_rules(self):
        for name in ("validate_iova_only", "validate_public_api_shape", "validate_core_dependencies", "validate_package_order"):
            getattr(CHECKER, name)(REPO_ROOT)
        with patch.object(
            CHECKER.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                ["git"], 0, stdout="", stderr=""
            ),
        ):
            CHECKER.validate_frozen_queue_abi(REPO_ROOT)

    def test_iova_only_rejects_backing_addr_in_each_consumer(self):
        for relative, label in [(REQUIRED_SOURCE_FILES[0], "policy"), (REQUIRED_SOURCE_FILES[1], "executor"), (REQUIRED_SOURCE_FILES[2], "PD codec")]:
            with self.subTest(label=label):
                import tempfile
                with tempfile.TemporaryDirectory() as d:
                    root = copied_repo(Path(d)); p = root / relative
                    p.write_text(p.read_text() + "\nfoo.backing_addr;\n")
                    with self.assertRaises(CHECKER.ValidationError): CHECKER.validate_iova_only(root)

    def test_iova_only_requires_projection_helper(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); p = root / REQUIRED_SOURCE_FILES[0]
            p.write_text(p.read_text().replace("rdma_queue_base_from_iova", "missing_helper"))
            with self.assertRaisesRegex(CHECKER.ValidationError, "rdma_queue_base_from_iova"): CHECKER.validate_iova_only(root)

    def test_iova_helper_comment_does_not_satisfy_requirement(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); p = root / REQUIRED_SOURCE_FILES[0]
            t = p.read_text().replace("rdma_queue_base_from_iova", "removed_helper")
            p.write_text(t + "\n// rdma_queue_base_from_iova(iova, base);\n")
            with self.assertRaisesRegex(CHECKER.ValidationError, "rdma_queue_base_from_iova"): CHECKER.validate_iova_only(root)

    def test_public_api_rejects_raw_address_fields(self):
        import tempfile
        classes = ("rdma_create_cq_req", "rdma_create_srq_req", "rdma_create_ceq_req", "rdma_create_aeq_req")
        for cls in classes:
            with tempfile.TemporaryDirectory() as d:
                root = copied_repo(Path(d)); p = root / "src/model/rdma_semantic_requests.sv"; text = p.read_text()
                marker = f"class {cls}"; i = text.index(marker); j = text.index("endclass", i)
                text = text[:j] + "  rdma_iova_t raw_field;\n" + text[j:]; p.write_text(text)
                with self.assertRaisesRegex(CHECKER.ValidationError, cls): CHECKER.validate_public_api_shape(root)

    def test_public_api_missing_class_fails(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); p = root / "src/model/rdma_semantic_requests.sv"; p.write_text(p.read_text().replace("class rdma_create_cq_req", "class removed_req"))
            with self.assertRaisesRegex(CHECKER.ValidationError, "rdma_create_cq_req"): CHECKER.validate_public_api_shape(root)

    def test_public_api_unclosed_class_fails_closed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); p = root / "src/model/rdma_semantic_requests.sv"; t = p.read_text(); i = t.index("class rdma_create_cq_req"); j = t.index("endclass", i); p.write_text(t[:j] + t[j+8:])
            with self.assertRaisesRegex(CHECKER.ValidationError, "malformed|missing"): CHECKER.validate_public_api_shape(root)

    def test_core_dependencies_reject_forbidden_symbols(self):
        import tempfile
        for symbol in ("pcie_work", "axis_vip", "net_packet", "host_mem_manager"):
            with tempfile.TemporaryDirectory() as d:
                root = copied_repo(Path(d)); p = root / "src/core/rdma_core_pkg.sv"; p.write_text(p.read_text() + f"\n{symbol};\n")
                with self.assertRaisesRegex(CHECKER.ValidationError, symbol): CHECKER.validate_core_dependencies(root)

    def test_missing_core_header_fails_closed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); (root / "src/core/rdma_control_plane.sv").unlink()
            with self.assertRaisesRegex(CHECKER.ValidationError, "missing core"): CHECKER.validate_core_dependencies(root)

    def test_extra_core_header_forbidden_symbol_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); evil = root / "src/core/evil.sv"; evil.write_text("host_mem_manager forbidden;\n")
            with self.assertRaisesRegex(CHECKER.ValidationError, "host_mem_manager"): CHECKER.validate_core_dependencies(root)

    def test_package_order_rejects_swap(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); p = root / "src/model/rdma_model_pkg.sv"; t = p.read_text(); p.write_text(t.replace('`include "rdma_queue_lifecycle_models.sv"\n  `include "rdma_hw_image.sv"\n  `include "rdma_semantic_requests.sv"', '`include "rdma_semantic_requests.sv"\n  `include "rdma_hw_image.sv"\n  `include "rdma_queue_lifecycle_models.sv"'))
            with self.assertRaisesRegex(CHECKER.ValidationError, "package order"): CHECKER.validate_package_order(root)

    def test_missing_required_file_fails_closed(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d)); (root / REQUIRED_SOURCE_FILES[0]).unlink()
            with self.assertRaisesRegex(CHECKER.ValidationError, "missing"): CHECKER.validate_iova_only(root)

    def test_frozen_abi_subprocess_failure_is_validation_error(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            with patch.object(CHECKER.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "git")):
                with self.assertRaisesRegex(CHECKER.ValidationError, "frozen ABI"): CHECKER.validate_frozen_queue_abi(Path(d))

    def test_modified_frozen_abi_fixture_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = copied_repo(Path(d))
            subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(["git", "add", *[str(p) for p in CHECKER.FROZEN_ABI_CURRENT]], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "baseline"], cwd=root, check=True, capture_output=True)
            p = root / CHECKER.FROZEN_ABI_CURRENT[0]
            p.write_text(p.read_text() + "\n// unauthorized ABI change\n")
            real_run = CHECKER.subprocess.run
            def translated_run(args, **kwargs):
                args = list(args)
                if "a0abd95" in args:
                    args[args.index("a0abd95")] = "HEAD"
                return real_run(args, **kwargs)
            with patch.object(CHECKER.subprocess, "run", side_effect=translated_run):
                with self.assertRaises(CHECKER.ValidationError): CHECKER.validate_frozen_queue_abi(root)


if __name__ == "__main__":
    unittest.main()
