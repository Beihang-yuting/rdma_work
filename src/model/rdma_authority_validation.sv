// 目录：模型层 model/rdma_authority_validation.sv。
// 职责：集中实现各 queue facade 共用的 Function authority 活性校验与错误优先级。
// 依赖：rdma_function_binding、rdma_status、rdma_reset_epoch_t；只读 facade 传入的快照与
//   非拥有 binding，不访问 queue runtime、Host-memory 或 MMIO。
// 所有权与生命周期：helper 不保存输入引用；返回的 rdma_status 由调用方消费，生命周期归调用方。

// 设计说明：facade 入口先拒绝未配置/无 delegate，再比较冻结的 UID/generation/epoch，
// 最后验证 binding 为 ACTIVE 且自校验通过。集中到 model package 以避免四份实现漂移，
// facade 保留原 protected 方法作为转发入口。

// 功能：按统一优先级确认 facade 仍持有有效的冻结 Function authority。
// 输入/输出及副作用：configured/delegate_present/authority_binding 为准入条件；后三个
//   authority_* 是 configure 时冻结的 UID/generation/epoch；label 用于诊断前缀；只读。
// 失败/边界：未配置/无 delegate/binding 为空返回 INVALID_STATE；UID、generation 或 epoch 不符
//   返回 STALE_GENERATION；binding 非 ACTIVE 返回 INVALID_STATE；validate() 失败则原样返回。
function automatic rdma_status rdma_validate_live_authority(
  input bit configured,
  input bit delegate_present,
  input rdma_function_binding authority_binding,
  input longint unsigned authority_function_uid,
  input int unsigned authority_generation,
  input rdma_reset_epoch_t authority_reset_epoch,
  input string label
);
  rdma_status status;

  if (!configured || !delegate_present || authority_binding == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " facade is not configured"});

  // 先比较冻结坐标再调用 binding.validate()，避免 reset/重绑后的漂移被误报为普通参数错误。
  if (authority_binding.function_uid != authority_function_uid ||
      authority_binding.generation != authority_generation ||
      authority_binding.function_reset_epoch() != authority_reset_epoch)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " Function authority is stale"});
  if (authority_binding.state != RDMA_BIND_ACTIVE)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " Function binding is not ACTIVE"});

  status = rdma_status::nonnull(
    authority_binding.validate(),
    {label, " binding validation returned null"}
  );
  if (!status.ok())
    return status;
  return rdma_status::success();
endfunction
