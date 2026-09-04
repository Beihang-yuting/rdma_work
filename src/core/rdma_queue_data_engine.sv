// 目录：核心执行层 core/rdma_queue_data_engine.sv。
// 职责：实现 rdma_queue_data_engine 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_data_engine.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Transaction-level host-side queue data facade.  Queue ownership remains in
// the lifecycle resources; this class only keeps detached runtime cursors and
// borrowed backing-access capabilities for the lifetime of an attachment.

class rdma_queue_post_result extends uvm_object;
  `uvm_object_utils(rdma_queue_post_result)
  rdma_handle queue_h;
  longint unsigned wr_id;
  int unsigned index;
  bit wrap;
  rdma_hw_image image;
  rdma_status status;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_post_result");
    super.new(name);
    queue_h = null; wr_id = 0; index = 0; wrap = 0;
    image = null; status = null;
  endfunction
endclass

class rdma_queue_completion_result extends uvm_object;
  `uvm_object_utils(rdma_queue_completion_result)
  rdma_handle queue_h;
  rdma_xtr_v1_cqe_model cqe;
  rdma_status completion_status;
  rdma_queue_slot_ledger_entry released_slots[$];

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_completion_result");
    super.new(name);
    queue_h = null; cqe = null; completion_status = null;
    released_slots.delete();
  endfunction
endclass

class rdma_queue_event_result extends uvm_object;
  `uvm_object_utils(rdma_queue_event_result)
  rdma_handle queue_h;
  rdma_hw_model event_model;
  rdma_status event_status;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_event_result");
    super.new(name);
    queue_h = null; event_model = null; event_status = null;
  endfunction
endclass

// A separate object is deliberately kept for every ring.  In particular, an
// SQ and an RQ belonging to one QP must not share a backing-access object's
// lookup namespace because their logical offsets both start at zero.
class rdma_queue_data_attachment extends uvm_object;
  `uvm_object_utils(rdma_queue_data_attachment)
  rdma_handle queue_h;
  rdma_queue_runtime_kind_e kind;
  rdma_queue_runtime runtime;
  rdma_queue_backing_access access;
  rdma_queue_backing_role_e role;
  int unsigned entry_size;
  int unsigned local_id;
  rdma_transport_e transport;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_data_attachment");
    super.new(name);
    queue_h = null; kind = RDMA_QUEUE_RUNTIME_SQ; runtime = null;
    access = null; role = RDMA_QUEUE_ROLE_CQ_RING; entry_size = 64;
    local_id = 0; transport = RDMA_TRANSPORT_RC;
  endfunction
endclass

