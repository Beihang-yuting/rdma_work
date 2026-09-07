// 目录：测试层 tests/unit/。
// 职责：验证 rdma_coverage 的事件快照、coverpoint/cross 计数以及非法样本拒绝。
// 依赖：rdma_core_pkg、rdma_model_pkg、rdma_types_pkg 和 UVM；不连接外部环境。
// 所有权与生命周期：测试只拥有本地 coverage 对象和状态值，不取得队列、Function
//   或外部 adapter 所有权。

class rdma_coverage_test extends uvm_test;
  `uvm_component_utils(rdma_coverage_test)

  // 功能：构造 coverage focused test 组件，不创建外部资源。
  // 输入/输出及副作用：name、parent（输入）；调用 super.new 并保留 UVM 层级。
  // 失败/边界：构造成功不代表 coverage 已采样，所有断言在 run_phase 执行。
  function new(string name = "rdma_coverage_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：发送四个有效事件和一个非法事件，验证基础 coverpoint/cross 统计。
  // 输入/输出及副作用：phase（输入）；只更新本地 rdma_coverage 采样账本和 UVM 报告。
  // 失败/边界：非法 transport、零 Function count 或未知枚举不得增加样本数；有效
  //   error/status/reset 样本必须留下 fault coverage 证据。
  task run_phase(uvm_phase phase);
    rdma_coverage coverage;
    rdma_status status;

    phase.raise_objection(this);
    coverage = rdma_coverage::type_id::create("coverage_fixture");
    if (coverage == null) begin
      `uvm_error("COVERAGE_SETUP", "coverage object allocation failed")
      phase.drop_objection(this);
      return;
    end

    coverage.sample_event(RDMA_TRANSPORT_RC, RDMA_WR_SEND,
                          RDMA_DOORBELL_SQ, RDMA_RESOURCE_QP, 4, 7,
                          1'b0, 1'b1, RDMA_SC_OK, RDMA_ENGINE_SQ,
                          RDMA_COVER_RESET_NONE, RDMA_COVER_FN_ACTIVE);
    coverage.sample_event(RDMA_TRANSPORT_UD, RDMA_WR_SEND,
                          RDMA_DOORBELL_RQ, RDMA_RESOURCE_CQ, 4, 7,
                          1'b1, 1'b1, RDMA_SC_DMA_PERMISSION, RDMA_ENGINE_DMA,
                          RDMA_COVER_RESET_VF, RDMA_COVER_FN_QUIESCING);
    coverage.sample_event(RDMA_TRANSPORT_URC, RDMA_WR_RDMA_WRITE,
                          RDMA_DOORBELL_CQ, RDMA_RESOURCE_MR, 4, 8,
                          1'b0, 1'b1, RDMA_SC_TIMEOUT, RDMA_ENGINE_NETWORK,
                          RDMA_COVER_RESET_PF, RDMA_COVER_FN_QUARANTINED);
    coverage.sample_event(RDMA_TRANSPORT_RC, RDMA_WR_ATOMIC_CMP_SWAP,
                          RDMA_DOORBELL_CMQ_SQ, RDMA_RESOURCE_CMQ, 4, 8,
                          1'b1, 1'b1, RDMA_SC_STALE_GENERATION, RDMA_ENGINE_RESET,
                          RDMA_COVER_RESET_DEVICE, RDMA_COVER_FN_RECOVERED);

    if (coverage.sample_count() != 4)
      `uvm_error("COVERAGE_COUNT", $sformatf("sample count=%0d", coverage.sample_count()))
    if (coverage.cross_hit_count() < 4)
      `uvm_error("COVERAGE_CROSS", $sformatf("cross hit count=%0d", coverage.cross_hit_count()))
    if (!coverage.has_fault_coverage())
      `uvm_error("COVERAGE_FAULT", "fault coverage flag was not set")

    coverage.sample_event(RDMA_TRANSPORT_CUSTOM, RDMA_WR_SEND,
                          RDMA_DOORBELL_SQ, RDMA_RESOURCE_QP, 0, 0,
                          1'b0, 1'b0, RDMA_SC_OK, RDMA_ENGINE_NONE,
                          RDMA_COVER_RESET_NONE, RDMA_COVER_FN_DISCOVERED);
    if (coverage.sample_count() != 4)
      `uvm_error("COVERAGE_INVALID", "invalid sample changed coverage count")

    status = rdma_status::success();
    if (status == null || !status.ok())
      `uvm_error("COVERAGE_STATUS", "coverage test status fixture failed")
    phase.drop_objection(this);
  endtask
endclass
