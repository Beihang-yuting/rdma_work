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
  // 基础 RC QP 之外，集成传输矩阵按需创建同一 Function 下的 UD/URC
  // QP。它们共享 CQ 依赖但拥有各自的 SQ/RQ backing 与 transport context。
  rdma_qp ud_qp;
  rdma_qp urc_qp;

  // 功能：构造 rdma_queue_data_engine_fixture，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：binding=null；manager=null；mem=null；pcie=null；contexts=null；cmq=null；queue_executor=null；qp_executor=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_fixture 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_fixture");
    super.new(name);
    binding = null; manager = null; mem = null; pcie = null;
    contexts = null; cmq = null; queue_executor = null; qp_executor = null;
    scheduler = null; registry = null; engine = null;
    pd = null; ceq = null; cq = null; qp = null;
    ud_qp = null; urc_qp = null;
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
    // 设计说明：Task 6 的 lifecycle-owned AEQ 使用 local vector 2；在 fixture
    // binding 中显式发布其独立硬件/MSI-X projection，避免把 AEQ 偷换为 CEQ 的
    // vector 1，也让 policy preflight 能验证真实 Function authority。
    vector.function_local_vector = 2;
    vector.hardware_eq_vector = 2;
    vector.msix_table_index = 2;
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

  // 功能：make_transport_attrs 为附加 transport QP 生成与基础 RC QP
  //   相同的通用路径属性，并替换对应的 UD/URC 专用扩展。
  // 输入/输出及副作用：name、transport 为输入；返回新的 context 快照，
  //   不修改 binding、CQ 或已有 QP。
  // 失败/边界：RC 使用基础 RC 扩展；UD/URC 使用专用扩展；CUSTOM 或未知
  //   transport 返回 null，调用方必须在创建 QP 前拒绝该结果。
  function automatic rdma_qp_context_attributes make_transport_attrs(
    string name, rdma_transport_e transport
  );
    rdma_qp_context_attributes attrs;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;

    attrs = make_rc_attrs(name);
    case (transport)
      RDMA_TRANSPORT_RC: begin end
      RDMA_TRANSPORT_UD: begin
        attrs.address_vector.traffic_class = 8'hac;
        ud_ext = rdma_qpc_ud_ext::type_id::create({name, "_ud"});
        ud_ext.qkey = 32'h8001_0000;
        attrs.transport_ext = ud_ext;
      end
      RDMA_TRANSPORT_URC: begin
        urc_ext = rdma_qpc_urc_ext::type_id::create({name, "_urc"});
        urc_ext.remote_qpn = 24'h765432;
        urc_ext.rbsn = 24'h010203;
        urc_ext.dbsn = 24'h040506;
        urc_ext.rpsn = 24'h070809;
        urc_ext.dpsn = 24'h0a0b0c;
        urc_ext.queues.rsq_depth = 16;
        urc_ext.queues.rdsq_depth = 16;
        urc_ext.queues.rdsq_fetch_count = 8;
        urc_ext.queues.dsq_fetch_count = 8;
        urc_ext.queues.rq_sequence_threshold_entries = 16;
        urc_ext.queues.sq_completion_threshold_entries = 16;
        attrs.transport_ext = urc_ext;
      end
      default: attrs = null;
    endcase
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

  // 功能：create_transport_qp 在已建立的 Function/PD/CQ 生命周期上创建一个
  //   指定 wire transport 的附加 QP，供集成测试真实提交对应 profile 的 SQE/RQE。
  // 输入/输出及副作用：label、transport 为输入；qp、status 为输出；成功时
  //   manager/CMQ/host-memory 新增一个 ACTIVE QP，资源所有权仍由 fixture 清理。
  // 失败/边界：依赖未 setup、transport 不受支持、context 构造失败或 CMQ
  //   create 失败时返回原始错误，不发布半成品 QP。
  task automatic create_transport_qp(
    string label,
    rdma_transport_e transport,
    output rdma_qp qp,
    output rdma_status status
  );
    create_transport_qp_for_cq(label, transport, cq, qp, status);
  endtask

  // 功能：create_transport_qp_for_cq 在指定 lifecycle-owned CQ 上创建一个真实
  //   transport QP，使 event publish 测试能以同一 CQ/QP route 校验 CEQE/AEQE。
  // 输入/输出及副作用：label、transport、target_cq 为输入，qp/status 为输出；
  //   成功时 manager/CMQ/Host-memory 新增 ACTIVE QP，所有权仍由 fixture 显式销毁。
  // 失败/边界：target_cq/依赖缺失、transport 不受支持、context 或 create 失败时
  //   qp 保持 null 并传播原始 status，不回退使用 fixture 的 dependency-only CQ。
  task automatic create_transport_qp_for_cq(
    string label,
    rdma_transport_e transport,
    rdma_cq target_cq,
    output rdma_qp qp,
    output rdma_status status
  );
    rdma_create_qp_req request;
    rdma_control_result control_result;

    qp = null;
    status = rdma_status::success();
    if (binding == null || manager == null || qp_executor == null ||
        pd == null || target_cq == null || target_cq.handle == null)
      begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "transport QP fixture is not initialized");
        return;
      end
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC})) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "additional QP transport is unsupported");
      return;
    end
    request = rdma_create_qp_req::type_id::create({label, "_request"});
    request.owner = binding.make_handle();
    request.transport = transport;
    request.sq_depth = 16;
    request.rq_depth = 16;
    request.max_send_sge = 4;
    request.max_recv_sge = 4;
    // UD 使用每 slot 的 512B SGB；传输矩阵不依赖大于 32B 的 inline
    // payload，因此统一使用基础 inline 上限，避免 profile capability
    // 检查把测试重点从 transport 路由本身移开。
    request.max_inline_data = 32;
    if (transport == RDMA_TRANSPORT_UD)
      request.sq_sgb_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    request.pd_h = rdma_clone_handle_value(pd.handle, {label, "_pd"});
    request.send_cq_h = rdma_clone_handle_value(target_cq.handle,
                                                {label, "_send_cq"});
    request.recv_cq_h = rdma_clone_handle_value(target_cq.handle,
                                                {label, "_recv_cq"});
    request.context_attrs = make_transport_attrs({label, "_attrs"}, transport);
    if (request.context_attrs == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "transport QP context attributes are missing");
      return;
    end
    qp_executor.create_locked(binding, binding.make_handle(), request,
                              transport == RDMA_TRANSPORT_RC ? 64'h100f :
                              (transport == RDMA_TRANSPORT_UD ? 64'h1010 :
                                                               64'h1011),
                              qp, control_result);
    if (control_result == null || control_result.status == null ||
        !control_result.status.ok() || qp == null) begin
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "transport QP creation returned no status") :
        control_result.status;
      qp = null;
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：setup_transport_qps 为集成测试创建 UD 与 URC 两个独立 QP，确保
  //   每种 RoCE wire profile 都由匹配的 CMQ transport context 驱动。
  // 输入/输出及副作用：status 为输出；新增 QP 及其 backing，成功后可由
  //   get_qp_for_transport 查询；失败时保留已成功创建的 QP 供 cleanup。
  // 失败/边界：基础 setup 未成功、任一 create 失败时返回错误，不把 RC QP
  //   伪装成 UD/URC；调用方必须仍执行完整 fixture cleanup。
  task automatic setup_transport_qps(output rdma_status status);
    status = rdma_status::success();
    create_transport_qp("ud", RDMA_TRANSPORT_UD, ud_qp, status);
    if (status == null || !status.ok()) return;
    create_transport_qp("urc", RDMA_TRANSPORT_URC, urc_qp, status);
  endtask

  // 功能：get_qp_for_transport 返回当前 fixture 中与指定 transport 匹配的
  //   QP 对象，使测试请求、RQE 和 CQE 使用同一份 QP authority。
  // 输入/输出及副作用：transport 为输入；返回 fixture 持有的非拥有 QP 引用，
  //   不修改任何资源。
  // 失败/边界：RC/UD/URC 返回对应 QP；未知 transport 或附加 QP 尚未创建时
  //   返回 null，调用方必须在提交前报告 setup 错误。
  function automatic rdma_qp get_qp_for_transport(
    rdma_transport_e transport
  );
    case (transport)
      RDMA_TRANSPORT_RC: return qp;
      RDMA_TRANSPORT_UD: return ud_qp;
      RDMA_TRANSPORT_URC: return urc_qp;
      default: return null;
    endcase
  endfunction

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

  // 功能：read_cq_entry 通过 fixture 管理的 CQ backing 读取指定已发布槽位，供
  //   publish 测试核对真实 Host-memory bytes，而不向测试暴露可修改 mapping 引用。
  // 输入/输出及副作用：index、size 为输入，data 为输出；函数只读取 fixture 所有的
  //   CQ queue plan 与 mock Host-memory，不推进 runtime cursor 或修改 backing。
  // 失败边界：CQ backing/mapping 缺失、size 为零或读越界时返回非成功 status，
  //   data 保持由 host-memory API 定义的安全空值。
  function rdma_status read_cq_entry(
    int unsigned index,
    int unsigned size,
    output byte data[]
  );
    rdma_queue_backing_ref backing;

    data = new[0];
    backing = null;
    if (size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "fixture CQ read size is zero");
    foreach (cq.queue_plan.refs[i]) begin
      if (cq.queue_plan.refs[i] != null &&
          cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        backing = cq.queue_plan.refs[i];
    end
    if (backing == null || backing.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture CQ backing is missing");
    return mem.read(backing.mapping,
                    backing.mapping_offset + longint'(index) * size,
                    size, data);
  endfunction

  // 功能：advance_binding_reset_epoch 通过 binding 的公开 identity 配置接口发布
  //   新 reset epoch，模拟 attachment 冻结 route 后外部 Function 已复位。
  // 输入/输出及副作用：next_epoch 为输入；成功时替换 binding 内部 authority snapshot，
  //   不修改已 attach runtime、queue handle、mapping 或 Host-memory 内容。
  // 失败边界：binding/旧 identity 缺失、next_epoch 为零或 identity 配置失败时返回
  //   非成功 status；调用方只能用它验证 stale route 拒绝，不能继续使用旧生命周期。
  function rdma_status advance_binding_reset_epoch(rdma_reset_epoch_t next_epoch);
    rdma_function_identity identity;

    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture binding is unavailable");
    if (next_epoch == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "fixture reset epoch is zero");
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "fixture Function identity is unavailable");
    identity.reset_epoch = next_epoch;
    return binding.configure_identity(identity);
  endfunction

  // 功能：destroy_lifecycle_owned_queue 按 created/attached 状态撤销测试临时
  //   CEQ/AEQ/CQ；已 attach 时先 detach，随后无论 detach 成败都尝试 executor destroy。
  // 输入/输出及副作用：queue_h、created、attached、transaction_id 为输入，status
  //   为输出；成功时回收 manager、context 和 owned backing，未创建资源为空操作。
  // 失败边界：状态矛盾、destroy 依赖/handle/transaction 缺失，或 attached=1 时
  //   engine 缺失均拒绝；detach 与 destroy 都失败时保留首个 detach 错误。
  task destroy_lifecycle_owned_queue(
    rdma_handle queue_h,
    bit created,
    bit attached,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_destroy_resource_req request;
    rdma_control_result control_result;
    rdma_status detach_status;
    rdma_status destroy_status;
    rdma_status first_failure;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event fixture teardown is not initialized");
    first_failure = null;
    if (!created) begin
      if (attached)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "uncreated event queue is marked attached");
      else
        status = rdma_status::success();
      return;
    end
    if ((attached && engine == null) || queue_executor == null || binding == null ||
        queue_h == null || transaction_id == 0) return;
    if (attached) begin
      detach_status = engine.detach(queue_h);
      if (detach_status == null)
        detach_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "event fixture detach returned null status");
      if (!detach_status.ok()) first_failure = detach_status;
    end
    request = rdma_destroy_resource_req::type_id::create("event_fixture_destroy");
    if (request == null) begin
      destroy_status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "event fixture destroy request allocation failed");
      status = first_failure == null ? destroy_status : first_failure;
      return;
    end
    request.owner = binding.make_handle();
    request.target_h = queue_h;
    queue_executor.destroy_locked(binding, binding.make_handle(), request,
                                  transaction_id, control_result);
    destroy_status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                         "event fixture destroy returned no control result") :
      control_result.status;
    if (destroy_status == null)
      destroy_status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "event fixture destroy returned null status");
    status = first_failure == null ? destroy_status : first_failure;
  endtask

  // 功能：destroy_lifecycle_owned_qp 按 created/attached 状态释放临时 QP；已
  //   attach 时先解除 queue-data link，随后始终由 executor 尝试 flush/delete/backing 回收。
  // 输入/输出及副作用：qp_h、created、attached、transaction_id 为输入，status
  //   为输出；未创建 QP 为空操作，不影响基础 fixture QP 或外部资源。
  // 失败边界：状态矛盾、destroy 依赖/handle/transaction 缺失，或 attached=1 时
  //   engine 缺失均拒绝；detach 失败仍执行 destroy，两者均失败时返回首个错误。
  task destroy_lifecycle_owned_qp(
    rdma_handle qp_h,
    bit created,
    bit attached,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_destroy_resource_req request;
    rdma_control_result control_result;
    rdma_status detach_status;
    rdma_status destroy_status;
    rdma_status first_failure;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event QP teardown is not initialized");
    first_failure = null;
    if (!created) begin
      if (attached)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "uncreated event QP is marked attached");
      else
        status = rdma_status::success();
      return;
    end
    if ((attached && engine == null) || qp_executor == null || binding == null ||
        qp_h == null || transaction_id == 0) return;
    if (attached) begin
      detach_status = engine.detach(qp_h);
      if (detach_status == null)
        detach_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "event QP detach returned null status");
      if (!detach_status.ok()) first_failure = detach_status;
    end
    request = rdma_destroy_resource_req::type_id::create("event_qp_destroy");
    if (request == null) begin
      destroy_status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "event QP destroy request allocation failed");
      status = first_failure == null ? destroy_status : first_failure;
      return;
    end
    request.owner = binding.make_handle();
    request.target_h = qp_h;
    qp_executor.destroy_locked(binding, binding.make_handle(), request,
                               transaction_id, control_result);
    destroy_status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "event QP destroy returned no control result") :
      control_result.status;
    if (destroy_status == null)
      destroy_status = rdma_status::make(
        RDMA_SC_INVALID_STATE, "event QP destroy returned null status");
    status = first_failure == null ? destroy_status : first_failure;
  endtask
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

  // 功能：check_atomic_model_projection 驱动带 compare/swap、local IOVA 和 lkey 的 RC 原子请求，验证 queue-data engine 生成的 SQE 镜像保留全部原子字段。
  // 输入/输出及副作用：无显式参数；任务创建并配置本地 fixture、发送一次原子请求、解码返回 image，并通过 UVM 报告暴露状态，不转移 fixture 资源所有权。
  // 失败/边界：fixture 初始化失败、请求校验/编码失败、返回 image 缺失、codec 解码失败或任一 atomic_local_iova/atomic_local_lkey/atomic_value/atomic_compare 不一致时报告 UVM_ERROR；失败请求不得发布成功 result。
  task automatic check_atomic_model_projection();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_sge local_sge;
    rdma_queue_post_result result;
    rdma_hw_model decoded_model;
    rdma_hw_sqe_model decoded_sqe;
    rdma_codec_base codec;
    rdma_codec_key key;
    rdma_status status;
    longint unsigned expected_local_iova;
    bit [31:0] expected_local_lkey;
    longint unsigned expected_compare;
    longint unsigned expected_swap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "atomic_projection_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("ATOMIC_FIXTURE", status == null ? "null setup status" :
                 status.convert2string())
      return;
    end
    request = fixture.make_send(64'h1234_5678_9abc_def0);
    request.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    request.remote_addr.value = 64'h0000_0000_0000_2000;
    request.rkey = 32'hcafebabe;
    request.remote_access_valid = 1'b1;
    request.rkey_valid = 1'b1;
    request.sges.delete();
    local_sge = rdma_sge::type_id::create("atomic_projection_local_sge");
    local_sge.iova.value = 64'h0000_0000_0000_8000;
    local_sge.length = 8;
    local_sge.lkey = 32'h8765_4321;
    request.sges.push_back(local_sge);
    request.compare_value = 64'h0123_4567_89ab_cdef;
    request.swap_add_value = 64'hfedc_ba98_7654_3210;
    expected_local_iova = local_sge.iova.value;
    expected_local_lkey = local_sge.lkey;
    expected_compare = request.compare_value;
    expected_swap = request.swap_add_value;

    result = null;
    fixture.engine.post_send(request, result, status);
    if (status == null || !status.ok() || result == null ||
        result.image == null) begin
      `uvm_error("ATOMIC_POST", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
            object_type:"sqe", variant:"rc", opcode:8'h00};
    status = fixture.registry.lookup(key, codec);
    if (status == null || !status.ok() || codec == null) begin
      `uvm_error("ATOMIC_CODEC", status == null ? "null codec status" :
                 status.convert2string())
      return;
    end
    status = codec.decode(result.image, decoded_model);
    if (status == null || !status.ok() ||
        !$cast(decoded_sqe, decoded_model) || decoded_sqe == null ||
        decoded_sqe.atomic_local_iova.value != expected_local_iova ||
        decoded_sqe.atomic_local_lkey != expected_local_lkey ||
        decoded_sqe.atomic_compare != expected_compare ||
        decoded_sqe.atomic_value != expected_swap)
      `uvm_error("ATOMIC_FIELDS", status == null ? "atomic image decode failed" :
                 status.convert2string())
  endtask

  // 功能：check_sgb_recovery_replays_slot 在首次 512-byte SQ SGB 写入失败后恢复 pending producer，验证恢复流程重新写入完整 SGB descriptor slot 再提交 64-byte WQE。
  // 输入/输出及副作用：无显式参数；任务创建本地 fixture、注入一次 host-memory 写故障、调用 recover_queue，并读取 SGB backing 与调用轨迹，不转移外部 backing 所有权。
  // 失败/边界：fixture/请求初始化失败、首次写入未进入 recovery、恢复未成功、恢复期间没有额外 512-byte write，或 SGB descriptor 未恢复时报告 UVM_ERROR；ambiguous MMIO 不得被该任务重试。
  task automatic check_sgb_recovery_replays_slot();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_sge sge;
    rdma_status status;
    rdma_status injected;
    byte sgb_data[];
    longint unsigned sgb_base;
    int unsigned trace_start;
    int unsigned sgb_write_count;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "sgb_recovery_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("SGB_FIXTURE", status == null ? "null setup status" :
                 status.convert2string())
      return;
    end
    request = fixture.make_send(64'h0bad_f00d_0000_0001);
    request.sges.delete();
    for (int unsigned i = 0; i < 3; i++) begin
      sge = rdma_sge::type_id::create($sformatf("sgb_recovery_sge%0d", i));
      sge.iova.value = 64'h0000_1000_0000_1000 + i * 64;
      sge.length = 8;
      sge.lkey = 32'ha0a0_a000 + i;
      request.sges.push_back(sge);
    end
    sgb_base = fixture.qp.qp_plan.sq_sgb_ref.mapping.iova.value +
               fixture.qp.qp_plan.sq_sgb_ref.mapping_offset;
    request.sgb_iova.value = sgb_base;
    trace_start = fixture.mem.calls.size();
    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "injected initial SGB write failure");
    fixture.mem.fail_next("write", injected);
    result = null;
    fixture.engine.post_send(request, result, status);
    if (status == null || status.ok() || result != null) begin
      `uvm_error("SGB_INITIAL_FAIL", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    fixture.engine.recover_queue(fixture.qp.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error("SGB_RECOVERY", status == null ? "null status" :
                 status.convert2string())
      return;
    end
    sgb_write_count = 0;
    for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
      if (fixture.mem.calls[i] != null &&
          fixture.mem.calls[i].method_name == "write" &&
          fixture.mem.calls[i].data.size() == 512)
        sgb_write_count++;
    if (sgb_write_count < 2)
      `uvm_error("SGB_RECOVERY_WRITE", "recovery did not rewrite 512-byte SGB slot")
    status = fixture.mem.read(fixture.qp.qp_plan.sq_sgb_ref.mapping,
                              fixture.qp.qp_plan.sq_sgb_ref.mapping_offset,
                              512, sgb_data);
    if (status == null || !status.ok() || sgb_data.size() != 512 ||
        sgb_data[3] != 8'h08 || sgb_data[4] != 8'ha0 ||
        sgb_data[7] != 8'h00 || sgb_data[19] != 8'h08 ||
        sgb_data[20] != 8'ha0 || sgb_data[23] != 8'h01 ||
        sgb_data[35] != 8'h08 || sgb_data[36] != 8'ha0 ||
        sgb_data[39] != 8'h02)
      `uvm_error("SGB_RECOVERY_DATA", status == null ? "SGB readback failed" :
                 status.convert2string())
  endtask

  // 功能：check_transport_link_mismatch 拦截“请求声明 transport 与已绑定
  // QP transport 不一致”的合法语义请求，验证 route authority 在写 SQE
  // 之前就 fail-closed。
  // 输入/输出及副作用：无显式参数；任务创建 RC fixture、构造字段完整的
  // UD SEND 请求并读取 SQ cursor，成功时只产生拒绝状态，不写入 host-memory
  // 或 doorbell 账本。
  // 失败/边界：若 mismatch 被错误放行、返回错误码不是 RDMA_SC_INVALID_STATE、
  // 发布 result 或推进 producer，任务报告 UVM_ERROR；fixture setup 失败时
  // 不继续访问未配置 engine。
  task automatic check_transport_link_mismatch();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_address_vector av;
    rdma_status status;
    int unsigned before_index;
    int unsigned after_index;
    int unsigned before_consumer;
    int unsigned after_consumer;
    bit before_wrap;
    bit after_wrap;
    bit before_consumer_wrap;
    bit after_consumer_wrap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "transport_mismatch_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("TRANSPORT_MISMATCH_FIXTURE",
                 status == null ? "null setup status" : status.convert2string())
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_index, before_wrap,
      before_consumer, before_consumer_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("TRANSPORT_MISMATCH_CURSOR",
                 status == null ? "null cursor status" : status.convert2string())
      return;
    end
    request = fixture.make_send(64'hdead_beef_0000_0001);
    request.transport = RDMA_TRANSPORT_UD;
    request.destination_qpn = 24'h000002;
    request.qkey = 32'h8001_0000;
    request.address_vector_valid = 1'b1;
    av = rdma_address_vector::type_id::create("transport_mismatch_av");
    av.destination_mac = 48'h0002_0000_0002;
    request.address_vector = av;
    request.completion_qp_h = null;
    result = null;
    fixture.engine.post_send(request, result, status);
    fixture.engine.query_runtime_cursors(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_index, after_wrap,
      after_consumer, after_consumer_wrap);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        result != null || after_index != before_index ||
        after_wrap != before_wrap || after_consumer != before_consumer ||
        after_consumer_wrap != before_consumer_wrap)
      `uvm_error("TRANSPORT_MISMATCH",
                 status == null ? "null mismatch status" : status.convert2string())
  endtask

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

    check_atomic_model_projection();
    check_transport_link_mismatch();
    check_sgb_recovery_replays_slot();

    phase.drop_objection(this);
  endtask

endclass
