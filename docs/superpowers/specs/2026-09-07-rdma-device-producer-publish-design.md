# RDMA CQ/CEQ/AEQ Device Producer Publish 设计

> 状态：已获方案批准，等待实现前文档审阅。  
> 日期：2026-09-07  
> 范围：本仓库的 queue-data runtime、CQ/EQ facade、Host-memory 访问和验证测试；不修改外部 `host_mem`、`net_packet`、`dpu_common` 或 PCIe checkout。

## 1. 目标与背景

当前 queue-data engine 已经能够消费 CQE、CEQE 和 AEQE，但设备侧生产仍由测试直接向 backing mapping 写字节。这样做绕过了运行时 producer cursor，导致以下状态无法表达或验证：

- CQ/CEQ/AEQ 的真实 producer-consumer occupancy；
- producer 达到 consumer 未追上的 full/backpressure；
- producer 回卷时的 owner/polarity 翻转；
- CQ consumer 释放后重新获得的 producer credit；
- CEQE 发布到 CEQ poll 再路由 CQ 的完整事件链路；
- 设备写入失败、写入后 commit 失败以及 stale/foreign authority 的恢复边界。

本设计为受控的 device model 提供正式 publish/commit 边界。它不是把 host-produced SQ/RQ/SRQ API 改名复用，也不声称替代真实 DUT；真实 DUT 后续只需把设备写入事件接到同一套 commit 语义即可。

### 1.1 本轮目标

1. 为 CQ、CEQ、AEQ 增加独立的 device producer reservation/commit 语义。
2. 让设备侧发布经过 Function/generation、queue authority、owner/polarity、route 和 backing access 校验。
3. 用真实 queue backing 完成 device-write、readback 和 producer occupancy 更新。
4. 覆盖 full、wrap、owner 翻转、consumer credit、失败恢复和 CEQ→CQ 链路。
5. 保持现有 `post_send`、`post_recv`、`poll_cqe`、`poll_ceqe`、`poll_aeqe` 的兼容行为。

### 1.2 非目标

- 不在本轮实现真实硬件中断线或 PCIe producer doorbell。CQ/CEQ/AEQ 的 producer 是设备拥有方，内存发布后由 host poll 消费；producer doorbell 不应由 host facade 伪造。
- 不自动把 `poll_ceqe` 隐式变成 `poll_cqe`。CEQ poll 返回事件并携带路由后的 CQ handle，调用方显式 poll CQ，保持当前 facade 的职责边界。
- 不改变 lifecycle manager 对 queue plan、DMA mapping 或资源释放的所有权。
- 不引入第二套独立的 CQ/EQ cursor shadow；device producer cursor 仍由该 attachment 的 runtime 唯一维护。

## 2. 现状盘点与设计原则

### 2.1 已有边界

- `src/core/rdma_queue_runtime.sv` 的 `commit_producer()` 会写 WQE slot ledger，适用于 host-produced SQ/RQ/SRQ，不适用于 device-produced CQ/CEQ/AEQ。
- `attach_cq()`、`attach_ceq()` 和 `attach_aeq()` 把 `host_produced=0` 传给 runtime，但旧 runtime 没有保存这个语义。
- `rdma_queue_backing_access.write()` 以 `RDMA_DMA_DEVICE_READ` 预检，表示 host 写 posting ring；CQ/EQ backing 通常只有 `RDMA_DMA_DEVICE_WRITE` 权限，不能用该入口模拟设备写入。
- CQE 支持 32/64/128-byte profile，CEQE/AEQE 固定 16-byte；共享 registry codec 不能通过改变可变 profile 状态来承担交错的 CQE 编码。

### 2.2 不变量

1. **生产者 API 隔离**：
   - SQ/RQ/SRQ 只能调用 host producer API，并维护 WQE ledger；
   - CQ/CEQ/AEQ 只能调用 device producer API，不创建 WQE ledger 条目；
   - 错误方向调用返回 `RDMA_SC_INVALID_STATE`，不改变任何 cursor、memory 或 occupancy。
2. **发布顺序**：模型/authority 校验 → producer slot reservation → detached encode → device-write → readback/逐字节比较 → producer commit。只有最后一步成功，slot 才对 consumer 可见。
3. **owner 由 cursor 决定**：slot 的期望 owner 为 `initial_polarity ^ slot_wrap`；producer 和 consumer 分别使用各自 reservation/CI 的 wrap，不能用另一端的 wrap 推导。
4. **失败 fail-closed**：任何失败都不得发布成功 result；写入之后但 commit 之前的失败必须保留 image、slot cursor、queue authority 和阶段证据。
5. **生命周期 authority 不复制**：runtime 保存 queue handle 的 detached identity snapshot；mapping、queue plan 和 manager 仍由其原所有者持有。

