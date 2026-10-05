# CMQ Batch 133：CQE variant/SRFQ topology 一致性 gate

本批基于 `feature/rdma-cmq-contract-foundation` 的重构后 queue-data engine，收束
CQE publish/poll 对同一条 QP route 的 overlay authority。基线为 `00b8ff6`
（`test: add shared SRQ CQE poll evidence`）；本报告中的“未修改外部依赖”只表示
Batch133 实现未写入外部仓库源码。2026-09-22 已按用户指定的 pcie_work 上游快照更新
本项目 `external_dependencies.tsv`，该后续接入证据见
`docs/rdma-pcie-work-adoption-evidence.md`；计划状态仍为 `active`。

## 实现边界

- `src/core/rdma_queue_data_engine.sv` 新增三个只读 admission helper：
  `resolve_cqe_variant_for_route()` 只接受 RC/UD/URC transport，并按 receive、UD
  send、RC/URC send 选择 `RQ_SRFQ`、`UD`、`RC`；
  `validate_cqe_srfq_route_consistency()` 要求 send CQE 的 `srfq=0`，并要求 receive
  CQE 的 `srfq` 与冻结 `link.srq_h != null` 一致；
  `validate_cqe_variant_consistency()` 比较显式 `model.variant` 与上述 authority。
  X/Z 标志、非法 transport、错误 handle kind 和 SRFQ 拓扑漂移均 fail-closed。
- variant authority 来自 `qp_links` 中冻结的 `rdma_queue_data_qp_link.transport`，
  不从 CQ attachment transport 猜测物理 union。这样同一 CQ 上交错的 RC、UD、URC
  QP 不会共享可变的 codec `active_variant`。
- `publish_cqe()` 在 WQE attachment lookup 与 producer reservation 之前调用
  `validate_cqe_variant_consistency()`；失败时不 lookup WQE、不 reserve、不编码、不写 CQ backing，
  `result` 保持 null。`resolve_cqe_variant_for_image()` 在 poll decode 前复用同一
  route/SRFQ gate，随后才选择 CQE variable codec。
- poll 的 gate 只读 route、image 和 topology，不建立 pending、不推进 cursor、不写
  Host-memory/MMIO；首次 runtime mutation 仍由既有
  `commit_cq_poll_candidate()` 顺序负责。SRFQ receive 的 WQE ledger 继续由 shared
  SRQ attachment 拥有，private RQ 不被误释放。
- 双环境 fixture 显式启用 CQC context shadow，并将 `contexts` 传给 composition
  `bind_data_path()`；这保持公开 CQ poll 契约的唯一 consumer-CI authority。

## 测试证据

### publish/poll hostile 与正向路径

- `rdma_queue_data_engine_device_publish_test` 增加 RC/UD/RQ_SRFQ variant mismatch、
  send-SRFQ 和 private-RQ topology mismatch。每个 case 都比较 CQ bytes、producer/
  consumer cursor、occupancy 和 result，确认 reservation 前原子拒绝；shared-SRQ
  topology hostile 则在下述真实 shared-SRQ poll fixture 中验证。
- `rdma_queue_data_engine_poll_test` 在真实 `post_recv(target_h=SRQ,
  completion_qp_h=QP)`→`publish_cqe(rq_cqe=1,srfq=1)`→`poll_cqe` route 上：
  1. 先发布相反 SRFQ 的 model，确认 publish-side topology gate 拒绝且 SRQ/CQ
     occupancy/cursor 不变；
  2. 发布合法 CQE 后，test-only `rdma_queue_data_engine_probe` 只改写已提交槽位
     qword0 bit[58]，绕过 publish gate，确认 poll-side image gate 返回
     `RDMA_SC_INVALID_ARGUMENT`，SRQ/CQ occupancy、producer/consumer cursor 和 result
     全部不变；恢复原 bit 后继续合法 poll，并确认 `RQ_SRFQ` overlay、`local_srq_id`
     SRFQN、SRQ ledger release、private RQ 不变。
- probe 仅通过 `write_device()` 以 detached 8-byte buffer 回写已提交 slot，不 reserve/commit runtime，
  不取得 CQ/backing 所有权；恢复失败会显式报告，避免 hostile image 泄漏到 cleanup。
- 所有进入 queue-data publish 路径的 direct CQE builder 显式设置 `srfq`/`variant`，覆盖
  dual-env、host-memory、CQ facade、multi-VF recovery 和 queue-data focused fixture；
  纯 codec profile fixture 不进入该 admission 路径，仍可独立验证默认/显式 profile。

## VCS53 验证

所有仿真均通过 `ubuntu@10.11.10.53` 登录 bash 的
`SSHPASS=123 scripts/run_vcs53.sh` 执行。

| 入口 | 结果 |
| --- | --- |
| `rdma_queue_data_engine_poll_test` | exit 0；PROCESS PASS、LOGICAL PASS；UVM_INFO 3、WARNING/ERROR/FATAL 0 |
| `rdma_queue_data_engine_device_publish_test` | exit 0；PROCESS PASS、LOGICAL PASS；UVM_INFO 220、WARNING/ERROR/FATAL 0 |
| `rdma_queue_data_engine_post_test` | exit 0；PROCESS PASS、LOGICAL PASS；UVM_INFO 3、WARNING/ERROR/FATAL 0 |
| `rdma_queue_data_engine_recovery_test` | exit 0；PROCESS PASS、LOGICAL PASS；UVM_INFO 3、WARNING/ERROR/FATAL 0 |

