<!-- 目录：项目根目录；职责：记录本地主线合并与 Batch222 queue 状态值去重及验证。 -->

# Batch222：本地主线合并与 queue 状态值去重

日期：2026-09-28。用户要求先合并一轮，再继续重构。
主线已合并到 `5f8dfe9`；后续工作位于独立分支
`feature/rdma-structural-batch222`，工作树为 `.worktrees/rdma-structural-batch222`。
本批尚未合回 main，不推送远端。项目重构计划仍 active。

## 本地合并结果

Batch160–221 原有未提交改动按 model、adapter、codec、resource、runtime、queue、
CMQ、lifecycle、reset、projector 分为 10 个源码提交，另有 1 个文档提交：

```text
7e89724  model lifecycle/reset transaction values
49d4036  adapter status normalization
c0be09b  codec SGE authority
d619f64  resource guarded allocation/lifecycle commits
b3c30df  runtime values/policies
eb3ae16  queue data/CQ replay
7fd19b2  CMQ kernel/models/policies
28772b0  lifecycle queue/QP policies
600c529  reset epoch/tokenless
00258d6  resource projector
b443be2  Batch160–221 documentation
```

主线原有 reset/tokenless characterization 单独保存在 `bec0f8f`。四处冲突只涉及
reset coordinator/测试的注释以及覆盖矩阵/历史报告：采用已验证的源码注释，保留
主线新增覆盖记录，并把主线 Batch185 原报告完整保留为标明历史状态的附录。
未使用 reset、clean、stash；未删除既有缓存/日志，旧工作树仍保留。

合并后的 src/tests/scripts/sim/tools 输入（排除 cache/build）与最终 Batch221
快照逐文件 SHA256 一致，清单见 `/tmp/rdma_merge222_feature_inputs.sha256`。
完整回归属于最终快照，不声称每个分组中间提交都已独立仿真验证。
合并前又运行主线 reset focused、feature Python 299/299 及两侧 style/diff：
`/tmp/rdma_merge222_main_reset.log`、`/tmp/rdma_merge222_feature_python.log`、
`/tmp/rdma_merge222_main_style.log`、`/tmp/rdma_merge222_feature_style.log`。

## 本批结构变化与保留边界

仅在既有 `rdma_queue_data_engine` 内复用两种状态字段操作，不新增生产文件、类、
方法、公开 API 或 factory 层：

- `make_engine_status_nonfatal()` 保留一次 raw factory 创建和 null/错型拒绝，
  成功后复用 `set_engine_status_noalloc()` 清空旧诊断并填入 code/message。
- `copy_publish_status_into()` 复用 `copy_status_fields()`，随后按原顺序创建业务
  返回 status；null 仍返回 INVALID_ARGUMENT 和原诊断字符串。它不是无分配接口，
  只有字段 helper 无分配，不得把 wrapper 放入 consumer 的 post-scheduler 窗口。
- helper 均 protected nonvirtual，不引入 clone/do_copy 回调；自复制合法，null
  不写目标，复制保留原 category/code 组合，不重新推导分类。

生产 engine 从 10,896 降到 10,872 行，净减 24 行，仍为 161 methods。
测试净增 200 行，用于冻结行为边界；这是生产重复赋值的真实收缩，不是项目总代码
净减，也不代表 queue-data 的大职责拆分已经完成。
未改变 attachment/runtime/ledger owner、完整 route/epoch admission、门铃/恢复
顺序或外部资源生命周期，没有修改外部依赖仓库及 dependency lock。

## 新增契约测试

沿用 post test 的 probe，在 lifecycle fixture 前运行隔离的状态值测试，再恢复
原 factory 引用。两个仅测试用类记录 hostile clone/do_copy 和 status factory：

- 13 个字段完整复制、目标身份不变、源值不变；特意构造 category 与 code 不一致
  的状态，防止复制偷偷重新分类。null 三组合、自复制均覆盖。
- OK、STALE_GENERATION、未知 code 的完整初始化；除状态文本比较外，直接检查
  hardware_code=0，因为 hardware_code_valid=0 时文本会隐藏硬件码。
- raw 正常、null 和 wrong-type factory 每次恰好调用一次；失败返回 null，无 fallback。
- publish 正常、自复制、null 三组合均保留一次返回 status factory；factory 观察值
  证明完整复制先于返回 status 创建，null 保留目标旧值和原诊断文案。
- 无虚拟 clone/do_copy，无 engine configure/attachment/link 副作用；每条非 fatal
  断言失败也继续走 factory 恢复尾段，并检查恢复后的引用身份。

## 静态核对与回归证据

