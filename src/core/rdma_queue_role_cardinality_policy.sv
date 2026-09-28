// 目录：核心策略层 core/rdma_queue_role_cardinality_policy.sv。
// 文件职责：统一 queue backing plan 中 flush target 与 backing ref 的 role 唯一性扫描，
//   为 resource manager 的进度提交建立可复用的纯值前置条件。
// 主要依赖：依赖 rdma_model_pkg 中的 rdma_queue_backing_plan、rdma_queue_flush_target、
//   rdma_queue_backing_ref 和 rdma_queue_backing_role_e；不读取 manager、recovery ledger、
//   runtime lock 或外部 Host-memory/PCIe adapter。
// 所有权与生命周期：policy 只读取调用方提供的 plan 快照，不拥有 plan、target、ref、
//   mapping 或 queue 生命周期；返回的 cardinality/index 由调用方消费。

// 中文设计说明：flush completion 和 local cleanup 都把 role 作为逻辑键，而不是数组位置。
// role 缺失或重复时必须在任何字段解引用前拒绝。两种数组元素类型不同，业务语义却相同，
// 因此只把扫描和索引规则集中在这里，避免 resource manager 的两份循环逐渐漂移。
class rdma_queue_role_cardinality_policy;

  // 功能：count_flush_targets 扫描 detached queue plan 的 flush_targets，统计 expected_role
  //   出现次数，并在命中时返回最后一个匹配索引供 caller 做 cardinality==1 检查。
  // 输入/输出及副作用：plan、expected_role（输入）提供快照和目标 role；target_index（输出）
  //   接收匹配索引；函数不修改 plan、target、registry、recovery 或外部 backing。
  // 失败/边界：plan 为空、数组为空、元素为 null 或没有匹配 role 时返回 0 且 index=0；
  //   重复 role 返回实际数量，index 仅用于诊断，caller 必须拒绝非 1 的结果。
  static function int unsigned count_flush_targets(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e expected_role,
    output int unsigned target_index
  );
    int unsigned count;

    count = 0;
    target_index = 0;
    if (plan == null)
      return count;
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] != null &&
          plan.flush_targets[i].role == expected_role) begin
        count++;
        target_index = i;
      end
    end
    return count;
  endfunction

  // 功能：count_backing_refs 扫描 detached queue plan 的 refs，统计 expected_role 出现次数，
  //   并在命中时返回最后一个匹配索引供 caller 做 cardinality==1 检查。
  // 输入/输出及副作用：plan、expected_role（输入）提供快照和目标 role；ref_index（输出）
  //   接收匹配索引；函数不修改 plan、ref、registry、recovery 或外部 backing。
  // 失败/边界：plan 为空、数组为空、元素为 null 或没有匹配 role 时返回 0 且 index=0；
  //   重复 role 返回实际数量，index 仅用于诊断，caller 必须拒绝非 1 的结果。
  static function int unsigned count_backing_refs(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e expected_role,
    output int unsigned ref_index
  );
    int unsigned count;

    count = 0;
    ref_index = 0;
    if (plan == null)
      return count;
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == expected_role) begin
        count++;
        ref_index = i;
      end
    end
    return count;
  endfunction

endclass
