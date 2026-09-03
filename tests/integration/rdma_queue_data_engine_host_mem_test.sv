// 中文说明：rdma_queue_data_engine_host_mem_test.sv 属于集成测试，验证真实适配器与队列/控制面之间的联调。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// End-to-end queue data-plane test using the pinned host_mem implementation.
// The test intentionally reuses the lifecycle fixture from the core package,
// replacing only its host-memory adapter with a delegating real adapter.

import rdma_unit_test_pkg::*;
import rdma_codec_pkg::*;

class rdma_real_host_mem_proxy extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_real_host_mem_proxy)

  rdma_host_mem_adapter delegate;

  function new(string name = "rdma_real_host_mem_proxy");
    super.new(name);
    delegate = null;
  endfunction

  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (delegate == null) begin
      mapping = null;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    end
    return delegate.allocate(request_context, size, alignment, direction,
                              mapping);
  endfunction

  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    return delegate.write(mapping, offset, data);
  endfunction

  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    if (delegate == null) begin
      data = new[0];
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    end
    return delegate.read(mapping, offset, size, data);
  endfunction

  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    return delegate.\release (mapping);
  endfunction
endclass

class rdma_queue_data_engine_host_mem_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_host_mem_test)

  function new(string name = "rdma_queue_data_engine_host_mem_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    $unit::host_mem_manager host_manager;
    rdma_host_mem_adapter real_adapter;
    rdma_real_host_mem_proxy proxy;
    rdma_queue_data_engine_fixture fixture;
    rdma_status status;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_post_send_req send_request;
    rdma_xtr_v1_cqe_model cqe;
    rdma_destroy_resource_req destroy_request;
    rdma_control_result destroy_result;
    int unsigned leak_count;
    byte actual_entry[];

    phase.raise_objection(this);

    host_manager = $unit::host_mem_manager::type_id::create("queue_hm_real");
    host_manager.init_region(64'h0000_0008_0000_0000,
                             64'h0000_0008_00ff_ffff);
    real_adapter = rdma_host_mem_adapter::type_id::create(
      "queue_real_adapter");
    real_adapter.mem = host_manager;
    real_adapter.iova_base = 64'h0000_0010_0000_0000;
    proxy = rdma_real_host_mem_proxy::type_id::create("queue_mem_proxy");
    proxy.delegate = real_adapter;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "queue_real_fixture");
    fixture.mem = proxy;
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("REAL_SETUP", status == null ? "null setup status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    send_request = fixture.make_send(64'hcafe_0000_0000_0001);
    fixture.engine.post_send(send_request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("REAL_POST", status == null ? "null status" :
                 status.convert2string())
    end
    else begin
      status = fixture.read_qp_entry(1'b1, posted.index, actual_entry);
      if (status == null || !status.ok() || actual_entry.size() != 64)
        `uvm_error("REAL_SQ_READ", status == null ? "null status" :
                   status.convert2string())
      else foreach (actual_entry[i])
        if (actual_entry[i] !== posted.image.bytes[i])
          `uvm_error("REAL_SQ_BYTES",
                     $sformatf("SQ byte %0d differs from returned image", i))
    end

    cqe = rdma_xtr_v1_cqe_model::type_id::create("real_device_cqe");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "real CQE QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted == null ? 0 : posted.index;
    cqe.wqe_wrap = posted == null ? 0 : posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = XTR_V1_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.status = rdma_status::success();
    status = fixture.write_cq_entry(0, cqe);
    if (status == null || !status.ok())
      `uvm_error("REAL_CQE_WRITE", status == null ? "null status" :
                 status.convert2string())

    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != send_request.wr_id ||
        completion.completion_status == null ||
        !completion.completion_status.ok())
      `uvm_error("REAL_POLL", status == null ? "null status" :
                 status.convert2string())

    // Destroying the lifecycle resources releases the real pinned allocations
    // through the adapter's ownership ledger.  The final leak check is the
    // integration contract: no test backing may survive the transaction.
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_qp");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.qp.handle;
    fixture.qp_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2001,
      destroy_result);
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_cq");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.cq.handle;
    fixture.queue_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2002,
      destroy_result);
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_ceq");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.ceq.handle;
    fixture.queue_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2003,
      destroy_result);
    status = real_adapter.check_leaks(leak_count);
    if (status == null || !status.ok() || leak_count != 0)
      `uvm_error("REAL_LEAK", status == null ? "null status" :
                 $sformatf("%s leaks=%0d", status.convert2string(),
                           leak_count))

    phase.drop_objection(this);
  endtask
endclass
