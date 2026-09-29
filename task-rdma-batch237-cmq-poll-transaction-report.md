# Batch237：CMQ 完成事务按业务阶段组织

日期：2026-09-29；基线：`837afbc`；分支：`feature/rdma-structural-batch226`。
本批不合并、不推送；main 保持 `083e0d7`，已有缓存与外部依赖不改。

## 改动与取舍

CMQ 完成路径原来在一个 drain 循环内同时读取 CQ、解码、匹配命令、校验 token、
预验回收前缀并提交完成。现在 engine 内按以下业务顺序组织，不新增组件或 owner：

```text
poll_locked：准入 → read_polled_cqe_locked → match_polled_cqe_locked
            → commit_polled_completion_locked → consume/retire
```

- 读取阶段负责 ring owner、精确 64B Host-memory read、原始快照和 profile 解码。
  仍先检查 raw input 未被 profile 改写，再检查 inspect status。未就绪返回 OK；
  null/codec/unsupported 检查失败沿原 poison 路径，其它错误保留原复制规则。
- 匹配阶段保留 entry/slot/ticket、decoded status/opcode、counter、registry、token
  incarnation、prospective retirement 的顺序。正常/晚到只保留不同的 registry
  规则和诊断文本，共用 token 校验。
- 候选是已有 transaction-model 文件中的四字段普通 struct，仅携带锁内已认证的
  slot 非拥有引用、software key、token 和 prospective retire cursor。无 factory、
  持久缓存、第二 journal 或跨 reset 生命周期。
- 提交阶段共用 completion 构造及 journal transition；late 在原分支点冻结，
  late diagnostic 仍先于 completion 构造。journal 成功后才发布对应 FIFO、删除
  普通 command registry、释放 token、更新 slot，最后由 drain 推进游标。
- 读取与匹配以显式布尔成功证据放行，不在失败返回后仅凭 status.ok() 推测是否
  可以提交。这样保留原控制流，也不增加成功 status factory 回调。

`poll_locked` 方法 **261→50 行**；engine **13,785→13,816 行**，transaction models
**502→512 行**；生产总量 **净增 41 行**。受影响方法 tokens **1,636→1,693**
（不含新 struct）。这是业务主流程可读性整理，不声称整体代码量收缩。
正常/晚到 completion 构造、journal helper 调用和 token 校验各由两份变成一份；
保留文件内 210 个原声明及 engine 实例字段；其中 31 个非 protected 声明包含
30 个 engine 方法（含构造）和 1 个 observer 回调。新增两个同类 protected 阶段。

## 对照与复审

新增独立 `rdma_cmq_poll_transaction_test`，只复用既有 fixture/断言，不运行父矩阵。
普通/晚到 × 首圈/第二圈 × 后项成功/owner 未就绪/inspect INVALID_STATE/inspect
CODEC_ERROR，共 **16 个流程用例**：

- 先完成 SQ 后项，再处理前项，检查部分 drain 的 completion/diagnostic 顺序、
  journal state/phase、command/token/entry 数量和 consume/retire 游标。
- 第二圈通过公开接口真正提交并完成 32 条命令，验证 owner/wrap，不 seed counter。
- 未就绪与普通 inspect 错误修复后只能交付剩余前项，并一次回收连续前缀。
- codec 错误检查 poison 诊断，同时保留已经完成的后项。late 先走真实 timeout，
  晚到只产生诊断，不二次作为普通 terminal completion 交付。10us watchdog 防挂死。

该专项先在未改生产的 `837afbc` 通过，再验证重构版；测试输入未随生产改动调整。
六项新 Python 门禁固定阶段顺序、显式 readiness、匹配顺序、共享提交、候选生命周期
和唯一注册。原 manifest 门禁从两个 journal caller 更新为一个，仍要求共享 seam，
没有通过删除断言绕过约束。

