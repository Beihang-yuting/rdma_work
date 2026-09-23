// 目录：测试层 unit/rdma_queue_recovery_test.sv。
// 职责：验证 rdma_queue_recovery_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_recovery_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Focused recovery coverage for the queue lifecycle executor.  The broader
// lifecycle test owns the fixture builders; this test deliberately exercises
// the public recovery facade so that queue ERROR records cannot accidentally
// fall through the MR-only recovery path.
class rdma_queue_recovery_test extends rdma_queue_lifecycle_test;
  `uvm_component_utils(rdma_queue_recovery_test)

  // Build a status with the same identity envelope that the real CMQ engine
  // attaches to a completion.  Recovery must not trust a status whose
  // command/function identity differs from the ticket being reconciled.
  // 功能：在 rdma_queue_recovery_test 中，query_status 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：ticket（输入）、code（输入）、hardware_ecode（输入）；query_status 读取 ticket、code、hardware_ecode 并使用字段 status、status.source_engine、status.function_uid、status.generation、status.resource_id、status.command_id、status.hardware_code_valid、status.hardware_code；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：query_status 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic rdma_status query_status(
    rdma_cmq_ticket ticket,
    rdma_status_code_e code,
    bit [7:0] hardware_ecode
  );
    rdma_status status;

    status = rdma_status::make(code, "query test status");
    if (ticket == null || ticket.function_h == null || ticket.cmq_h == null)
      return status;
    status.source_engine = RDMA_ENGINE_CMQ;
    status.function_uid = ticket.function_h.function_uid;
    status.generation = ticket.function_h.generation;
    status.resource_id = ticket.cmq_h.object_id;
    status.command_id = ticket.command_id;
    if (hardware_ecode != 8'h00) begin
      status.hardware_code_valid = 1'b1;
      status.hardware_code = {24'h0, hardware_ecode};
    end
    return status;
  endfunction

  // 功能：make_query_raw 创建独立的 rdma_hw_image；根据 name、ticket、payload 设置字段 image、i、qword0、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、ticket（输入）、payload（输入）；make_query_raw 读取 name、ticket、payload 并使用字段 image、qword0、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：make_query_raw 的结果直接由 return image 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_image make_query_raw(
    string name,
    rdma_cmq_ticket ticket,
    rdma_hw_cmq_completion payload
  );
    rdma_hw_image image;
    bit [63:0] qword0;

    image = rdma_hw_image::type_id::create(name);
    for (int unsigned i = 0; i < 64; i++)
      image.bytes.push_back(8'h00);
    qword0 = '0;
    qword0[63] = payload.owner;
    qword0[45] = payload.wrap;
    qword0[44:40] = payload.wqe_index;
    qword0[39:32] = payload.opcode;
    qword0[31:24] = payload.command_ecode;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[i] = qword0[63 - (i * 8) -: 8];
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = ticket == null || ticket.function_h == null ?
      1 : ticket.function_h.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：make_query_completion 创建独立的 rdma_cmq_completion；根据 name、policy、queue、ticket、status、query_opcode、ecode、owner、wqe_index、wrap、use_canonical_payload 设置字段 completion、offset、length、payload、payload.owner、payload.opcode、payload.command_ecode、payload.wqe_index、payload.wrap、build_status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、policy（输入）、queue（输入）、ticket（输入）、status（输入）、query_opcode（输入）、ecode（输入）、owner（输入）、wqe_index（输入）、wrap（输入）、use_canonical_payload（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_query_completion 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_cmq_completion make_query_completion(
    string name,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource queue,
    rdma_cmq_ticket ticket,
    rdma_status status,
    bit [7:0] query_opcode,
    bit [7:0] ecode,
    bit owner,
    int unsigned wqe_index,
    bit wrap,
    bit use_canonical_payload = 1'b1
  );
    rdma_cmq_completion completion;
    rdma_hw_cmq_completion payload;
    rdma_hw_model model;
    byte unsigned slot_image[];
    byte unsigned shadow_image[];
    int unsigned offset;
    int unsigned length;
    rdma_status build_status;

    completion = null;
    if (policy == null || queue == null || ticket == null || status == null)
      return null;
    case (queue.resource_kind())
      RDMA_RESOURCE_CQ: begin offset = 8;  length = 56; end
      default:           begin offset = 16; length = 32; end
    endcase
    payload = rdma_hw_cmq_completion::type_id::create(
      {name, "_payload"});
    payload.owner = owner;
    payload.opcode = query_opcode;
    payload.command_ecode = ecode;
    payload.wqe_index = wqe_index[4:0];
    payload.wrap = wrap;
    if (use_canonical_payload) begin
      build_status = policy.build_create_context(
        queue, queue.queue_plan, model, slot_image, shadow_image
      );
      if (build_status == null || !build_status.ok() ||
          slot_image.size() != 64 || offset + length > slot_image.size())
        return null;
      payload.object_payload = new[length];
      for (int unsigned i = 0; i < length; i++)
        payload.object_payload[i] = slot_image[offset + i];
    end
    else
      payload.object_payload = new[0];
    completion = rdma_cmq_completion::type_id::create(name);
    completion.ticket = rdma_cmq_clone_ticket_value(ticket,
                                                      "query test ticket");
    completion.status = rdma_cmq_clone_status_value(status);
    completion.decoded_response = payload;
    completion.raw_cqe = make_query_raw({name, "_raw"}, ticket, payload);
    if (completion.ticket == null || completion.status == null ||
        completion.raw_cqe == null)
      return null;
    return completion;
  endfunction

  // 功能：将 rhs 中 rdma_queue_recovery_test 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、name（输入）；clone_query_completion 读取 source、name 并使用字段 copy、cloned；函数返回 rdma_cmq_completion，不取得调用方资源所有权。
  // 失败/边界：clone_query_completion 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_cmq_completion clone_query_completion(
    rdma_cmq_completion source,
    string name
  );
    uvm_object cloned;
    rdma_cmq_completion copy;

    copy = null;
    if (source == null)
      return null;
    cloned = source.clone();
    if (cloned != null)
      void'($cast(copy, cloned));
    return copy;
  endfunction

  // 功能：在 rdma_queue_recovery_test 中，query_result_is 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：label（输入）、policy（输入）、queue（输入）、completion（输入）、expected_presence（输入）、expected_conclusive（输入）；输入
  //   handle/key/cursor 用于选择读取范围；返回值或 output 为 detached 快照，读取不取得外部资源所有权。
  // 失败/边界：query_result_is 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic bit query_result_is(
    string label,
    rdma_queue_lifecycle_policy policy,
    rdma_queue_resource queue,
    rdma_cmq_completion completion,
    rdma_hw_presence_e expected_presence,
    bit expected_conclusive
  );
    rdma_hw_presence_e presence;
    bit conclusive;
    rdma_status status;

    presence = RDMA_HW_PRESENCE_UNKNOWN;
    conclusive = 1'b0;
    status = policy.classify_query_completion(queue, completion, presence,
                                              conclusive);
    if (status == null || !status.ok() || presence != expected_presence ||
        conclusive != expected_conclusive) begin
      `uvm_error(label, $sformatf(
        "query classification mismatch: status=%s presence=%s conclusive=%0b",
        status == null ? "null" : status.code.name(), presence.name(),
        conclusive))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // A compact real-resource fixture used by the classifier tests.  The
  // inherited fixture allocates an authoritative queue plan, so typed QUERY
  // decoding exercises the same context codecs used by recovery.
  // 功能：make_query_fixture 按 label 和 kind 组装完整的 Query/recovery fixture，创建 binding、manager、Host-memory、上下文 backing、CMQ、trace、executor、queue 及依赖对象。
  // 输入/输出及副作用：label（输入）、kind（输入）、binding（输出）、manager（输出）、mem（输出）、context_backing（输出）、cmq（输出）、trace（输出）、executor（输出）、queue（输出）、create_result（输出）、ceq_dependency（输出）、pd_dependency（输出）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_query_fixture 失败或超时通过 binding、manager、mem、context_backing、cmq、trace、executor、queue、create_result、ceq_dependency、pd_dependency 明确发布；该路径不隐式重试，也不转移未声明资源。
  task automatic make_query_fixture(
    string label,
    rdma_resource_kind_e kind,
    output rdma_function_binding binding,
    output rdma_fault_inject_resource_manager manager,
    output rdma_queue_destroy_trace_mem mem,
    output rdma_queue_destroy_trace_context context_backing,
    output rdma_queue_destroy_trace_cmq cmq,
    output rdma_mock_call_trace trace,
    output rdma_queue_lifecycle_executor executor,
    output rdma_queue_resource queue,
    output rdma_control_result create_result,
    output rdma_ceq ceq_dependency,
    output rdma_pd pd_dependency
  );
    create_destroy_fixture(label, kind, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
  endtask

  // 功能：在测试辅助 rdma_queue_recovery_test.check_query_classifier_matrix 中构造或驱动“query classifier matrix”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_query_classifier_matrix();
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_ceq ceq;
    rdma_ceq_lifecycle_policy policy;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion ignored_completion;
    rdma_cmq_completion completion;
    rdma_cmq_completion copy;
    rdma_hw_cmq_completion payload;
    rdma_status status;

    label = "QUERY_CLASSIFIER";
    make_query_fixture({label, "_FIXTURE"}, RDMA_RESOURCE_CEQ, binding,
                       manager, mem, context_backing, cmq, trace, executor,
                       queue, create_result, ceq_dependency, pd_dependency);
    if (!$cast(ceq, queue)) begin
      `uvm_error(label, "classifier fixture is not a CEQ")
      return;
    end
    policy = rdma_ceq_lifecycle_policy::type_id::create(
      {label, "_policy"});
    status = policy.build_object_command(RDMA_OP_CEQC_QUERY,
                                         binding.make_handle(), ceq, 100ns,
                                         command);
    expect_status({label, "_BUILD"}, status, RDMA_SC_OK);
    cmq.execute(command, ticket, ignored_completion, status);
    expect_status({label, "_TICKET"}, status, RDMA_SC_OK);
    if (ticket == null) begin
      `uvm_error(label, "classifier query ticket was not created")
      return;
    end

    completion = make_query_completion(
      {label, "_VALID"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_OK, 8'h00), RDMA_OP_CEQC_QUERY,
      8'h00, !((ticket.slot_sequence / 32) & 1'b1), ticket.sq_index,
      ticket.sq_wrap
    );
    if (completion == null || !$cast(payload, completion.decoded_response)) begin
      `uvm_error(label, "valid typed QUERY completion could not be built")
      return;
    end
    query_result_is({label, "_TYPED_SUCCESS"}, policy, ceq, completion,
                    RDMA_HW_PRESENCE_PRESENT, 1'b1);

    // A whitelisted invalid-context ecode is absence evidence only when the
    // command status is non-OK.  In particular, an OK status paired with f7
    // must not be accepted as either PRESENT or ABSENT.
    copy = make_query_completion(
      {label, "_OK_WHITELIST"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_OK, RDMA_ECODE_EC_RCE_CEQC_INVLD),
      RDMA_OP_CEQC_QUERY, RDMA_ECODE_EC_RCE_CEQC_INVLD,
      payload.owner, ticket.sq_index, ticket.sq_wrap
    );
    query_result_is({label, "_OK_WHITELIST"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = make_query_completion(
      {label, "_ABSENT_WHITELIST"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR,
                   RDMA_ECODE_EC_RCE_CEQC_INVLD),
      RDMA_OP_CEQC_QUERY, RDMA_ECODE_EC_RCE_CEQC_INVLD,
      payload.owner, ticket.sq_index, ticket.sq_wrap
    );
    query_result_is({label, "_ABSENT_WHITELIST"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_ABSENT, 1'b1);

    // Every nonzero ecode outside the per-opcode absence whitelist remains
    // UNKNOWN, even if all context bytes decode as a valid typed object.
    copy = make_query_completion(
      {label, "_SRFQ_ECODE"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, 8'h7b),
      RDMA_OP_CEQC_QUERY, 8'h7b, payload.owner, ticket.sq_index,
      ticket.sq_wrap
    );
    query_result_is({label, "_SRFQ_ECODE"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = make_query_completion(
      {label, "_ARBITRARY_ECODE"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, 8'h55),
      RDMA_OP_CEQC_QUERY, 8'h55, payload.owner, ticket.sq_index,
      ticket.sq_wrap
    );
    query_result_is({label, "_ARBITRARY_ECODE"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);

    copy = clone_query_completion(completion, {label, "_TIMEOUT"});
    copy.status = query_status(copy.ticket, RDMA_SC_TIMEOUT, 8'h00);
    query_result_is({label, "_TIMEOUT"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = clone_query_completion(completion, {label, "_FAILURE"});
    copy.status = query_status(copy.ticket, RDMA_SC_UNKNOWN_HW_ERROR, 8'h44);
    if ($cast(payload, copy.decoded_response)) payload.command_ecode = 8'h44;
    query_result_is({label, "_FAILURE"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);

    // Mutating any authenticated completion field must invalidate typed
    // presence evidence.  The raw CQE remains the engine-authenticated
    // source for owner/opcode/index/wrap in these cases.
    copy = clone_query_completion(completion, {label, "_BAD_OPCODE"});
    if ($cast(payload, copy.decoded_response)) payload.opcode = 8'h12;
    query_result_is({label, "_BAD_OPCODE"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = clone_query_completion(completion, {label, "_BAD_INDEX"});
    if ($cast(payload, copy.decoded_response)) payload.wqe_index++;
    query_result_is({label, "_BAD_INDEX"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = clone_query_completion(completion, {label, "_BAD_WRAP"});
    if ($cast(payload, copy.decoded_response)) payload.wrap = ~payload.wrap;
    query_result_is({label, "_BAD_WRAP"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = clone_query_completion(completion, {label, "_BAD_OWNER"});
    if ($cast(payload, copy.decoded_response)) payload.owner = ~payload.owner;
    query_result_is({label, "_BAD_OWNER"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = clone_query_completion(completion, {label, "_BAD_FUNCTION"});
    copy.ticket.function_h.function_uid++;
    query_result_is({label, "_BAD_FUNCTION"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);

    // Mutating raw and decoded owner together must still fail: the CQ owner
    // phase is independently authenticated from the ticket's SQ wrap (the
    // rdma CMQ starts with CQ owner=1 and toggles once per 32-slot cycle).
    copy = clone_query_completion(completion, {label, "_BAD_RAW_OWNER"});
    if ($cast(payload, copy.decoded_response)) begin
      payload.owner = ~payload.owner;
      copy.raw_cqe.bytes[0] ^= 8'h80;
    end
    query_result_is({label, "_BAD_RAW_OWNER"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
  endtask

  // Exercise each queue profile's opcode-specific absence policy directly.
  // These completions carry no context bytes, as real invalid-context QUERY
  // responses do; the classifier must rely on the authenticated ecode/status
  // pair and must keep SRFQ's 0x7b (and arbitrary nonzero ecodes) inconclusive.
  // 功能：在测试辅助 rdma_queue_recovery_test.check_query_absent_case 中构造或驱动“query absent case”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：label（输入）、kind（输入）、absent_ecode（输入）、unknown_ecode（输入）、expect_absent（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM
  //   assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_query_absent_case(
    string label,
    rdma_resource_kind_e kind,
    bit [7:0] absent_ecode,
    bit [7:0] unknown_ecode,
    bit expect_absent
  );
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_queue_lifecycle_policy policy;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion ignored_completion;
    rdma_cmq_completion completion;
    bit [7:0] query_opcode_value;
    bit owner;
    rdma_status status;

    case (kind)
      RDMA_RESOURCE_CQ: begin
        policy = rdma_cq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = RDMA_OP_CQC_QUERY;
      end
      RDMA_RESOURCE_SRQ: begin
        policy = rdma_srq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = RDMA_OP_SRFQC_QUERY;
      end
      RDMA_RESOURCE_CEQ: begin
        policy = rdma_ceq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = RDMA_OP_CEQC_QUERY;
      end
      RDMA_RESOURCE_AEQ: begin
        policy = rdma_aeq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = RDMA_OP_AEQC_QUERY;
      end
      default: begin
        `uvm_error(label, "unsupported queue kind in QUERY absence case")
        return;
      end
    endcase
    make_query_fixture(label, kind, binding, manager, mem, context_backing,
                       cmq, trace, executor, queue, create_result,
                       ceq_dependency, pd_dependency);
    status = policy.build_object_command(query_opcode_value,
                                         binding.make_handle(), queue, 100ns,
                                         command);
    expect_status({label, "_BUILD"}, status, RDMA_SC_OK);
    cmq.execute(command, ticket, ignored_completion, status);
    expect_status({label, "_TICKET"}, status, RDMA_SC_OK);
    if (ticket == null) begin
      `uvm_error(label, "absence QUERY ticket was not created")
      return;
    end
    owner = !ticket.sq_wrap;
    completion = make_query_completion(
      {label, expect_absent ? "_ABSENT" : "_NONZERO"}, policy, queue, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, absent_ecode),
      query_opcode_value, absent_ecode, owner, ticket.sq_index,
      ticket.sq_wrap, 1'b0);
    query_result_is({label, expect_absent ? "_ABSENT" : "_NONZERO"}, policy,
                    queue, completion,
                    expect_absent ? RDMA_HW_PRESENCE_ABSENT :
                      RDMA_HW_PRESENCE_UNKNOWN,
                    expect_absent);

    completion = make_query_completion(
      {label, "_UNKNOWN"}, policy, queue, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, unknown_ecode),
      query_opcode_value, unknown_ecode, owner, ticket.sq_index,
      ticket.sq_wrap, 1'b0);
    query_result_is({label, "_UNKNOWN"}, policy, queue, completion,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
  endtask

  // 功能：在测试辅助 rdma_queue_recovery_test.check_query_profile_absence_matrix 中构造或驱动“query profile absence matrix”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_query_profile_absence_matrix();
    check_query_absent_case("QUERY_CQC_F3", RDMA_RESOURCE_CQ,
                            RDMA_ECODE_EC_RCE_CQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_CEQC_F7", RDMA_RESOURCE_CEQ,
                            RDMA_ECODE_EC_RCE_CEQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_AEQC_FA", RDMA_RESOURCE_AEQ,
                            RDMA_ECODE_EC_RCE_AEQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_SRFQC_7B", RDMA_RESOURCE_SRQ,
                            8'hff, 8'h7b, 1'b0);
    check_query_absent_case("QUERY_SRFQC_ARBITRARY", RDMA_RESOURCE_SRQ,
                            8'hff, 8'h55, 1'b0);
  endtask

  // A QUERY can prove that the hardware object is absent before the
  // remaining CQ post-delete OCC barrier has completed.  Absence is not a
  // license to release local authority: recovery must retain ERROR and leave
  // every backing/context release pending until the barrier is terminal.
  // 功能：在测试辅助 rdma_queue_recovery_test.check_query_absent_before_cq_occ_barrier 中构造或驱动“query absent before cq occ
  //   barrier”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_query_absent_before_cq_occ_barrier();
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_pd pd_dependency;
    rdma_ceq ceq_dependency;
    rdma_recovery_record recovery;
    rdma_resource error_resource;
    rdma_cq cq;
    rdma_cq_lifecycle_policy policy;
    rdma_cmq_ticket query_ticket;
    rdma_cmq_completion absent_completion;
    rdma_status status;
    rdma_status flush_failure;
    bit barrier_pending;

    label = "RECOVERY_QUERY_ABSENT_OCC_BARRIER";
    create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    if (!$cast(cq, queue)) begin
      `uvm_error(label, "CQ barrier fixture did not produce a CQ")
      return;
    end

    // Return a non-OK/null outcome for DELETE without pre-submit proof.  The
    // queue remains ERROR with UNKNOWN hardware presence, so recovery issues
    // a typed QUERY before retrying the post-delete OCC barrier.
    cmq.nonok_null_without_proof = 1'b1;
    cmq.nonok_null_status = rdma_status::make(
      RDMA_SC_INVALID_STATE, "injected CQ delete outcome without proof");
    executor.destroy_locked(binding, binding.make_handle(),
                            make_destroy_request({label, "_destroy"},
                                                  binding, queue.handle),
                            64'd2300, result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_LOOKUP_AFTER_FLUSH_TIMEOUT"}, status,
                  RDMA_SC_OK);
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_ERROR_AFTER_FLUSH_TIMEOUT"}, status,
                  RDMA_SC_OK);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required || error_resource == null ||
        error_resource.state != RDMA_RESOURCE_ERROR ||
        recovery == null || recovery.ambiguous_ticket != null ||
        recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_DELETE ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label,
                 "ambiguous CQ delete did not retain ERROR authority")

    // Force QUERY itself through the ticket reconciliation path, where this
    // test can provide an authenticated invalid-context (ABSENT) completion.
    cmq.timeout_opcode(RDMA_OP_CQC_QUERY);
    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2301, recovery_result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_LOOKUP_AFTER_QUERY_TIMEOUT"}, status,
                  RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null ||
        recovery.ambiguous_ticket.opcode_key == null ||
        recovery.ambiguous_ticket.opcode_key.opcode != RDMA_OP_CQC_QUERY ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label, "ambiguous CQ QUERY lost durable no-release state")
    query_ticket = recovery.ambiguous_ticket;

    policy = rdma_cq_lifecycle_policy::type_id::create(
      {label, "_policy"});
    absent_completion = make_query_completion(
      {label, "_absent"}, policy, cq, query_ticket,
      query_status(query_ticket, RDMA_SC_UNKNOWN_HW_ERROR,
                   RDMA_ECODE_EC_RCE_CQC_INVLD),
      RDMA_OP_CQC_QUERY, RDMA_ECODE_EC_RCE_CQC_INVLD,
      !query_ticket.sq_wrap,
      query_ticket.sq_index, query_ticket.sq_wrap, 1'b0);
    if (absent_completion == null ||
        !query_result_is({label, "_CLASSIFY_ABSENT"}, policy, cq,
                         absent_completion, RDMA_HW_PRESENCE_ABSENT, 1'b1))
      `uvm_error(label, "CQ QUERY absence completion was not authenticated")
    cmq.script_reconcile(query_ticket, 1'b1, absent_completion,
                         rdma_status::success("late CQ QUERY absence"));

    // QUERY absence is conclusive, but the post-delete OCC barrier is
    // not.  A definitive OCC failure must retain ERROR and must not release
    // any local mapping, context, dependency, or reservation.
    flush_failure = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                      "CQ post-delete flush still failed");
    cmq.fail_opcode(RDMA_OP_OCC_FLUSH, flush_failure);
    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2302, recovery_result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_LOOKUP_AFTER_BARRIER_FAILURE"}, status,
                  RDMA_SC_OK);
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_ERROR_AFTER_BARRIER_FAILURE"}, status,
                  RDMA_SC_OK);
    barrier_pending = 1'b0;
    if (recovery != null && recovery.queue_plan != null)
      foreach (recovery.queue_plan.flush_targets[i])
        if (recovery.queue_plan.flush_targets[i] != null &&
            !recovery.queue_plan.flush_targets[i].flush_complete &&
            recovery.queue_plan.flush_targets[i].phase ==
              RDMA_QUEUE_FLUSH_POST_DELETE)
          barrier_pending = 1'b1;
    if (recovery_result == null || recovery_result.status == null ||
        recovery_result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !recovery_result.recovery_required || error_resource == null ||
        error_resource.state != RDMA_RESOURCE_ERROR ||
        recovery == null || recovery.hardware_presence !=
          RDMA_HW_PRESENCE_ABSENT || !barrier_pending ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0 ||
        manager.release_reserved_calls != 0)
      `uvm_error(label,
                 "QUERY ABSENT crossed incomplete CQ OCC barrier or released local authority")
  endtask

  // Physical context release can succeed while its registry progress update
  // fails.  Recovery must persist the progress gap, query the opaque release
  // authority on retry, and avoid invoking the external release a second
  // time before finalizing the queue.
  // 功能：在测试辅助 rdma_queue_recovery_test.check_context_progress_failure_exactly_once 中构造或驱动“context progress failure
  //   exactly once”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_context_progress_failure_exactly_once();
    string label;
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result destroy_result;
    rdma_control_result first_recovery_result;
    rdma_control_result second_recovery_result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_recovery_record recovery;
    rdma_resource error_resource;
    rdma_status status;
    rdma_status flush_failure;
    rdma_status progress_failure;
    int unsigned host_release_count;
    int unsigned context_release_count;

    label = "RECOVERY_CONTEXT_PROGRESS_EXACTLY_ONCE";
    create_destroy_fixture(label, RDMA_RESOURCE_CQ, binding, manager, mem,
                           context_backing, cmq, trace, executor, queue,
                           create_result, ceq_dependency, pd_dependency);
    flush_failure = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                      "initial CQ post-delete flush failure");
    cmq.fail_opcode(RDMA_OP_OCC_FLUSH, flush_failure);
    executor.destroy_locked(binding, binding.make_handle(),
                            make_destroy_request({label, "_destroy"},
                                                  binding, queue.handle),
                            64'd2310, destroy_result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_INITIAL_RECOVERY"}, status, RDMA_SC_OK);
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_INITIAL_ERROR"}, status, RDMA_SC_OK);
    if (destroy_result == null || destroy_result.status == null ||
        destroy_result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !destroy_result.recovery_required || error_resource == null ||
        error_resource.state != RDMA_RESOURCE_ERROR || recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.queue_plan == null || recovery.queue_plan.context_ref == null ||
        recovery.queue_plan.context_ref.release_complete ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label, "initial cleanup-progress fixture was not retained")
    progress_failure = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "injected context progress persistence failure");
    expect_status({label, "_INJECT_PROGRESS"},
                  manager.fail_next_transition(
                    "record_queue_context_cleanup_complete",
                    progress_failure), RDMA_SC_OK);
    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2311, first_recovery_result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_FIRST_RECOVERY"}, status, RDMA_SC_OK);
    host_release_count = count_executor_host_calls(mem, "release");
    context_release_count = context_backing.release_call_count;
    if (first_recovery_result == null || first_recovery_result.status == null ||
        first_recovery_result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !first_recovery_result.recovery_required || recovery == null ||
        recovery.queue_plan == null || recovery.queue_plan.context_ref == null ||
        recovery.queue_plan.context_ref.release_complete ||
        context_release_count != 1 || host_release_count != 2 ||
        mem.live_allocations() != 0)
      `uvm_error(label,
                 "context release/progress failure did not retain exactly-once gap")

    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2312, second_recovery_result);
    status = manager.lookup(queue.handle, error_resource);
    expect_status({label, "_SECOND_LOOKUP"}, status, RDMA_SC_INVALID_STATE);
    if (second_recovery_result == null || !second_recovery_result.ok() ||
        second_recovery_result.recovery_required ||
        second_recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        context_backing.release_call_count != context_release_count ||
        count_executor_host_calls(mem, "release") != host_release_count ||
        mem.live_allocations() != 0)
      `uvm_error(label,
                 "context progress retry duplicated a physical release")
  endtask

  // 功能：在测试辅助 rdma_queue_recovery_test.check_create_timeout_matrix 中构造或驱动“create timeout matrix”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_create_timeout_matrix();
    for (int unsigned scenario = 0; scenario < 3; scenario++) begin
      string label;
      rdma_function_binding binding;
      rdma_fault_inject_resource_manager manager;
      rdma_queue_destroy_trace_mem mem;
      rdma_queue_destroy_trace_context context_backing;
      rdma_queue_destroy_trace_cmq cmq;
      rdma_mock_call_trace trace;
      rdma_queue_lifecycle_executor executor;
      rdma_queue_resource queue;
      rdma_control_result create_result;
      rdma_control_result result;
      rdma_ceq ceq_dependency;
      rdma_pd pd_dependency;
      rdma_semantic_request request;
      rdma_recovery_record recovery;
      rdma_status status;

      label = $sformatf("CREATE_TIMEOUT_%0d", scenario);
      binding = make_binding({label, "_binding"});
      manager = rdma_fault_inject_resource_manager::type_id::create(
        {label, "_manager"});
      ceq_dependency = null;
      pd_dependency = null;
      status = manager.create_ceq(binding, ceq_dependency);
      expect_status({label, "_CEQ"}, status, RDMA_SC_OK);
      mem = rdma_queue_destroy_trace_mem::type_id::create({label, "_mem"});
      mem.queue_kind = RDMA_RESOURCE_CEQ;
      context_backing = rdma_queue_destroy_trace_context::type_id::create(
        {label, "_context"});
      cmq = rdma_queue_destroy_trace_cmq::type_id::create({label, "_cmq"});
      trace = rdma_mock_call_trace::type_id::create({label, "_trace"});
      mem.set_shared_trace(trace);
      context_backing.set_call_trace(trace);
      cmq.set_call_trace(trace);
      executor = rdma_queue_lifecycle_executor::type_id::create(
        {label, "_executor"});
      expect_status({label, "_CONFIGURE"}, executor.configure(
        manager, cmq, mem, context_backing, 100ns), RDMA_SC_OK);
      request = make_executor_request({label, "_request"},
                                      RDMA_RESOURCE_CEQ, binding,
                                      ceq_dependency, 1'b0);
      cmq.timeout_opcode(RDMA_OP_CEQC_CREATE);
      queue = null;
      result = null;
      executor.create_locked(binding, binding.make_handle(), request,
                             64'd2000 + scenario, queue, result);
      if (result == null || result.status == null ||
          result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
          !result.recovery_required || queue == null) begin
        `uvm_error(label, "create timeout did not retain ERROR recovery")
        continue;
      end
      status = manager.lookup_recovery(queue.handle, recovery);
      expect_status({label, "_LOOKUP"}, status, RDMA_SC_OK);
      if (recovery == null || recovery.ambiguous_ticket == null ||
          recovery.ambiguous_queue_operation != RDMA_QUEUE_AMBIG_CREATE)
        `uvm_error(label, "create timeout ticket was not retained")
      if (scenario == 0)
        cmq.push_late_completion(recovery.ambiguous_ticket,
                                 rdma_status::success("late create success"));
      else if (scenario == 1)
        cmq.push_late_completion(recovery.ambiguous_ticket,
                                 rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                                    "late create failure"));
      executor.recover_locked(binding, binding.make_handle(), queue.handle,
                              64'd2100 + scenario, result);
      if (scenario == 2) begin
        if (result == null || result.status == null ||
            result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
            !result.recovery_required)
          `uvm_error(label, "pending create remained unresolved")
      end
      else if (result == null || !result.ok() || result.recovery_required ||
               result.final_resource_state != RDMA_RESOURCE_RELEASED)
        `uvm_error(label, "terminal create evidence did not finish rollback")
    end
  endtask

  // 功能：在测试辅助 rdma_queue_recovery_test.check_delete_timeout_failure_restore 中构造或驱动“delete timeout failure
  //   restore”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_delete_timeout_failure_restore();
    string label;
    string expected[$];
    rdma_function_binding binding;
    rdma_fault_inject_resource_manager manager;
    rdma_queue_destroy_trace_mem mem;
    rdma_queue_destroy_trace_context context_backing;
    rdma_queue_destroy_trace_cmq cmq;
    rdma_mock_call_trace trace;
    rdma_queue_lifecycle_executor executor;
    rdma_queue_resource queue;
    rdma_control_result create_result;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_ceq ceq_dependency;
    rdma_pd pd_dependency;
    rdma_destroy_resource_req request;
    rdma_recovery_record recovery;
    rdma_resource snapshot;
    rdma_status failure;
    rdma_status status;
    int unsigned cmq_before;

    label = "DELETE_TIMEOUT_LATE_FAILURE_RESTORE";
    make_query_fixture(label, RDMA_RESOURCE_CEQ, binding, manager, mem,
                       context_backing, cmq, trace, executor, queue,
                       create_result, ceq_dependency, pd_dependency);
    request = make_destroy_request({label, "_request"}, binding, queue.handle);
    cmq.timeout_opcode(RDMA_OP_CEQC_DELETE);
    cmq_before = cmq.calls.size();
    executor.destroy_locked(binding, binding.make_handle(), request, 64'd2200,
                            result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_LOOKUP"}, status, RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null)
      `uvm_error(label, "delete timeout ticket was not retained")
    failure = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                "late definitive delete failure");
    cmq.push_late_completion(recovery.ambiguous_ticket, failure);
    recovery_result = null;
    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2201, recovery_result);
    if (recovery_result == null || recovery_result.status == null ||
        recovery_result.final_resource_state != RDMA_RESOURCE_ACTIVE ||
        !recovery_result.final_resource_state_known ||
        recovery_result.recovery_required || recovery_result.status.code !=
          RDMA_SC_UNKNOWN_HW_ERROR)
      `uvm_error(label, "late delete failure did not restore ACTIVE")
    status = manager.lookup(queue.handle, snapshot);
    expect_status({label, "_ACTIVE"}, status, RDMA_SC_OK);
    if (snapshot == null || snapshot.state != RDMA_RESOURCE_ACTIVE)
      `uvm_error(label, "manager did not publish restored ACTIVE queue")
    if (cmq.calls.size() != cmq_before + 1 || mem.release_ordinal != 0 ||
        context_backing.release_call_count != 0)
      `uvm_error(label, "restore path issued destructive/local cleanup")
  endtask

  // 功能：构造 rdma_queue_recovery_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_recovery_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在测试辅助 rdma_queue_recovery_test.check_late_delete_success_recovery 中构造或驱动“late delete success recovery”场景，并断言
  //   DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  task automatic check_late_delete_success_recovery();
    rdma_control_plane control;
    rdma_resource_manager manager;
    rdma_mock_cmq_port cmq;
    rdma_mock_stag_key_policy key_policy;
    rdma_mock_host_mem host_mem;
    rdma_mock_context_backing context_backing;
    rdma_function_binding binding;
    rdma_create_ceq_req create_request;
    rdma_destroy_resource_req destroy_request;
    rdma_ceq ceq;
    rdma_control_result result;
    rdma_control_result recovery_result;
    rdma_recovery_record recovery;
    rdma_status status;

    control = rdma_control_plane::type_id::create("QUEUE_RECOVERY_control");
    manager = rdma_resource_manager::type_id::create("QUEUE_RECOVERY_manager");
    cmq = rdma_mock_cmq_port::type_id::create("QUEUE_RECOVERY_cmq");
    key_policy = rdma_mock_stag_key_policy::type_id::create(
      "QUEUE_RECOVERY_key_policy");
    host_mem = rdma_mock_host_mem::type_id::create("QUEUE_RECOVERY_mem");
    context_backing = rdma_mock_context_backing::type_id::create(
      "QUEUE_RECOVERY_context");
    binding = make_binding("QUEUE_RECOVERY_binding");
    status = control.configure(manager, cmq, key_policy, host_mem, null,
                               context_backing, 100ns);
    expect_status("QUEUE_RECOVERY_CONFIGURE", status, RDMA_SC_OK);

    create_request = rdma_create_ceq_req::type_id::create(
      "QUEUE_RECOVERY_create");
    create_request.owner = binding.make_handle();
    create_request.depth = 64;
    create_request.vector_id = 3;
    control.create_ceq(binding, create_request, ceq, result);
    if (ceq == null || result == null || !result.ok()) begin
      `uvm_error("QUEUE_RECOVERY_CREATE", "failed to create CEQ fixture")
      return;
    end

    cmq.timeout_opcode(RDMA_OP_CEQC_DELETE);
    destroy_request = make_destroy_request("QUEUE_RECOVERY_destroy", binding,
                                           ceq.handle);
    control.destroy_ceq(binding, destroy_request, result);
    if (result == null || result.status == null ||
        result.status.code != RDMA_SC_RECOVERY_REQUIRED ||
        !result.recovery_required) begin
      `uvm_error("QUEUE_RECOVERY_TIMEOUT",
                 "CEQ delete timeout did not retain recovery")
      return;
    end
    status = manager.lookup_recovery(ceq.handle, recovery);
    expect_status("QUEUE_RECOVERY_LOOKUP", status, RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null) begin
      `uvm_error("QUEUE_RECOVERY_TICKET", "delete ticket was not retained")
      return;
    end

    // The late terminal result is the only evidence that permits recovery to
    // cross the delete boundary.
    cmq.push_late_completion(recovery.ambiguous_ticket,
                             rdma_status::success("late CEQ delete"));
    control.recover_resource(binding, ceq.handle, recovery_result);
    if (recovery_result == null || !recovery_result.ok() ||
        recovery_result.final_resource_state != RDMA_RESOURCE_RELEASED ||
        recovery_result.recovery_required) begin
      `uvm_error("QUEUE_RECOVERY_LATE_SUCCESS",
                 "queue recovery did not complete after late delete success")
    end
  endtask

  // 功能：在 rdma_queue_recovery_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_query_classifier_matrix();
    check_query_profile_absence_matrix();
    check_query_absent_before_cq_occ_barrier();
    check_context_progress_failure_exactly_once();
    // Reuse the lifecycle executor's focused fault matrices here as well:
    // they assert ambiguous OCC ERROR retention/no-release and persisted
    // local-cleanup retries without duplicate physical releases.
    check_executor_cq_reset_cancelled();
    check_executor_local_cleanup_recovery();
    check_create_timeout_matrix();
    check_late_delete_success_recovery();
    check_delete_timeout_failure_restore();
    phase.drop_objection(this);
  endtask
endclass
