// 目录：模型层 model/rdma_cmq_typed_snapshot_contract.sv。
// 职责：集中 CMQ Function、handle、opcode、expected response 与 hardware image
// 的有类型快照契约。
// 依赖：rdma_cmq_value_contract.sv 的 image 值比较、已定义的 CMQ opcode
// 与 image shape 校验，以及 rdma_status 的 factory-backed 状态构造。
// 所有权与生命周期：helper 不保存引用或取得输入对象所有权；
// 成功时由调用方接管独立快照，失败时输出始终为 null。

// 设计说明：handle 与 Function handle 字段完全相同，共用 identity 快照实现（Function 版本
//   再做一次子类型 cast）；其余路径各自保留 cast、runtime type、factory、clone 与恢复顺序。

// 功能：handle 与 Function handle 共用的快照实现：clone 后恢复 source 四个身份字段，
//   要求副本类型名不变、非自别名且四字段与 source 一致。
// 输入/输出及副作用：noun 只用于诊断（"handle"/"Function"）；snapshot 成功时为新副本。
// 失败/边界：source 为 null、clone 契约失败或字段漂移时按 failure_code 拒绝，snapshot 为 null。
function automatic rdma_status rdma_cmq_checked_identity_snapshot(
  input rdma_handle source,
  input string label,
  input string noun,
  input rdma_status_code_e failure_code,
  output rdma_handle snapshot
);
  uvm_object cloned_object;
  string source_type_name;
  rdma_resource_kind_e saved_kind;
  longint unsigned saved_function_uid;
  int unsigned saved_object_id;
  int unsigned saved_generation;

  snapshot = null;
  if (source == null)
    return rdma_status::make(failure_code, {label, " ", noun, " is null"});
  saved_kind = source.kind;
  source_type_name = source.get_type_name();
  saved_function_uid = source.function_uid;
  saved_object_id = source.object_id;
  saved_generation = source.generation;
  cloned_object = source.clone();
  source.kind = saved_kind;
  source.function_uid = saved_function_uid;
  source.object_id = saved_object_id;
  source.generation = saved_generation;
  if (cloned_object == null || !$cast(snapshot, cloned_object) ||
      snapshot == source || snapshot.get_type_name() != source_type_name) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " ", noun, " snapshot clone contract failed"}
    );
  end
  if (source.kind != saved_kind ||
      source.function_uid != saved_function_uid ||
      source.object_id != saved_object_id ||
      source.generation != saved_generation ||
      snapshot.kind != saved_kind ||
      snapshot.function_uid != saved_function_uid ||
      snapshot.object_id != saved_object_id ||
      snapshot.generation != saved_generation) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " ", noun, " snapshot changed its source value"}
    );
  end
  return rdma_status::success();
endfunction

// 功能：为 Function handle 构造保留 runtime type 与四个公开身份字段的独立 clone 快照。
// 输入/输出及副作用：snapshot 先清空；成功输出非 source 的 handle；clone 后按 kind、
//   function_uid、object_id、generation 的原顺序恢复 source。
// 失败/边界：source 为 null，clone 为 null/不能 cast/自别名/type 改变，或四字段不等时按
//   failure_code 拒绝；不比较 subtype 扩展字段，仍接受第三个等值对象。
function automatic rdma_status rdma_cmq_checked_function_snapshot(
  input rdma_function_handle source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_function_handle snapshot
);
  rdma_handle generic;
  rdma_status status;

  snapshot = null;
  status = rdma_cmq_checked_identity_snapshot(source, label, "Function",
                                              failure_code, generic);
  if (!status.ok())
    return status;
  if (!$cast(snapshot, generic))
    return rdma_status::make(
      failure_code, {label, " Function snapshot clone contract failed"}
    );
  return status;
endfunction

// 功能：为通用 handle 构造保留 runtime type 与四个公开身份字段的独立 clone 快照。
// 输入/输出及副作用：snapshot 先清空；成功输出非 source 的 handle；clone 后按 kind、
//   function_uid、object_id、generation 的原顺序恢复 source。
// 失败/边界：source 为 null，clone 为 null/不能 cast/自别名/type 改变，或四字段不等时按
//   failure_code 拒绝；不比较 subtype 扩展字段，仍接受第三个等值对象。
function automatic rdma_status rdma_cmq_checked_handle_snapshot(
  input rdma_handle source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_handle snapshot
);
  return rdma_cmq_checked_identity_snapshot(source, label, "handle",
                                            failure_code, snapshot);
