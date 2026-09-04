// 目录：测试层 unit/rdma_queue_data_engine_post_test.sv。
// 职责：验证 rdma_queue_data_engine_post_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

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
  rdma_hw_doorbell_codec_registry registry;
  rdma_queue_data_engine engine;
  rdma_pd pd;
  rdma_ceq ceq;
  rdma_cq cq;
  rdma_qp qp;

  // 功能：构造 rdma_queue_data_engine_fixture，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：binding=null；manager=null；mem=null；pcie=null；contexts=null；cmq=null；queue_executor=null；qp_executor=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_fixture 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_fixture");
    super.new(name);
    binding = null; manager = null; mem = null; pcie = null;
    contexts = null; cmq = null; queue_executor = null; qp_executor = null;
    scheduler = null; registry = null; engine = null;
    pd = null; ceq = null; cq = null; qp = null;
  endfunction

  // 功能：make_binding 创建独立的 rdma_function_binding；根据 name 设置字段 result、result.function_uid、result.generation、result.global_function_id、result.host_id、result.rdma_vf_id、result.pfvf_id、pcie.bdf、pcie.parent_pf_bdf、pcie.mse，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_binding 读取 name 并使用字段 result、result.function_uid、result.generation、result.global_function_id、result.host_id、result.rdma_vf_id、result.pfvf_id、pcie.bdf；函数返回 rdma_function_binding，不取得调用方资源所有权。
  // 失败/边界：make_binding 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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
    result.pcie.parent_pf_bdf = '0;
    if (!result.configure_identity_from_legacy_mirrors(
          16'h0, 32'h1, RDMA_FUNCTION_PF).ok())
      `uvm_error("BINDING", "legacy binding identity configuration failed")
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

  // 功能：make_rc_attrs 创建独立的 rdma_qp_context_attributes；根据 name 设置字段 attrs、attrs.path_mtu_bytes、attrs.pkey、attrs.address_vector、address_vector.destination_mac、address_vector.traffic_class、attrs.behavior、behavior.transport_version、ext、ext.remote_qpn，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_rc_attrs 读取 name 并使用字段 attrs、attrs.path_mtu_bytes、attrs.pkey、attrs.address_vector、address_vector.destination_mac、address_vector.traffic_class、attrs.behavior、behavior.transport_version；函数返回 rdma_qp_context_attributes，不取得调用方资源所有权。
  // 失败/边界：make_rc_attrs 的结果直接由 return attrs 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：setup_status 校验 stage、value 与当前对象状态的一致性，并显式处理“returned null status”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：stage（输入）、value（输入）；setup_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：setup_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status setup_status(string stage, rdma_status value);
    if (value == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {stage, " returned null status"});
    if (value.ok())
      return value;
    return rdma_status::make(value.code, {stage, ": ", value.message});
  endfunction

  // 功能：setup 更新字段 status、binding、manager、mem、pcie、contexts、cmq、queue_executor、qp_executor、scheduler，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：status（输出）；setup 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：setup 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“CQ fixture creation returned no status”“QP fixture creation returned no status”；失败路径不提交部分状态或转移未声明资源。
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
    registry = rdma_hw_doorbell_codec_registry::type_id::create(
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
    cq_request.cqe_size_bytes = RDMA_CQE_BYTES;
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
                          rdma_register_queue_codecs(registry));
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

  // 功能：make_send 创建独立的 rdma_post_send_req；根据 wr_id 设置字段 request、request.owner、request.qp_h、request.wr_id、request.transport、request.opcode、request.signaled、sge、iova.value、sge.length，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：wr_id（输入）；make_send 读取 wr_id 并使用字段 request、request.owner、request.qp_h、request.wr_id、request.transport、request.opcode、request.signaled、sge；函数返回 rdma_post_send_req，不取得调用方资源所有权。
  // 失败/边界：make_send 的结果直接由 return request 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：make_recv 创建独立的 rdma_post_recv_req；根据 wr_id 设置字段 request、request.owner、request.target_h、request.wr_id、sge、iova.value、sge.length、sge.lkey，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：wr_id（输入）；make_recv 读取 wr_id 并使用字段 request、request.owner、request.target_h、request.wr_id、sge、iova.value、sge.length、sge.lkey；函数返回 rdma_post_recv_req，不取得调用方资源所有权。
  // 失败/边界：make_recv 的结果直接由 return request 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：在 rdma_queue_data_engine_fixture 中，read_qp_entry 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：send_ring（输入）、index（输入）、data（输出）；read_qp_entry 读取 send_ring、index、data 并使用字段 backing、data，并写入 data；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：read_qp_entry 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_queue_data_engine_fixture 中，write_cq_entry 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：index（输入）、model（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：write_cq_entry 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  function rdma_status write_cq_entry(
    int unsigned index, rdma_hw_cqe_model model
  );
    rdma_codec_key key;
    rdma_codec_base codec;
    rdma_hw_image image;
    rdma_queue_backing_ref backing;
    byte data[];
    rdma_status status;

    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
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

  // 功能：构造 rdma_queue_data_engine_post_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_post_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_post_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_data_engine_post_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
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