## 3. 推荐架构

### 3.1 runtime：扩展现有对象，不复用 host ledger

在 `rdma_queue_runtime` 中保存 `host_produced`，并新增 device producer 的受控状态：

- `bit host_produced`：configure 时锁存；后续 API 依此拒绝错误 producer 方向。
- `bit device_reservation_valid`：本 ring 至多允许一个未提交的 device reservation。这样可以在没有跨 task 锁的情况下保证“写入和 commit”之间不会出现重复 slot 或 out-of-order commit；并发调用返回 `RDMA_SC_RESOURCE_BUSY`，不静默覆盖。
- `rdma_queue_cursor_snapshot device_reservation`：保存已预留但尚未 commit 的 producer cursor。它是 runtime 拥有的值快照，不向调用方泄露可变内部引用。

reservation 的生命周期固定为 `none -> reserved -> committed/cancelled`。写入
已经尝试后不能走普通 `cancelled` 分支，而是进入 recovery；在 recovery 完成
或 abort 前，`device_reservation_valid` 和原 slot 快照都必须保留。一个未提交
reservation 只锁住 producer 的下一个 slot，不阻塞对已经 committed 的旧条目
执行 consumer commit；当 `used==0` 时 consumer 仍返回 empty，即使 reservation
对应的 backing bytes 已经写入。`begin_quiesce()`、resize 和 detach 必须等待
reservation/recovery 证据清除，不能在该窗口复用 backing。

新增公开方法：

```systemverilog
function rdma_status reserve_device_producer(
  output rdma_queue_cursor_snapshot reservation
);

function rdma_status commit_device_producer(
  rdma_queue_cursor_snapshot reservation
);

function rdma_status cancel_device_producer(
  rdma_queue_cursor_snapshot reservation
);

function bit expected_producer_polarity(
  rdma_queue_cursor_snapshot reservation = null
);

function rdma_status query_occupancy(output int unsigned value);
```

方法语义：

- `reserve_device_producer()` 仅允许 ACTIVE、`host_produced==0` 且 kind 为 CQ/CEQ/AEQ 的 runtime。`used >= depth` 或已有 reservation 返回 `QUEUE_FULL`/`RESOURCE_BUSY`，输出 reservation 保持 null。
- reservation 不立即推进 committed `producer_index` 或 `used`；它只锁定当前 slot。成功 publish 后 `commit_device_producer()` 才推进 PI/wrap 并使 `used++`。
- `commit_device_producer()` 要求 reservation 与保存的 device reservation 完全相同且 runtime 仍为 ACTIVE（或 recovery commit 已显式开启）；失配返回 `INVALID_STATE`，不改变状态。
- `cancel_device_producer()` 只用于确认没有写入副作用的路径，清除 reservation 而不改变 producer/consumer cursor。写入已尝试的路径必须进入 recovery，不能直接 cancel 后假装空闲。
- `commit_consumer()` 在 device-produced ring 上成功推进 CI 后执行 `used--`；若 `used==0` 或 reservation/恢复证据表明 CI 正指向尚未 committed 的 slot，则返回 `INVALID_STATE`。只要 CI 仍指向已 committed 条目，producer 侧存在另一个未提交 reservation 不影响 consumer 释放旧 credit。host-produced WQE ring 的既有 `match_and_release()` 账本规则不变。
- `peek_consumer()` 在 device-produced ring 上必须先检查 committed `used`；`used==0` 时直接返回 `RDMA_SC_QUEUE_EMPTY`，不得读取 backing。该门槛保证“image 已写入、producer 尚未 commit”的 slot 对 consumer 仍不可见。
- `query_occupancy()` 返回已 commit 的 producer-consumer 距离；`query_available()` 和 `available_slots()` 对 device ring 都要扣除一个未提交 reservation，避免 full 检查与查询不一致（结果为 `depth-used-1`，下限为 0）。

configure device-produced ring 时，runtime 根据 PI/CI/wrap 计算初始 committed occupancy：同 wrap 为 `PI-CI`，不同 wrap 为 `depth-CI+PI`；PI==CI 且 wrap 不同时表示 full。该计算把调用方提供的 cursor 视为可信的初始化快照，不在 configure 阶段读取 backing 或尝试重建每个条目的 codec/owner；attachment 负责在激活前保证 backing 与该快照一致。非法 cursor 组合直接拒绝 configure。host-produced ring 无法仅凭 cursor 重建 WQE 语义 ledger，因此仍要求 attachment 从空 ledger 开始，已有 WQE 状态只能通过现有 ledger copy/recovery 路径导入。

