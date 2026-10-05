// 目录/层次：核心执行层 core/rdma_resource_dependency_policy.sv。
// 职责：把跨资源 dependent 分类与 destroy/resize blocker 判定收束为无状态值策略。
// 依赖：依赖 rdma_types_pkg 的 rdma_resource_kind_e；不访问 registry、ledger、锁或 adapter。
// 所有权与生命周期：只返回 detached enum/bit；dependent 扫描、计数与状态迁移仍归 resource manager。

// 设计说明：QP 是 CQ resize 场景下唯一允许“仍引用但无 outstanding”的 dependent；
// SRQ 与其它 dependent 即使空闲也继续阻塞 parent destroy。集中于此避免各 caller 重写。
typedef enum bit [1:0] {
  RDMA_RESOURCE_DEP_NONE  = 2'd0,
  RDMA_RESOURCE_DEP_QP    = 2'd1,
  RDMA_RESOURCE_DEP_SRQ   = 2'd2,
  RDMA_RESOURCE_DEP_OTHER = 2'd3
} rdma_resource_dependency_class_e;

// 设计说明：普通 destroy/finalize 要求所有 dependent 消失；CQ resize 只放行空闲 QP 引用，
// 仍拒绝非 QP dependent、带 outstanding 的 QP 以及 CQ 自身 outstanding。
typedef enum bit {
  RDMA_RESOURCE_RELEASE_STRICT = 1'b0,
  RDMA_RESOURCE_RELEASE_CQ_RESIZE = 1'b1
} rdma_resource_release_mode_e;

class rdma_resource_dependency_policy extends uvm_object;
  `uvm_object_utils(rdma_resource_dependency_policy)

  // 功能：构造无状态 dependency policy。
  // 输入/输出及副作用：name 为 UVM 名称；仅初始化基类。
  // 失败/边界：无。
  function new(string name = "rdma_resource_dependency_policy");
    super.new(name);
  endfunction

  // 功能：把 dependent 的 resource kind 映射为 blocker 分类。
  // 输入/输出及副作用：kind 为输入；返回分类 enum，无副作用。
  // 失败/边界：QP/SRQ 返回专属分类；其余及未知 kind 一律 OTHER（fail-closed）。
  static function rdma_resource_dependency_class_e classify(
      rdma_resource_kind_e kind
  );
    case (kind)
      RDMA_RESOURCE_QP: return RDMA_RESOURCE_DEP_QP;
      RDMA_RESOURCE_SRQ: return RDMA_RESOURCE_DEP_SRQ;
      default: return RDMA_RESOURCE_DEP_OTHER;
    endcase
  endfunction

  // 功能：按 dependent 分类和其 outstanding 状态判断 parent 释放是否仍被阻塞。
  // 输入/输出及副作用：dependency_class、dependent_has_outstanding 为输入；返回 bit，纯计算。
  // 失败/边界：NONE 不阻塞；QP 仅在有 outstanding 时阻塞；SRQ/OTHER/未知值恒阻塞。
  static function bit blocks_parent_release(
      rdma_resource_dependency_class_e dependency_class,
      bit dependent_has_outstanding
  );
    case (dependency_class)
      RDMA_RESOURCE_DEP_NONE: return 1'b0;
      RDMA_RESOURCE_DEP_QP: return dependent_has_outstanding;
      RDMA_RESOURCE_DEP_SRQ,
      RDMA_RESOURCE_DEP_OTHER: return 1'b1;
      default: return 1'b1;
    endcase
  endfunction

  // 功能：判断 activity snapshot 在指定释放模式下是否仍有阻塞。
  // 输入/输出及副作用：snapshot 提供 dependent/outstanding 统计；mode 选择严格释放或 CQ resize；
  //   返回 bit，不修改 snapshot。
  // 失败/边界：CQ resize 允许空闲 QP 引用，其余阻塞条件同严格模式；未知 mode 按严格模式处理。
  static function bit blocks_release(
      rdma_resource_activity_blocker_snapshot snapshot,
      rdma_resource_release_mode_e mode
  );
    if (mode === RDMA_RESOURCE_RELEASE_CQ_RESIZE)
      return snapshot.has_outstanding_operations ||
             snapshot.has_non_qp_dependents ||
             snapshot.has_qp_dependents_with_outstanding;
    return snapshot.has_live_dependents ||
           snapshot.has_outstanding_operations;
  endfunction
endclass
