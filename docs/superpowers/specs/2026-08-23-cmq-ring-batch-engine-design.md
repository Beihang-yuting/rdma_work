# CMQ Ring、Batch 与多 Outstanding Engine 设计

日期：2026-08-23

## 1. 目标和范围

本设计细化总计划 Task 13，定义一个能够连接真实 DUT 的 UVM CMQ engine。它负责：

- 申请和释放 CMQ SQ/CQ host-memory backing；
- 为多种 command SQE 分配 ring slot 和软件 command ID；
- 支持单命令、混合 opcode batch 和多个 outstanding；
- 保证 SQE backing、DMA/MMIO barrier、doorbell 的可见性顺序；
- 从真实 CQ backing 轮询 completion，并支持乱序命令完成；
- 处理 per-command timeout、迟到 completion、Function generation cancel 和 reset；
- 通过注入的硬件 profile 隔离 xtr_v1 位域与通用 ring/state 逻辑。

本轮不实现 Task 14 的 PD/MR/CQ/QP 等控制面生命周期，也不把 `pcie_env`、
`axis_env`、VIP 或外部仓库复制到 core。真实 DUT 和辅助 VIP 只通过现有 adapter
更新 host memory 或执行 PCIe MMIO。

## 2. 参考实现审计

参考驱动固定为 commit `491faf2ba42627fffd4dd027607299c8bb591ec2`，53 上归档为：

```text
/home/ubuntu/workspace/Desktop.zip
  dpu_kernel_rdma-version_0.1.32/cmq.h
  dpu_kernel_rdma-version_0.1.32/cmq.c
  dpu_kernel_rdma-version_0.1.32/rdma_type.h
```

审计得到的硬件事实：

- SQ 和 CQ depth 都是 32；
- CMQE 固定 64B；
- SQ 和 CQ 共用一个 4096B 对齐的 DMA allocation；
- SQ 位于 allocation 前 2048B，CQ 位于后 2048B；
- SQE/CQE qword 使用 big-endian；
- SQE 公共字段包含 valid、wrap、5-bit WQE index 和 8-bit opcode；
- CQE 包含 owner/valid、wrap、WQE index、opcode 和 8-bit ecode；
- 软件通过 `request_array[wqe_index]` 找回 request，硬件没有独立软件 command ID 字段；
- 驱动以 CQ consumer position 顺序检查 CQE，但 CQE 自身返回 WQE index；
- 驱动每个命令写一次 doorbell，并使用 `size - 1` 的保留空槽策略。

本设计保留硬件格式和 DMA 布局，但不复制两个软件限制：batch 成功项使用一次
doorbell 发布，ring 使用 wrap/polarity 区分满空并允许 32 个 entry 全部成为
outstanding。

## 3. 已选架构

```text
Task 14 control-plane
        | rdma_cmq_command_desc
        v
rdma_cmq_engine ------ rdma_cmq_hw_profile
        |                    |
        |                    +-- xtr_v1 SQE/CQE/doorbell/error codecs
        +-- rdma_host_mem_api -- 4KiB SQ/CQ backing
        +-- doorbell scheduler -- rdma_pcie_api -- DUT BAR

真实 DUT -- EP DMA -- CQ backing -- engine.poll()
```

Task 23 runtime initializer 位于 `prepare()` 和 `activate()` 之间：engine 先申请 backing 并
返回 CMQ runtime descriptor，Task 23 使用 DUT testbench 注入的 frontdoor 编程 CMQ
context，Function/VFT 完成激活后，engine 才接受 command。Task 13 不猜测 CMQ context
寄存器地址。

### 3.1 `rdma_cmq_engine`

engine 只负责硬件中立的执行语义：

- backing 生命周期；
- command ID pool；
- ring reserve/publish/retire；
- batch staging；
- outstanding 和 tombstone；
- timeout、cancel、reset；
- 调用 profile 和 doorbell scheduler。

engine 内不得出现 `XTR_V1_*` 位域常量。一个 engine instance 只服务一个 CMQ 和一个
Function incarnation。所有会改变 ring 的公开 task 由 engine 内部 semaphore 串行化。

### 3.2 `rdma_cmq_hw_profile`

profile 是注入 engine 的抽象硬件契约，至少提供：

```text
compose_sqe(command, slot_context) -> 64B SQE image + expected response
inspect_cqe(raw_image, expected_owner) -> ready + decoded CQE
encode_doorbell(cmq_handle, final_pi, polarity) -> doorbell image/placement
```

