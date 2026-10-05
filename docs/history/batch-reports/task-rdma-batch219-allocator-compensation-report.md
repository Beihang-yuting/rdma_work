<!-- 目录：项目根目录；职责：记录 Batch219 allocator 补偿隔离与验证边界。 -->

# Batch219：统一 allocator 预留失败补偿

日期：2026-09-28。工作树：`feature/rdma-cmq-structural-phase2-batch160`。
本批未 commit、merge、push、reset 或 clean；保留全部既有改动，项目级重构仍 active。

## 问题与实现

旧 candidate 失败后无条件递减 local-ID 游标、恢复 prior_serial、删除首次 binding
登记；如果期间另一分配已成功，会使后续资源 lookup 失败或重用其身份。
最初四个交错场景在 VCS53 实际复现 8 UVM_ERROR / 0 FATAL，见
`/tmp/rdma_batch219_allocator_red.log`（wrapper rc=2），不是仅凭静态推断。

普通对象和 Function 现在复用 `rollback_identity_reservation()`：

- reservation_epoch 等于当前且未饱和：恢复本次独占的 cursor/serial；首次 binding
  只有 generation high-water 未变化、未 wrap 时才可移除。
- 有后续 mutation 或 epoch 饱和：只把本次未发布 local ID 放回 free-list，不回退
  cursor/serial，不撤销后来分配共享的 binding，不清 fresh-ID exhausted。
- Function 不参与普通对象 serial；补偿清空 candidate，重复失败不再回收 ID。
- 普通 reservation 删除多余的一次 epoch 推进；在实际消费完成时冻结 epoch，作为
  output 传给 candidate。`rdma_status::success()` 也经过 factory，不能在返回之后
  重采样 epoch，否则会把返回窗口内的重入分配误认成旧预留自己的 epoch。
- prior_serial 移到 binding admission 返回后，与本次选取的 serial 一起采样。

没有增加 owner、账本、锁、生产 observer 或单函数 policy 文件。manager 继续独占
allocator/registry/generation；补偿 helper 内无外部 factory/adapter 调用或 yield。
stale 时保留 binding 是保守的已接纳 authority 缓存，不代表仍有 live resource；在
没有独立 pending 使用者证明的情况下，不能删除它来追求“恢复所有初值”。

## 验证设计

`check_allocator_rollback_isolation()` 覆盖五种后续成功分配：普通同池、普通跨池、
Function→同 owner PD、Function→另一 owner Function、free-list 预留→同池 PD。
断言 successor 可查询、serial 不回退、candidate 清空、补偿 epoch 恰好 +1、返还
ID 只复用一次，且不与存活身份冲突。

`check_allocator_compensation_boundaries()` 覆盖独占恢复、两个 pending 依次失败、
重复已 clear candidate、PD 16-bit/Function 32-bit 最大 ID、epoch 饱和、generation
增长和 wrap。另使用两种真实 factory 重入：Function 默认 binding 构造时嵌套 PD，
普通 reservation 返回 status 时嵌套 PD；均检查存活资源与后续重试。
每个重入场景使用独立 factory，并通过 `uvm_coreservice_t::set_factory()` 恢复原
factory 引用，不用 self-override 或 report catcher 屏蔽 TYPDUP warning。

保留的中间证据：

- `/tmp/rdma_batch219_allocator_green.log`：最初补偿实现通过，但不含全部新增边界。
- `/tmp/rdma_batch219_allocator_final.log`：测试误用 UVM 1.2 不存在的
  `uvm_factory::set()`，编译两个 MFNF 错误、wrapper rc=2；改用 coreservice。
- `/tmp/rdma_batch219_allocator_verified.log`：边界与 binding factory 重入通过；
  尚不含最后的 status-return 冻结用例，不作为最终源码完整证据。
- `/tmp/rdma_batch219_pcie_work.log`：首次 wrapper 未提供 HOST_MEM_ROOT，被 Make
  preflight 拒绝（rc=2），未执行仿真；补齐只读依赖路径后以 verified 日志复跑。

## 验证结果

