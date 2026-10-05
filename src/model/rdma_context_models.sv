// 目录：协议与资源模型层 model/rdma_context_models.sv。
// 职责：实现 rdma_context_models 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_context_models.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_hw_model extends uvm_object;

  // 功能：构造 rdma_hw_model，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_model");
    super.new(name);
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、label、object_id_width、handle、handle.kind、handle.object_id、object_id_limit 并使用字段 object_id_limit；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  pure virtual function rdma_status validate();

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  pure virtual function string describe();
endclass

// Context handles carry hardware-projection/local IDs.  Resource-manager
// incarnation IDs remain opaque registry identities and are not used here.
// 功能：rdma_context_handle_status 校验 handle、expected_kind、object_id_width、label 与当前对象状态的一致性，并显式处理“handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：handle（输入）、expected_kind（输入）、object_id_width（输入）、label（输入）；rdma_context_handle_status 读取 handle、expected_kind、object_id_width、label 并使用字段 object_id_limit；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_context_handle_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_context_handle_status(
  rdma_handle handle,
  rdma_resource_kind_e expected_kind,
  int unsigned object_id_width,
  string label
);
  longint unsigned object_id_limit;

  if (handle == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle is null"});
  if (handle.kind != expected_kind)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " handle kind is invalid"});
  object_id_limit = 64'h1 << object_id_width;
  if ({32'b0, handle.object_id} >= object_id_limit)
    return rdma_status::make(
      RDMA_SC_INVALID_ARGUMENT,
      $sformatf("%s object ID exceeds %0d bits", label, object_id_width)
    );
  return rdma_status::success();
endfunction

// 功能：rdma_context_lifecycle_status 校验 reference、candidate、label 与当前对象状态的一致性，并显式处理“lifecycle handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：reference（输入）、candidate（输入）、label（输入）；rdma_context_lifecycle_status 读取 reference、candidate、label 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_context_lifecycle_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_context_lifecycle_status(
  rdma_handle reference,
  rdma_handle candidate,
  string label
);
  if (reference == null || candidate == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " lifecycle handle is null"});
  if (candidate.function_uid != reference.function_uid)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " function UID does not match"});
  if (candidate.generation != reference.generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             {label, " generation does not match"});
  return rdma_status::success();
endfunction

// 功能：rdma_function_incarnation_status 统一校验 Function UID、object ID、generation 和 reset epoch。
// 输入/输出及副作用：candidate、expected_uid、expected_object_id、expected_generation、expected_epoch 为输入；函数只返回状态，不修改句柄或资源账本。
// 失败/边界：空句柄/错误 kind 或 UID/object 不匹配返回 INVALID_ARGUMENT；generation/epoch 不匹配返回 STALE_GENERATION。
function automatic rdma_status rdma_function_incarnation_status(
  rdma_function_handle candidate,
  longint unsigned expected_uid,
  int unsigned expected_object_id,
  int unsigned expected_generation,
  rdma_reset_epoch_t expected_epoch,
  rdma_reset_epoch_t candidate_epoch = 0
);
  if (candidate == null || candidate.kind != RDMA_RESOURCE_FUNCTION)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "Function incarnation handle is invalid");
  if (candidate.function_uid != expected_uid ||
      candidate.object_id != expected_object_id)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "Function incarnation UID/object does not match");
  if (candidate.generation != expected_generation)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             "Function incarnation generation is stale");
  if (candidate_epoch != 0 && candidate_epoch != expected_epoch)
    return rdma_status::make(RDMA_SC_STALE_GENERATION,
                             "Function incarnation reset epoch is stale");
  return rdma_status::success();
endfunction

// 功能：rdma_context_state_status 校验 state、label 与当前对象状态的一致性，并显式处理“context state is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：state（输入）、label（输入）；rdma_context_state_status 读取 state、label 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_context_state_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_context_state_status(
  rdma_context_state_e state,
  string label
);
  if (!(state inside {RDMA_CONTEXT_INVALID, RDMA_CONTEXT_VALID,
                      RDMA_CONTEXT_ERROR}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " context state is invalid"});
  return rdma_status::success();
endfunction

// 功能：rdma_mr_state_status 校验 MRT 专用 INVLD/FREE/VLD 三态，避免把驱动的 FREE 状态误当成通用 context state。
// 输入/输出及副作用：state（输入）、label（输入）；函数只读取枚举和标签并返回状态，不修改 MRT、句柄或资源账本。
// 失败/边界：state 为 2'b11 时返回 RDMA_SC_INVALID_ARGUMENT；合法的 INVALID、FREE、VALID 三态均返回成功，label 只用于诊断文本。
function automatic rdma_status rdma_mr_state_status(
  rdma_mr_state_e state,
  string label
);
  if (!(state inside {RDMA_MR_STATE_INVALID, RDMA_MR_STATE_FREE,
                      RDMA_MR_STATE_VALID}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " MR state is invalid"});
  return rdma_status::success();
endfunction

// 功能：rdma_object_mode_status 校验 mode、label 与当前对象状态的一致性，并显式处理“object mode is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：mode（输入）、label（输入）；rdma_object_mode_status 读取 mode、label 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_object_mode_status 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_object_mode_status(
  rdma_object_mode_e mode,
  string label
);
  if (!(mode inside {RDMA_OBJECT_DIRECT_4K, RDMA_OBJECT_INDIRECT_4K,
                     RDMA_OBJECT_HUGE_2M,
                     RDMA_OBJECT_L3_INDIRECT_4K}))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             {label, " object mode is invalid"});
  return rdma_status::success();
endfunction

// 功能：rdma_context_nested_status 将 context model 依赖的 virtual validator
//       返回值规范化为可安全消费的 rdma_status。
// 输入/输出及副作用：status（输入）和 label（输入）；非空 status 原样返回，
//       null status 转换为 INVALID_STATE，不修改任何模型、句柄或资源账本。
// 失败/边界：null 表示下游扩展违反状态返回契约；调用方收到确定失败后不得
//       继续读取下游对象或发布 context image。
function automatic rdma_status rdma_context_nested_status(
  rdma_status status,
  string label
);
  if (status == null)
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      {label, " validation returned null status"}
    );
  return status;
endfunction

// 功能：rdma_clone_page_layout_value 复制 source、label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、label（输入）；rdma_clone_page_layout_value 读取 source、label 并使用字段 cloned_object；函数返回 rdma_page_table_layout，不取得调用方资源所有权。
// 失败/边界：rdma_clone_page_layout_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_page_table_layout rdma_clone_page_layout_value(
  rdma_page_table_layout source,
  string label
);
  uvm_object cloned_object;
  rdma_page_table_layout cloned_layout;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_layout, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " page layout clone mismatch"})
  return cloned_layout;
endfunction

// 功能：rdma_clone_ring_position_value 复制 source、label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、label（输入）；rdma_clone_ring_position_value 读取 source、label 并使用字段 cloned_object；函数返回 rdma_ring_position，不取得调用方资源所有权。
// 失败/边界：rdma_clone_ring_position_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_ring_position rdma_clone_ring_position_value(
  rdma_ring_position source,
  string label
);
  uvm_object cloned_object;
  rdma_ring_position cloned_position;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_position, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " ring position clone mismatch"})
  return cloned_position;
endfunction

// 功能：rdma_clone_address_vector_value 复制 source、label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、label（输入）；rdma_clone_address_vector_value 读取 source、label 并使用字段 cloned_object；函数返回 rdma_address_vector，不取得调用方资源所有权。
// 失败/边界：rdma_clone_address_vector_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_address_vector rdma_clone_address_vector_value(
  rdma_address_vector source,
  string label
);
  uvm_object cloned_object;
  rdma_address_vector cloned_vector;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_vector, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " address vector clone mismatch"})
  return cloned_vector;
endfunction

