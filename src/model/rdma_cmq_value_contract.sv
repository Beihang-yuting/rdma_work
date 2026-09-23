// 目录：模型层 model/rdma_cmq_value_contract.sv。
// 职责：集中 CMQ handle、status、image、mapping 与 ticket 的纯值比较契约。
// 依赖：依赖 rdma_cmq_engine_models.sv 的 opcode/expected/ticket 值以及
// rdma_cmq_execution_models.sv 导出的 required-status shape 校验。
// 所有权与生命周期：所有 helper 都是无状态纯函数，只读输入对象；
// 不保存引用、不授予 authority，也不接管 engine、adapter 或外部资源。

// 设计说明：instance 版本保留 rdma_handle::same_instance() 的现有身份
// 语义，detached 版本才比较公开字段；两者都不证明 SystemVerilog
// 对象引用相同，alias topology 仍由边界调用方单独校验。

// 功能：按 rdma_handle::same_instance() 判断两个 handle 是否表示同一资源 incarnation。
// 输入/输出及副作用：lhs/rhs 为只读 handle；返回 instance 值比较结果，不修改对象或账本。
// 失败/边界：任一输入为 null 时返回 0；值相等不表示两个参考是同一对象。
function automatic bit rdma_cmq_same_handle_instance(
  input rdma_handle lhs,
  input rdma_handle rhs
);
  if (lhs == null || rhs == null)
    return 1'b0;
  return lhs.same_instance(rhs);
endfunction

// 功能：逐字段比较两个 detached handle 的 kind、Function UID、object ID 与 generation。
// 输入/输出及副作用：lhs/rhs 为只读 handle；返回公开值是否相等，不修改句柄或外部状态。
// 失败/边界：任一 handle 为 null 或任一被比较字段含 X/Z 时返回 0；不推断对象 alias。
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
// 输入/输出及副作用：lhs/rhs 为只读 status；比较 category、code、硬件证据、身份、严重度与文本，不复制对象。
// 失败/边界：null、不受支持的 runtime subtype 或含 spare/X/Z 的 required-status shape 返回 0；alias 关系不在本函数中判定。
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

// 功能：按现有整体结构比较语义判断两个 PCIe BDF 是否相等。
// 输入/输出及副作用：lhs/rhs 为值输入；使用原有 `==` 表达式返回 bit，不修改 route 或资源。
// 失败/边界：没有 null 或错误码分支；本函数不改用 case equality，也不校验 BDF 是否可路由。
function automatic bit rdma_cmq_same_bdf_value(
  input rdma_bdf_t lhs,
  input rdma_bdf_t rhs
);
  return lhs == rhs;
endfunction

// 功能：先比较 cardinality，再按索引比较两个 byte queue 的全部元素。
// 输入/输出及副作用：lhs/rhs 为只读 queue 值；返回内容是否相等，不调整 queue 长度或元素。
// 失败/边界：长度不同或首个不同元素立即返回 0；两个空 queue 返回 1。
function automatic bit rdma_cmq_same_byte_queue_value(
  input byte unsigned lhs[$],
  input byte unsigned rhs[$]
);
  if (lhs.size() != rhs.size())
    return 1'b0;
  foreach (lhs[i])
    if (lhs[i] != rhs[i])
      return 1'b0;
  return 1'b1;
endfunction

// 功能：先比较 cardinality，再按索引比较两个 string queue 的全部元素。
// 输入/输出及副作用：lhs/rhs 为只读 queue 值；返回内容是否相等，不修改文本或 queue。
// 失败/边界：长度不同或首个不同元素立即返回 0；两个空 queue 返回 1。
function automatic bit rdma_cmq_same_string_queue_value(
  input string lhs[$],
  input string rhs[$]
);
  if (lhs.size() != rhs.size())
    return 1'b0;
  foreach (lhs[i])
    if (lhs[i] != rhs[i])
      return 1'b0;
  return 1'b1;
endfunction

// 功能：比较两个 hardware image 的 bytes、metadata、写目标与 field summary。
// 输入/输出及副作用：lhs/rhs 为只读 image；返回完整公开值是否相等，不复制 image 或 backing authority。
// 失败/边界：任一 image 为 null、queue 长度/内容不同或任一列出的 metadata/target 字段不同时返回 0；不额外执行 shape 校验。
function automatic bit rdma_cmq_same_image_value(
  input rdma_hw_image lhs,
  input rdma_hw_image rhs
);
  if (lhs == null || rhs == null)
    return 1'b0;
  return rdma_cmq_same_byte_queue_value(lhs.bytes, rhs.bytes) &&
         lhs.length == rhs.length &&
         lhs.alignment == rhs.alignment &&
         lhs.endian == rhs.endian &&
         lhs.image_kind == rhs.image_kind &&
         lhs.hardware_version == rhs.hardware_version &&
         lhs.function_generation == rhs.function_generation &&
         lhs.write_target_kind == rhs.write_target_kind &&
         lhs.backing_target.value == rhs.backing_target.value &&
         lhs.hmc_target.value == rhs.hmc_target.value &&
         lhs.bar_target.value == rhs.bar_target.value &&
         rdma_cmq_same_string_queue_value(lhs.field_summary,
                                          rhs.field_summary);
endfunction

