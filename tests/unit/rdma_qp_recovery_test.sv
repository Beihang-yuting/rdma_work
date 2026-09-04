// 目录：测试层 unit/rdma_qp_recovery_test.sv。
// 职责：验证 rdma_qp_recovery_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_qp_recovery_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_qp_publication_fault_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_qp_publication_fault_manager)
  bit fail_commit;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_qp_publication_fault_manager");
    super.new(name);
    fail_commit = 1'b0;
  endfunction

  // 功能：提交已验证的状态迁移或消费结果，推进游标/账本并保持幂等边界（接口 commit_qp_programmed）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status commit_qp_programmed(rdma_qp candidate);
    if (fail_commit) begin
      fail_commit = 1'b0;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "injected QP publication failure");
    end
    return super.commit_qp_programmed(candidate);
  endfunction
endclass

class rdma_qp_ticketless_modify_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_ticketless_modify_cmq)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_qp_ticketless_modify_cmq");
    super.new(name);
  endfunction

  // 功能：执行接口 execute 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 execute）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    super.execute(command, ticket, completion, status);
    if (command != null && command.opcode_key != null &&
        command.opcode_key.opcode == XTR_V1_OP_QPC_MODIFY) begin
      ticket = null;
      completion = null;
      if (status != null && !status.ok())
        last_execute_no_submit_proven = 1'b1;
    end
  endtask
endclass

// Populate each DEVICE_WRITE allocation with a complete QPC image.  QPC
// staging uses DEVICE_READ, so the script affects only the recovery query
// buffer allocated by the executor.
class rdma_qp_scripted_query_host_mem extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_qp_scripted_query_host_mem)
  byte scripted_query_bytes[];

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_qp_scripted_query_host_mem");
    super.new(name);
    scripted_query_bytes = new[0];
  endfunction

  // 功能：执行接口 script_query_image 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 script_query_image）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function void script_query_image(byte bytes[]);
    scripted_query_bytes = new[bytes.size()];
    foreach (bytes[i]) scripted_query_bytes[i] = bytes[i];
  endfunction

  // 功能：原子地预留或获取所需资源/游标，并记录后续提交所需的所有权证据（接口 allocate）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    rdma_status status;

    status = super.allocate(request_context, size, alignment, direction,
                            mapping);
    if (status != null && status.ok() && mapping != null &&
        direction == RDMA_DMA_DEVICE_WRITE &&
        scripted_query_bytes.size() == 512)
      void'(super.write(mapping, 0, scripted_query_bytes));
    return status;
  endfunction
endclass

// 功能：执行接口 rdma_qp_encode_query_bytes 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 rdma_qp_encode_query_bytes）。
// 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
//   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
// 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
function automatic rdma_status rdma_qp_encode_query_bytes(
  rdma_qpc_model qpc,
  output byte bytes[]
);
  rdma_codec_registry registry;
  rdma_codec_key key;
  rdma_codec_base codec;
  rdma_hw_image image;
  rdma_status status;
  string variant;

  bytes = new[0];
  if (qpc == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "QP query test QPC is null");
  case (qpc.transport)
    RDMA_TRANSPORT_RC: variant = "rc";
    RDMA_TRANSPORT_UD: variant = "ud";
    RDMA_TRANSPORT_URC: variant = "urc";
    default: return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                      "QP query test transport is invalid");
  endcase
  registry = rdma_codec_registry::type_id::create("qp_query_test_registry");
  status = rdma_xtr_v1_register_qpc_codecs(registry);
  key.hw_version = "xtr_v1";
  key.image_kind = RDMA_IMAGE_QPC;
  key.object_type = "qpc";
  key.variant = variant;
  key.opcode = XTR_V1_OP_QPC_CREATE;
  if (status.ok()) status = registry.lookup(key, codec);
  if (status.ok()) status = codec.encode(qpc, image);
  if (!status.ok() || image == null)
    return status.ok() ? rdma_status::make(RDMA_SC_INVALID_STATE,
      "QP query test image encode returned null") : status;
  bytes = new[image.bytes.size()];
  foreach (image.bytes[i]) bytes[i] = image.bytes[i];
  return rdma_status::success();
endfunction

