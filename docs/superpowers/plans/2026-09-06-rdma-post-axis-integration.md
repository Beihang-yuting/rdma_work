# RDMA Task 28～31 集成与多 VF 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在跳过 AXIS VIP 的前提下，完成 responder registry、可选 adapter 的 `rdma_env` 组合、RC/UD/URC 端到端场景以及多 VF 并发恢复回归。

**Architecture:** Task 28 先提供独立的 responder region 账本和 seal 约束；Task 29 在此之上组合 RDMA core 与抽象 adapter，不创建外部 VIP 子组件；Task 30 复用现有真实 host-memory/net-packet 双 env fixture 扩展 transport 矩阵；Task 31 再把 Function/generation/domain 隔离和故障恢复提升到四 VF 并发场景。四个任务按依赖顺序串行提交，每个任务都在 core-only 或外部依赖 filelist 上独立验证。

**Tech Stack:** SystemVerilog/UVM 1.2、VCS W-2024.09-SP1、现有 `rdma_types_pkg`/`rdma_model_pkg`/`rdma_adapter_pkg`/`rdma_core_pkg`、固定 host-mem 与 `net_packet` checkout；不引入 AXIS 源码。

**Spec:** `docs/superpowers/specs/2026-09-06-rdma-post-axis-integration-design.md`

## Global Constraints

- 所有新增普通 SystemVerilog 源码、package 和测试使用 `.sv`；`.svh` 只保留宏或固定 mask 头文件。
- 每个源码文件开头写目录/职责/依赖/所有权生命周期中文说明；每个 function/task 紧邻写“功能 / 输入输出及副作用 / 失败边界”三段注释。
- `dpu_common` 是 Host/PF/VF/BDF/BAR/global Function ID/topology 的唯一权威；RDMA 只消费冻结 snapshot。
- 外部 PCIe、host-mem、`net_packet` 生命周期由外部环境拥有；本项目不修改或复制外部源码。
- VCS 验证必须通过 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行。
- 不提交 build、日志、SSH wrapper、密码、token 或外部依赖 checkout。
- 每个任务结束执行 `git diff --check`、对应 Python/静态检查和目标 VCS 测试，确认 UVM `warning=0 error=0 fatal=0`。

---

### Task 28: Responder region registry

**Files:**
- Create: `src/core/rdma_responder_registry.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_responder_registry_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Consumes: `rdma_route_key_t`、`rdma_bar_addr_t`、`rdma_status`、已有 `rdma_responder_mode_e`。
- Produces: `rdma_responder_domain_e`、`rdma_responder_region`、`rdma_responder_registry`。
- Required signatures:

```systemverilog
typedef enum bit [1:0] {
  RDMA_RESPONDER_CONFIG      = 2'd0,
  RDMA_RESPONDER_MMIO        = 2'd1,
  RDMA_RESPONDER_HOST_MEMORY = 2'd2,
  RDMA_RESPONDER_NETWORK     = 2'd3
} rdma_responder_domain_e;

class rdma_responder_region extends uvm_object;
  rdma_responder_domain_e domain;
  rdma_responder_mode_e mode;
  rdma_route_key_t route;
  rdma_bar_addr_t base;
  longint unsigned size;
  string owner;
  longint unsigned lease_id;
  bit active;
endclass

class rdma_responder_registry extends uvm_object;
  function rdma_status claim(
    rdma_responder_domain_e domain,
    rdma_responder_mode_e mode,
    rdma_route_key_t route,
    rdma_bar_addr_t base,
    longint unsigned size,
    string owner,
    output rdma_responder_region region
  );
  function rdma_status release(rdma_responder_region region);
  function rdma_status seal();
  function bit is_sealed();
  function int unsigned active_count();
  function rdma_responder_region region_at(int unsigned index);
endclass
```

- [ ] **Step 1: Write the failing registry tests**

  在 `rdma_responder_registry_test.sv` 写以下独立断言：空 registry 可 seal；CONFIG/MMIO/HOST_MEMORY/NETWORK 四种 domain 可 claim；同 route/domain 的完全重叠和部分重叠拒绝；`base + size - 1` 65-bit 溢出拒绝；`RDMA_RESPONDER_MONITOR_ONLY` 不参与冲突；错误 owner/lease release 不删除现有条目；seal 后 claim 拒绝；release 后同一区间可再次 claim。测试只使用 core package，不导入外部 env。

- [ ] **Step 2: Run the focused test to verify it fails**

  Run:

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_responder_registry_test
  ```

  Expected: 编译失败并报告 `rdma_responder_registry` 或 `rdma_responder_domain_e` 未定义；此时不得添加临时 typedef 到测试中绕过红灯。

