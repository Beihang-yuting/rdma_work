# RDMA Multi-VF Recovery and Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在复用 dpu_common 投影和现有 reset coordinator 的前提下，验证四个 VF 的并发数据面、故障隔离、单 VF FLR/generation recovery，并输出可重复的 coverage/regression 入口。

**Architecture:** `rdma_device_env` 负责完整 Function identity/context ledger，`rdma_reset_coordinator` 负责 VF/PF/Host/Device epoch；Task 31 只增加一个轻量 VF harness，将真实 host-mem/net fault 与现有 context/reset API 连接起来。`rdma_coverage` 保存四视图事件的值快照并在采样点执行 covergroup/cross，测试和 coverage 不修改外部 dpu_common、PCIe、host-mem 或 net_packet 源码。

**Tech Stack:** SystemVerilog/UVM 1.2、VCS W-2024.09-SP1、现有 `rdma_types_pkg`/`rdma_model_pkg`/`rdma_core_pkg`/`rdma_dpu_env_pkg`、外部 dpu_common/host-mem/net_packet checkout。

**Spec:** `docs/superpowers/specs/2026-09-06-rdma-post-axis-integration-design.md`

## Global Constraints

- `dpu_common` 是 Host/PF/VF/BDF/BAR/global Function ID/topology 的唯一权威；RDMA 只消费冻结 snapshot。
- 所有新增普通 SystemVerilog 文件使用 `.sv`；`.svh` 只保留宏或固定 mask 头文件。
- 每个新增源码文件包含中文目录/职责/依赖/所有权说明；每个 function/task 紧邻功能、输入输出及副作用、失败边界注释。
- 外部 PCIe、host-mem、net_packet 和 dpu_common 源码保持只读，不复制到本仓库。
- VF FLR 只能隔离目标 Function 的旧 generation；非目标 VF 的 identity、payload、completion 和中断统计保持不变。
- 不提交 build、日志、Python cache、SSH wrapper、密码、token 或外部 checkout；本轮只创建本地 commit，不自动 push。

---

### Task 31A: Coverage value snapshot and cross model

**Files:**
- Create: `src/core/rdma_coverage.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_coverage_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Consumes: `rdma_transport_e`、`rdma_work_opcode_e`、`rdma_doorbell_kind_e`、`rdma_resource_kind_e`、`rdma_engine_kind_e`、`rdma_status_code_e`。
- Produces:

```systemverilog
typedef enum bit [2:0] {
  RDMA_COVER_RESET_NONE,
  RDMA_COVER_RESET_VF,
  RDMA_COVER_RESET_PF,
  RDMA_COVER_RESET_HOST,
  RDMA_COVER_RESET_DEVICE
} rdma_coverage_reset_stage_e;

typedef enum bit [2:0] {
  RDMA_COVER_FN_DISCOVERED,
  RDMA_COVER_FN_ACTIVE,
  RDMA_COVER_FN_QUIESCING,
  RDMA_COVER_FN_QUARANTINED,
  RDMA_COVER_FN_RECOVERED
} rdma_coverage_function_state_e;

class rdma_coverage extends uvm_object;
  function void sample_event(
    rdma_transport_e transport,
    rdma_work_opcode_e work_opcode,
    rdma_doorbell_kind_e doorbell_kind,
    rdma_resource_kind_e resource_kind,
    int unsigned function_count,
    int unsigned dma_domain_id,
    bit queue_wrap,
    bit dma_high_nonzero,
    rdma_status_code_e status_code,
    rdma_engine_kind_e source_engine,
    rdma_coverage_reset_stage_e reset_stage,
    rdma_coverage_function_state_e function_state
  );
  function int unsigned sample_count();
  function int unsigned cross_hit_count();
  function bit has_fault_coverage();
endclass
```

- [ ] **Step 1: Write the failing coverage test**

  在 `rdma_coverage_test.sv` 生成 RC/UD/URC、SEND/WRITE/READ/ATOMIC、SQ/RQ/CQ
  doorbell、QP/CQ/MR resource、四个 Function/domain、wrap、DMA 高 32 位非零、
  OK/STALE/timeout 状态和 VF/Device reset 样本；断言 `sample_count()`、
  `cross_hit_count()`、`has_fault_coverage()` 的结果。测试只依赖 core package。

- [ ] **Step 2: Run the focused test to verify it fails**

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_coverage_test
  ```

  Expected: `rdma_coverage` 或采样接口未定义，必须是编译失败而不是测试内部绕过。

- [ ] **Step 3: Implement the minimal coverage collector**

  `rdma_coverage.sv` 保存采样计数和 last-value 快照；covergroup 至少包含
  `transport×work_opcode`、`function_count×dma_domain_id`、
  `status_code×source_engine`、`doorbell_kind×function_state` 四个 cross，并
  将 `queue_wrap`、`dma_high_nonzero`、`reset_stage` 作为独立 coverpoint。空/非法
  样本不递增计数，所有字段保持 detached value snapshot。

