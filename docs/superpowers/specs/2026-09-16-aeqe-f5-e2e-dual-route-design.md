# AEQE F5 端到端与 CQ-flush 双路由设计

日期：2026-09-16

状态：设计已批准

上游计划：`docs/superpowers/plans/2026-09-14-rdma-phase1c-abi-fixes.md`

## 背景

Phase 1C 已完成 AEQE canonical class/field authority、raw observation/replay 和
device-publish pre-reservation 校验。现有生产路径已经能够发布并轮询 SRQ、普通
CQ、CEQ、AEQ 事件，但缺少真实 Host-memory backing 的端到端覆盖。

CQ flush 是唯一已确认的生产缺口。其 16B wire image 同时携带 primary CQ ID 和
secondary QP ID；当前 publish API 只有 `model.target_h`，无法让 caller 显式证明
secondary QP authority。poll resolver 也只以 primary 命中决定是否返回 result，
因此 primary CQ miss、secondary QP hit 时会提交 CI，却丢失仍有效的 QP route。

## 目标

1. 使用真实 lifecycle resource、真实 16B AEQ backing 和真实 poll/doorbell 路径覆盖
   SRQ、普通 CQ、CEQ、AEQ。
2. 为 CQ flush 增加显式双 caller authority，同时保持现有 API 签名兼容。
3. poll 独立保存 primary/secondary route 命中结果，并正确返回三种 partial/miss
   组合。
4. 覆盖 non-QP stale/miss、Function 边界、target/ID/wire-width 拒绝原子性。
5. 通过 EQ facade 暴露同一能力，并保持现有 facade API 不变。
6. 保持 raw/canonical 分离、reserved masks、wire qword 坐标、Function/reset
   authority 和 Host-memory 生命周期边界不变。

## 非目标

- 不向 `rdma_aeqe_model` 或 `rdma_hw_aeqe_model` 增加 secondary handle。
- 不修改 16B AEQE wire layout、reserved mask 或 signature 规则。
- 不以 attachment table 代替 resource manager 作为 route authority。
- 不修改外部依赖仓库、resource manager lifecycle 状态机或驱动尚未实现的 EQ
  side effect。
- 不伪造 Function route miss；Function authority 与 event AEQ attachment 是同一
  live binding 的组成部分。

## 设计选择

采用兼容 sibling API。保留旧 `publish_aeqe()` 签名，新增：

```systemverilog
virtual task publish_aeqe_with_secondary(
  rdma_handle aeq_h,
  rdma_hw_aeqe_model model,
  rdma_handle secondary_target_h,
  output rdma_queue_device_publish_result result,
  output rdma_status status
);
```

queue-data engine 将两个 public task 收敛到一个 protected 共用实现。旧入口传入
null secondary；新入口传入 caller 提供的 secondary handle。EQ facade 增加同名
透明 sibling task，只执行既有 live-authority 检查并 delegate，不复制 ecode
classifier。

未采用的方案：

- 修改旧 task 签名会破坏现有调用方和 test override。
- 把 secondary handle 放进 hardware model 会把一次 caller authority 证明错误地
  持久化为 wire model 状态。
- 继续从 wire QPN 隐式推断 caller authority 无法阻止未经授权的 CQ-flush publish。

## Canonical publish 规则

事件是否为 CQ flush 由唯一 ecode classifier 和
`packet_opcode[4:0] == 5'h1d` 判定。

CQ flush 必须满足：

- `model.target_h` 非空、kind 为 CQ，并与 split CQN/EQN resolver 结果
  `same_instance()`。
- `secondary_target_h` 非空、kind 为 QP，并与 QPN resolver 结果
  `same_instance()`。
- 两个 handle 都属于当前 Function UID/generation，且 route/reset epoch 有效。
- primary 和 secondary 都唯一命中。
- 完整 16B codec encode/preflight 在 `reserve_device_producer()` 前完成。

旧 `publish_aeqe()` 因无法提供 secondary caller，对 CQ flush 返回
`RDMA_SC_INVALID_ARGUMENT`，result 为 null，且 reservation、backing、PI/CI、
used、pending、Host-memory 和 MMIO 都不改变。

