# Batch147：host-producer hostile failure matrix

## 目标

本批次收缩 `post_send()` 的 WQE write/readback/producer-doorbell 失败边界，补齐
此前只覆盖 doorbell codec lookup、而未覆盖真实 Host-memory/PCIe adapter 返回错误的
测试缺口。范围限定在测试契约，不修改 reservation admission 或生产实现。

## 改动

- `tests/unit/rdma_queue_data_engine_final_fix_test.sv`
  - 新增 `run_host_producer_hostile_matrix()`，用独立 fixture 覆盖六个 case：
    `Host-memory write`、`Host-memory read`、readback byte mismatch、DMA visibility
    barrier、MMIO ordering barrier、MMIO write。
  - 新增 concrete UVM test
    `rdma_queue_host_producer_failure_final_fix_test`。
  - 每个 case 断言返回错误码与 `result=null`，SQ PI/CI/wrap、used 保持原值，
    pending 是 producer-owned 且携带 image/cursor；write/readback case 的
    `mmio_evidence=NO_SUBMIT`，doorbell case 的 evidence 为 `AMBIGUOUS`。
  - 同时核对 Host-memory write/read 和 PCIe DMA-barrier/MMIO-barrier/MMIO-write
    调用前缀，随后只通过公开 `RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH` 清理。
- `scripts/run_queue_lifecycle_regression53.sh`
  - 将新 concrete test 加入 `CORE_TESTS`，使 `--list`/回归实际执行该矩阵。

## 阶段契约

| 注入阶段 | 预期返回 | Host-memory 调用 | PCIe 调用前缀 | recovery evidence |
| --- | --- | --- | --- | --- |
| WQE write | `RDMA_SC_DMA_TRANSLATION` | write=1, read=0 | 无 | `NO_SUBMIT` |
| WQE readback error | `RDMA_SC_DMA_TRANSLATION` | write=1, read=1 | 无 | `NO_SUBMIT` |
| WQE readback mismatch | `RDMA_SC_DMA_TRANSLATION` | write=1, read=1 | 无 | `NO_SUBMIT` |
| DMA visibility barrier | `RDMA_SC_PCIE_COMPLETION` | write=1, read=1 | DMA barrier=1 | `AMBIGUOUS` |
| MMIO ordering barrier | `RDMA_SC_PCIE_COMPLETION` | write=1, read=1 | DMA=1, MMIO barrier=1 | `AMBIGUOUS` |
| MMIO write | `RDMA_SC_PCIE_COMPLETION` | write=1, read=1 | DMA=1, MMIO barrier=1, write=1 | `AMBIGUOUS` |

## 验证

在 `ubuntu@10.11.10.53` 登录 bash 环境执行：

```text
SSHPASS=123 scripts/run_vcs53.sh core rdma_queue_host_producer_failure_final_fix_test
```

结果：`PROCESS PASS`、`LOGICAL PASS`，UVM `INFO=27/WARNING=0/ERROR=0/FATAL=0`。

本地静态验证：

```text
git diff --check                         PASS
python3 -m unittest \
  tests.unit.test_run_queue_lifecycle_regression53.RunnerManifestTest.test_runner_lists_every_normal_unit_test
                                        PASS (1/1)
python3 tools/check_changed_sv_style.py --base HEAD
                                        PASS
```

## 未覆盖项

本批次有意未伪造 runtime `commit_producer()` fault hook；producer commit failure
仍需单独的 runtime fault seam/跨队列并发矩阵，避免把测试专用状态注入到
reservation/revalidation 逻辑中。
