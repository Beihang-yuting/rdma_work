// 目录：测试层 tests/unit/rdma_cmq_engine_models_test.sv。
// 职责：验证共享提交证据顺序、recovery owner、execution result 默认值，
// 以及 CMQ model 的 validation 与 detached clone。
// 依赖：依赖 rdma_model_pkg 导出的真实 helper/model 和 UVM test/object/report 基础设施。
// 所有权与生命周期：测试持有局部 fixture 引用；对象随 SystemVerilog 引用生命周期存在，
// 仿真结束时由模拟器回收，UVM 不拥有这些局部对象。

// 设计说明：该故障 fixture 专门让 validate() 返回 null，以覆盖 command 对异常 model 的拒绝路径。
class rdma_cmq_null_status_body extends rdma_hw_model;
  `uvm_object_utils(rdma_cmq_null_status_body)

  // 功能：构造一个 validate() 恒返 null 的 CMQ 测试 body，并初始化 UVM object 名称。
  // 输入/输出及副作用：name 传给 rdma_hw_model::new；不创建外部资源，也不设置业务字段。
  // 失败/边界：允许空名称；构造过程不校验后续 command，故障只在 validate() 调用时可见。
  function new(string name = "rdma_cmq_null_status_body");
    super.new(name);
  endfunction

  // 功能：注入非法的 null validation status，验证 command model 能拒绝异常 body 实现。
  // 输入/输出及副作用：无输入；恒定返回 null，不读取或修改对象字段，也不发布其他诊断。
  // 失败/边界：此返回值故意违反正常 rdma_hw_model 契约，仅供本单测的 INVALID_STATE 分支使用。
  virtual function rdma_status validate();
    return null;
  endfunction

  // 功能：为 null-status 故障 body 返回稳定描述，供被测模型的诊断路径识别 fixture 意图。
  // 输入/输出及副作用：无输入；返回固定 string，不读取或修改对象状态。
  // 失败/边界：不根据配置或 validation 结果变化；即使 validate() 返回 null 仍可安全调用。
  virtual function string describe();
    return "CMQ test body returning null validation status";
  endfunction
endclass

// 设计说明：错误类型载体只用于 raw factory 故障注入；它没有 RDMA 字段，
// 因而无法意外满足 status、ticket、image 或 completion 的值契约。
class rdma_cmq_value_wrong_factory_object extends uvm_object;
  `uvm_object_utils(rdma_cmq_value_wrong_factory_object)

  // 功能：构造不可转换为任一 CMQ 值类型的 UVM 测试对象。
  // 输入/输出及副作用：name 仅传给 uvm_object；不创建或登记 RDMA 资源。
  // 失败/边界：对象允许正常构造，但任何被测 RDMA typed cast 都必须失败。
  function new(string name = "rdma_cmq_value_wrong_factory_object");
    super.new(name);
  endfunction
endclass

// 设计说明：该注册 status 子类伪装基类名称，验证 required-status 边界只接受
// 唯一 rdma_status wrapper，不能把可覆盖的 legacy 类型名当作动态类型权限。
class rdma_cmq_spoofed_status_subtype extends rdma_status;
  typedef uvm_object_registry#(
    rdma_cmq_spoofed_status_subtype,
    "rdma_cmq_spoofed_status_subtype"
  ) type_id;

  // 功能：返回 hostile status fixture 的独立 UVM registry singleton。
  // 输入/输出及副作用：无输入；返回 type_id wrapper，不创建或修改 status。
  // 失败/边界：wrapper 注册名保持真实子类名，不受 get_type_name 基类伪装影响。
  static function type_id get_type();
    return type_id::get();
  endfunction

  // 功能：向 required-status 测试公开 hostile 子类的真实 wrapper 身份。
  // 输入/输出及副作用：无输入；返回 get_type()，不读取或写回 status 字段。
  // 失败/边界：不得返回 rdma_status 基类 wrapper，否则 fixture 无法覆盖名称冒充。
  virtual function uvm_object_wrapper get_object_type();
    return get_type();
  endfunction

  // 功能：构造公共字段均为合法默认值、但动态类型不受支持的 status fixture。
  // 输入/输出及副作用：name 传给 rdma_status；不安装 factory override 或外部资源。
  // 失败/边界：合法公共字段不能提升该子类权限，snapshot 必须按 wrapper 拒绝。
  function new(string name = "rdma_cmq_spoofed_status_subtype");
    super.new(name);
  endfunction

  // 功能：故意返回 rdma_status 基类名称，复现字符串 exact-type 检查的绕过。
  // 输入/输出及副作用：无输入；返回固定字符串，不改变独立 registry wrapper。
  // 失败/边界：仅伪装 legacy 诊断名；生产权限判断不得信任本返回值。
  virtual function string get_type_name();
    return "rdma_status";
  endfunction
endclass

// 设计说明：被测 nonfatal snapshot context 必须完全绕开 raw factory。
// wrapper 在 arm 窗口记录调用并返回 null/错误类型，disarm 后委托原 registry。
class rdma_cmq_value_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;
  protected bit wrong_type_state;
  protected int unsigned raw_create_calls;

  // 功能：保存原 factory wrapper，并以未注入、零调用计数状态启动。
  // 输入/输出及副作用：name 和 delegate_value 为输入；保存 delegate 非拥有引用。
  // 失败/边界：delegate_value 为空时，disarm 状态的 create_object 仍返回 null。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
    raw_create_calls = 0;
  endfunction

  // 功能：在故障窗口记录 raw create，并按模式返回 null 或不兼容对象。
  // 输入/输出及副作用：name 传给 delegate/错误对象；armed 时递增调用计数。
  // 失败/边界：disarm 时仅委托原 wrapper；原 wrapper 缺失则保守返回 null。
  virtual function uvm_object create_object(string name = "");
    rdma_cmq_value_wrong_factory_object wrong_object;

    if (!armed_state) begin
      if (delegate == null)
        return null;

      return delegate.create_object(name);
    end

    raw_create_calls++;
    if (!wrong_type_state)
      return null;

    wrong_object = new(name);
    return wrong_object;
  endfunction

  // 功能：返回 wrapper 的稳定测试类型名，供 UVM factory 显示 override。
  // 输入/输出及副作用：无输入；只读 wrapper_type_name，不修改 factory。
  // 失败/边界：名称不参与任何 RDMA authority 或值比较。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：开启 null/错误类型故障窗口并清零本窗口的 raw 调用计数。
  // 输入/输出及副作用：wrong_type 选择错误对象或 null；更新本 wrapper 状态。
  // 失败/边界：重复 arm 会开始新窗口，不改变 delegate 或全局 override。
  function void arm(bit wrong_type);
    armed_state = 1'b1;
    wrong_type_state = wrong_type;
    raw_create_calls = 0;
  endfunction

  // 功能：关闭故障窗口，使后续 factory create 恢复委托原 registry。
  // 输入/输出及副作用：无输入输出；只清除 armed/wrong-type 状态。
  // 失败/边界：disarm 幂等，且不会删除已安装的全局 type override。
  function void disarm();
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction

  // 功能：读取当前故障窗口内 raw create_object 的调用次数。
  // 输入/输出及副作用：无输入；返回 raw_create_calls，不修改 wrapper。
  // 失败/边界：未 arm 或窗口内无调用时返回零；计数不代表业务成功。
  function int unsigned call_count();
    return raw_create_calls;
  endfunction
