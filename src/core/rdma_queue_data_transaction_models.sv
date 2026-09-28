// 目录/层次：核心执行层 core/rdma_queue_data_transaction_models.sv。
// 文件职责：保存 queue-data post、device publish、CQ completion 和 CEQ/AEQ event 的 detached
//   结果模型，把调用方可观察的值快照与 queue-data engine 的 runtime mutation 分离。
// 主要依赖：依赖 rdma_handle、rdma_hw_image、rdma_hw_model、rdma_hw_cqe_model、
//   rdma_queue_slot_ledger_entry 和 rdma_status；不访问 runtime、registry、backing 或外部 adapter。
// 所有权与生命周期：结果对象只拥有自身字段和成功路径写入的 detached 快照；queue、mapping、
//   runtime、manager、Host-memory 与 PCIe 资源仍由各自 owner 管理，调用方消费后释放结果对象。

// 设计说明：host producer post 的返回对象必须与 runtime ledger 解耦，只向调用方发布 queue
// identity、WR 标识、已提交 producer cursor、编码镜像和最终状态的值快照。
//
class rdma_queue_post_result extends uvm_object;
  `uvm_object_utils(rdma_queue_post_result)
  rdma_handle queue_h;
  longint unsigned wr_id;
  int unsigned index;
  bit wrap;
  rdma_hw_image image;
  rdma_status status;

  // 功能：构造尚未代表成功 post 的空结果，清零 WR/cursor 并移除所有快照引用。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化 queue_h、wr_id、index、wrap、image
  //   和 status，不访问 runtime、backing 或 scheduler。
  // 失败/边界：status、queue_h 或 image 任一为空时对象都不是可发布结果；构造不取得
  //   manager、Host-memory 或 PCIe 资源所有权，只有 post 成功路径可以填充并返回它。
  function new(string name = "rdma_queue_post_result");
    super.new(name);
    queue_h = null;
    wr_id = 0;
    index = 0;
    wrap = 1'b0;
    image = null;
    status = null;
  endfunction
endclass

// 功能：保存一次 CQ/CEQ/AEQ 共用的 device-producer 发布 detached 结果，供调用方观察已提交
//   槽位、镜像与 occupancy，而不暴露 runtime 的可变内部状态。
// 输入/输出及副作用：字段由各类型 publish 成功路径写入；对象不拥有 queue、mapping 或
//   runtime，只拥有自身指向的 detached queue/image/status 快照。
// 失败/边界：失败路径不得发布半成品对象；occupancy_valid=0 表示提交后的查询失败，不是
//   对已提交 cursor 的回滚，也不得被调用方当作 occupancy=0。
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

// 设计说明：CQ poll 返回对象保存预物化的 CQE 语义和 WQE release 值快照；它不暴露
// runtime-owned ledger entry，调用方修改结果不能反向改变 SQ/RQ/SRQ credit。
class rdma_queue_completion_result extends uvm_object;
  `uvm_object_utils(rdma_queue_completion_result)
  rdma_handle queue_h;
  rdma_hw_cqe_model cqe;
  rdma_status completion_status;
  rdma_queue_slot_ledger_entry released_slots[$];

  // 功能：构造空的 CQ completion 结果，清除 queue/CQE/status 与 released slot 队列。
  // 输入/输出及副作用：name 为 UVM 对象名；仅写本对象字段，不读取 CQ backing、不提交
  //   consumer cursor，也不释放 WQE ledger。
  // 失败/边界：queue_h、cqe 或 completion_status 为空时不得发布给成功调用方；released_slots
  //   只有 prepared candidate 完整构造后才拥有 detached slot 值。
  function new(string name = "rdma_queue_completion_result");
    super.new(name);
    queue_h = null;
    cqe = null;
    completion_status = null;
    released_slots.delete();
  endfunction
endclass

