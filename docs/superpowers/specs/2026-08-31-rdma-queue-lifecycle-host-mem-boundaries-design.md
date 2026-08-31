# RDMA Task 15 Queue Lifecycle host_mem 集成与边界 Checker 设计

日期：2026-08-31
状态：设计已确认，等待规格复核

## 1. 目标

Task 15 为已经完成的 queue lifecycle planner/executor 增加最后一层
production host_mem 证据和静态边界保护：

1. 在 VCS53 的 pinned host_mem checkout 上，使用真实
   `rdma_host_mem_adapter` 完成 64-bit queue payload/PD backing 分配、
   初始化、读回和释放；
2. 证明 DMA requester 的 Function、BDF、PASID 和 DMA domain authority
   在 production mapping 中按值复制，并且 host backing address 与 device
   IOVA 保持清晰分离；
3. 提供 fail-closed 的 `tools/check_queue_lifecycle.py`，阻止 queue
   policy/executor/PD codec 越过 IOVA-only 边界、公共 request 暴露裸地址
   类型、core 依赖具体外部 VIP，以及 package include 顺序漂移；
4. 为 checker 的每条规则提供 pytest 反例和正常仓库正例。

真实 host_mem 不可用时遵循现有 `host_mem_preflight`：检查失败并停止，
不提供 fake/mock fallback 来替代 integration 证据。

## 2. 本轮不做的内容

- 不修改 xtr_v1 opcode、CMQ envelope、context body、queue page codec 或
  frozen error-code 定义；这些 ABI 继续由已批准的 `a0abd95` 基线和现有
  checker 负责。
- 不把 `host_mem_manager`、PCIe、AXIS、net packet 或任何 VIP 实现类
  引入 `rdma_core_pkg`、queue policy、executor 或 PD codec。
- 不公开 host CPU backing address，也不新增用 backing address 作为 queue
  base 的 API；planner/host adapter 内部为必要的 CPU 读写可以使用该字段。
- 不改变 `rdma_host_mem_api` 的 opaque mapping/release authority 契约，
  不实现第二套分配器或伪造 host_mem 行为。
- 不把 checker 变成通用 SystemVerilog 解析器；它只检查本任务列出的
  固定文件、受限正则和 pinned ABI 基线。

## 3. 事实基线和边界

`rdma_host_mem_adapter` 已经：

- 从 `rdma_dma_request_context` 复制 Function、requester BDF、PASID、
  DMA domain、direction 和 owner authority；
- 对 host backing 使用 64-bit 地址，对 IOVA 做对齐、重叠和 65-bit 结束
  地址溢出检查；
- 用 opaque allocation identity 保存 release completion，并在失败路径
  回收 backing 和 IOVA cursor；
- 通过 `read()`/`write()` 访问 host_mem manager，调用方只能看到 typed
  mapping value 和不可伪造的 release authority。

现有 host_mem integration 已覆盖普通 64-bit mapping、authority clone、
copy/tamper、边界读写、IOVA cursor 和 leak 检查，但尚未让 queue backing
planner 写入 PD，再从真实 host_mem mapping 读回 PD bytes。

## 4. 总体架构

```text
rdma_function_binding
        |
        v
rdma_queue_backing_planner -- allocate/write --> rdma_host_mem_adapter
        |                                             |
        | initialize_payload_and_pd                  v
        +------------------------------> pinned host_mem_manager
        |
        +--> xtr_v1 queue page codec (IOVA-only projection)
        |
        `--> rdma_host_mem_adapter_test: read PD bytes + release/leak check