`compose_sqe()` 拥有 opcode、valid、wrap、index、VF override 和 body 合成规则；
`inspect_cqe()` 拥有 owner、reserved-bit、opcode、wrap、index、ecode 和返回 payload
解析；`encode_doorbell()` 拥有 doorbell offset、width、endian 和字段布局。

slot context 同时给出 Function generation、mapping backing address 和相对 offset。
profile 返回的 SQE 必须已经是可交给 scheduler 的 immutable target image：kind 为
CMQ_SQE、长度和 alignment 都为 64、generation 匹配、target 为 backing memory。engine
只校验这些通用 metadata，不重写 profile 输出。

xtr_v1 profile 复用现有 request composer、completion codec、error codec 和 doorbell
codec。现有 xtr_v1 completion codec 将显式接收 expected owner，把 bit63 纳入 allowed
mask 和 decoded header，而不是由 engine 清位后绕过 codec。后续硬件版本通过新增 profile
接入，不改变 engine ring/state 算法。

### 3.3 外部依赖边界

engine 只依赖抽象对象：

- `rdma_host_mem_api`；
- `rdma_doorbell_scheduler`；
- `rdma_cmq_hw_profile`；
- Function binding snapshot 和 `rdma_cmq` resource snapshot。

`pcie_env`、`axis_env`、`host_mem` 具体实现、真实 DUT 和 VIP 均不构成 core 的编译或
构造必需项。真实 DUT 的 EP DMA 通过 RC responder 写入同一 host-memory allocation；
mock/VIP 测试也向同一 mapping 写入 CQE，不能绕过 CQ ring 调用内部完成函数。
CMQ base/context register programming 属于 Task 23 runtime initializer，不属于本 engine
或 doorbell scheduler。

## 4. 数据结构

### 4.1 DMA request context

现有 `rdma_host_mem_api.allocate(function_h, ...)` 无法表达 requester BDF；host_mem
adapter 当前把 `mapping.requester_bdf` 固定为零，而 doorbell scheduler 会用 binding BDF
严格检查 dependency mapping。为支持非零 PF/VF BDF，allocation 输入改为不可变的
`rdma_dma_request_context`：

```text
function_h
requester_bdf
pasid_valid
pasid
owner_h (optional)
```

context 从 PREPARED 或 ACTIVE Function binding 构造。host_mem adapter 在 allocation 时把
这些值写入 mapping 和内部 authority snapshot；调用者不得在 allocation 后修改。所有
mock、adapter contract test 和现有 allocation 调用点同步迁移到新接口。

新接口的语义为：

```text
allocate(dma_request_context, size, alignment, direction) -> mapping
```

engine 从 binding 派生 Function handle、`binding.pcie.bdf` 和 CMQ owner handle；可选
PASID 由 `prepare()` 的显式参数提供。`pasid_valid=0` 时 PASID 必须为零；
`pasid_valid=1` 时完整 20-bit PASID 进入 context 和 mapping authority。engine 会拒绝
context identity 与 binding 不一致的配置。

### 4.2 Command descriptor

`rdma_cmq_command_desc` 是低层 command-queue 输入，包含：

```text
Function handle/generation
profile opcode key
typed body model
optional QPC signature-source image
VF override/use-vfid routing
per-command timeout
```

profile opcode key 是独立 value object：

```text
profile_name
32-bit opcode
variant
```

`profile_name` 必须与 engine 配置的 profile 一致；`variant` 不能包含 registry delimiter。
xtr_v1 profile 要求 opcode 上 24 bit 为零，并使用低 8 bit 硬件 opcode。这个 key 只选择
设备命令格式，不承担软件 command ID 的职责。

调用者不提供 command ID、WQE index、wrap、valid 或 doorbell PI。profile opcode key 是
设备 profile 的低层 opcode；Task 14 负责把资源生命周期语义映射为一个或多个低层
command descriptor。

### 4.3 Ticket

`rdma_cmq_ticket` 是只读 value object，包含：

```text
64-bit command ID
Function UID/object ID/generation
CMQ handle identity
64-bit slot sequence
physical SQ index/wrap
profile opcode key
absolute deadline
```

ticket 不持有可修改的 engine 内部 slot 引用。

### 4.4 Completion

`rdma_cmq_completion` 包含：

```text
ticket snapshot
rdma_status
raw 64B CQE image
decoded response payload
```

