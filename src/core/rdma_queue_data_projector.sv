// 目录：核心值投影层 core/rdma_queue_data_projector.sv。
// 职责：集中 queue-data 的身份/route/epoch 值比较、无分配状态传输和 consumer 候选结果物化。
// 依赖：types/model、runtime/data transaction value 类型及 UVM raw factory；不依赖 engine 实例。
// 所有权与生命周期：无字段、缓存、锁或 UVM 注册，不持有 engine/runtime/manager/adapter 引用。
//   调用方管理输入与返回对象的生命周期；CQ result 会修改并复用传入的 detached release slots，
//   不能传入 live ledger；attachment 参数只读其值字段，不查询或修改借用 runtime。
// 设计说明：admission、I/O、commit 与恢复仍由业务 owner 决定，本类只处理显式输入的值。
//   static automatic 使每次调用局部变量独立。“无状态”不等于“无分配/无回调”：raw factory 和
//   AEQE profile 设置保留原调用窗口；post-scheduler 用 rdma_status 的 *_noalloc 值操作。

class rdma_queue_data_projector;

  // 功能：直接调用 raw factory，由调用方处理 null/错误动态类型，避免 typed-create fatal。
  // 输入/输出及副作用：requested_type/name 输入；返回 raw 对象，保留一次 create 请求及实例名。
  // 失败/边界：type/factory 为空返回 null；不捕获 provider 自身 fatal，不校验类型；factory 可重入。
  static function automatic uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null)

      return null;
    factory = uvm_factory::get();
    if (factory == null)
      return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：用 raw factory 创建 status 并原位初始化，清除旧诊断字段。
  // 输入/输出及副作用：code/message 决定分类、严重性和文案；只写 factory 返回的 status。
  // 失败/边界：null/错型返回 null，无隐藏 new/fallback；不能在无分配窗口调用。
  static function automatic rdma_status make_status_nonfatal(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status result;
    uvm_object raw_result;

    raw_result = factory_create_object_nonfatal(
      rdma_status::get_type(), "queue_data_engine_status");
    if (raw_result == null || !$cast(result, raw_result))
      return null;
    void'(rdma_status::set_fields_noalloc(result, code, message));
    return result;
  endfunction

  // 功能：为 consumer candidate 逐字段物化 kind/Function/object/generation 句柄，不 clone。
  // 输入/输出及副作用：source/label 输入；copy 先清空，再写 raw factory 创建的 handle。
  // 失败/边界：source 为空或 raw 对象 null/错型时 copy=null；返回 status 创建失败时 copy 可能已填充。
  static function automatic rdma_status clone_poll_handle_nonfatal(
    rdma_handle source,
    string label,
    output rdma_handle copy
  );
    rdma_handle candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_status_nonfatal(RDMA_SC_INVALID_ARGUMENT,
                                         {label, " source is null"});
    raw_candidate = factory_create_object_nonfatal(
      rdma_handle::get_type(), {label, "_handle"});
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_status_nonfatal(RDMA_SC_RESOURCE_EXHAUSTED,
                                         {label, " handle allocation failed"});
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：物化 poll 镜像的 metadata、bytes 和 field_summary，供 consumer pending 保存重放值。
  // 输入/输出及副作用：source 输入，copy 先清空；复用模型元数据复制，再向镜像追加两组队列，不 clone。
  // 失败/边界：空 source、零 length、bytes 数不符、null/错型 factory 均拒绝；不清空 override 预填
  //   队列；最终 status 创建失败时 copy 可非空，调用方须检查 status。
  static function automatic rdma_status clone_poll_image_nonfatal(
    rdma_hw_image source,
    output rdma_hw_image copy
  );
    rdma_hw_image candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null || source.length == 0 ||
        source.bytes.size() != source.length)
      return make_status_nonfatal(RDMA_SC_INVALID_ARGUMENT,
                                         "CQ poll image is incomplete");
    raw_candidate = factory_create_object_nonfatal(
      rdma_hw_image::get_type(), "cq_poll_pending_image");
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_status_nonfatal(RDMA_SC_RESOURCE_EXHAUSTED,
                                         "CQ poll image allocation failed");
    rdma_hw_image::copy_metadata_noalloc(source, candidate);
    foreach (source.bytes[i]) candidate.bytes.push_back(source.bytes[i]);
    foreach (source.field_summary[i])
      candidate.field_summary.push_back(source.field_summary[i]);
    copy = candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：按已计算的 index/wrap 物化 consumer old/next cursor，不读 live runtime。
  // 输入/输出及副作用：index/wrap/label 输入；copy 先清空再填入 raw factory 的 cursor。
  // 失败/边界：null/错型 cursor 拒绝；不校验 depth/index；status 分配失败时已填充 copy 不回滚。
  static function automatic rdma_status make_poll_cursor_nonfatal(
    int unsigned index,
    bit wrap,
    string label,
    output rdma_queue_cursor_snapshot copy
  );
    rdma_queue_cursor_snapshot candidate;
    uvm_object raw_candidate;

    copy = null;
    raw_candidate = factory_create_object_nonfatal(
      rdma_queue_cursor_snapshot::get_type(), {label, "_cursor"});
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_status_nonfatal(RDMA_SC_RESOURCE_EXHAUSTED,
                                         {label, " cursor allocation failed"});
    candidate.index = index;
    candidate.wrap = wrap;
    copy = candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：在 consumer barrier 前创建 nested status，逐字段复制原始诊断，不重新分类。
  // 输入/输出及副作用：source/label 输入，copy 先清空；字段复制成功后才发布 output。
  // 失败/边界：source=null、raw null/错型或字段复制拒绝均失败；无本地 fallback；返回 status
  //   分配失败不撤销已填充 copy，以 status 为准。
  static function automatic rdma_status allocate_poll_status_nonfatal(
    rdma_status source,
    string label,
    output rdma_status copy
  );
    rdma_status candidate;
    uvm_object raw_candidate;

    copy = null;
    if (source == null)
      return make_status_nonfatal(RDMA_SC_INVALID_ARGUMENT,
                                         {label, " source status is null"});
    raw_candidate = factory_create_object_nonfatal(
      rdma_status::get_type(), {label, "_status"});
    if (raw_candidate == null || !$cast(candidate, raw_candidate))
      return make_status_nonfatal(RDMA_SC_RESOURCE_EXHAUSTED,
                                         {label, " status allocation failed"});
    if (!rdma_status::copy_fields_noalloc(source, candidate))
      return make_status_nonfatal(RDMA_SC_INVALID_STATE,
                                         {label, " status copy failed"});
    copy = candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：在 CQ barrier 前组装 CQE 语义、payload、完成状态和已冻结 release slot 的结果图。
  // 输入/输出及副作用：cq_h/decoded_cqe/result_qp_h/completion_status/release_snapshots 输入；
  //   candidate/final_success 先清空；新建 CQE/handle/status，并原位更新传入 detached slot 的
  //   posted/consumed/completion_status；禁止传入 live runtime ledger。
  // 失败/边界：必要输入/slot 为空、raw factory null/错型或 nested status 失败均拒绝；失败时
  //   final_success/已处理 slot/candidate 可能残留，调用方须丢弃，不能视为已提交；
  //   不校验 route/epoch，不提交资源。
  static function automatic rdma_status prepare_cq_completion_candidate(
    rdma_handle cq_h,
    rdma_hw_cqe_model decoded_cqe,
    rdma_handle result_qp_h,
    rdma_status completion_status,
    rdma_queue_slot_ledger_entry release_snapshots[$],
    output rdma_queue_completion_result candidate,
    output rdma_status final_success
  );
    rdma_queue_completion_result result_candidate;
    rdma_hw_cqe_model cqe_candidate;
    rdma_handle cq_copy;
    rdma_handle qp_copy;
    rdma_status cqe_status_copy;
    rdma_status completion_status_copy;
    rdma_status slot_status_copy;
    rdma_status success_source;
    rdma_status local_status;
    rdma_queue_slot_ledger_entry slot;
    rdma_queue_slot_ledger_entry last_slot;
    rdma_post_send_req send_req;
    rdma_post_recv_req recv_req;
    uvm_object raw_result;
    uvm_object raw_cqe;

    candidate = null;
    final_success = null;
    if (cq_h == null || decoded_cqe == null || result_qp_h == null ||
        completion_status == null || release_snapshots.size() == 0)
      return make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT, "CQ completion candidate input is incomplete");
    last_slot = release_snapshots[release_snapshots.size()-1];
    if (last_slot == null)
      return make_status_nonfatal(
        RDMA_SC_INVALID_STATE, "CQ release snapshot has a null final slot");

    raw_result = factory_create_object_nonfatal(
      rdma_queue_completion_result::get_type(), "prepared_cqe_result");
    if (raw_result == null || !$cast(result_candidate, raw_result))
      return make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED, "CQ completion result allocation failed");
    raw_cqe = factory_create_object_nonfatal(
      rdma_hw_cqe_model::get_type(), "prepared_cqe_model");
    if (raw_cqe == null || !$cast(cqe_candidate, raw_cqe))
      return make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED, "CQ completion model allocation failed");
    local_status = clone_poll_handle_nonfatal(cq_h, "CQ result queue", cq_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    local_status = clone_poll_handle_nonfatal(
      result_qp_h, "CQ result QP", qp_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    local_status = allocate_poll_status_nonfatal(
      decoded_cqe.status, "CQ result model", cqe_status_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    local_status = allocate_poll_status_nonfatal(
      completion_status, "CQ result completion", completion_status_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    success_source = make_status_nonfatal(RDMA_SC_OK, "");
    local_status = allocate_poll_status_nonfatal(
      success_source, "CQ poll final success", final_success);
    if (local_status == null || !local_status.ok())
      return local_status;

    cqe_candidate.qp_h = qp_copy;
    cqe_candidate.wr_id = last_slot.wr_id;
    cqe_candidate.opcode = decoded_cqe.opcode;
    if (last_slot.request_snapshot != null) begin
      if ($cast(send_req, last_slot.request_snapshot)) begin
        cqe_candidate.wr_id = send_req.wr_id;
        cqe_candidate.opcode = send_req.opcode;
      end
      else if ($cast(recv_req, last_slot.request_snapshot)) begin
        cqe_candidate.wr_id = recv_req.wr_id;
        cqe_candidate.opcode = RDMA_WR_RECV;
      end
    end
    cqe_candidate.status = cqe_status_copy;
    // CQE detached 结果须保留完整驱动投影，而非只复制 poll 释放 WQE 用的公共字段：
    // variant、flags、qword2 typed/raw overlay、UD qword3 和 inline payload 都是可观察值，
    // 丢失任一项会使 poll 后的审计/异常处理与驱动 image 不一致。
    cqe_candidate.variant = decoded_cqe.variant;
    cqe_candidate.byte_len = decoded_cqe.byte_len;
    cqe_candidate.immediate_data = decoded_cqe.immediate_data;
    cqe_candidate.qpn = decoded_cqe.qpn;
    cqe_candidate.qp_state = decoded_cqe.qp_state;
    cqe_candidate.wqe_index = decoded_cqe.wqe_index;
    cqe_candidate.wqe_wrap = decoded_cqe.wqe_wrap;
    cqe_candidate.rq_cqe = decoded_cqe.rq_cqe;
    cqe_candidate.polarity = decoded_cqe.polarity;
    cqe_candidate.srfq = decoded_cqe.srfq;
    cqe_candidate.se = decoded_cqe.se;
    cqe_candidate.sign_en = decoded_cqe.sign_en;
    cqe_candidate.vlan = decoded_cqe.vlan;
    cqe_candidate.ipv6 = decoded_cqe.ipv6;
    cqe_candidate.cqe_format = decoded_cqe.cqe_format;
    cqe_candidate.resize_cqe = decoded_cqe.resize_cqe;
    cqe_candidate.ud_mc = decoded_cqe.ud_mc;
    cqe_candidate.packet_opcode = decoded_cqe.packet_opcode;
    cqe_candidate.ecode = decoded_cqe.ecode;
    cqe_candidate.payload_len = decoded_cqe.payload_len;
    cqe_candidate.immdt_data_invld_key = decoded_cqe.immdt_data_invld_key;
    cqe_candidate.signature = decoded_cqe.signature;
    cqe_candidate.rc_remote_syndrome = decoded_cqe.rc_remote_syndrome;
    cqe_candidate.ud_src_qpn = decoded_cqe.ud_src_qpn;
    cqe_candidate.rqe_cpl = decoded_cqe.rqe_cpl;
    cqe_candidate.srfqn = decoded_cqe.srfqn;
    cqe_candidate.srfqe_wrap = decoded_cqe.srfqe_wrap;
    cqe_candidate.srfqe_index = decoded_cqe.srfqe_index;
    cqe_candidate.raw_qword2_valid = decoded_cqe.raw_qword2_valid;
    cqe_candidate.raw_qword2 = decoded_cqe.raw_qword2;
    cqe_candidate.ud_smac = decoded_cqe.ud_smac;
    cqe_candidate.ud_vlan_tag = decoded_cqe.ud_vlan_tag;
    cqe_candidate.payload.delete();
    foreach (decoded_cqe.payload[i])
      cqe_candidate.payload.push_back(decoded_cqe.payload[i]);

    result_candidate.queue_h = cq_copy;
    result_candidate.cqe = cqe_candidate;
    result_candidate.completion_status = completion_status_copy;
    foreach (release_snapshots[i]) begin
      slot = release_snapshots[i];
      if (slot == null)
        return make_status_nonfatal(
          RDMA_SC_INVALID_STATE, "CQ release snapshot contains a null slot");
      local_status = allocate_poll_status_nonfatal(
        completion_status, $sformatf("CQ released slot %0d", i),
        slot_status_copy);
      if (local_status == null || !local_status.ok())
        return local_status;
      slot.posted = 1'b0;
      slot.consumed = 1'b1;
      slot.completion_status = slot_status_copy;
      result_candidate.released_slots.push_back(slot);
    end
    candidate = result_candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：在 CEQ/AEQ barrier 前物化完整 typed/raw event 结果，保留 CQ flush 的双 owner/partial 语义。
  // 输入/输出及副作用：queue_h/decoded_event/routed_target_h/event_status/secondary_target_h 输入；
  //   candidate/final_success 先清空；构造独立 handle/status/model，并调用 AEQE profile owner 设置。
  // 失败/边界：必要输入缺失、flush 无 live owner 或 CQ/QP kind 不符、非 flush 含 secondary、事件
  //   类型/primary kind 不匹配、factory 或 profile owner 拒绝均失败；失败输出可能残留，须丢弃。
  static function automatic rdma_status prepare_event_result_candidate_ex(
    rdma_handle queue_h,
    rdma_hw_model decoded_event,
    rdma_handle routed_target_h,
    rdma_status event_status,
    output rdma_queue_event_result candidate,
    output rdma_status final_success,
    input rdma_handle secondary_target_h
  );
    rdma_queue_event_result result_candidate;
    rdma_hw_ceqe_model source_ceqe;
    rdma_hw_ceqe_model ceqe_candidate;
    rdma_hw_aeqe_model source_aeqe;
    rdma_hw_aeqe_model aeqe_candidate;
    rdma_handle queue_copy;
    rdma_handle target_copy;
    rdma_handle secondary_copy;
    rdma_status event_status_copy;
    rdma_status success_source;
    rdma_status local_status;
    uvm_object raw_result;
    uvm_object raw_model;
    bit is_cq_flush;

    candidate = null;
    final_success = null;
    target_copy = null;
    secondary_copy = null;
    source_aeqe = null;
    if (queue_h == null || decoded_event == null || event_status == null)
      return make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT, "event result candidate input is incomplete");
    is_cq_flush = $cast(source_aeqe, decoded_event) &&
      rdma_aeqe_event_class_from_ecode(source_aeqe.ecode) ==
        RDMA_AEQE_EVENT_CQ && source_aeqe.packet_opcode[4:0] == 5'h1d;
    if (is_cq_flush) begin
      if (routed_target_h == null && secondary_target_h == null)
        return make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT, "AEQ CQ flush has no live route");
      if (routed_target_h != null &&
          routed_target_h.kind != RDMA_RESOURCE_CQ)
        return make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT, "AEQ CQ flush primary target is not a CQ");
      if (secondary_target_h != null &&
          secondary_target_h.kind != RDMA_RESOURCE_QP)
        return make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT, "AEQ CQ flush secondary target is not a QP");
    end
    else if (routed_target_h == null || secondary_target_h != null) begin
      return make_status_nonfatal(
        RDMA_SC_INVALID_ARGUMENT,
        "non-flush event result requires only a primary route");
    end
    raw_result = factory_create_object_nonfatal(
      rdma_queue_event_result::get_type(), "prepared_event_result");
    if (raw_result == null || !$cast(result_candidate, raw_result))
      return make_status_nonfatal(
        RDMA_SC_RESOURCE_EXHAUSTED, "event result allocation failed");
    local_status = clone_poll_handle_nonfatal(
      queue_h, "event result queue", queue_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    if (routed_target_h != null) begin
      local_status = clone_poll_handle_nonfatal(
        routed_target_h, "event result target", target_copy);
      if (local_status == null || !local_status.ok())
        return local_status;
    end

    if (secondary_target_h != null) begin
      local_status = clone_poll_handle_nonfatal(
        secondary_target_h, "event result secondary target", secondary_copy);
      if (local_status == null || !local_status.ok())
        return local_status;
    end
    local_status = allocate_poll_status_nonfatal(
      event_status, "event result", event_status_copy);
    if (local_status == null || !local_status.ok())
      return local_status;
    success_source = make_status_nonfatal(RDMA_SC_OK, "");
    local_status = allocate_poll_status_nonfatal(
      success_source, "event poll final success", final_success);
    if (local_status == null || !local_status.ok())
      return local_status;

    if ($cast(source_ceqe, decoded_event)) begin
      if (routed_target_h.kind != RDMA_RESOURCE_CQ)
        return make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT, "CEQ event target is not a CQ");
      raw_model = factory_create_object_nonfatal(
        rdma_hw_ceqe_model::get_type(), "prepared_ceqe_model");
      if (raw_model == null || !$cast(ceqe_candidate, raw_model))
        return make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED, "CEQ event model allocation failed");
      ceqe_candidate.cq_h = target_copy;
      ceqe_candidate.producer_index = source_ceqe.producer_index;
      ceqe_candidate.wrap = source_ceqe.wrap;
      ceqe_candidate.solicited = source_ceqe.solicited;
      ceqe_candidate.qpn = source_ceqe.qpn;
      ceqe_candidate.cqn = source_ceqe.cqn;
      ceqe_candidate.ecode = source_ceqe.ecode;
      ceqe_candidate.packet_opcode = source_ceqe.packet_opcode;
      ceqe_candidate.cq_pi = source_ceqe.cq_pi;
      ceqe_candidate.cq_pi_wrap = source_ceqe.cq_pi_wrap;
      ceqe_candidate.valid = source_ceqe.valid;
      // CEQE qword1 是 RC/URC 双布局；快照须复制 URC 全部字段，否则丢失驱动异常上下文。
      ceqe_candidate.urc_flag = source_ceqe.urc_flag;
      ceqe_candidate.urc_sq_cqe_valid = source_ceqe.urc_sq_cqe_valid;
      ceqe_candidate.urc_rq_cqe_valid = source_ceqe.urc_rq_cqe_valid;
      ceqe_candidate.urc_abnormal_cqe_type =
        source_ceqe.urc_abnormal_cqe_type;
      ceqe_candidate.urc_abnormal_cqe_remote_ecode =
        source_ceqe.urc_abnormal_cqe_remote_ecode;
      ceqe_candidate.urc_abnormal_cqe_wqe_idx_wrap =
        source_ceqe.urc_abnormal_cqe_wqe_idx_wrap;
      ceqe_candidate.urc_abnormal_cqe_wqe_idx =
        source_ceqe.urc_abnormal_cqe_wqe_idx;
      ceqe_candidate.urc_hw_cpl_sq_wqe_idx_wrap =
        source_ceqe.urc_hw_cpl_sq_wqe_idx_wrap;
      ceqe_candidate.urc_hw_cpl_sq_wqe_idx =
        source_ceqe.urc_hw_cpl_sq_wqe_idx;
      ceqe_candidate.urc_hw_cpl_rq_wqe_idx_wrap =
        source_ceqe.urc_hw_cpl_rq_wqe_idx_wrap;
      ceqe_candidate.urc_hw_cpl_rq_wqe_idx =
        source_ceqe.urc_hw_cpl_rq_wqe_idx;
      ceqe_candidate.raw_qword1_valid = source_ceqe.raw_qword1_valid;
      ceqe_candidate.raw_qword1 = source_ceqe.raw_qword1;
      ceqe_candidate.profile_transport = source_ceqe.profile_transport;
      ceqe_candidate.profile_transport_valid =
        source_ceqe.profile_transport_valid;
      ceqe_candidate.raw_qword1_replay_authorized =
        source_ceqe.raw_qword1_replay_authorized;
      result_candidate.event_model = ceqe_candidate;
    end
    else if ($cast(source_aeqe, decoded_event)) begin
      case (rdma_aeqe_event_class_from_ecode(source_aeqe.ecode))
        RDMA_AEQE_EVENT_QP:
          if (routed_target_h.kind != RDMA_RESOURCE_QP)
            return make_status_nonfatal(
              RDMA_SC_INVALID_ARGUMENT, "AEQ QP event target is not a QP");
        RDMA_AEQE_EVENT_SRQ:
          if (routed_target_h.kind != RDMA_RESOURCE_SRQ)
            return make_status_nonfatal(
              RDMA_SC_INVALID_ARGUMENT, "AEQ SRQ event target is not an SRQ");
        RDMA_AEQE_EVENT_CQ:
          if (!is_cq_flush && routed_target_h.kind != RDMA_RESOURCE_CQ)
            return make_status_nonfatal(
              RDMA_SC_INVALID_ARGUMENT, "AEQ CQ event target is not a CQ");
        RDMA_AEQE_EVENT_EQ:
          if (routed_target_h.kind != RDMA_RESOURCE_CEQ &&
              routed_target_h.kind != RDMA_RESOURCE_AEQ)
            return make_status_nonfatal(
              RDMA_SC_INVALID_ARGUMENT, "AEQ EQ event target is not an EQ");
        RDMA_AEQE_EVENT_DIAGNOSTIC,
        RDMA_AEQE_EVENT_FLUSH:
          if (routed_target_h.kind != RDMA_RESOURCE_FUNCTION &&
              routed_target_h.kind != RDMA_RESOURCE_QP)
            return make_status_nonfatal(
              RDMA_SC_INVALID_ARGUMENT, "AEQ event target kind is invalid");
        default: return make_status_nonfatal(
          RDMA_SC_INVALID_ARGUMENT, "AEQ event class is invalid");
      endcase
      raw_model = factory_create_object_nonfatal(
        rdma_hw_aeqe_model::get_type(), "prepared_aeqe_model");
      if (raw_model == null || !$cast(aeqe_candidate, raw_model))
        return make_status_nonfatal(
          RDMA_SC_RESOURCE_EXHAUSTED, "AEQ event model allocation failed");
      // CQ flush 的 primary miss 是可交付 partial 状态：target_copy 保持 null，
      // secondary QP 单独写入 result，不能投影成 canonical CQ owner。
      aeqe_candidate.target_h = target_copy;
      aeqe_candidate.event_code = source_aeqe.event_code;
      aeqe_candidate.syndrome = source_aeqe.syndrome;
      aeqe_candidate.severity = source_aeqe.severity;
      aeqe_candidate.qpn = source_aeqe.qpn;
      aeqe_candidate.qp_state = source_aeqe.qp_state;
      aeqe_candidate.ecode = source_aeqe.ecode;
      aeqe_candidate.packet_opcode = source_aeqe.packet_opcode;
      aeqe_candidate.wqe_index = source_aeqe.wqe_index;
      aeqe_candidate.wqe_wrap = source_aeqe.wqe_wrap;
      aeqe_candidate.valid = source_aeqe.valid;
      // AEQE 字段来自 defs.h/event.c 的逐位布局；flags 与拆分 CQN/EQN 须按原字段传播。
      aeqe_candidate.srfq_en = source_aeqe.srfq_en;
      aeqe_candidate.overflow_flag = source_aeqe.overflow_flag;
      aeqe_candidate.urc_flag = source_aeqe.urc_flag;
      aeqe_candidate.cq_invalid_flag = source_aeqe.cq_invalid_flag;
      aeqe_candidate.urc_abnormal_cqe_type =
        source_aeqe.urc_abnormal_cqe_type;
      aeqe_candidate.cqn_eqn_high = source_aeqe.cqn_eqn_high;
      aeqe_candidate.cqn_eqn_low = source_aeqe.cqn_eqn_low;
      aeqe_candidate.urc_remote_ecode = source_aeqe.urc_remote_ecode;
      aeqe_candidate.srfqn = source_aeqe.srfqn;
      aeqe_candidate.srfqe_idx = source_aeqe.srfqe_idx;

      // 解码得到的两个物理 qword 是 detached event 的证据，不能丢失；canonical owner 须由本次
      // route 决策重新冻结，不能从 projected QP target 或默认 enum 猜测。
      aeqe_candidate.raw_qwords_valid = source_aeqe.raw_qwords_valid;
      aeqe_candidate.raw_qword0 = source_aeqe.raw_qword0;
      aeqe_candidate.raw_qword1 = source_aeqe.raw_qword1;
      aeqe_candidate.raw_replay_authorized =
        source_aeqe.raw_replay_authorized;
      local_status = aeqe_candidate.set_profile_owner_authority(
        rdma_aeqe_event_class_from_ecode(source_aeqe.ecode),
        is_cq_flush ? RDMA_RESOURCE_CQ : routed_target_h.kind);
      if (local_status == null || !local_status.ok())
        return local_status == null ?
          make_status_nonfatal(
            RDMA_SC_INVALID_STATE,
            "AEQ candidate owner authority setup returned null status") :
          local_status;
      result_candidate.event_model = aeqe_candidate;
    end
    else begin
      return make_status_nonfatal(
        RDMA_SC_CODEC_ERROR, "event result model type is unsupported");
    end
    result_candidate.queue_h = queue_copy;
    result_candidate.event_status = event_status_copy;
    result_candidate.secondary_target_h = secondary_copy;
    candidate = result_candidate;
    return make_status_nonfatal(RDMA_SC_OK, "");
  endfunction

  // 功能：单 owner event 构造入口，以 secondary_target_h=null 调用完整投影。
  // 输入/输出及副作用：queue_h/decoded_event/routed_target_h/event_status 输入，candidate/
  //   final_success 输出；不接触 engine、runtime 或 backing。
  // 失败/边界：沿用 ex 入口的拒绝条件；不猜测 flush secondary，失败输出须丢弃。
  static function automatic rdma_status prepare_event_result_candidate(
    rdma_handle queue_h,
    rdma_hw_model decoded_event,
    rdma_handle routed_target_h,
    rdma_status event_status,
    output rdma_queue_event_result candidate,
    output rdma_status final_success
  );
    return prepare_event_result_candidate_ex(
      queue_h, decoded_event, routed_target_h, event_status,
      candidate, final_success, null
    );
  endfunction

  // 功能：把 handle 的 kind、Function UID、object ID、generation 编码为 engine 表的身份键。
  // 输入/输出及副作用：handle 输入，返回字符串，只读。
  // 失败/边界：handle=null 返回空键；键不含 cursor/route/reset epoch，这些由 attachment/runtime 另验。
  static function automatic string identity_key(rdma_handle handle);
    if (handle == null)
      return "";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：在 identity_key 后追加 runtime kind，使同一 QP 的 SQ/RQ attachment 索引互不共享。
  // 输入/输出及副作用：handle、kind 输入，返回字符串，只读。
  // 失败/边界：handle=null 返回空键；不校验 kind 与 handle 的组合，由 create/lookup 校验。
  static function automatic string attachment_key(
    rdma_handle handle, rdma_queue_runtime_kind_e kind
  );
    if (handle == null)
      return "";
    return {identity_key(handle), $sformatf(":%0d", kind)};
  endfunction

  // 功能：为 CQ resize recovery 生成跨 generation 稳定的索引键。
  // 输入/输出及副作用：只读 kind、Function UID、object ID，返回字符串。
  // 失败/边界：空句柄或非 CQ 句柄返回空键；旧代际记录在 cleanup 完成前不得与新 resize 事务并存。
  static function automatic string cq_recovery_key(rdma_handle handle);
    if (handle == null || handle.kind != RDMA_RESOURCE_CQ)
      return "";
    return $sformatf("%0d:%016h:%08h:%0d", handle.kind,
                     handle.function_uid, handle.object_id,
                     RDMA_QUEUE_RUNTIME_CQ);
  endfunction

  // 功能：比较 CQ recovery 的不可变身份，忽略 generation，使 reset 后仍能定位旧 backing 清理记录。
  // 输入/输出及副作用：lhs/rhs 只读，返回 bit。
  // 失败/边界：句柄为空、非 CQ 或 Function/object 不一致返回 0；generation 由 retry_cq_resize_cleanup 约束。
  static function automatic bit same_cq_recovery_identity(
    rdma_handle lhs, rdma_handle rhs
  );
    if (lhs == null || rhs == null || lhs.kind != RDMA_RESOURCE_CQ ||
        rhs.kind != RDMA_RESOURCE_CQ)
      return 1'b0;
    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id;
  endfunction

  // 功能：比较两个资源句柄的完整 incarnation，供 CQE/CEQE/SQE authority 和 attachment 索引复用。
  // 输入/输出及副作用：lhs、rhs 只读；判空后转发 rdma_handle::same_instance，无副作用。
  // 失败/边界：任一为空返回 0；不验证 route、reset epoch、attachment 状态或 alias，调用方保留
  //   各自的 valid/status 门禁和错误优先级。
  static function automatic bit same_handle_instance(
    rdma_handle lhs,
    rdma_handle rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：判断 attachment.queue_h 与 recover_queue 目标是否同一完整 incarnation，供各 recovery
  //   扫描复用身份门禁。
  // 输入/输出及副作用：attachment、queue_h 只读，调用 same_handle_instance，无副作用。
  // 失败/边界：attachment、attachment.queue_h 或 queue_h 为空返回 0；不检查 runtime/状态/
  //   reservation/route/epoch，调用方保留各分支的状态门禁和首错顺序。
  static function automatic bit attachment_matches_queue_identity(
    rdma_queue_data_attachment attachment,
    rdma_handle queue_h
  );
    if (attachment == null || attachment.queue_h == null || queue_h == null)
      return 1'b0;
    return same_handle_instance(attachment.queue_h, queue_h);
  endfunction

  // 功能：判断 recovery pending 的 queue_h 与 attachment.queue_h 是否同一完整 incarnation，
  //   供 device producer 与 consumer replay 共用。
  // 输入/输出及副作用：pending、attachment 只读，委托 same_handle_instance，无副作用。
  // 失败/边界：任一对象或 queue_h 为空返回 0；只比较句柄 incarnation，不比较 kind/producer/状态/
  //   cursor/route/epoch/geometry，调用方保留这些门禁与短路顺序。
  static function automatic bit pending_queue_handle_matches_attachment(
    rdma_queue_pending_operation pending,
    rdma_queue_data_attachment attachment
  );
    if (pending == null || attachment == null ||
        pending.queue_h == null || attachment.queue_h == null)
      return 1'b0;
    return same_handle_instance(pending.queue_h, attachment.queue_h);
  endfunction

  // 功能：按 CQE 的 receive 标志选择 QP link 的唯一 CQ route 并比较 CQ handle 完整 incarnation，
  //   供精确 QPN、超宽 QPN 投影和 poll 重查共用。
  // 输入/输出及副作用：link、cq_h、rq_cqe 只读，返回 bit，无副作用。
  // 失败/边界：link 或 cq_h 为空返回 0；rq_cqe=0 只比 send_cq_h，=1 只比 recv_cq_h，所选 route
  //   为空或不一致返回 0；不检查 QPN 宽度/duplicate/transport/SRQ/route/epoch，由调用方保留。
  static function automatic bit qp_link_cq_route_matches(
    rdma_queue_data_qp_link link,
    rdma_handle cq_h,
    bit rq_cqe
  );
    if (link == null || cq_h == null)
      return 1'b0;
    if (rq_cqe)
      return link.recv_cq_h != null &&
             same_handle_instance(link.recv_cq_h, cq_h);
    return link.send_cq_h != null &&
           same_handle_instance(link.send_cq_h, cq_h);
  endfunction

  // 功能：比较两个 route key 的 Host/root/segment/BDF 字段，确认 recovery 仍在原 Function 路径。
  // 输入/输出及副作用：lhs/rhs 只读，返回 bit。
  // 失败/边界：任一字段不一致返回 0。
  static function automatic bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：校验 CQC shadow context backing 的资源类型、CQ local ID、slot 大小及 shadow view 固定
  //   偏移和长度，确认 context_ref 可作 CQC shadow ABI 的几何 authority。
  // 输入/输出及副作用：context_ref、local_id 只读，返回 bit，无副作用。
  // 失败/边界：context_ref 为空或任一几何字段不符合 CQ/固定 ABI 值返回 0；不检查 context_backing、
  //   attachment kind、pending 阶段、owner、route/epoch，调用方保留这些门禁。
  static function automatic bit cqc_shadow_context_geometry_valid(
    rdma_context_backing_ref context_ref,
    int unsigned local_id
  );
    if (context_ref == null)
      return 1'b0;
    return context_ref.resource_kind == RDMA_RESOURCE_CQ &&
           context_ref.local_id == local_id &&
           context_ref.slot_length == 64 &&
           context_ref.shadow_view_offset == RDMA_CQC_SHADOW_AREA_OFFSET &&
           context_ref.shadow_view_length == RDMA_CQC_SHADOW_AREA_SIZE;
  endfunction

  // 功能：比较 CQC shadow context 冻结的 Function owner 与当前 binding 的三项生命周期身份，
  //   统一 prepare 与 replay 的 stale-owner 判定。
  // 输入/输出及副作用：context_ref、function_h 只读，比较 function_uid/object_id/generation。
  // 失败/边界：context_ref、owner 或 function_h 为空、任一字段不等返回 0；不比较 owner.kind、
  //   几何、route、epoch 等，调用方保留 null 短路与 STALE_GENERATION 错误优先级。
  static function automatic bit cqc_shadow_context_owner_matches(
    rdma_context_backing_ref context_ref,
    rdma_function_handle function_h
  );
    if (context_ref == null || context_ref.owner == null || function_h == null)
      return 1'b0;
    return context_ref.owner.function_uid == function_h.function_uid &&
           context_ref.owner.object_id == function_h.object_id &&
           context_ref.owner.generation == function_h.generation;
  endfunction

  // 功能：比较两个 reservation/cursor 快照的 index 与 wrap，供 device publish/recovery 和
  //   unclaimed abort 复用。
  // 输入/输出及副作用：lhs、rhs 只读，返回 bit，无副作用。
  // 失败/边界：任一为空返回 0；不判断 reservation_valid/identity/route/epoch，相同 index/wrap
  //   不能证明拥有同一 reservation。
  static function automatic bit same_cursor_value(
    rdma_queue_cursor_snapshot lhs,
    rdma_queue_cursor_snapshot rhs
  );
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.index == rhs.index && lhs.wrap == rhs.wrap;
  endfunction

  // 功能：对比 recovery pending 冻结的 route/epoch 与 runtime 当前查询结果，复用于
  //   device/consumer retry 的 authority 门禁。
  // 输入/输出及副作用：pending、runtime_route/epoch 及 valid 位只读；route 由 same_route 比较。
  // 失败/边界：pending 为空、任一 valid 位为 0 或 route/epoch 不符返回 0；不验证 route key
  //   内容，调用方保留错误优先级并先处理查询失败。
  static function automatic bit pending_route_epoch_matches(
    rdma_queue_pending_operation pending,
    rdma_route_key_t runtime_route,
    bit runtime_route_valid,
    rdma_reset_epoch_t runtime_epoch,
    bit runtime_epoch_valid
  );
    if (pending == null || !runtime_route_valid || !runtime_epoch_valid ||
        !pending.route_valid || !pending.epoch_valid)
      return 1'b0;
    return same_route(pending.route, runtime_route) &&
           pending.reset_epoch == runtime_epoch;
  endfunction

  // 功能：把 reservation admission 时冻结的 route/reset epoch 写入新建的 host-producer pending，
  //   覆盖 make_pending 对当前 runtime 的兼容查询结果。
  // 输入/输出及副作用：pending 为待发布 evidence；route、epoch、valid 位为 caller 在 reserve 前取得；
  //   只修改 pending 的四个 authority 字段。
  // 失败/边界：pending 为空、valid 位不全或 route 非法返回 0 并清空 authority；成功后 replay 可
  //   区分 reservation incarnation。
  static function automatic bit apply_host_producer_pending_route_epoch(
    rdma_queue_pending_operation pending,
    rdma_route_key_t route,
    rdma_reset_epoch_t epoch,
    bit route_valid,
    bit epoch_valid
  );
    if (pending == null || !route_valid || !epoch_valid ||
        !rdma_route_key_valid(route)) begin
      if (pending != null) begin
        pending.route = '0;
        pending.route_valid = 1'b0;
        pending.reset_epoch = '0;
        pending.epoch_valid = 1'b0;
      end
      return 1'b0;
    end
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    return 1'b1;
  endfunction
endclass
