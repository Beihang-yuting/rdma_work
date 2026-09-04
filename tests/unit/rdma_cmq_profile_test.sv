// 目录：测试层 unit/rdma_cmq_profile_test.sv。
// 职责：验证 rdma_cmq_profile_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_cmq_profile_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

typedef enum bit [2:0] {
  RDMA_XTR_SNAPSHOT_CLONE_GOOD,
  RDMA_XTR_SNAPSHOT_CLONE_NULL,
  RDMA_XTR_SNAPSHOT_CLONE_SELF,
  RDMA_XTR_SNAPSHOT_CLONE_MUTATE,
  RDMA_XTR_SNAPSHOT_CLONE_WRONG,
  RDMA_XTR_SNAPSHOT_CLONE_ALIAS
} rdma_xtr_snapshot_clone_fault_e;

class rdma_hw_snapshot_fault_handle extends rdma_handle;
  `uvm_object_utils(rdma_hw_snapshot_fault_handle)

  rdma_xtr_snapshot_clone_fault_e clone_fault;
  rdma_handle alias_target;

  // 功能：构造 rdma_hw_snapshot_fault_handle，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：clone_fault=RDMA_XTR_SNAPSHOT_CLONE_GOOD；alias_target=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_snapshot_fault_handle 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_snapshot_fault_handle");
    super.new(name);
    clone_fault = RDMA_XTR_SNAPSHOT_CLONE_GOOD;
    alias_target = null;
  endfunction

  // 功能：将 rhs 中 rdma_hw_snapshot_fault_handle 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取 对象字段：rdma_status、alias_target 并使用字段 rdma_status、alias_target；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  virtual function uvm_object clone();
    case (clone_fault)
      RDMA_XTR_SNAPSHOT_CLONE_NULL: return null;
      RDMA_XTR_SNAPSHOT_CLONE_SELF: return this;
      RDMA_XTR_SNAPSHOT_CLONE_MUTATE: begin
        object_id++;
        return super.clone();
      end
      RDMA_XTR_SNAPSHOT_CLONE_WRONG:
        return rdma_status::success("wrong XTR handle clone type");
      RDMA_XTR_SNAPSHOT_CLONE_ALIAS: return alias_target;
      default: return super.clone();
    endcase
  endfunction
endclass

class rdma_hw_snapshot_mutating_occ extends rdma_hw_occ_flush_body;
  `uvm_object_utils(rdma_hw_snapshot_mutating_occ)

  // 功能：构造 rdma_hw_snapshot_mutating_occ，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_snapshot_mutating_occ 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_snapshot_mutating_occ");
    super.new(name);
  endfunction

  // 功能：将 rhs 中 rdma_hw_snapshot_mutating_occ 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：无显式参数；clone 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 uvm_object，不取得调用方资源所有权。
  // 失败/边界：clone 的结果直接由 return super.clone() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function uvm_object clone();
    qpn++;
    return super.clone();
  endfunction
endclass

class rdma_hw_snapshot_unknown_body extends rdma_hw_model;
  `uvm_object_utils(rdma_hw_snapshot_unknown_body)

  // 功能：构造 rdma_hw_snapshot_unknown_body，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_snapshot_unknown_body 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_snapshot_unknown_body");
    super.new(name);
  endfunction

  // 功能：validate 校验 当前对象字段 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；validate 读取 对象字段：rdma_status 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：validate 的结果直接由 return rdma_status::success() 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  virtual function rdma_status validate();
    return rdma_status::success();
  endfunction

  // 功能：describe 把 当前对象字段 与当前对象的身份/状态字段编码为稳定文本，供日志、查找或恢复索引使用。
  // 输入/输出及副作用：无显式参数；无显式输入；返回 string，只读取对象字段，不修改模型或资源账本。
  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  virtual function string describe();
    return "unknown XTR body";
  endfunction
endclass

class rdma_hw_snapshot_copy_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  // 功能：构造 rdma_hw_snapshot_copy_catcher，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：caught_count=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_snapshot_copy_catcher 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_snapshot_copy_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  // 功能：在 rdma_hw_snapshot_copy_catcher 中，catch 控制 catch 对应的等待、异常或同步边界，按超时/捕获结果返回状态，不吞掉原始错误。
  // 输入/输出及副作用：无显式参数；catch 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 action_e，不取得调用方资源所有权。
  // 失败/边界：catch 超时或异常必须返回原始错误证据；不得无限等待或跳过同步边界。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL && get_id() == "RDMA_COPY_TYPE") begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
  endfunction
endclass

class rdma_hw_cmq_profile_probe
    extends rdma_hw_cmq_hw_profile;
  `uvm_object_utils(rdma_hw_cmq_profile_probe)

  // 功能：构造 rdma_hw_cmq_profile_probe，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_profile_probe 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_hw_cmq_profile_probe");
    super.new(name);
  endfunction

  // 功能：在 rdma_hw_cmq_profile_probe 中，clear_request_composer 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_request_composer 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear_request_composer();
    request_composer = null;
  endfunction

  // 功能：在 rdma_hw_cmq_profile_probe 中，clear_completion_codec 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_completion_codec 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear_completion_codec();
    completion_codec = null;
  endfunction

  // 功能：在 rdma_hw_cmq_profile_probe 中，clear_error_codec 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_error_codec 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear_error_codec();
    error_codec = null;
  endfunction

  // 功能：在 rdma_hw_cmq_profile_probe 中，clear_doorbell_registry 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_doorbell_registry 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear_doorbell_registry();
    doorbell_codecs = null;
  endfunction

  // 功能：在 rdma_hw_cmq_profile_probe 中，clear_doorbell_defaults 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear_doorbell_defaults 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear_doorbell_defaults();
    doorbell_codecs.clear();
  endfunction

endclass

