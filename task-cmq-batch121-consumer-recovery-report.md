# CMQ Batch 121：consumer recovery task 提取

本批继续基于已经完成 producer/device-producer recovery 提取的 queue-data engine，收敛
`replay_pending()` 中 consumer recovery 的职责边界。改动只搬移既有 CQ 路由、shadow/
doorbell、cursor commit、WQ release 和 completion 阶段，不改变 runtime ledger、pending
evidence、外部 backing 或 attachment 的所有权。

## 实现边界

- `src/core/rdma_queue_data_engine.sv`
  - 新增受保护的 `replay_consumer_pending()` task，接收 caller 已验证的
    `attachment`、`pending` 和 `next` cursor，承接原 consumer 分支的完整流程：CQ
    route/QP/SRQ identity 校验、completion target lookup、CQC shadow 或 consumer
    doorbell continuation、CQ consumer commit、CQ→WQ release gate 以及 completion。
  - `replay_pending()` 现在只负责 attachment/pending null 校验、
    `pending_next_cursor()` 和 producer/device-producer/consumer 分派；device-producer
    与 host-producer 继续分别进入既有 helper。caller 仍是唯一的 cursor-admission
    owner，consumer helper 不重新计算或 reserve cursor。
  - consumer helper 只持有 attachment、runtime、QP/SRQ link、scheduler 和 backing 的
    借用引用；不取得或释放 attachment、QP、SRQ、Host-memory mapping 或 pending 的
    生命周期所有权。

## 行为不变量与失败边界

- `pending_next_cursor()` 仍先于所有 branch dispatch 执行；attachment、pending 或
  `next` 为 null 时返回 `RDMA_SC_INVALID_STATE`，不查询 route、shadow/doorbell、
  release 或 completion。
- CQ route、QP identity、SRQ presence、completion target、route/epoch 和 WQ attachment
  的校验顺序保持不变；任何 null、identity mismatch、stale generation 或非成功
  status 都立即返回并保留 pending/recovery evidence。
- `consumer_shadow_required` 仍只在尚未发布 shadow 时访问 context backing；已发布
  shadow 复用 pending 的 continuation status，不重复触碰 Host-memory。legacy consumer
  doorbell 仍沿用原 scheduler、readback 和 evidence 语义。
- CQ consumer commit 成功后才进入 CQ→WQ release gate；release 或 completion 失败时
  保留原错误 evidence，release marker 防止同一 WQE range 被重复释放。helper 不把
  `AMBIGUOUS` 或不安全 MMIO evidence 转换成可重放成功。
- 去除 caller 中不再使用的 `local_status`，没有改变任何业务语句；对旧 consumer
  分支去除注释/空白后，helper body 与原路径保持 282 行语句级一致。

## 验证

所有 VCS 仿真均通过 `ubuntu@10.11.10.53` 的登录 bash 环境执行，入口为
`SSHPASS=123 scripts/run_vcs53.sh core <test>`。每项均满足 wrapper rc=0、PROCESS PASS、
LOGICAL PASS，且 UVM warning/error/fatal 为 `0/0/0`。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_device_publish_test` | PASS；device publish、reservation/recovery evidence 与 consumer-adjacent fault 场景通过 |
| `rdma_queue_data_engine_recovery_test` | PASS；producer/device/consumer recovery、CQ release 与 completion evidence 通过 |
| `rdma_queue_data_engine_post_test` | PASS；post、RQ/SRQ、CQ completion 与 recovery 交界回归通过 |
| `git diff --check` | PASS |
| `python3 tools/check_changed_sv_style.py --base HEAD` | PASS |
| `python3 tools/check_queue_lifecycle.py` | PASS |
| `python3 tools/check_rdma_profile_names.py` | PASS |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_cmq_gate_manifest` | 22 tests；OK |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.unit.test_sv_keyword_guards` | 3 tests；OK |
| `python3 tools/check_rdma_phase1a_approval.py` | PASS；全部 approval 保持 APPROVED |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/unit -p 'test_*.py'` | 292 tests；OK；synthetic git/CLI negative-path stderr 为预期输出 |
| 逐文件中文 method/comment 复审 | `rdma_queue_data_engine.sv` 139 个 function/task、`rdma_queue_data_engine_device_publish_test.sv` 122 个 function/task；均 0 diagnostics，均从文件头复审至 EOF |
| 当前源码全目录 scanner | 185 个 `.sv`、2 个 `.svh`，共 5,405 个 function/task（`.sv` 5,403、`.svh` 2）、0 diagnostics；逐文件检查文件头与三段中文 method comments |

pytest 因环境缺少 pytest 未执行，不记为业务失败或 GREEN。`pcie_work` 仍按既有边界
保持唯一阻断文本：`external dependency is not approved: pcie_work`。

## 源码指纹

以下哈希对应本报告所描述的 Batch121 source/test 字节；后续文档修改不会改变这两个
文件的指纹。

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `7f8412a5d80106663c45ace15336357cd05a775495557ea9313343d16768c881` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `5ee2e400a4ee3eec3d58eefaf97aed5cb1f386cd145cf591f9d8546c56e078a0` |

相对 Batch120 提交，本批只修改 source，diff 为 78/55（新增/删除）行；新增内容主要
是 consumer helper 的契约注释、参数和 caller 分派，删除内容是同一 consumer 分支从
caller 搬移后的重复局部变量/注释，不把行数变化宣称为完整 recovery 复杂度收口。

## 遗留并发与范围风险

- `query_pending()`、route/epoch 查询、release 和 completion 之间仍没有 engine-level
  全局并发锁；跨队列或同一 attachment 的并发 recovery 仍需后续契约。
- consumer helper 与 caller 的 cursor admission 已分开，但 query/recover 的窄窗口、
  CQ route 与 WQ release 的跨对象锁序仍依赖现有 runtime seam，未宣称原子事务。
- SRQ 全量 post/recovery lifecycle、跨队列并发、device/consumer recovery 的组合 fault
  矩阵、Phase 1C F2、coordinator 跨线程/跨进程锁、manager 外部调用窗口补偿和
  `pcie_work` 外部依赖锁仍 OPEN。

## Full-file review

提交前已从文件头到 EOF 复审 `src/core/rdma_queue_data_engine.sv`，重点核对 helper 与
caller 的参数/局部变量生命周期、CQ route 与 completion authority、shadow/doorbell 与
commit/release 顺序、失败 evidence、复位边界、中文三段函数注释和稀疏排版；未发现需要
扩大到外部依赖或修改既有 ownership 契约的问题。
