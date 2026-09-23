// 目录：模型层 model/rdma_authority_validation.sv。
// 职责：集中实现各 queue facade 共用的 Function authority 活性校验，统一配置状态、
//   incarnation 快照、binding 状态和下游 validate() 的错误优先级。
// 主要依赖：rdma_function_binding、rdma_status 以及 rdma_reset_epoch_t；本文件只读取
//   facade 传入的快照和非拥有 binding 引用，不访问 queue runtime、Host-memory 或 MMIO。
// 所有权与生命周期：helper 不保存任何输入引用、不取得 delegate/binding 所有权；返回的
//   rdma_status 由调用方消费，调用方继续负责 facade 与 binding 的生命周期。

// 设计说明：CQ/EQ/RQ/SQ facade 都必须在入口先拒绝未配置或缺少 delegate 的调用，
// 再比较配置时冻结的 Function UID、generation、reset epoch，最后验证 binding 仍为
// ACTIVE 且自身校验成功。把这段纯 admission 逻辑放在 model package，可减少四份
// 易漂移实现，同时让 facade 保留原 protected 方法作为兼容转发入口。

// 功能：rdma_validate_live_authority 按统一优先级确认 facade 仍可使用其冻结的
//       Function authority，并把 binding.validate() 的结果原样传回调用方。
// 输入/输出及副作用：configured 表示 facade 是否完成 configure，delegate_present 表示
//       共享 queue-data delegate 是否存在；authority_binding 为借用的 binding，后三个
//       authority_* 参数是 configure 时冻结的 UID/generation/reset epoch，label 仅用于
//       诊断前缀。函数只读这些输入并返回新建或转发的 rdma_status，不修改任何账本、
//       cursor、delegate、binding 或外部资源。
// 失败/边界：configured 为 0、delegate_present 为 0 或 binding 为空时返回
//       INVALID_STATE；UID、generation 或 reset epoch 与 binding 当前值不一致时返回
//       STALE_GENERATION；binding 非 ACTIVE、validate() 返回 null 或返回失败状态时分别
//       返回 INVALID_STATE 或该失败状态；只有全部检查通过才返回 success。
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

  // 先比较冻结的 authority 坐标，再调用 binding.validate()，避免把 reset/重绑
  // 后的镜像漂移误报成普通参数错误。
  if (authority_binding.function_uid != authority_function_uid ||
      authority_binding.generation != authority_generation ||
      authority_binding.function_reset_epoch() != authority_reset_epoch)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " Function authority is stale"});
  if (authority_binding.state != RDMA_BIND_ACTIVE)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " Function binding is not ACTIVE"});

  status = authority_binding.validate();
  if (status == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             {label, " binding validation returned null"});
  if (!status.ok())
    return status;
  return rdma_status::success();
endfunction