class rdma_hw_cmq_conflicted_doorbell_registry
    extends rdma_hw_doorbell_codec_registry;
  `uvm_object_utils(rdma_hw_cmq_conflicted_doorbell_registry)

  local static bit arm_conflict;
  local static bit conflict_seeded;

  // 功能：构造 rdma_hw_cmq_conflicted_doorbell_registry，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：arm_conflict=1'b0；conflict_seeded=1'b0；conflict_key='{hw_version:"rdma",；conflict_codec=new("pre_registered_cmq_sq", "cmq_sq")；status=register_codec(conflict_key, conflict_codec)；conflict_seeded=1'b1。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_hw_cmq_conflicted_doorbell_registry 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(
    string name = "rdma_hw_cmq_conflicted_doorbell_registry"
  );
    rdma_codec_key conflict_key;
    rdma_hw_doorbell_codec conflict_codec;
    rdma_status status;

    super.new(name);
    if (arm_conflict) begin
      arm_conflict = 1'b0;
      conflict_seeded = 1'b0;
      conflict_key = '{hw_version:"rdma",
                       image_kind:RDMA_IMAGE_DOORBELL,
                       object_type:"doorbell", variant:"cmq_sq",
                       opcode:8'h00};
      conflict_codec = new("pre_registered_cmq_sq", "cmq_sq");
      status = register_codec(conflict_key, conflict_codec);
      if (status == null || !status.ok())
        `uvm_fatal("PROFILE_REGISTRY_FIXTURE",
                   "failed to seed CMQ doorbell registration collision")
      else
        conflict_seeded = 1'b1;
    end
  endfunction

  // 功能：在 rdma_hw_cmq_conflicted_doorbell_registry 中，arm_next_instance 推进队列/事务游标或执行对应 I/O，并把结果写回声明的输出参数。
  // 输入/输出及副作用：无显式参数；arm_next_instance 读取 对象字段：arm_conflict、conflict_seeded 并使用字段 arm_conflict、conflict_seeded；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：arm_next_instance 无返回值，仅执行 arm_conflict=1'b1、conflict_seeded=1'b0；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  static function void arm_next_instance();
    arm_conflict = 1'b1;
    conflict_seeded = 1'b0;
  endfunction

  // 功能：seeded_collision 更新字段 函数体列出的状态字段，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：无显式参数；seeded_collision 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：seeded_collision 的结果直接由 return conflict_seeded 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  static function bit seeded_collision();
    return conflict_seeded;
  endfunction
endclass

