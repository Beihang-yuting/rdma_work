// 目录/层次：核心执行层 core/rdma_queue_lifecycle_opcode_policy.sv，队列生命周期 policy 层。
// 文件职责：集中计算 CQ/SRQ/CEQ/AEQ 的 create/query/delete CMQ opcode，避免 executor
//   在多个 recovery 分支重复维护映射表。
// 主要依赖：rdma_model_pkg 的 rdma_resource_kind_e 与 CMQ opcode 常量；不读取 manager、
//   queue plan、ledger、CMQ ticket 或 adapter。
// 所有权与生命周期：只返回 bit[7:0] 纯值，不携带 handle/owner；调用方负责 authority、
//   状态门禁、外部 I/O 与 commit 顺序。

// 设计说明：opcode 选择只是 wire-level 选择，不是生命周期状态迁移。SRQ pre-delete flush、
// CQ post-delete flush、ambiguous recovery 与错误优先级仍由 executor 决定；未知 kind
// fail-closed 为 8'h00。
class rdma_queue_lifecycle_opcode_policy extends uvm_object;
  `rdma_object_utils(rdma_queue_lifecycle_opcode_policy)

  // 功能：构造无状态 opcode policy 对象。
  // 输入/输出及副作用：name 为 UVM 对象名；不保存任何引用。
  // 失败/边界：无。
  function new(string name = "rdma_queue_lifecycle_opcode_policy");
    super.new(name);
  endfunction

  // 功能：把 CQ/SRQ/CEQ/AEQ kind 映射为 CMQ create opcode。
  // 输入/输出及副作用：kind 只读；返回 bit[7:0]，无副作用。
  // 失败/边界：其他 kind 或 X/Z 返回 8'h00，caller 必须拒绝构造 command。
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

  // 功能：把 CQ/SRQ/CEQ/AEQ kind 映射为 CMQ query opcode。
  // 输入/输出及副作用：kind 只读；返回 bit[7:0]，无副作用。
  // 失败/边界：其他 kind 或 X/Z 返回 8'h00，不可当作可重放的 QUERY。
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

  // 功能：把 CQ/SRQ/CEQ/AEQ kind 映射为 CMQ delete opcode。
  // 输入/输出及副作用：kind 只读；返回 bit[7:0]，无副作用。
  // 失败/边界：其他 kind 或 X/Z 返回 8'h00；caller 须先完成依赖、flush 与 presence 校验。
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