固定基线审计逐 token 对照 admission、read/inspect、匹配前缀、prospective retirement
及 commit/retire 尾段；正常/晚到 registry/token 规则分别对照；把冻结的 late 策略
展开后，两条 completion 路径的条件、诊断、factory/journal/FIFO/token 顺序均相同。
另 208 个 engine 方法正文不变，200 个其它既有 src/tests-unit SV 文件字节不变。

从文件头和 owner/lock 字段复核上下文，沿完成路径复核 raw image、status contract、
ticket/payload snapshot、expiry/quarantine、poison、retirement、retained-journal
staging/commit 及公开 poll/wait/reset 的调用边界。修正了四处旧注释中把 status
校验描述为 wire 解码、遗漏 raw snapshot 交付及虚称回收函数额外检查锁/epoch 的内容。
目录契约扫描为 **203 SV files / 5,376 methods / 零 diagnostics**；该扫描和本批
局部语义复审不代表全目录注释语义、并发与最终可读性已经验收。

## 验证状态

全部验证完成；各 wrapper 真实退出码为 0，最终输入哈希一致。

| 验证项 | 最终结果 |
| --- | --- |
| 旧版基线 / 重构版专项 | 各 1 PROCESS / 1 LOGICAL，16 个对照用例完成标记齐全 |
| core | 106 PROCESS / 89 LOGICAL，106 份 pristine 报告；新矩阵与既有十二组标记齐全 |
| CMQ | 28 PROCESS / 11 LOGICAL，28 份 pristine 报告 |
| integration / Host-memory / PCIe | 10 / 3 / 1，全通过 |
| 双环境 / 多 VF / 高流量 E2E | 各 1，全通过 |
| Python | 383/383，包含新增六项结构门禁 |
| 驱动契约 | 203 tests、definitions、C oracle、1,088 项字段归属检查全通过 |
| 静态复审 | style（含暂存文件）、lifecycle/profile/Phase-1A、固定基线/目录契约、diff 全通过 |

所有 suite 的 UVM WARNING/ERROR/FATAL 均为零。三组 E2E 各有 4 条既有编译告警
（2 FLWI、2 外部 net_packet SV-ANDNMD），其它 suite 编译告警为零；未修改外部依赖。
core 较 Batch236 增加一个独立专项，因此 105/88→106/89，不把注册增长称为旧用例
覆盖扩大。首次 core/CMQ 完整回归也通过；最终采用注释复审后的 reviewed 组。

所有 VCS 均由 `scripts/run_vcs53.sh` 在 `ubuntu@10.11.10.53` 登录 bash 执行，
使用原锁定依赖：

```text
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest
PCIE_WORK_ROOT=/home/ubuntu/workspace/pcie_work_audit.POaPmh
```

本机证据前缀 `/tmp/rdma_batch237_`；`baseline.log` 为旧版，`focused.log` 为阶段
拆分首版，`focused_final.log` 为显式放行的实现，`core.log`/`cmq.log` 为首次完整
回归。随后只改上述文件头/四处旧注释，又用最终字节重跑 `core_reviewed.log` 和
`cmq_reviewed.log`，以 reviewed 组作为最终 core/CMQ 证据。
其余 suite 为 `integration.log`、`host_mem.log`、`pcie_work.log`、`driver_contract.log`、
`e2e.log`、`e2e_multivf.log`、`e2e_traffic.log`；真实退出码在 `group_*.log`。
旧版送测哈希在 `baseline_inputs.sha256`，注释复审后的最终输入在
`reviewed_inputs.sha256`；审计脚本/结果为 `audit.py`/`audit.log`，最终日志核验为
`verify_logs.sh`/`verification_summary.log`。Python 最终日志为 `python_final.log`，
暂存后 style 日志为 `style_staged.log`；两者均通过。

## 尚未关闭

本批只完成 CMQ 完成路径整理。observed submit/recovery/reset 的整体编排、CMQ
文件规模与 protected 兼容层、queue-data/resource/lifecycle 更广泛结构、跨组件
并发、SRQ 完整组合、SQD/SQE drain/flush、外部 ordering/error/backpressure、
Phase-1C F2 whole-plan 和最终 ownership 审计仍 OPEN；两个项目计划保持 active。
