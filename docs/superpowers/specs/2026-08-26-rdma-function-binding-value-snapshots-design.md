# RDMA Function Binding Value Snapshot Design

## 目标

Queue resource lifecycle 需要在 `rdma_function_binding` 中固定保存 queue DMA authority、queue capability 和 interrupt vector snapshot，同时必须在 10.11.10.53 的 Synopsys VCS W-2024.09-SP1 上稳定运行。

本设计将三个 binding-owned snapshot 定义为固定 schema 的 SystemVerilog value type，而不是 `uvm_object` child。它保留 `binding.queue_dma.*` 等调用形式，消除新增 child allocation、null/alias 状态和 factory override 对 binding schema 的影响。目标 VCS 还需要一个最小、明确隔离的 class-codegen workaround；该编译选项不是功能 RTL 要求。

## 决策依据

最初设计使用三个 `uvm_object` child，并在 binding constructor 中创建 `queue_dma` 和 `queue_caps`。以下隔离证据证明该建模方式在目标模拟器上不可用：

| Candidate | 唯一变化 | 结果 |
|---|---|---|
| A2 | 增加三个 member declaration，不创建 child | PASS，8000 ps，UVM 0/0/0 |
| A3 | A2 加 `queue_dma::type_id::create()` | BAD，两次 native SIGSEGV |
| A4 | A2 加 `queue_caps::type_id::create()` | BAD，两次 native SIGSEGV |
| A5 | A2 仅加 vector queue delete | PASS，8000 ps，UVM 0/0/0 |
| A6 | A2 加 `queue_dma = new(...)` | BAD，native SIGSEGV |
| F2 | 完整 Task 1 使用 constructor direct-new 和 do_copy direct-new/copy | model test 0/0/0；control-plane native SIGSEGV |
| V1 | 三个 snapshot 改为 `struct packed` value，完成值复制迁移 | model test 0/0/0；control-plane 仍 native SIGSEGV |
| V1 trace | 保持 V1，逐语句追踪 control-plane | SIGSEGV 在后续 fork elaboration 暴露；更早的 xtr_v1 string/value-key 路径对无关 code shape 极度敏感，只有对象名 guard 能改变结果 |
| U1 | 三个 snapshot 改为 unpacked struct，不加编译 workaround | compile/link 成功；`[RNTST]` 后 native SIGSEGV |
| P1 | 将 snapshot primitive flatten 到 binding | compile/link 成功；control-plane 仍 native SIGSEGV |
| O0 | U1 仅加 `-O0` | compile/link 成功；control-plane 仍 native SIGSEGV |
| D1 | U1 仅加 `-debug_access+class` | control-plane 正常到达 8000 ps，连续运行 UVM 0/0/0 |
| PASID RED | D1 下 owned snapshot 把 `first_pasid` 固定为无 authority 的 `20'h1a111` | 正常运行而非 native crash；返回 `RDMA_SC_DMA_TRANSLATION`，UVM error 5 |
| PASID GREEN | D1 下令 `first_pasid = binding.queue_dma.pasid` | authority 有效；保留 lock 前 request/access mutation 与 CMQ 后 PASID mutation，UVM 0/0/0 |

因此，问题不是 UVM factory、child `clone()` 或 packed representation 独有；unpacked、primitive flatten 和 `-O0` 的负结果证明 representation 本身不能消除 W-2024.09-SP1 的非局部 class code-generation miscompile。对象名 guard、测试专用 early return 或无关 codec 改写都不是可接受的修复。

三个 snapshot 不参与 CMQ、doorbell、PCIe TLP 或 memory image 的直接 bit serialization，因此不需要连续位布局。最终设计继续使用 unpacked struct value以表达 value semantics，并在 `sim/Makefile` 的 `VCS_FLAGS` 中精确增加 `-debug_access+class`，规避目标版本的 class-codegen miscompile。

## 数据模型

三个现有公开类型名改为 unpacked struct，字段名保持不变：

```systemverilog
typedef struct {
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
} rdma_queue_dma_context;

typedef struct {
  int unsigned min_cq_depth;
  int unsigned max_cq_depth;
  int unsigned min_srq_depth;
  int unsigned max_srq_depth;
  int unsigned max_ceq_depth;
  int unsigned max_aeq_depth;
  int unsigned max_wq_sge;
  longint unsigned max_queue_ring_bytes;
  longint unsigned max_sgb_bytes;
} rdma_queue_capabilities;

typedef struct {
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
} rdma_interrupt_vector_binding;
```

