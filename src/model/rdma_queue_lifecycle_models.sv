// 目录：协议与资源模型层 model/rdma_queue_lifecycle_models.sv。
// 职责：实现 rdma_queue_lifecycle_models 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_lifecycle_models.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit { RDMA_QUEUE_BACKING_OWNED, RDMA_QUEUE_BACKING_BORROWED }
  rdma_queue_backing_mode_e;

typedef enum bit [4:0] {
  RDMA_QUEUE_ROLE_CQ_RING = 5'd0,
  RDMA_QUEUE_ROLE_SRQ_RING = 5'd1,
  RDMA_QUEUE_ROLE_SRFQ_RING = 5'd2,
  RDMA_QUEUE_ROLE_SRQ_SGB = 5'd3,
  RDMA_QUEUE_ROLE_CEQ_RING = 5'd4,
  RDMA_QUEUE_ROLE_AEQ_RING = 5'd5,
  RDMA_QUEUE_ROLE_CQ_PD = 5'd6,
  RDMA_QUEUE_ROLE_SRQ_PD = 5'd7,
  RDMA_QUEUE_ROLE_SRFQ_PD = 5'd8,
  RDMA_QUEUE_ROLE_CEQ_PD = 5'd9,
  RDMA_QUEUE_ROLE_AEQ_PD = 5'd10,
  RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW = 5'd11,
  RDMA_QUEUE_ROLE_SRFQC_CONTEXT_SHADOW = 5'd12,
  RDMA_QUEUE_ROLE_QP_SQ_RING = 5'd13,
  RDMA_QUEUE_ROLE_QP_RQ_RING = 5'd14,
  RDMA_QUEUE_ROLE_QP_SQ_PD = 5'd15,
  RDMA_QUEUE_ROLE_QP_RQ_PD = 5'd16,
  RDMA_QUEUE_ROLE_QP_URC_RSQ = 5'd17,
  RDMA_QUEUE_ROLE_QP_URC_RDSQ = 5'd18,
  RDMA_QUEUE_ROLE_QP_URC_DSQ = 5'd19
  ,RDMA_QUEUE_ROLE_QP_SQ_SGB = 5'd20
} rdma_queue_backing_role_e;

typedef enum bit { RDMA_QUEUE_FLUSH_PRE_DELETE, RDMA_QUEUE_FLUSH_POST_DELETE }
  rdma_queue_flush_phase_e;

typedef enum bit { RDMA_QUEUE_RECOVER_CREATE_ROLLBACK,
                   RDMA_QUEUE_RECOVER_NORMAL_DESTROY }
  rdma_queue_recovery_intent_e;

typedef enum bit [1:0] { RDMA_QUEUE_AMBIG_NONE,
                         RDMA_QUEUE_AMBIG_CREATE,
                         RDMA_QUEUE_AMBIG_DELETE,
                         RDMA_QUEUE_AMBIG_OCC_FLUSH }
  rdma_queue_ambiguous_operation_e;

// 中文设计：SRQ destroy 同时受硬件 OCC flush、SRQC delete、context release
// 和 backing detach 的顺序约束；其中 SRQ_SGB 只在 max_sge>2 时存在。把这组
// 不携带对象引用的值规则放在 model 层，policy 与 executor 只消费同一份 detached
// recipe，避免在跨资源 QP→SRQ dependency guard 旁边复制角色顺序或误提交半份清理。
// 功能：rdma_srq_destroy_value_policy 生成 SRQ 销毁所需的硬件 flush 与本地 backing
//       释放顺序，供 SRQ lifecycle policy 在 destroy/recovery 路径中投影为独立数组。
// 输入/输出及副作用：include_optional_sgb（输入）决定 local_roles 是否包含可选
//       RDMA_QUEUE_ROLE_SRQ_SGB；flush_roles、flush_phases、local_roles 和两个顺序
//       标志（输出）均为新写入的值数组/标志，不读取或修改 SRQ/QP/manager 对象。
// 失败/边界：函数没有失败返回；include_optional_sgb=0 只省略 SRQ_SGB，仍保留
//       SRFQ_PD→SRQ_PD flush 以及 SRFQ_PD→SRQ_PD→SRFQ_RING→SRQ_RING 释放顺序；
//       调用方不得把该值 recipe 当作 backing ownership 或 hardware completion 证据。
function automatic void rdma_srq_destroy_value_policy(
  input bit include_optional_sgb,
  output rdma_queue_backing_role_e flush_roles[$],
  output rdma_queue_flush_phase_e flush_phases[$],
  output bit delete_before_flush,
  output rdma_queue_backing_role_e local_roles[$],
  output bit release_context_first
);
  flush_roles.delete();
  flush_phases.delete();
  local_roles.delete();

  delete_before_flush = 1'b0;
  release_context_first = 1'b1;

  flush_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD);
  flush_phases.push_back(RDMA_QUEUE_FLUSH_PRE_DELETE);
  flush_roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD);
  flush_phases.push_back(RDMA_QUEUE_FLUSH_PRE_DELETE);

  local_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD);
  local_roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD);
  if (include_optional_sgb)
    local_roles.push_back(RDMA_QUEUE_ROLE_SRQ_SGB);
  local_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_RING);
  local_roles.push_back(RDMA_QUEUE_ROLE_SRQ_RING);
endfunction

// 功能：rdma_queue_nested_status 将 queue lifecycle 模型依赖的嵌套 virtual
//       validator 结果归一化为可安全消费的 rdma_status。
// 输入/输出及副作用：status（输入）和 label（输入）；非空 status 原样返回，
//       null status 转换为 INVALID_STATE，不修改任何 queue/backing 账本。
// 失败/边界：null 表示下游扩展违反状态返回契约；调用方收到确定失败后不得
//       继续读取嵌套对象或发布 ring/context authority。
function automatic rdma_status rdma_queue_nested_status(
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

// 功能：rdma_queue_role_is_payload 根据 role 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：role（输入）；rdma_queue_role_is_payload 读取 role 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_queue_role_is_payload 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_queue_role_is_payload(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_RING, RDMA_QUEUE_ROLE_SRQ_RING,
                      RDMA_QUEUE_ROLE_SRFQ_RING, RDMA_QUEUE_ROLE_SRQ_SGB,
                      RDMA_QUEUE_ROLE_CEQ_RING, RDMA_QUEUE_ROLE_AEQ_RING};
endfunction

// 功能：rdma_queue_role_is_ring 根据 role 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：role（输入）；rdma_queue_role_is_ring 读取 role 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_queue_role_is_ring 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_queue_role_is_ring(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_RING, RDMA_QUEUE_ROLE_SRQ_RING,
                      RDMA_QUEUE_ROLE_SRFQ_RING, RDMA_QUEUE_ROLE_SRQ_SGB,
                      RDMA_QUEUE_ROLE_CEQ_RING, RDMA_QUEUE_ROLE_AEQ_RING};
endfunction

// 功能：rdma_queue_role_is_pd 根据 role 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：role（输入）；rdma_queue_role_is_pd 读取 role 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_queue_role_is_pd 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_queue_role_is_pd(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_CQ_PD, RDMA_QUEUE_ROLE_SRQ_PD,
                      RDMA_QUEUE_ROLE_SRFQ_PD, RDMA_QUEUE_ROLE_CEQ_PD,
                      RDMA_QUEUE_ROLE_AEQ_PD};
endfunction
// Deliberately distinct from the legacy queue predicates above.  QP backing
// must never become valid input to a legacy queue plan just by widening the
// role enum.
// 功能：rdma_qp_role_is_payload 根据 role 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：role（输入）；rdma_qp_role_is_payload 读取 role 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_role_is_payload 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_qp_role_is_payload(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                      RDMA_QUEUE_ROLE_QP_SQ_SGB,
                      RDMA_QUEUE_ROLE_QP_RQ_RING,
                      RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ,
                      RDMA_QUEUE_ROLE_QP_URC_DSQ};
endfunction