任何非 CQ-flush 事件若通过 sibling API 传入非空 secondary，也返回
`RDMA_SC_INVALID_ARGUMENT`。普通 QP/SRQ/CQ/EQ/Function 事件通过旧入口保持兼容。

caller handle 与 live resolver 结果不一致、route 缺失或 generation 不匹配时返回
`RDMA_SC_INVALID_STATE`。codec 字段污染继续返回 `RDMA_SC_CODEC_ERROR`。所有
拒绝均保持 result null 和队列状态原子。

## Raw poll 与 partial result

`resolve_aeqe_routes()` 分别输出 `primary_found` 和 `secondary_found`。普通
single-owner 事件只使用 primary；CQ flush 可以独立命中两边。

`prepare_event_result_candidate_ex()` 仅对 CQ flush 允许一侧为空，并要求至少一侧
非空。primary CQ 为空时：

- decoded `event_model.target_h` 保持 null；
- profile class/owner 仍由 ecode 冻结为 CQ，而不是从 secondary QP 反推；
- live QP 仅写入 `result.secondary_target_h`；
- raw qwords、ecode、split CQ ID、QPN 和 opcode 保持可观察。

poll 结果矩阵：

| primary CQ | secondary QP | 返回结果 | 消费行为 |
| --- | --- | --- | --- |
| hit | hit | primary CQ + secondary QP | ack，CI +1，used 变 0，MMIO +1 |
| hit | miss | primary CQ，secondary null | 同上 |
| miss | hit | primary null，secondary QP | 同上 |
| miss | miss | result null | 仍 ack 并提交 CI |

resolver 只把明确的 stale/released/unknown resource 归类为 route miss；其他 manager、
binding 或 reset 错误继续 fail closed，且不提交 CI。

## 新测试边界

新增 `tests/unit/rdma_aeqe_f5_e2e_test.sv`，继承现有 route-consume 测试并复用真实
lifecycle fixture、backing reader、atomic-state capture 和 cleanup helper。该文件
按仓库规范提供文件头以及每个 function/task 紧邻自身的中文“功能 / 输入输出及副作用 /
失败边界”三段注释。

四个 publish → actual backing → poll 正例：

| case | ecode | primary owner | 关键 wire 条件 |
| --- | --- | --- | --- |
| SRQ | `8'h79` | SRQ | `srfq_en=0`，SRFQN 使用真实 local ID |
| CQ | `8'hf4` | CQ | non-flush，`qpn=0` |
| CEQ | `8'hf7` | CEQ | split ID，`qpn=0` |
| AEQ | `8'hfb` | 另一条 owner AEQ | split ID，`qpn=0` |

每项必须验证：

- publish 前后 PI/CI、wrap、used、pending、polarity 和 MMIO；
- actual 16B backing 逐 byte 等于 returned image；
- qword literal 坐标、完整 local ID 宽度前置断言及
  `(high << 6) | low` oracle；
- poll 后 route kind、instance、Function/generation、raw qwords、CI/used/MMIO；
- 二次 poll 返回 empty；
- 资源按 QP → SRQ → CQ → AEQ → CEQ 反依赖顺序无条件清理。

这些已有生产能力的正例允许首次运行即 GREEN，不能制造假 RED。

## CQ-flush TDD 合同

必须先取得两个真实 RED：

1. 旧 `publish_aeqe()` 在 primary CQ 和 wire QPN 都有效、但无 secondary caller
   authority 时当前会成功；新合同要求 pre-reservation 原子拒绝。
2. 合法发布后销毁 primary CQ、保留 secondary QP；当前 poll 会 ack 后返回 null，
   新合同要求返回 primary null、secondary QP。

同时覆盖 CQ hit/QP miss 和 both miss；若它们在生产修复前已满足合同，记录为已有
GREEN，不伪造失败。

GREEN 必须通过 sibling API 合法发布 CQ flush，读取实际 backing 验证 split CQ ID、
QPN、opcode 与 polarity，再用公开 lifecycle destroy 构造三种 partial/miss。禁止直接
修改 registry、allocator cursor、attachment 或 decoded model。

## Stale、Function 与原子拒绝

