// 目录：测试层 tests/unit/rdma_cmq_engine_models_test.sv。
// 职责：验证共享提交证据顺序，以及 CMQ model 的 validation 与 detached clone 契约。
// 依赖：依赖 rdma_model_pkg 导出的真实 helper/model 和 UVM test/object/report 基础设施。
// 所有权与生命周期：测试创建并持有本地 fixture 引用；UVM 在测试结束后统一回收对象。

// 设计说明：该故障 fixture 专门让 validate() 返回 null，以覆盖 command 对异常 model 的拒绝路径。
class rdma_cmq_null_status_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_null_status_body)

  // 功能：构造一个 validate() 恒返 null 的 CMQ 测试 body，并初始化 UVM object 名称。
  // 输入/输出及副作用：name 传给 rdma_hw_model::new；不创建外部资源，也不设置业务字段。
  // 失败/边界：允许空名称；构造过程不校验后续 command，故障只在 validate() 调用时可见。
  function new(string name = "rdma_cmq_null_status_body");
    super.new(name);
  endfunction

  // 功能：注入非法的 null validation status，验证 command model 能拒绝异常 body 实现。
  // 输入/输出及副作用：无输入；恒定返回 null，不读取或修改对象字段，也不发布其他诊断。
  // 失败/边界：此返回值故意违反正常 rdma_hw_model 契约，仅供本单测的 INVALID_STATE 分支使用。
  virtual function rdma_status validate();
    return null;
  endfunction

  // 功能：为 null-status 故障 body 返回稳定描述，供被测模型的诊断路径识别 fixture 意图。
  // 输入/输出及副作用：无输入；返回固定 string，不读取或修改对象状态。
  // 失败/边界：不根据配置或 validation 结果变化；即使 validate() 返回 null 仍可安全调用。
  virtual function string describe();
    return "CMQ test body returning null validation status";
  endfunction
endclass