endfunction

// 功能：先验证 CMQ opcode key，再构造保留 profile_name、opcode、variant 的 clone 快照。
// 输入/输出及副作用：snapshot 先清空；成功输出非 source 的 key；clone 后按原顺序恢复 source。
// 失败/边界：source 为 null 或 validate 返回 null 时按 failure_code 拒绝；source validate
//   失败原样返回且不 clone；clone 为 null/不能 cast/自别名、字段漂移或 snapshot 校验失败
//   均不发布；可 cast 的 subtype 不被拒绝。
function automatic rdma_status rdma_cmq_checked_opcode_snapshot(
  input rdma_cmq_opcode_key source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_cmq_opcode_key snapshot
);
  rdma_status status;
  uvm_object cloned_object;
  string saved_profile_name;
  bit [31:0] saved_opcode;
  string saved_variant;

  snapshot = null;
  if (source == null)
    return rdma_status::make(failure_code, {label, " opcode key is null"});
  status = source.validate();
  if (status == null)
    return rdma_status::make(
      failure_code, {label, " opcode validation returned null"}
    );
  if (!status.ok())
    return status;
  saved_profile_name = source.profile_name;
  saved_opcode = source.opcode;
  saved_variant = source.variant;
  cloned_object = source.clone();
  source.profile_name = saved_profile_name;
  source.opcode = saved_opcode;
  source.variant = saved_variant;
  if (cloned_object == null || !$cast(snapshot, cloned_object) ||
      snapshot == source) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " opcode snapshot clone contract failed"}
    );
  end
  if (source.profile_name != saved_profile_name ||
      source.opcode != saved_opcode || source.variant != saved_variant ||
      snapshot.profile_name != saved_profile_name ||
      snapshot.opcode != saved_opcode ||
      snapshot.variant != saved_variant) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " opcode snapshot changed its source value"}
    );
  end
  status = snapshot.validate();
  if (status == null) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " opcode snapshot validation returned null"}
    );
  end
  if (!status.ok())
    snapshot = null;
  return status;
endfunction

// 功能：验证 expected-response 后 clone 一次，锁存 clone 对 source 的篡改，只发布等值 candidate。
// 输入/输出及副作用：snapshot 先清空；clone 后立即锁存 source 漂移，再按 hardware_opcode、
//   variant 顺序恢复 source。
// 失败/边界：source 为 null、validate 为 null/失败、clone 为 null/不能 cast/self、source 被篡改
//   或 candidate 字段漂移时不发布；clone 契约优先于值漂移，第三个等值对象仍可接受。
function automatic rdma_status rdma_cmq_checked_expected_snapshot(
  input rdma_cmq_expected_response source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_cmq_expected_response snapshot
);
  uvm_object cloned_object;
  rdma_status status;
  bit [31:0] saved_hardware_opcode;
  string saved_variant;
  bit source_value_changed;

  snapshot = null;
  if (source == null)
    return rdma_status::make(
      failure_code, {label, " expected response is null"}
    );
  status = source.validate();
  if (status == null)
    return rdma_status::make(
      failure_code, {label, " expected validation returned null"}
    );
  if (!status.ok())
    return status;
  saved_hardware_opcode = source.hardware_opcode;
  saved_variant = source.variant;
  cloned_object = source.clone();
  source_value_changed =
    source.hardware_opcode != saved_hardware_opcode ||
    source.variant != saved_variant;
  source.hardware_opcode = saved_hardware_opcode;
  source.variant = saved_variant;
  if (cloned_object == null || !$cast(snapshot, cloned_object) ||
      snapshot == source) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " expected snapshot clone contract failed"}
    );
  end
  if (source_value_changed ||
      source.hardware_opcode != saved_hardware_opcode ||
      source.variant != saved_variant ||
      snapshot.hardware_opcode != saved_hardware_opcode ||
      snapshot.variant != saved_variant) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " expected snapshot changed its source value"}
    );
  end
  status = snapshot.validate();
  if (status == null) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " expected snapshot validation returned null"}
    );
  end
  if (!status.ok())
    snapshot = null;
  return status;
