// 目录：核心策略层 core/rdma_queue_borrowed_role_policy.sv。
// 文件职责：统一 CQ、CEQ、AEQ borrowed ring backing 的单角色集合校验，避免各生命
//   周期 policy 重复编写相同的 null/role/cardinality 条件。
// 主要依赖：依赖 rdma_model_pkg 的 rdma_queue_backing_spec、backing role 和 rdma_status；
//   不读取 resource manager、runtime ledger 或外部 Host-memory/PCIe adapter。
// 所有权与生命周期：policy 只读取调用方提供的 detached backing spec 值，不拥有 slice、
//   mapping 或 queue 生命周期；返回 status 由调用方消费。

// 中文设计说明：CQ/CEQ/AEQ 的 borrowed ring 要求所有 slice 为同一 ring role 且至少一项；
// 这是 request 快照的纯值 admission，不应与 Function authority、interrupt/dependency 查找或
// ring planner 混在同一 policy 中。
class rdma_queue_borrowed_role_policy;

  // 功能：校验 borrowed backing spec 的所有 slice 都是 expected_role 且至少一项。
  // 输入/输出及副作用：spec 为 detached 快照；invalid/missing_message 为诊断文本；返回 status，不改 spec。
  // 失败/边界：spec/slice 为空或 role 不符返回 invalid_message；无 slice 返回 missing_message；重复同角色视为成功。
  static function rdma_status validate_single_role(
    rdma_queue_backing_spec spec,
    rdma_queue_backing_role_e expected_role,
    string invalid_message,
    string missing_message
  );
    bit found;

    found = 1'b0;
    if (spec == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, invalid_message);
    foreach (spec.slices[i]) begin
      if (spec.slices[i] == null ||
          spec.slices[i].role != expected_role)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, invalid_message);
      found = 1'b1;
    end
    if (!found)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, missing_message);
    return rdma_status::success();
  endfunction

endclass