- [ ] **Step 3: Implement the fail-closed registry**

  在 `rdma_responder_registry.sv` 中：

  1. `claim()` 先拒绝零 size、非法 route、65-bit end overflow、sealed 状态；再遍历 active region，只有 domain、host_topology_key、root_id、segment 相同且双方均非 MONITOR_ONLY 时执行区间相交检查。
  2. 为每个成功 claim 分配单调 `lease_id`，保存 detached owner string 和完整 route snapshot；registry 拥有内部 region 对象。
  3. `release()` 必须逐项匹配对象句柄、lease_id、domain、route、base、size；成功后 active 清零并删除内部项，失败不改变账本。
  4. `seal()` 幂等成功；sealed 后 claim 返回 `RDMA_SC_INVALID_STATE`，release 仍可执行以支持清理。
  5. `make_status()` 将错误 source 标记为 `RDMA_ENGINE_RESOURCE`，不掩盖原始状态码。

  在 `rdma_core_pkg.sv` 中按依赖顺序 include registry；在测试 package 中注册测试。所有边界算术使用 65-bit 临时值，避免 64-bit 截断。

- [ ] **Step 4: Run registry tests and static checks**

  Run:

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_responder_registry_test
  python3 -m unittest discover -s tests/unit -p 'test_*.py'
  git diff --check
  ```

  Expected: registry test 和 Python tests 通过；UVM `warning=0 error=0 fatal=0`。

- [ ] **Step 5: Commit Task 28**

  ```bash
  git add src/core/rdma_responder_registry.sv src/core/rdma_core_pkg.sv \
    tests/unit/rdma_responder_registry_test.sv tests/rdma_unit_test_pkg.sv
  git commit -m "feat: add responder region registry"
  ```

---

### Task 29: `rdma_env` optional-adapter composition

**Files:**
- Create: `src/core/rdma_env_config.sv`
- Create: `src/core/rdma_env.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Create: `tests/unit/rdma_env_composition_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`

**Interfaces:**
- Consumes: Task 28 registry；`rdma_pcie_api`、`rdma_host_mem_api`、`rdma_net_api`；`rdma_function_identity`/binding；UVM `uvm_config_db`。
- Produces: `rdma_env_mode_e`、`rdma_env_config`、`rdma_env`。
- Required signatures:

```systemverilog
typedef enum bit [1:0] {
  RDMA_ENV_CORE_ONLY = 2'd0,
  RDMA_ENV_MODEL_ONLY = 2'd1,
  RDMA_ENV_DUT = 2'd2,
  RDMA_ENV_HYBRID = 2'd3
} rdma_env_mode_e;

class rdma_env_config extends uvm_object;
  rdma_env_mode_e mode;
  int unsigned hardware_version;
  bit pcie_enabled, pcie_required;
  bit host_mem_enabled, host_mem_required;
  bit net_enabled, net_required;
  time operation_timeout;
  rdma_queue_capabilities queue_profile;
  rdma_responder_region responder_regions[$];
  function rdma_status validate();
endclass

class rdma_env extends uvm_env;
  rdma_pcie_api pcie;
  rdma_host_mem_api host_mem;
  rdma_net_api net;
  rdma_responder_registry responders;
  function rdma_status configure(rdma_env_config cfg);
  function rdma_status capability_status(string capability);
  function int unsigned pending_count();
endclass
```

- [ ] **Step 1: Write failing composition tests**

  写 core-only、model-only、DUT、hybrid 四种配置测试；检查 `uvm_config_db` 缺少 cfg 时 build fatal，required adapter 缺失时 build fatal，optional adapter 缺失时 capability 为 disabled/passive；验证 env 不创建 `pcie_env`/`axis_env` 子组件；验证 cfg clone 后修改原始 responder list 不影响 env snapshot；验证 responder 在 build 结束后已 seal。

