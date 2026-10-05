// 目录/层次：核心执行层 core/rdma_queue_data_transaction_models.sv。
// 职责：保存 queue-data post、device publish、CQ completion 与 CEQ/AEQ event 的 detached 结果模型，
//   使调用方可见的值快照与 engine 的 runtime mutation 分离。
// 依赖：依赖 rdma_handle、rdma_hw_image/model/cqe_model、rdma_queue_slot_ledger_entry、rdma_status；
//   不访问 runtime、registry、backing 或外部 adapter。
// 所有权与生命周期：结果对象只拥有自身字段与成功路径写入的 detached 快照；其余资源归各自 owner，
//   调用方消费后释放结果对象。

// 设计说明：host producer post 的返回对象与 runtime ledger 解耦，只发布 queue identity、
// WR 标识、已提交 producer cursor、编码镜像和最终状态的值快照。
class rdma_queue_post_result extends uvm_object;
  `rdma_object_utils(rdma_queue_post_result)
  rdma_handle queue_h;
  longint unsigned wr_id;
  int unsigned index;
  bit wrap;
  rdma_hw_image image;
  rdma_status status;

  // 功能：构造空 post 结果，清零 WR/cursor 并清空快照引用。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：status/queue_h/image 为空时不是可发布结果；仅 post 成功路径填充。
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

// device-producer 发布的 detached 结果（CQ/CEQ/AEQ 共用），不暴露 runtime 内部状态。
// 字段由各 publish 成功路径写入；失败路径不发布半成品。
// occupancy_valid=0 表示提交后查询失败，不是 cursor 回滚，也不能当作 occupancy=0。
class rdma_queue_device_publish_result extends uvm_object;
  `rdma_object_utils(rdma_queue_device_publish_result)
  rdma_handle queue_h;
  int unsigned index;
  bit wrap;
  int unsigned occupancy;
  bit occupancy_valid;
  rdma_hw_image image;
  rdma_status status;

  // 功能：构造设备发布结果并设置安全默认值。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：构造不校验，调用方须依据 status 判断结果是否可用。
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

// 设计说明：CQ poll 结果保存预物化的 CQE 语义与 WQE release 值快照，不暴露 runtime 的 ledger entry，
// 修改结果不会反向影响 SQ/RQ/SRQ credit。
class rdma_queue_completion_result extends uvm_object;
  `rdma_object_utils(rdma_queue_completion_result)
  rdma_handle queue_h;
  rdma_hw_cqe_model cqe;
  rdma_status completion_status;
  rdma_queue_slot_ledger_entry released_slots[$];

  // 功能：构造空 CQ completion 结果，清空 queue/CQE/status 与 released_slots。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：字段为空时不得发布给成功调用方；released_slots 仅在 prepared candidate 完整构造后才有值。
  function new(string name = "rdma_queue_completion_result");
    super.new(name);
    queue_h = null;
    cqe = null;
    completion_status = null;
    released_slots.delete();
  endfunction
endclass

// 设计说明：CEQ/AEQ poll 只发布 event queue、路由目标模型与状态的 detached 值，
// 不交出 CQ/QP attachment 或 event runtime 的可变引用。
class rdma_queue_event_result extends uvm_object;
  `rdma_object_utils(rdma_queue_event_result)
  rdma_handle queue_h;
  rdma_hw_model event_model;
  rdma_status event_status;
  // CQ flush 同时带 CQ error 与 QP flush 语义；secondary_target_h 保存第二个已认证 owner 的值快照，
  // 其余事件为空。
  rdma_handle secondary_target_h;

  // 功能：构造空 event 结果，清空全部对象引用。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：queue_h/event_model/event_status 未由 prepared candidate 填满时不得作为成功结果。
  function new(string name = "rdma_queue_event_result");
    super.new(name);
    queue_h = null;
    event_model = null;
    event_status = null;
    secondary_target_h = null;
  endfunction
endclass

// 设计说明：每个 ring 必须有独立 attachment（同一 QP 的 SQ/RQ 逻辑 offset 都从零开始）；
// attachment 只保存各 ring 自己的 runtime/backing capability，不共享索引或释放权。
class rdma_queue_data_attachment extends uvm_object;
  `rdma_object_utils(rdma_queue_data_attachment)
  rdma_handle queue_h;
  rdma_handle ceq_h;
  rdma_queue_runtime_kind_e kind;
  rdma_queue_runtime runtime;
  rdma_queue_backing_access access;
  rdma_queue_backing_role_e role;
  // CQ context authority 借用自 lifecycle 持有的 queue plan。
  rdma_context_backing_ref context_ref;
  int unsigned entry_size;
  int unsigned local_id;
  rdma_transport_e transport;

  // 功能：构造queue attachment 的安全默认值。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：CQ 的 ceq_h 须在发布前另行冻结；ceq_h 为空的 CQ attachment 不完整，attach/publish 须报错，不回退到任意 CEQ。
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
// backing access/ref 为非拥有 capability，生命周期归 QP plan/manager。
class rdma_queue_data_qp_link extends uvm_object;
  `rdma_object_utils(rdma_queue_data_qp_link)
  rdma_handle qp_h;
  rdma_handle srq_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  int unsigned local_qp_id;
  rdma_transport_e transport;
  rdma_queue_backing_access sq_sgb_access;
  rdma_qp_backing_ref sq_sgb_ref;
  rdma_queue_backing_access rq_sgb_access;
  rdma_qp_backing_ref rq_sgb_ref;
  rdma_context_backing_ref context_ref;
  int unsigned path_mtu_bytes;
  bit [6:0] sw_ring_db_count;
  bit sw_ring_db_count_valid;

  // 功能：构造未绑定 QP/CQ/SRQ 的空路由记录，默认 RC transport。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：qp_h 或 CQ authority 缺失时不能用于 post/publish/poll；sw_ring_db_count_valid=0 时不能宣称已通知。
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
    rq_sgb_access = null;
    rq_sgb_ref = null;
    context_ref = null;
    path_mtu_bytes = 0;
    sw_ring_db_count = '0;
    sw_ring_db_count_valid = 1'b0;
  endfunction
endclass

// CQ resize 在 authority 发布后，旧 runtime/backing 可能因后端故障无法立即 detach/release；
// 该记录由 engine 持有，直到清理完成。
class rdma_cq_resize_recovery extends uvm_object;
  `rdma_object_utils(rdma_cq_resize_recovery)
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

  // 功能：构造CQ resize recovery 记录，初始化旧 authority、依赖 runtime 与最近失败状态。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：记录为空或字段不完整时，重试入口须拒绝并返回 RECOVERY_REQUIRED。
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