最终源码 focused 已 PROCESS/LOGICAL PASS，UVM 0/0/0、wrapper rc=0：
`/tmp/rdma_batch219_allocator_frozen.log`。
驱动契约 203 项自测、真实归档、CMQ C oracle 与 field ownership 通过，wrapper rc=0：
`/tmp/rdma_batch219_driver_contract.log`。
integration 10/10、Host-memory 3/3、E2E dual-env 1/1 均 UVM pristine、wrapper rc=0：
`/tmp/rdma_batch219_integration.log`、`/tmp/rdma_batch219_host_mem.log`、
`/tmp/rdma_batch219_e2e.log`。
E2E multivf recovery、高流量及 PCIe adapter 各 1/1 pristine，三个 wrapper rc=0：
`/tmp/rdma_batch219_e2e_multivf.log`、`/tmp/rdma_batch219_e2e_traffic.log`、
`/tmp/rdma_batch219_pcie_work_verified.log`。
CMQ 28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0：
`/tmp/rdma_batch219_cmq.log`。
core 最终源码全量回归 97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0：
`/tmp/rdma_batch219_core.log`。
日志统一为 `/tmp/rdma_batch219_*.log`。
Python 293/293、changed-SV style、diff、queue lifecycle、profile naming、Phase-1A
门禁已通过。src 与 tests/unit 全文件头/逐方法标签扫描：191 文件、5,246 methods、
0 diagnostics；机械标签通过不等于注释语义全部验收。
静态证据：`/tmp/rdma_batch219_python.log`、`/tmp/rdma_batch219_style_final_verified.log`、
`/tmp/rdma_batch219_contract.log`。changed-SV style 的既有 soft-limit 提示保留。
E2E 编译仍有外部依赖既有 FLWI/SV-ANDNMD 警告；UVM pristine 不等于编译零警告。

生产源码 SHA256：`44dc60ea5e917d7997fba5f985d11a4f165346fdfabf8e0f351d391827ee49aa`。
测试源码 SHA256：`5beafeee164bdcf4c571cb4369c4b8892537541e9e29771f0c49ad8129f2a63a`。
上述最终 focused/core/integration/CMQ/E2E/adapter 均在这组源码冻结后启动，收尾时再次
核对指纹一致；未复用 Batch218 的通过结果。两个计划与 coverage matrix 已同步。
manager 当前 10,091 行/186 methods，相比 Batch218 净增 35 行，主要是具体契约与
边界说明；本批收束补偿语义，不把它称为大文件收缩完成。

所有 VCS 使用 53 主机登录 bash 与隔离目录。外部依赖沿用已验证的 pinned 路径：
HOST_MEM_ROOT=`/home/ubuntu/workspace/host_mem.audit.current`、
DPU_COMMON_ROOT=`/home/ubuntu/deps_virtio/dpu_common`、
NET_PACKET_ROOT=`/home/ubuntu/net_packet_latest`、
PCIE_WORK_ROOT=`/home/ubuntu/workspace/pcie_work_audit.POaPmh`；不改外部仓库或 lock。

## 复审与剩余边界

本批复审 manager 文件入口、两种 reservation/publish/rollback、local-ID 消费和
generation 刷新、全部 create caller 的候选生命周期、candidate clear/valid、真实
status/binding factory 来源及新增 fixture；另扫描 src/tests/unit 的完整文件头与
逐方法标签。历史泛化注释和全项目 ownership 的逐项语义验收仍未完成。

下一批首先收束 **reserve admission→binding registration→allocator consume**：
`register_binding_context()` 的 projection/factory 返回窗口尚未具有冻结 epoch/source
提交契约；`local_id_status()` 的成功 status 也经过 factory。这些消费前窗口可能使
早先读取的 serial、has_free_id 或 registration_needed 失效，下一批需先刻画真实重入，
再将可重入准备与无外部调用的短提交分开，不能仅在消费后补一个 guard。
本批只保证可信、未发布 candidate 的失败补偿隔离，不能宣称 allocator admission
全面原子化，也不扩大到跨 owner/跨线程完整互斥。

饱和 epoch 只在本批补偿中保守处理；其它 publication 的饱和策略未整体收口。
SRQ 全业务组合、跨 queue/owner 原子性、Phase-1C F2、legacy/external
ordering/error、包 DAG、大文件职责收缩和历史注释语义审计继续 OPEN。