`/tmp/rdma_batch222_audit.py` 对照合并基线 `5f8dfe9` 读取完整 engine：
159/161 方法 token 不变（包括字符串），全部 161 方法声明不变；另外两个方法
只替换相同的 13 字段赋值。检查实际 helper 为 protected nonvirtual，保留 factory
类型、实例名称、cast/null 分支及复制后的返回路径。日志：
`/tmp/rdma_batch222_audit.log`。

src/tests/unit 全目录文件头及独占中文三段标签扫描为 192 files / 5,256 methods /
0 diagnostics。该结果是词法检查，不等于全项目历史注释语义验收；本次人工复审
聚焦完整 engine 状态 helper、所有调用点、post fixture 生命周期与现有 allocation
guard 测试，不声称重新人工验收全项目每个历史方法。

Python 299/299 两次通过，最终复验：`/tmp/rdma_batch222_python_final.log`；首轮日志
`/tmp/rdma_batch222_python.log` 单独保留。
changed-SV style、diff、queue lifecycle、profile naming、Phase-1A 通过；最终 style
无诊断：`/tmp/rdma_batch222_style_final.log`。
首轮 post focused pristine、wrapper rc=0：`/tmp/rdma_batch222_post.log`；该轮尚未
加入硬件码直接断言和 factory 恢复身份断言，仅作为中间证据。

本批最终 VCS 回归全部通过，wrapper 均 rc=0：

| 验证入口 | 当前结果 | 本地证据日志（`/tmp/`） |
| --- | --- | --- |
| 最终 core 全量 | 97/97 PROCESS、80/80 LOGICAL、97 pristine，wrapper rc=0 | `rdma_batch222_core_final.log` |
| 最终 CMQ gate | 28/28 PROCESS、11/11 LOGICAL、28 pristine，wrapper rc=0 | `rdma_batch222_cmq_final.log` |
| dpu_common integration | 10/10 pristine，wrapper rc=0 | `rdma_batch222_integration.log` |
| Host-memory | 3/3 pristine，wrapper rc=0 | `rdma_batch222_host_mem.log` |
| PCIe adapter | 1/1 pristine，wrapper rc=0 | `rdma_batch222_pcie_work.log` |
| E2E dual-env / 多 VF recovery | 两项 pristine，wrapper rc=0 | `rdma_batch222_e2e.log` / `rdma_batch222_e2e_multivf.log` |
| E2E high traffic | pristine，wrapper rc=0 | `rdma_batch222_e2e_traffic.log` |
| 驱动归档/定义/CMQ C oracle/字段归属 | 203 项自测与真实归档验证通过，wrapper rc=0 | `rdma_batch222_driver_contract.log` |

首轮 core/CMQ 在补强测试直接断言前启动，日志 `rdma_batch222_core.log` /
`rdma_batch222_cmq.log` 单独保留为中间证据；首轮 core 为 97 PROCESS / 80 LOGICAL
PASS、97 pristine，CMQ 为 28 PROCESS / 11 LOGICAL PASS、28 pristine，wrapper 均 rc=0。
最终 core/CMQ 使用上述 final 日志，不把
重复运行累加为额外覆盖。其余集成/adapter/E2E 均在最终源码/测试冻结后启动。

最终 core 包含 post、device publish、poll、recovery、event route/AEQE 等用例；
原有 post-scheduler allocation guard 与新状态值断言均通过。汇总脚本逐项检查
PROCESS/LOGICAL/pristine 数量及非零 UVM severity，结果见
`/tmp/rdma_batch222_verification_summary.log`；脚本为
`/tmp/rdma_batch222_verify_logs.sh`。最终提交前再次检查源码指纹未变。

E2E 编译保留 4 个既有警告：本项目 net adapter 的 2 个 FLWI，以及外部 net_packet
IPv6 扩展的 2 个 SV-ANDNMD。UVM pristine 不代表编译零警告；不为消警告修改外部库。

所有仿真经 `scripts/run_vcs53.sh` 在 ubuntu@10.11.10.53 的登录 bash 执行。
外部依赖只读使用：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

最终源码/测试输入 SHA256：

```text
93d1580753343eea18bb63fbf9b4b10660670ec5e5435372062e4c7ef6d3ec3c  src/core/rdma_queue_data_engine.sv
5d20b56c63e6f082313d4f63b8ffbd4cc6a4a8460bcfa3c11c959567104d594d  tests/unit/rdma_queue_data_engine_post_test.sv
```

## 未关闭项

queue-data producer/consumer 大职责拆分、manager publication 后更新、跨 owner
原子性、SRQ 完整业务组合、Phase-1C F2、legacy/external ordering/error、包 DAG、
其它 epoch 饱和策略和全项目注释语义审计继续 OPEN。下一批应继续按事务职责集中
收束重复流程，不能把新增单函数 policy 文件或本批局部去重当作目标架构验收。