- [ ] **Step 4: Run coverage unit test and core smoke**

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_coverage_test
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_smoke_test
  ```

- [ ] **Step 5: Commit coverage**

  ```bash
  git add src/core/rdma_coverage.sv src/core/rdma_core_pkg.sv \
    tests/unit/rdma_coverage_test.sv tests/rdma_unit_test_pkg.sv
  git commit -m "test: add RDMA multi-function coverage collector"
  ```

---

### Task 31B: Four-VF concurrency and fault/recovery matrix

**Files:**
- Create: `tests/integration/rdma_multivf_recovery_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/Makefile`
- Create: `sim/filelists/e2e_multivf.f` only if `e2e.f` cannot include the dpu_common integration package

**Interfaces:**
- Consumes: `rdma_device_env`/`rdma_reset_coordinator`、`rdma_net_packet_adapter`、real host-mem adapter、Task 31A `rdma_coverage`。
- Produces:

```systemverilog
task automatic run_vf_case(
  int unsigned vf_index,
  rdma_fault_kind_e fault,
  output rdma_status status
);
task automatic assert_other_vfs_unchanged(
  int unsigned excluded_vf,
  output rdma_status status
);
```

- [ ] **Step 1: Write the failing four-VF/fault matrix test**

  用 dpu_common snapshot 创建 4 个 VF identity（至少两个不同 PF 或不同 Host），
  为每个 VF 建立独立 DMA domain/route/Host ID，并让 VF0/VF1 使用相同数值 IOVA。
  在 `fork...join` 中调用四次 `run_vf_case()`，覆盖
  `RDMA_FAULT_WRONG_REQUESTER`、`RDMA_FAULT_IOVA_PERMISSION`、
  `RDMA_FAULT_CMQ_TIMEOUT`、`RDMA_FAULT_CQE_ERROR`、
  `RDMA_FAULT_PACKET_DROP`、`RDMA_FAULT_VF_FLR`；先写断言预期状态/码和非目标
  VF 不变性。

- [ ] **Step 2: Run focused test to verify it fails**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh integration rdma_multivf_recovery_test
  ```

  Expected: 测试/coverage 未注册或 helper 未定义导致失败；不得把 fault 逻辑写进
  测试临时变量绕过缺失实现。

- [ ] **Step 3: Implement VF harness and generation-safe recovery**

  每个 VF 保存完整 identity、binding、generation、DMA domain、payload 快照、
  `rdma_status` 和 network/CQ 计数；所有 event/completion 同时记录
  `function_uid`、`global_function_id`、`generation`、route 和 VF index。
  WRONG_REQUESTER/IOVA_PERMISSION 在 adapter 边界拒绝；CMQ_TIMEOUT/CQE_ERROR/
  PACKET_DROP 保存 durable recovery record；VF_FLR 先 quiesce 目标 context，再
  调用 `request_vf_flr()`，旧 handle 的 late completion 必须返回
  `RDMA_SC_STALE_GENERATION`，恢复后的新 handle 才能提交。owned mapping 只
  release 一次，borrowed payload release count 必须为零。

- [ ] **Step 4: Add regression manifest target**

  `sim/regression.list` 每行使用三个字段 `suite test dependency-tags`，至少包含
  `core rdma_coverage_test core`、`integration rdma_reset_cascade_test dpu_common`
  和 `integration rdma_multivf_recovery_test dpu_common,host_mem,net_packet`。
  Makefile 的 `regression` 目标逐行读取清单、校验 suite/test 字段、调用已有
  `run_vcs53.sh` 入口并汇总 test/seed/pass/fail；清单中不得出现 AXIS。

- [ ] **Step 5: Run VF matrix and non-regression checks**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  DPU_COMMON_ROOT=/home/ubuntu/dpu-common-external \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh integration rdma_multivf_recovery_test
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_coverage_test
  python3 tools/check_rdma_profile_names.py
  python3 -m unittest discover -s tests/unit -p 'test_*.py'
  git diff --check
  ```

- [ ] **Step 6: Commit Task 31**

  ```bash
  git add tests/integration/rdma_multivf_recovery_test.sv tests/rdma_unit_test_pkg.sv \
    sim/Makefile sim/regression.list
  git commit -m "test: add multi-VF recovery regression and coverage"
  ```

## Plan self-review

- Coverage requirement maps to Task 31A coverpoints/cross and its focused core test.
- Four-VF identity/domain/generation isolation, six fault kinds, FLR and exactly-once
  release map to Task 31B steps 1 and 3.
- Manifest and AXIS exclusion map to Task 31B step 4.
- Existing integration filelist is used unless the new test cannot be expressed there;
  no external source is copied into the repository.
- No placeholders or undefined helper signatures remain; Task 31A defines the coverage
  API consumed by Task 31B.