`rdma_function_binding` 继续发布：

```systemverilog
rdma_queue_dma_context queue_dma;
rdma_queue_capabilities queue_caps;
rdma_interrupt_vector_binding interrupt_vectors[$];
```

这保持所有下游字段访问语法，不引入裸 DMA/IOVA 地址，也不改变 Function、BDF、PASID 或 domain authority 的来源。

unpacked 仅表示字段没有连续 bit-level layout。三个类型仍是 SystemVerilog value type，assignment、function input 和 queue element copy 都按值执行。生产代码不得对它们使用 streaming operator、packed cast、`$bits` 布局假设或直接 wire/image serialization；需要硬件编码的字段仍由现有 codec 显式逐字段生成。

## 目标工具链适配

`sim/Makefile` 的公共 `VCS_FLAGS` 增加且只增加：

```make
# Work around a VCS W-2024.09-SP1 class-codegen miscompile; not an RTL requirement.
VCS_FLAGS := ... -debug_access+class
```

该 flag 同时覆盖 core 与 host_mem target，使两者编译相同的 RDMA class graph。它只针对 W-2024.09-SP1 的已复现 codegen miscompile，不改变 snapshot schema、功能要求或外部 host_mem/UVM/VCS 源码，也不授权 `-O0`、`-debug_access+all`、`-kdb` 或其他 debug/code-shape workaround。

## 构造、复制与所有权

binding constructor 只初始化值，不创建新增 child object：

```systemverilog
queue_dma = '0;
queue_caps = '0;
interrupt_vectors.delete();
```

`do_copy()` 使用值复制：

```systemverilog
queue_dma = rhs_binding.queue_dma;
queue_caps = rhs_binding.queue_caps;
interrupt_vectors = rhs_binding.interrupt_vectors;
```

unpacked struct 和其 queue element 都按值复制。因此 source/destination 无 child handle alias，不需要 `clone()`、`new()`、null 分支或 factory cast。binding、PCIe identity、owner handle 等原有 class 的深拷贝规则不变。

三个 snapshot type 不注册 UVM factory，不支持 subtype override，也不单独提供 `uvm_object` printing。它们是 binding schema 的组成部分，而非策略、adapter 或可替换 device model。

## Validation

DMA 和 capability validation 由 package-level value helper 提供：

```systemverilog
function automatic rdma_status rdma_validate_queue_dma_context(
  input rdma_queue_dma_context context
);

function automatic rdma_status rdma_validate_queue_capabilities(
  input rdma_queue_capabilities capabilities
);
```

规则保持为：

- invalid PASID 的 value 必须为 0；
- valid domain 的 ID 可以为 0；
- CQ/SRQ min/max depth 必须非零且 min 不大于 max；
- CEQ/AEQ depth 和 max WQ SGE 必须非零；
- queue ring/SGB byte capability 必须非零；
- `max_queue_ring_bytes` 大于 2 MiB 合法，后续 policy 自行取 `min(capability, 2 MiB)`；
- `queue_dma.requester_bdf` 必须等于 `pcie.bdf`；
- interrupt Function-local vector 在一个 binding 内必须唯一；
- `rdma_vf_id` 不得超过 8 bit。

struct 不可能为 null，因此删除 child-null 的 `RDMA_SC_INVALID_STATE` 分支。全零或字段非法 snapshot 通过上述 value rules 返回 `RDMA_SC_INVALID_ARGUMENT`；ACTIVE binding 缺少有效 domain 仍返回 `RDMA_SC_INVALID_STATE`。

Task 1 对 vector 的三个 unsigned ID 没有额外独立编码限制；binding 只检查 Function-local ID 唯一性。

## 调用点迁移

### Resource manager 与 authority projection

resource manager 直接复制 `queue_dma`、`queue_caps` 和 vector queue，不再构造或 clone snapshot child。equality/projection 继续逐字段或按 value 比较，必须包含 domain valid/value。

### Active-binding fixtures

所有 fixture 显式设置 queue DMA 和 capability 字段。vector 使用 value 初始化：

```systemverilog
rdma_interrupt_vector_binding vector;

vector = '0;
vector.function_local_vector = 3;
vector.hardware_eq_vector = 17;
vector.msix_table_index = 5;
vector.enabled = 1'b1;
binding.interrupt_vectors.push_back(vector);
```

