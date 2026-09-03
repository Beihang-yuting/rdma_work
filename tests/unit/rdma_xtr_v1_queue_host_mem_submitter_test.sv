// 中文说明：rdma_xtr_v1_queue_host_mem_submitter_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_xtr_v1_queue_host_mem_submitter_test extends uvm_test;
  `uvm_component_utils(rdma_xtr_v1_queue_host_mem_submitter_test)

  function new(string name = "rdma_xtr_v1_queue_host_mem_submitter_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function automatic rdma_function_handle function_handle();
    rdma_function_handle result;
    result = rdma_function_handle::type_id::create("function");
    result.function_uid = 64'h1122;
    result.object_id = 7;
    result.generation = 3;
    return result;
  endfunction

  function automatic rdma_dma_request_context request_context();
    rdma_dma_request_context result;
    result = rdma_dma_request_context::type_id::create("request_context");
    result.function_h = function_handle();
    result.requester_bdf = 16'h0102;
    result.pasid_valid = 1'b1;
    result.pasid = 20'h12345;
    result.dma_domain_valid = 1'b1;
    result.dma_domain_id = 9;
    return result;
  endfunction

  task run_phase(uvm_phase phase);
    rdma_mock_host_mem mem;
    rdma_codec_registry registry;
    rdma_xtr_v1_queue_host_mem_submitter submitter;
    rdma_xtr_v1_queue_host_mem_target target;
    rdma_dma_request_context context;
    rdma_status status;
    rdma_xtr_v1_sqe_model sqe;
    rdma_sqe_rc_ext rc;
    rdma_sge sge;
    rdma_hw_image image;
    rdma_xtr_v1_aeqe_model aeqe;
    byte unsigned aeqe_bytes[16];
    int unsigned release_calls;
    int unsigned release_calls_after;
    phase.raise_objection(this);

    mem = rdma_mock_host_mem::type_id::create("mem");
    registry = rdma_codec_registry::type_id::create("registry");
    void'(rdma_xtr_v1_register_queue_codecs(registry));
    submitter = rdma_xtr_v1_queue_host_mem_submitter::type_id::create(
      "submitter");
    submitter.host_mem = mem;
    submitter.registry = registry;
    context = request_context();

    // The submitter must return an opaque target after validating the
    // injected request context and retaining the allocation privately.
    status = submitter.allocate_target(context, 128, 64,
                                       RDMA_DMA_BIDIRECTIONAL, target);
    if (status == null || !status.ok() || target == null)
      `uvm_error("ALLOCATE", "queue host-memory target allocation failed")

    sqe = rdma_xtr_v1_sqe_model::type_id::create("sqe");
    sqe.transport = RDMA_TRANSPORT_RC;
    sqe.qp_h = rdma_handle::type_id::create("qp");
    sqe.qp_h.kind = RDMA_RESOURCE_QP;
    sqe.qp_h.function_uid = context.function_h.function_uid;
    sqe.qp_h.generation = context.function_h.generation;
    sqe.hw_opcode = 0;
    sqe.valid = 1'b1;
    rc = rdma_sqe_rc_ext::type_id::create("rc");
    sqe.transport_ext = rc;
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h2000;
    sge.length = 8;
    sqe.sges.push_back(sge);
    status = submitter.write_sqe(target, 0, sqe, image);
    if (status == null || !status.ok() || image == null)
      `uvm_error("WRITE", "queue SQE write transaction failed")

    // Seed a device-produced AEQE in the second slot.  Both CEQE and AEQE
    // are 16 bytes; the submitter must preserve the explicitly selected
    // image kind rather than inferring it from length.
    aeqe_bytes = '{8'hd0, 8'h00, 8'h00, 8'h81, 8'hff, 8'h02, 8'haa,
                   8'haa, 8'h00, 8'he5, 8'h43, 8'h21, 8'h00, 8'h00,
                   8'h00, 8'h00};
    foreach (aeqe_bytes[i])
      mem.regions[0].data[64 + i] = aeqe_bytes[i];
    aeqe = null;
    image = null;
    status = submitter.read_aeqe(target, 64, aeqe, image);
    if (status == null || !status.ok() || aeqe == null || image == null ||
        image.image_kind != RDMA_IMAGE_AEQE)
      `uvm_error("READ_AEQE", "AEQE read selected the wrong 16-byte image kind")

    status = submitter.release_target(target);
    if (status == null || !status.ok())
      `uvm_error("RELEASE", "queue target release failed")
    release_calls = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls++;
    // Exactly-once release: a duplicate release is rejected without another
    // adapter call.
    status = submitter.release_target(target);
    if (status == null || status.ok())
      `uvm_error("DUP_RELEASE", "duplicate target release was accepted")
    release_calls_after = 0;
    foreach (mem.calls[i])
      if (mem.calls[i].method_name == "release")
        release_calls_after++;
    if (release_calls != 1 || release_calls_after != release_calls)
      `uvm_error("DUP_RELEASE_CALL", "duplicate release invoked adapter")
    phase.drop_objection(this);
  endtask
endclass
