# Batch134：pcie_work error/ordering 供应商本体证据

日期：2026-09-22。工作树：`feature/rdma-cmq-contract-foundation`。

## 目的与边界

本批只补充用户指定 `pcie_work` 上游快照的 error/ordering 基础证据，确认锁定
`pcie_work` 与 `host_mem` 在 53 机登录 bash 中可以独立运行供应商 TL smoke。测试不修改
外部仓库，也不把供应商本体 TL-only 结果扩大解释为 RDMA adapter、SR-IOV 或完整
RDMA integration 的组合保证。

## 固定快照

- `pcie_work`：commit `1a80801e7d336ceeb492e7cdf57ba26ef27c2456`；锁闭包 tree SHA-256
  `8a9853c2cb618b5f73f4d2fed2167fad3a7b08bce37298cfef9ea159b1c5feb1`，75 个锁定文件均为
  `APPROVED`。
- `host_mem`：commit `365b7553fc7dac6b4ad55886a8e4869153607c28`；锁闭包 tree SHA-256
  `b9cd7d686c954823bdeafcea2f02013908fed51db5a8f4d39e96e5e877f6c770`。
- 53 机候选工作树分别核对为 pcie commit `1a80801e...`、host_mem commit
  `365b7553...`；本地 lock verify 两项均返回 0。

## 53 机命令与结果

以下命令均通过 `ubuntu@10.11.10.53` 的登录 bash 执行，VCS build 位于临时目录，
不写入外部源码树：

```bash
set -euo pipefail
build_dir=$(mktemp -d /tmp/pcie_work_err.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT
cd /home/ubuntu/workspace/pcie_work.audit.current/pcie_tl_vip
HOST_MEM_ROOT=/home/ubuntu/workspace/host_mem.audit.current \
BUILD_DIR="$build_dir" ./sim/run.sh pcie_tl_smoke_err_test
```

结果：compile/elab/link/仿真退出成功，200000 ps，`UVM_INFO=5`、
`UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`。完整日志留存于本地
`/tmp/pcie_work_err_test.log`。

ordering smoke 使用同一命令，将测试名替换为 `pcie_tl_smoke_ordering_test`；结果为
compile/elab/link/仿真退出成功，514000 ps，`UVM_INFO=6`、
`UVM_WARNING=0`、`UVM_ERROR=0`、`UVM_FATAL=0`。scoreboard 报告
`Requests=2`、`Completions=1`、`Matched=1`、`Mismatched=0`、`Unexpected=0`、
`Timed Out=0`；完整日志留存于本地 `/tmp/pcie_work_order_test.log`。

## 结论与遗留项

本批关闭 `pcie_work` 供应商 TL-only poisoned/error 与基础 ordering smoke 的证据缺口。
它不关闭以下组合边界：

- RDMA `rdma_pcie_work_adapter` 与 TL error/ordering 的组合注入；
- timeout、malformed TLP、tag-conflict、DMA/backpressure、多-root 和 SR-IOV stress；
- pcie_work smoke 与其余 RDMA integration suite 的同一运行矩阵。

因此总计划仍保持 `active`，pcie_work 采用状态为“锁定并通过 focused/供应商 smoke”，
而不是“完整 PCIe/RDMA 验收完成”。