锁定依赖后重新运行 transport E2E：

```bash
DPU_COMMON_ROOT=/home/ubuntu/deps_virtio/dpu_common \
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem \
NET_PACKET_ROOT=/home/ubuntu/net_packet_latest \
SSHPASS=123 scripts/run_vcs53.sh e2e rdma_end_to_end_transport_test
```

结果为 exit 0，UVM_INFO 32、WARNING 0、ERROR 0、FATAL 0；4 次 host-memory leak
check 均为 0。RC/UD/URC 正向矩阵通过。URC RDMA_READ 在核心 queue semantic 层保留
允许，随后由 net_packet wire-capability 层返回 `RDMA_SC_UNSUPPORTED_OPCODE`；测试
确认 `send_sequence` 只增加一次尝试计数，`sink.sent_count` 和 `last_sent_packet`
不变，没有发布半包。依赖编译器的既有参数名提示不影响 UVM pristine 结果。

## 静态门禁

- `git diff --check`（含无参数与 `HEAD`）通过。
- `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_changed_sv_style.py --base HEAD` 通过，
  hard diagnostics 为 0。
- 全目录中文文件头/function/task 三段契约 scanner：185 个 `.sv`、2 个 `.svh`，
  共 5,431 methods（`.sv` 5,429、`.svh` 2），0 diagnostics。
- `python3 -m unittest discover -s tests/unit -p 'test_*.py'`：292/292，`OK`；
  queue lifecycle 15/15、profile naming 103/103、CMQ manifest 22/22、SV keyword
  guards 3/3、Phase-1A approval 15/15，field-ownership 61/61，均通过。
- Batch133 记录时尚未运行真实 `pcie_work` integration；随后已在本项目依赖锁中固定并批准
  pcie_work/host_mem 快照，且 adapter/SR-IOV focused 已在 53 机通过。该后续证据不等同于
  完整外部 regression，详见 `docs/rdma-pcie-work-adoption-evidence.md`。

## 开放边界

本批只关闭 publish/poll 共用 variant/SRFQ authority 的局部 admission seam，不宣称
以下范围完成：

- private-RQ poll-side hostile、UD receive/replay、legacy descriptor branch；
- 全量 malformed CQE matrix、poll/recovery 组合、device/consumer recovery 组合；
- CQ→WQ 跨队列并发、engine-level 全局锁、query/recover 窄窗口并发；
- SRQ 全量公开 post/recovery lifecycle、snapshot 后 alias 与最终 ownership 审计；
- 更广泛的 coordinator 生命周期/跨线程跨进程并发，以及广义 Phase-1C F2。

历史阻断文本 `external dependency is not approved: pcie_work` 仅适用于本批最初记录时点；
当前依赖锁已批准 pcie_work 闭包，但完整 regression、上游 provenance（root README/LICENSE/tag）
和更广泛 PCIe error/ordering matrix 仍开放。

## 最终源码 SHA-256

以下哈希对应本报告所述最终源码边界；报告自身不列入表格，避免自引用。

| 文件 | SHA-256 |
| --- | --- |
| `src/core/rdma_queue_data_engine.sv` | `e7360519018d33c44c784a3b6e79e15b18f5475fb4f5141ec9a74ab873f37681` |
| `tests/unit/rdma_queue_data_engine_poll_test.sv` | `b8640cb4e901c70cc999016112b1f2c14ee540c29053f5a711ec623cf7b930a7` |
| `tests/unit/rdma_queue_data_engine_device_publish_test.sv` | `a68c332011425445b669c9819c534491ccda90f01837ce3c42882286088d6d21` |
| `tests/unit/rdma_queue_data_engine_post_test.sv` | `55915fa96bf5c37bd3a9ab7132167a1800b189abc3d091ee66d034e480ff9ba6` |
| `tests/unit/rdma_queue_data_engine_recovery_test.sv` | `548ef95ecb5b5100e44eb4734b8a47ce16bfbe1afb0b404bb1aa207a7730c660` |
| `tests/unit/rdma_cq_engine_test.sv` | `5a03681b856f87e8c215f1c46fcdbd89dc0d81d2059cef060119d37c12bcec31` |
| `tests/integration/rdma_end_to_end_dual_env_test.sv` | `c202dee49b5783a92b7fd327b781dd345d3916fffadfd4aa1edc168c4775eb9c` |
| `tests/integration/rdma_end_to_end_transport_test.sv` | `25185244a83ee055648e711a1a3175cd14f41c79e142829a623e50cca106a7e9` |
| `tests/integration/rdma_multivf_recovery_test.sv` | `5347123c7ab3197d6ccb74009a1822c527e0103ebbe7ac7212df4fdf133ce018` |
| `tests/integration/rdma_queue_data_engine_host_mem_test.sv` | `f5ac6623448c0b5e9c80f3d81c281600f8ee401194399052440a49a53e91cbea` |
| `docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md` | `3824e65e60441a866f5bb727a0c18b4ba7ab6fb38362a0f3289051580fa8bc90` |
| `docs/rdma-structural-refactor-coverage-matrix.md` | `e1517c12426d8fb4dd4a1e0947942b9a91a16f0b6e0eb08682a288ceaaf63a81` |
