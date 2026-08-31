# RDMA Task 15 host_mem Integration and Queue Boundary Checker Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

Goal: Add production host_mem evidence for 64-bit queue payload/PD backing and a fail-closed static checker for queue lifecycle address, API, dependency, package-order, and frozen-ABI boundaries.

Architecture: Extend the existing rdma_host_mem_adapter_test with a real rdma_queue_backing_planner allocation/initialization/readback/cleanup scenario on the pinned VCS53 host. Add a small standard-library Python checker whose validators operate on explicit source files and a pinned git baseline; pytest supplies positive and temporary-fixture negative cases.

Tech Stack: SystemVerilog/UVM 1.2, Synopsys VCS on ubuntu@10.11.10.53, pinned host_mem_manager, existing queue planner and xtr_v1 queue-PD codec, Python 3 and pytest.

Spec: docs/superpowers/specs/2026-08-31-rdma-queue-lifecycle-host-mem-boundaries-design.md

## Global Constraints

- Run all SystemVerilog simulation through scripts/run_vcs53.sh; the wrapper uses a bash login shell on ubuntu@10.11.10.53.
- Run host_mem with HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem; Makefile preflight must verify commit 3b9e000d5df4d10efbb3029f43605e0362e0caca and its source hashes.
- Do not modify pinned host_mem sources, frozen xtr_v1 definitions, opcodes, context masks, or CMQ envelope files.
- Do not add PCIe, AXIS, net-packet, or concrete host_mem_manager dependencies to src/core or queue policy/executor/PD codec.
- Do not expose host CPU backing addresses through public queue requests or use .backing_addr in IOVA-only consumers.
- Preserve the existing opaque mapping/release-authority contract and rdma_host_mem_api signatures.
- Do not stage, modify, or delete tests/unit/__pycache__/ or tools/__pycache__/.
- Do not persist credentials or tokens in remotes, scripts, environment files, or credential helpers.

## File Map and Interfaces

| File | Responsibility |
|---|---|
| tests/unit/test_check_queue_lifecycle.py | Checker positive and temporary-fixture negative tests. |
| tools/check_queue_lifecycle.py | ValidationError, source readers, five validators, and CLI main. |
| tests/integration/rdma_host_mem_adapter_test.svh | Real Function/queue fixture, planner initialization, PD readback, cleanup, and leak assertions. |
| src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv | Minimal production authority or 65-bit arithmetic fix only when integration evidence requires it. |

The checker exposes these exact Python functions:

    class ValidationError(RuntimeError): ...
    def read(repo_root: Path, relative: str) -> str: ...
    def reject(text: str, pattern: str, message: str) -> None: ...
    def validate_iova_only(repo_root: Path) -> None: ...
    def validate_public_api_shape(repo_root: Path) -> None: ...
    def validate_core_dependencies(repo_root: Path) -> None: ...
    def validate_package_order(repo_root: Path) -> None: ...
    def validate_frozen_queue_abi(repo_root: Path) -> None: ...

Every validator raises ValidationError for missing/unreadable files, rejected patterns, malformed input, or a failed frozen-ABI git command.

### Task 1: Checker red tests and fail-closed implementation

Files:
- Create: tests/unit/test_check_queue_lifecycle.py
- Create: tools/check_queue_lifecycle.py

Interfaces:
- Consumes: queue consumer/model/core source files and git baseline a0abd95.
- Produces: five validators and main used by CI and regression commands.

- [ ] Step 1: Write the checker loader and temporary repository fixture