// 功能：rdma_clone_mr_page_layout_value 复制 source、label 的受控字段并生成独立快照，供查询、编码或恢复使用；源对象保持不变。
// 输入/输出及副作用：source（输入）、label（输入）；rdma_clone_mr_page_layout_value 读取 source、label 并使用字段 cloned_object；函数返回 rdma_mr_page_layout，不取得调用方资源所有权。
// 失败/边界：rdma_clone_mr_page_layout_value 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal，不保留部分有效快照。
function automatic rdma_mr_page_layout rdma_clone_mr_page_layout_value(
  rdma_mr_page_layout source,
  string label
);
  uvm_object cloned_object;
  rdma_mr_page_layout cloned_layout;

  if (source == null)
    return null;
  cloned_object = source.clone();
  if (cloned_object == null || !$cast(cloned_layout, cloned_object))
    `uvm_fatal("RDMA_COPY_TYPE", {label, " MR page layout clone mismatch"})
  return cloned_layout;
endfunction

class rdma_qpc_behavior extends uvm_object;
  `uvm_object_utils(rdma_qpc_behavior)

  int unsigned transport_version;
  bit migration_enable;
  bit tx_endian_swap;
  bit rx_endian_swap;
  bit read_after_write_fence;
  bit atomic_after_atomic_fence;
  int unsigned \priority ;

  // 功能：构造 rdma_qpc_behavior，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：transport_version=0；migration_enable=1'b0；tx_endian_swap=1'b1；rx_endian_swap=1'b1；read_after_write_fence=1'b1；atomic_after_atomic_fence=1'b1；priority=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_behavior 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_behavior");
    super.new(name);
    transport_version = 0;
    migration_enable = 1'b0;
    tx_endian_swap = 1'b1;
    rx_endian_swap = 1'b1;
    read_after_write_fence = 1'b1;
    atomic_after_atomic_fence = 1'b1;
    \priority = 0;
  endfunction

  // 功能：将 rhs 中 rdma_qpc_behavior 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QPC behavior copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_behavior rhs_behavior;

    super.do_copy(rhs);
    if (!$cast(rhs_behavior, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QPC behavior copy mismatch")
    transport_version = rhs_behavior.transport_version;
    migration_enable = rhs_behavior.migration_enable;
    tx_endian_swap = rhs_behavior.tx_endian_swap;
    rx_endian_swap = rhs_behavior.rx_endian_swap;
    read_after_write_fence = rhs_behavior.read_after_write_fence;
    atomic_after_atomic_fence = rhs_behavior.atomic_after_atomic_fence;
    \priority = rhs_behavior.\priority ;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QPC transport version exceeds 3”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、transport_version、priority 并使用字段 rdma_status、transport_version、priority；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QPC transport version exceeds 3”“QPC priority exceeds 7”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (transport_version > 3)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC transport version exceeds 3");
    if (\priority > 7)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC priority exceeds 7");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf(
      "Behavior(tver=%0d migration=%0b tx_swap=%0b rx_swap=%0b ra_fence=%0b atomic_fence=%0b priority=%0d)",
      transport_version, migration_enable, tx_endian_swap, rx_endian_swap,
      read_after_write_fence, atomic_after_atomic_fence, \priority
    );
  endfunction
endclass

virtual class rdma_qpc_transport_ext extends uvm_object;

  // 功能：构造 rdma_qpc_transport_ext，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_transport_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_transport_ext");
    super.new(name);
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取 对象字段：retry_count、rnr_retry_count 并使用字段 name、remote_qpn、send_psn、recv_psn、retry_count、rnr_retry_count；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  pure virtual function rdma_transport_e transport_kind();

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“rdma_qpc_rc_ext”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 name、remote_qpn、send_psn、recv_psn、retry_count 和 rnr_retry_count，返回 RC 扩展上下文的字段约束状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 在 name 不是 rdma_qpc_rc_ext 或任一 PSN/重试字段超出编码范围时返回错误；成功路径不修改上下文，也不接管外部资源。
  pure virtual function rdma_status validate();

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  pure virtual function string describe();
endclass

class rdma_qpc_rc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_rc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] send_psn;
  bit [23:0] recv_psn;
  int unsigned retry_count;
  int unsigned rnr_retry_count;

  // 功能：构造 rdma_qpc_rc_ext，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：remote_qpn='0；send_psn='0；recv_psn='0；retry_count='0；rnr_retry_count='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_rc_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_rc_ext");
    super.new(name);
    remote_qpn = '0;
    send_psn = '0;
    recv_psn = '0;
    retry_count = '0;
    rnr_retry_count = '0;
  endfunction

  // 功能：将 rhs 中 rdma_qpc_rc_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（RC QPC extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_rc_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "RC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    send_psn = rhs_ext.send_psn;
    recv_psn = rhs_ext.recv_psn;
    retry_count = rhs_ext.retry_count;
    rnr_retry_count = rhs_ext.rnr_retry_count;
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_RC；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_RC;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“RC QPC remote QPN is zero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、remote_qpn 并使用字段 rdma_status、remote_qpn；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“RC QPC remote QPN is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RC QPC remote QPN is zero");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("RC(remote_qpn=%0d send_psn=%0d recv_psn=%0d)",
                     remote_qpn, send_psn, recv_psn);
  endfunction
endclass

class rdma_qpc_ud_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_ud_ext)

  bit [31:0] qkey;
  // 驱动在 UD QPC 中单独提供目标 QPN；它不能由 qkey 的低 24 位推导。
  bit [23:0] destination_qpn;

  // 功能：构造 rdma_qpc_ud_ext，调用 super.new 建立 UVM 对象，并把 qkey 与独立目标 QPN 初始化为零。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_ud_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_ud_ext");
    super.new(name);
    qkey = '0;
    destination_qpn = '0;
  endfunction

  // 功能：将 rhs 中 rdma_qpc_ud_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（UD QPC extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_ud_ext rhs_ext;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "UD QPC extension copy mismatch")
    qkey = rhs_ext.qkey;
    destination_qpn = rhs_ext.destination_qpn;
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_UD；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_UD;
  endfunction

  // 功能：validate 校验 UD QPC 的 qkey 是否满足现有抽象模型的基本约束，同时保留独立 destination_qpn。
  // 输入/输出及副作用：无显式参数；validate 只读 qkey，返回 rdma_status，不修改模型或资源账本。
  // 失败/边界：qkey 为零时返回 RDMA_SC_INVALID_ARGUMENT；destination_qpn 的零值语义由具体驱动命令决定，不能在通用模型中擅自拒绝。
  virtual function rdma_status validate();
    if (qkey == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UD QPC qkey is zero");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 UD QPC 的 qkey 与独立目标 QPN 编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("UD(qkey=0x%08x destination_qpn=0x%06x)",
                     qkey, destination_qpn);
  endfunction
endclass

