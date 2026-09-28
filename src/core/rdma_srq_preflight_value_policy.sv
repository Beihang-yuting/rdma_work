// 目录：核心策略层 core/rdma_srq_preflight_value_policy.sv。
// 文件职责：集中 SRQ create preflight 中不依赖 manager、binding ledger 或外部 backing
//   生命周期的纯值边界，供 SRQ policy 保持“authority/事务”和“值判定”分层。
// 主要依赖：依赖 rdma_model_pkg 提供的 SRQ backing spec、queue role 和 rdma_status；
//   不调用 resource manager、Host-memory、PCIe 或 context-backing adapter。
// 所有权与生命周期：policy 不拥有 request、slice、mapping 或任何运行时账本；返回的
//   rdma_status 是 detached 诊断值，由调用方负责消费和释放。

// 中文设计说明：SRQ preflight 既包含 Function capability/硬件字段宽度等标量检查，
// 也包含 borrowed backing 的角色 cardinality 检查。两类判定都不需要读取 manager，
// 但过去直接嵌在生命周期 policy 中，容易和 dependency lookup、ring allocation 混在
// 一起。此处只抽离可由输入快照决定的条件，保留 caller 的检查顺序和原始诊断文案。
class rdma_srq_preflight_value_policy;

  // 功能：requires_sgb 根据 SRQ 的最大 SGE 数量判定硬件是否需要独立 SGB ring。
  // 输入/输出及副作用：max_sge（输入）；返回 bit，不修改 request、backing spec、
  //   manager 或任何外部资源，也不取得调用方所有权。
  // 失败/边界：max_sge 大于 2 时返回 1；0、1、2 以及未知整型值均按“不需要 SGB”
  //   返回 0，调用方仍须由自身 request validation 拒绝 max_sge=0。
  static function bit requires_sgb(int unsigned max_sge);
    return max_sge > 2;
  endfunction

  // 功能：validate_limits 校验 SRQ depth、max_sge、Function capability 和编码后的
  //   limit threshold，返回与既有 SRQ preflight 相同的边界 status。
  // 输入/输出及副作用：depth、max_sge、limit_threshold、min_srq_depth、max_srq_depth
  //   和 max_wq_sge（输入）；返回 detached rdma_status，不修改 binding、request、
  //   manager 或 resource ledger。
  // 失败/边界：depth 超出 capability 返回“SRQ depth exceeds Function capability”；
  //   max_sge 为零或超过 max_wq_sge 返回“SRQ maximum SGE exceeds Function capability”；
  //   limit_threshold/4 超过 14 bit 返回“SRQ encoded limit exceeds 14 bits”；其它情况
  //   返回成功。幂、阈值粒度和 owner/dependency 检查仍由 request/common preflight 负责。
  static function rdma_status validate_limits(
    int unsigned depth,
    int unsigned max_sge,
    int unsigned limit_threshold,
    int unsigned min_srq_depth,
    int unsigned max_srq_depth,
    int unsigned max_wq_sge
  );
    if (depth < min_srq_depth || depth > max_srq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQ depth exceeds Function capability");
    if (max_sge == 0 || max_sge > max_wq_sge)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "SRQ maximum SGE exceeds Function capability"
      );
    if (limit_threshold / 4 > 14'h3fff)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "SRQ encoded limit exceeds 14 bits"
      );
    return rdma_status::success();
  endfunction

  // 功能：validate_borrowed_backing 校验 borrowed SRQ backing 的角色集合，保证 ring、
  //   SRFQ ring 以及按需 SGB 各出现至少一次且不携带多余 SGB。
  // 输入/输出及副作用：spec（输入）提供 borrowed slice 快照；need_sgb（输入）表示
  //   max_sge 是否要求 SGB；返回 detached rdma_status，不修改 slices、mapping、ledger
  //   或外部 Host-memory 所有权。
  // 失败/边界：spec 为空、slice 为空或角色不是 SRQ_RING/SRFQ_RING/SRQ_SGB 时返回
  //   “SRQ borrowed backing has an invalid role”；不需要 SGB 却出现该角色返回“SRQ
  //   borrowed backing has an extra SGB”；缺少必需角色返回“SRQ borrowed backing omits
  //   a required role”；满足集合约束时返回成功。重复的合法角色不在本层拒绝，后续
  //   planner/cardinality 继续沿用原有检查。
  static function rdma_status validate_borrowed_backing(
    rdma_queue_backing_spec spec,
    bit need_sgb
  );
    int unsigned srq_ring_count;
    int unsigned srfq_ring_count;
    int unsigned sgb_count;

    srq_ring_count = 0;
    srfq_ring_count = 0;
    sgb_count = 0;
    if (spec == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "SRQ borrowed backing has an invalid role"
      );
    foreach (spec.slices[i]) begin
      if (spec.slices[i] == null ||
          !(spec.slices[i].role inside {
            RDMA_QUEUE_ROLE_SRQ_RING, RDMA_QUEUE_ROLE_SRFQ_RING,
            RDMA_QUEUE_ROLE_SRQ_SGB
          }))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "SRQ borrowed backing has an invalid role"
        );
      case (spec.slices[i].role)
        RDMA_QUEUE_ROLE_SRQ_RING: srq_ring_count++;
        RDMA_QUEUE_ROLE_SRFQ_RING: srfq_ring_count++;
        RDMA_QUEUE_ROLE_SRQ_SGB: begin
          sgb_count++;
          if (!need_sgb)
            return rdma_status::make(
              RDMA_SC_INVALID_ARGUMENT,
              "SRQ borrowed backing has an extra SGB"
            );
        end
        default: begin
        end
      endcase
    end
    if (srq_ring_count == 0 || srfq_ring_count == 0 ||
        (need_sgb && sgb_count == 0))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "SRQ borrowed backing omits a required role"
      );
    return rdma_status::success();
  endfunction

endclass