- [ ] **Step 2: Run focused test to verify it fails**

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_env_composition_test
  ```

  Expected: `rdma_env`/`rdma_env_config` 未定义导致编译失败。

- [ ] **Step 3: Implement config snapshot and environment assembly**

  1. `rdma_env_config` 构造函数填充 core-only、版本 1、无 adapter、默认 timeout 和空 region list；`do_copy()` 深拷贝 region value，`validate()` 检查 mode、required/enable 一致性、timeout 非零和每个 region 合法。
  2. `rdma_env.build_phase()` 从 `uvm_config_db` 取 cfg 与抽象 adapter handle；没有 cfg 时 `uvm_fatal`，required adapter 缺失时 `uvm_fatal`，optional 缺失只设置 capability 状态。
  3. `configure()` 创建 registry、resource/codec/queue engine 所需 core 对象；将 cfg 中 region 逐一 claim；所有 claim 成功后调用 seal；不向下 cast 外部 adapter。
  4. 为注入的 Function identity 保存 generation/reset epoch 快照；`capability_status()` 返回 enabled/disabled/passive；`pending_count()` 汇总 env 自有 outstanding/scoreboard 事件。
  5. event 路由类型必须携带 target Function、vector 和 generation；拒绝只包含裸 vector 的事件。

- [ ] **Step 4: Run composition tests and core smoke**

  ```bash
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_env_composition_test
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core rdma_smoke_test
  git diff --check
  ```

  Expected: 四种模式和 capability gate 通过，core smoke 仍为 UVM 0/0/0。

- [ ] **Step 5: Commit Task 29**

  ```bash
  git add src/core/rdma_env_config.sv src/core/rdma_env.sv \
    src/core/rdma_core_pkg.sv tests/unit/rdma_env_composition_test.sv \
    tests/rdma_unit_test_pkg.sv
  git commit -m "feat: compose RDMA environment from optional adapters"
  ```

---

### Task 30: RC/UD/URC transport end-to-end sequence

**Files:**
- Create: `tests/integration/rdma_end_to_end_transport_test.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/Makefile` (only if a dedicated transport target is needed)
- Create: `sim/filelists/e2e_transport.f` (only if the existing `e2e.f` cannot express the transport matrix)

**Interfaces:**
- Consumes: Task 29 `rdma_env` semantic API；现有 `rdma_queue_data_engine_fixture`、真实 host-mem adapter、`rdma_net_packet_adapter`、CQ poll helper。
- Produces: transport-aware sequence/helper classes and one integration test `rdma_end_to_end_transport_test`。
- Required helper signatures:

```systemverilog
task automatic run_transport_case(
  rdma_transport_e transport,
  rdma_wr_opcode_e opcode,
  output rdma_status status
);
task automatic wait_transport_completion(
  rdma_transport_e transport,
  longint unsigned wr_id,
  time timeout,
  output rdma_queue_completion_result completion,
  output rdma_status status
);
```

- [ ] **Step 1: Write failing transport matrix tests**

  先扩展测试 fixture，列出 RC SEND/WRITE/READ/ATOMIC、UD SEND、URC SEND/WRITE/READ；每个 case 断言 payload、transport、QPN、PSN、opcode、CQE、pending_count 和 host-memory leak。保留 TX/RX 独立 Host ID、物理地址和 IOVA。测试先引用尚未实现的 `run_transport_case()`，确保红灯是接口缺失而不是运行时假失败。

- [ ] **Step 2: Run the focused transport test to verify it fails**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh e2e rdma_end_to_end_transport_test
  ```

  Expected: 新测试或 transport helper 未定义。

- [ ] **Step 3: Implement reusable transport sequence**

  1. 把当前 dual-env 的 payload/mapping/queue setup 抽成可复用 helper；每个 case 使用独立 WR ID 和 packet index，禁止复用已消费的 CQ slot。
  2. 按 transport/opcode 选择 semantic request 和 `net_packet` opcode；RC/URC 的 remote read/write 使用显式 responder policy，UD 只要求 SEND。
  3. 统一执行 post RQ → post SQ → packet encode/send/decode → host-memory write/readback → TX/RX CQE poll；CQ owner polarity、PI/CI、wrap、credit 和 outstanding key 必须逐 case 校验。
  4. timeout/packet fault 立即停止当前 case，保存首个 status；无论成功失败都按 mapping → QP/CQ/CEQ → host_mem 的顺序 cleanup。
  5. 对 unsupported transport/opcode 返回 `RDMA_SC_UNSUPPORTED_OPCODE`，不写 host-memory、不推进 ring、不发布 CQE。