现有 `producer_index/producer_wrap` 字段继续表示该 ring 的 committed producer cursor；不新增一份会与 resize/lifecycle 分叉的 CQ 专用 cursor。`copy_ring_state()`、detach、recovery abort 和 resize quiesce 必须复制或清除上述新状态；resize 只允许从没有 reservation/pending evidence 的 quiesced source 复制。`begin_quiesce()` 还必须把有效 device reservation 视作 outstanding work，禁止在写入/commit 窗口切换 backing。

### 3.2 backing access：增加明确的设备写入口

在 `src/core/rdma_queue_backing_access.sv` 增加：

```systemverilog
function rdma_status write_device(longint unsigned offset,
                                  byte data[]);
```

该入口与现有 `write()` 的区别是：

- `resolve()` 后以 `RDMA_DMA_DEVICE_WRITE` 执行 span preflight，匹配 CQ/CEQ/AEQ mapping 的权限；
- 仍按 span 顺序调用同一 `host_mem.write()`，不接管 mapping 所有权；
- 失败时不推进任何 runtime cursor；
- device publish 的 readback 使用现有 `read()`（同为 DEVICE_WRITE 方向），而不是 posting-ring 专用的 `readback()`。

这样可以明确区分“host 写给设备读的 WQE”和“设备写给 host 读的 completion/event”，避免通过放宽 mapping 权限掩盖方向错误。

### 3.3 codec：CQE profile 的无状态编码

在 `rdma_hw_cqe_codec` 增加与现有 `decode_with_entry_bytes()` 对称的：

```systemverilog
virtual function rdma_status encode_with_entry_bytes(
  rdma_hw_model model,
  int unsigned entry_size,
  output rdma_hw_image image
);
```

方法使用临时 profile builder，不改变 registry 中共享 codec 的 `active_bytes`；只接受 32/64/128，输出 image 的 `length/alignment/bytes` 必须完全匹配 entry size。CEQE/AEQE 继续使用固定 16-byte `encode()`。

### 3.4 queue-data engine：统一 publish pipeline + 三个类型化入口

在 `src/core/rdma_queue_data_engine.sv` 增加结果对象：

```systemverilog
class rdma_queue_device_publish_result extends uvm_object;
  rdma_handle queue_h;       // detached queue identity
  int unsigned index;        // committed producer slot
  bit wrap;                  // slot wrap before commit
  int unsigned occupancy;    // commit 后的 occupancy
  rdma_hw_image image;       // detached encoded image
  rdma_status status;
endclass
```

增加三个公开 task：

```systemverilog
task publish_cqe(
  rdma_handle cq_h,
  rdma_hw_cqe_model model,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);

task publish_ceqe(
  rdma_handle ceq_h,
  rdma_hw_ceqe_model model,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);

task publish_aeqe(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
```

三个入口共享一个受保护的写入/commit helper；类型化入口负责各自 authority 和 route 校验。失败时 `result` 必须保持 null，只有 commit 成功后才返回 detached image、slot cursor 和 occupancy：

- **CQE**：校验 CQ handle、Function UID/generation、`qpn` 与已 attach QP link、`qp_h` identity、`rq_cqe` 对应的 SQ/RQ/SRQ attachment，以及 `wqe_index/wqe_wrap` 在 WQE ledger 的 outstanding release range 内；同时拒绝超出 CQE 字段宽度或对应 WQE ring 可表示范围的 cursor。模型的 `polarity` 必须等于 reservation slot 的 expected producer polarity。
- **CEQE**：校验 CEQ handle、`cqn`/`cq_h` 与已 attach CQ 的 identity，若 `qpn` 非零则校验对应 QP link；`cq_pi/cq_pi_wrap` 必须等于 CQ runtime 当前已 commit 的 producer cursor，且 `cq_pi` 必须能无损表示该 cursor；`valid` 必须匹配 CEQ reservation polarity。
- **AEQE**：在本轮仅覆盖 QP async event，校验 AEQ handle、非零 `qpn` 与已 attach QP link、`target_h` 为同一 Function/generation 的 QP；`valid` 必须匹配 AEQ reservation polarity。

模型输入只读。引擎可在 detached clone 中填充返回结果的 queue handle，但不会静默修正调用者传入的 owner、wrap、ID 或 generation；错误字段直接 fail-closed。