class rdma_qpc_urc_ext extends rdma_qpc_transport_ext;
  `uvm_object_utils(rdma_qpc_urc_ext)

  bit [23:0] remote_qpn;
  bit [23:0] rbsn;
  bit [23:0] dbsn;
  bit [23:0] rpsn;
  bit [23:0] dpsn;
  rdma_urc_queue_config queues;

  // 功能：构造 rdma_qpc_urc_ext，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：remote_qpn='0；rbsn='0；dbsn='0；rpsn='0；dpsn='0；queues=rdma_urc_queue_config::type_id::create("queues")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_urc_ext 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_urc_ext");
    super.new(name);
    remote_qpn = '0;
    rbsn = '0;
    dbsn = '0;
    rpsn = '0;
    dpsn = '0;
    queues = rdma_urc_queue_config::type_id::create("queues");
  endfunction

  // 功能：将 rhs 中 rdma_qpc_urc_ext 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（URC QPC extension copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_urc_ext rhs_ext;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_ext, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "URC QPC extension copy mismatch")
    remote_qpn = rhs_ext.remote_qpn;
    rbsn = rhs_ext.rbsn;
    dbsn = rhs_ext.dbsn;
    rpsn = rhs_ext.rpsn;
    dpsn = rhs_ext.dpsn;
    if (rhs_ext.queues == null) begin
      queues = null;
    end
    else begin
      cloned_object = rhs_ext.queues.clone();
      if (cloned_object == null || !$cast(queues, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "URC queue configuration clone mismatch")
    end
  endfunction

  // 功能：transport_kind 使用 当前对象字段 计算并返回 rdma_transport_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：无显式参数；transport_kind 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 rdma_transport_e，不取得调用方资源所有权。
  // 失败/边界：transport_kind 是只读访问器，返回 RDMA_TRANSPORT_URC；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  virtual function rdma_transport_e transport_kind();
    return RDMA_TRANSPORT_URC;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“URC QPC remote QPN is zero”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、remote_qpn、queues 并使用字段 rdma_status、remote_qpn、queues；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“URC QPC remote QPN is zero”“URC QPC queue configuration is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    if (remote_qpn == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC QPC remote QPN is zero");
    if (queues == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC QPC queue configuration is null");
    status = rdma_context_nested_status(
      queues.validate(), "URC QPC queue configuration"
    );
    return status;
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    string queues_text;

    queues_text = (queues == null) ? "null" : queues.describe();
    return $sformatf(
      "URC(remote_qpn=%0d rbsn=%0d dbsn=%0d rpsn=%0d dpsn=%0d queues=%s)",
      remote_qpn, rbsn, dbsn, rpsn, dpsn, queues_text
    );
  endfunction
endclass

class rdma_qpc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_qpc_model)

  rdma_handle qp_h;
  rdma_handle pd_h;
  rdma_handle send_cq_h;
  rdma_handle recv_cq_h;
  rdma_handle srq_h;
  rdma_transport_e transport;
  rdma_qp_state_e state;
  int unsigned host_id;
  int unsigned vf_id;
  int unsigned stat_index;
  bit [15:0] pkey;
  bit [7:0] qp_sequence;
  rdma_rdma_access_t access;
  int unsigned path_mtu_bytes;
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_backing_addr_t sq_backing;
  rdma_backing_addr_t rq_backing;
  rdma_backing_addr_t context_backing;
  rdma_object_mode_e sq_mode;
  rdma_object_mode_e rq_mode;
  rdma_address_vector address_vector;
  bit signature_enable;
  bit tx_flow_control;
  bit rx_flow_control;
  rdma_qpc_behavior behavior;
  rdma_qpc_transport_ext transport_ext;

  // 功能：构造 rdma_qpc_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：qp_h=null；pd_h=null；send_cq_h=null；recv_cq_h=null；srq_h=null；transport=RDMA_TRANSPORT_RC；state=RDMA_QPS_RESET；host_id='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qpc_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qpc_model");
    super.new(name);
    qp_h = null;
    pd_h = null;
    send_cq_h = null;
    recv_cq_h = null;
    srq_h = null;
    transport = RDMA_TRANSPORT_RC;
    state = RDMA_QPS_RESET;
    host_id = '0;
    vf_id = '0;
    stat_index = '0;
    pkey = '0;
    qp_sequence = '0;
    access = '0;
    path_mtu_bytes = '0;
    sq_depth = '0;
    rq_depth = '0;
    sq_backing = '0;
    rq_backing = '0;
    context_backing = '0;
    sq_mode = RDMA_OBJECT_DIRECT_4K;
    rq_mode = RDMA_OBJECT_DIRECT_4K;
    address_vector = rdma_address_vector::type_id::create("address_vector");
    signature_enable = 1'b0;
    tx_flow_control = 1'b0;
    rx_flow_control = 1'b0;
    behavior = rdma_qpc_behavior::type_id::create("behavior");
    transport_ext = null;
  endfunction

  // 功能：将 rhs 中 rdma_qpc_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QPC model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qpc_model rhs_qpc;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_qpc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "QPC model copy mismatch")
    qp_h = rdma_clone_handle_value(rhs_qpc.qp_h, "QPC QP");
    pd_h = rdma_clone_handle_value(rhs_qpc.pd_h, "QPC PD");
    send_cq_h = rdma_clone_handle_value(rhs_qpc.send_cq_h, "QPC send CQ");
    recv_cq_h = rdma_clone_handle_value(rhs_qpc.recv_cq_h,
                                        "QPC receive CQ");
    srq_h = rdma_clone_handle_value(rhs_qpc.srq_h, "QPC SRQ");
    transport = rhs_qpc.transport;
    state = rhs_qpc.state;
    host_id = rhs_qpc.host_id;
    vf_id = rhs_qpc.vf_id;
    stat_index = rhs_qpc.stat_index;
    pkey = rhs_qpc.pkey;
    qp_sequence = rhs_qpc.qp_sequence;
    access = rhs_qpc.access;
    path_mtu_bytes = rhs_qpc.path_mtu_bytes;
    sq_depth = rhs_qpc.sq_depth;
    rq_depth = rhs_qpc.rq_depth;
    sq_backing = rhs_qpc.sq_backing;
    rq_backing = rhs_qpc.rq_backing;
    context_backing = rhs_qpc.context_backing;
    sq_mode = rhs_qpc.sq_mode;
    rq_mode = rhs_qpc.rq_mode;
    address_vector = rdma_clone_address_vector_value(rhs_qpc.address_vector,
                                                     "QPC");
    signature_enable = rhs_qpc.signature_enable;
    tx_flow_control = rhs_qpc.tx_flow_control;
    rx_flow_control = rhs_qpc.rx_flow_control;
    if (rhs_qpc.behavior == null) begin
      behavior = null;
    end
    else begin
      cloned_object = rhs_qpc.behavior.clone();
      if (cloned_object == null || !$cast(behavior, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QPC behavior clone mismatch")
    end
    if (rhs_qpc.transport_ext == null) begin
      transport_ext = null;
    end
    else begin
      cloned_object = rhs_qpc.transport_ext.clone();
      if (cloned_object == null || !$cast(transport_ext, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "QPC extension clone mismatch")
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QPC behavior is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、behavior、path_mtu_bytes、srq_h、sq_depth、state、sq_backing.value、hfff 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QPC behavior is null”“QPC path MTU is zero”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;

    if (behavior == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC behavior is null");
    status = rdma_context_nested_status(
      behavior.validate(), "QPC behavior"
    );
    if (!status.ok())
      return status;
    if (path_mtu_bytes == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC path MTU is zero");
    status = rdma_context_handle_status(qp_h, RDMA_RESOURCE_QP, 21,
                                        "QPC QP");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "QPC PD");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(send_cq_h, RDMA_RESOURCE_CQ, 20,
                                        "QPC send CQ");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(recv_cq_h, RDMA_RESOURCE_CQ, 20,
                                        "QPC receive CQ");
    if (!status.ok()) return status;
    if (srq_h != null) begin
      status = rdma_context_handle_status(srq_h, RDMA_RESOURCE_SRQ, 15,
                                          "QPC SRQ");
      if (!status.ok()) return status;
    end
    status = rdma_context_lifecycle_status(qp_h, pd_h, "QPC PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(qp_h, send_cq_h, "QPC send CQ");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(qp_h, recv_cq_h,
                                           "QPC receive CQ");
    if (!status.ok()) return status;
    if (srq_h != null) begin
      status = rdma_context_lifecycle_status(qp_h, srq_h, "QPC SRQ");
      if (!status.ok()) return status;
    end
    if (!rdma_is_power_of_two(sq_depth) ||
        !rdma_is_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC depth is not a nonzero power of two");
    if (!(state inside {RDMA_QPS_RESET, RDMA_QPS_INIT, RDMA_QPS_RTR,
                        RDMA_QPS_RTS, RDMA_QPS_SQD, RDMA_QPS_SQE,
                        RDMA_QPS_ERROR}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC state is invalid");
    if ((sq_backing.value & 64'hfff) != 0 ||
        (rq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC queue backing is not 4 KiB aligned");
    if ((context_backing.value & 64'h1ff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC context backing is not 512-byte aligned");
    status = rdma_object_mode_status(sq_mode, "QPC SQ");
    if (!status.ok()) return status;
    status = rdma_object_mode_status(rq_mode, "QPC RQ");
    if (!status.ok()) return status;
    if (address_vector == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC address vector is null");
    status = rdma_context_nested_status(
      address_vector.validate(), "QPC address vector"
    );
    if (!status.ok())
      return status;
    if (transport_ext == null || transport_ext.transport_kind() != transport)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QPC transport extension does not match");
    case (transport)
      RDMA_TRANSPORT_RC:
        if (!$cast(rc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "RC QPC lacks an RC extension");
      RDMA_TRANSPORT_UD:
        if (!$cast(ud_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "UD QPC lacks a UD extension");
      RDMA_TRANSPORT_URC:
        if (!$cast(urc_ext, transport_ext))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "URC QPC lacks a URC extension");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "QPC transport is unsupported");
    endcase
    status = rdma_context_nested_status(
      transport_ext.validate(), "QPC transport extension"
    );
    if (!status.ok())
      return status;
    if (transport == RDMA_TRANSPORT_URC) begin
      if (urc_ext.queues == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "URC QPC queue configuration disappeared after validation"
        );
      if (urc_ext.queues.rq_sequence_threshold_entries > rq_depth)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "URC RQ sequence threshold exceeds QPC RQ depth"
        );
      if (urc_ext.queues.sq_completion_threshold_entries > sq_depth)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "URC SQ completion threshold exceeds QPC SQ depth"
        );
    end
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    string behavior_text;
    string extension_text;

    behavior_text = (behavior == null) ? "null" : behavior.describe();
    extension_text = (transport_ext == null) ? "null"
                                             : transport_ext.describe();
    return $sformatf(
      "QPC(transport=%s mtu=%0d sq_depth=%0d rq_depth=%0d behavior=%s ext=%s)",
      transport.name(), path_mtu_bytes, sq_depth, rq_depth, behavior_text,
      extension_text
    );
  endfunction
endclass

// 中文设计：共享 CQ 的 URC shadow 是跨 reset/flush 边界传递的值快照。
// 它只携带 CQ/Function authority 与可恢复游标，不持有 queue runtime、DMA
// mapping 或 doorbell；因此 stale 检查可以在不触碰外部资源的情况下完成。
class rdma_cq_shadow_snapshot extends uvm_object;
  `uvm_object_utils(rdma_cq_shadow_snapshot)

  rdma_handle cq_h;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;
  int unsigned sq_ci;
  int unsigned rq_ci;
  bit [1:0] arm_state;
  longint unsigned \sequence ;

  // 功能：构造空 CQ shadow 快照，建立确定的零游标和未绑定 authority 默认状态。
  // 输入/输出及副作用：name 为 UVM 对象名；仅初始化本地字段，不访问或接管外部资源。
  // 失败/边界：空快照不能作为 flush authority；调用方必须先填充 cq_h、Function UID/generation/reset epoch。
  function new(string name = "rdma_cq_shadow_snapshot");
    super.new(name);
    cq_h = null;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
    sq_ci = 0;
    rq_ci = 0;
    arm_state = '0;
    \sequence = 0;
  endfunction

  // 功能：复制 source 的 CQ shadow 值字段，生成与 source 隔离的 authority/游标快照。
  // 输入/输出及副作用：rhs 为输入源对象；当前对象字段被覆盖，cq_h 通过 clone 脱离源对象。
  // 失败/边界：rhs 为空或类型不符触发 UVM fatal；句柄 clone 失败时不保留部分可信快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cq_shadow_snapshot source;
    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQ shadow snapshot copy mismatch")
    cq_h = rdma_clone_handle_value(source.cq_h, "CQ shadow CQ");
    function_uid = source.function_uid;
    generation = source.generation;
    reset_epoch = source.reset_epoch;
    sq_ci = source.sq_ci;
    rq_ci = source.rq_ci;
    arm_state = source.arm_state;
    \sequence = source.\sequence ;
  endfunction

  // 功能：基础实现校验 CQ shadow 的 CQ handle 与 Function authority，供 flush 前置检查
  //   使用；virtual override 会替换本函数体，成功的 override 必须调用 super.validate()
  //   或作等价校验，保留 CQ kind、Function UID 与 generation 的比较后才能报告成功。
  // 输入/输出及副作用：无显式参数；本函数体只读取本地字段并返回 rdma_status，不修改
  //   快照或外部账本；virtual dispatch 后的派生实现自行定义其额外读取和副作用。
  // 失败/边界：基础实现对 cq_h 为空/类型错误、UID 或 generation 为零、CQ 与快照
  //   authority 不一致返回 INVALID_ARGUMENT 或 STALE_GENERATION；override 返回 null 或
  //   非 OK 可短路，capture_urc_shadow() 会 fail-closed 且不复制游标证据。
  virtual function rdma_status validate();
    rdma_status status;
    status = rdma_context_handle_status(cq_h, RDMA_RESOURCE_CQ, 21,
                                         "CQ shadow CQ");
    if (!status.ok()) return status;
    if (function_uid == 0 || generation == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ shadow Function authority is incomplete");
    if (cq_h.function_uid != function_uid || cq_h.generation != generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "CQ shadow Function authority does not match CQ");
    return rdma_status::success();
  endfunction
endclass

class rdma_cqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_cqc_model)

  rdma_handle cq_h;
  rdma_handle ceq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned cqe_size_bytes;
  int unsigned threshold;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;
  bit urc_enable;
  bit load_ci_done;
  bit [1:0] last_arm_sequence;
  bit [1:0] arm_sequence;
  bit [1:0] arm_state;
  rdma_backing_addr_t shadow_backing;

  // 功能：构造 rdma_cqc_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：cq_h=null；ceq_h=null；state=RDMA_CONTEXT_INVALID；depth='0；cqe_size_bytes='0；threshold='0；page_layout=rdma_page_table_layout::type_id::create("page_layout")；producer=rdma_ring_position::type_id::create("producer")；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cqc_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cqc_model");
    super.new(name);
    cq_h = null;
    ceq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    cqe_size_bytes = '0;
    threshold = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
    urc_enable = 1'b0;
    load_ci_done = 1'b0;
    last_arm_sequence = '0;
    arm_sequence = '0;
    arm_state = '0;
    shadow_backing = '0;
  endfunction

  // 功能：将 rhs 中 rdma_cqc_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CQC model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_cqc_model rhs_cqc;

    super.do_copy(rhs);
    if (!$cast(rhs_cqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CQC model copy mismatch")
    cq_h = rdma_clone_handle_value(rhs_cqc.cq_h, "CQC CQ");
    ceq_h = rdma_clone_handle_value(rhs_cqc.ceq_h, "CQC CEQ");
    state = rhs_cqc.state;
    depth = rhs_cqc.depth;
    cqe_size_bytes = rhs_cqc.cqe_size_bytes;
    threshold = rhs_cqc.threshold;
    page_layout = rdma_clone_page_layout_value(rhs_cqc.page_layout, "CQC");
    producer = rdma_clone_ring_position_value(rhs_cqc.producer,
                                              "CQC producer");
    consumer = rdma_clone_ring_position_value(rhs_cqc.consumer,
                                              "CQC consumer");
    urc_enable = rhs_cqc.urc_enable;
    load_ci_done = rhs_cqc.load_ci_done;
    last_arm_sequence = rhs_cqc.last_arm_sequence;
    arm_sequence = rhs_cqc.arm_sequence;
    arm_state = rhs_cqc.arm_state;
    shadow_backing = rhs_cqc.shadow_backing;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CQC CQ”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、ceq_h、depth、page_layout、producer、consumer、producer.index、consumer.index 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQC depth is not a nonzero power of two”“CQC nested layout or ring is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(cq_h, RDMA_RESOURCE_CQ, 21,
                                        "CQC CQ");
    if (!status.ok()) return status;
    if (ceq_h != null) begin
      status = rdma_context_handle_status(ceq_h, RDMA_RESOURCE_CEQ, 12,
                                          "CQC CEQ");
      if (!status.ok()) return status;
      status = rdma_context_lifecycle_status(cq_h, ceq_h, "CQC CEQ");
      if (!status.ok()) return status;
    end
    status = rdma_context_state_status(state, "CQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC nested layout or ring is null");
    status = rdma_context_nested_status(
      page_layout.validate(), "CQC page layout"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      producer.validate(), "CQC producer ring"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      consumer.validate(), "CQC consumer ring"
    );
    if (!status.ok())
      return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC ring position is outside the depth");
    if ((shadow_backing.value & 64'h3f) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQC shadow backing is not 64-byte aligned");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("CQC(depth=%0d cqe_size=%0d shadow=0x%016x)",
                     depth, cqe_size_bytes, shadow_backing.value);
  endfunction
endclass

class rdma_mrt_model extends rdma_hw_model;
  `uvm_object_utils(rdma_mrt_model)

  rdma_handle mr_h;
  rdma_handle pd_h;
  rdma_mr_state_e state;
  rdma_iova_t iova;
  longint unsigned length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_rdma_access_t access;
  bit [1:0] object_type;
  rdma_mr_page_layout page_layout;

  // 功能：构造 rdma_mrt_model，调用 super.new 建立 UVM 对象，并把默认值设为
  //   mr_h=null、pd_h=null、state=RDMA_MR_STATE_INVALID、iova='0、length='0、
  //   lkey='0、rkey='0、access='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_mrt_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_mrt_model");
    super.new(name);
    mr_h = null;
    pd_h = null;
    state = RDMA_MR_STATE_INVALID;
    iova = '0;
    length = '0;
    lkey = '0;
    rkey = '0;
    access = '0;
    object_type = '0;
    page_layout = rdma_mr_page_layout::type_id::create("page_layout");
  endfunction

  // 功能：将 rhs 中 rdma_mrt_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（MRT model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_mrt_model rhs_mrt;

    super.do_copy(rhs);
    if (!$cast(rhs_mrt, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "MRT model copy mismatch")
    mr_h = rdma_clone_handle_value(rhs_mrt.mr_h, "MRT MR");
    pd_h = rdma_clone_handle_value(rhs_mrt.pd_h, "MRT PD");
    state = rhs_mrt.state;
    iova = rhs_mrt.iova;
    length = rhs_mrt.length;
    lkey = rhs_mrt.lkey;
    rkey = rhs_mrt.rkey;
    access = rhs_mrt.access;
    object_type = rhs_mrt.object_type;
    page_layout = rdma_clone_mr_page_layout_value(rhs_mrt.page_layout,
                                                  "MRT");
  endfunction

  // 功能：validate 校验 MRT 的句柄、专用 state（INVLD/FREE/VLD）、长度、key
  //   和 page layout 一致性，供 KEY_ALLOC/MR_REGISTER 提交前使用。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、length、mr_h.object_id、lkey、rkey、page_layout 并使用字段 status、has_remote_right；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“MRT length is zero”“MRT length exceeds 46 bits”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    bit has_remote_right;

    status = rdma_context_handle_status(mr_h, RDMA_RESOURCE_MR, 24,
                                        "MRT MR");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "MRT PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(mr_h, pd_h, "MRT PD");
    if (!status.ok()) return status;
    status = rdma_mr_state_status(state, "MRT");
    if (!status.ok()) return status;
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT length is zero");
    if (length[63:46] != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT length exceeds 46 bits");
    if (mr_h.object_id != {8'b0, lkey[31:8]})
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT object ID does not match lkey index");
    has_remote_right = access.remote_read || access.remote_write ||
                       access.remote_atomic;
    if ((has_remote_right && rkey != lkey) ||
        (!has_remote_right && !(rkey == 0 || rkey == lkey)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT lkey and rkey are inconsistent");
    if (page_layout == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MRT page layout is null");
    // MRT wire images carry FIRST_PBL_IDX but not the allocator lease bit.
    // Keep decode/encode at wire-shape scope; control-plane backing validation
    // remains responsible for proving the external HMC/PBLE authority.
    status = page_layout.validate_wire_shape();
    if (!status.ok()) return status;
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("MRT(iova=0x%016x length=%0d lkey=0x%08x)",
                     iova.value, length, lkey);
  endfunction
endclass

class rdma_srqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_srqc_model)

  rdma_handle srq_h;
  rdma_handle pd_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned load_pi_threshold;
  int unsigned limit_threshold;
  rdma_object_mode_e object_mode;
  rdma_backing_addr_t srfq_backing;
  rdma_backing_addr_t shadow_backing;
  rdma_ring_position producer;
  bit [1:0] arm_sequence;

  // 功能：构造 rdma_srqc_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：srq_h=null；pd_h=null；state=RDMA_CONTEXT_INVALID；depth='0；load_pi_threshold='0；limit_threshold='0；object_mode=RDMA_OBJECT_DIRECT_4K；srfq_backing='0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_srqc_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_srqc_model");
    super.new(name);
    srq_h = null;
    pd_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    load_pi_threshold = '0;
    limit_threshold = '0;
    object_mode = RDMA_OBJECT_DIRECT_4K;
    srfq_backing = '0;
    shadow_backing = '0;
    producer = rdma_ring_position::type_id::create("producer");
    arm_sequence = '0;
  endfunction

  // 功能：将 rhs 中 rdma_srqc_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（SRQC model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_srqc_model rhs_srqc;

    super.do_copy(rhs);
    if (!$cast(rhs_srqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "SRQC model copy mismatch")
    srq_h = rdma_clone_handle_value(rhs_srqc.srq_h, "SRQC SRQ");
    pd_h = rdma_clone_handle_value(rhs_srqc.pd_h, "SRQC PD");
    state = rhs_srqc.state;
    depth = rhs_srqc.depth;
    load_pi_threshold = rhs_srqc.load_pi_threshold;
    limit_threshold = rhs_srqc.limit_threshold;
    object_mode = rhs_srqc.object_mode;
    srfq_backing = rhs_srqc.srfq_backing;
    shadow_backing = rhs_srqc.shadow_backing;
    producer = rdma_clone_ring_position_value(rhs_srqc.producer,
                                              "SRQC producer");
    arm_sequence = rhs_srqc.arm_sequence;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“SRQC SRQ”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、depth、srfq_backing.value、producer、producer.index 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SRQC depth is not a nonzero power of two”“SRQC queue backing is not 4 KiB aligned”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(srq_h, RDMA_RESOURCE_SRQ, 16,
                                        "SRQC SRQ");
    if (!status.ok()) return status;
    status = rdma_context_handle_status(pd_h, RDMA_RESOURCE_PD, 16,
                                        "SRQC PD");
    if (!status.ok()) return status;
    status = rdma_context_lifecycle_status(srq_h, pd_h, "SRQC PD");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "SRQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC depth is not a nonzero power of two");
    status = rdma_object_mode_status(object_mode, "SRQC");
    if (!status.ok()) return status;
    if ((srfq_backing.value & 64'hfff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC queue backing is not 4 KiB aligned");
    if (producer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC producer position is null");
    status = rdma_context_nested_status(
      producer.validate(), "SRQC producer ring"
    );
    if (!status.ok())
      return status;
    if (producer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "SRQC producer position exceeds depth");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("SRQC(depth=%0d producer=%0d)", depth,
                     (producer == null) ? 0 : producer.index);
  endfunction
endclass

class rdma_ceqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_ceqc_model)

  rdma_handle ceq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;

  // 功能：构造 rdma_ceqc_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：ceq_h=null；state=RDMA_CONTEXT_INVALID；depth='0；vector_id='0；page_layout=rdma_page_table_layout::type_id::create("page_layout")；producer=rdma_ring_position::type_id::create("producer")；consumer=rdma_ring_position::type_id::create("consumer")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_ceqc_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_ceqc_model");
    super.new(name);
    ceq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    vector_id = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
  endfunction

  // 功能：将 rhs 中 rdma_ceqc_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（CEQC model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_ceqc_model rhs_ceqc;

    super.do_copy(rhs);
    if (!$cast(rhs_ceqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "CEQC model copy mismatch")
    ceq_h = rdma_clone_handle_value(rhs_ceqc.ceq_h, "CEQC CEQ");
    state = rhs_ceqc.state;
    depth = rhs_ceqc.depth;
    vector_id = rhs_ceqc.vector_id;
    page_layout = rdma_clone_page_layout_value(rhs_ceqc.page_layout,
                                               "CEQC");
    producer = rdma_clone_ring_position_value(rhs_ceqc.producer,
                                              "CEQC producer");
    consumer = rdma_clone_ring_position_value(rhs_ceqc.consumer,
                                              "CEQC consumer");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“CEQC CEQ”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、depth、page_layout、producer、consumer、producer.index、consumer.index 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CEQC depth is not a nonzero power of two”“CEQC nested layout or ring is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(ceq_h, RDMA_RESOURCE_CEQ, 12,
                                        "CEQC CEQ");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "CEQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC nested layout or ring is null");
    status = rdma_context_nested_status(
      page_layout.validate(), "CEQC page layout"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      producer.validate(), "CEQC producer ring"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      consumer.validate(), "CEQC consumer ring"
    );
    if (!status.ok())
      return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CEQC ring position is outside the depth");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("CEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass

class rdma_aeqc_model extends rdma_hw_model;
  `uvm_object_utils(rdma_aeqc_model)

  rdma_handle aeq_h;
  rdma_context_state_e state;
  int unsigned depth;
  int unsigned vector_id;
  rdma_page_table_layout page_layout;
  rdma_ring_position producer;
  rdma_ring_position consumer;

  // 功能：构造 rdma_aeqc_model，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：aeq_h=null；state=RDMA_CONTEXT_INVALID；depth='0；vector_id='0；page_layout=rdma_page_table_layout::type_id::create("page_layout")；producer=rdma_ring_position::type_id::create("producer")；consumer=rdma_ring_position::type_id::create("consumer")。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_aeqc_model 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_aeqc_model");
    super.new(name);
    aeq_h = null;
    state = RDMA_CONTEXT_INVALID;
    depth = '0;
    vector_id = '0;
    page_layout = rdma_page_table_layout::type_id::create("page_layout");
    producer = rdma_ring_position::type_id::create("producer");
    consumer = rdma_ring_position::type_id::create("consumer");
  endfunction

  // 功能：将 rhs 中 rdma_aeqc_model 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（AEQC model copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_aeqc_model rhs_aeqc;

    super.do_copy(rhs);
    if (!$cast(rhs_aeqc, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "AEQC model copy mismatch")
    aeq_h = rdma_clone_handle_value(rhs_aeqc.aeq_h, "AEQC AEQ");
    state = rhs_aeqc.state;
    depth = rhs_aeqc.depth;
    vector_id = rhs_aeqc.vector_id;
    page_layout = rdma_clone_page_layout_value(rhs_aeqc.page_layout,
                                               "AEQC");
    producer = rdma_clone_ring_position_value(rhs_aeqc.producer,
                                              "AEQC producer");
    consumer = rdma_clone_ring_position_value(rhs_aeqc.consumer,
                                              "AEQC consumer");
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“AEQC AEQ”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、depth、page_layout、producer、consumer、producer.index、consumer.index 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“AEQC depth is not a nonzero power of two”“AEQC nested layout or ring is null”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    status = rdma_context_handle_status(aeq_h, RDMA_RESOURCE_AEQ, 12,
                                        "AEQC AEQ");
    if (!status.ok()) return status;
    status = rdma_context_state_status(state, "AEQC");
    if (!status.ok()) return status;
    if (!rdma_is_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC depth is not a nonzero power of two");
    if (page_layout == null || producer == null || consumer == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC nested layout or ring is null");
    status = rdma_context_nested_status(
      page_layout.validate(), "AEQC page layout"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      producer.validate(), "AEQC producer ring"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      consumer.validate(), "AEQC consumer ring"
    );
    if (!status.ok())
      return status;
    if (producer.index >= depth || consumer.index >= depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "AEQC ring position is outside the depth");
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return $sformatf("AEQC(depth=%0d vector=%0d)", depth, vector_id);
  endfunction
endclass

// 功能：rdma_umem_page 描述一个被 pin 的用户页及其 DMA 地址映射。
// 输入/输出及副作用：对象字段由 rdma_umem.pin_pages() 填充；对象不拥有外部 host-mem 页。
// 失败/边界：host_va/iova 必须按 page_size 对齐，length 不得跨越一个配置页；pinned=0 表示不可提交 DMA。
class rdma_umem_page extends uvm_object;
  `uvm_object_utils(rdma_umem_page)

  longint unsigned host_va;
  rdma_iova_t iova;
  rdma_backing_addr_t backing_addr;
  longint unsigned length;
  rdma_dma_permission_t permissions;
  int unsigned generation;
  int unsigned refcount;
  bit pinned;
  bit borrowed;

  // 功能：构造空页描述符，建立未 pin 的安全默认值。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段，不访问外部资源。
  // 失败/边界：未填充 host_va/iova/length 的描述符不能通过 validate_page()。
  function new(string name = "rdma_umem_page");
    super.new(name);
    host_va = 0;
    iova = '0;
    backing_addr = '0;
    length = 0;
    permissions = '0;
    generation = 0;
    refcount = 0;
    pinned = 1'b0;
    borrowed = 1'b0;
  endfunction

  // 功能：校验页地址、长度、权限和 pin 状态是否满足 UMEM 访问约束。
  // 输入/输出及副作用：page_size、expected_generation 为输入；只读字段并返回状态，不修改页状态。
  // 失败/边界：未 pin、零长度、跨页、未对齐或代际不匹配返回明确错误。
  function rdma_status validate_page(int unsigned page_size,
                                     int unsigned expected_generation);
    if (!pinned || refcount == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "UMEM page is not pinned");
    if (page_size == 0 || (page_size & (page_size - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UMEM page size is not a power of two");
    if (length == 0 || length > page_size)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UMEM page length is invalid");
    if ((host_va % page_size) != 0 || (iova.value % page_size) != 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM page address is not aligned");
    if (generation != expected_generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "UMEM page generation is stale");
    return rdma_status::success();
  endfunction
endclass

// 功能：rdma_umem 管理一段用户虚拟地址范围的页 pin、引用计数和 exactly-once unpin。
// 输入/输出及副作用：调用方设置 Function、VA、length、page_size 和权限；pin/unpin 只更新本地页账本。
// 失败/边界：零长度、地址溢出、非法页大小或 stale Function 被拒绝；非页对齐范围按对齐 DMA span 建立页描述，重复 pin/unpin 幂等且不重复计数。
class rdma_umem extends uvm_object;
  `uvm_object_utils(rdma_umem)

  rdma_function_handle function_h;
  longint unsigned user_va;
  longint unsigned length;
  int unsigned page_size;
  longint unsigned first_page_offset;
  rdma_dma_permission_t permissions;
  int unsigned generation;
  rdma_resource_ownership_e ownership;
  rdma_umem_page pages[$];
  int unsigned pin_count;
  int unsigned unpin_count;
  int unsigned refcount;
  bit pinned;
  bit detached;

  // 功能：构造 UMEM 并初始化空页账本与生命周期计数器。
  // 输入/输出及副作用：name 为 UVM 对象名；不分配 host-mem 或改变外部页表。
  // 失败/边界：构造出的对象必须经过字段配置和 pin_pages() 后才能使用。
  function new(string name = "rdma_umem");
    super.new(name);
    function_h = null;
    user_va = 0;
    length = 0;
    page_size = 4096;
    first_page_offset = 0;
    permissions = '0;
    generation = 0;
    ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    pages.delete();
    pin_count = 0;
    unpin_count = 0;
    refcount = 0;
    pinned = 1'b0;
    detached = 1'b0;
  endfunction

  // 功能：校验 UMEM 的 Function authority、原始 VA 范围、页粒度和权限，并确认
  //   对齐后的 DMA span 不溢出。
  // 输入/输出及副作用：只读 function_h、user_va、length、page_size、permissions
  //   和 generation；返回状态，不 pin/unpin 或修改引用计数。
  // 失败/边界：Function 为空/类型错误、零长度、页大小非法、VA+length 溢出、DMA 权限为空或代际过期返回明确错误；原始 VA/length 不要求页对齐。
  function rdma_status validate();
    bit [65:0] aligned_span;

    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UMEM Function authority is invalid");
    if (length == 0 || page_size == 0 ||
        (page_size & (page_size - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UMEM length or page size is invalid");
    if (length - 1 > 64'hffff_ffff_ffff_ffff - user_va)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM address range overflows");
    aligned_span = {2'b0, (user_va % page_size)} +
                   {2'b0, length} + page_size - 1;
    if (aligned_span[65:64] != 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM aligned DMA span overflows");
    if (!(permissions.device_read || permissions.device_write))
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "UMEM has no device DMA permission");
    if (generation != function_h.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "UMEM Function generation is stale");
    return rdma_status::success();
  endfunction

  // 功能：pin_pages 按 Linux ib_umem 的对齐区间创建每个 page_size 粒度的页
  //   描述符，并建立一次 pin 引用。
  // 输入/输出及副作用：成功时填充 first_page_offset、pages、pinned、refcount
  //   和 pin_count；页描述符保存对齐后的 host_va/iova，不拥有外部 host-mem 页。
  // 失败/边界：已 pin 调用直接成功；校验、页数溢出或页对象创建失败时清空部分页并保持未 pin，原始非对齐 VA/length 本身不被拒绝。
  function rdma_status pin_pages();
    rdma_status status;
    longint unsigned page_count;
    longint unsigned page_offset;
    longint unsigned mapped_base;
    bit [65:0] aligned_span;
    rdma_umem_page page;

    if (pinned)
      return rdma_status::success("UMEM pages were already pinned");
    status = validate();
    if (!status.ok()) return status;
    page_offset = user_va % page_size;
    aligned_span = {2'b0, page_offset} + {2'b0, length} + page_size - 1;
    if (aligned_span[65:64] != 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM aligned DMA span overflows");
    page_count = aligned_span / page_size;
    if (page_count == 0 || page_count > 64'hffff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "UMEM page count is out of range");
    mapped_base = user_va - page_offset;
    first_page_offset = page_offset;
    pages.delete();
    for (int unsigned index = 0; index < page_count; index++) begin
      page = rdma_umem_page::type_id::create(
        $sformatf("%s_page_%0d", get_name(), index));
      if (page == null) begin
        pages.delete();
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "UMEM page descriptor allocation failed");
      end
      page.host_va = mapped_base + index * page_size;
      page.iova.value = page.host_va;
      page.backing_addr.value = page.host_va;
      page.length = page_size;
      page.permissions = permissions;
      page.generation = generation;
      page.refcount = 1;
      page.pinned = 1'b1;
      page.borrowed = (ownership == RDMA_OWNERSHIP_BORROWED);
      pages.push_back(page);
    end
    pinned = 1'b1;
    detached = 1'b0;
    refcount = 1;
    pin_count++;
    return rdma_status::success();
  endfunction

  // 功能：撤销页 pin 并将 UMEM 置为终态，保证 unpin_count 只增加一次。
  // 输入/输出及副作用：成功时清除 pages 的 pinned/refcount 并更新 pinned/unpin_count；borrowed 由调用方决定是否调用此函数。
  // 失败/边界：重复调用幂等；detached borrowed UMEM 保持外部页不变。
  function rdma_status unpin_pages();
    if (!pinned)
      return rdma_status::success("UMEM pages were already unpinned");
    if (ownership == RDMA_OWNERSHIP_BORROWED) begin
      detached = 1'b1;
      return rdma_status::success("borrowed UMEM was detached");
    end
    foreach (pages[index]) begin
      pages[index].pinned = 1'b0;
      pages[index].refcount = 0;
    end
    pinned = 1'b0;
    detached = 1'b0;
    refcount = 0;
    unpin_count++;
    return rdma_status::success();
  endfunction

  // 功能：检查给定 DMA IOVA/长度是否完全落在本 UMEM 的原始用户范围及其已 pin 页序列中。
  // 输入/输出及副作用：first_iova、access_length 为输入；只读 first_page_offset、pages 和生命周期字段，不修改 pin/refcount。
  // 失败/边界：范围溢出、首尾页 padding、页描述符无效、页间 gap/重叠、跨越
  //   未 pin 页或代际不符均返回 DMA_TRANSLATION/STALE_GENERATION；该接口只接受
  //   连续 DMA span，PBL2 的非连续逻辑访问必须由带页表翻译的上层路径处理。
  function rdma_status check_range(rdma_iova_t first_iova,
                                   longint unsigned access_length);
    longint unsigned logical_start;
    longint unsigned logical_end;
    longint unsigned end_iova;
    longint unsigned page_start;
    longint unsigned page_end;
    longint unsigned next_page_start;
    longint unsigned cursor;
    longint unsigned remaining;
    longint unsigned covered;
    longint unsigned page_offset;
    bit found_start;

    if (!pinned || pages.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "UMEM has no pinned pages");
    if (page_size == 0 || (page_size & (page_size - 1'b1)) != 0 ||
        first_page_offset >= page_size)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "UMEM page geometry is invalid");
    if (access_length == 0 ||
        first_iova.value > 64'hffff_ffff_ffff_ffff - (access_length - 1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM range is empty or overflows");

    foreach (pages[index]) begin
      if (pages[index] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "UMEM page descriptor is null");
      if (pages[index].generation != generation)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "UMEM page generation is stale");
      if (!pages[index].pinned || pages[index].refcount == 0)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "UMEM page is stale or unpinned");
      if (pages[index].length == 0 || pages[index].length > page_size ||
          (pages[index].iova.value % page_size) != 0 ||
          (pages[index].host_va % page_size) != 0)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "UMEM page geometry is invalid");
      if (pages[index].iova.value >
          64'hffff_ffff_ffff_ffff - (pages[index].length - 1))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "UMEM page range overflows");
    end

    page_offset = first_page_offset;
    if (pages[0].iova.value > 64'hffff_ffff_ffff_ffff - page_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM first page offset overflows");
    logical_start = pages[0].iova.value + page_offset;
    if (logical_start >
        64'hffff_ffff_ffff_ffff - (length - 1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM logical range overflows");
    logical_end = logical_start + length - 1;
    end_iova = first_iova.value + access_length - 1;
    if (first_iova.value < logical_start || end_iova > logical_end)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "UMEM range is outside original user span");

    cursor = first_iova.value;
    remaining = access_length;
    found_start = 1'b0;
    for (int unsigned index = 0; index < pages.size(); index++) begin
      page_start = pages[index].iova.value;
      page_end = page_start + pages[index].length - 1;

      if (!found_start) begin
        if (cursor < page_start || cursor > page_end)
          continue;
        found_start = 1'b1;
      end

      if (cursor < page_start || cursor > page_end)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "UMEM range starts in a page gap");
      covered = page_end - cursor + 1;
      if (covered >= remaining)
        return rdma_status::success();
      remaining -= covered;
      if (index + 1 >= pages.size())
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "UMEM range exceeds pinned pages");

      next_page_start = pages[index + 1].iova.value;
      if (page_end == 64'hffff_ffff_ffff_ffff ||
          next_page_start != page_end + 1)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "UMEM pinned pages are not contiguous");
      cursor = page_end + 1;
    end
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             "UMEM range does not resolve to pinned pages");
  endfunction
endclass

// 功能：rdma_pbl 保存多级页表目录、叶子页引用及其 MR authority 快照。
// 输入/输出及副作用：由 rdma_pbl_builder 创建并填充；对象不复制或释放 UMEM 页。
// 失败/边界：active=0 的 PBL 不得用于 DMA；directory_iovas 与 page_entries 数量必须一致且页不跨界。
class rdma_pbl extends uvm_object;
  `uvm_object_utils(rdma_pbl)

  rdma_umem umem_ref;
  rdma_function_handle function_h;
  rdma_mr_page_layout page_layout;
  rdma_mr_pbl_mode_e mode;
  int unsigned level_count;
  int unsigned page_count;
  int unsigned page_size;
  longint unsigned total_length;
  rdma_iova_t first_iova;
  rdma_iova_t directory_iova;
  rdma_iova_t directory_iovas[$];
  rdma_iova_t page_iovas[$];
  rdma_umem_page page_entries[$];
  rdma_hmc_ref hmc_ref;
  rdma_resource_ownership_e ownership;
  int unsigned generation;
  bit active;
  bit released;
  int unsigned release_count;

  // 功能：构造空 PBL 记录，默认处于 inactive/released 前状态。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段，不接触 UMEM。
  // 失败/边界：未由 builder 填充的 PBL 不能发布到 MR 或 MW。
  function new(string name = "rdma_pbl");
    super.new(name);
    umem_ref = null;
    function_h = null;
    page_layout = rdma_mr_page_layout::type_id::create("pbl_page_layout");
    mode = RDMA_MR_PBL0;
    level_count = 0;
    page_count = 0;
    page_size = 0;
    total_length = 0;
    first_iova = '0;
    directory_iova = '0;
    directory_iovas.delete();
    page_iovas.delete();
    page_entries.delete();
    hmc_ref = null;
    ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    generation = 0;
    active = 1'b0;
    released = 1'b0;
    release_count = 0;
  endfunction

  // 功能：校验 PBL 的 Function、目录、叶子页、PBL mode 和 UMEM/HMC 生命周期证据。
  // 输入/输出及副作用：只读本地字段、page_layout、page_entries、hmc_ref 和 UMEM 引用并返回状态，不修改 active/released。
  // 失败/边界：PBL0/PBL1 的直接 payload 若带目录或 HMC 会拒绝；PBL2 缺失有效 HMC lease、页数/目录不符、页跨界或代际不匹配返回错误。
  function rdma_status validate();
    rdma_status status;
    bit [64:0] directory_bytes;
    longint unsigned directory_count;
    bit dma_contiguous;
    longint unsigned previous_start;
    longint unsigned previous_end;
    longint unsigned current_end;

    if (!active || released)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PBL is not active");
    if (umem_ref == null || function_h == null ||
        function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL authority is incomplete");
    if (!umem_ref.pinned || page_count == 0 ||
        page_count != page_entries.size() || page_iovas.size() != page_count)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PBL page directory is incomplete");
    if (page_size == 0 || (page_size & (page_size - 1'b1)) != 0 ||
        page_size != umem_ref.page_size || total_length == 0 ||
        total_length != umem_ref.length || page_layout == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL geometry snapshot is inconsistent");
    if (generation != function_h.generation ||
        generation != umem_ref.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "PBL generation is stale");
    if (page_entries[0] == null ||
        first_iova.value != page_entries[0].iova.value)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL first IOVA does not match its first page");
    status = rdma_context_nested_status(
      page_layout.validate(), "PBL page layout"
    );
    if (!status.ok())
      return status;
    case (mode)
      RDMA_MR_PBL0: begin
        if (page_count == 0 || level_count != 1 ||
            directory_iovas.size() != 0 || hmc_ref != null ||
            directory_iova.value != 0 || page_layout.pbl_mode != RDMA_MR_PBL0)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 direct payload is inconsistent");
        if (page_layout.pba0.value != first_iova.value)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 PBA does not match its first page");
      end
      RDMA_MR_PBL1:
      begin
        if (page_count != 2 || level_count != 1 ||
            directory_iovas.size() != 0 || hmc_ref != null ||
            directory_iova.value != 0 || page_layout.pbl_mode != RDMA_MR_PBL1)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 direct payload is inconsistent");
        if (page_layout.pba0.value != page_entries[0].iova.value ||
            page_layout.pba1.value != page_entries[1].iova.value ||
            page_entries[1].iova.value ==
              page_entries[0].iova.value + page_size)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL1 PBAs do not match a two-block gap");
      end
      RDMA_MR_PBL2: begin
        if (page_count <= 2 || level_count != 3 || directory_iovas.size() == 0 ||
            hmc_ref == null || page_layout.pbl_mode != RDMA_MR_PBL2)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 HMC payload is incomplete");
        status = rdma_context_nested_status(
          hmc_ref.validate(), "PBL HMC reference"
        );
        if (!status.ok())
          return status;
        if ((hmc_ref.address.value & 64'hfff) != 0 ||
            directory_iova.value != hmc_ref.address.value ||
            directory_iovas[0].value != directory_iova.value)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 directory address is inconsistent");
        directory_bytes = {1'b0, page_count} * 64'd8;
        directory_count = (directory_bytes + 4095) / 4096;
        if (directory_count == 0 || directory_iovas.size() != directory_count ||
            hmc_ref.size < directory_count * 4096)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL2 HMC directory capacity is insufficient");
        for (int unsigned directory = 0;
             directory < directory_iovas.size(); directory++) begin
          if ((directory_iovas[directory].value & 64'hfff) != 0 ||
              hmc_ref.address.value >
                64'hffff_ffff_ffff_ffff - directory * 4096 ||
              directory_iovas[directory].value !=
                hmc_ref.address.value + directory * 4096)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "PBL2 directory pages are not contiguous");
        end
        if (hmc_ref.owner.function_uid != function_h.function_uid ||
            hmc_ref.owner.object_id != function_h.object_id ||
            hmc_ref.owner.generation != generation ||
            page_layout.first_pbl_index != hmc_ref.first_pbl_index ||
            !page_layout.first_pbl_index_valid || !hmc_ref.index_valid)
          return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                   "PBL2 HMC lease authority is stale");
      end
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "PBL mode is invalid");
    endcase
    foreach (page_entries[index]) begin
      if (page_entries[index] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "PBL contains a null page");
      if ((page_entries[index].iova.value % page_size) != 0 ||
          page_entries[index].length == 0 ||
          page_entries[index].length > page_size)
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "PBL page crosses its configured page size");
      if (page_entries[index].generation != generation ||
          !page_entries[index].pinned)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "PBL page authority is stale");
      if (page_iovas[index].value != page_entries[index].iova.value)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "PBL page IOVA snapshot is stale");
      if (page_entries[index].iova.value >
          64'hffff_ffff_ffff_ffff - (page_entries[index].length - 1))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "PBL page range overflows");
      if (index != 0) begin
        previous_start = page_entries[index - 1].iova.value;
        previous_end = previous_start +
                       page_entries[index - 1].length - 1;
        current_end = page_entries[index].iova.value +
                      page_entries[index].length - 1;
        if (page_entries[index].iova.value <= previous_end &&
            previous_start <= current_end)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL page entries overlap");
      end
    end

    dma_contiguous = 1'b1;
    for (int unsigned index = 1; index < page_entries.size(); index++) begin
      if (page_entries[index - 1].iova.value >
          64'hffff_ffff_ffff_ffff - page_size ||
          page_entries[index].iova.value !=
            page_entries[index - 1].iova.value + page_size) begin
        dma_contiguous = 1'b0;
        break;
      end
    end
    case (mode)
      RDMA_MR_PBL0:
        if (!dma_contiguous)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL0 pages are not physically contiguous");
      RDMA_MR_PBL1,
      RDMA_MR_PBL2:
        if (dma_contiguous)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "PBL mode requires a non-contiguous DMA span");
      default:
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "PBL mode is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：释放 PBL 目录引用并保证重复释放不再次修改资源账本。
  // 输入/输出及副作用：成功首次调用将 active 清零并递增 release_count；不 unpin UMEM。
  // 失败/边界：重复 release 幂等成功；borrowed PBL 只解除本地引用。
  function rdma_status release_pbl();
    if (released)
      return rdma_status::success("PBL was already released");
    active = 1'b0;
    released = 1'b1;
    release_count++;
    return rdma_status::success();
  endfunction
endclass

// 功能：rdma_pbl_builder::build_multilevel 将 UMEM DMA block 序列按真实连续性组织为 PBL0/PBL1/PBL2。
// 输入/输出及副作用：umem 和可选 hmc_ref 为输入，pbl 为输出；成功时创建页和目录快照，不改变 UMEM pin/refcount 或 HMC 所有权。
// 失败/边界：未 pin、页地址不齐、目录缺少驱动 allocator lease、页跨界或 Function stale 时在提交前返回错误，不伪造 PBL2 地址。
class rdma_pbl_builder;
  // 功能：判断 UMEM 的 DMA block 是否按 page_size 逐页连续，供 PBL mode 选择使用。
  // 输入/输出及副作用：umem 为只读输入；函数比较相邻 page_entries 的 IOVA，不修改页或资源账本。
  // 失败/边界：空 UMEM、页数为零或缺失页描述符返回 false；任一相邻 IOVA 不等于前一页加 page_size 即判定为非连续。
  static function bit dma_blocks_are_contiguous(rdma_umem umem);
    if (umem == null || umem.pages.size() == 0)
      return 1'b0;
    for (int unsigned index = 1; index < umem.pages.size(); index++) begin
      if (umem.pages[index] == null || umem.pages[index - 1] == null ||
          umem.pages[index - 1].iova.value >
            64'hffff_ffff_ffff_ffff - umem.page_size ||
          umem.pages[index].iova.value !=
            umem.pages[index - 1].iova.value + umem.page_size)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：根据页数构建每级最多 512 项的 PBL 目录并验证所有叶子页。
  // 输入/输出及副作用：umem、hmc_ref 为只读输入；pbl 输出新对象，失败时保持 null，不释放调用方 UMEM/HMC 资源。
  // 失败/边界：连续 block 使用 PBL0，恰好两个非连续 block 使用 PBL1，其余非
  //   连续 block 必须提供有效 HMC/PBLE lease 才使用 PBL2；不会从 UMEM 尾部伪造
  //   目录 IOVA。
  static function rdma_status build_multilevel(rdma_umem umem,
                                                output rdma_pbl pbl,
                                                input rdma_hmc_ref hmc_ref = null);
    rdma_status status;
    rdma_pbl candidate;
    longint unsigned page_count;
    longint unsigned directory_count;
    bit contiguous;

    pbl = null;
    if (umem == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PBL build UMEM is null");
    status = rdma_context_nested_status(
      umem.validate(), "PBL build UMEM"
    );
    if (!status.ok())
      return status;
    if (!umem.pinned || umem.pages.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PBL build requires pinned UMEM");
    page_count = umem.pages.size();
    candidate = rdma_pbl::type_id::create("multilevel_pbl");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "PBL descriptor allocation failed");
    candidate.umem_ref = umem;
    candidate.function_h = umem.function_h;
    candidate.generation = umem.generation;
    candidate.page_size = umem.page_size;
    candidate.total_length = umem.length;
    candidate.first_iova.value = umem.pages[0].iova.value;
    candidate.page_count = page_count;
    contiguous = dma_blocks_are_contiguous(umem);
    if (contiguous) begin
      candidate.mode = RDMA_MR_PBL0;
      candidate.level_count = 1;
      candidate.page_layout.pbl_mode = RDMA_MR_PBL0;
      candidate.page_layout.pba0 = umem.pages[0].iova;
    end
    else if (page_count == 2) begin
      candidate.mode = RDMA_MR_PBL1;
      candidate.level_count = 1;
      candidate.page_layout.pbl_mode = RDMA_MR_PBL1;
      candidate.page_layout.pba0 = umem.pages[0].iova;
      candidate.page_layout.pba1 = umem.pages[1].iova;
    end
    else begin
      if (hmc_ref == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PBL2 build requires an allocator-provided HMC lease"
        );
      status = rdma_context_nested_status(
        hmc_ref.validate(), "PBL build HMC reference"
      );
      if (!status.ok())
        return status;
      if (hmc_ref.owner.function_uid != umem.function_h.function_uid ||
          hmc_ref.owner.generation != umem.generation)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "PBL2 HMC lease does not own UMEM");
      candidate.mode = RDMA_MR_PBL2;
      candidate.level_count = 3;
      candidate.hmc_ref = hmc_ref;
      candidate.directory_iova.value = hmc_ref.address.value;
      directory_count = ((page_count * 8) + 4095) / 4096;
      if (directory_count == 0 ||
          hmc_ref.size < directory_count * 4096 ||
          (hmc_ref.address.value & 64'hfff) != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "PBL2 HMC lease cannot cover directory");
      for (int unsigned directory = 0;
           directory < directory_count; directory++) begin
        if (hmc_ref.address.value >
            64'hffff_ffff_ffff_ffff - directory * 4096)
          return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                   "PBL2 directory address overflows");
        candidate.directory_iovas.push_back('{value:
          hmc_ref.address.value + directory * 4096});
      end
      candidate.page_layout.pbl_mode = RDMA_MR_PBL2;
      candidate.page_layout.first_pbl_index = hmc_ref.first_pbl_index;
      candidate.page_layout.first_pbl_index_valid = hmc_ref.index_valid;
    end
    foreach (umem.pages[index]) begin
      status = umem.pages[index].validate_page(umem.page_size,
                                                umem.generation);
      if (!status.ok()) return status;
      candidate.page_entries.push_back(umem.pages[index]);
      candidate.page_iovas.push_back(umem.pages[index].iova);
    end
    candidate.active = 1'b1;
    candidate.released = 1'b0;
    status = rdma_context_nested_status(
      candidate.validate(), "PBL build candidate"
    );
    if (!status.ok())
      return status;
    pbl = candidate;
    return rdma_status::success();
  endfunction
endclass

typedef enum bit [1:0] {
  RDMA_MW_UNBOUND = 2'd0,
  RDMA_MW_BOUND = 2'd1,
  RDMA_MW_INVALIDATED = 2'd2
} rdma_mw_state_e;

// 功能：rdma_mw_binding 管理 Memory Window 与 UMEM/PBL 的绑定、权限校验和失效。
// 输入/输出及副作用：bind 保存非拥有 UMEM/PBL 引用；invalidate 按 MW→PBL→UMEM 顺序释放 owned backing。
// 失败/边界：跨 Function/stale generation、无 bind 权限或 PBL 不匹配时拒绝；invalidate 重复调用幂等。
class rdma_mw_binding extends uvm_object;
  `uvm_object_utils(rdma_mw_binding)

  rdma_function_handle function_h;
  rdma_handle mw_h;
  rdma_handle mr_h;
  rdma_rdma_access_t access;
  rdma_resource_ownership_e ownership;
  rdma_mw_state_e state;
  rdma_umem umem_ref;
  rdma_pbl pbl_ref;
  int unsigned generation;
  bit invalidated;
  int unsigned bind_count;
  int unsigned invalidate_count;

  // 功能：构造未绑定 MW 并清空 authority/backing 引用。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地状态，不分配资源。
  // 失败/边界：未设置 Function 或 MW handle 的对象只能用于显式错误测试。
  function new(string name = "rdma_mw_binding");
    super.new(name);
    function_h = null;
    mw_h = null;
    mr_h = null;
    access = '0;
    ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    state = RDMA_MW_UNBOUND;
    umem_ref = null;
    pbl_ref = null;
    generation = 0;
    invalidated = 1'b0;
    bind_count = 0;
    invalidate_count = 0;
  endfunction

  // 功能：绑定 MW 到已 pin UMEM 和 active PBL，并验证 Function/generation/权限 authority。
  // 输入/输出及副作用：umem、pbl 为输入；成功时保存非拥有引用并进入 BOUND，不修改页内容。
  // 失败/边界：空对象、PBL/UMEM 不一致、foreign Function、stale generation 或 bind 权限缺失均拒绝且不提交引用。
  function rdma_status \bind (rdma_umem umem, rdma_pbl pbl);
    rdma_status status;
    rdma_function_handle expected_function;

    if (state != RDMA_MW_UNBOUND || invalidated)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MW is already bound or invalidated");
    if (umem == null || pbl == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MW bind backing is null");
    status = rdma_context_nested_status(
      umem.validate(), "MW bind UMEM"
    );
    if (!status.ok())
      return status;
    status = rdma_context_nested_status(
      pbl.validate(), "MW bind PBL"
    );
    if (!status.ok())
      return status;
    if (pbl.umem_ref != umem)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MW PBL does not reference UMEM");
    expected_function = function_h == null ? umem.function_h : function_h;
    if (expected_function == null ||
        expected_function.function_uid != umem.function_h.function_uid ||
        expected_function.object_id != umem.function_h.object_id)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "MW Function does not own UMEM");
    if (expected_function.generation != umem.generation ||
        expected_function.generation != pbl.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "MW Function generation is stale");
    if (mw_h != null && mw_h.kind != RDMA_RESOURCE_MW)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MW handle kind is invalid");
    if (mr_h != null && mr_h.kind != RDMA_RESOURCE_MR)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "MR handle kind is invalid");
    if ((access.local_write || access.remote_read || access.remote_write ||
         access.remote_atomic) && !access.memory_window_bind)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "MW bind access omits bind permission");
    function_h = expected_function;
    generation = umem.generation;
    umem_ref = umem;
    pbl_ref = pbl;
    state = RDMA_MW_BOUND;
    invalidated = 1'b0;
    bind_count++;
    return rdma_status::success();
  endfunction

  // 功能：检查 MW 是否仍可访问给定范围和请求权限。
  // 输入/输出及副作用：requested_function、first_iova、length、requested_access 为输入；只读绑定状态。
  // 失败/边界：未绑定/已失效、authority 过期、范围越界或权限超集均返回错误。
  function rdma_status check_access(rdma_function_handle requested_function,
                                     rdma_iova_t first_iova,
                                     longint unsigned length,
                                     rdma_rdma_access_t requested_access);
    if (state != RDMA_MW_BOUND || invalidated || umem_ref == null ||
        pbl_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MW is not active");
    if (requested_function == null ||
        requested_function.function_uid != function_h.function_uid ||
        requested_function.object_id != function_h.object_id)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "MW access Function is foreign");
    if (requested_function.generation != generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "MW access Function is stale");
    if ((requested_access & ~access) != '0)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "MW access exceeds bound rights");
    return umem_ref.check_range(first_iova, length);
  endfunction

  // 功能：按 MW→PBL→UMEM 顺序失效绑定并释放 owned backing。
  // 输入/输出及副作用：成功首次调用更新 state、invalidated 和 invalidate_count；borrowed 不 unpin 外部 UMEM。
  // 失败/边界：重复调用幂等；任一步释放失败都保留未完成状态供安全重试。
  function rdma_status invalidate();
    rdma_status status;
    if (invalidated || state == RDMA_MW_INVALIDATED)
      return rdma_status::success("MW was already invalidated");
    if (state != RDMA_MW_BOUND || umem_ref == null || pbl_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "MW has no active binding");
    if (ownership == RDMA_OWNERSHIP_BORROWED) begin
      umem_ref = null;
      pbl_ref = null;
      state = RDMA_MW_INVALIDATED;
      invalidated = 1'b1;
      invalidate_count++;
      return rdma_status::success("borrowed MW was detached");
    end
    status = pbl_ref.release_pbl();
    if (!status.ok()) return status;
    status = umem_ref.unpin_pages();
    if (!status.ok()) return status;
    state = RDMA_MW_INVALIDATED;
    invalidated = 1'b1;
    invalidate_count++;
    return rdma_status::success();
  endfunction
endclass
