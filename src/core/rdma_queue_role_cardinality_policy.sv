// 目录：核心策略层 core/rdma_queue_role_cardinality_policy.sv。
// 文件职责：统一 queue backing plan 中 flush target 与 backing ref 的 role 唯一性扫描，
//   为 resource manager 的进度提交建立可复用的纯值前置条件。
// 主要依赖：依赖 rdma_model_pkg 中的 rdma_queue_backing_plan、rdma_queue_flush_target、
//   rdma_queue_backing_ref 和 rdma_queue_backing_role_e；不读取 manager、recovery ledger、
//   runtime lock 或外部 Host-memory/PCIe adapter。
// 所有权与生命周期：policy 只读取调用方提供的 plan 快照，不拥有 plan、target、ref、
//   mapping 或 queue 生命周期；返回的 cardinality/index 由调用方消费。

// 设计说明：flush completion 与 local cleanup 以 role 为逻辑键而非数组位置；
// 两类元素类型不同但语义相同，集中扫描规则以免 resource manager 中两份循环漂移。
class rdma_queue_role_cardinality_policy;

  // 功能：统计 plan.flush_targets 中 role==expected_role 的数量，并给出最后匹配的下标。
  // 输入/输出及副作用：target_index 输出最后匹配下标；只读，不修改 plan。
  // 失败/边界：plan 为 null、数组为空、元素为 null 或无匹配时返回 0 且 index=0；caller 须拒绝非 1。
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

  // 功能：统计 plan.refs 中 role==expected_role 的数量，并给出最后匹配的下标。
  // 输入/输出及副作用：ref_index 输出最后匹配下标；只读，不修改 plan。
  // 失败/边界：plan 为 null、数组为空、元素为 null 或无匹配时返回 0 且 index=0；caller 须拒绝非 1。
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
