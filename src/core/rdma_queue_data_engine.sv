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

  // 功能：构造 rdma_queue_post_result，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；wr_id=0；index=0；wrap=0；image=null；status=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_post_result 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_post_result");
    super.new(name);
    queue_h = null; wr_id = 0; index = 0; wrap = 0;
    image = null; status = null;
  endfunction
endclass

class rdma_queue_completion_result extends uvm_object;
  `uvm_object_utils(rdma_queue_completion_result)
  rdma_handle queue_h;
  rdma_hw_cqe_model cqe;
  rdma_status completion_status;
  rdma_queue_slot_ledger_entry released_slots[$];

  // 功能：构造 rdma_queue_completion_result，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；cqe=null；completion_status=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_completion_result 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：构造 rdma_queue_event_result，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；event_model=null；event_status=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_event_result 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：构造 rdma_queue_data_attachment，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：queue_h=null；kind=RDMA_QUEUE_RUNTIME_SQ；runtime=null；access=null；role=RDMA_QUEUE_ROLE_CQ_RING；entry_size=64；local_id=0；transport=RDMA_TRANSPORT_RC。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_attachment 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
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

  // 功能：构造 rdma_queue_data_qp_link，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qp_h=null；srq_h=null；send_cq_h=null；recv_cq_h=null；local_qp_id=0；transport=RDMA_TRANSPORT_RC。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_qp_link 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_qp_link");
    super.new(name);
    qp_h = null; srq_h = null; send_cq_h = null; recv_cq_h = null;
    local_qp_id = 0; transport = RDMA_TRANSPORT_RC;
  endfunction
endclass

// CQ resize 在 authority 已发布后，旧 runtime/backing 仍可能因为后端故障
// 无法立即 detach/release。该记录由 engine 持有，直到所有清理动作完成。
class rdma_cq_resize_recovery extends uvm_object;
  `uvm_object_utils(rdma_cq_resize_recovery)

  rdma_handle cq_h;
  // 保存 Function route/UID 的不可变快照，防止 UID/object-id 重用到另一
  // Host/root 后误释放旧 backing；generation/reset epoch 变化本身允许恢复。
  rdma_function_identity function_identity;
  rdma_queue_runtime old_runtime;
  rdma_queue_backing_ref old_ref;
  // 发布前候选 backing 的清理失败也必须保留 opaque authority；published=0
  // 时 retry 只处理 pending_ref，不触碰当前仍在使用的旧 attachment。
  rdma_queue_backing_ref pending_ref;
  bit published;
  // prepublish_restore_pending 表示 manager/CQ 屏障或 dependent runtime
  // 尚未恢复；该状态与 pending_ref 正交，允许一次记录同时保存两类失败。
  bit prepublish_restore_pending;
  bit manager_restore_pending;
  bit cq_restore_pending;
  // 保存旧/候选 CQ ring 的不可变几何，retry 时防止 recovery ref 被替换成
  // 另一 role 或另一 logical slice 后误清理。
  rdma_queue_backing_role_e backing_role;
  longint unsigned backing_mapping_offset;
  longint unsigned backing_length;
  longint unsigned backing_logical_queue_offset;
  bit backing_geometry_valid;
  rdma_reset_epoch_t backing_reset_epoch;
  bit backing_epoch_valid;
  rdma_queue_runtime dependents[$];
  rdma_status last_status;

  // 功能：构造 CQ resize recovery record，初始化旧 authority、依赖 runtime 和最近一次失败状态。
  // 输入输出及副作用：name 为 UVM 对象名称；只建立本地记录，不访问 Host-memory 或 manager。
  // 失败边界：记录为空或字段不完整时，重试入口必须拒绝执行并返回 RECOVERY_REQUIRED。
  function new(string name = "rdma_cq_resize_recovery");
    super.new(name);
    cq_h = null;
    function_identity = null;
    old_runtime = null;
    old_ref = null;
    pending_ref = null;
    published = 1'b0;
    prepublish_restore_pending = 1'b0;
    manager_restore_pending = 1'b0;
    cq_restore_pending = 1'b0;
    backing_role = RDMA_QUEUE_ROLE_CQ_RING;
    backing_mapping_offset = 0;
    backing_length = 0;
    backing_logical_queue_offset = 0;
    backing_geometry_valid = 1'b0;
    backing_reset_epoch = 0;
    backing_epoch_valid = 1'b0;
    dependents.delete();
    last_status = null;
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
  // The planner owns only temporary allocation bookkeeping; mappings remain
  // owned by the lifecycle queue plan after a successful replacement.
  protected rdma_queue_backing_planner backing_planner;
  protected semaphore resize_lock;

  protected rdma_queue_data_attachment attachments[string];
  protected rdma_queue_data_qp_link qp_links[string];
  // 以不含 generation 的稳定 CQ identity 索引发布后尚未完成的旧 backing
  // 清理记录，使 Function reset 后仍能找到旧代际的 release authority。
  protected rdma_cq_resize_recovery cq_resize_recoveries[string];
  protected bit configured;
  // Latest detached URC shadow evidence retained for recovery inspection.
  rdma_queue_txn_evidence last_urc_evidence;

  // 功能：构造 rdma_queue_data_engine，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：manager=null；binding=null；host_mem=null；doorbells=null；registry=null；operation_timeout=0；configured=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine");
    super.new(name);
    manager = null; binding = null; host_mem = null; doorbells = null;
    registry = null; operation_timeout = 0;
    backing_planner = rdma_queue_backing_planner::type_id::create(
      {name, "_backing_planner"});
    resize_lock = new(1);
    attachments.delete(); qp_links.delete(); cq_resize_recoveries.delete();
    last_urc_evidence = null;
    configured = 1'b0;
  endfunction

  // 功能：把 CQ flush 产生的 URC shadow 捕获为 queue-data engine 的可恢复事务证据。
  // 输入/输出及副作用：shadow 为输入；成功时新建并保存 last_urc_evidence 的 detached 快照，不释放或修改外部 runtime。
  // 失败边界：shadow 为空、authority 无效或 evidence 分配失败时返回错误，既有 evidence 保持不变。
  function rdma_status capture_urc_shadow_evidence(rdma_cq_shadow_snapshot shadow);
    rdma_queue_txn_evidence candidate;
    rdma_status status;
    if (shadow == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC CQ shadow evidence is null");
    candidate = rdma_queue_txn_evidence::type_id::create("urc_shadow_evidence");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "URC CQ shadow evidence allocation failed");
    status = candidate.capture_urc_shadow(shadow);
    if (!status.ok()) return status;
    last_urc_evidence = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，bad 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）、RDMA_SC_INVALID_ARGUMENT（输入）；bad 读取 message、code 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：bad 的结果直接由 return rdma_status::make(code, message) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function rdma_status bad(
    string message,
    rdma_status_code_e code = RDMA_SC_INVALID_ARGUMENT
  );
    return rdma_status::make(code, message);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，identity_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：handle（输入）；identity_key 读取 handle 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：identity_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string identity_key(rdma_handle handle);
    if (handle == null) return "";
    return $sformatf("%0d:%016h:%08h:%08h", handle.kind,
                     handle.function_uid, handle.object_id,
                     handle.generation);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，attachment_key 把 attachment_key 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：handle（输入）、kind（输入）；attachment_key 先依据 handle == null 校验 handle、kind；成功时更新本对象配置/状态并保存非拥有引用，返回 string。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  protected function string attachment_key(
    rdma_handle handle, rdma_queue_runtime_kind_e kind
  );
    if (handle == null) return "";
    return {identity_key(handle), $sformatf(":%0d", kind)};
  endfunction

  // 功能：cq_recovery_key 为 CQ resize recovery 生成跨 generation 稳定的索引键。
  // 输入输出及副作用：handle 为输入；函数只读取 kind、Function UID 和 object ID，
  // 返回稳定字符串，不修改 attachment、runtime 或 manager。
  // 失败边界：空句柄或非 CQ 句柄返回空键；同一 Function/object 的旧代际记录在
  // cleanup 完成前不得与新的 resize 事务并存。
  protected function string cq_recovery_key(rdma_handle handle);
    if (handle == null || handle.kind != RDMA_RESOURCE_CQ)
      return "";
    return $sformatf("%0d:%016h:%08h:%0d", handle.kind,
                     handle.function_uid, handle.object_id,
                     RDMA_QUEUE_RUNTIME_CQ);
  endfunction

  // 功能：same_cq_recovery_identity 比较 CQ recovery 所需的不可变身份，忽略
  // Function generation，以便 reset 后仍可定位旧 backing 的清理记录。
  // 输入输出及副作用：lhs/rhs 为输入；函数只读取句柄字段并返回 bit，不修改任何状态。
  // 失败边界：任一句柄为空、类型不是 CQ 或 Function/object identity 不一致时返回 0；
  // generation 不参与比较，代际合法性由 retry_cq_resize_cleanup 另行约束。
  protected function bit same_cq_recovery_identity(
    rdma_handle lhs, rdma_handle rhs
  );
    if (lhs == null || rhs == null || lhs.kind != RDMA_RESOURCE_CQ ||
        rhs.kind != RDMA_RESOURCE_CQ)
      return 1'b0;
    return lhs.function_uid == rhs.function_uid &&
           lhs.object_id == rhs.object_id;
  endfunction

  // 功能：比较两个完整 route key 的 Host/root/segment/BDF 字段，确认 recovery
  // 仍位于原 Function 的 fabric 路径。
  // 输入输出及副作用：lhs/rhs 为输入值；函数只读路由字段并返回 bit。
  // 失败边界：任一路由字段不一致时返回 0，不修改 recovery 或 attachment。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：record_candidate_cleanup_recovery 登记发布前候选 backing 的
  //       opaque release authority，供后续 retry 清理而不覆盖当前 CQ。
  // 输入/输出及副作用：cq_h/new_ref/original_status 为输入；成功时新增
  //       engine-owned recovery record，不修改 manager、attachment 或 runtime。
  // 失败/边界：句柄、binding、ref 或 Function identity 缺失、记录键冲突或
  //       recovery 对象创建失败时返回 RECOVERY_REQUIRED，绝不静默丢弃 ref。
  protected function rdma_status record_candidate_cleanup_recovery(
    rdma_handle cq_h,
    rdma_queue_backing_ref new_ref,
    rdma_status original_status
  );
    rdma_cq_resize_recovery recovery;
    string key;

    if (cq_h == null || new_ref == null || binding == null)
      return bad("CQ candidate cleanup recovery inputs are incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    key = cq_recovery_key(cq_h);
    if (key == "")
      return bad("CQ candidate cleanup recovery key is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    if (cq_resize_recoveries.exists(key))
      return bad("CQ candidate cleanup recovery key is already present",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery = rdma_cq_resize_recovery::type_id::create(
      "cq_candidate_cleanup_recovery");
    if (recovery == null)
      return bad("CQ candidate cleanup recovery allocation failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.cq_h = rdma_clone_handle_value(
      cq_h, "CQ candidate cleanup recovery CQ");
    if (recovery.cq_h == null)
      return bad("CQ candidate cleanup recovery handle snapshot failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.function_identity = binding.function_identity_snapshot();
    if (recovery.function_identity == null)
      return bad("CQ candidate cleanup Function identity snapshot failed",
                 RDMA_SC_RECOVERY_REQUIRED);
    recovery.pending_ref = new_ref;
    recovery.published = 1'b0;
    recovery.prepublish_restore_pending = 1'b0;
    recovery.manager_restore_pending = 1'b0;
    recovery.cq_restore_pending = 1'b0;
    if (new_ref.mapping == null || !new_ref.mapping.epoch_valid) begin
      return bad("CQ candidate cleanup mapping epoch is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    if (new_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        new_ref.cleanup_complete) begin
      return bad("CQ candidate cleanup ownership/state is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    recovery.backing_role = new_ref.role;
    recovery.backing_mapping_offset = new_ref.mapping_offset;
    recovery.backing_length = new_ref.length;
    recovery.backing_logical_queue_offset = new_ref.logical_queue_offset;
    recovery.backing_geometry_valid = 1'b1;
    recovery.backing_reset_epoch = new_ref.mapping.reset_epoch;
    recovery.backing_epoch_valid = 1'b1;
    recovery.last_status = original_status;
    cq_resize_recoveries[key] = recovery;
    return rdma_status::success();
  endfunction

  // 功能：record_prepublish_recovery 保存 manager/CQ 屏障及 dependent
  //       runtime 的未完成恢复，必要时合并到已有候选 cleanup 记录。
  // 输入/输出及副作用：cq_h/old_runtime/dependents/restore flags/original_status
  //       为输入；成功时写入 engine-owned recovery 表，不释放或替换任何资源。
  // 失败/边界：Function identity、CQ identity 或 recovery key 不完整时返回
  //       RECOVERY_REQUIRED；已有 published 记录不会被覆盖，避免跨阶段串账。
  protected function rdma_status record_prepublish_recovery(
    rdma_handle cq_h,
    rdma_queue_runtime old_runtime,
    rdma_queue_runtime dependents[$],
    bit manager_restore_pending,
    bit cq_restore_pending,
    rdma_status original_status
  );
    rdma_cq_resize_recovery recovery;
    string key;
    bit dependent_pending;

    dependent_pending = 1'b0;
    foreach (dependents[i]) begin
      if (dependents[i] != null &&
          dependents[i].state == RDMA_QUEUE_RUNTIME_QUIESCING)
        dependent_pending = 1'b1;
    end
    if (!manager_restore_pending && !cq_restore_pending &&
        !dependent_pending)
      return rdma_status::success();
    if (cq_h == null || binding == null)
      return bad("CQ pre-publish recovery inputs are incomplete",
                 RDMA_SC_RECOVERY_REQUIRED);
    key = cq_recovery_key(cq_h);
    if (key == "")
      return bad("CQ pre-publish recovery key is invalid",
                 RDMA_SC_RECOVERY_REQUIRED);
    if (cq_resize_recoveries.exists(key)) begin
      recovery = cq_resize_recoveries[key];
      if (recovery == null || recovery.published)
        return bad("CQ pre-publish recovery stage is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
    end
    else begin
      recovery = rdma_cq_resize_recovery::type_id::create(
        "cq_prepublish_recovery");
      if (recovery == null)
        return bad("CQ pre-publish recovery allocation failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.cq_h = rdma_clone_handle_value(
        cq_h, "CQ pre-publish recovery CQ");
      if (recovery.cq_h == null)
        return bad("CQ pre-publish recovery handle snapshot failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.function_identity = binding.function_identity_snapshot();
      if (recovery.function_identity == null)
        return bad("CQ pre-publish Function identity snapshot failed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.published = 1'b0;
      recovery.pending_ref = null;
    end
    recovery.old_runtime = old_runtime;
    recovery.manager_restore_pending = manager_restore_pending;
    recovery.cq_restore_pending = cq_restore_pending;
    recovery.prepublish_restore_pending = 1'b1;
    recovery.dependents.delete();
    foreach (dependents[i])
      if (dependents[i] != null)
        recovery.dependents.push_back(dependents[i]);
    recovery.last_status = original_status;
    cq_resize_recoveries[key] = recovery;
    return rdma_status::success();
  endfunction

  // 功能：recovery_backing_matches 校验 recovery ref 的 opaque identity、
  //       Function/CQ owner、完整 route 和原始 mapping epoch。
  // 输入/输出及副作用：ref_value/recovery 为输入；只读检查，不修改 ref、
  //       manager 或 Host-memory；返回 bit 供 retry 决定是否允许释放。
  // 失败/边界：任一 authority 字段缺失、被篡改、route 不一致或 epoch 改变时返回 0，
  //       防止 identity 重用时释放错误 backing。
  protected function bit recovery_backing_matches(
    rdma_queue_backing_ref ref_value,
    rdma_cq_resize_recovery recovery
  );
    rdma_dma_mapping mapping;
    rdma_route_key_t expected_route;

    if (ref_value == null || recovery == null ||
        recovery.function_identity == null ||
        recovery.cq_h == null || ref_value.mapping == null ||
        !recovery.backing_epoch_valid || !recovery.backing_geometry_valid)
      return 1'b0;
    if (ref_value.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        ref_value.cleanup_complete ||
        ref_value.role != recovery.backing_role ||
        ref_value.mapping_offset != recovery.backing_mapping_offset ||
        ref_value.length != recovery.backing_length ||
        ref_value.logical_queue_offset !=
          recovery.backing_logical_queue_offset)
      return 1'b0;
    mapping = ref_value.mapping;
    expected_route = recovery.function_identity.route_key();
    if (!mapping.route_valid || !rdma_route_key_valid(mapping.route) ||
        !same_route(mapping.route, expected_route) ||
        !mapping.epoch_valid ||
        mapping.reset_epoch != recovery.backing_reset_epoch ||
        mapping.function_h == null ||
        mapping.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        mapping.function_h.function_uid !=
          recovery.function_identity.function_uid ||
        mapping.function_h.object_id !=
          recovery.function_identity.global_function_id ||
        mapping.owner_h == null ||
        !same_cq_recovery_identity(mapping.owner_h, recovery.cq_h))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：find_cq_recovery_attachment 在 attachment 表中按稳定 CQ identity
  // 找到当前已发布的新 attachment，避免 reset 改变 generation 后直接拼接旧 key。
  // 输入输出及副作用：recovery 为输入，attachment/attachment_key_value 为输出；
  // 函数只读 engine 索引，不改变 runtime、manager 或 Host-memory 所有权。
  // 失败边界：找不到 attachment 或发现多个同身份 attachment 时返回 RECOVERY_REQUIRED，
  // 防止 retry 在 authority 不明确时释放错误 backing。
  protected function rdma_status find_cq_recovery_attachment(
    rdma_cq_resize_recovery recovery,
    output rdma_queue_data_attachment attachment,
    output string attachment_key_value
  );
    rdma_queue_data_attachment candidate;
    string scan_key;

    attachment = null;
    attachment_key_value = "";
    if (recovery == null || recovery.cq_h == null)
      return bad("CQ resize recovery CQ identity is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    foreach (attachments[scan_key]) begin
      candidate = attachments[scan_key];
      if (candidate == null || candidate.queue_h == null ||
          !same_cq_recovery_identity(candidate.queue_h, recovery.cq_h))
        continue;
      if (attachment != null)
        return bad("CQ resize recovery attachment identity is ambiguous",
                   RDMA_SC_RECOVERY_REQUIRED);
      attachment = candidate;
      attachment_key_value = scan_key;
    end
    if (attachment == null)
      return bad("CQ resize recovery attachment is missing",
                 RDMA_SC_RECOVERY_REQUIRED);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，ensure_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：handle（输入）、expected_kind（输入）；ensure_handle 读取 handle、expected_kind 并使用字段 binding.generation、rdma_status、configured、binding、binding.function_uid；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：ensure_handle 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue data engine is not configured”“queue handle kind is invalid”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_data_engine 中，lookup_attachment 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：handle（输入）、kind（输入）、attachment（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：lookup_attachment 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：query_runtime_state 返回指定队列 attachment 的只读运行状态，供
  // 复位/resize 回归检查依赖 runtime 是否已恢复 ACTIVE。
  // 输入输出及副作用：handle、kind 为输入，state 为输出；函数只读取
  // attachment 索引，不修改 runtime、authority 或 backing 所有权。
  // 失败边界：队列未配置、句柄代际失效或 attachment 缺失时返回错误，state
  // 置为 DETACHED，调用方不得把失败结果当作活动状态。
  function rdma_status query_runtime_state(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output rdma_queue_runtime_state_e state
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;
    state = RDMA_QUEUE_RUNTIME_DETACHED;
    status = lookup_attachment(handle, kind, attachment);
    if (!status.ok()) return status;
    if (attachment.runtime == null)
      return bad("queue runtime is missing", RDMA_SC_INVALID_STATE);
    state = attachment.runtime.state;
    return rdma_status::success();
  endfunction

  // 功能：has_pending_cq_resize 查询指定 CQ 是否存在已发布但尚未完成的旧 backing 清理。
  // 输入输出及副作用：cq_h 为输入；函数只读取 engine recovery 表，不改变 runtime、manager 或 Host-memory。
  // 失败边界：空句柄、未配置或不存在记录均返回 0；调用方不得把 0 当作“CQ 一定可 resize”之外的证据。
  function bit has_pending_cq_resize(rdma_handle cq_h);
    string key;
    if (!configured || cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return 1'b0;
    key = cq_recovery_key(cq_h);
    return key != "" && cq_resize_recoveries.exists(key) &&
           cq_resize_recoveries[key] != null;
  endfunction

  // 功能：retry_cq_resize_cleanup 重试已发布 CQ resize 的依赖恢复、旧 runtime detach 和旧 backing release。
  // 输入输出及副作用：cq_h 为输入；成功时删除 engine-owned recovery record，失败时更新 last_status 并保留全部重试 authority。
  // 失败边界：当前 CQ 不存在 recovery、代际失效、依赖仍无法恢复、旧 runtime 状态异常或 Host-memory release 未完成时返回 RECOVERY_REQUIRED。
  function rdma_status retry_cq_resize_cleanup(rdma_handle cq_h);
    rdma_cq_resize_recovery recovery;
    rdma_queue_data_attachment current_attachment;
    string current_attachment_key;
    rdma_status status;
    bit cleanup_complete;
    rdma_function_identity current_identity;
    string key;
    bit attachment_is_old;

    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (cq_h == null || cq_h.kind != RDMA_RESOURCE_CQ)
      return bad("CQ resize recovery handle is invalid");
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("CQ resize recovery is busy", RDMA_SC_RESOURCE_BUSY);
    key = cq_recovery_key(cq_h);
    if (key == "" || !cq_resize_recoveries.exists(key) ||
        cq_resize_recoveries[key] == null) begin
      resize_lock.put(1);
      return bad("CQ resize has no pending recovery", RDMA_SC_INVALID_STATE);
    end
    recovery = cq_resize_recoveries[key];
    // Recovery is allowed to finish an old-generation transaction after a
    // Function reset changed binding.generation.  The caller still has to
    // present the recorded identity and either the old or current generation;
    // this cleanup exception is not permission to operate on a stale CQ normally.
    if (!same_cq_recovery_identity(recovery.cq_h, cq_h) ||
        (cq_h.generation != recovery.cq_h.generation &&
         (binding == null || cq_h.generation != binding.generation))) begin
      status = bad("CQ resize recovery handle does not match record",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    if (binding == null || recovery.function_identity == null) begin
      status = bad("CQ resize recovery Function identity is missing",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    current_identity = binding.function_identity_snapshot();
    if (current_identity == null ||
        current_identity.function_uid != recovery.function_identity.function_uid ||
        !current_identity.same_function(recovery.function_identity)) begin
      status = bad("CQ resize recovery Function route identity changed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    status = find_cq_recovery_attachment(recovery, current_attachment,
                                         current_attachment_key);
    if (status == null || !status.ok() || current_attachment == null ||
        current_attachment.runtime == null ||
        current_attachment.access == null) begin
      status = bad("CQ resize recovery attachment authority is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    attachment_is_old = current_attachment.runtime === recovery.old_runtime;
    if ((recovery.published && attachment_is_old) ||
        (!recovery.published && recovery.old_runtime != null &&
         !attachment_is_old)) begin
      status = bad("CQ resize recovery attachment stage is inconsistent",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    // Any retained backing is released only after checking its opaque
    // allocation identity and immutable Function/CQ route evidence.  The
    // check deliberately runs on retry, because recovery records are mutable
    // storage owned by the engine and may survive a reset boundary.
    if ((!recovery.published && recovery.pending_ref != null &&
         !recovery_backing_matches(recovery.pending_ref, recovery)) ||
        (recovery.published &&
         !recovery_backing_matches(recovery.old_ref, recovery))) begin
      status = bad("CQ resize recovery backing identity changed",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end
    // 发布前失败可能同时保留候选 backing 和尚未恢复的 quiesce 屏障。
    // 先恢复原 CQ/dependents/manager，再处理候选 cleanup，避免在旧
    // attachment 仍被阻塞时丢失可用的恢复入口。
    if (!recovery.published) begin
      if (recovery.prepublish_restore_pending) begin
        if (recovery.old_runtime == null) begin
          status = bad("CQ pre-publish old runtime authority is missing",
                       RDMA_SC_RECOVERY_REQUIRED);
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
        if (recovery.cq_restore_pending) begin
          if (recovery.old_runtime.state == RDMA_QUEUE_RUNTIME_QUIESCING) begin
            status = recovery.old_runtime.restore_active();
            if (status == null || !status.ok()) begin
              status = status == null ?
                bad("CQ pre-publish old runtime restore returned null",
                    RDMA_SC_RECOVERY_REQUIRED) :
                rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                  {"CQ pre-publish old runtime restore failed: ",
                   status.message});
              recovery.last_status = status;
              resize_lock.put(1);
              return status;
            end
          end
          else if (recovery.old_runtime.state !=
                   RDMA_QUEUE_RUNTIME_ACTIVE) begin
            status = bad("CQ pre-publish old runtime state is unexpected",
                         RDMA_SC_RECOVERY_REQUIRED);
            recovery.last_status = status;
            resize_lock.put(1);
            return status;
          end
          recovery.cq_restore_pending = 1'b0;
        end
        status = restore_cq_dependents(recovery.dependents);
        if (status == null || !status.ok()) begin
          status = status == null ?
            bad("CQ pre-publish dependent restore returned null",
                RDMA_SC_RECOVERY_REQUIRED) :
            rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
              {"CQ pre-publish dependent restore failed: ", status.message});
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
        if (recovery.manager_restore_pending) begin
          status = manager.restore_active(recovery.cq_h);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("CQ pre-publish manager restore returned null",
                  RDMA_SC_RECOVERY_REQUIRED) :
              rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
                {"CQ pre-publish manager restore failed: ", status.message});
            recovery.last_status = status;
            resize_lock.put(1);
            return status;
          end
          recovery.manager_restore_pending = 1'b0;
        end
        recovery.prepublish_restore_pending = 1'b0;
      end
      if (recovery.pending_ref != null) begin
        status = backing_planner.cleanup_local_role(
          recovery.pending_ref, cleanup_complete);
        if (status == null || !status.ok() || !cleanup_complete) begin
          if (status == null)
            status = bad("CQ candidate cleanup retry returned null",
                         RDMA_SC_RECOVERY_REQUIRED);
          else if (!status.ok())
            status = rdma_status::make(
              RDMA_SC_RECOVERY_REQUIRED,
              {"CQ candidate cleanup retry failed: ", status.message});
          else
            status = bad("CQ candidate cleanup remains incomplete",
                         RDMA_SC_RECOVERY_REQUIRED);
          recovery.last_status = status;
          resize_lock.put(1);
          return status;
        end
      end
      cq_resize_recoveries.delete(key);
      resize_lock.put(1);
      return rdma_status::success();
    end
    if (recovery.old_runtime == null || recovery.old_ref == null ||
        recovery.old_ref.mapping == null) begin
      status = bad("CQ resize recovery authority is incomplete",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    // 依赖恢复可能在上一轮只完成了部分 runtime；restore helper 对已经
    // ACTIVE 的 runtime 幂等跳过，保证本入口可以安全重复调用。
    status = restore_cq_dependents(recovery.dependents);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ resize dependent recovery returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      else
        status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize dependent recovery retry failed: ", status.message});
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    if (recovery.old_runtime.state == RDMA_QUEUE_RUNTIME_QUIESCING) begin
      status = recovery.old_runtime.detach_quiesced();
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("CQ resize old runtime detach returned null",
                       RDMA_SC_RECOVERY_REQUIRED);
        else
          status = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            {"CQ resize old runtime detach retry failed: ", status.message});
        recovery.last_status = status;
        resize_lock.put(1);
        return status;
      end
    end
    else if (recovery.old_runtime.state != RDMA_QUEUE_RUNTIME_DETACHED) begin
      status = bad("CQ resize old runtime has unexpected state",
                   RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    status = backing_planner.cleanup_local_role(recovery.old_ref,
                                                cleanup_complete);
    if (status == null || !status.ok() || !cleanup_complete) begin
      if (status == null)
        status = bad("CQ resize old backing cleanup returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      else if (!status.ok())
        status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ resize old backing cleanup retry failed: ", status.message});
      else
        status = bad("CQ resize old backing cleanup is incomplete",
                     RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      resize_lock.put(1);
      return status;
    end

    cq_resize_recoveries.delete(key);
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：resource_manager（输入）、function_binding（输入）、memory（输入）、scheduler（输入）、codecs（输入）、timeout（输入）；configure 先依据 resource_manager == null || function_binding == null || memory == null || scheduler == null || codecs == null || timeout == 0；status == null || !status.ok(；function_binding.state != RDMA_BIND_ACTIVE || function_binding.generation == 0 校验 resource_manager、function_binding、memory、scheduler、codecs、timeout；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；存在 pending CQ recovery 或并发 resize 时拒绝重配置并保留旧配置。
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
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("queue data engine configuration is busy",
                 RDMA_SC_RESOURCE_BUSY);
    if (cq_resize_recoveries.num() != 0) begin
      resize_lock.put(1);
      return bad("queue data engine has pending CQ cleanup recovery",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
    // attachment/qp_links 是当前队列 backing 和依赖拓扑的唯一索引。
    // 重配置前若直接清空它们会丢失 release authority，留下 manager-active
    // resource；调用方必须先显式 detach 完整拓扑。
    if (attachments.num() != 0 || qp_links.num() != 0) begin
      resize_lock.put(1);
      return bad("active queue attachments prevent reconfigure",
                 RDMA_SC_RESOURCE_BUSY);
    end
    status = function_binding.validate();
    if (status == null || !status.ok()) begin
      resize_lock.put(1);
      return status == null ? bad("Function binding validation returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    end
    if (function_binding.state != RDMA_BIND_ACTIVE ||
        function_binding.generation == 0) begin
      resize_lock.put(1);
      return bad("Function binding is not active", RDMA_SC_INVALID_STATE);
    end
    if (backing_planner == null)
      backing_planner = rdma_queue_backing_planner::type_id::create(
        "queue_data_backing_planner");
    status = backing_planner.configure(memory);
    if (status == null || !status.ok()) begin
      resize_lock.put(1);
      return status == null ? bad("queue backing planner configuration returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    end
    manager = resource_manager; binding = function_binding; host_mem = memory;
    doorbells = scheduler; registry = codecs; operation_timeout = timeout;
    attachments.delete(); qp_links.delete(); configured = 1'b1;
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，find_queue_ref 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：plan（输入）、role（输入）、result（输出）；find_queue_ref 读取 plan、role、result 并使用字段 result，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_queue_ref 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：create_attachment 创建独立的 rdma_status；根据 queue_h、kind、role、queue_ref、qp_ref、depth、producer_index、producer_wrap、consumer_index、consumer_wrap、host_produced、local_id、transport、entry_size、initial_polarity 设置字段 key、access、status、runtime、attachment、attachment.queue_h、attachment.kind、attachment.runtime、attachment.access、attachment.role，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：queue_h（输入）、kind（输入）、role（输入）、queue_ref（输入）、qp_ref（输入）、depth（输入）、producer_index（输入）、producer_wrap（输入）、consumer_index（输入）、consumer_wrap（输入）、host_produced（输入）、local_id（输入）、transport（输入）、entry_size（输入）、initial_polarity（输入）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：create_attachment 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_queue_data_engine 中，delete_attachment delete_attachment 解除指定资源绑定并隔离 runtime/映射，避免旧句柄在删除后访问后端。
  // 输入/输出及副作用：queue_h（输入）、kind（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：delete_attachment 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：在 rdma_queue_data_engine 中，attach_srq_for_qp 把 attach_srq_for_qp 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：srq_h（输入）；attach_srq_for_qp 先依据 !status.ok(；attachments.exists(attachment_key(srq_h, RDMA_QUEUE_RUNTIME_SRQ；!$cast(srq, resource 校验 srq_h；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
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

  // 功能：在 rdma_queue_data_engine 中，attach_qp 把 attach_qp 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：qp_h（输入）；attach_qp 先依据 !status.ok(；!$cast(qp, resource；attachments.exists(attachment_key(qp_h, RDMA_QUEUE_RUNTIME_SQ 校验 qp_h；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
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

  // 功能：在 rdma_queue_data_engine 中，attach_cq 把 attach_cq 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：cq_h（输入）、transport_variant（输入）；attach_cq 先依据 !status.ok(；!(transport_variant inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD, RDMA_TRANSPORT_URC}；!$cast(cq, resource 校验 cq_h、transport_variant；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
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
    if (!(cq.cqe_size_bytes inside {32, 64, 128}))
      return bad("CQE size profile is unsupported", RDMA_SC_UNSUPPORTED_OPCODE);
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

  // 功能：在 rdma_queue_data_engine 中，attach_event_queue 把 attach_event_queue 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：queue_h（输入）、expected（输入）、kind（输入）、role（输入）；attach_event_queue 先依据 !status.ok(；!$cast(queue, resource；queue.queue_plan.rings[i] != null && queue.queue_plan.rings[i].role == role 校验 queue_h、expected、kind、role；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
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

  // 功能：在 rdma_queue_data_engine 中，attach_ceq 把 attach_ceq 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：ceq_h（输入）；attach_ceq 先依据 依赖存在性、authority 和 generation 条件 校验 ceq_h；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status attach_ceq(rdma_handle ceq_h);
    return attach_event_queue(ceq_h, RDMA_RESOURCE_CEQ,
                              RDMA_QUEUE_RUNTIME_CEQ,
                              RDMA_QUEUE_ROLE_CEQ_RING);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，attach_aeq 把 attach_aeq 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：aeq_h（输入）；attach_aeq 先依据 依赖存在性、authority 和 generation 条件 校验 aeq_h；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status attach_aeq(rdma_handle aeq_h);
    return attach_event_queue(aeq_h, RDMA_RESOURCE_AEQ,
                              RDMA_QUEUE_RUNTIME_AEQ,
                              RDMA_QUEUE_ROLE_AEQ_RING);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，detach detach 解除指定资源绑定并隔离 runtime/映射，避免旧句柄在删除后访问后端。
  // 输入/输出及副作用：queue_h（输入）；detach 读取 queue_h 并使用字段 found、status、runtime.state；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：detach 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function rdma_status detach(rdma_handle queue_h);
    rdma_status status;
    string key;
    bit found;
    found = 1'b0;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (!status.ok()) return status;
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("queue detach is busy", RDMA_SC_RESOURCE_BUSY);
    if (queue_h.kind == RDMA_RESOURCE_CQ &&
        cq_resize_recoveries.exists(cq_recovery_key(queue_h))) begin
      resize_lock.put(1);
      return bad("queue detach requires CQ cleanup recovery",
                 RDMA_SC_RECOVERY_REQUIRED);
    end
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
      begin
        resize_lock.put(1);
        return bad("queue is not attached", RDMA_SC_INVALID_STATE);
      end
    resize_lock.put(1);
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，make_sqe 完成发送队列预检、槽位预留、WQE 写入和 producer doorbell 提交，并返回提交结果与失败证据。
  // 输入/输出及副作用：request（输入）、link（输入）、cursor（输入）、model（输出）；make_sqe 读取 request、link、cursor、model 并使用字段 model、model.transport、model.qp_h、model.wr_id、model.opcode、model.signaled、model.solicited、model.fence，并写入 model；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：未配置、空队列、stale generation/reset epoch 和 ambiguous MMIO 均禁止发布成功结果或自动重试。
  protected function rdma_status make_sqe(
    rdma_post_send_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_hw_sqe_model model
  );
    rdma_sqe_rc_ext rc;
    rdma_sqe_ud_ext ud;
    rdma_sqe_urc_ext urc;
    rdma_sge cloned_sge;
    rdma_status status;
    model = null;
    if (request == null || link == null || cursor == null)
      return bad("SQE request, QP link, or reservation is null");
    model = rdma_hw_sqe_model::type_id::create("queue_sqe");
    model.transport = request.transport; model.qp_h = request.qp_h;
    model.wr_id = request.wr_id; model.opcode = request.opcode;
    model.inline_data = request.inline_data;
    model.payload = request.payload;
    model.immediate_data = request.immediate_data;
    model.remote_va = request.remote_addr;
    model.rkey = request.rkey;
    model.signaled = request.signaled; model.solicited = request.solicited;
    model.fence = '0; model.qpn = link.local_qp_id;
    model.qp_sn = 0; model.icos = 0; model.dst_port = 0;
    model.index = cursor.index; model.wrap = cursor.wrap;
    model.sign_en = request.signaled; model.se = request.solicited;
    model.ce = request.signaled ? 2'b01 : 2'b00; model.valid = 1'b1;
    model.hw_opcode = request.opcode;
    model.invalidate_key = request.invalidate_rkey;
    model.destination_qpn = request.destination_qpn;
    model.qkey = request.qkey;
    model.sgb_iova = request.sgb_iova;
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
        if (request.completion_qp_h == null || request.completion_qp_h.kind != RDMA_RESOURCE_QP)
          return bad("URC completion QP authority is missing");
        urc.completion_qp_h = request.completion_qp_h;
      end
      default: return bad("SQE transport is unsupported",
                          RDMA_SC_UNSUPPORTED_OPCODE);
    endcase
    status = model.validate();
    return status;
  endfunction

  // 功能：在 rdma_queue_data_engine 中，make_rqe 完成接收队列预检、槽位预留、RQE 写入和 producer doorbell 提交，并返回提交结果与失败证据。
  // 输入/输出及副作用：request（输入）、link（输入）、cursor（输入）、model（输出）；make_rqe 读取 request、link、cursor、model 并使用字段 model、model.target_h、model.wr_id、model.qpn、model.qp_sn、model.hw_opcode、model.index、model.wrap，并写入 model；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：未配置、空队列、stale generation/reset epoch 和 ambiguous MMIO 均禁止发布成功结果或自动重试。
  protected function rdma_status make_rqe(
    rdma_post_recv_req request,
    rdma_queue_data_qp_link link,
    rdma_queue_cursor_snapshot cursor,
    output rdma_hw_rqe_model model
  );
    rdma_sge cloned_sge;
    longint unsigned payload_len;
    model = null;
    if (request == null || link == null || cursor == null)
      return bad("RQE request, QP link, or reservation is null");
    model = rdma_hw_rqe_model::type_id::create("queue_rqe");
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

  // 功能：在 rdma_queue_data_engine 中，encode_queue_model 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：model（输入）、image_kind（输入）、object_type（输入）、variant（输入）、image（输出）；输入模型只读；成功时通过返回值或 output 发布完整
  //   image/bytes，不修改源模型。
  // 失败/边界：encode_queue_model 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  protected function rdma_status encode_queue_model(
    rdma_hw_model model, rdma_image_kind_e image_kind, string object_type,
    string variant, output rdma_hw_image image
  );
    rdma_codec_key codec_key;
    rdma_codec_base codec;
    rdma_status status;
    image = null;
    codec_key = '{hw_version:"rdma", image_kind:image_kind,
      object_type:object_type, variant:variant, opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return status;
    return codec.encode(model, image);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，write_and_verify 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：attachment（输入）、offset（输入）、image（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write_and_verify 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
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

  // 功能：make_pending 创建独立的 rdma_queue_pending_operation；根据 cursor、queue_h、kind、producer、entry_offset、image、request_snapshot、signaled、completion_index、completion_wrap、completion_target_valid、completion_released、routed_qp_h 设置字段 pending、pending.queue_h、pending.kind、pending.producer、pending.entry_offset、pending.wr_id、pending.cursor、cursor.index、cursor.wrap、pending.signaled，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：cursor（输入）、queue_h（输入）、kind（输入）、producer（输入）、entry_offset（输入）、image（输入）、request_snapshot（输入）、signaled（输入）、completion_index（输入）、completion_wrap（输入）、completion_target_valid（输入）、completion_released（输入）、routed_qp_h（输入）；输入字段被复制到返回值或
  //   output；生成结果与输入隔离，不隐式修改调用方对象。
  // 失败/边界：make_pending 先检查 queue_h != null；request_snapshot != null；$cast(pending_send, request_snapshot，再返回 pending；拒绝分支不提交部分状态，也不隐式重试。
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

  // 功能：在 rdma_queue_data_engine 中，projected_id_handle 构造或投影带完整 kind、Function UID、object ID 和 generation 的资源句柄。
  // 输入/输出及副作用：source（输入）、local_id（输入）；projected_id_handle 读取 source、local_id 并使用字段 result、result.kind、result.function_uid、result.generation、result.object_id；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：projected_id_handle 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_queue_data_engine 中，submit_producer_doorbell 完成发送队列预检、槽位预留、WQE 写入和 producer doorbell 提交，并返回提交结果与失败证据。
  // 输入/输出及副作用：target_h（输入）、kind（输入）、reservation（输入）、next（输入）、sqe_image（输入）、local_id（输入）、result（输出）、status（输出）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：未配置、空队列、stale generation/reset epoch 和 ambiguous MMIO 均禁止发布成功结果或自动重试。
  protected task submit_producer_doorbell(
    rdma_handle target_h, rdma_queue_runtime_kind_e kind,
    rdma_queue_cursor_snapshot reservation, rdma_queue_cursor_snapshot next,
    rdma_hw_image sqe_image, int unsigned local_id,
    output rdma_doorbell_result result,
    output rdma_status status
  );
    rdma_hw_sq_doorbell_model sq;
    rdma_hw_rq_doorbell_model rq;
    rdma_hw_srq_doorbell_model srq;
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
        variant = "sq"; relative_offset = RDMA_DB_SQ_OFFSET;
        sq = rdma_hw_sq_doorbell_model::type_id::create("sq_db_model");
        sq.target_h = rdma_clone_handle_value(target_h, "SQ DB target");
        if (sqe_image == null || sqe_image.bytes.size() < RDMA_DB_BYTES) begin
          status = bad("SQ doorbell lacks the encoded SQE header");
          return;
        end
        foreach (sqe_image.bytes[i]) begin
          if (i >= RDMA_DB_BYTES) break;
          sq.sqe_header.push_back(sqe_image.bytes[i]);
        end
        model = sq;
      end
      RDMA_QUEUE_RUNTIME_RQ: begin
        variant = "rq"; relative_offset = RDMA_DB_RQ_OFFSET;
        rq = rdma_hw_rq_doorbell_model::type_id::create("rq_db_model");
        rq.target_h = projected_id_handle(target_h, local_id);
        rq.qpn = local_id; rq.icos = 0; rq.pi = next.index; rq.wrap = next.wrap;
        model = rq;
      end
      RDMA_QUEUE_RUNTIME_SRQ: begin
        variant = "srq_pi"; relative_offset = RDMA_DB_SRFQ_OFFSET;
        srq = rdma_hw_srq_doorbell_model::type_id::create("srq_db_model");
        srq.target_h = projected_id_handle(target_h, local_id);
        srq.variant = RDMA_SRQ_DB_PI; srq.srqn = local_id;
        srq.pi = next.index; srq.wrap = next.wrap; model = srq;
      end
      default: begin
        status = bad("producer runtime kind is not a posting ring");
        return;
      end
    endcase
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
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
    desc.width = RDMA_DB_BYTES; desc.endian = RDMA_ENDIAN_BIG;
    desc.payload_image = image; desc.barrier_policy = RDMA_DB_BARRIER_DMA_MMIO;
    desc.write_combining_policy = RDMA_DB_WRITE_NON_COMBINING;
    desc.allow_merge = 1'b0; desc.merge_requested = 1'b0;
    desc.timeout = operation_timeout; desc.readback_policy = RDMA_DB_READBACK_NONE;
    doorbells.submit(binding, desc, result, status);
  endtask

  // 功能：make_entry_image 根据 data、kind、entry_size、image 生成或检查硬件镜像字段，保持布局、端序和保留位约束一致。
  // 输入/输出及副作用：data（输入）、kind（输入）、entry_size（输入）、image（输出）；make_entry_image 读取 data、kind、entry_size、image 并使用字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind，并写入 image；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：make_entry_image 返回 RDMA_SC_DMA_TRANSLATION；具体拒绝条件包括 “queue entry byte count does not match attachment geometry”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = binding.generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，find_qp_link_for_cq 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：cq_h（输入）、qpn（输入）、rq_cqe（输入）、link（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：find_qp_link_for_cq 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_queue_data_engine 中，find_qp_link_for_local_id 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：qpn（输入）、link（输出）；find_qp_link_for_local_id 读取 qpn、link 并使用字段 link、candidate，并写入 link；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_qp_link_for_local_id 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_queue_data_engine 中，find_cq_handle_for_local_id 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：cqn（输入）、cq_h（输出）；find_cq_handle_for_local_id 读取 cqn、cq_h 并使用字段 cq_h、candidate，并写入 cq_h；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：find_cq_handle_for_local_id 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：将 rhs 中 rdma_queue_data_engine 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、result（输出）；clone_slot_result 读取 source、result 并使用字段 result、result.posted、result.consumed、result.signaled、result.wr_id、result.index、result.wrap、cloned，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_slot_result 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“released slot ledger entry is null”“released request snapshot clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：completion_status_from_ecode 校验 ecode、observed_engine、completion_status 与当前对象状态的一致性，并显式处理“queue_error_codec”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：ecode（输入）、observed_engine（输入）、completion_status（输出）；completion_status_from_ecode 读取 ecode、observed_engine、completion_status 并使用字段 completion_status、error_codec，并写入 completion_status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：completion_status_from_ecode 无返回值，仅执行 completion_status=null、error_codec=rdma_hw_error_codec::type_id::create("queue_error_codec")；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function rdma_status completion_status_from_ecode(
      bit [7:0] ecode, rdma_engine_kind_e observed_engine,
      output rdma_status completion_status
  );
    rdma_hw_error_codec error_codec;
    completion_status = null;
    error_codec = rdma_hw_error_codec::type_id::create("queue_error_codec");
    return error_codec.decode_status(ecode, observed_engine,
                                     completion_status);
  endfunction

  // 功能：在 rdma_queue_data_engine 中，submit_consumer_doorbell 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：attachment（输入）、next（输入）、result（输出）、status（输出）、mmio_maybe_submitted（输出）、routed_link（输入）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：submit_consumer_doorbell 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected task submit_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_result result,
    output rdma_status status,
    output bit mmio_maybe_submitted,
    rdma_queue_data_qp_link routed_link
  );
    rdma_hw_cq_doorbell_model cq;
    rdma_hw_ceq_doorbell_model ceq;
    rdma_hw_aeq_doorbell_model aeq;
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
        relative_offset = RDMA_DB_CQ_OFFSET;
        cq = rdma_hw_cq_doorbell_model::type_id::create("cq_ci_db_model");
        cq.target_h = projected_id_handle(attachment.queue_h,
                                          attachment.local_id);
        cq.variant = (variant == "cq_urc") ? RDMA_CQ_DB_URC :
                                               RDMA_CQ_DB_RC_UD;
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
        relative_offset = RDMA_DB_CEQ_OFFSET;
        ceq = rdma_hw_ceq_doorbell_model::type_id::create("ceq_ci_db_model");
        ceq.target_h = projected_id_handle(attachment.queue_h,
                                           attachment.local_id);
        ceq.ceqn = attachment.local_id;
        ceq.ci = next.index;
        ceq.wrap = next.wrap;
        model = ceq;
      end
      RDMA_QUEUE_RUNTIME_AEQ: begin
        variant = "aeq";
        relative_offset = RDMA_DB_AEQ_OFFSET;
        aeq = rdma_hw_aeq_doorbell_model::type_id::create("aeq_ci_db_model");
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
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
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
    desc.width = RDMA_DB_BYTES;
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

  // 功能：在 rdma_queue_data_engine 中，poll_cqe_once 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：cq_h（输入）、result（输出）、status（输出）；poll_cqe_once 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：poll_cqe_once 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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
    rdma_hw_cqe_model cqe;
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
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    status = registry.lookup(codec_key, codec);
    if (!status.ok()) return;
    begin
      rdma_hw_cqe_codec variable_cqe_codec;
      if (!$cast(variable_cqe_codec, codec)) begin
        status = bad("CQ registry codec cannot select a variable profile",
                     RDMA_SC_CODEC_ERROR);
        return;
      end
      // The entry size belongs to this attachment/read, so pass it directly
      // instead of mutating the shared registry codec's active profile.
      status = variable_cqe_codec.decode_with_entry_bytes(
        entry_image, cq_attachment.entry_size, decoded_model);
    end
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

  // 功能：在 rdma_queue_data_engine 中，poll_cqe 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：cq_h（输入）、timeout（输入）、result（输出）、status（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：poll_cqe 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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

  // 功能：finish_resize 统一释放 engine 级 resize semaphore 并返回事务结果，确保所有退出分支都不会遗留锁。
  // 输入输出及副作用：status 为输入；finish_resize 释放本对象持有的 resize_lock token，不修改 CQ authority。
  // 失败边界：status 为空时仍返回 INVALID_STATE；未持有 lock 的调用方不得调用本函数，否则会破坏并发屏障。
  protected function rdma_status finish_resize(rdma_status status);
    if (status == null)
      status = bad("CQ resize returned null status", RDMA_SC_INVALID_STATE);
    if (resize_lock != null)
      resize_lock.put(1);
    return status;
  endfunction

  // 功能：quiesce_cq_dependents 找出引用 CQ 的 QP/SRQ runtime，并在 resize 前逐一切到 QUIESCING，阻止依赖队列产生新事务。
  // 输入输出及副作用：cq_h 为输入；runtimes 为输出；成功时更新相关 runtime 状态并返回其快照列表。
  // 失败边界：关联 runtime 非 ACTIVE、存在 pending/used、句柄拓扑不完整或任一 begin_quiesce 失败时回滚已切换 runtime 并返回错误。
  protected function rdma_status quiesce_cq_dependents(
    rdma_handle cq_h,
    output rdma_queue_runtime runtimes[$]
  );
    rdma_queue_data_qp_link link;
    rdma_queue_data_attachment attachment;
    rdma_status status;
    string link_key;
    string attachment_key_value;
    rdma_queue_runtime candidate_runtime;
    rdma_queue_runtime_kind_e kinds[$];
    bit already_seen;

    runtimes.delete();
    if (cq_h == null)
      return bad("CQ dependent quiesce handle is null");
    kinds.push_back(RDMA_QUEUE_RUNTIME_SQ);
    kinds.push_back(RDMA_QUEUE_RUNTIME_RQ);
    kinds.push_back(RDMA_QUEUE_RUNTIME_SRQ);
    foreach (qp_links[link_key]) begin
      link = qp_links[link_key];
      if (link == null)
        continue;
      if ((link.send_cq_h == null || !link.send_cq_h.same_instance(cq_h)) &&
          (link.recv_cq_h == null || !link.recv_cq_h.same_instance(cq_h)))
        continue;
      foreach (kinds[i]) begin
        attachment_key_value = attachment_key(
          kinds[i] == RDMA_QUEUE_RUNTIME_SRQ ? link.srq_h : link.qp_h,
          kinds[i]);
        if (attachment_key_value == "" ||
            !attachments.exists(attachment_key_value))
          continue;
        attachment = attachments[attachment_key_value];
        if (attachment == null || attachment.runtime == null)
          return bad("CQ dependent attachment is incomplete",
                     RDMA_SC_INVALID_STATE);
        candidate_runtime = attachment.runtime;
        // A shared SRQ can be reached through more than one QP link; only
        // transition a runtime once per resize transaction.
        already_seen = 1'b0;
        foreach (runtimes[j])
          if (runtimes[j] === candidate_runtime) already_seen = 1'b1;
        if (already_seen)
          continue;
        status = candidate_runtime.begin_quiesce();
        if (status == null || !status.ok()) begin
          // Keep the successfully quiesced runtime list intact.  abort_cq_resize
          // needs the exact list to retry restore_active when a transient
          // backend/lock failure prevents immediate rollback.
          if (status == null)
            status = bad("CQ dependent begin quiesce returned null",
                         RDMA_SC_RECOVERY_REQUIRED);
          foreach (runtimes[j]) begin
            rdma_status restore_status;
            restore_status = runtimes[j].restore_active();
            if (restore_status == null || !restore_status.ok())
              status = rdma_status::make(
                RDMA_SC_RECOVERY_REQUIRED,
                {"CQ dependent begin failed: ", status.message,
                 "; rollback restore failed: ",
                 restore_status == null ? "null status" :
                 restore_status.message});
          end
          return status;
        end
        runtimes.push_back(candidate_runtime);
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：restore_cq_dependents 把 resize 事务中暂时 QUIESCING 的依赖 runtime 恢复为 ACTIVE。
  // 输入输出及副作用：runtimes 为输入；成功时更新每个 runtime.state，不触碰 manager registry。
  // 失败边界：任一 runtime 恢复失败时返回该错误；调用方必须保留诊断并进入恢复路径。
  protected function rdma_status restore_cq_dependents(
    rdma_queue_runtime runtimes[$]
  );
    rdma_status status;
    foreach (runtimes[i]) begin
      if (runtimes[i] == null)
        continue;
      // 依赖恢复可能已经在上一轮完成一部分；ACTIVE runtime 直接跳过，
      // 让失败路径可以重复调用而不会把幂等恢复误报成错误。
      if (runtimes[i].state == RDMA_QUEUE_RUNTIME_ACTIVE)
        continue;
      if (runtimes[i].state != RDMA_QUEUE_RUNTIME_QUIESCING)
        return bad("CQ dependent runtime has unexpected state",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = runtimes[i].restore_active();
      if (status == null)
        return bad("CQ dependent runtime restore returned null",
                   RDMA_SC_RECOVERY_REQUIRED);
      if (!status.ok()) return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：abort_cq_resize 撤销尚未发布的 CQ resize 阶段，按“新 backing cleanup、runtime restore、manager restore”顺序恢复旧 authority。
  // 输入输出及副作用：cq_h/old_runtime/dependents/new_ref/manager_quiesced/cq_quiesced/original_status 为输入；函数可能释放候选 mapping、恢复 runtime 和 manager 状态。
  // 失败边界：任一回滚动作失败时返回 RECOVERY_REQUIRED 或底层错误，并把原始失败消息附加到结果；已提交的新 authority 不应调用本函数。
  protected function rdma_status abort_cq_resize(
    rdma_handle cq_h,
    rdma_queue_runtime old_runtime,
    rdma_queue_runtime dependents[$],
    rdma_queue_backing_ref new_ref,
    bit manager_quiesced,
    bit cq_quiesced,
    rdma_status original_status
  );
    rdma_status rollback_status;
    rdma_status first_failure;
    rdma_status recovery_status;
    bit complete;
    bit manager_restore_pending;
    bit cq_restore_pending;

    first_failure = null;
    manager_restore_pending = manager_quiesced;
    cq_restore_pending = cq_quiesced;
    if (new_ref != null) begin
      rollback_status = backing_planner.cleanup_local_role(new_ref,
                                                            complete);
      if (rollback_status == null || !rollback_status.ok() || !complete) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize candidate cleanup returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        first_failure = rollback_status;
        // 候选 authority 尚未发布，不能复用 published recovery 记录；仍要
        // 把它登记为 pending_ref，保证本次回滚失败后有唯一重试入口。
        recovery_status = record_candidate_cleanup_recovery(
          cq_h, new_ref, rollback_status);
        if (recovery_status == null || !recovery_status.ok()) begin
          if (recovery_status == null)
            recovery_status = bad(
              "CQ candidate cleanup recovery registration returned null",
              RDMA_SC_RECOVERY_REQUIRED);
          first_failure = rdma_status::make(
            RDMA_SC_RECOVERY_REQUIRED,
            {"CQ candidate cleanup recovery registration failed: ",
             recovery_status.message, "; cleanup failure: ",
             rollback_status.message});
        end
      end
    end
    if (cq_quiesced && old_runtime != null) begin
      rollback_status = old_runtime.restore_active();
      if (rollback_status == null || !rollback_status.ok()) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize runtime restore returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        if (first_failure == null) first_failure = rollback_status;
      end
      else
        cq_restore_pending = 1'b0;
    end
    rollback_status = restore_cq_dependents(dependents);
    if (rollback_status == null || !rollback_status.ok()) begin
      if (rollback_status == null)
        rollback_status = bad("CQ resize dependent restore returned null",
                              RDMA_SC_RECOVERY_REQUIRED);
      if (first_failure == null) first_failure = rollback_status;
    end
    if (manager_quiesced) begin
      rollback_status = manager.restore_active(cq_h);
      if (rollback_status == null || !rollback_status.ok()) begin
        if (rollback_status == null)
          rollback_status = bad("CQ resize manager restore returned null",
                                RDMA_SC_RECOVERY_REQUIRED);
        if (first_failure == null) first_failure = rollback_status;
      end
      else
        manager_restore_pending = 1'b0;
    end
    if (first_failure != null) begin
      // A failed rollback must retain every runtime that is still QUIESCING;
      // otherwise a later retry can only see the old CQ handle and would have
      // no safe way to restore a dependent that was removed from the list.
      recovery_status = record_prepublish_recovery(
        cq_h, old_runtime, dependents, manager_restore_pending,
        cq_restore_pending, first_failure);
      if (recovery_status == null || !recovery_status.ok()) begin
        if (recovery_status == null)
          recovery_status = bad(
            "CQ pre-publish recovery registration returned null",
            RDMA_SC_RECOVERY_REQUIRED);
        first_failure = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          {"CQ pre-publish recovery registration failed: ",
           recovery_status.message, "; rollback failure: ",
           first_failure.message});
      end
      return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize rollback failed: ", first_failure.message,
         "; original failure: ", original_status == null ? "" :
         original_status.message});
    end
    return original_status == null ?
      bad("CQ resize rollback has no original status",
          RDMA_SC_RECOVERY_REQUIRED) : original_status;
  endfunction

  // 功能：调整已附着 CQ 的 runtime ring，先确认 quiesce 条件，再分配新
  //       backing/runtime、复制 owner/CI 游标并原子替换 attachment；发布后
  //       若旧 runtime 或 backing 清理失败，登记可重试的 recovery record。
  // 输入输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；成功时更新 CQ attachment 的 runtime 与 entry geometry。
  // 失败边界：未配置、CQ 不存在、存在 pending 操作、深度/size 非法或候选
  //       runtime 激活失败时保留旧 ring；发布后的清理故障返回
  //       RDMA_SC_RECOVERY_REQUIRED 并保留新 attachment 与旧 authority。
  function rdma_status resize_cq(rdma_handle cq_h, int unsigned new_depth,
                                 int unsigned new_cqe_bytes);
    rdma_queue_data_attachment old_attachment;
    rdma_queue_data_attachment replacement;
    rdma_queue_runtime candidate_runtime;
    rdma_queue_backing_access candidate_access;
    rdma_queue_ring_layout candidate_ring;
    rdma_queue_backing_ref candidate_ref;
    rdma_queue_backing_ref old_ref;
    rdma_cq authoritative_cq;
    rdma_cq candidate_cq;
    rdma_resource authoritative_resource;
    rdma_queue_backing_plan candidate_plan;
    rdma_status status;
    rdma_queue_runtime dependents[$];
    rdma_cq_resize_recovery recovery;
    string key;
    string recovery_key;
    bit manager_quiesced;
    bit cq_quiesced;
    bit cleanup_complete;

    // 设计：geometry 校验不产生副作用，因此先于信号量获取执行；其余
    // 所有会改变状态的步骤均由 resize_lock 串行化，避免并发调用观察到半事务。
    if (!(new_cqe_bytes inside {32,64,128}) || new_depth == 0 ||
        (new_depth & (new_depth-1)) != 0)
      return bad("CQ resize geometry is invalid");
    if (!configured)
      return bad("queue data engine is not configured", RDMA_SC_INVALID_STATE);
    if (resize_lock == null || !resize_lock.try_get(1))
      return bad("CQ resize is busy", RDMA_SC_RESOURCE_BUSY);

    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, old_attachment);
    if (!status.ok()) return finish_resize(status);
    key = attachment_key(cq_h, RDMA_QUEUE_RUNTIME_CQ);
    recovery_key = cq_recovery_key(cq_h);
    if (key == "" || recovery_key == "" ||
        cq_resize_recoveries.exists(recovery_key))
      return finish_resize(bad("CQ resize has pending cleanup recovery",
                               RDMA_SC_RECOVERY_REQUIRED));
    if (old_attachment.runtime == null || old_attachment.access == null)
      return finish_resize(bad("CQ attachment runtime/access is missing",
                               RDMA_SC_INVALID_STATE));
    status = manager.begin_cq_resize(cq_h);
    if (!status.ok()) return finish_resize(status);
    manager_quiesced = 1'b1;
    status = old_attachment.runtime.begin_quiesce();
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    cq_quiesced = 1'b1;
    status = quiesce_cq_dependents(cq_h, dependents);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    // 设计：manager 屏障建立后再读取 QUIESCING authority；该 detached CQ
    // 快照提供 ring 替换必须保留的 PD/CEQ/context 不可变依赖拓扑。
    status = manager.lookup(cq_h, authoritative_resource);
    if (!status.ok() || !$cast(authoritative_cq, authoritative_resource) ||
        authoritative_cq == null || authoritative_cq.queue_plan == null) begin
      if (status.ok()) status = bad("CQ resize authority lookup failed",
                                   RDMA_SC_INVALID_STATE);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    if (old_attachment.runtime.consumer_index >= new_depth ||
        old_attachment.runtime.producer_index >= new_depth) begin
      status = bad("CQ resize cannot preserve cursor state");
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    status = backing_planner.allocate_owned_cq_resize_ring(
      binding, cq_h, new_depth, new_cqe_bytes, candidate_ring, candidate_ref,
      old_attachment.runtime.initial_polarity);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    candidate_runtime = rdma_queue_runtime::type_id::create("cq_resize_runtime");
    if (candidate_runtime == null) begin
      status = bad("CQ resize runtime allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    status = candidate_runtime.configure(old_attachment.queue_h,
      RDMA_QUEUE_RUNTIME_CQ, new_depth,
      old_attachment.runtime.producer_index, old_attachment.runtime.producer_wrap,
      old_attachment.runtime.consumer_index, old_attachment.runtime.consumer_wrap,
      1'b0, old_attachment.runtime.initial_polarity);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    status = candidate_runtime.copy_ring_state(old_attachment.runtime);
    if (status.ok()) status = candidate_runtime.activate();
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    candidate_access = rdma_queue_backing_access::type_id::create(
      "cq_resize_backing_access");
    if (candidate_access == null) begin
      status = bad("CQ resize backing access allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    status = candidate_access.configure(binding.make_handle(), host_mem);
    if (status.ok()) status = candidate_access.attach_queue(candidate_ref);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    candidate_plan = rdma_queue_backing_plan::type_id::create(
      "cq_resize_plan");
    if (candidate_plan == null) begin
      status = bad("CQ resize queue plan allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    candidate_plan.copy(authoritative_cq.queue_plan);
    foreach (candidate_plan.rings[i]) begin
      if (candidate_plan.rings[i] != null &&
          candidate_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        candidate_plan.rings[i] = candidate_ring;
    end
    foreach (candidate_plan.refs[i]) begin
      if (candidate_plan.refs[i] != null &&
          candidate_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        candidate_plan.refs[i] = candidate_ref;
    end

    candidate_cq = rdma_cq::type_id::create("cq_resize_candidate");
    if (candidate_cq == null) begin
      status = bad("CQ resize candidate allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    candidate_cq.copy(authoritative_cq);
    candidate_cq.state = RDMA_RESOURCE_ACTIVE;
    candidate_cq.depth = new_depth;
    candidate_cq.cqe_size_bytes = new_cqe_bytes;
    candidate_cq.producer_index = candidate_runtime.producer_index;
    candidate_cq.consumer_index = candidate_runtime.consumer_index;
    candidate_cq.producer_wrap = candidate_runtime.producer_wrap;
    candidate_cq.consumer_wrap = candidate_runtime.consumer_wrap;
    candidate_cq.queue_iova = candidate_ref.mapping.iova;
    candidate_cq.queue_plan = candidate_plan;

    // 设计：旧 authority 仍可读时预先解析发布后所需字段，并完成
    // replacement attachment 构造，使原子 manager swap 之后不再发生分配/类型失败。
    status = find_queue_ref(authoritative_cq.queue_plan,
                            RDMA_QUEUE_ROLE_CQ_RING, old_ref);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    // 在 manager/attachment 原子发布前准备 engine-owned recovery record，
    // 确保发布后任一 detach/release 故障都有持久重试入口。
    recovery = rdma_cq_resize_recovery::type_id::create(
      "cq_resize_recovery");
    if (recovery == null) begin
      status = bad("CQ resize recovery record allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    recovery.cq_h = rdma_clone_handle_value(cq_h, "CQ resize recovery CQ");
    if (recovery.cq_h == null)
      recovery.cq_h = cq_h;
    recovery.function_identity = binding.function_identity_snapshot();
    if (recovery.function_identity == null) begin
      status = bad("CQ resize recovery Function identity snapshot failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    recovery.old_runtime = old_attachment.runtime;
    recovery.old_ref = old_ref;
    if (old_ref == null || old_ref.mapping == null ||
        !old_ref.mapping.epoch_valid) begin
      status = bad("CQ resize recovery old backing epoch is missing",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    if (old_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        old_ref.cleanup_complete) begin
      status = bad("CQ resize recovery old backing ownership/state is invalid",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    recovery.backing_role = old_ref.role;
    recovery.backing_mapping_offset = old_ref.mapping_offset;
    recovery.backing_length = old_ref.length;
    recovery.backing_logical_queue_offset = old_ref.logical_queue_offset;
    recovery.backing_geometry_valid = 1'b1;
    // Published recovery must bind its immutable epoch to the old backing;
    // candidate mapping epoch belongs to the new attachment and is not a
    // proof that the retained old mapping is still safe to release.
    recovery.backing_reset_epoch = old_ref.mapping.reset_epoch;
    recovery.backing_epoch_valid = 1'b1;
    foreach (dependents[i])
      recovery.dependents.push_back(dependents[i]);
    replacement = rdma_queue_data_attachment::type_id::create(
      "cq_resize_attachment");
    if (replacement == null) begin
      status = bad("CQ resize attachment allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end
    replacement.queue_h = old_attachment.queue_h;
    replacement.kind = old_attachment.kind;
    replacement.runtime = candidate_runtime;
    replacement.access = candidate_access;
    replacement.role = old_attachment.role;
    replacement.entry_size = new_cqe_bytes;
    replacement.local_id = old_attachment.local_id;
    replacement.transport = old_attachment.transport;

    status = manager.replace_active_cq(candidate_cq);
    if (!status.ok()) begin
      status = abort_cq_resize(cq_h, old_attachment.runtime, dependents,
                               candidate_ref, manager_quiesced, cq_quiesced,
                               status);
      return finish_resize(status);
    end

    // 设计：发布成功后立即切换 attachment，使后续恢复报告指向新 authority；
    // 随后 detach 旧 runtime 并释放 control-plane-owned 的旧 mapping。
    // manager replacement 已经提交，recovery record 从此进入 published
    // 阶段；retry 必须把当前 attachment 视为新 runtime，并只清理 old_ref。
    recovery.published = 1'b1;
    attachments[key] = replacement;
    cq_resize_recoveries[recovery_key] = recovery;
    status = restore_cq_dependents(dependents);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ resize dependent runtime restore returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      return finish_resize(rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize published but dependent runtime restore failed: ",
         status.message}));
    end
    status = old_attachment.runtime.detach_quiesced();
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ resize old runtime detach returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      return finish_resize(rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize published but old runtime detach failed: ",
         status.message}));
    end
    status = backing_planner.cleanup_local_role(old_ref, cleanup_complete);
    if (status == null || !status.ok() || !cleanup_complete) begin
      if (status == null)
        status = bad("CQ resize old backing cleanup returned null",
                     RDMA_SC_RECOVERY_REQUIRED);
      recovery.last_status = status;
      return finish_resize(rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize published but old backing cleanup failed: ",
         status.message,
         "; dependent restore: ",
         "dependents already restored"}));
    end
    cq_resize_recoveries.delete(recovery_key);
    return finish_resize(rdma_status::success());
  endfunction

  // 功能：在 rdma_queue_data_engine 中，poll_ceqe_once 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：ceq_h（输入）、result（输出）、status（输出）；poll_ceqe_once 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：poll_ceqe_once 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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
    rdma_hw_ceqe_model ceqe;
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
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CEQE,
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

  // 功能：在 rdma_queue_data_engine 中，poll_ceqe 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：ceq_h（输入）、timeout（输入）、result（输出）、status（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：poll_ceqe 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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

  // 功能：在 rdma_queue_data_engine 中，poll_aeqe_once 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：aeq_h（输入）、result（输出）、status（输出）；poll_aeqe_once 驱动下游事务，并写入 result、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：poll_aeqe_once 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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
    rdma_hw_aeqe_model aeqe;
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
    codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
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

  // 功能：在 rdma_queue_data_engine 中，poll_aeqe 读取并解码队列条目，校验 owner/identity 后提交 consumer index，成功提交后才发布 completion/event。
  // 输入/输出及副作用：aeq_h（输入）、timeout（输入）、result（输出）、status（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：poll_aeqe 遇到队列为空、owner/identity 失配或 CI/MMIO 提交失败时不发布 completion/event。
  //   空句柄、队列为空、owner 不匹配或 doorbell 失败时不发布半成品结果。
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

  // 功能：在 rdma_queue_data_engine 中，post_send 完成发送队列预检、槽位预留、WQE 写入和 producer doorbell 提交，并返回提交结果与失败证据。
  // 输入/输出及副作用：request（输入）、result（输出）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：未配置、空队列、stale generation/reset epoch 和 ambiguous MMIO 均禁止发布成功结果或自动重试。
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
    rdma_hw_sqe_model model;
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

  // 功能：在 rdma_queue_data_engine 中，post_recv 完成接收队列预检、槽位预留、RQE 写入和 producer doorbell 提交，并返回提交结果与失败证据。
  // 输入/输出及副作用：request（输入）、result（输出）、status（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：未配置、空队列、stale generation/reset epoch 和 ambiguous MMIO 均禁止发布成功结果或自动重试。
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
    rdma_hw_rqe_model model;
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

  // 功能：在 rdma_queue_data_engine 中，pending_next_cursor 从 pending reservation 计算提交后的 index/wrap，遇到 ring 末尾时回卷并翻转 wrap。
  // 输入/输出及副作用：attachment（输入）、pending（输入）、next（输出）；pending_next_cursor 读取 attachment、pending、next 并使用字段 next、next.index、next.wrap，并写入 next；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：pending_next_cursor 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“pending recovery cursor is invalid”；失败路径不提交部分状态或转移未声明资源。
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
  // 功能：在 rdma_queue_data_engine 中，replay_pending 记录或执行队列恢复步骤，依据提交证据选择重试、提交或回滚并保持操作幂等。
  // 输入/输出及副作用：attachment（输入）、pending（输入）、status（输出）；replay_pending 驱动下游事务，并写入 status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：replay_pending 失败或超时通过 status 明确发布；该路径不隐式重试，也不转移未声明资源。
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
    rdma_hw_cqe_model cqe;
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
      codec_key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
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

  // 功能：在 rdma_queue_data_engine 中，recover_queue 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：queue_h（输入）、action（输入）、caller_confirmed_no_submit（输入）、status（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_queue 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
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
