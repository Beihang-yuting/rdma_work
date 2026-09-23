# CMQ Batch 67 — resource-manager QP recovery owner identity seam reuse

计划：`docs/superpowers/plans/2026-09-17-rdma-structural-refactor.md`。本批保留全部既有脏改动，不提交、不 push、不修改外部依赖。

## 结果：GREEN

在 `rdma_resource_manager::mark_qp_error` 的两个 QP recovery owner guard 中，将 direct
`same_instance` 改为既有 `same_handle_instance`：stale pre-program recovery gate 与
`preprogram_publication` authority gate。保留 recovery/registry owner 的非空门禁；第二处
显式补齐两侧 owner null 检查，继续返回原 `INVALID_ARGUMENT` authority-changed。helper
只比较完整 handle incarnation，不改变 recovery record、registry、SRQ shape、状态迁移或
资源所有权。

边界 source SHA：before `bd0ac313f6787afbd181d5cce1f363199558e617cecad9216d62feb0a9d316b7`，
after `b094558e1fbba78277973be7c9028a7960c3650443d931feaa3fc02794ccb4b9`（8505 → 8512
行），精确 diff SHA `a55c6cac9022390f733e0f181831eb736e025360db35c8885d17a9dec599c46e`。

## 验证

- source review/archive：`evidence/batch67-source-review.log`（SHA
  `721dea0a1cc0e2d6a408fabbb3f1b458e1fd6b776a7feef1d73d0cdb9d418677`）与
  `batch67-archive-validation.log`（SHA `2e318e9935ee6c7abed4bd80945c829bba24930d3181f6672aedb0971352fe04`），archive 成员与 source SHA 匹配；
- `rdma_resource_manager_test`：PROCESS/LOGICAL 1/1，UVM 0/0/0，日志 SHA
  `f694fb24555345ab7a16f29d46339ddb8d74f362f0843eb09578b74ebf26ec69`；
- `rdma_qp_lifecycle_test`：PROCESS/LOGICAL 1/1，UVM 0/0/0，日志 SHA
  `de988b9336558041b551ae371b7a37df318f9dd839d9230aef5adaf25fa84321`；
- 随后三批联合 `cmq_gate regression`：PROCESS 28/28、LOGICAL 11/11、严格 UVM pristine
  28/28，日志 `post-batch69-cmq-gate.log` SHA
  `68072bc2feb8e205aa9075259255b041cc52e481d765af29051cc0774bc388f0`；
- Python 292/292、manifest 22/22、style rc 0（仅既有 body-value:303 soft-limit）、
  `git diff --check` rc 0，均见 `post-batch69-*` 联合静态日志。

本批未改变 QP recovery 的 status/authority/lock/route/epoch 或外部资源生命周期。控制面、
runtime 及更深结构重构仍开放，计划不能标记完成。
