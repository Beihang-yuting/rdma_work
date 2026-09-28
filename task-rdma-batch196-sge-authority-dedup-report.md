# Batch196：SQ/RQ typed SGE authority 去重报告

## 目标

`src/codec/rdma/rdma_sge_authority.sv` 中 SQE 与 RQE 的 typed SGE 校验此前各自
实现了同一套列表上限、null、reserved bit31、2 GiB 累加和输出清零逻辑。重复实现
容易让两个方向的错误边界漂移，也让 authority 文件的职责不够集中。本批只收束这段
纯值校验，不改变调用方、错误码、诊断文案或 SGE/descriptor 所有权。

## 实现

- 新增无状态 `rdma_sge_authority::derive_typed_common()`，统一执行 typed SGE
  admission 和 canonical count/payload 计算。
- `derive_send()` 与 `derive_receive()` 保留原有公共 API，仅传入 `SQE`/`RQE`
  文案前缀并委托公共 helper。
- 失败时两个 output 仍保持零；`0x8000_0000` sentinel、零长度过滤、32 项上限、
  reserved bit31 和 2 GiB 边界均保持原语义。
- 未复制或接管 SGE、SGB、Host-memory、queue runtime 或任何外部账本。

## 验证

- VCS53 登录 bash：`rdma_sqe_authority_test` PROCESS/LOGICAL PASS，UVM
  warning/error/fatal `0/0/0`。
- Python unit：293/293 PASS。
- `python3 tools/check_changed_sv_style.py --base HEAD`：PASS。
- `git diff --check HEAD`：PASS。
- `python3 tools/check_queue_lifecycle.py`：PASS。
- `python3 tools/check_rdma_profile_names.py`：PASS。
- `python3 tools/check_rdma_phase1a_approval.py`：PASS。

完整 core regression 在本批源码同步前已连续输出 PROCESS/LOGICAL PASS；本批修改后
通过 focused authority 编译与执行，计划仍保持 active，后续仍需按完整 core/integration
门禁复核未关闭的 lifecycle、并发和 ownership 边界。