// 设计说明：CEQ/AEQ poll 只发布 event queue、路由目标模型与状态的 detached 值，不把 CQ/QP
// attachment 或 event runtime 的可变引用交给调用方。
class rdma_queue_event_result extends uvm_object;
  `uvm_object_utils(rdma_queue_event_result)
  rdma_handle queue_h;
  rdma_hw_model event_model;
  rdma_status event_status;
  // CQ flush 同时携带 CQ error 与 QP flush 语义；secondary_target_h 保存第二个已认证 owner
  // 的值快照，其余事件保持为空。
  rdma_handle secondary_target_h;

  // 功能：构造尚未绑定 CEQE/AEQE 的空 event 结果并清除全部对象引用。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化 queue_h、event_model、event_status 和
  //   secondary_target_h，不读取 route、backing 或 consumer cursor。
  // 失败/边界：三个字段未由 prepared event candidate 全部填充时不得作为成功结果；本对象
  //   不拥有 lifecycle queue/QP，只拥有成功路径写入的 detached 快照。
  function new(string name = "rdma_queue_event_result");
    super.new(name);
    queue_h = null;
    event_model = null;
    event_status = null;
    secondary_target_h = null;
  endfunction
endclass

// 设计说明：每个 ring 必须拥有独立 attachment。尤其同一 QP 的 SQ/RQ 逻辑 offset 都从零
// 开始；attachment 只保存各 ring 自己的 runtime/backing capability，不共享索引或释放权。
class rdma_queue_data_attachment extends uvm_object;
  `uvm_object_utils(rdma_queue_data_attachment)
  rdma_handle queue_h;
  rdma_handle ceq_h;
  rdma_queue_runtime_kind_e kind;
  rdma_queue_runtime runtime;
  rdma_queue_backing_access access;
  rdma_queue_backing_role_e role;
  // CQ context authority is borrowed from the lifecycle-owned queue plan.
  rdma_context_backing_ref context_ref;
  int unsigned entry_size;
  int unsigned local_id;
  rdma_transport_e transport;

  // 功能：构造 queue attachment 的安全默认状态；CQ 的 ceq_h 依赖必须在发布 attachment
  //   前另行冻结，其他 runtime 保持该字段为空。
  // 输入/输出及副作用：name 为 UVM 对象名；new 只初始化 queue_h/ceq_h、runtime、backing
  //   role、geometry 与 transport，不访问 manager 或 Host-memory。
  // 失败/边界：构造不分配 dependency handle；ceq_h 为空的 CQ attachment 不完整，attach/
  //   publish 必须返回错误，不能回退到同 Function 任意 CEQ。
  function new(string name = "rdma_queue_data_attachment");
    super.new(name);
    queue_h = null;
    ceq_h = null;
    kind = RDMA_QUEUE_RUNTIME_SQ;
    runtime = null;
    access = null;
    role = RDMA_QUEUE_ROLE_CQ_RING;
    context_ref = null;
    entry_size = 64;
    local_id = 0;
    transport = RDMA_TRANSPORT_RC;
  endfunction
endclass

// 设计说明：QP link 是 engine 内 SQ/RQ/SRQ 与 send/recv CQ 的冻结路由索引；handle 为值快照，
// backing access/ref 是非拥有 capability，生命周期仍归 QP plan/manager。
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
  rdma_context_backing_ref context_ref;
  int unsigned path_mtu_bytes;
  bit [6:0] sw_ring_db_count;
  bit sw_ring_db_count_valid;

  // 功能：构造未绑定 QP/CQ/SRQ 的空路由记录，并默认采用 RC transport。
  // 输入/输出及副作用：name 为 UVM 对象名；清空四个 handle、local_id、SGB access/ref、
  //   QPC context ref 和 software doorbell count，仅修改本地记录。
  // 失败/边界：qp_h 或 send/recv CQ authority 缺失时不能用于 post/publish/poll；构造不会
  //   取得 capability 所有权，失败清理由 attachment owner 负责；count_valid=0 时不能宣称已通知。
  function new(string name = "rdma_queue_data_qp_link");
    super.new(name);
    qp_h = null;
    srq_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    local_qp_id = 0;
    transport = RDMA_TRANSPORT_RC;
    sq_sgb_access = null;
    sq_sgb_ref = null;
    context_ref = null;
    path_mtu_bytes = 0;
    sw_ring_db_count = '0;
    sw_ring_db_count_valid = 1'b0;
  endfunction
endclass

// CQ resize 在 authority 已发布后，旧 runtime/backing 仍可能因为后端故障无法立即 detach/
// release；该记录由 engine 持有，直到所有清理动作完成。
class rdma_cq_resize_recovery extends uvm_object;
  `uvm_object_utils(rdma_cq_resize_recovery)
  rdma_handle cq_h;
  rdma_function_identity function_identity;
  rdma_queue_runtime old_runtime;
  rdma_queue_backing_ref old_ref;
  rdma_queue_backing_ref pending_ref;
  bit published;
  bit prepublish_restore_pending;
  bit manager_restore_pending;
  bit cq_restore_pending;
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
  // 输入/输出及副作用：name 为 UVM 对象名称；只建立本地记录，不访问 Host-memory 或 manager。
  // 失败/边界：记录为空或字段不完整时，重试入口必须拒绝执行并返回 RECOVERY_REQUIRED。
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