正常、硬件错误、timeout 和 reset cancel 都以相同 completion value object 返回，且每个
completion 必须有可信 ticket。malformed/unmatched CQE 因无法可信地选择 ticket，只能
生成 diagnostic，不能伪造一个 null-ticket completion。

迟到 completion、malformed CQE 和 poison 原因使用单独的 `rdma_cmq_diagnostic` value
object；diagnostic 可以包含旧 ticket snapshot，但永远不进入正常 completion 数组。

### 4.5 Command ID pool

command ID allocator 使用 32 个可回收的 5-bit pool token，并为每个 token 保存 59-bit
单调 incarnation。public ID 为 `{incarnation, token}`；incarnation 从 1 开始，因此零始终
无效。timeout 后 token 可以回收，但下一次分配得到不同的完整 command ID；59-bit
incarnation 耗尽后该 token 永久返回 `RDMA_SC_RESOURCE_EXHAUSTED`，不得回绕。因此同一
Function generation 中不会出现历史 command key 别名。

软件 registry 的主 key 是：

```text
Function UID + Function generation + 64-bit command ID
```

硬件 CQE 的入口关联 key 是：

```text
Function UID + Function generation + WQE index + WQE wrap
```

入口关联命中 slot incarnation 后，再取得完整软件 command ID。两种 key 不互相替代。

## 5. Backing 布局与两阶段激活

`prepare()` 要求 PREPARED 或 ACTIVE binding、有效 CMQ handle、depth 32、entry size
64、合法的 PASID 参数和未配置 engine。它以 `RDMA_DMA_BIDIRECTIONAL` 申请一个 4096B、
4096B 对齐 mapping：

| 区域 | offset | size | DUT 方向 |
|---|---:|---:|---|
| SQ | 0 | 2048B | device read |
| CQ | 2048 | 2048B | device write |

mapping 的 Function、requester BDF、PASID 和 owner 来自 DMA request context。
`rdma_cmq.queue_iova` 指向 SQ base，`completion_iova` 指向 SQ base + 2048。

初始化把完整 4096B backing 清零，再返回 detached `rdma_cmq_runtime_desc`，其中只包含
Function/CMQ identity、SQ/CQ IOVA、depth、entry bytes 和初始 owner/polarity。任何
allocation、zeroing、resource snapshot 或 profile validation 失败都释放已取得 mapping，
并保持 engine `UNCONFIGURED`。成功后 engine 进入 `PREPARED`，仍拒绝 submit/poll。

Task 23 使用 runtime descriptor 编程真实 CMQ context。完成 notify/DMI/runtime/VFT 后，
调用 `activate(active_binding)`；engine 验证 Function UID/object ID/generation、BDF 和
PASID 与 prepare snapshot 完全一致，并要求 binding state 为 ACTIVE，随后进入 `ACTIVE`。
Task 13 单元测试使用 mock runtime initializer，但不能跳过显式 activate。

## 6. Ring 算法

engine 保存三个 64-bit 单调计数器：

- `publish_seq`：已经由成功 doorbell 发布的 SQE 总数；
- `retire_seq`：已经可安全覆盖的连续 SQ slot 前缀；
- `cq_consume_seq`：已经消费的物理 CQE 总数。

对任意 sequence：

```text
index = sequence % 32
wrap  = (sequence / 32) % 2
```

xtr_v1 初始 owner/polarity 规则为：

```text
SQE wrap              = slot wrap
SQE valid             = !slot wrap
doorbell PI           = final publish_seq % 32
doorbell polarity     = (final publish_seq / 32) % 2
expected CQ owner     = !((cq_consume_seq / 32) % 2)
CQE returned wrap     = originating SQ slot wrap
```

ring 使用量为 `publish_seq - retire_seq`。差值等于 32 时才返回
`RDMA_SC_QUEUE_FULL`；计数器倒退、差值大于 32 或 64-bit 加法溢出会 poison engine。

乱序 completion 只把对应 SQ slot 标为可回收。`retire_seq` 仅在当前 sequence slot 已经
COMPLETED、LATE_COMPLETED 或 RESET_CANCELLED 时连续前进。完成较新的 slot 不会越过仍
PUBLISHED 或 TIMED_OUT_QUARANTINED 的旧 slot。

## 7. Batch 提交

`submit()` 是单元素 `submit_batch()` wrapper。batch 按输入顺序执行：