- [ ] **Step 4: Run transport E2E and existing regressions**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh e2e rdma_end_to_end_transport_test
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh e2e rdma_end_to_end_dual_env_test
  ```

  Expected: transport matrix 和原有 128 包双 env E2E 均退出码 0，两个 manager leak check 为 0。

- [ ] **Step 5: Commit Task 30**

  ```bash
  git add tests/integration/rdma_end_to_end_transport_test.sv \
    tests/rdma_unit_test_pkg.sv sim/Makefile sim/filelists/e2e_transport.f
  git commit -m "test: add RC UD and URC transport end-to-end scenarios"
  ```

  若 `sim/Makefile`/filelist 未发生改动，只 stage 实际存在的文件，不创建空文件提交。

---

### Task 31: Multi-VF concurrency, recovery and coverage

**Files:**
- Create: `tests/integration/rdma_multivf_recovery_test.sv`
- Create: `src/core/rdma_coverage.sv`
- Modify: `src/core/rdma_core_pkg.sv`
- Modify: `tests/rdma_unit_test_pkg.sv`
- Modify: `sim/Makefile`
- Create: `sim/regression.list`

**Interfaces:**
- Consumes: Task 28 registry、Task 29 env、Task 30 transport helpers、`rdma_fault_kind_e`、现有 recovery/control-plane/queue APIs。
- Produces: `rdma_multivf_recovery_test`、`rdma_coverage`、逐行 regression manifest。
- Required helper signatures:

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

- [ ] **Step 1: Write failing multi-VF/fault tests**

  建立四个完整 Function identity（不同 BDF/PF-VF ID/notify window/domain），至少两个 VF 使用相同数值 IOVA；并发执行四个 `run_vf_case()`。逐项写 fault matrix：WRONG_REQUESTER、IOVA_PERMISSION、CMQ_TIMEOUT、CQE_ERROR、PACKET_DROP、VF_FLR。断言目标 VF 进入预期 ERROR/RECOVERY/RELEASED，其他 VF ACTIVE 且 payload、generation、completion 和中断计数不变；断言 owned release exactly-once、borrowed release count=0。

- [ ] **Step 2: Run focused test to verify it fails**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh e2e rdma_multivf_recovery_test
  ```

  Expected: multi-VF test/coverage 或 regression manifest 未定义。

- [ ] **Step 3: Implement concurrent recovery and coverage**

  1. 四个 VF 在 fork/join 中提交独立事务；每个事务把完整 Function identity、DMA domain、generation 和 route 写入 event，禁止只用 local VF index 匹配 completion。
  2. WRONG_REQUESTER/IOVA_PERMISSION 在 adapter 边界 fail-closed；CMQ_TIMEOUT/CQE_ERROR/PACKET_DROP 保留 durable recovery record；VF_FLR 先 bump 目标 generation，再取消旧 ticket/doorbell/mapping，其他 VF 不进入 quiesce。
  3. 恢复 dispatcher 按 presence/completion 两轴继续，逐项 `query_release_completion()` 后 exactly-once release；late completion 必须返回 STALE_GENERATION。
  4. `rdma_coverage.sv` 订阅四视图事件，覆盖 transport、WR/CMQ opcode、doorbell kind、resource kind、Function count、queue wrap、DMA 高 32 位非零、status category、reset stage，并定义 transport×opcode、Function×domain、error×source-engine、doorbell×Function-state cross。
  5. `sim/regression.list` 每行包含 suite/test/依赖标签；Makefile `regression` 逐行调用既有 runner，汇总 test、seed、pass/fail，不把 AXIS suite 加入清单。

- [ ] **Step 4: Run multi-VF, full regression and static audit**

  ```bash
  PCIE_WORK_ROOT=/home/ubuntu/pcie_work_unified \
  HOST_MEM_ROOT=/home/ubuntu/host_mem_latest \
  NET_PACKET_ROOT=/home/ubuntu/netpacket_np.GalEXM \
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh e2e rdma_multivf_recovery_test
  PATH="/tmp/rdma_sshpass_wrapper_codex:$PATH" SSHPASS=123 \
    scripts/run_vcs53.sh core regression
  python3 tools/check_rdma_profile_names.py
  python3 -m unittest discover -s tests/unit -p 'test_*.py'
  git diff --check
  ```

  Expected: multi-VF fault matrix、core regression、静态检查均退出码 0，UVM 汇总无未处理 error/fatal，registry/env/transport/coverage pending 均为零。

- [ ] **Step 5: Commit Task 31 and update verification record**

  ```bash
  git add src/core/rdma_coverage.sv src/core/rdma_core_pkg.sv \
    tests/integration/rdma_multivf_recovery_test.sv tests/rdma_unit_test_pkg.sv \
    sim/Makefile sim/regression.list docs/rdma-0.1.34-gap-closure-verification.md
  git commit -m "test: add multi-VF recovery regression and coverage"
  ```

---

## Final handoff checklist

- [ ] Task 28～31 各自提交，提交内容不含 build/log/wrapper/外部源码/凭据。
- [ ] `README.md`/验证文档说明 AXIS 被显式跳过，`AXIS_VIP_ROOT` 仍仅作为预留变量。
- [ ] core-only filelist 不依赖 PCIe、host-mem、`net_packet` 或 AXIS 实现类。
- [ ] 53 机 core、PCIe/SR-IOV、host-mem、net-packet、transport E2E 和 multi-VF 回归均有退出码证据。
- [ ] 最终工作树 `git status --short` 为空，`git diff --check` 通过。
