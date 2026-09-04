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
  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function automatic rdma_hw_image make_query_raw(
    string name,
    rdma_cmq_ticket ticket,
    rdma_xtr_v1_cmq_completion payload
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
    image.hardware_version = XTR_V1_HW_VERSION;
    image.function_generation = ticket == null || ticket.function_h == null ?
      1 : ticket.function_h.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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
    rdma_xtr_v1_cmq_completion payload;
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
    payload = rdma_xtr_v1_cmq_completion::type_id::create(
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

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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
  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
    rdma_xtr_v1_cmq_completion payload;
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
    status = policy.build_object_command(XTR_V1_OP_CEQC_QUERY,
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
      query_status(ticket, RDMA_SC_OK, 8'h00), XTR_V1_OP_CEQC_QUERY,
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
      query_status(ticket, RDMA_SC_OK, XTR_V1_ECODE_EC_RCE_CEQC_INVLD),
      XTR_V1_OP_CEQC_QUERY, XTR_V1_ECODE_EC_RCE_CEQC_INVLD,
      payload.owner, ticket.sq_index, ticket.sq_wrap
    );
    query_result_is({label, "_OK_WHITELIST"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = make_query_completion(
      {label, "_ABSENT_WHITELIST"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR,
                   XTR_V1_ECODE_EC_RCE_CEQC_INVLD),
      XTR_V1_OP_CEQC_QUERY, XTR_V1_ECODE_EC_RCE_CEQC_INVLD,
      payload.owner, ticket.sq_index, ticket.sq_wrap
    );
    query_result_is({label, "_ABSENT_WHITELIST"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_ABSENT, 1'b1);

    // Every nonzero ecode outside the per-opcode absence whitelist remains
    // UNKNOWN, even if all context bytes decode as a valid typed object.
    copy = make_query_completion(
      {label, "_SRFQ_ECODE"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, 8'h7b),
      XTR_V1_OP_CEQC_QUERY, 8'h7b, payload.owner, ticket.sq_index,
      ticket.sq_wrap
    );
    query_result_is({label, "_SRFQ_ECODE"}, policy, ceq, copy,
                    RDMA_HW_PRESENCE_UNKNOWN, 1'b0);
    copy = make_query_completion(
      {label, "_ARBITRARY_ECODE"}, policy, ceq, ticket,
      query_status(ticket, RDMA_SC_UNKNOWN_HW_ERROR, 8'h55),
      XTR_V1_OP_CEQC_QUERY, 8'h55, payload.owner, ticket.sq_index,
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
    // xtr_v1 CMQ starts with CQ owner=1 and toggles once per 32-slot cycle).
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
  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
        query_opcode_value = XTR_V1_OP_CQC_QUERY;
      end
      RDMA_RESOURCE_SRQ: begin
        policy = rdma_srq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = XTR_V1_OP_SRFQC_QUERY;
      end
      RDMA_RESOURCE_CEQ: begin
        policy = rdma_ceq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = XTR_V1_OP_CEQC_QUERY;
      end
      RDMA_RESOURCE_AEQ: begin
        policy = rdma_aeq_lifecycle_policy::type_id::create(
          {label, "_policy"});
        query_opcode_value = XTR_V1_OP_AEQC_QUERY;
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  task automatic check_query_profile_absence_matrix();
    check_query_absent_case("QUERY_CQC_F3", RDMA_RESOURCE_CQ,
                            XTR_V1_ECODE_EC_RCE_CQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_CEQC_F7", RDMA_RESOURCE_CEQ,
                            XTR_V1_ECODE_EC_RCE_CEQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_AEQC_FA", RDMA_RESOURCE_AEQ,
                            XTR_V1_ECODE_EC_RCE_AEQC_INVLD, 8'h7b, 1'b1);
    check_query_absent_case("QUERY_SRFQC_7B", RDMA_RESOURCE_SRQ,
                            8'hff, 8'h7b, 1'b0);
    check_query_absent_case("QUERY_SRFQC_ARBITRARY", RDMA_RESOURCE_SRQ,
                            8'hff, 8'h55, 1'b0);
  endtask

  // A QUERY can prove that the hardware object is absent before the
  // remaining CQ post-delete OCC barrier has completed.  Absence is not a
  // license to release local authority: recovery must retain ERROR and leave
  // every backing/context release pending until the barrier is terminal.
  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
    cmq.timeout_opcode(XTR_V1_OP_CQC_QUERY);
    executor.recover_locked(binding, binding.make_handle(), queue.handle,
                            64'd2301, recovery_result);
    status = manager.lookup_recovery(queue.handle, recovery);
    expect_status({label, "_LOOKUP_AFTER_QUERY_TIMEOUT"}, status,
                  RDMA_SC_OK);
    if (recovery == null || recovery.ambiguous_ticket == null ||
        recovery.ambiguous_ticket.opcode_key == null ||
        recovery.ambiguous_ticket.opcode_key.opcode != XTR_V1_OP_CQC_QUERY ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_UNKNOWN ||
        mem.release_ordinal != 0 || context_backing.release_call_count != 0)
      `uvm_error(label, "ambiguous CQ QUERY lost durable no-release state")
    query_ticket = recovery.ambiguous_ticket;

    policy = rdma_cq_lifecycle_policy::type_id::create(
      {label, "_policy"});
    absent_completion = make_query_completion(
      {label, "_absent"}, policy, cq, query_ticket,
      query_status(query_ticket, RDMA_SC_UNKNOWN_HW_ERROR,
                   XTR_V1_ECODE_EC_RCE_CQC_INVLD),
      XTR_V1_OP_CQC_QUERY, XTR_V1_ECODE_EC_RCE_CQC_INVLD,
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
    cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH, flush_failure);
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
  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
    cmq.fail_opcode(XTR_V1_OP_OCC_FLUSH, flush_failure);
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
      cmq.timeout_opcode(XTR_V1_OP_CEQC_CREATE);
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

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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
    cmq.timeout_opcode(XTR_V1_OP_CEQC_DELETE);
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_queue_recovery_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
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

    cmq.timeout_opcode(XTR_V1_OP_CEQC_DELETE);
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

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
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