### 3.5 facade 委托

- `rdma_cq_engine` 增加 `publish_cqe()`，只做 configured/delegate 检查并委托 queue-data engine。
- `rdma_eq_engine` 增加 `publish_ceqe()` 和 `publish_aeqe()`，保持与现有 poll facade 相同的依赖检查。
- facade 不拥有 runtime、mapping、image 或 result 中的外部资源；result 是 detached snapshot。

## 4. 事务与恢复语义

### 4.1 正常发布

```text
validate handle/route/model
        |
reserve device slot (PI, wrap, owner evidence)
        |
encode detached image (CQE uses explicit profile)
        |
write_device(mapping-relative bytes)
        |
read + byte-for-byte verify
        |
commit_device_producer()
        |
publish result and occupancy
```

commit 之前，device ring 的 committed occupancy 不包含该 reservation；若 ring 原本为空，consumer 的 `peek_consumer()` 必须返回 `QUEUE_EMPTY`，不能访问新写 slot；若 ring 仍有旧 committed 条目，consumer 只能读取 CI 指向的旧条目，不能越过它看到 reservation。commit 成功后 poll 才能检查并看到新 owner。内存写入先于 cursor commit，并由 occupancy 门槛隔离，保证 consumer 不会观察到半写 image。

### 4.2 失败矩阵

| 阶段 | 返回码 | runtime 变化 | recovery |
| --- | --- | --- | --- |
| handle/model/route 校验 | 原始 INVALID/STALE/CODEC | 无 | 无 |
| reserve full | `RDMA_SC_QUEUE_FULL` | 无；输出全空 | 无 |
| encode 失败 | `RDMA_SC_CODEC_ERROR` 等 | 无；reservation 若已建立则 cancel | 无 |
| write/readback 失败 | DMA/后端原始错误 | 不 commit；reservation 保留 | 保存完整 pending image/slot |
| device commit stale/状态错误 | `RDMA_SC_INVALID_STATE` | producer/used 不推进 | 保存 pending；要求显式 recovery |
| recovery retry 再失败 | 原始错误或 `RECOVERY_REQUIRED` | 保留 pending | 不丢证据 |
| recovery abort | `RDMA_SC_OK`（runtime 进入 DETACHED 且 lifecycle detach 成功后） | 清除 reservation 并使 runtime 失效 | 已写入的旧 backing image 不再对该 attachment 可见；mapping 释放/回收仍由 lifecycle manager 管理 |

`rdma_queue_pending_operation` 增加 `device_producer`（以及必要的 device-write-attempted 阶段位），以区别 host producer replay。`replay_pending()` 对 device producer 只重放同一 detached image 到同一 slot，再显式 `enable_recovery_commit()`、`commit_device_producer()`、`complete_recovery_retry()`；不发 producer doorbell。若 reservation 已被其他代际/authority 隔离，retry 返回 `RDMA_SC_RECOVERY_REQUIRED`，不得写入当前 attachment。

现有 `recover_queue()` 的 caller confirmation 继续作为“允许重放此前可能已有写入副作用”的明确门槛。没有确认时不重放；ambiguous 或 stale 证据保持 pending。

## 5. 测试设计

### 5.1 runtime 单元测试

在 `tests/unit/rdma_queue_runtime_test.sv` 增加 CQ/CEQ/AEQ device runtime 场景：

1. device kind 可以 reserve/commit；host producer API 被拒绝，反向调用也被拒绝。
2. 深度为 2 或 4 时发布到第 N 个 slot 后 occupancy=N、available=0；第 N+1 次返回 `QUEUE_FULL`，PI/CI/used/reservation 均不变。
3. producer 从末尾回到 0 时 wrap 翻转，`expected_producer_polarity()` 同步翻转。
4. device consumer commit 每次释放一个 credit；释放后可再次 reserve；空 ring consumer commit 返回 `INVALID_STATE`。
5. stale reservation、重复 commit、错误 kind 和 cancel-after-commit 都 fail-closed。
6. recovery abort 清除未提交 reservation；recovery retry 只在显式 enable 后推进一次。

### 5.2 queue-data engine 单元测试

新增 `tests/unit/rdma_queue_data_engine_device_publish_test.sv`，复用现有 fixture 但不再直接写 backing：

