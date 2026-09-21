// 目录：测试层 unit/rdma_queue_data_engine_post_test.sv。
// 职责：提供 queue-data engine 单元测试及跨 post/poll/CQ 测试复用的完整 lifecycle fixture。
// 依赖：依赖 UVM、resource/lifecycle executor、mock Host-memory/PCIe/CMQ/context
//       与 queue-data engine。
// 所有权与生命周期：fixture 拥有 Function、ACTIVE PD、owned CEQ/AEQ/CQ/QP，
//                   以及按需创建的 UD/URC transport QP；engine 只借用
//                   attachment，调用方必须执行聚合 cleanup。

// 中文说明：rdma_queue_data_engine_post_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 设计说明：该 probe 只把一个受保护的准备阶段暴露给 focused test，仍复用生产
// engine 的 configure/attach 与真实 registry，不复制或旁路 consumer admission。
// 它不改变生产类的可见接口，也不持有 fixture 资源；测试结束时由调用方显式
// detach，避免借用 attachment 跨过 reset/cleanup 生命周期。
class rdma_queue_data_engine_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_data_engine_probe)

  // 功能：构造 queue-data engine probe，沿用生产 engine 的默认未配置状态。
  // 输入/输出及副作用：name 为 UVM 对象名；仅调用基类构造，不接管 manager、
  //   binding、Host-memory、doorbell scheduler 或 codec registry。
  // 失败/边界：构造阶段不执行 configure/attach；调用方必须在调用 probe_prepare_cq
  //   前完成有效 binding、依赖和 CQ attachment，否则原样返回生产拒绝状态。
  function new(string name = "rdma_queue_data_engine_probe");
    super.new(name);
  endfunction

  // 功能：probe_validate_cq_poll_wq_attachment_fixture 在已 attach 的 QP/SQ 上
  //   构造最小冻结 send-CQE/link contract，并按 fault_kind 注入单一 hostile
  //   attachment 变形，再调用生产 selector 与 validator；该 probe 只为 focused
  //   contract test 暴露受保护只读 seam，不模拟完整 poll admission。
  // 输入/输出及副作用：qp_h、fault_kind 为输入；函数返回 validator status。测试
  //   fault_kind=0 验证正常 SQ，1 暂时置 runtime.depth=0，2 暂时置 entry_size=32，
  //   3 暂时置错误 backing role，4 暂时修改 attachment.queue_h generation；所有
  //   变形在 validator 返回后恢复，engine attachment、ledger、cursor 与外部资源
  //   ownership 不被永久修改。
  // 失败/边界：QP/SQ attachment、QP link、CQE 或 selector/validator 输入缺失时返回
  //   对应非成功 status；未知 fault_kind 返回 INVALID_ARGUMENT；该 helper 不调用
  //   snapshot/release/admission，不把临时 hostile 字段修改传播到 fixture cleanup。
  function rdma_status probe_validate_cq_poll_wq_attachment_fixture(
    rdma_handle qp_h,
    int unsigned fault_kind
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_hw_cqe_model cqe;
    rdma_handle target_h;
    rdma_queue_runtime_kind_e expected_kind;
    rdma_queue_backing_role_e expected_role;
    rdma_status status;
    int unsigned saved_depth;
    int unsigned saved_entry_size;
    rdma_queue_backing_role_e saved_role;
    int unsigned saved_generation;
    bit mutated;

    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ poll validator probe QP is invalid");
    status = lookup_attachment(qp_h, RDMA_QUEUE_RUNTIME_SQ, attachment);
    if (status == null || !status.ok() || attachment == null ||
        attachment.runtime == null)
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CQ poll validator probe SQ lookup returned null") :
        status;
    if (!qp_links.exists(identity_key(qp_h)) ||
        qp_links[identity_key(qp_h)] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ poll validator probe QP link is missing");
    link = qp_links[identity_key(qp_h)];
    cqe = rdma_hw_cqe_model::type_id::create(
      "cq_poll_validator_probe_cqe");
    if (cqe == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "CQ poll validator probe CQE allocation failed");
    cqe.rq_cqe = 1'b0;
    status = select_cq_poll_wq_target_contract(
      cqe, link, target_h, expected_kind, expected_role);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CQ poll validator probe selector returned null") :
        status;
    // 中文设计：probe 与生产 resolver 一样，以冻结 link 重新确认 selector 的
    // class-handle output；focused test 不应把 simulator 的 output 复制差异误报为
    // attachment validator 失败，真正的 hostile 变形仍由后续 validator 判定。
    if (expected_kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      if (target_h == null || !same_handle_instance(target_h, link.srq_h))
        target_h = link.srq_h;
    end
    else begin
      if (target_h == null || !same_handle_instance(target_h, link.qp_h))
        target_h = link.qp_h;
    end
    if (target_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CQ poll validator probe target is missing");
    saved_depth = attachment.runtime.depth;
    saved_entry_size = attachment.entry_size;
    saved_role = attachment.role;
    saved_generation = attachment.queue_h == null ? 0 :
                       attachment.queue_h.generation;
    mutated = 1'b0;
    case (fault_kind)
      0: begin end
      1: begin
        attachment.runtime.depth = 0;
        mutated = 1'b1;
      end
      2: begin
        attachment.entry_size = 32;
        mutated = 1'b1;
      end
      3: begin
        attachment.role = RDMA_QUEUE_ROLE_CQ_RING;
        mutated = 1'b1;
      end
      4: begin
        if (attachment.queue_h == null)
          return rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "CQ poll validator probe handle is missing");
        attachment.queue_h.generation = saved_generation ^ 32'h1;
        mutated = 1'b1;
      end
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ poll validator probe fault is unknown");
    endcase
    status = validate_cq_poll_wq_attachment(
      attachment, target_h, expected_kind, expected_role);
    if (mutated) begin
      attachment.runtime.depth = saved_depth;
      attachment.entry_size = saved_entry_size;
      attachment.role = saved_role;
      if (attachment.queue_h != null)
        attachment.queue_h.generation = saved_generation;
    end
    return status == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "CQ poll validator probe returned null status") :
      status;
  endfunction

  // 功能：probe_prepare_cq_consumer_doorbell 通过真实 CQ attachment 调用生产
  //   prepare_consumer_doorbell，观察 CQ consumer CI 是否错误地物化为 MMIO 描述符。
  // 输入/输出及副作用：cq_h/next 为输入；prepared_desc/prepared_status 为输出；
  //   只读 attachment、registry 和 binding，不提交 scheduler、不推进 runtime cursor。
  // 失败/边界：CQ lookup、next、依赖或生产 prepare 的任何拒绝均原样返回；成功
  //   返回时 descriptor/status 必须同时非空，调用方仍需验证 doorbell kind/offset。
  function rdma_status probe_prepare_cq_consumer_doorbell(
    rdma_handle cq_h,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_desc prepared_desc,
    output rdma_status prepared_status
  );
    rdma_queue_data_attachment attachment;
    rdma_status lookup_status;

    prepared_desc = null;
    prepared_status = null;
    lookup_status = lookup_attachment(
      cq_h, RDMA_QUEUE_RUNTIME_CQ, attachment);
    if (lookup_status == null || !lookup_status.ok())
      return lookup_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CQ probe attachment lookup returned null status") :
        lookup_status;
    return prepare_consumer_doorbell(
      attachment, next, null, prepared_desc, prepared_status);
  endfunction

  // 功能：probe_write_sgb_after_model_mutation 通过真实 SQ attachment 生成并
  //   编码一个 external-SGB SQE，然后在 image 已签名后按指定类别篡改 detached
  //   model，调用生产 write_sgb_and_verify 验证 canonical gate 与 signature gate。
  // 输入/输出及副作用：request、mutate_count、mutate_mode、mutate_descriptor 为
  //   输入；函数只可能写入当前 SQ SGB slot，返回 writer status；它不 reserve/commit
  //   runtime cursor，也不推进 PI、doorbell 或 recovery ledger，调用方负责比较
  //   Host-memory trace 并释放 fixture attachment。
  // 失败/边界：request/route/attachment、三项 SGE、SGB mapping、model/image 编码
  //   任一缺失或失败时原样返回；mutation 会在首次 writer Host-memory write 前
  //   被 canonical count/mode 或 SQ signature 拒绝，未授权的非 external-SGB model
  //   不能被该 probe 当作成功写入。
  function rdma_status probe_write_sgb_after_model_mutation(
    rdma_post_send_req request,
    bit mutate_count,
    bit mutate_mode,
    bit mutate_descriptor
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_hw_sqe_model model;
    rdma_hw_image image;
    rdma_status status;
    string variant;

    if (request == null || request.qp_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SGB mutation probe request is null");

    status = lookup_attachment(request.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                               attachment);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "SGB mutation probe SQ lookup returned null status") :
        status;
    if (!qp_links.exists(identity_key(request.qp_h)) ||
        qp_links[identity_key(request.qp_h)] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "SGB mutation probe QP route is unavailable");
    link = qp_links[identity_key(request.qp_h)];

    cursor = rdma_queue_cursor_snapshot::type_id::create(
      "sgb_mutation_probe_cursor");
    if (cursor == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "SGB mutation probe cursor allocation failed");
    cursor.index = 0;
    cursor.wrap = 1'b0;

    status = make_sqe(request, link, cursor, model);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "SGB mutation probe SQE construction returned null") :
        status;
    case (request.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "SGB mutation probe transport is unsupported");
    endcase
    status = encode_queue_model(model, RDMA_IMAGE_SQE, "sqe", variant, image);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_CODEC_ERROR,
                          "SGB mutation probe SQE encode returned null") :
        status;

    if (mutate_count)
      model.sge_num = model.sge_num + 8'd1;
    if (mutate_mode)
      model.payload_mode = RDMA_SQ_PAYLOAD_SGE_WQE;
    if (mutate_descriptor) begin
      if (model.sges.size() == 0 || model.sges[0] == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "SGB mutation probe has no descriptor");
      model.sges[0].length = model.sges[0].length + 32'd8;
    end

    return write_sgb_and_verify(link, model, cursor, image);
  endfunction
endclass

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
  rdma_function function_resource;
  rdma_pd pd;
  rdma_ceq ceq;
  rdma_aeq aeq;
  rdma_cq cq;
  rdma_qp qp;
  bit function_created;
  bit pd_created;
  bit pd_activated;
  bit ceq_created;
  bit aeq_created;
  bit cq_created;
  bit qp_created;
  bit ud_qp_created;
  bit urc_qp_created;
  bit cq_attached;
  bit ceq_attached;
  bit aeq_attached;
  bit qp_attached;
  // 附加 transport QP 也会在 engine 内建立 SQ/RQ attachment；这些标志必须
  // 与 created 标志分开，才能在共享 CQ/PD 销毁前按正确顺序撤销借用引用。
  bit ud_qp_attached;
  bit urc_qp_attached;
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
    function_resource = null; pd = null; ceq = null; aeq = null;
    cq = null; qp = null;
    function_created = 1'b0; pd_created = 1'b0; pd_activated = 1'b0;
    ceq_created = 1'b0; aeq_created = 1'b0; cq_created = 1'b0;
    qp_created = 1'b0; ud_qp_created = 1'b0; urc_qp_created = 1'b0;
    cq_attached = 1'b0;
    ceq_attached = 1'b0;
    aeq_attached = 1'b0;
    qp_attached = 1'b0;
    ud_qp_attached = 1'b0;
    urc_qp_attached = 1'b0;
    ud_qp = null; urc_qp = null;
  endfunction

  // 功能：make_binding 为 queue-data fixture 创建一份 ACTIVE Function binding，
  //   填充固定 identity、PCIe/BAR、DMA、queue capability 和中断向量 authority。
  // 输入/输出及副作用：name 为 UVM 对象名；返回由 fixture 持有的 binding，函数
  //   会调用 legacy mirror identity 配置并在失败时发布 `BINDING` UVM_ERROR。
  // 失败/边界：对象 factory 返回 null 时本 helper 无本地恢复；identity 配置失败
  //   只报告 UVM_ERROR 后继续返回 binding，不存在可供调用方检查的 status，也不重试。
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
    // 设计说明：额外发布 vector 2 以兼容仍显式请求该向量的局部拓扑；基础
    // fixture 的 CEQ/AEQ 均按统一 lifecycle 契约借用 vector 1，不假设独占向量。
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

  // 功能：setup_status 规范化 fixture setup 各阶段的返回状态，为失败消息补充
  //   stage 前缀，同时保持成功状态和原始错误类别可判别。
  // 输入/输出及副作用：stage、value 为输入；返回新的或原有 rdma_status，纯函数
  //   不更新 fixture ownership、attachment 标志或外部资源。
  // 失败/边界：value=null 时返回 RDMA_SC_INVALID_STATE；value 非 OK 时保留
  //   value.code 并拼接 stage/message；value OK 时原样返回，不执行回滚或重试。
  protected function rdma_status setup_status(string stage, rdma_status value);
    if (value == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               {stage, " returned null status"});
    if (value.ok())
      return value;
    return rdma_status::make(value.code, {stage, ": ", value.message});
  endfunction

  // 功能：setup 以可配置的 CQ/CEQ/AEQ depth 与 CQE stride 建立完整正向
  //   lifecycle fixture：Function、ACTIVE PD、owned CEQ/AEQ/CQ、RC QP 及
  //   queue-data engine。
  // 输入/输出及副作用：status 为输出；cq_depth/cqe_size/ceq_depth/aeq_depth
  //   为输入，enable_cq_context_shadow 选择是否把 CQC context backing 注入，
  //   enable_qpc_shadow_gate 再独立选择是否启用 QPC HW_DROP_DB_CNT gate；成功后
  //   use_prepare_probe 仅在 focused test 中选择受保护准备阶段 probe，生产 fixture
  //   默认仍实例化 rdma_queue_data_engine；
  //   engine 按 CQ→CEQ→AEQ→QP
  //   借用 attachment，资源销毁权仍归 executor/manager，并写入 mock Host-memory/CMQ。
  // 失败/边界：任一步 null/non-OK control status、cast、配置或 attach 失败时保留
  //   首个 setup status，调用 cleanup 继续撤销所有已建资源；CQ depth<16 仍由
  //   lifecycle policy 拒绝，失败不发布半初始化成功状态。
  task setup(
    output rdma_status status,
    input int unsigned cq_depth = 16,
    input int unsigned cqe_size = RDMA_CQE_BYTES,
    input int unsigned ceq_depth = 16,
    input int unsigned aeq_depth = 16,
    input bit enable_cq_context_shadow = 1'b0,
    input bit enable_qpc_shadow_gate = 1'b0,
    input bit use_prepare_probe = 1'b0
  );
    rdma_create_ceq_req ceq_request;
    rdma_create_aeq_req aeq_request;
    rdma_create_cq_req cq_request;
    rdma_create_qp_req qp_request;
    rdma_queue_resource queue;
    rdma_control_result control_result;
    rdma_status cleanup_status;

    status = null;
    function_resource = null; pd = null; ceq = null; aeq = null;
    cq = null; qp = null; ud_qp = null; urc_qp = null;
    function_created = 1'b0; pd_created = 1'b0; pd_activated = 1'b0;
    ceq_created = 1'b0; aeq_created = 1'b0; cq_created = 1'b0;
    qp_created = 1'b0; ud_qp_created = 1'b0; urc_qp_created = 1'b0;
    cq_attached = 1'b0;
    ceq_attached = 1'b0;
    aeq_attached = 1'b0;
    qp_attached = 1'b0;
    ud_qp_attached = 1'b0;
    urc_qp_attached = 1'b0;
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
    engine = use_prepare_probe ?
      rdma_queue_data_engine_probe::type_id::create({get_name(), "_engine"}) :
      rdma_queue_data_engine::type_id::create({get_name(), "_engine"});

    // 中文设计：setup_flow 只负责建立资源；所有失败使用 disable 跳到统一
    // epilogue，使 partial setup 与 normal cleanup 共享同一逆序释放实现。
    begin : setup_flow
      status = setup_status("create_function",
                            manager.create_function(binding, function_resource));
      if (!status.ok() || function_resource == null) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "Function fixture creation returned null");
        disable setup_flow;
      end
      function_created = 1'b1;
      status = setup_status("create_pd", manager.create_pd(binding, pd));
      if (!status.ok() || pd == null) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "PD fixture creation returned null");
        disable setup_flow;
      end
      pd_created = 1'b1;
      status = setup_status("activate_pd", manager.activate(pd.handle));
      if (!status.ok()) disable setup_flow;
      pd_activated = 1'b1;
      status = setup_status("queue_executor.configure",
                            queue_executor.configure(manager, cmq, mem,
                                                      contexts, 2us));
      if (!status.ok()) disable setup_flow;

      ceq_request = rdma_create_ceq_req::type_id::create(
        {get_name(), "_ceq_request"});
      if (ceq_request == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "CEQ request allocation failed");
        disable setup_flow;
      end
      ceq_request.owner = binding.make_handle();
      ceq_request.depth = ceq_depth;
      ceq_request.vector_id = 1;
      ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      queue = null; control_result = null;
      queue_executor.create_locked(binding, binding.make_handle(), ceq_request,
                                   64'h1001, queue, control_result);
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CEQ fixture creation returned no status") :
        setup_status("CEQ create", control_result.status);
      if (!status.ok() || queue == null || !$cast(ceq, queue)) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "CEQ fixture creation returned wrong resource");
        disable setup_flow;
      end
      ceq_created = 1'b1;

      aeq_request = rdma_create_aeq_req::type_id::create(
        {get_name(), "_aeq_request"});
      if (aeq_request == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "AEQ request allocation failed");
        disable setup_flow;
      end
      aeq_request.owner = binding.make_handle();
      aeq_request.depth = aeq_depth;
      aeq_request.vector_id = 1;
      aeq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      queue = null; control_result = null;
      queue_executor.create_locked(binding, binding.make_handle(), aeq_request,
                                   64'h1002, queue, control_result);
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "AEQ fixture creation returned no status") :
        setup_status("AEQ create", control_result.status);
      if (!status.ok() || queue == null || !$cast(aeq, queue)) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "AEQ fixture creation returned wrong resource");
        disable setup_flow;
      end
      aeq_created = 1'b1;

      cq_request = rdma_create_cq_req::type_id::create(
        {get_name(), "_cq_request"});
      if (cq_request == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "CQ request allocation failed");
        disable setup_flow;
      end
      cq_request.owner = binding.make_handle();
      cq_request.depth = cq_depth;
      cq_request.cqe_size_bytes = cqe_size;
      cq_request.ceq_h = rdma_clone_handle_value(ceq.handle,
                                                  "fixture CQ CEQ");
      cq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
      if (cq_request.ceq_h == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "CQ CEQ handle clone failed");
        disable setup_flow;
      end
      queue = null; control_result = null;
      queue_executor.create_locked(binding, binding.make_handle(), cq_request,
                                   64'h1003, queue, control_result);
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "CQ fixture creation returned no status") :
        setup_status("CQ create", control_result.status);
      if (!status.ok() || queue == null || !$cast(cq, queue)) begin
        if (status.ok()) status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "CQ fixture creation returned wrong resource");
        disable setup_flow;
      end
      cq_created = 1'b1;

      status = setup_status("qp_executor.configure",
                            qp_executor.configure(manager, cmq, mem,
                                                  contexts, 2us));
      if (!status.ok()) disable setup_flow;
      qp_request = rdma_create_qp_req::type_id::create(
        {get_name(), "_qp_request"});
      if (qp_request == null) begin
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "QP request allocation failed");
        disable setup_flow;
      end
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
      control_result = null;
      qp_executor.create_locked(binding, binding.make_handle(), qp_request,
                                64'h1004, qp, control_result);
      status = control_result == null || control_result.status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "QP fixture creation returned no status") :
        setup_status("QP create", control_result.status);
      if (!status.ok() || qp == null) disable setup_flow;
      qp_created = 1'b1;

      status = setup_status("scheduler.configure", scheduler.configure(mem, pcie));
      if (!status.ok()) disable setup_flow;
      status = setup_status("registry.register_defaults",
                            registry.register_defaults());
      if (!status.ok()) disable setup_flow;
      status = setup_status("register_queue_codecs",
                            rdma_register_queue_codecs(registry));
      if (!status.ok()) disable setup_flow;
      status = setup_status(
        "engine.configure",
        engine.configure(
          manager, binding, mem, scheduler, registry, 2us,
          enable_cq_context_shadow ? contexts : null,
          enable_qpc_shadow_gate));
      if (!status.ok()) disable setup_flow;
      status = setup_status("engine.attach_cq",
                            engine.attach_cq(cq.handle, RDMA_TRANSPORT_RC));
      if (!status.ok()) disable setup_flow;
      cq_attached = 1'b1;
      status = setup_status("engine.attach_ceq", engine.attach_ceq(ceq.handle));
      if (!status.ok()) disable setup_flow;
      ceq_attached = 1'b1;
      status = setup_status("engine.attach_aeq", engine.attach_aeq(aeq.handle));
      if (!status.ok()) disable setup_flow;
      aeq_attached = 1'b1;
      status = setup_status("engine.attach_qp", engine.attach_qp(qp.handle));
      if (!status.ok()) disable setup_flow;
      qp_attached = 1'b1;
    end
    if (status == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "fixture setup returned null status");
    if (!status.ok()) begin
      cleanup(cleanup_status);
      if (cleanup_status == null)
        status.message = {status.message, "; cleanup returned null status"};
      else if (!cleanup_status.ok())
        status.message = {status.message, "; cleanup: ", cleanup_status.message};
    end
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
    // UD 的单 slot inline authority 是 512B；focused capacity negative 必须让
    // 513B 请求越过合法 512B QP capability 基线，才能观察 codec/backing admission
    // 是否在 reservation/recovery 前 fail closed。RC/URC 保持 32B fixture 上限。
    request.max_inline_data = transport == RDMA_TRANSPORT_UD ? 512 : 32;
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
    ud_qp_created = 1'b1;
    create_transport_qp("urc", RDMA_TRANSPORT_URC, urc_qp, status);
    if (status != null && status.ok()) urc_qp_created = 1'b1;
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

  // 功能：set_qpc_shadow_counts 以驱动 wr.h 的 qword63 坐标写入 QP context
  //   runtime shadow，构造 HW_DROP_DB_CNT[54:48] 与 SW_RING_DB_CNT[38:32]。
  // 输入/输出及副作用：hw_drop_db_count、sw_ring_db_count 为 7-bit 输入；
  //   函数通过 context backing 写入 byte504 的 8-byte big-endian qword，不修改
  //   QP semantic model、SQ runtime cursor 或 doorbell scheduler。
  // 失败/边界：QP/context authority 缺失、字段超出 7 bit、写入失败或 shadow
  //   geometry 不匹配时返回错误；不会用 QPC canonical codec 伪造 runtime shadow。
  function rdma_status set_qpc_shadow_counts(
    bit [6:0] hw_drop_db_count,
    bit [6:0] sw_ring_db_count
  );
    rdma_context_backing_ref context_ref;
    longint unsigned qword;
    byte unsigned data[];

    if (contexts == null || qp == null || qp.qp_plan == null ||
        qp.qp_plan.context_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context authority is unavailable");
    context_ref = qp.qp_plan.context_ref;
    qword = (longint'(hw_drop_db_count) << 48) |
             (longint'(sw_ring_db_count) << 32);
    data = new[8];
    for (int unsigned i = 0; i < 8; i++)
      data[i] = qword >> (56 - 8 * i);
    return contexts.write(context_ref,
                          RDMA_QPC_RUNTIME_SHADOW_BYTE_OFFSET, data);
  endfunction

  // 功能：write_cq_entry 仅作为 malformed image/owner mismatch 的 raw backing
  //   故障注入器；它故意绕过 runtime reservation/commit，严禁用于正向 CQE 生成。
  // 输入/输出及副作用：index/model 为输入；按 CQ attachment 的 cqe_size_bytes
  //   计算 slot offset 并直接改写 mock Host-memory，不推进 PI/CI、occupancy、WQE
  //   ledger 或 pending，调用方仍拥有 model/image 及后续故障清理责任。
  // 失败/边界：codec、backing、mapping、范围或 DMA 写入失败时返回原始 status；
  //   即使写入成功也没有 committed entry，调用方不得 poll 该字节来伪造 completion。
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
                     backing.mapping_offset +
                       longint'(index) * longint'(cq.cqe_size_bytes), data);
  endfunction

  // 功能：read_cq_entry 通过 fixture 管理的 CQ backing 读取指定已发布槽位，供
  //   publish 测试核对真实 Host-memory bytes，而不向测试暴露可修改 mapping 引用。
  // 输入/输出及副作用：index、size 为输入，data 为输出；函数只读取 fixture 所有的
  //   CQ queue plan 与 mock Host-memory，不推进 runtime cursor 或修改 backing。
  // 失败/边界：CQ backing/mapping 缺失、size 为零或读越界时返回非成功 status，
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

  // 功能：needs_cleanup 只根据 fixture 自身登记的 lifecycle ownership 与
  //   attachment 标志，判断调用方是否仍须执行聚合 cleanup。
  // 输入/输出及副作用：无输入；返回任一 created/activated/attached 标志的 OR，
  //   不查询 engine/manager 私有表，也不修改资源、引用或状态。
  // 失败/边界：完全未 setup 或 setup 失败且已完整回收时返回 0；partial cleanup
  //   遗留任一 ownership/attachment 标志时返回 1，以允许调用方显式重试。
  function bit needs_cleanup();
    return function_created || pd_created || pd_activated ||
           ceq_created || aeq_created || cq_created || qp_created ||
           ud_qp_created || urc_qp_created || cq_attached ||
           ceq_attached || aeq_attached || qp_attached ||
           ud_qp_attached || urc_qp_attached;
  endfunction

  // 功能：cleanup 统一撤销 fixture 的 attachment 与 lifecycle 资源，严格按
  //   detach(URC/UD/基础 QP/CQ/CEQ/AEQ)→destroy(URC/UD/基础 QP/CQ/CEQ/AEQ)
  //   →PD→Function 顺序执行，附加 transport QP 必须先于其共享 CQ/PD 销毁。
  // 输入/输出及副作用：status 为输出；task 读取 setup 记录的 created/attached
  //   状态，驱动 engine、executor 与 manager 回收 owned backing/context；engine
  //   仅借用这些对象，cleanup 不释放外部 PCIe/Host-memory adapter 本身。
  // 失败/边界：每个 null status 规范化为 INVALID_STATE，保存首个失败并继续后续
  //   cleanup；重复调用对已成功回收的阶段为空操作，detach 失败也绝不跳过 destroy。
  task cleanup(output rdma_status status);
    rdma_status first_failure;
    rdma_status stage_status;

    first_failure = null;
    // 中文设计：先解除全部非拥有引用，再触碰任一 lifecycle owner，避免后续
    // destroy 因 engine attachment 仍存活而早退，并保证单个 detach 失败不泄漏其余资源。
    // transport QP 必须排在共享 CQ 之前；否则 qp_links 会继续引用旧 route，
    // 而 CQ 的 detach/release 已经使该 route 无法再被 recovery 完整定位。
    if (urc_qp_attached) begin
      stage_status = (engine == null || urc_qp == null) ? null :
                     engine.detach(urc_qp.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture URC QP detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok())
        urc_qp_attached = 1'b0;
    end
    if (ud_qp_attached) begin
      stage_status = (engine == null || ud_qp == null) ? null :
                     engine.detach(ud_qp.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture UD QP detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok())
        ud_qp_attached = 1'b0;
    end
    if (qp_attached) begin
      stage_status = engine == null ? null : engine.detach(qp.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture QP detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) qp_attached = 1'b0;
    end
    if (cq_attached) begin
      stage_status = engine == null ? null : engine.detach(cq.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture CQ detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) cq_attached = 1'b0;
    end
    if (ceq_attached) begin
      stage_status = engine == null ? null : engine.detach(ceq.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture CEQ detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) ceq_attached = 1'b0;
    end
    if (aeq_attached) begin
      stage_status = engine == null ? null : engine.detach(aeq.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture AEQ detach returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) aeq_attached = 1'b0;
    end

    // 中文设计：所有 detach 均已尝试后才逆序销毁；transport QP 的 attached
    // 状态作为第二道保护传给 destroy helper，使首次 detach 失败时 helper 仍
    // 会重试，而不会把残留 qp_links 隐藏成普通资源销毁。
    if (urc_qp_created) begin
      destroy_lifecycle_owned_qp(urc_qp == null ? null : urc_qp.handle,
                                 1'b1, urc_qp_attached, 64'h2011,
                                 stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture URC QP destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) begin
        urc_qp_created = 1'b0;
        urc_qp_attached = 1'b0;
        urc_qp = null;
      end
    end
    if (ud_qp_created) begin
      destroy_lifecycle_owned_qp(ud_qp == null ? null : ud_qp.handle,
                                 1'b1, ud_qp_attached, 64'h2010,
                                 stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture UD QP destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) begin
        ud_qp_created = 1'b0;
        ud_qp_attached = 1'b0;
        ud_qp = null;
      end
    end
    // 基础 QP 即使先前 detach 失败也仍交给 executor 尝试 destroy，使首错与
    // 最大化回收兼得；CQ/CEQ/AEQ 随后按依赖反序释放。
    if (qp_created) begin
      destroy_lifecycle_owned_qp(qp == null ? null : qp.handle,
                                 1'b1, 1'b0, 64'h2004, stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture QP destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) qp_created = 1'b0;
    end
    if (cq_created) begin
      destroy_lifecycle_owned_queue(cq == null ? null : cq.handle,
                                    1'b1, 1'b0, 64'h2003, stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture CQ destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) cq_created = 1'b0;
    end
    if (ceq_created) begin
      destroy_lifecycle_owned_queue(ceq == null ? null : ceq.handle,
                                    1'b1, 1'b0, 64'h2001, stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture CEQ destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) ceq_created = 1'b0;
    end
    if (aeq_created) begin
      destroy_lifecycle_owned_queue(aeq == null ? null : aeq.handle,
                                    1'b1, 1'b0, 64'h2002, stage_status);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture AEQ destroy returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) aeq_created = 1'b0;
    end

    if (pd_created) begin
      // 中文设计：activate 之前失败的 PD 仍处于 ALLOCATED，只能走
      // release_reserved；ACTIVE PD 才执行 quiesce→finalize，避免 partial setup
      // 把合法的未激活资源误报为 cleanup 失败。
      if (pd_activated) begin
        stage_status = manager == null || pd == null ? null :
          manager.begin_quiesce(pd.handle);
        if (stage_status == null)
          stage_status = rdma_status::make(
            RDMA_SC_INVALID_STATE, "fixture PD quiesce returned null status");
        if (!stage_status.ok() && first_failure == null)
          first_failure = stage_status;
        stage_status = manager == null || pd == null ? null :
          manager.finalize_release(pd.handle);
      end
      else
        stage_status = manager == null || pd == null ? null :
          manager.release_reserved(pd.handle);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture PD release returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) begin
        pd_created = 1'b0;
        pd_activated = 1'b0;
      end
    end
    if (function_created) begin
      stage_status = manager == null || function_resource == null ? null :
        manager.release_function(function_resource.owner);
      if (stage_status == null)
        stage_status = rdma_status::make(
          RDMA_SC_INVALID_STATE, "fixture Function release returned null status");
      if (!stage_status.ok() && first_failure == null)
        first_failure = stage_status;
      if (stage_status.ok()) function_created = 1'b0;
    end
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：advance_binding_reset_epoch 通过 binding 的公开 identity 配置接口发布
  //   新 reset epoch，模拟 attachment 冻结 route 后外部 Function 已复位。
  // 输入/输出及副作用：next_epoch 为输入；成功时替换 binding 内部 authority snapshot，
  //   不修改已 attach runtime、queue handle、mapping 或 Host-memory 内容。
  // 失败/边界：binding/旧 identity 缺失、next_epoch 为零或 identity 配置失败时返回
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
  // 失败/边界：状态矛盾、destroy 依赖/handle/transaction 缺失，或 attached=1 时
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
  // 失败/边界：状态矛盾、destroy 依赖/handle/transaction 缺失，或 attached=1 时
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
  // 失败/边界：fixture 初始化失败、请求校验/编码失败、返回 image 缺失、codec
  //   解码或原子字段不一致时报告 UVM_ERROR；所有分支进入 epilogue 聚合 cleanup。
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
    rdma_status cleanup_status;
    longint unsigned expected_local_iova;
    bit [31:0] expected_local_lkey;
    longint unsigned expected_compare;
    longint unsigned expected_swap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "atomic_projection_fixture");
    begin : atomic_projection_flow
      if (fixture == null) begin
        `uvm_error("ATOMIC_FIXTURE", "fixture allocation failed")
        disable atomic_projection_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("ATOMIC_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable atomic_projection_flow;
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
        disable atomic_projection_flow;
      end
      key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
              object_type:"sqe", variant:"rc", opcode:8'h00};
      status = fixture.registry.lookup(key, codec);
      if (status == null || !status.ok() || codec == null) begin
        `uvm_error("ATOMIC_CODEC", status == null ? "null codec status" :
                   status.convert2string())
        disable atomic_projection_flow;
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
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("ATOMIC_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_sgb_recovery_replays_slot 在首次 512-byte SQ SGB 写入失败后恢复 pending producer，验证恢复流程重新写入完整 SGB descriptor slot 再提交 64-byte WQE。
  // 输入/输出及副作用：无显式参数；任务创建本地 fixture、注入一次 host-memory 写故障、调用 recover_queue，并读取 SGB backing 与调用轨迹，不转移外部 backing 所有权。
  // 失败/边界：fixture/请求初始化失败、首次写入未进入 recovery、恢复未成功、
  //   未重写 512-byte SGB slot 或 descriptor 不符时报告，并在 epilogue cleanup；
  //   ambiguous MMIO 不得被该任务重试。
  task automatic check_sgb_recovery_replays_slot();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_sge sge;
    rdma_status status;
    rdma_status injected;
    rdma_status cleanup_status;
    byte sgb_data[];
    longint unsigned sgb_base;
    int unsigned trace_start;
    int unsigned sgb_write_count;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "sgb_recovery_fixture");
    begin : sgb_recovery_flow
      if (fixture == null) begin
        `uvm_error("SGB_FIXTURE", "fixture allocation failed")
        disable sgb_recovery_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("SGB_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable sgb_recovery_flow;
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
        disable sgb_recovery_flow;
      end
      fixture.engine.recover_queue(fixture.qp.handle,
        RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
      if (status == null || !status.ok()) begin
        `uvm_error("SGB_RECOVERY", status == null ? "null status" :
                   status.convert2string())
        disable sgb_recovery_flow;
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
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SGB_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_sgb_writer_rejects_post_encode_mutation 验证 SQ external-SGB
  //   writer 在 image 已签名后仍以 canonical authority 保护首次 backing write：
  //   分别篡改 sge_num、payload_mode，以及保持 count 不变但改写 descriptor length。
  // 输入/输出及副作用：任务创建使用真实 attachment/codec registry 的 probe fixture，
  //   读取 Host-memory call trace；每个 mutation 只生成 detached model，不 reserve
  //   runtime、不推进 PI/doorbell，也不取得 SGE、mapping 或 fixture 资源所有权。
  // 失败/边界：fixture/probe/SGB route 缺失、任一 mutation 返回 OK、status 为空，
  //   或首次 writer 调用新增任何 Host-memory call（尤其 512-byte SGB/64-byte SQ
  //   write）均报告错误；mode mutation 可返回 INVALID_ARGUMENT，count/descriptor
  //   mutation 预期返回 INVALID_STATE，但三者都必须在写入前 fail-closed。
  task automatic check_sgb_writer_rejects_post_encode_mutation();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_probe probe;
    rdma_post_send_req request;
    rdma_sge sge;
    rdma_status status;
    rdma_status cleanup_status;
    longint unsigned sgb_base;
    int unsigned trace_start;
    int unsigned write_calls;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "sgb_mutation_fixture");
    begin : sgb_mutation_flow
      if (fixture == null) begin
        `uvm_error("SGB_MUTATION_FIXTURE", "fixture allocation failed")
        disable sgb_mutation_flow;
      end
      // use_prepare_probe 只暴露受保护 writer；所有 route、mapping、codec 和
      // lifecycle authority 仍由生产 fixture 建立，测试不复制 queue admission。
      fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b0, 1'b0, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("SGB_MUTATION_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable sgb_mutation_flow;
      end
      if (!$cast(probe, fixture.engine) || probe == null) begin
        `uvm_error("SGB_MUTATION_PROBE", "fixture did not create writer probe")
        disable sgb_mutation_flow;
      end

      request = fixture.make_send(64'h0bad_f00d_0000_0010);
      request.sges.delete();
      for (int unsigned i = 0; i < 3; i++) begin
        sge = rdma_sge::type_id::create($sformatf("sgb_mutation_sge%0d", i));
        sge.iova.value = 64'h0000_1000_0000_2000 + i * 64;
        sge.length = 8;
        sge.lkey = 32'hb0b0_b000 + i;
        request.sges.push_back(sge);
      end
      sgb_base = fixture.qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                 fixture.qp.qp_plan.sq_sgb_ref.mapping_offset;
      request.sgb_iova.value = sgb_base;

      trace_start = fixture.mem.calls.size();
      status = probe.probe_write_sgb_after_model_mutation(
        request, 1'b0, 1'b0, 1'b0);
      write_calls = 0;
      for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "write")
          write_calls++;
      if (status == null || !status.ok() || fixture.mem.calls.size() <= trace_start ||
          write_calls == 0)
        `uvm_error("SGB_MUTATION_BASELINE",
                   status == null ? "baseline writer returned null status" :
                   $sformatf("baseline status=%s calls=%0d writes=%0d",
                             status.convert2string(),
                             fixture.mem.calls.size() - trace_start,
                             write_calls))

      trace_start = fixture.mem.calls.size();
      status = probe.probe_write_sgb_after_model_mutation(
        request, 1'b1, 1'b0, 1'b0);
      write_calls = 0;
      for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "write")
          write_calls++;
      if (status == null || status.ok() || fixture.mem.calls.size() != trace_start ||
          write_calls != 0)
        `uvm_error("SGB_MUTATION_COUNT",
                   status == null ? "count mutation returned null status" :
                   $sformatf("count mutation status=%s calls=%0d writes=%0d",
                             status.convert2string(),
                             fixture.mem.calls.size() - trace_start,
                             write_calls))

      trace_start = fixture.mem.calls.size();
      status = probe.probe_write_sgb_after_model_mutation(
        request, 1'b0, 1'b1, 1'b0);
      write_calls = 0;
      for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "write")
          write_calls++;
      if (status == null || status.ok() || fixture.mem.calls.size() != trace_start ||
          write_calls != 0)
        `uvm_error("SGB_MUTATION_MODE",
                   status == null ? "mode mutation returned null status" :
                   $sformatf("mode mutation status=%s calls=%0d writes=%0d",
                             status.convert2string(),
                             fixture.mem.calls.size() - trace_start,
                             write_calls))

      trace_start = fixture.mem.calls.size();
      status = probe.probe_write_sgb_after_model_mutation(
        request, 1'b0, 1'b0, 1'b1);
      write_calls = 0;
      for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
        if (fixture.mem.calls[i] != null &&
            fixture.mem.calls[i].method_name == "write")
          write_calls++;
      if (status == null || status.ok() || fixture.mem.calls.size() != trace_start ||
          write_calls != 0)
        `uvm_error("SGB_MUTATION_DESCRIPTOR",
                   status == null ? "descriptor mutation returned null status" :
                   $sformatf("descriptor mutation status=%s calls=%0d writes=%0d",
                             status.convert2string(),
                             fixture.mem.calls.size() - trace_start,
                             write_calls))
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SGB_MUTATION_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_ud_effective_sgb_writer_paths 通过真实 UD SQ attachment、共享
  //   make_sqe/codec 和生产 SGB writer，验证非零 inline、一个 SGE 与两个 SGE
  //   都使用 transport-aware external-SGB mode，并能在 signature gate 后完成
  //   detached 512-byte backing 写入。
  // 输入/输出及副作用：任务只创建 focused probe fixture，request/model/image 为
  //   detached 输入快照；probe 允许 writer 写入当前 UD SQ SGB slot，任务读取
  //   Host-memory trace，不推进 runtime cursor、PI、doorbell 或 completion ledger。
  // 失败/边界：fixture/UD route/SGB mapping、codec 或 writer 返回 null/non-OK，
  //   或合法 variant 没有新增 Host-memory write 时报告 UVM_ERROR；只覆盖非零
  //   payload 的 effective mode 对齐，zero-byte inline 仍由既有 codec 场景负责。
  task automatic check_ud_effective_sgb_writer_paths();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_probe probe;
    rdma_post_send_req request;
    rdma_address_vector av;
    rdma_sge sge;
    rdma_status status;
    rdma_status cleanup_status;
    longint unsigned sgb_base;
    int unsigned trace_start;
    int unsigned write_calls;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "ud_effective_sgb_fixture");
    begin : ud_effective_sgb_flow
      if (fixture == null) begin
        `uvm_error("UD_EFFECTIVE_SGB_FIXTURE", "fixture allocation failed")
        disable ud_effective_sgb_flow;
      end
      fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b0, 1'b0, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_EFFECTIVE_SGB_FIXTURE",
                   status == null ? "null setup status" :
                                    status.convert2string())
        disable ud_effective_sgb_flow;
      end
      fixture.create_transport_qp(
        "ud_effective_sgb", RDMA_TRANSPORT_UD, fixture.ud_qp, status);
      if (status == null || !status.ok() || fixture.ud_qp == null) begin
        `uvm_error("UD_EFFECTIVE_SGB_FIXTURE",
                   status == null ? "null UD QP status" :
                                    status.convert2string())
        disable ud_effective_sgb_flow;
      end
      fixture.ud_qp_created = 1'b1;
      status = fixture.engine.attach_qp(fixture.ud_qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_EFFECTIVE_SGB_FIXTURE",
                   status == null ? "null UD attach status" :
                                    status.convert2string())
        disable ud_effective_sgb_flow;
      end
      fixture.ud_qp_attached = 1'b1;
      if (fixture.ud_qp.qp_plan == null ||
          fixture.ud_qp.qp_plan.sq_sgb_ref == null ||
          fixture.ud_qp.qp_plan.sq_sgb_ref.mapping == null) begin
        `uvm_error("UD_EFFECTIVE_SGB_FIXTURE",
                   "UD SQ-SGB mapping authority is unavailable")
        disable ud_effective_sgb_flow;
      end
      if (!$cast(probe, fixture.engine) || probe == null) begin
        `uvm_error("UD_EFFECTIVE_SGB_PROBE",
                   "fixture did not create queue-data probe")
        disable ud_effective_sgb_flow;
      end

      sgb_base = fixture.ud_qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                 fixture.ud_qp.qp_plan.sq_sgb_ref.mapping_offset;
      for (int unsigned sge_count = 0; sge_count <= 2; sge_count++) begin
        request = fixture.make_send(
          64'h0d00_0000_0000_0000 + sge_count);
        request.qp_h = rdma_clone_handle_value(
          fixture.ud_qp.handle, "UD effective mode QP");
        request.transport = RDMA_TRANSPORT_UD;
        request.opcode = RDMA_WR_SEND;
        request.destination_qpn = 24'h123;
        request.qkey = 32'h8001_0000;
        request.address_vector_valid = 1'b1;
        av = rdma_address_vector::type_id::create(
          $sformatf("ud_effective_mode_av%0d", sge_count));
        av.destination_mac = 48'h0011_2233_4455;
        request.address_vector = av;
        request.sgb_iova.value = sgb_base;
        request.sges.delete();
        request.payload.delete();
        request.inline_data = sge_count == 0;
        if (sge_count == 0) begin
          request.payload.push_back(8'h5a);
        end
        else begin
          for (int unsigned i = 0; i < sge_count; i++) begin
            sge = rdma_sge::type_id::create(
              $sformatf("ud_effective_mode_sge%0d_%0d", sge_count, i));
            sge.iova.value = 64'h0000_1000_0000_4000 + i * 64;
            sge.length = 8;
            sge.lkey = 32'hc0de_1000 + i;
            request.sges.push_back(sge);
          end
        end

        trace_start = fixture.mem.calls.size();
        status = probe.probe_write_sgb_after_model_mutation(
          request, 1'b0, 1'b0, 1'b0);
        write_calls = 0;
        for (int unsigned i = trace_start; i < fixture.mem.calls.size(); i++)
          if (fixture.mem.calls[i] != null &&
              fixture.mem.calls[i].method_name == "write")
            write_calls++;
        if (status == null || !status.ok() || write_calls == 0)
          `uvm_error("UD_EFFECTIVE_SGB_PATH",
                     status == null ?
                       $sformatf("variant=%0d returned null status", sge_count) :
                       $sformatf("variant=%0d status=%s writes=%0d",
                                 sge_count, status.convert2string(), write_calls))
      end
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("UD_EFFECTIVE_SGB_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_sgb_filters_zero_length_descriptors 验证 SQ external-SGB
  //   mixed-zero post 把同一 result.index 的 64-byte header 与 512-byte backing
  //   联合持久化：header 发布三个有效描述符、48-byte TPL 和精确 SGB_PA，backing
  //   跳过零长度前缀并压紧三个 descriptor，二者共同满足生产 signature validator。
  // 输入/输出及副作用：任务创建独立 fixture，提交一个含零长度前缀和三个
  //   有效 SGE 的 RC SEND；按 result.index 读取真实 SQ slot 与 SGB slot，解码
  //   actual header 并校验完整 backing，fixture 资源仍由本任务清理。
  // 失败/边界：setup/post、任一 readback、raw field/codec decode/signature 失败，
  //   header 与返回 image 不同、SGE_NUM/SGB_PA/TPL 不符、三个描述符未连续压紧
  //   或 byte48..511 任一非零时报告 UVM_ERROR；原始 SGE 数超过 32 的拒绝不在本任务范围。
  task automatic check_sgb_filters_zero_length_descriptors();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_sge sge;
    rdma_status status;
    rdma_status field_status;
    rdma_status cleanup_status;
    rdma_hw_qword_builder sqe_builder;
    rdma_hw_qword_builder sgb_builder;
    rdma_hw_image actual_sqe_image;
    rdma_hw_model decoded_model;
    rdma_hw_sqe_model decoded_sqe;
    rdma_codec_base codec;
    rdma_codec_key key;
    bit [63:0] sqe_words[];
    bit [63:0] sgb_words[];
    bit [63:0] raw_sge_num;
    bit [63:0] raw_sgb_pa;
    bit [63:0] raw_tpl;
    bit signature_valid;
    byte sqe_data[];
    byte sgb_data[];
    byte unsigned signature_sgb[$];
    longint unsigned sgb_base;
    longint unsigned actual_sgb_iova;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "sgb_filter_fixture");
    begin : sgb_filter_flow
      if (fixture == null) begin
        `uvm_error("SGB_FILTER_FIXTURE", "fixture allocation failed")
        disable sgb_filter_flow;
      end

      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("SGB_FILTER_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable sgb_filter_flow;
      end

      request = fixture.make_send(64'h0bad_f00d_0000_0004);
      request.sges.delete();

      sge = rdma_sge::type_id::create("sgb_filter_zero_prefix");
      sge.length = 0;
      sge.lkey = 32'hdead_beef;
      sge.iova.value = 64'h1111_0000;
      request.sges.push_back(sge);

      for (int unsigned i = 0; i < 3; i++) begin
        sge = rdma_sge::type_id::create($sformatf("sgb_filter_valid_%0d", i));
        sge.length = 8 + i * 8;
        sge.lkey = 32'ha0a0_a000 + i;
        sge.iova.value = 64'h0000_1000_0000_1000 + i * 64;
        request.sges.push_back(sge);
      end

      sgb_base = fixture.qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                 fixture.qp.qp_plan.sq_sgb_ref.mapping_offset;
      request.sgb_iova.value = sgb_base;
      result = null;
      fixture.engine.post_send(request, result, status);
      if (status == null || !status.ok() || result == null ||
          result.image == null || result.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("SGB_FILTER_POST", status == null ? "null status" :
                   status.convert2string())
        disable sgb_filter_flow;
      end

      // 设计断点：若 external-SGB 路径只返回正确 image，却跳过或错位写入
      // 64-byte SQ header，下列 actual-slot 比较会失败，即使 SGB backing 本身正确。
      status = fixture.read_qp_entry(1'b1, result.index, sqe_data);
      if (status == null || !status.ok() ||
          sqe_data.size() != RDMA_WQE_BYTES) begin
        `uvm_error("SGB_FILTER_SQE_READ", status == null ?
                   "null SQE read status" : status.convert2string())
        disable sgb_filter_flow;
      end
      foreach (sqe_data[i]) begin
        if (sqe_data[i] !== result.image.bytes[i])
          `uvm_error("SGB_FILTER_SQE_PERSIST",
                     $sformatf("SQ byte %0d differs from returned image", i))
      end

      actual_sqe_image = rdma_hw_image::type_id::create(
        "sgb_filter_actual_sqe");
      actual_sqe_image.copy(result.image);
      actual_sqe_image.bytes.delete();
      foreach (sqe_data[i])
        actual_sqe_image.bytes.push_back(sqe_data[i]);

      sqe_builder = new("sgb_filter_sqe_builder");
      field_status = sqe_builder.deserialize(actual_sqe_image.bytes);
      raw_sge_num = 'x;
      raw_sgb_pa = 'x;
      raw_tpl = 'x;
      if (field_status != null && field_status.ok())
        field_status = sqe_builder.get_field(
          RDMA_SQ_WQE_RC_SGE_NUM_WORD_BYTE_OFFSET,
          RDMA_SQ_WQE_RC_SGE_NUM_LSB,
          RDMA_SQ_WQE_RC_SGE_NUM_WIDTH,
          raw_sge_num);
      if (field_status != null && field_status.ok())
        field_status = sqe_builder.get_field(
          RDMA_SQ_WQE_SGB_PA_WORD_BYTE_OFFSET,
          RDMA_SQ_WQE_SGB_PA_LSB,
          RDMA_SQ_WQE_SGB_PA_WIDTH,
          raw_sgb_pa);
      if (field_status != null && field_status.ok())
        field_status = sqe_builder.get_field(
          RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WORD_BYTE_OFFSET,
          RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_LSB,
          RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN_WIDTH,
          raw_tpl);
      if (field_status != null && field_status.ok())
        sqe_builder.get_words(sqe_words);

      actual_sgb_iova = sgb_base + longint'(result.index) * 512;
      if (field_status == null || !field_status.ok() ||
          sqe_words.size() != 8 || raw_sge_num !== 64'd3 ||
          raw_sgb_pa !== (actual_sgb_iova >> 9) || raw_tpl !== 64'd48)
        `uvm_error("SGB_FILTER_SQE_FIELDS",
                   "persisted SQE did not publish count=3, TPL=48 and the actual SGB slot")

      key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
              object_type:"sqe", variant:"rc", opcode:8'h00};
      codec = null;
      status = fixture.registry.lookup(key, codec);
      decoded_model = null;
      if (status != null && status.ok() && codec != null)
        status = codec.decode(actual_sqe_image, decoded_model);
      if (status == null || !status.ok() ||
          !$cast(decoded_sqe, decoded_model) || decoded_sqe == null ||
          decoded_sqe.payload_mode != RDMA_SQ_PAYLOAD_SGE_SGB ||
          decoded_sqe.sge_num != 3 ||
          decoded_sqe.sgb_iova.value != actual_sgb_iova ||
          decoded_sqe.total_payload_len != 48)
        `uvm_error("SGB_FILTER_SQE_DECODE", status == null ?
                   "null SQE decode status" : status.convert2string())

      status = fixture.mem.read(fixture.qp.qp_plan.sq_sgb_ref.mapping,
                                fixture.qp.qp_plan.sq_sgb_ref.mapping_offset +
                                  longint'(result.index) * 512,
                                512, sgb_data);
      if (status == null || !status.ok() || sgb_data.size() != 512) begin
        `uvm_error("SGB_FILTER_READ", status == null ? "null read status" :
                   status.convert2string())
        disable sgb_filter_flow;
      end

      // Driver xtrdma_set_sge() increments byte_off only for nonzero SGE.
      // Six literal qwords independently pin all bytes of the three packed
      // descriptors; the following byte loop covers the complete unused tail.
      signature_sgb.delete();
      foreach (sgb_data[i])
        signature_sgb.push_back(sgb_data[i]);
      sgb_builder = new("sgb_filter_backing_builder");
      field_status = sgb_builder.deserialize(signature_sgb);
      if (field_status != null && field_status.ok())
        sgb_builder.get_words(sgb_words);
      if (field_status == null || !field_status.ok() ||
          sgb_words.size() != 64 ||
          sgb_words[0] !== 64'h0000_0008_a0a0_a000 ||
          sgb_words[1] !== 64'h0000_1000_0000_1000 ||
          sgb_words[2] !== 64'h0000_0010_a0a0_a001 ||
          sgb_words[3] !== 64'h0000_1000_0000_1040 ||
          sgb_words[4] !== 64'h0000_0018_a0a0_a002 ||
          sgb_words[5] !== 64'h0000_1000_0000_1080)
        `uvm_error("SGB_FILTER_LAYOUT",
                   "external SGB descriptors were not filtered and compressed")
      for (int unsigned i = 48; i < 512; i++) begin
        if (sgb_data[i] !== 8'h00)
          `uvm_error("SGB_FILTER_TAIL",
                     $sformatf("external SGB byte %0d was not cleared", i))
      end

      signature_valid = 1'b0;
      status = validate_sq_signature(
        actual_sqe_image, signature_sgb, signature_valid);
      if (status == null || !status.ok() || !signature_valid)
        `uvm_error("SGB_FILTER_SIGNATURE", status == null ?
                   "null signature status" :
                   (status.ok() ? "actual SQE/SGB signature is invalid" :
                                  status.convert2string()))
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("SGB_FILTER_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_qpc_shadow_sq_gate 对照驱动 wr.c 的 SQ 门铃流控，验证
  //   HW_DROP_DB_CNT[54:48] 与本地 software count 的 bit6 差值只抑制 MMIO，
  //   不阻止 WQE 写入、SQ producer cursor 或 ledger commit。
  // 输入/输出及副作用：无显式参数；任务创建启用 shadow reader 的 fixture，
  //   写入 byte504 runtime shadow，执行三次 post_send，并读取 PCIe/Host-memory
  //   观察记录；fixture 资源仍由本任务 epilogue 清理。
  // 失败/边界：shadow 坐标、门铃宽度、gate 结果、status/result、cursor 或
  //   host-memory slot 任一不符都报告 UVM_ERROR；gate=false 必须返回成功结果，
  //   不得进入 recovery 或被误报为 QUEUE_FULL。
  task automatic check_qpc_shadow_sq_gate();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_status status;
    rdma_status cleanup_status;
    byte entry[];
    int unsigned mmio_count_before;
    int unsigned mmio_count_after;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "qpc_shadow_gate_fixture");
    begin : qpc_shadow_gate_flow
      if (fixture == null) begin
        `uvm_error("QPC_GATE_FIXTURE", "fixture allocation failed")
        disable qpc_shadow_gate_flow;
      end
      fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("QPC_GATE_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable qpc_shadow_gate_flow;
      end

      // Driver wr.c:1200 extracts HW_DROP_DB_CNT from qword byte504.  The
      // first post starts with sw_ring_db_cnt=0 and therefore passes at 0.
      status = fixture.set_qpc_shadow_counts(7'd0, 7'd0);
      if (status == null || !status.ok()) begin
        `uvm_error("QPC_GATE_SHADOW", status == null ? "null shadow status" :
                   status.convert2string())
        disable qpc_shadow_gate_flow;
      end
      request = fixture.make_send(64'h0bad_f00d_0000_0001);
      result = null;
      fixture.engine.post_send(request, result, status);
      if (status == null || !status.ok() || result == null) begin
        `uvm_error("QPC_GATE_FIRST", status == null ? "first post failed" :
                   status.convert2string())
        disable qpc_shadow_gate_flow;
      end

      mmio_count_before = 0;
      foreach (fixture.pcie.calls[i])
        if (fixture.pcie.calls[i] != null &&
            fixture.pcie.calls[i].method_name == "mmio_write")
          mmio_count_before++;

      // Keep HW count at zero.  The driver-local software count is now one,
      // so unsigned 7-bit subtraction has bit6=1 and must suppress MMIO.
      status = fixture.set_qpc_shadow_counts(7'd0, 7'd0);
      if (status == null || !status.ok()) begin
        `uvm_error("QPC_GATE_SHADOW", status == null ? "null shadow status" :
                   status.convert2string())
        disable qpc_shadow_gate_flow;
      end
      request = fixture.make_send(64'h0bad_f00d_0000_0002);
      result = null;
      fixture.engine.post_send(request, result, status);
      mmio_count_after = 0;
      foreach (fixture.pcie.calls[i])
        if (fixture.pcie.calls[i] != null &&
            fixture.pcie.calls[i].method_name == "mmio_write")
          mmio_count_after++;
      if (status == null || !status.ok() || result == null ||
          mmio_count_after != mmio_count_before)
        `uvm_error("QPC_GATE_SUPPRESS", status == null ?
                   "suppressed post returned null status" :
                   (status.ok() ? "SQ MMIO was not suppressed" :
                    status.convert2string()))

      status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, producer_index,
        producer_wrap, consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 2 ||
          producer_wrap != 1'b0)
        `uvm_error("QPC_GATE_COMMIT", status == null ?
                   "cursor query failed after suppressed doorbell" :
                   $sformatf("suppressed doorbell did not commit PI: %s",
                             status.convert2string()))
      status = fixture.read_qp_entry(1'b1, 1, entry);
      if (status == null || !status.ok() || entry.size() != 64 ||
          result.image == null || result.image.bytes.size() != 64)
        `uvm_error("QPC_GATE_WQE", "suppressed post did not persist SQ WQE")
      else foreach (entry[i])
        if (entry[i] != result.image.bytes[i])
          `uvm_error("QPC_GATE_WQE",
                     $sformatf("SQ byte %0d was not persisted before gate", i))

      // Advancing HW_DROP_DB_CNT to one makes (1-1)&0x40 zero, so the next
      // post must emit exactly one 8-byte SQ header doorbell again.
      status = fixture.set_qpc_shadow_counts(7'd1, 7'd0);
      if (status == null || !status.ok()) begin
        `uvm_error("QPC_GATE_SHADOW", status == null ? "null shadow status" :
                   status.convert2string())
        disable qpc_shadow_gate_flow;
      end
      request = fixture.make_send(64'h0bad_f00d_0000_0003);
      result = null;
      fixture.engine.post_send(request, result, status);
      mmio_count_after = 0;
      foreach (fixture.pcie.calls[i])
        if (fixture.pcie.calls[i] != null &&
            fixture.pcie.calls[i].method_name == "mmio_write") begin
          mmio_count_after++;
          if (fixture.pcie.calls[i].data.size() != RDMA_DB_BYTES)
            `uvm_error("QPC_GATE_WIDTH", "SQ doorbell was not 8 bytes")
        end
      if (status == null || !status.ok() || result == null ||
          mmio_count_after != mmio_count_before + 1)
        `uvm_error("QPC_GATE_ALLOW", status == null ?
                   "allowed post returned null status" :
                   (status.ok() ? "SQ MMIO was not emitted after credit" :
                    status.convert2string()))
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("QPC_GATE_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_recv_owner_authority 验证 private RQ 的 receive request 在
  //   owner Function UID 与当前 fixture 不一致，或 attachment 的 reset epoch
  //   已过期时，被 post_recv 在 reservation 前拒绝。
  // 输入/输出及副作用：无显式参数；task 建立独立 fixture，篡改 request.owner
  //   或 binding epoch，读取前后 RQ producer/consumer cursor，并通过 UVM 报告
  //   暴露 authority 结果。
  // 失败/边界：setup、cursor 查询或 cleanup 返回空/失败状态时单独报告；若
  //   foreign owner 或 stale epoch 被接受、result 非空或任一 cursor 推进则报错。
  task automatic check_recv_owner_authority();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_recv_req request;
    rdma_queue_post_result result;
    rdma_status status;
    rdma_status cursor_status;
    rdma_status cleanup_status;
    rdma_status epoch_status;
    rdma_function_handle foreign_owner;
    int unsigned before_index;
    int unsigned after_index;
    int unsigned before_consumer;
    int unsigned after_consumer;
    bit before_wrap;
    bit after_wrap;
    bit before_consumer_wrap;
    bit after_consumer_wrap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "recv_owner_authority_fixture");

    begin : recv_owner_authority_flow
      if (fixture == null) begin
        `uvm_error("RECV_OWNER_FIXTURE", "fixture allocation failed")
        disable recv_owner_authority_flow;
      end

      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("RECV_OWNER_FIXTURE",
                   status == null ? "null setup status" :
                   status.convert2string())
        disable recv_owner_authority_flow;
      end

      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, before_index, before_wrap,
        before_consumer, before_consumer_wrap);
      if (cursor_status == null || !cursor_status.ok()) begin
        `uvm_error("RECV_OWNER_CURSOR",
                   cursor_status == null ? "null cursor status" :
                   cursor_status.convert2string())
        disable recv_owner_authority_flow;
      end

      request = fixture.make_recv(64'hface_cafe_0000_0001);
      foreign_owner = fixture.binding.make_handle();
      if (foreign_owner == null) begin
        `uvm_error("RECV_OWNER_HANDLE", "fixture owner handle is unavailable")
        disable recv_owner_authority_flow;
      end
      foreign_owner.function_uid = foreign_owner.function_uid ^ 64'h1;
      request.owner = foreign_owner;
      result = null;
      fixture.engine.post_recv(request, result, status);

      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, after_index, after_wrap,
        after_consumer, after_consumer_wrap);
      if (status == null || status.ok() || result != null ||
          cursor_status == null || !cursor_status.ok() ||
          after_index != before_index || after_wrap != before_wrap ||
          after_consumer != before_consumer ||
          after_consumer_wrap != before_consumer_wrap)
        `uvm_error("RECV_OWNER_AUTHORITY",
                   status == null ? "null status" : status.convert2string())

      epoch_status = fixture.advance_binding_reset_epoch(2);
      if (epoch_status == null || !epoch_status.ok()) begin
        `uvm_error("RECV_EPOCH_FIXTURE",
                   epoch_status == null ? "null epoch status" :
                   epoch_status.convert2string())
        disable recv_owner_authority_flow;
      end

      request = fixture.make_recv(64'hface_cafe_0000_0002);
      result = null;
      fixture.engine.post_recv(request, result, status);
      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, after_index, after_wrap,
        after_consumer, after_consumer_wrap);
      if (status == null || status.ok() || result != null ||
          cursor_status == null || !cursor_status.ok() ||
          after_index != before_index || after_wrap != before_wrap ||
          after_consumer != before_consumer ||
          after_consumer_wrap != before_consumer_wrap)
        `uvm_error("RECV_EPOCH_AUTHORITY",
                   status == null ? "null status" : status.convert2string())
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("RECV_OWNER_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_transport_link_mismatch 拦截“请求声明 transport 与已绑定
  // QP transport 不一致”的合法语义请求，验证 route authority 在写 SQE
  // 之前就 fail-closed。
  // 输入/输出及副作用：无显式参数；任务创建 RC fixture、构造字段完整的
  // UD SEND 请求并读取 SQ cursor，成功时只产生拒绝状态，不写入 host-memory
  // 或 doorbell 账本。
  // 失败/边界：若 mismatch 被错误放行、返回错误码不是 RDMA_SC_INVALID_STATE、
  // 发布 result、推进 producer 或 cursor query 失败时报告 UVM_ERROR；fixture
  // setup 失败时不访问未配置 engine，所有分支在 epilogue 按残留标志 cleanup。
  task automatic check_transport_link_mismatch();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_address_vector av;
    rdma_status status;
    rdma_status cursor_status;
    rdma_status cleanup_status;
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
    begin : transport_mismatch_flow
      if (fixture == null) begin
        `uvm_error("TRANSPORT_MISMATCH_FIXTURE", "fixture allocation failed")
        disable transport_mismatch_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("TRANSPORT_MISMATCH_FIXTURE",
                   status == null ? "null setup status" : status.convert2string())
        disable transport_mismatch_flow;
      end
      status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, before_index, before_wrap,
        before_consumer, before_consumer_wrap);
      if (status == null || !status.ok()) begin
        `uvm_error("TRANSPORT_MISMATCH_CURSOR",
                   status == null ? "null cursor status" : status.convert2string())
        disable transport_mismatch_flow;
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
      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, after_index, after_wrap,
        after_consumer, after_consumer_wrap);
      if (status == null || status.code != RDMA_SC_INVALID_STATE ||
          cursor_status == null || !cursor_status.ok() || result != null ||
          after_index != before_index || after_wrap != before_wrap ||
          after_consumer != before_consumer ||
          after_consumer_wrap != before_consumer_wrap)
        `uvm_error("TRANSPORT_MISMATCH",
                   status == null ? "null mismatch status" : status.convert2string())
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("TRANSPORT_MISMATCH_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_ud_inline_capacity_admission 向真实 UD SQ attachment 提交 513B
  //   inline SEND，验证固定 512B SGB 上限在任何 backing/recovery 副作用前拒绝。
  // 输入/输出及副作用：无显式参数；task 建立独立 fixture/UD QP，记录公开 SQ
  //   cursor、used/pending、Host-memory 与 PCIe call count，调用 post_send 后比较快照；
  //   若旧实现已进入 recovery，仅在完成断言后执行显式 abort 以便 deterministic cleanup。
  // 失败/边界：setup/create/attach 或公开 query 失败使用 fixture ID 报告；目标契约
  //   要求 INVALID_ARGUMENT、result=null、PI/CI/used/call counts 不变且无 pending，
  //   任一不符只发布一次 POST_SEND_UD_INLINE_CAPACITY，避免拆成多个假 RED。
  task automatic check_ud_inline_capacity_admission();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_send_req request;
    rdma_queue_post_result result;
    rdma_queue_pending_operation recovery_pending;
    rdma_status status;
    rdma_status post_status;
    rdma_status cursor_status;
    rdma_status occupancy_status;
    rdma_status pending_status;
    rdma_status cleanup_status;
    int unsigned before_producer;
    int unsigned before_consumer;
    int unsigned after_producer;
    int unsigned after_consumer;
    int unsigned before_used;
    int unsigned after_used;
    int unsigned before_mem_calls;
    int unsigned before_pcie_calls;
    bit before_producer_wrap;
    bit before_consumer_wrap;
    bit after_producer_wrap;
    bit after_consumer_wrap;
    bit before_pending;
    bit after_pending;
    longint unsigned sgb_base;
    bit contract_ok;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "ud_inline_capacity_fixture");
    begin : ud_inline_capacity_flow
      if (fixture == null) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE", "fixture allocation failed")
        disable ud_inline_capacity_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE",
                   status == null ? "null setup status" :
                                    status.convert2string())
        disable ud_inline_capacity_flow;
      end
      fixture.create_transport_qp(
        "ud_inline_capacity", RDMA_TRANSPORT_UD, fixture.ud_qp, status);
      if (status == null || !status.ok() || fixture.ud_qp == null) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE",
                   status == null ? "null UD QP create status" :
                                    status.convert2string())
        disable ud_inline_capacity_flow;
      end
      fixture.ud_qp_created = 1'b1;
      status = fixture.engine.attach_qp(fixture.ud_qp.handle);
      if (status == null || !status.ok()) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE",
                   status == null ? "null UD QP attach status" :
                                    status.convert2string())
        disable ud_inline_capacity_flow;
      end
      fixture.ud_qp_attached = 1'b1;
      if (fixture.ud_qp.qp_plan == null ||
          fixture.ud_qp.qp_plan.sq_sgb_ref == null ||
          fixture.ud_qp.qp_plan.sq_sgb_ref.mapping == null) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE",
                   "UD QP lacks SQ-SGB backing authority")
        disable ud_inline_capacity_flow;
      end

      request = fixture.make_send(64'h5130_0000_0000_0001);
      request.qp_h = rdma_clone_handle_value(
        fixture.ud_qp.handle, "UD inline capacity QP");
      request.transport = RDMA_TRANSPORT_UD;
      request.opcode = RDMA_WR_SEND;
      request.sges.delete();
      request.inline_data = 1'b1;
      request.payload.delete();
      for (int unsigned i = 0; i < 513; i++)
        request.payload.push_back(i[7:0]);
      request.destination_qpn = 24'h123;
      request.qkey = 32'h8001_0000;
      request.address_vector_valid = 1'b1;
      request.address_vector = rdma_address_vector::type_id::create(
        "ud_inline_capacity_av");
      sgb_base = fixture.ud_qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                 fixture.ud_qp.qp_plan.sq_sgb_ref.mapping_offset;
      request.sgb_iova.value = sgb_base;

      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ,
        before_producer, before_producer_wrap,
        before_consumer, before_consumer_wrap);
      occupancy_status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ,
        before_used, before_pending);
      if (cursor_status == null || !cursor_status.ok() ||
          occupancy_status == null || !occupancy_status.ok() ||
          before_pending) begin
        `uvm_error("UD_INLINE_CAPACITY_FIXTURE",
                   "UD SQ baseline cursor/occupancy is unavailable")
        disable ud_inline_capacity_flow;
      end
      before_mem_calls = fixture.mem.calls.size();
      before_pcie_calls = fixture.pcie.calls.size();

      result = rdma_queue_post_result::type_id::create(
        "ud_inline_capacity_result_sentinel");
      fixture.engine.post_send(request, result, post_status);

      cursor_status = fixture.engine.query_runtime_cursors(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ,
        after_producer, after_producer_wrap,
        after_consumer, after_consumer_wrap);
      occupancy_status = fixture.engine.query_runtime_occupancy(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ,
        after_used, after_pending);
      recovery_pending = null;
      pending_status = fixture.engine.query_runtime_pending(
        fixture.ud_qp.handle, RDMA_QUEUE_RUNTIME_SQ, recovery_pending);

      contract_ok = post_status != null &&
                    post_status.code == RDMA_SC_INVALID_ARGUMENT &&
                    result == null && cursor_status != null &&
                    cursor_status.ok() && occupancy_status != null &&
                    occupancy_status.ok() &&
                    after_producer == before_producer &&
                    after_producer_wrap == before_producer_wrap &&
                    after_consumer == before_consumer &&
                    after_consumer_wrap == before_consumer_wrap &&
                    after_used == before_used && !after_pending &&
                    fixture.mem.calls.size() == before_mem_calls &&
                    fixture.pcie.calls.size() == before_pcie_calls &&
                    pending_status != null &&
                    pending_status.code == RDMA_SC_INVALID_STATE &&
                    recovery_pending == null;
      if (!contract_ok)
        `uvm_error("POST_SEND_UD_INLINE_CAPACITY",
                   "513-byte UD inline rejection changed SQ/backing/doorbell/recovery state")

      // 旧实现会在 capacity guard 后置时留下 pending；断言已经记录该缺陷，
      // 这里仅显式 abort/detach，防止 RED fixture 污染 teardown 的失败集合。
      if (after_pending || recovery_pending != null) begin
        fixture.engine.recover_queue(
          fixture.ud_qp.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH,
          1'b1, status);
        if (status != null && status.ok())
          fixture.ud_qp_attached = 1'b0;
      end
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("UD_INLINE_CAPACITY_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end
  endtask

  // 功能：check_empty_receive_rqe 通过真实 queue-data post_recv 提交一个
  //   num_sge=0 的接收请求，验证驱动允许的空 RQE 在 host-memory、RQ cursor
  //   和 producer doorbell 上保持完整且一致的可观察结果。
  // 输入/输出及副作用：无显式参数；任务建立独立 fixture，删除 receive
  //   request 的全部 SGE，读取返回 image、RQ backing、runtime cursor 与 PCIe
  //   doorbell 记录；fixture 资源仍由 epilogue cleanup 释放。
  // 失败/边界：setup/post/cursor/readback 或 codec 解析失败、SGE_NUM/TPL 非零、
  //   qword4..7 任一字节非零、cursor 未推进一步、doorbell 缺失/宽度错误时报告
  //   UVM_ERROR；空请求不得进入 recovery 或发布半成品 result。
  task automatic check_empty_receive_rqe();
    rdma_queue_data_engine_fixture fixture;
    rdma_post_recv_req request;
    rdma_queue_post_result result;
    rdma_status status;
    rdma_status cleanup_status;
    rdma_hw_qword_builder builder;
    bit [63:0] words[];
    byte entry[];
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    int unsigned rq_mmio_count;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "empty_receive_rqe_fixture");
    begin : empty_receive_rqe_flow
      if (fixture == null) begin
        `uvm_error("EMPTY_RQE_FIXTURE", "fixture allocation failed")
        disable empty_receive_rqe_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("EMPTY_RQE_FIXTURE", status == null ? "null setup status" :
                   status.convert2string())
        disable empty_receive_rqe_flow;
      end

      request = fixture.make_recv(64'hface_cafe_0000_0100);
      request.sges.delete();
      result = null;
      fixture.engine.post_recv(request, result, status);
      if (status == null || !status.ok() || result == null ||
          result.image == null || result.image.bytes.size() != 64) begin
        `uvm_error("EMPTY_RQE_POST", status == null ? "null status" :
                   status.convert2string())
        disable empty_receive_rqe_flow;
      end

      builder = new("empty_receive_rqe_builder");
      status = builder.deserialize(result.image.bytes);
      if (status == null || !status.ok()) begin
        `uvm_error("EMPTY_RQE_IMAGE", status == null ? "null deserialize status" :
                   status.convert2string())
        disable empty_receive_rqe_flow;
      end
      builder.get_words(words);
      if (words.size() != 8 || words[0][35:32] !== 4'h9 ||
          words[1][31:0] !== 32'd0 ||
          words[2][55:48] !== 8'd0 || words[4] !== 64'd0 ||
          words[5] !== 64'd0 || words[6] !== 64'd0 || words[7] !== 64'd0)
        `uvm_error("EMPTY_RQE_FIELDS",
                   "empty receive RQE did not encode SGE_NUM/TPL/payload as zero")

      status = fixture.read_qp_entry(1'b0, result.index, entry);
      if (status == null || !status.ok() || entry.size() != 64)
        `uvm_error("EMPTY_RQE_MEMORY", status == null ? "null readback status" :
                   status.convert2string())
      else foreach (entry[i])
        if (entry[i] !== result.image.bytes[i])
          `uvm_error("EMPTY_RQE_MEMORY",
                     $sformatf("RQ byte %0d differs from returned image", i))

      status = fixture.engine.query_runtime_cursors(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_RQ, producer_index, producer_wrap,
        consumer_index, consumer_wrap);
      if (status == null || !status.ok() || producer_index != 1 || producer_wrap ||
          consumer_index != 0 || consumer_wrap)
        `uvm_error("EMPTY_RQE_CURSOR", status == null ? "null cursor status" :
                   $sformatf("empty RQE cursor mismatch: %s",
                             status.convert2string()))

      rq_mmio_count = 0;
      foreach (fixture.pcie.calls[i])
        if (fixture.pcie.calls[i] != null &&
            fixture.pcie.calls[i].method_name == "mmio_write") begin
          rq_mmio_count++;
          if (fixture.pcie.calls[i].data.size() != RDMA_DB_BYTES)
            `uvm_error("EMPTY_RQE_DOORBELL", "RQ producer doorbell width is not 8 bytes")
        end
      if (rq_mmio_count != 1)
        `uvm_error("EMPTY_RQE_DOORBELL",
                   $sformatf("expected one RQ producer doorbell, got %0d",
                             rq_mmio_count))
    end
    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("EMPTY_RQE_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" : cleanup_status.convert2string())
    end
  endtask

  // 功能：run_phase 验证未配置门禁与真实 SQ/RQ post/readback；direct mixed-zero
  //   SEND 锁定 filtered SGE count 与跨零项压紧布局，17-byte inline SEND 锁定
  //   canonical 两个 chunk 及 actual-slot 持久化，并覆盖 513B UD inline admission。
  // 输入/输出及副作用：phase 为输入；task 管理 objection，创建并驱动主 fixture，
  //   读取 returned image 对应的实际 SQ/RQ backing，通过 UVM 报告暴露结果，最终
  //   释放 fixture-owned lifecycle 资源。
  // 失败/边界：主 fixture setup、actual-slot read/decode、raw SGE_NUM、descriptor
  //   布局或子场景失败时报告；513B UD 拒绝还要求 cursor/occupancy、pending、
  //   Host-memory 与 doorbell 计数全不变；cleanup 失败单独报告且始终 drop objection。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine engine;
    rdma_queue_data_engine_fixture fixture;
    rdma_status status;
    rdma_status cleanup_status;
    rdma_queue_post_result result;
    rdma_post_send_req send_request;
    rdma_post_recv_req recv_request;
    byte entry[];
    rdma_hw_qword_builder sqe_builder;
    rdma_hw_image actual_sqe_image;
    rdma_hw_model decoded_model;
    rdma_hw_sqe_model decoded_sqe;
    rdma_codec_base sqe_codec;
    rdma_codec_key sqe_key;
    rdma_status sqe_field_status;
    bit [63:0] sqe_words[];
    bit [63:0] sqe_sge_num;
    rdma_sge zero_prefix_sge;
    rdma_sge zero_tail_sge;
    byte unsigned inline_payload_byte;

    phase.raise_objection(this);
    begin : post_flow
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
      if (fixture == null) begin
        `uvm_error("FIXTURE_SETUP", "fixture allocation failed")
        disable post_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("FIXTURE_SETUP", status == null ? "null setup status" :
                   status.convert2string())
        disable post_flow;
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

      // 设计断点：若 direct mixed-zero 路径只返回正确 image，却跳过/错位写入
      // result.index，把原始数组长度写入 SGE_NUM，或按原始索引在零长度前缀处
      // 留洞，actual-slot 的 byte 比较、raw field 与 literal 布局至少一项会失败。
      send_request = fixture.make_send(64'h1111_2222_3333_4445);
      zero_prefix_sge = rdma_sge::type_id::create("fixture_zero_prefix_sge");
      zero_prefix_sge.length = 0;
      zero_prefix_sge.iova.value = 64'h0000_1000_0000_0f00;
      zero_prefix_sge.lkey = 32'hdead_beef;
      send_request.sges.push_front(zero_prefix_sge);
      zero_tail_sge = rdma_sge::type_id::create("fixture_zero_tail_sge");
      zero_tail_sge.length = 0;
      zero_tail_sge.iova.value = 64'h0000_1000_0000_1000;
      zero_tail_sge.lkey = 32'h0bad_cafe;
      send_request.sges.push_back(zero_tail_sge);
      result = null;
      fixture.engine.post_send(send_request, result, status);
      if (status == null || !status.ok() || result == null ||
          result.image == null || result.image.bytes.size() != 64) begin
        `uvm_error("POST_SEND_FILTERED_SGE",
                   status == null ? "null status" : status.convert2string())
      end
      else begin
        if (result.index != 1 || result.wrap != 0)
          `uvm_error("POST_SEND_FILTERED_INDEX",
                     $sformatf("mixed-zero post used index=%0d wrap=%0b",
                               result.index, result.wrap))
        status = fixture.read_qp_entry(1'b1, result.index, entry);
        if (status == null || !status.ok() ||
            entry.size() != RDMA_WQE_BYTES) begin
          `uvm_error("POST_SEND_FILTERED_READ", status == null ?
                     "null SQ slot read status" : status.convert2string())
        end
        else begin
          foreach (entry[i]) begin
            if (entry[i] !== result.image.bytes[i])
              `uvm_error("POST_SEND_FILTERED_PERSIST",
                         $sformatf("SQ byte %0d differs from returned image", i))
          end

          actual_sqe_image = rdma_hw_image::type_id::create(
            "filtered_sge_actual_sqe");
          actual_sqe_image.copy(result.image);
          actual_sqe_image.bytes.delete();
          foreach (entry[i])
            actual_sqe_image.bytes.push_back(entry[i]);

          sqe_builder = new("filtered_sge_sqe_builder");
          sqe_field_status = sqe_builder.deserialize(actual_sqe_image.bytes);
          sqe_sge_num = 'x;
          if (sqe_field_status != null && sqe_field_status.ok())
            sqe_field_status = sqe_builder.get_field(
              RDMA_SQ_WQE_RC_SGE_NUM_WORD_BYTE_OFFSET,
              RDMA_SQ_WQE_RC_SGE_NUM_LSB,
              RDMA_SQ_WQE_RC_SGE_NUM_WIDTH,
              sqe_sge_num);
          if (sqe_field_status != null && sqe_field_status.ok())
            sqe_builder.get_words(sqe_words);
          if (sqe_field_status == null || !sqe_field_status.ok() ||
              sqe_words.size() != 8 || sqe_sge_num !== 64'd1 ||
              sqe_words[4] !== 64'h0000_0020_0102_0304 ||
              sqe_words[5] !== 64'h0000_1000_0000_0000 ||
              sqe_words[6] !== 64'd0 || sqe_words[7] !== 64'd0)
            `uvm_error("POST_SEND_FILTERED_LAYOUT",
                       "persisted SQE did not contain one packed direct descriptor")

          sqe_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_SQE,
                      object_type:"sqe", variant:"rc", opcode:8'h00};
          sqe_codec = null;
          status = fixture.registry.lookup(sqe_key, sqe_codec);
          decoded_model = null;
          if (status != null && status.ok() && sqe_codec != null)
            status = sqe_codec.decode(actual_sqe_image, decoded_model);
          if (status == null || !status.ok() ||
              !$cast(decoded_sqe, decoded_model) || decoded_sqe == null ||
              decoded_sqe.payload_mode != RDMA_SQ_PAYLOAD_SGE_WQE ||
              decoded_sqe.sge_num != 1 || decoded_sqe.sges.size() != 1) begin
            `uvm_error("POST_SEND_FILTERED_DECODE", status == null ?
                       "null SQE decode status" : status.convert2string())
          end
          else if (decoded_sqe.sges[0] == null ||
                   decoded_sqe.sges[0].length != 32 ||
                   decoded_sqe.sges[0].lkey != 32'h0102_0304 ||
                   decoded_sqe.sges[0].iova.value !=
                     64'h0000_1000_0000_0000) begin
            `uvm_error("POST_SEND_FILTERED_DESCRIPTOR",
                       "decoded actual SQ slot lost the packed descriptor")
          end
        end
      end

      // F2 集成契约：17 个 literal inline bytes 必须映射成两个 16-byte
      // chunk。断言直接读取 result.index 指向的实际 SQ slot，并与返回 image
      // 逐字节比较；byte17 是大端 qword2 中的 raw SGE_NUM，期望固定为 2。
      send_request = fixture.make_send(64'h1111_2222_3333_4446);
      send_request.sges.delete();
      send_request.inline_data = 1'b1;
      send_request.payload.delete();
      for (int unsigned inline_index = 0;
           inline_index < 17;
           inline_index++) begin
        inline_payload_byte = inline_index;
        send_request.payload.push_back(inline_payload_byte);
      end
      result = null;
      fixture.engine.post_send(send_request, result, status);
      if (status == null || !status.ok() || result == null ||
          result.image == null || result.image.bytes.size() != RDMA_WQE_BYTES) begin
        `uvm_error("POST_SEND_INLINE_SGE_NUM",
                   status == null ? "null inline post status" :
                   status.convert2string())
      end
      else begin
        status = fixture.read_qp_entry(1'b1, result.index, entry);
        if (status == null || !status.ok() ||
            entry.size() != RDMA_WQE_BYTES) begin
          `uvm_error("POST_SEND_INLINE_SGE_NUM",
                     status == null ? "null inline SQ read status" :
                     status.convert2string())
        end
        else begin
          foreach (entry[i]) begin
            if (entry[i] !== result.image.bytes[i])
              `uvm_error("POST_SEND_INLINE_PERSIST",
                         $sformatf(
                           "inline SQ byte %0d differs from returned image", i))
          end
          if (entry[17] !== 8'd2 || result.image.bytes[17] !== 8'd2)
            `uvm_error("POST_SEND_INLINE_SGE_NUM",
                       "17-byte inline SQE did not persist raw SGE_NUM two")
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
      check_ud_inline_capacity_admission();
      check_sgb_recovery_replays_slot();
      check_ud_effective_sgb_writer_paths();
      check_sgb_writer_rejects_post_encode_mutation();
      check_sgb_filters_zero_length_descriptors();
      check_qpc_shadow_sq_gate();
      check_recv_owner_authority();
      check_empty_receive_rqe();
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("POST_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end

    phase.drop_objection(this);
  endtask

endclass
