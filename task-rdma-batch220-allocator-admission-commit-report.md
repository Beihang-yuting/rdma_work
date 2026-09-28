<!-- 目录：项目根目录；职责：记录 Batch220 allocator admission/registration 提交与验证边界。 -->

# Batch220：统一 allocator admission 提交

日期：2026-09-28。工作树：`feature/rdma-cmq-structural-phase2-batch160`。
保留全部既有改动；本批未 commit、merge、push、reset 或 clean，项目级重构仍 active。

## 实现与边界

Batch219 保护已经消费 ID 的旧 reservation 补偿。本批处理更早的窗口：binding
admission、local-ID status 和 registration projection 都可能通过 factory 同步重入；
原路径可能使用旧 serial/has_free_id，并先登记 binding，再跨回调消费 ID。

`register_binding_context()` 被 `commit_identity_reservation()` 替代，普通资源和
Function 复用同一提交路径：

1. caller 在首次 binding/schema 外部调用前冻结 admission epoch，保留原有 kind、
   serial、local-ID、重复 Function、旧代际资源和 tombstone 的检查顺序。
2. 首次 binding 的 detached 投影在锁外完成，不写 registration。
3. 使用既有 mutation_guard 复核 epoch、registration presence/source、当前代际、
   high-water、wrap 与 retirement，再一起登记 binding、消费 ID/serial、推进 epoch。
4. commit 返回 `make_direct()` 状态，不在 guard 内或消费后的返回路径插入 status
   factory；reservation_epoch 与 prior_serial 由实际消费点输出。

准备失败不再依赖“先登记、失败再删”的补偿。已成功预留后的 publication 失败仍使用
Batch219 补偿，不新增 ledger、锁、owner、生产 observer 或 policy 文件。
generation high-water 的单调观察保留，不因 admission 失败倒退。

明确的安全边界调整：admission epoch 已饱和时返回 INVALID_STATE，不再接纳无法区分
新旧的 reservation；最后一次从最大值减一推进到饱和的预留仍可补偿，保留 Batch219
的非独占补偿语义。这不代表其它 publication 的饱和策略已经全部收口。

同步修正文件头关于 guard 不保护 allocator 的过时说明，以及 constructor、
local-ID capacity/consume、generation refresh 和两种 reservation 的中文具体契约。
manager 当前 10,150 行/186 methods，相比 Batch219 净增 59 行；本批收束提交责任与
安全边界，不把增加门禁或注释称为大文件收缩完成。

## 测试设计与中间结果

新增 `check_allocator_admission_windows()`：fresh PD、free-list PD、另一 owner
Function、同身份不同 binding source 四种 fixture。先计数消费前的真实 status factory
窗口，再逐个窗口嵌套成功分配；最后窗口另注入 guard busy、epoch 更新和 generation
变化。检查外层拒绝且不改 ID/serial/free-list/epoch/registry/binding 数量、内层资源
可查询、失败后可重试。factory 按引用完整恢复，注入前清 target 防止递归。

保留所有失败证据：

- 初始 RED 的三个场景有 34/31/35 个真实窗口，产生 267 UVM_ERROR、0 WARNING/FATAL，
  wrapper rc=2：`/tmp/rdma_batch220_admission_red.log`。
- 初轮修复 `/tmp/rdma_batch220_admission_green.log` 的逐窗失败隔离通过，但两个
  generation 重试 fixture 未同步 identity/mirror，产生 2 UVM_ERROR、wrapper rc=2。
- 增加竞争 source 后的 `/tmp/rdma_batch220_admission_final.log` 同类 fixture 错误
  共 3 个，wrapper rc=2；最终测试在重试前显式同步 identity 和 owner_h。
- 首次 core `/tmp/rdma_batch220_core.log` 同样使用上述未修正 fixture；不作为通过证据。

## 最终验证