// 功能：rdma_qp_role_is_pd 根据 role 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：role（输入）；rdma_qp_role_is_pd 读取 role 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_role_is_pd 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_qp_role_is_pd(rdma_queue_backing_role_e role);
  return role inside {RDMA_QUEUE_ROLE_QP_SQ_PD,
                      RDMA_QUEUE_ROLE_QP_RQ_PD};
endfunction

// 功能：rdma_queue_add_ok 检查 offset 加 length 不为零且不发生 64 位地址溢出，供 backing range 校验使用；不修改运行时账本。
// 输入/输出及副作用：offset（输入）、length（输入）；rdma_queue_add_ok 读取 offset、length 并使用字段 ；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_queue_add_ok 的结果直接由 return length != 0 && offset <= (64'hffff_ffff_ffff_ffff - length) 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
function automatic bit rdma_queue_add_ok(longint unsigned offset,
                                          longint unsigned length);
  return length != 0 && offset <= (64'hffff_ffff_ffff_ffff - length);
endfunction

// 功能：rdma_queue_aligned 判断 value 是否为 alignment 的整数倍，供页地址、ring 起始地址和 IOVA 对齐校验使用；不修改运行时账本。
// 输入/输出及副作用：value（输入）、alignment（输入）；rdma_queue_aligned 读取 value、alignment 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_queue_aligned 的结果直接由 return (value % alignment) == 0 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
function automatic bit rdma_queue_aligned(longint unsigned value,
                                           longint unsigned alignment);
  return (value % alignment) == 0;
endfunction

// 功能：rdma_qp_power_of_two 判断 value 是否为非零二的幂，供 QP ring depth 和 SGE 能力校验使用；不修改运行时账本。
// 输入/输出及副作用：value（输入）；rdma_qp_power_of_two 读取 value 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_power_of_two 的结果直接由 return value != 0 && (value & (value - 1'b1)) == 0 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
function automatic bit rdma_qp_power_of_two(int unsigned value);
  return value != 0 && (value & (value - 1'b1)) == 0;
endfunction

// 功能：rdma_queue_queue_range_status 校验 mapping、offset、length、alignment 与当前对象状态的一致性，并显式处理“mapping is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
// 输入/输出及副作用：mapping（输入）、offset（输入）、length（输入）、alignment（输入）；rdma_queue_queue_range_status 读取 mapping、offset、length、alignment 并使用字段 rdma_status、value；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_queue_queue_range_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“mapping is null”“mapping is not active”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_queue_queue_range_status(
    rdma_dma_mapping mapping, longint unsigned offset, longint unsigned length,
    longint unsigned alignment);
  if (mapping == null)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "mapping is null");
  if (mapping.state != RDMA_MAPPING_ACTIVE)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "mapping is not active");
  if (length > 64'hffff_ffff_ffff_ffff ||
      !rdma_queue_add_ok(offset, length) || offset > mapping.size ||
      length > mapping.size - offset)
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "mapping range overflows");
  if (!rdma_queue_aligned(offset, alignment) || !rdma_queue_aligned(length, alignment))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "queue range is unaligned");
  if (mapping.iova.value > 64'hffff_ffff_ffff_ffff - offset)
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "IOVA offset overflows");
  if (!rdma_queue_aligned(mapping.iova.value + offset, alignment))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                             "effective queue IOVA is unaligned");
  return rdma_status::success();
endfunction

// 功能：rdma_queue_base_from_iova 根据 iova、base 执行 rdma_status 结果转换，具体更新字段 base.value；失败时返回 RDMA_SC_INVALID_ARGUMENT，保持已登记资源和输出不变。
// 输入/输出及副作用：iova（输入）、base（输入输出）；rdma_queue_base_from_iova 读取 iova、base 并使用字段 base.value，并写入 base；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_queue_base_from_iova 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“queue IOVA is not 4 KiB aligned”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_queue_base_from_iova(
    rdma_iova_t iova, inout rdma_backing_addr_t base);
  if (!rdma_queue_aligned(iova.value, 4096))
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "queue IOVA is not 4 KiB aligned");
  base.value = iova.value;
  return rdma_status::success();
endfunction

class rdma_queue_completion_authority extends uvm_object;
  `uvm_object_utils(rdma_queue_completion_authority)
  bit complete;

  // 功能：构造 rdma_queue_completion_authority，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：complete=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_completion_authority 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_completion_authority");
    super.new(name);
    complete = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_completion_authority 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（completion authority copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_completion_authority r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "completion authority copy mismatch");
    complete = r.complete;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“completion authority invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、complete 并使用字段 rdma_status、complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“completion authority invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (!(complete inside {1'b0, 1'b1}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "completion authority invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_slot_token_contract extends uvm_object;
  `uvm_object_utils(rdma_queue_slot_token_contract)
  rdma_queue_completion_authority completion_authority;

  // 功能：构造 rdma_queue_slot_token_contract，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：completion_authority=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_slot_token_contract 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_slot_token_contract");
    super.new(name);
    completion_authority = null;
  endfunction

  // 功能：将 rhs 中 rdma_queue_slot_token_contract 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（slot token contract copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_slot_token_contract r;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "slot token contract copy mismatch");
    completion_authority = r.completion_authority;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“slot token authority missing”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、completion_authority 并使用字段 rdma_status、completion_authority；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“slot token authority missing”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (completion_authority == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "slot token authority missing");
    return rdma_queue_nested_status(
      completion_authority.validate(), "slot token completion authority"
    );
  endfunction
endclass