- CQE：post send/recv WQE → `publish_cqe()` → poll CQE，断言真实 image、slot index/wrap、occupancy 和 WQE release；第二次 poll 返回 `QUEUE_EMPTY`。
- CQ full：填满 CQ 后第 N+1 publish 返回 `QUEUE_FULL`，比较 publish 前后的 backing bytes、PI/CI、occupancy、result 和 event ledger。
- CQ owner/wrap：深度 2/4 跨回卷发布，检查每个 slot polarity 与 runtime 期望一致；错误 polarity 不写内存。
- CQ malformed/foreign/stale：错误 QPN、WQE cursor、foreign Function、stale generation、错误 `rq_cqe` 均返回明确错误，不创建 pending 或半成品 result。
- CEQ 链路：publish CQE 后用当前 CQ PI/wrap publish CEQE；poll CEQ 得到 routed CQ handle，再 poll CQ 得到对应 completion。
- CEQ full/owner/wrap：覆盖 event ring occupancy、full、CI 释放 credit 和 polarity 翻转。
- AEQ：合法 QP event publish/poll、owner mismatch、full 和 stale target。
- device-write/readback 注入失败：确认写前失败无 cursor 变化；写后失败保留 pending image，未确认 retry 不重放，确认 retry 成功只 commit 一次。

### 5.3 真实 Host-memory 集成

在 `tests/integration/rdma_queue_data_engine_host_mem_test.sv` 或独立集成用例中使用现有 pinned `host_mem_manager`/adapter：

- 读回实际 CQ/CEQ/AEQ backing bytes，验证设备写方向权限和 variable CQE stride（32/64/128）；
- 运行多个 publish/poll 回卷周期，确认 mapping-relative offsets 正确；
- CQ、CEQ、AEQ、QP destroy 后执行 leak check，要求 `0 blocks outstanding`；
- 不把外部源码、build/log、wrapper 或临时 token 纳入仓库。

### 5.4 验证命令

- Python profile checker、现有 Python 单测和 diff 检查；
- VCS53：使用 `scripts/run_vcs53.sh` 的 bash login 环境运行新增 unit/integration case；检查 exit code 为 0，UVM `WARNING=0 ERROR=0 FATAL=0`；
- 运行现有 queue-data poll/post、CQ resize、recovery 和高流量回归，确保兼容行为未回退。

## 6. 文件变更边界

预期修改/新增文件：

| 文件 | 职责 |
| --- | --- |
| `src/core/rdma_queue_runtime.sv` | 保存 producer 方向、device reservation、occupancy、owner 和 recovery commit 语义。 |
| `src/core/rdma_queue_backing_access.sv` | 增加 `write_device()`，严格使用 DEVICE_WRITE permission。 |
| `src/codec/rdma/rdma_queue_codecs.sv` | 增加 CQE 显式 entry-size encode。 |
| `src/core/rdma_queue_data_engine.sv` | 类型化 CQE/CEQE/AEQE publish、路由校验、write/readback/commit 和 replay。 |
| `src/core/rdma_cq_engine.sv` | CQ publish 委托。 |
| `src/core/rdma_eq_engine.sv` | CEQ/AEQ publish 委托。 |
| `src/core/rdma_core_pkg.sv` | 若新增类型文件，按依赖顺序 include；优先在现有文件内实现，避免无必要拆分。 |
| `tests/unit/rdma_queue_runtime_test.sv` | runtime device producer 单元覆盖。 |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | 新增 queue-data publish/full/wrap/recovery/route 测试。 |
| `tests/rdma_unit_test_pkg.sv` | 注册新增测试。 |
| `tests/integration/rdma_queue_data_engine_host_mem_test.sv` | 真实 mapping/permission/leak 集成覆盖。 |

所有新增/修改的普通 SystemVerilog 文件使用 `.sv`；只有确实需要文本包含的现有宏定义文件保持 `.svh`。每个文件、class、module、function、task 在同步写代码时补充准确中文注释，说明功能、输入输出/副作用和失败边界。

## 7. 验收标准

实现完成前必须逐条满足：

1. CQ/CEQ/AEQ 的 publish API 不调用或伪装 host `commit_producer()`。
2. 真实 backing bytes 只有在模型、owner、authority 和 profile 全部通过后才写入。
3. full、错误 polarity、foreign/stale authority 和写入失败均不发布成功 result。
4. publish→poll 后 occupancy 和 CI/PI/wrap 与预期一致，跨回卷 owner 正确翻转。
5. CEQ 事件可以路由到同一 Function 的 CQ，跨 Function/代际不能串线。
6. recovery evidence 足以重放或安全 abort，且不会重复 commit、重复 release 或泄漏 mapping。
7. 既有 post/poll/resize/recovery/high-traffic 回归和 VCS53 质量门全部通过。