endfunction

// 功能：经 rdma_hw_image factory 捕获原值，再 clone image 并校验公开 byte/metadata/target/summary。
// 输入/输出及副作用：snapshot 先清空；成功输出非自别名、公开值相等的 clone（不要求保留
//   source subtype）；clone 后按原字段与 queue 顺序恢复 source；捕获与恢复只用无回调的元数据操作。
// 失败/边界：source 为 null、factory/clone 返回 null、不能 cast/自别名，或公开值与 saved_value
//   不等时按 failure_code 拒绝；不做 image shape 校验，仍接受非 canonical 等值 image；
//   saved-value 错型仍报 FCTTYP fatal。
function automatic rdma_status rdma_cmq_checked_image_snapshot(
  input rdma_hw_image source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_hw_image snapshot
);
  uvm_object cloned_object;
  rdma_hw_image saved_value;

  snapshot = null;
  if (source == null)
    return rdma_status::make(failure_code, {label, " image is null"});
  saved_value = rdma_hw_image::type_id::create({label, "_saved"});
  if (saved_value == null)
    return rdma_status::make(
      failure_code, {label, " image value capture failed"}
    );
  saved_value.bytes = source.bytes;
  rdma_hw_image::copy_metadata_noalloc(source, saved_value);
  saved_value.field_summary = source.field_summary;
  cloned_object = source.clone();
  source.bytes = saved_value.bytes;
  rdma_hw_image::copy_metadata_noalloc(saved_value, source);
  source.field_summary = saved_value.field_summary;
  if (cloned_object == null || !$cast(snapshot, cloned_object) ||
      snapshot == source) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " image snapshot clone contract failed"}
    );
  end
  if (!rdma_cmq_same_image_value(source, saved_value) ||
      !rdma_cmq_same_image_value(snapshot, saved_value)) begin
    snapshot = null;
    return rdma_status::make(
      failure_code, {label, " image snapshot changed its source value"}
    );
  end
  return rdma_status::success();
endfunction

// 功能：先完整执行 image factory/clone 契约，再构造 exact rdma_hw_image 作为 canonical 快照。
// 输入/输出及副作用：snapshot 先清空；成功输出与 source/factory_snapshot 无别名的 base image，
//   byte queue、metadata、targets、summary 逐项复制。
// 失败/边界：底层 helper 失败原样传播；clone 之后才检查 canonical shape 与全值等价，不满足时
//   按 failure_code 拒绝，不发布 partial snapshot。
function automatic rdma_status rdma_cmq_checked_canonical_image_snapshot(
  input rdma_hw_image source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_hw_image snapshot
);
  rdma_hw_image factory_snapshot;
  rdma_hw_image canonical_snapshot;
  rdma_status status;

  snapshot = null;
  status = rdma_cmq_checked_image_snapshot(
    source, label, failure_code, factory_snapshot
  );
  if (status == null || !status.ok())
    return status;
  canonical_snapshot = new({label, "_canonical"});
  canonical_snapshot.bytes = factory_snapshot.bytes;
  canonical_snapshot.length = factory_snapshot.length;
  canonical_snapshot.alignment = factory_snapshot.alignment;
  canonical_snapshot.endian = factory_snapshot.endian;
  canonical_snapshot.image_kind = factory_snapshot.image_kind;
  canonical_snapshot.hardware_version = factory_snapshot.hardware_version;
  canonical_snapshot.function_generation =
    factory_snapshot.function_generation;
  canonical_snapshot.write_target_kind = factory_snapshot.write_target_kind;
  canonical_snapshot.backing_target = factory_snapshot.backing_target;
  canonical_snapshot.hmc_target = factory_snapshot.hmc_target;
  canonical_snapshot.bar_target = factory_snapshot.bar_target;
  canonical_snapshot.field_summary = factory_snapshot.field_summary;
  if (!rdma_cmq_image_shape_valid(canonical_snapshot) ||
      !rdma_cmq_same_image_value(canonical_snapshot, factory_snapshot))
    return rdma_status::make(
      failure_code, {label, " canonical image value is invalid"}
    );
  snapshot = canonical_snapshot;
  return rdma_status::success();
endfunction
