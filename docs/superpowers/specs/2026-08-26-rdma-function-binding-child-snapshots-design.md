# RDMA Function Binding Child Snapshot Construction Design

> **Superseded:** 后续 A6/F2 诊断证明 direct `new` 与完整 direct-new/copy 设计仍会触发相同 VCS SIGSEGV。本文件不再作为实施依据；替代设计见 `2026-08-26-rdma-function-binding-value-snapshots-design.md`。

## 背景

Queue resource lifecycle 为 `rdma_function_binding` 增加三个 Function-scoped snapshot：

- `rdma_queue_dma_context queue_dma`
- `rdma_queue_capabilities queue_caps`
- `rdma_interrupt_vector_binding interrupt_vectors[$]`

`queue_dma` 和 `queue_caps` 是 binding 的固定 schema value object，不是可替换的策略、adapter 或 device model。正常构造的 binding 必须始终拥有这两个对象；vector queue 可以为空，但其中的每个元素必须是有效、独立的 value snapshot。

## 问题证据

Task 1 的完整实现使 `rdma_control_plane_test` 在 10.11.10.53 的 VCS W-2024.09-SP1 中确定性 SIGSEGV。基线 `97e5735` 在相同环境通过，GDB 将崩溃定位到 `libvcsnew.so!Wsemget+442`，其中 stale pointer 的字节内容为对象名称 `mapping_`。

隔离的编译期二分得到以下相邻结果：

| Candidate | 相对已知 PASS 的唯一变化 | 结果 |
|---|---|---|
| A2 | 仅增加三个 binding member 声明 | PASS，8000 ps，UVM 0/0/0 |
| A3 | constructor 增加 `queue_dma::type_id::create()` | BAD，两次相同 SIGSEGV |
| A4 | constructor 增加 `queue_caps::type_id::create()` | BAD，两次相同 SIGSEGV |
| A5 | constructor 仅增加 `interrupt_vectors.delete()` | PASS，8000 ps，UVM 0/0/0 |

因此，最小触发条件是 `rdma_function_binding::new()` 中新增的 nested UVM factory allocation，而不是 member layout、snapshot 字段内容、vector queue 操作、binding clone、automatic task 或 fork watchdog 形式。

## 设计决策

### 固定 schema 子对象使用直接构造

`rdma_function_binding::new()` 使用直接构造：

```systemverilog
queue_dma = new("queue_dma");
queue_caps = new("queue_caps");
interrupt_vectors.delete();
```

这两个 child snapshot 不经过 UVM factory override。它们的具体类型、validation 和 copy 语义属于 `rdma_function_binding` 的数据契约，不能被测试或环境替换为改变 schema 的 subtype。

三个 snapshot class 仍保留 `uvm_object_utils`，因此仍可作为独立对象通过 factory 创建、打印或用于普通单元测试。限制只适用于它们作为 binding-owned child value object 时的构造和深拷贝。

### 深拷贝保持相同的固定类型规则

`rdma_function_binding::do_copy()` 不调用这些 child snapshot 的 `clone()`。目标 binding 为每个非空 source child 直接构造相同的基类对象，再调用 `copy()`：

```systemverilog
queue_dma = new("queue_dma");
queue_dma.copy(rhs_binding.queue_dma);
```

`queue_caps` 使用相同规则。`interrupt_vectors` 先清空，再对每个 source element 直接构造 `rdma_interrupt_vector_binding` 并调用 `copy()` 后入队。这样同时保证：

- source 和 destination 不共享 child handle；
- queue 元素不别名；
- factory override 不改变 binding snapshot schema；
- null source 的现有错误/validation 语义保持不变。

现有 `pcie`、BAR 和其他 model 的构造方式不在本次修正范围内；只处理二分已证明触发问题的新 queue snapshot。

## 不变量与错误处理

- 正常 constructor 返回后，`queue_dma` 和 `queue_caps` 必须非空。
- `validate()` 继续拒绝 null child、BDF 不一致、非法 PASID、非法 queue capability 和重复 Function-local vector。
- 有效 DMA domain ID 可以为 0；invalid PASID 的值必须为 0。
- 硬件 `max_queue_ring_bytes` 大于 2 MiB 合法；后续 policy 自行取 `min(capability, 2 MiB)`。
- 直接构造不改变 domain、PASID、BDF、IOVA、权限或 ownership authority 的传播规则。

## 验证设计

当前确定性的 `rdma_control_plane_test` SIGSEGV 是修正前的 RED 证据。实施后按以下顺序验证：

1. 在 53 上连续两次运行 `rdma_control_plane_test`，要求均到达 UVM summary 且 warning/error/fatal 为 0/0/0。
2. 运行 `rdma_adapter_contract_test` 和 `rdma_model_test`，验证 constructor 非空、validation 和 detached deep copy。
3. 运行 `rdma_resource_manager_test`，验证 registry projection 的 child snapshot 不别名且 domain 不丢失。
4. 运行 `rdma_cmq_engine_test`、`rdma_control_plane_cmq_engine_test` 和 `rdma_doorbell_scheduler_test`，验证最终 access contract 的调用点。
5. 使用 53 上实际存在的 `/home/ubuntu/workspace/host_mem` 运行 `rdma_host_mem_adapter_test`，验证 production adapter 的 64-bit mapping 和 domain snapshot。
6. 要求每项 UVM summary 都是 0 warning / 0 error / 0 fatal，并执行 `git diff --check`。

若直接构造仍发生同一 native crash，不叠加 workaround；恢复本次单点变化并返回 compile-time bisection 的已知 PASS/BAD 边界重新调查。

## 非目标

- 不拆分或弱化 `rdma_control_plane_test` 来隐藏模拟器问题。
- 不把 queue snapshot 改成 caller-owned 或 lazy initialization。
- 不修改 UVM、VCS、外部 host_mem、PCIe VIP 或 axis VIP。
- 不改变 Task 1 之外的 queue lifecycle API 或后续 policy 行为。