1. 获取 engine lock，snapshot binding、CMQ、request 和 profile 输入。
2. 对每项执行 Function/generation/timeout/body validation。
3. 调用 profile 编码 SQE；失败项写入独立 `item_statuses[i]`，ticket 保持 null。
4. 成功项压紧到连续 tentative slot；剩余容量不足的项返回
   `RDMA_SC_QUEUE_FULL`。
5. 为成功项生成 tentative command ID、ticket、slot record 和 SQE image。
6. 把所有 SQE 作为一个 doorbell descriptor 的 queue-context dependencies，offset 为
   `index * 64`。
7. scheduler 顺序执行全部 SQE write、DMA visibility barrier、MMIO ordering barrier 和
   一次 CMQ doorbell。
8. doorbell 成功后，原子发布所有 ticket/slot/outstanding，并把 `publish_seq` 推进成功项
   数量。

`tickets` 和 `item_statuses` 始终与输入数组等长。`batch_status` 只描述 staging/scheduler
事务，不能替代逐项 status。只有逐项 validation/codec/queue-full 结果而没有 scheduler
失败时，`batch_status` 返回 OK；没有成功项时不发送 doorbell。成功发布项的
`item_statuses[i]` 必须为 OK。

如果 dependency、barrier 或 MMIO 失败，整个 tentative publish 不成立：

- `publish_seq` 不推进；
- 不登记 outstanding；
- tentative command IDs 全部回收；
- 所有原本编码成功的 item 得到同一个 transport failure；
- 原有 validation/codec failure 保持不变；
- 已写但未 doorbell 的 slot 被视为 unpublished，下次提交必须覆盖。

## 8. Completion 轮询和乱序相关

`poll()` 在 engine lock 下循环：

1. 从 `CQ_BASE + (cq_consume_seq % 32) * 64` 读取完整 64B image。
2. profile 先检查当前 expected owner；不匹配表示 CQ 为空，正常停止。
3. owner 匹配后校验完整 image，并解析 opcode、WQE index、wrap、ecode 和 payload。
4. 使用硬件入口 key 查找 slot incarnation。
5. 比较 slot 的 expected opcode/wrap/Function generation。
6. 生成 completion，关闭软件 command key，并回收 ID token。
7. 标记 slot completed，推进 `cq_consume_seq`，再尝试推进连续 `retire_seq`。

物理 CQ entry 必须按 `cq_consume_seq` 连续变为 ready，但每个 entry 返回的 WQE index 可以
对应任意 outstanding command。因此测试中的 command completion 可以按 ticket
`2 -> 0 -> 1` 返回；三个结果按到达顺序立即发布，而 SQ slot retirement 仍按原提交顺序
推进。

非零 ecode 只使对应 command 失败。xtr_v1 error codec 保留原始 8-bit ecode，并把
`source_engine`、Function UID/generation、CMQ resource ID 和 command ID 填入统一 status。

## 9. Timeout、迟到 Completion 与错误隔离

### 9.1 Timeout

timeout 使用协作式检查，不为每个 command 创建后台 process。`poll()`、显式
`expire()` 和同步 `wait_for()` 都检查绝对 deadline。

```text
FREE -> PUBLISHED -> COMPLETED -> FREE
                  -> TIMED_OUT_QUARANTINED
                     -> LATE_COMPLETED -> FREE
                  -> RESET_CANCELLED -> FREE
```

到期时：

- 向调用者发布一次 `RDMA_SC_TIMEOUT` completion；
- 从 outstanding command-key registry 移除并回收 ID pool token；
- 保留 slot 的旧 opcode、index、wrap、完整旧 command ID 和 raw correlation metadata；
- slot 进入 TIMED_OUT_QUARANTINED，不能推动 `retire_seq`。

匹配的迟到 CQE 只生成独立 diagnostic，不再次进入 completion 数组；slot 转为
LATE_COMPLETED 后才允许连续 retirement。

### 9.3 Observed 生命周期决策（Phase 1A）

生产调用方应使用 `execute_observed(command, result)` 取得一次 detached
`rdma_cmq_execution_result`。该入口恰好执行一次 submit；只有 journal 明确处于
`PUBLISH_AMBIGUOUS/PUBLISH_CONFIRMED + PENDING` 时才调用一次 `wait_for()`。
`HOST_VISIBLE_NOT_PUBLISHED + NONE` 立即返回，已保留的 terminal/timeout/late/reset
行直接从 journal 快照返回。`STAGED`、`PENDING_EFFECT`、缺失/矛盾 identity 或
快照构造失败均返回 `UNOBSERVED + INVALID_STATE + recovery_required=1`，不得猜测
提交是否已穿越 MMIO。legacy `execute()` 仅作为 deprecated 单向投影 seam，不能
反向驱动 observed 或写共享 last-state。