class rdma_queue_data_qp_link extends uvm_object;
  `uvm_object_utils(rdma_queue_data_qp_link)
  rdma_handle qp_h;
  rdma_handle srq_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  int unsigned local_qp_id;
  rdma_transport_e transport;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_data_qp_link");
    super.new(name);
    qp_h = null; srq_h = null; send_cq_h = null; recv_cq_h = null;
    local_qp_id = 0; transport = RDMA_TRANSPORT_RC;
  endfunction
endclass

class rdma_queue_data_engine extends uvm_object;
  `uvm_object_utils(rdma_queue_data_engine)

  rdma_resource_manager manager;
  rdma_function_binding binding;
  rdma_host_mem_api host_mem;
  rdma_doorbell_scheduler doorbells;
  rdma_codec_registry registry;
  time operation_timeout;

  protected rdma_queue_data_attachment attachments[string];
  protected rdma_queue_data_qp_link qp_links[string];
  protected bit configured;

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_queue_data_engine");
    super.new(name);
    manager = null; binding = null; host_mem = null; doorbells = null;
    registry = null; operation_timeout = 0;
    attachments.delete(); qp_links.delete(); configured = 1'b0;
  endfunction

  // 功能：执行接口 bad 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 bad）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status bad(
    string message,
    rdma_status_code_e code = RDMA_SC_INVALID_ARGUMENT
  );
    return rdma_status::make(code, message);
  endfunction

  // 功能：执行接口 identity_key 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 identity_key）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function string identity_key(rdma_handle handle);
    if (handle == null) return "";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：执行接口 attachment_key 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attachment_key）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function string attachment_key(
    rdma_handle handle, rdma_queue_runtime_kind_e kind
  );
    if (handle == null) return "";
    return {identity_key(handle), $sformatf(":%0d", kind)};
  endfunction

  // 功能：执行接口 ensure_handle 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 ensure_handle）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status ensure_handle(
    rdma_handle handle, rdma_resource_kind_e expected_kind
  );
    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (handle == null || handle.kind != expected_kind)
      return bad("queue handle kind is invalid");
    if (binding == null)
      return bad("queue data engine has no Function binding",
                 RDMA_SC_INVALID_STATE);
    if (handle.function_uid != binding.function_uid ||
        handle.generation != binding.generation)
      return bad("queue handle Function or generation is stale",
                 handle.generation == binding.generation ?
                 RDMA_SC_INVALID_ARGUMENT : RDMA_SC_STALE_GENERATION);
    return rdma_status::success();
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 lookup_attachment）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status lookup_attachment(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output rdma_queue_data_attachment attachment
  );
    rdma_status status;
    attachment = null;
    status = ensure_handle(handle, handle == null ? RDMA_RESOURCE_QP :
                           handle.kind);
    if (!status.ok()) return status;
    if (!attachments.exists(attachment_key(handle, kind)) ||
        attachments[attachment_key(handle, kind)] == null)
      return bad("queue is not attached", RDMA_SC_INVALID_STATE);
    attachment = attachments[attachment_key(handle, kind)];
    if (attachment.runtime == null || attachment.access == null)
      return bad("queue attachment is incomplete", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：写入并校验运行所需的配置、身份或资源参数，建立后续操作的边界（接口 configure）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codecs,
    time timeout
  );
    rdma_status status;
    if (resource_manager == null || function_binding == null || memory == null ||
        scheduler == null || codecs == null || timeout == 0)
      return bad("queue data engine configuration has a null/zero dependency");
    status = function_binding.validate();
    if (status == null || !status.ok())
      return status == null ? bad("Function binding validation returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    if (function_binding.state != RDMA_BIND_ACTIVE ||
        function_binding.generation == 0)
      return bad("Function binding is not active", RDMA_SC_INVALID_STATE);
    manager = resource_manager; binding = function_binding; host_mem = memory;
    doorbells = scheduler; registry = codecs; operation_timeout = timeout;
    attachments.delete(); qp_links.delete(); configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_queue_ref）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status find_queue_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    output rdma_queue_backing_ref result
  );
    result = null;
    if (plan == null)
      return bad("queue backing plan is null", RDMA_SC_INVALID_STATE);
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role) begin
        result = plan.refs[i];
        return rdma_status::success();
      end
    end
    return bad("queue backing role is missing", RDMA_SC_INVALID_STATE);
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 create_attachment）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status create_attachment(
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_backing_role_e role,
    rdma_queue_backing_ref queue_ref,
    rdma_qp_backing_ref qp_ref,
    int unsigned depth,
    int unsigned producer_index,
    bit producer_wrap,
    int unsigned consumer_index,
    bit consumer_wrap,
    bit host_produced,
    int unsigned local_id,
    rdma_transport_e transport,
    int unsigned entry_size = 64,
    bit initial_polarity = 1'b0
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_backing_access access;
    rdma_queue_runtime runtime;
    rdma_status status;
    string key;

    if (queue_h == null || depth == 0)
      return bad("queue attachment geometry is invalid");
    key = attachment_key(queue_h, kind);
    if (attachments.exists(key))
      return bad("queue is already attached", RDMA_SC_INVALID_STATE);
    access = rdma_queue_backing_access::type_id::create(
      $sformatf("queue_access_%0d", attachments.num()));
    status = access.configure(binding.make_handle(), host_mem);
    if (!status.ok()) return status;
    if (qp_ref != null)
      status = access.attach_qp(qp_ref);
    else
      status = access.attach_queue(queue_ref);
    if (!status.ok()) return status;
    runtime = rdma_queue_runtime::type_id::create(
      $sformatf("queue_runtime_%0d", attachments.num()));
    status = runtime.configure(queue_h, kind, depth, producer_index,
                               producer_wrap, consumer_index, consumer_wrap,
                               host_produced, initial_polarity);
    if (!status.ok()) return status;
    status = runtime.activate();
    if (!status.ok()) return status;
    attachment = rdma_queue_data_attachment::type_id::create(
      $sformatf("queue_attachment_%0d", attachments.num()));
    attachment.queue_h = rdma_clone_handle_value(queue_h,
                                                  "queue attachment handle");
    if (attachment.queue_h == null)
      attachment.queue_h = queue_h;
    attachment.kind = kind; attachment.runtime = runtime; attachment.access = access;
    attachment.role = role; attachment.entry_size = entry_size;
    attachment.local_id = local_id; attachment.transport = transport;
    attachments[key] = attachment;
    return rdma_status::success();
  endfunction

  // 功能：执行接口 delete_attachment 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 delete_attachment）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function void delete_attachment(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind
  );
    string key;
    key = attachment_key(queue_h, kind);
    if (attachments.exists(key)) begin
      if (attachments[key] != null && attachments[key].runtime != null)
        attachments[key].runtime.state = RDMA_QUEUE_RUNTIME_DETACHED;
      attachments.delete(key);
    end
  endfunction

  // 功能：执行接口 attach_srq_for_qp 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_srq_for_qp）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status attach_srq_for_qp(
    rdma_handle srq_h
  );
    rdma_resource resource;
    rdma_srq srq;
    rdma_queue_backing_ref queue_backing;
    rdma_status status;
    bit initial_polarity;

    status = ensure_handle(srq_h, RDMA_RESOURCE_SRQ);
    if (!status.ok()) return status;
    if (attachments.exists(attachment_key(srq_h, RDMA_QUEUE_RUNTIME_SRQ)))
      return rdma_status::success();
    status = manager.lookup(srq_h, resource);
    if (!status.ok()) return status;
    if (!$cast(srq, resource) || srq == null ||
        srq.state != RDMA_RESOURCE_ACTIVE || srq.queue_plan == null)
      return bad("SRQ lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    status = find_queue_ref(srq.queue_plan, RDMA_QUEUE_ROLE_SRQ_RING, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (srq.queue_plan.rings[i]) begin
      if (srq.queue_plan.rings[i] != null &&
          srq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_SRQ_RING)
        initial_polarity = srq.queue_plan.rings[i].initial_polarity;
    end
    return create_attachment(srq_h, RDMA_QUEUE_RUNTIME_SRQ,
      RDMA_QUEUE_ROLE_SRQ_RING, queue_backing, null, srq.depth,
      srq.producer_index, srq.producer_wrap, srq.consumer_index,
      srq.consumer_wrap, 1'b1, srq.local_srq_id, RDMA_TRANSPORT_RC,
      64, initial_polarity);
  endfunction

  // 功能：执行接口 attach_qp 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_qp）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status attach_qp(rdma_handle qp_h);
    rdma_resource resource;
    rdma_qp qp;
    rdma_status status;
    rdma_queue_backing_ref unused_ref;
    rdma_queue_data_qp_link link;
    bit sq_attached;

    status = ensure_handle(qp_h, RDMA_RESOURCE_QP);
    if (!status.ok()) return status;
    status = manager.lookup(qp_h, resource);
    if (!status.ok()) return status;
    if (!$cast(qp, resource) || qp == null ||
        qp.state != RDMA_RESOURCE_ACTIVE || qp.qp_plan == null)
      return bad("QP lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    if (attachments.exists(attachment_key(qp_h, RDMA_QUEUE_RUNTIME_SQ)))
      return bad("QP is already attached", RDMA_SC_INVALID_STATE);
    status = create_attachment(qp_h, RDMA_QUEUE_RUNTIME_SQ,
      RDMA_QUEUE_ROLE_QP_SQ_RING, unused_ref, qp.qp_plan.sq_ref,
      qp.sq_depth, qp.sq_producer_index, qp.sq_wrap,
      qp.sq_consumer_index, qp.sq_consumer_wrap, 1'b1,
      qp.local_qp_id, qp.transport);
    if (!status.ok()) return status;
    sq_attached = 1'b1;
    if (qp.srq_h == null) begin
      status = create_attachment(qp_h, RDMA_QUEUE_RUNTIME_RQ,
        RDMA_QUEUE_ROLE_QP_RQ_RING, unused_ref, qp.qp_plan.rq_ref,
        qp.rq_depth, qp.rq_producer_index, qp.rq_wrap,
        qp.rq_consumer_index, qp.rq_consumer_wrap, 1'b1,
        qp.local_qp_id, qp.transport);
    end
    else begin
      status = attach_srq_for_qp(qp.srq_h);
    end
    if (!status.ok()) begin
      if (sq_attached) delete_attachment(qp_h, RDMA_QUEUE_RUNTIME_SQ);
      return status;
    end
    link = rdma_queue_data_qp_link::type_id::create(
      $sformatf("qp_link_%0d", qp_links.num()));
    link.qp_h = rdma_clone_handle_value(qp_h, "QP link handle");
    if (link.qp_h == null) link.qp_h = qp_h;
    link.srq_h = rdma_clone_handle_value(qp.srq_h, "QP link SRQ");
    if (link.srq_h == null && qp.srq_h != null) link.srq_h = qp.srq_h;
    link.send_cq_h = rdma_clone_handle_value(qp.send_cq_h, "QP link send CQ");
    if (link.send_cq_h == null && qp.send_cq_h != null)
      link.send_cq_h = qp.send_cq_h;
    link.recv_cq_h = rdma_clone_handle_value(qp.recv_cq_h, "QP link receive CQ");
    if (link.recv_cq_h == null && qp.recv_cq_h != null)
      link.recv_cq_h = qp.recv_cq_h;
    link.local_qp_id = qp.local_qp_id; link.transport = qp.transport;
    qp_links[identity_key(qp_h)] = link;
    return rdma_status::success();
  endfunction

  // 功能：执行接口 attach_cq 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_cq）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status attach_cq(
    rdma_handle cq_h, rdma_transport_e transport_variant
  );
    rdma_resource resource;
    rdma_cq cq;
    rdma_queue_backing_ref queue_backing;
    bit initial_polarity;
    rdma_status status;
    status = ensure_handle(cq_h, RDMA_RESOURCE_CQ);
    if (!status.ok()) return status;
    if (!(transport_variant inside {RDMA_TRANSPORT_RC,
                                    RDMA_TRANSPORT_UD,
                                    RDMA_TRANSPORT_URC}))
      return bad("CQ transport variant is invalid");
    status = manager.lookup(cq_h, resource);
    if (!status.ok()) return status;
    if (!$cast(cq, resource) || cq == null ||
        cq.state != RDMA_RESOURCE_ACTIVE || cq.queue_plan == null)
      return bad("CQ lookup/backing plan is invalid", RDMA_SC_INVALID_STATE);
    // XTR v1 exposes a single fixed 64-byte CQE image.  The lifecycle model
    // accepts other sizes for forward compatibility, but this engine cannot
    // safely decode them and must reject the attachment up front.
    if (cq.cqe_size_bytes != XTR_V1_CQE_BYTES)
      return bad("XTR v1 CQE size is unsupported",
                 RDMA_SC_UNSUPPORTED_OPCODE);
    status = find_queue_ref(cq.queue_plan, RDMA_QUEUE_ROLE_CQ_RING, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (cq.queue_plan.rings[i]) begin
      if (cq.queue_plan.rings[i] != null &&
          cq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        initial_polarity = cq.queue_plan.rings[i].initial_polarity;
    end
    return create_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, queue_backing, null, cq.depth,
      cq.producer_index, cq.producer_wrap, cq.consumer_index,
      cq.consumer_wrap, 1'b0, cq.local_cq_id, transport_variant,
      cq.cqe_size_bytes, initial_polarity);
  endfunction

  // 功能：执行接口 attach_event_queue 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_event_queue）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status attach_event_queue(
    rdma_handle queue_h, rdma_resource_kind_e expected,
    rdma_queue_runtime_kind_e kind, rdma_queue_backing_role_e role
  );
    rdma_resource resource;
    rdma_queue_resource queue;
    rdma_queue_backing_ref queue_backing;
    rdma_status status;
    int unsigned local_id;
    bit initial_polarity;

    status = ensure_handle(queue_h, expected);
    if (!status.ok()) return status;
    status = manager.lookup(queue_h, resource);
    if (!status.ok()) return status;
    if (!$cast(queue, resource) || queue == null ||
        queue.state != RDMA_RESOURCE_ACTIVE || queue.queue_plan == null)
      return bad("event queue lookup/backing plan is invalid",
                 RDMA_SC_INVALID_STATE);
    status = find_queue_ref(queue.queue_plan, role, queue_backing);
    if (!status.ok()) return status;
    initial_polarity = 1'b0;
    foreach (queue.queue_plan.rings[i]) begin
      if (queue.queue_plan.rings[i] != null &&
          queue.queue_plan.rings[i].role == role)
        initial_polarity = queue.queue_plan.rings[i].initial_polarity;
    end
    local_id = queue_h.object_id;
    if (expected == RDMA_RESOURCE_CEQ) begin
      rdma_ceq ceq;
      if ($cast(ceq, queue)) local_id = ceq.local_ceq_id;
    end
    else begin
      rdma_aeq aeq;
      if ($cast(aeq, queue)) local_id = aeq.local_aeq_id;
    end
    return create_attachment(queue_h, kind, role, queue_backing, null, queue.depth,
      queue.producer_index, queue.producer_wrap, queue.consumer_index,
      queue.consumer_wrap, 1'b0, local_id, RDMA_TRANSPORT_RC,
      (kind == RDMA_QUEUE_RUNTIME_CEQ || kind == RDMA_QUEUE_RUNTIME_AEQ) ? 16 : 64,
      initial_polarity);
  endfunction

  // 功能：执行接口 attach_ceq 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_ceq）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status attach_ceq(rdma_handle ceq_h);
    return attach_event_queue(ceq_h, RDMA_RESOURCE_CEQ,
                              RDMA_QUEUE_RUNTIME_CEQ,
                              RDMA_QUEUE_ROLE_CEQ_RING);
  endfunction

  // 功能：执行接口 attach_aeq 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 attach_aeq）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status attach_aeq(rdma_handle aeq_h);
    return attach_event_queue(aeq_h, RDMA_RESOURCE_AEQ,
                              RDMA_QUEUE_RUNTIME_AEQ,
                              RDMA_QUEUE_ROLE_AEQ_RING);
  endfunction

  // 功能：释放、撤销或回滚当前对象持有的事务/资源，并保持账本与生命周期一致（接口 detach）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function rdma_status detach(rdma_handle queue_h);
    rdma_status status;
    string key;
    bit found;
    found = 1'b0;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (!status.ok()) return status;
    foreach (attachments[key]) begin
      if (attachments[key] != null && attachments[key].queue_h != null &&
          attachments[key].queue_h.same_instance(queue_h)) begin
        if (attachments[key].runtime != null)
          attachments[key].runtime.state = RDMA_QUEUE_RUNTIME_DETACHED;
        attachments.delete(key); found = 1'b1;
      end
    end
    if (queue_h.kind == RDMA_RESOURCE_QP)
      qp_links.delete(identity_key(queue_h));
    if (!found)
      return bad("queue is not attached", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_sqe）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status make_sqe(
    rdma_post_send_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_xtr_v1_sqe_model model
  );
    rdma_sqe_rc_ext rc;
    rdma_sqe_ud_ext ud;
    rdma_sqe_urc_ext urc;
    rdma_sge cloned_sge;
    rdma_status status;
    model = null;
    if (request == null || link == null || cursor == null)
      return bad("SQE request, QP link, or reservation is null");
    model = rdma_xtr_v1_sqe_model::type_id::create("queue_sqe");
    model.transport = request.transport; model.qp_h = request.qp_h;
    model.wr_id = request.wr_id; model.opcode = request.opcode;
    model.signaled = request.signaled; model.solicited = request.solicited;
    model.fence = '0; model.qpn = link.local_qp_id;
    model.qp_sn = 0; model.icos = 0; model.dst_port = 0;
    model.index = cursor.index; model.wrap = cursor.wrap;
    model.sign_en = request.signaled; model.se = request.solicited;
    model.ce = request.signaled ? 2'b01 : 2'b00; model.valid = 1'b1;
    model.hw_opcode = request.opcode;
    model.sge_num = request.sges.size();
    foreach (request.sges[i]) begin
      if (request.sges[i] == null)
        return bad("SQE request has a null SGE");
      cloned_sge = rdma_sge::type_id::create("sqe_sge");
      cloned_sge.copy(request.sges[i]); model.sges.push_back(cloned_sge);
    end
    case (request.transport)
      RDMA_TRANSPORT_RC: begin
        rc = rdma_sqe_rc_ext::type_id::create("sqe_rc");
        rc.remote_addr = request.remote_addr; rc.rkey = request.rkey;
        rc.remote_access_valid = request.remote_access_valid;
        rc.rkey_valid = request.rkey_valid; model.transport_ext = rc;
        model.rkey = request.rkey; model.remote_va = request.remote_addr;
      end
      RDMA_TRANSPORT_UD: begin
        ud = rdma_sqe_ud_ext::type_id::create("sqe_ud");
        ud.destination_qpn = request.destination_qpn; ud.qkey = request.qkey;
        ud.address_vector_id = request.address_vector_id;
        ud.address_vector_valid = request.address_vector_valid;
        model.transport_ext = ud;
      end
      RDMA_TRANSPORT_URC: begin
        urc = rdma_sqe_urc_ext::type_id::create("sqe_urc");
        urc.destination_qpn = request.destination_qpn;
        urc.remote_addr = request.remote_addr; urc.rkey = request.rkey;
        urc.remote_access_valid = request.remote_access_valid;
        urc.rkey_valid = request.rkey_valid; model.transport_ext = urc;
      end
      default: return bad("SQE transport is unsupported",
                          RDMA_SC_UNSUPPORTED_OPCODE);
    endcase
    status = model.validate();
    return status;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_rqe）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status make_rqe(
    rdma_post_recv_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_xtr_v1_rqe_model model
  );
    rdma_sge cloned_sge;
    longint unsigned payload_len;
    model = null;
    if (request == null || link == null || cursor == null)
      return bad("RQE request, QP link, or reservation is null");
    model = rdma_xtr_v1_rqe_model::type_id::create("queue_rqe");
    model.target_h = request.target_h; model.wr_id = request.wr_id;
    model.qpn = link.local_qp_id; model.qp_sn = 0;
    model.hw_opcode = 4'd8; model.index = cursor.index;
    model.wrap = cursor.wrap; model.valid = 1'b1;
    model.sge_num = request.sges.size(); payload_len = 0;
    foreach (request.sges[i]) begin
      if (request.sges[i] == null || request.sges[i].length == 0)
        return bad("RQE request has an invalid SGE");
      if (payload_len > 64'hffff_ffff - request.sges[i].length)
        return bad("RQE payload length exceeds 32 bits");
      payload_len += request.sges[i].length;
      cloned_sge = rdma_sge::type_id::create("rqe_sge");
      cloned_sge.copy(request.sges[i]); model.sges.push_back(cloned_sge);
    end
    model.payload_len = payload_len;
    return model.validate();
  endfunction

  // 功能：将模型或请求按硬件/协议布局编码为可传输的镜像或令牌（接口 encode_queue_model）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status encode_queue_model(
    rdma_hw_model model, rdma_image_kind_e image_kind, string object_type,
    string variant, output rdma_hw_image image
  );
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_status status;
    image = null;
    codec_key = '{hw_version:"xtr_v1", image_kind:image_kind,
      object_type:object_type, variant:variant, opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return status;
    return codec.encode(model, image);
  endfunction

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 write_and_verify）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status write_and_verify(
      rdma_queue_data_attachment attachment,
      longint unsigned offset,
      rdma_hw_image image
  );
    byte data[];
    byte readback[];
    rdma_status status;
    if (attachment == null || attachment.access == null || image == null)
      return bad("queue write attachment/image is null",
                 RDMA_SC_INVALID_STATE);
    data = new[image.bytes.size()];
    foreach (data[i]) data[i] = image.bytes[i];
    status = attachment.access.write(offset, data);
    if (!status.ok()) return status;
    status = attachment.access.readback(offset, data.size(), readback);
    if (!status.ok()) return status;
    if (readback.size() != data.size())
      return bad("queue write readback is short", RDMA_SC_DMA_TRANSLATION);
    foreach (readback[i]) begin
      if (readback[i] !== data[i])
        return bad("queue write readback mismatch", RDMA_SC_DMA_TRANSLATION);
    end
    return rdma_status::success();
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_pending）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_queue_pending_operation make_pending(
    rdma_queue_cursor_snapshot cursor,
    rdma_handle queue_h = null,
    rdma_queue_runtime_kind_e kind = RDMA_QUEUE_RUNTIME_SQ,
    bit producer = 1'b0,
    longint unsigned entry_offset = 0,
    rdma_hw_image image = null,
    rdma_semantic_request request_snapshot = null,
    bit signaled = 1'b0,
    int unsigned completion_index = 0,
    bit completion_wrap = 1'b0,
    bit completion_target_valid = 1'b0,
    bit completion_released = 1'b0,
    rdma_handle routed_qp_h = null
  );
    rdma_queue_pending_operation pending;
    uvm_object cloned;
    pending = rdma_queue_pending_operation::type_id::create("queue_pending");
    if (queue_h != null) begin
      pending.queue_h = rdma_clone_handle_value(queue_h, "pending queue");
    end
    pending.kind = kind;
    pending.producer = producer;
    pending.entry_offset = entry_offset;
    if (request_snapshot != null) begin
      rdma_post_send_req pending_send;
      rdma_post_recv_req pending_recv;
      if ($cast(pending_send, request_snapshot))
        pending.wr_id = pending_send.wr_id;
      else if ($cast(pending_recv, request_snapshot))
        pending.wr_id = pending_recv.wr_id;
    end
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create("pending_cursor");
    pending.cursor.index = cursor.index; pending.cursor.wrap = cursor.wrap;
    pending.signaled = signaled;
    pending.completion_index = completion_index;
    pending.completion_wrap = completion_wrap;
    pending.completion_target_valid = completion_target_valid;
    pending.completion_released = completion_released;
    if (routed_qp_h != null)
      pending.routed_qp_h = rdma_clone_handle_value(routed_qp_h,
                                                     "pending routed QP");
    if (request_snapshot != null) begin
      cloned = request_snapshot.clone();
      if (cloned != null)
        void'($cast(pending.request_snapshot, cloned));
    end
    if (image != null) begin
      cloned = image.clone();
      if (cloned != null) void'($cast(pending.image, cloned));
    end
    return pending;
  endfunction

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 projected_id_handle）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_handle projected_id_handle(
    rdma_handle source, int unsigned local_id
  );
    rdma_handle result;
    result = rdma_clone_handle_value(source, "doorbell model target");
    if (result == null)
      result = rdma_handle::type_id::create("doorbell_model_target_fallback");
    if (result == null || source == null)
      return null;
    result.kind = source.kind;
    result.function_uid = source.function_uid;
    result.generation = source.generation;
    result.object_id = local_id;
    return result;
  endfunction

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 submit_producer_doorbell）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task submit_producer_doorbell(
    rdma_handle target_h, rdma_queue_runtime_kind_e kind,
    rdma_queue_cursor_snapshot reservation, rdma_queue_cursor_snapshot next,
    rdma_hw_image sqe_image, int unsigned local_id,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_xtr_v1_sq_doorbell_model sq;
    rdma_xtr_v1_rq_doorbell_model rq;
    rdma_xtr_v1_srq_doorbell_model srq;
    rdma_hw_model model;
    rdma_hw_image image;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_doorbell_desc desc;
    string variant;
    longint unsigned relative_offset;

    result = null; model = null; image = null; status = null;
    if (target_h == null || next == null) begin
      status = bad("producer doorbell target/cursor is null");
      return;
    end
    case (kind)
      RDMA_QUEUE_RUNTIME_SQ: begin
        variant = "sq"; relative_offset = XTR_V1_DB_SQ_OFFSET;
        sq = rdma_xtr_v1_sq_doorbell_model::type_id::create("sq_db_model");
        sq.target_h = rdma_clone_handle_value(target_h, "SQ DB target");
        if (sqe_image == null || sqe_image.bytes.size() < XTR_V1_DB_BYTES) begin
          status = bad("SQ doorbell lacks the encoded SQE header");
          return;
        end
        foreach (sqe_image.bytes[i]) begin
          if (i >= XTR_V1_DB_BYTES) break;
          sq.sqe_header.push_back(sqe_image.bytes[i]);
        end
        model = sq;
      end
      RDMA_QUEUE_RUNTIME_RQ: begin
        variant = "rq"; relative_offset = XTR_V1_DB_RQ_OFFSET;
        rq = rdma_xtr_v1_rq_doorbell_model::type_id::create("rq_db_model");
        rq.target_h = projected_id_handle(target_h, local_id);
        rq.qpn = local_id; rq.icos = 0; rq.pi = next.index; rq.wrap = next.wrap;
        model = rq;
      end
      RDMA_QUEUE_RUNTIME_SRQ: begin
        variant = "srq_pi"; relative_offset = XTR_V1_DB_SRFQ_OFFSET;
        srq = rdma_xtr_v1_srq_doorbell_model::type_id::create("srq_db_model");
        srq.target_h = projected_id_handle(target_h, local_id);
        srq.variant = XTR_V1_SRQ_DB_PI; srq.srqn = local_id;
        srq.pi = next.index; srq.wrap = next.wrap; model = srq;
      end
      default: begin
        status = bad("producer runtime kind is not a posting ring");
        return;
      end
    endcase
    codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_DOORBELL,
      object_type:"doorbell", variant:variant, opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    status = codec.encode(model, image);
    if (!status.ok()) return;
    desc = rdma_doorbell_desc::type_id::create("producer_db_desc");
    desc.kind = (kind == RDMA_QUEUE_RUNTIME_SQ) ? RDMA_DOORBELL_SQ :
                (kind == RDMA_QUEUE_RUNTIME_RQ) ? RDMA_DOORBELL_RQ :
                                                   RDMA_DOORBELL_SRQ;
    desc.function_h = binding.make_handle();
    desc.target_h = rdma_clone_handle_value(target_h, "producer DB target");
    desc.notify_bar_id = binding.notify_bar_id; desc.relative_offset = relative_offset;
    desc.width = XTR_V1_DB_BYTES; desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = image; desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0; desc.merge_requested = 1'b0;
    desc.timeout = operation_timeout; desc.readback_policy = RDMA_DB_READBACK_NONE;
    doorbells.submit(binding, desc, result, status);
  endtask

  // 功能：依据输入快照构造请求、资源或适配对象，并返回独立的结果载体（接口 make_entry_image）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status make_entry_image(
    byte data[], rdma_image_kind_e kind, int unsigned entry_size,
    output rdma_hw_image image
  );
    image = null;
    if (entry_size == 0 || data.size() != entry_size)
      return bad("queue entry byte count does not match attachment geometry",
                 RDMA_SC_DMA_TRANSLATION);
    image = rdma_hw_image::type_id::create("queue_entry_image");
    foreach (data[i]) image.bytes.push_back(data[i]);
    image.length = entry_size;
    image.alignment = entry_size;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = kind;
    image.hardware_version = XTR_V1_HW_VERSION;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return rdma_status::success();
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_qp_link_for_cq）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status find_qp_link_for_cq(
    rdma_handle cq_h, int unsigned qpn, bit rq_cqe,
    output rdma_queue_data_qp_link link
  );
    rdma_queue_data_qp_link candidate;
    link = null;
    foreach (qp_links[key]) begin
      candidate = qp_links[key];
      if (candidate == null || candidate.local_qp_id != qpn)
        continue;
      // A CQ can be shared by a QP's send and receive paths, and a QP may
      // use distinct CQs for each path.  Route using the CQE's receive bit;
      // accepting the opposite handle would release the wrong WQE ledger.
      if ((!rq_cqe && candidate.send_cq_h != null &&
           candidate.send_cq_h.same_instance(cq_h)) ||
          (rq_cqe && candidate.recv_cq_h != null &&
           candidate.recv_cq_h.same_instance(cq_h))) begin
        if (link != null)
          return bad("CQE QPN routes to multiple attached QPs",
                     RDMA_SC_INVALID_STATE);
        link = candidate;
      end
    end
    if (link == null)
      return bad("CQE QPN has no attached QP route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_qp_link_for_local_id）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status find_qp_link_for_local_id(
    int unsigned qpn, output rdma_queue_data_qp_link link
  );
    rdma_queue_data_qp_link candidate;
    link = null;
    foreach (qp_links[key]) begin
      candidate = qp_links[key];
      if (candidate != null && candidate.local_qp_id == qpn) begin
        if (link != null)
          return bad("event QPN routes to multiple attached QPs",
                     RDMA_SC_INVALID_STATE);
        link = candidate;
      end
    end
    if (link == null)
      return bad("event QPN has no attached QP route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：读取或查询当前对象的权威状态，并以返回值或 output 参数交付快照（接口 find_cq_handle_for_local_id）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status find_cq_handle_for_local_id(
    int unsigned cqn, output rdma_handle cq_h
  );
    rdma_queue_data_attachment candidate;
    cq_h = null;
    foreach (attachments[key]) begin
      candidate = attachments[key];
      if (candidate != null && candidate.kind == RDMA_QUEUE_RUNTIME_CQ &&
          candidate.local_id == cqn) begin
        if (cq_h != null)
          return bad("CEQE CQN routes to multiple attached CQs",
                     RDMA_SC_INVALID_STATE);
        cq_h = rdma_clone_handle_value(candidate.queue_h,
                                        "CEQE routed CQ");
        if (cq_h == null)
          cq_h = candidate.queue_h;
      end
    end
    if (cq_h == null)
      return bad("CEQE CQN has no attached CQ route", RDMA_SC_INVALID_STATE);
    return rdma_status::success();
  endfunction

  // 功能：把源对象投影/克隆为当前类型的独立值快照，避免共享可变引用（接口 clone_slot_result）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status clone_slot_result(
    rdma_queue_slot_ledger_entry source,
    output rdma_queue_slot_ledger_entry result
  );
    uvm_object cloned;
    result = null;
    if (source == null)
      return bad("released slot ledger entry is null", RDMA_SC_INVALID_STATE);
    result = rdma_queue_slot_ledger_entry::type_id::create("released_slot");
    result.posted = source.posted;
    result.consumed = source.consumed;
    result.signaled = source.signaled;
    result.wr_id = source.wr_id;
    result.index = source.index;
    result.wrap = source.wrap;
    if (source.request_snapshot != null) begin
      cloned = source.request_snapshot.clone();
      if (cloned == null || !$cast(result.request_snapshot, cloned)) begin
        result = null;
        return bad("released request snapshot clone failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      end
    end
    if (source.image != null) begin
      cloned = source.image.clone();
      if (cloned == null || !$cast(result.image, cloned)) begin
        result = null;
        return bad("released image snapshot clone failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      end
    end
    result.completion_status = rdma_clone_status_value(source.completion_status);
    return rdma_status::success();
  endfunction

  // 功能：执行接口 completion_status_from_ecode 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 completion_status_from_ecode）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status completion_status_from_ecode(
      bit [7:0] ecode, rdma_engine_kind_e observed_engine,
      output rdma_status completion_status
  );
    rdma_xtr_v1_error_codec error_codec;
    completion_status = null;
    error_codec = rdma_xtr_v1_error_codec::type_id::create("queue_error_codec");
    return error_codec.decode_status(ecode, observed_engine,
                                     completion_status);
  endfunction

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 submit_consumer_doorbell）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task submit_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_result result,
    output rdma_status status,
    output bit mmio_maybe_submitted,
    rdma_queue_data_qp_link routed_link
  );
    rdma_xtr_v1_cq_doorbell_model cq;
    rdma_xtr_v1_ceq_doorbell_model ceq;
    rdma_xtr_v1_aeq_doorbell_model aeq;
    rdma_hw_model model;
    rdma_hw_image image;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_doorbell_desc desc;
    rdma_queue_data_attachment sq_attachment;
    rdma_queue_data_attachment rq_attachment;
    rdma_queue_cursor_snapshot sq_cursor;
    rdma_queue_cursor_snapshot rq_cursor;
    rdma_status cursor_status;
    string variant;
    longint unsigned relative_offset;

    result = null;
    status = null;
    mmio_maybe_submitted = 1'b0;
    if (attachment == null || next == null) begin
      status = bad("consumer doorbell attachment/cursor is null");
      return;
    end
    case (attachment.kind)
      RDMA_QUEUE_RUNTIME_CQ: begin
        variant = (attachment.transport == RDMA_TRANSPORT_URC) ?
                  "cq_urc" : "cq_rc_ud";
        relative_offset = XTR_V1_DB_CQ_OFFSET;
        cq = rdma_xtr_v1_cq_doorbell_model::type_id::create("cq_ci_db_model");
        cq.target_h = projected_id_handle(attachment.queue_h,
                                          attachment.local_id);
        cq.variant = (variant == "cq_urc") ? XTR_V1_CQ_DB_URC :
                                               XTR_V1_CQ_DB_RC_UD;
        cq.cqn = attachment.local_id;
        cq.host_id = binding.host_id;
        cq.arm = 1'b0;
        cq.arm_state = 0;
        cq.arm_sn = 0;
        cq.ci = next.index;
        cq.wrap = next.wrap;
        // URC CQ notifications carry the WQ consumer cursors, not the CQ CI.
        // The CQE route identifies the QP whose completion is being consumed;
        // use that link explicitly so a shared CQ never aliases its own CI
        // into SQ/RQ fields.
        if (attachment.transport == RDMA_TRANSPORT_URC) begin
          if (routed_link == null)
            begin
              status = bad("URC CQ consumer doorbell has no QP route",
                           RDMA_SC_INVALID_STATE);
              return;
            end
          cursor_status = lookup_attachment(routed_link.qp_h,
                                             RDMA_QUEUE_RUNTIME_SQ,
                                             sq_attachment);
          if (!cursor_status.ok()) begin status = cursor_status; return; end
          cursor_status = sq_attachment.runtime.peek_consumer(sq_cursor);
          if (!cursor_status.ok()) begin status = cursor_status; return; end
          if (routed_link.srq_h != null)
            cursor_status = lookup_attachment(routed_link.srq_h,
                                               RDMA_QUEUE_RUNTIME_SRQ,
                                               rq_attachment);
          else
            cursor_status = lookup_attachment(routed_link.qp_h,
                                               RDMA_QUEUE_RUNTIME_RQ,
                                               rq_attachment);
          if (!cursor_status.ok()) begin status = cursor_status; return; end
          cursor_status = rq_attachment.runtime.peek_consumer(rq_cursor);
          if (!cursor_status.ok()) begin status = cursor_status; return; end
          cq.sq_ci = sq_cursor.index;
          cq.sq_wrap = sq_cursor.wrap;
          cq.rq_ci = rq_cursor.index;
          cq.rq_wrap = rq_cursor.wrap;
        end
        else begin
          cq.sq_ci = 0;
          cq.sq_wrap = 0;
          cq.rq_ci = 0;
          cq.rq_wrap = 0;
        end
        model = cq;
      end
      RDMA_QUEUE_RUNTIME_CEQ: begin
        variant = "ceq";
        relative_offset = XTR_V1_DB_CEQ_OFFSET;
        ceq = rdma_xtr_v1_ceq_doorbell_model::type_id::create("ceq_ci_db_model");
        ceq.target_h = projected_id_handle(attachment.queue_h,
                                           attachment.local_id);
        ceq.ceqn = attachment.local_id;
        ceq.ci = next.index;
        ceq.wrap = next.wrap;
        model = ceq;
      end
      RDMA_QUEUE_RUNTIME_AEQ: begin
        variant = "aeq";
        relative_offset = XTR_V1_DB_AEQ_OFFSET;
        aeq = rdma_xtr_v1_aeq_doorbell_model::type_id::create("aeq_ci_db_model");
        aeq.target_h = projected_id_handle(attachment.queue_h,
                                           attachment.local_id);
        aeq.aeqn = attachment.local_id;
        aeq.ci = next.index;
        aeq.wrap = next.wrap;
        model = aeq;
      end
      default: begin
        status = bad("consumer doorbell runtime kind is invalid");
        return;
      end
    endcase
    codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_DOORBELL,
      object_type:"doorbell", variant:variant, opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    status = codec.encode(model, image);
    if (!status.ok()) return;
    desc = rdma_doorbell_desc::type_id::create("consumer_db_desc");
    desc.kind = (attachment.kind == RDMA_QUEUE_RUNTIME_CQ) ? RDMA_DOORBELL_CQ :
                (attachment.kind == RDMA_QUEUE_RUNTIME_CEQ) ? RDMA_DOORBELL_CEQ :
                                                              RDMA_DOORBELL_AEQ;
    desc.function_h = binding.make_handle();
    desc.target_h = rdma_clone_handle_value(attachment.queue_h,
                                             "consumer DB target");
    desc.notify_bar_id = binding.notify_bar_id;
    desc.relative_offset = relative_offset;
    desc.width = XTR_V1_DB_BYTES;
    desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = image;
    desc.barrier_policy = RDMA_DB_BARRIER_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0;
    desc.merge_requested = 1'b0;
    desc.timeout = operation_timeout;
    desc.readback_policy = RDMA_DB_READBACK_NONE;
    // Once submit() is entered, the scheduler may have passed its preflight
    // and issued (or partially issued) the MMIO write before reporting an
    // error.  Preserve that ambiguity for recovery; failures above this
    // point are known-no-MMIO and may be retried after explicit confirmation.
    mmio_maybe_submitted = 1'b1;
    doorbells.submit(binding, desc, result, status);
  endtask

  // 功能：执行接口 poll_cqe_once 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_cqe_once）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task poll_cqe_once(
    rdma_handle cq_h,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment cq_attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_queue_data_qp_link link;
    rdma_queue_data_attachment wqe_attachment;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_xtr_v1_cqe_model cqe;
    rdma_queue_slot_ledger_entry released[$];
    rdma_queue_slot_ledger_entry released_copy;
    rdma_queue_pending_operation pending;
    rdma_handle result_qp_h;
    rdma_doorbell_result db_result;
    bit db_mmio_maybe_submitted;
    rdma_status local_status;
    rdma_status completion_status;
    byte data[];
    longint unsigned offset;
    string route_key;
    int unsigned released_count;

    result = null;
    status = null;
    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, cq_attachment);
    if (!status.ok()) return;
    status = cq_attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * cq_attachment.entry_size;
    status = cq_attachment.access.read(offset, cq_attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_CQE,
                              cq_attachment.entry_size, entry_image);
    if (!status.ok()) return;
    codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    status = codec.decode(entry_image, decoded_model);
    if (!status.ok()) return;
    if (!$cast(cqe, decoded_model) || cqe == null)
      begin status = bad("CQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR); return; end
    if (cqe.polarity != cq_attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "CQE owner polarity does not match CI");
      return;
    end
    status = find_qp_link_for_cq(cq_h, cqe.qpn, cqe.rq_cqe, link);
    if (!status.ok()) return;
    // Some simulators lose a class-handle output assigned from an associative
    // array traversal across a function boundary.  Re-resolve directly at
    // the transaction site as a defensive fallback; the same identity and
    // send/receive-CQ predicate is retained.
    if (link == null) begin
      foreach (qp_links[route_key]) begin
        if (qp_links[route_key] == null ||
            qp_links[route_key].local_qp_id != cqe.qpn)
          continue;
        if ((!cqe.rq_cqe && qp_links[route_key].send_cq_h != null &&
             qp_links[route_key].send_cq_h.same_instance(cq_h)) ||
            (cqe.rq_cqe && qp_links[route_key].recv_cq_h != null &&
             qp_links[route_key].recv_cq_h.same_instance(cq_h))) begin
          link = qp_links[route_key];
          break;
        end
      end
    end
    if (link == null) begin
      status = bad("CQE route has no QP link", RDMA_SC_INVALID_STATE);
      return;
    end
    // Snapshot the route handle before the doorbell task.  This keeps result
    // construction independent of any simulator-specific class-handle
    // lifetime/argument aliasing across task calls.
    result_qp_h = link.qp_h;
    if (cqe.rq_cqe) begin
      if (link.srq_h != null)
        status = lookup_attachment(link.srq_h, RDMA_QUEUE_RUNTIME_SRQ,
                                   wqe_attachment);
      else
        status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_RQ,
                                   wqe_attachment);
    end
    else begin
      status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                                  wqe_attachment);
    end
    if (!status.ok()) return;
    status = wqe_attachment.runtime.validate_release_range(cqe.wqe_index,
                                                           cqe.wqe_wrap);
    if (!status.ok()) return;
    status = completion_status_from_ecode(cqe.ecode,
      cqe.rq_cqe ? RDMA_ENGINE_RQ : RDMA_ENGINE_SQ, completion_status);
    if (!status.ok()) return;
    next = rdma_queue_cursor_snapshot::type_id::create("next_cq_cursor");
    next.index = cursor.index;
    next.wrap = cursor.wrap;
    if (next.index + 1 >= cq_attachment.runtime.depth) begin
      next.index = 0;
      next.wrap = ~next.wrap;
    end
    else next.index++;
    submit_consumer_doorbell(cq_attachment, next, db_result, status,
                             db_mmio_maybe_submitted, link);
    if (!status.ok()) begin
      // The CQ CI doorbell may have been submitted. Preserve a recovery
      // marker on the CQ runtime; do not advance CI or release the WQE ledger
      // until the caller resolves the pending operation.
      pending = make_pending(cursor, cq_h, RDMA_QUEUE_RUNTIME_CQ,
                            1'b0, offset, entry_image, null, 1'b0,
                            cqe.wqe_index, cqe.wqe_wrap, 1'b1,
                            1'b0, link.qp_h);
      void'(cq_attachment.runtime.enter_recovery(pending,
                                                  db_mmio_maybe_submitted));
      return;
    end
    status = wqe_attachment.runtime.match_and_release(cqe.wqe_index,
                                                       cqe.wqe_wrap, released);
    if (!status.ok()) begin
      rdma_queue_pending_operation pending;
      pending = make_pending(cursor, cq_h, RDMA_QUEUE_RUNTIME_CQ,
                            1'b0, offset, entry_image, null, 1'b0,
                            cqe.wqe_index, cqe.wqe_wrap, 1'b1,
                            1'b0, link.qp_h);
      void'(cq_attachment.runtime.enter_recovery(pending, 1'b1));
      return;
    end
    if (released.size() == 0) begin
      status = bad("CQE did not release an outstanding WQE",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (released[released.size()-1] == null) begin
      status = bad("CQE release returned a null WQE ledger entry",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    // The CI doorbell has succeeded and the corresponding producer ledger is
    // now released. Advance the CQ consumer cursor before publishing the
    // result; a failed local commit remains recoverable without releasing the
    // WQE a second time.
    status = cq_attachment.runtime.commit_consumer(cursor);
    if (!status.ok()) begin
      rdma_queue_pending_operation pending;
      pending = make_pending(cursor, cq_h, RDMA_QUEUE_RUNTIME_CQ,
                            1'b0, offset, entry_image, null, 1'b0,
                            cqe.wqe_index, cqe.wqe_wrap, 1'b1, 1'b1,
                            link.qp_h);
      void'(cq_attachment.runtime.enter_recovery(pending, 1'b1));
      return;
    end
    // Fill semantic fields from the linked WQE and detach every returned
    // ledger entry before exposing the result to the caller.
    // The linked QP handle is normally detached at attach time.  If a
    // malformed resource omitted it, the private WQ attachment still carries
    // the authoritative QP identity for SQ/RQ completions.
    if (result_qp_h != null) begin
      cqe.qp_h = rdma_clone_handle_value(result_qp_h, "CQE result QP");
      if (cqe.qp_h == null)
        cqe.qp_h = result_qp_h;
    end
    else if (!cqe.rq_cqe && wqe_attachment.queue_h != null)
      cqe.qp_h = rdma_clone_handle_value(wqe_attachment.queue_h,
                                          "CQE result QP fallback");
    else
      cqe.qp_h = null;
    if (cqe.qp_h == null && !cqe.rq_cqe && wqe_attachment.queue_h != null)
      cqe.qp_h = wqe_attachment.queue_h;
    if (cqe.qp_h == null) begin
      status = bad("CQE route has no QP handle", RDMA_SC_INVALID_STATE);
      return;
    end
    cqe.wr_id = released[released.size()-1].wr_id;
    if (released[released.size()-1].request_snapshot != null) begin
      rdma_post_send_req send_req;
      rdma_post_recv_req recv_req;
      if ($cast(send_req, released[released.size()-1].request_snapshot)) begin
        cqe.wr_id = send_req.wr_id;
        cqe.opcode = send_req.opcode;
      end
      else if ($cast(recv_req, released[released.size()-1].request_snapshot)) begin
        cqe.wr_id = recv_req.wr_id;
        cqe.opcode = RDMA_WR_RECV;
      end
    end
    result = rdma_queue_completion_result::type_id::create("cqe_result");
    result.queue_h = rdma_clone_handle_value(cq_h, "CQE result CQ");
    if (result.queue_h == null) result.queue_h = cq_h;
    result.cqe = cqe;
    result.completion_status = completion_status;
    foreach (released[i]) begin
      local_status = clone_slot_result(released[i], released_copy);
      if (!local_status.ok()) begin result = null; status = local_status; return; end
      released_copy.completion_status = rdma_clone_status_value(completion_status);
      result.released_slots.push_back(released_copy);
    end
    status = rdma_status::success();
  endtask

  // 功能：执行接口 poll_cqe 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_cqe）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task poll_cqe(
    rdma_handle cq_h, time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    time deadline;
    rdma_queue_completion_result candidate;
    rdma_status attempt;
    result = null;
    status = null;
    if (timeout != 0) begin
      deadline = $time + timeout;
      if (deadline < $time) begin
        status = bad("CQ poll deadline overflows simulation time");
        return;
      end
    end
    do begin
      candidate = null;
      attempt = null;
      poll_cqe_once(cq_h, candidate, attempt);
      if (attempt == null) begin
        status = bad("CQ poll returned null status", RDMA_SC_INVALID_STATE);
        return;
      end
      if (attempt.code != RDMA_SC_QUEUE_EMPTY || timeout == 0) begin
        status = attempt;
        if (attempt.ok()) result = candidate;
        return;
      end
      if ($time >= deadline) begin
        status = rdma_status::make(RDMA_SC_TIMEOUT,
                                   "CQ poll deadline expired");
        return;
      end
      #1ns;
    end while (1);
  endtask

  // 功能：执行接口 poll_ceqe_once 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_ceqe_once）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task poll_ceqe_once(
    rdma_handle ceq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_xtr_v1_ceqe_model ceqe;
    rdma_handle routed_cq_h;
    rdma_doorbell_result db_result;
    bit db_mmio_maybe_submitted;
    rdma_queue_data_qp_link no_route;
    byte data[];
    longint unsigned offset;

    result = null;
    status = lookup_attachment(ceq_h, RDMA_QUEUE_RUNTIME_CEQ, attachment);
    if (!status.ok()) return;
    status = attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * attachment.entry_size;
    status = attachment.access.read(offset, attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_CEQE, attachment.entry_size,
                              entry_image);
    if (!status.ok()) return;
    codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_CEQE,
      object_type:"ceqe", variant:"default", opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    status = codec.decode(entry_image, decoded_model);
    if (!status.ok()) return;
    if (!$cast(ceqe, decoded_model) || ceqe == null) begin
      status = bad("CEQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR);
      return;
    end
    if (ceqe.valid != attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "CEQE owner bit does not match CI");
      return;
    end
    status = find_cq_handle_for_local_id(ceqe.cqn, routed_cq_h);
    if (!status.ok()) return;
    next = rdma_queue_cursor_snapshot::type_id::create("next_ceq_cursor");
    next.index = cursor.index;
    next.wrap = cursor.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0; next.wrap = ~next.wrap;
    end else next.index++;
    submit_consumer_doorbell(attachment, next, db_result, status,
                             db_mmio_maybe_submitted, no_route);
    if (!status.ok()) begin
      rdma_queue_pending_operation pending;
      pending = make_pending(cursor, attachment.queue_h,
                            attachment.kind, 1'b0, offset, entry_image);
      void'(attachment.runtime.enter_recovery(pending,
                                               db_mmio_maybe_submitted));
      return;
    end
    status = attachment.runtime.commit_consumer(cursor);
    if (!status.ok()) return;
    result = rdma_queue_event_result::type_id::create("ceqe_result");
    result.queue_h = rdma_clone_handle_value(ceq_h, "CEQE result CEQ");
    if (result.queue_h == null) result.queue_h = ceq_h;
    ceqe.cq_h = routed_cq_h;
    result.event_model = ceqe;
    status = completion_status_from_ecode(ceqe.ecode, RDMA_ENGINE_CEQ,
                                          result.event_status);
    if (!status.ok()) begin result = null; return; end
    status = rdma_status::success();
  endtask

  // 功能：执行接口 poll_ceqe 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_ceqe）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task poll_ceqe(
    rdma_handle ceq_h, time timeout,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    time deadline;
    rdma_queue_event_result candidate;
    rdma_status attempt;
    result = null; status = null;
    if (timeout != 0) begin
      deadline = $time + timeout;
      if (deadline < $time) begin status = bad("CEQ poll deadline overflows simulation time"); return; end
    end
    do begin
      candidate = null; attempt = null;
      poll_ceqe_once(ceq_h, candidate, attempt);
      if (attempt == null) begin status = bad("CEQ poll returned null status", RDMA_SC_INVALID_STATE); return; end
      if (attempt.code != RDMA_SC_QUEUE_EMPTY || timeout == 0) begin
        status = attempt; if (attempt.ok()) result = candidate; return;
      end
      if ($time >= deadline) begin status = rdma_status::make(RDMA_SC_TIMEOUT, "CEQ poll deadline expired"); return; end
      #1ns;
    end while (1);
  endtask

  // 功能：执行接口 poll_aeqe_once 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_aeqe_once）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task poll_aeqe_once(
    rdma_handle aeq_h,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_queue_data_qp_link link;
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_hw_image entry_image;
    rdma_hw_model decoded_model;
    rdma_xtr_v1_aeqe_model aeqe;
    rdma_doorbell_result db_result;
    bit db_mmio_maybe_submitted;
    rdma_queue_data_qp_link no_route;
    byte data[];
    longint unsigned offset;

    result = null;
    status = lookup_attachment(aeq_h, RDMA_QUEUE_RUNTIME_AEQ, attachment);
    if (!status.ok()) return;
    status = attachment.runtime.peek_consumer(cursor);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * attachment.entry_size;
    status = attachment.access.read(offset, attachment.entry_size, data);
    if (!status.ok()) return;
    status = make_entry_image(data, RDMA_IMAGE_AEQE, attachment.entry_size,
                              entry_image);
    if (!status.ok()) return;
    codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_AEQE,
      object_type:"aeqe", variant:"default", opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    status = codec.decode(entry_image, decoded_model);
    if (!status.ok()) return;
    if (!$cast(aeqe, decoded_model) || aeqe == null) begin
      status = bad("AEQE codec returned the wrong model type", RDMA_SC_CODEC_ERROR);
      return;
    end
    if (aeqe.valid != attachment.runtime.expected_owner_polarity()) begin
      status = rdma_status::make(RDMA_SC_QUEUE_EMPTY,
                                 "AEQE owner bit does not match CI");
      return;
    end
    status = find_qp_link_for_local_id(aeqe.qpn, link);
    if (!status.ok()) return;
    aeqe.target_h = rdma_clone_handle_value(link.qp_h, "AEQE result QP");
    if (aeqe.target_h == null)
      aeqe.target_h = link.qp_h;
    next = rdma_queue_cursor_snapshot::type_id::create("next_aeq_cursor");
    next.index = cursor.index;
    next.wrap = cursor.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0; next.wrap = ~next.wrap;
    end else next.index++;
    submit_consumer_doorbell(attachment, next, db_result, status,
                             db_mmio_maybe_submitted, no_route);
    if (!status.ok()) begin
      rdma_queue_pending_operation pending;
      pending = make_pending(cursor, attachment.queue_h,
                            attachment.kind, 1'b0, offset, entry_image);
      void'(attachment.runtime.enter_recovery(pending,
                                               db_mmio_maybe_submitted));
      return;
    end
    status = attachment.runtime.commit_consumer(cursor);
    if (!status.ok()) return;
    result = rdma_queue_event_result::type_id::create("aeqe_result");
    result.queue_h = rdma_clone_handle_value(aeq_h, "AEQE result AEQ");
    if (result.queue_h == null) result.queue_h = aeq_h;
    result.event_model = aeqe;
    status = completion_status_from_ecode(aeqe.ecode, RDMA_ENGINE_AEQ,
                                          result.event_status);
    if (!status.ok()) begin result = null; return; end
    status = rdma_status::success();
  endtask

  // 功能：执行接口 poll_aeqe 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 poll_aeqe）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task poll_aeqe(
    rdma_handle aeq_h, time timeout,
    output rdma_queue_event_result result,
    output rdma_status status
  );
    time deadline;
    rdma_queue_event_result candidate;
    rdma_status attempt;
    result = null; status = null;
    if (timeout != 0) begin
      deadline = $time + timeout;
      if (deadline < $time) begin status = bad("AEQ poll deadline overflows simulation time"); return; end
    end
    do begin
      candidate = null; attempt = null;
      poll_aeqe_once(aeq_h, candidate, attempt);
      if (attempt == null) begin status = bad("AEQ poll returned null status", RDMA_SC_INVALID_STATE); return; end
      if (attempt.code != RDMA_SC_QUEUE_EMPTY || timeout == 0) begin
        status = attempt; if (attempt.ok()) result = candidate; return;
      end
      if ($time >= deadline) begin status = rdma_status::make(RDMA_SC_TIMEOUT, "AEQ poll deadline expired"); return; end
      #1ns;
    end while (1);
  endtask

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 post_send）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    rdma_post_send_req snapshot;
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_xtr_v1_sqe_model model;
    rdma_hw_image image;
    rdma_doorbell_result doorbell_result;
    rdma_queue_pending_operation pending;
    rdma_status recovery_status;
    rdma_status local_status;
    longint unsigned offset;

    result = null; status = null;
    if (request == null) begin status = bad("send request is null"); return; end
    snapshot = rdma_post_send_req::type_id::create("send_snapshot");
    snapshot.copy(request);
    status = snapshot.validate(); if (!status.ok()) return;
    status = lookup_attachment(snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                               attachment); if (!status.ok()) return;
    if (!qp_links.exists(identity_key(snapshot.qp_h)) ||
        qp_links[identity_key(snapshot.qp_h)] == null)
      begin status = bad("QP is not attached", RDMA_SC_INVALID_STATE); return; end
    link = qp_links[identity_key(snapshot.qp_h)];
    status = attachment.runtime.reserve_producer(cursor);
    if (!status.ok()) return;
    status = make_sqe(snapshot, link, cursor, model);
    if (!status.ok()) return;
    status = encode_queue_model(model, RDMA_IMAGE_SQE, "sqe",
      snapshot.transport == RDMA_TRANSPORT_RC ? "rc" :
      snapshot.transport == RDMA_TRANSPORT_UD ? "ud" : "urc", image);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * 64;
    status = write_and_verify(attachment, offset, image);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                            1'b1, offset, image, snapshot,
                            snapshot.signaled);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b0);
      return;
    end
    next = rdma_queue_cursor_snapshot::type_id::create("next_sq_cursor");
    next.index = cursor.index; next.wrap = cursor.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0; next.wrap = ~next.wrap;
    end else next.index++;
    submit_producer_doorbell(snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
      cursor, next, image, link.local_qp_id, doorbell_result, status);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                            1'b1, offset, image, snapshot,
                            snapshot.signaled);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b1);
      return;
    end
    status = attachment.runtime.commit_producer(cursor, snapshot,
      snapshot.wr_id, snapshot.signaled, image);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                            1'b1, offset, image, snapshot,
                            snapshot.signaled);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b1);
      return;
    end
    result = rdma_queue_post_result::type_id::create("send_result");
    result.queue_h = rdma_clone_handle_value(snapshot.qp_h, "send result QP");
    result.wr_id = snapshot.wr_id; result.index = cursor.index;
    result.wrap = cursor.wrap; result.image = image;
    result.status = rdma_status::success(); status = result.status;
  endtask

  // 功能：向目标后端提交数据/事务并更新本对象的进度或账本状态（接口 post_recv）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task post_recv(
    rdma_post_recv_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    rdma_post_recv_req snapshot;
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_queue_cursor_snapshot next;
    rdma_xtr_v1_rqe_model model;
    rdma_hw_image image;
    rdma_doorbell_result doorbell_result;
    rdma_queue_pending_operation pending;
    rdma_status recovery_status;
    rdma_handle completion_qp_h;
    string runtime_key;
    longint unsigned offset;

    result = null; status = null;
    if (request == null) begin status = bad("receive request is null"); return; end
    snapshot = rdma_post_recv_req::type_id::create("recv_snapshot");
    snapshot.copy(request); status = snapshot.validate();
    if (!status.ok()) return;
    completion_qp_h = (snapshot.target_h.kind == RDMA_RESOURCE_SRQ) ?
                      snapshot.completion_qp_h : snapshot.target_h;
    if (!qp_links.exists(identity_key(completion_qp_h)) ||
        qp_links[identity_key(completion_qp_h)] == null) begin
      status = bad("receive completion QP is not attached", RDMA_SC_INVALID_STATE);
      return;
    end
    link = qp_links[identity_key(completion_qp_h)];
    if (snapshot.target_h.kind == RDMA_RESOURCE_SRQ) begin
      if (link.srq_h == null || !link.srq_h.same_instance(snapshot.target_h)) begin
        status = bad("receive completion QP is not attached to the target SRQ");
        return;
      end
      status = lookup_attachment(snapshot.target_h, RDMA_QUEUE_RUNTIME_SRQ,
                                 attachment);
    end
    else begin
      status = lookup_attachment(snapshot.target_h, RDMA_QUEUE_RUNTIME_RQ,
                                 attachment);
    end
    if (!status.ok()) return;
    status = attachment.runtime.reserve_producer(cursor);
    if (!status.ok()) return;
    status = make_rqe(snapshot, link, cursor, model);
    if (!status.ok()) return;
    status = encode_queue_model(model, RDMA_IMAGE_RQE, "rqe", "default", image);
    if (!status.ok()) return;
    offset = longint'(cursor.index) * 64;
    status = write_and_verify(attachment, offset, image);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.target_h,
                            snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
                            RDMA_QUEUE_RUNTIME_SRQ : RDMA_QUEUE_RUNTIME_RQ,
                            1'b1, offset, image, snapshot, 1'b1);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b0);
      return;
    end
    next = rdma_queue_cursor_snapshot::type_id::create("next_rq_cursor");
    next.index = cursor.index; next.wrap = cursor.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0; next.wrap = ~next.wrap;
    end else next.index++;
    submit_producer_doorbell(snapshot.target_h,
      snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
      RDMA_QUEUE_RUNTIME_SRQ : RDMA_QUEUE_RUNTIME_RQ,
      cursor, next, null,
      snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
      attachment.local_id : link.local_qp_id, doorbell_result, status);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.target_h,
                            snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
                            RDMA_QUEUE_RUNTIME_SRQ : RDMA_QUEUE_RUNTIME_RQ,
                            1'b1, offset, image, snapshot, 1'b1);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b1);
      return;
    end
    status = attachment.runtime.commit_producer(cursor, snapshot,
      snapshot.wr_id, 1'b1, image);
    if (!status.ok()) begin
      pending = make_pending(cursor, snapshot.target_h,
                            snapshot.target_h.kind == RDMA_RESOURCE_SRQ ?
                            RDMA_QUEUE_RUNTIME_SRQ : RDMA_QUEUE_RUNTIME_RQ,
                            1'b1, offset, image, snapshot, 1'b1);
      recovery_status = attachment.runtime.enter_recovery(pending, 1'b1);
      return;
    end
    result = rdma_queue_post_result::type_id::create("recv_result");
    result.queue_h = rdma_clone_handle_value(snapshot.target_h,
                                              "receive result queue");
    result.wr_id = snapshot.wr_id; result.index = cursor.index;
    result.wrap = cursor.wrap; result.image = image;
    result.status = rdma_status::success(); status = result.status;
  endtask

  // 功能：执行接口 pending_next_cursor 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 pending_next_cursor）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected function rdma_status pending_next_cursor(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_queue_cursor_snapshot next
  );
    next = null;
    if (attachment == null || attachment.runtime == null || pending == null ||
        pending.cursor == null || attachment.runtime.depth == 0 ||
        pending.cursor.index >= attachment.runtime.depth)
      return bad("pending recovery cursor is invalid", RDMA_SC_INVALID_STATE);
    next = rdma_queue_cursor_snapshot::type_id::create("recovery_next_cursor");
    next.index = pending.cursor.index;
    next.wrap = pending.cursor.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0;
      next.wrap = ~next.wrap;
    end
    else
      next.index++;
    return rdma_status::success();
  endfunction

  // Re-execute the detached transaction only when the original operation is
  // known not to have reached MMIO.  The runtime remains RECOVERY_REQUIRED
  // until every side effect and ledger transition has completed.
  // 功能：执行接口 replay_pending 的职责逻辑，完成本对象对输入事务的处理和状态维护（接口 replay_pending）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  protected task replay_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation pending,
    output rdma_status status
  );
    rdma_queue_cursor_snapshot next;
    rdma_doorbell_result db_result;
    bit db_mmio_maybe_submitted;
    rdma_queue_data_qp_link link;
    rdma_queue_data_qp_link no_route;
    rdma_queue_data_attachment wqe_attachment;
    rdma_queue_slot_ledger_entry released[$];
    rdma_xtr_v1_cqe_model cqe;
    rdma_hw_model decoded_model;
    rdma_codec_base codec;
    rdma_codec_key codec_key;
    rdma_status local_status;
    byte data[];

    status = null;
    if (attachment == null || pending == null) begin
      status = bad("pending recovery attachment/evidence is null",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    status = pending_next_cursor(attachment, pending, next);
    if (!status.ok()) return;

    if (pending.producer) begin
      if (pending.image == null || pending.image.bytes.size() == 0) begin
        status = bad("producer recovery image is missing", RDMA_SC_INVALID_STATE);
        return;
      end
      // A known-no-MMIO producer failure is normally the queue write itself;
      // retry the exact detached image before issuing its doorbell.
      status = write_and_verify(attachment, pending.entry_offset,
                                pending.image);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(1'b0));
        return;
      end
      submit_producer_doorbell(pending.queue_h, pending.kind, pending.cursor,
                               next,
                               pending.kind == RDMA_QUEUE_RUNTIME_SQ ?
                               pending.image : null,
                               attachment.local_id, db_result, status);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(1'b1));
        return;
      end
      status = attachment.runtime.enable_recovery_commit();
      if (!status.ok()) return;
      status = attachment.runtime.commit_producer(
        pending.cursor, pending.request_snapshot, pending.wr_id,
        pending.signaled, pending.image);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(1'b1));
        return;
      end
      status = attachment.runtime.complete_recovery_retry();
      return;
    end

    // Consumer recovery does not rewrite an entry.  It replays the consumer
    // doorbell and commits the corresponding CI (and, for CQ, WQE release)
    // only after the MMIO transaction succeeds.
    if (attachment.kind == RDMA_QUEUE_RUNTIME_CQ) begin
      if (pending.image == null) begin
        status = bad("CQ recovery image is missing", RDMA_SC_INVALID_STATE);
        return;
      end
      codec_key = '{hw_version:"xtr_v1", image_kind:RDMA_IMAGE_CQE,
        object_type:"cqe", variant:"default", opcode:8'h00};
      status = registry.lookup(codec_key, codec);
      if (!status.ok()) return;
      status = codec.decode(pending.image, decoded_model);
      if (!status.ok()) return;
      if (!$cast(cqe, decoded_model) || cqe == null) begin
        status = bad("CQ recovery image decoded to the wrong model",
                     RDMA_SC_CODEC_ERROR);
        return;
      end
      link = null;
      if (pending.routed_qp_h != null)
        status = find_qp_link_for_local_id(pending.routed_qp_h.object_id,
                                           link);
      if (status == null || !status.ok() || link == null)
        status = find_qp_link_for_cq(pending.queue_h, cqe.qpn, cqe.rq_cqe,
                                     link);
      if (!status.ok()) return;
      if (cqe.rq_cqe) begin
        if (link.srq_h != null)
          status = lookup_attachment(link.srq_h, RDMA_QUEUE_RUNTIME_SRQ,
                                     wqe_attachment);
        else
          status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_RQ,
                                     wqe_attachment);
      end
      else
        status = lookup_attachment(link.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                                   wqe_attachment);
      if (!status.ok()) return;
      if (!pending.completion_released) begin
        status = wqe_attachment.runtime.validate_release_range(cqe.wqe_index,
                                                                cqe.wqe_wrap);
        if (!status.ok()) return;
      end
      submit_consumer_doorbell(attachment, next, db_result, status,
                               db_mmio_maybe_submitted, link);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          db_mmio_maybe_submitted));
        return;
      end
      if (!pending.completion_released) begin
        status = wqe_attachment.runtime.match_and_release(cqe.wqe_index,
                                                           cqe.wqe_wrap,
                                                           released);
        if (!status.ok()) begin
          void'(attachment.runtime.record_recovery_failure(1'b1));
          return;
        end
      end
      status = attachment.runtime.enable_recovery_commit();
      if (!status.ok()) return;
      status = attachment.runtime.commit_consumer(pending.cursor);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(1'b1));
        return;
      end
      status = attachment.runtime.complete_recovery_retry();
      return;
    end

    submit_consumer_doorbell(attachment, next, db_result, status,
                             db_mmio_maybe_submitted, no_route);
    if (!status.ok()) begin
      void'(attachment.runtime.record_recovery_failure(
        db_mmio_maybe_submitted));
      return;
    end
    status = attachment.runtime.enable_recovery_commit();
    if (!status.ok()) return;
    status = attachment.runtime.commit_consumer(pending.cursor);
    if (!status.ok()) begin
      void'(attachment.runtime.record_recovery_failure(1'b1));
      return;
    end
    status = attachment.runtime.complete_recovery_retry();
  endtask

  // 功能：推进对象的运行/复位/恢复状态机，并清晰隔离旧 incarnation 的操作（接口 recover_queue）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task recover_queue(
    rdma_handle queue_h,
    rdma_queue_recovery_action_e action,
    bit caller_confirmed_no_submit,
    output rdma_status status
  );
    rdma_queue_data_attachment candidate;
    rdma_queue_data_attachment found;
    string key;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (!status.ok()) return;
    found = null;
    foreach (attachments[key]) begin
      candidate = attachments[key];
      if (candidate != null && candidate.queue_h != null &&
          candidate.queue_h.same_instance(queue_h) && candidate.runtime != null &&
          candidate.runtime.state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
        if (found != null)
          begin status = bad("queue has multiple pending recovery runtimes",
                             RDMA_SC_INVALID_STATE); return; end
        found = candidate;
      end
    end
    if (found == null)
      begin status = bad("queue has no pending recovery", RDMA_SC_INVALID_STATE); return; end
    if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      status = found.runtime.abort_recovery();
      if (!status.ok()) return;
      // Drop all borrowed backing capabilities and QP routing metadata once
      // the caller chooses abort.  Lifecycle-owned DMA mappings remain owned
      // by the resource manager; only the data-engine attachment is removed.
      status = detach(queue_h);
      return;
    end
    if (action != RDMA_QUEUE_RECOVERY_RETRY_PENDING)
      begin status = bad("recovery action is invalid"); return; end
    if (!caller_confirmed_no_submit)
      begin status = bad("retry requires caller confirmation"); return; end
    begin
      rdma_queue_pending_operation pending;
      status = found.runtime.snapshot_pending(pending);
      if (!status.ok()) return;
      if (pending.mmio_maybe_submitted)
        begin status = rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                                          "pending MMIO outcome is ambiguous"); return; end
      replay_pending(found, pending, status);
      return;
    end
  endtask

endclass