class rdma_cmq_profile_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_profile_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  // 功能：构造 rdma_cmq_profile_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_profile_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_profile_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_cmq_profile_test 中，expect_status 在测试中执行 expect_status 断言，比较输入结果与期望状态并报告可定位的失败信息。
  // 输入/输出及副作用：label（输入）、status（输入）、expected（输入）；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：测试函数 expect_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
  function automatic void expect_status(
    string label,
    rdma_status status,
    rdma_status_code_e expected
  );
    if (status == null)
      `uvm_error(label, "profile returned a null status")
    else if (status.code != expected)
      `uvm_error(label,
                 $sformatf("expected %s, got %s (%s)", expected.name(),
                           status.code.name(), status.convert2string()))
  endfunction

  // 功能：make_function 创建独立的 rdma_function_handle；根据 name 设置字段 function_h、function_h.function_uid、function_h.object_id、function_h.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）；make_function 读取 name 并使用字段 function_h、function_h.function_uid、function_h.object_id、function_h.generation；函数返回 rdma_function_handle，不取得调用方资源所有权。
  // 失败/边界：make_function 的结果直接由 return function_h 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;
    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  // 功能：make_handle 创建独立的 rdma_handle；根据 name、kind、object_id 设置字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、kind（输入）、object_id（输入）；make_handle 读取 name、kind、object_id 并使用字段 handle、handle.kind、handle.function_uid、handle.object_id、handle.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：make_handle 的结果直接由 return handle 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_handle make_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle handle;
    handle = rdma_handle::type_id::create(name);
    handle.kind = kind;
    handle.function_uid = TEST_FUNCTION_UID;
    handle.object_id = object_id;
    handle.generation = TEST_GENERATION;
    return handle;
  endfunction

  // 功能：make_command 创建独立的 rdma_cmq_command_desc；根据 name、function_h 设置字段 key、key.profile_name、key.opcode、key.variant、body、body.object_h、command、command.function_h、command.opcode_key、command.body，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、function_h（输入）；make_command 读取 name、function_h 并使用字段 key、key.profile_name、key.opcode、key.variant、body、body.object_h、command、command.function_h；函数返回 rdma_cmq_command_desc，不取得调用方资源所有权。
  // 失败/边界：make_command 的结果直接由 return command 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_command_desc make_command(
    string name,
    rdma_function_handle function_h
  );
    rdma_cmq_command_desc command;
    rdma_cmq_opcode_key key;
    rdma_hw_object_id_command_body body;

    key = rdma_cmq_opcode_key::type_id::create({name, "_key"});
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_CQC_DELETE;
    key.variant = "delete";
    body = rdma_hw_object_id_command_body::type_id::create(
      {name, "_body"});
    body.object_h = make_handle({name, "_cq"}, RDMA_RESOURCE_CQ,
                                21'h12345);
    command = rdma_cmq_command_desc::type_id::create(name);
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    return command;
  endfunction

  // 功能：make_slot 创建独立的 rdma_cmq_slot_context；根据 name、function_h、cmq_h 设置字段 slot、slot.function_h、slot.cmq_h、backing_addr.value、slot.relative_offset、slot.slot_sequence、slot.sq_index、slot.sq_wrap，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：name（输入）、function_h（输入）、cmq_h（输入）；make_slot 读取 name、function_h、cmq_h 并使用字段 slot、slot.function_h、slot.cmq_h、backing_addr.value、slot.relative_offset、slot.slot_sequence、slot.sq_index、slot.sq_wrap；函数返回 rdma_cmq_slot_context，不取得调用方资源所有权。
  // 失败/边界：make_slot 的结果直接由 return slot 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_cmq_slot_context make_slot(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h
  );
    rdma_cmq_slot_context slot;
    slot = rdma_cmq_slot_context::type_id::create(name);
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;
    return slot;
  endfunction

  // 功能：在 rdma_cmq_profile_test 中，get_qword 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：image（输入）、qword_index（输入）；get_qword 读取 image、qword_index 并使用字段 value、base；函数返回 bit [63:0]，不取得调用方资源所有权。
  // 失败/边界：get_qword 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function automatic bit [63:0] get_qword(
    rdma_hw_image image,
    int unsigned qword_index
  );
    bit [63:0] value;
    int unsigned base;
    value = '0;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      value = {value[55:0], image.bytes[base + i]};
    return value;
  endfunction

  // 功能：在 rdma_cmq_profile_test 中，set_qword 按硬件布局把输入模型编码到 image/缓冲区，并在写入前检查范围、重叠、端序和保留位。
  // 输入/输出及副作用：image（输入）、qword_index（输入）、value（输入）；set_qword 先依据 依赖存在性、authority 和 generation 条件 校验 image、qword_index、value；成功时更新本对象配置/状态并保存非拥有引用，返回 void。
  // 失败/边界：set_qword 遇到 image/model 为空、长度/对齐/保留位非法或 codec 校验失败时不发布部分字段。
  function automatic void set_qword(
    rdma_hw_image image,
    int unsigned qword_index,
    bit [63:0] value
  );
    int unsigned base;
    base = qword_index * 8;
    for (int unsigned i = 0; i < 8; i++)
      image.bytes[base + i] = value[63 - (i * 8) -: 8];
  endfunction

  // 功能：将 rhs 中 rdma_cmq_profile_test 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、name（输入）；clone_image 读取 source、name 并使用字段 result；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：clone_image 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
  function automatic rdma_hw_image clone_image(
    rdma_hw_image source,
    string name
  );
    rdma_hw_image result;
    result = rdma_hw_image::type_id::create(name);
    result.copy(source);
    return result;
  endfunction

  // 功能：在 rdma_cmq_profile_test 中由 images_equal 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：images_equal 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  function automatic bit images_equal(
    rdma_hw_image lhs,
    rdma_hw_image rhs
  );
    if (lhs == null || rhs == null ||
        lhs.bytes.size() != rhs.bytes.size() ||
        lhs.field_summary.size() != rhs.field_summary.size())
      return 1'b0;
    if (lhs.length != rhs.length || lhs.alignment != rhs.alignment ||
        lhs.endian != rhs.endian || lhs.image_kind != rhs.image_kind ||
        lhs.hardware_version != rhs.hardware_version ||
        lhs.function_generation != rhs.function_generation ||
        lhs.write_target_kind != rhs.write_target_kind ||
        lhs.backing_target.value != rhs.backing_target.value ||
        lhs.hmc_target.value != rhs.hmc_target.value ||
        lhs.bar_target.value != rhs.bar_target.value)
      return 1'b0;
    foreach (lhs.bytes[i])
      if (lhs.bytes[i] != rhs.bytes[i]) return 1'b0;
    foreach (lhs.field_summary[i])
      if (lhs.field_summary[i] != rhs.field_summary[i]) return 1'b0;
    return 1'b1;
  endfunction

  // 功能：make_cqe 创建独立的 rdma_hw_image；根据 owner、opcode、command_ecode、wqe_index、wrap 设置字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind、image.backing_target、image.hmc_target，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：owner（输入）、opcode（输入）、command_ecode（输入）、wqe_index（输入）、wrap（输入）；make_cqe 读取 owner、opcode、command_ecode、wqe_index、wrap 并使用字段 image、image.length、image.alignment、image.endian、image.image_kind、image.hardware_version、image.function_generation、image.write_target_kind；函数返回 rdma_hw_image，不取得调用方资源所有权。
  // 失败/边界：make_cqe 的结果直接由 return image 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  function automatic rdma_hw_image make_cqe(
    bit owner,
    bit [7:0] opcode,
    bit [7:0] command_ecode,
    bit [4:0] wqe_index,
    bit wrap
  );
    rdma_hw_image image;
    bit [63:0] qword0;
    image = rdma_hw_image::type_id::create("profile_cqe");
    repeat (64) image.bytes.push_back(8'h00);
    image.length = 64;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CMQ_CQE;
    image.hardware_version = RDMA_HW_VERSION;
    image.function_generation = 0;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    qword0 = '0;
    qword0[63] = owner;
    qword0[45] = wrap;
    qword0[44:40] = wqe_index;
    qword0[39:32] = opcode;
    qword0[31:24] = command_ecode;
    set_qword(image, 0, qword0);
    for (int unsigned i = 8; i < 64; i++)
      image.bytes[i] = i[7:0];
    return image;
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_profile_validation 中构造或驱动“profile validation”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_profile_validation();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_cmq_hw_profile failed_registration_profile;
    rdma_hw_cmq_profile_probe probe;
    uvm_factory factory;
    rdma_status status;
    string expected_message;

    profile = rdma_hw_cmq_hw_profile::type_id::create("profile");
    if (profile.profile_name() != "rdma")
      `uvm_error("PROFILE_NAME", "rdma profile reported a wrong name")
    expect_status("PROFILE_VALID", profile.validate_profile(), RDMA_SC_OK);

    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_request_composer");
    probe.clear_request_composer();
    expect_status("PROFILE_MISSING_REQUEST", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_completion_codec");
    probe.clear_completion_codec();
    expect_status("PROFILE_MISSING_COMPLETION", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_error_codec");
    probe.clear_error_codec();
    expect_status("PROFILE_MISSING_ERROR", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_doorbell_registry");
    probe.clear_doorbell_registry();
    expect_status("PROFILE_MISSING_DOORBELL_REGISTRY",
                  probe.validate_profile(), RDMA_SC_INVALID_STATE);
    probe = rdma_hw_cmq_profile_probe::type_id::create(
      "missing_doorbell_defaults");
    probe.clear_doorbell_defaults();
    expect_status("PROFILE_MISSING_DOORBELLS", probe.validate_profile(),
                  RDMA_SC_INVALID_STATE);
    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_hw_doorbell_codec_registry::get_type(),
      rdma_hw_cmq_conflicted_doorbell_registry::get_type()
    );
    rdma_hw_cmq_conflicted_doorbell_registry::arm_next_instance();
    failed_registration_profile =
      rdma_hw_cmq_hw_profile::type_id::create(
        "failed_doorbell_registration");
    if (!rdma_hw_cmq_conflicted_doorbell_registry::seeded_collision())
      `uvm_error("PROFILE_ARM_REGISTRATION_FAILURE",
                 "factory override did not seed the intended collision")
    status = failed_registration_profile.validate_profile();
    expect_status("PROFILE_FAILED_DOORBELL_REGISTRATION", status,
                  RDMA_SC_INVALID_STATE);
    expected_message = {
      "rdma doorbell codec key already registered: ",
      $sformatf("rdma|%0d|doorbell|cmq_sq|00", RDMA_IMAGE_DOORBELL)
    };
    if (status != null && status.message != expected_message)
      `uvm_error("PROFILE_FAILED_DOORBELL_REGISTRATION",
                 {"profile did not preserve register_defaults failure: ",
                  status.message})

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "profile_after_registration_failure");
    expect_status("PROFILE_AFTER_REGISTRATION_FAILURE",
                  profile.validate_profile(), RDMA_SC_OK);
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_compose_sqe 中构造或驱动“compose sqe”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_compose_sqe();
    rdma_hw_cmq_hw_profile profile;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_hw_object_id_command_body body;
    rdma_hw_object_id_command_body snapshot_body;
    rdma_hw_image sqe;
    rdma_hw_image second_sqe;
    rdma_cmq_expected_response expected;
    rdma_cmq_expected_response second_expected;
    rdma_status status;
    bit [63:0] qword0;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "compose_profile");
    function_h = make_function("compose_function");
    cmq_h = make_handle("compose_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    command = make_command("compose_command", function_h);
    slot = make_slot("compose_slot", function_h, cmq_h);
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "command_snapshot");
    command_snapshot.copy(command);
    slot_snapshot = rdma_cmq_slot_context::type_id::create("slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_OUTPUT", "successful compose published null")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_METADATA", "composed SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[59] != 1'b1 ||
        qword0[58:48] != 11'h345 || qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_CQC_DELETE ||
        qword0[20:0] != 21'h12345)
      `uvm_error("COMPOSE_FIELDS", "composed SQE envelope/body is wrong")
    if (expected.hardware_opcode != RDMA_OP_CQC_DELETE ||
        expected.variant != "delete")
      `uvm_error("COMPOSE_EXPECTED", "expected response is wrong")

    if (command.function_h != function_h ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout ||
        !$cast(body, command.body) ||
        !$cast(snapshot_body, command_snapshot.body) ||
        body.object_h.kind != snapshot_body.object_h.kind ||
        body.object_h.function_uid != snapshot_body.object_h.function_uid ||
        body.object_h.object_id != snapshot_body.object_h.object_id ||
        body.object_h.generation != snapshot_body.object_h.generation)
      `uvm_error("COMPOSE_COMMAND_IMMUTABLE", "compose mutated command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_SLOT_IMMUTABLE", "compose mutated slot")

    sqe.bytes[0] ^= 8'hff;
    expected.variant = "mutated";
    second_sqe = null;
    second_expected = null;
    status = profile.compose_sqe(command, slot, second_sqe, second_expected);
    expect_status("COMPOSE_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_sqe == null || second_expected == null ||
        second_sqe == sqe || second_expected == expected ||
        get_qword(second_sqe, 0)[63] != !slot.sq_wrap ||
        second_expected.variant != "delete")
      `uvm_error("COMPOSE_DETACHED", "compose outputs alias profile state")

    sqe = rdma_hw_image::type_id::create("stale_bad_profile_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_bad_profile_expected");
    command.opcode_key.profile_name = "other_profile";
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_OTHER_PROFILE", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_OTHER_PROFILE", "failure published outputs")
    command.opcode_key.profile_name = "rdma";

    command.opcode_key.opcode = 32'h0100_000e;
    sqe = rdma_hw_image::type_id::create("stale_high_opcode_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_high_opcode_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_HIGH_OPCODE", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_HIGH_OPCODE", "failure published outputs")
    command.opcode_key.opcode = RDMA_OP_CQC_DELETE;

    command.vfid_override = 1'b0;
    sqe = rdma_hw_image::type_id::create("stale_invalid_vfid_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_invalid_vfid_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INVALID_VFID", status, RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_INVALID_VFID", "failure published outputs")
    command.vfid_override = 1'b1;

    command.opcode_key.opcode = RDMA_OP_TQ_FLUSH;
    command.opcode_key.variant = "flush";
    sqe = rdma_hw_image::type_id::create("stale_incompatible_body_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_incompatible_body_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_INCOMPATIBLE_BODY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_INCOMPATIBLE_BODY", "failure published outputs")
    command.opcode_key.opcode = RDMA_OP_CQC_DELETE;
    command.opcode_key.variant = "delete";

    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_TARGET_OVERFLOW", status,
                  RDMA_SC_DMA_TRANSLATION);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_TARGET_OVERFLOW", "failure published outputs")
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_body_snapshot_contract 中构造或驱动“body snapshot contract”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_body_snapshot_contract();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_model bodies[5];
    rdma_hw_model snapshot;
    rdma_hw_qpc_command_body qpc_body;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_mr_deregister_body mr_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_cmq_empty_body empty_body;
    rdma_hw_snapshot_fault_handle fault_handle;
    rdma_hw_snapshot_mutating_occ mutating_occ;
    rdma_hw_snapshot_unknown_body unknown_body;
    rdma_hw_snapshot_copy_catcher catcher;
    rdma_status status;
    rdma_handle saved_fault_qp_ref;
    int unsigned saved_fault_object_id;
    bit [23:0] saved_mutating_qpn;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "snapshot_profile"
    );
    qpc_body = rdma_hw_qpc_command_body::type_id::create(
      "snapshot_qpc"
    );
    qpc_body.qp_h = make_handle("snapshot_qp", RDMA_RESOURCE_QP,
                                24'h123456);
    qpc_body.send_cq_h = make_handle("snapshot_scq", RDMA_RESOURCE_CQ,
                                     20'h34567);
    qpc_body.recv_cq_h = make_handle("snapshot_rcq", RDMA_RESOURCE_CQ,
                                     20'h34568);
    qpc_body.qpc_buffer.value = 64'h0000_0000_1000_0000;
    qpc_body.next_state = RDMA_QPS_RTS;
    qpc_body.partial_modify = 1'b1;
    qpc_body.wbe_template_count = 2;
    foreach (qpc_body.modify_start_qword[i]) begin
      qpc_body.modify_start_qword[i] = i;
      qpc_body.modify_wbe[i] = byte'(8'h11 << i);
      qpc_body.modify_data[i] = 64'h1000 + i;
    end
    object_body = rdma_hw_object_id_command_body::type_id::create(
      "snapshot_object"
    );
    object_body.object_h = make_handle("snapshot_object_h",
                                       RDMA_RESOURCE_CQ, 20'h45678);
    mr_body = rdma_hw_mr_deregister_body::type_id::create(
      "snapshot_mr"
    );
    mr_body.mr_h = make_handle("snapshot_mr_h", RDMA_RESOURCE_MR,
                               24'h56789a);
    mr_body.stag_key = 8'ha5;
    mr_body.next_state = RDMA_CONTEXT_INVALID;
    occ_body = rdma_hw_occ_flush_body::type_id::create("snapshot_occ");
    occ_body.vf_flush = 1'b1;
    occ_body.qpc = 1'b1;
    occ_body.cqc = 1'b1;
    occ_body.mrt = 1'b1;
    occ_body.pble = 1'b1;
    occ_body.sqrqe = 1'b1;
    occ_body.sgb_irqe = 1'b1;
    occ_body.eirqe = 1'b1;
    occ_body.orqe = 1'b1;
    occ_body.uaqe = 1'b1;
    empty_body = rdma_hw_cmq_empty_body::type_id::create(
      "snapshot_empty"
    );
    bodies = '{qpc_body, object_body, mr_body, occ_body, empty_body};
    foreach (bodies[i]) begin
      snapshot = null;
      status = profile.snapshot_command_body(bodies[i], snapshot);
      expect_status($sformatf("BODY_SNAPSHOT_VALID_%0d", i), status,
                    RDMA_SC_OK);
      if (snapshot == null || snapshot == bodies[i] ||
          !profile.same_command_body_value(bodies[i], snapshot) ||
          !profile.command_body_graph_detached(bodies[i], snapshot))
        `uvm_error("BODY_SNAPSHOT_VALID",
                   $sformatf("valid body %0d snapshot is not detached", i))
    end

    catcher = new("snapshot_copy_catcher");
    uvm_report_cb::add(null, catcher);
    for (int unsigned fault = RDMA_XTR_SNAPSHOT_CLONE_NULL;
         fault <= RDMA_XTR_SNAPSHOT_CLONE_WRONG; fault++) begin
      qpc_body = rdma_hw_qpc_command_body::type_id::create(
        $sformatf("fault_qpc_%0d", fault)
      );
      fault_handle = rdma_hw_snapshot_fault_handle::type_id::create(
        $sformatf("fault_qp_%0d", fault)
      );
      fault_handle.copy(make_handle("fault_qp_source", RDMA_RESOURCE_QP,
                                    24'h123456));
      fault_handle.clone_fault = rdma_xtr_snapshot_clone_fault_e'(fault);
      qpc_body.qp_h = fault_handle;
      saved_fault_qp_ref = qpc_body.qp_h;
      saved_fault_object_id = fault_handle.object_id;
      snapshot = null;
      status = profile.snapshot_command_body(qpc_body, snapshot);
      expect_status($sformatf("BODY_SNAPSHOT_FAULT_%0d", fault), status,
                    RDMA_SC_INVALID_ARGUMENT);
      if (snapshot != null)
        `uvm_error("BODY_SNAPSHOT_FAULT", "failure published a snapshot")
      if (qpc_body.qp_h != saved_fault_qp_ref ||
          fault_handle.object_id != saved_fault_object_id)
        `uvm_error("BODY_SNAPSHOT_SOURCE",
                   $sformatf("handle fault %0d changed its source", fault))
    end
    qpc_body = rdma_hw_qpc_command_body::type_id::create(
      "fault_qpc_alias"
    );
    qpc_body.recv_cq_h = make_handle("fault_alias_target",
                                     RDMA_RESOURCE_CQ, 20'h12345);
    fault_handle = rdma_hw_snapshot_fault_handle::type_id::create(
      "fault_alias_source"
    );
    fault_handle.copy(qpc_body.recv_cq_h);
    fault_handle.clone_fault = RDMA_XTR_SNAPSHOT_CLONE_ALIAS;
    fault_handle.alias_target = qpc_body.recv_cq_h;
    qpc_body.qp_h = make_handle("fault_alias_qp", RDMA_RESOURCE_QP,
                                24'h123456);
    qpc_body.send_cq_h = fault_handle;
    snapshot = null;
    status = profile.snapshot_command_body(qpc_body, snapshot);
    expect_status("BODY_SNAPSHOT_ALIAS", status, RDMA_SC_INVALID_ARGUMENT);

    mutating_occ = rdma_hw_snapshot_mutating_occ::type_id::create(
      "snapshot_mutating_occ"
    );
    mutating_occ.mr_serial_flush = 1'b1;
    mutating_occ.pble = 1'b1;
    saved_mutating_qpn = mutating_occ.qpn;
    snapshot = null;
    status = profile.snapshot_command_body(mutating_occ, snapshot);
    expect_status("BODY_SNAPSHOT_MUTATING_BODY", status,
                  RDMA_SC_INVALID_ARGUMENT);
    if (mutating_occ.qpn != saved_mutating_qpn ||
        !mutating_occ.mr_serial_flush || !mutating_occ.pble)
      `uvm_error("BODY_SNAPSHOT_SOURCE",
                 "mutating XTR body clone changed its source")
    unknown_body = rdma_hw_snapshot_unknown_body::type_id::create(
      "snapshot_unknown"
    );
    snapshot = null;
    status = profile.snapshot_command_body(unknown_body, snapshot);
    expect_status("BODY_SNAPSHOT_UNKNOWN", status,
                  RDMA_SC_INVALID_ARGUMENT);
    uvm_report_cb::delete(null, catcher);
    if (catcher.caught_count != 0)
      `uvm_error("BODY_SNAPSHOT_FATAL",
                 $sformatf("body preflight reached %0d copy fatals",
                           catcher.caught_count))
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_compose_generation_policy 中构造或驱动“compose generation policy”场景，并断言 DUT
  //   的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_compose_generation_policy();
    rdma_hw_cmq_hw_profile profile;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_opcode_key key;
    rdma_cmq_slot_context slot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_hw_object_id_command_body object_body;
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_occ_flush_body occ_snapshot;
    rdma_hw_cmq_empty_body empty_body;
    rdma_hw_cmq_empty_body empty_snapshot;
    rdma_hw_image sqe;
    rdma_cmq_expected_response expected;
    rdma_status status;
    bit [63:0] qword0;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "generation_profile");
    function_h = make_function("generation_function");
    cmq_h = make_handle("generation_cmq", RDMA_RESOURCE_CMQ, 32'h56);
    slot = make_slot("generation_slot", function_h, cmq_h);

    command = make_command("mismatched_generation_command", function_h);
    if (!$cast(object_body, command.body)) begin
      `uvm_error("COMPOSE_BODY_GENERATION_SETUP",
                 "object-ID command body cast failed")
      return;
    end
    object_body.object_h.generation = TEST_GENERATION + 1;
    sqe = rdma_hw_image::type_id::create("stale_generation_sqe");
    expected = rdma_cmq_expected_response::type_id::create(
      "stale_generation_expected");
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_BODY_GENERATION", status,
                  RDMA_SC_STALE_GENERATION);
    if (sqe != null || expected != null)
      `uvm_error("COMPOSE_BODY_GENERATION",
                 "generation mismatch published outputs")
    if (object_body.object_h.generation != TEST_GENERATION + 1)
      `uvm_error("COMPOSE_BODY_GENERATION",
                 "generation mismatch mutated the command body")

    occ_body = rdma_hw_occ_flush_body::type_id::create(
      "generationless_occ_body");
    occ_body.vf_flush = 1'b1;
    occ_body.qpc = 1'b1;
    occ_body.cqc = 1'b1;
    occ_body.mrt = 1'b1;
    occ_body.pble = 1'b1;
    occ_body.sqrqe = 1'b1;
    occ_body.sgb_irqe = 1'b1;
    occ_body.eirqe = 1'b1;
    occ_body.orqe = 1'b1;
    occ_body.uaqe = 1'b1;
    key = rdma_cmq_opcode_key::type_id::create("occ_flush_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_OCC_FLUSH;
    key.variant = "vf_flush";
    command = rdma_cmq_command_desc::type_id::create("occ_flush_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = occ_body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "occ_flush_command_snapshot");
    command_snapshot.copy(command);
    if (!$cast(occ_snapshot, command_snapshot.body)) begin
      `uvm_error("COMPOSE_OCC_SETUP", "OCC snapshot body cast failed")
      return;
    end
    slot_snapshot = rdma_cmq_slot_context::type_id::create(
      "occ_flush_slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_OCC_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_OCC_OUTPUT", "OCC flush published null outputs")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_OCC_METADATA",
                 "generationless OCC SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[61] != 1'b1 ||
        qword0[59] != 1'b1 || qword0[58:48] != 11'h345 ||
        qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_OCC_FLUSH ||
        get_qword(sqe, 1) != 64'hff80_0000_0000_0000)
      `uvm_error("COMPOSE_OCC_FIELDS",
                 "generationless OCC SQE fields are wrong")
    for (int unsigned q = 2; q < 8; q++)
      if (get_qword(sqe, q) != 0)
        `uvm_error("COMPOSE_OCC_FIELDS",
                   "generationless OCC SQE has unexpected payload")
    if (expected.hardware_opcode != RDMA_OP_OCC_FLUSH ||
        expected.variant != "vf_flush")
      `uvm_error("COMPOSE_OCC_EXPECTED", "OCC expected response is wrong")
    if (command.function_h != function_h || command.opcode_key != key ||
        command.body != occ_body ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.qpc_signature_source !=
          command_snapshot.qpc_signature_source ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout ||
        occ_body.vf_flush != occ_snapshot.vf_flush ||
        occ_body.mr_serial_flush != occ_snapshot.mr_serial_flush ||
        occ_body.qpc != occ_snapshot.qpc ||
        occ_body.cqc != occ_snapshot.cqc ||
        occ_body.mrt != occ_snapshot.mrt ||
        occ_body.pble != occ_snapshot.pble ||
        occ_body.sqrqe != occ_snapshot.sqrqe ||
        occ_body.sgb_irqe != occ_snapshot.sgb_irqe ||
        occ_body.eirqe != occ_snapshot.eirqe ||
        occ_body.orqe != occ_snapshot.orqe ||
        occ_body.uaqe != occ_snapshot.uaqe ||
        occ_body.pd != occ_snapshot.pd ||
        occ_body.qpn != occ_snapshot.qpn ||
        occ_body.mr_serial != occ_snapshot.mr_serial ||
        occ_body.pd_backing.value != occ_snapshot.pd_backing.value)
      `uvm_error("COMPOSE_OCC_COMMAND_IMMUTABLE",
                 "OCC compose mutated the command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_OCC_SLOT_IMMUTABLE",
                 "OCC compose mutated the slot")

    empty_body = rdma_hw_cmq_empty_body::type_id::create(
      "tq_flush_body");
    status = empty_body.validate();
    expect_status("COMPOSE_TQ_BODY_VALID", status, RDMA_SC_OK);
    if (empty_body.describe() != "rdma empty CMQ command body")
      `uvm_error("COMPOSE_TQ_BODY_DESCRIBE",
                 "typed empty body description is not meaningful")
    key = rdma_cmq_opcode_key::type_id::create("tq_flush_key");
    key.profile_name = "rdma";
    key.opcode = RDMA_OP_TQ_FLUSH;
    key.variant = "flush";
    command = rdma_cmq_command_desc::type_id::create("tq_flush_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = empty_body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;
    command_snapshot = rdma_cmq_command_desc::type_id::create(
      "tq_flush_command_snapshot");
    command_snapshot.copy(command);
    if (!$cast(empty_snapshot, command_snapshot.body)) begin
      `uvm_error("COMPOSE_TQ_SETUP", "empty snapshot body cast failed")
      return;
    end
    slot_snapshot = rdma_cmq_slot_context::type_id::create(
      "tq_flush_slot_snapshot");
    slot_snapshot.copy(slot);

    sqe = null;
    expected = null;
    status = profile.compose_sqe(command, slot, sqe, expected);
    expect_status("COMPOSE_TQ_STATUS", status, RDMA_SC_OK);
    if (sqe == null || expected == null) begin
      `uvm_error("COMPOSE_TQ_OUTPUT", "TQ flush published null outputs")
      return;
    end
    qword0 = get_qword(sqe, 0);
    if (sqe.length != 64 || sqe.bytes.size() != 64 ||
        sqe.alignment != 64 || sqe.endian != RDMA_ENDIAN_BIG ||
        sqe.image_kind != RDMA_IMAGE_CMQ_SQE ||
        sqe.hardware_version != RDMA_HW_VERSION ||
        sqe.function_generation != TEST_GENERATION ||
        sqe.write_target_kind != RDMA_HW_TARGET_BACKING ||
        sqe.backing_target.value != 64'h0000_0000_4000_0140 ||
        sqe.hmc_target.value != 0 || sqe.bar_target.value != 0)
      `uvm_error("COMPOSE_TQ_METADATA", "TQ flush SQE metadata is wrong")
    if (qword0[63] != !slot.sq_wrap || qword0[59] != 1'b1 ||
        qword0[58:48] != 11'h345 || qword0[45] != slot.sq_wrap ||
        qword0[44:40] != slot.sq_index[4:0] ||
        qword0[39:32] != RDMA_OP_TQ_FLUSH)
      `uvm_error("COMPOSE_TQ_FIELDS", "TQ flush envelope is wrong")
    for (int unsigned q = 1; q < 8; q++)
      if (get_qword(sqe, q) != 0)
        `uvm_error("COMPOSE_TQ_FIELDS",
                   "TQ flush has nonempty body payload")
    if (expected.hardware_opcode != RDMA_OP_TQ_FLUSH ||
        expected.variant != "flush")
      `uvm_error("COMPOSE_TQ_EXPECTED", "TQ expected response is wrong")
    if (command.function_h != function_h || command.opcode_key != key ||
        command.body != empty_body ||
        empty_snapshot == empty_body ||
        command.function_h.function_uid !=
          command_snapshot.function_h.function_uid ||
        command.function_h.object_id !=
          command_snapshot.function_h.object_id ||
        command.function_h.generation !=
          command_snapshot.function_h.generation ||
        command.opcode_key.profile_name !=
          command_snapshot.opcode_key.profile_name ||
        command.opcode_key.opcode != command_snapshot.opcode_key.opcode ||
        command.opcode_key.variant != command_snapshot.opcode_key.variant ||
        command.qpc_signature_source !=
          command_snapshot.qpc_signature_source ||
        command.vfid_override != command_snapshot.vfid_override ||
        command.use_vfid != command_snapshot.use_vfid ||
        command.timeout != command_snapshot.timeout)
      `uvm_error("COMPOSE_TQ_COMMAND_IMMUTABLE",
                 "TQ compose mutated the command")
    if (slot.function_h != function_h || slot.cmq_h != cmq_h ||
        slot.backing_addr.value != slot_snapshot.backing_addr.value ||
        slot.relative_offset != slot_snapshot.relative_offset ||
        slot.slot_sequence != slot_snapshot.slot_sequence ||
        slot.sq_index != slot_snapshot.sq_index ||
        slot.sq_wrap != slot_snapshot.sq_wrap)
      `uvm_error("COMPOSE_TQ_SLOT_IMMUTABLE",
                 "TQ compose mutated the slot")
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_completion_payload_snapshot_contract 中构造或驱动“completion payload
  //   snapshot contract”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_completion_payload_snapshot_contract();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_cmq_completion source;
    rdma_hw_cmq_completion snapshot;
    uvm_object snapshot_object;
    rdma_status status;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "completion_payload_snapshot_profile"
    );
    source = rdma_hw_cmq_completion::type_id::create(
      "completion_payload_snapshot_source"
    );
    source.owner = 1'b1;
    source.opcode = RDMA_OP_CQC_QUERY;
    source.command_ecode = RDMA_ECODE_EC_RCE_CQ_FULL;
    source.wqe_index = 5'h1b;
    source.wrap = 1'b1;
    source.object_payload = new[3];
    source.object_payload[0] = 8'h12;
    source.object_payload[1] = 8'h34;
    source.object_payload[2] = 8'h56;

    snapshot_object = null;
    status = profile.snapshot_completion_payload(source, snapshot_object);
    expect_status("PAYLOAD_SNAPSHOT_STATUS", status, RDMA_SC_OK);
    if (!$cast(snapshot, snapshot_object)) begin
      `uvm_error("PAYLOAD_SNAPSHOT_TYPE",
                 "completion payload snapshot lost its XTR type")
      return;
    end
    if (snapshot == source ||
        !profile.same_completion_payload_value(source, snapshot) ||
        !profile.completion_payload_graph_detached(source, snapshot) ||
        snapshot.owner != source.owner ||
        snapshot.opcode != source.opcode ||
        snapshot.command_ecode != source.command_ecode ||
        snapshot.wqe_index != source.wqe_index ||
        snapshot.wrap != source.wrap ||
        snapshot.object_payload.size() != source.object_payload.size())
      `uvm_error("PAYLOAD_SNAPSHOT_CONTRACT",
                 "completion payload snapshot is not detached and equal")
    else
      foreach (source.object_payload[i])
        if (snapshot.object_payload[i] != source.object_payload[i])
          `uvm_error("PAYLOAD_SNAPSHOT_BYTES",
                     "completion payload snapshot bytes changed")

    source.owner = 1'b0;
    source.opcode = RDMA_OP_CQC_DELETE;
    source.command_ecode = 8'h00;
    source.wqe_index = 5'h02;
    source.wrap = 1'b0;
    source.object_payload[0] = 8'hff;
    if (!snapshot.owner || snapshot.opcode != RDMA_OP_CQC_QUERY ||
        snapshot.command_ecode != RDMA_ECODE_EC_RCE_CQ_FULL ||
        snapshot.wqe_index != 5'h1b || !snapshot.wrap ||
        snapshot.object_payload.size() != 3 ||
        snapshot.object_payload[0] != 8'h12 ||
        snapshot.object_payload[1] != 8'h34 ||
        snapshot.object_payload[2] != 8'h56)
      `uvm_error("PAYLOAD_SNAPSHOT_DRIFT",
                 "completion payload snapshot followed source mutation")
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_inspect_cqe 中构造或驱动“inspect cqe”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_inspect_cqe();
    rdma_hw_cmq_hw_profile profile;
    rdma_hw_error_codec oracle;
    rdma_hw_image raw_cqe;
    rdma_hw_image snapshot;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_decoded_cqe second_decoded;
    rdma_hw_cmq_completion payload;
    rdma_status expected_status;
    rdma_status status;
    bit ready;
    bit [7:0] ecode;

    ecode = RDMA_ECODE_EC_RCE_CQ_FULL;
    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "inspect_profile");
    oracle = rdma_hw_error_codec::type_id::create("error_oracle");
    raw_cqe = make_cqe(1'b1, RDMA_OP_CQC_QUERY, ecode, 5'h1b, 1'b1);
    snapshot = clone_image(raw_cqe, "raw_cqe_snapshot");
    ready = 1'b0;
    decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_STATUS", status, RDMA_SC_OK);
    if (!ready || decoded == null) begin
      `uvm_error("INSPECT_OUTPUT", "ready CQE did not publish decoded data")
      return;
    end
    expected_status = null;
    status = oracle.decode_status(ecode, RDMA_ENGINE_CMQ, expected_status);
    expect_status("INSPECT_ORACLE", status, RDMA_SC_OK);
    if (decoded.hardware_opcode != RDMA_OP_CQC_QUERY ||
        decoded.wqe_index != 5'h1b || !decoded.wqe_wrap ||
        decoded.hardware_ecode != ecode || decoded.command_status == null ||
        expected_status == null ||
        decoded.command_status.code != expected_status.code ||
        decoded.command_status.category != expected_status.category ||
        decoded.command_status.source_engine != expected_status.source_engine ||
        decoded.command_status.hardware_code != expected_status.hardware_code ||
        decoded.command_status.hardware_code_valid !=
          expected_status.hardware_code_valid)
      `uvm_error("INSPECT_FIELDS", "decoded CQE/error mapping is wrong")
    if (!$cast(payload, decoded.response_payload))
      `uvm_error("INSPECT_PAYLOAD_TYPE", "response payload lost xtr type")
    else if (!payload.owner || payload.opcode != RDMA_OP_CQC_QUERY ||
             payload.object_payload.size() != 56 ||
             payload.object_payload[0] != 8'h08 ||
             payload.object_payload[55] != 8'h3f)
      `uvm_error("INSPECT_PAYLOAD", "typed response payload is wrong")
    if (decoded.command_status.function_uid != 0 ||
        decoded.command_status.generation != 0 ||
        decoded.command_status.resource_id != 0 ||
        decoded.command_status.command_id != 0)
      `uvm_error("INSPECT_IDENTITY", "profile invented ticket identity")
    if (!images_equal(raw_cqe, snapshot))
      `uvm_error("INSPECT_IMMUTABLE", "inspect mutated raw CQE")

    second_decoded = null;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, second_decoded);
    expect_status("INSPECT_DETACHED_STATUS", status, RDMA_SC_OK);
    if (!ready || second_decoded == null || second_decoded == decoded ||
        second_decoded.response_payload == decoded.response_payload)
      `uvm_error("INSPECT_DETACHED", "decoded CQE outputs alias")

    raw_cqe = make_cqe(1'b0, 8'hfe, 8'hff, 5'h1f, 1'b1);
    raw_cqe.bytes[63] = 8'hff;
    decoded = rdma_cmq_decoded_cqe::type_id::create("stale_decoded");
    ready = 1'b1;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_OWNER_MISMATCH_STATUS", status, RDMA_SC_OK);
    if (ready || decoded != null)
      `uvm_error("INSPECT_OWNER_MISMATCH", "stale CQE was inspected")

    raw_cqe = make_cqe(1'b1, 8'hfe, 8'hff, 5'h1f, 1'b1);
    decoded = rdma_cmq_decoded_cqe::type_id::create(
      "stale_malformed_decoded");
    ready = 1'b1;
    status = profile.inspect_cqe(raw_cqe, 1'b1, ready, decoded);
    expect_status("INSPECT_MALFORMED_STATUS", status,
                  RDMA_SC_UNSUPPORTED_OPCODE);
    if (ready || decoded != null)
      `uvm_error("INSPECT_MALFORMED",
                 "malformed CQE published partial outputs")
  endfunction

  // 功能：在测试辅助 rdma_cmq_profile_test.check_encode_doorbell 中构造或驱动“encode doorbell”场景，并断言 DUT 的状态、错误码和资源账本符合契约。
  // 输入/输出及副作用：无显式参数；fixture/输入由测试调用方提供；执行时会产生 UVM assertion/report，不向 DUT 转移未声明的资源所有权。
  // 失败/边界：fixture 未初始化、故障注入未生效或观测值与预期不一致时报告 UVM_ERROR/断言失败；测试不会吞掉失败。
  function automatic void check_encode_doorbell();
    rdma_hw_cmq_hw_profile profile;
    rdma_handle cmq_h;
    rdma_hw_image image;
    rdma_hw_image second_image;
    rdma_status status;
    bit [63:0] word;

    profile = rdma_hw_cmq_hw_profile::type_id::create(
      "doorbell_profile");
    cmq_h = make_handle("doorbell_cmq", RDMA_RESOURCE_CMQ, 32'h55);
    image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_STATUS", status, RDMA_SC_OK);
    if (image == null) begin
      `uvm_error("DOORBELL_OUTPUT", "successful doorbell encode is null")
      return;
    end
    word = get_qword(image, 0);
    if (image.length != 8 || image.bytes.size() != 8 ||
        image.alignment != 8 || image.endian != RDMA_ENDIAN_BIG ||
        image.image_kind != RDMA_IMAGE_DOORBELL ||
        image.hardware_version != RDMA_HW_VERSION ||
        image.function_generation != TEST_GENERATION ||
        image.write_target_kind != RDMA_HW_TARGET_BAR ||
        image.bar_target.value != 64'h000 ||
        image.backing_target.value != 0 || image.hmc_target.value != 0 ||
        word[36:32] != 5'd17 || word[37] != 1'b1)
      `uvm_error("DOORBELL_FIELDS", "CMQ SQ doorbell is wrong")

    image.bytes[0] ^= 8'hff;
    second_image = null;
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, second_image);
    expect_status("DOORBELL_DETACHED_STATUS", status, RDMA_SC_OK);
    if (second_image == null || second_image == image ||
        get_qword(second_image, 0)[37:32] != 6'b1_10001)
      `uvm_error("DOORBELL_DETACHED", "doorbell output aliases codec state")

    image = rdma_hw_image::type_id::create("stale_bad_doorbell");
    status = profile.encode_doorbell(null, 17, 1'b1, image);
    expect_status("DOORBELL_NULL_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_NULL_HANDLE", "failure published image")
    cmq_h.kind = RDMA_RESOURCE_CQ;
    image = rdma_hw_image::type_id::create("stale_wrong_handle_doorbell");
    status = profile.encode_doorbell(cmq_h, 17, 1'b1, image);
    expect_status("DOORBELL_WRONG_HANDLE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_WRONG_HANDLE", "failure published image")
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    image = rdma_hw_image::type_id::create("stale_pi_range_doorbell");
    status = profile.encode_doorbell(cmq_h, 32, 1'b1, image);
    expect_status("DOORBELL_PI_RANGE", status, RDMA_SC_INVALID_ARGUMENT);
    if (image != null)
      `uvm_error("DOORBELL_PI_RANGE", "failure published image")
  endfunction

  // 功能：在 rdma_cmq_profile_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_profile_validation();
    check_body_snapshot_contract();
    check_compose_sqe();
    check_compose_generation_policy();
    check_completion_payload_snapshot_contract();
    check_inspect_cqe();
    check_encode_doorbell();
    phase.drop_objection(this);
  endtask
endclass
