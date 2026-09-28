// 目录/层次：核心执行层 core/rdma_resource_dependency_policy.sv。
// 文件职责：把 resource manager 的跨资源 dependent 分类和 destroy/resize blocker
//   判定收束为无状态值策略，统一 QP、SRQ 与其它 dependent 的语义。
// 主要依赖：依赖 rdma_types_pkg 的 rdma_resource_kind_e；不访问 resource registry、
//   outstanding ledger、lock、recovery record 或外部 adapter。
// 所有权与生命周期：policy 只返回 detached enum/bit；resource manager 仍唯一拥有
//   dependent 扫描、计数快照、状态迁移和资源生命周期副作用。

// 中文设计说明：QP 是允许在特定 CQ resize 场景下“仍引用但无 outstanding”的特殊
//   dependent；SRQ 和其它 dependent 即使没有 outstanding 也继续阻塞 parent destroy。
//   独立策略避免 snapshot caller 各自重写这组跨资源取舍。
typedef enum bit [1:0] {
  RDMA_RESOURCE_DEP_NONE  = 2'd0,
  RDMA_RESOURCE_DEP_QP    = 2'd1,
  RDMA_RESOURCE_DEP_SRQ   = 2'd2,
  RDMA_RESOURCE_DEP_OTHER = 2'd3
} rdma_resource_dependency_class_e;

// 中文设计说明：普通 destroy/finalize 要求所有 dependent 消失；CQ resize 是唯一
// 允许“空闲 QP 仍引用 CQ”的窗口，因此只拒绝非 QP dependent、携带 outstanding 的
// QP，或 CQ 自身存在 manager-visible outstanding。把该 operation mode 显式化，避免
// manager 在 SRQ/QP 组合变化时复制一套容易漂移的条件表达式。
typedef enum bit {
  RDMA_RESOURCE_RELEASE_STRICT = 1'b0,
  RDMA_RESOURCE_RELEASE_CQ_RESIZE = 1'b1
} rdma_resource_release_mode_e;

class rdma_resource_dependency_policy extends uvm_object;
  `uvm_object_utils(rdma_resource_dependency_policy)

  // 功能：构造无状态 resource dependency policy，不创建 registry 或生命周期资源。
  // 输入/输出及副作用：name（输入）设置 UVM 名称；new 只初始化基类对象，不写入
  //   resource manager、dependent ledger 或外部 adapter。
  // 失败/边界：构造成功不代表某个 dependent 已被 manager 观察；调用方仍需先完成
  //   handle、代际和 registry admission，再调用 classify()/blocks_parent_release()。
  function new(string name = "rdma_resource_dependency_policy");
    super.new(name);
  endfunction

  // 功能：classify 将已登记 dependent 的 resource kind 映射到 parent blocker 分类，
  //   供 activity snapshot 统计 QP/SRQ/其它 dependent cardinality。
  // 输入/输出及副作用：kind（输入）；返回 detached 分类 enum；函数不修改 kind、registry
  //   或任何 resource owner，也不读取业务字段推导依赖关系。
  // 失败/边界：QP 和 SRQ 分别返回专属分类；FUNCTION、PD、MR、CQ、CMQ、CEQ、AEQ
  //   以及未知/X/Z kind 均 fail-closed 为 OTHER，不能被误判成无 dependent。
  static function rdma_resource_dependency_class_e classify(
      rdma_resource_kind_e kind
  );
    case (kind)
      RDMA_RESOURCE_QP: return RDMA_RESOURCE_DEP_QP;
      RDMA_RESOURCE_SRQ: return RDMA_RESOURCE_DEP_SRQ;
      default: return RDMA_RESOURCE_DEP_OTHER;
    endcase
  endfunction

  // 功能：blocks_parent_release 根据 dependent 分类和其 outstanding 状态判断 parent
  //   destroy/resize 是否必须继续保持阻塞。
  // 输入/输出及副作用：dependency_class、dependent_has_outstanding（输入）；返回 bit；
  //   只做纯值计算，不改变 snapshot、registry、resource state 或外部资源。
  // 失败/边界：NONE 永不阻塞；QP 仅在有 outstanding 时阻塞；SRQ/OTHER 无论是否有
  //   outstanding 都阻塞，以保留共享 SRQ 与非 QP 依赖的生命周期安全边界。
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

  // 功能：判断 activity snapshot 在指定生命周期操作下是否仍有跨资源阻塞，统一普通
  //   destroy/finalize 与 CQ resize 的 QP/SRQ/其它 dependent 组合语义。
  // 输入/输出及副作用：snapshot（输入）提供 dependent/outstanding 分类；mode（输入）
  //   选择严格释放或 CQ resize 特殊窗口；返回 bit，不修改 snapshot、registry、锁或资源。
  // 失败/边界：严格模式按 live dependent 或自身 outstanding 阻塞；CQ resize 允许空闲 QP
  //   引用，但 SRQ/其它 dependent、带 outstanding 的 QP 或自身 outstanding 仍阻塞；未知
  //   mode 按严格模式处理，保证 fail-closed。
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
