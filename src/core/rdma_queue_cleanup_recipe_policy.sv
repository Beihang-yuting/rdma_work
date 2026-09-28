// 目录：核心执行层 core/rdma_queue_cleanup_recipe_policy.sv。
// 文件职责：校验 queue lifecycle 的 detached hardware/local cleanup recipe 是否与
//   backing plan 的 role、phase、context 和 reverse-release 顺序一致。
// 主要依赖：依赖 rdma_model_pkg 中的 rdma_queue_backing_plan、flush target/ref 和
//   resource/role/phase 枚举；不调用 manager、CMQ、runtime、Host-memory 或 PCIe。
// 所有权与生命周期：本文件只读取调用方提供的 detached plan/role 队列并返回短生命周期
//   rdma_status；不保存 plan 引用，不取得 backing、registry、recovery ledger 或锁的所有权。

// 中文设计：cleanup recipe 是 lifecycle policy 对资源类型给出的值规则，destroy/recovery
// caller 负责执行副作用。本 policy 只证明“每个声明 role 恰好出现一次、context 规则一致、
// reverse release 顺序可解释”，避免 executor 在不同业务阶段复制并漂移同一张门禁表。
class rdma_queue_cleanup_recipe_policy extends uvm_object;
  `uvm_object_utils(rdma_queue_cleanup_recipe_policy)

  // 功能：构造无状态 cleanup recipe policy 对象，建立 UVM 名称但不绑定任何 queue 或
  //   backing；所有校验均通过静态 validate 完成。
  // 输入/输出及副作用：name（输入）；new 返回不持有 semaphore、plan、registry 或外部
  //   adapter 的 helper 对象。
  // 失败/边界：构造成功不代表 recipe 合法；调用方仍必须检查 validate() 返回状态，不能
  //   把缺省 role 数组当作允许执行 cleanup。
  function new(string name = "rdma_queue_cleanup_recipe_policy");
    super.new(name);
  endfunction

  // 功能：validate 校验给定资源 kind 的 hardware flush 与 local release recipe，确认
  //   role/phase cardinality、SRQ 可选 SGB、context release 标记及 plan.refs 的逆序释放
  //   均与 policy 输出一致，供 destroy_locked 在首次外部副作用前建立完整前置条件。
  // 输入/输出及副作用：resource_kind、plan、flush_roles、flush_phases、local_roles 和
  //   release_context_first 为 detached 输入；返回 rdma_status，不修改 plan、role 队列、
  //   manager registry、recovery ledger、runtime lock 或任何外部 backing。
  // 失败/边界：plan 为空、flush role/phase 数量不一致、声明 role 缺失/重复、context 标记
  //   与 plan.context_ref 不一致、非 SRQ role 未按反向顺序出现、或 plan 含未列出的 ref 时
  //   返回 RDMA_SC_INVALID_STATE；SRQ 的 SRQ_SGB 在 max_sge<=2 时允许从 plan 中省略，
  //   其他资源和其他 role 不享受该例外。
  static function rdma_status validate(
    rdma_resource_kind_e resource_kind,
    rdma_queue_backing_plan plan,
    input rdma_queue_backing_role_e flush_roles[$],
    input rdma_queue_flush_phase_e flush_phases[$],
    input bit release_context_first,
    input rdma_queue_backing_role_e local_roles[$]
  );
    int unsigned i;
    int unsigned j;
    int unsigned count;
    int unsigned ref_cursor;
    int unsigned ref_role_count;

    if (plan == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "cleanup recipe plan is null");
    if (flush_roles.size() != flush_phases.size())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "cleanup recipe phase mismatch");

    foreach (flush_roles[i]) begin
      count = 0;
      foreach (plan.flush_targets[j]) begin
        if (plan.flush_targets[j] != null &&
            plan.flush_targets[j].role == flush_roles[i] &&
            plan.flush_targets[j].phase == flush_phases[i])
          count++;
      end
      if (count != 1)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "cleanup recipe role missing or duplicated");
    end

    foreach (local_roles[i]) begin
      count = 0;
      foreach (plan.refs[j]) begin
        if (plan.refs[j] != null && plan.refs[j].role == local_roles[i])
          count++;
      end
      if (count != 1 &&
          !(resource_kind == RDMA_RESOURCE_SRQ &&
            local_roles[i] == RDMA_QUEUE_ROLE_SRQ_SGB && count == 0))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "local cleanup role missing or duplicated");
    end

    if (release_context_first != (plan.context_ref != null))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "local cleanup context recipe mismatch");

    ref_cursor = plan.refs.size();
    for (i = 0; i < local_roles.size(); i++) begin
      ref_role_count = 0;
      foreach (plan.refs[j]) begin
        if (plan.refs[j] != null && plan.refs[j].role == local_roles[i])
          ref_role_count++;
      end
      if (ref_role_count == 0 && resource_kind == RDMA_RESOURCE_SRQ &&
          local_roles[i] == RDMA_QUEUE_ROLE_SRQ_SGB)
        continue;
      if (ref_cursor == 0)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "planner local cleanup order diverges from recipe");
      ref_cursor--;
      if (plan.refs[ref_cursor] == null ||
          plan.refs[ref_cursor].role != local_roles[i])
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "planner local cleanup order diverges from recipe");
    end
    if (ref_cursor != 0)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "planner local cleanup has unlisted roles");
    return rdma_status::success();
  endfunction
endclass
