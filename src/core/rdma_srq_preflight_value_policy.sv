// 目录/层次：核心策略层 core/rdma_srq_preflight_value_policy.sv。
// 职责：集中 SRQ create preflight 中不依赖 manager 与 backing 生命周期的纯值边界检查。
// 依赖：依赖 rdma_model_pkg 的 backing spec、queue role 与 rdma_status；不调用 manager 或 adapter。
// 所有权与生命周期：不拥有 request、slice、mapping 或账本；返回的 rdma_status 为 detached 值。

// 设计说明：标量能力/字段宽度检查与 borrowed backing 角色检查都只依赖输入快照，
// 从生命周期 policy 中抽出；保留 caller 的检查顺序与原始诊断文案。
class rdma_srq_preflight_value_policy;

  // 功能：判断 SRQ 是否需要独立 SGB ring。
  // 输入/输出及副作用：max_sge 为输入；返回 bit，无副作用。
  // 失败/边界：max_sge > 2 返回 1，其余返回 0；max_sge=0 仍须由 request validation 拒绝。
  static function bit requires_sgb(int unsigned max_sge);
    return max_sge > 2;
  endfunction

  // 功能：校验 SRQ depth、max_sge 与编码后的 limit threshold 是否在 Function 能力内。
  // 输入/输出及副作用：各限值与请求值为输入；返回 detached status，无副作用。
  // 失败/边界：depth 越界、max_sge 为 0 或超过 max_wq_sge、limit_threshold/4 超过 14 bit，
  //   各返回 INVALID_ARGUMENT 及对应文案；owner/dependency 检查不在此处。
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

  // 功能：校验 borrowed SRQ backing 的角色集合。
  // 输入/输出及副作用：spec 提供 slice 快照；need_sgb 表示是否要求 SGB；返回 detached status。
  // 失败/边界：spec/slice 为空或角色非 SRQ_RING/SRFQ_RING/SRQ_SGB、不需要 SGB 却出现 SGB、
  //   缺少必需角色，均返回 INVALID_ARGUMENT；同一角色重复不在此拒绝。
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
