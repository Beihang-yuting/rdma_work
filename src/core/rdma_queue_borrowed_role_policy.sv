// 目录：核心策略层 core/rdma_queue_borrowed_role_policy.sv。
// 文件职责：统一 CQ、CEQ、AEQ borrowed ring backing 的单角色集合校验，避免各生命
//   周期 policy 重复编写相同的 null/role/cardinality 条件。
// 主要依赖：依赖 rdma_model_pkg 的 rdma_queue_backing_spec、backing role 和 rdma_status；
//   不读取 resource manager、runtime ledger 或外部 Host-memory/PCIe adapter。
// 所有权与生命周期：policy 只读取调用方提供的 detached backing spec 值，不拥有 slice、
//   mapping 或 queue 生命周期；返回 status 由调用方消费。

// 中文设计说明：CQ/CEQ/AEQ 的 borrowed ring 都要求“所有 slice 都是同一个 ring role，
// 且至少存在一项”。这一约束属于 request snapshot 的纯值 admission，不应和 Function
// authority、interrupt lookup、dependency lookup 或 ring planner 混在同一 policy 中。
class rdma_queue_borrowed_role_policy;

  // 功能：validate_single_role 校验一个 borrowed backing spec 是否只包含 expected_role，
  //   并确认该角色至少出现一次。
  // 输入/输出及副作用：spec（输入）提供 backing slice 快照；expected_role、invalid_message、
  //   missing_message（输入）定义允许角色和诊断文本；返回 detached rdma_status，不修改
  //   spec、slice、mapping、manager 或外部资源所有权。
  // 失败/边界：spec 为空、slice 为空或任一 slice role 不等 expected_role 时返回
  //   invalid_message；所有 slice 合法但没有任何 slice 时返回 missing_message；重复同一
  //   合法角色保持成功，以保留 caller 原有 cardinality 语义。
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