不得再对三个 snapshot type 使用 `type_id::create()`、`new()`、`clone()`、`.copy()` 或 null comparison。

### Host memory、CMQ 与 doorbell

这些组件继续从 `binding.queue_dma` 取得 requester BDF、PASID 和 DMA domain，并把字段传播到 request context/mapping。设备地址仍只从 `mapping.iova` 推导；BAR/backing address 不参与 DMA authority。

## 测试设计

### Value-semantics RED

移除已失效的 factory-override child test，增加可同时编译于旧 class 模型和新 struct 模型的 assignment test：

1. 创建两个 binding。
2. 将 source 的 `queue_dma`、`queue_caps` 和 `interrupt_vectors` 赋给 destination。
3. 修改 destination 中的 PASID/domain、capability 和 vector 字段。
4. 旧 class 模型会因 handle/element alias 改变 source，测试必须 RED。
5. struct 模型必须保持 source 不变并 GREEN。

该测试只观察公开值语义，不添加 production test-only API，也不测试 mock 行为。

### Compiler-miscompile RED/GREEN

packed、unpacked、primitive flatten 和 `-O0` candidates 都在 compile/link 后于 `[RNTST]` 之后 native SIGSEGV，证明 unpacked representation alone 不是 crash fix。保持 unpacked schema并只增加 `-debug_access+class` 后，`rdma_control_plane_test` 必须连续两次到达 8000 ps且 UVM warning/error/fatal 为 0/0/0。不得修改 codec、mock CMQ、测试顺序、对象名字、timeout 或 fork structure 来影响 VCS code shape。

### Fixed-authority PASID RED/GREEN

owned snapshot test 在 lock 释放前更新第一次 request snapshot。若 `first_pasid` 使用与 binding authority 不同的固定 literal，最终 flag 下会正常运行到 `RDMA_SC_DMA_TRANSLATION` RED，而不是 native crash。测试必须用 `first_pasid = binding.queue_dma.pasid` 保持第一次 authority 有效，同时保留 request length/access mutation 和 CMQ 进入后的 `dma_context.pasid = 20'h2b222` mutation；这样 GREEN 仍证明 detached post-lock snapshot 不受 caller 后续修改影响。

### 回归

完成迁移后在 53 上逐项运行：

- `rdma_adapter_contract_test`
- `rdma_control_plane_test`
- `rdma_resource_manager_test`
- `rdma_model_test`
- `rdma_cmq_engine_test`
- `rdma_control_plane_cmq_engine_test`
- `rdma_doorbell_scheduler_test`
- `rdma_host_mem_adapter_test`，使用 `/home/ubuntu/workspace/host_mem`

每项必须 compile/link/run 成功并为 UVM 0 warning / 0 error / 0 fatal；最终 `rdma_control_plane_test` 总计运行两次。静态检查还必须证明三个 value snapshot type 没有残留 object allocation/copy/null 操作。

静态检查还必须证明三个 typedef 是 `typedef struct {`，而不是 `typedef struct packed`；`VCS_FLAGS` 恰好含 `-debug_access+class` 而不含禁止 flags；仓库中没有为该问题残留 `DBG_CP`、对象名 guard、typed-only return 或 xtr_v1 codec diff。提交范围为原 Task 1 的 17 个 tracked files、`sim/Makefile` 和本次纠正的两份 docs，共 20 个 tracked files。

## 非目标

- 不通过拆分或弱化 control-plane test 隐藏模拟器问题。
- 不保留 caller-owned、lazy-init 或 builder-managed child class。
- 不修改 VCS、UVM 或任何外部 VIP/host_mem 源码；`-debug_access+class` 是 repo-local build workaround，不是功能 RTL requirement。
- 不用测试对象名字、额外控制流、codec/string formatting 改写或 test-order change 规避 VCS 崩溃。
- 不使用 primitive flatten、direct-new snapshot、`-O0`、`-debug_access+all`、`-kdb`、direct-call probe、diagnostic marker 或 fork/timeout 改写。
- 不为 snapshot 恢复 packed layout；后续若确有硬件 image 需求，必须通过独立 codec 明确编码。
- 不改变 Task 1 之外的 queue lifecycle policy、executor 或 recovery 行为。