endclass

typedef enum int unsigned {
  RDMA_CMQ_SNAPSHOT_CLONE_GOOD,
  RDMA_CMQ_SNAPSHOT_CLONE_NULL,
  RDMA_CMQ_SNAPSHOT_CLONE_SELF,
  RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE,
  RDMA_CMQ_SNAPSHOT_CLONE_MUTATE,
  RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL
} rdma_cmq_snapshot_clone_mode_e;

// 设计说明：Function primitive 历史上以 get_type_name() 而非
// registry wrapper 判定 clone 类型；该 peer 使用独立 wrapper 但返回 source 的类型名。
class rdma_cmq_snapshot_function_name_peer extends rdma_function_handle;
  typedef uvm_object_registry#(
    rdma_cmq_snapshot_function_name_peer,
    "rdma_cmq_snapshot_function_name_peer"
  ) type_id;

  // 功能：返回 Function name-peer 的独立 UVM registry wrapper。
  // 输入/输出及副作用：无输入；返回 type_id singleton，不创建或修改 handle。
  // 失败/边界：wrapper 必须与 source fixture 的 wrapper 不同，否则无法证明 type-name 语义。
  static function type_id get_type();
    return type_id::get();
  endfunction

  // 功能：向测试公开 name-peer 的真实 wrapper identity。
  // 输入/输出及副作用：无输入；返回 get_type()，不改写 identity 字段。
  // 失败/边界：不得返回 source 子类 wrapper，即使 get_type_name() 故意相同。
  virtual function uvm_object_wrapper get_object_type();
    return get_type();
  endfunction

  // 功能：构造字段待填充的 Function name-peer candidate。
  // 输入/输出及副作用：name 传给 rdma_function_handle；不安装 factory override 或保存 source 引用。
  // 失败/边界：构造后仅有基类默认 identity，必须由 fixture helper 填充后使用。
  function new(string name = "rdma_cmq_snapshot_function_name_peer");
    super.new(name);
  endfunction

  // 功能：故意返回 source hostile Function subtype 的类型名。
  // 输入/输出及副作用：无输入；返回固定 string，不改变真实 registry wrapper。
  // 失败/边界：该伪装只用于冻结既有契约，不代表两个 wrapper 具有相同 authority。
  virtual function string get_type_name();
    return "rdma_cmq_snapshot_function_handle";
  endfunction
endclass

