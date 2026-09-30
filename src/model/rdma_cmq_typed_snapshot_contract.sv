// 目录：模型层 model/rdma_cmq_typed_snapshot_contract.sv。
// 职责：集中 CMQ Function、handle、opcode、expected response 与 hardware image
// 的有类型快照契约。
// 依赖：rdma_cmq_value_contract.sv 的 image 值比较、已定义的 CMQ opcode
// 与 image shape 校验，以及 rdma_status 的 factory-backed 状态构造。
// 所有权与生命周期：helper 不保存引用或取得输入对象所有权；
// 成功时由调用方接管独立快照，失败时输出始终为 null。

// 设计说明：六条路径分别保留自身的 cast、runtime type、factory、
// clone 与恢复顺序；不合并成无类型 helper，避免改变错误优先级或可观测次数。

// 功能：为 Function handle 构造保留 runtime type name 与四个公开身份字段的独立 clone 快照。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空，
// 成功时输出非 source 的 Function handle；clone 后按 kind、function_uid、
// object_id、generation 的原顺序恢复 source。
// 失败/边界：source 为 null，clone 为 null/不能 cast/自别名/runtime type name
// 改变，或 source/snapshot 四字段不等时用 failure_code 和原消息拒绝；
// 不比较 subtype 扩展字段，且保留对第三个等值对象的接受语义。
function automatic rdma_status rdma_cmq_checked_function_snapshot(
  input rdma_function_handle source,
  input string label,
  input rdma_status_code_e failure_code,
  output rdma_function_handle snapshot
);
  uvm_object cloned_object;
  string source_type_name;
  rdma_resource_kind_e saved_kind;
  longint unsigned saved_function_uid;
  int unsigned saved_object_id;
  int unsigned saved_generation;

  snapshot = null;
  if (source == null)
    return rdma_status::make(failure_code, {label, " Function is null"});
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
      failure_code, {label, " Function snapshot clone contract failed"}
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
      failure_code, {label, " Function snapshot changed its source value"}
    );
  end
  return rdma_status::success();
endfunction

// 功能：为通用 RDMA handle 构造保留 runtime type name 与四个公开身份字段的独立 clone 快照。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空，
// 成功时输出非 source 的 handle；clone 后按 kind、function_uid、
// object_id、generation 的原顺序恢复 source。
// 失败/边界：source 为 null，clone 为 null/不能 cast/自别名/runtime type name
// 改变，或 source/snapshot 四字段不等时用 failure_code 和原消息拒绝；
// 不比较 subtype 扩展字段，且保留对第三个等值对象的接受语义。
function automatic rdma_status rdma_cmq_checked_handle_snapshot(
  input rdma_handle source,
  input string label,
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
    return rdma_status::make(failure_code, {label, " handle is null"});
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
      failure_code, {label, " handle snapshot clone contract failed"}
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
      failure_code, {label, " handle snapshot changed its source value"}
    );
  end
  return rdma_status::success();
endfunction

// 功能：先验证 CMQ opcode key，再构造保留 profile_name、opcode 与 variant 的独立 clone 快照。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空，
// 成功时输出非 source 的 opcode key；validate 可构造状态，clone 后
// 按原顺序恢复 source 的三个字段。
// 失败/边界：source 为 null 或 validate 返回 null 时按 failure_code 拒绝；
// source validate 失败优先原样返回且不 clone；clone 为 null/不能 cast/自别名、
// 三字段漂移、snapshot validate 为 null 或失败均不发布 snapshot；不拒绝可 cast subtype。
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

// 功能：验证 expected-response 后执行一次 clone，锁存 hostile clone 对 caller
// source 的篡改，并只发布两个公开字段等值的独立 candidate。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空；
// clone 后立即锁存 source 漂移，再按 hardware_opcode、variant 顺序恢复 source；
// 成功时 snapshot 接收非 source 的合法 candidate，helper 不保存或取得对象所有权。
// 失败/边界：source 为 null，source/candidate validate 返回 null 或失败，clone
// 为 null/不能 cast/self，source 曾被 clone 篡改，或 candidate 字段漂移时不发布
// snapshot；clone-contract 优先于值漂移，第三个独立等值对象仍可接受。
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

// 功能：通过 rdma_hw_image factory 捕获原值，再 clone image 并校验
// 全部公开 byte、metadata、target 与 summary 投影。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空，
// 成功时输出非自别名、可转换且公开值相等的 clone，不要求保留
// source runtime subtype；saved_value 由 factory 创建，clone 后按原字段与 queue
// 顺序恢复 source；捕获与恢复只复用无回调的模型元数据操作，不替换 clone 窗口。
// 失败/边界：source 为 null、saved-value factory 返回 null、clone 为 null/不能
// cast/自别名，或 source/snapshot 公开值与 saved_value 不等时按 failure_code 和原消息
// 拒绝；本函数不执行 image shape 校验，保留对非 canonical 等值 image 的接受语义。
// saved-value typed factory 错型仍报 FCTTYP fatal，不改成 raw factory 的 non-fatal 策略。
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

// 功能：先完整消费 image factory/clone 契约，再构造 exact rdma_hw_image
// 作为 submission/journal 的 canonical 快照。
// 输入/输出及副作用：source/label/failure_code 为输入；snapshot 入口先清空，
// 成功时输出与 source 及 factory_snapshot 无别名的 exact base image；字节 queue、
// metadata、targets 与 summary 逐项复制到 new 对象。
// 失败/边界：底层 image helper 返回 null/失败状态时原样传播；必须在其
// clone 之后才检查 canonical shape 与全值等价，不满足时按 failure_code 和原消息
// 拒绝，不发布 partial snapshot。
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