// Leave the task-level status successful while withholding the terminal
// completion object.  A QPC_QUERY image must never be authenticated without
// this completion proof; the recovery path should remain ERROR/fail-closed.
class rdma_qp_query_completion_fault_cmq extends rdma_mock_cmq_port;
  `uvm_object_utils(rdma_qp_query_completion_fault_cmq)
  bit drop_query_completion;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_qp_query_completion_fault_cmq");
    super.new(name);
    drop_query_completion = 1'b0;
  endfunction

  // 功能：执行接口 execute 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 execute）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    super.execute(command, ticket, completion, status);
    if (drop_query_completion && command != null &&
        command.opcode_key != null &&
        command.opcode_key.opcode[7:0] == XTR_V1_OP_QPC_QUERY)
      completion = null;
  endtask
endclass

// Focused Task 5 recovery regression shell.  The lifecycle test owns the
// fixture builders; this test is registered early so the mandated RED command
// compiles while modify recovery behavior is being developed.
class rdma_qp_recovery_test extends rdma_qp_lifecycle_test;
  `uvm_component_utils(rdma_qp_recovery_test)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_qp_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行 UVM 阶段任务，驱动测试场景并在结束时释放阶段 objection（接口 run_phase）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_ticketless_definitive_modify_recovery();
    check_ticketless_publication_modify_recovery();
    check_ambiguous_modify_recovery();
    check_modify_query_requires_terminal_completion();
    check_create_rollback_without_candidate_qpc();
    check_ambiguous_destroy_recovery();
    check_ambiguous_create_recovery_dispatch();
    check_ambiguous_create_terminal_failure_cleanup();
    check_ambiguous_create_terminal_success_destroy();
    check_modify_query_matrix();
    check_create_presence_query();
    check_delete_presence_query();
    check_optional_sgb_recovery_validation();
    phase.drop_objection(this);
  endtask

  // RC can legally carry an optional SQ-SGB when its SGE capability requires
  // one.  Recovery must authenticate that retained authority and reject a
  // forged mapping owner or malformed rounded geometry before any CMQ work.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_optional_sgb_recovery_validation）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_optional_sgb_recovery_validation();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record record;
    rdma_status status;
    rdma_handle original_owner;
    longint unsigned original_length;

    mem = rdma_mock_host_mem::type_id::create("OPTIONAL_SGB_mem");
    setup_qp_environment("OPTIONAL_SGB", mem, binding, manager, contexts,
                         cmq, executor, pd, cq);
    create_req = make_request("OPTIONAL_SGB_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    create_req.max_send_sge = 4;
    create_req.max_recv_sge = 4;
    create_req.max_inline_data = 512;
    create_req.sq_sgb_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    executor.create_locked(binding, binding.make_handle(), create_req, 970,
                           qp, result);
    if (result == null || !result.ok() || qp == null) begin
      `uvm_error("OPTIONAL_SGB_CREATE", "RC optional SGB fixture did not create")
      return;
    end
    modify_req = rdma_modify_qp_req::type_id::create("OPTIONAL_SGB_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle,
                                               "OPTIONAL_SGB_qp");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 971,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h34567;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 972,
                           qp, result);
    record = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, record));
    if (record == null || record.qp_recovery == null ||
        record.qp_recovery.qp_plan == null ||
        record.qp_recovery.qp_plan.sq_sgb_ref == null) begin
      `uvm_error("OPTIONAL_SGB_RECOVERY_SETUP",
                 "RC recovery did not retain optional SQ-SGB authority")
      return;
    end
    original_owner = rdma_clone_handle_value(
      record.qp_recovery.qp_plan.sq_sgb_ref.mapping.owner_h,
      "OPTIONAL_SGB_original_owner");
    original_length = record.qp_recovery.qp_plan.sq_sgb_ref.length;
    record.qp_recovery.qp_plan.sq_sgb_ref.mapping.owner_h =
      rdma_clone_handle_value(pd.handle, "OPTIONAL_SGB_forged_owner");
    status = record.qp_recovery.validate();
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("OPTIONAL_SGB_RECOVERY_OWNER",
                 "forged optional SGB mapping owner was accepted")
    record.qp_recovery.qp_plan.sq_sgb_ref.mapping.owner_h = original_owner;
    record.qp_recovery.qp_plan.sq_sgb_ref.length = original_length - 512;
    status = record.qp_recovery.validate();
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("OPTIONAL_SGB_RECOVERY_GEOMETRY",
                 "malformed optional SGB geometry was accepted")
  endtask

  // A successful task status with an empty QPC_QUERY completion must not
  // authorize stale bytes already present in the query buffer.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_modify_query_requires_terminal_completion）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_modify_query_requires_terminal_completion();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_query_completion_fault_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;
    byte query_bytes[];
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("QUERY_COMPLETION_mem");
    manager = rdma_resource_manager::type_id::create("QUERY_COMPLETION_manager");
    contexts = rdma_mock_context_backing::type_id::create(
      "QUERY_COMPLETION_contexts");
    cmq = rdma_qp_query_completion_fault_cmq::type_id::create(
      "QUERY_COMPLETION_cmq");
    cmq.drop_query_completion = 1'b1;
    executor = rdma_qp_lifecycle_executor::type_id::create(
      "QUERY_COMPLETION_executor");
    setup_custom_qp_environment("QUERY_COMPLETION", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    create_req = make_request("QUERY_COMPLETION_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 960,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("QUERY_COMPLETION_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle,
                                               "QUERY_COMPLETION_qp");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 961,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h23456;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 962,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.query_mapping == null) begin
      `uvm_error("QUERY_COMPLETION_SETUP",
                 "ambiguous MODIFY did not retain query mapping")
      return;
    end
    status = rdma_qp_encode_query_bytes(recovery.qp_recovery.candidate_qpc,
                                         query_bytes);
    if (status == null || !status.ok() ||
        !((mem.write(recovery.qp_recovery.query_mapping, 0, query_bytes)) != null)) begin
      `uvm_error("QUERY_COMPLETION_SETUP", "failed to seed QPC query image")
      return;
    end
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            963, recovery_result);
    void'(manager.lookup(result.resource_h, resource));
    status = recovery_result == null ? null : recovery_result.status;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        resource == null || resource.state != RDMA_RESOURCE_ERROR)
      `uvm_error("QUERY_COMPLETION_FAIL_CLOSED",
                 "QPC_QUERY without terminal completion was accepted")
  endtask

  // A pre-program CREATE rollback may have no candidate QPC at all.  With no
  // hardware context present, recovery must still release local authorities
  // and finalize the reservation.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_create_rollback_without_candidate_qpc）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_create_rollback_without_candidate_qpc();
    rdma_qp_boundary_host_mem mem;
    rdma_qp_fault_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_function_binding binding;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req request;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;
    rdma_status status;

    mem = rdma_qp_boundary_host_mem::type_id::create("NULL_CANDIDATE_mem");
    manager = rdma_qp_fault_manager::type_id::create("NULL_CANDIDATE_manager");
    manager.sequence_failure = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "injected pre-program authority failure");
    mem.mode = "timeout_plan_release_before";
    contexts = rdma_mock_context_backing::type_id::create(
      "NULL_CANDIDATE_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("NULL_CANDIDATE_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create(
      "NULL_CANDIDATE_executor");
    setup_custom_qp_environment("NULL_CANDIDATE", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    request = make_request("NULL_CANDIDATE_request", binding, pd, cq,
                           RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), request, 964,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.candidate_qpc != null) begin
      `uvm_error("NULL_CANDIDATE_SETUP",
                 "setup did not produce a candidate-less rollback")
      return;
    end
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            965, recovery_result);
    status = recovery_result == null ? null : recovery_result.status;
    void'(manager.lookup(result.resource_h, resource));
    if (status == null || !status.ok() ||
        recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        resource != null || mem.live_allocations() != 0)
      `uvm_error("NULL_CANDIDATE_RECOVERY",
                 "candidate-less CREATE rollback did not clean up")
  endtask

  // An ambiguous full MODIFY must authenticate the complete QPC_QUERY image
  // before selecting candidate, restoring prior, or remaining in ERROR.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_modify_query_matrix）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_modify_query_matrix();
    for (int unsigned query_case = 0; query_case < 3; query_case++) begin
      string label;
      rdma_mock_host_mem mem;
      rdma_function_binding binding;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req create_req;
      rdma_modify_qp_req modify_req;
      rdma_qp qp;
      rdma_control_result result;
      rdma_control_result recovery_result;
      rdma_recovery_record recovery;
      rdma_resource resource;
      rdma_qpc_model query_qpc;
      uvm_object cloned;
      byte query_bytes[];
      rdma_status status;

      label = $sformatf("MODIFY_QUERY_%0d", query_case);
      mem = rdma_mock_host_mem::type_id::create({label, "_mem"});
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq,
                                  executor, binding, pd, cq);
      create_req = make_request({label, "_create"}, binding, pd, cq,
                                RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), create_req,
                             900 + query_case * 10, qp, result);
      modify_req = rdma_modify_qp_req::type_id::create({label, "_init"});
      modify_req.owner = binding.make_handle();
      modify_req.qp_h = rdma_clone_handle_value(qp.handle, {label, "_qp"});
      modify_req.new_state = RDMA_QPS_INIT;
      executor.modify_locked(binding, binding.make_handle(), modify_req,
                             901 + query_case * 10, qp, result);
      modify_req.new_state = RDMA_QPS_RTR;
      modify_req.destination_qpn_valid = 1'b1;
      modify_req.destination_qpn = 24'h23456;
      cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
      executor.modify_locked(binding, binding.make_handle(), modify_req,
                             902 + query_case * 10, qp, result);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.lookup_recovery(result.resource_h, recovery));
      if (recovery == null || recovery.qp_recovery == null ||
          recovery.qp_recovery.query_mapping == null) begin
        `uvm_error(label, "ambiguous MODIFY did not retain query mapping")
        continue;
      end
      if (query_case == 0)
        query_qpc = recovery.qp_recovery.candidate_qpc;
      else if (query_case == 1)
        query_qpc = recovery.qp_recovery.prior_qpc;
      else begin
        cloned = recovery.qp_recovery.candidate_qpc.clone();
        if (cloned == null || !$cast(query_qpc, cloned)) begin
          `uvm_error(label, "failed to clone MODIFY neither image")
          continue;
        end
        query_qpc.pkey ^= 16'h0001;
      end
      status = rdma_qp_encode_query_bytes(query_qpc, query_bytes);
      if (status == null || !status.ok() || query_bytes.size() != 512 ||
          mem.write(recovery.qp_recovery.query_mapping, 0, query_bytes) == null)
        `uvm_error(label, "failed to seed complete QPC query image")
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              903 + query_case * 10, recovery_result);
      status = recovery_result == null ? null : recovery_result.status;
      void'(manager.lookup(result.resource_h, resource));
      if (query_case == 0) begin
        if (status == null || !status.ok() || resource == null ||
            resource.state != RDMA_RESOURCE_ACTIVE) `uvm_error(label,
          "candidate QPC query did not publish ACTIVE QP")
        else if (!$cast(qp, resource) || qp.qp_state != RDMA_QPS_RTR)
          `uvm_error(label, "candidate QPC query restored wrong state")
      end
      else if (query_case == 1) begin
        if (status == null || !status.ok() || resource == null ||
            resource.state != RDMA_RESOURCE_ACTIVE) `uvm_error(label,
          "prior QPC query did not restore ACTIVE QP")
        else if (!$cast(qp, resource) || qp.qp_state != RDMA_QPS_INIT)
          `uvm_error(label, "prior QPC query restored wrong semantic state")
      end
      else if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
               resource == null || resource.state != RDMA_RESOURCE_ERROR)
        `uvm_error(label, "neither QPC query did not remain fail-closed")
    end
  endtask

  // CREATE ambiguity is resolved by an authenticated presence query.  A
  // present image runs the destroy recipe; a terminal query failure skips all
  // hardware cleanup and releases only local authorities.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_create_presence_query）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_create_presence_query();
    for (int unsigned query_case = 0; query_case < 3; query_case++) begin
      string label;
      rdma_qp_scripted_query_host_mem mem;
      rdma_function_binding binding;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req create_req;
      rdma_qp qp;
      rdma_control_result result;
      rdma_control_result recovery_result;
      rdma_recovery_record recovery;
      rdma_qpc_model query_qpc;
      uvm_object cloned;
      byte query_bytes[];
      bit [7:0] opcodes[$];
      bit [7:0] expected[$];
      rdma_status status;

      label = $sformatf("CREATE_PRESENCE_%0d", query_case);
      mem = rdma_qp_scripted_query_host_mem::type_id::create({label, "_mem"});
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq,
                                  executor, binding, pd, cq);
      cmq.timeout_opcode(XTR_V1_OP_QPC_CREATE);
      create_req = make_request({label, "_create"}, binding, pd, cq,
                                RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), create_req,
                             920 + query_case, qp, result);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.lookup_recovery(result.resource_h, recovery));
      if (recovery == null || recovery.qp_recovery == null ||
          recovery.qp_recovery.candidate_qpc == null) begin
        `uvm_error(label, "ambiguous CREATE did not retain candidate QPC")
        continue;
      end
      if (query_case == 0) begin
        query_qpc = recovery.qp_recovery.candidate_qpc;
        status = rdma_qp_encode_query_bytes(query_qpc, query_bytes);
        if (status == null || !status.ok()) begin
          `uvm_error(label, "failed to encode CREATE presence image")
          continue;
        end
        mem.script_query_image(query_bytes);
      end
      else if (query_case == 1)
        cmq.fail_opcode(XTR_V1_OP_QPC_QUERY,
          rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                            "QP context is absent"));
      else begin
        cloned = recovery.qp_recovery.candidate_qpc.clone();
        if (cloned == null || !$cast(query_qpc, cloned) ||
            query_qpc.qp_h == null) begin
          `uvm_error(label, "failed to clone CREATE wrong-QPN image")
          continue;
        end
        query_qpc.qp_h.object_id++;
        status = rdma_qp_encode_query_bytes(query_qpc, query_bytes);
        if (status == null || !status.ok()) begin
          `uvm_error(label, "failed to encode CREATE wrong-QPN image")
          continue;
        end
        mem.script_query_image(query_bytes);
      end
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              922 + query_case, recovery_result);
      cmq.get_opcodes(opcodes);
      status = recovery_result == null ? null : recovery_result.status;
      if (query_case == 0) begin
        expected = '{XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_QUERY,
                     XTR_V1_OP_QPC_MODIFY, XTR_V1_OP_OCC_FLUSH,
                     XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_OCC_FLUSH,
                     XTR_V1_OP_QPC_DELETE};
        if (status == null || !status.ok() || opcodes != expected ||
            mem.live_allocations() != 0 || contexts.release_call_count != 1)
          `uvm_error(label, "present CREATE query did not run destroy recipe")
      end
      else if (query_case == 1) begin
        expected = '{XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_QUERY};
        if (status == null || !status.ok() || opcodes != expected ||
            mem.live_allocations() != 0 || contexts.release_call_count != 1)
          `uvm_error(label, "absent CREATE query did not run local cleanup")
      end
      else begin
        expected = '{XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_QUERY};
        if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
            opcodes != expected || mem.live_allocations() == 0)
          `uvm_error(label, "wrong-QPN CREATE query was accepted")
      end
    end
  endtask

  // DELETE ambiguity uses the same presence proof, but a present QPC must
  // retry DELETE while an absent QPC must mark DELETE complete and never retry.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_delete_presence_query）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_delete_presence_query();
    for (int unsigned query_case = 0; query_case < 2; query_case++) begin
      string label;
      rdma_qp_scripted_query_host_mem mem;
      rdma_function_binding binding;
      rdma_resource_manager manager;
      rdma_mock_context_backing contexts;
      rdma_mock_cmq_port cmq;
      rdma_qp_lifecycle_executor executor;
      rdma_pd pd;
      rdma_cq cq;
      rdma_create_qp_req create_req;
      rdma_destroy_resource_req destroy_req;
      rdma_qp qp;
      rdma_control_result result;
      rdma_control_result recovery_result;
      rdma_recovery_record recovery;
      rdma_qpc_model query_qpc;
      byte query_bytes[];
      bit [7:0] opcodes[$];
      bit [7:0] expected[$];
      rdma_status status;
      rdma_resource resource;

      label = $sformatf("DELETE_PRESENCE_%0d", query_case);
      mem = rdma_qp_scripted_query_host_mem::type_id::create({label, "_mem"});
      manager = rdma_resource_manager::type_id::create({label, "_manager"});
      contexts = rdma_mock_context_backing::type_id::create({label, "_contexts"});
      cmq = rdma_mock_cmq_port::type_id::create({label, "_cmq"});
      executor = rdma_qp_lifecycle_executor::type_id::create({label, "_executor"});
      setup_custom_qp_environment(label, mem, manager, contexts, cmq, executor,
                                  binding, pd, cq);
      create_req = make_request({label, "_create"}, binding, pd, cq,
                                RDMA_TRANSPORT_RC);
      executor.create_locked(binding, binding.make_handle(), create_req,
                             930 + query_case, qp, result);
      destroy_req = rdma_destroy_resource_req::type_id::create({label, "_destroy"});
      destroy_req.owner = binding.make_handle();
      destroy_req.target_h = rdma_clone_handle_value(qp.handle, {label, "_target"});
      cmq.timeout_opcode(XTR_V1_OP_QPC_DELETE);
      executor.destroy_locked(binding, binding.make_handle(), destroy_req,
                              932 + query_case, result);
      recovery = null;
      if (result != null && result.resource_h != null)
        void'(manager.lookup_recovery(result.resource_h, recovery));
      if (recovery == null || recovery.qp_recovery == null ||
          recovery.qp_recovery.prior_qpc == null) begin
        `uvm_error(label, "ambiguous DELETE did not retain prior QPC")
        continue;
      end
      if (query_case == 0) begin
        query_qpc = recovery.qp_recovery.prior_qpc;
        status = rdma_qp_encode_query_bytes(query_qpc, query_bytes);
        if (status == null || !status.ok()) begin
          `uvm_error(label, "failed to encode DELETE presence image")
          continue;
        end
        mem.script_query_image(query_bytes);
      end
      else
        cmq.fail_opcode(XTR_V1_OP_QPC_QUERY,
          rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                            "QP context is absent"));
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              934 + query_case, recovery_result);
      cmq.get_opcodes(opcodes);
      status = recovery_result == null ? null : recovery_result.status;
      expected = '{XTR_V1_OP_QPC_CREATE, XTR_V1_OP_QPC_MODIFY,
                   XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_OCC_FLUSH,
                   XTR_V1_OP_OCC_FLUSH, XTR_V1_OP_QPC_DELETE,
                   XTR_V1_OP_QPC_QUERY};
      if (query_case == 0) expected.push_back(XTR_V1_OP_QPC_DELETE);
      if (status == null || !status.ok() || opcodes != expected ||
          mem.live_allocations() != 0 || contexts.release_call_count != 1 ||
          manager.lookup(result.resource_h, resource) == null || resource != null)
        `uvm_error(label, "DELETE presence query did not finish exactly once")
    end
  endtask

  // An ambiguous QPC_CREATE must enter the QP recovery dispatcher.  Until
  // reconciliation produces terminal evidence, recovery remains fail-closed.
  // It may issue one authenticated QPC_QUERY probe, but must not retry the
  // original CREATE side effect.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ambiguous_create_recovery_dispatch）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ambiguous_create_recovery_dispatch();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_output_fault_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    int unsigned calls_before;

    mem = rdma_mock_host_mem::type_id::create("create_recovery_mem");
    manager = rdma_resource_manager::type_id::create("create_recovery_manager");
    contexts = rdma_mock_context_backing::type_id::create("create_recovery_contexts");
    cmq = rdma_qp_output_fault_cmq::type_id::create("create_recovery_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("create_recovery_executor");
    setup_custom_qp_environment("create_recovery", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    cmq.timeout_opcode(XTR_V1_OP_QPC_CREATE);
    create_req = make_request("create_recovery_req", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 880,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    calls_before = cmq.calls.size();
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            881, recovery_result);
    if (result == null || result.resource_h == null || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.intent != RDMA_QP_RECOVER_CREATE_ROLLBACK ||
        recovery_result == null || recovery_result.status == null ||
        recovery_result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !recovery_result.recovery_required ||
        cmq.calls.size() != calls_before + 1 ||
        cmq.calls[calls_before] == null ||
        cmq.calls[calls_before].opcode != XTR_V1_OP_QPC_QUERY)
      `uvm_error("QP_CREATE_RECOVERY_DISPATCH",
                 $sformatf("ambiguous create was not dispatched fail-closed result=%p status=%s resource=%p recovery=%p calls=%0d",
                           result, result == null || result.status == null ? "null" : result.status.convert2string(),
                           result == null ? null : result.resource_h, recovery,
                           cmq.calls.size()))
  endtask

  // A terminal CREATE failure proves that no QP context was installed.  The
  // recovery recipe must therefore skip every hardware destroy command and
  // release the retained staging/context/backing authorities exactly once.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ambiguous_create_terminal_failure_cleanup）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ambiguous_create_terminal_failure_cleanup();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    int unsigned releases_before;
    int unsigned release_count;
    int unsigned calls_before;
    rdma_status status;
    rdma_resource resource;

    mem = rdma_mock_host_mem::type_id::create("create_failure_mem");
    manager = rdma_resource_manager::type_id::create("create_failure_manager");
    contexts = rdma_mock_context_backing::type_id::create("create_failure_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("create_failure_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("create_failure_executor");
    setup_custom_qp_environment("create_failure", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    cmq.timeout_opcode(XTR_V1_OP_QPC_CREATE);
    create_req = make_request("create_failure_req", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 882,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_ticket == null) begin
      `uvm_error("QP_CREATE_FAILURE_SETUP",
                 $sformatf("ambiguous create failure did not retain its ticket result=%p status=%s resource=%p recovery=%p calls=%0d",
                           result, result == null || result.status == null ? "null" : result.status.convert2string(),
                           result == null ? null : result.resource_h, recovery,
                           cmq.calls.size()))
      return;
    end
    cmq.push_late_completion(recovery.qp_recovery.ambiguous_ticket,
                             rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                               "terminal create failure"));
    releases_before = 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null && mem.calls[i].method_name == "release")
        releases_before++;
    calls_before = cmq.calls.size();
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            883, recovery_result);
    status = recovery_result == null ? null : recovery_result.status;
    if (status == null || !status.ok() ||
        recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        recovery_result.recovery_required ||
        mem.live_allocations() != 0 ||
        contexts.release_call_count != 1 || cmq.calls.size() != calls_before ||
        manager.lookup(result.resource_h, resource) == null ||
        resource != null)
      `uvm_error("QP_CREATE_FAILURE_RECOVERY",
                 $sformatf("terminal create failure did not perform local cleanup status=%0d message=%s final=%0d required=%0b live=%0d ctx=%0d calls=%0d resource=%p",
                           status == null ? -1 : status.code,
                           status == null ? "" : status.message,
                           recovery_result == null ? -1 : recovery_result.final_resource_state,
                           recovery_result == null ? 1'b1 : recovery_result.recovery_required,
                           mem.live_allocations(), contexts.release_call_count,
                           cmq.calls.size(), resource))
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null && mem.calls[i].method_name == "release")
        release_count++;
    if (release_count != releases_before + 5)
      `uvm_error("QP_CREATE_FAILURE_RELEASES",
                 $sformatf("terminal create failure release count mismatch got=%0d expected=%0d",
                           release_count, releases_before + 5))
    // A second recovery attempt must not repeat physical releases after the
    // identity has been finalized.
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            884, recovery_result);
    release_count = 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null && mem.calls[i].method_name == "release")
        release_count++;
    if (release_count != releases_before + 5 || cmq.calls.size() != calls_before)
      `uvm_error("QP_CREATE_FAILURE_ONCE",
                 $sformatf("terminal create failure cleanup was repeated releases=%0d calls=%0d",
                           release_count, cmq.calls.size()))
  endtask

  // A terminal CREATE success proves that hardware contains the QP.  Recovery
  // must run the canonical OCC/QPC_DELETE destroy recipe before releasing
  // software authorities and finalizing the ERROR incarnation.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ambiguous_create_terminal_success_destroy）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ambiguous_create_terminal_success_destroy();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;
    bit [7:0] opcodes[$];
    bit [7:0] expected[$];
    rdma_status status;

    mem = rdma_mock_host_mem::type_id::create("create_success_mem");
    manager = rdma_resource_manager::type_id::create("create_success_manager");
    contexts = rdma_mock_context_backing::type_id::create("create_success_contexts");
    cmq = rdma_mock_cmq_port::type_id::create("create_success_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("create_success_executor");
    setup_custom_qp_environment("create_success", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    cmq.timeout_opcode(XTR_V1_OP_QPC_CREATE);
    create_req = make_request("create_success_req", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 885,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_ticket == null) begin
      `uvm_error("QP_CREATE_SUCCESS_SETUP",
                 $sformatf("ambiguous create success did not retain its ticket result=%p status=%s resource=%p recovery=%p calls=%0d",
                           result, result == null || result.status == null ? "null" : result.status.convert2string(),
                           result == null ? null : result.resource_h, recovery,
                           cmq.calls.size()))
      return;
    end
    cmq.push_late_completion(recovery.qp_recovery.ambiguous_ticket,
                             rdma_status::success());
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                            886, recovery_result);
    cmq.get_opcodes(opcodes);
    expected.push_back(XTR_V1_OP_QPC_CREATE);
    expected.push_back(XTR_V1_OP_QPC_MODIFY);
    expected.push_back(XTR_V1_OP_OCC_FLUSH);
    expected.push_back(XTR_V1_OP_OCC_FLUSH);
    expected.push_back(XTR_V1_OP_OCC_FLUSH);
    expected.push_back(XTR_V1_OP_QPC_DELETE);
    status = recovery_result == null ? null : recovery_result.status;
    if (status == null || !status.ok() ||
        recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        recovery_result.recovery_required || opcodes != expected ||
        mem.live_allocations() != 0 || contexts.release_call_count != 1 ||
        manager.lookup(result.resource_h, resource) == null ||
        resource != null)
      `uvm_error("QP_CREATE_SUCCESS_RECOVERY",
                 $sformatf("terminal create success did not run destroy recipe status=%0d message=%s final=%0d required=%0b opcodes=%p expected=%p live=%0d ctx=%0d resource=%p",
                           status == null ? -1 : status.code,
                           status == null ? "" : status.message,
                           recovery_result == null ? -1 : recovery_result.final_resource_state,
                           recovery_result == null ? 1'b1 : recovery_result.recovery_required,
                           opcodes, expected, mem.live_allocations(),
                           contexts.release_call_count, resource))
  endtask

  // A definitive CMQ failure followed by a failed staging release has no
  // ticket, but the staging mapping must remain durable recovery authority.
  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ticketless_definitive_modify_recovery）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ticketless_definitive_modify_recovery();
    rdma_qp_boundary_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_qp_ticketless_modify_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;

    mem = rdma_qp_boundary_host_mem::type_id::create("ticketless_def_mem");
    manager = rdma_resource_manager::type_id::create("ticketless_def_manager");
    contexts = rdma_mock_context_backing::type_id::create("ticketless_def_contexts");
    cmq = rdma_qp_ticketless_modify_cmq::type_id::create("ticketless_def_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("ticketless_def_executor");
    setup_custom_qp_environment("ticketless_def", mem, manager, contexts,
                                cmq, executor, binding, pd, cq);
    create_req = make_request("ticketless_def_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 870,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("ticketless_def_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "ticketless def QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 871,
                           qp, result);
    mem.mode = "timeout_staging_release_before";
    cmq.fail_opcode(XTR_V1_OP_QPC_MODIFY,
                    rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                      "ticketless definitive modify failure"));
    modify_req.new_state = RDMA_QPS_RTR;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 872,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (qp != null || result == null || !result.recovery_required ||
        result.status == null || result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket != null ||
        !recovery.qp_recovery.has_pending_hardware_step ||
        recovery.qp_recovery.staging_mapping == null)
      `uvm_error("QP_TICKETLESS_DEFINITIVE",
                 "ticketless definitive modify lost recovery authority")
  endtask

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ticketless_publication_modify_recovery）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ticketless_publication_modify_recovery();
    rdma_qp_publication_fault_manager manager;
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_mock_context_backing contexts;
    rdma_qp_ticketless_modify_cmq cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_recovery_record recovery;

    mem = rdma_mock_host_mem::type_id::create("ticketless_pub_mem");
    manager = rdma_qp_publication_fault_manager::type_id::create(
      "ticketless_pub_manager");
    contexts = rdma_mock_context_backing::type_id::create("ticketless_pub_contexts");
    cmq = rdma_qp_ticketless_modify_cmq::type_id::create("ticketless_pub_cmq");
    executor = rdma_qp_lifecycle_executor::type_id::create("ticketless_pub_executor");
    setup_custom_qp_environment("ticketless_pub", mem, manager, contexts, cmq,
                                executor, binding, pd, cq);
    create_req = make_request("ticketless_pub_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 873,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("ticketless_pub_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "ticketless pub QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 874,
                           qp, result);
    manager.fail_commit = 1'b1;
    modify_req.new_state = RDMA_QPS_RTR;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 875,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (qp != null || result == null || !result.recovery_required ||
        result.status == null || result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        recovery == null || recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket != null ||
        !recovery.qp_recovery.has_pending_hardware_step ||
        recovery.qp_recovery.candidate_qpc == null ||
        recovery.qp_recovery.staging_mapping != null)
      `uvm_error("QP_TICKETLESS_PUBLICATION",
                 "ticketless publication failure lost ERROR recovery authority")
  endtask

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ambiguous_modify_recovery）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ambiguous_modify_recovery();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_modify_qp_req modify_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_status status;
    rdma_resource resource;
    rdma_recovery_record recovery;
    rdma_qp_state_e qp_state;

    mem = rdma_mock_host_mem::type_id::create("recovery_mem");
    setup_qp_environment("recovery", mem, binding, manager,
                         contexts, cmq, executor, pd, cq);
    create_req = make_request("recovery_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 800,
                           qp, result);
    modify_req = rdma_modify_qp_req::type_id::create("recovery_modify_init");
    modify_req.owner = binding.make_handle();
    modify_req.qp_h = rdma_clone_handle_value(qp.handle, "recovery QP");
    modify_req.new_state = RDMA_QPS_INIT;
    executor.modify_locked(binding, binding.make_handle(), modify_req, 801,
                           qp, result);
    modify_req.new_state = RDMA_QPS_RTR;
    modify_req.destination_qpn_valid = 1'b1;
    modify_req.destination_qpn = 24'h23456;
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.modify_locked(binding, binding.make_handle(), modify_req, 802,
                           qp, result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (qp != null || result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.query_mapping == null)
      `uvm_error("QP_RECOVERY_AMBIGUOUS", "ambiguous modify did not retain recovery authority")

    if (cmq.calls.size() != 2 || cmq.calls[1] == null ||
        cmq.calls[1].ticket == null) begin
      `uvm_error("QP_RECOVERY_TICKET", "ambiguous modify did not retain a ticket")
    end
    else begin
      cmq.push_late_completion(cmq.calls[1].ticket, rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              803, recovery_result);
      status = manager.lookup(result.resource_h, resource);
      qp_state = RDMA_QPS_RESET;
      if (resource != null)
        qp_state = $cast(qp, resource) ? qp.qp_state : RDMA_QPS_RESET;
      if (recovery_result == null || recovery_result.status == null ||
          !recovery_result.status.ok() || status == null || !status.ok() ||
          resource == null || resource.state != RDMA_RESOURCE_ACTIVE ||
          qp_state != RDMA_QPS_RTR)
        `uvm_error("QP_RECOVERY_RECONCILE", "ambiguous modify was not reconciled")
    end
  endtask

  // 功能：检查输入值、身份字段和当前生命周期约束，给出一致性判断或状态结果（接口 check_ambiguous_destroy_recovery）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task automatic check_ambiguous_destroy_recovery();
    rdma_mock_host_mem mem;
    rdma_function_binding binding;
    rdma_resource_manager manager;
    rdma_mock_context_backing contexts;
    rdma_mock_cmq_port cmq;
    rdma_qp_lifecycle_executor executor;
    rdma_pd pd;
    rdma_cq cq;
    rdma_create_qp_req create_req;
    rdma_destroy_resource_req destroy_req;
    rdma_qp qp;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_resource resource;
    rdma_status lookup_status;

    mem = rdma_mock_host_mem::type_id::create("destroy_recovery_mem");
    setup_qp_environment("destroy_recovery", mem, binding, manager,
                         contexts, cmq, executor, pd, cq);
    create_req = make_request("destroy_recovery_create", binding, pd, cq,
                              RDMA_TRANSPORT_RC);
    executor.create_locked(binding, binding.make_handle(), create_req, 850,
                           qp, result);
    destroy_req = rdma_destroy_resource_req::type_id::create(
      "destroy_recovery_destroy");
    destroy_req.owner = binding.make_handle();
    destroy_req.target_h = rdma_clone_handle_value(
      qp.handle, "destroy recovery target");
    cmq.timeout_opcode(XTR_V1_OP_QPC_MODIFY);
    executor.destroy_locked(binding, binding.make_handle(), destroy_req, 851,
                            result);
    recovery = null;
    if (result != null && result.resource_h != null)
      void'(manager.lookup_recovery(result.resource_h, recovery));
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED || recovery == null ||
        recovery.qp_recovery == null ||
        recovery.qp_recovery.ambiguous_operation != RDMA_QP_AMBIG_MODIFY ||
        recovery.qp_recovery.ambiguous_ticket == null)
      `uvm_error("QP_DESTROY_RECOVERY_SETUP",
                 "destroy timeout did not retain ERROR transition authority")
    else begin
      cmq.push_late_completion(recovery.qp_recovery.ambiguous_ticket,
                               rdma_status::success());
      recovery_result = null;
      executor.recover_locked(binding, binding.make_handle(), result.resource_h,
                              852, recovery_result);
      lookup_status = manager.lookup(result.resource_h, resource);
      if (recovery_result == null || recovery_result.status == null ||
          !recovery_result.status.ok() || lookup_status == null ||
          lookup_status.code != RDMA_SC_INVALID_STATE || resource != null)
        `uvm_error("QP_DESTROY_RECOVERY",
                   "destroy timeout recovery did not finalize the QP")
    end
  endtask
endclass
