// 目录：测试层 unit/rdma_queue_detached_snapshot_test.sv。
// 职责：独立验证 queue-data projector 的身份/route 值边界，以及在 consumer barrier 前
//   构造的 CQE、CEQE 和 AEQE candidate 不丢失驱动 typed/raw 字段。
// 依赖：依赖 rdma_queue_data_projector、queue codec model、runtime slot model 与 UVM
//   factory；本文件不访问 Host-memory、PCIe 或真实生命周期 executor。
// 所有权与生命周期：测试只拥有本地 probe、model、handle 和 candidate；被测 helper
//   不取得这些对象的外部所有权，测试在 run_phase 结束时释放 objection。

// 设计说明：prepare_*_candidate 是 queue-data 的值边界。它们必须把已解码的
// 驱动物理 overlay 一起搬到 detached 结果，不能只复制当前业务分支恰好使用的
// 字段；否则 poll 成功后原始字节审计和异常上下文都会丢失。
// probe 不再继承或构造 engine，确保值投影的测试无需 planner、配置、attachment 或运行时账本。
class rdma_queue_detached_snapshot_probe extends uvm_object;
  `uvm_object_utils(rdma_queue_detached_snapshot_probe)

  // 功能：构造只转发值投影的测试对象，不再创建生产 engine 或其 backing planner。
  // 输入/输出及副作用：name 只设置 UVM 名称；对象不保存 fixture、runtime 或 adapter 引用。
  // 失败/边界：该 probe 不能执行 post/poll，也不提供 authority admission；只用于本地值契约测试。
  function new(string name = "rdma_queue_detached_snapshot_probe");
    super.new(name);
  endfunction

  // 功能：prepare_cqe 暴露生产 CQ completion candidate helper，供测试直接检查
  //   detached CQE 的字段和值隔离，不执行 consumer admission 或 WQE release。
  // 输入/输出及副作用：cq_h、decoded_cqe、result_qp_h、completion_status 和
  //   release_snapshots 为输入；candidate/final_success 为输出；更新并复用输入 detached slot。
  // 失败/边界：输入缺失、factory 或 slot 失败时返回非成功，可能留下 final_success 和已更新
  //   slot；最终 status 创建失败也可留下 candidate，测试必须以返回状态判断，不使用失败输出。
  function rdma_status prepare_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model decoded_cqe,
    rdma_handle result_qp_h,
    rdma_status completion_status,
    rdma_queue_slot_ledger_entry release_snapshots[$],
    output rdma_queue_completion_result candidate,
    output rdma_status final_success
  );
    return rdma_queue_data_projector::prepare_cq_completion_candidate(
      cq_h, decoded_cqe, result_qp_h, completion_status,
      release_snapshots, candidate, final_success);
  endfunction

  // 功能：prepare_event 暴露生产 CEQ/AEQ event candidate helper，供测试检查
  //   typed overlay 与 raw authority 是否完整进入 detached event result。
  // 输入/输出及副作用：queue_h、decoded_event、routed_target_h、event_status 为
  //   输入；candidate/final_success 为输出；只分配新结果和模型，不修改 source。
  // 失败/边界：事件类型与目标 kind 不匹配、factory 失败或输入缺失时返回非成功，
  //   不进入 scheduler，也不改变 queue/runtime/backing 状态。
  function rdma_status prepare_event(
    rdma_handle queue_h,
    rdma_hw_model decoded_event,
    rdma_handle routed_target_h,
    rdma_status event_status,
    output rdma_queue_event_result candidate,
    output rdma_status final_success
  );
    return rdma_queue_data_projector::prepare_event_result_candidate(
      queue_h, decoded_event, routed_target_h, event_status,
      candidate, final_success);
  endfunction
endclass

class rdma_queue_detached_snapshot_test extends uvm_test;
  `uvm_component_utils(rdma_queue_detached_snapshot_test)

  // 功能：构造 detached snapshot 测试组件，等待 run_phase 创建独立 probe 和
  //   全部值对象。
  // 输入/输出及副作用：name、parent 为输入；构造不申请外部资源或启动仿真线程。
  // 失败/边界：依赖缺失由 run_phase 的具体断言报告，构造本身不伪造成功状态。
  function new(string name = "rdma_queue_detached_snapshot_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：make_handle 创建带有明确 kind、Function UID、object ID 和 generation
  //   的 detached handle，作为 candidate helper 的输入 authority。
  // 输入/输出及副作用：kind、object_id、generation 为输入；返回新 handle，不修改
  //   任何 manager/binding，也不把 handle 所有权转移给被测 engine。
  // 失败/边界：factory 返回 null 时返回 null；调用方必须在继续构造 model 前检查。
  function automatic rdma_handle make_handle(
    rdma_resource_kind_e kind,
    int unsigned object_id,
    int unsigned generation
  );
    rdma_handle handle;

    handle = rdma_handle::type_id::create("snapshot_test_handle");
    if (handle == null)
      return null;
    handle.kind = kind;
    handle.function_uid = 64'h1122_3344_5566_7788;
    handle.object_id = object_id;
    handle.generation = generation;
    return handle;
  endfunction

  // 功能：make_slot 构造一个已 post 的 detached release snapshot，使 CQE
  //   candidate helper 能复制最后一个 WQE 的 WR 标识而无需 live runtime。
  // 输入/输出及副作用：wr_id、index、wrap 为输入；返回新 slot，仅写本地字段。
  // 失败/边界：factory 失败返回 null；空 slot 不代表可释放的 WQE，测试会报告错误。
  function automatic rdma_queue_slot_ledger_entry make_slot(
    longint unsigned wr_id,
    int unsigned index,
    bit wrap
  );
    rdma_queue_slot_ledger_entry slot;

    slot = rdma_queue_slot_ledger_entry::type_id::create("snapshot_test_slot");
    if (slot == null)
      return null;
    slot.posted = 1'b1;
    slot.consumed = 1'b0;
    slot.signaled = 1'b1;
    slot.wr_id = wr_id;
    slot.index = index;
    slot.wrap = wrap;
    return slot;
  endfunction

  // 功能：check_identity_value_boundary 独立验证完整 incarnation 与跨 generation cleanup key
  //   的区别，并锁定 attachment/link、cursor、route/epoch 的只读值门禁。
  // 输入/输出及副作用：无参数；创建不绑定 runtime 的本地 handle/attachment/pending/link/cursor，
  //   逐字段改变 route 副本，检查 pending authority 写入/清空；不配置 engine 或外部 authority。
  // 失败/边界：null、代际/方向/游标不符、任一 route 字段或 epoch/valid 位漂移必须拒绝；
  //   显式 valid 的零 epoch 沿用值层接受语义，不把值相等当作资源准入；任一违例报告 UVM_ERROR。
  task automatic check_identity_value_boundary();
    rdma_handle old_h;
    rdma_handle fresh_h;
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot lhs;
    rdma_queue_cursor_snapshot rhs;
    rdma_route_key_t route;
    rdma_route_key_t changed_route;

    old_h = make_handle(RDMA_RESOURCE_CQ, 3, 9);
    fresh_h = make_handle(RDMA_RESOURCE_CQ, 3, 10);
    if (old_h == null || fresh_h == null) begin
      `uvm_error("VALUE_ID_SETUP", "identity fixture allocation failed")
      return;
    end
    if (rdma_queue_data_projector::same_handle_instance(old_h, fresh_h) ||
        !rdma_queue_data_projector::same_cq_recovery_identity(old_h, fresh_h) ||
        rdma_queue_data_projector::identity_key(old_h) ==
          rdma_queue_data_projector::identity_key(fresh_h) ||
        rdma_queue_data_projector::cq_recovery_key(old_h) !=
          rdma_queue_data_projector::cq_recovery_key(fresh_h))
      `uvm_error("VALUE_ID_GENERATION", "live identity and cleanup identity were conflated")
    if (rdma_queue_data_projector::identity_key(null) != "" ||
        rdma_queue_data_projector::attachment_key(null, RDMA_QUEUE_RUNTIME_SQ) != "" ||
        rdma_queue_data_projector::cq_recovery_key(null) != "" ||
        rdma_queue_data_projector::same_handle_instance(null, old_h) ||
        rdma_queue_data_projector::attachment_key(old_h, RDMA_QUEUE_RUNTIME_SQ) ==
          rdma_queue_data_projector::attachment_key(old_h, RDMA_QUEUE_RUNTIME_RQ))
      `uvm_error("VALUE_ID_NULL_KIND", "null or SQ/RQ key isolation changed")

    attachment = new("value_attachment");
    pending = new("value_pending");
    link = new("value_link");
    attachment.queue_h = old_h;
    pending.queue_h = old_h;
    link.send_cq_h = old_h;
    link.recv_cq_h = fresh_h;
    if (!rdma_queue_data_projector::attachment_matches_queue_identity(attachment, old_h) ||
        rdma_queue_data_projector::attachment_matches_queue_identity(attachment, fresh_h) ||
        !rdma_queue_data_projector::pending_queue_handle_matches_attachment(pending, attachment) ||
        !rdma_queue_data_projector::qp_link_cq_route_matches(link, old_h, 1'b0) ||
        rdma_queue_data_projector::qp_link_cq_route_matches(link, old_h, 1'b1) ||
        attachment.runtime != null)
      `uvm_error("VALUE_ID_ROUTE", "identity predicates depended on runtime or lost direction")
    lhs = new("value_cursor_lhs");
    rhs = new("value_cursor_rhs");
    lhs.index = 7;
    rhs.index = 7;
    if (!rdma_queue_data_projector::same_cursor_value(lhs, rhs) ||
        rdma_queue_data_projector::same_cursor_value(null, rhs))
      `uvm_error("VALUE_CURSOR", "equal/null cursor comparison changed")
    rhs.wrap = ~lhs.wrap;
    if (rdma_queue_data_projector::same_cursor_value(lhs, rhs))
      `uvm_error("VALUE_CURSOR_WRAP", "cursor wrap was ignored")

    route = '0;
    route.bdf.bus = 1;
    if (!rdma_queue_data_projector::apply_host_producer_pending_route_epoch(
          pending, route, 7, 1'b1, 1'b1) ||
        !rdma_queue_data_projector::pending_route_epoch_matches(pending, route, 1'b1, 7, 1'b1) ||
        rdma_queue_data_projector::pending_route_epoch_matches(pending, route, 1'b1, 8, 1'b1) ||
        rdma_queue_data_projector::pending_route_epoch_matches(pending, route, 1'b0, 7, 1'b1) ||
        rdma_queue_data_projector::pending_route_epoch_matches(pending, route, 1'b1, 7, 1'b0))
      `uvm_error("VALUE_EPOCH", "pending authority value or valid-bit comparison changed")
    for (int unsigned field = 0; field < 7; field++) begin
      changed_route = route;
      case (field)
        0: changed_route.host_topology_key++;
        1: changed_route.root_id++;
        2: changed_route.segment++;
        3: changed_route.bdf.segment++;
        4: changed_route.bdf.bus++;
        5: changed_route.bdf.device++;
        default: changed_route.bdf.function_num++;
      endcase
      if (rdma_queue_data_projector::same_route(route, changed_route) ||
          rdma_queue_data_projector::pending_route_epoch_matches(
            pending, changed_route, 1'b1, 7, 1'b1))
        `uvm_error("VALUE_ROUTE_FIELD", $sformatf("route field %0d was ignored", field))
    end
    if (!rdma_queue_data_projector::apply_host_producer_pending_route_epoch(
          pending, route, 0, 1'b1, 1'b1) ||
        !rdma_queue_data_projector::pending_route_epoch_matches(pending, route, 1'b1, 0, 1'b1))
      `uvm_error("VALUE_ZERO_EPOCH", "value layer unexpectedly added epoch admission")
    if (rdma_queue_data_projector::apply_host_producer_pending_route_epoch(
          pending, route, 7, 1'b1, 1'b0) ||
        pending.route_valid || pending.epoch_valid || pending.route != '0 ||
        pending.reset_epoch != 0 ||
        rdma_queue_data_projector::apply_host_producer_pending_route_epoch(
          pending, '0, 7, 1'b1, 1'b1) ||
        rdma_queue_data_projector::apply_host_producer_pending_route_epoch(
          null, route, 7, 1'b1, 1'b1))
      `uvm_error("VALUE_AUTHORITY_CLEAR", "invalid pending authority was not cleared/rejected")
  endtask

  // 功能：check_cqe_snapshot 验证 RC CQE candidate 复制公共头、variant、flags、
  //   qword2 raw/typed overlay、UD metadata 和 detached payload 的完整值。
  // 输入/输出及副作用：probe 为输入；创建本地 handles/model/slot 并报告断言，
  //   不访问 queue runtime、CQ backing 或 consumer cursor。
  // 失败/边界：任一 factory/helper 返回非成功、candidate 缺失或字段不等时发布
  //   UVM_ERROR；该测试故意覆盖此前容易被“只复制公共字段”遗漏的值。
  task automatic check_cqe_snapshot(
    rdma_queue_detached_snapshot_probe probe
  );
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_hw_cqe_model source;
    rdma_queue_slot_ledger_entry slots[$];
    rdma_queue_completion_result candidate;
    rdma_status final_success;
    rdma_status status;

    cq_h = make_handle(RDMA_RESOURCE_CQ, 3, 9);
    qp_h = make_handle(RDMA_RESOURCE_QP, 7, 9);
    source = rdma_hw_cqe_model::type_id::create("snapshot_test_cqe");
    if (cq_h == null || qp_h == null || source == null) begin
      `uvm_error("DETACHED_CQE_SETUP", "CQE snapshot fixture allocation failed")
      return;
    end

    source.qp_h = qp_h;
    source.variant = RDMA_CQE_VARIANT_RC;
    source.qpn = 18'h2a5;
    source.qp_state = 3'd4;
    source.wqe_index = 15'h1234;
    source.wqe_wrap = 1'b1;
    source.polarity = 1'b0;
    source.rq_cqe = 1'b0;
    source.srfq = 1'b1;
    source.se = 1'b1;
    source.sign_en = 1'b1;
    source.vlan = 1'b1;
    source.ipv6 = 1'b1;
    source.cqe_format = 2'b10;
    source.resize_cqe = 1'b1;
    source.ud_mc = 1'b1;
    source.packet_opcode = 8'hc7;
    source.ecode = 8'h5a;
    source.payload_len = 32'd4;
    source.immediate_data = 32'h1020_3040;
    source.immdt_data_invld_key = 32'h1020_3040;
    source.signature = 8'ha1;
    source.rc_remote_syndrome = 8'hb2;
    source.ud_src_qpn = 24'hc3d4e5;
    source.rqe_cpl = 1'b1;
    source.srfqn = 12'habc;
    source.srfqe_wrap = 1'b1;
    source.srfqe_index = 15'h4567;
    source.raw_qword2_valid = 1'b1;
    source.raw_qword2 = 64'ha1b2_c3d4_e580_4567;
    source.ud_smac = 48'h1122_3344_5566;
    source.ud_vlan_tag = 16'h7788;
    source.payload.push_back(8'h01);
    source.payload.push_back(8'h23);
    source.payload.push_back(8'h45);
    source.payload.push_back(8'h67);
    source.status = rdma_status::success();
    slots.push_back(make_slot(64'hfeed_beef_0102_0304, 4, 1'b1));
    status = probe.prepare_cqe(
      cq_h, source, qp_h, rdma_status::success(), slots,
      candidate, final_success);
    if (status == null || !status.ok() || candidate == null ||
        candidate.cqe == null || final_success == null) begin
      `uvm_error("DETACHED_CQE_STATUS", "CQE candidate preparation failed")
      return;
    end

    if (candidate.cqe.variant != source.variant ||
        candidate.cqe.qp_state != source.qp_state ||
        candidate.cqe.srfq != source.srfq ||
        candidate.cqe.se != source.se ||
        candidate.cqe.sign_en != source.sign_en ||
        candidate.cqe.vlan != source.vlan ||
        candidate.cqe.ipv6 != source.ipv6 ||
        candidate.cqe.cqe_format != source.cqe_format ||
        candidate.cqe.resize_cqe != source.resize_cqe ||
        candidate.cqe.ud_mc != source.ud_mc ||
        candidate.cqe.immdt_data_invld_key != source.immdt_data_invld_key ||
        candidate.cqe.rc_remote_syndrome != source.rc_remote_syndrome ||
        candidate.cqe.ud_src_qpn != source.ud_src_qpn ||
        candidate.cqe.rqe_cpl != source.rqe_cpl ||
        candidate.cqe.srfqn != source.srfqn ||
        candidate.cqe.srfqe_wrap != source.srfqe_wrap ||
        candidate.cqe.srfqe_index != source.srfqe_index ||
        candidate.cqe.raw_qword2_valid != source.raw_qword2_valid ||
        candidate.cqe.raw_qword2 != source.raw_qword2 ||
        candidate.cqe.ud_smac != source.ud_smac ||
        candidate.cqe.ud_vlan_tag != source.ud_vlan_tag ||
        candidate.cqe.payload.size() != source.payload.size()) begin
      `uvm_error("DETACHED_CQE_FIELDS",
                 "CQE detached candidate lost a driver field or payload")
    end
    foreach (source.payload[i]) begin
      if (candidate.cqe.payload[i] !== source.payload[i])
        `uvm_error("DETACHED_CQE_PAYLOAD",
                   $sformatf("CQE payload byte %0d changed", i))
    end
  endtask

  // 功能：check_event_snapshots 验证 CEQE raw qword1 authority 与 typed URC overlay
  //   以及 AEQE 全部驱动字段均被复制到 detached event result。
  // 输入/输出及副作用：probe 为输入；创建本地 CEQ/CQ/QP handles 和 event models，
  //   只调用 candidate helper 并报告字段差异。
  // 失败/边界：事件 target kind 错误、helper/factory 失败或任一字段丢失发布
  //   UVM_ERROR；source models 在检查后仍保持不变。
  task automatic check_event_snapshots(
    rdma_queue_detached_snapshot_probe probe
  );
    rdma_handle ceq_h;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_hw_ceqe_model source_ceqe;
    rdma_hw_ceqe_model copied_ceqe;
    rdma_hw_aeqe_model source_aeqe;
    rdma_hw_aeqe_model copied_aeqe;
    rdma_queue_event_result candidate;
    rdma_status final_success;
    rdma_status status;

    ceq_h = make_handle(RDMA_RESOURCE_CEQ, 11, 9);
    cq_h = make_handle(RDMA_RESOURCE_CQ, 3, 9);
    qp_h = make_handle(RDMA_RESOURCE_QP, 7, 9);
    source_ceqe = rdma_hw_ceqe_model::type_id::create("snapshot_test_ceqe");
    source_aeqe = rdma_hw_aeqe_model::type_id::create("snapshot_test_aeqe");
    if (ceq_h == null || cq_h == null || qp_h == null ||
        source_ceqe == null || source_aeqe == null) begin
      `uvm_error("DETACHED_EVENT_SETUP", "event snapshot fixture allocation failed")
      return;
    end

    source_ceqe.cq_h = cq_h;
    source_ceqe.qpn = 21'h15555;
    source_ceqe.cqn = 21'h1a2b3;
    source_ceqe.ecode = 8'he1;
    source_ceqe.packet_opcode = 8'h34;
    source_ceqe.cq_pi = 16'h5678;
    source_ceqe.cq_pi_wrap = 1'b1;
    source_ceqe.valid = 1'b0;
    source_ceqe.urc_flag = 1'b1;
    source_ceqe.urc_sq_cqe_valid = 1'b1;
    source_ceqe.urc_rq_cqe_valid = 1'b0;
    source_ceqe.urc_abnormal_cqe_type = 2'b11;
    source_ceqe.urc_abnormal_cqe_remote_ecode = 8'ha6;
    source_ceqe.urc_abnormal_cqe_wqe_idx_wrap = 1'b1;
    source_ceqe.urc_abnormal_cqe_wqe_idx = 15'h1357;
    source_ceqe.urc_hw_cpl_sq_wqe_idx_wrap = 1'b0;
    source_ceqe.urc_hw_cpl_sq_wqe_idx = 15'h2468;
    source_ceqe.urc_hw_cpl_rq_wqe_idx_wrap = 1'b1;
    source_ceqe.urc_hw_cpl_rq_wqe_idx = 15'h369c;
    source_ceqe.raw_qword1_valid = 1'b1;
    source_ceqe.raw_qword1 = 64'hd00d_1234_5678_9abc;
    status = probe.prepare_event(
      ceq_h, source_ceqe, cq_h, rdma_status::success(),
      candidate, final_success);
    if (status == null || !status.ok() || candidate == null ||
        !$cast(copied_ceqe, candidate.event_model) || copied_ceqe == null) begin
      `uvm_error("DETACHED_CEQE_STATUS", "CEQE candidate preparation failed")
    end
    else if (copied_ceqe.raw_qword1_valid != source_ceqe.raw_qword1_valid ||
             copied_ceqe.raw_qword1 != source_ceqe.raw_qword1 ||
             copied_ceqe.urc_abnormal_cqe_type !=
               source_ceqe.urc_abnormal_cqe_type ||
             copied_ceqe.urc_hw_cpl_rq_wqe_idx !=
               source_ceqe.urc_hw_cpl_rq_wqe_idx) begin
      `uvm_error("DETACHED_CEQE_FIELDS",
                 "CEQE detached candidate lost raw or URC field")
    end

    source_aeqe.target_h = qp_h;
    source_aeqe.qpn = 18'h2aaaa;
    source_aeqe.qp_state = 3'd5;
    source_aeqe.ecode = 8'h7f;
    source_aeqe.packet_opcode = 8'h91;
    source_aeqe.wqe_index = 23'h456789;
    source_aeqe.wqe_wrap = 1'b1;
    source_aeqe.valid = 1'b0;
    source_aeqe.srfq_en = 1'b1;
    source_aeqe.overflow_flag = 1'b1;
    source_aeqe.urc_flag = 1'b1;
    source_aeqe.cq_invalid_flag = 1'b1;
    source_aeqe.urc_abnormal_cqe_type = 2'b10;
    source_aeqe.cqn_eqn_high = 13'h1234;
    source_aeqe.cqn_eqn_low = 6'h2b;
    source_aeqe.urc_remote_ecode = 8'hc8;
    source_aeqe.srfqn = 12'habc;
    source_aeqe.srfqe_idx = 16'hd234;
    status = probe.prepare_event(
      ceq_h, source_aeqe, qp_h, rdma_status::success(),
      candidate, final_success);
    if (status == null || !status.ok() || candidate == null ||
        !$cast(copied_aeqe, candidate.event_model) || copied_aeqe == null) begin
      `uvm_error("DETACHED_AEQE_STATUS", "AEQE candidate preparation failed")
    end
    else if (copied_aeqe.srfq_en != source_aeqe.srfq_en ||
             copied_aeqe.overflow_flag != source_aeqe.overflow_flag ||
             copied_aeqe.urc_flag != source_aeqe.urc_flag ||
             copied_aeqe.cq_invalid_flag != source_aeqe.cq_invalid_flag ||
             copied_aeqe.cqn_eqn_high != source_aeqe.cqn_eqn_high ||
             copied_aeqe.srfqe_idx != source_aeqe.srfqe_idx) begin
      `uvm_error("DETACHED_AEQE_FIELDS", "AEQE detached candidate lost driver field")
    end
  endtask

  // 功能：run_phase 先检查独立 identity/route 值边界，再执行 CQE/CEQE/AEQE candidate 回归，并在
  //   所有断言完成后释放 UVM objection。
  // 输入/输出及副作用：phase 为输入；创建不继承 engine 的 probe、调用三个检查 task 并向 UVM
  //   报告失败，不访问外部 backing 或生命周期资源。
  // 失败/边界：probe allocation 失败时报告错误并安全结束；任一字段差异由 UVM
  //   summary 汇总为非零 error，防止缺字段修复被误判为通过。
  task run_phase(uvm_phase phase);
    rdma_queue_detached_snapshot_probe probe;

    phase.raise_objection(this);
    check_identity_value_boundary();
    probe = rdma_queue_detached_snapshot_probe::type_id::create(
      "detached_snapshot_probe");
    if (probe == null)
      `uvm_error("DETACHED_PROBE", "detached snapshot probe allocation failed")
    else begin
      check_cqe_snapshot(probe);
      check_event_snapshots(probe);
    end
    phase.drop_objection(this);
  endtask
endclass