static source files --> tools/check_queue_lifecycle.py --> pytest fixtures
```

production adapter 仍是 host_mem API 与 queue planner 之间的唯一实现边界。
planner 负责 role、mapping、ownership 和 CPU-side initialization；queue
policy/executor/PD codec 只消费 checked IOVA projections。checker 只读取
源文件和 git baseline，不执行 production code，也不改变运行时状态。

## 5. Production adapter 语义

### 5.1 Authority propagation

每次成功 `allocate()` 必须将 request context 的下列字段复制到 mapping
和 authority snapshot：

```text
function_h (deep value copy)
requester_bdf
pasid_valid, pasid
dma_domain_valid, dma_domain_id
owner_h (deep value copy when present)
```

任何字段被 caller 修改、mapping 被另一个 adapter 使用、或 authority
identity 不匹配时，`read`、`write` 和 `release` 都返回
`RDMA_SC_DMA_TRANSLATION`/相应的 fail-closed 状态，并且不访问 host_mem。

### 5.2 64-bit address separation

真实 host_mem fixture 必须返回大于 `0xffff_ffff` 的 backing address。默认
identity IOVA 可以数值相同，但测试必须单独覆盖非零 IOVA base，使 IOVA
与 backing address 不相同。所有加法使用 65-bit 临时值；结束地址溢出、
非对齐或活动 IOVA 重叠都在分配提交前失败并回滚 backing/cursor。

### 5.3 Queue initialization evidence

integration fixture 创建一个 valid active Function binding 和 CQ queue
request，使用 planner 的 `materialize()` 与
`initialize_payload_and_pd()`。初始化后：

- payload backing 和 PD backing 均来自 production adapter；
- `adapter.read(pd_mapping, 0, 8, bytes)` 返回成功；
- bytes 中的 queue-page entry 编码 payload IOVA 的高字节/valid 位，
  而非 payload backing address；
- fixture 按 planner 生成的 reverse order cleanup，随后
  `adapter.check_leaks()` 返回 0 active mappings。

该断言证明 planner/codec 的 device-visible 数据没有偷偷依赖 host CPU
address。

## 6. 静态 checker 规则

`tools/check_queue_lifecycle.py` 暴露可独立调用的函数，并由 `main()` 按
固定顺序执行；任何缺失文件、无法读取、正则命中或 baseline 不一致都抛出
`ValidationError` 并返回非零退出码。

### 6.1 IOVA-only consumer

扫描以下文件，拒绝 `.backing_addr`：

```text
src/core/rdma_queue_lifecycle_policy.svh
src/core/rdma_queue_lifecycle_executor.svh
src/codec/xtr_v1/rdma_xtr_v1_queue_page_codec.svh
```

同时要求 policy 包含 `rdma_queue_base_from_iova`。planner 和 host adapter
不在该拒绝列表中，因为它们需要 CPU-side backing access。

### 6.2 Public request shape

在 `src/model/rdma_semantic_requests.svh` 的
`rdma_create_cq_req`、`rdma_create_srq_req`、`rdma_create_ceq_req`、
`rdma_create_aeq_req` class body 中拒绝裸的
`rdma_iova_t`/`rdma_backing_addr_t` 字段。

### 6.3 Core dependency boundary

扫描 `src/core/*.svh` 和 `src/core/rdma_core_pkg.sv`，拒绝
`pcie_work`、`axis_vip`、`net_packet`、`host_mem_manager` 等具体外部实现
标识符。core 只能依赖 adapter/model interface。

### 6.4 Package include order

固定并检查 model 顺序：

```text
rdma_resource_refs.svh
rdma_queue_lifecycle_models.svh
rdma_semantic_requests.svh
rdma_resources.svh
```

固定并检查 core 顺序：

```text
rdma_resource_manager.svh
rdma_queue_lifecycle_policy.svh
rdma_queue_backing_planner.svh
rdma_queue_lifecycle_executor.svh
rdma_control_plane.svh
```

缺失或顺序不单调即失败。

### 6.5 Frozen ABI

checker 执行：

```bash
git diff --exit-code a0abd95 -- \
  src/codec/xtr_v1/rdma_xtr_v1_defs.svh \
  src/codec/xtr_v1/rdma_xtr_v1_image_masks.svh \
  src/codec/xtr_v1/rdma_xtr_v1_context_body_codecs.svh \
  src/codec/xtr_v1/rdma_xtr_v1_cmq_codecs.svh
```

它不复制 opcode 数值或 mask 真相；现有 pinned-source checker 继续负责
真实驱动映射和值校验。

## 7. 测试与验收

### 7.1 Python TDD

`tests/unit/test_check_queue_lifecycle.py` 必须覆盖：

- 正常仓库所有规则通过；
- policy/executor/PD codec 读取 `.backing_addr` 被拒绝；
- request class 出现裸 IOVA/backing 字段被拒绝；
- core 外部 VIP 依赖和错误 package 顺序被拒绝；
- 任一 frozen ABI 文件偏离 `a0abd95` 被拒绝；
- 缺失文件、无法解析的输入和 git 命令失败均 fail-closed。

测试通过 temporary directory/fake repo 输入验证规则，不修改真实仓库
和 frozen 文件。

### 7.2 VCS53 integration

运行：

```bash
HOST_MEM_ROOT=/home/ubuntu/pcie-svt-switch-proxy.20260815/pcie_work/host_mem \
  scripts/run_vcs53.sh host_mem rdma_host_mem_adapter_test
```

预期 Makefile preflight 通过，测试 exit 0，且
`UVM_WARNING=0, UVM_ERROR=0, UVM_FATAL=0`。测试结束后 production adapter
的 local leak count 为 0。

### 7.3 Existing regression guards

运行：

```bash
python3 -m pytest -q tests/unit/test_check_xtr_v1_defs.py \
  tests/unit/test_check_queue_lifecycle.py
python3 tools/check_queue_lifecycle.py
scripts/run_vcs53.sh xtr_defs regression
```

Task 15 不得改变 Task 14 的四套 core VCS53 结果。

## 8. 交付文件

- Modify: `src/adapters/host_mem/rdma_host_mem_adapter_pkg.sv`
- Modify: `tests/integration/rdma_host_mem_adapter_test.svh`
- Create: `tools/check_queue_lifecycle.py`
- Create: `tests/unit/test_check_queue_lifecycle.py`

production 修改仅限 authority/domain/64-bit 边界确认证据所需的最小变更；
不扩大公共 API。checker 与 pytest 保持纯 Python、标准库依赖和可重复
输入。所有实现和测试在 VCS53/pinned host_mem 验证后再提交。