### 9.4 Observed 生命周期决策（Phase 1B）

result envelope 必须同时满足 operation status、submission/attempt effect、completion
phase、ticket/completion alias 和 Function/CMQ generation/incarnation 一致性。零
identity 直接返回仅适用于真实 `PRE_SUBMIT_REJECTED + NONE`；任何 delegated malformed
envelope 都转换为 `UNOBSERVED`。adapter 只校验并传播 detached 图，语义矛盾只能污染
`observation_status`，不得把 operation status 改写为成功或清除 recovery 证据。

### 9.2 Malformed 或未知 CQE

owner 已匹配但出现以下任一情况时，engine 进入 `POISONED`：

- reserved bit 非零；
- unsupported 或 slot-mismatched opcode；
- WQE index/wrap 无对应 active/tombstone incarnation；
- profile 返回空 decoded object/status；
- CQ/SQ counter 或 slot ledger 不一致。

engine 以 `rdma_cmq_diagnostic` 保留原始 CQE 和 identity-rich status，不猜测 ticket，
不改变错误关联的 slot，也不继续扫描后续 CQE。只有 reset 可以离开 POISONED。

## 10. Generation、Reset 与资源释放

`cancel_generation(old_generation)` 由 Function lifecycle manager 在该 generation 已进入
QUIESCING/RESETTING 后调用。它：

- 拒绝该 generation 的新提交；
- 为所有未完成 command 发布 `RDMA_SC_RESET_CANCELLED`；
- 清理 timeout tombstone；
- 回收 command ID token 和 slot；
- 不修改其他 Function generation 的对象。

`reset()` 串行阻止 submit/poll，取消当前 incarnation，释放旧 DMA mapping，清空 counters、
slot ledger、completion queue 和 poison 状态，回到 `UNCONFIGURED`。已经通过 timeout
完成的 tombstone 不再产生 RESET_CANCELLED；reset 只把它安全清除。随后必须以新
binding/generation 重新 `prepare()`、完成 runtime 初始化并 `activate()`。

旧 mapping 的 Function generation 和 requester BDF 仍保留在 adapter authority 中。旧
generation 的迟到 DMA 必须由 PCIe/host-memory 路由拒绝，不能写入新 mapping。
`shutdown()` 与无后续 prepare 的 reset 共用同一释放路径，并对 allocation leak 返回
明确 status。

### 10.2 Journal authority 与历史快照

journal row 是 batch、attempt、engine incarnation、Function identity、CMQ identity、
command/ticket 和 completion phase 的唯一权威。结果重建必须按 row 记录的 profile/
codec snapshot 解码 payload，不能使用 reconfigure 后的 mutable profile。消费 FIFO 后，
row 的 terminal/late/reset 快照仍可通过 ticket 查询；未知、重复或跨 reset epoch 的
ticket 一律 fail-closed 并保持 counters、quarantine 和其他 Function 的 FIFO 不变。

## 11. 公开 API

公开 task 语义为：

```systemverilog
prepare(binding, cmq, pasid_valid, pasid,
        host_mem, scheduler, profile, runtime_desc, status);
activate(active_binding, status);

submit(request, ticket, status);
submit_batch(requests, tickets, item_statuses, batch_status);

poll(completions, diagnostics, status);
expire(completions, status);
wait_for(ticket, completion, status);

cancel_generation(generation, completions, status);
reset(completions, status);
shutdown(status);
```

engine 内部保存未交付 terminal-result FIFO。`poll()` 把新 CQE/timeout 结果加入 FIFO 后取走
全部当前 completion；`wait_for()` 只取走目标 ticket 的结果，其他结果留在 FIFO，后续
`poll()` 仍可取得。每个 command completion 最多从 FIFO 交付一次。`reset()` 的 output
包含 reset 前尚未交付的 terminal results 和本次新生成的 RESET_CANCELLED results，随后
才清空 FIFO。

查询函数只返回 detached snapshot：engine state、mapping、三个单调计数器、
outstanding count、quarantine count 和最后 poison diagnostic。调用者不能取得可修改的
slot、registry 或 authority mapping 引用。