// 设计说明：generic handle 与 Function handle 共享字段投影但保留不同输出类型；
// 独立 fixture 防止 Function 的固定 kind 假象掩盖 generic handle 边界。
class rdma_cmq_snapshot_handle extends rdma_handle;
  `uvm_object_utils(rdma_cmq_snapshot_handle)

  rdma_cmq_snapshot_clone_mode_e clone_mode;
  int unsigned clone_calls;
  int unsigned extension_value;
  rdma_handle third_equal_value;

  // 功能：构造默认正常 clone 的 generic handle hostile fixture。
  // 输入/输出及副作用：name 传给 rdma_handle；初始化模式、计数、扩展值与第三对象引用。
  // 失败/边界：不自动填充资源 kind 或 incarnation；非法值由调用测试显式构造。
  function new(string name = "rdma_cmq_snapshot_handle");
    super.new(name);
    clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    clone_calls = 0;
    extension_value = 0;
    third_equal_value = null;
  endfunction

  // 功能：按 clone_mode 产生 generic handle 的正常、别名、错类型或 source-mutation clone 结果。
  // 输入/输出及副作用：无显式输入；递增 clone_calls，mutate 模式改写全部四个公开字段。
  // 失败/边界：third_equal_value 为 null 时 third-equal 也返回 null；故障输出不归 fixture 回收。
  virtual function uvm_object clone();
    rdma_cmq_value_wrong_factory_object wrong_object;

    clone_calls++;
    case (clone_mode)
      RDMA_CMQ_SNAPSHOT_CLONE_NULL: return null;
      RDMA_CMQ_SNAPSHOT_CLONE_SELF: return this;
      RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE: begin
        wrong_object = new({get_name(), "_wrong_type"});
        return wrong_object;
      end
      RDMA_CMQ_SNAPSHOT_CLONE_MUTATE: begin
        kind = RDMA_RESOURCE_CQ;
        function_uid++;
        object_id++;
        generation++;
        return super.clone();
      end
      RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL: return third_equal_value;
      default: return super.clone();
    endcase
  endfunction
endclass

// 设计说明：generic-handle peer 与 source 可以 cast 到同一基类，
// 但拥有独立 registry wrapper；伪装类型名用于冻结既有 string-based clone gate。
class rdma_cmq_snapshot_handle_name_peer extends rdma_handle;
  typedef uvm_object_registry#(
    rdma_cmq_snapshot_handle_name_peer,
    "rdma_cmq_snapshot_handle_name_peer"
  ) type_id;

  // 功能：返回 generic-handle name-peer 的独立 UVM registry wrapper。
  // 输入/输出及副作用：无输入；返回 type_id singleton，不创建资源或更改 factory。
  // 失败/边界：wrapper 不得退化为 rdma_cmq_snapshot_handle 的 wrapper。
  static function type_id get_type();
    return type_id::get();
  endfunction

  // 功能：公开 generic-handle name-peer 的真实 wrapper identity。
  // 输入/输出及副作用：无输入；返回 get_type()，不读写 handle 公开字段。
  // 失败/边界：get_type_name() 相同不得影响本函数返回独立 wrapper。
  virtual function uvm_object_wrapper get_object_type();
    return get_type();
  endfunction

  // 功能：构造尚未填充 identity 的 generic-handle name-peer candidate。
  // 输入/输出及副作用：name 传给 rdma_handle；不登记真实资源或拥有外部对象。
  // 失败/边界：调用方必须显式填充 kind/UID/object/generation 后才可作为等值 candidate。
  function new(string name = "rdma_cmq_snapshot_handle_name_peer");
    super.new(name);
  endfunction

  // 功能：故意返回 source hostile generic-handle subtype 的类型名。
  // 输入/输出及副作用：无输入；返回固定 string，不修改真实 wrapper 或 identity。
  // 失败/边界：仅用于证明 package helper 依赖类型名；不把字符串伪装作为新的权威设计。
  virtual function string get_type_name();
    return "rdma_cmq_snapshot_handle";
  endfunction
endclass

// 设计说明：测试集中覆盖共享只读值 helper 和既有 CMQ value model；binding helper
// 允许 accessor 的瞬态 status/identity，其余纯比较 helper 属性不变，且不引入 mock 或外部 I/O。
class rdma_cmq_engine_models_test extends uvm_test;
  `uvm_component_utils(rdma_cmq_engine_models_test)

  localparam longint unsigned TEST_FUNCTION_UID =
    64'h1122_3344_5566_7788;
  localparam int unsigned TEST_GENERATION = 32'd7;

  protected rdma_cmq_value_factory_fault_wrapper status_fault;
  protected rdma_cmq_value_factory_fault_wrapper ticket_fault;
  protected rdma_cmq_value_factory_fault_wrapper image_fault;
  protected rdma_cmq_value_factory_fault_wrapper completion_fault;

  // 功能：构造 CMQ model 单元测试组件，并通过 UVM 基类建立名称和父子层级。
  // 输入/输出及副作用：name 和 parent 传给 uvm_test::new；fixture 延迟到 run_phase 创建。
  // 失败/边界：parent 可为 null 以作为顶层 test；构造阶段不执行断言、仿真事务或资源分配。
  function new(string name = "rdma_cmq_engine_models_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：比较 model 返回的 status code 与手工期望，并用 check_name 标识失败分支。
  // 输入/输出及副作用：读取 check_name、status 和 expected_code；不匹配时发布 UVM error。
  // 失败/边界：status 为 null 时报告错误并立即返回；匹配时无输出且不修改 status。
  function automatic void expect_status(
    string check_name,
    rdma_status status,
    rdma_status_code_e expected_code
  );
    if (status == null) begin
      `uvm_error(check_name, "model returned a null status")
      return;
    end
    if (status.code != expected_code)
      `uvm_error(check_name,
                 $sformatf("expected %s, got %s (%s)",
                           expected_code.name(), status.code.name(),
                           status.convert2string()))
  endfunction

  // 功能：创建带固定 function_uid、object_id 和 generation 的 Function handle fixture。
  // 输入/输出及副作用：name 用作 UVM object 名称；返回新 handle，由测试局部引用持有。
  // 失败/边界：不校验 name；假定已注册 factory 返回非空对象，不建立 topology 或外部绑定。
  function automatic rdma_function_handle make_function(string name);
    rdma_function_handle function_h;

    function_h = rdma_function_handle::type_id::create(name);
    function_h.function_uid = TEST_FUNCTION_UID;
    function_h.object_id = 32'h1234;
    function_h.generation = TEST_GENERATION;
    return function_h;
  endfunction

  // 功能：按 Function fixture 的 uid/generation 创建固定 object_id 的 CMQ handle。
  // 输入/输出及副作用：读取 name 和 function_h；返回新 handle，不修改输入 Function handle。
  // 失败/边界：function_h 必须非空；helper 不做空值防护，也不建立真实 CMQ 资源。
  function automatic rdma_handle make_cmq(
    string name,
    rdma_function_handle function_h
  );
    rdma_handle cmq_h;

    cmq_h = rdma_handle::type_id::create(name);
    cmq_h.kind = RDMA_RESOURCE_CMQ;
    cmq_h.function_uid = function_h.function_uid;
    cmq_h.object_id = 32'h55;
    cmq_h.generation = function_h.generation;
    return cmq_h;
  endfunction

  // 功能：创建 generic_profile/query 对应固定 opcode 的 CMQ opcode key fixture。
  // 输入/输出及副作用：name 用作 UVM object 名称；返回新 key，不修改其他 fixture。
  // 失败/边界：不校验 name；固定字段本身有效，错误分支由调用方后续 mutation 构造。
  function automatic rdma_cmq_opcode_key make_key(string name);
    rdma_cmq_opcode_key key;

    key = rdma_cmq_opcode_key::type_id::create(name);
    key.profile_name = "generic_profile";
    key.opcode = 32'hff00_abcd;
    key.variant = "query";
    return key;
  endfunction

  // 功能：创建 QUERY SQE body fixture，并关联固定 command_id、Function 和 target handle。
  // 输入/输出及副作用：读取 name、function_h、target_h；返回新 body，保存输入对象引用但不修改它们。
  // 失败/边界：允许保存 null handle 供后续 validation 拒绝；helper 本身不验证 handle 世代或 kind。
  function automatic rdma_cmq_sqe_model make_body(
    string name,
    rdma_function_handle function_h,
    rdma_handle target_h
  );
    rdma_cmq_sqe_model body;

    body = rdma_cmq_sqe_model::type_id::create(name);
    body.opcode = RDMA_CMQ_QUERY;
    body.command_id = 64'h111;
    body.function_h = function_h;
    body.target_h = target_h;
    return body;
  endfunction

  // 功能：创建由 8'h5a 填充的硬件 image fixture，并设置长度、对齐、端序、kind 和 generation。
  // 输入/输出及副作用：读取 name、image_kind、byte_count、generation；返回新 image 和独立 bytes。
  // 失败/边界：byte_count 为零时返回空 bytes；不验证 kind/长度组合，错误 metadata 由 validate 拒绝。
  function automatic rdma_hw_image make_image(
    string name,
    rdma_image_kind_e image_kind,
    int unsigned byte_count,
    int unsigned generation
  );
    rdma_hw_image image;

    image = rdma_hw_image::type_id::create(name);
    repeat (byte_count)
      image.bytes.push_back(8'h5a);
    image.length = byte_count;
    image.alignment = 64;
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = image_kind;
    image.hardware_version = 1;
    image.function_generation = generation;
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target = '0;
    image.hmc_target = '0;
    image.bar_target = '0;
    return image;
  endfunction

  // 功能：创建固定 command/slot/deadline 的 CMQ ticket fixture，并关联 Function、CMQ 和 opcode key。
  // 输入/输出及副作用：读取 name 及三个对象引用；返回新 ticket，不克隆或修改输入对象。
  // 失败/边界：允许保存 null 引用供 ticket.validate() 拒绝；helper 不检查世代、slot 或 deadline。
  function automatic rdma_cmq_ticket make_ticket(
    string name,
    rdma_function_handle function_h,
    rdma_handle cmq_h,
    rdma_cmq_opcode_key opcode_key
  );
    rdma_cmq_ticket ticket;

    ticket = rdma_cmq_ticket::type_id::create(name);
    ticket.command_id = 64'h1234_0005;
    ticket.function_h = function_h;
    ticket.cmq_h = cmq_h;
    ticket.slot_sequence = 64'd37;
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b1;
    ticket.opcode_key = opcode_key;
    ticket.absolute_deadline = 64'd1000;
    return ticket;
  endfunction

  // 功能：创建与 TEST Function handle 完全一致、带显式 Host/root/BDF 的身份快照。
  // 输入/输出及副作用：name 用作对象名；返回测试持有的新 identity，不修改全局 topology。
  // 失败/边界：固定 fixture 应通过 validate；若 factory 返回空，调用测试会报告失败。
  function automatic rdma_function_identity make_identity(string name);
    rdma_function_identity identity;
    rdma_function_key_t function_key;
    rdma_status status;

    function_key = '{
      root_id:16'h44,
      host_topology_key:32'h5566_7788,
      function_kind:RDMA_FUNCTION_VF,
      parent_pf_bdf:'{
        segment:16'h1,
        bus:8'h20,
        device:5'h3,
        function_num:3'h0
      },
      vf_index:16'h2,
      bdf:'{
        segment:16'h1,
        bus:8'h21,
        device:5'h4,
        function_num:3'h1
      }
    };
    identity = rdma_function_identity::type_id::create(name);
    status = identity.configure(
      function_key,
      32'h1234,
      TEST_FUNCTION_UID,
      TEST_GENERATION,
      64'h0102_0304_0506_0708
    );
    if (status == null || !status.ok())
      `uvm_error("IDENTITY_FIXTURE", "failed to configure identity fixture")

    return identity;
  endfunction

  // 功能：创建指定 resource kind/object ID、归属测试 Function incarnation 的句柄。
  // 输入/输出及副作用：name、kind、object_id 为输入；返回新 handle，不登记真实资源。
  // 失败/边界：允许调用方传入不受 owner workflow 支持的 kind，以构造拒绝用例。
  function automatic rdma_handle make_resource_handle(
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

  // 功能：创建尚未冻结的具体 recovery owner，显式绑定 workflow/kind/action。
  // 输入/输出及副作用：name、workflow、kind、action 为输入；返回新 owner 与资源句柄。
  // 失败/边界：helper 不修正非法组合；INVALID/spare action 仅供被测 validator 拒绝。
  function automatic rdma_cmq_recovery_owner make_owner(
    string name,
    rdma_cmq_recovery_workflow_e workflow,
    rdma_resource_kind_e kind,
    rdma_cmq_submission_recovery_action_e action
  );
    rdma_cmq_recovery_owner owner;

    owner = rdma_cmq_recovery_owner::type_id::create(name);
    owner.workflow = workflow;
    owner.resource_h = make_resource_handle(
      {name, "_resource"}, kind, 32'h7788
    );
    owner.transaction_id = 64'h1111_2222_3333_4444;
    owner.allowed_actions = '0;
    owner.allowed_actions[action] = 1'b1;
    return owner;
  endfunction

  // 功能：验证 legacy sentinel、具体 workflow/kind 矩阵、冻结 provenance 和 action fail-closed。
  // 输入/输出及副作用：无显式输入；构造本地 owner/command 并通过 UVM report 发布断言。
  // 失败/边界：覆盖零 ID、重复冻结、identity/resource 漂移、spare/X/Z action 与 mask。
  function automatic void check_recovery_owner_contract();
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_function_identity identity;
    rdma_function_identity wrong_identity;
    rdma_cmq_submission_recovery_action_e unknown_action;
    rdma_cmq_submission_recovery_action_e spare_action;
    rdma_cmq_recovery_workflow_e unknown_workflow;
    rdma_cmq_command_desc command;
    rdma_cmq_command_desc command_snapshot;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    uvm_object cloned_object;

    owner = rdma_cmq_recovery_owner::legacy_unmigrated();
    if (owner == null ||
        owner.workflow != RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED ||
        owner.resource_h != null || owner.transaction_id != 0 ||
        owner.allowed_actions !== 3'b000 ||
        owner.function_identity != null ||
        owner.admission_attempt_id != 0 || owner.frozen)
      `uvm_error("LEGACY_OWNER_SHAPE", "legacy owner sentinel shape drifted")
    expect_status("LEGACY_OWNER_VALID",
                  owner.validate_for_admission(), RDMA_SC_OK);

    owner.allowed_actions[RDMA_CMQ_RECOVERY_RETRY_PUBLISH] = 1'b1;
    expect_status("LEGACY_OWNER_NO_ACTION",
                  owner.validate_for_admission(), RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = '0;
    if (owner.permits(RDMA_CMQ_RECOVERY_RETRY_PUBLISH) ||
        owner.permits(RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION) ||
        owner.permits(RDMA_CMQ_RECOVERY_INVALID))
      `uvm_error("LEGACY_OWNER_PERMITS", "legacy sentinel permitted an action")
    expect_status(
      "LEGACY_OWNER_NO_FREEZE",
      owner.freeze_for_journal(make_identity("legacy_identity"), 1),
      RDMA_SC_INVALID_ARGUMENT
    );

    owner = make_owner(
      "owner_mr",
      RDMA_CMQ_WORKFLOW_MR,
      RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_MR_VALID", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_QP;
    expect_status("OWNER_MR_REJECT_QP", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.resource_h.kind = RDMA_RESOURCE_MR;

    owner = make_owner(
      "owner_qp",
      RDMA_CMQ_WORKFLOW_QP,
      RDMA_RESOURCE_QP,
      RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
    );
    expect_status("OWNER_QP_VALID", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_MR;
    expect_status("OWNER_QP_REJECT_MR", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_queue_cq", RDMA_CMQ_WORKFLOW_QUEUE, RDMA_RESOURCE_CQ,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_QUEUE_CQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_SRQ;
    expect_status("OWNER_QUEUE_SRQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_CEQ;
    expect_status("OWNER_QUEUE_CEQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    owner.resource_h.kind = RDMA_RESOURCE_AEQ;
    expect_status("OWNER_QUEUE_AEQ", owner.validate_for_admission(),
                  RDMA_SC_OK);
    for (int unsigned kind_value = RDMA_RESOURCE_FUNCTION;
         kind_value <= RDMA_RESOURCE_MW; kind_value++) begin
      if (kind_value inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                             RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})
        continue;

      owner.resource_h.kind = rdma_resource_kind_e'(kind_value);
      expect_status(
        $sformatf("OWNER_QUEUE_REJECT_%0d", kind_value),
        owner.validate_for_admission(), RDMA_SC_INVALID_ARGUMENT
      );
    end

    owner = make_owner(
      "owner_bad_fields", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    owner.transaction_id = 0;
    expect_status("OWNER_ZERO_TRANSACTION", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.transaction_id = 1;
    owner.allowed_actions = 3'b001;
    expect_status("OWNER_INVALID_ACTION_BIT", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b000;
    expect_status("OWNER_NO_ACTION", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b1x0;
    expect_status("OWNER_UNKNOWN_ACTION_MASK", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.allowed_actions = 3'b010;
    owner.function_identity = make_identity("premature_identity");
    expect_status("OWNER_PREMATURE_IDENTITY", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.function_identity = null;
    owner.admission_attempt_id = 1;
    expect_status("OWNER_PREMATURE_ATTEMPT", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.admission_attempt_id = 0;
    owner.frozen = 1'b1;
    expect_status("OWNER_PREMATURE_FROZEN", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.frozen = 1'b0;
    owner.resource_h = null;
    expect_status("OWNER_NULL_RESOURCE", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_permits", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    if (!owner.permits(RDMA_CMQ_RECOVERY_RETRY_PUBLISH) ||
        owner.permits(RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION))
      `uvm_error("OWNER_PERMITS", "legal action mask was misread")
    unknown_action = rdma_cmq_submission_recovery_action_e'(2'bx1);
    spare_action = rdma_cmq_submission_recovery_action_e'(2'b11);
    if (owner.permits(unknown_action) || owner.permits(spare_action) ||
        owner.permits(RDMA_CMQ_RECOVERY_INVALID))
      `uvm_error("OWNER_ACTION_FAIL_CLOSED",
                 "unknown, INVALID or spare action was accepted")

    unknown_workflow = rdma_cmq_recovery_workflow_e'(3'bx10);
    owner.workflow = unknown_workflow;
    expect_status("OWNER_UNKNOWN_WORKFLOW", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.workflow = rdma_cmq_recovery_workflow_e'(3'd5);
    expect_status("OWNER_SPARE_WORKFLOW", owner.validate_for_admission(),
                  RDMA_SC_INVALID_ARGUMENT);

    owner = make_owner(
      "owner_freeze", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    identity = make_identity("owner_identity");
    expect_status("OWNER_FREEZE_ZERO_ATTEMPT",
                  owner.freeze_for_journal(identity, 0),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_identity = make_identity("owner_wrong_identity");
    wrong_identity.function_uid++;
    expect_status("OWNER_FREEZE_IDENTITY_MISMATCH",
                  owner.freeze_for_journal(wrong_identity, 7),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("OWNER_FREEZE", owner.freeze_for_journal(identity, 7),
                  RDMA_SC_OK);
    if (!owner.frozen || owner.admission_attempt_id != 7 ||
        owner.function_identity == null ||
        owner.function_identity == identity ||
        !owner.function_identity.same_incarnation(identity))
      `uvm_error("OWNER_FREEZE_VALUE",
                 "freeze did not retain detached immutable provenance")
    expect_status("OWNER_DUPLICATE_FREEZE",
                  owner.freeze_for_journal(identity, 7),
                  RDMA_SC_INVALID_STATE);
    expect_status("OWNER_FROZEN_VALID",
                  owner.validate_frozen(identity, 7), RDMA_SC_OK);
    expect_status("OWNER_FROZEN_ATTEMPT_MISMATCH",
                  owner.validate_frozen(identity, 8),
                  RDMA_SC_INVALID_ARGUMENT);
    wrong_identity = make_identity("owner_other_epoch");
    wrong_identity.reset_epoch++;
    expect_status("OWNER_FROZEN_IDENTITY_MISMATCH",
                  owner.validate_frozen(wrong_identity, 7),
                  RDMA_SC_INVALID_ARGUMENT);
    owner.resource_h.generation++;
    expect_status("OWNER_FROZEN_RESOURCE_MISMATCH",
                  owner.validate_frozen(identity, 7),
                  RDMA_SC_STALE_GENERATION);
    owner.resource_h.generation--;

    function_h = make_function("owner_command_function");
    cmq_h = make_cmq("owner_command_cmq", function_h);
    key = make_key("owner_command_key");
    body = make_body("owner_command_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("owner_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.timeout = 100;
    expect_status("COMMAND_LEGACY_OWNER", command.validate(), RDMA_SC_OK);
    if (command.recovery_owner == null ||
        command.recovery_owner.workflow !=
          RDMA_CMQ_WORKFLOW_LEGACY_UNMIGRATED)
      `uvm_error("COMMAND_LEGACY_OWNER", "constructor omitted sentinel")
    expect_status("COMMAND_LEGACY_JOURNAL",
                  command.validate_for_journal(identity, 7), RDMA_SC_OK);

    command.recovery_owner = owner;
    expect_status("COMMAND_FROZEN_ADMISSION_REJECT", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expect_status("COMMAND_FROZEN_JOURNAL",
                  command.validate_for_journal(identity, 7), RDMA_SC_OK);
    cloned_object = command.clone();
    if (!$cast(command_snapshot, cloned_object) ||
        command_snapshot.recovery_owner == null ||
        command_snapshot.recovery_owner == command.recovery_owner ||
        command_snapshot.recovery_owner.resource_h ==
          command.recovery_owner.resource_h ||
        command_snapshot.recovery_owner.function_identity ==
          command.recovery_owner.function_identity)
      `uvm_error("COMMAND_OWNER_COPY", "command owner was not deep-copied")
    else begin
      owner_snapshot = command_snapshot.recovery_owner;
      owner_snapshot.transaction_id++;
      if (command.recovery_owner.transaction_id !=
          64'h1111_2222_3333_4444)
        `uvm_error("COMMAND_OWNER_COPY", "copied owner aliases source")
    end

    command.recovery_owner = null;
    expect_status("COMMAND_NULL_OWNER", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
  endfunction

  // 功能：验证 execution result 的保守默认值与 completion phase 编码。
  // 输入/输出及副作用：无显式输入；创建本地 result 并用 UVM error 报告契约偏差。
  // 失败/边界：默认值为成功、null status 或 phase 编码漂移时报告 UVM_ERROR。
  function automatic void check_execution_value_defaults();
    rdma_cmq_execution_result result;

    result = new("uninitialized_result");
    if (result.status == null || result.status.ok() ||
        result.status.code != RDMA_SC_INVALID_STATE ||
        result.observation_status == null ||
        result.observation_status.ok() ||
        result.observation_status.code != RDMA_SC_INVALID_STATE ||
        result.status == result.observation_status ||
        result.submission_effect != RDMA_SUBMIT_EFFECT_UNOBSERVED ||
        result.completion_phase != RDMA_CMQ_COMPLETION_UNOBSERVED ||
        !result.recovery_required)
      `uvm_error("EXECUTION_DEFAULT",
                 "new execution result defaulted to success or null status")
    if (RDMA_CMQ_COMPLETION_NONE != 0 ||
        RDMA_CMQ_COMPLETION_PENDING != 1 ||
        RDMA_CMQ_COMPLETION_TERMINAL != 2 ||
        RDMA_CMQ_COMPLETION_TIMEOUT != 3 ||
        RDMA_CMQ_COMPLETION_RESET_CANCELLED != 4 ||
        RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY != 5 ||
        RDMA_CMQ_COMPLETION_UNOBSERVED != 6)
      `uvm_error("COMPLETION_PHASE_ENCODING", "completion phase encoding changed")
  endfunction

  // 功能：检查共享 submission effect helper 只允许副作用阶段前进，并保持两个终止分支闭合。
  // 输入/输出及副作用：无显式输入或返回值；调用真实 helper，并通过 UVM error 发布失败结果。
  // 失败/边界：阶段回退、终止分支重开以及 before/after 含 X/Z 时均必须被 helper 拒绝。
  function automatic void check_submission_effect_ordering();
    rdma_submission_effect_e unknown_effect;

    if (!rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE))
      `uvm_error("EFFECT_FORWARD", "forward effect was rejected")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED))
      `uvm_error("EFFECT_REGRESSION", "effect regression was accepted")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE))
      `uvm_error("EFFECT_TERMINAL", "pre-submit rejection was reopened")

    if (rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE))
      `uvm_error("EFFECT_UNOBSERVED", "unknown evidence was promoted")

    unknown_effect = rdma_submission_effect_e'(3'bx);

    if (rdma_submission_effect_is_monotonic(
          unknown_effect,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE) ||
        rdma_submission_effect_is_monotonic(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN,
          unknown_effect))
      `uvm_error("EFFECT_X", "four-state unknown evidence was accepted")
  endfunction

  // 功能：运行各 model 检查，并验证 CMQ 值对象的 validation 与 detached clone。
  // 输入/输出及副作用：phase 由 UVM 提供；task 持有 objection，调用断言并在结束时释放。
  // 失败/边界：任一 ordering、validation 或 clone 契约失败均产生 UVM error；task 仍释放
  // objection，且不接管 DUT 资源。
  task run_phase(uvm_phase phase);
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_command_desc command;
    rdma_cmq_slot_context slot;
    rdma_cmq_expected_response expected;
    rdma_cmq_decoded_cqe decoded;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_cmq_runtime_desc runtime_desc;

    rdma_cmq_opcode_key key_snapshot;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_cmq_expected_response expected_snapshot;
    rdma_cmq_decoded_cqe decoded_snapshot;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_cmq_runtime_desc runtime_snapshot;

    rdma_cmq_sqe_model body;
    rdma_cmq_sqe_model body_snapshot;
    rdma_cmq_null_status_body null_status_body;
    rdma_qpc_behavior response_payload;
    rdma_qpc_behavior response_payload_snapshot;
    rdma_qpc_behavior decoded_response;
    rdma_qpc_behavior decoded_response_snapshot;
    uvm_object cloned_object;

    phase.raise_objection(this);

    // 先校验独立的共享只读值契约；binding accessor 允许瞬态 status/identity，
    // ordering 检查不依赖后续 CMQ object fixture。
    check_submission_effect_ordering();
    check_recovery_owner_contract();
    check_execution_value_defaults();

    // 初始化一组有效且相互关联的 CMQ model，随后逐字段注入 validation 错误。
    function_h = make_function("function_h");
    cmq_h = make_cmq("cmq_h", function_h);
    key = make_key("key");
    body = make_body("body", function_h, cmq_h);

    command = rdma_cmq_command_desc::type_id::create("command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = make_image(
      "qpc_signature_source", RDMA_IMAGE_QPC, 512, TEST_GENERATION
    );
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 100;

    slot = rdma_cmq_slot_context::type_id::create("slot");
    slot.function_h = function_h;
    slot.cmq_h = cmq_h;
    slot.backing_addr.value = 64'h0000_0000_4000_0000;
    slot.relative_offset = 64'd320;
    slot.slot_sequence = 64'd37;
    slot.sq_index = 5;
    slot.sq_wrap = 1'b1;

    expected = rdma_cmq_expected_response::type_id::create("expected");
    expected.hardware_opcode = 32'hff00_abcd;
    expected.variant = "query";

    response_payload = rdma_qpc_behavior::type_id::create(
      "response_payload"
    );
    response_payload.transport_version = 1;
    response_payload.\priority = 3;
    decoded = rdma_cmq_decoded_cqe::type_id::create("decoded");
    decoded.hardware_opcode = 32'hff00_abcd;
    decoded.wqe_index = 5;
    decoded.wqe_wrap = 1'b1;
    decoded.hardware_ecode = 32'ha5;
    decoded.command_status = rdma_status::success("decoded success");
    decoded.command_status.hardware_code = 32'ha5;
    decoded.command_status.hardware_code_valid = 1'b1;
    decoded.response_payload = response_payload;

    ticket = make_ticket("ticket", function_h, cmq_h, key);

    decoded_response = rdma_qpc_behavior::type_id::create(
      "decoded_response"
    );
    decoded_response.transport_version = 2;
    decoded_response.\priority = 4;
    completion = rdma_cmq_completion::type_id::create("completion");
    completion.ticket = ticket;
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64, TEST_GENERATION
    );
    completion.decoded_response = decoded_response;

    runtime_desc = rdma_cmq_runtime_desc::type_id::create("runtime_desc");
    runtime_desc.function_h = function_h;
    runtime_desc.cmq_h = cmq_h;
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 64;
    runtime_desc.initial_sq_valid = 1'b1;
    runtime_desc.initial_cq_owner = 1'b1;
    runtime_desc.initial_doorbell_polarity = 1'b0;

    // 先确认有效基线，再短暂修改单一字段覆盖各 model 的拒绝与恢复边界。
    expect_status("KEY_VALID", key.validate(), RDMA_SC_OK);
    expect_status("COMMAND_VALID", command.validate(), RDMA_SC_OK);
    expect_status("SLOT_VALID", slot.validate(), RDMA_SC_OK);
    expect_status("EXPECTED_VALID", expected.validate(), RDMA_SC_OK);
    expect_status("DECODED_VALID", decoded.validate(), RDMA_SC_OK);
    expect_status("TICKET_VALID", ticket.validate(), RDMA_SC_OK);
    expect_status("COMPLETION_VALID", completion.validate(), RDMA_SC_OK);
    expect_status("RUNTIME_VALID", runtime_desc.validate(), RDMA_SC_OK);

    key.profile_name = "";
    expect_status("KEY_EMPTY_PROFILE", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "";
    expect_status("KEY_EMPTY_VARIANT", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";
    key.profile_name = "generic|profile";
    expect_status("KEY_PROFILE_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.profile_name = "generic_profile";
    key.variant = "query|fast";
    expect_status("KEY_VARIANT_SEPARATOR", key.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    key.variant = "query";

    command.body = null;
    expect_status("COMMAND_NULL_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.body = body;
    body.command_id = 0;
    expect_status("COMMAND_INVALID_BODY", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    body.command_id = 64'h111;
    null_status_body = rdma_cmq_null_status_body::type_id::create(
      "null_status_body"
    );
    command.body = null_status_body;
    expect_status("COMMAND_NULL_BODY_STATUS", command.validate(),
                  RDMA_SC_INVALID_STATE);
    command.body = body;
    command.timeout = 0;
    expect_status("COMMAND_ZERO_TIMEOUT", command.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    command.timeout = 100;
    command.qpc_signature_source.function_generation++;
    expect_status("COMMAND_STALE_SIGNATURE", command.validate(),
                  RDMA_SC_STALE_GENERATION);
    command.qpc_signature_source.function_generation--;

    slot.sq_index = 32;
    expect_status("SLOT_INDEX", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.sq_index = 5;
    slot.relative_offset = 64'd321;
    expect_status("SLOT_OFFSET", slot.validate(), RDMA_SC_INVALID_ARGUMENT);
    slot.relative_offset = 64'd320;
    slot.backing_addr.value++;
    expect_status("SLOT_ALIGNMENT", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.backing_addr.value--;
    slot.slot_sequence = 38;
    expect_status("SLOT_SEQUENCE", slot.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    slot.slot_sequence = 37;
    slot.cmq_h.generation++;
    expect_status("SLOT_STALE_CMQ", slot.validate(),
                  RDMA_SC_STALE_GENERATION);
    slot.cmq_h.generation--;
    slot.backing_addr.value = 64'hffff_ffff_ffff_ffc0;
    slot.relative_offset = 64'd320;
    expect_status("SLOT_ADDRESS_OVERFLOW", slot.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    slot.backing_addr.value = 64'h0000_0000_4000_0000;

    expected.variant = "";
    expect_status("EXPECTED_EMPTY_VARIANT", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query|fast";
    expect_status("EXPECTED_SEPARATOR", expected.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    expected.variant = "query";

    decoded.command_status = null;
    expect_status("DECODED_NULL_STATUS", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.command_status = rdma_status::success("decoded success");
    decoded.wqe_index = 32;
    expect_status("DECODED_INDEX", decoded.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    decoded.wqe_index = 5;

    ticket.command_id = 0;
    expect_status("TICKET_ZERO_ID", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.command_id = 64'h1234_0005;
    ticket.absolute_deadline = 0;
    expect_status("TICKET_ZERO_DEADLINE", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.absolute_deadline = 1000;
    ticket.sq_index = 32;
    expect_status("TICKET_INDEX", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_index = 5;
    ticket.sq_wrap = 1'b0;
    expect_status("TICKET_WRAP", ticket.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    ticket.sq_wrap = 1'b1;

    completion.ticket = null;
    expect_status("COMPLETION_NULL_TICKET", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.ticket = ticket;
    completion.status = null;
    expect_status("COMPLETION_NULL_STATUS", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = null;
    expect_status("COMPLETION_SUCCESS_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.status = rdma_status::make(RDMA_SC_TIMEOUT, "timed out");
    expect_status("COMPLETION_TIMEOUT_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::make(
      RDMA_SC_RESET_CANCELLED, "reset cancellation"
    );
    expect_status("COMPLETION_RESET_WITHOUT_CQE", completion.validate(),
                  RDMA_SC_OK);
    completion.status = rdma_status::success("hardware completion");
    completion.raw_cqe = make_image(
      "completion_raw_cqe_restored", RDMA_IMAGE_CMQ_CQE, 64,
      TEST_GENERATION
    );
    completion.raw_cqe.alignment = 32;
    expect_status("COMPLETION_CQE_ALIGNMENT", completion.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    completion.raw_cqe.alignment = 64;
    completion.raw_cqe.function_generation++;
    expect_status("COMPLETION_CQE_GENERATION", completion.validate(),
                  RDMA_SC_STALE_GENERATION);
    completion.raw_cqe.function_generation--;

    runtime_desc.sq_depth = 31;
    expect_status("RUNTIME_SQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.sq_depth = 32;
    runtime_desc.cq_depth = 31;
    expect_status("RUNTIME_CQ_DEPTH", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_depth = 32;
    runtime_desc.entry_bytes = 32;
    expect_status("RUNTIME_ENTRY_BYTES", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.entry_bytes = 64;
    runtime_desc.cq_iova.value++;
    expect_status("RUNTIME_LAYOUT", runtime_desc.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    runtime_desc.cq_iova.value--;
    runtime_desc.sq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_SQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.sq_iova.value = 64'h0000_0001_2000_0000;
    runtime_desc.cq_iova.value = 64'hffff_ffff_ffff_ffc0;
    expect_status("RUNTIME_CQ_ADD_OVERFLOW", runtime_desc.validate(),
                  RDMA_SC_DMA_TRANSLATION);
    runtime_desc.cq_iova.value = 64'h0000_0001_2000_0800;

    // 对每个值对象执行真实 clone，并先确认动态类型和嵌套引用均已 detached。
    cloned_object = key.clone();
    if (!$cast(key_snapshot, cloned_object))
      `uvm_error("KEY_CLONE", "opcode key clone has wrong type")

    cloned_object = command.clone();
    if (!$cast(command_snapshot, cloned_object))
      `uvm_error("COMMAND_CLONE", "command clone has wrong type")

    cloned_object = slot.clone();
    if (!$cast(slot_snapshot, cloned_object))
      `uvm_error("SLOT_CLONE", "slot clone has wrong type")

    cloned_object = expected.clone();
    if (!$cast(expected_snapshot, cloned_object))
      `uvm_error("EXPECTED_CLONE", "expected response clone has wrong type")

    cloned_object = decoded.clone();
    if (!$cast(decoded_snapshot, cloned_object))
      `uvm_error("DECODED_CLONE", "decoded CQE clone has wrong type")

    cloned_object = ticket.clone();
    if (!$cast(ticket_snapshot, cloned_object))
      `uvm_error("TICKET_CLONE", "ticket clone has wrong type")

    cloned_object = completion.clone();
    if (!$cast(completion_snapshot, cloned_object))
      `uvm_error("COMPLETION_CLONE", "completion clone has wrong type")

    cloned_object = runtime_desc.clone();
    if (!$cast(runtime_snapshot, cloned_object))
      `uvm_error("RUNTIME_CLONE", "runtime descriptor clone has wrong type")

    if (command_snapshot != null) begin
      if (command_snapshot.function_h == command.function_h ||
          command_snapshot.opcode_key == command.opcode_key ||
          command_snapshot.body == command.body ||
          command_snapshot.qpc_signature_source ==
            command.qpc_signature_source)
        `uvm_error("COMMAND_DEEP_COPY",
                   "command nested objects alias the source")
      if (!$cast(body_snapshot, command_snapshot.body))
        `uvm_error("COMMAND_DEEP_COPY", "command body clone lost type")
    end
    if (slot_snapshot != null &&
        (slot_snapshot.function_h == slot.function_h ||
         slot_snapshot.cmq_h == slot.cmq_h))
      `uvm_error("SLOT_DEEP_COPY", "slot handles alias the source")
    if (decoded_snapshot != null) begin
      if (decoded_snapshot.command_status == decoded.command_status ||
          decoded_snapshot.response_payload == decoded.response_payload)
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded CQE nested objects alias the source")
      if (!$cast(response_payload_snapshot,
                 decoded_snapshot.response_payload))
        `uvm_error("DECODED_DEEP_COPY",
                   "decoded response payload clone lost type")
    end
    if (ticket_snapshot != null &&
        (ticket_snapshot.function_h == ticket.function_h ||
         ticket_snapshot.cmq_h == ticket.cmq_h ||
         ticket_snapshot.opcode_key == ticket.opcode_key))
      `uvm_error("TICKET_DEEP_COPY", "ticket nested objects alias source")
    if (completion_snapshot != null) begin
      if (completion_snapshot.ticket == completion.ticket ||
          completion_snapshot.status == completion.status ||
          completion_snapshot.raw_cqe == completion.raw_cqe ||
          completion_snapshot.decoded_response ==
            completion.decoded_response)
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion nested objects alias the source")
      if (!$cast(decoded_response_snapshot,
                 completion_snapshot.decoded_response))
        `uvm_error("COMPLETION_DEEP_COPY",
                   "completion decoded response clone lost type")
    end
    if (runtime_snapshot != null &&
        (runtime_snapshot.function_h == runtime_desc.function_h ||
         runtime_snapshot.cmq_h == runtime_desc.cmq_h))
      `uvm_error("RUNTIME_DEEP_COPY",
                 "runtime descriptor handles alias the source")

    // 修改所有源对象后，用手工 literal 证明已发布 snapshot 不受源图变化影响。
    function_h.generation++;
    cmq_h.object_id++;
    key.profile_name = "mutated_profile";
    key.variant = "mutated_variant";
    body.command_id++;
    command.qpc_signature_source.bytes[0] = 8'h00;
    decoded.command_status.message = "mutated decoded status";
    response_payload.transport_version++;
    completion.status.message = "mutated completion status";
    completion.raw_cqe.bytes[0] = 8'h00;
    decoded_response.transport_version++;

    if (key_snapshot == null ||
        key_snapshot.profile_name != "generic_profile" ||
        key_snapshot.variant != "query" ||
        key_snapshot.opcode != 32'hff00_abcd)
      `uvm_error("KEY_SNAPSHOT", "opcode key snapshot changed")
    if (command_snapshot == null ||
        command_snapshot.function_h.generation != TEST_GENERATION ||
        command_snapshot.opcode_key.profile_name != "generic_profile" ||
        command_snapshot.qpc_signature_source.bytes[0] != 8'h5a ||
        body_snapshot == null || body_snapshot.command_id != 64'h111 ||
        command_snapshot.vfid_override != 1'b1 ||
        command_snapshot.use_vfid != 11'h345 ||
        command_snapshot.timeout != 100)
      `uvm_error("COMMAND_SNAPSHOT", "command snapshot changed")
    if (slot_snapshot == null ||
        slot_snapshot.function_h.generation != TEST_GENERATION ||
        slot_snapshot.cmq_h.object_id != 32'h55 ||
        slot_snapshot.backing_addr.value != 64'h0000_0000_4000_0000 ||
        slot_snapshot.relative_offset != 320 ||
        slot_snapshot.slot_sequence != 37 || slot_snapshot.sq_index != 5 ||
        slot_snapshot.sq_wrap != 1'b1)
      `uvm_error("SLOT_SNAPSHOT", "slot snapshot changed")
    if (expected_snapshot == null ||
        expected_snapshot.hardware_opcode != 32'hff00_abcd ||
        expected_snapshot.variant != "query")
      `uvm_error("EXPECTED_SNAPSHOT",
                 "expected response snapshot changed")
    if (decoded_snapshot == null ||
        decoded_snapshot.command_status.message != "decoded success" ||
        response_payload_snapshot == null ||
        response_payload_snapshot.transport_version != 1 ||
        decoded_snapshot.hardware_opcode != 32'hff00_abcd ||
        decoded_snapshot.wqe_index != 5 ||
        decoded_snapshot.wqe_wrap != 1'b1 ||
        decoded_snapshot.hardware_ecode != 32'ha5)
      `uvm_error("DECODED_SNAPSHOT", "decoded CQE snapshot changed")
    if (ticket_snapshot == null ||
        ticket_snapshot.function_h.generation != TEST_GENERATION ||
        ticket_snapshot.cmq_h.object_id != 32'h55 ||
        ticket_snapshot.opcode_key.variant != "query" ||
        ticket_snapshot.command_id != 64'h1234_0005 ||
        ticket_snapshot.absolute_deadline != 1000)
      `uvm_error("TICKET_SNAPSHOT", "ticket snapshot changed")
    if (completion_snapshot == null ||
        completion_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        completion_snapshot.status.message != "hardware completion" ||
        completion_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        decoded_response_snapshot == null ||
        decoded_response_snapshot.transport_version != 2)
      `uvm_error("COMPLETION_SNAPSHOT", "completion snapshot changed")
    if (runtime_snapshot == null ||
        runtime_snapshot.function_h.generation != TEST_GENERATION ||
        runtime_snapshot.cmq_h.object_id != 32'h55 ||
        runtime_snapshot.sq_iova.value != 64'h0000_0001_2000_0000 ||
        runtime_snapshot.cq_iova.value != 64'h0000_0001_2000_0800 ||
        runtime_snapshot.sq_depth != 32 || runtime_snapshot.cq_depth != 32 ||
        runtime_snapshot.entry_bytes != 64 ||
        runtime_snapshot.initial_sq_valid != 1'b1 ||
        runtime_snapshot.initial_cq_owner != 1'b1 ||
        runtime_snapshot.initial_doorbell_polarity != 1'b0)
      `uvm_error("RUNTIME_SNAPSHOT", "runtime descriptor snapshot changed")

    phase.drop_objection(this);
  endtask
endclass
