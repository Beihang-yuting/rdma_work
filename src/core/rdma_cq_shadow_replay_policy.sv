// 目录：核心执行层 core/rdma_cq_shadow_replay_policy.sv。
// 文件职责：集中校验 CQ shadow caller/cache snapshot 的 Function、generation、reset epoch
//   和 CQ handle authority，明确 replay 只接受 authority 输入并回填 canonical payload。
// 主要依赖：依赖 rdma_model_pkg 的 rdma_cq_shadow_snapshot、rdma_handle 和 reset epoch
//   值类型；不访问 CQ engine、delegate、runtime、shadow cache 或外部 backing。
// 所有权与生命周期：本文件只读取 detached snapshot 与 expected authority，返回短生命周期
//   rdma_status；不保存 snapshot 引用，不拥有 cache、evidence、lock 或外部资源。

// 中文设计：shadow replay 的 caller payload（SQ/RQ CI、arm、sequence）不是 authority，
// 首次 flush 后必须由 engine 的 flushed_shadow canonical cache 覆盖。policy 只验证不可伪造
// 的 Function/CQ identity，避免把“canonical overwrite”误写成 caller payload 的二次提交。
class rdma_cq_shadow_replay_policy extends uvm_object;
  `uvm_object_utils(rdma_cq_shadow_replay_policy)

  // 功能：构造无状态的 CQ shadow replay policy 对象，不绑定 CQ、delegate 或 cache。
  // 输入/输出及副作用：name 为 UVM 名；不持有外部资源。
  // 失败/边界：构造成功不代表 snapshot authority 合法，调用方须检查 validate() 状态。
  function new(string name = "rdma_cq_shadow_replay_policy");
    super.new(name);
  endfunction

  // 功能：校验 snapshot 是否绑定到指定 shared CQ 的 Function UID、generation、reset epoch 与 object ID。
  // 输入/输出及副作用：snapshot/expected_cq_h/function_uid/generation/reset_epoch/stale_message/mismatch_
  //   code 只读；返回 status，不改任何对象。
  // 失败/边界：snapshot/handle 缺失、handle 非 CQ 或 UID/generation/object ID/reset epoch 不符返回
  //   mismatch_code（默认 STALE_GENERATION）；expected authority 不完整返回 INVALID_STATE。
  static function rdma_status validate(
    rdma_cq_shadow_snapshot snapshot,
    rdma_handle expected_cq_h,
    longint unsigned function_uid,
    int unsigned generation,
    rdma_reset_epoch_t reset_epoch,
    string stale_message,
    rdma_status_code_e mismatch_code = RDMA_SC_STALE_GENERATION
  );
    if (expected_cq_h == null || expected_cq_h.kind != RDMA_RESOURCE_CQ ||
        function_uid == 0 || generation == 0 || reset_epoch == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE, "CQ shadow expected authority is incomplete");
    if (snapshot == null || snapshot.cq_h == null ||
        snapshot.cq_h.kind != RDMA_RESOURCE_CQ ||
        snapshot.function_uid != function_uid ||
        snapshot.generation != generation ||
        snapshot.reset_epoch != reset_epoch ||
        snapshot.cq_h.function_uid != function_uid ||
        snapshot.cq_h.generation != generation ||
        snapshot.cq_h.object_id != expected_cq_h.object_id)
      return rdma_status::make(
        mismatch_code, stale_message);
    return rdma_status::success();
  endfunction
endclass