最终 focused PROCESS/LOGICAL PASS，UVM 0/0/0、wrapper rc=0：
`/tmp/rdma_batch220_admission_verified.log`。四种 fixture 分别观测 33/31/34/33 个真实
窗口，共 131 次逐窗嵌套分配，另有 12 次 guard/epoch/generation 故障和 4 次成功基线。
integration 10/10 pristine，wrapper rc=0：`/tmp/rdma_batch220_integration.log`。
驱动契约 203 项自测、真实归档、CMQ C oracle 和 field ownership 通过，wrapper rc=0：
`/tmp/rdma_batch220_driver_contract.log`。
CMQ 28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0：
`/tmp/rdma_batch220_cmq.log`。
E2E dual-env、多 VF recovery、高流量三项均 pristine、wrapper rc=0：
`/tmp/rdma_batch220_e2e.log`、`/tmp/rdma_batch220_e2e_multivf.log`、
`/tmp/rdma_batch220_e2e_traffic.log`。
Host-memory 3/3、PCIe adapter 1/1 pristine，两个 wrapper rc=0：
`/tmp/rdma_batch220_host_mem.log`、`/tmp/rdma_batch220_pcie_work.log`。
core 最终复跑 97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0：
`/tmp/rdma_batch220_core_final.log`。
Python 最终复跑 293/293、changed-SV style、diff、queue lifecycle、profile naming 与
Phase-1A 全部通过，证据为 `/tmp/rdma_batch220_python_verified.log`、
`/tmp/rdma_batch220_style_verified.log`；既有 style soft-limit 提示不等价于可读性验收。
src/tests/unit 全文件头与逐方法标签扫描：191 文件、5,249 methods、0 diagnostics；
机械 GREEN 不能替代全项目注释语义复审，见 `/tmp/rdma_batch220_contract_verified.log`。

最终生产 SHA256：`d2bce7a04eb2d1696dbe8835d688ceb04374b3fb6ea3324c80dd88c4b74a4cc1`。
最终测试 SHA256：`2a8957fd0e0c7309ce0223e3c549ff4139803c2204b34d79977e50c28e92ed11`。
收尾再次核对两份指纹一致，两个计划与 coverage matrix 已同步更新。
focused-verified/core-final 在这组指纹冻结后启动。早启动的 integration/CMQ/dual-env
生产逻辑相同，但仍使用注释收尾前的生产文件、generation 重试修正前的单测；它们
不承担新增 resource-manager 单测最终覆盖的证明，不复用 Batch219 的测试结果。
E2E 编译仍有外部依赖既有 FLWI/SV-ANDNMD 警告；UVM pristine 不等于编译零警告。

所有 VCS 通过 run_vcs53 在 53 主机登录 bash 执行。只读外部依赖继续使用：
HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`。未修改外部仓库或 lock。

## 复审与剩余工作

复审了 manager 文件入口、两种 admission/commit/publish/rollback、ID/serial/代际
写入来源及全部 create caller，检查 guard 内没有 factory/adapter/clone、失败释放锁、
先准备后写入与候选 clear/补偿边界；测试复审覆盖逐窗计数、fixture 生命周期和 factory
恢复。全目录文件头/逐方法标签扫描不能代表历史泛化注释的语义验收已完成。

本批只关闭 allocator admission 到 reservation commit 的同步重入窗口，不宣称整个
resource 生命周期跨 owner 原子化。后续优先把 manager 中大量 detached projector 的
职责与事务写入分开，并复审 QP sequence 等 publication 后的状态更新；不能继续以
零散单函数 policy 文件代替大文件职责收缩。
只读方法扫描发现 33 个 `project_*` 共 1,495 行函数体，其 manager 内部调用闭包共
48 methods / 1,986 行函数体，均未直接命中 allocator/registry/generation/recovery
账本字段。它们仍调用 mapping authority、clone/factory 和比较器；这只是后续提取
候选范围，不是纯值性或 ownership 的完整证明。下一批须复审这些外部边界，并保留
manager 的入口快照与 commit 检查，不把可变 owner 一起迁入 projector。
跨 queue/owner 原子性、SRQ 完整业务组合、Phase-1C F2、legacy/external
ordering/error、包 DAG、其它 epoch 饱和策略及全项目注释语义审计继续 OPEN。
