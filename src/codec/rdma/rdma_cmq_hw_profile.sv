// 目录：硬件编解码层 codec/rdma/rdma_cmq_hw_profile.sv。
// 职责：实现 rdma_hw_cmq_hw_profile 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_hw_profile.sv 属于编码层，将模型字段转换为硬件图像并执行反向校验。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_hw_cmq_hw_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_hw_cmq_hw_profile)

  protected rdma_hw_cmq_request_composer request_composer;
  protected rdma_hw_cmq_completion_codec completion_codec;
  protected rdma_hw_error_codec error_codec;
  protected rdma_hw_doorbell_codec_registry doorbell_codecs;
  protected rdma_status doorbell_registration_status;

  // 功能：构造 rdma_hw_cmq_hw_profile，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：request_composer=rdma_hw_cmq_request_composer::type_id::create(；completion_codec=rdma_hw_cmq_completion_codec::type_id::create(；error_codec=rdma_hw_error_codec::type_id::create("error_codec")；doorbell_registration_status=null；status=doorbell_codecs.register_defaults()；doorbell_registration_status=status。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_hw_profile 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_hw_profile");
    rdma_status status;
    super.new(name);
    request_composer = rdma_hw_cmq_request_composer::type_id::create(
      "request_composer");
    completion_codec = rdma_hw_cmq_completion_codec::type_id::create(
      "completion_codec");
    error_codec = rdma_hw_error_codec::type_id::create("error_codec");
    doorbell_codecs =
      rdma_hw_doorbell_codec_registry::type_id::create(
        "doorbell_codecs");
    doorbell_registration_status = null;
    if (doorbell_codecs != null) begin
      status = doorbell_codecs.register_defaults();
      doorbell_registration_status = status;
    end
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，profile_name 返回该实现声明的固定 profile/资源属性，供注册表和上层选择正确的 codec 或生命周期策略。
  // 输入/输出及副作用：无显式参数；profile_name 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：profile_name 是只读访问器，返回 "rdma"；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function string profile_name();
    return "rdma";
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，command_handle_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：handle（输入）；command_handle_value_key 读取 handle 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：command_handle_value_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string command_handle_value_key(rdma_handle handle);
    if (handle == null)
      return "<null-handle>";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，command_body_value_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：body（输入）；command_body_value_key 读取 body 并使用字段 result；函数返回 string，不取得调用方资源所有权。
  // 失败/边界：command_body_value_key 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  protected function string command_body_value_key(rdma_hw_model body);
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;
    string result;

    if (body == null)
      return "<null-body>";
    if ($cast(qpc_body, body)) begin
      result = $sformatf(
        "qpc:%s:%s:%s:%016h:%0d:%0b:%0b:%0h",
        command_handle_value_key(qpc_body.qp_h),
        command_handle_value_key(qpc_body.send_cq_h),
        command_handle_value_key(qpc_body.recv_cq_h),
        qpc_body.qpc_buffer.value, qpc_body.next_state,
        qpc_body.full_modify, qpc_body.partial_modify,
        qpc_body.wbe_template_count
      );
      foreach (qpc_body.modify_start_qword[i])
        result = {result,
                  $sformatf(":%02h:%02h:%016h",
                            qpc_body.modify_start_qword[i],
                            qpc_body.modify_wbe[i],
                            qpc_body.modify_data[i])};
      return result;
    end
    if ($cast(object_body, body))
      return {"object:", command_handle_value_key(object_body.object_h)};
    if ($cast(mr_body, body))
      return $sformatf("mr:%s:%02h:%0d",
                       command_handle_value_key(mr_body.mr_h),
                       mr_body.stag_key, mr_body.next_state);
    if ($cast(occ_body, body))
      return $sformatf(
        "occ:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%06h:%03h:%016h",
        occ_body.vf_flush, occ_body.mr_serial_flush, occ_body.qpc,
        occ_body.cqc, occ_body.mrt, occ_body.pble, occ_body.sqrqe,
        occ_body.sgb_irqe, occ_body.eirqe, occ_body.orqe, occ_body.uaqe,
        occ_body.pd, occ_body.qpn, occ_body.mr_serial,
        occ_body.pd_backing.value
      );
    if ($cast(empty_body, body))
      return "empty";
    return "";
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，append_command_body_nodes 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：body（输入）、nodes（引用）；append_command_body_nodes 可能更新本对象明确拥有的状态，并写入 nodes；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：append_command_body_nodes 无返回值，仅执行 函数体中的顺序操作；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void append_command_body_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;

    if (body == null)
      return;
    nodes.push_back(body);
    if ($cast(qpc_body, body)) begin
      if (qpc_body.qp_h != null) nodes.push_back(qpc_body.qp_h);
      if (qpc_body.send_cq_h != null) nodes.push_back(qpc_body.send_cq_h);
      if (qpc_body.recv_cq_h != null) nodes.push_back(qpc_body.recv_cq_h);
    end
    else if ($cast(object_body, body)) begin
      if (object_body.object_h != null) nodes.push_back(object_body.object_h);
    end
    else if ($cast(mr_body, body)) begin
      if (mr_body.mr_h != null) nodes.push_back(mr_body.mr_h);
    end
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中由 same_command_body_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_command_body_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null ||
        lhs.get_type_name() != rhs.get_type_name())
      return 1'b0;
    lhs_value = command_body_value_key(lhs);
    rhs_value = command_body_value_key(rhs);
    return lhs_value != "" && lhs_value == rhs_value;
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，command_body_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；command_body_graph_detached 读取 source、snapshot 并使用字段 source_nodes、snapshot_nodes、j；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：command_body_graph_detached 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit command_body_graph_detached(
    rdma_hw_model source,
    rdma_hw_model snapshot
  );
    uvm_object source_nodes[$];
    uvm_object snapshot_nodes[$];

    if (source == null || snapshot == null ||
        command_body_value_key(source) == "" ||
        command_body_value_key(snapshot) == "")
      return 1'b0;
    append_command_body_nodes(source, source_nodes);
    append_command_body_nodes(snapshot, snapshot_nodes);
    foreach (source_nodes[i])
      foreach (snapshot_nodes[j])
        if (source_nodes[i] == snapshot_nodes[j])
          return 1'b0;
    return 1'b1;
  endfunction

  // 功能：checked_command_handle_snapshot 复制 source、label、snapshot 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
  // 输入/输出及副作用：source（输入）、label（输入）、snapshot（输出）；checked_command_handle_snapshot 读取 source、label、snapshot 并使用字段 snapshot、source_type_name、saved_kind、saved_function_uid、saved_object_id、saved_generation、cloned_object、source.kind，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_command_handle_snapshot 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status checked_command_handle_snapshot(
    rdma_handle source,
    string label,
    output rdma_handle snapshot
  );
    uvm_object cloned_object;
    string source_type_name;
    rdma_resource_kind_e saved_kind;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;

    snapshot = null;
    if (source == null)
      return invalid_argument({label, " handle is null"});
    source_type_name = source.get_type_name();
    saved_kind = source.kind;
    saved_function_uid = source.function_uid;
    saved_object_id = source.object_id;
    saved_generation = source.generation;
    cloned_object = source.clone();
    source.kind = saved_kind;
    source.function_uid = saved_function_uid;
    source.object_id = saved_object_id;
    source.generation = saved_generation;
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return invalid_argument({label, " handle clone contract failed"});
    end
    if (source.kind != saved_kind ||
        source.function_uid != saved_function_uid ||
        source.object_id != saved_object_id ||
        source.generation != saved_generation ||
        snapshot.kind != saved_kind ||
        snapshot.function_uid != saved_function_uid ||
        snapshot.object_id != saved_object_id ||
        snapshot.generation != saved_generation) begin
      snapshot = null;
      return invalid_argument({label, " handle clone changed its value"});
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，clear_command_body_references 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：body（输入）、references（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_command_body_references 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function bit clear_command_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;

    references.delete();
    if ($cast(qpc_body, body)) begin
      references.push_back(qpc_body.qp_h);
      references.push_back(qpc_body.send_cq_h);
      references.push_back(qpc_body.recv_cq_h);
      qpc_body.qp_h = null;
      qpc_body.send_cq_h = null;
      qpc_body.recv_cq_h = null;
      return 1'b1;
    end
    if ($cast(object_body, body)) begin
      references.push_back(object_body.object_h);
      object_body.object_h = null;
      return 1'b1;
    end
    if ($cast(mr_body, body)) begin
      references.push_back(mr_body.mr_h);
      mr_body.mr_h = null;
      return 1'b1;
    end
    return $cast(occ_body, body) || $cast(empty_body, body);
  endfunction

  // 功能：执行 restore_command_body_references 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：body（输入）、references（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_command_body_references 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function bit restore_command_body_references(
    rdma_hw_model body,
    ref uvm_object references[$]
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;

    if ($cast(qpc_body, body) && references.size() == 3) begin
      if (!$cast(qpc_body.qp_h, references[0]) && references[0] != null)
        return 1'b0;
      if (!$cast(qpc_body.send_cq_h, references[1]) &&
          references[1] != null)
        return 1'b0;
      if (!$cast(qpc_body.recv_cq_h, references[2]) &&
          references[2] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(object_body, body) && references.size() == 1) begin
      if (!$cast(object_body.object_h, references[0]) &&
          references[0] != null)
        return 1'b0;
      return 1'b1;
    end
    if ($cast(mr_body, body) && references.size() == 1) begin
      if (!$cast(mr_body.mr_h, references[0]) && references[0] != null)
        return 1'b0;
      return 1'b1;
    end
    return references.size() == 0 &&
           ($cast(occ_body, body) || $cast(empty_body, body));
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，command_body_references_are_null 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：body（输入）；command_body_references_are_null 读取 body 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：command_body_references_are_null 先检查 $cast(qpc_body, body；$cast(object_body, body；$cast(mr_body, body，再返回 object_body.object_h == null；mr_body.mr_h == null；$cast(occ_body, body) || $cast(empty_body, body)；拒绝分支不提交部分状态，也不隐式重试。
  protected function bit command_body_references_are_null(
    rdma_hw_model body
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;

    if ($cast(qpc_body, body))
      return qpc_body.qp_h == null && qpc_body.send_cq_h == null &&
             qpc_body.recv_cq_h == null;
    if ($cast(object_body, body))
      return object_body.object_h == null;
    if ($cast(mr_body, body))
      return mr_body.mr_h == null;
    return $cast(occ_body, body) || $cast(empty_body, body);
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，snapshot_command_body 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_command_body 读取 source、snapshot 并使用字段 snapshot、source_type_name、saved_value、status、handle0_snapshot、handle1_snapshot、handle2_snapshot、source_wrapper，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_command_body 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    uvm_object cloned_object;
    rdma_status status;
    rdma_hw_qpc_command_body source_qpc;
    rdma_hw_qpc_command_body snapshot_qpc;
    rdma_hw_object_id_command_body source_object;
    rdma_hw_object_id_command_body snapshot_object;
    rdma_hw_mr_deregister_body source_mr;
    rdma_hw_mr_deregister_body snapshot_mr;
    rdma_hw_occ_flush_body source_occ;
    rdma_hw_cmq_empty_body source_empty;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    rdma_handle handle2_snapshot;
    string source_type_name;
    string saved_value;
    string saved_shell_value;
    uvm_object saved_object;
    uvm_object_wrapper source_wrapper;
    rdma_hw_model saved_body;
    uvm_object saved_references[$];

    snapshot = null;
    if (source == null)
      return invalid_argument("rdma CMQ command body is null");
    source_type_name = source.get_type_name();
    saved_value = command_body_value_key(source);
    if (saved_value == "" ||
        !($cast(source_qpc, source) || $cast(source_object, source) ||
          $cast(source_mr, source) || $cast(source_occ, source) ||
          $cast(source_empty, source)))
      return invalid_argument({"rdma CMQ command body type is unsupported: ",
                               source_type_name});
    status = source.validate();
    if (status == null)
      return invalid_argument("rdma CMQ body validation returned null");
    if (!status.ok())
      return status;
    handle0_snapshot = null;
    handle1_snapshot = null;
    handle2_snapshot = null;
    if (source_qpc != null) begin
      status = checked_command_handle_snapshot(
        source_qpc.qp_h, "rdma QPC command QP", handle0_snapshot
      );
      if (!status.ok()) return status;
      if (source_qpc.send_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.send_cq_h, "rdma QPC command send CQ",
          handle1_snapshot
        );
        if (!status.ok()) return status;
      end
      if (source_qpc.recv_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.recv_cq_h, "rdma QPC command receive CQ",
          handle2_snapshot
        );
        if (!status.ok()) return status;
      end
    end
    else if (source_object != null) begin
      status = checked_command_handle_snapshot(
        source_object.object_h, "rdma object-ID command",
        handle0_snapshot
      );
      if (!status.ok()) return status;
    end
    else if (source_mr != null) begin
      status = checked_command_handle_snapshot(
        source_mr.mr_h, "rdma MR deregister", handle0_snapshot
      );
      if (!status.ok()) return status;
    end
    if (!clear_command_body_references(source, saved_references))
      return invalid_argument("rdma CMQ body reference capture failed");
    source_wrapper = source.get_object_type();
    saved_object = (source_wrapper == null) ? null :
      source_wrapper.create_object("rdma_saved_body_shell");
    if (saved_object == null || !$cast(saved_body, saved_object)) begin
      void'(restore_command_body_references(source, saved_references));
      return invalid_argument("rdma CMQ body value capture failed");
    end
    saved_body.copy(source);
    saved_shell_value = command_body_value_key(saved_body);
    cloned_object = source.clone();
    source.copy(saved_body);
    if (!restore_command_body_references(source, saved_references)) begin
      snapshot = null;
      return invalid_argument("rdma CMQ body source restoration failed");
    end
    if (cloned_object == null || !$cast(snapshot, cloned_object) ||
        snapshot == source || snapshot.get_type_name() != source_type_name) begin
      snapshot = null;
      return invalid_argument("rdma CMQ body clone contract failed");
    end
    if (command_body_value_key(source) != saved_value ||
        command_body_value_key(snapshot) != saved_shell_value ||
        !command_body_references_are_null(snapshot)) begin
      snapshot = null;
      return invalid_argument("rdma CMQ body clone changed its value");
    end
    if (source_qpc != null) begin
      if (!$cast(snapshot_qpc, snapshot)) begin
        snapshot = null;
        return invalid_argument("rdma QPC body snapshot type is invalid");
      end
      snapshot_qpc.qp_h = handle0_snapshot;
      snapshot_qpc.send_cq_h = handle1_snapshot;
      snapshot_qpc.recv_cq_h = handle2_snapshot;
    end
    else if (source_object != null) begin
      if (!$cast(snapshot_object, snapshot)) begin
        snapshot = null;
        return invalid_argument(
          "rdma object-ID body snapshot type is invalid"
        );
      end
      snapshot_object.object_h = handle0_snapshot;
    end
    else if (source_mr != null) begin
      if (!$cast(snapshot_mr, snapshot)) begin
        snapshot = null;
        return invalid_argument("rdma MR body snapshot type is invalid");
      end
      snapshot_mr.mr_h = handle0_snapshot;
    end
    if (!command_body_graph_detached(source, snapshot)) begin
      snapshot = null;
      return invalid_argument("rdma CMQ body snapshot aliases its source");
    end
    status = snapshot.validate();
    if (status == null) begin
      snapshot = null;
      return invalid_argument("rdma CMQ snapshot validation returned null");
    end
    if (!status.ok())
      snapshot = null;
    return status;
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，snapshot_completion_payload 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）、snapshot（输出）；snapshot_completion_payload 读取 source、snapshot 并使用字段 snapshot、snapshot_payload、snapshot_payload.owner、snapshot_payload.opcode、snapshot_payload.command_ecode、snapshot_payload.wqe_index、snapshot_payload.wrap、snapshot_payload.object_payload，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_completion_payload 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    rdma_hw_cmq_completion source_payload;
    rdma_hw_cmq_completion snapshot_payload;

    snapshot = null;
    if (!$cast(source_payload, source))
      return invalid_argument(
        "rdma CMQ completion payload type is unsupported"
      );
    snapshot_payload = rdma_hw_cmq_completion::type_id::create(
      "rdma_completion_payload_snapshot"
    );
    if (snapshot_payload == null)
      return invalid_state("rdma completion payload allocation failed");
    snapshot_payload.owner = source_payload.owner;
    snapshot_payload.opcode = source_payload.opcode;
    snapshot_payload.command_ecode = source_payload.command_ecode;
    snapshot_payload.wqe_index = source_payload.wqe_index;
    snapshot_payload.wrap = source_payload.wrap;
    snapshot_payload.object_payload = source_payload.object_payload;
    snapshot = snapshot_payload;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中由 same_completion_payload_value 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_completion_payload_value 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    rdma_hw_cmq_completion lhs_payload;
    rdma_hw_cmq_completion rhs_payload;

    if (!$cast(lhs_payload, lhs) || !$cast(rhs_payload, rhs) ||
        lhs_payload.object_payload.size() !=
          rhs_payload.object_payload.size())
      return 1'b0;
    foreach (lhs_payload.object_payload[i])
      if (lhs_payload.object_payload[i] != rhs_payload.object_payload[i])
        return 1'b0;
    return lhs_payload.owner == rhs_payload.owner &&
           lhs_payload.opcode == rhs_payload.opcode &&
           lhs_payload.command_ecode == rhs_payload.command_ecode &&
           lhs_payload.wqe_index == rhs_payload.wqe_index &&
           lhs_payload.wrap == rhs_payload.wrap;
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，completion_payload_graph_detached 检查嵌套 body/graph 引用是否已经 detached，防止编码或恢复阶段残留可变别名。
  // 输入/输出及副作用：source（输入）、snapshot（输入）；completion_payload_graph_detached 读取 source、snapshot 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：completion_payload_graph_detached 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    rdma_hw_cmq_completion source_payload;
    rdma_hw_cmq_completion snapshot_payload;

    return $cast(source_payload, source) &&
           $cast(snapshot_payload, snapshot) &&
           source_payload != snapshot_payload;
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，doorbell_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：variant（输入）；doorbell_key 读取 variant 并使用字段 key.hw_version、key.image_kind、key.object_type、key.variant、key.opcode；函数返回 rdma_codec_key，不取得调用方资源所有权。
// 失败/边界：doorbell_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function rdma_codec_key doorbell_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  // 功能：validate_profile 校验 当前对象字段 与当前对象状态的一致性，并显式处理“cmq_sq”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate_profile 读取 对象字段：variants、rdma_status、request_composer、completion_codec、error_codec、doorbell_codecs 并使用字段 codec、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_profile 返回 函数体规定的失败状态；具体拒绝条件包括 “rdma CMQ request composer is not initialized”；“rdma CMQ completion codec is not initialized”；“rdma error codec is not initialized”；“rdma doorbell registry is not initialized”；“rdma doorbell default registration failed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate_profile();
    string variants[13] = '{
      "cmq_sq", "sq", "rq", "srq_pi", "srq_limit", "cq_rc_ud",
      "cq_urc", "ceq", "aeq", "rts2sqd", "sqd2rts", "qp_flush",
      "tx_flush"
    };
    rdma_codec_base codec;
    rdma_status status;

    if (request_composer == null)
      return invalid_state("rdma CMQ request composer is not initialized");
    if (completion_codec == null)
      return invalid_state("rdma CMQ completion codec is not initialized");
    if (error_codec == null)
      return invalid_state("rdma error codec is not initialized");
    if (doorbell_codecs == null)
      return invalid_state("rdma doorbell registry is not initialized");
    if (doorbell_registration_status == null)
      return invalid_state("rdma doorbell default registration failed");
    if (!doorbell_registration_status.ok())
      return doorbell_registration_status;
    status = rdma_cmq_codec_registry::validate();
    if (!status.ok())
      return status;
    foreach (variants[i]) begin
      codec = null;
      status = doorbell_codecs.lookup(doorbell_key(variants[i]), codec);
      if (!status.ok() || codec == null)
        return invalid_state({"rdma doorbell defaults are incomplete: ",
                              variants[i]});
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中比较两份 Function identity 的 Host/root、PF/VF、BDF 和 global_function_id，判断是否代表同一
  //   Function。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；lhs/rhs 只读，返回 bit，不更新 authority 或资源账本。
  // 失败/边界：same_function 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_function(
    rdma_function_handle lhs,
    rdma_function_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id &&
           lhs.generation == rhs.generation;
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，generationless_opcode 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：opcode（输入）；generationless_opcode 读取 opcode 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：generationless_opcode 的结果直接由 return opcode inside {RDMA_OP_OCC_FLUSH, RDMA_OP_TQ_FLUSH} 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function bit generationless_opcode(bit [7:0] opcode);
    return opcode inside {RDMA_OP_OCC_FLUSH, RDMA_OP_TQ_FLUSH} ||
           rdma_cmq_codec_registry::is_generationless(opcode);
  endfunction

  // 功能：validate_composed_sqe 校验 image、opcode、function_generation 与当前对象状态的一致性，并显式处理“rdma CMQ request composer published null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：image（输入）、opcode（输入）、function_generation（输入）；validate_composed_sqe 读取 image、opcode、function_generation 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_composed_sqe(
    rdma_hw_image image,
    bit [7:0] opcode,
    int unsigned function_generation
  );
    if (image == null)
      return invalid_state("rdma CMQ request composer published null");
    if (image.length != RDMA_CMQE_BYTES ||
        image.bytes.size() != RDMA_CMQE_BYTES ||
        image.alignment != RDMA_CMQE_BYTES ||
        image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_CMQ_SQE ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.write_target_kind != RDMA_HW_TARGET_NONE ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        image.bar_target.value != 0)
      return rdma_status::make(
        RDMA_SC_CODEC_ERROR,
        "rdma CMQ request composer published invalid metadata"
      );
    if (generationless_opcode(opcode)) begin
      if (image.function_generation != 0)
        return rdma_status::make(
          RDMA_SC_CODEC_ERROR,
          "rdma generationless CMQ body published a generation"
        );
    end
    else if (image.function_generation != function_generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "rdma CMQ body generation does not match Function"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，compose_sqe 按 profile 的字段布局和端序把语义模型编码为硬件镜像，并在发布前检查长度与对齐。
  // 输入/输出及副作用：command（输入）、slot（输入）、sqe（输出）、expected（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：模型为空、字段越界、保留位非零或输出长度不足时返回编码错误，不发布部分图像。
  virtual function rdma_status compose_sqe(
    rdma_cmq_command_desc command,
    rdma_cmq_slot_context slot,
    output rdma_hw_image sqe,
    output rdma_cmq_expected_response expected
  );
    rdma_status status;
    rdma_hw_image body;
    rdma_hw_image composed;
    rdma_hw_image detached;
    rdma_hw_cmq_envelope envelope;
    rdma_cmq_expected_response candidate_expected;
    bit [7:0] opcode;
    longint unsigned target_address;

    sqe = null;
    expected = null;
    status = validate_profile();
    if (!status.ok()) return status;
    if (command == null)
      return invalid_argument("rdma CMQ command is null");
    if (slot == null)
      return invalid_argument("rdma CMQ slot is null");
    status = command.validate();
    if (!status.ok()) return status;
    status = slot.validate();
    if (!status.ok()) return status;
    if (!same_function(command.function_h, slot.function_h))
      return invalid_argument(
        "rdma CMQ command and slot Functions do not match"
      );
    if (command.opcode_key.profile_name != profile_name())
      return invalid_argument("CMQ command selects a different profile");
    if (command.opcode_key.opcode[31:8] != 0)
      return invalid_argument("rdma CMQ opcode exceeds 8 bits");

    // 驱动在 QPC_CREATE 路径把 VFID_OVERRIDE 与 USE_VFID 固定为零；
    // 非零输入必须在 body/image 构造前拒绝，避免发布不可达请求。
    if (command.opcode_key.opcode[7:0] == RDMA_OP_QPC_CREATE &&
        (command.vfid_override || command.use_vfid != 0))
      return invalid_argument(
        "QPC_CREATE driver-fixed VFID fields must remain zero"
      );

    if (!command.vfid_override && command.use_vfid != 0)
      return invalid_argument("rdma CMQ VFID requires override");
    if (slot.backing_addr.value >
        (64'hffff_ffff_ffff_ffff - slot.relative_offset))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "rdma CMQ SQE backing target overflows"
      );

    opcode = command.opcode_key.opcode[7:0];
    body = null;
    status = request_composer.build_body(opcode, command.body, body);
    if (!status.ok()) return status;
    if (body == null)
      return invalid_state("rdma CMQ body composer published null");

    envelope = rdma_hw_cmq_envelope::type_id::create("envelope");
    envelope.valid = !slot.sq_wrap;
    envelope.vfid_override = command.vfid_override;
    envelope.use_vfid = command.use_vfid;
    envelope.wrap = slot.sq_wrap;
    envelope.wqe_index = slot.sq_index[4:0];
    envelope.opcode = opcode;
    composed = null;
    status = request_composer.compose_request(
      envelope, body, command.qpc_signature_source, composed
    );
    if (!status.ok()) return status;
    status = validate_composed_sqe(
      composed, opcode, command.function_h.generation
    );
    if (!status.ok()) return status;

    detached = rdma_hw_image::type_id::create("detached_sqe");
    detached.copy(composed);
    if (generationless_opcode(opcode))
      detached.function_generation = command.function_h.generation;
    target_address = slot.backing_addr.value + slot.relative_offset;
    detached.write_target_kind = RDMA_HW_TARGET_BACKING;
    detached.backing_target.value = target_address;
    detached.hmc_target = '0;
    detached.bar_target = '0;

    candidate_expected = rdma_cmq_expected_response::type_id::create(
      "expected_response");
    candidate_expected.hardware_opcode = {24'h0, opcode};
    candidate_expected.variant = command.opcode_key.variant;
    sqe = detached;
    expected = candidate_expected;
    return rdma_status::success();
  endfunction

  // 功能：validate_raw_cqe 校验 raw_cqe 与当前对象状态的一致性，并显式处理“CMQ raw CQE is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：raw_cqe（输入）；validate_raw_cqe 读取 raw_cqe 并使用字段 rdma_status、value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_raw_cqe(rdma_hw_image raw_cqe);
    if (raw_cqe == null)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE is null");
    if (raw_cqe.length != RDMA_CMQE_BYTES ||
        raw_cqe.bytes.size() != RDMA_CMQE_BYTES)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE length is invalid");
    if (raw_cqe.image_kind != RDMA_IMAGE_CMQ_CQE ||
        raw_cqe.write_target_kind != RDMA_HW_TARGET_NONE ||
        raw_cqe.backing_target.value != 0 ||
        raw_cqe.hmc_target.value != 0 || raw_cqe.bar_target.value != 0)
      return rdma_status::make(RDMA_SC_CODEC_ERROR,
                               "CMQ raw CQE metadata is invalid");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，inspect_cqe 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：raw_cqe（输入）、expected_owner（输入）、ready（输出）、decoded（输出）；inspect_cqe 读取 raw_cqe、expected_owner、ready、decoded 并使用字段 ready、decoded、status、completion、completion_ready、command_status、cloned_object、candidate，并写入 ready、decoded；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：inspect_cqe 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“rdma completion codec published null”“rdma error codec published null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status inspect_cqe(
    rdma_hw_image raw_cqe,
    bit expected_owner,
    output bit ready,
    output rdma_cmq_decoded_cqe decoded
  );
    rdma_status status;
    rdma_status command_status;
    rdma_hw_cmq_completion completion;
    rdma_hw_cmq_completion payload;
    rdma_cmq_decoded_cqe candidate;
    uvm_object cloned_object;
    bit completion_ready;

    ready = 1'b0;
    decoded = null;
    status = validate_profile();
    if (!status.ok()) return status;
    status = validate_raw_cqe(raw_cqe);
    if (!status.ok()) return status;
    completion = null;
    completion_ready = 1'b0;
    status = completion_codec.inspect_completion(
      raw_cqe, expected_owner, completion_ready, completion
    );
    if (!status.ok()) return status;
    if (!completion_ready) return rdma_status::success();
    if (completion == null)
      return invalid_state("rdma completion codec published null");

    command_status = null;
    status = error_codec.decode_status(completion.command_ecode,
                                       RDMA_ENGINE_CMQ, command_status);
    if (!status.ok()) return status;
    if (command_status == null)
      return invalid_state("rdma error codec published null");
    cloned_object = completion.clone();
    if (cloned_object == null || !$cast(payload, cloned_object))
      return invalid_state("rdma completion payload clone failed");

    candidate = rdma_cmq_decoded_cqe::type_id::create("decoded_cqe");
    if (candidate == null)
      return invalid_state("rdma decoded CQE allocation failed");
    candidate.hardware_opcode = {24'h0, completion.opcode};
    candidate.wqe_index = completion.wqe_index;
    candidate.wqe_wrap = completion.wrap;
    candidate.hardware_ecode = {24'h0, completion.command_ecode};
    candidate.command_status = command_status;
    candidate.response_payload = payload;
    status = candidate.validate();
    if (!status.ok()) return status;
    decoded = candidate;
    ready = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_hw_cmq_hw_profile 中，encode_doorbell 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：cmq_h（输入）、final_pi（输入）、polarity（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整 image/bytes，不修改源模型。
  // 失败/边界：encode_doorbell 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  virtual function rdma_status encode_doorbell(
    rdma_handle cmq_h,
    int unsigned final_pi,
    bit polarity,
    output rdma_hw_image image
  );
    rdma_status status;
    rdma_hw_cmq_sq_doorbell_model model;
    rdma_hw_image encoded;
    rdma_hw_image detached;
    uvm_object cloned_object;

    image = null;
    status = validate_profile();
    if (!status.ok()) return status;
    if (cmq_h == null || cmq_h.kind != RDMA_RESOURCE_CMQ)
      return invalid_argument("rdma CMQ doorbell handle is invalid");
    if (final_pi >= 32)
      return invalid_argument("rdma CMQ doorbell PI exceeds 5 bits");

    model = rdma_hw_cmq_sq_doorbell_model::type_id::create(
      "cmq_sq_doorbell");
    cloned_object = cmq_h.clone();
    if (cloned_object == null || !$cast(model.target_h, cloned_object))
      return invalid_state("rdma CMQ doorbell handle clone failed");
    model.pi = final_pi;
    model.polarity = polarity;
    encoded = null;
    status = doorbell_codecs.encode(model, encoded);
    if (!status.ok()) return status;
    if (encoded == null)
      return invalid_state("rdma doorbell codec published null");
    detached = rdma_hw_image::type_id::create("detached_doorbell");
    detached.copy(encoded);
    image = detached;
    return rdma_status::success();
  endfunction
endclass