// 设计说明：错误类型载体只用于 raw factory 故障注入；它没有 RDMA 字段，
// 因而无法意外满足 status、ticket、image 或 completion 的值契约。
class rdma_cmq_value_wrong_factory_object extends uvm_object;
  `uvm_object_utils(rdma_cmq_value_wrong_factory_object)

  // 功能：构造不可转换为任一 CMQ 值类型的 UVM 测试对象。
  // 输入/输出及副作用：name 仅传给 uvm_object；不创建或登记 RDMA 资源。
  // 失败/边界：对象允许正常构造，但任何被测 RDMA typed cast 都必须失败。
  function new(string name = "rdma_cmq_value_wrong_factory_object");
    super.new(name);
  endfunction
endclass

// 设计说明：被测 nonfatal snapshot context 必须完全绕开 raw factory。
// wrapper 在 arm 窗口记录调用并返回 null/错误类型，disarm 后委托原 registry。
class rdma_cmq_value_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;
  protected bit wrong_type_state;
  protected int unsigned raw_create_calls;

  // 功能：保存原 factory wrapper，并以未注入、零调用计数状态启动。
  // 输入/输出及副作用：name 和 delegate_value 为输入；保存 delegate 非拥有引用。
  // 失败/边界：delegate_value 为空时，disarm 状态的 create_object 仍返回 null。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
    raw_create_calls = 0;
  endfunction

  // 功能：在故障窗口记录 raw create，并按模式返回 null 或不兼容对象。
  // 输入/输出及副作用：name 传给 delegate/错误对象；armed 时递增调用计数。
  // 失败/边界：disarm 时仅委托原 wrapper；原 wrapper 缺失则保守返回 null。
  virtual function uvm_object create_object(string name = "");
    rdma_cmq_value_wrong_factory_object wrong_object;

    if (!armed_state) begin
      if (delegate == null)
        return null;

      return delegate.create_object(name);
    end

    raw_create_calls++;
    if (!wrong_type_state)
      return null;

    wrong_object = new(name);
    return wrong_object;
  endfunction

  // 功能：返回 wrapper 的稳定测试类型名，供 UVM factory 显示 override。
  // 输入/输出及副作用：无输入；只读 wrapper_type_name，不修改 factory。
  // 失败/边界：名称不参与任何 RDMA authority 或值比较。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：开启 null/错误类型故障窗口并清零本窗口的 raw 调用计数。
  // 输入/输出及副作用：wrong_type 选择错误对象或 null；更新本 wrapper 状态。
  // 失败/边界：重复 arm 会开始新窗口，不改变 delegate 或全局 override。
  function void arm(bit wrong_type);
    armed_state = 1'b1;
    wrong_type_state = wrong_type;
    raw_create_calls = 0;
  endfunction

  // 功能：关闭故障窗口，使后续 factory create 恢复委托原 registry。
  // 输入/输出及副作用：无输入输出；只清除 armed/wrong-type 状态。
  // 失败/边界：disarm 幂等，且不会删除已安装的全局 type override。
  function void disarm();
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction

  // 功能：读取当前故障窗口内 raw create_object 的调用次数。
  // 输入/输出及副作用：无输入；返回 raw_create_calls，不修改 wrapper。
  // 失败/边界：未 arm 或窗口内无调用时返回零；计数不代表业务成功。
  function int unsigned call_count();
    return raw_create_calls;
  endfunction
endclass

// 设计说明：测试集中覆盖共享纯值 helper 和既有 CMQ value model，避免引入 mock 或外部 I/O。
class rdma_cmq_engine_models_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_models_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  protected rdma_cmq_value_factory_fault_wrapper status_fault;
  protected rdma_cmq_value_factory_fault_wrapper ticket_fault;
  protected rdma_cmq_value_factory_fault_wrapper image_fault;
  protected rdma_cmq_value_factory_fault_wrapper completion_fault;

  // 功能：构造 CMQ model 单元测试组件，并通过 UVM 基类建立名称和父子层级。
  // 输入/输出及副作用：name 和 parent 传给 uvm_test::new；fixture 延迟到 run_phase 创建。
  // 失败/边界：parent 可为 null 以作为顶层 test；构造阶段不执行断言、仿真事务或资源分配。
  function new(string name = "rdma_cmq_engine_models_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：比较 model 返回的 status code 与手工期望，并用 check_name 标识失败分支。
  // 输入/输出及副作用：读取 check_name、status 和 expected_code；不匹配时发布 UVM error。
  // 失败/边界：status 为 null 时报告错误并立即返回；匹配时无输出且不修改 status。
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

  // 功能：创建带固定 function_uid、object_id 和 generation 的 Function handle fixture。
  // 输入/输出及副作用：name 用作 UVM object 名称；返回新 handle，由测试局部引用持有。
  // 失败/边界：不校验 name；假定已注册 factory 返回非空对象，不建立 topology 或外部绑定。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  // 功能：按 Function fixture 的 uid/generation 创建固定 object_id 的 CMQ handle。
  // 输入/输出及副作用：读取 name 和 function_h；返回新 handle，不修改输入 Function handle。
  // 失败/边界：function_h 必须非空；helper 不做空值防护，也不建立真实 CMQ 资源。
  function automatic rdma_handle make_cmq(
    string name,
    rdma_function_handle function_h
  );
    rdma_handle cmq_h;

    cmq_h = rdma_handle::type_id::create(name);
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    cmq_h.function_uid = function_h.function_uid;
    cmq_h.object_id = 32'h55;
    cmq_h.generation = function_h.generation;
    return cmq_h;
  endfunction

  // 功能：创建 generic_profile/query 对应固定 opcode 的 CMQ opcode key fixture。
  // 输入/输出及副作用：name 用作 UVM object 名称；返回新 key，不修改其他 fixture。
  // 失败/边界：不校验 name；固定字段本身有效，错误分支由调用方后续 mutation 构造。
  function automatic rdma_cmq_opcode_key make_key(string name);
    rdma_cmq_opcode_key key;

    key = rdma_cmq_opcode_key::type_id::create(name);
    key.profile_name = "generic_profile";
    key.opcode = 32'hff00_abcd;
    key.variant = "query";
    return key;
  endfunction

  // 功能：创建 QUERY SQE body fixture，并关联固定 command_id、Function 和 target handle。
  // 输入/输出及副作用：读取 name、function_h、target_h；返回新 body，保存输入对象引用但不修改它们。
  // 失败/边界：允许保存 null handle 供后续 validation 拒绝；helper 本身不验证 handle 世代或 kind。
  function automatic rdma_cmq_sqe_model make_body(
    string name,
    rdma_function_handle function_h,
    rdma_handle target_h
  );
    rdma_cmq_sqe_model body;

    body = rdma_cmq_sqe_model::type_id::create(name);
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = 64'h111;
    body.function_h = function_h;
    body.target_h = target_h;
    return body;
  endfunction

  // 功能：创建由 8'h5a 填充的硬件 image fixture，并设置长度、对齐、端序、kind 和 generation。
  // 输入/输出及副作用：读取 name、image_kind、byte_count、generation；返回新 image 和独立 bytes。
  // 失败/边界：byte_count 为零时返回空 bytes；不验证 kind/长度组合，错误 metadata 由 validate 拒绝。
  function automatic rdma_hw_image make_image(
    string name,
    rdma_image_kind_e image_kind,
    int unsigned byte_count,
    int unsigned generation
  );
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create(name);
    repeat (byte_count)
      image.bytes.push_back(8'h5a);
    image.length = byte_count;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = 1;
    image.function_generation = generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：创建固定 command/slot/deadline 的 CMQ ticket fixture，并关联 Function、CMQ 和 opcode key。
  // 输入/输出及副作用：读取 name 及三个对象引用；返回新 ticket，不克隆或修改输入对象。
  // 失败/边界：允许保存 null 引用供 ticket.validate() 拒绝；helper 不检查世代、slot 或 deadline。
  function automatic rdma_cmq_ticket make_ticket(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    rdma_cmq_opcode_key opcode_key
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234_0005;
    ticket.function_h = function_h;
    ticket.cmq_h = cmq_h;
    ticket.slot_sequence = 64'd37;
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b1;
    ticket.opcode_key = opcode_key;
    ticket.absolute_deadline = 64'd1000;
    return ticket;
  endfunction

  // 功能：创建与 TEST Function handle 完全一致、带显式 Host/root/BDF 的身份快照。
  // 输入/输出及副作用：name 用作对象名；返回测试持有的新 identity，不修改全局 topology。
  // 失败/边界：固定 fixture 应通过 validate；若 factory 返回空，调用测试会报告失败。
  function automatic rdma_function_identity make_identity(string name);
    rdma_function_identity identity;
    rdma_function_key_t function_key;
    rdma_status status;

    function_key = '{
      root_id:16'h44,
      host_topology_key:32'h5566_7788,
      function_kind:RDMA_FUNCTION_VF,
      parent_pf_bdf:'{
        segment:16'h1,
        bus:8'h20,
        device:5'h3,
        function_num:3'h0
      },
      vf_index:16'h2,
      bdf:'{
        segment:16'h1,
        bus:8'h21,
        device:5'h4,
        function_num:3'h1
      }
    };
    identity = rdma_function_identity::type_id::create(name);
    status = identity.configure(
      function_key,
      32'h1234,
      TEST_FUNCTION_UID,
      TEST_GENERATION,
      64'h0102_0304_0506_0708
    );
    if (status == null || !status.ok())
      `uvm_error("IDENTITY_FIXTURE", "failed to configure identity fixture")

    return identity;
  endfunction

  // 功能：创建指定 resource kind/object ID、归属测试 Function incarnation 的句柄。
  // 输入/输出及副作用：name、kind、object_id 为输入；返回新 handle，不登记真实资源。
  // 失败/边界：允许调用方传入不受 owner workflow 支持的 kind，以构造拒绝用例。
  function automatic rdma_handle make_resource_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = TEST_FUNCTION_UID;
    handle.object_id = object_id;
    handle.generation = TEST_GENERATION;
    return handle;
  endfunction

  // 功能：创建尚未冻结的具体 recovery owner，显式绑定 workflow/kind/action。
  // 输入/输出及副作用：name、workflow、kind、action 为输入；返回新 owner 与资源句柄。
  // 失败/边界：helper 不修正非法组合；INVALID/spare action 仅供被测 validator 拒绝。
  function automatic rdma_cmq_recovery_owner make_owner(
    string name,
    rdma_cmq_recovery_workflow_e workflow,
    rdma_resource_kind_e kind,
    rdma_cmq_submission_recovery_action_e action
  );
    rdma_cmq_recovery_owner owner;

    owner = rdma_cmq_recovery_owner::type_id::create(name);
    owner.workflow = workflow;
    owner.resource_h = make_resource_handle(
      {name, "_resource"}, kind, 32'h7788
    );
    owner.transaction_id = 64'h1111_2222_3333_4444;
    owner.allowed_actions = '0;
    owner.allowed_actions[action] = 1'b1;
    return owner;
  endfunction

  // 功能：创建完整 DMA request context，覆盖 Function、route、epoch、owner 与 queue role。
  // 输入/输出及副作用：name、identity 为输入；返回新 context，嵌套 handle 由 fixture 持有。
  // 失败/边界：identity 必须是有效 TEST incarnation；helper 不连接真实 IOMMU。
  function automatic rdma_dma_request_context make_dma_context(
    string name,
    rdma_function_identity identity
  );
    rdma_dma_request_context dma_context;

    dma_context = rdma_dma_request_context::type_id::create(name);
    dma_context.function_h = make_function({name, "_function"});
    dma_context.requester_bdf = identity.key.bdf;
    dma_context.pasid_valid = 1'b1;
    dma_context.pasid = 20'habcde;
    dma_context.dma_domain_valid = 1'b1;
    dma_context.dma_domain_id = 32'h1234_5678;
    dma_context.route = identity.route_key();
    dma_context.reset_epoch = identity.reset_epoch;
    dma_context.route_valid = 1'b1;
    dma_context.epoch_valid = 1'b1;
    dma_context.owner_h = make_resource_handle(
      {name, "_owner"}, RDMA_RESOURCE_MR, 32'h99
    );
    dma_context.queue_role_valid = 1'b1;
    dma_context.queue_role = 32'ha5a5_5a5a;
    return dma_context;
  endfunction

  // 功能：创建完整 public DMA mapping，供 authority digest 的 V1 字段覆盖。
  // 输入/输出及副作用：name、identity 为输入；返回 ACTIVE mapping，不分配真实 backing。
  // 失败/边界：opaque allocation authority 不由此 helper 伪造，base mapping 不能授权释放。
  function automatic rdma_dma_mapping make_mapping(
    string name,
    rdma_function_identity identity
  );
    rdma_dma_mapping mapping;

    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = make_function({name, "_function"});
    mapping.requester_bdf = identity.key.bdf;
    mapping.pasid_valid = 1'b1;
    mapping.pasid = 20'habcde;
    mapping.dma_domain_valid = 1'b1;
    mapping.dma_domain_id = 32'h1234_5678;
    mapping.route = identity.route_key();
    mapping.reset_epoch = identity.reset_epoch;
    mapping.route_valid = 1'b1;
    mapping.epoch_valid = 1'b1;
    mapping.backing_addr.value = 64'h0000_0000_9000_0000;
    mapping.iova.value = 64'h0000_0001_9000_0000;
    mapping.size = 64'h2000;
    mapping.direction = RDMA_DMA_DEVICE_READ;
    mapping.permissions = '{
      device_read:1'b1,
      device_write:1'b0,
      atomic:1'b0
    };
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h = make_resource_handle(
      {name, "_owner"}, RDMA_RESOURCE_MR, 32'h99
    );
    mapping.umem_backed = 1'b1;
    mapping.umem_page_count = 2;
    return mapping;
  endfunction

  // 功能：创建通过完整 binding.validate() 的六 BAR、DMA、能力和双中断向量 fixture。
  // 输入/输出及副作用：name、identity 为输入；返回新 binding，拥有其 identity/PCIe 快照。
  // 失败/边界：configure 或 validate 失败会报告 fixture 错误；不配置真实 PCIe 设备。
  function automatic rdma_function_binding make_binding(
    string name,
    rdma_function_identity identity
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;
    rdma_status status;

    binding = rdma_function_binding::type_id::create(name);
    status = binding.configure_identity(identity);
    if (status == null || !status.ok())
      `uvm_error("BINDING_FIXTURE", "failed to configure binding identity")

    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    foreach (binding.pcie.bar[i]) begin
      binding.pcie.bar[i].bar_id = i;
      binding.pcie.bar[i].base.value = 64'h8000_0000 + (i * 64'h10000);
      binding.pcie.bar[i].size = 64'h10000;
      binding.pcie.bar[i].enabled = 1'b1;
    end

    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.notify_table_sel = 32'h0102_0304;
    binding.notify_table_index = 32'h0506_0708;
    binding.host_id = 32'h1112_1314;
    binding.pfvf_id = 32'h1516_1718;
    binding.rdma_vf_id = 32'h22;
    binding.vsi_id = 32'h2324_2526;
    binding.queue_dma.requester_bdf = identity.key.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'habcde;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1234_5678;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 64'h0040_0000;
    vector = '{
      function_local_vector:32'd3,
      hardware_eq_vector:32'd17,
      msix_table_index:32'd5,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    vector = '{
      function_local_vector:32'd4,
      hardware_eq_vector:32'd18,
      msix_table_index:32'd6,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = make_function({name, "_owner"});
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;

    status = binding.validate();
    if (status == null || !status.ok())
      `uvm_error("BINDING_FIXTURE", "constructed binding is invalid")
    return binding;
  endfunction

  // 功能：安装 status/ticket/image/completion 的可控 raw factory wrapper。
  // 输入/输出及副作用：无显式输入；更新四个测试字段并修改本次仿真的 UVM override。
  // 失败/边界：只允许调用一次；重复安装会使 delegate 指向旧故障 wrapper。
  function automatic void configure_snapshot_factory_faults();
    uvm_factory factory;

    factory = uvm_factory::get();
    status_fault = new("cmq_status_fault", rdma_status::get_type());
    ticket_fault = new("cmq_ticket_fault", rdma_cmq_ticket::get_type());
    image_fault = new("cmq_image_fault", rdma_hw_image::get_type());
    completion_fault = new(
      "cmq_completion_fault", rdma_cmq_completion::get_type()
    );
    factory.set_type_override_by_type(
      rdma_status::get_type(), status_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_ticket::get_type(), ticket_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), image_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_completion::get_type(), completion_fault, 1'b1
    );
  endfunction

  // 功能：关闭四个 raw factory 故障窗口，恢复后续 fixture 的正常创建。
  // 输入/输出及副作用：无输入输出；只修改 wrapper arm 状态，不移除 override。
  // 失败/边界：wrapper 尚未配置时跳过；重复调用保持幂等。
  function automatic void disarm_snapshot_factory_faults();
    if (status_fault != null)
      status_fault.disarm();
    if (ticket_fault != null)
      ticket_fault.disarm();
    if (image_fault != null)
      image_fault.disarm();
    if (completion_fault != null)
      completion_fault.disarm();
  endfunction

  // 功能：比较 canonical writer 输出与手工给定的字节数组。
  // 输入/输出及副作用：label、actual、expected 只读；不匹配时发布 UVM error。
  // 失败/边界：长度不等立即报错并返回；不会越界读取较短数组。
  function automatic void expect_bytes(
    string label,
    byte unsigned actual[],
    byte unsigned expected[]
  );
    if (actual.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("expected %0d bytes, got %0d",
                           expected.size(), actual.size()))
      return;
    end

    foreach (expected[i]) begin
      if (actual[i] != expected[i]) begin
        `uvm_error(label,
                   $sformatf("byte[%0d] expected %02x, got %02x",
                             i, expected[i], actual[i]))
        return;
      end
    end
  endfunction

  // 功能：对 canonical byte 数组执行真实 digest，并与独立手算常量比较。
  // 输入/输出及副作用：label、bytes、expected 只读；不匹配时发布 UVM error。
  // 失败/边界：空数组是合法输入；函数不借用被测 encoder 生成期望值。
  function automatic void expect_digest(
    string label,
    byte unsigned bytes[],
    rdma_cmq_journal_digest_t expected
  );
    rdma_cmq_journal_digest_t actual;

    actual = rdma_cmq_digest_bytes(bytes);
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("expected %064x, got %064x", expected, actual))
  endfunction

  // 功能：完成一个 nested-schema 编码并计算其 canonical byte digest。
  // 输入/输出及副作用：label/writer/encoded 为输入；读取 detached bytes 并返回 digest。
  // 失败/边界：encoded 为 0 时报告 UVM_ERROR 并返回全零，避免无效 fixture 被误判为覆盖。
  function automatic rdma_cmq_journal_digest_t finish_schema_digest(
    string label,
    rdma_cmq_canonical_writer writer,
    bit encoded
  );
    byte unsigned bytes[];

    if (!encoded || writer == null) begin
      `uvm_error(label, "nested V1 schema rejected a valid mutation fixture")
      return '0;
    end
    writer.snapshot(bytes);
    return rdma_cmq_digest_bytes(bytes);
  endfunction

  // 功能：断言某个已列入 V1 schema 的字段 mutation 会改变 canonical digest。
  // 输入/输出及副作用：label/baseline/changed 只读；相等时发布 UVM_ERROR。
  // 失败/边界：不把碰撞解释为成功；任一全零结果也会由对应 encoder helper 先报告。
  function automatic void expect_schema_digest_changed(
    string label,
    rdma_cmq_journal_digest_t baseline,
    rdma_cmq_journal_digest_t changed
  );
    if (changed == baseline)
      `uvm_error(label, "listed V1 field did not change canonical digest")
  endfunction

  // 功能：编码 HANDLE-V1 的 presence、kind、UID、object ID 与 generation。
  // 输入/输出及副作用：label/value/allow_null 只读；返回该独立 schema 的 digest。
  // 失败/边界：required null、未知 subtype 或非法句柄由 production encoder 拒绝并报错。
  function automatic rdma_cmq_journal_digest_t digest_handle_schema(
    string label,
    rdma_handle value,
    bit allow_null = 1'b0
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_handle_v1(writer, value, allow_null)
    );
  endfunction

  // 功能：编码 BDF-V1 的 segment、bus、device 与 function_num。
  // 输入/输出及副作用：label/bdf 只读；返回该 packed BDF schema 的 digest。
  // 失败/边界：writer 分配或 production encoder 失败时报告错误并返回全零。
  function automatic rdma_cmq_journal_digest_t digest_bdf_schema(
    string label,
    rdma_bdf_t bdf
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_bdf_v1(writer, bdf)
    );
  endfunction

  // 功能：编码 ROUTE-V1 的 Host/root/segment 与嵌套 BDF。
  // 输入/输出及副作用：label/route 只读；返回完整 route schema 的 digest。
  // 失败/边界：空 BDF 或 route.segment 不一致时 production encoder 必须拒绝。
  function automatic rdma_cmq_journal_digest_t digest_route_schema(
    string label,
    rdma_route_key_t route
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_route_v1(writer, route)
    );
  endfunction

  // 功能：编码 FUNCTION-IDENTITY-V1 的 topology、global ID 与 incarnation。
  // 输入/输出及副作用：label/identity 只读；返回完整 identity schema digest。
  // 失败/边界：identity 无效或缺失时由 production encoder 原子拒绝并报告错误。
  function automatic rdma_cmq_journal_digest_t digest_identity_schema(
    string label,
    rdma_function_identity identity
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer,
      rdma_cmq_append_function_identity_v1(writer, identity, 1'b0)
    );
  endfunction

  // 功能：编码 OPCODE-KEY-V1 的 profile、opcode 与 variant。
  // 输入/输出及副作用：label/key 只读；返回 opcode-key schema digest。
  // 失败/边界：空文本、分隔符或 malformed UTF-8 由 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_opcode_schema(
    string label,
    rdma_cmq_opcode_key key
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_opcode_key_v1(writer, key)
    );
  endfunction

  // 功能：编码 RECOVERY-OWNER-V1 的 workflow、resource、action 与冻结 provenance。
  // 输入/输出及副作用：label/owner 只读；返回完整 recovery-owner schema digest。
  // 失败/边界：非 frozen concrete owner 或被篡改 legacy sentinel 必须原子拒绝。
  function automatic rdma_cmq_journal_digest_t digest_owner_schema(
    string label,
    rdma_cmq_recovery_owner owner
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_recovery_owner_v1(writer, owner)
    );
  endfunction

  // 功能：编码 IMAGE-V1 的 metadata、三个 target、bytes 与 field summary。
  // 输入/输出及副作用：label/image 只读；返回 required image schema digest。
  // 失败/边界：长度不符、非法 enum 或零 version/generation 时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_image_schema(
    string label,
    rdma_hw_image image
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_image_v1(writer, image, 1'b0)
    );
  endfunction

  // 功能：编码 CMQ-COMMAND-V1 shell，并在 body 位置插入 profile-owned projection。
  // 输入/输出及副作用：label/command/tag/body_bytes 只读；返回 command schema digest。
  // 失败/边界：未知 body tag、非法 Function/opcode/owner/image 或零 timeout 必须拒绝。
  function automatic rdma_cmq_journal_digest_t digest_command_schema(
    string label,
    rdma_cmq_command_desc command,
    string body_tag,
    byte unsigned body_bytes[]
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer,
      rdma_cmq_append_command_v1(writer, command, body_tag, body_bytes)
    );
  endfunction

  // 功能：编码 CMQ-TICKET-V1 的 command、Function/CMQ、slot、opcode 与 deadline。
  // 输入/输出及副作用：label/ticket 只读；返回完整 ticket schema digest。
  // 失败/边界：slot/index/wrap 不一致或任一 required handle 非法时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_ticket_schema(
    string label,
    rdma_cmq_ticket ticket
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_ticket_v1(writer, ticket)
    );
  endfunction

  // 功能：编码 DMA-CONTEXT-V1 的 requester、route/epoch、owner 与 queue role。
  // 输入/输出及副作用：label/dma_context 只读；返回公开 DMA context digest。
  // 失败/边界：Function/owner 不同代、无效 PASID 或坏 route 时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_dma_context_schema(
    string label,
    rdma_dma_request_context dma_context
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_dma_context_v1(writer, dma_context)
    );
  endfunction

  // 功能：编码 DMA-MAPPING-PUBLIC-V1，并只覆盖冻结的 public authority projection。
  // 输入/输出及副作用：label/mapping 只读；返回排除 opaque allocation token 的 digest。
  // 失败/边界：零 size、坏 direction/state、route 或句柄代际不一致时 encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_mapping_schema(
    string label,
    rdma_dma_mapping mapping
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_dma_mapping_public_v1(writer, mapping)
    );
  endfunction

  // 功能：编码 FUNCTION-BINDING-V1 的 identity、PCIe/BAR、DMA/caps/vector 与状态位。
  // 输入/输出及副作用：label/binding 只读；内部通过 nonfatal accessor 读取 identity。
  // 失败/边界：identity/PCIe/BAR 缺失或 owner subtype 不支持时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_binding_schema(
    string label,
    rdma_function_binding binding
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_function_binding_v1(writer, binding)
    );
  endfunction

  // 功能：验证 legacy sentinel、具体 workflow/kind 矩阵、冻结 provenance 和 action fail-closed。
  // 输入/输出及副作用：无显式输入；构造本地 owner/command 并通过 UVM report 发布断言。
  // 失败/边界：覆盖零 ID、重复冻结、identity/resource 漂移、spare/X/Z action 与 mask。
  function automatic void check_recovery_owner_contract();
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_function_identity identity;
    rdma_function_identity wrong_identity;
    rdma_cmq_submission_recovery_action_e unknown_action;
    rdma_cmq_submission_recovery_action_e spare_action;
    rdma_cmq_recovery_workflow_e unknown_workflow;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    uvm_object cloned_object;

    owner = rdma_cmq_recovery_owner::legacy_unmigrated();
    if (owner == null ||
        owner.workflow != RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED ||
        owner.resource_h != null || owner.transaction_id != 0 ||
        owner.allowed_actions !== 3'b000 ||
        owner.function_identity != null ||
        owner.admission_attempt_id != 0 || owner.frozen)
      `uvm_error("LEGACY_OWNER_SHAPE", "legacy owner sentinel shape drifted")
    expect_status("LEGACY_OWNER_VALID",
                  owner.validate_for_admission(), RDMA_SC_OK);

    owner.allowed_actions[RDMA_CMQ_RECOVERY_RETRY_PUBLISH] = 1'b1;
    expect_status("LEGACY_OWNER_NO_ACTION",
                  owner.validate_for_admission(), RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = '0;
    if (owner.permits(RDMA_CMQ_RECOVERY_RETRY_PUBLISH) ||
        owner.permits(RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION) ||
        owner.permits(RDMA_CMQ_RECOVERY_INVALID))
      `uvm_error("LEGACY_OWNER_PERMITS", "legacy sentinel permitted an action")
    expect_status(
      "LEGACY_OWNER_NO_FREEZE",
      owner.freeze_for_journal(make_identity("legacy_identity"), 1),
      RDMA_SC_INVALID_ARGUMENT
    );

    owner = make_owner(
      "owner_mr",
      RDMA_CMQ_WORKFLOW_MR,
      RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_MR_VALID", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_QP;
    expect_status("OWNER_MR_REJECT_QP", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.resource_h.kind = RDMA_RESOURCE_MR;

    owner = make_owner(
      "owner_qp",
      RDMA_CMQ_WORKFLOW_QP,
      RDMA_RESOURCE_QP,
      RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
    );
    expect_status("OWNER_QP_VALID", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_MR;
    expect_status("OWNER_QP_REJECT_MR", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_queue_cq", RDMA_CMQ_WORKFLOW_QUEUE, RDMA_RESOURCE_CQ,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_QUEUE_CQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_SRQ;
    expect_status("OWNER_QUEUE_SRQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_CEQ;
    expect_status("OWNER_QUEUE_CEQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_AEQ;
    expect_status("OWNER_QUEUE_AEQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    for (int unsigned kind_value = RDMA_RESOURCE_FUNCTION;
         kind_value <= RDMA_RESOURCE_MW; kind_value++) begin
      if (kind_value inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                             RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})
        continue;

      owner.resource_h.kind = rdma_resource_kind_e'(kind_value);
      expect_status(
        $sformatf("OWNER_QUEUE_REJECT_%0d", kind_value),
        owner.validate_for_admission(), RDMA_SC_INVALID_ARGUMENT
      );
    end

    owner = make_owner(
      "owner_bad_fields", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    owner.transaction_id = 0;
    expect_status("OWNER_ZERO_TRANSACTION", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.transaction_id = 1;
    owner.allowed_actions = 3'b001;
    expect_status("OWNER_INVALID_ACTION_BIT", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b000;
    expect_status("OWNER_NO_ACTION", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b1x0;
    expect_status("OWNER_UNKNOWN_ACTION_MASK", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b010;
    owner.function_identity = make_identity("premature_identity");
    expect_status("OWNER_PREMATURE_IDENTITY", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.function_identity = null;
    owner.admission_attempt_id = 1;
    expect_status("OWNER_PREMATURE_ATTEMPT", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.admission_attempt_id = 0;
    owner.frozen = 1'b1;
    expect_status("OWNER_PREMATURE_FROZEN", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.frozen = 1'b0;
    owner.resource_h = null;
    expect_status("OWNER_NULL_RESOURCE", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_permits", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    if (!owner.permits(RDMA_CMQ_RECOVERY_RETRY_PUBLISH) ||
        owner.permits(RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION))
      `uvm_error("OWNER_PERMITS", "legal action mask was misread")
    unknown_action = rdma_cmq_submission_recovery_action_e'(2'bx1);
    spare_action = rdma_cmq_submission_recovery_action_e'(2'b11);
    if (owner.permits(unknown_action) || owner.permits(spare_action) ||
        owner.permits(RDMA_CMQ_RECOVERY_INVALID))
      `uvm_error("OWNER_ACTION_FAIL_CLOSED",
                 "unknown, INVALID or spare action was accepted")

    unknown_workflow = rdma_cmq_recovery_workflow_e'(3'bx10);
    owner.workflow = unknown_workflow;
    expect_status("OWNER_UNKNOWN_WORKFLOW", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.workflow = rdma_cmq_recovery_workflow_e'(3'd5);
    expect_status("OWNER_SPARE_WORKFLOW", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_freeze", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    identity = make_identity("owner_identity");
    expect_status("OWNER_FREEZE_ZERO_ATTEMPT",
                  owner.freeze_for_journal(identity, 0),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_identity = make_identity("owner_wrong_identity");
    wrong_identity.function_uid++;
    expect_status("OWNER_FREEZE_IDENTITY_MISMATCH",
                  owner.freeze_for_journal(wrong_identity, 7),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OWNER_FREEZE", owner.freeze_for_journal(identity, 7),
                  RDMA_SC_OK);
    if (!owner.frozen || owner.admission_attempt_id != 7 ||
        owner.function_identity == null ||
        owner.function_identity == identity ||
        !owner.function_identity.same_incarnation(identity))
      `uvm_error("OWNER_FREEZE_VALUE",
                 "freeze did not retain detached immutable provenance")
    expect_status("OWNER_DUPLICATE_FREEZE",
                  owner.freeze_for_journal(identity, 7),
                  RDMA_SC_INVALID_STATE);
    expect_status("OWNER_FROZEN_VALID",
                  owner.validate_frozen(identity, 7), RDMA_SC_OK);
    expect_status("OWNER_FROZEN_ATTEMPT_MISMATCH",
                  owner.validate_frozen(identity, 8),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_identity = make_identity("owner_other_epoch");
    wrong_identity.reset_epoch++;
    expect_status("OWNER_FROZEN_IDENTITY_MISMATCH",
                  owner.validate_frozen(wrong_identity, 7),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.resource_h.generation++;
    expect_status("OWNER_FROZEN_RESOURCE_MISMATCH",
                  owner.validate_frozen(identity, 7),
                  RDMA_SC_STALE_GENERATION);
    owner.resource_h.generation--;

    function_h = make_function("owner_command_function");
    cmq_h = make_cmq("owner_command_cmq", function_h);
    key = make_key("owner_command_key");
    body = make_body("owner_command_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("owner_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.timeout = 100;
    expect_status("COMMAND_LEGACY_OWNER", command.validate(), RDMA_SC_OK);
    if (command.recovery_owner == null ||
        command.recovery_owner.workflow !=
          RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED)
      `uvm_error("COMMAND_LEGACY_OWNER", "constructor omitted sentinel")
    expect_status("COMMAND_LEGACY_JOURNAL",
                  command.validate_for_journal(identity, 7), RDMA_SC_OK);

    command.recovery_owner = owner;
    expect_status("COMMAND_FROZEN_ADMISSION_REJECT", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("COMMAND_FROZEN_JOURNAL",
                  command.validate_for_journal(identity, 7), RDMA_SC_OK);
    cloned_object = command.clone();
    if (!$cast(command_snapshot, cloned_object) ||
        command_snapshot.recovery_owner == null ||
        command_snapshot.recovery_owner == command.recovery_owner ||
        command_snapshot.recovery_owner.resource_h ==
          command.recovery_owner.resource_h ||
        command_snapshot.recovery_owner.function_identity ==
          command.recovery_owner.function_identity)
      `uvm_error("COMMAND_OWNER_COPY", "command owner was not deep-copied")
    else begin
      owner_snapshot = command_snapshot.recovery_owner;
      owner_snapshot.transaction_id++;
      if (command.recovery_owner.transaction_id !=
          64'h1111_2222_3333_4444)
        `uvm_error("COMMAND_OWNER_COPY", "copied owner aliases source")
    end

    command.recovery_owner = null;
    expect_status("COMMAND_NULL_OWNER", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
  endfunction

  // 功能：验证新增执行/日志/恢复值默认形状、command identity 与 nonfatal 快照拓扑。
  // 输入/输出及副作用：无显式输入；创建本地值图并用 UVM error 报告契约偏差。
  // 失败/边界：覆盖 null、payload 自别名、factory hostile 和重复节点 canonicalization。
  function automatic void check_execution_value_defaults();
    rdma_cmq_execution_result result;
    rdma_cmq_batch_submission_item_record item_record;
    rdma_cmq_batch_submission_record batch_record;
    rdma_cmq_submission_recovery_item recovery_item;
    rdma_cmq_reset_isolation_proof proof;
    rdma_cmq_submission_recovery_request recovery_request;
    rdma_cmq_command_identity command_identity;
    rdma_cmq_command_desc command;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_status source_status;
    rdma_status status_snapshot;
    rdma_status second_status_snapshot;
    rdma_cmq_ticket source_ticket;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_ticket second_ticket_snapshot;
    rdma_cmq_completion source_completion;
    rdma_cmq_completion completion_snapshot;
    rdma_hw_image raw_cqe;
    rdma_cmq_value_wrong_factory_object source_payload;
    rdma_cmq_value_wrong_factory_object detached_payload;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_cmq_recovery_owner second_owner_snapshot;
    rdma_function_identity identity;
    string failure_reason;
    bit snapshot_ok;

    result = new("uninitialized_result");
    if (result.status == null || result.status.ok() ||
        result.status.code != RDMA_SC_INVALID_STATE ||
        result.observation_status == null ||
        result.observation_status.ok() ||
        result.observation_status.code != RDMA_SC_INVALID_STATE ||
        result.status == result.observation_status)
      `uvm_error("EXECUTION_DEFAULT",
                 "new execution result defaulted to success or null status")

    item_record = new("uninitialized_item_record");
    if (item_record.status == null || item_record.status.ok() ||
        item_record.status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("ITEM_STATUS_DEFAULT",
                 "new journal item defaulted to success or null status")

    batch_record = new("uninitialized_batch_record");
    recovery_item = new("uninitialized_recovery_item");
    proof = new("uninitialized_reset_proof");
    recovery_request = new("uninitialized_recovery_request");
    if (batch_record.items.size() != 0 || recovery_request.items.size() != 0 ||
        recovery_item.command != null ||
        proof.state != RDMA_CMQ_RESET_PROOF_INVALID ||
        proof.isolated_request_indices.size() != 0 ||
        proof.isolated_image_digests.size() != 0 ||
        proof.isolated_authority_digests.size() != 0 ||
        proof.isolated_recovery_owners.size() != 0 ||
        recovery_request.action != RDMA_CMQ_RECOVERY_INVALID)
      `uvm_error("VALUE_DEFAULTS", "new value queues/state were not empty/invalid")

    if (RDMA_CMQ_COMPLETION_NONE != 0 ||
        RDMA_CMQ_COMPLETION_PENDING != 1 ||
        RDMA_CMQ_COMPLETION_TERMINAL != 2 ||
        RDMA_CMQ_COMPLETION_TIMEOUT != 3 ||
        RDMA_CMQ_COMPLETION_RESET_CANCELLED != 4 ||
        RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY != 5 ||
        RDMA_CMQ_COMPLETION_UNOBSERVED != 6 ||
        RDMA_CMQ_SUBMISSION_STAGED != 0 ||
        RDMA_CMQ_SUBMISSION_PENDING_EFFECT != 1 ||
        RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED != 2 ||
        RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS != 3 ||
        RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED != 4 ||
        RDMA_CMQ_SUBMISSION_COMPLETED != 5 ||
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED != 6 ||
        RDMA_CMQ_SUBMISSION_LATE_COMPLETED != 7 ||
        RDMA_CMQ_SUBMISSION_RESET_QUARANTINED != 8)
      `uvm_error("VALUE_ENUM_ENCODING", "execution enum encoding drifted")

    function_h = make_function("identity_capture_function");
    cmq_h = make_cmq("identity_capture_cmq", function_h);
    key = make_key("identity_capture_key");
    body = make_body("identity_capture_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("identity_capture_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.timeout = 100;
    command_identity = new("captured_command_identity");
    failure_reason = "preseeded";
    if (!command_identity.capture_from(command, failure_reason) ||
        failure_reason != "" ||
        command_identity.function_kind != RDMA_RESOURCE_FUNCTION ||
        command_identity.function_uid != TEST_FUNCTION_UID ||
        command_identity.global_function_id != 32'h1234 ||
        command_identity.generation != TEST_GENERATION ||
        command_identity.profile_name != "generic_profile" ||
        command_identity.opcode != 32'hff00_abcd ||
        command_identity.variant != "query")
      `uvm_error("COMMAND_IDENTITY_CAPTURE", "immutable identity capture failed")
    command.function_h.function_uid++;
    command.opcode_key.variant = "mutated";
    if (command_identity.function_uid != TEST_FUNCTION_UID ||
        command_identity.variant != "query")
      `uvm_error("COMMAND_IDENTITY_DETACHED", "capture retained command aliases")
    command.function_h.function_uid--;
    command.opcode_key.variant = "query";

    snapshot_context = new();
    status_snapshot = rdma_status::success("preseeded status");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      null, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_NULL_STATUS",
                 "required null status did not fail atomically")

    ticket_snapshot = make_ticket(
      "preseeded_ticket", function_h, cmq_h, key
    );
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      null, ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || ticket_snapshot != null || failure_reason != "")
      `uvm_error("SNAPSHOT_NULL_TICKET",
                 "optional null ticket did not return clean null")

    completion_snapshot = new("preseeded_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      null, null, completion_snapshot, failure_reason
    );
    if (!snapshot_ok || completion_snapshot != null || failure_reason != "")
      `uvm_error("SNAPSHOT_NULL_COMPLETION",
                 "optional null completion did not return clean null")

    source_status = rdma_status::make(
      RDMA_SC_DMA_PERMISSION, "operation status retained"
    );
    source_status.hardware_code = 32'ha5a5_5a5a;
    source_status.hardware_code_valid = 1'b1;
    source_status.source_engine = RDMA_ENGINE_DMA;
    source_status.function_uid = TEST_FUNCTION_UID;
    source_status.generation = TEST_GENERATION;
    source_status.resource_id = 64'h1111;
    source_status.command_id = 64'h2222;
    source_status.wr_id = 64'h3333;
    source_status.severity = RDMA_SEVERITY_WARNING;
    source_status.retryable = 1'b1;
    source_ticket = make_ticket(
      "snapshot_source_ticket", function_h, cmq_h, key
    );
    raw_cqe = make_image(
      "snapshot_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64, TEST_GENERATION
    );
    source_completion = new("snapshot_source_completion");
    source_completion.ticket = source_ticket;
    source_completion.status = source_status;
    source_completion.raw_cqe = raw_cqe;
    source_completion.decoded_response = null;

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || status_snapshot == null ||
        status_snapshot == source_status ||
        status_snapshot.code != RDMA_SC_DMA_PERMISSION ||
        status_snapshot.hardware_code != 32'ha5a5_5a5a ||
        status_snapshot.source_engine != RDMA_ENGINE_DMA ||
        status_snapshot.message != "operation status retained")
      `uvm_error("SNAPSHOT_STATUS", "status snapshot lost fields or detachment")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      source_ticket, ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || ticket_snapshot == null ||
        ticket_snapshot == source_ticket ||
        ticket_snapshot.function_h == source_ticket.function_h ||
        ticket_snapshot.cmq_h == source_ticket.cmq_h ||
        ticket_snapshot.opcode_key == source_ticket.opcode_key ||
        ticket_snapshot.command_id != 64'h1234_0005)
      `uvm_error("SNAPSHOT_TICKET", "ticket snapshot was not a detached value")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, null, completion_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || completion_snapshot == null ||
        completion_snapshot == source_completion ||
        completion_snapshot.ticket != ticket_snapshot ||
        completion_snapshot.status != status_snapshot ||
        completion_snapshot.raw_cqe == source_completion.raw_cqe ||
        completion_snapshot.raw_cqe.bytes.size() != 64 ||
        completion_snapshot.decoded_response != null)
      `uvm_error("SNAPSHOT_COMPLETION_NULL_PAYLOAD",
                 "completion shell lost scalar/raw/canonical alias values")

    source_payload = new("source_payload");
    detached_payload = new("detached_payload");
    source_completion.decoded_response = source_payload;
    completion_snapshot = new("preseeded_self_payload_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, source_payload, completion_snapshot, failure_reason
    );
    if (snapshot_ok || completion_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_SELF_PAYLOAD",
                 "self-cloning completion payload was accepted")

    completion_snapshot = new("preseeded_null_payload_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, null, completion_snapshot, failure_reason
    );
    if (snapshot_ok || completion_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_MISSING_PAYLOAD",
                 "missing detached completion payload was accepted")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, detached_payload, completion_snapshot,
      failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || completion_snapshot == null ||
        completion_snapshot.decoded_response != detached_payload)
      `uvm_error("SNAPSHOT_DETACHED_PAYLOAD",
                 "detached completion payload was not published")

    identity = make_identity("snapshot_owner_identity");
    owner = make_owner(
      "snapshot_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("SNAPSHOT_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 19), RDMA_SC_OK);
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, owner_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || owner_snapshot == null ||
        owner_snapshot == owner || owner_snapshot.resource_h == owner.resource_h ||
        owner_snapshot.function_identity == owner.function_identity ||
        !owner_snapshot.validate_frozen(identity, 19).ok())
      `uvm_error("SNAPSHOT_OWNER", "frozen owner snapshot was not detached")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, second_owner_snapshot, failure_reason
    );
    if (!snapshot_ok || second_owner_snapshot != owner_snapshot)
      `uvm_error("SNAPSHOT_OWNER_CANONICAL",
                 "repeated owner source did not reuse detached node")
    owner_snapshot.transaction_id++;
    if (owner.transaction_id != 64'h1111_2222_3333_4444)
      `uvm_error("SNAPSHOT_OWNER_MUTATION", "owner snapshot aliases source")

    configure_snapshot_factory_faults();
    status_fault.arm(1'b1);
    ticket_fault.arm(1'b1);
    image_fault.arm(1'b1);
    completion_fault.arm(1'b1);
    snapshot_context = new();
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, second_status_snapshot, failure_reason
    );
    if (!snapshot_ok || second_status_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_STATUS", "direct status snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      source_ticket, second_ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || second_ticket_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_TICKET", "direct ticket snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, second_owner_snapshot, failure_reason
    );
    if (!snapshot_ok || second_owner_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_OWNER", "direct owner snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, detached_payload, completion_snapshot,
      failure_reason
    );
    if (!snapshot_ok || completion_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_COMPLETION",
                 "direct completion snapshot failed")
    if (status_fault.call_count() != 0 || ticket_fault.call_count() != 0 ||
        image_fault.call_count() != 0 || completion_fault.call_count() != 0)
      `uvm_error("SNAPSHOT_FACTORY_CALLS",
                 "nonfatal snapshot context entered raw factory")
    disarm_snapshot_factory_faults();
  endfunction

  // 功能：创建只携带指定 lifetime state 的 journal item，供 reducer 表驱动测试。
  // 输入/输出及副作用：name、state 为输入；返回新 item，其他字段保持构造默认。
  // 失败/边界：允许 spare/X/Z state 进入 fixture，以验证 reducer 保持输出不变。
  function automatic rdma_cmq_batch_submission_item_record make_state_item(
    string name,
    rdma_cmq_submission_state_e state
  );
    rdma_cmq_batch_submission_item_record item;

    item = new(name);
    item.state = state;
    return item;
  endfunction

  // 功能：验证 batch reducer 的保守优先级、全终态归约和非法阶段混合拒绝。
  // 输入/输出及副作用：无显式输入；构造 item queue 并检查返回 status/state。
  // 失败/边界：空队列、spare/X/Z state 与 pre-MMIO/published 混合必须非致命失败。
  function automatic void check_batch_state_reducer();
    rdma_cmq_batch_submission_item_record items[$];
    rdma_cmq_submission_state_e reduced_state;
    rdma_cmq_submission_state_e unknown_state;
    rdma_status status;

    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_STAGED)
      `uvm_error("BATCH_REDUCE_EMPTY", "empty batch changed aggregate state")

    items.push_back(make_state_item(
      "completed_0", RDMA_CMQ_SUBMISSION_COMPLETED
    ));
    items.push_back(make_state_item(
      "published_1", RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
    ));
    expect_status("BATCH_REDUCE_PENDING",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED)
      `uvm_error("BATCH_REDUCE_PENDING", "pending published item was lost")

    items.delete();
    items.push_back(make_state_item(
      "timeout_0", RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED
    ));
    items.push_back(make_state_item(
      "completed_1", RDMA_CMQ_SUBMISSION_COMPLETED
    ));
    expect_status("BATCH_REDUCE_TIMEOUT",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED)
      `uvm_error("BATCH_REDUCE_TIMEOUT", "timeout quarantine was lost")

    items[0].state = RDMA_CMQ_SUBMISSION_COMPLETED;
    expect_status("BATCH_REDUCE_COMPLETED",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_COMPLETED", "all-completed batch was not terminal")

    items[1].state = RDMA_CMQ_SUBMISSION_LATE_COMPLETED;
    expect_status("BATCH_REDUCE_LATE",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_LATE_COMPLETED)
      `uvm_error("BATCH_REDUCE_LATE", "late terminal item was not retained")

    items[0].state = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
    expect_status("BATCH_REDUCE_RESET",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
      `uvm_error("BATCH_REDUCE_RESET", "reset quarantine was not dominant")

    items[0].state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
    items[1].state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_STAGED)
      `uvm_error("BATCH_REDUCE_IMPOSSIBLE_MIX",
                 "pre-MMIO/published mix was accepted or changed output")

    unknown_state = rdma_cmq_submission_state_e'(4'bx001);
    items.delete();
    items.push_back(make_state_item("unknown_state", unknown_state));
    reduced_state = RDMA_CMQ_SUBMISSION_COMPLETED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_UNKNOWN", "unknown state changed output")
    items[0].state = rdma_cmq_submission_state_e'(4'hf);
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_SPARE", "spare state changed output")
  endfunction

  // 功能：验证跨 attempt evidence fold 的显式终止分支与 concrete high-water 规则。
  // 输入/输出及副作用：无显式输入；调用纯 helper 并检查 cumulative 输出。
  // 失败/边界：非法 prior、spare/X/Z 输入必须返回 0 且不改写预置输出。
  function automatic void check_attempt_effect_fold();
    rdma_submission_effect_e cumulative;
    rdma_submission_effect_e prior;
    rdma_submission_effect_e current;
    rdma_submission_effect_e expected;

    for (int unsigned prior_value =
           RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
         prior_value <= RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
         prior_value++) begin
      prior = rdma_submission_effect_e'(prior_value);
      cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      if (!rdma_cmq_fold_attempt_effect(
            prior, RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, cumulative
          ) || cumulative != prior)
        `uvm_error("ATTEMPT_FOLD_PRE", "pre-submit retry erased prior evidence")
      cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      if (!rdma_cmq_fold_attempt_effect(
            prior, RDMA_SUBMIT_EFFECT_UNOBSERVED, cumulative
          ) || cumulative != prior)
        `uvm_error("ATTEMPT_FOLD_UNOBSERVED",
                   "unobserved retry erased prior evidence")

      for (int unsigned current_value =
             RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
           current_value <= RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
           current_value++) begin
        current = rdma_submission_effect_e'(current_value);
        expected = (current_value > prior_value) ? current : prior;
        cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        if (!rdma_cmq_fold_attempt_effect(prior, current, cumulative) ||
            cumulative != expected)
          `uvm_error("ATTEMPT_FOLD_CONCRETE", "concrete maximum was wrong")
      end
    end

    current = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    cumulative = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED, current, cumulative
        ) || cumulative != current)
      `uvm_error("ATTEMPT_FOLD_DISCOVERED", "concrete evidence was not retained")
    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN_PRE", "unknown+pre did not stay unknown")
    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN", "unknown+unknown changed evidence")

    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_INVALID_PRIOR", "invalid prior changed output")
    prior = rdma_submission_effect_e'(3'b111);
    if (rdma_cmq_fold_attempt_effect(
          prior, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_SPARE", "spare effect changed output")
    current = rdma_submission_effect_e'(3'bx10);
    if (rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, current, cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN_BITS", "unknown effect changed output")
  endfunction

  // 功能：执行一行 recovery-required 表并校验 status 与预期 bit。
  // 输入/输出及副作用：label、state、phase、effect、confirmation、legacy、expected 为输入。
  // 失败/边界：返回 null/non-OK 或输出不符时发布 UVM error；不修改输入枚举。
  function automatic void expect_recovery_case(
    string label,
    rdma_cmq_submission_state_e state,
    rdma_cmq_completion_phase_e completion_phase,
    rdma_submission_effect_e submission_effect,
    bit reset_isolation_confirmed,
    bit legacy_unmigrated,
    bit expected
  );
    bit recovery_required;
    rdma_status status;

    recovery_required = ~expected;
    status = rdma_cmq_classify_recovery_required(
      state,
      completion_phase,
      submission_effect,
      reset_isolation_confirmed,
      legacy_unmigrated,
      recovery_required
    );
    if (status == null || !status.ok() || recovery_required != expected)
      `uvm_error(label, "recovery-required table row was misclassified")
  endfunction

  // 功能：验证 recovery_required 只由 lifetime state/phase/effect/proof 表推导。
  // 输入/输出及副作用：无显式输入；覆盖七个 completion phase 和 resolved/unresolved 行。
  // 失败/边界：unknown/spare/impossible 输入必须返回非成功并保持预置 output。
  function automatic void check_recovery_required_classifier();
    rdma_cmq_submission_state_e unknown_state;
    rdma_cmq_completion_phase_e unknown_phase;
    rdma_submission_effect_e unknown_effect;
    bit recovery_required;
    rdma_status status;

    expect_recovery_case(
      "RECOVERY_STAGED", RDMA_CMQ_SUBMISSION_STAGED,
      RDMA_CMQ_COMPLETION_NONE, RDMA_SUBMIT_EFFECT_UNOBSERVED,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_PENDING_EFFECT", RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
      RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_HOST_VISIBLE",
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
      RDMA_CMQ_COMPLETION_NONE, RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_AMBIGUOUS", RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
      RDMA_CMQ_COMPLETION_PENDING,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_PUBLISHED", RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
      RDMA_CMQ_COMPLETION_PENDING, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_TIMEOUT", RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
      RDMA_CMQ_COMPLETION_TIMEOUT, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_AWAITING", RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_READY_UNCONFIRMED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b1, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_CONCRETE_CONFIRMED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b1, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_RESET_LEGACY_RELEASED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b1, 1'b1, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_COMPLETED", RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_COMPLETION_TERMINAL, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_LATE", RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
      RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_UNOBSERVED", RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_COMPLETION_UNOBSERVED, RDMA_SUBMIT_EFFECT_UNOBSERVED,
      1'b0, 1'b1, 1'b1
    );

    recovery_required = 1'b0;
    unknown_state = rdma_cmq_submission_state_e'(4'bx001);
    status = rdma_cmq_classify_recovery_required(
      unknown_state, RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_UNOBSERVED, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_STATE", "unknown state changed output")
    status = rdma_cmq_classify_recovery_required(
      rdma_cmq_submission_state_e'(4'hf), RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_UNOBSERVED, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_SPARE_STATE", "spare state changed output")

    unknown_phase = rdma_cmq_completion_phase_e'(3'bx01);
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, unknown_phase,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_PHASE", "unknown phase changed output")
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED,
      rdma_cmq_completion_phase_e'(3'b111),
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_SPARE_PHASE", "spare phase changed output")

    unknown_effect = rdma_submission_effect_e'(3'bx10);
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, RDMA_CMQ_COMPLETION_TERMINAL,
      unknown_effect, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_EFFECT", "unknown effect changed output")
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, RDMA_CMQ_COMPLETION_PENDING,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_IMPOSSIBLE", "impossible phase changed output")
  endfunction

  // 功能：验证 canonical writer 的 big-endian、计数、对象 header、UTF-8 与原子失败语义。
  // 输入/输出及副作用：无显式输入；读取 writer snapshot 并与手工 byte literal 比较。
  // 失败/边界：X/Z 数值和 malformed UTF-8 必须返回 0 且完全保持已有 buffer。
  function automatic void check_canonical_writer_contract();
    rdma_cmq_canonical_writer writer;
    byte unsigned actual[];
    byte unsigned expected[];
    byte unsigned counted[];
    byte unsigned before_failure[];
    logic [15:0] unknown_u16;
    string utf8_value;
    string malformed;

    writer = new();
    if (!writer.append_u16(16'h0102))
      `uvm_error("WRITER_U16", "writer rejected known u16")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h02};
    expect_bytes("WRITER_U16", actual, expected);

    writer.clear();
    if (!writer.append_u32(32'h0102_0304))
      `uvm_error("WRITER_U32", "writer rejected known u32")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h02, 8'h03, 8'h04};
    expect_bytes("WRITER_U32", actual, expected);

    writer.clear();
    if (!writer.append_string("A"))
      `uvm_error("WRITER_STRING", "writer rejected ASCII string")
    writer.snapshot(actual);
    expected = '{8'h00, 8'h00, 8'h00, 8'h01, 8'h41};
    expect_bytes("WRITER_STRING", actual, expected);

    writer.clear();
    if (!writer.append_object_header(1'b0, ""))
      `uvm_error("WRITER_ABSENT_OBJECT", "writer rejected absent object")
    writer.snapshot(actual);
    expected = '{8'h00};
    expect_bytes("WRITER_ABSENT_OBJECT", actual, expected);

    writer.clear();
    if (!writer.append_u8(8'h01) || !writer.append_u8(8'h7f))
      `uvm_error("WRITER_PRESENT_VALUE", "writer rejected present u8 fixture")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h7f};
    expect_bytes("WRITER_PRESENT_VALUE", actual, expected);

    writer.clear();
    if (!writer.append_object_header(1'b1, "T"))
      `uvm_error("WRITER_OBJECT_TAG", "writer rejected stable object tag")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h00, 8'h00, 8'h00, 8'h01, 8'h54};
    expect_bytes("WRITER_OBJECT_TAG", actual, expected);

    writer.clear();
    counted = '{8'h80, 8'hff};
    if (!writer.append_counted_bytes(counted))
      `uvm_error("WRITER_COUNTED", "writer rejected counted bytes")
    writer.snapshot(actual);
    expected = '{8'h00, 8'h00, 8'h00, 8'h02, 8'h80, 8'hff};
    expect_bytes("WRITER_COUNTED", actual, expected);

    writer.clear();
    utf8_value = "xxx";
    utf8_value.putc(0, 8'he4);
    utf8_value.putc(1, 8'hb8);
    utf8_value.putc(2, 8'had);
    if (!writer.append_string(utf8_value))
      `uvm_error("WRITER_UTF8", "writer rejected valid UTF-8")
    writer.snapshot(actual);
    expected = '{
      8'h00, 8'h00, 8'h00, 8'h03, 8'he4, 8'hb8, 8'had
    };
    expect_bytes("WRITER_UTF8", actual, expected);

    writer.snapshot(before_failure);
    malformed = "xx";
    malformed.putc(0, 8'he4);
    malformed.putc(1, 8'hb8);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_TRUNCATED", "truncated UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_TRUNCATED_ATOMIC", actual, before_failure);

    malformed = "xx";
    malformed.putc(0, 8'hc0);
    malformed.putc(1, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_OVERLONG", "overlong UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_OVERLONG_ATOMIC", actual, before_failure);

    malformed = "xxx";
    malformed.putc(0, 8'hed);
    malformed.putc(1, 8'ha0);
    malformed.putc(2, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_SURROGATE", "UTF-8 surrogate was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_SURROGATE_ATOMIC", actual, before_failure);

    malformed = "xxxx";
    malformed.putc(0, 8'hf4);
    malformed.putc(1, 8'h90);
    malformed.putc(2, 8'h80);
    malformed.putc(3, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_RANGE", "out-of-range UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_RANGE_ATOMIC", actual, before_failure);

    unknown_u16 = 16'h0102;
    unknown_u16[7] = 1'bx;
    if (writer.append_u16(unknown_u16))
      `uvm_error("WRITER_UNKNOWN", "four-state unknown integer was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UNKNOWN_ATOMIC", actual, before_failure);
    if (writer.append_object_header(1'bx, "T") ||
        writer.append_object_header(1'b0, "T") ||
        writer.append_object_header(1'b1, ""))
      `uvm_error("WRITER_OBJECT_HEADER", "invalid object header was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_OBJECT_HEADER_ATOMIC", actual, before_failure);
  endfunction

  // 功能：逐字段变更 HANDLE/BDF/ROUTE/IDENTITY/OPCODE/OWNER V1 fixture，
  //   证明每个列明字段进入 canonical digest，而固定为真的 frozen 位会拒绝篡改。
  // 输入/输出及副作用：无显式输入；只修改本地 fixture，逐次恢复基线并报告差异。
  // 失败/边界：受 PF/VF、route segment 与 workflow/kind 约束的字段成组保持合法；
  //   任一合法 mutation 编码失败、digest 不变或 frozen=0 被接受均报告 UVM_ERROR。
  function automatic void check_identity_schema_field_mutations();
    rdma_handle handle;
    rdma_bdf_t bdf;
    rdma_route_key_t route;
    rdma_function_identity identity;
    rdma_function_key_t saved_key;
    rdma_cmq_opcode_key key;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_workflow_e saved_workflow;
    rdma_resource_kind_e saved_kind;
    rdma_cmq_canonical_writer writer;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;

    handle = make_resource_handle(
      "schema_handle", RDMA_RESOURCE_MR, 32'h1020_3040
    );
    baseline_digest = digest_handle_schema("HANDLE_BASELINE", handle);
    handle.kind = RDMA_RESOURCE_CQ;
    changed_digest = digest_handle_schema("HANDLE_KIND", handle);
    expect_schema_digest_changed("HANDLE_KIND", baseline_digest,
                                 changed_digest);
    handle.kind = RDMA_RESOURCE_MR;
    handle.function_uid++;
    changed_digest = digest_handle_schema("HANDLE_FUNCTION_UID", handle);
    expect_schema_digest_changed("HANDLE_FUNCTION_UID", baseline_digest,
                                 changed_digest);
    handle.function_uid--;
    handle.object_id++;
    changed_digest = digest_handle_schema("HANDLE_OBJECT_ID", handle);
    expect_schema_digest_changed("HANDLE_OBJECT_ID", baseline_digest,
                                 changed_digest);
    handle.object_id--;
    handle.generation++;
    changed_digest = digest_handle_schema("HANDLE_GENERATION", handle);
    expect_schema_digest_changed("HANDLE_GENERATION", baseline_digest,
                                 changed_digest);
    handle.generation--;

    identity = make_identity("schema_identity");
    bdf = identity.key.bdf;
    baseline_digest = digest_bdf_schema("BDF_BASELINE", bdf);
    bdf.segment++;
    changed_digest = digest_bdf_schema("BDF_SEGMENT", bdf);
    expect_schema_digest_changed("BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    bdf.segment--;
    bdf.bus++;
    changed_digest = digest_bdf_schema("BDF_BUS", bdf);
    expect_schema_digest_changed("BDF_BUS", baseline_digest,
                                 changed_digest);
    bdf.bus--;
    bdf.device++;
    changed_digest = digest_bdf_schema("BDF_DEVICE", bdf);
    expect_schema_digest_changed("BDF_DEVICE", baseline_digest,
                                 changed_digest);
    bdf.device--;
    bdf.function_num++;
    changed_digest = digest_bdf_schema("BDF_FUNCTION", bdf);
    expect_schema_digest_changed("BDF_FUNCTION", baseline_digest,
                                 changed_digest);
    bdf.function_num--;

    route = identity.route_key();
    baseline_digest = digest_route_schema("ROUTE_BASELINE", route);
    route.host_topology_key++;
    changed_digest = digest_route_schema("ROUTE_HOST", route);
    expect_schema_digest_changed("ROUTE_HOST", baseline_digest,
                                 changed_digest);
    route.host_topology_key--;
    route.root_id++;
    changed_digest = digest_route_schema("ROUTE_ROOT", route);
    expect_schema_digest_changed("ROUTE_ROOT", baseline_digest,
                                 changed_digest);
    route.root_id--;
    route.segment++;
    route.bdf.segment++;
    changed_digest = digest_route_schema("ROUTE_SEGMENT", route);
    expect_schema_digest_changed("ROUTE_SEGMENT", baseline_digest,
                                 changed_digest);
    route.segment--;
    route.bdf.segment--;
    route.bdf.bus++;
    changed_digest = digest_route_schema("ROUTE_BDF", route);
    expect_schema_digest_changed("ROUTE_BDF", baseline_digest,
                                 changed_digest);
    route.bdf.bus--;

    baseline_digest = digest_identity_schema(
      "IDENTITY_BASELINE", identity
    );
    identity.key.root_id++;
    changed_digest = digest_identity_schema("IDENTITY_ROOT", identity);
    expect_schema_digest_changed("IDENTITY_ROOT", baseline_digest,
                                 changed_digest);
    identity.key.root_id--;
    identity.key.host_topology_key++;
    changed_digest = digest_identity_schema("IDENTITY_HOST", identity);
    expect_schema_digest_changed("IDENTITY_HOST", baseline_digest,
                                 changed_digest);
    identity.key.host_topology_key--;

    saved_key = identity.key;
    identity.key.function_kind = RDMA_FUNCTION_PF;
    identity.key.parent_pf_bdf = '0;
    identity.key.vf_index = 0;
    changed_digest = digest_identity_schema("IDENTITY_KIND", identity);
    expect_schema_digest_changed("IDENTITY_KIND", baseline_digest,
                                 changed_digest);
    identity.key = saved_key;

    identity.key.parent_pf_bdf.segment++;
    identity.key.bdf.segment++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_SEGMENT", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_SEGMENT",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.segment--;
    identity.key.bdf.segment--;
    identity.key.parent_pf_bdf.bus++;
    changed_digest = digest_identity_schema("IDENTITY_PARENT_BUS", identity);
    expect_schema_digest_changed("IDENTITY_PARENT_BUS", baseline_digest,
                                 changed_digest);
    identity.key.parent_pf_bdf.bus--;
    identity.key.parent_pf_bdf.device++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_DEVICE", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_DEVICE",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.device--;
    identity.key.parent_pf_bdf.function_num++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_FUNCTION", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_FUNCTION",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.function_num--;
    identity.key.vf_index++;
    changed_digest = digest_identity_schema("IDENTITY_VF_INDEX", identity);
    expect_schema_digest_changed("IDENTITY_VF_INDEX", baseline_digest,
                                 changed_digest);
    identity.key.vf_index--;

    identity.key.bdf.segment++;
    identity.key.parent_pf_bdf.segment++;
    changed_digest = digest_identity_schema(
      "IDENTITY_BDF_SEGMENT", identity
    );
    expect_schema_digest_changed("IDENTITY_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    identity.key.bdf.segment--;
    identity.key.parent_pf_bdf.segment--;
    identity.key.bdf.bus++;
    changed_digest = digest_identity_schema("IDENTITY_BDF_BUS", identity);
    expect_schema_digest_changed("IDENTITY_BDF_BUS", baseline_digest,
                                 changed_digest);
    identity.key.bdf.bus--;
    identity.key.bdf.device++;
    changed_digest = digest_identity_schema("IDENTITY_BDF_DEVICE", identity);
    expect_schema_digest_changed("IDENTITY_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    identity.key.bdf.device--;
    identity.key.bdf.function_num++;
    changed_digest = digest_identity_schema(
      "IDENTITY_BDF_FUNCTION", identity
    );
    expect_schema_digest_changed("IDENTITY_BDF_FUNCTION", baseline_digest,
                                 changed_digest);
    identity.key.bdf.function_num--;
    identity.global_function_id++;
    changed_digest = digest_identity_schema("IDENTITY_GLOBAL_ID", identity);
    expect_schema_digest_changed("IDENTITY_GLOBAL_ID", baseline_digest,
                                 changed_digest);
    identity.global_function_id--;
    identity.function_uid++;
    changed_digest = digest_identity_schema("IDENTITY_UID", identity);
    expect_schema_digest_changed("IDENTITY_UID", baseline_digest,
                                 changed_digest);
    identity.function_uid--;
    identity.generation++;
    changed_digest = digest_identity_schema("IDENTITY_GENERATION", identity);
    expect_schema_digest_changed("IDENTITY_GENERATION", baseline_digest,
                                 changed_digest);
    identity.generation--;
    identity.reset_epoch++;
    changed_digest = digest_identity_schema("IDENTITY_RESET_EPOCH", identity);
    expect_schema_digest_changed("IDENTITY_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    identity.reset_epoch--;

    key = make_key("schema_opcode_key");
    baseline_digest = digest_opcode_schema("OPCODE_BASELINE", key);
    key.profile_name = "generic_profile_2";
    changed_digest = digest_opcode_schema("OPCODE_PROFILE", key);
    expect_schema_digest_changed("OPCODE_PROFILE", baseline_digest,
                                 changed_digest);
    key.profile_name = "generic_profile";
    key.opcode++;
    changed_digest = digest_opcode_schema("OPCODE_VALUE", key);
    expect_schema_digest_changed("OPCODE_VALUE", baseline_digest,
                                 changed_digest);
    key.opcode--;
    key.variant = "query_2";
    changed_digest = digest_opcode_schema("OPCODE_VARIANT", key);
    expect_schema_digest_changed("OPCODE_VARIANT", baseline_digest,
                                 changed_digest);
    key.variant = "query";

    owner = make_owner(
      "schema_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_SCHEMA_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    baseline_digest = digest_owner_schema("OWNER_BASELINE", owner);
    saved_workflow = owner.workflow;
    saved_kind = owner.resource_h.kind;
    owner.workflow = RDMA_CMQ_WORKFLOW_QP;
    owner.resource_h.kind = RDMA_RESOURCE_QP;
    changed_digest = digest_owner_schema("OWNER_WORKFLOW", owner);
    expect_schema_digest_changed("OWNER_WORKFLOW", baseline_digest,
                                 changed_digest);
    owner.workflow = saved_workflow;
    owner.resource_h.kind = saved_kind;
    owner.resource_h.object_id++;
    changed_digest = digest_owner_schema("OWNER_RESOURCE", owner);
    expect_schema_digest_changed("OWNER_RESOURCE", baseline_digest,
                                 changed_digest);
    owner.resource_h.object_id--;
    owner.transaction_id++;
    changed_digest = digest_owner_schema("OWNER_TRANSACTION", owner);
    expect_schema_digest_changed("OWNER_TRANSACTION", baseline_digest,
                                 changed_digest);
    owner.transaction_id--;
    owner.allowed_actions[RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION] = 1'b1;
    changed_digest = digest_owner_schema("OWNER_ACTIONS", owner);
    expect_schema_digest_changed("OWNER_ACTIONS", baseline_digest,
                                 changed_digest);
    owner.allowed_actions[RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION] = 1'b0;
    owner.function_identity.reset_epoch++;
    changed_digest = digest_owner_schema("OWNER_IDENTITY", owner);
    expect_schema_digest_changed("OWNER_IDENTITY", baseline_digest,
                                 changed_digest);
    owner.function_identity.reset_epoch--;
    owner.admission_attempt_id++;
    changed_digest = digest_owner_schema("OWNER_ATTEMPT", owner);
    expect_schema_digest_changed("OWNER_ATTEMPT", baseline_digest,
                                 changed_digest);
    owner.admission_attempt_id--;

    // Concrete owner 的 frozen 唯一合法值为 1；没有第二个合法值可比较 digest，
    // 因此这里直接证明变为 0 时整个 schema 原子拒绝且不能产生候选 bytes。
    owner.frozen = 1'b0;
    writer = new();
    if (rdma_cmq_append_recovery_owner_v1(writer, owner))
      `uvm_error("OWNER_FROZEN", "unfrozen concrete owner was canonicalized")
    owner.frozen = 1'b1;
  endfunction

  // 功能：逐字段变更 IMAGE、CMQ-COMMAND 与 CMQ-TICKET V1 fixture，证明
  //   metadata、body projection、nullable image 和 slot identity 都进入 digest。
  // 输入/输出及副作用：无显式输入；创建本地 graph，每次 mutation 后恢复原值。
  // 失败/边界：IMAGE length 与 byte count、ticket sequence/index/wrap 成组保持合法；
  //   任一 production encoder 拒绝合法 fixture 或 digest 不变时报告 UVM_ERROR。
  function automatic void check_command_schema_field_mutations();
    rdma_function_identity identity;
    rdma_cmq_recovery_owner owner;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_hw_image image;
    rdma_hw_image signature_image;
    byte unsigned body_bytes[];
    byte unsigned removed_byte;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;

    identity = make_identity("command_schema_identity");
    owner = make_owner(
      "command_schema_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("COMMAND_SCHEMA_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    function_h = make_function("command_schema_function");
    cmq_h = make_cmq("command_schema_cmq", function_h);
    key = make_key("command_schema_opcode");
    body = make_body("command_schema_body", function_h, cmq_h);

    image = make_image(
      "schema_image", RDMA_IMAGE_CMQ_SQE, 8, TEST_GENERATION
    );
    image.field_summary.push_back("schema-field");
    baseline_digest = digest_image_schema("IMAGE_BASELINE", image);
    image.bytes.push_back(8'h6b);
    image.length++;
    changed_digest = digest_image_schema("IMAGE_LENGTH", image);
    expect_schema_digest_changed("IMAGE_LENGTH", baseline_digest,
                                 changed_digest);
    removed_byte = image.bytes.pop_back();
    image.length--;
    if (removed_byte != 8'h6b)
      `uvm_error("IMAGE_LENGTH", "image byte queue restore drifted")
    image.alignment++;
    changed_digest = digest_image_schema("IMAGE_ALIGNMENT", image);
    expect_schema_digest_changed("IMAGE_ALIGNMENT", baseline_digest,
                                 changed_digest);
    image.alignment--;
    image.endian = RDMA_ENDIAN_LITTLE;
    changed_digest = digest_image_schema("IMAGE_ENDIAN", image);
    expect_schema_digest_changed("IMAGE_ENDIAN", baseline_digest,
                                 changed_digest);
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CQC;
    changed_digest = digest_image_schema("IMAGE_KIND", image);
    expect_schema_digest_changed("IMAGE_KIND", baseline_digest,
                                 changed_digest);
    image.image_kind = RDMA_IMAGE_CMQ_SQE;
    image.hardware_version++;
    changed_digest = digest_image_schema("IMAGE_HW_VERSION", image);
    expect_schema_digest_changed("IMAGE_HW_VERSION", baseline_digest,
                                 changed_digest);
    image.hardware_version--;
    image.function_generation++;
    changed_digest = digest_image_schema("IMAGE_FUNCTION_GENERATION", image);
    expect_schema_digest_changed("IMAGE_FUNCTION_GENERATION",
                                 baseline_digest, changed_digest);
    image.function_generation--;
    image.write_target_kind = RDMA_HW_TARGET_BACKING;
    changed_digest = digest_image_schema("IMAGE_TARGET_KIND", image);
    expect_schema_digest_changed("IMAGE_TARGET_KIND", baseline_digest,
                                 changed_digest);
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target.value++;
    changed_digest = digest_image_schema("IMAGE_BACKING_TARGET", image);
    expect_schema_digest_changed("IMAGE_BACKING_TARGET", baseline_digest,
                                 changed_digest);
    image.backing_target.value--;
    image.hmc_target.value++;
    changed_digest = digest_image_schema("IMAGE_HMC_TARGET", image);
    expect_schema_digest_changed("IMAGE_HMC_TARGET", baseline_digest,
                                 changed_digest);
    image.hmc_target.value--;
    image.bar_target.value++;
    changed_digest = digest_image_schema("IMAGE_BAR_TARGET", image);
    expect_schema_digest_changed("IMAGE_BAR_TARGET", baseline_digest,
                                 changed_digest);
    image.bar_target.value--;
    image.bytes[0] ^= 8'h01;
    changed_digest = digest_image_schema("IMAGE_BYTES", image);
    expect_schema_digest_changed("IMAGE_BYTES", baseline_digest,
                                 changed_digest);
    image.bytes[0] ^= 8'h01;
    image.field_summary[0] = "schema-field-mutated";
    changed_digest = digest_image_schema("IMAGE_SUMMARY_VALUE", image);
    expect_schema_digest_changed("IMAGE_SUMMARY_VALUE", baseline_digest,
                                 changed_digest);
    image.field_summary[0] = "schema-field";
    image.field_summary.push_back("schema-field-2");
    changed_digest = digest_image_schema("IMAGE_SUMMARY_COUNT", image);
    expect_schema_digest_changed("IMAGE_SUMMARY_COUNT", baseline_digest,
                                 changed_digest);
    void'(image.field_summary.pop_back());

    command = rdma_cmq_command_desc::type_id::create(
      "command_schema_command"
    );
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 64'h0102_0304_0506_0708;
    command.recovery_owner = owner;
    body_bytes = new[0];
    baseline_digest = digest_command_schema(
      "COMMAND_BASELINE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    command.function_h.object_id++;
    changed_digest = digest_command_schema(
      "COMMAND_FUNCTION", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_FUNCTION", baseline_digest,
                                 changed_digest);
    command.function_h.object_id--;
    command.opcode_key.opcode++;
    changed_digest = digest_command_schema(
      "COMMAND_OPCODE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_OPCODE", baseline_digest,
                                 changed_digest);
    command.opcode_key.opcode--;
    changed_digest = digest_command_schema(
      "COMMAND_BODY_TAG", command, "CMQ-BODY-OCC-FLUSH-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_BODY_TAG", baseline_digest,
                                 changed_digest);
    body_bytes = '{8'ha5};
    changed_digest = digest_command_schema(
      "COMMAND_BODY_BYTES", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_BODY_BYTES", baseline_digest,
                                 changed_digest);
    body_bytes = new[0];
    signature_image = make_image(
      "command_signature", RDMA_IMAGE_QPC, 8, TEST_GENERATION
    );
    command.qpc_signature_source = signature_image;
    changed_digest = digest_command_schema(
      "COMMAND_SIGNATURE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_SIGNATURE", baseline_digest,
                                 changed_digest);
    command.qpc_signature_source = null;
    command.vfid_override = 1'b0;
    changed_digest = digest_command_schema(
      "COMMAND_VFID_OVERRIDE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_VFID_OVERRIDE", baseline_digest,
                                 changed_digest);
    command.vfid_override = 1'b1;
    command.use_vfid++;
    changed_digest = digest_command_schema(
      "COMMAND_USE_VFID", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_USE_VFID", baseline_digest,
                                 changed_digest);
    command.use_vfid--;
    command.timeout++;
    changed_digest = digest_command_schema(
      "COMMAND_TIMEOUT", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_TIMEOUT", baseline_digest,
                                 changed_digest);
    command.timeout--;
    command.recovery_owner.transaction_id++;
    changed_digest = digest_command_schema(
      "COMMAND_OWNER", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_OWNER", baseline_digest,
                                 changed_digest);
    command.recovery_owner.transaction_id--;

    ticket = make_ticket(
      "ticket_schema_ticket", function_h, cmq_h, key
    );
    baseline_digest = digest_ticket_schema("TICKET_BASELINE", ticket);
    ticket.command_id++;
    changed_digest = digest_ticket_schema("TICKET_COMMAND_ID", ticket);
    expect_schema_digest_changed("TICKET_COMMAND_ID", baseline_digest,
                                 changed_digest);
    ticket.command_id--;
    ticket.function_h.object_id++;
    changed_digest = digest_ticket_schema("TICKET_FUNCTION", ticket);
    expect_schema_digest_changed("TICKET_FUNCTION", baseline_digest,
                                 changed_digest);
    ticket.function_h.object_id--;
    ticket.cmq_h.object_id++;
    changed_digest = digest_ticket_schema("TICKET_CMQ", ticket);
    expect_schema_digest_changed("TICKET_CMQ", baseline_digest,
                                 changed_digest);
    ticket.cmq_h.object_id--;
    ticket.slot_sequence += 64;
    changed_digest = digest_ticket_schema("TICKET_SEQUENCE", ticket);
    expect_schema_digest_changed("TICKET_SEQUENCE", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence -= 64;
    ticket.slot_sequence++;
    ticket.sq_index++;
    changed_digest = digest_ticket_schema("TICKET_SQ_INDEX", ticket);
    expect_schema_digest_changed("TICKET_SQ_INDEX", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence--;
    ticket.sq_index--;
    ticket.slot_sequence += 32;
    ticket.sq_wrap ^= 1'b1;
    changed_digest = digest_ticket_schema("TICKET_SQ_WRAP", ticket);
    expect_schema_digest_changed("TICKET_SQ_WRAP", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence -= 32;
    ticket.sq_wrap ^= 1'b1;
    ticket.opcode_key.opcode++;
    changed_digest = digest_ticket_schema("TICKET_OPCODE", ticket);
    expect_schema_digest_changed("TICKET_OPCODE", baseline_digest,
                                 changed_digest);
    ticket.opcode_key.opcode--;
    ticket.absolute_deadline++;
    changed_digest = digest_ticket_schema("TICKET_DEADLINE", ticket);
    expect_schema_digest_changed("TICKET_DEADLINE", baseline_digest,
                                 changed_digest);
    ticket.absolute_deadline--;
  endfunction

  // 功能：逐字段变更 DMA-CONTEXT、DMA-MAPPING-PUBLIC 与 FUNCTION-BINDING
  //   V1 fixture，覆盖 nested BDF、六个 BAR、全部 capability 和 vector entry。
  // 输入/输出及副作用：无显式输入；只修改本地 fixture，并在每次编码后恢复基线。
  // 失败/边界：PASID-valid mutation 使用 pasid=0 的合法子基线；任一合法字段变化
  //   被 encoder 拒绝或未改变 digest，以及 identity 重配置失败时报告 UVM_ERROR。
  function automatic void check_dma_binding_schema_field_mutations();
    rdma_function_identity identity;
    rdma_function_identity changed_identity;
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;
    rdma_interrupt_vector_binding saved_vector;
    bit [19:0] saved_pasid;
    rdma_status status;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t field_baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    string label;

    identity = make_identity("dma_schema_identity");
    dma_context = make_dma_context("dma_schema_context", identity);
    baseline_digest = digest_dma_context_schema(
      "DMA_CONTEXT_BASELINE", dma_context
    );
    dma_context.function_h.object_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_FUNCTION", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_FUNCTION", baseline_digest,
                                 changed_digest);
    dma_context.function_h.object_id--;
    dma_context.requester_bdf.bus++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_REQUESTER", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_REQUESTER", baseline_digest,
                                 changed_digest);
    dma_context.requester_bdf.bus--;

    saved_pasid = dma_context.pasid;
    dma_context.pasid = 0;
    field_baseline_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID_VALID_BASELINE", dma_context
    );
    dma_context.pasid_valid = 1'b0;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_PASID_VALID",
                                 field_baseline_digest, changed_digest);
    dma_context.pasid_valid = 1'b1;
    dma_context.pasid = saved_pasid;
    dma_context.pasid++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_PASID", baseline_digest,
                                 changed_digest);
    dma_context.pasid--;
    dma_context.dma_domain_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_DOMAIN_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    dma_context.dma_domain_valid ^= 1'b1;
    dma_context.dma_domain_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_DOMAIN_ID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    dma_context.dma_domain_id--;
    dma_context.route.host_topology_key++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROUTE", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROUTE", baseline_digest,
                                 changed_digest);
    dma_context.route.host_topology_key--;
    dma_context.reset_epoch++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_RESET_EPOCH", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    dma_context.reset_epoch--;
    dma_context.route_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROUTE_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROUTE_VALID", baseline_digest,
                                 changed_digest);
    dma_context.route_valid ^= 1'b1;
    dma_context.epoch_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_EPOCH_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_EPOCH_VALID", baseline_digest,
                                 changed_digest);
    dma_context.epoch_valid ^= 1'b1;
    dma_context.owner_h.object_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_OWNER", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_OWNER", baseline_digest,
                                 changed_digest);
    dma_context.owner_h.object_id--;
    dma_context.queue_role_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROLE_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROLE_VALID", baseline_digest,
                                 changed_digest);
    dma_context.queue_role_valid ^= 1'b1;
    dma_context.queue_role++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROLE", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROLE", baseline_digest,
                                 changed_digest);
    dma_context.queue_role--;

    mapping = make_mapping("dma_schema_mapping", identity);
    baseline_digest = digest_mapping_schema("MAPPING_BASELINE", mapping);
    mapping.function_h.object_id++;
    changed_digest = digest_mapping_schema("MAPPING_FUNCTION", mapping);
    expect_schema_digest_changed("MAPPING_FUNCTION", baseline_digest,
                                 changed_digest);
    mapping.function_h.object_id--;
    mapping.requester_bdf.bus++;
    changed_digest = digest_mapping_schema("MAPPING_REQUESTER", mapping);
    expect_schema_digest_changed("MAPPING_REQUESTER", baseline_digest,
                                 changed_digest);
    mapping.requester_bdf.bus--;

    saved_pasid = mapping.pasid;
    mapping.pasid = 0;
    field_baseline_digest = digest_mapping_schema(
      "MAPPING_PASID_VALID_BASELINE", mapping
    );
    mapping.pasid_valid = 1'b0;
    changed_digest = digest_mapping_schema("MAPPING_PASID_VALID", mapping);
    expect_schema_digest_changed("MAPPING_PASID_VALID",
                                 field_baseline_digest, changed_digest);
    mapping.pasid_valid = 1'b1;
    mapping.pasid = saved_pasid;
    mapping.pasid++;
    changed_digest = digest_mapping_schema("MAPPING_PASID", mapping);
    expect_schema_digest_changed("MAPPING_PASID", baseline_digest,
                                 changed_digest);
    mapping.pasid--;
    mapping.dma_domain_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_DOMAIN_VALID", mapping);
    expect_schema_digest_changed("MAPPING_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    mapping.dma_domain_valid ^= 1'b1;
    mapping.dma_domain_id++;
    changed_digest = digest_mapping_schema("MAPPING_DOMAIN_ID", mapping);
    expect_schema_digest_changed("MAPPING_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    mapping.dma_domain_id--;
    mapping.route.host_topology_key++;
    changed_digest = digest_mapping_schema("MAPPING_ROUTE", mapping);
    expect_schema_digest_changed("MAPPING_ROUTE", baseline_digest,
                                 changed_digest);
    mapping.route.host_topology_key--;
    mapping.reset_epoch++;
    changed_digest = digest_mapping_schema("MAPPING_RESET_EPOCH", mapping);
    expect_schema_digest_changed("MAPPING_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    mapping.reset_epoch--;
    mapping.route_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_ROUTE_VALID", mapping);
    expect_schema_digest_changed("MAPPING_ROUTE_VALID", baseline_digest,
                                 changed_digest);
    mapping.route_valid ^= 1'b1;
    mapping.epoch_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_EPOCH_VALID", mapping);
    expect_schema_digest_changed("MAPPING_EPOCH_VALID", baseline_digest,
                                 changed_digest);
    mapping.epoch_valid ^= 1'b1;
    mapping.backing_addr.value++;
    changed_digest = digest_mapping_schema("MAPPING_BACKING", mapping);
    expect_schema_digest_changed("MAPPING_BACKING", baseline_digest,
                                 changed_digest);
    mapping.backing_addr.value--;
    mapping.iova.value++;
    changed_digest = digest_mapping_schema("MAPPING_IOVA", mapping);
    expect_schema_digest_changed("MAPPING_IOVA", baseline_digest,
                                 changed_digest);
    mapping.iova.value--;
    mapping.size++;
    changed_digest = digest_mapping_schema("MAPPING_SIZE", mapping);
    expect_schema_digest_changed("MAPPING_SIZE", baseline_digest,
                                 changed_digest);
    mapping.size--;
    mapping.direction = RDMA_DMA_DEVICE_WRITE;
    changed_digest = digest_mapping_schema("MAPPING_DIRECTION", mapping);
    expect_schema_digest_changed("MAPPING_DIRECTION", baseline_digest,
                                 changed_digest);
    mapping.direction = RDMA_DMA_DEVICE_READ;
    mapping.permissions.device_read ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_READ_PERMISSION", mapping);
    expect_schema_digest_changed("MAPPING_READ_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.device_read ^= 1'b1;
    mapping.permissions.device_write ^= 1'b1;
    changed_digest = digest_mapping_schema(
      "MAPPING_WRITE_PERMISSION", mapping
    );
    expect_schema_digest_changed("MAPPING_WRITE_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.device_write ^= 1'b1;
    mapping.permissions.atomic ^= 1'b1;
    changed_digest = digest_mapping_schema(
      "MAPPING_ATOMIC_PERMISSION", mapping
    );
    expect_schema_digest_changed("MAPPING_ATOMIC_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.atomic ^= 1'b1;
    mapping.state = RDMA_MAPPING_FROZEN;
    changed_digest = digest_mapping_schema("MAPPING_STATE", mapping);
    expect_schema_digest_changed("MAPPING_STATE", baseline_digest,
                                 changed_digest);
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h.object_id++;
    changed_digest = digest_mapping_schema("MAPPING_OWNER", mapping);
    expect_schema_digest_changed("MAPPING_OWNER", baseline_digest,
                                 changed_digest);
    mapping.owner_h.object_id--;
    mapping.umem_backed ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_UMEM_BACKED", mapping);
    expect_schema_digest_changed("MAPPING_UMEM_BACKED", baseline_digest,
                                 changed_digest);
    mapping.umem_backed ^= 1'b1;
    mapping.umem_page_count++;
    changed_digest = digest_mapping_schema("MAPPING_UMEM_PAGES", mapping);
    expect_schema_digest_changed("MAPPING_UMEM_PAGES", baseline_digest,
                                 changed_digest);
    mapping.umem_page_count--;

    binding = make_binding("schema_binding", identity);
    baseline_digest = digest_binding_schema("BINDING_BASELINE", binding);
    binding.function_uid++;
    changed_digest = digest_binding_schema("BINDING_FUNCTION_UID", binding);
    expect_schema_digest_changed("BINDING_FUNCTION_UID", baseline_digest,
                                 changed_digest);
    binding.function_uid--;
    changed_identity = make_identity("schema_binding_changed_identity");
    changed_identity.reset_epoch++;
    status = binding.configure_identity(changed_identity);
    expect_status("BINDING_IDENTITY_CONFIGURE", status, RDMA_SC_OK);
    changed_digest = digest_binding_schema("BINDING_IDENTITY", binding);
    expect_schema_digest_changed("BINDING_IDENTITY", baseline_digest,
                                 changed_digest);
    status = binding.configure_identity(identity);
    expect_status("BINDING_IDENTITY_RESTORE", status, RDMA_SC_OK);

    binding.pcie.bdf.segment++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_SEGMENT", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.segment--;
    binding.pcie.bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.bus--;
    binding.pcie.bdf.device++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_DEVICE", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.device--;
    binding.pcie.bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_PCIE_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_PCIE_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.pcie.bdf.function_num--;

    binding.pcie.parent_pf_bdf.segment++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_SEGMENT", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_SEGMENT",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.segment--;
    binding.pcie.parent_pf_bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_PARENT_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_PARENT_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.pcie.parent_pf_bdf.bus--;
    binding.pcie.parent_pf_bdf.device++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_DEVICE", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_DEVICE",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.device--;
    binding.pcie.parent_pf_bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.function_num--;
    binding.pcie.vf_index++;
    changed_digest = digest_binding_schema("BINDING_VF_INDEX", binding);
    expect_schema_digest_changed("BINDING_VF_INDEX", baseline_digest,
                                 changed_digest);
    binding.pcie.vf_index--;
    binding.pcie.mse ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_MSE", binding);
    expect_schema_digest_changed("BINDING_MSE", baseline_digest,
                                 changed_digest);
    binding.pcie.mse ^= 1'b1;
    binding.pcie.bme ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_BME", binding);
    expect_schema_digest_changed("BINDING_BME", baseline_digest,
                                 changed_digest);
    binding.pcie.bme ^= 1'b1;

    foreach (binding.pcie.bar[i]) begin
      label = $sformatf("BINDING_BAR_%0d_ID", i);
      binding.pcie.bar[i].bar_id++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].bar_id--;
      label = $sformatf("BINDING_BAR_%0d_BASE", i);
      binding.pcie.bar[i].base.value++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].base.value--;
      label = $sformatf("BINDING_BAR_%0d_SIZE", i);
      binding.pcie.bar[i].size++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].size--;
      label = $sformatf("BINDING_BAR_%0d_ENABLED", i);
      binding.pcie.bar[i].enabled ^= 1'b1;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].enabled ^= 1'b1;
    end

    binding.notify_bar_id++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_BAR", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_BAR", baseline_digest,
                                 changed_digest);
    binding.notify_bar_id--;
    binding.notify_base.value++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_BASE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_BASE", baseline_digest,
                                 changed_digest);
    binding.notify_base.value--;
    binding.notify_size++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_SIZE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_SIZE", baseline_digest,
                                 changed_digest);
    binding.notify_size--;
    binding.notify_table_sel++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_TABLE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_TABLE", baseline_digest,
                                 changed_digest);
    binding.notify_table_sel--;
    binding.notify_table_index++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_INDEX", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_INDEX", baseline_digest,
                                 changed_digest);
    binding.notify_table_index--;
    binding.host_id++;
    changed_digest = digest_binding_schema("BINDING_HOST_ID", binding);
    expect_schema_digest_changed("BINDING_HOST_ID", baseline_digest,
                                 changed_digest);
    binding.host_id--;
    binding.pfvf_id++;
    changed_digest = digest_binding_schema("BINDING_PFVF_ID", binding);
    expect_schema_digest_changed("BINDING_PFVF_ID", baseline_digest,
                                 changed_digest);
    binding.pfvf_id--;
    binding.rdma_vf_id++;
    changed_digest = digest_binding_schema("BINDING_RDMA_VF_ID", binding);
    expect_schema_digest_changed("BINDING_RDMA_VF_ID", baseline_digest,
                                 changed_digest);
    binding.rdma_vf_id--;
    binding.global_function_id++;
    changed_digest = digest_binding_schema("BINDING_GLOBAL_ID", binding);
    expect_schema_digest_changed("BINDING_GLOBAL_ID", baseline_digest,
                                 changed_digest);
    binding.global_function_id--;
    binding.vsi_id++;
    changed_digest = digest_binding_schema("BINDING_VSI_ID", binding);
    expect_schema_digest_changed("BINDING_VSI_ID", baseline_digest,
                                 changed_digest);
    binding.vsi_id--;

    binding.queue_dma.requester_bdf.segment++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_SEGMENT", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.segment--;
    binding.queue_dma.requester_bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.bus--;
    binding.queue_dma.requester_bdf.device++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_DEVICE", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.device--;
    binding.queue_dma.requester_bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_DMA_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_DMA_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.queue_dma.requester_bdf.function_num--;
    binding.queue_dma.pasid_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMA_PASID_VALID", binding);
    expect_schema_digest_changed("BINDING_DMA_PASID_VALID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.pasid_valid ^= 1'b1;
    binding.queue_dma.pasid++;
    changed_digest = digest_binding_schema("BINDING_DMA_PASID", binding);
    expect_schema_digest_changed("BINDING_DMA_PASID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.pasid--;
    binding.queue_dma.dma_domain_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMA_DOMAIN_VALID", binding);
    expect_schema_digest_changed("BINDING_DMA_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.dma_domain_valid ^= 1'b1;
    binding.queue_dma.dma_domain_id++;
    changed_digest = digest_binding_schema("BINDING_DMA_DOMAIN_ID", binding);
    expect_schema_digest_changed("BINDING_DMA_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.dma_domain_id--;

    binding.queue_caps.min_cq_depth++;
    changed_digest = digest_binding_schema("BINDING_MIN_CQ", binding);
    expect_schema_digest_changed("BINDING_MIN_CQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.min_cq_depth--;
    binding.queue_caps.max_cq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_CQ", binding);
    expect_schema_digest_changed("BINDING_MAX_CQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_cq_depth--;
    binding.queue_caps.min_srq_depth++;
    changed_digest = digest_binding_schema("BINDING_MIN_SRQ", binding);
    expect_schema_digest_changed("BINDING_MIN_SRQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.min_srq_depth--;
    binding.queue_caps.max_srq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_SRQ", binding);
    expect_schema_digest_changed("BINDING_MAX_SRQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_srq_depth--;
    binding.queue_caps.max_ceq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_CEQ", binding);
    expect_schema_digest_changed("BINDING_MAX_CEQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_ceq_depth--;
    binding.queue_caps.max_aeq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_AEQ", binding);
    expect_schema_digest_changed("BINDING_MAX_AEQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_aeq_depth--;
    binding.queue_caps.max_wq_sge++;
    changed_digest = digest_binding_schema("BINDING_MAX_WQ_SGE", binding);
    expect_schema_digest_changed("BINDING_MAX_WQ_SGE", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_wq_sge--;
    binding.queue_caps.max_queue_ring_bytes++;
    changed_digest = digest_binding_schema("BINDING_MAX_RING", binding);
    expect_schema_digest_changed("BINDING_MAX_RING", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_queue_ring_bytes--;
    binding.queue_caps.max_sgb_bytes++;
    changed_digest = digest_binding_schema("BINDING_MAX_SGB", binding);
    expect_schema_digest_changed("BINDING_MAX_SGB", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_sgb_bytes--;

    foreach (binding.interrupt_vectors[i]) begin
      label = $sformatf("BINDING_VECTOR_%0d_LOCAL", i);
      binding.interrupt_vectors[i].function_local_vector++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].function_local_vector--;
      label = $sformatf("BINDING_VECTOR_%0d_HARDWARE", i);
      binding.interrupt_vectors[i].hardware_eq_vector++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].hardware_eq_vector--;
      label = $sformatf("BINDING_VECTOR_%0d_MSIX", i);
      binding.interrupt_vectors[i].msix_table_index++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].msix_table_index--;
      label = $sformatf("BINDING_VECTOR_%0d_ENABLED", i);
      binding.interrupt_vectors[i].enabled ^= 1'b1;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].enabled ^= 1'b1;
    end
    saved_vector = binding.interrupt_vectors[0];
    binding.interrupt_vectors[0] = binding.interrupt_vectors[1];
    binding.interrupt_vectors[1] = saved_vector;
    changed_digest = digest_binding_schema("BINDING_VECTOR_ORDER", binding);
    expect_schema_digest_changed("BINDING_VECTOR_ORDER", baseline_digest,
                                 changed_digest);
    saved_vector = binding.interrupt_vectors[0];
    binding.interrupt_vectors[0] = binding.interrupt_vectors[1];
    binding.interrupt_vectors[1] = saved_vector;
    vector = '{
      function_local_vector:32'd9,
      hardware_eq_vector:32'd29,
      msix_table_index:32'd19,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    changed_digest = digest_binding_schema("BINDING_VECTOR_COUNT", binding);
    expect_schema_digest_changed("BINDING_VECTOR_COUNT", baseline_digest,
                                 changed_digest);
    void'(binding.interrupt_vectors.pop_back());

    binding.state = RDMA_BIND_ERROR;
    changed_digest = digest_binding_schema("BINDING_STATE", binding);
    expect_schema_digest_changed("BINDING_STATE", baseline_digest,
                                 changed_digest);
    binding.state = RDMA_BIND_ACTIVE;
    binding.generation++;
    changed_digest = digest_binding_schema("BINDING_GENERATION", binding);
    expect_schema_digest_changed("BINDING_GENERATION", baseline_digest,
                                 changed_digest);
    binding.generation--;
    binding.owner_h.object_id++;
    changed_digest = digest_binding_schema("BINDING_OWNER", binding);
    expect_schema_digest_changed("BINDING_OWNER", baseline_digest,
                                 changed_digest);
    binding.owner_h.object_id--;
    binding.notify_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_VALID", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_VALID", baseline_digest,
                                 changed_digest);
    binding.notify_valid ^= 1'b1;
    binding.notify_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_READY", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_READY", baseline_digest,
                                 changed_digest);
    binding.notify_ready ^= 1'b1;
    binding.dmi_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMI_VALID", binding);
    expect_schema_digest_changed("BINDING_DMI_VALID", baseline_digest,
                                 changed_digest);
    binding.dmi_valid ^= 1'b1;
    binding.dmi_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMI_READY", binding);
    expect_schema_digest_changed("BINDING_DMI_READY", baseline_digest,
                                 changed_digest);
    binding.dmi_ready ^= 1'b1;
    binding.vft_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_VFT_VALID", binding);
    expect_schema_digest_changed("BINDING_VFT_VALID", baseline_digest,
                                 changed_digest);
    binding.vft_valid ^= 1'b1;
    binding.vft_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_VFT_READY", binding);
    expect_schema_digest_changed("BINDING_VFT_READY", baseline_digest,
                                 changed_digest);
    binding.vft_ready ^= 1'b1;
  endfunction

  // 功能：验证 FNV 已知答案、item 双域字段覆盖和 opaque mapping authority 分离。
  // 输入/输出及副作用：无显式输入；构造 request-owned 图并反复独立计算 digest。
  // 失败/边界：null/长度漂移/owner 不一致不发布 digest；private token 不进入公开字节。
  function automatic void check_journal_digest_contract();
    byte unsigned digest_bytes[];
    byte unsigned body_bytes[];
    rdma_function_identity identity;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner mismatched_owner;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_hw_image sqe_image;
    rdma_hw_image dependency_image;
    rdma_cmq_journal_digest_t image_digest;
    rdma_cmq_journal_digest_t authority_digest;
    rdma_cmq_journal_digest_t baseline_image_digest;
    rdma_cmq_journal_digest_t baseline_authority_digest;
    rdma_cmq_journal_digest_t second_image_digest;
    rdma_cmq_journal_digest_t second_authority_digest;
    rdma_mock_dma_mapping first_private_mapping;
    rdma_mock_dma_mapping second_private_mapping;
    rdma_mock_release_seal first_seal;
    rdma_mock_release_seal second_seal;
    rdma_status status;

    digest_bytes = new[0];
    expect_digest(
      "DIGEST_EMPTY",
      digest_bytes,
      256'hd6e8feb86659fd939e3779b97f4a7c1584222325cbf29ce4cbf29ce484222325
    );
    digest_bytes = '{8'h00, 8'h01, 8'h7f, 8'h80, 8'hff};
    expect_digest(
      "DIGEST_ASYMMETRIC",
      digest_bytes,
      256'hc4dd9f5b971ab9405e8f446e17f9bf86a7d453fabd35e4b5a5bcd1d1065f84b6
    );
    check_canonical_writer_contract();

    identity = make_identity("digest_identity");
    owner = make_owner(
      "digest_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("DIGEST_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    function_h = make_function("digest_function");
    cmq_h = make_cmq("digest_cmq", function_h);
    key = make_key("digest_key");
    body = make_body("digest_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("digest_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 64'h0102_0304_0506_0708;
    command.recovery_owner = owner;
    ticket = make_ticket("digest_ticket", function_h, cmq_h, key);
    dma_context = make_dma_context("digest_dma_context", identity);
    mapping = make_mapping("digest_mapping", identity);
    sqe_image = make_image(
      "digest_sqe", RDMA_IMAGE_CMQ_SQE, 64, TEST_GENERATION
    );
    sqe_image.field_summary.push_back("sqe-field");
    dependency_image = make_image(
      "digest_dependency", RDMA_IMAGE_CQC, 8, TEST_GENERATION
    );
    dependency_image.field_summary.push_back("dependency-field");
    body_bytes = new[0];

    status = rdma_cmq_compute_item_digests(
      command,
      "CMQ-BODY-EMPTY-V1",
      body_bytes,
      ticket,
      owner,
      identity,
      dma_context,
      sqe_image,
      mapping,
      64'h1020_3040_5060_7080,
      dependency_image,
      baseline_image_digest,
      baseline_authority_digest
    );
    expect_status("ITEM_DIGEST_BASELINE", status, RDMA_SC_OK);
    if (baseline_image_digest == '0 || baseline_authority_digest == '0)
      `uvm_error("ITEM_DIGEST_BASELINE", "valid graph returned zero digest")

    status = rdma_cmq_compute_item_digests(
      command,
      "CMQ-BODY-EMPTY-V1",
      body_bytes,
      ticket,
      owner,
      identity,
      dma_context,
      sqe_image,
      mapping,
      64'h1020_3040_5060_7080,
      dependency_image,
      image_digest,
      authority_digest
    );
    expect_status("ITEM_DIGEST_REPEAT", status, RDMA_SC_OK);
    if (image_digest != baseline_image_digest ||
        authority_digest != baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_REPEAT", "same graph was not deterministic")

    sqe_image.bytes[0] ^= 8'h01;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_SQE_BYTE", status, RDMA_SC_OK);
    if (image_digest == baseline_image_digest ||
        authority_digest != baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_SQE_BYTE", "image domain coverage drifted")
    sqe_image.bytes[0] ^= 8'h01;

    dependency_image.alignment++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DEPENDENCY_METADATA", status, RDMA_SC_OK);
    if (image_digest == baseline_image_digest)
      `uvm_error("ITEM_DIGEST_DEPENDENCY_METADATA",
                 "dependency metadata was omitted")
    dependency_image.alignment--;

    command.opcode_key.opcode++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_COMMAND_OPCODE", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_COMMAND_OPCODE", "command opcode was omitted")
    command.opcode_key.opcode--;

    body_bytes = '{8'ha5};
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_BODY_BYTES", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_BODY_BYTES", "body bytes were omitted")
    body_bytes = new[0];

    ticket.command_id++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_TICKET", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_TICKET", "ticket identity was omitted")
    ticket.command_id--;

    owner.transaction_id++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_OWNER", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_OWNER", "recovery owner was omitted")
    owner.transaction_id--;

    dma_context.queue_role++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DMA_CONTEXT", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_DMA_CONTEXT", "DMA context field was omitted")
    dma_context.queue_role--;

    mapping.iova.value += 64'h1000;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_MAPPING", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_MAPPING", "public mapping field was omitted")
    mapping.iova.value -= 64'h1000;

    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7081, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DEPENDENCY_OFFSET", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_DEPENDENCY_OFFSET", "offset was omitted")

    mismatched_owner = make_owner(
      "mismatched_digest_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("MISMATCHED_OWNER_FREEZE",
                  mismatched_owner.freeze_for_journal(identity, 37),
                  RDMA_SC_OK);
    image_digest = '1;
    authority_digest = '1;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket,
      mismatched_owner, identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    if (status == null || status.ok() || image_digest != '0 ||
        authority_digest != '0)
      `uvm_error("ITEM_DIGEST_OWNER_MISMATCH",
                 "owner mismatch published a partial digest")

    dependency_image.length++;
    image_digest = '1;
    authority_digest = '1;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    if (status == null || status.ok() || image_digest != '0 ||
        authority_digest != '0)
      `uvm_error("ITEM_DIGEST_BAD_IMAGE",
                 "malformed image published a partial digest")
    dependency_image.length--;

    first_private_mapping = new("first_private_mapping");
    second_private_mapping = new("second_private_mapping");
    first_seal = new("first_private_seal");
    second_seal = new("second_private_seal");
    expect_status("PRIVATE_MAPPING_FIRST_TOKEN",
                  first_private_mapping.initialize_allocation_token(first_seal),
                  RDMA_SC_OK);
    expect_status("PRIVATE_MAPPING_SECOND_TOKEN",
                  second_private_mapping.initialize_allocation_token(second_seal),
                  RDMA_SC_OK);
    first_private_mapping.function_h = mapping.function_h;
    first_private_mapping.requester_bdf = mapping.requester_bdf;
    first_private_mapping.pasid_valid = mapping.pasid_valid;
    first_private_mapping.pasid = mapping.pasid;
    first_private_mapping.dma_domain_valid = mapping.dma_domain_valid;
    first_private_mapping.dma_domain_id = mapping.dma_domain_id;
    first_private_mapping.route = mapping.route;
    first_private_mapping.reset_epoch = mapping.reset_epoch;
    first_private_mapping.route_valid = mapping.route_valid;
    first_private_mapping.epoch_valid = mapping.epoch_valid;
    first_private_mapping.backing_addr = mapping.backing_addr;
    first_private_mapping.iova = mapping.iova;
    first_private_mapping.size = mapping.size;
    first_private_mapping.direction = mapping.direction;
    first_private_mapping.permissions = mapping.permissions;
    first_private_mapping.state = mapping.state;
    first_private_mapping.owner_h = mapping.owner_h;
    first_private_mapping.umem_backed = mapping.umem_backed;
    first_private_mapping.umem_page_count = mapping.umem_page_count;
    second_private_mapping.copy(first_private_mapping);

    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, first_private_mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("PRIVATE_MAPPING_FIRST_DIGEST", status, RDMA_SC_OK);
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, second_private_mapping,
      64'h1020_3040_5060_7080, dependency_image,
      second_image_digest, second_authority_digest
    );
    expect_status("PRIVATE_MAPPING_SECOND_DIGEST", status, RDMA_SC_OK);
    if (authority_digest != second_authority_digest ||
        image_digest != second_image_digest)
      `uvm_error("PRIVATE_MAPPING_PUBLIC_DIGEST",
                 "opaque allocation token entered public digest")
    status = first_private_mapping.release_authority_status(
      second_private_mapping
    );
    if (status == null || status.ok())
      `uvm_error("PRIVATE_MAPPING_AUTHORITY",
                 "matching public digest authorized a different allocation")
  endfunction

  // 功能：验证 batch authority 投影、ordered tuple 覆盖及 mutable lifecycle 字段排除。
  // 输入/输出及副作用：无显式输入；从 record/request 两份图分别重算并比较 digest。
  // 失败/边界：空或不等长 tuple 不发布 digest；每个 included 字段 mutation 必须改值。
  function automatic void check_batch_digest_contract();
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_function_binding identity_binding;
    rdma_handle cmq_h;
    rdma_hw_image doorbell_image;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    rdma_cmq_journal_digest_t request_digest;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_submission_recovery_request request;
    rdma_status status;

    identity = make_identity("batch_identity");
    binding = make_binding("batch_binding", identity);
    cmq_h = make_resource_handle(
      "batch_cmq", RDMA_RESOURCE_CMQ, 32'h55
    );
    doorbell_image = make_image(
      "batch_doorbell", RDMA_IMAGE_DOORBELL, 8, TEST_GENERATION
    );
    doorbell_image.write_target_kind = RDMA_HW_TARGET_BAR;
    doorbell_image.bar_target.value = 64'h8000_2040;
    doorbell_image.field_summary.push_back("batch-doorbell");
    request_indices = '{32'd2, 32'd9};
    image_digests = '{256'h0102, 256'h0304};
    authority_digests = '{256'h0506, 256'h0708};

    status = rdma_cmq_compute_batch_digest(
      identity,
      binding,
      cmq_h,
      doorbell_image,
      13,
      1'b1,
      64'd100,
      64'd102,
      request_indices,
      image_digests,
      authority_digests,
      baseline_digest
    );
    expect_status("BATCH_DIGEST_BASELINE", status, RDMA_SC_OK);
    if (baseline_digest == '0)
      `uvm_error("BATCH_DIGEST_BASELINE", "valid batch returned zero digest")

    record = new("batch_digest_record");
    record.batch_key = "batch-key";
    record.batch_id = 64'h101;
    record.attempt_id = 64'h202;
    record.function_identity = identity;
    record.binding = binding;
    record.cmq_h = cmq_h;
    record.start_sequence = 100;
    record.end_sequence = 102;
    record.doorbell_image = doorbell_image;
    record.final_pi = 13;
    record.final_polarity = 1'b1;
    record.batch_digest = baseline_digest;
    request = new("batch_digest_request");
    request.batch_key = record.batch_key;
    request.batch_id = record.batch_id;
    request.expected_attempt_id = record.attempt_id;
    request.expected_function_identity = identity;
    request.binding = binding;
    request.cmq_h = cmq_h;
    request.start_sequence = record.start_sequence;
    request.end_sequence = record.end_sequence;
    request.doorbell_image = doorbell_image;
    request.final_pi = record.final_pi;
    request.final_polarity = record.final_polarity;
    request.batch_digest = baseline_digest;
    status = rdma_cmq_compute_batch_digest(
      request.expected_function_identity,
      request.binding,
      request.cmq_h,
      request.doorbell_image,
      request.final_pi,
      request.final_polarity,
      request.start_sequence,
      request.end_sequence,
      request_indices,
      image_digests,
      authority_digests,
      request_digest
    );
    expect_status("BATCH_DIGEST_REQUEST", status, RDMA_SC_OK);
    if (request_digest != record.batch_digest)
      `uvm_error("BATCH_DIGEST_PROJECTION",
                 "record and recovery request projections differ")

    identity.reset_epoch++;
    identity_binding = make_binding("batch_identity_binding", identity);
    status = rdma_cmq_compute_batch_digest(
      identity, identity_binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_IDENTITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_IDENTITY", "Function identity was omitted")
    identity.reset_epoch--;

    binding.notify_table_index++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_BINDING", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_BINDING", "binding field was omitted")
    binding.notify_table_index--;

    cmq_h.object_id++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_CMQ", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_CMQ", "CMQ handle was omitted")
    cmq_h.object_id--;

    doorbell_image.bytes[0] ^= 8'h80;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_DOORBELL_BYTE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_DOORBELL_BYTE", "doorbell byte was omitted")
    doorbell_image.bytes[0] ^= 8'h80;

    doorbell_image.bar_target.value++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_DOORBELL_METADATA", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_DOORBELL_METADATA", "doorbell metadata omitted")
    doorbell_image.bar_target.value--;

    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 14, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_PI", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_PI", "final PI was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b0,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_POLARITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_POLARITY", "final polarity was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      99, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_START", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_START", "start sequence was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 103, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_END", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_END", "end sequence was omitted")

    request_indices = '{32'd9, 32'd2};
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_ORDER", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_ORDER", "request order was omitted")
    request_indices = '{32'd2, 32'd9};
    image_digests[0] ^= 256'h1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_IMAGE_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_IMAGE_DIGEST", "image digest was omitted")
    image_digests[0] ^= 256'h1;
    authority_digests[1] ^= 256'h1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_AUTHORITY_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_AUTHORITY_DIGEST",
                 "authority digest was omitted")
    authority_digests[1] ^= 256'h1;

    record.attempt_id++;
    record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    record.observer_armed = 1'b1;
    record.publication_retry_safe = 1'b1;
    status = rdma_cmq_compute_batch_digest(
      record.function_identity,
      record.binding,
      record.cmq_h,
      record.doorbell_image,
      record.final_pi,
      record.final_polarity,
      record.start_sequence,
      record.end_sequence,
      request_indices,
      image_digests,
      authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_EXCLUDED_LIFECYCLE", status, RDMA_SC_OK);
    if (changed_digest != baseline_digest)
      `uvm_error("BATCH_DIGEST_EXCLUDED_LIFECYCLE",
                 "mutable lifecycle field changed batch authority")

    request_indices.delete();
    changed_digest = '1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("BATCH_DIGEST_EMPTY", "empty tuple published digest")
    request_indices.push_back(2);
    changed_digest = '1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("BATCH_DIGEST_LENGTH", "unequal tuple published digest")
  endfunction

  // 功能：验证 reset proof 的稳定 domain、ordered 四字段 tuple 和 mutable transition 排除。
  // 输入/输出及副作用：无显式输入；构造不对称 proof 并逐项 mutation 后重算。
  // 失败/边界：零 ID、空/不等长 tuple 或非法 owner 必须失败且输出清零。
  function automatic void check_reset_proof_value();
    rdma_function_identity isolated_identity;
    rdma_function_identity replacement_identity;
    rdma_cmq_recovery_owner owners[$];
    rdma_cmq_recovery_owner first_owner;
    rdma_cmq_recovery_owner second_owner;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    rdma_cmq_reset_isolation_proof proof;
    rdma_status status;

    isolated_identity = make_identity("proof_isolated_identity");
    replacement_identity = make_identity("proof_replacement_identity");
    replacement_identity.reset_epoch++;
    first_owner = make_owner(
      "proof_owner_mr", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    second_owner = make_owner(
      "proof_owner_qp", RDMA_CMQ_WORKFLOW_QP, RDMA_RESOURCE_QP,
      RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
    );
    expect_status("PROOF_OWNER_MR_FREEZE",
                  first_owner.freeze_for_journal(isolated_identity, 37),
                  RDMA_SC_OK);
    expect_status("PROOF_OWNER_QP_FREEZE",
                  second_owner.freeze_for_journal(isolated_identity, 37),
                  RDMA_SC_OK);
    owners = '{first_owner, second_owner};
    request_indices = '{32'd1, 32'd7};
    image_digests = '{256'h1122, 256'h3344};
    authority_digests = '{256'h5566, 256'h7788};

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key",
      64'h101,
      "batch-key",
      64'h202,
      64'h303,
      64'h404,
      64'h505,
      isolated_identity,
      256'h0123_4567_89ab_cdef,
      request_indices,
      image_digests,
      authority_digests,
      owners,
      baseline_digest
    );
    expect_status("RESET_PROOF_BASELINE", status, RDMA_SC_OK);
    if (baseline_digest == '0)
      `uvm_error("RESET_PROOF_BASELINE", "valid proof returned zero digest")

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key-2", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_KEY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_KEY", "proof key was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h102, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ID", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ID", "proof ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key-2", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_KEY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_KEY", "batch key was omitted")

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h203, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_ID", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_ID", "batch ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h304,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ATTEMPT", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ATTEMPT", "attempt ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h405, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ENGINE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ENGINE", "engine instance was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h506, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_INCARNATION", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_INCARNATION", "engine incarnation omitted")

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdee, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_DIGEST", "batch digest was omitted")
    request_indices[0]++;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_REQUEST_INDEX", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_REQUEST_INDEX", "request index was omitted")
    request_indices[0]--;
    image_digests[0] ^= 256'h1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_IMAGE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_IMAGE", "image digest was omitted")
    image_digests[0] ^= 256'h1;
    authority_digests[1] ^= 256'h1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_AUTHORITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_AUTHORITY", "authority digest was omitted")
    authority_digests[1] ^= 256'h1;
    first_owner.transaction_id++;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_OWNER", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_OWNER", "full recovery owner was omitted")
    first_owner.transaction_id--;

    proof = new("reset_proof_value");
    proof.proof_key = "proof-key";
    proof.proof_id = 64'h101;
    proof.batch_key = "batch-key";
    proof.batch_id = 64'h202;
    proof.attempt_id = 64'h303;
    proof.engine_instance_id = 64'h404;
    proof.engine_incarnation = 64'h505;
    proof.isolated_identity = isolated_identity;
    proof.replacement_identity = replacement_identity;
    proof.batch_digest = 256'h0123_4567_89ab_cdef;
    proof.isolated_request_indices = request_indices;
    proof.isolated_image_digests = image_digests;
    proof.isolated_authority_digests = authority_digests;
    proof.isolated_recovery_owners = owners;
    proof.proof_digest = baseline_digest;
    proof.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
    proof.backing_release_confirmed = 1'b1;
    replacement_identity.reset_epoch++;
    proof.state = RDMA_CMQ_RESET_PROOF_READY;
    proof.backing_release_confirmed = 1'b0;
    status = rdma_cmq_compute_reset_proof_digest(
      proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
      proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
      proof.isolated_identity, proof.batch_digest,
      proof.isolated_request_indices, proof.isolated_image_digests,
      proof.isolated_authority_digests, proof.isolated_recovery_owners,
      changed_digest
    );
    expect_status("RESET_PROOF_MUTABLE_EXCLUDED", status, RDMA_SC_OK);
    if (changed_digest != baseline_digest)
      `uvm_error("RESET_PROOF_MUTABLE_EXCLUDED",
                 "replacement/state/release changed stable proof digest")

    changed_digest = '1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 0, "batch-key", 64'h202, 64'h303, 64'h404,
      64'h505, isolated_identity, 256'h1, request_indices,
      image_digests, authority_digests, owners, changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("RESET_PROOF_ZERO_ID", "zero ID published proof digest")
    owners.delete();
    changed_digest = '1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 1, "batch-key", 2, 3, 4, 5,
      isolated_identity, 256'h1, request_indices,
      image_digests, authority_digests, owners, changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("RESET_PROOF_TUPLE_LENGTH",
                 "unequal proof tuple published digest")
  endfunction

  // 功能：检查共享 submission effect helper 只允许副作用阶段前进，并保持两个终止分支闭合。
  // 输入/输出及副作用：无显式输入或返回值；调用真实 helper，并通过 UVM error 发布失败结果。
  // 失败/边界：阶段回退、终止分支重开以及 before/after 含 X/Z 时均必须被 helper 拒绝。
  function automatic void check_submission_effect_ordering();
    rdma_submission_effect_e unknown_effect;

    if (!rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE))
      `uvm_error("EFFECT_FORWARD", "forward effect was rejected")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED))
      `uvm_error("EFFECT_REGRESSION", "effect regression was accepted")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE))
      `uvm_error("EFFECT_TERMINAL", "pre-submit rejection was reopened")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE))
      `uvm_error("EFFECT_UNOBSERVED", "unknown evidence was promoted")

    unknown_effect = rdma_submission_effect_e'(3'bx);

    if (rdma_submission_effect_is_monotonic(
          unknown_effect,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) ||
        rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          unknown_effect))
      `uvm_error("EFFECT_X", "four-state unknown evidence was accepted")
  endfunction

  // 功能：驱动 CMQ 模型 fixture、校验 submission effect 顺序，并验证对象校验与深拷贝契约。
  // 输入/输出及副作用：phase 由 UVM 提供；task 持有 objection，调用断言并在结束时释放。
  // 失败/边界：任一 ordering、validation 或 snapshot 契约失败均产生 UVM error；不接管 DUT 资源。
  task run_phase(uvm_phase phase);
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_cmq_expected_response expected;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_runtime_desc runtime_desc;

    rdma_cmq_opcode_key key_snapshot;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_cmq_expected_response expected_snapshot;
    rdma_cmq_decoded_cqe decoded_snapshot;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_cmq_diagnostic diagnostic_snapshot;
    rdma_cmq_runtime_desc runtime_snapshot;

    rdma_cmq_sqe_model body;
    rdma_cmq_sqe_model body_snapshot;
    rdma_cmq_null_status_body null_status_body;
    rdma_qpc_behavior response_payload;
    rdma_qpc_behavior response_payload_snapshot;
    rdma_qpc_behavior decoded_response;
    rdma_qpc_behavior decoded_response_snapshot;
    uvm_object cloned_object;

    phase.raise_objection(this);

    // 先校验独立的共享纯值契约，ordering 检查不依赖后续 CMQ object fixture。
    check_submission_effect_ordering();
    check_recovery_owner_contract();
    check_execution_value_defaults();
    check_identity_schema_field_mutations();
    check_command_schema_field_mutations();
    check_dma_binding_schema_field_mutations();
    check_journal_digest_contract();
    check_batch_digest_contract();
    check_batch_state_reducer();
    check_attempt_effect_fold();
    check_recovery_required_classifier();
    check_reset_proof_value();

    // 初始化一组有效且相互关联的 CMQ model，随后逐字段注入 validation 错误。
    function_h = make_function("function_h");
    cmq_h = make_cmq("cmq_h", function_h);
    key = make_key("key");
    body = make_body("body", function_h, cmq_h);

    command = rdma_cmq_command_desc::type_id::create("command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = make_image(
      "qpc_signature_source", RDMA_IMAGE_QPC, 512, TEST_GENERATION
    );
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;

    slot = rdma_cmq_slot_context::type_id::create("slot");
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;

    expected = rdma_cmq_expected_response::type_id::create("expected");
    expected.hardware_opcode = 32'hff00_abcd;
    expected.variant = "query";

    response_payload = rdma_qpc_behavior::type_id::create(
      "response_payload"
    );
    response_payload.transport_version = 1;
    response_payload.\priority = 3;
    decoded = rdma_cmq_decoded_cqe::type_id::create("decoded");
    decoded.hardware_opcode = 32'hff00_abcd;
    decoded.wqe_index = 5;
    decoded.wqe_wrap = 1'b1;
    decoded.hardware_ecode = 32'ha5;
    decoded.command_status = rdma_status::success("decoded success");
    decoded.command_status.hardware_code = 32'ha5;
    decoded.command_status.hardware_code_valid = 1'b1;
    decoded.response_payload = response_payload;

    ticket = make_ticket("ticket", function_h, cmq_h, key);

    decoded_response = rdma_qpc_behavior::type_id::create(
      "decoded_response"
    );
    decoded_response.transport_version = 2;
    decoded_response.\priority = 4;
    completion = rdma_cmq_completion::type_id::create("completion");
    completion.ticket = ticket;
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64, TEST_GENERATION
    );
    completion.decoded_response = decoded_response;

    diagnostic = rdma_cmq_diagnostic::type_id::create("diagnostic");
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;
    diagnostic.status = rdma_status::make(
      RDMA_SC_TIMEOUT, "late completion"
    );
    diagnostic.raw_cqe = completion.raw_cqe;

    runtime_desc = rdma_cmq_runtime_desc::type_id::create("runtime_desc");
    runtime_desc.function_h = function_h;
    runtime_desc.cmq_h = cmq_h;
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 64;
    runtime_desc.initial_sq_valid = 1'b1;
    runtime_desc.initial_cq_owner = 1'b1;
    runtime_desc.initial_doorbell_polarity = 1'b0;

    // 先确认有效基线，再短暂修改单一字段覆盖各 model 的拒绝与恢复边界。
    expect_status("KEY_VALID", key.validate(), RDMA_SC_OK);
    expect_status("COMMAND_VALID", command.validate(), RDMA_SC_OK);
    expect_status("SLOT_VALID", slot.validate(), RDMA_SC_OK);
    expect_status("EXPECTED_VALID", expected.validate(), RDMA_SC_OK);
    expect_status("DECODED_VALID", decoded.validate(), RDMA_SC_OK);
    expect_status("TICKET_VALID", ticket.validate(), RDMA_SC_OK);
    expect_status("COMPLETION_VALID", completion.validate(), RDMA_SC_OK);
    expect_status("DIAGNOSTIC_VALID", diagnostic.validate(), RDMA_SC_OK);
    expect_status("RUNTIME_VALID", runtime_desc.validate(), RDMA_SC_OK);

    key.profile_name = "";
    expect_status("KEY_EMPTY_PROFILE", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "";
    expect_status("KEY_EMPTY_VARIANT", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";
    key.profile_name = "generic|profile";
    expect_status("KEY_PROFILE_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "query|fast";
    expect_status("KEY_VARIANT_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";

    command.body = null;
    expect_status("COMMAND_NULL_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.body = body;
    body.command_id = 0;
    expect_status("COMMAND_INVALID_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    body.command_id = 64'h111;
    null_status_body = rdma_cmq_null_status_body::type_id::create(
      "null_status_body"
    );
    command.body = null_status_body;
    expect_status("COMMAND_NULL_BODY_STATUS", command.validate(),
                  RDMA_SC_INVALID_STATE);
    command.body = body;
    command.timeout = 0;
    expect_status("COMMAND_ZERO_TIMEOUT", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.timeout = 100;
    command.qpc_signature_source.function_generation++;
    expect_status("COMMAND_STALE_SIGNATURE", command.validate(),
                  RDMA_SC_STALE_GENERATION);
    command.qpc_signature_source.function_generation--;

    slot.sq_index = 32;
    expect_status("SLOT_INDEX", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.sq_index = 5;
    slot.relative_offset = 64'd321;
    expect_status("SLOT_OFFSET", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.relative_offset = 64'd320;
    slot.backing_addr.value++;
    expect_status("SLOT_ALIGNMENT", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.backing_addr.value--;
    slot.slot_sequence = 38;
    expect_status("SLOT_SEQUENCE", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.slot_sequence = 37;
    slot.cmq_h.generation++;
    expect_status("SLOT_STALE_CMQ", slot.validate(),
                  RDMA_SC_STALE_GENERATION);
    slot.cmq_h.generation--;
    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    slot.relative_offset = 64'd320;
    expect_status("SLOT_ADDRESS_OVERFLOW", slot.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    slot.backing_addr.value = 64'h0000_0000_4000_0000;

    expected.variant = "";
    expect_status("EXPECTED_EMPTY_VARIANT", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query|fast";
    expect_status("EXPECTED_SEPARATOR", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query";

    decoded.command_status = null;
    expect_status("DECODED_NULL_STATUS", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.command_status = rdma_status::success("decoded success");
    decoded.wqe_index = 32;
    expect_status("DECODED_INDEX", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.wqe_index = 5;

    ticket.command_id = 0;
    expect_status("TICKET_ZERO_ID", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.command_id = 64'h1234_0005;
    ticket.absolute_deadline = 0;
    expect_status("TICKET_ZERO_DEADLINE", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.absolute_deadline = 1000;
    ticket.sq_index = 32;
    expect_status("TICKET_INDEX", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b0;
    expect_status("TICKET_WRAP", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_wrap = 1'b1;

    completion.ticket = null;
    expect_status("COMPLETION_NULL_TICKET", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.ticket = ticket;
    completion.status = null;
    expect_status("COMPLETION_NULL_STATUS", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = null;
    expect_status("COMPLETION_SUCCESS_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::make(RDMA_SC_TIMEOUT, "timed out");
    expect_status("COMPLETION_TIMEOUT_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "reset cancellation"
    );
    expect_status("COMPLETION_RESET_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe_restored", RDMA_IMAGE_CMQ_CQE, 64,
      TEST_GENERATION
    );
    completion.raw_cqe.alignment = 32;
    expect_status("COMPLETION_CQE_ALIGNMENT", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.raw_cqe.alignment = 64;
    completion.raw_cqe.function_generation++;
    expect_status("COMPLETION_CQE_GENERATION", completion.validate(),
                  RDMA_SC_STALE_GENERATION);
    completion.raw_cqe.function_generation--;

    diagnostic.status = null;
    expect_status("DIAGNOSTIC_NULL_STATUS", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.status = rdma_status::make(RDMA_SC_TIMEOUT,
                                          "late completion");
    diagnostic.raw_cqe = null;
    expect_status("DIAGNOSTIC_NULL_CQE", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.raw_cqe = completion.raw_cqe;
    diagnostic.kind = RDMA_CMQ_DIAG_UNKNOWN_CQE;
    diagnostic.ticket = null;
    expect_status("DIAGNOSTIC_UNKNOWN_WITHOUT_TICKET",
                  diagnostic.validate(), RDMA_SC_OK);
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;

    runtime_desc.sq_depth = 31;
    expect_status("RUNTIME_SQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 31;
    expect_status("RUNTIME_CQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 32;
    expect_status("RUNTIME_ENTRY_BYTES", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.entry_bytes = 64;
    runtime_desc.cq_iova.value++;
    expect_status("RUNTIME_LAYOUT", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_iova.value--;
    runtime_desc.sq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_SQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_CQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;

    // 对每个值对象执行真实 clone，并先确认动态类型和嵌套引用均已 detached。
    cloned_object = key.clone();
    if (!$cast(key_snapshot, cloned_object))
      `uvm_error("KEY_CLONE", "opcode key clone has wrong type")

    cloned_object = command.clone();
    if (!$cast(command_snapshot, cloned_object))
      `uvm_error("COMMAND_CLONE", "command clone has wrong type")

    cloned_object = slot.clone();
    if (!$cast(slot_snapshot, cloned_object))
      `uvm_error("SLOT_CLONE", "slot clone has wrong type")

    cloned_object = expected.clone();
    if (!$cast(expected_snapshot, cloned_object))
      `uvm_error("EXPECTED_CLONE", "expected response clone has wrong type")

    cloned_object = decoded.clone();
    if (!$cast(decoded_snapshot, cloned_object))
      `uvm_error("DECODED_CLONE", "decoded CQE clone has wrong type")

    cloned_object = ticket.clone();
    if (!$cast(ticket_snapshot, cloned_object))
      `uvm_error("TICKET_CLONE", "ticket clone has wrong type")

    cloned_object = completion.clone();
    if (!$cast(completion_snapshot, cloned_object))
      `uvm_error("COMPLETION_CLONE", "completion clone has wrong type")

    cloned_object = diagnostic.clone();
    if (!$cast(diagnostic_snapshot, cloned_object))
      `uvm_error("DIAGNOSTIC_CLONE", "diagnostic clone has wrong type")

    cloned_object = runtime_desc.clone();
    if (!$cast(runtime_snapshot, cloned_object))
      `uvm_error("RUNTIME_CLONE", "runtime descriptor clone has wrong type")

    if (command_snapshot != null) begin
      if (command_snapshot.function_h == command.function_h ||
          command_snapshot.opcode_key == command.opcode_key ||
          command_snapshot.body == command.body ||
          command_snapshot.qpc_signature_source ==
            command.qpc_signature_source)
        `uvm_error("COMMAND_DEEP_COPY",
                   "command nested objects alias the source")
      if (!$cast(body_snapshot, command_snapshot.body))
        `uvm_error("COMMAND_DEEP_COPY", "command body clone lost type")
    end
    if (slot_snapshot != null &&
        (slot_snapshot.function_h == slot.function_h ||
         slot_snapshot.cmq_h == slot.cmq_h))
      `uvm_error("SLOT_DEEP_COPY", "slot handles alias the source")
    if (decoded_snapshot != null) begin
      if (decoded_snapshot.command_status == decoded.command_status ||
          decoded_snapshot.response_payload == decoded.response_payload)
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded CQE nested objects alias the source")
      if (!$cast(response_payload_snapshot,
                 decoded_snapshot.response_payload))
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded response payload clone lost type")
    end
    if (ticket_snapshot != null &&
        (ticket_snapshot.function_h == ticket.function_h ||
         ticket_snapshot.cmq_h == ticket.cmq_h ||
         ticket_snapshot.opcode_key == ticket.opcode_key))
      `uvm_error("TICKET_DEEP_COPY", "ticket nested objects alias source")
    if (completion_snapshot != null) begin
      if (completion_snapshot.ticket == completion.ticket ||
          completion_snapshot.status == completion.status ||
          completion_snapshot.raw_cqe == completion.raw_cqe ||
          completion_snapshot.decoded_response ==
            completion.decoded_response)
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion nested objects alias the source")
      if (!$cast(decoded_response_snapshot,
                 completion_snapshot.decoded_response))
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion decoded response clone lost type")
    end
    if (diagnostic_snapshot != null &&
        (diagnostic_snapshot.ticket == diagnostic.ticket ||
         diagnostic_snapshot.status == diagnostic.status ||
         diagnostic_snapshot.raw_cqe == diagnostic.raw_cqe))
      `uvm_error("DIAGNOSTIC_DEEP_COPY",
                 "diagnostic nested objects alias the source")
    if (runtime_snapshot != null &&
        (runtime_snapshot.function_h == runtime_desc.function_h ||
         runtime_snapshot.cmq_h == runtime_desc.cmq_h))
      `uvm_error("RUNTIME_DEEP_COPY",
                 "runtime descriptor handles alias the source")

    // 修改所有源对象后，用手工 literal 证明已发布 snapshot 不受源图变化影响。
    function_h.generation++;
    cmq_h.object_id++;
    key.profile_name = "mutated_profile";
    key.variant = "mutated_variant";
    body.command_id++;
    command.qpc_signature_source.bytes[0] = 8'h00;
    decoded.command_status.message = "mutated decoded status";
    response_payload.transport_version++;
    completion.status.message = "mutated completion status";
    completion.raw_cqe.bytes[0] = 8'h00;
    decoded_response.transport_version++;
    diagnostic.status.message = "mutated diagnostic status";

    if (key_snapshot == null ||
        key_snapshot.profile_name != "generic_profile" ||
        key_snapshot.variant != "query" ||
        key_snapshot.opcode != 32'hff00_abcd)
      `uvm_error("KEY_SNAPSHOT", "opcode key snapshot changed")
    if (command_snapshot == null ||
        command_snapshot.function_h.generation != TEST_GENERATION ||
        command_snapshot.opcode_key.profile_name != "generic_profile" ||
        command_snapshot.qpc_signature_source.bytes[0] != 8'h5a ||
        body_snapshot == null || body_snapshot.command_id != 64'h111 ||
        command_snapshot.vfid_override != 1'b1 ||
        command_snapshot.use_vfid != 11'h345 ||
        command_snapshot.timeout != 100)
      `uvm_error("COMMAND_SNAPSHOT", "command snapshot changed")
    if (slot_snapshot == null ||
        slot_snapshot.function_h.generation != TEST_GENERATION ||
        slot_snapshot.cmq_h.object_id != 32'h55 ||
        slot_snapshot.backing_addr.value != 64'h0000_0000_4000_0000 ||
        slot_snapshot.relative_offset != 320 ||
        slot_snapshot.slot_sequence != 37 || slot_snapshot.sq_index != 5 ||
        slot_snapshot.sq_wrap != 1'b1)
      `uvm_error("SLOT_SNAPSHOT", "slot snapshot changed")
    if (expected_snapshot == null ||
        expected_snapshot.hardware_opcode != 32'hff00_abcd ||
        expected_snapshot.variant != "query")
      `uvm_error("EXPECTED_SNAPSHOT",
                 "expected response snapshot changed")
    if (decoded_snapshot == null ||
        decoded_snapshot.command_status.message != "decoded success" ||
        response_payload_snapshot == null ||
        response_payload_snapshot.transport_version != 1 ||
        decoded_snapshot.hardware_opcode != 32'hff00_abcd ||
        decoded_snapshot.wqe_index != 5 ||
        decoded_snapshot.wqe_wrap != 1'b1 ||
        decoded_snapshot.hardware_ecode != 32'ha5)
      `uvm_error("DECODED_SNAPSHOT", "decoded CQE snapshot changed")
    if (ticket_snapshot == null ||
        ticket_snapshot.function_h.generation != TEST_GENERATION ||
        ticket_snapshot.cmq_h.object_id != 32'h55 ||
        ticket_snapshot.opcode_key.variant != "query" ||
        ticket_snapshot.command_id != 64'h1234_0005 ||
        ticket_snapshot.absolute_deadline != 1000)
      `uvm_error("TICKET_SNAPSHOT", "ticket snapshot changed")
    if (completion_snapshot == null ||
        completion_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        completion_snapshot.status.message != "hardware completion" ||
        completion_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        decoded_response_snapshot == null ||
        decoded_response_snapshot.transport_version != 2)
      `uvm_error("COMPLETION_SNAPSHOT", "completion snapshot changed")
    if (diagnostic_snapshot == null ||
        diagnostic_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        diagnostic_snapshot.status.message != "late completion" ||
        diagnostic_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        diagnostic_snapshot.kind != RDMA_CMQ_DIAG_LATE_COMPLETION)
      `uvm_error("DIAGNOSTIC_SNAPSHOT", "diagnostic snapshot changed")
    if (runtime_snapshot == null ||
        runtime_snapshot.function_h.generation != TEST_GENERATION ||
        runtime_snapshot.cmq_h.object_id != 32'h55 ||
        runtime_snapshot.sq_iova.value != 64'h0000_0001_2000_0000 ||
        runtime_snapshot.cq_iova.value != 64'h0000_0001_2000_0800 ||
        runtime_snapshot.sq_depth != 32 || runtime_snapshot.cq_depth != 32 ||
        runtime_snapshot.entry_bytes != 64 ||
        runtime_snapshot.initial_sq_valid != 1'b1 ||
        runtime_snapshot.initial_cq_owner != 1'b1 ||
        runtime_snapshot.initial_doorbell_polarity != 1'b0)
      `uvm_error("RUNTIME_SNAPSHOT", "runtime descriptor snapshot changed")

    phase.drop_objection(this);
  endtask
endclass
