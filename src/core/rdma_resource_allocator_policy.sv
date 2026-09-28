// 目录：核心策略层 core/rdma_resource_allocator_policy.sv。
// 职责：集中保存 resource manager 使用的资源 kind 合法性和硬件 local-ID 宽度映射，
//   为 allocator admission 提供无状态、可直接测试的纯值边界。
// 依赖：仅依赖 rdma_types_pkg 的资源 kind 枚举；不读取 manager registry、allocator
//   free-list、generation ledger 或任何外部 adapter。
// 所有权与生命周期：本文件不拥有运行时资源；policy 无实例状态，返回值由调用方使用，
//   local-ID 的分配、回收和 publication 仍由 rdma_resource_manager 唯一负责。

// 中文设计：硬件 local-ID 宽度是 allocator 的静态契约，不应与 registry mutation、
// free-list reservation 或 Function incarnation 逻辑交织。将它放在纯值 policy 中可以让
// manager 保持“账本所有者”职责，同时让边界矩阵不必构造 manager 或伪造资源。
class rdma_resource_allocator_policy;

  // 功能：valid_kind 判断输入 resource kind 是否属于 manager 可以登记的资源集合，供
  //   authority、identity reservation 和 release 前置校验复用。
  // 输入/输出及副作用：kind（输入）；函数返回 bit，不修改任何 ledger、candidate、
  //   registry 或外部资源，也不取得调用方所有权。
  // 失败/边界：FUNCTION、PD、MR、CQ、QP、SRQ、CMQ、CEQ、AEQ 返回 1；未定义枚举值
  //   返回 0。该结果只表示 kind 可登记，不代表对象存在或当前 generation 可用。
  static function bit valid_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                        RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                        RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                        RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：local_id_limit 返回每类资源在单个 Function 内可编码的最大 local ID，供
  //   free-list 和 fresh allocator 在消费 reservation 前执行硬件宽度检查。
  // 输入/输出及副作用：kind（输入）；函数返回 int unsigned，不修改 allocator 游标、
  //   free-list 或资源对象，也不拥有任何外部 backing。
  // 失败/边界：PD=16 bit、MR=24 bit、CQ/QP=21 bit、SRQ=16 bit、CEQ/AEQ=12 bit；
  //   FUNCTION、CMQ 或未知 kind 返回全 32-bit 上限，调用方仍须单独拒绝不可分配 kind，
  //   不能把该 fallback 当成“硬件支持”证明。
  static function int unsigned local_id_limit(rdma_resource_kind_e kind);
    case (kind)
      RDMA_RESOURCE_PD: return 16'hffff;
      RDMA_RESOURCE_MR: return 24'hff_ffff;
      RDMA_RESOURCE_CQ,
      RDMA_RESOURCE_QP: return 21'h1f_ffff;
      RDMA_RESOURCE_SRQ: return 16'hffff;
      RDMA_RESOURCE_CEQ,
      RDMA_RESOURCE_AEQ: return 12'hfff;
      default: return 32'hffff_ffff;
    endcase
  endfunction

endclass