single-owner miss 表覆盖 SRQ、CQ、CEQ、AEQ：先合法 publish 并保存 actual backing，
再用公开 destroy 使 owner stale，最后 poll。每项应返回 operation OK、result null，
并正常 ack/CI/MMIO commit。

Function diagnostic/TX-flush 是必命中控制项。若通过公开 reset/generation 变化令 binding
或 event AEQ attachment stale，poll 必须 fail closed，且 CI/used/MMIO 不变；该行为不
归类为 route miss。

publish negatives 覆盖：

- SRQ/CQ/CEQ/AEQ target kind 或 instance mismatch；
- wire ID 与 caller handle mismatch；
- SRQ manager-valid 但超 12-bit wire ID；
- CQ manager-valid 但超 19-bit split ID；
- CEQ/AEQ 超本类 manager 宽度的 raw split ID；
- Function wrong target 与 object-field pollution。

每项必须证明 reservation 未建立、backing/PI/CI/used/pending 未变、Host-memory 与 MMIO
调用数不增。test-only allocator override 使用后立即恢复，并用正常 positive smoke
证明没有全局 factory 泄漏。

## 文件范围

计划内文件：

- 新增 `tests/unit/rdma_aeqe_f5_e2e_test.sv`
- 修改 `tests/rdma_unit_test_pkg.sv`
- 修改 `scripts/run_queue_lifecycle_regression53.sh`
- 修改 `src/core/rdma_queue_data_engine.sv`
- 修改 `src/core/rdma_eq_engine.sv`
- 修改 `tests/unit/rdma_eq_engine_test.sv`
- 在 F5-D 同步修正 codec 中 `logical_cqn_eqn()` 的 stale 公式注释，使其明确写为
  `(high << 6) | low`；不改变该函数实现或 codec 行为

禁止扩大到外部依赖或无关格式化。

## 实现任务

1. **F5-A：non-QP positive coverage**

   新测试文件、package include、runner、真实 SRQ/owner queue helper和四个真实
   publish/backing/poll 正例；严格限制为 test/include/runner 变更，允许初跑 GREEN。
2. **F5-B：CQ-flush dual-route RED 与修复**

   missing-secondary publish RED、primary-miss/secondary-hit RED、另两种 partial/miss；
   实现 sibling API、双 found bits、partial candidate 和 poll OR 语义。
3. **F5-C：stale/miss 与 atomic negatives**

   四资源 miss、Function control/fail-closed、target/ID/width 表和 factory-reset smoke；
   本任务只写测试。若 RED 暴露 F5-B 之外的独立生产缺陷，先记录独立 finding，
   再进入单独的 RED→最小修复→scoped review，不在 F5-C 中静默扩大生产修改范围。
4. **F5-D：EQ facade 与收口**

   facade sibling API 与透明传播测试、focused regressions、全文注释/生命周期复审。

每个任务独立实现、独立 scoped review；前一任务存在未解决 Critical/Important 时不得进入
下一任务。

## 验证

所有 VCS 只通过 `ubuntu@10.11.10.53` 的 login bash 运行：

```bash
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_f5_e2e_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_event_route_consume_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_data_engine_device_publish_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_aeqe_route_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_resource_local_lookup_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_aeqe_codec_final_fix_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_codec_test
SSHPASS=123 scripts/run_vcs53.sh core rdma_eq_engine_test
SSHPASS=123 scripts/run_queue_lifecycle_regression53.sh
```

每个 acceptance run 要求 wrapper exit 0、PROCESS PASS、LOGICAL PASS 和严格 UVM
`0/0/0`，并保存 command、host、source/test hashes、log/meta/SHA sidecar。最后运行
本地静态门禁和 `git diff --check`。

## 验收标准

完成时必须同时具备：

- 四个真实 non-QP publish/backing/poll 正例；
- CQ-flush 显式双 caller canonical publish；
- 三种 partial/miss 的正确 handle 结果与 ack；
- 四资源 single-owner miss 与 Function 控制边界；
- target/ID/width pre-reservation 原子拒绝；
- EQ facade 透明 sibling API；
- 所有额外 lifecycle resource 无泄漏；
- focused 与 queue-lifecycle VCS53 严格全绿；
- 每个触及 SV 文件完成全文中文注释、所有权、生命周期、reset/state/error-path 复审。