Follow tests/unit/test_check_xtr_v1_defs.py and load the checker with importlib.util.spec_from_file_location. Define REQUIRED_SOURCE_FILES with the three IOVA-only consumers, src/model/rdma_semantic_requests.svh, src/model/rdma_model_pkg.sv, src/core/rdma_core_pkg.sv, every src/core/*.svh, and the four frozen ABI files. Copy each required file into a tmp_path while preserving its relative path:

    def copied_repo(tmp_path: Path) -> Path:
        for relative in REQUIRED_SOURCE_FILES:
            destination = tmp_path / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(
                (REPO_ROOT / relative).read_text(encoding="utf-8"),
                encoding="utf-8",
            )
        return tmp_path

- [ ] Step 2: Add red tests for every checker rule

Add a normal-repository test invoking all five validators. Add temporary-fixture tests that append .backing_addr to policy, executor, and PD codec independently; insert raw rdma_iova_t and rdma_backing_addr_t fields into each request class; insert each forbidden core symbol; swap one package include; delete one required file; and make the git subprocess raise CalledProcessError. Each test asserts ValidationError and a message naming the violated boundary. Use unittest.mock.patch for subprocess failure so tests never alter the real baseline.

- [ ] Step 3: Run the red tests

    python3 -m pytest -q tests/unit/test_check_queue_lifecycle.py

Expected before implementation: collection fails because tools/check_queue_lifecycle.py is absent. If collection fails for another reason, fix the loader/path first.

- [ ] Step 4: Implement the narrow checker

Use only pathlib, re, subprocess, and sys. read() catches OSError; reject() uses MULTILINE and DOTALL. Implement:

1. validate_iova_only() rejects the word-bounded .backing_addr pattern in policy, executor, and src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh, and requires rdma_queue_base_from_iova in policy.
2. validate_public_api_shape() locates each named request class body through its matching endclass and rejects word-bounded rdma_(iova|backing_addr)_t; missing classes are errors.
3. validate_core_dependencies() joins src/core/*.svh plus rdma_core_pkg.sv and rejects word-bounded pcie_work, axis_vip, net_packet, or host_mem_manager.
4. validate_package_order() requires and compares the model and core include sequences exactly as listed in the spec.
5. validate_frozen_queue_abi() runs git diff --exit-code a0abd95 -- followed by the four frozen paths with cwd=repo_root, captures output, and converts OSError or CalledProcessError to ValidationError. Do not embed opcode values or masks.

main() runs validators in the listed order, prints one concise error to stderr, returns 1 on ValidationError, and returns 0 on success. Guard it with if __name__ == "__main__": raise SystemExit(main()).

- [ ] Step 5: Run the checker tests and real checker

    python3 -m pytest -q tests/unit/test_check_queue_lifecycle.py
    python3 tools/check_queue_lifecycle.py
    git diff --check

Expected: all new tests pass, the real repository validates, and whitespace is clean.

- [ ] Step 6: Commit the checker unit

    git add tools/check_queue_lifecycle.py tests/unit/test_check_queue_lifecycle.py
    git commit -m "test: enforce queue lifecycle source boundaries"

### Task 2: Queue host_mem integration red test and fixture

Files:
- Modify: tests/integration/rdma_host_mem_adapter_test.svh

Interfaces:
- Consumes: rdma_queue_backing_planner.configure(), materialize(binding, preflight, resource_h, plan), initialize_payload_and_pd(binding, plan, pd_codec), rdma_xtr_v1_queue_pd_codec, and rdma_host_mem_adapter.read/release.
- Produces: a real host_mem test proving the PD contains payload IOVA and every owned mapping is released.

- [ ] Step 1: Add the queue fixture call and a deliberately missing helper

Add a run_queue_host_mem_fixture() call to run_phase() and initially reference build_queue_host_mem_fixture; do not silently skip the test. The intended fixture is an active binding with queue DMA requester BDF, PASID, domain, and CQ capability values; an owned CQ preflight; a reserved CQ resource; a configured planner; and a production rdma_xtr_v1_queue_pd_codec.

- [ ] Step 2: Run the integration red test

    HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
      scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test

Expected: host_mem preflight passes and VCS compilation fails at the intentionally missing helper. If preflight fails, stop and report the pinned checkout/hash problem; do not weaken the Makefile.

- [ ] Step 3: Implement the concrete fixture

Replace the missing helper with a task that creates the binding and rdma_host_mem_adapter, configures rdma_queue_backing_planner, creates a CQ reservation and preflight through the existing typed policy, calls materialize(), then calls initialize_payload_and_pd(). Find the RDMA_QUEUE_ROLE_CQ_RING and RDMA_QUEUE_ROLE_CQ_PD references by role.

Read the first eight bytes from the PD mapping and assert the first byte equals the first payload page IOVA high byte and the low valid bit is set:

    status = adapter.read(pd_ref.mapping, pd_ref.mapping_offset, 8, pd_bytes);
    expect_status("QUEUE_PD_READ", status, RDMA_SC_OK);
    if (pd_bytes.size() != 8 ||
        pd_bytes[0] != ring_ref.pages[0].page_iova.value[63:56] ||
        pd_bytes[7][0] != 1'b1)
      report_error("QUEUE_PD_READ", "PD did not encode the payload IOVA");

Use a nonzero adapter IOVA base for this fixture and assert the page IOVA differs from ring_ref.mapping.backing_addr.value. Also assert that mapping Function, requester BDF, PASID, DMA domain, direction, and owner are deep value copies of the request context.

- [ ] Step 4: Add reverse cleanup and leak proof

Release owned refs in reverse planner order using the existing planner cleanup helper or its exact role-level API, query release completion where required, and finish with:

    status = adapter.check_leaks(leak_count);
    expect_status("QUEUE_LEAKS", status, RDMA_SC_OK);
    if (leak_count != 0)
      report_error("QUEUE_LEAKS", "queue fixture leaked host backing");

Mutate the caller request context after allocation and assert the mapping authority snapshot is unchanged. Keep borrowed mappings untouched.

### Task 3: Minimal production authority and 64-bit fixes

Files:
- Modify only if Task 2 exposes a gap: src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv
- Test coverage: tests/integration/rdma_host_mem_adapter_test.svh

Interfaces:
- Consumes: current rdma_dma_request_context, rdma_dma_mapping, and rdma_host_mem_api contracts.
- Produces: unchanged adapter signatures, complete authority propagation, and fail-closed 65-bit range arithmetic.

- [ ] Step 1: Turn each observed gap into a named assertion

If a field is missing, add an assertion before changing production: check both dma_domain_valid and dma_domain_id, or check distinct nonzero IOVA/backing values with a QUEUE_* label. Do not relax an assertion to make a failing integration run green.

- [ ] Step 2: Implement only the necessary production change

Preserve allocate() ordering: request validation, host allocation, backing range validation, IOVA selection, authority clones, mapping/identity creation, authority snapshot, ledger/cursor commit. Copy Function/BDF/PASID/domain/owner before snapshot creation. Use 65-bit temporaries for backing and IOVA end calculations. On failure after mem.alloc(), free exactly that allocation and leave cursor/configuration unchanged. Do not add address getters, alter release identity semantics, or call PCIe/VIP code. If the existing implementation satisfies every assertion, leave this file unchanged and record that Task 2 supplied the missing evidence.

- [ ] Step 3: Run focused production checks

    HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
      scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
    scripts/run_vcs53.sh core rdma_adapter_contract_test

Expected: both exit 0 and report UVM warning/error/fatal counts of 0.

- [ ] Step 4: Commit the adapter/integration unit

    git add src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv \
      tests/integration/rdma_host_mem_adapter_test.svh
    git commit -m "test: verify queue lifecycle host memory boundaries"

If production is unchanged, stage only the integration test with the same message.

### Task 4: Full Task 15 verification

Files:
- Verify: tools/check_queue_lifecycle.py
- Verify: tests/unit/test_check_queue_lifecycle.py
- Verify: host_mem integration and Task 14 core suites

- [ ] Step 1: Run Python and frozen-boundary checks

    python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py \
      tests/unit/test_check_queue_lifecycle.py
    python3 tools/check_queue_lifecycle.py
    scripts/run_vcs53.sh xtr_defs regression

Expected: pytest passes, checker exits 0, and xtr_defs exits 0.

- [ ] Step 2: Run host_mem integration on VCS53

    HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
      scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test

Expected: preflight passes and the test ends with UVM warning/error/fatal counts 0 and local leak count 0.

- [ ] Step 3: Re-run Task 14 regression guards sequentially

    scripts/run_vcs53.sh core rdma_queue_lifecycle_test
    scripts/run_vcs53.sh core rdma_queue_recovery_test
    scripts/run_vcs53.sh core rdma_control_plane_test
    scripts/run_vcs53.sh core rdma_control_plane_cmq_engine_test

Run one at a time because they share build/core. Every command must exit 0 and end with the pristine UVM summary.

- [ ] Step 4: Inspect scope and final checks

    git diff --check
    git status --short --branch
    git diff HEAD~2..HEAD --stat

Confirm only Task 15 files plus the committed spec/plan changed and no cache directory is staged. Keep transient logs under /tmp; do not commit build outputs.

- [ ] Step 5: Record evidence and handoff

Report exact commands, exit codes, UVM counts, host_mem preflight result, checker result, and any production file changes before claiming Task 15 complete.
