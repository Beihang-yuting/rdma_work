// 目录：核心执行层 core/rdma_queue_data_engine.sv。
// 职责：实现 queue-data facade，协调 SQ/RQ/SRQ post、CQ/CEQ/AEQ device publish、
// poll、CQ resize 与 recovery，并在每个边界校验 Function、route、generation 和 epoch。
// 依赖：依赖 rdma_queue_runtime 的冻结队列状态、codec/model、resource manager、
// Host-memory/backing access 与 doorbell scheduler 契约；全局 topology authority 只读自 binding。
// 所有权与生命周期：engine 拥有本地 attachment 索引、detached 结果和未接管 recovery
// evidence；runtime、queue handle、backing capability、mapping 与 QP route 均为非拥有引用，
// 其生命周期由 lifecycle/resource manager 或外部环境管理，detach/abort 不越权释放 mapping。

// 设计说明：本层是 host 侧 queue-data facade。queue 的生命周期仍归 lifecycle
// resource 所有；engine 仅在 attachment 存活期间保存 detached runtime cursor 和
// 借用的 backing-access capability，不能反向接管外部 mapping 或队列资源。

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

// 功能：保存一次 CQ/CEQ/AEQ 共用的 device-producer 发布 detached 结果，供
//   调用方观察已提交槽位、镜像与 occupancy，而不暴露 runtime 的可变内部状态。
// 输入/输出及副作用：字段由各类型 publish 成功路径写入；对象不拥有 queue、
//   mapping 或 runtime，只拥有自身指向的 detached queue/image/status 快照。
// 失败边界：失败路径不得发布半成品对象；occupancy_valid=0 表示提交后的查询失败，
//   不是对已提交 cursor 的回滚，也不得被调用方当作 occupancy=0。
class rdma_queue_device_publish_result extends uvm_object;
  `uvm_object_utils(rdma_queue_device_publish_result)
  rdma_handle queue_h;
  int unsigned index;
  bit wrap;
  int unsigned occupancy;
  bit occupancy_valid;
  rdma_hw_image image;
  rdma_status status;

  // 功能：构造设备发布结果并建立安全默认状态。
  // 输入/输出及副作用：name 为输入；仅初始化本地字段，不接管外部资源。
  // 失败/边界：构造阶段不执行校验，调用方必须依据 status 判断结果是否可用。
  function new(string name = "rdma_queue_device_publish_result");
    super.new(name);
    queue_h = null;
    index = 0;
    wrap = 1'b0;
    occupancy = 0;
    occupancy_valid = 1'b0;
    image = null;
    status = null;
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

// 设计说明：每个 ring 必须拥有独立 attachment。尤其同一 QP 的 SQ/RQ 逻辑
// offset 都从零开始，若共享 backing-access lookup namespace 会把不同 ring 的
// slot 误解析到同一 mapping；因此只借用各自的 access/runtime，不共享索引。
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
  rdma_queue_backing_access sq_sgb_access;
  rdma_qp_backing_ref sq_sgb_ref;

  // 功能：构造 rdma_queue_data_qp_link，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qp_h=null；srq_h=null；send_cq_h=null；recv_cq_h=null；local_qp_id=0；transport=RDMA_TRANSPORT_RC。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_qp_link 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_qp_link");
    super.new(name);
    qp_h = null; srq_h = null; send_cq_h = null; recv_cq_h = null;
    local_qp_id = 0; transport = RDMA_TRANSPORT_RC; sq_sgb_access = null; sq_sgb_ref = null;
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
  // 设计说明：planner 只拥有临时分配账本；替换成功后的 mapping 仍由 lifecycle
  // queue plan 所有，engine 不得把借用的 backing 当作可释放资源。
  protected rdma_queue_backing_planner backing_planner;
  protected semaphore resize_lock;

  protected rdma_queue_data_attachment attachments[string];
  protected rdma_queue_data_qp_link qp_links[string];
  // 以不含 generation 的稳定 CQ identity 索引发布后尚未完成的旧 backing
  // 清理记录，使 Function reset 后仍能找到旧代际的 release authority。
  protected rdma_cq_resize_recovery cq_resize_recoveries[string];
  // 设计说明：device publish 的 recovery 可能在 runtime 接管前就遇到并发状态
  // 迁移失败。此时必须成对保留 detached evidence 与借用 attachment，直到调用方
  // 显式 retry 或 abort；任一项被静默丢弃都会失去 reservation 的释放 authority。
  protected rdma_queue_pending_operation unclaimed_device_recoveries[string];
  protected rdma_queue_data_attachment unclaimed_recovery_attachments[string];
  protected bit configured;
  // 最新 detached URC shadow evidence，供 recovery 检查但不转移原始对象所有权。
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
    unclaimed_device_recoveries.delete();
    unclaimed_recovery_attachments.delete();
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

  // 功能：lookup_attachment 按完整 handle/kind key 返回 engine 索引的借用
  //   attachment，供同一 engine 内的 publish/poll/recovery 使用。
  // 输入/输出及副作用：handle、kind 为输入，attachment 为输出；成功时输出仅是
  //   非拥有引用，不复制 runtime/access，也不验证 route、reset epoch 或 backing。
  // 失败边界：handle 校验、索引缺失、runtime/access 不完整时返回非成功 status；
  //   调用方须在需要时另行执行冻结 route/epoch 与具体 backing authority 校验。
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

  // 功能：validate_publish_route_epoch 对比 attachment runtime 冻结的 route/epoch
  //   与当前 binding detached identity，阻止复位或换路后继续预留 device producer slot。
  // 输入/输出及副作用：attachment 为输入；函数只读取 runtime 与 binding snapshot，
  //   不预留 cursor、不访问 backing、不修改任何 ownership。
  // 失败边界：attachment/binding/identity 缺失、query 返回 null、route/epoch 无效
  //   或任一快照不相等时返回明确非成功 status，调用方必须在 reserve 前停止。
  protected function rdma_status validate_publish_route_epoch(
    rdma_queue_data_attachment attachment
  );
    rdma_function_identity identity;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    bit route_valid;
    bit epoch_valid;
    rdma_status status;

    route = '0;
    epoch = '0;
    route_valid = 1'b0;
    epoch_valid = 1'b0;
    if (attachment == null || attachment.runtime == null || binding == null)
      return bad("publish route authority is incomplete", RDMA_SC_INVALID_STATE);
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return bad("publish Function identity snapshot is unavailable",
                 RDMA_SC_INVALID_STATE);
    status = identity.validate();
    if (status == null || !status.ok())
      return status == null ?
        bad("publish Function identity validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
    status = attachment.runtime.query_route_epoch(route, route_valid, epoch,
                                                  epoch_valid);
    if (status == null || !status.ok())
      return status == null ?
        bad("publish runtime route query returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (!route_valid || !epoch_valid || route != identity.route_key() ||
        epoch != identity.reset_epoch)
      return bad("publish route or reset epoch is stale",
                 RDMA_SC_STALE_GENERATION);
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

  // 功能：query_runtime_occupancy 返回指定 SQ/RQ/CQ 等 runtime 的当前
  //   credit 使用量以及是否存在待恢复事务，供端到端 scoreboard 验证
  //   completion 后的 outstanding 账本已经清零。
  // 输入/输出及副作用：handle、kind（输入）；used、pending（输出）；函数
  //   只读取 attachment/runtime 快照，不推进 PI/CI，不提交 doorbell，也不
  //   转移队列或 Host-memory 所有权。
  // 失败/边界：句柄代际失效、attachment 缺失或 runtime 未配置时返回明确
  //   错误，并把 used/pending 保持为安全默认值 0/0，调用方不得把失败当作
  //   “队列为空”的证据。
  function rdma_status query_runtime_occupancy(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output int unsigned used, output bit pending
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    used = 0;
    pending = 1'b0;
    status = lookup_attachment(handle, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("runtime occupancy lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("runtime occupancy attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    used = attachment.runtime.used;
    pending = attachment.runtime.pending_operation != null;
    return rdma_status::success();
  endfunction

  // 功能：query_runtime_cursors 返回指定 runtime 的 producer/consumer
  //   index 与 wrap 快照，用于验证 PI/CI doorbell 及 ring 回卷语义。
  // 输入/输出及副作用：handle、kind（输入）；producer_index、producer_wrap、
  //   consumer_index、consumer_wrap（输出）；函数只读 runtime，不提交任何
  //   MMIO 或修改队列状态。
  // 失败/边界：句柄、代际或 attachment 无效时返回错误，所有输出置零；
  //   调用方必须先检查返回状态，不能使用失败路径的默认游标作有效证据。
  function rdma_status query_runtime_cursors(
    rdma_handle handle, rdma_queue_runtime_kind_e kind,
    output int unsigned producer_index, output bit producer_wrap,
    output int unsigned consumer_index, output bit consumer_wrap
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    producer_index = 0;
    producer_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = lookup_attachment(handle, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("runtime cursor lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("runtime cursor attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    producer_index = attachment.runtime.producer_index;
    producer_wrap = attachment.runtime.producer_wrap;
    consumer_index = attachment.runtime.consumer_index;
    consumer_wrap = attachment.runtime.consumer_wrap;
    return rdma_status::success();
  endfunction

  // 功能：query_runtime_device_reservation 返回尚未清除的 device producer
  //   reservation，供 cancel 返回 RECOVERY_REQUIRED 时定位同一 queue/cursor
  //   evidence，而不依赖 lifecycle 的外部 shadow。
  // 输入/输出及副作用：queue_h、kind 为输入，valid/reservation 为输出并先置安全
  //   默认值；函数只读取 runtime，不提交、取消或接管 reservation。
  // 失败边界：attachment/runtime 缺失或 runtime 查询返回 null status 时返回
  //   INVALID_STATE；没有 reservation 时 valid=0、reservation=null 仍为成功查询。
  function rdma_status query_runtime_device_reservation(
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    output bit valid,
    output rdma_queue_cursor_snapshot reservation
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    valid = 1'b0;
    reservation = null;
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("device reservation lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("device reservation attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_device_reservation(valid, reservation);
    return status == null ?
      bad("device reservation query returned null status",
          RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：clone_publish_handle 为设备发布事务复制 queue/route handle 的全部
  //   身份字段，形成不会随调用方修改而变化的 detached 快照。
  // 输入/输出及副作用：source、label 为输入，copy 为输出；函数只分配并写入
  //   一个本地 handle，不访问 backing、runtime 或 manager，也不取得 source 所有权。
  // 失败边界：source 为空、工厂分配失败或输出无法建立时返回明确错误，copy 保持
  //   null；任何失败都不能把半成品句柄交给 recovery 或 result。
  protected function rdma_status clone_publish_handle(
    rdma_handle source, string label, output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return bad({label, " source handle is null"});
    candidate = rdma_handle::type_id::create({label, "_copy"});
    if (candidate == null)
      return bad({label, " handle allocation failed"},
                 RDMA_SC_RESOURCE_EXHAUSTED);
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：clone_publish_image 深复制设备发布所需的镜像 metadata、payload 和
  //   field_summary，保证写后失败时仍能按原始槽位重放。
  // 输入/输出及副作用：source 为输入，copy 为输出；只创建 detached image，源
  //   image、runtime 和 backing 均保持不变。
  // 失败边界：source 为空、image 工厂分配失败或复制中止时返回错误且 copy=null；
  //   调用方不得使用不完整镜像继续写入或提交。
  protected function rdma_status clone_publish_image(
    rdma_hw_image source, output rdma_hw_image copy
  );
    rdma_hw_image candidate;

    copy = null;
    if (source == null)
      return bad("publish image source is null");
    candidate = rdma_hw_image::type_id::create("publish_image_copy");
    if (candidate == null)
      return bad("publish image allocation failed", RDMA_SC_RESOURCE_EXHAUSTED);
    candidate.length = source.length;
    candidate.alignment = source.alignment;
    candidate.endian = source.endian;
    candidate.image_kind = source.image_kind;
    candidate.hardware_version = source.hardware_version;
    candidate.function_generation = source.function_generation;
    candidate.write_target_kind = source.write_target_kind;
    candidate.backing_target = source.backing_target;
    candidate.hmc_target = source.hmc_target;
    candidate.bar_target = source.bar_target;
    candidate.bytes.delete();
    foreach (source.bytes[i]) candidate.bytes.push_back(source.bytes[i]);
    candidate.field_summary.delete();
    foreach (source.field_summary[i])
      candidate.field_summary.push_back(source.field_summary[i]);
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：clone_unclaimed_device_pending 为 engine-owned 的 device recovery
  //   evidence 创建完整 detached 查询快照，避免 query API 泄露可写内部对象。
  // 输入/输出及副作用：source 为输入、copy 为输出；函数只分配和复制 handle、
  //   cursor、image、status 与设备发布阶段字段，不修改 unclaimed 表或 runtime。
  // 失败边界：source 不是完整 device pending、任一对象分配或复制失败时返回非空
  //   status 且 copy=null；调用方必须保留原 evidence，不能因查询失败删除表项。
  protected function rdma_status clone_unclaimed_device_pending(
    rdma_queue_pending_operation source,
    output rdma_queue_pending_operation copy
  );
    rdma_queue_pending_operation candidate;
    rdma_status status;

    copy = null;
    if (source == null || !source.device_producer || source.producer ||
        source.request_snapshot != null || source.queue_h == null ||
        source.cursor == null || source.next_cursor == null ||
        source.image == null || source.failure_status == null)
      return bad("unclaimed device pending is incomplete", RDMA_SC_INVALID_STATE);
    candidate = rdma_queue_pending_operation::type_id::create(
      "unclaimed_device_pending_snapshot");
    if (candidate == null)
      return bad("unclaimed device pending allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    status = clone_publish_handle(source.queue_h, "unclaimed device queue",
                                  candidate.queue_h);
    if (status == null || !status.ok() || candidate.queue_h == null)
      return status == null ?
        bad("unclaimed device queue clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    candidate.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "unclaimed_device_cursor_snapshot");
    candidate.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "unclaimed_device_next_cursor_snapshot");
    if (candidate.cursor == null || candidate.next_cursor == null)
      return bad("unclaimed device cursor snapshot allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    candidate.cursor.index = source.cursor.index;
    candidate.cursor.wrap = source.cursor.wrap;
    candidate.next_cursor.index = source.next_cursor.index;
    candidate.next_cursor.wrap = source.next_cursor.wrap;
    if (source.committed_consumer_cursor != null) begin
      candidate.committed_consumer_cursor =
        rdma_queue_cursor_snapshot::type_id::create(
          "unclaimed_device_committed_cursor_snapshot");
      if (candidate.committed_consumer_cursor == null)
        return bad("unclaimed device committed cursor allocation failed",
                   RDMA_SC_RESOURCE_EXHAUSTED);
      candidate.committed_consumer_cursor.index =
        source.committed_consumer_cursor.index;
      candidate.committed_consumer_cursor.wrap =
        source.committed_consumer_cursor.wrap;
    end
    status = clone_publish_image(source.image, candidate.image);
    if (status == null || !status.ok() || candidate.image == null)
      return status == null ?
        bad("unclaimed device image clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    candidate.failure_status = rdma_status::type_id::create(
      "unclaimed_device_failure_status_snapshot");
    if (candidate.failure_status == null)
      return bad("unclaimed device failure status allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    status = copy_publish_status_into(source.failure_status,
                                      candidate.failure_status);
    if (status == null || !status.ok())
      return status == null ?
        bad("unclaimed device failure status copy returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    if (source.routed_qp_h != null) begin
      status = clone_publish_handle(source.routed_qp_h,
                                    "unclaimed device routed QP",
                                    candidate.routed_qp_h);
      if (status == null || !status.ok() || candidate.routed_qp_h == null)
        return status == null ?
          bad("unclaimed device routed QP clone returned null status",
              RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    candidate.kind = source.kind;
    candidate.producer = source.producer;
    candidate.device_producer = source.device_producer;
    candidate.device_write_attempted = source.device_write_attempted;
    candidate.consumer_committed = source.consumer_committed;
    candidate.cq_consumer_committed = source.cq_consumer_committed;
    candidate.completion_released = source.completion_released;
    candidate.consumer_doorbell_succeeded = source.consumer_doorbell_succeeded;
    candidate.entry_offset = source.entry_offset;
    candidate.wr_id = source.wr_id;
    candidate.signaled = source.signaled;
    candidate.completion_index = source.completion_index;
    candidate.completion_wrap = source.completion_wrap;
    candidate.completion_target_valid = source.completion_target_valid;
    candidate.mmio_maybe_submitted = source.mmio_maybe_submitted;
    candidate.known_no_mmio = source.known_no_mmio;
    candidate.mmio_evidence = source.mmio_evidence;
    candidate.entry_size = source.entry_size;
    candidate.route = source.route;
    candidate.route_valid = source.route_valid;
    candidate.reset_epoch = source.reset_epoch;
    candidate.epoch_valid = source.epoch_valid;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：copy_publish_status_into 在 pending 已预分配的诊断对象中更新原始
  //   失败字段，避免写后故障路径再次依赖可能失败的 clone/工厂分配。
  // 输入/输出及副作用：source、destination 为输入；destination 的受控状态字段
  //   会被覆盖，source、queue cursor 和 backing 不受影响。
  // 失败边界：任一状态为空返回 INVALID_ARGUMENT，destination 保持原值；成功后
  //   不会改变 status 的对象身份或其拥有关系。
  protected function rdma_status copy_publish_status_into(
    rdma_status source, rdma_status destination
  );
    if (source == null || destination == null)
      return bad("publish status copy input is null");
    destination.category = source.category;
    destination.code = source.code;
    destination.hardware_code = source.hardware_code;
    destination.hardware_code_valid = source.hardware_code_valid;
    destination.source_engine = source.source_engine;
    destination.function_uid = source.function_uid;
    destination.generation = source.generation;
    destination.resource_id = source.resource_id;
    destination.command_id = source.command_id;
    destination.wr_id = source.wr_id;
    destination.severity = source.severity;
    destination.retryable = source.retryable;
    destination.message = source.message;
    return rdma_status::success();
  endfunction

  // 功能：copy_image_bytes 将 image 的 queue payload 复制到连续 byte 数组，供
  //   write_device 和 readback 比较使用；源镜像保持只读。
  // 输入/输出及副作用：source 为输入，data 为输出并先清空；函数不访问外部
  //   mapping，也不推进任何 runtime cursor。
  // 失败边界：source 为空、length 与 bytes 数量不一致或长度为零时返回错误，data
  //   保持空数组，调用方必须在 backend 调用前停止事务。
  protected function rdma_status copy_image_bytes(
    rdma_hw_image source, output byte data[]
  );
    data = new[0];
    if (source == null)
      return bad("publish image source is null");
    if (source.length == 0 || source.length != source.bytes.size())
      return bad("publish image metadata length is inconsistent",
                 RDMA_SC_CODEC_ERROR);
    data = new[source.bytes.size()];
    foreach (data[i]) data[i] = byte'(source.bytes[i]);
    return rdma_status::success();
  endfunction

  // 功能：prepare_device_pending 在设备写入前建立完整的 detached recovery
  //   evidence（queue、旧/新 cursor、entry offset、image、route/epoch 和失败状态）。
  // 输入/输出及副作用：attachment、reservation、next、image、device_write_attempted
  //   为输入，pending 为输出；只分配本地 evidence，不写 backing、不修改 runtime。
  // 失败边界：任一 authority/geometry/clone/route 查询失败时返回非成功状态且
  //   pending=null；半成品 evidence 不得挂入 runtime recovery。
  protected function rdma_status prepare_device_pending(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_queue_cursor_snapshot next,
    rdma_hw_image image,
    bit device_write_attempted,
    output rdma_queue_pending_operation pending
  );
    rdma_status status;
    rdma_handle queue_copy;
    rdma_hw_image image_copy;
    rdma_queue_cursor_snapshot cursor_copy;
    rdma_queue_cursor_snapshot next_copy;

    pending = null;
    if (attachment == null || attachment.queue_h == null ||
        attachment.runtime == null || reservation == null || next == null ||
        image == null || attachment.entry_size == 0)
      return bad("device pending input is incomplete");
    if (reservation.index >= attachment.runtime.depth ||
        next.index >= attachment.runtime.depth)
      return bad("device pending cursor is outside depth");

    pending = rdma_queue_pending_operation::type_id::create(
      "device_publish_pending");
    if (pending == null) begin
      pending = null;
      return bad("device pending allocation failed", RDMA_SC_RESOURCE_EXHAUSTED);
    end
    status = clone_publish_handle(attachment.queue_h, "device pending queue",
                                  queue_copy);
    if (status == null || !status.ok() || queue_copy == null) begin
      pending = null;
      return status == null ?
        bad("device pending queue clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    status = clone_publish_image(image, image_copy);
    if (status == null || !status.ok() || image_copy == null) begin
      pending = null;
      return status == null ?
        bad("device pending image clone returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    cursor_copy = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_cursor");
    next_copy = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_next_cursor");
    if (cursor_copy == null || next_copy == null) begin
      pending = null;
      return bad("device pending cursor allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    cursor_copy.index = reservation.index;
    cursor_copy.wrap = reservation.wrap;
    next_copy.index = next.index;
    next_copy.wrap = next.wrap;

    pending.queue_h = queue_copy;
    pending.kind = attachment.kind;
    pending.producer = 1'b0;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = device_write_attempted;
    pending.entry_size = attachment.entry_size;
    pending.entry_offset = longint'(reservation.index) *
                           longint'(attachment.entry_size);
    pending.cursor = cursor_copy;
    pending.next_cursor = next_copy;
    pending.image = image_copy;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    pending.mmio_maybe_submitted = 1'b0;
    pending.known_no_mmio = 1'b1;
    pending.consumer_doorbell_succeeded = 1'b0;
    pending.consumer_committed = 1'b0;
    pending.cq_consumer_committed = 1'b0;
    pending.completion_released = 1'b0;
    pending.failure_status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED, "device publish failure not yet recorded");
    if (pending.failure_status == null) begin
      pending = null;
      return bad("device pending failure status allocation failed",
                 RDMA_SC_RESOURCE_EXHAUSTED);
    end
    status = attachment.runtime.query_route_epoch(
      pending.route, pending.route_valid, pending.reset_epoch,
      pending.epoch_valid);
    if (status == null || !status.ok() || !pending.route_valid ||
        !pending.epoch_valid) begin
      pending = null;
      return status == null ?
        bad("device pending route/epoch query returned null",
            RDMA_SC_INVALID_STATE) :
        (status.ok() ? bad("device pending route/epoch evidence is invalid",
                           RDMA_SC_INVALID_STATE) : status);
    end
    return rdma_status::success();
  endfunction

  // 功能：enter_device_publish_recovery 把写后失败的 detached evidence 安装到
  //   runtime recovery 状态，并在 runtime 无法接管时保存到 engine-owned unclaimed 表。
  // 输入/输出及副作用：attachment、prepared_pending、original_status、evidence 为
  //   输入，final_status 为输出；成功安装会切换 runtime 状态，失败仅更新 engine 表。
  // 失败边界：任何阶段均返回非空 RECOVERY_REQUIRED；不得调用 cancel 清除已进入
  //   backend 的 reservation，也不得覆盖已有不同 identity 的 evidence。
  protected task enter_device_publish_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation prepared_pending,
    rdma_status original_status,
    rdma_queue_mmio_evidence_e evidence,
    output rdma_status final_status
  );
    rdma_status status;
    rdma_status copy_status;
    string key;

    final_status = null;
    if (attachment == null || attachment.runtime == null ||
        prepared_pending == null || prepared_pending.queue_h == null) begin
      final_status = bad("device recovery evidence is incomplete",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (original_status == null)
      original_status = bad("device publish returned null status");
    copy_status = copy_publish_status_into(original_status,
                                            prepared_pending.failure_status);
    if (copy_status == null || !copy_status.ok()) begin
      if (prepared_pending.failure_status != null) begin
        prepared_pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
        prepared_pending.failure_status.message =
          "original device publish failure could not be detached";
      end
    end
    prepared_pending.mmio_evidence = evidence;
    prepared_pending.known_no_mmio = evidence inside {
      RDMA_QUEUE_MMIO_NOT_APPLICABLE, RDMA_QUEUE_MMIO_NO_SUBMIT};
    prepared_pending.mmio_maybe_submitted =
      evidence == RDMA_QUEUE_MMIO_AMBIGUOUS;
    prepared_pending.consumer_doorbell_succeeded =
      evidence == RDMA_QUEUE_MMIO_SUCCESS;
    status = admit_device_publish_recovery(attachment, prepared_pending);
    if (status != null && status.ok()) begin
      status = attachment.runtime.record_recovery_failure(evidence);
      final_status = bad("device publish entered recovery",
                         RDMA_SC_RECOVERY_REQUIRED);
      if (status == null || !status.ok())
        final_status.message = "device recovery evidence projection failed";
      return;
    end

    key = identity_key(prepared_pending.queue_h);
    if (key == "") begin
      final_status = bad("device recovery evidence has no stable identity",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    if (unclaimed_device_recoveries.exists(key) &&
        unclaimed_device_recoveries[key] != null) begin
      final_status = bad("device recovery identity is already retained",
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    unclaimed_device_recoveries[key] = prepared_pending;
    unclaimed_recovery_attachments[key] = attachment;
    final_status = bad("device recovery admission failed; evidence retained",
                       RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：device publish 的 runtime admission 是写后恢复证据进入状态机的
  //   唯一边界。保留此 virtual 分派使故障注入能在不公开 attachment/backing 的
  //   前提下验证 engine-owned unclaimed evidence 的保留与回收路径。
  // 功能：admit_device_publish_recovery 将完整的 device pending 交给 attachment
  //   runtime 接管，默认保持 runtime 的真实 state/identity 校验。
  // 输入/输出及副作用：attachment、prepared_pending 为输入；成功时 runtime 接管
  //   pending 并进入 recovery，函数不修改 Host-memory、backing 或 engine 表。
  // 失败边界：attachment/runtime/pending 缺失返回 INVALID_STATE；runtime 拒绝、
  //   返回 null 或状态迁移失败原样交给调用方决定保留 unclaimed evidence。
  protected virtual function rdma_status admit_device_publish_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation prepared_pending
  );
    if (attachment == null || attachment.runtime == null ||
        prepared_pending == null)
      return bad("device recovery admission input is incomplete",
                 RDMA_SC_INVALID_STATE);
    return attachment.runtime.enter_recovery_prepared(prepared_pending);
  endfunction

  // 功能：finish_device_producer_cancel 将 reservation 的安全取消收敛为可观察
  //   的原始失败或 RECOVERY_REQUIRED；若已有 detached pending，则在取消失败时
  //   把它交给 runtime/engine recovery 保存，避免遗失槽位与镜像证据。
  // 输入/输出及副作用：attachment、reservation、pending、original_status、cancel_context
  //   为输入，final_status 为输出；成功取消不修改 committed cursor，失败时可能
  //   切换 runtime recovery 或写入 engine 的 unclaimed recovery 表。
  // 失败边界：runtime 返回 null、非 OK 或 attachment 不完整时 final_status 始终
  //   为非空 RECOVERY_REQUIRED；pending 为空的纯 preflight 路径保留 runtime
  //   reservation，调用方不得将它误判为已经清理。
  protected task finish_device_producer_cancel(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_queue_pending_operation pending,
    rdma_status original_status,
    string cancel_context,
    output rdma_status final_status
  );
    rdma_status cancel_status;

    final_status = null;
    if (original_status == null)
      original_status = bad({cancel_context, " original status is null"},
                            RDMA_SC_INVALID_STATE);
    if (attachment == null || attachment.runtime == null ||
        reservation == null) begin
      final_status = bad({cancel_context, " cancel evidence is incomplete"},
                         RDMA_SC_RECOVERY_REQUIRED);
      return;
    end
    cancel_status = cancel_device_publish_reservation(attachment, reservation);
    if (cancel_status != null && cancel_status.ok()) begin
      final_status = original_status;
      return;
    end
    if (pending != null) begin
      pending.device_write_attempted = 1'b0;
      enter_device_publish_recovery(attachment, pending, cancel_status,
                                    RDMA_QUEUE_MMIO_NO_SUBMIT,
                                    final_status);
      if (final_status != null &&
          final_status.code == RDMA_SC_RECOVERY_REQUIRED)
        return;
    end
    final_status = bad({cancel_context,
                        " cancel did not clear the device reservation"},
                       RDMA_SC_RECOVERY_REQUIRED);
  endtask

  // 设计说明：preflight cancel 与写后 recovery 的边界不同：前者只能在尚未进入
  //   backend 时撤销 reservation。virtual 分派把确定性取消失败限制在该边界，避免
  //   测试取得或改写 lifecycle-owned runtime/backing。
  // 功能：cancel_device_publish_reservation 请求 attachment runtime 取消指定的
  //   device producer reservation，默认执行真实 runtime 校验和状态变更。
  // 输入/输出及副作用：attachment、reservation 为输入；成功时清除 runtime 内的
  //   reservation，不推进 producer cursor、不访问 Host-memory 或修改 queue plan。
  // 失败边界：attachment/runtime/reservation 缺失返回 INVALID_STATE；runtime 的
  //   stale、非 ACTIVE 或已有写入证据拒绝结果原样返回，调用方必须保留恢复证据。
  protected virtual function rdma_status cancel_device_publish_reservation(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation
  );
    if (attachment == null || attachment.runtime == null || reservation == null)
      return bad("device reservation cancel input is incomplete",
                 RDMA_SC_INVALID_STATE);
    return attachment.runtime.cancel_device_producer(reservation);
  endfunction

  // 功能：write_commit_device_entry 执行 CQ/CEQ/AEQ 共享的设备发布事务，从
  //   reservation 到 DEVICE_WRITE、readback、producer commit 和 detached result。
  // 输入/输出及副作用：attachment、reservation、image 为已校验输入，result/status
  //   为输出；成功写入真实 backing 并推进 device runtime occupancy，不发送 producer
  //   doorbell，也不创建 host WQE ledger。
  // 失败边界：写入前纯校验失败只允许 cancel；一旦 backend write 开始，任何失败都
  //   必须保存 pending 并返回 RECOVERY_REQUIRED，绝不能回滚或伪造成功 result。
  protected task write_commit_device_entry(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation,
    rdma_hw_image image,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_cursor_snapshot current_reservation;
    rdma_queue_cursor_snapshot next;
    rdma_queue_pending_operation pending;
    rdma_queue_device_publish_result candidate;
    rdma_hw_image detached_image;
    rdma_handle detached_queue;
    rdma_status local_status;
    rdma_status original_status;
    rdma_status recovery_status;
    byte data[];
    byte readback[];
    bit reservation_valid;
    bit backend_write_started;
    int unsigned occupancy;
    longint unsigned offset;

    result = null;
    status = null;
    current_reservation = null;
    next = null;
    pending = null;
    candidate = null;
    detached_image = null;
    detached_queue = null;
    data = new[0];
    readback = new[0];
    occupancy = 0;

    if (attachment == null || attachment.queue_h == null ||
        attachment.runtime == null || attachment.access == null ||
        reservation == null || image == null) begin
      status = bad("device publish attachment/evidence is incomplete",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (!(attachment.kind inside {RDMA_QUEUE_RUNTIME_CQ,
                                  RDMA_QUEUE_RUNTIME_CEQ,
                                  RDMA_QUEUE_RUNTIME_AEQ}) ||
        attachment.entry_size == 0 || (attachment.entry_size & 64'h7) != 0) begin
      status = bad("device publish kind/geometry is invalid",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    reservation_valid = 1'b0;
    status = attachment.runtime.query_device_reservation(
      reservation_valid, current_reservation);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("device reservation query returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (!reservation_valid || current_reservation == null ||
        current_reservation.index != reservation.index ||
        current_reservation.wrap != reservation.wrap) begin
      status = bad("device reservation is stale or not owned");
      return;
    end
    // 设计说明：所有可能触发 cancel 的纯 preflight 分支之前，先准备完整 pending。
    // 这样取消本身失败时，runtime 能立刻接管同一 queue/cursor/image evidence，
    // 调用方可经 query_runtime_pending/recover_queue 查询或显式 abort，而不是只
    // 留下无法处理的 reservation。
    next = rdma_queue_cursor_snapshot::type_id::create("device_publish_next");
    if (next == null) begin
      original_status = bad("device publish next cursor allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "device publish next cursor",
                                    status);
      return;
    end
    next.index = reservation.index;
    next.wrap = reservation.wrap;
    if (next.index + 1 >= attachment.runtime.depth) begin
      next.index = 0;
      next.wrap = ~next.wrap;
    end
    else next.index++;
    status = prepare_device_pending(attachment, reservation, next, image,
                                    1'b0, pending);
    if (status == null || !status.ok() || pending == null) begin
      if (status == null)
        status = bad("device publish recovery evidence allocation failed",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status,
                                    "device publish pending preparation", status);
      return;
    end
    if (reservation.index >= attachment.runtime.depth ||
        reservation.index > 64'hffff_ffff_ffff_ffff /
                           longint'(attachment.entry_size)) begin
      original_status = bad("device publish slot offset is out of range",
                            RDMA_SC_DMA_TRANSLATION);
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish offset",
                                    status);
      return;
    end
    if (image.length != attachment.entry_size ||
        image.bytes.size() != attachment.entry_size ||
        image.alignment != attachment.entry_size ||
        image.endian != RDMA_ENDIAN_BIG) begin
      original_status = bad("device publish image length/alignment mismatch",
                            RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish image",
                                    status);
      return;
    end

    candidate = rdma_queue_device_publish_result::type_id::create(
      "device_publish_result");
    if (candidate == null) begin
      original_status = bad("device publish result allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish result",
                                    status);
      return;
    end
    // candidate.status 必须在 backend write 前完成分配。commit 成功后只原位
    // 更新这份状态，避免已提交槽位因结果状态工厂失败而没有 result/evidence。
    candidate.status = rdma_status::success(
      "device publish candidate; commit not yet acknowledged");
    if (candidate.status == null) begin
      original_status = bad("device publish result status allocation failed",
                            RDMA_SC_RESOURCE_EXHAUSTED);
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status,
                                    "device publish result status", status);
      return;
    end
    status = copy_image_bytes(image, data);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("device publish image copy returned null status",
                     RDMA_SC_CODEC_ERROR);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish byte copy",
                                    status);
      return;
    end
    status = clone_publish_image(image, detached_image);
    if (status == null || !status.ok() || detached_image == null) begin
      if (status == null)
        status = bad("device publish image clone returned null status",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish image clone",
                                    status);
      return;
    end
    status = clone_publish_handle(attachment.queue_h, "publish result queue",
                                  detached_queue);
    if (status == null || !status.ok() || detached_queue == null) begin
      if (status == null)
        status = bad("device publish queue clone returned null status",
                     RDMA_SC_RESOURCE_EXHAUSTED);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, pending,
                                    original_status, "device publish queue clone",
                                    status);
      return;
    end
    pending.device_write_attempted = 1'b1;
    offset = longint'(reservation.index) * longint'(attachment.entry_size);
    readback = new[attachment.entry_size];
    backend_write_started = 1'b0;
    status = attachment.access.write_device(offset, data,
                                            backend_write_started);
    if (status == null || !status.ok()) begin
      original_status = status;
      if (original_status == null)
        original_status = bad("device write returned null status");
      if (!backend_write_started) begin
        finish_device_producer_cancel(attachment, reservation, pending,
                                      original_status,
                                      "device publish write preflight", status);
      end
      else begin
        local_status = copy_publish_status_into(original_status,
                                                 pending.failure_status);
        if (local_status == null || !local_status.ok()) begin
          pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
          pending.failure_status.message =
            "device write failure status copy failed";
        end
        enter_device_publish_recovery(attachment, pending, original_status,
                                      RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                      recovery_status);
        status = recovery_status;
      end
      return;
    end
    if (!backend_write_started) begin
      original_status = bad("device write did not enter backend");
      enter_device_publish_recovery(attachment, pending, original_status,
                                    RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                    recovery_status);
      status = recovery_status;
      return;
    end
    status = attachment.access.read(offset, attachment.entry_size, readback);
    if (status == null || !status.ok() || readback.size() != data.size()) begin
      if (status == null)
        status = bad("device publish readback returned null status",
                     RDMA_SC_DMA_TRANSLATION);
      else if (status.ok())
        status = bad("device publish readback length differs",
                     RDMA_SC_DMA_TRANSLATION);
      original_status = status;
      local_status = copy_publish_status_into(original_status,
                                               pending.failure_status);
      if (local_status == null || !local_status.ok()) begin
        pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
        pending.failure_status.message =
          "device readback failure status copy failed";
      end
      enter_device_publish_recovery(attachment, pending, original_status,
                                    RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                    recovery_status);
      status = recovery_status;
      return;
    end
    foreach (readback[i]) begin
      if (readback[i] !== data[i]) begin
        original_status = bad("device publish readback bytes differ",
                             RDMA_SC_DMA_TRANSLATION);
        local_status = copy_publish_status_into(original_status,
                                                 pending.failure_status);
        if (local_status == null || !local_status.ok()) begin
          pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
          pending.failure_status.message =
            "device readback mismatch status copy failed";
        end
        enter_device_publish_recovery(attachment, pending, original_status,
                                      RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                      recovery_status);
        status = recovery_status;
        return;
      end
    end
    status = attachment.runtime.commit_device_producer(reservation);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("device producer commit returned null status",
                     RDMA_SC_INVALID_STATE);
      original_status = status;
      local_status = copy_publish_status_into(original_status,
                                               pending.failure_status);
      if (local_status == null || !local_status.ok()) begin
        pending.failure_status.code = RDMA_SC_RECOVERY_REQUIRED;
        pending.failure_status.message =
          "device producer commit failure status copy failed";
      end
      enter_device_publish_recovery(attachment, pending, original_status,
                                    RDMA_QUEUE_MMIO_NOT_APPLICABLE,
                                    recovery_status);
      status = recovery_status;
      return;
    end
    candidate.queue_h = detached_queue;
    candidate.index = reservation.index;
    candidate.wrap = reservation.wrap;
    candidate.image = detached_image;
    candidate.occupancy_valid = 1'b0;
    local_status = attachment.runtime.query_occupancy(occupancy);
    if (local_status != null && local_status.ok()) begin
      candidate.occupancy_valid = 1'b1;
      candidate.occupancy = occupancy;
    end
    else candidate.occupancy = 0;
    candidate.status.code = RDMA_SC_OK;
    candidate.status.message = "device publish committed";
    result = candidate;
    status = rdma_status::success();
  endtask

  // 功能：query_runtime_producer_polarity 查询设备生产 ring 当前 producer owner 位。
  // 输入/输出及副作用：queue_h、kind 为输入，polarity 为输出；仅读取 runtime 快照，不推进游标或写入后端。
  // 失败边界：句柄、attachment 或 runtime 不完整，或 runtime 非设备生产 ring 时返回明确错误并保持 polarity=0。
  function rdma_status query_runtime_producer_polarity(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind,
    output bit polarity
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;

    polarity = 1'b0;
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("producer polarity lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    if (attachment == null || attachment.runtime == null)
      return bad("producer polarity attachment is incomplete",
                 RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_expected_producer_polarity(polarity);
    return status == null ?
      bad("producer polarity query returned null status",
          RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：query_runtime_pending 返回 runtime 或 engine-owned unclaimed 表中的
  //   detached recovery evidence，使调用方可审计而不能改写内部恢复对象。
  // 输入/输出及副作用：queue_h、kind 为输入，pending 为输出；函数只复制 evidence，
  //   不改变 runtime、unclaimed 表、reservation 或任何 backing ownership。
  // 失败边界：句柄或请求 kind 无效、unclaimed 配对不完整、快照复制失败、runtime
  //   不存在或无 pending 时返回非成功 status 且 pending 保持 null，原 evidence
  //   不会被删除或通过错误 kind 泄露。
  function rdma_status query_runtime_pending(
    rdma_handle queue_h, rdma_queue_runtime_kind_e kind,
    output rdma_queue_pending_operation pending
  );
    rdma_queue_data_attachment attachment;
    rdma_status status;
    string key;

    pending = null;
    if (queue_h == null)
      return bad("pending query queue handle is null", RDMA_SC_INVALID_ARGUMENT);
    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok())
      return status == null ?
        bad("pending attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
    key = identity_key(queue_h);
    if (key != "" && (unclaimed_device_recoveries.exists(key) ||
                       unclaimed_recovery_attachments.exists(key))) begin
      if (!unclaimed_device_recoveries.exists(key) ||
          unclaimed_device_recoveries[key] == null ||
          !unclaimed_recovery_attachments.exists(key) ||
          unclaimed_recovery_attachments[key] == null)
        return bad("unclaimed pending evidence pair is incomplete",
                   RDMA_SC_RECOVERY_REQUIRED);
      status = clone_unclaimed_device_pending(unclaimed_device_recoveries[key],
                                              pending);
      return status == null ?
        bad("unclaimed pending snapshot returned null status",
            RDMA_SC_RESOURCE_EXHAUSTED) : status;
    end
    if (attachment == null || attachment.runtime == null)
      return bad("pending attachment is incomplete", RDMA_SC_INVALID_STATE);
    status = attachment.runtime.query_pending(pending);
    return status == null ?
      bad("pending query returned null status", RDMA_SC_INVALID_STATE) : status;
  endfunction

  // 功能：publish_cqe 校验 CQE 的 Function/QP/WQE authority，随后经公共设备生产
  //   pipeline 写入 CQ backing 并提交 producer cursor。
  // 输入/输出及副作用：cq_h、model 为只读输入，result/status 为输出；成功时仅
  //   写入 CQ host-memory 并更新 CQ occupancy，不修改 model、不发 producer doorbell。
  // 失败边界：任一身份、路由、polarity、编码或事务失败均不发布 result；reservation
  //   后的纯失败尝试 cancel，写入 backend 后的失败必须进入 recovery。
  task publish_cqe(
    rdma_handle cq_h, rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_attachment wqe_attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot reservation;
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_cqe_codec cqe_codec;
    rdma_hw_image image;
    rdma_status original_status;
    bit expected_polarity;

    result = null;
    status = null;
    reservation = null;
    link = null;
    wqe_attachment = null;
    image = null;

    status = ensure_handle(cq_h, RDMA_RESOURCE_CQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    status = lookup_attachment(cq_h, RDMA_QUEUE_RUNTIME_CQ, attachment);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQ publish attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (attachment == null || attachment.runtime == null ||
        attachment.access == null || attachment.entry_size == 0) begin
      status = bad("CQ publish attachment is incomplete", RDMA_SC_INVALID_STATE);
      return;
    end
    status = validate_publish_route_epoch(attachment);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQ publish route validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (model == null || model.qp_h == null || model.status == null) begin
      status = bad("CQE model authority/status is incomplete");
      return;
    end
    status = model.validate();
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE model validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    if (binding == null || model.qp_h.function_uid != binding.function_uid)
      begin
        status = bad("CQE QP Function UID does not match CQ attachment");
        return;
      end
    if (model.qp_h.generation != binding.generation) begin
      status = bad("CQE QP generation is stale", RDMA_SC_STALE_GENERATION);
      return;
    end
    status = find_qp_link_for_cq(cq_h, model.qpn, model.rq_cqe, link);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE QP route lookup returned null status", RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (link == null || link.qp_h == null ||
        !link.qp_h.same_instance(model.qp_h)) begin
      status = bad("CQE QP authority does not match CQ route",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (link.local_qp_id > 18'h3ffff) begin
      status = bad("CQE QPN cannot represent attached QP", RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    if (model.rq_cqe) begin
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
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE WQE attachment lookup returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (wqe_attachment == null || wqe_attachment.runtime == null) begin
      status = bad("CQE WQE attachment is incomplete", RDMA_SC_INVALID_STATE);
      return;
    end
    status = wqe_attachment.runtime.validate_release_range(
      model.wqe_index, model.wqe_wrap);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("CQE WQE release validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end

    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQ device reservation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    expected_polarity = attachment.runtime.expected_producer_polarity(
      reservation);
    if (model.polarity !== expected_polarity) begin
      original_status = bad("CQE producer polarity does not match reservation");
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE polarity", status);
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CQE,
      object_type:"cqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE codec lookup returned null status",
                     RDMA_SC_CODEC_ERROR);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE codec lookup", status);
      return;
    end
    if (!$cast(cqe_codec, base_codec) || cqe_codec == null) begin
      original_status = bad("CQ registry codec type mismatch",
                            RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE codec cast", status);
      return;
    end
    // 使用局部 image 接收无状态编码结果，避免在 commit 前把半成品写入 result。
    // 编码器只读取 entry_size，本次调用不会修改 registry 中共享的 active_bytes。
    status = cqe_codec.encode_with_entry_bytes(model, attachment.entry_size,
                                               image);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CQE encode returned null status", RDMA_SC_CODEC_ERROR);
      original_status = status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE encode", status);
      return;
    end
    if (image == null) begin
      original_status = bad("CQE encoder returned no image",
                            RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CQE image", status);
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 功能：publish_ceqe 在 CEQ backing 发布一个已经由 CQ producer 提交的通知，
  //   使 CEQ poll 只负责 route CQ 而不会替 CQ 生成或消费 completion。
  // 输入/输出及副作用：ceq_h、model 为只读输入，result/status 为输出；成功时写入
  //   16B CEQ ring 并推进 CEQ producer，不修改 CQ cursor、model 或 WQE ledger。
  // 失败边界：CEQ/CQ/QP authority、generation、已提交 PI、16 位 PI、polarity、
  //   full ring 或 codec 失败时 result 保持 null；预写失败取消 reservation，写后失败
  //   保留 pending/recovery evidence，不能改变 backing、cursor 或 committed occupancy。
  task publish_ceqe(
    rdma_handle ceq_h,
    rdma_hw_ceqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_attachment cq_attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot reservation;
    rdma_handle routed_cq_h;
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_ceqe_codec ceqe_codec;
    rdma_hw_image image;
    rdma_status original_status;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit expected_polarity;

    result = null;
    status = null;
    attachment = null;
    cq_attachment = null;
    link = null;
    reservation = null;
    routed_cq_h = null;
    image = null;
    producer_index = 0;
    consumer_index = 0;
    producer_wrap = 1'b0;
    consumer_wrap = 1'b0;

    status = ensure_handle(ceq_h, RDMA_RESOURCE_CEQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CEQE handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    status = lookup_attachment(ceq_h, RDMA_QUEUE_RUNTIME_CEQ, attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE attachment lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    status = validate_publish_route_epoch(attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (model == null || model.cq_h == null) begin
      status = bad("CEQE model CQ authority is incomplete");
      return;
    end
    status = model.validate();
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE model validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (binding == null || model.cq_h.function_uid != binding.function_uid ||
        model.cq_h.generation != binding.generation) begin
      status = bad("CEQE CQ Function/generation authority is stale",
                   model.cq_h != null && binding != null &&
                   model.cq_h.generation != binding.generation ?
                   RDMA_SC_STALE_GENERATION : RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    status = find_cq_handle_for_local_id(model.cqn, routed_cq_h);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ route lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (routed_cq_h == null || !routed_cq_h.same_instance(model.cq_h)) begin
      status = bad("CEQE CQ authority does not match attached route",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    status = lookup_attachment(routed_cq_h, RDMA_QUEUE_RUNTIME_CQ,
                               cq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE routed CQ attachment is null",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    status = validate_publish_route_epoch(cq_attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    // 设计说明：CEQE 的核心 route authority 是 cqn/cq_h；qpn=0 表示通知不绑定
    // 某个 QP，属于协议允许的通用 CQ 通知。只有调用方显式给出非零 qpn 时才要求
    // 它命中当前 Function 已 attach 的唯一 QP link，不能把 0 当成隐式 QP。
    if (model.qpn != 0) begin
      status = find_qp_link_for_local_id(model.qpn, link);
      if (status == null || !status.ok()) begin
        status = status == null ? bad("CEQE QP route lookup returned null status",
                                      RDMA_SC_INVALID_STATE) : status;
        return;
      end
      if (link == null ||
          ((link.send_cq_h == null ||
            !link.send_cq_h.same_instance(routed_cq_h)) &&
           (link.recv_cq_h == null ||
            !link.recv_cq_h.same_instance(routed_cq_h)))) begin
        status = bad("CEQE QPN is not associated with routed CQ",
                     RDMA_SC_INVALID_STATE);
        return;
      end
    end
    status = query_runtime_cursors(routed_cq_h, RDMA_QUEUE_RUNTIME_CQ,
                                   producer_index, producer_wrap,
                                   consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("CEQE CQ cursor query returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (producer_index > 16'hffff) begin
      status = bad("CEQE CQ producer index cannot fit in 16 bits",
                   RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    if (model.cq_pi != producer_index[15:0] ||
        model.cq_pi_wrap != producer_wrap) begin
      status = bad("CEQE CQ producer cursor is not committed cursor",
                   RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("CEQE device reservation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    expected_polarity = attachment.runtime.expected_producer_polarity(
      reservation);
    if (model.valid !== expected_polarity) begin
      original_status = bad("CEQE producer polarity does not match reservation");
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE polarity", status);
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_CEQE,
      object_type:"ceqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      original_status = status == null ?
        bad("CEQE codec lookup returned null status", RDMA_SC_CODEC_ERROR) : status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE codec lookup", status);
      return;
    end
    if (!$cast(ceqe_codec, base_codec) || ceqe_codec == null) begin
      original_status = bad("CEQE registry codec type mismatch", RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE codec cast", status);
      return;
    end
    status = ceqe_codec.encode(model, image);
    if (status == null || !status.ok() || image == null ||
        image.length != 16 || image.bytes.size() != 16) begin
      original_status = status == null ?
        bad("CEQE encode returned null status", RDMA_SC_CODEC_ERROR) :
        (!status.ok() ? status : bad("CEQE codec did not return fixed 16B image",
                                     RDMA_SC_CODEC_ERROR));
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "CEQE encode", status);
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

  // 功能：publish_aeqe 在 AEQ backing 发布指向已 attached QP 的异常事件，供
  //   AEQ poll 解码并以同一 target identity 交付给上层。
  // 输入/输出及副作用：aeq_h、model 为只读输入，result/status 为输出；成功写入
  //   固定 16B AEQ ring 并推进 producer，不取得 target_h、QP 或 image 所有权。
  // 失败边界：AEQ/QP authority、零 QPN、generation、route、polarity、full 或
  //   codec 失败时 result 为空且不改 committed state；reservation 后失败遵循共享
  //   cancel/recovery 事务，绝不留下可见的半条 AEQE。
  task publish_aeqe(
    rdma_handle aeq_h,
    rdma_hw_aeqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot reservation;
    rdma_codec_key key;
    rdma_codec_base base_codec;
    rdma_hw_aeqe_codec aeqe_codec;
    rdma_hw_image image;
    rdma_status original_status;
    bit expected_polarity;

    result = null;
    status = null;
    attachment = null;
    link = null;
    reservation = null;
    image = null;
    status = ensure_handle(aeq_h, RDMA_RESOURCE_AEQ);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE handle validation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    status = lookup_attachment(aeq_h, RDMA_QUEUE_RUNTIME_AEQ, attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE attachment lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    status = validate_publish_route_epoch(attachment);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE route validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (model == null || model.target_h == null || model.qpn == 0) begin
      status = bad("AEQE model target/QPN authority is incomplete",
                   RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    status = model.validate();
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE model validation returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (model.target_h.kind != RDMA_RESOURCE_QP) begin
      status = bad("AEQE target is not a QP", RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    if (binding == null) begin
      status = bad("AEQE Function binding is unavailable",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    if (model.target_h.function_uid != binding.function_uid) begin
      status = bad("AEQE target Function UID does not match AEQ attachment",
                   RDMA_SC_INVALID_ARGUMENT);
      return;
    end
    if (model.target_h.generation != binding.generation) begin
      status = bad("AEQE target generation is stale",
                   RDMA_SC_STALE_GENERATION);
      return;
    end
    status = find_qp_link_for_local_id(model.qpn, link);
    if (status == null || !status.ok()) begin
      status = status == null ? bad("AEQE QP route lookup returned null status",
                                    RDMA_SC_INVALID_STATE) : status;
      return;
    end
    if (link == null || link.qp_h == null ||
        !link.qp_h.same_instance(model.target_h)) begin
      status = bad("AEQE target authority does not match QPN route",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    status = attachment.runtime.reserve_device_producer(reservation);
    if (status == null || !status.ok()) begin
      if (status == null)
        status = bad("AEQE device reservation returned null status",
                     RDMA_SC_INVALID_STATE);
      return;
    end
    expected_polarity = attachment.runtime.expected_producer_polarity(
      reservation);
    if (model.valid !== expected_polarity) begin
      original_status = bad("AEQE producer polarity does not match reservation");
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "AEQE polarity", status);
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_AEQE,
      object_type:"aeqe", variant:"default", opcode:8'h00};
    status = registry.lookup(key, base_codec);
    if (status == null || !status.ok()) begin
      original_status = status == null ?
        bad("AEQE codec lookup returned null status", RDMA_SC_CODEC_ERROR) : status;
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "AEQE codec lookup", status);
      return;
    end
    if (!$cast(aeqe_codec, base_codec) || aeqe_codec == null) begin
      original_status = bad("AEQE registry codec type mismatch", RDMA_SC_CODEC_ERROR);
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "AEQE codec cast", status);
      return;
    end
    status = aeqe_codec.encode(model, image);
    if (status == null || !status.ok() || image == null ||
        image.length != 16 || image.bytes.size() != 16) begin
      original_status = status == null ?
        bad("AEQE encode returned null status", RDMA_SC_CODEC_ERROR) :
        (!status.ok() ? status : bad("AEQE codec did not return fixed 16B image",
                                     RDMA_SC_CODEC_ERROR));
      finish_device_producer_cancel(attachment, reservation, null,
                                    original_status, "AEQE encode", status);
      return;
    end
    write_commit_device_entry(attachment, reservation, image, result, status);
  endtask

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

  // 功能：create_attachment 为一个 queue runtime 建立借用的 backing access、冻结
  //   route/epoch 并激活 attachment，使后续 post/poll/publish 只消费同一 authority。
  // 输入/输出及副作用：queue_h、kind、role、queue_ref/qp_ref、cursor、geometry 和
  //   transport 为输入；成功时向 attachments 插入新记录，但不取得外部 backing 所有权。
  // 失败边界：重复 key、几何/依赖不完整、access/runtime 配置、route/epoch 校验或
  //   activate 失败时返回非成功 status，attachments 不发布半成品记录。
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
    rdma_function_identity identity;
    rdma_status status;
    string key;

    if (queue_h == null || depth == 0)
      return bad("queue attachment geometry is invalid");
    key = attachment_key(queue_h, kind);
    if (attachments.exists(key))
      return bad("queue is already attached", RDMA_SC_INVALID_STATE);
    if (binding == null || host_mem == null)
      return bad("queue attachment dependencies are incomplete",
                 RDMA_SC_INVALID_STATE);
    access = rdma_queue_backing_access::type_id::create(
      $sformatf("queue_access_%0d", attachments.num()));
    status = access.configure(binding.make_handle(), host_mem);
    if (status == null || !status.ok())
      return status == null ? bad("queue backing access configure returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    if (qp_ref != null)
      status = access.attach_qp(qp_ref);
    else
      status = access.attach_queue(queue_ref);
    if (status == null || !status.ok())
      return status == null ? bad("queue backing access attach returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    runtime = rdma_queue_runtime::type_id::create(
      $sformatf("queue_runtime_%0d", attachments.num()));
    status = runtime.configure(queue_h, kind, depth, producer_index,
                               producer_wrap, consumer_index, consumer_wrap,
                               host_produced, initial_polarity);
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime configure returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    // runtime 必须在激活前锁存完整 Function route/epoch；后续 publish 与
    // recovery 只读取这个快照，不能依赖可变 binding 或默认 route。
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return bad("queue attachment Function identity is unavailable",
                 RDMA_SC_INVALID_STATE);
    status = identity.validate();
    if (status == null || !status.ok())
      return status == null ? bad("queue attachment identity validation returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    status = runtime.set_route_epoch(identity.route_key(), identity.reset_epoch);
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime route/epoch setup returned null",
                                  RDMA_SC_INVALID_STATE) : status;
    status = runtime.activate();
    if (status == null || !status.ok())
      return status == null ? bad("queue runtime activate returned null",
                                  RDMA_SC_INVALID_STATE) : status;
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
    if (qp.qp_plan.sq_sgb_ref != null) begin
      link.sq_sgb_access = rdma_queue_backing_access::type_id::create("sq_sgb_access");
      link.sq_sgb_ref = qp.qp_plan.sq_sgb_ref;
      status = link.sq_sgb_access.configure(binding.make_handle(), host_mem);
      if (!status.ok()) return status;
      status = link.sq_sgb_access.attach_qp(qp.qp_plan.sq_sgb_ref);
      if (!status.ok()) return status;
    end
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

  // 功能：在 rdma_queue_data_engine 中，sqe_authority_status 对发送请求的
  // QP、URC completion QP、MR/MW 和 FLUSH authority 做运行时身份及 attach
  // 校验，确保已通过语义模型的请求仍绑定到当前 queue-data route。
  // 输入/输出及副作用：request、link 为输入；函数只读取 request 快照、QP
  // link 和 qp_links 索引，返回 rdma_status，不预留槽位、不修改账本或外部资源。
  // 失败/边界：request/link/快照为空、QP route 不一致、owner/UID/generation
  // 失配、URC completion QP 未 attach、control authority kind 错误或 FLUSH
  // authority 非 posting QP 时返回对应错误码；失败路径保持 producer 游标不变。
  protected function rdma_status sqe_authority_status(
    rdma_post_send_req request,
    rdma_queue_data_qp_link link
  );
    rdma_status status;
    rdma_handle reference;
    rdma_queue_data_qp_link completion_link;
    string completion_key;

    if (request == null || link == null || link.qp_h == null)
      return bad("SQE authority request or QP link is null",
                 RDMA_SC_INVALID_STATE);
    status = ensure_handle(request.qp_h, RDMA_RESOURCE_QP);
    if (!status.ok()) return status;
    if (!link.qp_h.same_instance(request.qp_h))
      return bad("SQE posting QP route identity does not match request",
                 RDMA_SC_INVALID_STATE);
    // QP 的 transport 是 CMQ 创建阶段冻结的 wire/profile authority；请求
    // 中的 transport 只能复述该值，不能借同一 SQ 句柄切换到另一协议。若
    // 允许继续，会在 codec 阶段把 RC ring 误编码成 UD/URC，造成网络头和
    // QP context 不一致，因此必须在 reservation 之前 fail-closed。
    if (request.transport != link.transport)
      return bad("SQE request transport does not match bound QP",
                 RDMA_SC_INVALID_STATE);

    reference = request.owner == null ? request.qp_h : request.owner;
    if (request.owner != null) begin
      status = rdma_handle_owner_status(request.qp_h, request.owner);
      if (!status.ok()) return status;
    end

    case (request.opcode)
      RDMA_WR_REG_MR: begin
        status = rdma_handle_authority_status(
          request.mr_h, RDMA_RESOURCE_MR, reference, "REG_MR authority");
        if (!status.ok()) return status;
      end
      RDMA_WR_BIND_MW: begin
        status = rdma_handle_authority_status(
          request.mr_h, RDMA_RESOURCE_MR, reference,
          "BIND_MW MR authority");
        if (!status.ok()) return status;
        status = rdma_handle_authority_status(
          request.mw_h, RDMA_RESOURCE_MW, reference,
          "BIND_MW MW authority");
        if (!status.ok()) return status;
      end
      RDMA_WR_FLUSH: begin
        status = rdma_handle_authority_status(
          request.authority_h, RDMA_RESOURCE_QP, reference,
          "FLUSH authority");
        if (!status.ok()) return status;
        if (!request.authority_h.same_instance(link.qp_h))
          return bad("FLUSH authority is detached from the posting QP",
                     RDMA_SC_INVALID_STATE);
      end
      default: begin end
    endcase

    if (request.transport == RDMA_TRANSPORT_URC) begin
      status = rdma_handle_authority_status(
        request.completion_qp_h, RDMA_RESOURCE_QP, reference,
        "URC completion QP");
      if (!status.ok()) return status;
      completion_key = identity_key(request.completion_qp_h);
      if (!qp_links.exists(completion_key) ||
          qp_links[completion_key] == null)
        return bad("URC completion QP is not attached", RDMA_SC_INVALID_STATE);
      completion_link = qp_links[completion_key];
      if (completion_link.qp_h == null ||
          !completion_link.qp_h.same_instance(request.completion_qp_h))
        return bad("URC completion QP route identity is stale",
                   RDMA_SC_INVALID_STATE);
      if (completion_link.transport != RDMA_TRANSPORT_URC)
        return bad("URC completion QP transport does not match request",
                   RDMA_SC_INVALID_STATE);
    end
    else if (request.completion_qp_h != null) begin
      return bad("completion QP is only valid for URC send");
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_data_engine 中，make_sqe 将发送请求投影为待编码的硬件 SQE 模型，复制传输、authority、原子操作和 SGB 相关字段，并绑定 reservation 的 index/wrap。
  // 输入/输出及副作用：request（输入）提供 qp_h、mr_h、mw_h、authority_h、SGE、compare_value、swap_add_value、sgb_iova 等语义快照；link/cursor（输入）提供 QP route 与槽位；model（输出）发布 detached SQE 模型，不取得调用方资源所有权。
  // 失败/边界：request、link 或 cursor 为空、SGE 含 null、URC 缺少 completion_qp_h、authority kind 不满足请求语义或模型校验失败时返回错误；失败路径不发布可提交模型，也不自动推进 PI。
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
    status = sqe_authority_status(request, link);
    if (!status.ok()) return status;
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
    // 硬件模型只保存 MR/MW 的 profile object-ID；完整句柄（含 kind、
    // Function UID 和 generation）仍由 request snapshot 保留，供 ledger/
    // recovery 做 authority 校验，不能用截断 ID 代替生命周期证据。
    model.mr_handle_id = request.mr_h == null ? 0 : request.mr_h.object_id;
    model.mw_handle_id = request.mw_h == null ? 0 : request.mw_h.object_id;
    model.sge_num = request.sges.size();
    foreach (request.sges[i]) begin
      if (request.sges[i] == null)
        return bad("SQE request has a null SGE");
      cloned_sge = rdma_sge::type_id::create("sqe_sge");
      cloned_sge.copy(request.sges[i]); model.sges.push_back(cloned_sge);
    end
    if (request.opcode inside {RDMA_WR_ATOMIC_CMP_SWAP,
                               RDMA_WR_ATOMIC_FETCH_ADD}) begin
      // 原子 fixed body 的 local IOVA/lkey 来自唯一 local SGE，而
      // compare/swap 值来自请求语义；四个字段必须一起投影，避免 codec
      // 看到默认零值后误编码一个可提交但语义错误的 WQE。
      model.atomic_local_iova = model.sges[0].iova;
      model.atomic_local_lkey = model.sges[0].lkey;
      model.atomic_compare = request.compare_value;
      model.atomic_value = request.swap_add_value;
    end
    case (request.transport)
      RDMA_TRANSPORT_RC: begin
        rc = rdma_sqe_rc_ext::type_id::create("sqe_rc");
        rc.remote_addr = request.remote_addr; rc.rkey = request.rkey;
        rc.remote_access_valid = request.remote_access_valid;
        rc.rkey_valid = request.rkey_valid;
        rc.compare_value = request.compare_value;
        rc.swap_add_value = request.swap_add_value;
        model.transport_ext = rc;
        model.rkey = request.rkey; model.remote_va = request.remote_addr;
      end
      RDMA_TRANSPORT_UD: begin
        ud = rdma_sqe_ud_ext::type_id::create("sqe_ud");
        ud.destination_qpn = request.destination_qpn; ud.qkey = request.qkey;
        ud.address_vector_id = request.address_vector_id;
        // AV 是 UD SQE 校验所需的完整 authority 对象；仅复制 ID 会让
        // request.validate() 通过但在硬件模型校验阶段丢失 AV 证据。
        ud.address_vector = request.address_vector;
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

  // 功能：write_sgb_and_verify 为 SQE 的外置 SGB 构造 512-byte 大端槽位并完成 host-memory 写入/回读校验。
  // 输入/输出及副作用：link/model 为输入；link.sq_sgb_access 指向借用的 QP SGB backing，函数只写入该 backing 并返回状态。
  // 失败/边界：缺少 SGB authority、IOVA 未按 512 对齐或超出 mapping 范围、后端写入/回读失败时返回 DMA/INVALID_STATE，调用方不得推进 PI。
  protected function rdma_status write_sgb_and_verify(
      rdma_queue_data_qp_link link, rdma_hw_sqe_model model,
      rdma_queue_cursor_snapshot cursor);
    byte data[]; byte readback[]; rdma_status status; bit [31:0] len; bit [31:0] key; bit [63:0] va; longint unsigned sgb_offset;
    if (link == null || model == null || cursor == null || link.sq_sgb_access == null)
      return bad("SQE SGB backing authority is unavailable", RDMA_SC_INVALID_STATE);
    if (model.sgb_iova.value == 0 || (model.sgb_iova.value & 64'h1ff) != 0)
      return bad("SQE SGB IOVA is not 512-byte aligned", RDMA_SC_DMA_TRANSLATION);
    if (link.sq_sgb_ref == null || link.sq_sgb_ref.mapping == null)
      return bad("SQE SGB IOVA is outside backing authority", RDMA_SC_DMA_TRANSLATION);
    data = new[512]; foreach (data[i]) data[i] = 0;
    begin
      longint unsigned logical_offset, covered, effective_iova;
      bit resolved;
      logical_offset = cursor.index * 512; covered = link.sq_sgb_ref.length; resolved = 1'b0;
      if (logical_offset + 512 > covered) begin
        foreach (link.sq_sgb_ref.additional_segments[k]) covered += link.sq_sgb_ref.additional_segments[k].length;
      end
      if (logical_offset + 512 > covered) return bad("SQE SGB slot exceeds logical coverage", RDMA_SC_DMA_TRANSLATION);
      if (logical_offset < link.sq_sgb_ref.length) effective_iova = link.sq_sgb_ref.mapping.iova.value + link.sq_sgb_ref.mapping_offset + logical_offset;
      else begin
        longint unsigned base;
        base = link.sq_sgb_ref.length;
        foreach (link.sq_sgb_ref.additional_segments[k]) begin
          if (!resolved && logical_offset >= base && logical_offset < base + link.sq_sgb_ref.additional_segments[k].length) begin
            effective_iova = link.sq_sgb_ref.additional_segments[k].mapping.iova.value + link.sq_sgb_ref.additional_segments[k].mapping_offset + (logical_offset-base); resolved = 1'b1;
          end
          base += link.sq_sgb_ref.additional_segments[k].length;
        end
      end
      if (!resolved && logical_offset < link.sq_sgb_ref.length) resolved = 1'b1;
      if (!resolved || model.sgb_iova.value != effective_iova) return bad("SQE SGB IOVA does not resolve to backing slot", RDMA_SC_DMA_TRANSLATION);
    end
    if (model.inline_data) begin
      if (model.payload.size() > 512) return bad("SQE inline SGB exceeds 512 bytes");
      foreach (model.payload[i]) data[i] = model.payload[i];
    end else begin
      if (model.sges.size() > 32) return bad("SQE SGB descriptor count exceeds 32");
      foreach (model.sges[i]) begin
        if (model.sges[i] == null || model.sges[i].length == 0) return bad("SQE SGB descriptor is invalid");
        len = model.sges[i].length == 32'h8000_0000 ? 0 : model.sges[i].length; key = model.sges[i].lkey; va = model.sges[i].iova.value;
        for (int j=0;j<4;j++) data[i*16+j] = len[31-j*8 -: 8];
        for (int j=0;j<4;j++) data[i*16+4+j] = key[31-j*8 -: 8];
        for (int j=0;j<8;j++) data[i*16+8+j] = va[63-j*8 -: 8];
      end
    end
    sgb_offset = cursor.index * 512;
    status = link.sq_sgb_access.write(sgb_offset, data); if (!status.ok()) return status;
    status = link.sq_sgb_access.readback(sgb_offset, 512, readback); if (!status.ok()) return status;
    if (readback.size() != 512) return bad("SQE SGB readback is short", RDMA_SC_DMA_TRANSLATION);
    foreach (data[i]) if (readback[i] !== data[i]) return bad("SQE SGB readback mismatch", RDMA_SC_DMA_TRANSLATION);
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
    // 设计说明：resource manager 的 QP local ID 可宽于 CQE 的 18-bit qpn。
    // 精确 route 不存在时才识别低位投影相同的超宽 authority，让调用方在 encode
    // 前以完整 local_qp_id 返回 width 错误；绝不把该投影当作可发布的合法 QPN。
    if (link == null) begin
      foreach (qp_links[key]) begin
        candidate = qp_links[key];
        if (candidate == null || candidate.local_qp_id <= 18'h3ffff ||
            candidate.local_qp_id[17:0] != qpn)
          continue;
        if ((!rq_cqe && candidate.send_cq_h != null &&
             candidate.send_cq_h.same_instance(cq_h)) ||
            (rq_cqe && candidate.recv_cq_h != null &&
             candidate.recv_cq_h.same_instance(cq_h))) begin
          if (link != null)
            return bad("CQE projected QPN routes to multiple wide QPs",
                       RDMA_SC_INVALID_STATE);
          link = candidate;
        end
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
    rdma_handle runtime_queue_h;
    rdma_queue_runtime_kind_e runtime_kind;
    string key;
    string recovery_key;
    bit runtime_host_produced;
    bit runtime_initial_polarity;
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
    status = old_attachment.runtime.query_attachment_config(
      runtime_queue_h, runtime_kind, runtime_host_produced,
      runtime_initial_polarity);
    if (status == null || !status.ok() || runtime_queue_h == null ||
        old_attachment.queue_h == null ||
        !runtime_queue_h.same_instance(old_attachment.queue_h) ||
        runtime_kind != RDMA_QUEUE_RUNTIME_CQ || runtime_host_produced) begin
      if (status == null || status.ok())
        status = bad("CQ runtime attachment config is inconsistent",
                     RDMA_SC_INVALID_STATE);
      return finish_resize(status);
    end
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
      runtime_initial_polarity);
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
      1'b0, runtime_initial_polarity);
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
    // 功能：在进入通用 request.validate() 前把 transport/opcode 能力拒绝归类为
    //   UNSUPPORTED_OPCODE，确保调用方可以区分“组合不支持”和“字段形状错误”。
    // 输入/输出及副作用：snapshot.transport、snapshot.opcode（输入）；返回新的
    //   rdma_status，不修改队列 runtime、Host-memory、doorbell 或 pending ledger。
    // 失败/边界：未知 transport 或该 transport 不允许的 work opcode 均在此返回；
    //   合法组合继续执行后续 authority/SGE/资源校验。
    if (!rdma_send_opcode_valid_for_transport(snapshot.transport,
                                              snapshot.opcode)) begin
      status = rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                                 "work opcode is unsupported for transport");
      return;
    end
    status = snapshot.validate(); if (!status.ok()) return;
    status = lookup_attachment(snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                               attachment); if (!status.ok()) return;
    if (!qp_links.exists(identity_key(snapshot.qp_h)) ||
        qp_links[identity_key(snapshot.qp_h)] == null)
      begin status = bad("QP is not attached", RDMA_SC_INVALID_STATE); return; end
    link = qp_links[identity_key(snapshot.qp_h)];
    status = sqe_authority_status(snapshot, link);
    if (!status.ok()) return;
    status = attachment.runtime.reserve_producer(cursor);
    if (!status.ok()) return;
    status = make_sqe(snapshot, link, cursor, model);
    if (!status.ok()) return;
    status = encode_queue_model(model, RDMA_IMAGE_SQE, "sqe",
      snapshot.transport == RDMA_TRANSPORT_RC ? "rc" :
      snapshot.transport == RDMA_TRANSPORT_UD ? "ud" : "urc", image);
    if (!status.ok()) return;
    if (snapshot.sgb_iova.value != 0) begin
      status = write_sgb_and_verify(link, model, cursor);
      if (!status.ok()) begin
        pending = make_pending(cursor, snapshot.qp_h, RDMA_QUEUE_RUNTIME_SQ,
                              1'b1, longint'(cursor.index) * 64, image,
                              snapshot, snapshot.signaled);
        recovery_status = attachment.runtime.enter_recovery(pending, 1'b0);
        return;
      end
    end
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

  // 设计说明：仅当原事务确定没有到达 MMIO，或调用方已经明确确认可重放时才执行
  // detached transaction。所有副作用和 ledger transition 完成前，runtime 保持
  // RECOVERY_REQUIRED，防止同一 reservation 被并发消费。
  // 功能：replay_pending 按 pending 的 producer/device-producer/consumer 阶段重放
  //   必要写入、doorbell 或 cursor commit，并保持已完成阶段的幂等性。
  // 输入/输出及副作用：attachment、pending 为输入，status 为输出；可能访问 backing
  //   与 runtime recovery 状态，但不接管 attachment、mapping 或 pending 的所有权。
  // 失败边界：authority、cursor、route/epoch、readback 或下游提交不一致时返回明确
  //   非成功 status 并保留 pending；没有 caller confirmation 时不得重放 ambiguous MMIO。
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
    rdma_hw_sqe_model sgb_model;
    rdma_post_send_req pending_send;
    rdma_hw_model decoded_model;
    rdma_codec_base codec;
    rdma_codec_key codec_key;
    rdma_status local_status;
    byte data[];
    rdma_queue_pending_operation device_pending;
    rdma_queue_cursor_snapshot current_device_reservation;
    rdma_route_key_t runtime_route;
    rdma_reset_epoch_t runtime_epoch;
    bit runtime_route_valid;
    bit runtime_epoch_valid;
    bit reservation_valid;
    bit backend_write_started;
    byte readback[];

    status = null;
    if (attachment == null || pending == null) begin
      status = bad("pending recovery attachment/evidence is null",
                   RDMA_SC_INVALID_STATE);
      return;
    end
    status = pending_next_cursor(attachment, pending, next);
    if (!status.ok()) return;

    // 设计说明：device-produced CQ/CEQ/AEQ recovery 必须先于旧的 host producer/
    // consumer 分支处理。reservation 仍归 runtime 所有，image 只能经
    // DEVICE_WRITE 重放；write()/write_and_verify() 使用相反 DMA 方向，会把
    // 非法 CQ recovery 静默当作合法 host posting。
    if (pending.device_producer) begin
      device_pending = null;
      current_device_reservation = null;
      reservation_valid = 1'b0;
      runtime_route = '0;
      runtime_route_valid = 1'b0;
      runtime_epoch = '0;
      runtime_epoch_valid = 1'b0;
      status = attachment.runtime.query_pending(device_pending);
      if (status == null || !status.ok() || device_pending == null) begin
        status = status == null ?
          bad("device pending query returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      status = attachment.runtime.query_route_epoch(
        runtime_route, runtime_route_valid, runtime_epoch,
        runtime_epoch_valid);
      if (status == null || !status.ok() || !runtime_route_valid ||
          !runtime_epoch_valid) begin
        status = status == null ?
          bad("device recovery route/epoch query failed",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      status = attachment.runtime.query_device_reservation(
        reservation_valid, current_device_reservation);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("device recovery reservation query failed",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      if (!reservation_valid || current_device_reservation == null ||
          device_pending.queue_h == null || attachment.queue_h == null ||
          !device_pending.queue_h.same_instance(attachment.queue_h) ||
          device_pending.kind != attachment.kind ||
          !device_pending.device_producer || device_pending.cursor == null ||
          device_pending.next_cursor == null || device_pending.image == null ||
          device_pending.entry_size != attachment.entry_size ||
          device_pending.entry_size == 0 || !device_pending.route_valid ||
          !device_pending.epoch_valid ||
          device_pending.route != runtime_route ||
          device_pending.reset_epoch != runtime_epoch ||
          !attachment.runtime.reservation_matches(device_pending.cursor) ||
          current_device_reservation.index != device_pending.cursor.index ||
          current_device_reservation.wrap != device_pending.cursor.wrap ||
          device_pending.entry_offset !=
            longint'(device_pending.cursor.index) * device_pending.entry_size) begin
        status = bad("device pending authority or reservation is stale",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      status = copy_image_bytes(device_pending.image, data);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("device recovery image copy returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      readback = new[0];
      backend_write_started = 1'b0;
      status = attachment.access.write_device(
        device_pending.entry_offset, data, backend_write_started);
      if (status == null || !status.ok() || !backend_write_started) begin
        if (status == null)
          status = bad("device recovery write returned null status",
                       RDMA_SC_RECOVERY_REQUIRED);
        local_status = attachment.runtime.record_recovery_failure(
          backend_write_started ? RDMA_QUEUE_MMIO_NOT_APPLICABLE :
                                  RDMA_QUEUE_MMIO_NO_SUBMIT);
        if (local_status == null || !local_status.ok())
          status = bad("device recovery write evidence could not be retained",
                       RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      // 设计说明：preflight/cancel fallback 生成的 pending 可能尚未带有
      // attempted-write 位；只有 write_device 明确报告已进入 backend 后才标记，
      // 保证 retry 始终 fail-closed，不能将未尝试写入误判成可提交。
      if (!device_pending.device_write_attempted) begin
        local_status = attachment.runtime.mark_pending_device_write_attempted();
        if (local_status == null || !local_status.ok()) begin
          status = local_status == null ?
            bad("device recovery write-attempt evidence failed",
                RDMA_SC_RECOVERY_REQUIRED) : local_status;
          return;
        end
      end
      status = attachment.access.read(device_pending.entry_offset,
                                      device_pending.image.length, readback);
      if (status == null || !status.ok() ||
          readback.size() != data.size()) begin
        if (status == null)
          status = bad("device recovery read returned null status",
                       RDMA_SC_RECOVERY_REQUIRED);
        else if (status.ok())
          status = bad("device recovery readback length differs",
                       RDMA_SC_RECOVERY_REQUIRED);
        local_status = attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_NOT_APPLICABLE);
        if (local_status == null || !local_status.ok())
          status = bad("device recovery read failure evidence could not be retained",
                       RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      foreach (data[i]) begin
        if (readback[i] !== data[i]) begin
          status = bad("device recovery readback mismatch",
                       RDMA_SC_RECOVERY_REQUIRED);
          local_status = attachment.runtime.record_recovery_failure(
            RDMA_QUEUE_MMIO_NOT_APPLICABLE);
          if (local_status == null || !local_status.ok())
            status = bad("device recovery mismatch evidence could not be retained",
                         RDMA_SC_RECOVERY_REQUIRED);
          return;
        end
      end
      status = attachment.runtime.enable_recovery_commit();
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("device recovery commit gate returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      status = attachment.runtime.commit_device_producer(
        device_pending.cursor);
      if (status == null || !status.ok()) begin
        if (status == null)
          status = bad("device recovery producer commit returned null status",
                       RDMA_SC_RECOVERY_REQUIRED);
        local_status = attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_NOT_APPLICABLE);
        if (local_status == null || !local_status.ok())
          status = bad("device recovery commit evidence could not be retained",
                       RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      status = attachment.runtime.complete_recovery_retry();
      if (status == null)
        status = bad("device recovery completion returned null status",
                     RDMA_SC_RECOVERY_REQUIRED);
      return;
    end

    if (pending.producer) begin
      if (pending.image == null || pending.image.bytes.size() == 0) begin
        status = bad("producer recovery image is missing", RDMA_SC_INVALID_STATE);
        return;
      end
      // A known-no-MMIO producer failure is normally the queue write itself;
      // retry the detached SGB slot first (when present), then the exact
      // detached 64-byte WQE image before issuing its doorbell.  SGB bytes are
      // not part of pending.image, so silently omitting this write would make
      // a recovered SGE-SGB WQE reference stale/zero payload data.
      if (pending.kind == RDMA_QUEUE_RUNTIME_SQ &&
          pending.request_snapshot != null &&
          $cast(pending_send, pending.request_snapshot) &&
          pending_send.sgb_iova.value != 0) begin
        link = null;
        if (pending.queue_h != null &&
            qp_links.exists(identity_key(pending.queue_h)))
          link = qp_links[identity_key(pending.queue_h)];
        if (link == null) begin
          status = bad("SQ SGB recovery QP route is unavailable",
                       RDMA_SC_INVALID_STATE);
          return;
        end
        status = make_sqe(pending_send, link, pending.cursor, sgb_model);
        if (!status.ok()) return;
        status = write_sgb_and_verify(link, sgb_model, pending.cursor);
        if (!status.ok()) begin
          void'(attachment.runtime.record_recovery_failure(
            RDMA_QUEUE_MMIO_NO_SUBMIT));
          return;
        end
      end
      status = write_and_verify(attachment, pending.entry_offset,
                                pending.image);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_NO_SUBMIT));
        return;
      end
      submit_producer_doorbell(pending.queue_h, pending.kind, pending.cursor,
                               next,
                               pending.kind == RDMA_QUEUE_RUNTIME_SQ ?
                               pending.image : null,
                               attachment.local_id, db_result, status);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_AMBIGUOUS));
        return;
      end
      status = attachment.runtime.enable_recovery_commit();
      if (!status.ok()) return;
      status = attachment.runtime.commit_producer(
        pending.cursor, pending.request_snapshot, pending.wr_id,
        pending.signaled, pending.image);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_SUCCESS));
        return;
      end
      status = attachment.runtime.complete_recovery_retry();
      return;
    end

    // 设计阶段：consumer recovery 不重写队列条目。NO_SUBMIT 经显式确认后
    // 才重放 doorbell 并记录 SUCCESS；已有 SUCCESS 的 pending 绝不重发 MMIO，
    // 只续做尚未完成的 WQE release、CI 和 complete。doorbell 结果不确定时
    // 必须保留 AMBIGUOUS，不能把本地后续失败误写成“未提交”。
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
      if (pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS) begin
        submit_consumer_doorbell(attachment, next, db_result, status,
                                 db_mmio_maybe_submitted, link);
        if (!status.ok()) begin
          void'(attachment.runtime.record_recovery_failure(
            db_mmio_maybe_submitted ? RDMA_QUEUE_MMIO_AMBIGUOUS :
                                      RDMA_QUEUE_MMIO_NO_SUBMIT));
          return;
        end
        status = attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_SUCCESS);
        if (status == null || !status.ok()) return;
      end
      if (!pending.completion_released) begin
        status = wqe_attachment.runtime.match_and_release(cqe.wqe_index,
                                                           cqe.wqe_wrap,
                                                           released);
        if (!status.ok()) begin
          void'(attachment.runtime.record_recovery_failure(
            RDMA_QUEUE_MMIO_SUCCESS));
          return;
        end
      end
      if (!pending.consumer_committed) begin
        status = attachment.runtime.enable_recovery_commit();
        if (!status.ok()) return;
        status = attachment.runtime.commit_consumer(pending.cursor);
        if (!status.ok()) begin
          void'(attachment.runtime.record_recovery_failure(
            RDMA_QUEUE_MMIO_SUCCESS));
          return;
        end
      end
      if (!pending.completion_released) begin
        status = attachment.runtime.mark_pending_completion_released();
        if (status == null || !status.ok()) return;
      end
      status = attachment.runtime.complete_recovery_retry();
      return;
    end

    if (pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS) begin
      submit_consumer_doorbell(attachment, next, db_result, status,
                               db_mmio_maybe_submitted, no_route);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          db_mmio_maybe_submitted ? RDMA_QUEUE_MMIO_AMBIGUOUS :
                                    RDMA_QUEUE_MMIO_NO_SUBMIT));
        return;
      end
      status = attachment.runtime.record_recovery_failure(
        RDMA_QUEUE_MMIO_SUCCESS);
      if (status == null || !status.ok()) return;
    end
    if (!pending.consumer_committed) begin
      status = attachment.runtime.enable_recovery_commit();
      if (!status.ok()) return;
      status = attachment.runtime.commit_consumer(pending.cursor);
      if (!status.ok()) begin
        void'(attachment.runtime.record_recovery_failure(
          RDMA_QUEUE_MMIO_SUCCESS));
        return;
      end
    end
    status = attachment.runtime.complete_recovery_retry();
  endtask

  // 功能：recover_queue 定位 queue 的 claimed/unclaimed recovery，执行 abort，
  //   或把 caller-confirmed retry 先交给 runtime 授权，再重放尚未完成的事务阶段。
  // 输入输出及副作用：queue_h、action、caller_confirmed_no_submit（输入）选择
  //   recovery 对象与动作，status（输出）返回最终阶段结果；retry 可能访问 backing、
  //   doorbell 和 runtime ledger，abort 可能删除 attachment，但不接管外部 mapping。
  // 失败边界：句柄/证据不完整、非法 action、未确认 retry、AMBIGUOUS MMIO、
  //   runtime 授权/pending 查询返回 null 或非成功，以及 replay 任一阶段失败时保留可恢复
  //   evidence；只有 runtime enum gate 可以记录一次性 confirmation。
  task recover_queue(
    rdma_handle queue_h,
    rdma_queue_recovery_action_e action,
    bit caller_confirmed_no_submit,
    output rdma_status status
  );
    rdma_queue_data_attachment candidate;
    rdma_queue_data_attachment found;
    rdma_queue_pending_operation unclaimed_pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_runtime_state_e runtime_state;
    bit reservation_valid;
    string key;
    status = ensure_handle(queue_h, queue_h == null ? RDMA_RESOURCE_QP :
                           queue_h.kind);
    if (status == null || !status.ok()) begin
      status = status == null ?
        bad("recovery queue handle validation returned null status",
            RDMA_SC_INVALID_STATE) : status;
      return;
    end
    found = null;
    unclaimed_pending = null;
    reservation = null;
    reservation_valid = 1'b0;
    runtime_state = RDMA_QUEUE_RUNTIME_DETACHED;
    key = identity_key(queue_h);
    // 设计说明：runtime admission 失败时 evidence 由 engine 的 unclaimed 表保留。
    // retry/abort 必须先尝试把同一 detached pending 安装回原 attachment runtime；
    // 安装成功后 runtime 接管生命周期，表项才可成对删除，安装失败则保持证据不丢失。
    if (key != "" && (unclaimed_device_recoveries.exists(key) ||
                       unclaimed_recovery_attachments.exists(key))) begin
      if (!unclaimed_device_recoveries.exists(key) ||
          unclaimed_device_recoveries[key] == null ||
          !unclaimed_recovery_attachments.exists(key) ||
          unclaimed_recovery_attachments[key] == null) begin
        status = bad("unclaimed recovery evidence pair is incomplete",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      found = unclaimed_recovery_attachments[key];
      unclaimed_pending = unclaimed_device_recoveries[key];
      if (found.runtime == null || found.queue_h == null ||
          !found.queue_h.same_instance(queue_h)) begin
        status = bad("unclaimed recovery attachment is stale",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      status = admit_device_publish_recovery(found, unclaimed_pending);
      if (status == null || !status.ok()) begin
        // admission 仍失败时，retry 必须保留 engine-owned evidence。abort 可以
        // 仅在 runtime 仍 ACTIVE 且 reservation 与该 evidence 完全匹配时取消
        // reservation，然后 detach；这样不会遗留一个不可见的活动 attachment。
        if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
          status = found.runtime.query_device_reservation(reservation_valid,
                                                           reservation);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("unclaimed recovery reservation query returned null status",
                  RDMA_SC_RECOVERY_REQUIRED) : status;
            return;
          end
          status = found.runtime.query_state(runtime_state);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("unclaimed recovery state query returned null status",
                  RDMA_SC_RECOVERY_REQUIRED) : status;
            return;
          end
          if (reservation_valid && reservation != null &&
              runtime_state == RDMA_QUEUE_RUNTIME_ACTIVE &&
              unclaimed_pending.cursor != null &&
              reservation.index == unclaimed_pending.cursor.index &&
              reservation.wrap == unclaimed_pending.cursor.wrap) begin
            status = found.runtime.cancel_device_producer(reservation);
            if (status != null && status.ok()) begin
              status = detach(queue_h);
              if (status != null && status.ok()) begin
                unclaimed_device_recoveries.delete(key);
                unclaimed_recovery_attachments.delete(key);
              end
              return;
            end
          end
        end
        status = bad("unclaimed recovery admission is still unavailable",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      unclaimed_device_recoveries.delete(key);
      unclaimed_recovery_attachments.delete(key);
    end
    foreach (attachments[key]) begin
      candidate = attachments[key];
      if (candidate != null && candidate.queue_h != null &&
          candidate.queue_h.same_instance(queue_h) && candidate.runtime != null &&
          candidate.runtime.state == RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED) begin
        // 中文设计：unclaimed handoff 已选中同一个 attachment 时只接管一次；
        // 只有发现不同 runtime 也声明同一 queue recovery 时才按歧义拒绝。
        if (found != null && found != candidate) begin
          status = bad("queue has multiple pending recovery runtimes",
                       RDMA_SC_INVALID_STATE);
          return;
        end
        found = candidate;
      end
    end
    if (found == null) begin
      // cancel 前置路径在还没有完整 pending 时也可能返回 RECOVERY_REQUIRED。
      // 它只能显式 abort：再次 cancel 成功后 detach；retry 没有可重放 image，
      // 必须保持 fail-closed，而不是伪造一笔 publish。
      foreach (attachments[key]) begin
        candidate = attachments[key];
        if (candidate != null && candidate.queue_h != null &&
            candidate.queue_h.same_instance(queue_h) && candidate.runtime != null) begin
          status = candidate.runtime.query_device_reservation(reservation_valid,
                                                               reservation);
          if (status == null || !status.ok()) begin
            status = status == null ?
              bad("reservation-only recovery query returned null status",
                  RDMA_SC_RECOVERY_REQUIRED) : status;
            return;
          end
          if (reservation_valid && reservation != null) begin
            if (action != RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
              status = bad("reservation-only recovery cannot retry without image",
                           RDMA_SC_RECOVERY_REQUIRED);
              return;
            end
            status = candidate.runtime.cancel_device_producer(reservation);
            if (status == null || !status.ok()) begin
              status = bad("reservation-only recovery abort could not cancel",
                           RDMA_SC_RECOVERY_REQUIRED);
              return;
            end
            status = detach(queue_h);
            return;
          end
        end
      end
      status = bad("queue has no pending recovery", RDMA_SC_INVALID_STATE);
      return;
    end
    if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH) begin
      status = found.runtime.abort_recovery();
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("runtime recovery abort returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      // 中文设计：caller 选择 abort 后删除 data-engine attachment，使借用的
      // backing capability 与 QP route metadata 一并失效；lifecycle owner 仍持有
      // DMA mapping，本层不能越权释放外部资源。
      status = detach(queue_h);
      return;
    end
    if (action != RDMA_QUEUE_RECOVERY_RETRY_PENDING) begin
      status = bad("recovery action is invalid");
      return;
    end
    if (!caller_confirmed_no_submit) begin
      status = bad("retry requires caller confirmation");
      return;
    end
    begin
      rdma_queue_pending_operation pending;

      // 中文设计：caller bit 不能由 engine snapshot 或兼容投影直接解释成 authority。
      // runtime.recover() 先依据唯一 mmio_evidence enum 拒绝 AMBIGUOUS/错误方向，
      // 再记录一次性 confirmation；后续 commit gate 成功时消费该授权。
      status = found.runtime.recover(
        RDMA_QUEUE_RECOVERY_RETRY_PENDING, caller_confirmed_no_submit);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("runtime recovery confirmation returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      status = found.runtime.query_pending(pending);
      if (status == null || !status.ok()) begin
        status = status == null ?
          bad("runtime recovery pending query returned null status",
              RDMA_SC_RECOVERY_REQUIRED) : status;
        return;
      end
      if (pending == null) begin
        status = bad("runtime recovery pending query returned null evidence",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      if (pending.mmio_evidence == RDMA_QUEUE_MMIO_AMBIGUOUS) begin
        status = bad("pending MMIO outcome is ambiguous",
                     RDMA_SC_RECOVERY_REQUIRED);
        return;
      end
      replay_pending(found, pending, status);
      return;
    end
  endtask

endclass
