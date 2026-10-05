// 目录：模型层 model/rdma_cmq_value_contract.sv。
// 职责：CMQ port adapter 使用的 handle 与 status 纯值比较。
// 依赖：rdma_cmq_execution_models.sv 的 required-status shape 校验。
// 所有权与生命周期：全部为无状态纯函数，只读输入；不保存引用、不授予 authority。

// 功能：逐字段比较两个 handle 的 kind、function_uid、object_id、generation。
// 输入/输出及副作用：lhs/rhs 只读；返回公开值是否相等。
// 失败/边界：任一为 null 或字段含 X/Z 返回 0；不推断 alias。
function automatic bit rdma_cmq_same_handle_value(
  input rdma_handle lhs,
  input rdma_handle rhs
);
  if (lhs == null || rhs == null ||
      $isunknown(lhs.kind) || $isunknown(rhs.kind) ||
      $isunknown(lhs.function_uid) || $isunknown(rhs.function_uid) ||
      $isunknown(lhs.object_id) || $isunknown(rhs.object_id) ||
      $isunknown(lhs.generation) || $isunknown(rhs.generation))
    return 1'b0;
  return lhs.kind === rhs.kind &&
         lhs.function_uid === rhs.function_uid &&
         lhs.object_id === rhs.object_id &&
         lhs.generation === rhs.generation;
endfunction

// 功能：比较两个 required CMQ status 的完整诊断值。
// 输入/输出及副作用：lhs/rhs 只读；比较 category、code、硬件证据、身份、严重度与文本。
// 失败/边界：null 或 required-status shape 无效（含 spare/X/Z、不支持的 subtype）返回 0。
function automatic bit rdma_cmq_same_status_value(
  input rdma_status lhs,
  input rdma_status rhs
);
  if (lhs == null || rhs == null ||
      !rdma_cmq_status_shape_valid(lhs) ||
      !rdma_cmq_status_shape_valid(rhs))
    return 1'b0;
  return lhs.category === rhs.category &&
         lhs.code === rhs.code &&
         lhs.hardware_code === rhs.hardware_code &&
         lhs.hardware_code_valid === rhs.hardware_code_valid &&
         lhs.source_engine === rhs.source_engine &&
         lhs.function_uid === rhs.function_uid &&
         lhs.generation === rhs.generation &&
         lhs.resource_id === rhs.resource_id &&
         lhs.command_id === rhs.command_id &&
         lhs.wr_id === rhs.wr_id &&
         lhs.severity === rhs.severity &&
         lhs.retryable === rhs.retryable &&
         lhs.message == rhs.message;
endfunction