## 12. 预计文件边界

实施计划应把 Task 13 原来的单文件范围扩展为以下最小集合：

- model：DMA request context、opcode key、command descriptor、ticket、completion、
  diagnostic 和 runtime descriptor value objects；
- adapter API：带 requester BDF/PASID 的 host-memory allocation contract；
- host_mem adapter/mock：保存并验证 immutable DMA request context；
- codec：抽象 CMQ hardware profile；
- xtr_v1 codec/profile：SQE/CQE/doorbell glue 和 CQE bit63 owner/valid；
- core：`rdma_cmq_engine.svh`；
- tests：model/API/profile/engine focused tests，以及受 API 变化影响的现有 tests；
- package/filelist：只增加上述文件的 include/import/compile order。

不在本任务中重构 PCIe/VF lifecycle manager、Task 14 control plane 或 Task 18 data-plane
completion engine，也不实现 Task 23 的 CMQ context MMIO frontdoor。Task 13 只定义并
返回 runtime descriptor 契约。

## 13. 验证矩阵

### 13.1 Contract 和 model

- DMA request context 的 deep copy、BDF/PASID/generation validation；
- host_mem adapter authority 保存 requester BDF，伪造/修改 mapping 被拒绝；
- command/ticket/completion deep copy 和 null/zero/overflow negative cases；
- profile 空返回、错误 metadata 和 unsupported opcode。

### 13.2 Allocation 和发布顺序

- 单次 4096B、4KiB 对齐、bidirectional allocation；
- SQ/CQ offset 与 IOVA 正确，reset/shutdown 正好 release 一次；
- prepare 阶段拒绝 submit/poll，只有同 identity ACTIVE binding 才能 activate；
- SQE write -> DMA barrier -> MMIO barrier -> doorbell 的严格顺序；
- 混合 opcode batch 只产生一次 doorbell；
- codec 局部失败后成功项压紧；
- dependency/barrier/MMIO failure 不推进 PI、不产生 outstanding/ticket leak。

### 13.3 Ring 和 completion

- 32 个 outstanding 全部可用，第 33 个无 completion 时返回 queue full；
- retirement 后第 33 个有效发布使用 SQ index 0，SQ wrap=1，doorbell polarity 翻转；
- CQ owner 初值为 1，并在 32 个物理 CQE 后翻转；
- CQE 以 ticket `2 -> 0 -> 1` 返回时，结果立即发布且 slot 只连续退休；
- 非零 ecode 只失败对应 command，其他 batch item 不受影响；
- CQ payload、opcode、index、wrap 和 raw image 保留正确。

### 13.4 Timeout 和 lifecycle

- per-command timeout 不影响同 batch 其他 outstanding；
- timeout slot 阻止 producer 越过，迟到 CQE 后释放；
- 回收 pool token 后 public command ID incarnation 不重复；
- cancel/reset 为所有剩余 command 产生 RESET_CANCELLED；
- reset 释放旧 mapping，旧 generation completion/DMA 不污染新 engine；
- malformed/reserved/unknown CQE poison engine，reset 后恢复。

### 13.5 执行环境

仿真在 `10.11.10.53` 的 bash login shell 中执行：

```text
scripts/run_vcs53.sh core rdma_cmq_engine_test
```

随后运行所有正常注册的 core unit tests、host_mem integration test、Python contract tests
和 `git diff --check`。已知 `scripts/run_vcs53.sh core regression` 把 `regression` 当 UVM
class 的 harness 缺口属于 Task 31；Task 13 不以该已知失败替代逐项全回归。

## 14. 验收标准

Task 13 完成必须同时满足：

1. core 不依赖具体 PCIe/AXIS/VIP env；
2. 非零 VF BDF/PASID 能正确进入 immutable DMA mapping；
3. prepare/runtime/activate 边界与 Task 23 激活顺序无启动环；
4. 32-entry ring、batch 单 doorbell、多 outstanding 和乱序 completion 全部通过；
5. 任何 SQE 都只在完整 backing write 和 barrier 后被 doorbell 发布；
6. timeout、迟到 completion、ecode、malformed CQE 和 reset 不造成 ID、slot 或 mapping
   泄漏；
7. xtr_v1 owner/wrap/polarity 与 pinned driver 一致；
8. focused test、全部正常 core tests、host_mem integration 和 Python tests 无新增失败。
