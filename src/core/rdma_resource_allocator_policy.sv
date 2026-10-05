// 目录/层次：核心策略层 core/rdma_resource_allocator_policy.sv。
// 职责：提供资源 kind 合法性与硬件 local-ID 宽度映射的无状态纯值策略。
// 依赖：仅依赖 rdma_types_pkg 的资源 kind 枚举，不读 registry、free-list 或 adapter。
// 所有权与生命周期：无实例状态；local-ID 分配、回收与发布仍由 rdma_resource_manager 负责。

// 设计说明：local-ID 宽度是 allocator 的静态契约，独立成纯值 policy，
// 使 manager 只做账本所有者，边界测试也无需构造 manager。
class rdma_resource_allocator_policy;

  // 功能：判断 kind 是否为 manager 可登记的资源类型。
  // 输入/输出及副作用：kind 为输入；返回 bit，无副作用。
  // 失败/边界：未定义枚举值返回 0；1 只表示 kind 可登记，不代表对象存在。
  static function bit valid_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                        RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                        RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                        RDMA_RESOURCE_AEQ};
  endfunction

  // 功能：返回各类资源在单个 Function 内可编码的最大 local ID。
  // 输入/输出及副作用：kind 为输入；返回 int unsigned，无副作用。
  // 失败/边界：PD/SRQ 16 bit、MR 24 bit、CQ/QP 21 bit、CEQ/AEQ 12 bit；其余 kind 回退全 32 bit，
  //   该回退不代表硬件支持，不可分配的 kind 须由调用方另行拒绝。
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
