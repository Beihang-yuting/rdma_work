// 中文说明：rdma_queue_data_engine_post_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_data_engine_fixture extends uvm_object;
  `uvm_object_utils(rdma_queue_data_engine_fixture)

  rdma_function_binding binding;
  rdma_resource_manager manager;
  rdma_mock_host_mem mem;
  rdma_mock_pcie pcie;
  rdma_mock_context_backing contexts;
  rdma_mock_cmq_port cmq;
  rdma_queue_lifecycle_executor queue_executor;
  rdma_qp_lifecycle_executor qp_executor;
  rdma_doorbell_scheduler scheduler;
  rdma_xtr_v1_doorbell_codec_registry registry;
  rdma_queue_data_engine engine;
  rdma_pd pd;
  rdma_ceq ceq;
  rdma_cq cq;
  rdma_qp qp;

  function new(string name = "rdma_queue_data_engine_fixture");
    super.new(name);
    binding = null; manager = null; mem = null; pcie = null;
    contexts = null; cmq = null; queue_executor = null; qp_executor = null;
    scheduler = null; registry = null; engine = null;
    pd = null; ceq = null; cq = null; qp = null;
  endfunction

  protected function rdma_function_binding make_binding(string name);
    rdma_function_binding result;
    rdma_interrupt_vector_binding vector;

    result = rdma_function_binding::type_id::create(name);
    result.function_uid = 64'h1122_3344_5566_7788;
    result.generation = 7;
    result.global_function_id = 32'h1234_0001;
    result.host_id = 5;
    result.rdma_vf_id = 8'h55;
    result.pfvf_id = 32'h1234_0099;
    result.pcie.bdf = '{segment:16'h1, bus:8'h20, device:5'h2,
                        function_num:3'h1};
    result.pcie.parent_pf_bdf = result.pcie.bdf;
    result.pcie.mse = 1'b1;
    result.pcie.bme = 1'b1;
    result.pcie.bar[0].base.value = 64'h8000_0000;
    result.pcie.bar[0].size = 64'h4000;
    result.pcie.bar[0].enabled = 1'b1;
    result.notify_bar_id = 0;
    result.notify_base.value = 64'h8000_2000;
    result.notify_size = 64'h2000;
    result.queue_dma.requester_bdf = result.pcie.bdf;
    result.queue_dma.pasid_valid = 1'b1;
    result.queue_dma.pasid = 20'h12345;
    result.queue_dma.dma_domain_valid = 1'b1;
    result.queue_dma.dma_domain_id = 9;
    result.queue_caps.min_cq_depth = 16;
    result.queue_caps.max_cq_depth = 32768;
    result.queue_caps.min_srq_depth = 16;
    result.queue_caps.max_srq_depth = 32768;
    result.queue_caps.max_ceq_depth = 4096;
    result.queue_caps.max_aeq_depth = 4096;
    result.queue_caps.max_wq_sge = 8;
    result.queue_caps.max_queue_ring_bytes = 2 * 1024 * 1024;
    result.queue_caps.max_sgb_bytes = 2 * 1024 * 1024;
    vector = '{default:'0};
    vector.function_local_vector = 1;
    vector.hardware_eq_vector = 1;
    vector.msix_table_index = 1;
    vector.enabled = 1'b1;
    result.interrupt_vectors.push_back(vector);
    result.state = RDMA_BIND_ACTIVE;
    result.owner_h = result.make_handle();
    result.notify_valid = 1'b1;
    result.notify_ready = 1'b1;
    result.dmi_valid = 1'b1;
    result.dmi_ready = 1'b1;
    result.vft_valid = 1'b1;
    result.vft_ready = 1'b1;
    return result;
  endfunction

  protected function rdma_qp_context_attributes make_rc_attrs(string name);
    rdma_qp_context_attributes attrs;
    rdma_qpc_rc_ext ext;

    attrs = rdma_qp_context_attributes::type_id::create(name);
    attrs.path_mtu_bytes = 4096;
    attrs.pkey = 16'hbeef;
    attrs.address_vector = rdma_address_vector::type_id::create({name, "_av"});
    attrs.address_vector.destination_mac = 48'h1122_3344_5566;
    attrs.address_vector.traffic_class = 8'h02;
    attrs.behavior = rdma_qpc_behavior::type_id::create({name, "_behavior"});
    attrs.behavior.transport_version = 1;
    ext = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    ext.remote_qpn = 24'h456789;
    ext.send_psn = 24'h123456;
    ext.recv_psn = 24'h654321;
    ext.retry_count = 2;
    ext.rnr_retry_count = 2;
    attrs.transport_ext = ext;
    return attrs;
  endfunction

  protected function rdma_status setup_status(string stage, rdma_status value);
    if (value == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {stage, " returned null status"});
    if (value.ok())
      return value;
    return rdma_status::make(value.code, {stage, ": ", value.message});
  endfunction

  task setup(output rdma_status status);
    rdma_function function_resource;
    rdma_create_cq_req cq_request;
    rdma_create_qp_req qp_request;
    rdma_queue_resource queue;
    rdma_control_result control_result;

    status = null;
    binding = make_binding({get_name(), "_binding"});
    manager = rdma_resource_manager::type_id::create({get_name(), "_manager"});
    if (mem == null)
      mem = rdma_mock_host_mem::type_id::create({get_name(), "_mem"});
    if (pcie == null)
      pcie = rdma_mock_pcie::type_id::create({get_name(), "_pcie"});
    contexts = rdma_mock_context_backing::type_id::create(
      {get_name(), "_contexts"});
    cmq = rdma_mock_cmq_port::type_id::create({get_name(), "_cmq"});
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      {get_name(), "_queue_executor"});
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      {get_name(), "_qp_executor"});
    scheduler = rdma_doorbell_scheduler::type_id::create(
      {get_name(), "_scheduler"});
    registry = rdma_xtr_v1_doorbell_codec_registry::type_id::create(
      {get_name(), "_registry"});
    engine = rdma_queue_data_engine::type_id::create({get_name(), "_engine"});

    status = setup_status("create_function",
                          manager.create_function(binding, function_resource));
    if (!status.ok()) return;
    status = setup_status("create_pd", manager.create_pd(binding, pd));
    if (!status.ok()) return;
    // A CQ lifecycle request requires an explicit CEQ dependency.  Keep the
    // dependency real so the executor can build the CQC projection and
    // retain the lifecycle-owned context/backing references used by the data
    // engine fixture.
    status = setup_status("create_ceq", manager.create_ceq(binding, ceq));
    if (!status.ok()) return;
    status = setup_status("queue_executor.configure",
                          queue_executor.configure(manager, cmq, mem,
                                                    contexts, 2us));
    if (!status.ok()) return;

    cq_request = rdma_create_cq_req::type_id::create(
      {get_name(), "_cq_request"});
    cq_request.owner = binding.make_handle();
    cq_request.depth = 16;
    cq_request.cqe_size_bytes = XTR_V1_CQE_BYTES;
    cq_request.ceq_h = rdma_clone_handle_value(ceq.handle,
                                                "fixture CQ CEQ");
    queue_executor.create_locked(binding, binding.make_handle(), cq_request,
                                 64'h1001, queue, control_result);
    if (control_result == null || control_result.status == null ||
        !control_result.status.ok() || queue == null || !$cast(cq, queue)) begin
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CQ fixture creation returned no status") :
        setup_status("CQ create", control_result.status);
      if (control_result != null)
        status.message = {status.message, $sformatf(" primary=%p rollback=%p steps=%p resource=%p",
                                                     control_result.primary_status,
                                                     control_result.rollback_statuses,
                                                     control_result.completed_steps,
                                                     control_result.resource_h)};
      return;
    end

    status = setup_status("qp_executor.configure",
                          qp_executor.configure(manager, cmq, mem,
                                                contexts, 2us));
    if (!status.ok()) return;
    qp_request = rdma_create_qp_req::type_id::create(
      {get_name(), "_qp_request"});
    qp_request.owner = binding.make_handle();
    qp_request.transport = RDMA_TRANSPORT_RC;
    qp_request.sq_depth = 16;
    qp_request.rq_depth = 16;
    qp_request.max_send_sge = 4;
    qp_request.max_recv_sge = 4;
    qp_request.max_inline_data = 512;
    qp_request.sq_sgb_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    qp_request.pd_h = rdma_clone_handle_value(pd.handle, "fixture QP PD");
    qp_request.send_cq_h = rdma_clone_handle_value(cq.handle,
                                                   "fixture QP send CQ");
    qp_request.recv_cq_h = rdma_clone_handle_value(cq.handle,
                                                   "fixture QP receive CQ");
    qp_request.context_attrs = make_rc_attrs({get_name(), "_qp_attrs"});
    qp_executor.create_locked(binding, binding.make_handle(), qp_request,
                              64'h1002, qp, control_result);
    if (control_result == null || control_result.status == null ||
        !control_result.status.ok() || qp == null) begin
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "QP fixture creation returned no status") :
        setup_status("QP create", control_result.status);
      if (control_result != null)
        status.message = {status.message, $sformatf(" primary=%p rollback=%p steps=%p resource=%p",
                                                     control_result.primary_status,
                                                     control_result.rollback_statuses,
                                                     control_result.completed_steps,
                                                     control_result.resource_h)};
      return;
    end

    status = setup_status("scheduler.configure", scheduler.configure(mem, pcie));
    if (!status.ok()) return;
    status = setup_status("registry.register_defaults",
                          registry.register_defaults());
    if (!status.ok()) return;
    status = setup_status("register_queue_codecs",
                          rdma_xtr_v1_register_queue_codecs(registry));
    if (!status.ok()) return;
    status = setup_status("engine.configure",
                          engine.configure(manager, binding, mem, scheduler,
                                           registry, 2us));
    if (!status.ok()) return;
    status = setup_status("engine.attach_cq",
                          engine.attach_cq(cq.handle, RDMA_TRANSPORT_RC));
    if (!status.ok()) return;
    status = setup_status("engine.attach_qp", engine.attach_qp(qp.handle));
  endtask

  function rdma_post_send_req make_send(longint unsigned wr_id);
    rdma_post_send_req request;
    rdma_sge sge;
    request = rdma_post_send_req::type_id::create("fixture_send");
    request.owner = binding.make_handle();
    request.qp_h = rdma_clone_handle_value(qp.handle, "fixture send QP");
    request.wr_id = wr_id;
    request.transport = RDMA_TRANSPORT_RC;
    request.opcode = RDMA_WR_SEND;
    request.signaled = 1'b1;
    sge = rdma_sge::type_id::create("fixture_send_sge");
    sge.iova.value = 64'h0000_1000_0000_0000;
    sge.length = 32;
    sge.lkey = 32'h0102_0304;
    request.sges.push_back(sge);
    return request;
  endfunction

  function rdma_post_recv_req make_recv(longint unsigned wr_id);
    rdma_post_recv_req request;
    rdma_sge sge;
    request = rdma_post_recv_req::type_id::create("fixture_recv");
    request.owner = binding.make_handle();
    request.target_h = rdma_clone_handle_value(qp.handle,
                                                "fixture receive QP");
    request.wr_id = wr_id;
    sge = rdma_sge::type_id::create("fixture_recv_sge");
    sge.iova.value = 64'h0000_2000_0000_0000;
    sge.length = 128;
    sge.lkey = 32'h0506_0708;
    request.sges.push_back(sge);
    return request;
  endfunction

  function rdma_status read_qp_entry(
    bit send_ring, int unsigned index, output byte data[]
  );
    rdma_qp_backing_ref backing;
    backing = send_ring ? qp.qp_plan.sq_ref : qp.qp_plan.rq_ref;
    data = new[0];
    if (backing == null || backing.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture QP backing is missing");
    return mem.read(backing.mapping,
                    backing.mapping_offset + longint'(index) * 64,
                    64, data);
  endfunction

  function rdma_status write_cq_entry(
    int unsigned index, rdma_xtr_v1_cqe_model model
  );
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_queue_backing_ref backing;
    byte data[];
    rdma_status status;

    key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_CQE,
            object_type:"cqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, codec);
    if (status == null || !status.ok()) return status;
    status = codec.encode(model, image);
    if (status == null || !status.ok()) return status;
    backing = null;
    foreach (cq.queue_plan.refs[i]) begin
      if (cq.queue_plan.refs[i] != null &&
          cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        backing = cq.queue_plan.refs[i];
    end
    if (backing == null || backing.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture CQ backing is missing");
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    return mem.write(backing.mapping,
                     backing.mapping_offset + longint'(index) * 64, data);
  endfunction
endclass

class rdma_queue_data_engine_post_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_post_test)

  function new(string name = "rdma_queue_data_engine_post_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    rdma_queue_data_engine engine;
    rdma_queue_data_engine_fixture fixture;
    rdma_status status;
    rdma_queue_post_result result;
    rdma_post_send_req send_request;
    rdma_post_recv_req recv_request;
    byte entry[];

    phase.raise_objection(this);
    engine = rdma_queue_data_engine::type_id::create("unconfigured_engine");

    status = engine.configure(null, null, null, null, null, 1ns);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("CONFIG_NULL", "engine accepted missing dependencies")

    send_request = rdma_post_send_req::type_id::create("send_request");
    result = rdma_queue_post_result::type_id::create("sentinel_send");
    status = null;
    engine.post_send(send_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("POST_UNCONFIGURED",
                 "send published output while unconfigured")

    recv_request = rdma_post_recv_req::type_id::create("recv_request");
    result = rdma_queue_post_result::type_id::create("sentinel_recv");
    status = null;
    engine.post_recv(recv_request, result, status);
    if (status == null || status.ok() || result != null)
      `uvm_error("RECV_UNCONFIGURED",
                 "receive published output while unconfigured")

    fixture = rdma_queue_data_engine_fixture::type_id::create("post_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("FIXTURE_SETUP", status == null ? "null setup status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    // Missing host-memory writes or an incorrect SQ offset make this fail:
    // the returned image must be byte-identical to the actual SQ slot.
    send_request = fixture.make_send(64'h1111_2222_3333_4444);
    fixture.engine.post_send(send_request, result, status);
    if (status == null || !status.ok() || result == null ||
        result.index != 0 || result.wrap != 0)
      `uvm_error("POST_SEND", status == null ? "null status" :
                 status.convert2string())
    else begin
      status = fixture.read_qp_entry(1'b1, 0, entry);
      if (status == null || !status.ok() || entry.size() != 64 ||
          result.image == null || result.image.bytes.size() != 64)
        `uvm_error("POST_SEND_MEMORY", "SQ slot readback is unavailable")
      else foreach (entry[i]) begin
        if (entry[i] != result.image.bytes[i])
          `uvm_error("POST_SEND_MEMORY",
                     $sformatf("SQ byte %0d was not persisted", i))
      end
    end

    // Selecting the SQ attachment for a receive, or writing the wrong ring,
    // is caught by the private-RQ byte-for-byte observation below.
    recv_request = fixture.make_recv(64'h5555_6666_7777_8888);
    fixture.engine.post_recv(recv_request, result, status);
    if (status == null || !status.ok() || result == null ||
        result.index != 0 || result.wrap != 0)
      `uvm_error("POST_RECV", status == null ? "null status" :
                 status.convert2string())
    else begin
      status = fixture.read_qp_entry(1'b0, 0, entry);
      if (status == null || !status.ok() || entry.size() != 64 ||
          result.image == null || result.image.bytes.size() != 64)
        `uvm_error("POST_RECV_MEMORY", "RQ slot readback is unavailable")
      else foreach (entry[i]) begin
        if (entry[i] != result.image.bytes[i])
          `uvm_error("POST_RECV_MEMORY",
                     $sformatf("RQ byte %0d was not persisted", i))
      end
    end

    phase.drop_objection(this);
  endtask
endclass
