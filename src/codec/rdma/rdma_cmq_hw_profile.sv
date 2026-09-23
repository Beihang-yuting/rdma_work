// 目录/层次：codec/rdma 层的 X722/0.1.34 CMQ hardware profile 实现。
// 职责：组合 CMQ request/completion/error/doorbell codec，实现 RDMA SQE/CQE/doorbell
// 编解码，并为五种具体 body 和 completion payload 提供类型化快照/序列化边界。
// 主要依赖：rdma_cmq_hw_profile 抽象契约、rdma_cmq_codec_registry、RDMA CMQ body/
// completion codec 以及 model 层 canonical writer；不直接执行 DMA 或 MMIO。
// 所有权与生命周期：profile 拥有构造的四类 codec/registry 句柄及注册 status；
// command/body/image 为非拥有输入，成功快照和编码 image 由调用方拥有。

// 设计说明：production profile 固定 X722/0.1.34 的五种 body schema 与 codec 组合；
// 显式类型 dispatch 和直接构造保证 nonfatal snapshot 不受 UVM factory override 影响。
class rdma_hw_cmq_hw_profile extends rdma_cmq_hw_profile;
  `uvm_object_utils(rdma_hw_cmq_hw_profile)

  protected rdma_hw_cmq_request_composer request_composer;
  protected rdma_hw_cmq_completion_codec completion_codec;
  protected rdma_hw_error_codec error_codec;
  protected rdma_hw_doorbell_codec_registry doorbell_codecs;
  protected rdma_status doorbell_registration_status;

  // 功能：构造 RDMA CMQ profile 的 request/completion/error codec 和 doorbell registry，
  //   并注册默认 doorbell variants。
  // 输入/输出及副作用：name 设置 UVM 实例名；四个 child 通过 factory 创建，
  // registry 非空时执行 register_defaults() 并保留其精确 status。
  // 失败/边界：任一 child 缺失或默认注册返回 null/错误时构造仍完成，
  // validate_profile() 后续以 INVALID_STATE 或保留 status 拒绝使用。
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

  // 功能：返回 opcode key 和 codec registry 共用的稳定 profile 名“rdma”。
  // 输入/输出及副作用：无参数；返回 string literal 值，不读写对象字段。
  // 失败/边界：无失败分支；名称不随 hardware version 或具体 opcode 变化。
  virtual function string profile_name();
    return "rdma";
  endfunction

  // 功能：为 profile 输入契约违例构造 RDMA_SC_INVALID_ARGUMENT status。
  // 输入/输出及副作用：message 原样写入新 status；返回对象由调用方持有，不修改 profile。
  // 失败/边界：空 message 仍生成有效 INVALID_ARGUMENT status；本 helper 不包装硬件 ecode。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：为 profile/codec 未就绪或输出违反内部契约构造 INVALID_STATE status。
  // 输入/输出及副作用：message 原样写入新 status；不修改 registry 或 codec 状态。
  // 失败/边界：空 message 仍返回非 OK INVALID_STATE；本 helper 不将错误降级或重试。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：把 handle 的 kind/Function UID/object ID/generation 组成 body 值比较专用文本片段。
  // 输入/输出及副作用：handle 为非拥有只读输入；返回固定宽度十六进制 string，
  // 不修改句柄或注册任何 key。
  // 失败/边界：null 返回明确的 "<null-handle>" sentinel；本 helper 仅用于类型化
  // 相等比较，不可作为安全/恢复 digest。
  protected function string command_handle_value_key(rdma_handle handle);
    if (handle == null)
      return "<null-handle>";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：使用与 CQC_CREATE 相同的驱动 codec，把 CQC context 的 64B wire
  //   projection 转成稳定十六进制值，供 CQC_DELETE body 的值比较使用。
  // 输入/输出及副作用：context 为非拥有只读输入；返回包含所有已编码 context
  //   bytes 的 string，不修改 context、profile 或外部资源。
  // 失败/边界：null、非 exact rdma_cqc_model、codec/metadata/长度校验失败时
  //   返回明确的 invalid sentinel；调用方必须把该 sentinel 视为不可比较。
  protected function string cqc_context_value_key(rdma_cqc_model ctx_snapshot);
    rdma_hw_cqc_create_body_codec codec;
    rdma_hw_image image;
    rdma_status status;
    string result;

    if (ctx_snapshot == null ||
        ctx_snapshot.get_object_type() != rdma_cqc_model::get_type())
      return "<invalid-cqc-context>";
    codec = new("cmq_cqc_context_value_codec");
    image = null;
    status = codec.encode(ctx_snapshot, image);
    if (status == null || !status.ok() || image == null ||
        image.length != 64 || image.bytes.size() != 64 ||
        image.image_kind != RDMA_IMAGE_CQC ||
        image.endian != RDMA_ENDIAN_BIG)
      return "<invalid-cqc-context>";
    result = "CQC-CONTEXT-WIRE-V1:";
    foreach (image.bytes[i])
      result = {result, $sformatf("%02x", image.bytes[i])};
    return result;
  endfunction

  // 功能：将五种受支持 CMQ body 的全部标量/句柄字段投影为可比较文本。
  // 输入/输出及副作用：body 为非拥有只读输入；返回 QPC/object/MR/OCC/empty
  // 的类型化值投影，不保存 body 或嵌套 handle。
  // 失败/边界：null 返回 "<null-body>"；未知 subtype 返回空串；本文本只用于
  // snapshot 值验证，不是 canonical V1 字节或 journal authority。
  protected function string command_body_value_key(rdma_hw_model body);
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_cqc_delete_body cqc_delete_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;
    uvm_object_wrapper body_type;
    string result;

    if (body == null)
      return "<null-body>";
    body_type = body.get_object_type();
    if (body_type == rdma_hw_qpc_command_body::get_type() &&
        $cast(qpc_body, body)) begin
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
    if (body_type == rdma_hw_cqc_delete_body::get_type() &&
        $cast(cqc_delete_body, body)) begin
      return $sformatf(
        "cqc-delete:%s:%s:%s",
        command_handle_value_key(cqc_delete_body.cqc_context == null ?
                                 null : cqc_delete_body.cqc_context.cq_h),
        command_handle_value_key(cqc_delete_body.cqc_context == null ?
                                 null : cqc_delete_body.cqc_context.ceq_h),
        cqc_context_value_key(cqc_delete_body.cqc_context)
      );
    end
    if (body_type == rdma_hw_object_id_command_body::get_type() &&
        $cast(object_body, body))
      return {"object:", command_handle_value_key(object_body.object_h)};
    if (body_type == rdma_hw_mr_deregister_body::get_type() &&
        $cast(mr_body, body))
      return $sformatf("mr:%s:%02h:%0d",
                       command_handle_value_key(mr_body.mr_h),
                       mr_body.stag_key, mr_body.next_state);
    if (body_type == rdma_hw_occ_flush_body::get_type() &&
        $cast(occ_body, body))
      return $sformatf(
        "occ:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%0b:%06h:%03h:%016h",
        occ_body.vf_flush, occ_body.mr_serial_flush, occ_body.qpc,
        occ_body.cqc, occ_body.mrt, occ_body.pble, occ_body.sqrqe,
        occ_body.sgb_irqe, occ_body.eirqe, occ_body.orqe, occ_body.uaqe,
        occ_body.pd, occ_body.qpn, occ_body.mr_serial,
        occ_body.pd_backing.value
      );
    if (body_type == rdma_hw_cmq_empty_body::get_type() &&
        $cast(empty_body, body))
      return "empty";
    return "";
  endfunction

  // 功能：枚举 body 图中必须与 snapshot 分离的外层节点和嵌套 handle。
  // 输入/输出及副作用：body 只读，nodes 为调用方 queue；非空 body 首先追加自身，
  // 再对 QPC/object/MR body 追加其非空句柄，不修改 profile。
  // 失败/边界：null body 是无操作；OCC/empty 无嵌套对象；未知 body 仅追加外层，
  // 后续 command_body_value_key()=="" 会使 detachment 检查失败。
  protected function void append_command_body_nodes(
    rdma_hw_model body,
    ref uvm_object nodes[$]
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_cqc_delete_body cqc_delete_body;
    rdma_hw_mr_deregister_body mr_body;

    if (body == null)
      return;
    nodes.push_back(body);
    if ($cast(cqc_delete_body, body)) begin
      if (cqc_delete_body.cqc_context != null) begin
        nodes.push_back(cqc_delete_body.cqc_context);
        if (cqc_delete_body.cqc_context.cq_h != null)
          nodes.push_back(cqc_delete_body.cqc_context.cq_h);
        if (cqc_delete_body.cqc_context.ceq_h != null)
          nodes.push_back(cqc_delete_body.cqc_context.ceq_h);
        if (cqc_delete_body.cqc_context.page_layout != null)
          nodes.push_back(cqc_delete_body.cqc_context.page_layout);
        if (cqc_delete_body.cqc_context.producer != null)
          nodes.push_back(cqc_delete_body.cqc_context.producer);
        if (cqc_delete_body.cqc_context.consumer != null)
          nodes.push_back(cqc_delete_body.cqc_context.consumer);
      end
    end
    else if ($cast(qpc_body, body)) begin
      if (qpc_body.qp_h != null)
        nodes.push_back(qpc_body.qp_h);
      if (qpc_body.send_cq_h != null)
        nodes.push_back(qpc_body.send_cq_h);
      if (qpc_body.recv_cq_h != null)
        nodes.push_back(qpc_body.recv_cq_h);
    end
    else if ($cast(object_body, body)) begin
      if (object_body.object_h != null)
        nodes.push_back(object_body.object_h);
    end
    else if ($cast(mr_body, body)) begin
      if (mr_body.mr_h != null)
        nodes.push_back(mr_body.mr_h);
    end
  endfunction

  // 功能：对 exact 同类型 RDMA CMQ body 比较完整字段投影，验证 snapshot 值不漂移。
  // 输入/输出及副作用：lhs/rhs 只读；先要求注册 wrapper 身份一致，再比较
  // command_body_value_key() 的非空结果，不修改任一 body。
  // 失败/边界：任一句柄为 null、wrapper 不同或未知 subtype 投影为空时返回 0；
  //   可覆盖 get_type_name 不参与判断，本检查不证明图已 detached。
  virtual function bit same_command_body_value(
    rdma_hw_model lhs,
    rdma_hw_model rhs
  );
    string lhs_value;
    string rhs_value;

    if (lhs == null || rhs == null ||
        lhs.get_object_type() != rhs.get_object_type())
      return 1'b0;
    lhs_value = command_body_value_key(lhs);
    rhs_value = command_body_value_key(rhs);
    return lhs_value != "" && lhs_value == rhs_value;
  endfunction

  // 功能：确认 source/snapshot 的外层 body 和所有受支持嵌套 handle 没有交叉别名。
  // 输入/输出及副作用：只读两个 body 图，各自收集节点后做笛卡尔句柄比较；
  // 无任一共享节点时返回 1，不保存临时 queue。
  // 失败/边界：任一 body 为 null/未知类型或发现外层/嵌套句柄相同时返回 0；
  // 本检查不替代字段值相等检查。
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

  // 功能：直接复制 body 嵌套 handle，保留 exact base/Function subtype 并绕开 factory。
  // 输入/输出及副作用：source/label 为输入，snapshot 为输出且入口清空；
  //   成功发布 detached handle，不修改源句柄。
  // 失败/边界：null、未知 subtype、复制后类型/字段漂移返回 INVALID_ARGUMENT；
  //   不调用 clone/copy/type_id::create，也不发布 partial handle。
  protected function rdma_status checked_command_handle_snapshot(
    rdma_handle source,
    string label,
    output rdma_handle snapshot
  );
    snapshot = null;
    if (source == null)
      return invalid_argument({label, " handle is null"});
    if (!rdma_cmq_try_snapshot_handle_direct(source, 1'b0, snapshot) ||
        snapshot == null || snapshot == source ||
        snapshot.get_object_type() != source.get_object_type() ||
        !snapshot.same_instance(source)) begin
      snapshot = null;
      return invalid_argument({label, " handle direct snapshot failed"});
    end
    return rdma_status::success();
  endfunction

  // 功能：直接复制 CQC_DELETE 所需的完整 CQC context 及其嵌套 handle/layout，
  //   建立不依赖 factory override 的 detached snapshot。
  // 输入/输出及副作用：source 为非拥有只读 CQC context；snapshot 为输出且入口
  //   清空；成功时发布新建 rdma_cqc_model 及 page/ring/handle 子对象。
  // 失败/边界：source 非 exact 类型、任一嵌套对象缺失、validation/handle snapshot
  //   失败或 candidate 仍与源图共享节点时返回非 OK，绝不发布 partial snapshot。
  protected function rdma_status checked_cqc_context_snapshot(
    rdma_cqc_model source,
    output rdma_cqc_model snapshot
  );
    rdma_status status;
    rdma_handle cq_snapshot;
    rdma_handle ceq_snapshot;
    rdma_cqc_model candidate;
    rdma_page_table_layout page_snapshot;
    rdma_ring_position producer_snapshot;
    rdma_ring_position consumer_snapshot;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_cqc_model::get_type())
      return invalid_argument(
        "CQC delete context requires exact rdma_cqc_model"
      );
    status = source.validate();
    if (status == null)
      return invalid_argument("CQC delete context validation returned null");
    if (!status.ok())
      return status;

    status = checked_command_handle_snapshot(
      source.cq_h, "CQC delete context CQ", cq_snapshot
    );
    if (!status.ok())
      return status;
    if (source.ceq_h != null) begin
      status = checked_command_handle_snapshot(
        source.ceq_h, "CQC delete context CEQ", ceq_snapshot
      );
      if (!status.ok())
        return status;
    end
    if (source.page_layout == null || source.producer == null ||
        source.consumer == null)
      return invalid_argument(
        "CQC delete context nested layout or ring is null"
      );

    // 这些值对象不携带外部资源所有权；直接构造，避免测试 factory override
    //   注入共享节点或不满足约束的对象。
    page_snapshot = new("cqc_delete_page_layout_snapshot");
    page_snapshot.mode = source.page_layout.mode;
    page_snapshot.sd_base = source.page_layout.sd_base;
    page_snapshot.current_base = source.page_layout.current_base;
    page_snapshot.current_valid = source.page_layout.current_valid;
    page_snapshot.next_base = source.page_layout.next_base;
    page_snapshot.next_valid = source.page_layout.next_valid;

    producer_snapshot = new("cqc_delete_producer_snapshot");
    producer_snapshot.index = source.producer.index;
    producer_snapshot.wrap = source.producer.wrap;
    consumer_snapshot = new("cqc_delete_consumer_snapshot");
    consumer_snapshot.index = source.consumer.index;
    consumer_snapshot.wrap = source.consumer.wrap;

    candidate = new("cqc_delete_context_snapshot");
    candidate.cq_h = cq_snapshot;
    candidate.ceq_h = ceq_snapshot;
    candidate.state = source.state;
    candidate.depth = source.depth;
    candidate.cqe_size_bytes = source.cqe_size_bytes;
    candidate.threshold = source.threshold;
    candidate.page_layout = page_snapshot;
    candidate.producer = producer_snapshot;
    candidate.consumer = consumer_snapshot;
    candidate.urc_enable = source.urc_enable;
    candidate.load_ci_done = source.load_ci_done;
    candidate.last_arm_sequence = source.last_arm_sequence;
    candidate.arm_sequence = source.arm_sequence;
    candidate.arm_state = source.arm_state;
    candidate.shadow_backing = source.shadow_backing;

    status = candidate.validate();
    if (status == null)
      return invalid_argument("CQC delete context snapshot validation null");
    if (!status.ok())
      return status;
    if (candidate == source || candidate.cq_h == source.cq_h ||
        candidate.ceq_h == source.ceq_h ||
        candidate.page_layout == source.page_layout ||
        candidate.producer == source.producer ||
        candidate.consumer == source.consumer)
      return invalid_argument("CQC delete context snapshot aliases source");
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  // 功能：对五种 exact RDMA CMQ body 直接构造 typed detached snapshot。
  // 输入/输出及副作用：source 为输入，snapshot 为输出且入口清空；逐字段复制
  //   scalar/fixed-array，并为嵌套 handle 直接构造新值，不修改 source。
  // 失败/边界：null、未知/派生 body、坏 handle、source/candidate validation 失败
  //   或 graph 未分离时返回非空错误；不调用 raw factory、clone 或 copy。
  virtual function rdma_status snapshot_command_body(
    rdma_hw_model source,
    output rdma_hw_model snapshot
  );
    rdma_status status;
    rdma_hw_qpc_command_body source_qpc;
    rdma_hw_qpc_command_body snapshot_qpc;
    rdma_hw_cqc_delete_body source_cqc_delete;
    rdma_hw_cqc_delete_body snapshot_cqc_delete;
    rdma_cqc_model cqc_context_snapshot;
    rdma_hw_object_id_command_body source_object;
    rdma_hw_object_id_command_body snapshot_object;
    rdma_hw_mr_deregister_body source_mr;
    rdma_hw_mr_deregister_body snapshot_mr;
    rdma_hw_occ_flush_body source_occ;
    rdma_hw_occ_flush_body snapshot_occ;
    rdma_hw_cmq_empty_body source_empty;
    rdma_hw_cmq_empty_body snapshot_empty;
    rdma_handle handle0_snapshot;
    rdma_handle handle1_snapshot;
    rdma_handle handle2_snapshot;
    rdma_hw_model candidate;
    uvm_object_wrapper source_type;

    snapshot = null;
    if (source == null)
      return invalid_argument("rdma CMQ command body is null");
    source_type = source.get_object_type();
    if (source_type == rdma_hw_qpc_command_body::get_type()) begin
      if (!$cast(source_qpc, source))
        return invalid_argument("rdma CMQ QPC wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_cqc_delete_body::get_type()) begin
      if (!$cast(source_cqc_delete, source))
        return invalid_argument("rdma CMQ CQC delete wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_object_id_command_body::get_type()) begin
      if (!$cast(source_object, source))
        return invalid_argument("rdma CMQ object wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_mr_deregister_body::get_type()) begin
      if (!$cast(source_mr, source))
        return invalid_argument("rdma CMQ MR wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_occ_flush_body::get_type()) begin
      if (!$cast(source_occ, source))
        return invalid_argument("rdma CMQ OCC wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_cmq_empty_body::get_type()) begin
      if (!$cast(source_empty, source))
        return invalid_argument("rdma CMQ empty wrapper/cast mismatch");
    end
    else begin
      return invalid_argument("rdma CMQ command body wrapper is unsupported");
    end
    status = source.validate();
    if (status == null)
      return invalid_argument("rdma CMQ body validation returned null");
    if (!status.ok())
      return status;

    if (source_qpc != null) begin
      status = checked_command_handle_snapshot(
        source_qpc.qp_h, "rdma QPC command QP", handle0_snapshot
      );
      if (!status.ok())
        return status;
      if (source_qpc.send_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.send_cq_h, "rdma QPC command send CQ",
          handle1_snapshot
        );
        if (!status.ok())
          return status;
      end
      if (source_qpc.recv_cq_h != null) begin
        status = checked_command_handle_snapshot(
          source_qpc.recv_cq_h, "rdma QPC command receive CQ",
          handle2_snapshot
        );
        if (!status.ok())
          return status;
      end
      snapshot_qpc = new("rdma_qpc_body_snapshot");
      snapshot_qpc.qp_h = handle0_snapshot;
      snapshot_qpc.send_cq_h = handle1_snapshot;
      snapshot_qpc.recv_cq_h = handle2_snapshot;
      snapshot_qpc.qpc_buffer = source_qpc.qpc_buffer;
      snapshot_qpc.next_state = source_qpc.next_state;
      snapshot_qpc.full_modify = source_qpc.full_modify;
      snapshot_qpc.partial_modify = source_qpc.partial_modify;
      snapshot_qpc.wbe_template_count = source_qpc.wbe_template_count;
      foreach (source_qpc.modify_start_qword[i]) begin
        snapshot_qpc.modify_start_qword[i] =
          source_qpc.modify_start_qword[i];
        snapshot_qpc.modify_wbe[i] = source_qpc.modify_wbe[i];
        snapshot_qpc.modify_data[i] = source_qpc.modify_data[i];
      end
      candidate = snapshot_qpc;
    end
    else if (source_cqc_delete != null) begin
      status = checked_cqc_context_snapshot(
        source_cqc_delete.cqc_context, cqc_context_snapshot
      );
      if (!status.ok())
        return status;
      snapshot_cqc_delete = new("rdma_cqc_delete_body_snapshot");
      snapshot_cqc_delete.cqc_context = cqc_context_snapshot;
      candidate = snapshot_cqc_delete;
    end
    else if (source_object != null) begin
      status = checked_command_handle_snapshot(
        source_object.object_h, "rdma object-ID command",
        handle0_snapshot
      );
      if (!status.ok())
        return status;
      snapshot_object = new("rdma_object_id_body_snapshot");
      snapshot_object.object_h = handle0_snapshot;
      candidate = snapshot_object;
    end
    else if (source_mr != null) begin
      status = checked_command_handle_snapshot(
        source_mr.mr_h, "rdma MR deregister", handle0_snapshot
      );
      if (!status.ok())
        return status;
      snapshot_mr = new("rdma_mr_deregister_body_snapshot");
      snapshot_mr.mr_h = handle0_snapshot;
      snapshot_mr.stag_key = source_mr.stag_key;
      snapshot_mr.next_state = source_mr.next_state;
      candidate = snapshot_mr;
    end
    else if (source_occ != null) begin
      snapshot_occ = new("rdma_occ_flush_body_snapshot");
      snapshot_occ.vf_flush = source_occ.vf_flush;
      snapshot_occ.mr_serial_flush = source_occ.mr_serial_flush;
      snapshot_occ.qpc = source_occ.qpc;
      snapshot_occ.cqc = source_occ.cqc;
      snapshot_occ.mrt = source_occ.mrt;
      snapshot_occ.pble = source_occ.pble;
      snapshot_occ.sqrqe = source_occ.sqrqe;
      snapshot_occ.sgb_irqe = source_occ.sgb_irqe;
      snapshot_occ.eirqe = source_occ.eirqe;
      snapshot_occ.orqe = source_occ.orqe;
      snapshot_occ.uaqe = source_occ.uaqe;
      snapshot_occ.pd = source_occ.pd;
      snapshot_occ.qpn = source_occ.qpn;
      snapshot_occ.mr_serial = source_occ.mr_serial;
      snapshot_occ.pd_backing = source_occ.pd_backing;
      candidate = snapshot_occ;
    end
    else begin
      snapshot_empty = new("rdma_empty_body_snapshot");
      candidate = snapshot_empty;
    end
    if (candidate == null || candidate == source ||
        candidate.get_object_type() != source.get_object_type() ||
        !same_command_body_value(source, candidate) ||
        !command_body_graph_detached(source, candidate))
      return invalid_argument("rdma CMQ body snapshot aliases its source");
    status = candidate.validate();
    if (status == null) begin
      return invalid_argument("rdma CMQ snapshot validation returned null");
    end
    if (!status.ok())
      return status;
    snapshot = candidate;
    return rdma_status::success();
  endfunction

  // 功能：把 exact 五种 RDMA CMQ body 编码为稳定 V1 tag 后的字段 bytes。
  // 输入/输出及副作用：source 为输入；schema_tag/canonical_field_bytes 入口清空，
  //   成功时发布 fresh tag/array，不保留 source handle。
  // 失败/边界：null、未知/派生 subtype、body validation、QPC next_state 的
  //   X/Z/7..15 spare 或任一字段编码失败时返回 INVALID_ARGUMENT 且输出保持空；
  //   不进入 raw factory。
  virtual function rdma_status canonicalize_command_body(
    input rdma_hw_model source,
    output string schema_tag,
    output byte unsigned canonical_field_bytes[]
  );
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_cqc_delete_body cqc_delete_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;
    rdma_cmq_canonical_writer writer;
    rdma_status status;
    rdma_hw_cqc_create_body_codec cqc_context_codec;
    rdma_hw_image cqc_context_image;
    string candidate_tag;
    byte unsigned candidate_bytes[];
    uvm_object_wrapper source_type;

    schema_tag = "";
    canonical_field_bytes = new[0];
    if (source == null)
      return invalid_argument("rdma CMQ canonical body is null");
    source_type = source.get_object_type();
    if (source_type == rdma_hw_qpc_command_body::get_type()) begin
      if (!$cast(qpc_body, source))
        return invalid_argument("rdma canonical QPC wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_cqc_delete_body::get_type()) begin
      if (!$cast(cqc_delete_body, source))
        return invalid_argument(
          "rdma canonical CQC delete wrapper/cast mismatch"
        );
    end
    else if (source_type == rdma_hw_object_id_command_body::get_type()) begin
      if (!$cast(object_body, source))
        return invalid_argument("rdma canonical object wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_mr_deregister_body::get_type()) begin
      if (!$cast(mr_body, source))
        return invalid_argument("rdma canonical MR wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_occ_flush_body::get_type()) begin
      if (!$cast(occ_body, source))
        return invalid_argument("rdma canonical OCC wrapper/cast mismatch");
    end
    else if (source_type == rdma_hw_cmq_empty_body::get_type()) begin
      if (!$cast(empty_body, source))
        return invalid_argument("rdma canonical empty wrapper/cast mismatch");
    end
    else begin
      return invalid_argument("rdma CMQ canonical body wrapper is unsupported");
    end
    status = source.validate();
    if (status == null || !status.ok())
      return (status == null) ? invalid_argument(
        "rdma CMQ canonical body validation returned null"
      ) : status;
    if (qpc_body != null &&
        ($isunknown(qpc_body.next_state) ||
         qpc_body.next_state > RDMA_QPS_ERROR))
      return invalid_argument("rdma canonical QPC next state is invalid");

    writer = new();
    if (qpc_body != null) begin
      candidate_tag = "CMQ-BODY-QPC-V1";
      if (!rdma_cmq_append_handle_v1(writer, qpc_body.qp_h, 1'b1) ||
          !rdma_cmq_append_handle_v1(writer, qpc_body.send_cq_h, 1'b1) ||
          !rdma_cmq_append_handle_v1(writer, qpc_body.recv_cq_h, 1'b1) ||
          !writer.append_u64(qpc_body.qpc_buffer.value) ||
          !writer.append_u8(qpc_body.next_state) ||
          !writer.append_u8({7'b0, qpc_body.full_modify}) ||
          !writer.append_u8({7'b0, qpc_body.partial_modify}) ||
          !writer.append_u8(qpc_body.wbe_template_count))
        return invalid_argument("rdma QPC body canonicalization failed");
      foreach (qpc_body.modify_start_qword[i]) begin
        if (!writer.append_u8(qpc_body.modify_start_qword[i]) ||
            !writer.append_u8(qpc_body.modify_wbe[i]) ||
            !writer.append_u64(qpc_body.modify_data[i]))
          return invalid_argument(
            "rdma QPC modify tuple canonicalization failed"
          );
      end
    end
    else if (cqc_delete_body != null) begin
      cqc_context_codec = new("cmq_canonical_cqc_context_codec");
      cqc_context_image = null;
      status = cqc_context_codec.encode(
        cqc_delete_body.cqc_context, cqc_context_image
      );
      if (!status.ok() || cqc_context_image == null ||
          cqc_context_image.length != 64 ||
          cqc_context_image.bytes.size() != 64 ||
          cqc_context_image.image_kind != RDMA_IMAGE_CQC ||
          cqc_context_image.endian != RDMA_ENDIAN_BIG)
        return invalid_argument(
          "rdma CQC delete context canonical encoding failed"
        );
      candidate_tag = "CMQ-BODY-CQC-DELETE-V1";
      if (!rdma_cmq_append_handle_v1(
            writer, cqc_delete_body.cqc_context.cq_h, 1'b0
          ) ||
          !rdma_cmq_append_handle_v1(
            writer, cqc_delete_body.cqc_context.ceq_h, 1'b1
          ) ||
          !writer.append_raw(cqc_context_image.bytes))
        return invalid_argument(
          "rdma CQC delete body canonicalization failed"
        );
    end
    else if (object_body != null) begin
      candidate_tag = "CMQ-BODY-OBJECT-ID-V1";
      if (!rdma_cmq_append_handle_v1(
            writer, object_body.object_h, 1'b0
          ))
        return invalid_argument("rdma object-ID body canonicalization failed");
    end
    else if (mr_body != null) begin
      candidate_tag = "CMQ-BODY-MR-DEREGISTER-V1";
      if (!rdma_cmq_append_handle_v1(writer, mr_body.mr_h, 1'b0) ||
          !writer.append_u8(mr_body.stag_key) ||
          !writer.append_u8(mr_body.next_state))
        return invalid_argument("rdma MR body canonicalization failed");
    end
    else if (occ_body != null) begin
      candidate_tag = "CMQ-BODY-OCC-FLUSH-V1";
      if (!writer.append_u8({7'b0, occ_body.vf_flush}) ||
          !writer.append_u8({7'b0, occ_body.mr_serial_flush}) ||
          !writer.append_u8({7'b0, occ_body.qpc}) ||
          !writer.append_u8({7'b0, occ_body.cqc}) ||
          !writer.append_u8({7'b0, occ_body.mrt}) ||
          !writer.append_u8({7'b0, occ_body.pble}) ||
          !writer.append_u8({7'b0, occ_body.sqrqe}) ||
          !writer.append_u8({7'b0, occ_body.sgb_irqe}) ||
          !writer.append_u8({7'b0, occ_body.eirqe}) ||
          !writer.append_u8({7'b0, occ_body.orqe}) ||
          !writer.append_u8({7'b0, occ_body.uaqe}) ||
          !writer.append_u8({7'b0, occ_body.pd}) ||
          !writer.append_u32(occ_body.qpn) ||
          !writer.append_u16(occ_body.mr_serial) ||
          !writer.append_u64(occ_body.pd_backing.value))
        return invalid_argument("rdma OCC body canonicalization failed");
    end
    else if (empty_body != null) begin
      candidate_tag = "CMQ-BODY-EMPTY-V1";
    end
    else begin
      return invalid_argument("rdma CMQ canonical body dispatch failed");
    end
    writer.snapshot(candidate_bytes);
    schema_tag = candidate_tag;
    canonical_field_bytes = candidate_bytes;
    return rdma_status::success();
  endfunction

  // 功能：直接复制 exact rdma_hw_cmq_completion 的标量和 payload bytes，并在发布前执行源不变/等值/分离三道门禁。
  // 输入/输出及副作用：source 为非拥有输入，snapshot 入口清空；直接 new guard
  // 和 candidate，逐字节复制 object_payload，全部检查通过后只发布 candidate。
  // 失败/边界：null/非 exact subtype、快照期间源值变化、candidate 不等值或外层别名
  // 均返回 INVALID_ARGUMENT/null；不调用 factory、clone 或 copy。
  virtual function rdma_status snapshot_completion_payload(
    uvm_object source,
    output uvm_object snapshot
  );
    rdma_hw_cmq_completion source_payload;
    rdma_hw_cmq_completion source_guard;
    rdma_hw_cmq_completion snapshot_payload;

    snapshot = null;
    if (source == null ||
        source.get_object_type() != rdma_hw_cmq_completion::get_type() ||
        !$cast(source_payload, source))
      return invalid_argument(
        "rdma CMQ completion payload type is unsupported"
      );
    source_guard = new("rdma_completion_payload_source_guard");
    source_guard.owner = source_payload.owner;
    source_guard.opcode = source_payload.opcode;
    source_guard.command_ecode = source_payload.command_ecode;
    source_guard.wqe_index = source_payload.wqe_index;
    source_guard.wrap = source_payload.wrap;
    source_guard.object_payload = new[source_payload.object_payload.size()];
    foreach (source_payload.object_payload[i])
      source_guard.object_payload[i] = source_payload.object_payload[i];

    snapshot_payload = new("rdma_completion_payload_snapshot");
    snapshot_payload.owner = source_payload.owner;
    snapshot_payload.opcode = source_payload.opcode;
    snapshot_payload.command_ecode = source_payload.command_ecode;
    snapshot_payload.wqe_index = source_payload.wqe_index;
    snapshot_payload.wrap = source_payload.wrap;
    snapshot_payload.object_payload = new[source_payload.object_payload.size()];
    foreach (source_payload.object_payload[i])
      snapshot_payload.object_payload[i] = source_payload.object_payload[i];

    if (!same_completion_payload_value(source_guard, source_payload))
      return invalid_argument(
        "rdma CMQ completion payload source changed during snapshot"
      );
    if (!same_completion_payload_value(source_payload, snapshot_payload) ||
        !completion_payload_graph_detached(source_payload,
                                           snapshot_payload))
      return invalid_argument(
        "rdma CMQ completion payload snapshot is unequal or aliased"
      );
    snapshot = snapshot_payload;
    return rdma_status::success();
  endfunction

  // 功能：逐字段比较两个 RDMA CMQ completion payload，包括所有 object_payload 字节。
  // 输入/输出及副作用：lhs/rhs 只读；比较 owner/opcode/ecode/index/wrap、数组长度
  // 和每个 byte，返回 bit，不修改 payload。
  // 失败/边界：任一输入 wrapper 非 exact completion、无法 cast，或长度/任一字段
  //   不同时返回 0；伪造 get_type_name 的注册子类不能参与等值门禁。
  virtual function bit same_completion_payload_value(
    uvm_object lhs,
    uvm_object rhs
  );
    rdma_hw_cmq_completion lhs_payload;
    rdma_hw_cmq_completion rhs_payload;

    if (lhs == null || rhs == null ||
        lhs.get_object_type() != rdma_hw_cmq_completion::get_type() ||
        rhs.get_object_type() != rdma_hw_cmq_completion::get_type() ||
        !$cast(lhs_payload, lhs) || !$cast(rhs_payload, rhs) ||
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

  // 功能：确认 completion snapshot 是与 source 不同的 typed 外层对象。
  // 输入/输出及副作用：source/snapshot 只读；两者均可 cast 且句柄不同时返回 1。
  // 失败/边界：任一 wrapper 非 exact completion、cast 失败或外层句柄相同时返回
  //   0；payload 只含动态 byte array，无其他句柄需遍历。
  virtual function bit completion_payload_graph_detached(
    uvm_object source,
    uvm_object snapshot
  );
    rdma_hw_cmq_completion source_payload;
    rdma_hw_cmq_completion snapshot_payload;

    return source != null && snapshot != null &&
           source.get_object_type() == rdma_hw_cmq_completion::get_type() &&
           snapshot.get_object_type() ==
             rdma_hw_cmq_completion::get_type() &&
           $cast(source_payload, source) &&
           $cast(snapshot_payload, snapshot) &&
           source_payload != snapshot_payload;
  endfunction

  // 功能：构造 RDMA doorbell registry 查找键，把调用方 variant 放入固定域。
  // 输入/输出及副作用：variant 为输入；返回 hw_version="rdma"、DOORBELL image、
  // object_type="doorbell"、opcode=0 的 rdma_codec_key 值，不修改 registry。
  // 失败/边界：本 helper 不校验空/未知 variant；lookup 是否命中由调用方检查并返回 status。
  protected function rdma_codec_key doorbell_key(string variant);
    rdma_codec_key key;
    key.hw_version = "rdma";
    key.image_kind = RDMA_IMAGE_DOORBELL;
    key.object_type = "doorbell";
    key.variant = variant;
    key.opcode = 8'h00;
    return key;
  endfunction

  // 功能：确认三个 CMQ codec、doorbell registry/初始注册 status、CMQ opcode registry
  //   和 13 个 doorbell variant 全部就绪。
  // 输入/输出及副作用：无参数；只读 profile 拥有的 child/status，调用全局 CMQ registry
  // validate() 并逐个 lookup doorbell key，返回首个失败或 OK。
  // 失败/边界：任一 child/status 为 null、默认注册失败、CMQ registry 无效，
  // 或任一 variant lookup 非 OK/null codec 时拒绝；校验不自动重新注册。
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

  // 功能：比较 command 与 slot 的 Function handle 是否指向同一 UID/global-ID/generation。
  // 输入/输出及副作用：lhs/rhs 为非拥有只读句柄；返回三个身份字段是否全等，不修改句柄。
  // 失败/边界：任一句柄为 null 返回 0；kind 已由两个上游 validate() 检查，本 helper 不重复报错。
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

  // 功能：判断 opcode 的 composed body 是否按协议不携带 Function generation。
  // 输入/输出及副作用：opcode 为八位输入；OCC_FLUSH/TQ_FLUSH 或 CMQ registry 标记的
  // generationless opcode 返回 1，不修改 registry。
  // 失败/边界：未知/未注册 opcode 通常返回 0；该结果仅决定 image generation 校验，不表示 opcode 受支持。
  protected function bit generationless_opcode(bit [7:0] opcode);
    return opcode inside {RDMA_OP_OCC_FLUSH, RDMA_OP_TQ_FLUSH} ||
           rdma_cmq_codec_registry::is_generationless(opcode);
  endfunction

  // 功能：验证 request composer 产生未定址的标准 64B big-endian CMQ SQE 及 generation 规则。
  // 输入/输出及副作用：image/opcode/function_generation 只读；检查 image metadata 和指定 opcode
  // 的 generationless/绑定约束，返回 status，不改写 image target。
  // 失败/边界：null image 返回 INVALID_STATE；长度/bytes/对齐/端序/kind/version/target
  // 不符返回 CODEC_ERROR；generationless 非零返回 CODEC_ERROR，其他 generation 不同返回 STALE_GENERATION。
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

  // 功能：将受支持 command body 包装进 CMQ envelope，定位到 slot backing，并产生 CQE 期望键。
  // 输入/输出及副作用：command/slot 为非拥有只读输入；sqe/expected 入口清空；
  // 成功时发布 detached 64B SQE（BACKING target）和 opcode/variant expected response。
  // 失败/边界：profile/command/slot 无效、Function/profile/opcode/VFID 不匹配、target 溢出、
  // body/envelope codec 失败或产生 null/非法 image 时原子拒绝；QPC_CREATE 必须保持 driver-fixed VFID 为零。
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
    if (!status.ok())
      return status;
    if (command == null)
      return invalid_argument("rdma CMQ command is null");
    if (slot == null)
      return invalid_argument("rdma CMQ slot is null");
    status = command.validate();
    if (!status.ok())
      return status;
    status = slot.validate();
    if (!status.ok())
      return status;
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
    if (!status.ok())
      return status;
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
    if (!status.ok())
      return status;
    status = validate_composed_sqe(
      composed, opcode, command.function_h.generation
    );
    if (!status.ok())
      return status;

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

  // 功能：在 completion codec 解码前校验 raw image 是未定址的 64B CMQ CQE。
  // 输入/输出及副作用：raw_cqe 为只读 image；检查 length/bytes、image_kind 和
  // NONE/zero target metadata，返回 rdma_status，不解码或修改 bytes。
  // 失败/边界：null、非 64B 或 kind/target metadata 非法统一返回 CODEC_ERROR；
  // alignment/endian/version/generation 由下游 completion 和 engine authority 约束。
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

  // 功能：通过 RDMA completion/error codec 解码一个 owner-ready CQE，并组装 decoded CQE 值。
  // 输入/输出及副作用：raw_cqe/expected_owner 只读；ready 先置 0、decoded 先置 null；
  // not-ready 返回 OK/ready=0，ready 时克隆 completion payload、绑定 command_status 并发布 candidate。
  // 失败/边界：profile/raw image/codec 失败，ready 却返回 null completion/status，payload clone
  // 失败，candidate allocation/validation 失败时保持 ready=0/decoded=null；operation 失败 status 作为数据保留。
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
    if (!status.ok())
      return status;
    status = validate_raw_cqe(raw_cqe);
    if (!status.ok())
      return status;
    completion = null;
    completion_ready = 1'b0;
    status = completion_codec.inspect_completion(
      raw_cqe, expected_owner, completion_ready, completion
    );
    if (!status.ok())
      return status;
    if (!completion_ready)
      return rdma_status::success();
    if (completion == null)
      return invalid_state("rdma completion codec published null");

    command_status = null;
    status = error_codec.decode_status(completion.command_ecode,
                                       RDMA_ENGINE_CMQ, command_status);
    if (!status.ok())
      return status;
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
    if (!status.ok())
      return status;
    decoded = candidate;
    ready = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：构造 CMQ-SQ doorbell model，通过 registry 编码 final PI/polarity，并发布 detached image。
  // 输入/输出及副作用：cmq_h/final_pi/polarity 只读；image 入口清空；克隆 handle
  // 到临时 model，registry encode 成功后再 copy 为调用方拥有的 image，不写 MMIO。
  // 失败/边界：profile 无效、cmq_h 为 null/非 CMQ、final_pi>=32、handle clone 失败、
  // registry encode 失败或返回 null image 时不发布部分 output。
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
    if (!status.ok())
      return status;
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
    if (!status.ok())
      return status;
    if (encoded == null)
      return invalid_state("rdma doorbell codec published null");
    detached = rdma_hw_image::type_id::create("detached_doorbell");
    detached.copy(encoded);
    image = detached;
    return rdma_status::success();
  endfunction
endclass
