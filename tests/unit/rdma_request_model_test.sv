// 目录：测试层 unit/rdma_request_model_test.sv。
// 职责：验证 rdma_request_model_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_request_model_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_request_model_test extends uvm_test;
  `uvm_component_utils(rdma_request_model_test)

  // 功能：构造 rdma_request_model_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_request_model_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_request_model_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = 64'h1234_5678_9abc_def0;
    handle.object_id = object_id;
    handle.generation = 32'd9;
    return handle;
  endfunction

  // 功能：make_function_handle 创建独立的 rdma_function_handle；根据 name 设置字段 handle、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_function_handle 读取 name 并使用字段 handle、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：make_function_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_handle make_function_handle(string name);
    rdma_function_handle handle;

    handle = rdma_function_handle::type_id::create(name);
    handle.function_uid = 64'h1234_5678_9abc_def0;
    handle.object_id = 32'h1020_3040;
    handle.generation = 32'd9;
    return handle;
  endfunction

  // 功能：make_queue_mapping 创建独立的 rdma_dma_mapping；根据 name、owner、iova_value 设置字段 mapping、mapping.function_h、iova.value、backing_addr.value、mapping.size、mapping.state，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、owner（输入）、iova_value（输入）；make_queue_mapping 读取 name、owner、iova_value 并使用字段 mapping、mapping.function_h、iova.value、backing_addr.value、mapping.size、mapping.state；函数返回 rdma_dma_mapping，不取得调用方资源所有权。
  // 失败/边界：make_queue_mapping 的结果直接由 return mapping 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_dma_mapping make_queue_mapping(
    string name,
    rdma_function_handle owner,
    longint unsigned iova_value
  );
    rdma_dma_mapping mapping;

    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = owner;
    mapping.iova.value = iova_value;
    mapping.backing_addr.value = iova_value + 64'h1000_0000;
    mapping.size = 64'h1_0000;
    mapping.state = RDMA_MAPPING_ACTIVE;
    return mapping;
  endfunction

  // 功能：make_queue_ring 创建独立的 rdma_queue_ring_layout；根据 name、role、depth、mapping 设置字段 ring、ring.role、ring.entry_size_bytes、ring.depth、ring.logical_bytes、storage_bytes、ring.storage_bytes、ring.page_count、ring.initial_polarity、i，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、role（输入）、depth（输入）、mapping（输入）；make_queue_ring 读取 name、role、depth、mapping 并使用字段 ring、ring.role、ring.entry_size_bytes、ring.depth、ring.logical_bytes、storage_bytes、ring.storage_bytes、ring.page_count；函数返回 rdma_queue_ring_layout，不取得调用方资源所有权。
  // 失败/边界：make_queue_ring 的结果直接由 return ring 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_queue_ring_layout make_queue_ring(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth,
    rdma_dma_mapping mapping
  );
    rdma_queue_ring_layout ring;
    rdma_queue_dma_page_ref page;
    longint unsigned storage_bytes;

    ring = rdma_queue_ring_layout::type_id::create(name);
    ring.role = role;
    ring.entry_size_bytes = 64;
    ring.depth = depth;
    ring.logical_bytes = depth * 64;
    storage_bytes = ((ring.logical_bytes + 4095) / 4096) * 4096;
    ring.storage_bytes = storage_bytes;
    ring.page_count = storage_bytes / 4096;
    ring.initial_polarity = 1'b1;
    for (int unsigned i = 0; i < ring.page_count; i++) begin
      page = rdma_queue_dma_page_ref::type_id::create(
        $sformatf("%s_page_%0d", name, i)
      );
      page.role = role;
      page.mapping = mapping;
      page.mapping_offset = i * 4096;
      page.logical_page_offset = i * 4096;
      page.page_iova.value = mapping.iova.value + i * 4096;
      ring.pages.push_back(page);
    end
    return ring;
  endfunction

  // 功能：make_queue_ref 创建独立的 rdma_queue_backing_ref；根据 name、role、mapping、length、ownership 设置字段 ref_value、ref_value.role、ref_value.mapping、ref_value.length、ref_value.ownership，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、role（输入）、mapping（输入）、length（输入）、ownership（输入）；make_queue_ref 读取 name、role、mapping、length、ownership 并使用字段 ref_value、ref_value.role、ref_value.mapping、ref_value.length、ref_value.ownership；函数返回 rdma_queue_backing_ref，不取得调用方资源所有权。
  // 失败/边界：make_queue_ref 的结果直接由 return ref_value 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_queue_backing_ref make_queue_ref(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned length,
    rdma_resource_ownership_e ownership
  );
    rdma_queue_backing_ref ref_value;

    ref_value = rdma_queue_backing_ref::type_id::create(name);
    ref_value.role = role;
    ref_value.mapping = mapping;
    ref_value.length = length;
    ref_value.ownership = ownership;
    return ref_value;
  endfunction

  // 功能：make_queue_context 创建独立的 rdma_context_backing_ref；根据 name、kind、owner 设置字段 context_ref、context_ref.owner、context_ref.resource_kind、token、authority、token.completion_authority、context_ref.slot_token、context_ref.hmc_ref、hmc_ref.owner、hmc_ref.object_kind，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、owner（输入）；make_queue_context 读取 name、kind、owner 并使用字段 context_ref、context_ref.owner、context_ref.resource_kind、token、authority、token.completion_authority、context_ref.slot_token、context_ref.hmc_ref；函数返回 rdma_context_backing_ref，不取得调用方资源所有权。
  // 失败/边界：make_queue_context 的结果直接由 return context_ref 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_context_backing_ref make_queue_context(
    string name,
    rdma_resource_kind_e kind,
    rdma_function_handle owner
  );
    rdma_context_backing_ref context_ref;
    rdma_queue_opaque_slot_token token;
    rdma_queue_completion_authority authority;

    context_ref = rdma_context_backing_ref::type_id::create(name);
    context_ref.owner = owner;
    context_ref.resource_kind = kind;
    token = rdma_queue_opaque_slot_token::type_id::create({name, "_token"});
    authority = rdma_queue_completion_authority::type_id::create(
      {name, "_authority"}
    );
    token.completion_authority = authority;
    context_ref.slot_token = token;
    context_ref.hmc_ref = rdma_hmc_ref::type_id::create({name, "_hmc"});
    context_ref.hmc_ref.owner = owner;
    context_ref.hmc_ref.object_kind = RDMA_RESOURCE_MR;
    context_ref.hmc_ref.size = 4096;
    context_ref.hmc_ref.first_pbl_index = 1;
    context_ref.hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    context_ref.shadow_pointer_base.value = 64'h8000_0000;
    context_ref.slot_length = 64;
    context_ref.shadow_view_length = 32;
    return context_ref;
  endfunction

  // 功能：make_queue_plan 创建独立的 rdma_queue_backing_plan；根据 name、kind、depth、owner 设置字段 plan、plan.resource_kind、mapping、ring、ring_ref、pd_ref、plan.context_ref、flush_target、flush_target.role、flush_target.phase，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、depth（输入）、owner（输入）；make_queue_plan 读取 name、kind、depth、owner 并使用字段 plan、plan.resource_kind、mapping、ring、ring_ref、pd_ref、plan.context_ref、flush_target；函数返回 rdma_queue_backing_plan，不取得调用方资源所有权。
  // 失败/边界：make_queue_plan 先检查 kind == RDMA_RESOURCE_CQ，再返回 plan；拒绝分支不提交部分状态，也不隐式重试。
  function automatic rdma_queue_backing_plan make_queue_plan(
    string name,
    rdma_resource_kind_e kind,
    int unsigned depth,
    rdma_function_handle owner
  );
    rdma_queue_backing_plan plan;
    rdma_dma_mapping mapping;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref ring_ref;
    rdma_queue_backing_ref pd_ref;
    rdma_queue_flush_target flush_target;

    plan = rdma_queue_backing_plan::type_id::create(name);
    plan.resource_kind = kind;
    mapping = make_queue_mapping({name, "_mapping"}, owner,
                                 64'h4000_0000);
    if (kind == RDMA_RESOURCE_CQ) begin
      ring = make_queue_ring({name, "_ring"}, RDMA_QUEUE_ROLE_CQ_RING,
                             depth, mapping);
      ring_ref = make_queue_ref({name, "_ring_ref"},
                                RDMA_QUEUE_ROLE_CQ_RING, mapping,
                                ring.storage_bytes,
                                RDMA_OWNERSHIP_BORROWED);
      pd_ref = make_queue_ref({name, "_pd_ref"}, RDMA_QUEUE_ROLE_CQ_PD,
                              mapping, 4096,
                              RDMA_OWNERSHIP_CONTROL_PLANE);
      plan.rings.push_back(ring);
      plan.refs.push_back(ring_ref);
      plan.refs.push_back(pd_ref);
      plan.context_ref = make_queue_context({name, "_context"}, kind,
                                            owner);
      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_CQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_POST_DELETE;
      flush_target.pd_ref = pd_ref;
      plan.flush_targets.push_back(flush_target);
    end
    else begin
      rdma_queue_ring_layout srfq_ring;
      rdma_queue_backing_ref srfq_ref;
      rdma_queue_backing_ref srfq_pd;

      ring = make_queue_ring({name, "_srq_ring"},
                             RDMA_QUEUE_ROLE_SRQ_RING, depth, mapping);
      srfq_ring = make_queue_ring({name, "_srfq_ring"},
                                  RDMA_QUEUE_ROLE_SRFQ_RING, depth, mapping);
      ring_ref = make_queue_ref({name, "_srq_ref"},
                                RDMA_QUEUE_ROLE_SRQ_RING, mapping,
                                ring.storage_bytes,
                                RDMA_OWNERSHIP_BORROWED);
      srfq_ref = make_queue_ref({name, "_srfq_ref"},
                                RDMA_QUEUE_ROLE_SRFQ_RING, mapping,
                                srfq_ring.storage_bytes,
                                RDMA_OWNERSHIP_BORROWED);
      pd_ref = make_queue_ref({name, "_srq_pd"}, RDMA_QUEUE_ROLE_SRQ_PD,
                              mapping, 4096,
                              RDMA_OWNERSHIP_CONTROL_PLANE);
      srfq_pd = make_queue_ref({name, "_srfq_pd"},
                               RDMA_QUEUE_ROLE_SRFQ_PD, mapping, 4096,
                               RDMA_OWNERSHIP_CONTROL_PLANE);
      plan.rings.push_back(ring);
      plan.rings.push_back(srfq_ring);
      plan.refs.push_back(ring_ref);
      plan.refs.push_back(srfq_ref);
      plan.refs.push_back(pd_ref);
      plan.refs.push_back(srfq_pd);
      plan.context_ref = make_queue_context({name, "_context"}, kind,
                                            owner);
      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_srfq_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_SRFQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
      flush_target.pd_ref = srfq_pd;
      plan.flush_targets.push_back(flush_target);
      flush_target = rdma_queue_flush_target::type_id::create(
        {name, "_srq_flush"}
      );
      flush_target.role = RDMA_QUEUE_ROLE_SRQ_PD;
      flush_target.phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
      flush_target.pd_ref = pd_ref;
      plan.flush_targets.push_back(flush_target);
    end
    return plan;
  endfunction

  // 功能：make_qp_ring 创建独立的 rdma_qp_ring_layout；根据 name、role、depth 设置字段 ring、ring.role、ring.entry_size_bytes、ring.depth、ring.logical_bytes、ring.storage_bytes、ring.object_mode，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、role（输入）、depth（输入）；make_qp_ring 读取 name、role、depth 并使用字段 ring、ring.role、ring.entry_size_bytes、ring.depth、ring.logical_bytes、ring.storage_bytes、ring.object_mode；函数返回 rdma_qp_ring_layout，不取得调用方资源所有权。
  // 失败/边界：make_qp_ring 的结果直接由 return ring 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qp_ring_layout make_qp_ring(
    string name,
    rdma_queue_backing_role_e role,
    int unsigned depth
  );
    rdma_qp_ring_layout ring;

    ring = rdma_qp_ring_layout::type_id::create(name);
    ring.role = role;
    ring.entry_size_bytes = 64;
    ring.depth = depth;
    ring.logical_bytes = longint'(depth) * 64;
    ring.storage_bytes = ((ring.logical_bytes + 4095) / 4096) * 4096;
    ring.object_mode = RDMA_OBJECT_INDIRECT_4K;
    return ring;
  endfunction

  // 功能：make_qp_ref 创建独立的 rdma_qp_backing_ref；根据 name、role、mapping、length、ownership 设置字段 ref_value、ref_value.role、ref_value.mapping、ref_value.length、ref_value.ownership，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、role（输入）、mapping（输入）、length（输入）、ownership（输入）；make_qp_ref 读取 name、role、mapping、length、ownership 并使用字段 ref_value、ref_value.role、ref_value.mapping、ref_value.length、ref_value.ownership；函数返回 rdma_qp_backing_ref，不取得调用方资源所有权。
  // 失败/边界：make_qp_ref 的结果直接由 return ref_value 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qp_backing_ref make_qp_ref(
    string name,
    rdma_queue_backing_role_e role,
    rdma_dma_mapping mapping,
    longint unsigned length,
    rdma_resource_ownership_e ownership
  );
    rdma_qp_backing_ref ref_value;

    ref_value = rdma_qp_backing_ref::type_id::create(name);
    ref_value.role = role;
    ref_value.mapping = mapping;
    ref_value.length = length;
    ref_value.ownership = ownership;
    return ref_value;
  endfunction

  // 功能：make_qp_plan 创建独立的 rdma_qp_backing_plan；根据 name、sq_depth、rq_depth、owner、qp_h 设置字段 plan、plan.transport、plan.sq_depth、plan.rq_depth、plan.sq_ring、plan.rq_ring、sq_mapping、rq_mapping、sq_pd_mapping、rq_pd_mapping，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、sq_depth（输入）、rq_depth（输入）、owner（输入）、qp_h（输入）；make_qp_plan 读取 name、sq_depth、rq_depth、owner、qp_h 并使用字段 plan、plan.transport、plan.sq_depth、plan.rq_depth、plan.sq_ring、plan.rq_ring、sq_mapping、rq_mapping；函数返回 rdma_qp_backing_plan，不取得调用方资源所有权。
  // 失败/边界：make_qp_plan 的结果直接由 return plan 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qp_backing_plan make_qp_plan(
    string name,
    int unsigned sq_depth,
    int unsigned rq_depth,
    rdma_function_handle owner,
    rdma_handle qp_h
  );
    rdma_qp_backing_plan plan;
    rdma_dma_mapping sq_mapping;
    rdma_dma_mapping rq_mapping;
    rdma_dma_mapping sq_pd_mapping;
    rdma_dma_mapping rq_pd_mapping;

    plan = rdma_qp_backing_plan::type_id::create(name);
    plan.transport = RDMA_TRANSPORT_RC;
    plan.sq_depth = sq_depth;
    plan.rq_depth = rq_depth;
    plan.sq_ring = make_qp_ring({name, "_sq_ring"},
                                RDMA_QUEUE_ROLE_QP_SQ_RING, sq_depth);
    plan.rq_ring = make_qp_ring({name, "_rq_ring"},
                                RDMA_QUEUE_ROLE_QP_RQ_RING, rq_depth);
    sq_mapping = make_queue_mapping({name, "_sq_mapping"}, owner,
                                    64'h5000_0000);
    rq_mapping = make_queue_mapping({name, "_rq_mapping"}, owner,
                                    64'h5100_0000);
    sq_pd_mapping = make_queue_mapping({name, "_sq_pd_mapping"}, owner,
                                       64'h5200_0000);
    rq_pd_mapping = make_queue_mapping({name, "_rq_pd_mapping"}, owner,
                                       64'h5300_0000);
    sq_mapping.function_h = rdma_clone_function_handle_value(
      owner, {name, " SQ mapping"}
    );
    rq_mapping.function_h = rdma_clone_function_handle_value(
      owner, {name, " RQ mapping"}
    );
    sq_pd_mapping.function_h = rdma_clone_function_handle_value(
      owner, {name, " SQ PD mapping"}
    );
    rq_pd_mapping.function_h = rdma_clone_function_handle_value(
      owner, {name, " RQ PD mapping"}
    );
    sq_mapping.owner_h = rdma_clone_handle_value(qp_h, {name, " SQ owner"});
    rq_mapping.owner_h = rdma_clone_handle_value(qp_h, {name, " RQ owner"});
    sq_pd_mapping.owner_h = rdma_clone_handle_value(
      qp_h, {name, " SQ PD owner"}
    );
    rq_pd_mapping.owner_h = rdma_clone_handle_value(
      qp_h, {name, " RQ PD owner"}
    );
    plan.sq_ref = make_qp_ref({name, "_sq_ref"},
                              RDMA_QUEUE_ROLE_QP_SQ_RING, sq_mapping,
                              plan.sq_ring.storage_bytes,
                              RDMA_OWNERSHIP_BORROWED);
    plan.rq_ref = make_qp_ref({name, "_rq_ref"},
                              RDMA_QUEUE_ROLE_QP_RQ_RING, rq_mapping,
                              plan.rq_ring.storage_bytes,
                              RDMA_OWNERSHIP_BORROWED);
    plan.sq_pd_ref = make_qp_ref({name, "_sq_pd_ref"},
                                 RDMA_QUEUE_ROLE_QP_SQ_PD, sq_pd_mapping,
                                 4096, RDMA_OWNERSHIP_CONTROL_PLANE);
    plan.rq_pd_ref = make_qp_ref({name, "_rq_pd_ref"},
                                 RDMA_QUEUE_ROLE_QP_RQ_PD, rq_pd_mapping,
                                 4096, RDMA_OWNERSHIP_CONTROL_PLANE);
    plan.context_ref = make_queue_context({name, "_context"},
                                          RDMA_RESOURCE_QP, owner);
    plan.context_ref.owner = rdma_clone_function_handle_value(
      owner, {name, " context owner"}
    );
    plan.context_ref.hmc_ref.owner = rdma_clone_function_handle_value(
      owner, {name, " HMC owner"}
    );
    plan.context_ref.hmc_ref.size = 512;
    plan.context_ref.slot_length = 512;
    plan.context_ref.shadow_view_length = 512;
    return plan;
  endfunction

  // 功能：make_rc_qpc 创建独立的 rdma_qpc_model；根据 name、qp_h、pd_h、send_cq_h、recv_cq_h、sq_depth、rq_depth 设置字段 model、model.qp_h、model.pd_h、model.send_cq_h、model.recv_cq_h、model.transport、model.state、model.path_mtu_bytes、model.sq_depth、model.rq_depth，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、qp_h（输入）、pd_h（输入）、send_cq_h（输入）、recv_cq_h（输入）、sq_depth（输入）、rq_depth（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_rc_qpc 的结果直接由 return model 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_qpc_model make_rc_qpc(
    string name,
    rdma_handle qp_h,
    rdma_handle pd_h,
    rdma_handle send_cq_h,
    rdma_handle recv_cq_h,
    int unsigned sq_depth,
    int unsigned rq_depth
  );
    rdma_qpc_model model;
    rdma_qpc_rc_ext extension;

    model = rdma_qpc_model::type_id::create(name);
    model.qp_h = rdma_clone_handle_value(qp_h, {name, " QP"});
    model.pd_h = rdma_clone_handle_value(pd_h, {name, " PD"});
    model.send_cq_h = rdma_clone_handle_value(send_cq_h, {name, " send CQ"});
    model.recv_cq_h = rdma_clone_handle_value(recv_cq_h,
                                              {name, " receive CQ"});
    model.transport = RDMA_TRANSPORT_RC;
    model.state = RDMA_QPS_RTS;
    model.path_mtu_bytes = 4096;
    model.sq_depth = sq_depth;
    model.rq_depth = rq_depth;
    model.sq_backing.value = 64'h5200_0000;
    model.rq_backing.value = 64'h5300_0000;
    model.context_backing.value = 64'h8000_0000;
    model.sq_mode = RDMA_OBJECT_INDIRECT_4K;
    model.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    extension = rdma_qpc_rc_ext::type_id::create({name, "_rc"});
    extension.remote_qpn = 24'h123;
    model.transport_ext = extension;
    return model;
  endfunction

  // 功能：make_recovery_opcode 创建独立的 rdma_cmq_opcode_key；根据 name、opcode、variant 设置字段 key、key.profile_name、key.opcode、key.variant，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、opcode（输入）、variant（输入）；make_recovery_opcode 读取 name、opcode、variant 并使用字段 key、key.profile_name、key.opcode、key.variant；函数返回 rdma_cmq_opcode_key，不取得调用方资源所有权。
  // 失败/边界：make_recovery_opcode 的结果直接由 return key 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_opcode_key make_recovery_opcode(
    string name,
    bit [31:0] opcode,
    string variant
  );
    rdma_cmq_opcode_key key;

    key = rdma_cmq_opcode_key::type_id::create(name);
    key.profile_name = "rdma";
    key.opcode = opcode;
    key.variant = variant;
    return key;
  endfunction

  // 功能：make_recovery_mapping 创建独立的 rdma_dma_mapping；根据 name、owner、qp_h、iova_value 设置字段 mapping、mapping.function_h、mapping.owner_h、mapping.size，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、owner（输入）、qp_h（输入）、iova_value（输入）；make_recovery_mapping 读取 name、owner、qp_h、iova_value 并使用字段 mapping、mapping.function_h、mapping.owner_h、mapping.size；函数返回 rdma_dma_mapping，不取得调用方资源所有权。
  // 失败/边界：make_recovery_mapping 的结果直接由 return mapping 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_dma_mapping make_recovery_mapping(
    string name,
    rdma_function_handle owner,
    rdma_handle qp_h,
    longint unsigned iova_value
  );
    rdma_dma_mapping mapping;

    mapping = make_queue_mapping(name, owner, iova_value);
    mapping.function_h = rdma_clone_function_handle_value(
      owner, {name, " Function"}
    );
    mapping.owner_h = rdma_clone_handle_value(qp_h, {name, " QP"});
    mapping.size = 512;
    return mapping;
  endfunction

  // 功能：make_recovery_ticket 创建独立的 rdma_cmq_ticket；根据 name、owner、cmq_h、opcode_key 设置字段 ticket、ticket.command_id、ticket.function_h、ticket.cmq_h、ticket.slot_sequence、ticket.sq_index、ticket.sq_wrap、ticket.opcode_key、ticket.absolute_deadline，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、owner（输入）、cmq_h（输入）、opcode_key（输入）；make_recovery_ticket 读取 name、owner、cmq_h、opcode_key 并使用字段 ticket、ticket.command_id、ticket.function_h、ticket.cmq_h、ticket.slot_sequence、ticket.sq_index、ticket.sq_wrap、ticket.opcode_key；函数返回 rdma_cmq_ticket，不取得调用方资源所有权。
  // 失败/边界：make_recovery_ticket 的结果直接由 return ticket 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_ticket make_recovery_ticket(
    string name,
    rdma_function_handle owner,
    rdma_handle cmq_h,
    rdma_cmq_opcode_key opcode_key
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234;
    ticket.function_h = rdma_clone_function_handle_value(
      owner, {name, " Function"}
    );
    ticket.cmq_h = rdma_clone_handle_value(cmq_h, {name, " CMQ"});
    ticket.slot_sequence = 3;
    ticket.sq_index = 3;
    ticket.sq_wrap = 1'b0;
    ticket.opcode_key = rdma_cmq_clone_opcode_key_value(opcode_key, name);
    ticket.absolute_deadline = 100;
    return ticket;
  endfunction

  // 功能：在 rdma_request_model_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：check_name（输入）、status（输入）、expected_code（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT
  //   转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  // 功能：在 rdma_request_model_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_create_qp_req req;
    rdma_create_qp_req req_clone;
    rdma_qp_context_attributes context_attrs;
    rdma_queue_capabilities qp_caps;
    rdma_function_handle function_h;
    rdma_handle pd_h;
    rdma_handle mr_h;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_handle srq_h;
    rdma_handle ceq_h;
    rdma_handle aeq_h;
    rdma_handle cmq_h;
    rdma_handle mismatched_h;
    rdma_create_pd_req create_pd;
    rdma_register_mr_req register_mr;
    rdma_register_mr_req register_mr_clone;
    rdma_create_cq_req create_cq;
    rdma_create_cq_req create_cq_clone;
    rdma_create_srq_req create_srq;
    rdma_create_srq_req create_srq_clone;
    rdma_create_ceq_req create_ceq;
    rdma_create_ceq_req create_ceq_clone;
    rdma_create_aeq_req create_aeq;
    rdma_create_aeq_req create_aeq_clone;
    rdma_destroy_resource_req destroy_resource;
    rdma_modify_qp_req modify_qp;
    rdma_post_send_req post_send;
    rdma_post_send_req post_send_clone;
    rdma_post_recv_req post_recv;
    rdma_sge sge;
    rdma_sge atomic_sge;
    rdma_sge extra_sge;
    rdma_sge recv_sge;
    rdma_function function_resource;
    rdma_pd pd_resource;
    rdma_mr mr_resource;
    rdma_mr mr_resource_clone;
    rdma_cq cq_resource;
    rdma_cq cq_resource_clone;
    rdma_qp qp_resource;
    rdma_qp qp_resource_clone;
    rdma_qp_recovery_state qp_recovery;
    rdma_qp_recovery_state qp_recovery_clone;
    rdma_qp_recovery_state qp_occ_recovery;
    rdma_qp_recovery_state split_qp_recovery;
    rdma_recovery_record qp_recovery_record;
    rdma_qp_ring_layout saved_qp_rq_ring;
    rdma_qp_backing_ref saved_qp_rq_ref;
    rdma_qp_backing_ref saved_qp_rq_pd_ref;
    rdma_queue_slot_token_contract recovery_token;
    rdma_queue_completion_authority saved_completion_authority;
    rdma_srq srq_resource;
    rdma_ceq ceq_resource;
    rdma_aeq aeq_resource;
    rdma_cmq cmq_resource;
    rdma_dma_mapping mapping;
    rdma_dma_mapping qp_borrowed_mapping;
    rdma_queue_backing_slice qp_borrowed_slice, qp_borrowed_slice2;
    rdma_backing_ref backing_ref;
    rdma_hmc_ref hmc_ref;
    rdma_qpc_model qpc;
    rdma_qpc_model qpc_clone;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_rc_ext rc_ext_clone;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;
    rdma_qpc_urc_ext urc_ext_clone;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_cmq_sqe_model cmq_create_qp;
    rdma_cmq_sqe_model cmq_modify_qp;
    rdma_cmq_sqe_model cmq_clone;
    rdma_cmq_completion_model cmq_completion;
    rdma_sqe_model rc_sqe;
    rdma_sqe_model ud_sqe;
    rdma_sqe_model urc_sqe;
    rdma_sqe_model urc_sqe_clone;
    rdma_sqe_model sqe_clone;
    rdma_sqe_model ud_sqe_clone;
    rdma_sqe_rc_ext sqe_rc_ext;
    rdma_sqe_rc_ext sqe_rc_ext_clone;
    rdma_sqe_ud_ext sqe_ud_ext;
    rdma_sqe_ud_ext sqe_ud_ext_clone;
    rdma_sqe_urc_ext sqe_urc_ext;
    rdma_sqe_urc_ext sqe_urc_ext_clone;
    rdma_rqe_model rqe;
    rdma_cqe_model cqe;
    rdma_ceqe_model ceqe;
    rdma_aeqe_model aeqe;
    rdma_doorbell_model doorbell;
    rdma_doorbell_model doorbell_clone;
    rdma_packet packet;
    rdma_packet packet_clone;
    rdma_net_response_policy policy;
    rdma_net_response_policy policy_clone;
    rdma_net_fault fault;
    rdma_net_fault fault_clone;
    uvm_object cloned_object;
    string iova_type_name;
    string hmc_type_name;

    phase.raise_objection(this);

    function_h = make_function_handle("function_h");
    pd_h = make_handle("pd_h", RDMA_RESOURCE_PD, 32'h101);
    mr_h = make_handle("mr_h", RDMA_RESOURCE_MR, 32'h202);
    cq_h = make_handle("cq_h", RDMA_RESOURCE_CQ, 32'h303);
    qp_h = make_handle("qp_h", RDMA_RESOURCE_QP, 32'h404);
    srq_h = make_handle("srq_h", RDMA_RESOURCE_SRQ, 32'h505);
    ceq_h = make_handle("ceq_h", RDMA_RESOURCE_CEQ, 32'h606);
    aeq_h = make_handle("aeq_h", RDMA_RESOURCE_AEQ, 32'h707);
    cmq_h = make_handle("cmq_h", RDMA_RESOURCE_CMQ, 32'h808);

    req = rdma_create_qp_req::type_id::create("req");
    req.owner = function_h;
    req.transport = RDMA_TRANSPORT_RC;
    req.sq_depth = 128;
    req.rq_depth = 128;
    req.max_send_sge = 4;
    req.max_recv_sge = 4;
    req.pd_h = pd_h;
    req.send_cq_h = cq_h;
    req.recv_cq_h = cq_h;
    req.sq_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    req.rq_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    context_attrs = rdma_qp_context_attributes::type_id::create("req_attrs");
    context_attrs.path_mtu_bytes = 4096;
    context_attrs.address_vector = rdma_address_vector::type_id::create("req_av");
    context_attrs.behavior = rdma_qpc_behavior::type_id::create("req_behavior");
    rc_ext = rdma_qpc_rc_ext::type_id::create("req_rc");
    rc_ext.remote_qpn = 24'h101;
    context_attrs.transport_ext = rc_ext;
    req.context_attrs = context_attrs;
    expect_status("CREATE_QP", req.validate(), RDMA_SC_OK);
    qp_caps = '{default:'0};
    qp_caps.max_wq_sge = 4;
    qp_caps.max_queue_ring_bytes = 8192;
    expect_status("CREATE_QP_CAPS", req.validate_queue_caps(qp_caps),
                  RDMA_SC_OK);
    qp_caps.max_wq_sge = 3;
    expect_status("CREATE_QP_SGE_CAP", req.validate_queue_caps(qp_caps),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_caps.max_wq_sge = 4;
    qp_caps.max_queue_ring_bytes = 4096;
    expect_status("CREATE_QP_RING_CAP", req.validate_queue_caps(qp_caps),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_caps.max_queue_ring_bytes = 8192;
    req.context_attrs = null;
    expect_status("CREATE_QP_NULL_ATTRS", req.validate(), RDMA_SC_INVALID_STATE);
    req.context_attrs = context_attrs;
    cloned_object = req.clone();
    if (!$cast(req_clone, cloned_object) || req_clone == req ||
        req_clone.sq_backing == req.sq_backing ||
        req_clone.rq_backing == req.rq_backing ||
        req_clone.context_attrs == req.context_attrs ||
        req_clone.context_attrs.transport_ext == req.context_attrs.transport_ext)
      `uvm_error("CREATE_QP_DEEP_COPY", "create QP clone aliases owned graph")
    else begin
      req_clone.context_attrs.path_mtu_bytes = 2048;
      if (req.context_attrs.path_mtu_bytes != 4096)
        `uvm_error("CREATE_QP_DEEP_COPY", "clone mutation reached request")
      rc_ext.remote_qpn = 24'h202;
      if (!$cast(rc_ext_clone, req_clone.context_attrs.transport_ext) ||
          rc_ext_clone.remote_qpn != 24'h101)
        `uvm_error("CREATE_QP_SNAPSHOT",
                   "caller extension mutation reached cloned snapshot")
      rc_ext.remote_qpn = 24'h101;
    end
    req.sq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    qp_borrowed_mapping = make_queue_mapping("qp_borrowed_mapping",
                                             function_h, 64'h5800_0000);
    qp_borrowed_slice = rdma_queue_backing_slice::type_id::create(
      "qp_borrowed_slice"
    );
    qp_borrowed_slice.role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_borrowed_slice.mapping = qp_borrowed_mapping;
    qp_borrowed_slice.length = 8192;
    req.sq_backing.slices.push_back(qp_borrowed_slice);
    expect_status("CREATE_QP_BORROWED", req.validate(), RDMA_SC_OK);
    cloned_object = req.clone();
    if (!$cast(req_clone, cloned_object) ||
        req_clone.sq_backing == req.sq_backing ||
        req_clone.sq_backing.slices.size() != 1 ||
        req_clone.sq_backing.slices[0] == req.sq_backing.slices[0] ||
        req_clone.sq_backing.slices[0].mapping ==
          req.sq_backing.slices[0].mapping)
      `uvm_error("CREATE_QP_BORROWED_COPY",
                 "borrowed QP backing clone aliases source graph")
    qp_borrowed_slice.length = 4096;
    qp_borrowed_slice2 = rdma_queue_backing_slice::type_id::create(
      "qp_borrowed_slice2"
    );
    qp_borrowed_slice2.role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_borrowed_slice2.mapping = qp_borrowed_mapping;
    qp_borrowed_slice2.mapping_offset = 4096;
    qp_borrowed_slice2.length = 4096;
    qp_borrowed_slice2.logical_queue_offset = 4096;
    req.sq_backing.slices.push_back(qp_borrowed_slice2);
    expect_status("CREATE_QP_BORROWED_SPLIT", req.validate(), RDMA_SC_OK);
    qp_borrowed_slice2.logical_queue_offset = 8192;
    expect_status("CREATE_QP_BORROWED_GAP", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_borrowed_slice2.logical_queue_offset = 0;
    expect_status("CREATE_QP_BORROWED_OVERLAP", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_borrowed_slice2.logical_queue_offset = 4096;
    req.sq_backing.slices.delete(1);
    expect_status("CREATE_QP_BORROWED_UNDER_COVERAGE", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_borrowed_slice.length = 8192;
    qp_borrowed_slice2.logical_queue_offset = 8192;
    req.sq_backing.slices.push_back(qp_borrowed_slice2);
    expect_status("CREATE_QP_BORROWED_OVER_COVERAGE", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.sq_backing = rdma_queue_backing_spec::type_id::create(
      "restored_sq_backing"
    );
    req.owner = null;
    expect_status("CREATE_QP_OWNER", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.owner = function_h;
    req.pd_h = cq_h;
    expect_status("CREATE_QP_PD", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.pd_h = pd_h;
    req.send_cq_h = qp_h;
    expect_status("CREATE_QP_SEND_CQ", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.send_cq_h = cq_h;
    req.recv_cq_h = qp_h;
    expect_status("CREATE_QP_RECV_CQ", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.recv_cq_h = cq_h;
    mismatched_h = make_handle("qp_cross_pd_h", RDMA_RESOURCE_PD, 32'h901);
    mismatched_h.function_uid++;
    req.pd_h = mismatched_h;
    expect_status("CREATE_QP_PD_OWNER", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.pd_h = pd_h;
    mismatched_h = make_handle("qp_stale_cq_h", RDMA_RESOURCE_CQ, 32'h902);
    mismatched_h.generation++;
    req.send_cq_h = mismatched_h;
    expect_status("CREATE_QP_CQ_GENERATION", req.validate(),
                  RDMA_SC_STALE_GENERATION);
    req.send_cq_h = cq_h;
    req.srq_h = srq_h;
    expect_status("CREATE_QP_SRQ", req.validate(), RDMA_SC_OK);
    expect_status("CREATE_QP_SRQ_DEPTH", req.validate_srq_depth(128),
                  RDMA_SC_OK);
    expect_status("CREATE_QP_SRQ_DEPTH_MISMATCH", req.validate_srq_depth(64),
                  RDMA_SC_INVALID_ARGUMENT);
    req.rq_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    qp_borrowed_slice = rdma_queue_backing_slice::type_id::create(
      "qp_borrowed_rq_slice"
    );
    qp_borrowed_slice.role = RDMA_QUEUE_ROLE_QP_RQ_RING;
    qp_borrowed_slice.mapping = make_queue_mapping("qp_borrowed_rq_mapping",
                                                   function_h,
                                                   64'h5900_0000);
    qp_borrowed_slice.length = 8192;
    req.rq_backing.slices.push_back(qp_borrowed_slice);
    expect_status("CREATE_QP_SRQ_NONEMPTY_RQ", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.rq_backing = rdma_queue_backing_spec::type_id::create(
      "restored_rq_backing"
    );
    mismatched_h = make_handle("qp_cross_srq_h", RDMA_RESOURCE_SRQ,
                               32'h903);
    mismatched_h.function_uid++;
    req.srq_h = mismatched_h;
    expect_status("CREATE_QP_SRQ_OWNER", req.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    req.srq_h = null;
    req.sq_depth = 1000;
    if (req.validate().ok()) `uvm_error("REQ", "non-power-of-two depth accepted")
    expect_status("QP_DEPTH", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    req.sq_depth = 128;

    req.transport = RDMA_TRANSPORT_URC;
    req.srq_h = null;
    req.context_attrs = rdma_qp_context_attributes::type_id::create("urc_attrs");
    req.context_attrs.path_mtu_bytes = 4096;
    req.context_attrs.address_vector = rdma_address_vector::type_id::create("urc_req_av");
    req.context_attrs.behavior = rdma_qpc_behavior::type_id::create("urc_req_behavior");
    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_req_ext");
    urc_ext.remote_qpn = 24'h102;
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 64;
    req.context_attrs.transport_ext = urc_ext;
    expect_status("CREATE_QP_URC_ZERO_INTERNAL_ADDRS", req.validate(), RDMA_SC_OK);
    urc_ext.queues.rsq_backing.value = 64'h6100_0000;
    expect_status("CREATE_QP_URC_CALLER_ADDR", req.validate(), RDMA_SC_INVALID_ARGUMENT);
    urc_ext.queues.rsq_backing.value = 0;
    req.transport = RDMA_TRANSPORT_RC;
    req.context_attrs = context_attrs;

    create_pd = rdma_create_pd_req::type_id::create("create_pd");
    create_pd.owner = function_h;
    create_pd.request_id = 64'h10;
    expect_status("CREATE_PD", create_pd.validate(), RDMA_SC_OK);

    register_mr = rdma_register_mr_req::type_id::create("register_mr");
    if (register_mr.access != '0)
      `uvm_error("REGISTER_MR_ACCESS_DEFAULT",
                 "new register MR request access is not zero")
    register_mr.owner = function_h;
    register_mr.pd_h = pd_h;
    register_mr.iova.value = 64'h1111_0000;
    register_mr.length = 64'h4000;
    register_mr.access = '{local_write:1'b1, remote_read:1'b1,
                           remote_write:1'b1, memory_window_bind:1'b0,
                           remote_atomic:1'b0};
    expect_status("REGISTER_MR", register_mr.validate(), RDMA_SC_OK);
    register_mr.access.remote_atomic = 1'b1;
    cloned_object = register_mr.clone();
    if (!$cast(register_mr_clone, cloned_object))
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 "register MR clone lost dynamic type")
    else if (!register_mr_clone.access.remote_atomic)
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 "register MR clone lost remote atomic access")
    else if (register_mr_clone.access != register_mr.access)
      `uvm_error("REGISTER_MR_ACCESS_COPY",
                 $sformatf("register MR clone changed access from 0x%0h to 0x%0h",
                           register_mr.access, register_mr_clone.access))
    register_mr.owner = null;
    expect_status("REGISTER_MR_OWNER", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    register_mr.owner = function_h;
    register_mr.length = 0;
    expect_status("REGISTER_MR_LENGTH", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    register_mr.length = 64'h4000;
    register_mr.pd_h = null;
    expect_status("REGISTER_MR_PD", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("mr_cross_pd_h", RDMA_RESOURCE_PD, 32'h904);
    mismatched_h.function_uid++;
    register_mr.pd_h = mismatched_h;
    expect_status("REGISTER_MR_PD_OWNER", register_mr.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("mr_stale_pd_h", RDMA_RESOURCE_PD, 32'h905);
    mismatched_h.generation++;
    register_mr.pd_h = mismatched_h;
    expect_status("REGISTER_MR_PD_GENERATION", register_mr.validate(),
                  RDMA_SC_STALE_GENERATION);
    register_mr.pd_h = pd_h;

    create_cq = rdma_create_cq_req::type_id::create("create_cq");
    if (create_cq.cqe_size_bytes != 64 || create_cq.ring_backing == null ||
        create_cq.ring_backing.mode != RDMA_QUEUE_BACKING_OWNED)
      `uvm_error("CREATE_CQ_DEFAULTS",
                 "CQ request defaults do not describe a 64-byte owned ring")
    create_cq.owner = function_h;
    create_cq.depth = 256;
    create_cq.ceq_h = ceq_h;
    expect_status("CREATE_CQ", create_cq.validate(), RDMA_SC_OK);
    create_cq.cqe_size_bytes = 48;
    expect_status("CREATE_CQ_CQE_SIZE", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_cq.cqe_size_bytes = 64;
    cloned_object = create_cq.clone();
    if (!$cast(create_cq_clone, cloned_object) ||
        create_cq_clone.ceq_h == null ||
        create_cq_clone.ring_backing == null ||
        create_cq_clone.ceq_h == create_cq.ceq_h ||
        create_cq_clone.ring_backing == create_cq.ring_backing ||
        create_cq_clone.cqe_size_bytes != 64)
      `uvm_error("CREATE_CQ_CLONE",
                 "CQ request clone lost or aliased typed fields")
    else begin
      create_cq_clone.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
      create_cq_clone.ceq_h.object_id++;
      if (create_cq.ring_backing.mode != RDMA_QUEUE_BACKING_OWNED ||
          create_cq.ceq_h.object_id != 32'h606)
        `uvm_error("CREATE_CQ_CLONE",
                   "CQ request clone mutation reached source")
    end
    create_cq.owner = null;
    expect_status("CREATE_CQ_STRUCTURAL_ONLY", create_cq.validate(),
                  RDMA_SC_OK);
    create_cq.owner = function_h;
    create_cq.ceq_h = null;
    expect_status("CREATE_CQ_OPTIONAL_CEQ", create_cq.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("cq_cross_ceq_h", RDMA_RESOURCE_CEQ, 32'h906);
    mismatched_h.function_uid++;
    create_cq.ceq_h = mismatched_h;
    expect_status("CREATE_CQ_CEQ_PREFLIGHT", create_cq.validate(),
                  RDMA_SC_OK);
    create_cq.ceq_h = ceq_h;
    create_cq.depth = 0;
    expect_status("CREATE_CQ_DEPTH", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_cq.depth = 256;
    create_cq.ring_backing = null;
    expect_status("CREATE_CQ_BACKING", create_cq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    create_srq = rdma_create_srq_req::type_id::create("create_srq");
    if (create_srq.limit_threshold != 16 ||
        create_srq.payload_backing == null ||
        create_srq.payload_backing.mode != RDMA_QUEUE_BACKING_OWNED)
      `uvm_error("CREATE_SRQ_DEFAULTS",
                 "SRQ request defaults do not describe threshold 16 owned payload")
    create_srq.owner = function_h;
    create_srq.depth = 128;
    create_srq.max_sge = 2;
    create_srq.pd_h = pd_h;
    expect_status("CREATE_SRQ", create_srq.validate(), RDMA_SC_OK);
    create_srq.limit_threshold = 18;
    expect_status("CREATE_SRQ_LIMIT_ALIGN", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_srq.limit_threshold = 12;
    expect_status("CREATE_SRQ_LIMIT_MIN", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_srq.limit_threshold = 132;
    expect_status("CREATE_SRQ_LIMIT_DEPTH", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_srq.limit_threshold = 16;
    cloned_object = create_srq.clone();
    if (!$cast(create_srq_clone, cloned_object) ||
        create_srq_clone.pd_h == null ||
        create_srq_clone.payload_backing == null ||
        create_srq_clone.pd_h == create_srq.pd_h ||
        create_srq_clone.payload_backing == create_srq.payload_backing ||
        create_srq_clone.limit_threshold != 16)
      `uvm_error("CREATE_SRQ_CLONE",
                 "SRQ request clone lost or aliased typed fields")
    create_srq.owner = null;
    expect_status("CREATE_SRQ_STRUCTURAL_ONLY", create_srq.validate(),
                  RDMA_SC_OK);
    create_srq.owner = function_h;
    create_srq.pd_h = cq_h;
    expect_status("CREATE_SRQ_PD_PREFLIGHT", create_srq.validate(),
                  RDMA_SC_OK);
    mismatched_h = make_handle("srq_stale_pd_h", RDMA_RESOURCE_PD, 32'h907);
    mismatched_h.generation++;
    create_srq.pd_h = mismatched_h;
    expect_status("CREATE_SRQ_PD_GENERATION_PREFLIGHT", create_srq.validate(),
                  RDMA_SC_OK);
    create_srq.pd_h = pd_h;
    create_srq.max_sge = 0;
    expect_status("CREATE_SRQ_SGE", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    create_srq.max_sge = 2;
    create_srq.payload_backing = null;
    expect_status("CREATE_SRQ_BACKING", create_srq.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    create_ceq = rdma_create_ceq_req::type_id::create("create_ceq");
    if (create_ceq.ring_backing == null ||
        create_ceq.ring_backing.mode != RDMA_QUEUE_BACKING_OWNED)
      `uvm_error("CREATE_CEQ_DEFAULTS", "CEQ ring backing default is invalid")
    create_ceq.depth = 64;
    create_ceq.vector_id = 3;
    expect_status("CREATE_CEQ", create_ceq.validate(), RDMA_SC_OK);
    cloned_object = create_ceq.clone();
    if (!$cast(create_ceq_clone, cloned_object) ||
        create_ceq_clone.ring_backing == null ||
        create_ceq_clone.ring_backing == create_ceq.ring_backing ||
        create_ceq_clone.vector_id != 3)
      `uvm_error("CREATE_CEQ_CLONE",
                 "CEQ request clone lost or aliased typed fields")
    create_aeq = rdma_create_aeq_req::type_id::create("create_aeq");
    if (create_aeq.ring_backing == null ||
        create_aeq.ring_backing.mode != RDMA_QUEUE_BACKING_OWNED)
      `uvm_error("CREATE_AEQ_DEFAULTS", "AEQ ring backing default is invalid")
    create_aeq.depth = 64;
    create_aeq.vector_id = 3;
    expect_status("CREATE_AEQ", create_aeq.validate(), RDMA_SC_OK);
    cloned_object = create_aeq.clone();
    if (!$cast(create_aeq_clone, cloned_object) ||
        create_aeq_clone.ring_backing == null ||
        create_aeq_clone.ring_backing == create_aeq.ring_backing ||
        create_aeq_clone.vector_id != 3)
      `uvm_error("CREATE_AEQ_CLONE",
                 "AEQ request clone lost or aliased typed fields")

    destroy_resource =
      rdma_destroy_resource_req::type_id::create("destroy_resource");
    expect_status("DESTROY_NULL", destroy_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    destroy_resource.target_h = mr_h;
    expect_status("DESTROY", destroy_resource.validate(), RDMA_SC_OK);

    modify_qp = rdma_modify_qp_req::type_id::create("modify_qp");
    modify_qp.new_state = RDMA_QPS_RTS;
    expect_status("MODIFY_NULL", modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    modify_qp.qp_h = qp_h;
    modify_qp.destination_qpn = 24'h345;
    modify_qp.destination_qpn_valid = 1'b1;
    expect_status("MODIFY", modify_qp.validate(), RDMA_SC_OK);
    expect_status("MODIFY_RC_PATCH",
                  modify_qp.validate_for_transport(RDMA_TRANSPORT_RC),
                  RDMA_SC_OK);
    expect_status("MODIFY_UD_DESTINATION_PATCH",
                  modify_qp.validate_for_transport(RDMA_TRANSPORT_UD),
                  RDMA_SC_INVALID_ARGUMENT);
    modify_qp.destination_qpn_valid = 1'b0;
    modify_qp.send_psn_valid = 1'b1;
    expect_status("MODIFY_UD_SEND_PSN",
                  modify_qp.validate_for_transport(RDMA_TRANSPORT_UD),
                  RDMA_SC_INVALID_ARGUMENT);
    modify_qp.send_psn_valid = 1'b0;
    modify_qp.recv_psn_valid = 1'b1;
    expect_status("MODIFY_UD_RECV_PSN",
                  modify_qp.validate_for_transport(RDMA_TRANSPORT_UD),
                  RDMA_SC_INVALID_ARGUMENT);

    qp_recovery = rdma_qp_recovery_state::type_id::create("qp_recovery");
    qp_recovery.intent = RDMA_QP_RECOVER_MODIFY_RECONCILE;
    qp_recovery.prior_qpc = make_rc_qpc("qp_prior_qpc", qp_h, pd_h, cq_h,
                                        cq_h, 128, 128);
    qp_recovery.candidate_qpc = make_rc_qpc(
      "qp_candidate_qpc", qp_h, pd_h, cq_h, cq_h, 128, 128
    );
    qp_recovery.qp_plan = make_qp_plan("qp_recovery_plan", 128, 128,
                                       function_h, qp_h);
    cloned_object = qp_recovery.qp_plan.context_ref.clone();
    if (!$cast(qp_recovery.context_ref, cloned_object))
      `uvm_fatal("QP_RECOVERY_SETUP", "QP context clone lost type")
    qp_recovery.qp_plan.context_ref.local_id = qp_h.object_id;
    qp_recovery.context_ref.local_id = qp_h.object_id;
    qp_recovery.staging_mapping = make_recovery_mapping(
      "qp_recovery_staging", function_h, qp_h, 64'h8100_0000
    );
    qp_recovery.query_mapping = make_recovery_mapping(
      "qp_recovery_query", function_h, qp_h, 64'h8200_0000
    );
    qp_recovery.create_opcode = make_recovery_opcode(
      "qp_recovery_create", 32'h10, "qp_create"
    );
    qp_recovery.modify_opcode = make_recovery_opcode(
      "qp_recovery_modify", 32'h11, "qp_modify"
    );
    qp_recovery.delete_opcode = make_recovery_opcode(
      "qp_recovery_delete", 32'h12, "qp_delete"
    );
    qp_recovery.query_opcode = make_recovery_opcode(
      "qp_recovery_query_opcode", 32'h13, "qp_query"
    );
    qp_recovery.occ_opcode = make_recovery_opcode(
      "qp_recovery_occ_opcode", 32'h14, "occ_flush"
    );
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] = 1'b1;
    expect_status("QP_RECOVERY", qp_recovery.validate(), RDMA_SC_OK);
    begin
      rdma_qp_recovery_state preprogram_recovery;
      rdma_qp_recovery_state preprogram_clone;
      rdma_qp_recovery_state malformed_preprogram;
      longint unsigned saved_sq_iova;

      cloned_object = qp_recovery.clone();
      if (!$cast(preprogram_recovery, cloned_object))
        `uvm_fatal("QP_PREPROGRAM_RECOVERY_SETUP",
                   "pre-program recovery clone lost type")
      preprogram_recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
      preprogram_recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
      preprogram_recovery.ambiguous_ticket = null;
      preprogram_recovery.prior_qpc = null;
      preprogram_recovery.candidate_qpc = null;
      preprogram_recovery.staging_mapping = null;
      preprogram_recovery.query_mapping = null;
      preprogram_recovery.context_ref = null;
      preprogram_recovery.qp_plan.context_ref = null;
      foreach (preprogram_recovery.role_complete[i])
        preprogram_recovery.role_complete[i] = 1'b0;
      expect_status("QP_PREPROGRAM_RECOVERY",
                    preprogram_recovery.validate(), RDMA_SC_OK);

      cloned_object = preprogram_recovery.clone();
      if (!$cast(preprogram_clone, cloned_object) ||
          preprogram_clone == preprogram_recovery ||
          preprogram_clone.qp_plan == preprogram_recovery.qp_plan ||
          preprogram_clone.context_ref != null ||
          preprogram_clone.qp_plan.context_ref != null ||
          preprogram_clone.qp_plan.sq_ref == null ||
          preprogram_clone.qp_plan.sq_ref ==
            preprogram_recovery.qp_plan.sq_ref ||
          preprogram_clone.qp_plan.sq_ref.mapping ==
            preprogram_recovery.qp_plan.sq_ref.mapping)
        `uvm_error("QP_PREPROGRAM_RECOVERY_CLONE",
                   "partial recovery clone aliased or invented authority")
      else begin
        saved_sq_iova = preprogram_clone.qp_plan.sq_ref.mapping.iova.value;
        preprogram_recovery.qp_plan.sq_ref.mapping.iova.value += 4096;
        if (preprogram_clone.qp_plan.sq_ref.mapping.iova.value != saved_sq_iova)
          `uvm_error("QP_PREPROGRAM_RECOVERY_CLONE_DETACH",
                     "partial recovery clone shared mapping value state")
        preprogram_recovery.qp_plan.sq_ref.mapping.iova.value -= 4096;
      end

      cloned_object = preprogram_recovery.clone();
      if (!$cast(malformed_preprogram, cloned_object))
        `uvm_fatal("QP_PREPROGRAM_RECOVERY_MALFORMED",
                   "malformed recovery clone lost type")
      malformed_preprogram.qp_plan.rq_pd_ref.mapping.function_h.function_uid++;
      expect_status("QP_PREPROGRAM_RECOVERY_MIXED_OWNER",
                    malformed_preprogram.validate(),
                    RDMA_SC_INVALID_ARGUMENT);
      malformed_preprogram.qp_plan = null;
      expect_status("QP_PREPROGRAM_RECOVERY_NO_PLAN",
                    malformed_preprogram.validate(),
                    RDMA_SC_INVALID_STATE);
    end
    cloned_object = qp_recovery.clone();
    if (!$cast(split_qp_recovery, cloned_object))
      `uvm_fatal("QP_RECOVERY_SPLIT_SETUP",
                 "split-identity QP recovery clone lost type")
    split_qp_recovery.qp_plan.context_ref.local_id = 21'h1_2345;
    split_qp_recovery.context_ref.local_id = 21'h1_2345;
    split_qp_recovery.prior_qpc.qp_h.object_id = 21'h1_2345;
    split_qp_recovery.candidate_qpc.qp_h.object_id = 21'h1_2345;
    if (split_qp_recovery.qp_plan.sq_ref.mapping.owner_h.object_id ==
        split_qp_recovery.context_ref.local_id)
      `uvm_fatal("QP_RECOVERY_SPLIT_SETUP",
                 "registry-global QP ID must differ from local QPN")
    expect_status("QP_RECOVERY_SPLIT_GLOBAL_LOCAL_IDENTITY",
                  split_qp_recovery.validate(), RDMA_SC_OK);
    cloned_object = qp_recovery.clone();
    if (!$cast(qp_occ_recovery, cloned_object))
      `uvm_fatal("QP_OCC_RECOVERY_SETUP", "QP OCC recovery clone lost type")
    qp_occ_recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    qp_occ_recovery.ambiguous_operation = RDMA_QP_AMBIG_OCC_FLUSH;
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_occ_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] = 1'b0;
    qp_occ_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_occ_qpn_ticket", function_h, cmq_h, qp_occ_recovery.occ_opcode
    );
    expect_status("QP_OCC_RECOVERY_QPN", qp_occ_recovery.validate(),
                  RDMA_SC_OK);
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_RQ_RING;
    expect_status("QP_OCC_RECOVERY_INVALID_ROLE", qp_occ_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_PD;
    expect_status("QP_OCC_RECOVERY_OUT_OF_ORDER_SQ_PD",
                  qp_occ_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    qp_occ_recovery.ambiguous_ticket.opcode_key =
      rdma_cmq_clone_opcode_key_value(qp_occ_recovery.delete_opcode,
                                      "wrong OCC opcode");
    expect_status("QP_OCC_RECOVERY_WRONG_OPCODE", qp_occ_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_occ_recovery.ambiguous_ticket.opcode_key =
      rdma_cmq_clone_opcode_key_value(qp_occ_recovery.occ_opcode,
                                      "restored OCC opcode");
    qp_occ_recovery.ambiguous_ticket.function_h.generation++;
    expect_status("QP_OCC_RECOVERY_WRONG_FUNCTION",
                  qp_occ_recovery.validate(), RDMA_SC_INVALID_ARGUMENT);
    qp_occ_recovery.ambiguous_ticket.function_h.generation--;
    qp_occ_recovery.qp_plan.cleanup_complete = 1'b1;
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_PD;
    expect_status("QP_OCC_RECOVERY_SQ_PD", qp_occ_recovery.validate(),
                  RDMA_SC_OK);
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_RQ_PD;
    expect_status("QP_OCC_RECOVERY_OUT_OF_ORDER_RQ_PD",
                  qp_occ_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_occ_recovery.qp_plan.sq_pd_flush_complete = 1'b1;
    expect_status("QP_OCC_RECOVERY_RQ_PD", qp_occ_recovery.validate(),
                  RDMA_SC_OK);
    qp_occ_recovery.intent = RDMA_QP_RECOVER_MODIFY_RECONCILE;
    expect_status("QP_OCC_RECOVERY_MODIFY_REJECTED",
                  qp_occ_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_occ_recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    cloned_object = qp_occ_recovery.clone();
    if (!$cast(qp_recovery_clone, cloned_object) ||
        qp_recovery_clone.occ_opcode == qp_occ_recovery.occ_opcode ||
        qp_recovery_clone.ambiguous_ticket ==
          qp_occ_recovery.ambiguous_ticket ||
        qp_recovery_clone.ambiguous_role != RDMA_QUEUE_ROLE_QP_RQ_PD)
      `uvm_error("QP_OCC_RECOVERY_COPY",
                 "QP OCC recovery clone lost or aliased authority")
    else begin
      qp_recovery_clone.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_RING;
      qp_recovery_clone.occ_opcode.opcode++;
      if (qp_occ_recovery.ambiguous_role != RDMA_QUEUE_ROLE_QP_RQ_PD ||
          qp_occ_recovery.occ_opcode.opcode != 32'h14)
        `uvm_error("QP_OCC_RECOVERY_COPY_ISOLATION",
                   "mutating QP OCC clone changed source authority")
    end
    qp_occ_recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_occ_recovery.ambiguous_ticket = null;
    qp_occ_recovery.ambiguous_role = RDMA_QUEUE_ROLE_QP_SQ_PD;
    expect_status("QP_OCC_RECOVERY_NON_OCC_CANONICAL_ROLE",
                  qp_occ_recovery.validate(), RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_unexpected_ticket", function_h, cmq_h, qp_recovery.modify_opcode
    );
    expect_status("QP_RECOVERY_NONE_TICKET", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.ambiguous_ticket = null;
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ] = 1'b1;
    expect_status("QP_RECOVERY_ABSENT_URC_RSQ_PROGRESS",
                  qp_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_RSQ] = 1'b0;
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] = 1'b1;
    expect_status("QP_RECOVERY_ABSENT_URC_RDSQ_PROGRESS",
                  qp_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_RDSQ] = 1'b0;
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ] = 1'b1;
    expect_status("QP_RECOVERY_ABSENT_URC_DSQ_PROGRESS",
                  qp_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_URC_DSQ] = 1'b0;
    saved_qp_rq_ring = qp_recovery.qp_plan.rq_ring;
    saved_qp_rq_ref = qp_recovery.qp_plan.rq_ref;
    saved_qp_rq_pd_ref = qp_recovery.qp_plan.rq_pd_ref;
    qp_recovery.qp_plan.rq_source_h = srq_h;
    qp_recovery.qp_plan.rq_ring = null;
    qp_recovery.qp_plan.rq_ref = null;
    qp_recovery.qp_plan.rq_pd_ref = null;
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_RQ_RING] = 1'b1;
    expect_status("QP_RECOVERY_SRQ_PRIVATE_RQ_PROGRESS",
                  qp_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_RQ_RING] = 1'b0;
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD] = 1'b1;
    expect_status("QP_RECOVERY_SRQ_PRIVATE_RQ_PD_PROGRESS",
                  qp_recovery.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_RQ_PD] = 1'b0;
    qp_recovery.qp_plan.rq_source_h = null;
    qp_recovery.qp_plan.rq_ring = saved_qp_rq_ring;
    qp_recovery.qp_plan.rq_ref = saved_qp_rq_ref;
    qp_recovery.qp_plan.rq_pd_ref = saved_qp_rq_pd_ref;
    qp_recovery.qp_plan.rq_pd_ref.mapping.function_h.function_uid++;
    expect_status("QP_RECOVERY_MIXED_PLAN_FUNCTION", qp_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.qp_plan.rq_pd_ref.mapping.function_h.function_uid--;
    qp_recovery.qp_plan.rq_pd_ref.mapping.owner_h.object_id++;
    expect_status("QP_RECOVERY_MIXED_PLAN_QP", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.qp_plan.rq_pd_ref.mapping.owner_h.object_id--;
    qp_recovery.prior_qpc.qp_h.object_id++;
    expect_status("QP_RECOVERY_PRIOR_QP", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.prior_qpc.qp_h.object_id--;
    qp_recovery.candidate_qpc.qp_h.function_uid++;
    expect_status("QP_RECOVERY_CANDIDATE_FUNCTION", qp_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.candidate_qpc.qp_h.function_uid--;
    qp_recovery.candidate_qpc.qp_h.generation++;
    expect_status("QP_RECOVERY_CANDIDATE_GENERATION", qp_recovery.validate(),
                  RDMA_SC_STALE_GENERATION);
    qp_recovery.candidate_qpc.qp_h.generation--;
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_modify_ticket", function_h, cmq_h, qp_recovery.modify_opcode
    );
    expect_status("QP_RECOVERY_MODIFY_TICKET", qp_recovery.validate(),
                  RDMA_SC_OK);
    qp_recovery.ambiguous_ticket.function_h.function_uid++;
    qp_recovery.ambiguous_ticket.cmq_h.function_uid++;
    expect_status("QP_RECOVERY_TICKET_FUNCTION", qp_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.ambiguous_ticket.function_h.function_uid--;
    qp_recovery.ambiguous_ticket.cmq_h.function_uid--;
    qp_recovery.ambiguous_ticket.opcode_key =
      rdma_cmq_clone_opcode_key_value(qp_recovery.create_opcode,
                                      "wrong recovery ticket opcode");
    expect_status("QP_RECOVERY_TICKET_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_recovery.ambiguous_ticket = null;
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_CREATE;
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_modify_create_ticket", function_h, cmq_h,
      qp_recovery.create_opcode
    );
    expect_status("QP_RECOVERY_MODIFY_CREATE_MATRIX", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_recovery.ambiguous_ticket = null;
    qp_recovery.prior_qpc = null;
    expect_status("QP_RECOVERY_MODIFY_PRIOR", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.prior_qpc = make_rc_qpc("qp_prior_qpc_restored", qp_h, pd_h,
                                        cq_h, cq_h, 128, 128);
    qp_recovery.candidate_qpc = null;
    expect_status("QP_RECOVERY_MODIFY_CANDIDATE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.candidate_qpc = make_rc_qpc(
      "qp_candidate_qpc_restored", qp_h, pd_h, cq_h, cq_h, 128, 128
    );
    qp_recovery.query_mapping = null;
    expect_status("QP_RECOVERY_MODIFY_QUERY", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.query_mapping = make_recovery_mapping(
      "qp_recovery_query_restored", function_h, qp_h, 64'h8200_0000
    );
    qp_recovery.intent = RDMA_QP_RECOVER_NORMAL_DESTROY;
    qp_recovery.prior_qpc = null;
    expect_status("QP_RECOVERY_DESTROY_PRIOR", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.prior_qpc = make_rc_qpc("qp_destroy_prior", qp_h, pd_h,
                                        cq_h, cq_h, 128, 128);
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_CREATE;
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_destroy_create_ticket", function_h, cmq_h,
      qp_recovery.create_opcode
    );
    expect_status("QP_RECOVERY_DESTROY_CREATE_MATRIX", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.intent = RDMA_QP_RECOVER_CREATE_ROLLBACK;
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_MODIFY;
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_create_modify_ticket", function_h, cmq_h,
      qp_recovery.modify_opcode
    );
    // A CREATE rollback may enter the canonical destroy recipe after the
    // CREATE side effect was proven present.  Its state-only QPC_MODIFY to
    // ERROR is therefore a valid ambiguous recovery step, even though a
    // MODIFY_RECONCILE record may only carry AMBIG_MODIFY.
    expect_status("QP_RECOVERY_CREATE_ROLLBACK_MODIFY",
                  qp_recovery.validate(), RDMA_SC_OK);
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_CREATE;
    qp_recovery.candidate_qpc = null;
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_create_ticket", function_h, cmq_h, qp_recovery.create_opcode
    );
    expect_status("QP_RECOVERY_CREATE_CANDIDATE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.candidate_qpc = make_rc_qpc(
      "qp_create_candidate", qp_h, pd_h, cq_h, cq_h, 128, 128
    );
    qp_recovery.staging_mapping = null;
    expect_status("QP_RECOVERY_AMBIG_STAGING", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.staging_mapping = make_recovery_mapping(
      "qp_recovery_staging_restored", function_h, qp_h, 64'h8100_0000
    );
    qp_recovery.ambiguous_ticket = null;
    expect_status("QP_RECOVERY_AMBIG_TICKET", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.ambiguous_ticket = make_recovery_ticket(
      "qp_invalid_ticket", function_h, cmq_h, qp_recovery.create_opcode
    );
    qp_recovery.ambiguous_ticket.command_id = 0;
    expect_status("QP_RECOVERY_TICKET_VALIDATE", qp_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.ambiguous_ticket.command_id = 64'h1234;
    qp_recovery.intent = RDMA_QP_RECOVER_MODIFY_RECONCILE;
    qp_recovery.ambiguous_operation = RDMA_QP_AMBIG_NONE;
    qp_recovery.ambiguous_ticket = null;
    qp_recovery.create_opcode = null;
    expect_status("QP_RECOVERY_CREATE_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.create_opcode = make_recovery_opcode(
      "qp_recovery_create_restored", 32'h10, "qp_create"
    );
    qp_recovery.modify_opcode = null;
    expect_status("QP_RECOVERY_MODIFY_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.modify_opcode = make_recovery_opcode(
      "qp_recovery_modify_restored", 32'h11, "qp_modify"
    );
    qp_recovery.delete_opcode = null;
    expect_status("QP_RECOVERY_DELETE_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.delete_opcode = make_recovery_opcode(
      "qp_recovery_delete_restored", 32'h12, "qp_delete"
    );
    qp_recovery.query_opcode = null;
    expect_status("QP_RECOVERY_QUERY_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.query_opcode = make_recovery_opcode(
      "qp_recovery_query_restored", 32'h13, "qp_query"
    );
    qp_recovery.occ_opcode = null;
    expect_status("QP_RECOVERY_OCC_OPCODE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.occ_opcode = make_recovery_opcode(
      "qp_recovery_occ_restored", 32'h14, "occ_flush"
    );
    qp_recovery.query_opcode.variant = "";
    expect_status("QP_RECOVERY_OPCODE_VALIDATE", qp_recovery.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_recovery.query_opcode.variant = "qp_query";
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_CQ_RING] = 1'b1;
    expect_status("QP_RECOVERY_LEGACY_PROGRESS", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_CQ_RING] = 1'b0;
    qp_recovery.context_ref.local_id++;
    expect_status("QP_RECOVERY_CONTEXT_LOCAL_ID", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.context_ref.local_id--;
    qp_recovery.context_ref.hmc_ref.address.value += 64'h1000;
    expect_status("QP_RECOVERY_CONTEXT_HMC", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.context_ref.hmc_ref.address.value -= 64'h1000;
    if (!$cast(recovery_token, qp_recovery.context_ref.slot_token))
      `uvm_fatal("QP_RECOVERY_SETUP", "QP context token lost contract")
    saved_completion_authority = recovery_token.completion_authority;
    recovery_token.completion_authority =
      rdma_queue_completion_authority::type_id::create(
        "mismatched_completion_authority"
      );
    expect_status("QP_RECOVERY_CONTEXT_COMPLETION", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    recovery_token.completion_authority = saved_completion_authority;
    qp_recovery.query_mapping.state = RDMA_MAPPING_RELEASED;
    expect_status("QP_RECOVERY_PENDING_QUERY", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.query_mapping.state = RDMA_MAPPING_ACTIVE;
    qp_recovery.qp_plan.sq_pd_ref.cleanup_complete = 1'b1;
    qp_recovery.qp_plan.sq_pd_ref.mapping.state = RDMA_MAPPING_RELEASED;
    expect_status("QP_RECOVERY_COMPLETED_RELEASE", qp_recovery.validate(),
                  RDMA_SC_OK);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] = 1'b0;
    expect_status("QP_RECOVERY_PENDING_RELEASE", qp_recovery.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_recovery.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD] = 1'b1;
    qp_recovery.qp_plan.sq_pd_ref.cleanup_complete = 1'b0;
    qp_recovery.qp_plan.sq_pd_ref.mapping.state = RDMA_MAPPING_ACTIVE;
    cloned_object = qp_recovery.clone();
    if (!$cast(qp_recovery_clone, cloned_object) ||
        qp_recovery_clone == qp_recovery ||
        qp_recovery_clone.prior_qpc == qp_recovery.prior_qpc ||
        qp_recovery_clone.candidate_qpc == qp_recovery.candidate_qpc ||
        qp_recovery_clone.qp_plan == qp_recovery.qp_plan ||
        qp_recovery_clone.context_ref == qp_recovery.context_ref ||
        qp_recovery_clone.occ_opcode == qp_recovery.occ_opcode ||
        !qp_recovery_clone.role_complete[RDMA_QUEUE_ROLE_QP_SQ_PD])
      `uvm_error("QP_RECOVERY_COPY",
                 "QP recovery clone lost or aliased authority")
    qp_recovery_record = rdma_recovery_record::type_id::create(
      "qp_recovery_record"
    );
    qp_recovery_record.resource_h = rdma_clone_handle_value(
      qp_h, "QP recovery record resource"
    );
    qp_recovery_record.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
    qp_recovery_record.primary_status = rdma_status::make(
      RDMA_SC_TIMEOUT, "QP recovery record fixture"
    );
    qp_recovery_record.qp_recovery_valid = 1'b1;
    cloned_object = qp_recovery.clone();
    if (!$cast(qp_recovery_record.qp_recovery, cloned_object))
      `uvm_fatal("QP_RECOVERY_RECORD_SETUP",
                 "QP recovery record state clone lost type")
    expect_status("QP_RECOVERY_RECORD", qp_recovery_record.validate(),
                  RDMA_SC_OK);
    qp_recovery_record.resource_h.object_id++;
    expect_status("QP_RECOVERY_RECORD_RESOURCE",
                  qp_recovery_record.validate(), RDMA_SC_INVALID_STATE);
    qp_recovery_record.resource_h.object_id--;

    post_send = rdma_post_send_req::type_id::create("post_send");
    post_send.owner = function_h;
    post_send.request_id = 64'h8877_6655_4433_2211;
    post_send.correlation_id = 64'h0102_0304_0506_0708;
    post_send.timeout_policy = RDMA_TIMEOUT_CYCLES;
    post_send.timeout_value = 64'd12345;
    post_send.expected_status_code = RDMA_SC_QUEUE_FULL;
    post_send.qp_h = qp_h;
    post_send.wr_id = 64'hdead_beef_cafe_1234;
    post_send.opcode = RDMA_WR_SEND;
    sge = rdma_sge::type_id::create("sge");
    sge.iova.value = 64'h2000_4000;
    sge.length = 32'h345;
    sge.lkey = 32'h1234_abcd;
    post_send.sges.push_back(sge);
    post_send.opcode = RDMA_WR_RECV;
    expect_status("POST_SEND_RECV_OPCODE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.opcode = RDMA_WR_RDMA_WRITE;
    expect_status("POST_SEND_REMOTE_FIELDS", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.remote_access_valid = 1'b1;
    post_send.rkey_valid = 1'b1;
    expect_status("POST_SEND_ZERO_REMOTE_FIELDS", post_send.validate(),
                  RDMA_SC_OK);
    post_send.remote_addr.value = 64'h1234_0000;
    post_send.rkey = 32'h1357_2468;
    expect_status("POST_SEND_RDMA_WRITE", post_send.validate(), RDMA_SC_OK);
    post_send.transport = RDMA_TRANSPORT_UD;
    expect_status("POST_SEND_UD_OPCODE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.opcode = RDMA_WR_SEND;
    post_send.destination_qpn = 24'h102030;
    post_send.qkey = 32'h8001_0000;
    post_send.address_vector_id = 32'h5566_7788;
    expect_status("POST_SEND_UD_AV_MISSING", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.address_vector_valid = 1'b1;
    post_send.address_vector_id = '0;
    expect_status("POST_SEND_UD_ZERO_AV_ID", post_send.validate(), RDMA_SC_OK);
    post_send.address_vector_id = 32'h5566_7788;
    expect_status("POST_SEND_UD", post_send.validate(), RDMA_SC_OK);
    post_send.transport = RDMA_TRANSPORT_RC;
    post_send.opcode = RDMA_WR_RDMA_WRITE;
    post_send.compare_value = 64'h0123_4567_89ab_cdef;
    post_send.swap_add_value = 64'hfedc_ba98_7654_3210;
    post_send.payload.push_back(8'ha5);
    post_send.payload.push_back(8'h5a);
    expect_status("POST_SEND", post_send.validate(), RDMA_SC_OK);
    cloned_object = post_send.clone();
    if (!$cast(post_send_clone, cloned_object))
      `uvm_error("REQ_CLONE", "post-send clone lost dynamic type")
    else if (post_send_clone.owner == null ||
             post_send_clone.qp_h == null ||
             post_send_clone.sges.size() != 1)
      `uvm_error("REQ_CLONE", "post-send clone lost nested objects")
    else if (post_send_clone.sges[0] == null)
      `uvm_error("REQ_CLONE", "post-send clone contains a null SGE")
    else if (post_send_clone.owner == post_send.owner ||
             post_send_clone.qp_h == post_send.qp_h ||
             post_send_clone.sges[0] == post_send.sges[0] ||
             post_send_clone.sges[0].iova != post_send.sges[0].iova ||
             post_send_clone.payload != post_send.payload ||
             post_send_clone.request_id != 64'h8877_6655_4433_2211 ||
             post_send_clone.correlation_id != 64'h0102_0304_0506_0708 ||
             post_send_clone.timeout_value != post_send.timeout_value ||
             post_send_clone.timeout_policy != RDMA_TIMEOUT_CYCLES ||
             post_send_clone.expected_status_code != RDMA_SC_QUEUE_FULL ||
             post_send_clone.transport != RDMA_TRANSPORT_RC ||
             post_send_clone.opcode != RDMA_WR_RDMA_WRITE ||
             post_send_clone.remote_addr.value != 64'h1234_0000 ||
             post_send_clone.rkey != 32'h1357_2468 ||
             !post_send_clone.remote_access_valid ||
             !post_send_clone.rkey_valid ||
             post_send_clone.destination_qpn != 24'h102030 ||
             post_send_clone.qkey != 32'h8001_0000 ||
             post_send_clone.address_vector_id != 32'h5566_7788 ||
             !post_send_clone.address_vector_valid ||
             post_send_clone.compare_value != 64'h0123_4567_89ab_cdef ||
             post_send_clone.swap_add_value != 64'hfedc_ba98_7654_3210)
      `uvm_error("REQ_CLONE", "post-send clone lost or aliased fields")
    else begin
      post_send_clone.owner.function_uid++;
      post_send_clone.qp_h.object_id++;
      post_send_clone.sges[0].length++;
      post_send_clone.payload[0] = 8'hff;
      if (post_send.owner.function_uid != 64'h1234_5678_9abc_def0 ||
          post_send.qp_h.object_id != 32'h404 ||
          post_send.sges[0].length != 32'h345 ||
          post_send.payload[0] != 8'ha5)
        `uvm_error("REQ_CLONE", "post-send clone mutation reached source")
    end

    post_send.inline_data = 1'b0;
    post_send.sges.delete();
    expect_status("POST_SEND_EMPTY", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.sges.push_back(sge);
    sge.length = 0;
    expect_status("POST_SEND_ZERO_SGE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sge.length = 32'h345;

    atomic_sge = rdma_sge::type_id::create("atomic_sge");
    atomic_sge.iova.value = 64'h2222_0000;
    atomic_sge.length = 8;
    atomic_sge.lkey = 32'h2222_3333;
    extra_sge = rdma_sge::type_id::create("extra_sge");
    extra_sge.iova.value = 64'h3333_0000;
    extra_sge.length = 8;
    extra_sge.lkey = 32'h3333_4444;
    post_send.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    post_send.inline_data = 1'b1;
    expect_status("POST_SEND_ATOMIC_INLINE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.inline_data = 1'b0;
    post_send.payload.delete();
    post_send.sges.delete();
    post_send.sges.push_back(atomic_sge);
    post_send.remote_addr.value = 64'h4444_0000;
    post_send.rkey = 32'h4444_5555;
    expect_status("POST_SEND_ATOMIC", post_send.validate(), RDMA_SC_OK);
    post_send.sges.push_back(extra_sge);
    expect_status("POST_SEND_ATOMIC_COUNT", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(post_send.sges.pop_back());
    atomic_sge.length = 4;
    expect_status("POST_SEND_ATOMIC_LENGTH", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.length = 8;
    atomic_sge.iova.value = 64'h2222_0004;
    expect_status("POST_SEND_ATOMIC_LOCAL_ALIGN", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.iova.value = 64'h2222_0000;
    post_send.remote_addr.value = 64'h4444_0004;
    expect_status("POST_SEND_ATOMIC_REMOTE_ALIGN", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.remote_addr.value = 64'h4444_0000;
    post_send.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("POST_SEND_FETCH_ADD", post_send.validate(), RDMA_SC_OK);

    post_send.opcode = RDMA_WR_RDMA_READ;
    atomic_sge.length = 64;
    expect_status("POST_SEND_READ", post_send.validate(), RDMA_SC_OK);
    post_send.inline_data = 1'b1;
    post_send.payload.push_back(8'h5c);
    expect_status("POST_SEND_READ_INLINE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.inline_data = 1'b0;
    expect_status("POST_SEND_READ_PAYLOAD", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.payload.delete();

    post_send.opcode = RDMA_WR_LOCAL_INVALIDATE;
    expect_status("POST_SEND_INVALIDATE_SGE", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.sges.delete();
    post_send.payload.delete();
    post_send.rkey_valid = 1'b0;
    post_send.rkey = 0;
    expect_status("POST_SEND_INVALIDATE_RKEY_MISSING", post_send.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    post_send.rkey_valid = 1'b1;
    expect_status("POST_SEND_INVALIDATE_ZERO_RKEY", post_send.validate(),
                  RDMA_SC_OK);

    post_recv = rdma_post_recv_req::type_id::create("post_recv");
    post_recv.target_h = srq_h;
    post_recv.wr_id = 64'h1122;
    recv_sge = rdma_sge::type_id::create("recv_sge");
    recv_sge.iova.value = 64'h3000_0000;
    recv_sge.length = 512;
    recv_sge.lkey = 32'h5566;
    post_recv.sges.push_back(recv_sge);
    post_recv.completion_qp_h = qp_h;
    expect_status("POST_RECV", post_recv.validate(), RDMA_SC_OK);
    post_recv.target_h = null;
    expect_status("POST_RECV_NULL", post_recv.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    function_resource = rdma_function::type_id::create("function_resource");
    pd_resource = rdma_pd::type_id::create("pd_resource");
    mr_resource = rdma_mr::type_id::create("mr_resource");
    cq_resource = rdma_cq::type_id::create("cq_resource");
    qp_resource = rdma_qp::type_id::create("qp_resource");
    srq_resource = rdma_srq::type_id::create("srq_resource");
    ceq_resource = rdma_ceq::type_id::create("ceq_resource");
    aeq_resource = rdma_aeq::type_id::create("aeq_resource");
    cmq_resource = rdma_cmq::type_id::create("cmq_resource");
    if (function_resource == null || pd_resource == null ||
        mr_resource == null || cq_resource == null || srq_resource == null ||
        ceq_resource == null || aeq_resource == null || cmq_resource == null)
      `uvm_error("RESOURCES", "one or more concrete resources are absent")

    function_resource.handle = make_function_handle("function_resource_h");
    function_resource.owner =
      make_function_handle("function_resource_owner_h");
    function_resource.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("FUNCTION_RESOURCE", function_resource.validate(),
                  RDMA_SC_OK);
    function_resource.handle.object_id++;
    expect_status("FUNCTION_RESOURCE_OBJECT_ID", function_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    function_resource.handle.object_id--;
    function_resource.handle.generation++;
    expect_status("FUNCTION_RESOURCE_GENERATION", function_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    function_resource.handle.generation--;

    expect_status("RESOURCE_NEW_IDENTITY_OPTIONAL", pd_resource.validate(),
                  RDMA_SC_OK);
    pd_resource.state = RDMA_RESOURCE_ALLOCATED;
    expect_status("RESOURCE_ALLOCATED_IDENTITY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle = cq_h;
    pd_resource.owner = function_h;
    expect_status("RESOURCE_HANDLE_KIND", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle = pd_h;
    expect_status("RESOURCE_ALLOCATED", pd_resource.validate(), RDMA_SC_OK);
    pd_resource.handle.function_uid++;
    expect_status("RESOURCE_HANDLE_OWNER", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.handle.function_uid--;
    pd_resource.handle.generation++;
    expect_status("RESOURCE_HANDLE_GENERATION", pd_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    pd_resource.handle.generation--;
    pd_resource.dependencies.push_back(null);
    expect_status("RESOURCE_NULL_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.dependencies.delete();
    mismatched_h = make_handle("cross_dependency_h", RDMA_RESOURCE_CQ,
                               32'h908);
    mismatched_h.function_uid++;
    pd_resource.dependencies.push_back(mismatched_h);
    expect_status("RESOURCE_CROSS_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    pd_resource.dependencies.delete();
    mismatched_h = make_handle("stale_dependency_h", RDMA_RESOURCE_CQ,
                               32'h90e);
    mismatched_h.generation++;
    pd_resource.dependencies.push_back(mismatched_h);
    expect_status("RESOURCE_STALE_DEPENDENCY", pd_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    pd_resource.dependencies.delete();
    function_h.kind = RDMA_RESOURCE_PD;
    expect_status("RESOURCE_OWNER_KIND", pd_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    function_h.kind = RDMA_RESOURCE_FUNCTION;

    if (mr_resource.access != '0 || mr_resource.mr_serial != '0)
      `uvm_error("MR_RESOURCE_DEFAULT", "MR access or serial default is nonzero")
    mr_resource.handle = mr_h;
    mr_resource.owner = function_h;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.pd_h = pd_h;
    mr_resource.length = 64'h1000;
    mr_resource.local_mr_id = 24'h12_3456;
    mr_resource.lkey = 32'h1234_56a5;
    mr_resource.rkey = 0;
    mr_resource.access.local_write = 1'b1;
    mr_resource.mr_serial = 12'habc;
    expect_status("MR_RESOURCE", mr_resource.validate(), RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_KEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.local_mr_id++;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    expect_status("MR_RESOURCE_PROGRAMMED_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_INDEX", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.local_mr_id = 32'h0112_3456;
    expect_status("MR_RESOURCE_INDEX_WIDTH", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.local_mr_id = 24'h12_3456;
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.access.remote_read = 1'b1;
    expect_status("MR_RESOURCE_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_REMOTE_RKEY",
                  mr_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_REMOTE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.rkey = mr_resource.lkey;
    expect_status("MR_RESOURCE_REMOTE_RKEY_MATCH", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.access.remote_read = 1'b0;
    mr_resource.access.remote_write = 1'b1;
    mr_resource.rkey = 0;
    expect_status("MR_RESOURCE_REMOTE_WRITE_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.access.remote_write = 1'b0;
    mr_resource.access.remote_atomic = 1'b1;
    expect_status("MR_RESOURCE_REMOTE_ATOMIC_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.access.remote_atomic = 1'b0;
    mr_resource.access.memory_window_bind = 1'b1;
    mr_resource.rkey = 32'hffff_ffff;
    expect_status("MR_RESOURCE_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ACTIVE;
    expect_status("MR_RESOURCE_ACTIVE_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_QUIESCING;
    expect_status("MR_RESOURCE_QUIESCING_LOCAL_RKEY",
                  mr_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_ERROR;
    expect_status("MR_RESOURCE_ERROR_LOCAL_RKEY", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_PROGRAMMED;
    mr_resource.rkey = mr_resource.lkey;
    expect_status("MR_RESOURCE_LOCAL_MATCHING_RKEY", mr_resource.validate(),
                  RDMA_SC_OK);
    mr_resource.rkey = 0;
    expect_status("MR_RESOURCE_LOCAL_ZERO_RKEY", mr_resource.validate(),
                  RDMA_SC_OK);
    cloned_object = mr_resource.clone();
    if (!$cast(mr_resource_clone, cloned_object))
      `uvm_error("MR_RESOURCE_COPY", "MR clone lost dynamic type")
    else if (mr_resource_clone.handle == null ||
             mr_resource_clone.pd_h == null ||
             mr_resource_clone.handle == mr_resource.handle ||
             mr_resource_clone.pd_h == mr_resource.pd_h ||
             mr_resource_clone.access != mr_resource.access ||
             mr_resource_clone.mr_serial != 12'habc ||
             mr_resource_clone.local_mr_id != 24'h12_3456 ||
             mr_resource_clone.lkey != 32'h1234_56a5 ||
             mr_resource_clone.rkey != 0)
      `uvm_error("MR_RESOURCE_COPY", "MR clone lost or aliased state")
    mismatched_h = make_handle("mr_resource_cross_pd_h", RDMA_RESOURCE_PD,
                               32'h909);
    mismatched_h.function_uid++;
    mr_resource.pd_h = mismatched_h;
    expect_status("MR_RESOURCE_PD_OWNER", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.pd_h = cq_h;
    expect_status("MR_RESOURCE_PD_KIND", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.pd_h = pd_h;
    mr_resource.length = 0;
    expect_status("MR_RESOURCE_LENGTH", mr_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mr_resource.state = RDMA_RESOURCE_RELEASED;
    mr_resource.pd_h = null;
    expect_status("MR_RESOURCE_RELEASED", mr_resource.validate(), RDMA_SC_OK);

    cq_resource.handle = cq_h;
    cq_resource.owner = function_h;
    cq_resource.state = RDMA_RESOURCE_ACTIVE;
    cq_resource.local_cq_id = 32'h3131;
    cq_resource.global_cq_id = 32'h9191_3131;
    cq_resource.ceq_h = ceq_h;
    cq_resource.depth = 256;
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_index = 32'h42;
    cq_resource.producer_wrap = 1'b1;
    cq_resource.consumer_wrap = 1'b1;
    cq_resource.queue_iova.value = 64'h4100_0000;
    cq_resource.queue_plan = make_queue_plan(
      "cq_resource_plan", RDMA_RESOURCE_CQ, cq_resource.depth, function_h
    );
    expect_status("CQ_RESOURCE", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.ceq_h = null;
    expect_status("CQ_RESOURCE_CEQ", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    mismatched_h = make_handle("cq_resource_stale_ceq_h", RDMA_RESOURCE_CEQ,
                               32'h90a);
    mismatched_h.generation++;
    cq_resource.ceq_h = mismatched_h;
    expect_status("CQ_RESOURCE_CEQ_GENERATION", cq_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    cq_resource.ceq_h = cq_h;
    expect_status("CQ_RESOURCE_CEQ_KIND", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.state = RDMA_RESOURCE_RELEASED;
    cq_resource.ceq_h = null;
    expect_status("CQ_RESOURCE_RELEASED", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.state = RDMA_RESOURCE_ACTIVE;
    cq_resource.ceq_h = ceq_h;
    cloned_object = cq_resource.clone();
    if (!$cast(cq_resource_clone, cloned_object))
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost dynamic type")
    else if (cq_resource_clone.handle == null ||
             cq_resource_clone.owner == null ||
             cq_resource_clone.ceq_h == null)
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost nested handles")
    else if (cq_resource_clone.handle == cq_resource.handle ||
             cq_resource_clone.owner == cq_resource.owner ||
             cq_resource_clone.ceq_h == cq_resource.ceq_h ||
             cq_resource_clone.state != RDMA_RESOURCE_ACTIVE ||
             cq_resource_clone.local_cq_id != 32'h3131 ||
             cq_resource_clone.global_cq_id != 32'h9191_3131 ||
             cq_resource_clone.depth != 256 ||
             cq_resource_clone.producer_index != 32'h81 ||
             cq_resource_clone.consumer_index != 32'h42 ||
             !cq_resource_clone.producer_wrap ||
             !cq_resource_clone.consumer_wrap ||
             cq_resource_clone.queue_iova.value != 64'h4100_0000)
      `uvm_error("CQ_RESOURCE_CLONE", "CQ clone lost or aliased fields")
    cq_resource.producer_index = 32'h20;
    expect_status("CQ_RESOURCE_SAME_WRAP_ORDER", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_wrap = 1'b0;
    expect_status("CQ_RESOURCE_DIFFERENT_WRAP_ORDER", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h42;
    expect_status("CQ_RESOURCE_FULL_RING", cq_resource.validate(), RDMA_SC_OK);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_wrap = 1'b1;
    cq_resource.depth = 0;
    expect_status("CQ_RESOURCE_ZERO_DEPTH", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.depth = 100;
    expect_status("CQ_RESOURCE_POWER_TWO", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.depth = 256;
    cq_resource.producer_index = 256;
    expect_status("CQ_RESOURCE_PI", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.producer_index = 32'h81;
    cq_resource.consumer_index = 256;
    expect_status("CQ_RESOURCE_CI", cq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cq_resource.consumer_index = 32'h42;

    qp_resource.handle = qp_h;
    qp_resource.owner = function_h;
    qp_resource.state = RDMA_RESOURCE_ACTIVE;
    qp_resource.local_qp_id = 32'h404;
    qp_resource.global_qp_id = 32'h9999_1111;
    qp_resource.transport = RDMA_TRANSPORT_RC;
    qp_resource.qp_state = RDMA_QPS_RTS;
    qp_resource.sq_depth = 1024;
    qp_resource.rq_depth = 512;
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.sq_consumer_index = 32'h42;
    qp_resource.sq_wrap = 1'b1;
    qp_resource.sq_consumer_wrap = 1'b1;
    qp_resource.rq_producer_index = 32'h24;
    qp_resource.rq_consumer_index = 32'h12;
    qp_resource.rq_wrap = 1'b0;
    qp_resource.rq_consumer_wrap = 1'b0;
    qp_resource.sq_iova.value = 64'h4200_0000;
    qp_resource.rq_iova.value = 64'h4300_0000;
    qp_resource.pd_h = pd_h;
    qp_resource.send_cq_h = cq_h;
    qp_resource.recv_cq_h = cq_h;
    qp_resource.dependencies.push_back(pd_h);
    qp_resource.outstanding_ids.push_back(64'hface_0001);
    qp_resource.hmc_fvm_addr_valid = 1'b1;
    qp_resource.hmc_fvm_addr.value = 64'h4444_0000;
    mapping = rdma_dma_mapping::type_id::create("mapping");
    mapping.function_h = function_h;
    mapping.owner_h = qp_h;
    mapping.iova.value = 64'h5000_0000;
    mapping.size = 64'h2000;
    mapping.state = RDMA_MAPPING_ACTIVE;
    backing_ref = rdma_backing_ref::type_id::create("backing_ref");
    backing_ref.mapping = mapping;
    backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    qp_resource.backing_refs.push_back(backing_ref);
    hmc_ref = rdma_hmc_ref::type_id::create("hmc_ref");
    hmc_ref.owner = function_h;
    hmc_ref.object_kind = RDMA_RESOURCE_MR;
    hmc_ref.address.value = 64'h6000_0000;
    hmc_ref.size = 64'h1000;
    hmc_ref.first_pbl_index = 32'h80;
    hmc_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    qp_resource.hmc_refs.push_back(hmc_ref);
    qp_resource.qp_plan = make_qp_plan("qp_resource_plan", 1024, 512,
                                       function_h, qp_h);
    qp_resource.programmed_qpc = make_rc_qpc(
      "qp_resource_qpc", qp_h, pd_h, cq_h, cq_h, 1024, 512
    );
    expect_status("QP_RESOURCE_SPLIT_AUTHORITY", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.backing_refs.delete();
    qp_resource.hmc_refs.delete();
    qp_resource.qp_plan.context_ref.local_id = qp_resource.local_qp_id;
    expect_status("QP_RESOURCE", qp_resource.validate(), RDMA_SC_OK);
    qp_resource.qp_plan.context_ref.local_id++;
    expect_status("QP_RESOURCE_CONTEXT_LOCAL_ID", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.qp_plan.context_ref.local_id--;
    qp_resource.qp_state = RDMA_QPS_INIT;
    qp_resource.programmed_qpc.state = RDMA_QPS_RESET;
    expect_status("QP_RESOURCE_SOFTWARE_INIT", qp_resource.validate(),
                  RDMA_SC_OK);
    qp_resource.qp_state = RDMA_QPS_RTS;
    qp_resource.programmed_qpc.state = RDMA_QPS_RTS;
    qp_resource.programmed_qpc.qp_h.object_id++;
    expect_status("QP_RESOURCE_QPC_LOCAL_ID", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.qp_h.object_id--;
    qp_resource.programmed_qpc.qp_h.function_uid++;
    qp_resource.programmed_qpc.pd_h.function_uid++;
    qp_resource.programmed_qpc.send_cq_h.function_uid++;
    qp_resource.programmed_qpc.recv_cq_h.function_uid++;
    expect_status("QP_RESOURCE_QPC_FUNCTION", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.programmed_qpc.qp_h.function_uid--;
    qp_resource.programmed_qpc.pd_h.function_uid--;
    qp_resource.programmed_qpc.send_cq_h.function_uid--;
    qp_resource.programmed_qpc.recv_cq_h.function_uid--;
    qp_resource.programmed_qpc.qp_h.generation++;
    qp_resource.programmed_qpc.pd_h.generation++;
    qp_resource.programmed_qpc.send_cq_h.generation++;
    qp_resource.programmed_qpc.recv_cq_h.generation++;
    expect_status("QP_RESOURCE_QPC_GENERATION", qp_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    qp_resource.programmed_qpc.qp_h.generation--;
    qp_resource.programmed_qpc.pd_h.generation--;
    qp_resource.programmed_qpc.send_cq_h.generation--;
    qp_resource.programmed_qpc.recv_cq_h.generation--;
    qp_resource.programmed_qpc.sq_depth *= 2;
    expect_status("QP_RESOURCE_QPC_SQ_DEPTH", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.sq_depth /= 2;
    qp_resource.programmed_qpc.rq_depth *= 2;
    expect_status("QP_RESOURCE_QPC_RQ_DEPTH", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.rq_depth /= 2;
    qp_resource.programmed_qpc.sq_mode = RDMA_OBJECT_DIRECT_4K;
    expect_status("QP_RESOURCE_QPC_SQ_MODE", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.sq_mode = RDMA_OBJECT_INDIRECT_4K;
    qp_resource.programmed_qpc.rq_mode = RDMA_OBJECT_DIRECT_4K;
    expect_status("QP_RESOURCE_QPC_RQ_MODE", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.rq_mode = RDMA_OBJECT_INDIRECT_4K;
    qp_resource.programmed_qpc.sq_backing.value += 64'h1000;
    expect_status("QP_RESOURCE_QPC_SQ_BACKING", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.sq_backing.value -= 64'h1000;
    qp_resource.programmed_qpc.rq_backing.value += 64'h1000;
    expect_status("QP_RESOURCE_QPC_RQ_BACKING", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.rq_backing.value -= 64'h1000;
    qp_resource.programmed_qpc.context_backing.value += 64'h200;
    expect_status("QP_RESOURCE_QPC_CONTEXT_BACKING", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.programmed_qpc.context_backing.value -= 64'h200;
    qp_resource.qp_plan.sq_ref.mapping.function_h.function_uid++;
    expect_status("QP_RESOURCE_PLAN_MAPPING_FUNCTION", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.qp_plan.sq_ref.mapping.function_h.function_uid--;
    qp_resource.qp_plan.sq_ref.mapping.owner_h.object_id++;
    expect_status("QP_RESOURCE_PLAN_MAPPING_OWNER", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    qp_resource.qp_plan.sq_ref.mapping.owner_h.object_id--;
    qp_resource.qp_plan.context_ref.owner.function_uid++;
    expect_status("QP_RESOURCE_PLAN_CONTEXT_OWNER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.qp_plan.context_ref.owner.function_uid--;
    qp_resource.qp_plan.context_ref.hmc_ref.owner.function_uid++;
    expect_status("QP_RESOURCE_PLAN_HMC_OWNER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.qp_plan.context_ref.hmc_ref.owner.function_uid--;
    qp_resource.srq_h = srq_h;
    expect_status("QP_RESOURCE_SRQ_PLAN_MISMATCH", qp_resource.validate(),
                  RDMA_SC_INVALID_STATE);
    mismatched_h = make_handle("qp_resource_cross_srq_h", RDMA_RESOURCE_SRQ,
                               32'h90b);
    mismatched_h.function_uid++;
    qp_resource.srq_h = mismatched_h;
    expect_status("QP_RESOURCE_SRQ_OWNER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.srq_h = null;
    mismatched_h = make_handle("qp_resource_stale_cq_h", RDMA_RESOURCE_CQ,
                               32'h90c);
    mismatched_h.generation++;
    qp_resource.recv_cq_h = mismatched_h;
    expect_status("QP_RESOURCE_CQ_GENERATION", qp_resource.validate(),
                  RDMA_SC_STALE_GENERATION);
    qp_resource.recv_cq_h = cq_h;
    cloned_object = qp_resource.clone();
    if (!$cast(qp_resource_clone, cloned_object))
      `uvm_error("RESOURCE_CLONE", "QP clone lost dynamic type")
    else if (qp_resource_clone.handle == null ||
             qp_resource_clone.owner == null ||
             qp_resource_clone.pd_h == null ||
             qp_resource_clone.send_cq_h == null ||
             qp_resource_clone.recv_cq_h == null ||
             qp_resource_clone.qp_plan == null ||
             qp_resource_clone.programmed_qpc == null ||
             qp_resource_clone.backing_refs.size() != 0 ||
             qp_resource_clone.hmc_refs.size() != 0 ||
             qp_resource_clone.dependencies.size() != 1 ||
             qp_resource_clone.outstanding_ids.size() != 1)
      `uvm_error("RESOURCE_CLONE", "QP clone lost nested objects")
    else if (qp_resource_clone.qp_plan.sq_ref == null ||
             qp_resource_clone.qp_plan.sq_ref.mapping == null ||
             qp_resource_clone.programmed_qpc.transport_ext == null ||
             qp_resource_clone.dependencies[0] == null)
      `uvm_error("RESOURCE_CLONE", "QP clone contains a null nested object")
    else if (qp_resource_clone.handle == qp_resource.handle ||
             qp_resource_clone.owner == qp_resource.owner ||
             qp_resource_clone.qp_plan == qp_resource.qp_plan ||
             qp_resource_clone.qp_plan.sq_ref ==
               qp_resource.qp_plan.sq_ref ||
             qp_resource_clone.qp_plan.sq_ref.mapping ==
               qp_resource.qp_plan.sq_ref.mapping ||
             qp_resource_clone.programmed_qpc ==
               qp_resource.programmed_qpc ||
             qp_resource_clone.programmed_qpc.transport_ext ==
               qp_resource.programmed_qpc.transport_ext ||
             qp_resource_clone.dependencies[0] ==
               qp_resource.dependencies[0] ||
             qp_resource_clone.pd_h == qp_resource.pd_h ||
             qp_resource_clone.send_cq_h == qp_resource.send_cq_h ||
             qp_resource_clone.recv_cq_h == qp_resource.recv_cq_h ||
             qp_resource_clone.state != RDMA_RESOURCE_ACTIVE ||
             qp_resource_clone.local_qp_id != 32'h404 ||
             qp_resource_clone.global_qp_id != 32'h9999_1111 ||
             qp_resource_clone.transport != RDMA_TRANSPORT_RC ||
             qp_resource_clone.qp_state != RDMA_QPS_RTS ||
             qp_resource_clone.sq_depth != 1024 ||
             qp_resource_clone.rq_depth != 512 ||
             qp_resource_clone.sq_producer_index != 32'h81 ||
             qp_resource_clone.sq_consumer_index != 32'h42 ||
             !qp_resource_clone.sq_wrap ||
             !qp_resource_clone.sq_consumer_wrap ||
             qp_resource_clone.rq_producer_index != 32'h24 ||
             qp_resource_clone.rq_consumer_index != 32'h12 ||
             qp_resource_clone.rq_wrap ||
             qp_resource_clone.rq_consumer_wrap ||
             qp_resource_clone.sq_iova.value != 64'h4200_0000 ||
             qp_resource_clone.rq_iova.value != 64'h4300_0000 ||
             qp_resource_clone.outstanding_ids[0] != 64'hface_0001)
      `uvm_error("RESOURCE_CLONE", "QP clone lost or aliased state")
    else begin
      qp_resource_clone.handle.object_id++;
      qp_resource_clone.owner.function_uid++;
      qp_resource_clone.qp_plan.sq_ref.mapping.iova.value++;
      rc_ext_clone = null;
      if (!$cast(rc_ext_clone,
                 qp_resource_clone.programmed_qpc.transport_ext))
        `uvm_error("RESOURCE_CLONE", "QP clone lost RC extension type")
      else
        rc_ext_clone.remote_qpn++;
      qp_resource_clone.dependencies[0].object_id++;
      if (qp_resource.handle.object_id != 32'h404 ||
          qp_resource.owner.function_uid != 64'h1234_5678_9abc_def0 ||
          qp_resource.qp_plan.sq_ref.mapping.iova.value !=
            64'h5000_0000 ||
          qp_resource.dependencies[0].object_id != 32'h101)
        `uvm_error("RESOURCE_CLONE", "QP clone mutation reached source")
      qp_resource_clone.qp_plan = null;
      qp_resource_clone.programmed_qpc = null;
      qp_resource_clone.copy(qp_resource);
      if (qp_resource_clone.qp_plan == null ||
          qp_resource_clone.programmed_qpc == null ||
          qp_resource_clone.qp_plan == qp_resource.qp_plan ||
          qp_resource_clone.programmed_qpc == qp_resource.programmed_qpc)
        `uvm_error("RESOURCE_REF_REPLACE",
                   "resource copy retained or aliased prior QP authority")
    end

    qp_resource.sq_producer_index = 32'h20;
    expect_status("QP_RESOURCE_SQ_SAME_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.sq_consumer_wrap = 1'b0;
    expect_status("QP_RESOURCE_SQ_DIFFERENT_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_consumer_wrap = 1'b1;
    qp_resource.rq_producer_index = 32'h08;
    expect_status("QP_RESOURCE_RQ_SAME_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_producer_index = 32'h24;
    qp_resource.rq_wrap = 1'b1;
    expect_status("QP_RESOURCE_RQ_DIFFERENT_WRAP_ORDER", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_wrap = 1'b0;

    qp_resource.pd_h = cq_h;
    expect_status("QP_RESOURCE_PD", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.pd_h = pd_h;
    qp_resource.send_cq_h = qp_h;
    expect_status("QP_RESOURCE_SEND_CQ", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.send_cq_h = cq_h;
    qp_resource.recv_cq_h = null;
    expect_status("QP_RESOURCE_RECV_CQ", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.recv_cq_h = cq_h;

    qp_resource.sq_depth = 0;
    expect_status("QP_RESOURCE_ZERO_DEPTH", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_depth = 1000;
    expect_status("QP_RESOURCE_POWER_TWO", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_depth = 1024;
    qp_resource.sq_producer_index = 1024;
    expect_status("QP_RESOURCE_SQ_PI", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.sq_producer_index = 32'h81;
    qp_resource.rq_consumer_index = 512;
    expect_status("QP_RESOURCE_RQ_CI", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.rq_consumer_index = 32'h12;
    qp_resource.transport = rdma_transport_e'(3'b111);
    expect_status("QP_RESOURCE_TRANSPORT", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.transport = RDMA_TRANSPORT_URC;
    qp_resource.qp_state = rdma_qp_state_e'(4'hf);
    expect_status("QP_RESOURCE_QP_STATE", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.qp_state = RDMA_QPS_RTS;
    qp_resource.state = rdma_resource_state_e'(3'b111);
    expect_status("QP_RESOURCE_STATE", qp_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qp_resource.state = RDMA_RESOURCE_ACTIVE;

    srq_resource.handle = srq_h;
    srq_resource.owner = function_h;
    srq_resource.state = RDMA_RESOURCE_PROGRAMMED;
    srq_resource.depth = 128;
    srq_resource.max_sge = 2;
    srq_resource.limit_threshold = 16;
    srq_resource.pd_h = pd_h;
    srq_resource.queue_plan = make_queue_plan(
      "srq_resource_plan", RDMA_RESOURCE_SRQ, srq_resource.depth,
      function_h
    );
    expect_status("SRQ_RESOURCE", srq_resource.validate(), RDMA_SC_OK);
    mismatched_h = make_handle("srq_resource_cross_pd_h", RDMA_RESOURCE_PD,
                               32'h90d);
    mismatched_h.function_uid++;
    srq_resource.pd_h = mismatched_h;
    expect_status("SRQ_RESOURCE_PD_OWNER", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.pd_h = cq_h;
    expect_status("SRQ_RESOURCE_PD_KIND", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.pd_h = pd_h;
    srq_resource.max_sge = 0;
    expect_status("SRQ_RESOURCE_MAX_SGE", srq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    srq_resource.state = RDMA_RESOURCE_RELEASED;
    srq_resource.pd_h = null;
    expect_status("SRQ_RESOURCE_RELEASED", srq_resource.validate(),
                  RDMA_SC_OK);

    cmq_resource.handle = cmq_h;
    cmq_resource.owner = function_h;
    cmq_resource.state = RDMA_RESOURCE_PROGRAMMED;
    cmq_resource.depth = 64;
    cmq_resource.producer_index = 11;
    cmq_resource.consumer_index = 7;
    cmq_resource.producer_wrap = 1'b1;
    cmq_resource.consumer_wrap = 1'b1;
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_index = 19;
    cmq_resource.completion_wrap = 1'b1;
    cmq_resource.completion_consumer_wrap = 1'b1;
    expect_status("CMQ_RESOURCE", cmq_resource.validate(), RDMA_SC_OK);
    cmq_resource.completion_producer_index = 11;
    expect_status("CMQ_RESOURCE_COMPLETION_SAME_WRAP_ORDER",
                  cmq_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_wrap = 1'b0;
    expect_status("CMQ_RESOURCE_COMPLETION_DIFFERENT_WRAP_ORDER",
                  cmq_resource.validate(), RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_consumer_wrap = 1'b1;
    cmq_resource.completion_producer_index = 64;
    expect_status("CMQ_RESOURCE_COMPLETION_PI", cmq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_producer_index = 23;
    cmq_resource.completion_consumer_index = 64;
    expect_status("CMQ_RESOURCE_COMPLETION_CI", cmq_resource.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_resource.completion_consumer_index = 19;

    iova_type_name = $typename(mr_resource.iova);
    hmc_type_name = $typename(qp_resource.hmc_fvm_addr);
    if (iova_type_name == hmc_type_name ||
        function_resource.binding == null)
      `uvm_error("IDENTITY_TYPES",
                 "identity/address wrapper separation was lost")

    qpc = rdma_qpc_model::type_id::create("qpc");
    qpc.behavior.transport_version = 1;
    qpc.behavior.migration_enable = 1'b1;
    qpc.behavior.\priority = 5;
    qpc.transport = RDMA_TRANSPORT_RC;
    qpc.qp_h = qp_h;
    qpc.pd_h = pd_h;
    qpc.send_cq_h = cq_h;
    qpc.recv_cq_h = cq_h;
    qpc.state = RDMA_QPS_RTS;
    qpc.sq_depth = 1024;
    qpc.rq_depth = 512;
    qpc.sq_backing.value = 64'h6000_0000;
    qpc.rq_backing.value = 64'h6001_0000;
    qpc.context_backing.value = 64'h6002_0000;
    qpc.address_vector.destination_mac = 48'h02_11_22_33_44_55;
    qpc.path_mtu_bytes = 4096;
    rc_ext = rdma_qpc_rc_ext::type_id::create("rc_ext");
    rc_ext.remote_qpn = 24'habc123;
    rc_ext.send_psn = 24'h102030;
    rc_ext.recv_psn = 24'h405060;
    rc_ext.retry_count = 3;
    rc_ext.rnr_retry_count = 5;
    qpc.transport_ext = rc_ext;
    expect_status("QPC_RC", qpc.validate(), RDMA_SC_OK);
    cloned_object = qpc.clone();
    if (!$cast(qpc_clone, cloned_object))
      `uvm_error("QPC_CLONE", "QPC clone lost dynamic type")
    else if (qpc_clone.qp_h == null ||
        qpc_clone.pd_h == null ||
        qpc_clone.send_cq_h == null ||
        qpc_clone.recv_cq_h == null ||
        qpc_clone.behavior == null ||
        qpc_clone.transport_ext == null)
      `uvm_error("QPC_CLONE", "QPC clone lost nested objects")
    else if (qpc_clone.behavior == qpc.behavior ||
        qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.qp_h == qpc.qp_h ||
        qpc_clone.pd_h == qpc.pd_h ||
        qpc_clone.send_cq_h == qpc.send_cq_h ||
        qpc_clone.recv_cq_h == qpc.recv_cq_h ||
        qpc_clone.transport != RDMA_TRANSPORT_RC ||
        qpc_clone.state != RDMA_QPS_RTS ||
        qpc_clone.path_mtu_bytes != 4096 ||
        qpc_clone.sq_depth != 1024 || qpc_clone.rq_depth != 512 ||
        qpc_clone.sq_backing.value != 64'h6000_0000 ||
        qpc_clone.rq_backing.value != 64'h6001_0000 ||
        qpc_clone.context_backing.value != 64'h6002_0000 ||
        qpc_clone.behavior.transport_version != 1 ||
        qpc_clone.behavior.migration_enable != 1'b1 ||
        qpc_clone.behavior.\priority != 5 ||
        qpc_clone.address_vector == qpc.address_vector)
      `uvm_error("QPC_CLONE", "QPC clone lost or aliased common fields")
    else if (!$cast(rc_ext_clone, qpc_clone.transport_ext))
      `uvm_error("QPC_CLONE", "QPC clone lost RC extension type")
    else if (rc_ext_clone.remote_qpn != 24'habc123 ||
        rc_ext_clone.send_psn != 24'h102030 ||
        rc_ext_clone.recv_psn != 24'h405060 ||
        rc_ext_clone.retry_count != 3 ||
        rc_ext_clone.rnr_retry_count != 5)
      `uvm_error("QPC_CLONE", "QPC clone lost nested RC extension")
    else begin
      qpc_clone.behavior.\priority = 6;
      qpc_clone.qp_h.object_id++;
      qpc_clone.sq_depth = 2048;
      qpc_clone.path_mtu_bytes = 2048;
      rc_ext_clone.remote_qpn++;
      if (qpc.behavior.\priority != 5 ||
          qpc.qp_h.object_id != 32'h404 || qpc.sq_depth != 1024 ||
          qpc.path_mtu_bytes != 4096 ||
          rc_ext.remote_qpn != 24'habc123)
        `uvm_error("QPC_CLONE", "QPC clone mutation reached source")
    end

    ud_ext = rdma_qpc_ud_ext::type_id::create("ud_ext");
    ud_ext.qkey = 32'h8001_0000;
    qpc.transport_ext = ud_ext;
    expect_status("QPC_MISMATCH", qpc.validate(), RDMA_SC_INVALID_ARGUMENT);
    qpc.transport = RDMA_TRANSPORT_UD;
    qpc.address_vector = null;
    expect_status("QPC_UD_AV_MISSING", qpc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    qpc.address_vector = rdma_address_vector::type_id::create("qpc_ud_av");
    if (qpc.path_mtu_bytes != 4096)
      `uvm_error("QPC_UD_PATH_MTU",
                 "QPC common path MTU changed during UD transition")
    expect_status("QPC_UD", qpc.validate(), RDMA_SC_OK);
    urc_ext = rdma_qpc_urc_ext::type_id::create("urc_ext");
    urc_ext.remote_qpn = 24'h765432;
    urc_ext.rbsn = 24'h112244;
    urc_ext.dbsn = 24'h223355;
    urc_ext.rpsn = 24'h334466;
    urc_ext.dpsn = 24'h445577;
    urc_ext.queues.rsq_backing.value = 64'h6100_0000;
    urc_ext.queues.rdsq_backing.value = 64'h6200_0000;
    urc_ext.queues.dsq_backing.value = 64'h6300_0000;
    urc_ext.queues.rsq_depth = 64;
    urc_ext.queues.rdsq_depth = 128;
    urc_ext.queues.rdsq_fetch_count = 8;
    urc_ext.queues.dsq_fetch_count = 16;
    urc_ext.queues.rq_sequence_threshold_entries = 128;
    urc_ext.queues.sq_completion_threshold_entries = 256;
    qpc.path_mtu_bytes = 8192;
    qpc.transport = RDMA_TRANSPORT_URC;
    qpc.transport_ext = urc_ext;
    expect_status("QPC_URC", qpc.validate(), RDMA_SC_OK);
    qpc.state = rdma_qp_state_e'(4'hf);
    expect_status("QPC_STATE", qpc.validate(), RDMA_SC_INVALID_ARGUMENT);
    qpc.state = RDMA_QPS_RTS;

    cqc = rdma_cqc_model::type_id::create("cqc");
    cqc.cq_h = cq_h;
    cqc.state = RDMA_CONTEXT_VALID;
    cqc.depth = 256;
    cqc.cqe_size_bytes = 64;
    cqc.page_layout.current_valid = 1'b1;
    cqc.page_layout.current_base.value = 64'h7000_0000;
    expect_status("CQC", cqc.validate(), RDMA_SC_OK);
    cqc.producer.index = cqc.depth;
    expect_status("CQC_PI", cqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqc.producer.index = 0;
    cqc.consumer.index = cqc.depth;
    expect_status("CQC_CI", cqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqc.consumer.index = 0;
    mrt = rdma_mrt_model::type_id::create("mrt");
    mrt.mr_h = mr_h;
    mrt.pd_h = pd_h;
    mrt.state = RDMA_CONTEXT_VALID;
    mrt.iova.value = 64'h8000_0000;
    mrt.length = 64'h1000;
    mrt.lkey = 32'h0002_025a;
    mrt.rkey = 0;
    mrt.access.local_write = 1'b1;
    expect_status("MRT", mrt.validate(), RDMA_SC_OK);
    srqc = rdma_srqc_model::type_id::create("srqc");
    srqc.srq_h = srq_h;
    srqc.pd_h = pd_h;
    srqc.state = RDMA_CONTEXT_VALID;
    srqc.depth = 128;
    srqc.srfq_backing.value = 64'h9000_0000;
    expect_status("SRQC", srqc.validate(), RDMA_SC_OK);
    srqc.producer.index = srqc.depth;
    expect_status("SRQC_PI", srqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    srqc.producer.index = 0;
    ceqc = rdma_ceqc_model::type_id::create("ceqc");
    ceqc.ceq_h = ceq_h;
    ceqc.state = RDMA_CONTEXT_VALID;
    ceqc.depth = 64;
    ceqc.page_layout.current_valid = 1'b1;
    ceqc.page_layout.current_base.value = 64'ha000_0000;
    expect_status("CEQC", ceqc.validate(), RDMA_SC_OK);
    ceqc.producer.index = ceqc.depth;
    expect_status("CEQC_PI", ceqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    ceqc.producer.index = 0;
    ceqc.consumer.index = ceqc.depth;
    expect_status("CEQC_CI", ceqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    ceqc.consumer.index = 0;
    aeqc = rdma_aeqc_model::type_id::create("aeqc");
    aeqc.aeq_h = aeq_h;
    aeqc.state = RDMA_CONTEXT_VALID;
    aeqc.depth = 64;
    aeqc.page_layout.current_valid = 1'b1;
    aeqc.page_layout.current_base.value = 64'hb000_0000;
    expect_status("AEQC", aeqc.validate(), RDMA_SC_OK);
    aeqc.producer.index = aeqc.depth;
    expect_status("AEQC_PI", aeqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    aeqc.producer.index = 0;
    aeqc.consumer.index = aeqc.depth;
    expect_status("AEQC_CI", aeqc.validate(), RDMA_SC_INVALID_ARGUMENT);
    aeqc.consumer.index = 0;
    if (qpc.describe() == "" || cqc.describe() == "")
      `uvm_error("HW_MODEL", "hardware models lack semantic descriptions")

    cmq_create_qp = rdma_cmq_sqe_model::type_id::create("cmq_create_qp");
    cmq_create_qp.opcode = RDMA_CMQ_CREATE_QP;
    cmq_create_qp.command_id = 64'h1111_2222;
    cmq_create_qp.function_h = function_h;
    cmq_create_qp.target_h = qp_h;
    cmq_create_qp.context_model = qpc;
    expect_status("CMQ_CREATE_QP", cmq_create_qp.validate(), RDMA_SC_OK);
    cmq_create_qp.context_model = cqc;
    expect_status("CMQ_CONTEXT_TYPE", cmq_create_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_create_qp.context_model = qpc;
    cmq_create_qp.function_h = null;
    expect_status("CMQ_FUNCTION", cmq_create_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_create_qp.function_h = function_h;
    cmq_modify_qp = rdma_cmq_sqe_model::type_id::create("cmq_modify_qp");
    cmq_modify_qp.opcode = RDMA_CMQ_MODIFY_QP;
    cmq_modify_qp.command_id = 64'h3333_4444;
    cmq_modify_qp.function_h = function_h;
    cmq_modify_qp.target_h = qp_h;
    expect_status("CMQ_MODIFY_CONTEXT", cmq_modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_modify_qp.context_model = qpc;
    expect_status("CMQ_MODIFY_QP", cmq_modify_qp.validate(), RDMA_SC_OK);
    if (cmq_create_qp.opcode == cmq_modify_qp.opcode ||
        cmq_create_qp.command_id == cmq_modify_qp.command_id)
      `uvm_error("CMQ_OPCODES", "CMQ operations are not independent")
    cloned_object = cmq_create_qp.clone();
    if (!$cast(cmq_clone, cloned_object))
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost dynamic type")
    else if (cmq_clone.function_h == null ||
        cmq_clone.target_h == null ||
        cmq_clone.context_model == null)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost nested objects")
    else if (cmq_clone.context_model == cmq_create_qp.context_model ||
        cmq_clone.function_h == cmq_create_qp.function_h ||
        cmq_clone.target_h == cmq_create_qp.target_h ||
        cmq_clone.opcode != RDMA_CMQ_CREATE_QP ||
        cmq_clone.command_id != 64'h1111_2222)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost or aliased fields")
    else if (!$cast(qpc_clone, cmq_clone.context_model))
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost QPC context type")
    else if (qpc_clone.transport_ext == null)
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost its extension")
    else if (qpc_clone.transport_ext == qpc.transport_ext ||
        qpc_clone.transport != RDMA_TRANSPORT_URC ||
        qpc_clone.path_mtu_bytes != 8192 ||
        qpc_clone.sq_depth != 1024)
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost or aliased fields")
    else if (!$cast(urc_ext_clone, qpc_clone.transport_ext))
      `uvm_error("CMQ_CLONE", "CMQ QPC clone lost URC extension type")
    else if (urc_ext_clone.queues == null ||
        urc_ext_clone.queues == urc_ext.queues ||
        urc_ext_clone.remote_qpn != 24'h765432 ||
        urc_ext_clone.rbsn != 24'h112244 ||
        urc_ext_clone.dbsn != 24'h223355 ||
        urc_ext_clone.rpsn != 24'h334466 ||
        urc_ext_clone.dpsn != 24'h445577 ||
        urc_ext_clone.queues.rsq_backing.value != 64'h6100_0000 ||
        urc_ext_clone.queues.rdsq_backing.value != 64'h6200_0000 ||
        urc_ext_clone.queues.dsq_backing.value != 64'h6300_0000 ||
        urc_ext_clone.queues.rsq_depth != 64 ||
        urc_ext_clone.queues.rdsq_depth != 128 ||
        urc_ext_clone.queues.rdsq_fetch_count != 8 ||
        urc_ext_clone.queues.dsq_fetch_count != 16 ||
        urc_ext_clone.queues.rq_sequence_threshold_entries != 128 ||
        urc_ext_clone.queues.sq_completion_threshold_entries != 256)
      `uvm_error("CMQ_CLONE", "CMQ SQE clone lost nested context")
    else begin
      cmq_clone.function_h.function_uid++;
      cmq_clone.target_h.object_id++;
      qpc_clone.sq_depth = 2048;
      urc_ext_clone.remote_qpn++;
      urc_ext_clone.queues.rsq_backing.value += 64'h1000;
      urc_ext_clone.queues.rdsq_fetch_count = 24;
      if (cmq_create_qp.function_h.function_uid !=
            64'h1234_5678_9abc_def0 ||
          cmq_create_qp.target_h.object_id != 32'h404 ||
          qpc.sq_depth != 1024 || urc_ext.remote_qpn != 24'h765432 ||
          urc_ext.queues.rsq_backing.value != 64'h6100_0000 ||
          urc_ext.queues.rdsq_fetch_count != 8)
        `uvm_error("CMQ_CLONE", "CMQ clone mutation reached source")
    end

    cmq_completion =
      rdma_cmq_completion_model::type_id::create("cmq_completion");
    cmq_completion.opcode = RDMA_CMQ_CREATE_QP;
    cmq_completion.command_id = cmq_create_qp.command_id;
    cmq_completion.status = rdma_status::success("created");
    cmq_completion.result_h = qp_h;
    expect_status("CMQ_COMPLETION", cmq_completion.validate(), RDMA_SC_OK);
    cmq_completion.opcode = rdma_cmq_opcode_e'(6'h3f);
    expect_status("CMQ_COMPLETION_OPCODE", cmq_completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    cmq_completion.opcode = RDMA_CMQ_CREATE_QP;

    rc_sqe = rdma_sqe_model::type_id::create("rc_sqe");
    rc_sqe.transport = RDMA_TRANSPORT_RC;
    rc_sqe.opcode = RDMA_WR_ATOMIC_CMP_SWAP;
    rc_sqe.qp_h = qp_h;
    rc_sqe.wr_id = 64'ha1;
    rc_sqe.inline_data = 1'b0;
    atomic_sge.iova.value = 64'h2222_0000;
    atomic_sge.length = 8;
    rc_sqe.sges.push_back(atomic_sge);
    sqe_rc_ext = rdma_sqe_rc_ext::type_id::create("sqe_rc_ext");
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    sqe_rc_ext.rkey = 32'h1234_5678;
    sqe_rc_ext.compare_value = 64'h1111_2222_3333_4444;
    sqe_rc_ext.swap_add_value = 64'haaaa_bbbb_cccc_dddd;
    rc_sqe.transport_ext = sqe_rc_ext;
    expect_status("RC_SQE_REMOTE_PRESENCE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.remote_access_valid = 1'b1;
    sqe_rc_ext.rkey_valid = 1'b1;
    sqe_rc_ext.remote_addr.value = '0;
    sqe_rc_ext.rkey = '0;
    expect_status("RC_SQE_ZERO_REMOTE_FIELDS", rc_sqe.validate(), RDMA_SC_OK);
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    sqe_rc_ext.rkey = 32'h1234_5678;
    expect_status("RC_SQE", rc_sqe.validate(), RDMA_SC_OK);

    cloned_object = rc_sqe.clone();
    if (!$cast(sqe_clone, cloned_object))
      `uvm_error("SQE_CLONE", "SQE clone lost dynamic type")
    else if (sqe_clone.qp_h == null || sqe_clone.transport_ext == null ||
             sqe_clone.sges.size() != 1)
      `uvm_error("SQE_CLONE", "SQE clone lost nested objects")
    else if (sqe_clone.sges[0] == null)
      `uvm_error("SQE_CLONE", "SQE clone contains a null SGE")
    else if (sqe_clone.qp_h == rc_sqe.qp_h ||
             sqe_clone.transport_ext == rc_sqe.transport_ext ||
             sqe_clone.sges[0] == rc_sqe.sges[0] ||
             sqe_clone.transport != RDMA_TRANSPORT_RC ||
             sqe_clone.opcode != RDMA_WR_ATOMIC_CMP_SWAP ||
             sqe_clone.wr_id != 64'ha1 ||
             sqe_clone.sges[0].iova.value != 64'h2222_0000 ||
             sqe_clone.sges[0].length != 8)
      `uvm_error("SQE_CLONE", "SQE clone lost or aliased common fields")
    else if (!$cast(sqe_rc_ext_clone, sqe_clone.transport_ext))
      `uvm_error("SQE_CLONE", "SQE clone lost RC extension type")
    else if (sqe_rc_ext_clone.remote_addr.value != 64'hc000_0000 ||
             sqe_rc_ext_clone.rkey != 32'h1234_5678 ||
             !sqe_rc_ext_clone.remote_access_valid ||
             !sqe_rc_ext_clone.rkey_valid ||
             sqe_rc_ext_clone.compare_value != 64'h1111_2222_3333_4444 ||
             sqe_rc_ext_clone.swap_add_value != 64'haaaa_bbbb_cccc_dddd)
      `uvm_error("SQE_CLONE", "SQE clone lost nested atomic fields")
    else begin
      sqe_clone.qp_h.object_id++;
      sqe_clone.sges[0].length++;
      sqe_rc_ext_clone.compare_value++;
      if (rc_sqe.qp_h.object_id != 32'h404 ||
          rc_sqe.sges[0].length != 8 ||
          sqe_rc_ext.compare_value != 64'h1111_2222_3333_4444)
        `uvm_error("SQE_CLONE", "SQE clone mutation reached source")
    end

    rc_sqe.inline_data = 1'b1;
    rc_sqe.payload.push_back(8'hc3);
    expect_status("RC_SQE_ATOMIC_INLINE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.inline_data = 1'b0;
    rc_sqe.payload.delete();
    rc_sqe.sges.push_back(extra_sge);
    expect_status("RC_SQE_ATOMIC_COUNT", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    void'(rc_sqe.sges.pop_back());
    atomic_sge.length = 4;
    expect_status("RC_SQE_ATOMIC_LENGTH", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.length = 8;
    atomic_sge.iova.value = 64'h2222_0004;
    expect_status("RC_SQE_ATOMIC_LOCAL_ALIGN", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    atomic_sge.iova.value = 64'h2222_0000;
    sqe_rc_ext.remote_addr.value = 64'hc000_0004;
    expect_status("RC_SQE_ATOMIC_REMOTE_ALIGN", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.remote_addr.value = 64'hc000_0000;
    rc_sqe.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("RC_SQE_FETCH_ADD", rc_sqe.validate(), RDMA_SC_OK);

    rc_sqe.opcode = RDMA_WR_RDMA_READ;
    atomic_sge.length = 64;
    expect_status("RC_SQE_READ", rc_sqe.validate(), RDMA_SC_OK);
    rc_sqe.inline_data = 1'b1;
    rc_sqe.payload.push_back(8'hc4);
    expect_status("RC_SQE_READ_INLINE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.inline_data = 1'b0;
    expect_status("RC_SQE_READ_PAYLOAD", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.payload.delete();

    ud_sqe = rdma_sqe_model::type_id::create("ud_sqe");
    ud_sqe.transport = RDMA_TRANSPORT_UD;
    ud_sqe.opcode = RDMA_WR_SEND_WITH_IMM;
    ud_sqe.qp_h = qp_h;
    ud_sqe.wr_id = 64'hb2;
    ud_sqe.inline_data = 1'b1;
    ud_sqe.payload.push_back(8'hd4);
    sqe_ud_ext = rdma_sqe_ud_ext::type_id::create("sqe_ud_ext");
    sqe_ud_ext.destination_qpn = 24'h010203;
    sqe_ud_ext.qkey = 32'h1111_2222;
    sqe_ud_ext.address_vector_id = 32'h89ab_cdef;
    // UD 数据面不仅携带 AV 标识，还必须绑定可校验的地址向量内容；先保持 valid=0 验证缺失标志，再复用该 fixture 验证有效路径。
    sqe_ud_ext.address_vector = rdma_address_vector::type_id::create("sqe_ud_av");
    sqe_ud_ext.address_vector.destination_mac = 48'h02_11_22_33_44_55;
    ud_sqe.transport_ext = sqe_ud_ext;
    expect_status("UD_SQE_AV_MISSING", ud_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_ud_ext.address_vector_valid = 1'b1;
    sqe_ud_ext.address_vector_id = '0;
    expect_status("UD_SQE_ZERO_AV_ID", ud_sqe.validate(), RDMA_SC_OK);
    sqe_ud_ext.address_vector_id = 32'h89ab_cdef;
    expect_status("UD_SQE", ud_sqe.validate(), RDMA_SC_OK);
    if (rc_sqe.transport == ud_sqe.transport ||
        rc_sqe.opcode == ud_sqe.opcode)
      `uvm_error("SQE_VARIANTS", "SQE variants are not independent")
    cloned_object = ud_sqe.clone();
    if (!$cast(ud_sqe_clone, cloned_object))
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost dynamic type")
    else if (ud_sqe_clone.qp_h == null ||
             ud_sqe_clone.transport_ext == null ||
             ud_sqe_clone.payload.size() != 1)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost nested objects")
    else if (ud_sqe_clone.qp_h == ud_sqe.qp_h ||
             ud_sqe_clone.transport_ext == ud_sqe.transport_ext ||
             ud_sqe_clone.payload != ud_sqe.payload)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost or aliased fields")
    else if (!$cast(sqe_ud_ext_clone, ud_sqe_clone.transport_ext))
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost UD extension type")
    else if (sqe_ud_ext_clone.destination_qpn != 24'h010203 ||
             sqe_ud_ext_clone.qkey != 32'h1111_2222 ||
             sqe_ud_ext_clone.address_vector_id != 32'h89ab_cdef ||
             !sqe_ud_ext_clone.address_vector_valid)
      `uvm_error("UD_SQE_CLONE", "UD SQE clone lost fields")
    else begin
      ud_sqe_clone.qp_h.object_id++;
      ud_sqe_clone.payload[0] = 8'h00;
      sqe_ud_ext_clone.address_vector_id++;
      if (ud_sqe.qp_h.object_id != 32'h404 ||
          ud_sqe.payload[0] != 8'hd4 ||
          sqe_ud_ext.address_vector_id != 32'h89ab_cdef)
        `uvm_error("UD_SQE_CLONE", "UD SQE clone mutation reached source")
    end

    rc_sqe.opcode = RDMA_WR_RECV;
    expect_status("RC_SQE_RECV_OPCODE", rc_sqe.validate(),
                  RDMA_SC_UNSUPPORTED_OPCODE);
    rc_sqe.opcode = RDMA_WR_LOCAL_INVALIDATE;
    rc_sqe.inline_data = 1'b0;
    rc_sqe.payload.delete();
    rc_sqe.sges.delete();
    sqe_rc_ext.rkey_valid = 1'b0;
    sqe_rc_ext.rkey = 0;
    expect_status("RC_SQE_INVALIDATE_RKEY_MISSING", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_rc_ext.rkey_valid = 1'b1;
    expect_status("RC_SQE_INVALIDATE_ZERO_RKEY", rc_sqe.validate(),
                  RDMA_SC_OK);
    rc_sqe.sges.push_back(sge);
    expect_status("RC_SQE_INVALIDATE_SGE", rc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    rc_sqe.sges.delete();

    urc_sqe = rdma_sqe_model::type_id::create("urc_sqe");
    urc_sqe.transport = RDMA_TRANSPORT_URC;
    urc_sqe.opcode = RDMA_WR_RDMA_WRITE;
    urc_sqe.qp_h = qp_h;
    urc_sqe.wr_id = 64'hc4;
    urc_sqe.inline_data = 1'b0;
    urc_sqe.sges.push_back(sge);
    sqe_urc_ext = rdma_sqe_urc_ext::type_id::create("sqe_urc_ext");
    sqe_urc_ext.destination_qpn = 24'h506070;
    urc_sqe.transport_ext = sqe_urc_ext;
    expect_status("URC_SQE_REMOTE_PRESENCE", urc_sqe.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    sqe_urc_ext.remote_access_valid = 1'b1;
    sqe_urc_ext.rkey_valid = 1'b1;
    expect_status("URC_SQE_ZERO_REMOTE_FIELDS", urc_sqe.validate(), RDMA_SC_OK);
    cloned_object = urc_sqe.clone();
    if (!$cast(urc_sqe_clone, cloned_object))
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost dynamic type")
    else if (urc_sqe_clone.transport_ext == null)
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost its extension")
    else if (!$cast(sqe_urc_ext_clone, urc_sqe_clone.transport_ext))
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost extension type")
    else if (sqe_urc_ext_clone.remote_addr.value != 0 ||
             sqe_urc_ext_clone.rkey != 0 ||
             !sqe_urc_ext_clone.remote_access_valid ||
             !sqe_urc_ext_clone.rkey_valid)
      `uvm_error("URC_SQE_CLONE", "URC SQE clone lost presence fields")
    urc_sqe.opcode = RDMA_WR_ATOMIC_FETCH_ADD;
    expect_status("URC_SQE_ATOMIC_OPCODE", urc_sqe.validate(),
                  RDMA_SC_UNSUPPORTED_OPCODE);

    cmq_modify_qp.opcode = RDMA_CMQ_QUERY;
    cmq_modify_qp.context_model = null;
    cmq_modify_qp.target_h = null;
    expect_status("CMQ_QUERY_TARGET", cmq_modify_qp.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    rqe = rdma_rqe_model::type_id::create("rqe");
    rqe.target_h = qp_h;
    rqe.wr_id = 64'hc3;
    rqe.sges.push_back(recv_sge);
    expect_status("RQE", rqe.validate(), RDMA_SC_OK);
    cqe = rdma_cqe_model::type_id::create("cqe");
    cqe.qp_h = qp_h;
    cqe.wr_id = 64'hd4;
    cqe.opcode = RDMA_WR_RECV;
    cqe.status = rdma_status::success();
    expect_status("CQE", cqe.validate(), RDMA_SC_OK);
    cqe.opcode = rdma_work_opcode_e'(5'h1f);
    expect_status("CQE_OPCODE", cqe.validate(), RDMA_SC_INVALID_ARGUMENT);
    cqe.opcode = RDMA_WR_RECV;
    ceqe = rdma_ceqe_model::type_id::create("ceqe");
    ceqe.cq_h = cq_h;
    ceqe.producer_index = 32'h55;
    expect_status("CEQE", ceqe.validate(), RDMA_SC_OK);
    aeqe = rdma_aeqe_model::type_id::create("aeqe");
    aeqe.target_h = qp_h;
    aeqe.event_code = 32'h66;
    expect_status("AEQE", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_WARNING;
    expect_status("AEQE_SEVERITY_WARNING", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_ERROR;
    expect_status("AEQE_SEVERITY_ERROR", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_FATAL;
    expect_status("AEQE_SEVERITY_FATAL", aeqe.validate(), RDMA_SC_OK);
    aeqe.severity = RDMA_SEVERITY_INFO;
    doorbell = rdma_doorbell_model::type_id::create("doorbell");
    doorbell.kind = RDMA_DOORBELL_SQ;
    doorbell.target_h = qp_h;
    doorbell.producer_index = 32'h77;
    doorbell.wrap = 1'b1;
    expect_status("DOORBELL_SQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_SQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_RQ;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_RQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = srq_h;
    expect_status("DOORBELL_RQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_QP_FLUSH;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_QP_FLUSH", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_QP_FLUSH_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_SRQ;
    doorbell.target_h = srq_h;
    expect_status("DOORBELL_SRQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_SRQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CQ;
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_CQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_CQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CEQ;
    doorbell.target_h = ceq_h;
    expect_status("DOORBELL_CEQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = cq_h;
    expect_status("DOORBELL_CEQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_AEQ;
    doorbell.target_h = aeq_h;
    expect_status("DOORBELL_AEQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = ceq_h;
    expect_status("DOORBELL_AEQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_CMQ_SQ;
    doorbell.target_h = cmq_h;
    expect_status("DOORBELL_CMQ", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_CMQ_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_RTS2SQD;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_RTS2SQD", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = function_h;
    expect_status("DOORBELL_RTS2SQD_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_SQD2RTS;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_SQD2RTS", doorbell.validate(), RDMA_SC_OK);
    doorbell.target_h = function_h;
    expect_status("DOORBELL_SQD2RTS_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    doorbell.kind = RDMA_DOORBELL_TX_FLUSH;
    doorbell.target_h = qp_h;
    expect_status("DOORBELL_TX_FLUSH", doorbell.validate(), RDMA_SC_OK);
    cloned_object = doorbell.clone();
    if (!$cast(doorbell_clone, cloned_object))
      `uvm_error("DOORBELL_TX_CLONE", "doorbell clone lost dynamic type")
    else if (doorbell_clone.target_h == null ||
             doorbell_clone.target_h == doorbell.target_h ||
             doorbell_clone.target_h.kind != RDMA_RESOURCE_QP)
      `uvm_error("DOORBELL_TX_CLONE", "doorbell clone lost TX identity")
    doorbell.target_h = function_h;
    expect_status("DOORBELL_TX_TARGET", doorbell.validate(),
                  RDMA_SC_INVALID_ARGUMENT);

    packet = rdma_packet::type_id::create("packet");
    packet.transport = RDMA_TRANSPORT_URC;
    packet.opcode = RDMA_NET_RDMA_WRITE;
    packet.destination_qpn = 24'h112233;
    packet.source_qpn = 24'h445566;
    packet.psn = 24'h778899;
    packet.header_bytes.push_back(8'hde);
    packet.header_bytes.push_back(8'had);
    packet.metadata.push_back("flow=primary");
    packet.payload.push_back(8'hbe);
    packet.payload.push_back(8'hef);
    cloned_object = packet.clone();
    if (!$cast(packet_clone, cloned_object) ||
        packet_clone.transport != RDMA_TRANSPORT_URC ||
        packet_clone.opcode != RDMA_NET_RDMA_WRITE ||
        packet_clone.destination_qpn != 24'h112233 ||
        packet_clone.header_bytes != packet.header_bytes ||
        packet_clone.metadata != packet.metadata ||
        packet_clone.payload != packet.payload)
      `uvm_error("PACKET_CLONE", "packet clone lost semantic fields")
    else begin
      packet_clone.header_bytes[0] = 8'h00;
      packet_clone.metadata[0] = "changed";
      if (packet.header_bytes[0] != 8'hde ||
          packet.metadata[0] != "flow=primary")
        `uvm_error("PACKET_CLONE", "packet clone mutation reached source")
    end

    policy = rdma_net_response_policy::type_id::create("policy");
    policy.responder_mode = RDMA_RESPONDER_VIP;
    policy.drop_every_n = 17;
    policy.corrupt_every_n = 19;
    policy.delay_cycles = 23;
    policy.deterministic_seed = 32'h1357_9bdf;
    cloned_object = policy.clone();
    if (!$cast(policy_clone, cloned_object) ||
        policy_clone.responder_mode != RDMA_RESPONDER_VIP ||
        policy_clone.drop_every_n != 17 ||
        policy_clone.corrupt_every_n != 19 ||
        policy_clone.delay_cycles != 23 ||
        policy_clone.deterministic_seed != 32'h1357_9bdf)
      `uvm_error("POLICY_CLONE", "response policy lost deterministic fields")

    fault = rdma_net_fault::type_id::create("fault");
    fault.kind = RDMA_FAULT_PACKET_DROP;
    fault.drop_packet = 1'b1;
    fault.corrupt_byte = 1'b1;
    fault.corrupt_byte_index = 13;
    fault.corrupt_xor_mask = 8'h81;
    fault.delay_cycles = 29;
    fault.deterministic_seed = 32'h2468_ace0;
    cloned_object = fault.clone();
    if (!$cast(fault_clone, cloned_object) ||
        fault_clone.kind != RDMA_FAULT_PACKET_DROP ||
        !fault_clone.drop_packet || !fault_clone.corrupt_byte ||
        fault_clone.corrupt_byte_index != 13 ||
        fault_clone.corrupt_xor_mask != 8'h81 ||
        fault_clone.delay_cycles != 29 ||
        fault_clone.deterministic_seed != 32'h2468_ace0)
      `uvm_error("FAULT_CLONE", "network fault lost deterministic fields")

    phase.drop_objection(this);
  endtask
endclass
