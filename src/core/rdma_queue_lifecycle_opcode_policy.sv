// 目录/层次：核心执行层 core/rdma_queue_lifecycle_opcode_policy.sv，位于队列生命周期
//   policy 层。
// 文件职责：集中计算 CQ、SRQ、CEQ 和 AEQ 的 create/query/delete CMQ opcode，避免
//   queue lifecycle executor 在多个 recovery 分支重复维护同一张静态映射表。
// 主要依赖：依赖 rdma_model_pkg 提供的 rdma_resource_kind_e 与 CMQ opcode 常量；不读取
//   resource manager、queue plan、runtime ledger、CMQ ticket 或任何外部 adapter。
// 所有权与生命周期：本文件只返回 bit[7:0] 纯值；opcode 不携带 handle、owner 或
//   resource 引用，调用方继续负责 authority、状态门禁、外部 I/O 和 commit 顺序。

// 设计说明：create、query、delete 是生命周期事务的 wire-level operation choice，
// 但不是生命周期状态迁移本身。把它们独立成无状态 policy 后，SRQ 的 pre-delete
// flush、CQ 的 post-delete flush、ambiguous recovery 以及错误优先级仍由 executor
// 决定，未知 kind 继续 fail-closed 为 8'h00。
class rdma_queue_lifecycle_opcode_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_lifecycle_opcode_policy)

  // 功能：构造无状态 opcode policy 对象，供 queue lifecycle executor 或测试建立短生命周期
  //   的纯值 policy 句柄。
  // 输入/输出及副作用：name（输入）设置 UVM 对象名；构造不保存资源 kind、handle、owner、
  //   CMQ 或 runtime 引用。
  // 失败/边界：构造成功不代表 opcode 已获授权；调用方必须检查返回值是否为 8'h00，并在此
  //   之前完成资源与状态校验。
  function new(string name = "rdma_queue_lifecycle_opcode_policy");
    super.new(name);
  endfunction

  // 功能：create_opcode 将 CQ/SRQ/CEQ/AEQ resource kind 映射为对应的 CMQ create opcode，
  //   供首次硬件建对象路径复用。
  // 输入/输出及副作用：kind（输入）为只读资源类型；函数返回 bit[7:0]，不修改 manager、
  //   queue plan、CMQ 或外部资源。
  // 失败/边界：kind 为 FUNCTION、PD、MR、QP、CMQ 或未知/X/Z 时返回 8'h00；返回零时 caller
  //   必须拒绝构造 command。
  static function bit [7:0] create_opcode(input rdma_resource_kind_e kind);
    if ($isunknown(kind))
      return 8'h00;
    case (kind)
      RDMA_RESOURCE_CQ:  return RDMA_OP_CQC_CREATE;
      RDMA_RESOURCE_SRQ: return RDMA_OP_SRFQC_CREATE;
      RDMA_RESOURCE_CEQ: return RDMA_OP_CEQC_CREATE;
      RDMA_RESOURCE_AEQ: return RDMA_OP_AEQC_CREATE;
      default:           return 8'h00;
    endcase
  endfunction

  // 功能：query_opcode 将 CQ/SRQ/CEQ/AEQ resource kind 映射为对应的 CMQ query opcode，
  //   供 presence reconciliation 路径复用。
  // 输入/输出及副作用：kind（输入）为只读资源类型；函数返回 bit[7:0]，不修改 recovery
  //   record、硬件 presence 或 registry。
  // 失败/边界：kind 不属于四类可查询队列或含未知位时返回 8'h00；caller 不得把零 opcode
  //   当作可重放的 QUERY。
  static function bit [7:0] query_opcode(input rdma_resource_kind_e kind);
    if ($isunknown(kind))
      return 8'h00;
    case (kind)
      RDMA_RESOURCE_CQ:  return RDMA_OP_CQC_QUERY;
      RDMA_RESOURCE_SRQ: return RDMA_OP_SRFQC_QUERY;
      RDMA_RESOURCE_CEQ: return RDMA_OP_CEQC_QUERY;
      RDMA_RESOURCE_AEQ: return RDMA_OP_AEQC_QUERY;
      default:           return 8'h00;
    endcase
  endfunction

  // 功能：delete_opcode 将 CQ/SRQ/CEQ/AEQ resource kind 映射为对应的 CMQ delete opcode，
  //   供正常删除和 recovery 删除复用。
  // 输入/输出及副作用：kind（输入）为只读资源类型；函数返回 bit[7:0]，不释放 backing、
  //   修改状态或提交外部 I/O。
  // 失败/边界：kind 不属于四类可删除队列或含未知位时返回 8'h00；caller 必须先完成依赖、
  //   flush 和硬件 presence admission。
  static function bit [7:0] delete_opcode(input rdma_resource_kind_e kind);
    if ($isunknown(kind))
      return 8'h00;
    case (kind)
      RDMA_RESOURCE_CQ:  return RDMA_OP_CQC_DELETE;
      RDMA_RESOURCE_SRQ: return RDMA_OP_SRFQC_DELETE;
      RDMA_RESOURCE_CEQ: return RDMA_OP_CEQC_DELETE;
      RDMA_RESOURCE_AEQ: return RDMA_OP_AEQC_DELETE;
      default:           return 8'h00;
    endcase
  endfunction
endclass