class rdma_queue_opaque_slot_token extends rdma_queue_slot_token_contract;
  `uvm_object_utils(rdma_queue_opaque_slot_token)

  // 功能：构造 rdma_queue_opaque_slot_token，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_opaque_slot_token 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_opaque_slot_token");
    super.new(name);
  endfunction
endclass

class rdma_queue_backing_slice extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_slice)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset, length, logical_queue_offset;

  // 功能：构造 rdma_queue_backing_slice，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_RING；mapping=null；mapping_offset=0；length=0；logical_queue_offset=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_slice 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_slice");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_backing_slice 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（slice copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_slice r;
    uvm_object c;
    rdma_dma_mapping m;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "slice copy mismatch");
    role = r.role;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "slice mapping clone failure");
      mapping = m;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“slice role is not payload”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、mapping、mapping_offset、length、role、logical_queue_offset 并使用字段 rdma_status、mapping、mapping_offset、length、role、logical_queue_offset；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“slice role is not payload”“logical offset is unaligned”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    if (!rdma_queue_role_is_payload(role) && !rdma_qp_role_is_payload(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "slice role is not payload");
    if (!rdma_queue_aligned(logical_queue_offset,
                            (role inside {RDMA_QUEUE_ROLE_SRQ_SGB,
                                          RDMA_QUEUE_ROLE_QP_SQ_SGB}) ? 512 : 4096))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "logical offset is unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "logical range overflows");
    return rdma_queue_queue_range_status(mapping, mapping_offset, length,
      (role inside {RDMA_QUEUE_ROLE_SRQ_SGB, RDMA_QUEUE_ROLE_QP_SQ_SGB}) ? 512 : 4096);
  endfunction
endclass

class rdma_queue_backing_spec extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_spec)
  rdma_queue_backing_mode_e mode;
  rdma_queue_backing_slice slices[$];

  // 功能：构造 rdma_queue_backing_spec，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mode=RDMA_QUEUE_BACKING_OWNED。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_spec 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_spec");
    super.new(name);
    mode = RDMA_QUEUE_BACKING_OWNED;
  endfunction

  // 功能：将 rhs 中 rdma_queue_backing_spec 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（spec copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_spec r;
    uvm_object c;
    rdma_queue_backing_slice s;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "spec copy mismatch");
    mode = r.mode;
    slices.delete();
    foreach (r.slices[i]) begin
      c = r.slices[i].clone();
      if (c == null || !$cast(s, c) || s == r.slices[i])
        `uvm_fatal("RDMA_COPY_TYPE", "slice clone failure");
      slices.push_back(s);
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“backing mode invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、mode、slices、role 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“backing mode invalid”“owned spec contains slices”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;

    if (!(mode inside {RDMA_QUEUE_BACKING_OWNED,
                       RDMA_QUEUE_BACKING_BORROWED}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "backing mode invalid");
    if (mode == RDMA_QUEUE_BACKING_OWNED) begin
      if (slices.size() != 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "owned spec contains slices");
      return rdma_status::success();
    end
    if (slices.size() == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "borrowed spec has no slices");
    foreach (slices[i]) begin
      if (slices[i] == null || !rdma_queue_role_is_payload(slices[i].role))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "invalid borrowed payload role");
      s = rdma_queue_nested_status(
        slices[i].validate(), "backing spec slice"
      );
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_dma_page_ref extends uvm_object;
  `uvm_object_utils(rdma_queue_dma_page_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_page_offset;
  rdma_iova_t page_iova;

  // 功能：构造 rdma_queue_dma_page_ref，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_RING；mapping=null；mapping_offset=0；logical_page_offset=0；page_iova='0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_dma_page_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_dma_page_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    mapping_offset = 0;
    logical_page_offset = 0;
    page_iova = '0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_dma_page_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（page copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_dma_page_ref r;
    uvm_object c;
    rdma_dma_mapping m;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "page copy mismatch");
    role = r.role;
    mapping_offset = r.mapping_offset;
    logical_page_offset = r.logical_page_offset;
    page_iova = r.page_iova;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "page mapping clone failure");
      // Preserve mapping value fields explicitly; some simulators leave
      // fields at constructor defaults on repeated object clones.
      m.requester_bdf = r.mapping.requester_bdf;
      m.pasid_valid = r.mapping.pasid_valid;
      m.pasid = r.mapping.pasid;
      m.dma_domain_valid = r.mapping.dma_domain_valid;
      m.dma_domain_id = r.mapping.dma_domain_id;
      m.backing_addr = r.mapping.backing_addr;
      m.iova = r.mapping.iova;
      m.size = r.mapping.size;
      m.direction = r.mapping.direction;
      m.permissions = r.mapping.permissions;
      m.state = r.mapping.state;
      mapping = m;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“page role is not ring”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、role、logical_page_offset、mapping.iova、value、mapping_offset、page_iova.value 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“page role is not ring”“page is unaligned”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;

    if (!rdma_queue_role_is_ring(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "page role is not ring");
    s = rdma_queue_queue_range_status(mapping, mapping_offset, 4096, 4096);
    if (!s.ok())
      return s;
    if (!rdma_queue_aligned(logical_page_offset, 4096) ||
        !rdma_queue_aligned(page_iova.value, 4096))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "page is unaligned");
    if (mapping.iova.value + mapping_offset != page_iova.value)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION, "page IOVA mismatch");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_ring_layout extends uvm_object;
  `uvm_object_utils(rdma_queue_ring_layout)
  rdma_queue_backing_role_e role;
  int unsigned entry_size_bytes, depth;
  longint unsigned logical_bytes, storage_bytes;
  int unsigned page_count;
  bit initial_polarity;
  rdma_queue_dma_page_ref pages[$];

  // 功能：构造 rdma_queue_ring_layout，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_RING；entry_size_bytes=0；depth=0；logical_bytes=0；storage_bytes=0；page_count=0；initial_polarity=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_ring_layout 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_ring_layout");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    entry_size_bytes = 0;
    depth = 0;
    logical_bytes = 0;
    storage_bytes = 0;
    page_count = 0;
    initial_polarity = 0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_ring_layout 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（ring copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_ring_layout r;
    uvm_object c;
    rdma_queue_dma_page_ref p;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ring copy mismatch");
    role = r.role;
    entry_size_bytes = r.entry_size_bytes;
    depth = r.depth;
    logical_bytes = r.logical_bytes;
    storage_bytes = r.storage_bytes;
    page_count = r.page_count;
    initial_polarity = r.initial_polarity;
    pages.delete();
    foreach (r.pages[i]) begin
      c = r.pages[i].clone();
      if (c == null || !$cast(p, c) || p == r.pages[i])
        `uvm_fatal("RDMA_COPY_TYPE", "page clone failure");
      pages.push_back(p);
    end
  endfunction

  // 功能：validate_metadata 校验 当前对象字段 与当前对象状态的一致性，并显式处理“ring metadata invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate_metadata 读取 对象字段：rdma_status、role、depth、entry_size_bytes、logical_bytes、storage_bytes、hffff_ffff 并使用字段 expected；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate_metadata 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“ring metadata invalid”“ring size overflows”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate_metadata();
    longint unsigned expected;

    if (!rdma_queue_role_is_ring(role) || entry_size_bytes == 0 || depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring metadata invalid");
    if (depth > 64'hffff_ffff_ffff_ffff / entry_size_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring size overflows");
    expected = depth * entry_size_bytes;
    if (logical_bytes != expected || storage_bytes < 4096 ||
        storage_bytes % 4096 != 0 || storage_bytes < logical_bytes)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring layout size invalid");
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB) begin
      if (storage_bytes > 32'hffff_ffff)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "SGB storage exceeds API width");
    end else if (storage_bytes > 2 * 1024 * 1024) begin
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PD-backed ring storage exceeds ceiling");
    end
    if (page_count == 0 ||
        (role != RDMA_QUEUE_ROLE_SRQ_SGB && page_count > 512) ||
        page_count != storage_bytes / 4096)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ring page count invalid");
    return rdma_status::success();
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“ring materialized page count invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、role、pages、i 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“ring materialized page count invalid”“null page”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;

    s = validate_metadata();
    if (!s.ok())
      return s;
    if (role == RDMA_QUEUE_ROLE_SRQ_SGB && pages.size() == 0)
      return rdma_status::success();
    if (pages.size() != page_count)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ring materialized page count invalid");
    foreach (pages[i]) begin
      if (pages[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null page");
      if (pages[i].role != role)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "page role does not match ring role");
      s = rdma_queue_nested_status(
        pages[i].validate(), "ring page"
      );
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_backing_segment extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_segment)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset;
  longint unsigned length;
  longint unsigned logical_queue_offset;

  // 功能：构造 rdma_queue_backing_segment，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_RING；mapping=null；ownership=RDMA_OWNERSHIP_BORROWED；mapping_offset=0；length=0；logical_queue_offset=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_segment 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_segment");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_backing_segment 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（backing segment copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_segment r;
    uvm_object cloned_object;
    rdma_dma_mapping cloned_mapping;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing segment copy mismatch");
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      cloned_object = r.mapping.clone();
      if (cloned_object == null ||
          !$cast(cloned_mapping, cloned_object) ||
          cloned_mapping == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "backing segment mapping clone failure");
      mapping = cloned_mapping;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“backing segment role is not payload”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、mapping、mapping_offset、length、alignment、role、ownership、logical_queue_offset 并使用字段 alignment；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“backing segment role is not payload”“backing segment ownership invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    longint unsigned alignment;

    if (!rdma_queue_role_is_payload(role) && !rdma_qp_role_is_payload(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment role is not payload");
    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment ownership invalid");
    alignment = (role inside {RDMA_QUEUE_ROLE_SRQ_SGB,
                              RDMA_QUEUE_ROLE_QP_SQ_SGB}) ? 512 : 4096;
    if (!rdma_queue_aligned(logical_queue_offset, alignment))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment logical offset unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "backing segment logical range overflows");
    return rdma_queue_queue_range_status(mapping, mapping_offset, length,
                                         alignment);
  endfunction
endclass

class rdma_queue_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset, length, logical_queue_offset;
  rdma_queue_backing_segment additional_segments[$];
  bit cleanup_complete;

  // 功能：构造 rdma_queue_backing_ref，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_RING；mapping=null；ownership=RDMA_OWNERSHIP_BORROWED；mapping_offset=0；length=0；logical_queue_offset=0；cleanup_complete=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name="rdma_queue_backing_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    logical_queue_offset = 0;
    cleanup_complete = 0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_backing_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（backing ref copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_ref r;
    uvm_object c;
    rdma_dma_mapping m;
    rdma_queue_backing_segment segment;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "backing ref copy mismatch");
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    logical_queue_offset = r.logical_queue_offset;
    cleanup_complete = r.cleanup_complete;
    additional_segments.delete();
    if (r.mapping == null) begin
      mapping = null;
    end else begin
      c = r.mapping.clone();
      if (c == null || !$cast(m, c) || m == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "backing mapping clone failure");
      mapping = m;
    end
    foreach (r.additional_segments[i]) begin
      if (r.additional_segments[i] == null)
        `uvm_fatal("RDMA_COPY_TYPE", "null additional backing segment");
      c = r.additional_segments[i].clone();
      if (c == null || !$cast(segment, c) ||
          segment == r.additional_segments[i])
        `uvm_fatal("RDMA_COPY_TYPE", "additional backing segment clone failure");
      additional_segments.push_back(segment);
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“ownership invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、ownership、role、logical_queue_offset、align、length、cleanup_complete、additional_segments 并使用字段 align、s、next_logical_offset；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“ownership invalid”“backing role invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;
    longint unsigned align;
    longint unsigned next_logical_offset;

    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "ownership invalid");
    if (!rdma_queue_role_is_payload(role) && !rdma_queue_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "backing role invalid");
    if (rdma_queue_role_is_pd(role) &&
        ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PD backing must be control-plane owned");
    if (rdma_queue_role_is_pd(role) && additional_segments.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PD backing cannot contain additional segments");
    align = (role == RDMA_QUEUE_ROLE_SRQ_SGB) ? 512 : 4096;
    s = rdma_queue_queue_range_status(mapping, mapping_offset, length, align);
    if (!s.ok())
      return s;
    if (!rdma_queue_aligned(logical_queue_offset, align))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "logical offset unaligned");
    if (!rdma_queue_add_ok(logical_queue_offset, length))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "logical range overflows");
    if (cleanup_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "borrowed backing cleaned");
    next_logical_offset = logical_queue_offset + length;
    foreach (additional_segments[i]) begin
      if (additional_segments[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "additional backing segment is null");
      if (additional_segments[i].role != role)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "additional backing segment role mismatch");
      if (additional_segments[i].ownership != ownership)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "additional backing segment ownership mismatch"
        );
      s = rdma_queue_nested_status(
        additional_segments[i].validate(), "backing segment"
      );
      if (!s.ok())
        return s;
      if (additional_segments[i].logical_queue_offset != next_logical_offset)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "additional backing segments are not logically contiguous"
        );
      next_logical_offset = additional_segments[i].logical_queue_offset +
                            additional_segments[i].length;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_context_backing_ref extends uvm_object;
  `uvm_object_utils(rdma_context_backing_ref)
  rdma_function_handle owner;
  rdma_resource_kind_e resource_kind;
  int unsigned local_id;
  uvm_object slot_token;
  rdma_hmc_ref hmc_ref;
  rdma_backing_addr_t shadow_pointer_base;
  longint unsigned slot_length;
  longint unsigned shadow_view_offset;
  longint unsigned shadow_view_length;
  bit release_complete;

  // 功能：构造 rdma_context_backing_ref，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：owner=null；resource_kind=RDMA_RESOURCE_CQ；local_id=0；slot_token=null；hmc_ref=null；shadow_pointer_base='0；slot_length=0；shadow_view_offset=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_context_backing_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_context_backing_ref");
    super.new(name);
    owner = null;
    resource_kind = RDMA_RESOURCE_CQ;
    local_id = 0;
    slot_token = null;
    hmc_ref = null;
    shadow_pointer_base = '0;
    slot_length = 0;
    shadow_view_offset = 0;
    shadow_view_length = 0;
    release_complete = 0;
  endfunction

  // 功能：将 rhs 中 rdma_context_backing_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（context copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_context_backing_ref r;
    uvm_object c;
    rdma_function_handle f;
    rdma_hmc_ref h;
    rdma_queue_slot_token_contract source_token;
    rdma_queue_slot_token_contract cloned_token;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "context copy mismatch");
    resource_kind = r.resource_kind;
    local_id = r.local_id;
    shadow_pointer_base = r.shadow_pointer_base;
    slot_length = r.slot_length;
    shadow_view_offset = r.shadow_view_offset;
    shadow_view_length = r.shadow_view_length;
    release_complete = r.release_complete;
    if (r.owner == null) begin
      owner = null;
    end else begin
      c = r.owner.clone();
      if (c == null || !$cast(f, c) || f == r.owner)
        `uvm_fatal("RDMA_COPY_TYPE", "owner clone failure");
      owner = f;
    end
    if (r.slot_token == null) begin
      slot_token = null;
    end else begin
      if (!$cast(source_token, r.slot_token))
        `uvm_fatal("RDMA_COPY_TYPE", "source slot token contract invalid");
      c = r.slot_token.clone();
      if (c == null || c == r.slot_token || !$cast(cloned_token, c) ||
          cloned_token.completion_authority == null ||
          cloned_token.completion_authority !==
            source_token.completion_authority)
        `uvm_fatal("RDMA_COPY_TYPE", "opaque token clone failure");
      slot_token = c;
    end
    if (r.hmc_ref == null) begin
      hmc_ref = null;
    end else begin
      c = r.hmc_ref.clone();
      if (c == null || !$cast(h, c) || h == r.hmc_ref)
        `uvm_fatal("RDMA_COPY_TYPE", "HMC clone failure");
      hmc_ref = h;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“context owner invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、owner、owner.kind、resource_kind、slot_token、hmc_ref、slot_length、shadow_view_length 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“context owner invalid”“context resource invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;
    rdma_queue_slot_token_contract token;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "context owner invalid");
    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_QP}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context resource invalid");
    if (slot_token == null || hmc_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context authority missing");
    if (!$cast(token, slot_token))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "slot token contract invalid");
    s = rdma_queue_nested_status(
      token.validate(), "context slot token"
    );
    if (!s.ok())
      return s;
    s = rdma_queue_nested_status(
      hmc_ref.validate(), "context HMC reference"
    );
    if (!s.ok())
      return s;
    if (slot_length == 0 || shadow_view_length == 0 ||
        shadow_view_length > slot_length ||
        shadow_view_offset > slot_length - shadow_view_length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "context view out of bounds");
    if (resource_kind == RDMA_RESOURCE_QP &&
        (slot_length != 512 || shadow_view_offset != 0 ||
         shadow_view_length != 512 || hmc_ref.size != 512))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP context geometry must be 512 bytes");
    // 设计说明：context shadow 的对齐由冻结硬件 ABI 按资源类型决定：CQ slot
    // 为 64B、SRQ 为 4KB、QP 为 512B；不能把 CQ 误按 SRQ 的页粒度要求。
    if (!rdma_queue_aligned(shadow_pointer_base.value,
                            resource_kind == RDMA_RESOURCE_CQ ? 64 :
                            (resource_kind == RDMA_RESOURCE_QP ? 512 : 4096)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "shadow pointer unaligned");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_flush_target extends uvm_object;
  `uvm_object_utils(rdma_queue_flush_target)
  rdma_queue_backing_role_e role;
  rdma_queue_flush_phase_e phase;
  rdma_queue_backing_ref pd_ref;
  bit flush_complete;

  // 功能：构造 rdma_queue_flush_target，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_CQ_PD；phase=RDMA_QUEUE_FLUSH_PRE_DELETE；pd_ref=null；flush_complete=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_flush_target 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_flush_target");
    super.new(name);
    role = RDMA_QUEUE_ROLE_CQ_PD;
    phase = RDMA_QUEUE_FLUSH_PRE_DELETE;
    pd_ref = null;
    flush_complete = 0;
  endfunction

  // 功能：将 rhs 中 rdma_queue_flush_target 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（flush copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_flush_target r;
    uvm_object c;
    rdma_queue_backing_ref p;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "flush copy mismatch");
    role = r.role;
    phase = r.phase;
    flush_complete = r.flush_complete;
    if (r.pd_ref == null) begin
      pd_ref = null;
    end else begin
      c = r.pd_ref.clone();
      if (c == null || !$cast(p, c) || p == r.pd_ref)
        `uvm_fatal("RDMA_COPY_TYPE", "flush ref clone failure");
      pd_ref = p;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“flush PD invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、role 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“flush PD invalid”“flush phase invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;

    if (!rdma_queue_role_is_pd(role) || pd_ref == null ||
        pd_ref.role != role)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flush PD invalid");
    s = rdma_queue_nested_status(
      pd_ref.validate(), "flush PD reference"
    );
    if (!s.ok())
      return s;
    if (!(phase inside {RDMA_QUEUE_FLUSH_PRE_DELETE,
                        RDMA_QUEUE_FLUSH_POST_DELETE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "flush phase invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_backing_plan extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_plan)
  rdma_resource_kind_e resource_kind;
  rdma_queue_ring_layout rings[$];
  rdma_queue_backing_ref refs[$];
  rdma_context_backing_ref context_ref;
  rdma_queue_flush_target flush_targets[$];

  // 功能：构造 rdma_queue_backing_plan，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：resource_kind=RDMA_RESOURCE_CQ；context_ref=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_plan 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_plan");
    super.new(name);
    resource_kind = RDMA_RESOURCE_CQ;
    context_ref = null;
  endfunction

  // 功能：将 rhs 中 rdma_queue_backing_plan 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（plan copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_backing_plan r;
    uvm_object c;
    rdma_queue_ring_layout l;
    rdma_queue_backing_ref b;
    rdma_context_backing_ref x;
    rdma_queue_flush_target f;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "plan copy mismatch");
    resource_kind = r.resource_kind;
    rings.delete();
    refs.delete();
    flush_targets.delete();
    foreach (r.rings[i]) begin
      c = r.rings[i].clone();
      if (c == null || !$cast(l, c))
        `uvm_fatal("RDMA_COPY_TYPE", "ring clone failure");
      rings.push_back(l);
    end
    foreach (r.refs[i]) begin
      c = r.refs[i].clone();
      if (c == null || !$cast(b, c))
        `uvm_fatal("RDMA_COPY_TYPE", "ref clone failure");
      refs.push_back(b);
    end
    foreach (r.flush_targets[i]) begin
      c = r.flush_targets[i].clone();
      if (c == null || !$cast(f, c))
        `uvm_fatal("RDMA_COPY_TYPE", "flush clone failure");
      flush_targets.push_back(f);
    end
    if (r.context_ref == null) begin
      context_ref = null;
    end else begin
      c = r.context_ref.clone();
      if (c == null || !$cast(x, c))
        `uvm_fatal("RDMA_COPY_TYPE", "context clone failure");
      context_ref = x;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“plan kind invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、resource_kind、rings、role、refs、ref_seen、flush_targets 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“plan kind invalid”“null ring”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s; bit seen[13]; bit ref_seen[13]; int unsigned i;
    foreach (seen[i]) seen[i] = 1'b0;
    foreach (ref_seen[i]) ref_seen[i] = 1'b0;
    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "plan kind invalid");
    foreach (rings[i]) begin
      if (rings[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null ring");
      s = rdma_queue_nested_status(
        rings[i].validate(), "queue backing plan ring"
      );
      if (!s.ok())
        return s;
      if (!rdma_queue_role_is_ring(rings[i].role) ||
          seen[rings[i].role])
        return rdma_status::make(RDMA_SC_INVALID_STATE, "duplicate or invalid ring role");
      seen[rings[i].role] = 1'b1;
    end
    foreach (refs[i]) begin
      if (refs[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null backing ref");
      s = rdma_queue_nested_status(
        refs[i].validate(), "queue backing plan reference"
      );
      if (!s.ok())
        return s;
      if (ref_seen[refs[i].role])
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "duplicate backing role");
      ref_seen[refs[i].role] = 1'b1;
    end
    foreach (flush_targets[i]) begin
      if (flush_targets[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "null flush target");
      s = rdma_queue_nested_status(
        flush_targets[i].validate(), "queue backing plan flush target"
      );
      if (!s.ok())
        return s;
    end
    case (resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_CQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_CQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_CQ_PD] || context_ref == null ||
            context_ref.resource_kind != RDMA_RESOURCE_CQ ||
            flush_targets.size() != 1 ||
            flush_targets[0].role != RDMA_QUEUE_ROLE_CQ_PD ||
            flush_targets[0].phase != RDMA_QUEUE_FLUSH_POST_DELETE)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "CQ plan roles invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (rings.size() < 2 || rings.size() > 3 || refs.size() < 4 ||
            refs.size() > 5 ||
            !seen[RDMA_QUEUE_ROLE_SRQ_RING] || !seen[RDMA_QUEUE_ROLE_SRFQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_SRQ_RING] || !ref_seen[RDMA_QUEUE_ROLE_SRFQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_SRQ_PD] || !ref_seen[RDMA_QUEUE_ROLE_SRFQ_PD] ||
            ((rings.size() == 3) != seen[RDMA_QUEUE_ROLE_SRQ_SGB]) ||
            ((refs.size() == 5) != ref_seen[RDMA_QUEUE_ROLE_SRQ_SGB]) ||
            context_ref == null || context_ref.resource_kind != RDMA_RESOURCE_SRQ ||
            flush_targets.size() != 2 ||
            flush_targets[0].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            flush_targets[1].role != RDMA_QUEUE_ROLE_SRQ_PD ||
            flush_targets[0].phase != RDMA_QUEUE_FLUSH_PRE_DELETE ||
            flush_targets[1].phase != RDMA_QUEUE_FLUSH_PRE_DELETE)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "SRQ plan roles invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_CEQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_CEQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_CEQ_PD] || context_ref != null ||
            flush_targets.size() != 0)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "CEQ plan roles invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (rings.size() != 1 || !seen[RDMA_QUEUE_ROLE_AEQ_RING] ||
            refs.size() != 2 || !ref_seen[RDMA_QUEUE_ROLE_AEQ_RING] ||
            !ref_seen[RDMA_QUEUE_ROLE_AEQ_PD] || context_ref != null ||
            flush_targets.size() != 0)
          return rdma_status::make(RDMA_SC_INVALID_STATE, "AEQ plan roles invalid");
      end
    endcase
    if (context_ref != null) begin
      s = rdma_queue_nested_status(
        context_ref.validate(), "queue backing plan context"
      );
      if (!s.ok())
        return s;
    end
    return rdma_status::success();
  endfunction
endclass

class rdma_qp_ring_layout extends uvm_object;
  `uvm_object_utils(rdma_qp_ring_layout)
  rdma_queue_backing_role_e role;
  int unsigned entry_size_bytes;
  int unsigned depth;
  longint unsigned logical_bytes;
  longint unsigned storage_bytes;
  rdma_object_mode_e object_mode;

  // 功能：构造 rdma_qp_ring_layout，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_QP_SQ_RING；entry_size_bytes=64；depth=0；logical_bytes=0；storage_bytes=0；object_mode=RDMA_OBJECT_INDIRECT_4K。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp_ring_layout 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp_ring_layout");
    super.new(name);
    role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    entry_size_bytes = 64;
    depth = 0;
    logical_bytes = 0;
    storage_bytes = 0;
    object_mode = RDMA_OBJECT_INDIRECT_4K;
  endfunction

  // 功能：将 rhs 中 rdma_qp_ring_layout 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP ring copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_ring_layout r;
    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP ring copy mismatch")
    role = r.role;
    entry_size_bytes = r.entry_size_bytes;
    depth = r.depth;
    logical_bytes = r.logical_bytes;
    storage_bytes = r.storage_bytes;
    object_mode = r.object_mode;
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP ring role or WQE geometry is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、role、logical_bytes、expected_logical、storage_bytes、expected_storage、object_mode 并使用字段 expected_logical、expected_storage；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP ring role or WQE geometry is invalid”“QP ring logical bytes are invalid”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    longint unsigned expected_logical;
    longint unsigned expected_storage;

    if (!(role inside {RDMA_QUEUE_ROLE_QP_SQ_RING,
                       RDMA_QUEUE_ROLE_QP_RQ_RING}) ||
        entry_size_bytes != 64 || !rdma_qp_power_of_two(depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring role or WQE geometry is invalid");
    expected_logical = longint'(depth) * 64;
    if (logical_bytes != expected_logical ||
        expected_logical > 64'hffff_ffff_ffff_efff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring logical bytes are invalid");
    expected_storage = ((expected_logical + 4095) / 4096) * 4096;
    if (storage_bytes != expected_storage || storage_bytes > 2 * 1024 * 1024)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring storage geometry is invalid");
    if (object_mode != RDMA_OBJECT_INDIRECT_4K)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP ring mode must be indirect 4 KiB");
    return rdma_status::success();
  endfunction
endclass

// 功能：在 rdma_qp_ring_layout 中，rdma_qp_sq_sgb_geometry 根据 QP transport/depth/stride 计算 SQ SGB 页布局、长度和对齐约束。
// 输入/输出及副作用：depth（输入）、logical_bytes（输出）、storage_bytes（输出）；rdma_qp_sq_sgb_geometry 读取 depth、logical_bytes、storage_bytes 并使用字段 logical_bytes、storage_bytes，并写入 logical_bytes、storage_bytes；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_sq_sgb_geometry 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“SQ SGB depth invalid”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_sq_sgb_geometry(
  int unsigned depth, output longint unsigned logical_bytes,
  output longint unsigned storage_bytes);
  // logical bytes 描述有效 slot 总量，storage bytes 额外包含 4KiB 对齐填充。
  logical_bytes = longint'(depth) * 512;
  storage_bytes = ((logical_bytes + 4095) / 4096) * 4096;
  if (!rdma_qp_power_of_two(depth) || depth == 0)
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SQ SGB depth invalid");
  return rdma_status::success();
endfunction

// 功能：rdma_qp_needs_sq_sgb 根据 transport、max_send_sge、max_recv_sge 的 函数体条件 判断队列/角色/依赖条件，返回 bit 供上层选择分支；不修改运行时账本。
// 输入/输出及副作用：transport（输入）、max_send_sge（输入）、max_recv_sge（输入）；rdma_qp_needs_sq_sgb 读取 transport、max_send_sge、max_recv_sge 并使用输入参数和固定枚举/常量；函数返回 bit，不取得调用方资源所有权。
// 失败/边界：rdma_qp_needs_sq_sgb 只读输入并返回 bit；边界由函数体现有分支决定，不修改状态或转移资源。
function automatic bit rdma_qp_needs_sq_sgb(
  rdma_transport_e transport, int unsigned max_send_sge,
  int unsigned max_recv_sge);
  // UD 总是需要 SGB；RC 在任一方向超过 2 个 SGE 时也必须启用 SGB。
  return transport == RDMA_TRANSPORT_UD ||
         (transport == RDMA_TRANSPORT_RC &&
          (max_send_sge > 2 || max_recv_sge > 2));
endfunction

// 功能：在 rdma_qp_ring_layout 中，rdma_qp_sgb_layout 根据 QP transport/depth/stride 计算 SQ SGB 页布局、长度和对齐约束。
// 输入/输出及副作用：depth（输入）；rdma_qp_sgb_layout 读取 depth 并使用字段 layout、layout.role、layout.entry_size_bytes、layout.depth、layout.logical_bytes、layout.storage_bytes、layout.object_mode；函数返回 rdma_qp_ring_layout，不取得调用方资源所有权。
// 失败/边界：rdma_qp_sgb_layout 的结果直接由 return layout 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
function automatic rdma_qp_ring_layout rdma_qp_sgb_layout(int unsigned depth);
  rdma_qp_ring_layout layout;
  layout = rdma_qp_ring_layout::type_id::create("sq_sgb_layout");
  layout.role = RDMA_QUEUE_ROLE_QP_SQ_SGB;
  layout.entry_size_bytes = 512;
  layout.depth = depth;
  layout.logical_bytes = longint'(depth) * 512;
  layout.storage_bytes = ((layout.logical_bytes + 4095) / 4096) * 4096;
  layout.object_mode = RDMA_OBJECT_INDIRECT_4K;
  return layout;
endfunction

class rdma_qp_backing_ref extends uvm_object;
  // backing_ref 是 QP 资源持有的 mapping authority；borrowed 只保留 detached 引用。
  `uvm_object_utils(rdma_qp_backing_ref)
  rdma_queue_backing_role_e role;
  rdma_dma_mapping mapping;
  rdma_resource_ownership_e ownership;
  longint unsigned mapping_offset;
  longint unsigned length;
  rdma_queue_backing_segment additional_segments[$];
  bit cleanup_complete;
  // Set only for a pre-program recovery capability retained after an
  // allocation/authority failure.  Such a reference is intentionally not a
  // valid QP ring input; its geometry is inspected by recovery validation
  // only after the opaque adapter completion authority is checked.
  bit recovery_only;

  // 功能：构造 rdma_qp_backing_ref，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：role=RDMA_QUEUE_ROLE_QP_SQ_RING；mapping=null；ownership=RDMA_OWNERSHIP_BORROWED；mapping_offset=0；length=0；cleanup_complete=0；recovery_only=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp_backing_ref 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp_backing_ref");
    super.new(name);
    role = RDMA_QUEUE_ROLE_QP_SQ_RING;
    mapping = null;
    ownership = RDMA_OWNERSHIP_BORROWED;
    mapping_offset = 0;
    length = 0;
    cleanup_complete = 0;
    recovery_only = 1'b0;
  endfunction

  // 功能：将 rhs 中 rdma_qp_backing_ref 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP backing copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_backing_ref r;
    uvm_object c;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP backing copy mismatch")
    role = r.role;
    ownership = r.ownership;
    mapping_offset = r.mapping_offset;
    length = r.length;
    cleanup_complete = r.cleanup_complete;
    recovery_only = r.recovery_only;
    if (r.mapping == null) mapping = null;
    else begin
      c = r.mapping.clone();
      if (c == null || !$cast(mapping, c) || mapping == r.mapping)
        `uvm_fatal("RDMA_COPY_TYPE", "QP backing mapping clone failure")
    end
    additional_segments.delete();
    foreach (r.additional_segments[i]) begin
      rdma_queue_backing_segment segment;
      c = r.additional_segments[i].clone();
      if (c == null || !$cast(segment, c) || segment == r.additional_segments[i])
        `uvm_fatal("RDMA_COPY_TYPE", "QP additional backing segment clone failure")
      additional_segments.push_back(segment);
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP backing role invalid”；“QP ownership invalid”；“borrowed QP backing cleaned”；“recovery-only QP backing is not valid normal-plan geometry”；“QP internal backing must be control-plane owned”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、recovery_only、role、ownership、cleanup_complete、additional_segments、logical_queue_offset 并使用字段 status、next_logical_offset；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；具体拒绝条件包括 “QP backing role invalid”；“QP ownership invalid”；“borrowed QP backing cleaned”；“recovery-only QP backing is not valid normal-plan geometry”；“QP internal backing must be control-plane owned”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;

    if (recovery_only)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "recovery-only QP backing is not valid normal-plan geometry"
      );

    if (!rdma_qp_role_is_payload(role) && !rdma_qp_role_is_pd(role))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP backing role invalid");
    if (!(ownership inside {RDMA_OWNERSHIP_BORROWED,
                            RDMA_OWNERSHIP_CONTROL_PLANE}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP ownership invalid");
    if ((rdma_qp_role_is_pd(role) ||
         role inside {RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ,
                      RDMA_QUEUE_ROLE_QP_URC_DSQ}) &&
        ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP internal backing must be control-plane owned");
    if (cleanup_complete && ownership == RDMA_OWNERSHIP_BORROWED)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "borrowed QP backing cleaned");
    status = rdma_queue_queue_range_status(mapping, mapping_offset, length,
      role == RDMA_QUEUE_ROLE_QP_SQ_SGB ? 512 : 4096);
    if (!status.ok()) return status;
    if (rdma_qp_role_is_pd(role) && additional_segments.size() != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP PD backing cannot have segments");
    begin
      longint unsigned next_logical_offset;
      next_logical_offset = length;
      foreach (additional_segments[i]) begin
        if (additional_segments[i] == null ||
            additional_segments[i].role != role ||
            additional_segments[i].ownership != ownership ||
            additional_segments[i].logical_queue_offset != next_logical_offset)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "QP backing segments are not contiguous");
        status = rdma_queue_nested_status(
          additional_segments[i].validate(), "QP backing segment"
        );
        if (!status.ok())
          return status;
        next_logical_offset += additional_segments[i].length;
      end
    end
    if ((role inside {RDMA_QUEUE_ROLE_QP_URC_RSQ,
                      RDMA_QUEUE_ROLE_QP_URC_RDSQ}) && length != 4096 ||
        role == RDMA_QUEUE_ROLE_QP_URC_DSQ && length != 8192)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "URC internal backing geometry is invalid");
    return rdma_status::success();
  endfunction
endclass

// 功能：rdma_qp_backing_total_length 根据 backing_ref、total_length 执行 rdma_status 结果转换，具体更新字段 total_length；失败时返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT，保持已登记资源和输出不变。
// 输入/输出及副作用：backing_ref（输入）、total_length（输出）；rdma_qp_backing_total_length 读取 backing_ref、total_length 并使用字段 total_length，并写入 total_length；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_qp_backing_total_length 返回 RDMA_SC_INVALID_STATE、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“QP backing reference is null”“QP backing coverage is not contiguous”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_qp_backing_total_length(
  rdma_qp_backing_ref backing_ref,
  output longint unsigned total_length
);
  total_length = 0;
  if (backing_ref == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "QP backing reference is null");
  total_length = backing_ref.length;
  foreach (backing_ref.additional_segments[i]) begin
    if (backing_ref.additional_segments[i] == null ||
        backing_ref.additional_segments[i].logical_queue_offset != total_length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP backing coverage is not contiguous");
    if (backing_ref.additional_segments[i].length >
        64'hffff_ffff_ffff_ffff - total_length)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "QP backing coverage overflows");
    total_length += backing_ref.additional_segments[i].length;
  end
  return rdma_status::success();
endfunction

class rdma_qp_backing_plan extends uvm_object;
  // plan 按固定角色顺序保存 SQ、SQ-SGB、PD、RQ 和 URC backing。
  `uvm_object_utils(rdma_qp_backing_plan)
  rdma_transport_e transport;
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_qp_ring_layout sq_ring;
  rdma_qp_ring_layout rq_ring;
  rdma_qp_backing_ref sq_ref;
  rdma_qp_backing_ref sq_sgb_ref;
  rdma_qp_backing_ref rq_ref;
  rdma_qp_backing_ref sq_pd_ref;
  rdma_qp_backing_ref rq_pd_ref;
  rdma_handle rq_source_h;
  rdma_qp_backing_ref urc_refs[$];
  rdma_context_backing_ref context_ref;
  bit sq_pd_flush_complete;
  bit rq_pd_flush_complete;
  bit cleanup_complete;

  // 功能：构造 rdma_qp_backing_plan，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：transport=RDMA_TRANSPORT_RC；sq_depth=0；rq_depth=0；sq_ring=null；rq_ring=null；sq_ref=null；sq_sgb_ref=null；rq_ref=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_qp_backing_plan 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_qp_backing_plan");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    sq_depth = 0;
    rq_depth = 0;
    sq_ring = null;
    rq_ring = null;
    sq_ref = null;
    sq_sgb_ref = null;
    rq_ref = null;
    sq_pd_ref = null;
    rq_pd_ref = null;
    rq_source_h = null;
    context_ref = null;
    sq_pd_flush_complete = 0;
    rq_pd_flush_complete = 0;
    cleanup_complete = 0;
  endfunction

  // 功能：将 rhs 中 rdma_qp_backing_plan 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（QP plan copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_qp_backing_plan r;
    uvm_object c;
    rdma_qp_backing_ref cloned_ref;

    super.do_copy(rhs);
    if (!$cast(r, rhs)) `uvm_fatal("RDMA_COPY_TYPE", "QP plan copy mismatch")
    transport = r.transport;
    sq_depth = r.sq_depth;
    rq_depth = r.rq_depth;
    sq_pd_flush_complete = r.sq_pd_flush_complete;
    rq_pd_flush_complete = r.rq_pd_flush_complete;
    cleanup_complete = r.cleanup_complete;
    sq_ring = null; rq_ring = null; sq_ref = null; sq_sgb_ref = null; rq_ref = null;
    sq_pd_ref = null; rq_pd_ref = null; context_ref = null;
    if (r.sq_ring != null) begin c = r.sq_ring.clone(); if (!$cast(sq_ring, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ ring clone failure") end
    if (r.rq_ring != null) begin c = r.rq_ring.clone(); if (!$cast(rq_ring, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ ring clone failure") end
    if (r.sq_ref != null) begin c = r.sq_ref.clone(); if (!$cast(sq_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ ref clone failure") end
    if (r.sq_sgb_ref != null) begin c = r.sq_sgb_ref.clone(); if (!$cast(sq_sgb_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ SGB ref clone failure") end
    if (r.rq_ref != null) begin c = r.rq_ref.clone(); if (!$cast(rq_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ ref clone failure") end
    if (r.sq_pd_ref != null) begin c = r.sq_pd_ref.clone(); if (!$cast(sq_pd_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP SQ PD clone failure") end
    if (r.rq_pd_ref != null) begin c = r.rq_pd_ref.clone(); if (!$cast(rq_pd_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP RQ PD clone failure") end
    if (r.rq_source_h == null) rq_source_h = null;
    else begin
      c = r.rq_source_h.clone();
      if (c == null || !$cast(rq_source_h, c) || rq_source_h == r.rq_source_h)
        `uvm_fatal("RDMA_COPY_TYPE", "QP RQ source clone failure")
    end
    urc_refs.delete();
    foreach (r.urc_refs[i]) begin
      if (r.urc_refs[i] == null) urc_refs.push_back(null);
      else begin
        c = r.urc_refs[i].clone();
        if (c == null || !$cast(cloned_ref, c) || cloned_ref == r.urc_refs[i])
          `uvm_fatal("RDMA_COPY_TYPE", "URC ref clone failure")
        urc_refs.push_back(cloned_ref);
      end
    end
    if (r.context_ref != null) begin c = r.context_ref.clone(); if (!$cast(context_ref, c)) `uvm_fatal("RDMA_COPY_TYPE", "QP context clone failure") end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“QP plan transport/depth invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、transport、sq_ring、sq_ref、sq_pd_ref、sq_ring.role、sq_ring.depth、sq_depth 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“QP plan transport/depth invalid”“QP SQ authority missing”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status status;
    bit seen_urc[3];
    longint unsigned total_length;

    foreach (seen_urc[i]) seen_urc[i] = 0;
    if (!(transport inside {RDMA_TRANSPORT_RC, RDMA_TRANSPORT_UD,
                            RDMA_TRANSPORT_URC}) ||
        !rdma_qp_power_of_two(sq_depth) || !rdma_qp_power_of_two(rq_depth))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP plan transport/depth invalid");
    if (sq_ring == null || sq_ref == null || sq_pd_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ authority missing");
    status = rdma_queue_nested_status(
      sq_ring.validate(), "QP SQ ring"
    );
    if (!status.ok())
      return status;
    if (sq_ring.role != RDMA_QUEUE_ROLE_QP_SQ_RING || sq_ring.depth != sq_depth)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ ring does not match plan");
    status = rdma_queue_nested_status(
      sq_ref.validate(), "QP SQ backing reference"
    );
    if (!status.ok())
      return status;
    status = rdma_queue_nested_status(
      sq_pd_ref.validate(), "QP SQ PD reference"
    );
    if (!status.ok())
      return status;
    if (sq_ref.recovery_only || sq_pd_ref.recovery_only)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "recovery-only QP backing cannot enter a normal plan"
      );
    if (transport == RDMA_TRANSPORT_UD && sq_sgb_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ SGB authority missing");
    // RC/URC normally do not require an SGB, but a present optional SGB is
    // still part of the published authority and must carry canonical geometry.
    if (sq_sgb_ref != null) begin
      status = rdma_queue_nested_status(
        sq_sgb_ref.validate(), "QP SQ SGB reference"
      );
      if (!status.ok())
        return status;
      status = rdma_qp_backing_total_length(sq_sgb_ref, total_length);
      if (!status.ok()) return status;
      if (sq_sgb_ref.role != RDMA_QUEUE_ROLE_QP_SQ_SGB ||
          total_length != ((longint'(sq_depth)*512 + 4095)/4096)*4096)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP SQ SGB geometry invalid");
    end
    status = rdma_qp_backing_total_length(sq_ref, total_length);
    if (!status.ok()) return status;
    if (sq_ref.role != RDMA_QUEUE_ROLE_QP_SQ_RING ||
        total_length != sq_ring.storage_bytes ||
        sq_pd_ref.role != RDMA_QUEUE_ROLE_QP_SQ_PD ||
        sq_pd_ref.length != 4096)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP SQ references do not match ring");
    if (rq_source_h == null) begin
      if (rq_ring == null || rq_ref == null || rq_pd_ref == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "QP private RQ authority missing");
      status = rdma_queue_nested_status(
        rq_ring.validate(), "QP RQ ring"
      );
      if (!status.ok())
        return status;
      status = rdma_queue_nested_status(
        rq_ref.validate(), "QP RQ backing reference"
      );
      if (!status.ok())
        return status;
      status = rdma_queue_nested_status(
        rq_pd_ref.validate(), "QP RQ PD reference"
      );
      if (!status.ok())
        return status;
      if (rq_ref.recovery_only || rq_pd_ref.recovery_only)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "recovery-only QP backing cannot enter a normal plan"
        );
      status = rdma_qp_backing_total_length(rq_ref, total_length);
      if (!status.ok()) return status;
      if (rq_ring.role != RDMA_QUEUE_ROLE_QP_RQ_RING || rq_ring.depth != rq_depth ||
          rq_ref.role != RDMA_QUEUE_ROLE_QP_RQ_RING ||
          total_length != rq_ring.storage_bytes ||
          rq_pd_ref.role != RDMA_QUEUE_ROLE_QP_RQ_PD ||
          rq_pd_ref.length != 4096)
        return rdma_status::make(RDMA_SC_INVALID_STATE, "QP private RQ references invalid");
    end
    else if (transport != RDMA_TRANSPORT_RC || rq_source_h.kind != RDMA_RESOURCE_SRQ ||
             rq_ring != null || rq_ref != null || rq_pd_ref != null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP SRQ RQ authority invalid");
    if (context_ref == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP context authority missing");
    status = rdma_queue_nested_status(
      context_ref.validate(), "QP context reference"
    );
    if (!status.ok())
      return status;
    if (context_ref.resource_kind != RDMA_RESOURCE_QP ||
        context_ref.hmc_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "QP context authority is invalid");
    foreach (urc_refs[i]) begin
      if (urc_refs[i] == null) return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "null URC ref");
      if (urc_refs[i].recovery_only)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "recovery-only QP backing cannot enter a normal plan"
        );
      status = rdma_queue_nested_status(
        urc_refs[i].validate(), "QP URC backing reference"
      );
      if (!status.ok())
        return status;
      case (urc_refs[i].role)
        RDMA_QUEUE_ROLE_QP_URC_RSQ: seen_urc[0] = 1;
        RDMA_QUEUE_ROLE_QP_URC_RDSQ: seen_urc[1] = 1;
        RDMA_QUEUE_ROLE_QP_URC_DSQ: seen_urc[2] = 1;
        default: return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid URC role");
      endcase
    end
    if ((transport == RDMA_TRANSPORT_URC &&
         (urc_refs.size() != 3 || !seen_urc[0] || !seen_urc[1] || !seen_urc[2])) ||
        (transport != RDMA_TRANSPORT_URC && urc_refs.size() != 0))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP URC backing roles invalid");
    return rdma_status::success();
  endfunction
endclass

class rdma_queue_preflight extends uvm_object;
  `uvm_object_utils(rdma_queue_preflight)
  rdma_resource_kind_e resource_kind;
  int unsigned depth;
  int unsigned cqe_size_bytes;
  int unsigned max_sge;
  int unsigned limit_threshold;
  int unsigned local_vector;
  int unsigned hardware_vector;
  int unsigned msix_table_index;
  rdma_queue_backing_spec backing_spec;
  rdma_queue_ring_layout required_rings[$];

  // 功能：构造 rdma_queue_preflight，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：resource_kind=RDMA_RESOURCE_CQ；depth=0；cqe_size_bytes=0；max_sge=0；limit_threshold=0；local_vector=0；hardware_vector=0；msix_table_index=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_preflight 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_preflight");
    super.new(name);
    resource_kind = RDMA_RESOURCE_CQ;
    depth = 0;
    cqe_size_bytes = 0;
    max_sge = 0;
    limit_threshold = 0;
    local_vector = 0;
    hardware_vector = 0;
    msix_table_index = 0;
    backing_spec = null;
  endfunction

  // 功能：将 rhs 中 rdma_queue_preflight 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（preflight copy mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_queue_preflight r;
    uvm_object c;
    rdma_queue_backing_spec b;
    rdma_queue_ring_layout l;

    super.do_copy(rhs);
    if (!$cast(r, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "preflight copy mismatch");
    resource_kind = r.resource_kind;
    depth = r.depth;
    cqe_size_bytes = r.cqe_size_bytes;
    max_sge = r.max_sge;
    limit_threshold = r.limit_threshold;
    local_vector = r.local_vector;
    hardware_vector = r.hardware_vector;
    msix_table_index = r.msix_table_index;
    required_rings.delete();
    foreach (r.required_rings[i]) begin
      c = r.required_rings[i].clone();
      if (c == null || !$cast(l, c))
        `uvm_fatal("RDMA_COPY_TYPE", "required ring clone failure");
      required_rings.push_back(l);
    end
    if (r.backing_spec == null) begin
      backing_spec = null;
    end else begin
      c = r.backing_spec.clone();
      if (c == null || !$cast(b, c))
        `uvm_fatal("RDMA_COPY_TYPE", "spec clone failure");
      backing_spec = b;
    end
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，并显式处理“preflight kind invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status、resource_kind、depth、backing_spec、required_rings、cqe_size_bytes 并使用字段 s；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“preflight kind invalid”“preflight fields missing”；失败路径不提交部分状态或转移未声明资源。
  virtual function rdma_status validate();
    rdma_status s;

    if (!(resource_kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "preflight kind invalid");
    if (depth == 0 || backing_spec == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "preflight fields missing");
    s = rdma_queue_nested_status(
      backing_spec.validate(), "preflight backing spec"
    );
    if (!s.ok())
      return s;
    foreach (required_rings[i]) begin
      if (required_rings[i] == null)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "null required ring");
      if (required_rings[i].pages.size() == 0)
        s = rdma_queue_nested_status(
          required_rings[i].validate_metadata(), "preflight ring metadata"
        );
      else
        s = rdma_queue_nested_status(
          required_rings[i].validate(), "preflight ring"
        );
      if (!s.ok())
        return s;
    end
    if (resource_kind == RDMA_RESOURCE_CQ &&
        !(cqe_size_bytes inside {32, 64, 128}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CQE size invalid");
    return rdma_status::success();
  endfunction
endclass