// 功能：比较两个 CMQ expected response 的 hardware opcode 与 variant。
// 输入/输出及副作用：lhs/rhs 为只读 expected-response 对象；返回值比较结果，不调用 validate 或修改对象。
// 失败/边界：任一输入为 null 时返回 0；本函数不新增 variant/opcode shape gate。
function automatic bit rdma_cmq_same_expected_value(
  input rdma_cmq_expected_response lhs,
  input rdma_cmq_expected_response rhs
);
  if (lhs == null || rhs == null)
    return 1'b0;
  return lhs.hardware_opcode == rhs.hardware_opcode &&
         lhs.variant == rhs.variant;
endfunction

// 功能：比较两个 CMQ opcode key 的 profile、opcode 与 variant。
// 输入/输出及副作用：lhs/rhs 为只读 opcode key；返回值比较结果，不修改 profile registry 或对象。
// 失败/边界：任一 key 为 null 时返回 0；本函数不执行 validate，保留现有宽松值契约。
function automatic bit rdma_cmq_same_opcode_value(
  input rdma_cmq_opcode_key lhs,
  input rdma_cmq_opcode_key rhs
);
  if (lhs == null || rhs == null)
    return 1'b0;
  return lhs.profile_name == rhs.profile_name &&
         lhs.opcode == rhs.opcode && lhs.variant == rhs.variant;
endfunction

// 功能：比较两个 DMA mapping 的 Function/owner instance authority 与现有标量映射字段。
// 输入/输出及副作用：lhs/rhs 为只读 mapping；返回句柄 instance 与标量值是否全部一致，不修改 DMA 状态。
// 失败/边界：mapping、function_h 或 owner_h 任一为 null 时返回 0；
// 不比较 route/epoch/UMEM 等现有契约未列出的字段，也不新增 shape gate。
function automatic bit rdma_cmq_same_mapping_instance_value(
  input rdma_dma_mapping lhs,
  input rdma_dma_mapping rhs
);
  if (lhs == null || rhs == null ||
      lhs.function_h == null || rhs.function_h == null ||
      lhs.owner_h == null || rhs.owner_h == null)
    return 1'b0;
  return lhs.function_h.same_instance(rhs.function_h) &&
         lhs.requester_bdf == rhs.requester_bdf &&
         lhs.pasid_valid == rhs.pasid_valid &&
         lhs.pasid == rhs.pasid &&
         lhs.dma_domain_valid == rhs.dma_domain_valid &&
         lhs.dma_domain_id == rhs.dma_domain_id &&
         lhs.backing_addr.value == rhs.backing_addr.value &&
         lhs.iova.value == rhs.iova.value &&
         lhs.size == rhs.size &&
         lhs.direction == rhs.direction &&
         lhs.permissions == rhs.permissions &&
         lhs.state == rhs.state &&
         lhs.owner_h.same_instance(rhs.owner_h);
endfunction

// 功能：比较两个 CMQ ticket，并用 same_instance() 保留 Function/CMQ authority 语义。
// 输入/输出及副作用：lhs/rhs 为只读 ticket；比较 command、handle instance、slot、opcode 与 deadline，不修改 journal。
// 失败/边界：ticket 或嵌套 Function/CMQ handle 为 null 时返回 0；
// opcode_key 为 null 时由嵌套 opcode comparator 返回 0；不新增 ticket shape gate，
// 且 instance 值相等不证明对象 alias。
function automatic bit rdma_cmq_same_ticket_instance_value(
  input rdma_cmq_ticket lhs,
  input rdma_cmq_ticket rhs
);
  if (lhs == null || rhs == null ||
      lhs.function_h == null || rhs.function_h == null ||
      lhs.cmq_h == null || rhs.cmq_h == null)
    return 1'b0;
  return lhs.command_id == rhs.command_id &&
         lhs.function_h.same_instance(rhs.function_h) &&
         lhs.cmq_h.same_instance(rhs.cmq_h) &&
         lhs.slot_sequence == rhs.slot_sequence &&
         lhs.sq_index == rhs.sq_index &&
         lhs.sq_wrap == rhs.sq_wrap &&
         rdma_cmq_same_opcode_value(lhs.opcode_key, rhs.opcode_key) &&
         lhs.absolute_deadline == rhs.absolute_deadline;
endfunction

// 功能：比较两个 caller/journal detached ticket 的公开 immutable 值。
// 输入/输出及副作用：lhs/rhs 为只读 ticket；逐字段比较嵌套 handle 以及 command、slot、opcode、deadline，不修改对象。
// 失败/边界：ticket 或嵌套 handle/key 为 null、句柄字段含 X/Z 或任一列出值不同时返回 0；不授予可变对象 alias authority。
function automatic bit rdma_cmq_same_ticket_detached_value(
  input rdma_cmq_ticket lhs,
  input rdma_cmq_ticket rhs
);
  if (lhs == null || rhs == null || lhs.function_h == null ||
      rhs.function_h == null || lhs.cmq_h == null || rhs.cmq_h == null)
    return 1'b0;
  return lhs.command_id == rhs.command_id &&
         rdma_cmq_same_handle_value(lhs.function_h, rhs.function_h) &&
         rdma_cmq_same_handle_value(lhs.cmq_h, rhs.cmq_h) &&
         lhs.slot_sequence == rhs.slot_sequence &&
         lhs.sq_index == rhs.sq_index &&
         lhs.sq_wrap == rhs.sq_wrap &&
         rdma_cmq_same_opcode_value(lhs.opcode_key, rhs.opcode_key) &&
         lhs.absolute_deadline == rhs.absolute_deadline;
endfunction
