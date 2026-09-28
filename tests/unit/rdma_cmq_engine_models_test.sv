// 目录：测试层 tests/unit/rdma_cmq_engine_models_test.sv。
// 职责：验证共享提交证据顺序、CMQ model validation/detached clone，
// 以及 package-level value、typed snapshot、body-value、journal-value、ordered
// recovery item tuple 与 reset-proof 只读值原语的直接行为契约；binding 比较通过
// nonfatal accessor 间接 direct-new 瞬态 status/identity，不将该路径描述为零分配纯函数。
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

// 设计说明：body contract 必须按 registry wrapper 拒绝可 cast 的 SQE subtype；
// 该 fixture 同时携带完整嵌套引用，以区分 exact-type gate 与宽松 cast 实现。
class rdma_cmq_body_sqe_subtype extends rdma_cmq_sqe_model;
  `uvm_object_utils(rdma_cmq_body_sqe_subtype)

  // 功能：构造 registered SQE subtype，供 shell/key/node 三条边界共用。
  // 输入/输出及副作用：name 传给 rdma_cmq_sqe_model；其余业务字段由调用测试填充。
  // 失败/边界：fixture 可 cast 为 SQE，但 wrapper 与基类不同，不得进入 exact body 分支。
  function new(string name = "rdma_cmq_body_sqe_subtype");
    super.new(name);
  endfunction
endclass

// 设计说明：QPC shell/key 要求 exact URC extension，graph append 却保留历史 `$cast`
// 语义；registered subtype 让两种规则在同一对象上可观测地区分。
class rdma_cmq_body_urc_ext_subtype extends rdma_qpc_urc_ext;
  `uvm_object_utils(rdma_cmq_body_urc_ext_subtype)

  // 功能：构造可 cast 但 wrapper 非 exact 的 URC transport extension fixture。
  // 输入/输出及副作用：name 传给 rdma_qpc_urc_ext；基类创建默认 queues，调用方可替换。
  // 失败/边界：shell/nested key 必须拒绝本类型，append 仍应读取其非空 queues。
  function new(string name = "rdma_cmq_body_urc_ext_subtype");
    super.new(name);
  endfunction
endclass

// 设计说明：URC shell 对 queues 使用 exact wrapper，而 graph append 只检查非空；
// 独立 queue subtype 防止 transport subtype 的先行拒绝掩盖该差异。
class rdma_cmq_body_urc_queue_subtype extends rdma_urc_queue_config;
  `uvm_object_utils(rdma_cmq_body_urc_queue_subtype)

  // 功能：构造 registered URC queue subtype，冻结 shell exact 与 append non-null 边界。
  // 输入/输出及副作用：name 传给 rdma_urc_queue_config；不创建外部 backing authority。
  // 失败/边界：可 cast 到 queue 基类不代表 shell 接受；append 不得因 subtype 丢弃引用。
  function new(string name = "rdma_cmq_body_urc_queue_subtype");
    super.new(name);
  endfunction
endclass

// 设计说明：journal owner comparator 必须先通过 exact frozen-owner shape；
// registered subtype 即使继承全部字段也不能获得 retained journal authority。
class rdma_cmq_journal_owner_subtype extends rdma_cmq_recovery_owner;
  `uvm_object_utils(rdma_cmq_journal_owner_subtype)

  // 功能：构造 wrapper 与基类不同的 recovery-owner fixture，覆盖 exact shape 拒绝。
  // 输入/输出及副作用：name 传给 rdma_cmq_recovery_owner；不冻结或登记真实资源。
  // 失败/边界：对象可 cast 到基类仍不应通过 journal owner 比较器的 shape gate。
  function new(string name = "rdma_cmq_journal_owner_subtype");
    super.new(name);
  endfunction
endclass

// 设计说明：DMA context comparator 历史上不做 outer exact-type gate；扩展字段
// 不属于 journal 公开投影，两个 subtype 的扩展值不同仍应按基类字段比较。
class rdma_cmq_journal_dma_context_subtype extends rdma_dma_request_context;
  `uvm_object_utils(rdma_cmq_journal_dma_context_subtype)

  int unsigned extension_value;

  // 功能：构造带独立扩展字段的 DMA context subtype fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，业务字段由测试填充。
  // 失败/边界：subtype 可被 comparator 接受，但扩展字段不得被误纳入既有公开值契约。
  function new(string name = "rdma_cmq_journal_dma_context_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：mapping comparator 只冻结既有 public projection 与三类外部引用；
// outer registered subtype 的私有扩展不属于 release authority 证明。
class rdma_cmq_journal_mapping_subtype extends rdma_dma_mapping;
  `uvm_object_utils(rdma_cmq_journal_mapping_subtype)

  int unsigned extension_value;

  // 功能：构造带未比较扩展字段的 DMA mapping subtype fixture。
  // 输入/输出及副作用：name 传给基类；扩展值清零，不分配 backing 或 release authority。
  // 失败/边界：fixture 只证明 outer subtype 被接受，不授予 opaque allocation 权限。
  function new(string name = "rdma_cmq_journal_mapping_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：command identity comparator 只读取七个既有基类字段；registered
// subtype 的扩展诊断值不改变 retained command identity。
class rdma_cmq_journal_command_identity_subtype extends
    rdma_cmq_command_identity;
  `uvm_object_utils(rdma_cmq_journal_command_identity_subtype)

  int unsigned extension_value;

  // 功能：构造可携带不同扩展值的 command identity subtype fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，其余字段由测试填充。
  // 失败/边界：扩展字段差异应被既有 comparator 忽略，基类前置拒绝仍然生效。
  function new(string name = "rdma_cmq_journal_command_identity_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：reset-proof comparator 历史上不做 outer exact-type gate；扩展字段不属于
// retained proof 的既有公开投影，两个 subtype 扩展值不同仍应按基类字段比较。
class rdma_cmq_journal_reset_proof_subtype extends
    rdma_cmq_reset_isolation_proof;
  `uvm_object_utils(rdma_cmq_journal_reset_proof_subtype)

  int unsigned extension_value;

  // 功能：构造带独立扩展字段的 reset-isolation-proof subtype fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，proof 字段由测试填充。
  // 失败/边界：subtype 可被 comparator 接受，但扩展字段不得进入既有 equality 契约。
  function new(string name = "rdma_cmq_journal_reset_proof_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：binding 只读比较要求 outer wrapper 精确为基类，随后才通过 nonfatal
// accessor 间接 direct-new 瞬态 status/identity；测试 builder 必须把该 subtype
// 填成有效等值图，避免 identity 失败掩盖 outer exact gate。
class rdma_cmq_journal_binding_subtype extends rdma_function_binding;
  `uvm_object_utils(rdma_cmq_journal_binding_subtype)

  int unsigned extension_value;

  // 功能：构造 wrapper 与基类不同的 Function binding 拒绝 fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，保留基类默认图。
  // 失败/边界：fixture 可 cast 为 binding，但 comparator 必须在读取无效 identity 前拒绝。
  function new(string name = "rdma_cmq_journal_binding_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：binding outer 保持 exact base 时，protected identity 仍由
// snapshot_identity_nonfatal() 单独拒绝 registered subtype。
class rdma_cmq_journal_binding_identity_subtype extends
    rdma_function_identity;
  `uvm_object_utils(rdma_cmq_journal_binding_identity_subtype)

  int unsigned extension_value;

  // 功能：构造带额外字段的 Function identity，供 binding 内层 exact gate 测试。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，identity 由 helper 后续配置。
  // 失败/边界：公开 identity 值可完全有效，但非基类 wrapper 仍不得发布 snapshot。
  function new(string name = "rdma_cmq_journal_binding_identity_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：PCIe 投影在既有 comparator 中没有 runtime exact-type gate；
// 该 fixture 冻结扩展字段不参与 retained journal 值比较的基线。
class rdma_cmq_journal_binding_pcie_subtype extends rdma_pcie_identity;
  `uvm_object_utils(rdma_cmq_journal_binding_pcie_subtype)

  int unsigned extension_value;

  // 功能：构造拥有六个固定 BAR 的 PCIe identity subtype fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，BAR 仍由基类构造并拥有。
  // 失败/边界：扩展字段不得改变 comparator 结果；公开 PCIe/BAR 值仍须完全一致。
  function new(string name = "rdma_cmq_journal_binding_pcie_subtype");
    super.new(name);
    extension_value = 0;
  endfunction
endclass

// 设计说明：BAR 元素是六槽固定数组中的值节点，原 comparator
// 只比较四个公开字段，不限制节点 runtime subtype。
class rdma_cmq_journal_binding_bar_subtype extends rdma_bar_info;
  `uvm_object_utils(rdma_cmq_journal_binding_bar_subtype)

  int unsigned extension_value;

  // 功能：构造带扩展字段的 BAR metadata 元素 fixture。
  // 输入/输出及副作用：name 传给基类；extension_value 清零，四个公开字段保持基类默认。
  // 失败/边界：只有公开 bar_id/base/size/enabled 参与比较，扩展值必须被忽略。
  function new(string name = "rdma_cmq_journal_binding_bar_subtype");
    super.new(name);
    extension_value = 0;
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

// 设计说明：Function snapshot 只冻结基类的四个 identity 字段；
// 该注册子类用可控 clone 结果证明 subtype/type-name、source 恢复与第三对象边界。
class rdma_cmq_snapshot_function_handle extends rdma_function_handle;
  `uvm_object_utils(rdma_cmq_snapshot_function_handle)

  rdma_cmq_snapshot_clone_mode_e clone_mode;
  int unsigned clone_calls;
  int unsigned extension_value;
  rdma_function_handle third_equal_value;

  // 功能：构造默认执行正常 clone 的 Function handle hostile fixture。
  // 输入/输出及副作用：name 传给基类；清零调用计数和扩展值，不安装 factory override。
  // 失败/边界：构造后 identity 仍是基类默认值；调用方必须显式填充有效 incarnation。
  function new(string name = "rdma_cmq_snapshot_function_handle");
    super.new(name);
    clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    clone_calls = 0;
    extension_value = 0;
    third_equal_value = null;
  endfunction

  // 功能：按 clone_mode 返回正常子类副本、null/self/错类型，或注入 source mutation/第三等值对象。
  // 输入/输出及副作用：无显式输入；每次递增 clone_calls，mutate 模式改写四个 identity 字段。
  // 失败/边界：third-equal 仅在 third_equal_value 非空时有效；其他故障故意违反 typed clone 契约。
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

// 设计说明：opcode helper 必须在 clone 前完成 validate；
// 该子类记录 clone 次数，使 validation priority 成为直接可观测契约。
class rdma_cmq_snapshot_opcode_key extends rdma_cmq_opcode_key;
  `uvm_object_utils(rdma_cmq_snapshot_opcode_key)

  rdma_cmq_snapshot_clone_mode_e clone_mode;
  int unsigned clone_calls;
  int unsigned extension_value;

  // 功能：构造未填充 opcode 文本、默认正常 clone 的注册子类 fixture。
  // 输入/输出及副作用：name 传给基类；清零 clone_calls/extension_value 并设置 GOOD 模式。
  // 失败/边界：默认 profile_name/variant 为空，因此调用方填充前 validate 必须失败。
  function new(string name = "rdma_cmq_snapshot_opcode_key");
    super.new(name);
    clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    clone_calls = 0;
    extension_value = 0;
  endfunction

  // 功能：按 clone_mode 产生 opcode 子类副本或注入 null/self/错类型/source mutation。
  // 输入/输出及副作用：无显式输入；递增 clone_calls，mutate 模式改写 profile/opcode/variant。
  // 失败/边界：本 clone 不主动调用 validate；非法文本时是否进入本函数由被测 helper 决定。
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
        profile_name = {profile_name, "_mutated"};
        opcode++;
        variant = {variant, "_mutated"};
        return super.clone();
      end
      default: return super.clone();
    endcase
  endfunction
endclass

// 设计说明：expected-response helper 只冻结 hardware opcode 与 variant；
// 该注册子类可返回第三对象并在返回前篡改 source，用于直接证明 mutation latch、
// caller 恢复与 clone-contract 错误优先级。
class rdma_cmq_snapshot_expected_response extends rdma_cmq_expected_response;
  `uvm_object_utils(rdma_cmq_snapshot_expected_response)

  rdma_cmq_snapshot_clone_mode_e clone_mode;
  int unsigned clone_calls;
  int unsigned extension_value;
  bit mutate_hardware_opcode;
  bit mutate_variant;
  // 非拥有 candidate；生命周期由当前测试调用方覆盖到 clone 窗口结束。
  rdma_cmq_expected_response clone_candidate;

  // 功能：构造默认执行正常 clone 的 expected-response hostile fixture。
  // 输入/输出及副作用：name 传给基类；初始化模式、计数、扩展值、两个 mutation mask
  // 及非拥有 candidate 引用，默认同时篡改两个公开字段。
  // 失败/边界：默认 variant 为空，调用方必须先填充有效值；构造不取得 candidate 所有权。
  function new(string name = "rdma_cmq_snapshot_expected_response");
    super.new(name);
    clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    clone_calls = 0;
    extension_value = 0;
    mutate_hardware_opcode = 1'b1;
    mutate_variant = 1'b1;
    clone_candidate = null;
  endfunction

  // 功能：按 clone_mode 返回正常 subtype clone、null/self/错类型/第三对象，
  // 或先篡改 expected source 再返回指定 candidate。
  // 输入/输出及副作用：无显式输入；递增 clone_calls；MUTATE 同时改写
  // mutation mask 选择性改写 hardware_opcode/variant，并读取非拥有 clone_candidate。
  // 失败/边界：THIRD_EQUAL 的 candidate 可为 null；MUTATE 未提供 candidate 时回退
  // 到 super.clone()，所有故障对象仅由测试窗口持有且不转移所有权。
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
        if (mutate_hardware_opcode)
          hardware_opcode ^= 32'hffff_ffff;
        if (mutate_variant)
          variant = {variant, "_mutated"};
        if (clone_candidate != null)
          return clone_candidate;
        return super.clone();
      end
      RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL: return clone_candidate;
      default: return super.clone();
    endcase
  endfunction
endclass

// 设计说明：image primitive 要在 hostile clone 后恢复所有公开字段和 queue；
// 该子类一次改写整个投影，并可暴露 canonical 路径消费的第三 factory candidate。
class rdma_cmq_snapshot_image extends rdma_hw_image;
  `uvm_object_utils(rdma_cmq_snapshot_image)

  rdma_cmq_snapshot_clone_mode_e clone_mode;
  int unsigned clone_calls;
  int unsigned extension_value;
  rdma_hw_image third_equal_value;

  // 功能：构造默认正常 clone 的 image subtype fixture。
  // 输入/输出及副作用：name 传给 rdma_hw_image；初始化模式、计数、扩展值与 candidate 引用。
  // 失败/边界：默认 image metadata/queue 仍是非 canonical 空值；调用方负责填充。
  function new(string name = "rdma_cmq_snapshot_image");
    super.new(name);
    clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    clone_calls = 0;
    extension_value = 0;
    third_equal_value = null;
  endfunction

  // 功能：按 clone_mode 生成 image clone，mutate 模式改写 bytes、metadata、targets 和 summary 全投影。
  // 输入/输出及副作用：无显式输入；递增 clone_calls，可修改 source 或返回预置第三对象。
  // 失败/边界：mutate 要求 bytes/field_summary 非空；本测试 fixture 在进入该模式前保证此前提。
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
        bytes[0] ^= 8'hff;
        length++;
        alignment++;
        if (endian == RDMA_ENDIAN_BIG)
          endian = RDMA_ENDIAN_LITTLE;
        else
          endian = RDMA_ENDIAN_BIG;
        image_kind = RDMA_IMAGE_CMQ_CQE;
        hardware_version++;
        function_generation++;
        write_target_kind = RDMA_HW_TARGET_BAR;
        backing_target.value++;
        hmc_target.value++;
        bar_target.value++;
        field_summary[0] = {field_summary[0], "_mutated"};
        return super.clone();
      end
      RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL: return third_equal_value;
      default: return super.clone();
    endcase
  endfunction
endclass

// 设计说明：UVM registry::create() 对 class-handle null 的 $cast 成功并返回 null，
// 只有不兼容动态类型会发布 FCTTYP fatal；本 catcher 使两个
// saved-value 窗口可分别断言零/一次 fatal。
class rdma_cmq_snapshot_factory_fatal_catcher extends uvm_report_catcher;
  int unsigned caught_count;

  // 功能：构造尚未捕获 FCTTYP 的 typed-snapshot factory catcher。
  // 输入/输出及副作用：name 传给基类；caught_count 清零，不自动注册 callback。
  // 失败/边界：调用方必须在窗口前后显式 add/delete，防止吞掉非目标 fatal。
  function new(string name = "rdma_cmq_snapshot_factory_fatal_catcher");
    super.new(name);
    caught_count = 0;
  endfunction

  // 功能：精确捕获 severity=UVM_FATAL 且 ID=FCTTYP 的 registry 类型错误。
  // 输入/输出及副作用：读取当前 report；命中时递增 caught_count 并返回 CAUGHT。
  // 失败/边界：任何非 FCTTYP 或非 fatal report 均 THROW，不降级真实产品错误。
  virtual function action_e catch();
    if (get_severity() == UVM_FATAL && get_id() == "FCTTYP") begin
      caught_count++;
      return CAUGHT;
    end
    return THROW;
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

  // 功能：同时校验 typed snapshot 拒绝路径的精确 status code 与 message。
  // 输入/输出及副作用：check_name/status/expected_code/expected_message 为只读输入；偏差时发布 UVM error。
  // 失败/边界：status 为 null 时只报告一次并返回；本 helper 不修改或重建被比较 status。
  function automatic void expect_snapshot_failure(
    input string check_name,
    input rdma_status status,
    input rdma_status_code_e expected_code,
    input string expected_message
  );
    if (status == null) begin
      `uvm_error(check_name, "snapshot helper returned a null status")
      return;
    end
    if (status.code != expected_code || status.message != expected_message)
      `uvm_error(
        check_name,
        $sformatf("expected %s/'%s', got %s/'%s'",
                  expected_code.name(), expected_message,
                  status.code.name(), status.message)
      )
  endfunction

  // 功能：填充 typed Function fixture 的固定 kind/UID/object/generation 投影。
  // 输入/输出及副作用：value 为待改写句柄，object_id 选择测试身份；函数更新四个公开字段。
  // 失败/边界：value 必须非 null；本 fixture helper 不注册真实 Function 或校验 object_id 范围。
  function automatic void fill_snapshot_function(
    input rdma_function_handle value,
    input int unsigned object_id
  );
    value.kind = RDMA_RESOURCE_FUNCTION;
    value.function_uid = TEST_FUNCTION_UID;
    value.object_id = object_id;
    value.generation = TEST_GENERATION;
  endfunction

  // 功能：填充 typed generic-handle fixture 的资源类型与 incarnation 投影。
  // 输入/输出及副作用：value/kind/object_id 为输入；改写 value 的四个公开 identity 字段。
  // 失败/边界：value 为 null 时不可调用；本 helper 故意不限制 kind 与 object_id 的业务合法性。
  function automatic void fill_snapshot_handle(
    input rdma_handle value,
    input rdma_resource_kind_e kind,
    input int unsigned object_id
  );
    value.kind = kind;
    value.function_uid = TEST_FUNCTION_UID;
    value.object_id = object_id;
    value.generation = TEST_GENERATION;
  endfunction

  // 功能：填充可通过 validate() 的固定 profile/opcode/variant fixture。
  // 输入/输出及副作用：value 为待改写 opcode key；写入 generic_profile、固定 opcode 和 query variant。
  // 失败/边界：value 必须非 null；本 helper 不触发 profile registry 查找，只满足 key 自身 shape。
  function automatic void fill_snapshot_opcode(
    input rdma_cmq_opcode_key value
  );
    value.profile_name = "generic_profile";
    value.opcode = 32'hff00_abcd;
    value.variant = "query";
  endfunction

  // 功能：填充可通过 validate() 的固定 expected-response opcode/variant 投影。
  // 输入/输出及副作用：value 为待改写对象；写入固定 hardware_opcode 和 query variant。
  // 失败/边界：value 必须非 null；该 helper 不绑定 profile 或 payload 类型。
  function automatic void fill_snapshot_expected(
    input rdma_cmq_expected_response value
  );
    value.hardware_opcode = 32'h00cd_1234;
    value.variant = "query";
  endfunction

  // 功能：填充覆盖 bytes、metadata、三种 target 与 summary 的完整 image fixture。
  // 输入/输出及副作用：value 为待改写 image；重建两个 queue 并写入所有公开标量字段。
  // 失败/边界：value 必须非 null；三种 target 同时填值用于恢复比较，不表示同时授予三种写权。
  function automatic void fill_snapshot_image(input rdma_hw_image value);
    value.bytes = '{8'h11, 8'h22, 8'h33, 8'h44};
    value.length = 4;
    value.alignment = 64;
    value.endian = RDMA_ENDIAN_BIG;
    value.image_kind = RDMA_IMAGE_CMQ_SQE;
    value.hardware_version = 3;
    value.function_generation = TEST_GENERATION;
    value.write_target_kind = RDMA_HW_TARGET_BACKING;
    value.backing_target.value = 64'h1000;
    value.hmc_target.value = 64'h2000;
    value.bar_target.value = 64'h3000;
    value.field_summary = '{"opcode", "owner", "signature"};
  endfunction

  // 功能：校验一个 CMQ 只读值 helper 的 bit 结果，并用独立 check_name 标识 mutation 分支。
  // 输入/输出及副作用：check_name、actual 和 expected 为输入；不匹配时发布 UVM error，不修改被比较 fixture。
  // 失败/边界：actual 与 expected 完全相等时无输出；本 helper 只报告结果，不改写或重试被测契约。
  function automatic void expect_value_contract(
    input string check_name,
    input bit actual,
    input bit expected
  );
    if (actual !== expected)
      `uvm_error(check_name,
                 $sformatf("expected %0b, got %0b", expected, actual))
  endfunction

  // 功能：同时核对 retained-instance 与 detached 两条 journal owner 比较结果。
  // 输入/输出及副作用：label、lhs/rhs、expected 为只读输入；仅在偏差时发布
  // UVM error，不冻结、复制或改写 owner 图。
  // 失败/边界：两条路径任一结果漂移都会使用独立后缀报告；null/非法 shape
  // 由被测 helper 返回 0，本检查不替其补做 validation。
  function automatic void expect_journal_owner_contract(
    input string label,
    input rdma_cmq_recovery_owner lhs,
    input rdma_cmq_recovery_owner rhs,
    input bit expected
  );
    expect_value_contract(
      {label, "_INSTANCE"},
      rdma_cmq_same_journal_owner_value(lhs, rhs), expected
    );
    expect_value_contract(
      {label, "_DETACHED"},
      rdma_cmq_same_journal_owner_detached_value(lhs, rhs), expected
    );
  endfunction

  // 功能：同时核对 instance-handle 与 detached-handle 两条 journal DMA context 比较结果。
  // 输入/输出及副作用：label、lhs/rhs、expected 为只读输入；只报告结果，不执行
  // DMA、不复制 context，也不改写嵌套 handle。
  // 失败/边界：null、Function 缺失或 optional owner shape 不一致由被测 helper
  // fail-closed；本检查分别标识两条路径。
  function automatic void expect_journal_dma_context_contract(
    input string label,
    input rdma_dma_request_context lhs,
    input rdma_dma_request_context rhs,
    input bit expected
  );
    expect_value_contract(
      {label, "_INSTANCE"},
      rdma_cmq_same_journal_dma_context_value(lhs, rhs), expected
    );
    expect_value_contract(
      {label, "_DETACHED"},
      rdma_cmq_same_journal_dma_context_detached_value(lhs, rhs), expected
    );
  endfunction

  // 功能：核对 package-level journal binding 只读比较器的单次布尔结果。
  // 输入/输出及副作用：label、lhs/rhs 和 expected 为只读输入；被测 helper 通过
  // nonfatal accessor 间接 direct-new 瞬态 status/identity，但不修改输入值图。
  // 失败/边界：null、subtype、invalid identity 及字段漂移由被测 helper fail closed；
  // 本检查不补做 validate、digest 或 alias 断言。
  function automatic void expect_journal_binding_contract(
    input string label,
    input rdma_function_binding lhs,
    input rdma_function_binding rhs,
    input bit expected
  );
    expect_value_contract(
      label, rdma_cmq_same_journal_binding_value(lhs, rhs), expected
    );
  endfunction

  // 功能：检查 ordered recovery item tuple 的 package 谓词，并在每次比较后逐项
  // 核对 request/record 的 queue 引用、tuple 列和独立外层/非 tuple 哨兵没有被改写。
  // 输入/输出及副作用：label、request、journal_record、expected 为只读输入；只在
  // predicate 结果或输入图发生变化时发布 UVM error，不复制或写入生产图。
  // 失败/边界：任一 outer/item 为 null 时只检查可达节点；queue cardinality 变化
  // 先报告再停止索引，以免越界掩盖 comparator 的第一处错误。
  function automatic void expect_journal_ordered_tuple_contract(
    input string label,
    input rdma_cmq_submission_recovery_request request,
    input rdma_cmq_batch_submission_record journal_record,
    input bit expected
  );
    rdma_cmq_submission_recovery_item request_refs[$];
    rdma_cmq_batch_submission_item_record record_refs[$];
    int unsigned request_indices[$];
    int unsigned record_indices[$];
    rdma_cmq_journal_digest_t request_images[$];
    rdma_cmq_journal_digest_t record_images[$];
    rdma_cmq_journal_digest_t request_authorities[$];
    rdma_cmq_journal_digest_t record_authorities[$];
    longint unsigned request_offsets[$];
    longint unsigned record_offsets[$];
    string request_batch_key;
    string record_batch_key;
    longint unsigned request_batch_id;
    longint unsigned record_batch_id;
    bit actual;

    if (request != null) begin
      request_refs = request.items;
      request_batch_key = request.batch_key;
      request_batch_id = request.batch_id;
      foreach (request.items[i]) begin
        request_indices.push_back(
          request.items[i] == null ? '0 : request.items[i].request_index
        );
        request_images.push_back(
          request.items[i] == null ? '0 : request.items[i].image_digest
        );
        request_authorities.push_back(
          request.items[i] == null ? '0 : request.items[i].authority_digest
        );
        request_offsets.push_back(
          request.items[i] == null ? '0 : request.items[i].dependency_offset
        );
      end
    end
    if (journal_record != null) begin
      record_refs = journal_record.items;
      record_batch_key = journal_record.batch_key;
      record_batch_id = journal_record.batch_id;
      foreach (journal_record.items[i]) begin
        record_indices.push_back(
          journal_record.items[i] == null ? '0 :
            journal_record.items[i].request_index
        );
        record_images.push_back(
          journal_record.items[i] == null ? '0 :
            journal_record.items[i].image_digest
        );
        record_authorities.push_back(
          journal_record.items[i] == null ? '0 :
            journal_record.items[i].authority_digest
        );
        record_offsets.push_back(
          journal_record.items[i] == null ? '0 :
            journal_record.items[i].dependency_offset
        );
      end
    end

    actual = rdma_cmq_recovery_batch_ordered_item_tuple_matches(
      request, journal_record
    );
    expect_value_contract(label, actual, expected);

    if (request != null) begin
      if (request.items.size() != request_refs.size() ||
          request.batch_key != request_batch_key ||
          request.batch_id != request_batch_id)
        `uvm_error({label, "_REQUEST_MUTATED"},
                   "request outer fields or item count changed")
      else begin
        foreach (request_refs[i]) begin
          if (request.items[i] != request_refs[i] ||
              (request.items[i] != null &&
               (request.items[i].request_index != request_indices[i] ||
                request.items[i].image_digest !== request_images[i] ||
                request.items[i].authority_digest !==
                  request_authorities[i] ||
                request.items[i].dependency_offset != request_offsets[i])))
            `uvm_error({label, "_REQUEST_MUTATED"},
                       $sformatf("request item %0d changed", i))
        end
      end
    end
    if (journal_record != null) begin
      if (journal_record.items.size() != record_refs.size() ||
          journal_record.batch_key != record_batch_key ||
          journal_record.batch_id != record_batch_id)
        `uvm_error({label, "_RECORD_MUTATED"},
                   "journal outer fields or item count changed")
      else begin
        foreach (record_refs[i]) begin
          if (journal_record.items[i] != record_refs[i] ||
              (journal_record.items[i] != null &&
               (journal_record.items[i].request_index != record_indices[i] ||
                journal_record.items[i].image_digest !== record_images[i] ||
                journal_record.items[i].authority_digest !==
                  record_authorities[i] ||
                journal_record.items[i].dependency_offset !=
                  record_offsets[i])))
            `uvm_error({label, "_RECORD_MUTATED"},
                       $sformatf("journal item %0d changed", i))
        end
      end
    end
  endfunction

  // 功能：按队列长度与每个对象句柄的原顺序核对 body graph node 输出。
  // 输入/输出及副作用：check_name、actual、expected 为只读输入；不匹配时发布
  // UVM error，不修改队列内容或其中对象。
  // 失败/边界：长度不等时只报告 cardinality 并停止索引比较；相同值但不同句柄
  // 仍视为失败，用于冻结 append helper 的 alias/order 契约。
  function automatic void expect_body_node_contract(
    input string check_name,
    input uvm_object actual[$],
    input uvm_object expected[$]
  );
    if (actual.size() != expected.size()) begin
      `uvm_error(check_name,
                 $sformatf("expected %0d nodes, got %0d",
                           expected.size(), actual.size()))
      return;
    end
    foreach (expected[i]) begin
      if (actual[i] != expected[i])
        `uvm_error(check_name,
                   $sformatf("node %0d changed identity or order", i))
    end
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

  // 功能：创建一份公开 incarnation 完全有效、但 registry wrapper 非基类的 identity fixture。
  // 输入/输出及副作用：name 用于 subtype 及临时 reference 命名；返回测试拥有的新 subtype，
  // 不与其他 binding 共享 identity 节点。
  // 失败/边界：fixed route 配置失败时发布 BINDING_IDENTITY_SUBTYPE_FIXTURE；
  // 返回对象仍保留失败值，以便 direct comparator 暴露 fixture 错误。
  function automatic rdma_cmq_journal_binding_identity_subtype
  make_journal_binding_identity_subtype(input string name);
    rdma_function_identity reference;
    rdma_cmq_journal_binding_identity_subtype identity;
    rdma_status status;

    reference = make_identity({name, "_reference"});
    identity = new(name);
    identity.extension_value = 32'hcafe_0001;
    status = identity.configure(
      reference.key, reference.global_function_id, reference.function_uid,
      reference.generation, reference.reset_epoch
    );
    if (status == null || !status.ok())
      `uvm_error(
        "BINDING_IDENTITY_SUBTYPE_FIXTURE",
        "failed to configure identity subtype fixture"
      )
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

  // 功能：创建并冻结一个 exact recovery owner，供 journal comparator 直接契约使用。
  // 输入/输出及副作用：name/workflow/kind/action/identity/attempt 为输入；返回新
  // owner，freeze_for_journal 会在 owner 内保存 detached Function provenance。
  // 失败/边界：workflow/kind/action/identity/attempt 非法时报告 fixture UVM error；
  // helper 不修复失败对象，也不安装 journal 记录。
  function automatic rdma_cmq_recovery_owner make_frozen_owner(
    input string name,
    input rdma_cmq_recovery_workflow_e workflow,
    input rdma_resource_kind_e kind,
    input rdma_cmq_submission_recovery_action_e action,
    input rdma_function_identity identity,
    input longint unsigned attempt_id
  );
    rdma_cmq_recovery_owner owner;
    rdma_status status;

    owner = make_owner(name, workflow, kind, action);
    status = owner.freeze_for_journal(identity, attempt_id);
    if (status == null || !status.ok())
      `uvm_error("JOURNAL_OWNER_FIXTURE",
                 {"failed to freeze journal owner ", name})
    return owner;
  endfunction

  // 功能：填充一个完整且不对称的 reset-isolation proof comparator fixture，包含
  // 两项 ordered tuple、isolated/replacement identity 与两个 exact frozen owner。
  // 输入/输出及副作用：proof 为待改写对象，name_prefix 仅区分局部对象名；重建
  // proof 的全部公开标量、identity 引用和四个 queue，不登记 journal 或 reset 状态。
  // 失败/边界：proof 为 null 时报告 fixture error 并返回；freeze 失败由
  // make_frozen_owner 报告，本 helper 不计算或验证 digest。
  function automatic void fill_reset_proof_comparator_fixture(
    input rdma_cmq_reset_isolation_proof proof,
    input string name_prefix
  );
    rdma_function_identity isolated_identity;
    rdma_function_identity replacement_identity;
    rdma_cmq_recovery_owner first_owner;
    rdma_cmq_recovery_owner second_owner;

    if (proof == null) begin
      `uvm_error("RESET_PROOF_COMPARATOR_FIXTURE", "proof is null")
      return;
    end

    isolated_identity = make_identity({name_prefix, "_isolated_identity"});
    replacement_identity = make_identity(
      {name_prefix, "_replacement_identity"}
    );
    replacement_identity.reset_epoch++;
    first_owner = make_frozen_owner(
      {name_prefix, "_owner_mr"}, RDMA_CMQ_WORKFLOW_MR,
      RDMA_RESOURCE_MR, RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
      isolated_identity, 64'h303
    );
    second_owner = make_frozen_owner(
      {name_prefix, "_owner_qp"}, RDMA_CMQ_WORKFLOW_QP,
      RDMA_RESOURCE_QP, RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION,
      isolated_identity, 64'h303
    );

    proof.proof_key = "proof-key";
    proof.proof_id = 64'h101;
    proof.batch_key = "batch-key";
    proof.batch_id = 64'h202;
    proof.attempt_id = 64'h303;
    proof.engine_instance_id = 64'h404;
    proof.engine_incarnation = 64'h505;
    proof.isolated_identity = isolated_identity;
    proof.replacement_identity = replacement_identity;
    proof.batch_digest = 256'h0123_4567_89ab_cdef;
    proof.isolated_request_indices = '{32'd1, 32'd7};
    proof.isolated_image_digests = '{256'h1122, 256'h3344};
    proof.isolated_authority_digests = '{256'h5566, 256'h7788};
    proof.isolated_recovery_owners = '{first_owner, second_owner};
    proof.proof_digest =
      256'h566d7583_584213fe_f287c531_6b843754_45071d95_8af83cc3_7f13b868_cf7f9724;
    proof.state = RDMA_CMQ_RESET_PROOF_READY;
    proof.backing_release_confirmed = 1'b1;
  endfunction

  // 功能：创建完整 DMA request context，覆盖 Function、route、epoch、owner 与 queue role。
  // 输入/输出及副作用：name、identity 为输入；返回新 context，嵌套 handle 由 fixture 持有。
  // 失败/边界：identity 必须是有效 TEST incarnation；helper 不连接真实 IOMMU。
  function automatic rdma_dma_request_context make_dma_context(
    string name,
    rdma_function_identity identity
  );
    rdma_dma_request_context dma_context;

    dma_context = rdma_dma_request_context::type_id::create(name);
    dma_context.function_h = make_function({name, "_function"});
    dma_context.requester_bdf = identity.key.bdf;
    dma_context.pasid_valid = 1'b1;
    dma_context.pasid = 20'habcde;
    dma_context.dma_domain_valid = 1'b1;
    dma_context.dma_domain_id = 32'h1234_5678;
    dma_context.route = identity.route_key();
    dma_context.reset_epoch = identity.reset_epoch;
    dma_context.route_valid = 1'b1;
    dma_context.epoch_valid = 1'b1;
    dma_context.owner_h = make_resource_handle(
      {name, "_owner"}, RDMA_RESOURCE_MR, 32'h99
    );
    dma_context.queue_role_valid = 1'b1;
    dma_context.queue_role = 32'ha5a5_5a5a;
    return dma_context;
  endfunction

  // 功能：创建完整 public DMA mapping，供 authority digest 的 V1 字段覆盖。
  // 输入/输出及副作用：name、identity 为输入；返回 ACTIVE mapping，不分配真实 backing。
  // 失败/边界：opaque allocation authority 不由此 helper 伪造，base mapping 不能授权释放。
  function automatic rdma_dma_mapping make_mapping(
    string name,
    rdma_function_identity identity
  );
    rdma_dma_mapping mapping;

    mapping = rdma_dma_mapping::type_id::create(name);
    mapping.function_h = make_function({name, "_function"});
    mapping.requester_bdf = identity.key.bdf;
    mapping.pasid_valid = 1'b1;
    mapping.pasid = 20'habcde;
    mapping.dma_domain_valid = 1'b1;
    mapping.dma_domain_id = 32'h1234_5678;
    mapping.route = identity.route_key();
    mapping.reset_epoch = identity.reset_epoch;
    mapping.route_valid = 1'b1;
    mapping.epoch_valid = 1'b1;
    mapping.backing_addr.value = 64'h0000_0000_9000_0000;
    mapping.iova.value = 64'h0000_0001_9000_0000;
    mapping.size = 64'h2000;
    mapping.direction = RDMA_DMA_DEVICE_READ;
    mapping.permissions = '{
      device_read:1'b1,
      device_write:1'b0,
      atomic:1'b0
    };
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h = make_resource_handle(
      {name, "_owner"}, RDMA_RESOURCE_MR, 32'h99
    );
    mapping.umem_backed = 1'b1;
    mapping.umem_page_count = 2;
    return mapping;
  endfunction

  // 功能：创建通过 journal comparator 前置形状的不可变 command identity fixture。
  // 输入/输出及副作用：name 用作对象名；返回新 identity 并填充全部比较字段，
  // 不保留 command/body/handle 引用。
  // 失败/边界：helper 不调用 capture_from 或 validate；后续测试可独立注入零值、
  // 空文本和字段漂移。
  function automatic rdma_cmq_command_identity make_command_identity(
    input string name
  );
    rdma_cmq_command_identity identity;

    identity = rdma_cmq_command_identity::type_id::create(name);
    identity.function_kind = RDMA_RESOURCE_FUNCTION;
    identity.function_uid = TEST_FUNCTION_UID;
    identity.global_function_id = 32'h1234;
    identity.generation = TEST_GENERATION;
    identity.profile_name = "generic_profile";
    identity.opcode = 32'hff00_abcd;
    identity.variant = "query";
    return identity;
  endfunction

  // 功能：创建通过完整 binding.validate() 的六 BAR、DMA、能力和双中断向量 fixture。
  // 输入/输出及副作用：name、identity 为输入；返回新 binding，拥有其 identity/PCIe 快照。
  // 失败/边界：configure 或 validate 失败会报告 fixture 错误；不配置真实 PCIe 设备。
  function automatic rdma_function_binding make_binding(
    string name,
    rdma_function_identity identity
  );
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;
    rdma_status status;

    binding = rdma_function_binding::type_id::create(name);
    status = binding.configure_identity(identity);
    if (status == null || !status.ok())
      `uvm_error("BINDING_FIXTURE", "failed to configure binding identity")

    binding.pcie.mse = 1'b1;
    binding.pcie.bme = 1'b1;
    foreach (binding.pcie.bar[i]) begin
      binding.pcie.bar[i].bar_id = i;
      binding.pcie.bar[i].base.value = 64'h8000_0000 + (i * 64'h10000);
      binding.pcie.bar[i].size = 64'h10000;
      binding.pcie.bar[i].enabled = 1'b1;
    end

    binding.notify_bar_id = 3'd0;
    binding.notify_base.value = 64'h8000_2000;
    binding.notify_size = 64'h2000;
    binding.notify_table_sel = 32'h0102_0304;
    binding.notify_table_index = 32'h0506_0708;
    binding.host_id = 32'h1112_1314;
    binding.pfvf_id = 32'h1516_1718;
    binding.rdma_vf_id = 32'h22;
    binding.vsi_id = 32'h2324_2526;
    binding.queue_dma.requester_bdf = identity.key.bdf;
    binding.queue_dma.pasid_valid = 1'b1;
    binding.queue_dma.pasid = 20'habcde;
    binding.queue_dma.dma_domain_valid = 1'b1;
    binding.queue_dma.dma_domain_id = 32'h1234_5678;
    binding.queue_caps.min_cq_depth = 16;
    binding.queue_caps.max_cq_depth = 32768;
    binding.queue_caps.min_srq_depth = 16;
    binding.queue_caps.max_srq_depth = 32768;
    binding.queue_caps.max_ceq_depth = 4096;
    binding.queue_caps.max_aeq_depth = 4096;
    binding.queue_caps.max_wq_sge = 8;
    binding.queue_caps.max_queue_ring_bytes = 64'h0020_0000;
    binding.queue_caps.max_sgb_bytes = 64'h0040_0000;
    vector = '{
      function_local_vector:32'd3,
      hardware_eq_vector:32'd17,
      msix_table_index:32'd5,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    vector = '{
      function_local_vector:32'd4,
      hardware_eq_vector:32'd18,
      msix_table_index:32'd6,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    binding.state = RDMA_BIND_ACTIVE;
    binding.owner_h = make_function({name, "_owner"});
    binding.notify_valid = 1'b1;
    binding.notify_ready = 1'b1;
    binding.dmi_valid = 1'b1;
    binding.dmi_ready = 1'b1;
    binding.vft_valid = 1'b1;
    binding.vft_ready = 1'b1;

    status = binding.validate();
    if (status == null || !status.ok())
      `uvm_error("BINDING_FIXTURE", "constructed binding is invalid")
    return binding;
  endfunction

  // 功能：建立两项有序且左右 item 对象完全独立的 recovery request/journal fixture。
  // 输入/输出及副作用：name 命名四个 item 与两份 outer；request、journal_record
  // 输出分别拥有自己的 queue 和对象，填入相同 index/image/authority 与非 tuple 哨兵。
  // 失败/边界：fixture 不构造 command/handle 或真实 journal authority；若左右
  // outer/item 出现对象别名则发布 ORDERED_TUPLE_FIXTURE_ALIAS，避免假阳性。
  function automatic void make_journal_ordered_tuple_fixture(
    input string name,
    output rdma_cmq_submission_recovery_request request,
    output rdma_cmq_batch_submission_record journal_record
  );
    rdma_cmq_submission_recovery_item request_item;
    rdma_cmq_batch_submission_item_record record_item;

    request = new({name, "_request"});
    journal_record = new({name, "_journal"});
    request.batch_key = {name, "_request_key"};
    journal_record.batch_key = {name, "_journal_key"};
    request.batch_id = 64'h101;
    journal_record.batch_id = 64'h202;
    for (int i = 0; i < 2; i++) begin
      request_item = new($sformatf("%s_request_item_%0d", name, i));
      record_item = new($sformatf("%s_record_item_%0d", name, i));
      request_item.request_index = 32'(i + 7);
      record_item.request_index = request_item.request_index;
      request_item.image_digest = 256'h1100 + i;
      record_item.image_digest = request_item.image_digest;
      request_item.authority_digest = 256'h2200 + i;
      record_item.authority_digest = request_item.authority_digest;
      request_item.dependency_offset = 64'h3300 + i;
      record_item.dependency_offset = 64'h4400 + i;
      request.items.push_back(request_item);
      journal_record.items.push_back(record_item);
    end
    if (request.items.size() != 2 || journal_record.items.size() != 2 ||
        request.items[0] == request.items[1] ||
        journal_record.items[0] == journal_record.items[1])
      `uvm_error("ORDERED_TUPLE_FIXTURE_ALIAS",
                 "request and journal item fixtures must be independent")
  endfunction

  // 功能：从有效 base binding 逐字段构造公开值完全相同的 registered outer subtype。
  // 输入/输出及副作用：name/source/extension_value 为只读输入；返回拥有独立
  // identity、PCIe/BAR 与 Function owner 图的 subtype，不保存 source 中的对象引用。
  // 失败/边界：source 图不完整、identity snapshot/configure、最终 validate 或
  // detached 完整快照失败时报告 BINDING_OUTER_SUBTYPE_FIXTURE 并返回 null。
  function automatic rdma_cmq_journal_binding_subtype
  make_journal_binding_outer_subtype(
    input string name,
    input rdma_function_binding source,
    input int unsigned extension_value
  );
    rdma_cmq_journal_binding_subtype result;
    rdma_function_binding detached_check;
    rdma_function_identity identity_snapshot;
    rdma_function_handle owner_snapshot;
    rdma_status status;

    if (source == null || source.pcie == null || source.owner_h == null ||
        source.owner_h.get_object_type() !=
          rdma_function_handle::get_type()) begin
      `uvm_error(
        "BINDING_OUTER_SUBTYPE_FIXTURE",
        "source binding graph or exact Function owner is unavailable"
      )
      return null;
    end
    foreach (source.pcie.bar[i]) begin
      if (source.pcie.bar[i] == null) begin
        `uvm_error(
          "BINDING_OUTER_SUBTYPE_FIXTURE",
          "source binding contains a null fixed BAR"
        )
        return null;
      end
    end

    status = source.snapshot_identity_nonfatal(identity_snapshot);
    if (status == null || !status.ok() || identity_snapshot == null) begin
      `uvm_error(
        "BINDING_OUTER_SUBTYPE_FIXTURE",
        "source binding identity snapshot failed"
      )
      return null;
    end

    result = new(name);
    status = result.configure_identity(identity_snapshot);
    if (status == null || !status.ok()) begin
      `uvm_error(
        "BINDING_OUTER_SUBTYPE_FIXTURE",
        "outer subtype identity configuration failed"
      )
      return null;
    end

    result.function_uid = source.function_uid;
    result.pcie.bdf = source.pcie.bdf;
    result.pcie.parent_pf_bdf = source.pcie.parent_pf_bdf;
    result.pcie.vf_index = source.pcie.vf_index;
    result.pcie.mse = source.pcie.mse;
    result.pcie.bme = source.pcie.bme;
    foreach (result.pcie.bar[i]) begin
      result.pcie.bar[i].bar_id = source.pcie.bar[i].bar_id;
      result.pcie.bar[i].base = source.pcie.bar[i].base;
      result.pcie.bar[i].size = source.pcie.bar[i].size;
      result.pcie.bar[i].enabled = source.pcie.bar[i].enabled;
    end
    result.notify_bar_id = source.notify_bar_id;
    result.notify_base = source.notify_base;
    result.notify_size = source.notify_size;
    result.notify_table_sel = source.notify_table_sel;
    result.notify_table_index = source.notify_table_index;
    result.host_id = source.host_id;
    result.pfvf_id = source.pfvf_id;
    result.rdma_vf_id = source.rdma_vf_id;
    result.global_function_id = source.global_function_id;
    result.vsi_id = source.vsi_id;
    result.queue_dma = source.queue_dma;
    result.queue_caps = source.queue_caps;
    result.interrupt_vectors = source.interrupt_vectors;
    result.state = source.state;
    result.generation = source.generation;
    owner_snapshot = new({name, "_owner"});
    owner_snapshot.kind = source.owner_h.kind;
    owner_snapshot.function_uid = source.owner_h.function_uid;
    owner_snapshot.object_id = source.owner_h.object_id;
    owner_snapshot.generation = source.owner_h.generation;
    result.owner_h = owner_snapshot;
    result.notify_valid = source.notify_valid;
    result.notify_ready = source.notify_ready;
    result.dmi_valid = source.dmi_valid;
    result.dmi_ready = source.dmi_ready;
    result.vft_valid = source.vft_valid;
    result.vft_ready = source.vft_ready;
    result.extension_value = extension_value;

    status = result.validate();
    if (status == null || !status.ok()) begin
      `uvm_error(
        "BINDING_OUTER_SUBTYPE_FIXTURE",
        "constructed outer subtype is not a valid binding"
      )
      return null;
    end
    status = result.snapshot_complete_nonfatal(detached_check);
    if (status == null || !status.ok() || detached_check == null ||
        result.pcie == source.pcie || result.owner_h == source.owner_h) begin
      `uvm_error(
        "BINDING_OUTER_SUBTYPE_FIXTURE",
        "constructed outer subtype is incomplete or retains a source alias"
      )
      return null;
    end
    foreach (result.pcie.bar[i]) begin
      if (result.pcie.bar[i] == source.pcie.bar[i]) begin
        `uvm_error(
          "BINDING_OUTER_SUBTYPE_FIXTURE",
          "constructed outer subtype retains a source BAR alias"
        )
        return null;
      end
    end
    return result;
  endfunction

  // 功能：从一份六 BAR PCIe 投影逐字段构造独立的 registered subtype。
  // 输入/输出及副作用：name/source 为只读输入；返回拥有六个新 BAR 节点的 subtype，
  // 不保存 source 或其 BAR 引用。
  // 失败/边界：source 或任一固定 BAR 为 null 时报告 PCIE_SUBTYPE_FIXTURE 并返回 null；
  // 本helper不执行 binding.validate() 或 factory clone。
  function automatic rdma_cmq_journal_binding_pcie_subtype
  make_journal_binding_pcie_subtype(
    input string name,
    input rdma_pcie_identity source
  );
    rdma_cmq_journal_binding_pcie_subtype result;

    if (source == null) begin
      `uvm_error("PCIE_SUBTYPE_FIXTURE", "source PCIe identity is null")
      return null;
    end
    foreach (source.bar[i]) begin
      if (source.bar[i] == null) begin
        `uvm_error("PCIE_SUBTYPE_FIXTURE", "source BAR is null")
        return null;
      end
    end

    result = new(name);
    result.bdf = source.bdf;
    result.parent_pf_bdf = source.parent_pf_bdf;
    result.vf_index = source.vf_index;
    result.mse = source.mse;
    result.bme = source.bme;
    result.extension_value = 32'hcafe_1001;
    foreach (result.bar[i]) begin
      result.bar[i].bar_id = source.bar[i].bar_id;
      result.bar[i].base = source.bar[i].base;
      result.bar[i].size = source.bar[i].size;
      result.bar[i].enabled = source.bar[i].enabled;
    end
    return result;
  endfunction

  // 功能：从一份六 BAR PCIe 投影构造 exact-base PCIe，但将每个 BAR 换成独立 subtype。
  // 输入/输出及副作用：name/source/extension_seed 为只读输入；返回新 PCIe 及六个
  // 新 BAR，每个 extension_value 从 seed 递增，不与 source 形成 alias。
  // 失败/边界：source/固定 BAR 缺失时报告 BAR_SUBTYPE_FIXTURE 并返回 null；
  // 返回值只供 comparator 投影测试，不取得 PCIe 设备权限。
  function automatic rdma_pcie_identity
  make_journal_binding_bar_subtypes(
    input string name,
    input rdma_pcie_identity source,
    input int unsigned extension_seed
  );
    rdma_pcie_identity result;
    rdma_cmq_journal_binding_bar_subtype bar_value;

    if (source == null) begin
      `uvm_error("BAR_SUBTYPE_FIXTURE", "source PCIe identity is null")
      return null;
    end
    foreach (source.bar[i]) begin
      if (source.bar[i] == null) begin
        `uvm_error("BAR_SUBTYPE_FIXTURE", "source BAR is null")
        return null;
      end
    end

    result = new(name);
    result.bdf = source.bdf;
    result.parent_pf_bdf = source.parent_pf_bdf;
    result.vf_index = source.vf_index;
    result.mse = source.mse;
    result.bme = source.bme;
    foreach (result.bar[i]) begin
      bar_value = new($sformatf("%s_bar_%0d", name, i));
      bar_value.bar_id = source.bar[i].bar_id;
      bar_value.base = source.bar[i].base;
      bar_value.size = source.bar[i].size;
      bar_value.enabled = source.bar[i].enabled;
      bar_value.extension_value = extension_seed + i;
      result.bar[i] = bar_value;
    end
    return result;
  endfunction

  // 功能：安装 status/ticket/image/completion 的可控 raw factory wrapper。
  // 输入/输出及副作用：无显式输入；更新四个测试字段并修改本次仿真的 UVM override。
  // 失败/边界：只允许调用一次；重复安装会使 delegate 指向旧故障 wrapper。
  function automatic void configure_snapshot_factory_faults();
    uvm_factory factory;

    factory = uvm_factory::get();
    status_fault = new("cmq_status_fault", rdma_status::get_type());
    ticket_fault = new("cmq_ticket_fault", rdma_cmq_ticket::get_type());
    image_fault = new("cmq_image_fault", rdma_hw_image::get_type());
    completion_fault = new(
      "cmq_completion_fault", rdma_cmq_completion::get_type()
    );
    factory.set_type_override_by_type(
      rdma_status::get_type(), status_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_ticket::get_type(), ticket_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), image_fault, 1'b1
    );
    factory.set_type_override_by_type(
      rdma_cmq_completion::get_type(), completion_fault, 1'b1
    );
  endfunction

  // 功能：关闭四个 raw factory 故障窗口，恢复后续 fixture 的正常创建。
  // 输入/输出及副作用：无输入输出；只修改 wrapper arm 状态，不移除 override。
  // 失败/边界：wrapper 尚未配置时跳过；重复调用保持幂等。
  function automatic void disarm_snapshot_factory_faults();
    if (status_fault != null)
      status_fault.disarm();
    if (ticket_fault != null)
      ticket_fault.disarm();
    if (image_fault != null)
      image_fault.disarm();
    if (completion_fault != null)
      completion_fault.disarm();
  endfunction

  // 功能：比较 canonical writer 输出与手工给定的字节数组。
  // 输入/输出及副作用：label、actual、expected 只读；不匹配时发布 UVM error。
  // 失败/边界：长度不等立即报错并返回；不会越界读取较短数组。
  function automatic void expect_bytes(
    string label,
    byte unsigned actual[],
    byte unsigned expected[]
  );
    if (actual.size() != expected.size()) begin
      `uvm_error(label,
                 $sformatf("expected %0d bytes, got %0d",
                           expected.size(), actual.size()))
      return;
    end

    foreach (expected[i]) begin
      if (actual[i] != expected[i]) begin
        `uvm_error(label,
                   $sformatf("byte[%0d] expected %02x, got %02x",
                             i, expected[i], actual[i]))
        return;
      end
    end
  endfunction

  // 功能：对 canonical byte 数组执行真实 digest，并与独立手算常量比较。
  // 输入/输出及副作用：label、bytes、expected 只读；不匹配时发布 UVM error。
  // 失败/边界：空数组是合法输入；函数不借用被测 encoder 生成期望值。
  function automatic void expect_digest(
    string label,
    byte unsigned bytes[],
    rdma_cmq_journal_digest_t expected
  );
    rdma_cmq_journal_digest_t actual;

    actual = rdma_cmq_digest_bytes(bytes);
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("expected %064x, got %064x", expected, actual))
  endfunction

  // 功能：校验一个已经由被测 encoder 产生的 schema stream 的手算长度与摘要常量。
  // 输入/输出及副作用：label/writer/encoded/expected_size/expected_digest 为输入；
  //   只读取 writer snapshot，失败时发布 UVM_ERROR，不调用任何 production serializer。
  // 失败/边界：encoder 拒绝、writer 为空或长度漂移时立即报错；长度正确后才计算摘要，
  //   因而期望侧始终只是独立 literal，不会用被测 schema 重建自身期望。
  function automatic void expect_schema_golden(
    string label,
    rdma_cmq_canonical_writer writer,
    bit encoded,
    int unsigned expected_size,
    rdma_cmq_journal_digest_t expected_digest
  );
    byte unsigned actual_bytes[];

    if (!encoded || writer == null) begin
      `uvm_error(label, "golden fixture was rejected before comparison")
      return;
    end
    writer.snapshot(actual_bytes);
    if (actual_bytes.size() != expected_size) begin
      `uvm_error(label,
                 $sformatf("expected %0d bytes, got %0d",
                           expected_size, actual_bytes.size()))
      return;
    end
    expect_digest(label, actual_bytes, expected_digest);
  endfunction

  // 功能：比较被测 item/batch/proof helper 发布的摘要与独立手算 literal。
  // 输入/输出及副作用：label、actual、expected 只读；不重建 canonical bytes，
  //   不调用 serializer，值不一致时发布 UVM_ERROR。
  // 失败/边界：全零也按普通不等处理；调用方负责先断言 status 为 OK，避免把拒绝
  //   路径误诊为 golden 漂移。
  function automatic void expect_digest_value(
    string label,
    rdma_cmq_journal_digest_t actual,
    rdma_cmq_journal_digest_t expected
  );
    if (actual != expected)
      `uvm_error(label,
                 $sformatf("expected %064x, got %064x", expected, actual))
  endfunction

  // 功能：完成一个 nested-schema 编码并计算其 canonical byte digest。
  // 输入/输出及副作用：label/writer/encoded 为输入；读取 detached bytes 并返回 digest。
  // 失败/边界：encoded 为 0 时报告 UVM_ERROR 并返回全零，避免无效 fixture 被误判为覆盖。
  function automatic rdma_cmq_journal_digest_t finish_schema_digest(
    string label,
    rdma_cmq_canonical_writer writer,
    bit encoded
  );
    byte unsigned bytes[];

    if (!encoded || writer == null) begin
      `uvm_error(label, "nested V1 schema rejected a valid mutation fixture")
      return '0;
    end
    writer.snapshot(bytes);
    return rdma_cmq_digest_bytes(bytes);
  endfunction

  // 功能：断言某个已列入 V1 schema 的字段 mutation 会改变 canonical digest。
  // 输入/输出及副作用：label/baseline/changed 只读；相等时发布 UVM_ERROR。
  // 失败/边界：不把碰撞解释为成功；任一全零结果也会由对应 encoder helper 先报告。
  function automatic void expect_schema_digest_changed(
    string label,
    rdma_cmq_journal_digest_t baseline,
    rdma_cmq_journal_digest_t changed
  );
    if (changed == baseline)
      `uvm_error(label, "listed V1 field did not change canonical digest")
  endfunction

  // 功能：编码 HANDLE-V1 的 presence、kind、UID、object ID 与 generation。
  // 输入/输出及副作用：label/value/allow_null 只读；返回该独立 schema 的 digest。
  // 失败/边界：required null、未知 subtype 或非法句柄由 production encoder 拒绝并报错。
  function automatic rdma_cmq_journal_digest_t digest_handle_schema(
    string label,
    rdma_handle value,
    bit allow_null = 1'b0
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_handle_v1(writer, value, allow_null)
    );
  endfunction

  // 功能：编码 BDF-V1 的 segment、bus、device 与 function_num。
  // 输入/输出及副作用：label/bdf 只读；返回该 packed BDF schema 的 digest。
  // 失败/边界：writer 分配或 production encoder 失败时报告错误并返回全零。
  function automatic rdma_cmq_journal_digest_t digest_bdf_schema(
    string label,
    rdma_bdf_t bdf
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_bdf_v1(writer, bdf)
    );
  endfunction

  // 功能：编码 ROUTE-V1 的 Host/root/segment 与嵌套 BDF。
  // 输入/输出及副作用：label/route 只读；返回完整 route schema 的 digest。
  // 失败/边界：空 BDF 或 route.segment 不一致时 production encoder 必须拒绝。
  function automatic rdma_cmq_journal_digest_t digest_route_schema(
    string label,
    rdma_route_key_t route
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_route_v1(writer, route)
    );
  endfunction

  // 功能：编码 FUNCTION-IDENTITY-V1 的 topology、global ID 与 incarnation。
  // 输入/输出及副作用：label/identity 只读；返回完整 identity schema digest。
  // 失败/边界：identity 无效或缺失时由 production encoder 原子拒绝并报告错误。
  function automatic rdma_cmq_journal_digest_t digest_identity_schema(
    string label,
    rdma_function_identity identity
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer,
      rdma_cmq_append_function_identity_v1(writer, identity, 1'b0)
    );
  endfunction

  // 功能：编码 OPCODE-KEY-V1 的 profile、opcode 与 variant。
  // 输入/输出及副作用：label/key 只读；返回 opcode-key schema digest。
  // 失败/边界：空文本、分隔符或 malformed UTF-8 由 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_opcode_schema(
    string label,
    rdma_cmq_opcode_key key
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_opcode_key_v1(writer, key)
    );
  endfunction

  // 功能：编码 RECOVERY-OWNER-V1 的 workflow、resource、action 与冻结 provenance。
  // 输入/输出及副作用：label/owner 只读；返回完整 recovery-owner schema digest。
  // 失败/边界：非 frozen concrete owner 或被篡改 legacy sentinel 必须原子拒绝。
  function automatic rdma_cmq_journal_digest_t digest_owner_schema(
    string label,
    rdma_cmq_recovery_owner owner
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_recovery_owner_v1(writer, owner)
    );
  endfunction

  // 功能：编码 IMAGE-V1 的 metadata、三个 target、bytes 与 field summary。
  // 输入/输出及副作用：label/image 只读；返回 required image schema digest。
  // 失败/边界：长度不符、非法 enum 或零 version/generation 时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_image_schema(
    string label,
    rdma_hw_image image
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_image_v1(writer, image, 1'b0)
    );
  endfunction

  // 功能：编码 CMQ-COMMAND-V1 shell，并在 body 位置插入 profile-owned projection。
  // 输入/输出及副作用：label/command/tag/body_bytes 只读；返回 command schema digest。
  // 失败/边界：未知 body tag、非法 Function/opcode/owner/image 或零 timeout 必须拒绝。
  function automatic rdma_cmq_journal_digest_t digest_command_schema(
    string label,
    rdma_cmq_command_desc command,
    string body_tag,
    byte unsigned body_bytes[]
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer,
      rdma_cmq_append_command_v1(writer, command, body_tag, body_bytes)
    );
  endfunction

  // 功能：编码 CMQ-TICKET-V1 的 command、Function/CMQ、slot、opcode 与 deadline。
  // 输入/输出及副作用：label/ticket 只读；返回完整 ticket schema digest。
  // 失败/边界：slot/index/wrap 不一致或任一 required handle 非法时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_ticket_schema(
    string label,
    rdma_cmq_ticket ticket
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_ticket_v1(writer, ticket)
    );
  endfunction

  // 功能：编码 DMA-CONTEXT-V1 的 requester、route/epoch、owner 与 queue role。
  // 输入/输出及副作用：label/dma_context 只读；返回公开 DMA context digest。
  // 失败/边界：Function/owner 不同代、无效 PASID 或坏 route 时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_dma_context_schema(
    string label,
    rdma_dma_request_context dma_context
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_dma_context_v1(writer, dma_context)
    );
  endfunction

  // 功能：编码 DMA-MAPPING-PUBLIC-V1，并只覆盖冻结的 public authority projection。
  // 输入/输出及副作用：label/mapping 只读；返回排除 opaque allocation token 的 digest。
  // 失败/边界：零 size、坏 direction/state、route 或句柄代际不一致时 encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_mapping_schema(
    string label,
    rdma_dma_mapping mapping
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_dma_mapping_public_v1(writer, mapping)
    );
  endfunction

  // 功能：编码 FUNCTION-BINDING-V1 的 identity、PCIe/BAR、DMA/caps/vector 与状态位。
  // 输入/输出及副作用：label/binding 只读；内部通过 nonfatal accessor 读取 identity。
  // 失败/边界：identity/PCIe/BAR 缺失或 owner subtype 不支持时 production encoder 拒绝。
  function automatic rdma_cmq_journal_digest_t digest_binding_schema(
    string label,
    rdma_function_binding binding
  );
    rdma_cmq_canonical_writer writer;

    writer = new();
    return finish_schema_digest(
      label, writer, rdma_cmq_append_function_binding_v1(writer, binding)
    );
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

  // 功能：验证新增执行/日志/恢复值默认形状、command identity 与 nonfatal 快照拓扑。
  // 输入/输出及副作用：无显式输入；创建本地值图并用 UVM error 报告契约偏差。
  // 失败/边界：覆盖 null、payload 自别名、factory hostile 和重复节点 canonicalization。
  function automatic void check_execution_value_defaults();
    rdma_cmq_execution_result result;
    rdma_cmq_batch_submission_item_record item_record;
    rdma_cmq_batch_submission_record batch_record;
    rdma_cmq_submission_recovery_item recovery_item;
    rdma_cmq_reset_isolation_proof proof;
    rdma_cmq_submission_recovery_request recovery_request;
    rdma_cmq_command_identity command_identity;
    rdma_cmq_command_desc command;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_status source_status;
    rdma_status status_snapshot;
    rdma_status second_status_snapshot;
    rdma_cmq_ticket source_ticket;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_ticket second_ticket_snapshot;
    rdma_cmq_completion source_completion;
    rdma_cmq_completion completion_snapshot;
    rdma_hw_image raw_cqe;
    rdma_cmq_value_wrong_factory_object source_payload;
    rdma_cmq_value_wrong_factory_object detached_payload;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_cmq_recovery_owner second_owner_snapshot;
    rdma_function_identity identity;
    string failure_reason;
    bit snapshot_ok;

    result = new("uninitialized_result");
    if (result.status == null || result.status.ok() ||
        result.status.code != RDMA_SC_INVALID_STATE ||
        result.observation_status == null ||
        result.observation_status.ok() ||
        result.observation_status.code != RDMA_SC_INVALID_STATE ||
        result.status == result.observation_status)
      `uvm_error("EXECUTION_DEFAULT",
                 "new execution result defaulted to success or null status")

    item_record = new("uninitialized_item_record");
    if (item_record.status == null || item_record.status.ok() ||
        item_record.status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("ITEM_STATUS_DEFAULT",
                 "new journal item defaulted to success or null status")

    batch_record = new("uninitialized_batch_record");
    recovery_item = new("uninitialized_recovery_item");
    proof = new("uninitialized_reset_proof");
    recovery_request = new("uninitialized_recovery_request");
    if (batch_record.items.size() != 0 || recovery_request.items.size() != 0 ||
        recovery_item.command != null ||
        proof.state != RDMA_CMQ_RESET_PROOF_INVALID ||
        proof.isolated_request_indices.size() != 0 ||
        proof.isolated_image_digests.size() != 0 ||
        proof.isolated_authority_digests.size() != 0 ||
        proof.isolated_recovery_owners.size() != 0 ||
        recovery_request.action != RDMA_CMQ_RECOVERY_INVALID)
      `uvm_error("VALUE_DEFAULTS", "new value queues/state were not empty/invalid")

    if (RDMA_CMQ_COMPLETION_NONE != 0 ||
        RDMA_CMQ_COMPLETION_PENDING != 1 ||
        RDMA_CMQ_COMPLETION_TERMINAL != 2 ||
        RDMA_CMQ_COMPLETION_TIMEOUT != 3 ||
        RDMA_CMQ_COMPLETION_RESET_CANCELLED != 4 ||
        RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY != 5 ||
        RDMA_CMQ_COMPLETION_UNOBSERVED != 6 ||
        RDMA_CMQ_SUBMISSION_STAGED != 0 ||
        RDMA_CMQ_SUBMISSION_PENDING_EFFECT != 1 ||
        RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED != 2 ||
        RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS != 3 ||
        RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED != 4 ||
        RDMA_CMQ_SUBMISSION_COMPLETED != 5 ||
        RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED != 6 ||
        RDMA_CMQ_SUBMISSION_LATE_COMPLETED != 7 ||
        RDMA_CMQ_SUBMISSION_RESET_QUARANTINED != 8)
      `uvm_error("VALUE_ENUM_ENCODING", "execution enum encoding drifted")

    function_h = make_function("identity_capture_function");
    cmq_h = make_cmq("identity_capture_cmq", function_h);
    key = make_key("identity_capture_key");
    body = make_body("identity_capture_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("identity_capture_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.timeout = 100;
    command_identity = new("captured_command_identity");
    failure_reason = "preseeded";
    if (!command_identity.capture_from(command, failure_reason) ||
        failure_reason != "" ||
        command_identity.function_kind != RDMA_RESOURCE_FUNCTION ||
        command_identity.function_uid != TEST_FUNCTION_UID ||
        command_identity.global_function_id != 32'h1234 ||
        command_identity.generation != TEST_GENERATION ||
        command_identity.profile_name != "generic_profile" ||
        command_identity.opcode != 32'hff00_abcd ||
        command_identity.variant != "query")
      `uvm_error("COMMAND_IDENTITY_CAPTURE", "immutable identity capture failed")
    command.function_h.function_uid++;
    command.opcode_key.variant = "mutated";
    if (command_identity.function_uid != TEST_FUNCTION_UID ||
        command_identity.variant != "query")
      `uvm_error("COMMAND_IDENTITY_DETACHED", "capture retained command aliases")
    command.function_h.function_uid--;
    command.opcode_key.variant = "query";

    snapshot_context = new();
    status_snapshot = rdma_status::success("preseeded status");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      null, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_NULL_STATUS",
                 "required null status did not fail atomically")

    ticket_snapshot = make_ticket(
      "preseeded_ticket", function_h, cmq_h, key
    );
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      null, ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || ticket_snapshot != null || failure_reason != "")
      `uvm_error("SNAPSHOT_NULL_TICKET",
                 "optional null ticket did not return clean null")

    completion_snapshot = new("preseeded_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      null, null, completion_snapshot, failure_reason
    );
    if (!snapshot_ok || completion_snapshot != null || failure_reason != "")
      `uvm_error("SNAPSHOT_NULL_COMPLETION",
                 "optional null completion did not return clean null")

    source_status = rdma_status::make(
      RDMA_SC_DMA_PERMISSION, "operation status retained"
    );
    source_status.hardware_code = 32'ha5a5_5a5a;
    source_status.hardware_code_valid = 1'b1;
    source_status.source_engine = RDMA_ENGINE_DMA;
    source_status.function_uid = TEST_FUNCTION_UID;
    source_status.generation = TEST_GENERATION;
    source_status.resource_id = 64'h1111;
    source_status.command_id = 64'h2222;
    source_status.wr_id = 64'h3333;
    source_status.severity = RDMA_SEVERITY_WARNING;
    source_status.retryable = 1'b1;
    source_ticket = make_ticket(
      "snapshot_source_ticket", function_h, cmq_h, key
    );
    raw_cqe = make_image(
      "snapshot_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64, TEST_GENERATION
    );
    source_completion = new("snapshot_source_completion");
    source_completion.ticket = source_ticket;
    source_completion.status = source_status;
    source_completion.raw_cqe = raw_cqe;
    source_completion.decoded_response = null;

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || status_snapshot == null ||
        status_snapshot == source_status ||
        status_snapshot.code != RDMA_SC_DMA_PERMISSION ||
        status_snapshot.hardware_code != 32'ha5a5_5a5a ||
        status_snapshot.source_engine != RDMA_ENGINE_DMA ||
        status_snapshot.message != "operation status retained")
      `uvm_error("SNAPSHOT_STATUS", "status snapshot lost fields or detachment")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      source_ticket, ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || ticket_snapshot == null ||
        ticket_snapshot == source_ticket ||
        ticket_snapshot.function_h == source_ticket.function_h ||
        ticket_snapshot.cmq_h == source_ticket.cmq_h ||
        ticket_snapshot.opcode_key == source_ticket.opcode_key ||
        ticket_snapshot.command_id != 64'h1234_0005)
      `uvm_error("SNAPSHOT_TICKET", "ticket snapshot was not a detached value")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, null, completion_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || completion_snapshot == null ||
        completion_snapshot == source_completion ||
        completion_snapshot.ticket != ticket_snapshot ||
        completion_snapshot.status != status_snapshot ||
        completion_snapshot.raw_cqe == source_completion.raw_cqe ||
        completion_snapshot.raw_cqe.bytes.size() != 64 ||
        completion_snapshot.decoded_response != null)
      `uvm_error("SNAPSHOT_COMPLETION_NULL_PAYLOAD",
                 "completion shell lost scalar/raw/canonical alias values")

    source_payload = new("source_payload");
    detached_payload = new("detached_payload");
    source_completion.decoded_response = source_payload;
    completion_snapshot = new("preseeded_self_payload_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, source_payload, completion_snapshot, failure_reason
    );
    if (snapshot_ok || completion_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_SELF_PAYLOAD",
                 "self-cloning completion payload was accepted")

    completion_snapshot = new("preseeded_null_payload_completion");
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, null, completion_snapshot, failure_reason
    );
    if (snapshot_ok || completion_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_MISSING_PAYLOAD",
                 "missing detached completion payload was accepted")

    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, detached_payload, completion_snapshot,
      failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || completion_snapshot == null ||
        completion_snapshot.decoded_response != detached_payload)
      `uvm_error("SNAPSHOT_DETACHED_PAYLOAD",
                 "detached completion payload was not published")

    identity = make_identity("snapshot_owner_identity");
    owner = make_owner(
      "snapshot_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("SNAPSHOT_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 19), RDMA_SC_OK);
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, owner_snapshot, failure_reason
    );
    if (!snapshot_ok || failure_reason != "" || owner_snapshot == null ||
        owner_snapshot == owner || owner_snapshot.resource_h == owner.resource_h ||
        owner_snapshot.function_identity == owner.function_identity ||
        !owner_snapshot.validate_frozen(identity, 19).ok())
      `uvm_error("SNAPSHOT_OWNER", "frozen owner snapshot was not detached")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, second_owner_snapshot, failure_reason
    );
    if (!snapshot_ok || second_owner_snapshot != owner_snapshot)
      `uvm_error("SNAPSHOT_OWNER_CANONICAL",
                 "repeated owner source did not reuse detached node")
    owner_snapshot.transaction_id++;
    if (owner.transaction_id != 64'h1111_2222_3333_4444)
      `uvm_error("SNAPSHOT_OWNER_MUTATION", "owner snapshot aliases source")

    configure_snapshot_factory_faults();
    status_fault.arm(1'b1);
    ticket_fault.arm(1'b1);
    image_fault.arm(1'b1);
    completion_fault.arm(1'b1);
    snapshot_context = new();
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, second_status_snapshot, failure_reason
    );
    if (!snapshot_ok || second_status_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_STATUS", "direct status snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_optional_ticket(
      source_ticket, second_ticket_snapshot, failure_reason
    );
    if (!snapshot_ok || second_ticket_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_TICKET", "direct ticket snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_recovery_owner(
      owner, second_owner_snapshot, failure_reason
    );
    if (!snapshot_ok || second_owner_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_OWNER", "direct owner snapshot failed")
    failure_reason = "preseeded reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      source_completion, detached_payload, completion_snapshot,
      failure_reason
    );
    if (!snapshot_ok || completion_snapshot == null)
      `uvm_error("SNAPSHOT_FACTORY_COMPLETION",
                 "direct completion snapshot failed")
    if (status_fault.call_count() != 0 || ticket_fault.call_count() != 0 ||
        image_fault.call_count() != 0 || completion_fault.call_count() != 0)
      `uvm_error("SNAPSHOT_FACTORY_CALLS",
                 "nonfatal snapshot context entered raw factory")
    disarm_snapshot_factory_faults();
  endfunction

  // 功能：验证 required status 在 cache lookup 前拒绝注册子类与三类 spare 编码，
  //   且 completion shell 对共享 status 使用同一门禁。
  // 输入/输出及副作用：无显式输入；构造独立 snapshot context、status 与 completion
  //   fixture；仅通过 UVM error 发布契约偏差，不保留外部资源。
  // 失败/边界：覆盖 category=11、code=17、source_engine=12、已缓存源后变异，
  //   以及伪装 get_type_name 的独立 wrapper；每次失败均须清空 snapshot 并给出原因。
  function automatic void check_required_status_snapshot_validation();
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_spoofed_status_subtype subtype_status;
    rdma_status source_status;
    rdma_status status_snapshot;
    rdma_status retained_snapshot;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_completion completion;
    rdma_cmq_completion completion_snapshot;
    string failure_reason;
    bit snapshot_ok;

    snapshot_context = new();
    subtype_status = new("registered_status_subtype");
    if (subtype_status.get_type_name() != "rdma_status" ||
        subtype_status.get_object_type() == rdma_status::get_type())
      `uvm_error("STATUS_SUBTYPE_FIXTURE",
                 "registered status subtype did not preserve hostile identity")
    status_snapshot = rdma_status::success("preseeded subtype output");
    failure_reason = "preseeded subtype reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      subtype_status, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_STATUS_SUBTYPE",
                 "registered status subtype was accepted or partially published")

    source_status = rdma_status::success("invalid category source");
    source_status.category = rdma_status_category_e'(4'd11);
    status_snapshot = rdma_status::success("preseeded category output");
    failure_reason = "preseeded category reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_STATUS_CATEGORY_RANGE",
                 "status category spare encoding was accepted")

    source_status = rdma_status::success("invalid code source");
    source_status.code = rdma_status_code_e'(5'd17);
    status_snapshot = rdma_status::success("preseeded code output");
    failure_reason = "preseeded code reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_STATUS_CODE_RANGE",
                 "status code spare encoding was accepted")

    source_status = rdma_status::success("invalid engine source");
    source_status.source_engine = rdma_engine_kind_e'(4'd12);
    status_snapshot = rdma_status::success("preseeded engine output");
    failure_reason = "preseeded engine reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_STATUS_ENGINE_RANGE",
                 "status source-engine spare encoding was accepted")

    snapshot_context = new();
    source_status = rdma_status::success("cache mutation source");
    failure_reason = "preseeded initial-cache reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, retained_snapshot, failure_reason
    );
    if (!snapshot_ok || retained_snapshot == null || failure_reason != "")
      `uvm_error("SNAPSHOT_STATUS_CACHE_SETUP",
                 "valid status did not seed the canonical cache")
    source_status.code = rdma_status_code_e'(5'd17);
    status_snapshot = rdma_status::success("preseeded cache output");
    failure_reason = "preseeded cache reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, status_snapshot, failure_reason
    );
    if (snapshot_ok || status_snapshot != null || failure_reason == "" ||
        retained_snapshot == null || retained_snapshot.code != RDMA_SC_OK)
      `uvm_error("SNAPSHOT_STATUS_MUTATED_CACHE",
                 "mutated malformed status reused a cached snapshot")

    snapshot_context = new();
    source_status = rdma_status::success("completion shared status");
    failure_reason = "preseeded completion-cache reason";
    snapshot_ok = snapshot_context.try_snapshot_required_status(
      source_status, retained_snapshot, failure_reason
    );
    if (!snapshot_ok || retained_snapshot == null || failure_reason != "")
      `uvm_error("SNAPSHOT_COMPLETION_STATUS_SETUP",
                 "valid completion status did not seed the canonical cache")
    source_status.category = rdma_status_category_e'(4'd11);
    function_h = make_function("status_validation_function");
    cmq_h = make_cmq("status_validation_cmq", function_h);
    key = make_key("status_validation_key");
    completion = new("status_validation_completion");
    completion.ticket = make_ticket(
      "status_validation_ticket", function_h, cmq_h, key
    );
    completion.status = source_status;
    completion.raw_cqe = make_image(
      "status_validation_raw_cqe", RDMA_IMAGE_CMQ_CQE, 64,
      TEST_GENERATION
    );
    completion.decoded_response = null;
    completion_snapshot = new("preseeded_status_validation_completion");
    failure_reason = "preseeded completion reason";
    snapshot_ok = snapshot_context.try_snapshot_completion_shell(
      completion, null, completion_snapshot, failure_reason
    );
    if (snapshot_ok || completion_snapshot != null || failure_reason == "")
      `uvm_error("SNAPSHOT_COMPLETION_STATUS_RANGE",
                 "completion shell reused a cached malformed status")
  endfunction

  // 功能：创建只携带指定 lifetime state 的 journal item，供 reducer 表驱动测试。
  // 输入/输出及副作用：name、state 为输入；返回新 item，其他字段保持构造默认。
  // 失败/边界：允许 spare/X/Z state 进入 fixture，以验证 reducer 保持输出不变。
  function automatic rdma_cmq_batch_submission_item_record make_state_item(
    string name,
    rdma_cmq_submission_state_e state
  );
    rdma_cmq_batch_submission_item_record item;

    item = new(name);
    item.state = state;
    return item;
  endfunction

  // 功能：验证 batch reducer 的保守优先级、全终态归约和非法阶段混合拒绝。
  // 输入/输出及副作用：无显式输入；构造 item queue 并检查返回 status/state。
  // 失败/边界：空队列、spare/X/Z state 与 pre-MMIO/published 混合必须非致命失败。
  function automatic void check_batch_state_reducer();
    rdma_cmq_batch_submission_item_record items[$];
    rdma_cmq_submission_state_e reduced_state;
    rdma_cmq_submission_state_e unknown_state;
    rdma_status status;

    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_STAGED)
      `uvm_error("BATCH_REDUCE_EMPTY", "empty batch changed aggregate state")

    items.push_back(make_state_item(
      "completed_0", RDMA_CMQ_SUBMISSION_COMPLETED
    ));
    items.push_back(make_state_item(
      "published_1", RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED
    ));
    expect_status("BATCH_REDUCE_PENDING",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED)
      `uvm_error("BATCH_REDUCE_PENDING", "pending published item was lost")

    items.delete();
    items.push_back(make_state_item(
      "timeout_0", RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED
    ));
    items.push_back(make_state_item(
      "completed_1", RDMA_CMQ_SUBMISSION_COMPLETED
    ));
    expect_status("BATCH_REDUCE_TIMEOUT",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED)
      `uvm_error("BATCH_REDUCE_TIMEOUT", "timeout quarantine was lost")

    items[0].state = RDMA_CMQ_SUBMISSION_COMPLETED;
    expect_status("BATCH_REDUCE_COMPLETED",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_COMPLETED", "all-completed batch was not terminal")

    items[1].state = RDMA_CMQ_SUBMISSION_LATE_COMPLETED;
    expect_status("BATCH_REDUCE_LATE",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_LATE_COMPLETED)
      `uvm_error("BATCH_REDUCE_LATE", "late terminal item was not retained")

    items[0].state = RDMA_CMQ_SUBMISSION_RESET_QUARANTINED;
    expect_status("BATCH_REDUCE_RESET",
                  rdma_cmq_reduce_batch_state(items, reduced_state),
                  RDMA_SC_OK);
    if (reduced_state != RDMA_CMQ_SUBMISSION_RESET_QUARANTINED)
      `uvm_error("BATCH_REDUCE_RESET", "reset quarantine was not dominant")

    items[0].state = RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED;
    items[1].state = RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS;
    reduced_state = RDMA_CMQ_SUBMISSION_STAGED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_STAGED)
      `uvm_error("BATCH_REDUCE_IMPOSSIBLE_MIX",
                 "pre-MMIO/published mix was accepted or changed output")

    unknown_state = rdma_cmq_submission_state_e'(4'bx001);
    items.delete();
    items.push_back(make_state_item("unknown_state", unknown_state));
    reduced_state = RDMA_CMQ_SUBMISSION_COMPLETED;
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_UNKNOWN", "unknown state changed output")
    items[0].state = rdma_cmq_submission_state_e'(4'hf);
    status = rdma_cmq_reduce_batch_state(items, reduced_state);
    if (status == null || status.ok() ||
        reduced_state != RDMA_CMQ_SUBMISSION_COMPLETED)
      `uvm_error("BATCH_REDUCE_SPARE", "spare state changed output")
  endfunction

  // 功能：验证跨 attempt evidence fold 的显式终止分支与 concrete high-water 规则。
  // 输入/输出及副作用：无显式输入；调用纯 helper 并检查 cumulative 输出。
  // 失败/边界：非法 prior、spare/X/Z 输入必须返回 0 且不改写预置输出。
  function automatic void check_attempt_effect_fold();
    rdma_submission_effect_e cumulative;
    rdma_submission_effect_e prior;
    rdma_submission_effect_e current;
    rdma_submission_effect_e expected;

    for (int unsigned prior_value =
           RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
         prior_value <= RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
         prior_value++) begin
      prior = rdma_submission_effect_e'(prior_value);
      cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      if (!rdma_cmq_fold_attempt_effect(
            prior, RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED, cumulative
          ) || cumulative != prior)
        `uvm_error("ATTEMPT_FOLD_PRE", "pre-submit retry erased prior evidence")
      cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
      if (!rdma_cmq_fold_attempt_effect(
            prior, RDMA_SUBMIT_EFFECT_UNOBSERVED, cumulative
          ) || cumulative != prior)
        `uvm_error("ATTEMPT_FOLD_UNOBSERVED",
                   "unobserved retry erased prior evidence")

      for (int unsigned current_value =
             RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE;
           current_value <= RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
           current_value++) begin
        current = rdma_submission_effect_e'(current_value);
        expected = (current_value > prior_value) ? current : prior;
        cumulative = RDMA_SUBMIT_EFFECT_UNOBSERVED;
        if (!rdma_cmq_fold_attempt_effect(prior, current, cumulative) ||
            cumulative != expected)
          `uvm_error("ATTEMPT_FOLD_CONCRETE", "concrete maximum was wrong")
      end
    end

    current = RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED;
    cumulative = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED, current, cumulative
        ) || cumulative != current)
      `uvm_error("ATTEMPT_FOLD_DISCOVERED", "concrete evidence was not retained")
    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN_PRE", "unknown+pre did not stay unknown")
    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (!rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          RDMA_SUBMIT_EFFECT_UNOBSERVED,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_UNOBSERVED)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN", "unknown+unknown changed evidence")

    cumulative = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    if (rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED,
          RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
          cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_INVALID_PRIOR", "invalid prior changed output")
    prior = rdma_submission_effect_e'(3'b111);
    if (rdma_cmq_fold_attempt_effect(
          prior, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_SPARE", "spare effect changed output")
    current = rdma_submission_effect_e'(3'bx10);
    if (rdma_cmq_fold_attempt_effect(
          RDMA_SUBMIT_EFFECT_HOST_MEMORY_WRITTEN, current, cumulative
        ) || cumulative != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("ATTEMPT_FOLD_UNKNOWN_BITS", "unknown effect changed output")
  endfunction

  // 功能：执行一行 recovery-required 表并校验 status 与预期 bit。
  // 输入/输出及副作用：label、state、phase、effect、confirmation、legacy、expected 为输入。
  // 失败/边界：返回 null/non-OK 或输出不符时发布 UVM error；不修改输入枚举。
  function automatic void expect_recovery_case(
    string label,
    rdma_cmq_submission_state_e state,
    rdma_cmq_completion_phase_e completion_phase,
    rdma_submission_effect_e submission_effect,
    bit reset_isolation_confirmed,
    bit legacy_unmigrated,
    bit expected
  );
    bit recovery_required;
    rdma_status status;

    recovery_required = ~expected;
    status = rdma_cmq_classify_recovery_required(
      state,
      completion_phase,
      submission_effect,
      reset_isolation_confirmed,
      legacy_unmigrated,
      recovery_required
    );
    if (status == null || !status.ok() || recovery_required != expected)
      `uvm_error(label, "recovery-required table row was misclassified")
  endfunction

  // 功能：验证 recovery_required 只由 lifetime state/phase/effect/proof 表推导，
  //   并冻结未 arm degraded envelope 的 HOST_VISIBLE/NONE/UNOBSERVED 恢复行。
  // 输入/输出及副作用：无显式输入；覆盖七个 completion phase、同步未观测
  //   transport 返回，以及 resolved/unresolved 行。
  // 失败/边界：unknown/spare/impossible 输入必须返回非成功并保持预置 output；
  //   只有精确的 host-visible 未观测组合可在 NONE phase 下保守要求恢复。
  function automatic void check_recovery_required_classifier();
    rdma_cmq_submission_state_e unknown_state;
    rdma_cmq_completion_phase_e unknown_phase;
    rdma_submission_effect_e unknown_effect;
    bit recovery_required;
    rdma_status status;

    expect_recovery_case(
      "RECOVERY_STAGED", RDMA_CMQ_SUBMISSION_STAGED,
      RDMA_CMQ_COMPLETION_NONE, RDMA_SUBMIT_EFFECT_UNOBSERVED,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_PENDING_EFFECT", RDMA_CMQ_SUBMISSION_PENDING_EFFECT,
      RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_HOST_MEMORY_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_HOST_VISIBLE",
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
      RDMA_CMQ_COMPLETION_NONE, RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_HOST_VISIBLE_UNOBSERVED",
      RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED,
      RDMA_CMQ_COMPLETION_NONE, RDMA_SUBMIT_EFFECT_UNOBSERVED,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_AMBIGUOUS", RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,
      RDMA_CMQ_COMPLETION_PENDING,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_PUBLISHED", RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED,
      RDMA_CMQ_COMPLETION_PENDING, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_TIMEOUT", RDMA_CMQ_SUBMISSION_TIMED_OUT_QUARANTINED,
      RDMA_CMQ_COMPLETION_TIMEOUT, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_AWAITING", RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_READY_UNCONFIRMED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b1, 1'b1
    );
    expect_recovery_case(
      "RECOVERY_RESET_CONCRETE_CONFIRMED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b1, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_RESET_LEGACY_RELEASED",
      RDMA_CMQ_SUBMISSION_RESET_QUARANTINED,
      RDMA_CMQ_COMPLETION_RESET_CANCELLED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b1, 1'b1, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_COMPLETED", RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_COMPLETION_TERMINAL, RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_LATE", RDMA_CMQ_SUBMISSION_LATE_COMPLETED,
      RDMA_CMQ_COMPLETION_DIAGNOSTIC_ONLY,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE,
      1'b0, 1'b0, 1'b0
    );
    expect_recovery_case(
      "RECOVERY_UNOBSERVED", RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_COMPLETION_UNOBSERVED, RDMA_SUBMIT_EFFECT_UNOBSERVED,
      1'b0, 1'b1, 1'b1
    );
    // arm 后 envelope 丢失时 phase 为 UNOBSERVED，但 cumulative effect 必须保留
    // 已发生的 MMIO_MAYBE_VISIBLE 证据；该降级组合仍需保守 reconcile。
    expect_recovery_case(
      "RECOVERY_UNOBSERVED_POST_ARM", RDMA_CMQ_SUBMISSION_COMPLETED,
      RDMA_CMQ_COMPLETION_UNOBSERVED,
      RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE,
      1'b0, 1'b0, 1'b1
    );

    recovery_required = 1'b0;
    unknown_state = rdma_cmq_submission_state_e'(4'bx001);
    status = rdma_cmq_classify_recovery_required(
      unknown_state, RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_UNOBSERVED, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_STATE", "unknown state changed output")
    status = rdma_cmq_classify_recovery_required(
      rdma_cmq_submission_state_e'(4'hf), RDMA_CMQ_COMPLETION_NONE,
      RDMA_SUBMIT_EFFECT_UNOBSERVED, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_SPARE_STATE", "spare state changed output")

    unknown_phase = rdma_cmq_completion_phase_e'(3'bx01);
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, unknown_phase,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_PHASE", "unknown phase changed output")
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED,
      rdma_cmq_completion_phase_e'(3'b111),
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_SPARE_PHASE", "spare phase changed output")

    unknown_effect = rdma_submission_effect_e'(3'bx10);
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, RDMA_CMQ_COMPLETION_TERMINAL,
      unknown_effect, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_UNKNOWN_EFFECT", "unknown effect changed output")
    status = rdma_cmq_classify_recovery_required(
      RDMA_CMQ_SUBMISSION_COMPLETED, RDMA_CMQ_COMPLETION_PENDING,
      RDMA_SUBMIT_EFFECT_MMIO_VISIBLE, 1'b0, 1'b0, recovery_required
    );
    if (status == null || status.ok() || recovery_required != 1'b0)
      `uvm_error("RECOVERY_IMPOSSIBLE", "impossible phase changed output")
  endfunction

  // 功能：验证 canonical writer 的 big-endian、计数、对象 header、UTF-8 与原子失败语义。
  // 输入/输出及副作用：无显式输入；读取 writer snapshot 并与手工 byte literal 比较。
  // 失败/边界：X/Z 数值和 malformed UTF-8 必须返回 0 且完全保持已有 buffer。
  function automatic void check_canonical_writer_contract();
    rdma_cmq_canonical_writer writer;
    byte unsigned actual[];
    byte unsigned expected[];
    byte unsigned counted[];
    byte unsigned before_failure[];
    logic [15:0] unknown_u16;
    string utf8_value;
    string malformed;

    writer = new();
    if (!writer.append_u16(16'h0102))
      `uvm_error("WRITER_U16", "writer rejected known u16")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h02};
    expect_bytes("WRITER_U16", actual, expected);

    writer.clear();
    if (!writer.append_u32(32'h0102_0304))
      `uvm_error("WRITER_U32", "writer rejected known u32")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h02, 8'h03, 8'h04};
    expect_bytes("WRITER_U32", actual, expected);

    writer.clear();
    if (!writer.append_string("A"))
      `uvm_error("WRITER_STRING", "writer rejected ASCII string")
    writer.snapshot(actual);
    expected = '{8'h00, 8'h00, 8'h00, 8'h01, 8'h41};
    expect_bytes("WRITER_STRING", actual, expected);

    writer.clear();
    if (!writer.append_object_header(1'b0, ""))
      `uvm_error("WRITER_ABSENT_OBJECT", "writer rejected absent object")
    writer.snapshot(actual);
    expected = '{8'h00};
    expect_bytes("WRITER_ABSENT_OBJECT", actual, expected);

    writer.clear();
    if (!writer.append_u8(8'h01) || !writer.append_u8(8'h7f))
      `uvm_error("WRITER_PRESENT_VALUE", "writer rejected present u8 fixture")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h7f};
    expect_bytes("WRITER_PRESENT_VALUE", actual, expected);

    writer.clear();
    if (!writer.append_object_header(1'b1, "T"))
      `uvm_error("WRITER_OBJECT_TAG", "writer rejected stable object tag")
    writer.snapshot(actual);
    expected = '{8'h01, 8'h00, 8'h00, 8'h00, 8'h01, 8'h54};
    expect_bytes("WRITER_OBJECT_TAG", actual, expected);

    writer.clear();
    counted = '{8'h80, 8'hff};
    if (!writer.append_counted_bytes(counted))
      `uvm_error("WRITER_COUNTED", "writer rejected counted bytes")
    writer.snapshot(actual);
    expected = '{8'h00, 8'h00, 8'h00, 8'h02, 8'h80, 8'hff};
    expect_bytes("WRITER_COUNTED", actual, expected);

    writer.clear();
    utf8_value = "xxx";
    utf8_value.putc(0, 8'he4);
    utf8_value.putc(1, 8'hb8);
    utf8_value.putc(2, 8'had);
    if (!writer.append_string(utf8_value))
      `uvm_error("WRITER_UTF8", "writer rejected valid UTF-8")
    writer.snapshot(actual);
    expected = '{
      8'h00, 8'h00, 8'h00, 8'h03, 8'he4, 8'hb8, 8'had
    };
    expect_bytes("WRITER_UTF8", actual, expected);

    writer.snapshot(before_failure);
    malformed = "xx";
    malformed.putc(0, 8'he4);
    malformed.putc(1, 8'hb8);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_TRUNCATED", "truncated UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_TRUNCATED_ATOMIC", actual, before_failure);

    malformed = "xx";
    malformed.putc(0, 8'hc0);
    malformed.putc(1, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_OVERLONG", "overlong UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_OVERLONG_ATOMIC", actual, before_failure);

    malformed = "xxx";
    malformed.putc(0, 8'hed);
    malformed.putc(1, 8'ha0);
    malformed.putc(2, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_SURROGATE", "UTF-8 surrogate was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_SURROGATE_ATOMIC", actual, before_failure);

    malformed = "xxxx";
    malformed.putc(0, 8'hf4);
    malformed.putc(1, 8'h90);
    malformed.putc(2, 8'h80);
    malformed.putc(3, 8'h80);
    if (writer.append_string(malformed))
      `uvm_error("WRITER_UTF8_RANGE", "out-of-range UTF-8 was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UTF8_RANGE_ATOMIC", actual, before_failure);

    unknown_u16 = 16'h0102;
    unknown_u16[7] = 1'bx;
    if (writer.append_u16(unknown_u16))
      `uvm_error("WRITER_UNKNOWN", "four-state unknown integer was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_UNKNOWN_ATOMIC", actual, before_failure);
    if (writer.append_object_header(1'bx, "T") ||
        writer.append_object_header(1'b0, "T") ||
        writer.append_object_header(1'b1, ""))
      `uvm_error("WRITER_OBJECT_HEADER", "invalid object header was accepted")
    writer.snapshot(actual);
    expect_bytes("WRITER_OBJECT_HEADER_ATOMIC", actual, before_failure);
  endfunction

  // 功能：以 brief 字段表独立手算的长度与 digest literal 锁定十二个非 body V1 schema；
  //   HANDLE 另比较完整 byte literal，直接暴露 header、宽度或大端顺序漂移。
  // 输入/输出及副作用：无显式输入；构造固定 identity/owner/image/command/DMA/binding
  //   fixture，把各 production encoder 的实际 writer 交给不含 serializer 的比较器。
  // 失败/边界：任一 fixture 创建/冻结失败、encoder 拒绝、字段遗漏/换序/变宽或对象
  //   header 漂移均发布 UVM_ERROR；golden 不覆盖 profile-owned body field bytes。
  function automatic void check_schema_golden_vectors();
    rdma_handle handle;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_bdf_t bdf;
    rdma_route_key_t route;
    rdma_function_identity identity;
    rdma_cmq_opcode_key key;
    rdma_cmq_recovery_owner owner;
    rdma_hw_image image;
    rdma_cmq_sqe_model body;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_function_binding binding;
    rdma_cmq_canonical_writer writer;
    rdma_status status;
    byte unsigned body_bytes[];
    byte unsigned actual_handle_bytes[];
    byte unsigned expected_handle_bytes[];
    bit encoded;

    identity = make_identity("golden_identity");
    bdf = identity.key.bdf;
    route = identity.route_key();
    key = make_key("golden_key");
    owner = make_owner(
      "golden_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    status = owner.freeze_for_journal(identity, 37);
    expect_status("GOLDEN_OWNER_FREEZE", status, RDMA_SC_OK);
    function_h = make_function("golden_function");
    cmq_h = make_cmq("golden_cmq", function_h);
    body = make_body("golden_body", function_h, cmq_h);
    ticket = make_ticket("golden_ticket", function_h, cmq_h, key);
    dma_context = make_dma_context("golden_dma_context", identity);
    mapping = make_mapping("golden_mapping", identity);
    binding = make_binding("golden_binding", identity);

    handle = make_resource_handle(
      "golden_handle", RDMA_RESOURCE_MR, 32'h1020_3040
    );
    writer = new();
    encoded = rdma_cmq_append_handle_v1(writer, handle, 1'b0);
    writer.snapshot(actual_handle_bytes);
    expected_handle_bytes = '{
      8'h01, 8'h00, 8'h00, 8'h00, 8'h09,
      8'h48, 8'h41, 8'h4e, 8'h44, 8'h4c, 8'h45, 8'h2d, 8'h56, 8'h31,
      8'h02, 8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, 8'h77, 8'h88,
      8'h10, 8'h20, 8'h30, 8'h40, 8'h00, 8'h00, 8'h00, 8'h07
    };
    expect_bytes("GOLDEN_HANDLE_BYTES", actual_handle_bytes,
                 expected_handle_bytes);
    expect_schema_golden(
      "GOLDEN_HANDLE", writer, encoded, 31,
      256'habe6b760_bc7c27d2_e4877ab3_2fd17530_eb1c861d_edd684c7_31b221e6_77661da0
    );

    writer = new();
    encoded = rdma_cmq_append_bdf_v1(writer, bdf);
    expect_schema_golden(
      "GOLDEN_BDF", writer, encoded, 16,
      256'h0046fa88_7e2200cb_ea3421f6_cccb66ad_2fbbf3cb_be10e658_7a4c72e0_ad12707d
    );

    writer = new();
    encoded = rdma_cmq_append_route_v1(writer, route);
    expect_schema_golden(
      "GOLDEN_ROUTE", writer, encoded, 37,
      256'h8a5aa83d_46157490_ea67743d_9bbb4cda_41de0ebc_82ded875_12b8dcf6_8bd6c9ea
    );

    writer = new();
    encoded = rdma_cmq_append_function_identity_v1(writer, identity, 1'b0);
    expect_schema_golden(
      "GOLDEN_IDENTITY", writer, encoded, 90,
      256'h6ac1c0fb_55319ca0_5b4c341f_38e96206_2e3263cb_a177d5af_ed75b85d_61876cd6
    );

    writer = new();
    encoded = rdma_cmq_append_opcode_key_v1(writer, key);
    expect_schema_golden(
      "GOLDEN_OPCODE", writer, encoded, 50,
      256'h24b098b7_71608999_298930db_57eba477_a0ae2ead_ccfbf546_7b98b11b_20dbd9e7
    );

    writer = new();
    encoded = rdma_cmq_append_recovery_owner_v1(writer, owner);
    expect_schema_golden(
      "GOLDEN_OWNER", writer, encoded, 162,
      256'h4566d606_fba93e9d_db7d9985_97f83fe7_86de860d_b2baec0e_3a979697_74a01ef7
    );

    image = make_image("golden_image", RDMA_IMAGE_CQC, 8, TEST_GENERATION);
    image.field_summary.push_back("golden-image");
    writer = new();
    encoded = rdma_cmq_append_image_v1(writer, image, 1'b0);
    expect_schema_golden(
      "GOLDEN_IMAGE", writer, encoded, 92,
      256'h011f34c7_c8b374e0_bdc518df_91ad9e22_09f41013_01b371e3_431a5ad8_53385832
    );

    command = rdma_cmq_command_desc::type_id::create("golden_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 64'h0102_0304_0506_0708;
    command.recovery_owner = owner;
    body_bytes = new[0];
    writer = new();
    encoded = rdma_cmq_append_command_v1(
      writer, command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_golden(
      "GOLDEN_COMMAND", writer, encoded, 296,
      256'h0213934c_c5f0f455_6e27041f_07270eff_5d08ae8b_e2bfe6f2_7545be27_4e5ae08f
    );

    writer = new();
    encoded = rdma_cmq_append_ticket_v1(writer, ticket);
    expect_schema_golden(
      "GOLDEN_TICKET", writer, encoded, 159,
      256'hc837b5de_67b5fb7b_15d5f683_222a29fd_28fade6b_97be515e_3591784d_f3058fcd
    );

    writer = new();
    encoded = rdma_cmq_append_dma_context_v1(writer, dma_context);
    expect_schema_golden(
      "GOLDEN_DMA_CONTEXT", writer, encoded, 159,
      256'h88bfa657_e10cbb3b_adb6906f_91eb0f09_21d50e1d_7a0a04e2_c25199f5_f7f1a6d9
    );

    writer = new();
    encoded = rdma_cmq_append_dma_mapping_public_v1(writer, mapping);
    expect_schema_golden(
      "GOLDEN_DMA_MAPPING", writer, encoded, 195,
      256'h6a5adc9d_f2a97be4_273bd9d2_1d3f70c6_3f458aa1_bd9ec6d5_12b36a5f_9e6b08d6
    );

    writer = new();
    encoded = rdma_cmq_append_function_binding_v1(writer, binding);
    expect_schema_golden(
      "GOLDEN_BINDING", writer, encoded, 455,
      256'h845b81fa_a965ff10_ba34a42d_5a5385a2_85dfc72e_05336c09_316b1fbf_099eaa32
    );
  endfunction

  // 功能：逐字段变更 HANDLE/BDF/ROUTE/IDENTITY/OPCODE/OWNER V1 fixture，
  //   证明每个列明字段进入 canonical digest，而固定为真的 frozen 位会拒绝篡改。
  // 输入/输出及副作用：无显式输入；只修改本地 fixture，逐次恢复基线并报告差异。
  // 失败/边界：受 PF/VF、route segment 与 workflow/kind 约束的字段成组保持合法；
  //   任一合法 mutation 编码失败、digest 不变或 frozen=0 被接受均报告 UVM_ERROR。
  function automatic void check_identity_schema_field_mutations();
    rdma_handle handle;
    rdma_bdf_t bdf;
    rdma_route_key_t route;
    rdma_function_identity identity;
    rdma_function_key_t saved_key;
    rdma_cmq_opcode_key key;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_workflow_e saved_workflow;
    rdma_resource_kind_e saved_kind;
    rdma_cmq_canonical_writer writer;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;

    handle = make_resource_handle(
      "schema_handle", RDMA_RESOURCE_MR, 32'h1020_3040
    );
    baseline_digest = digest_handle_schema("HANDLE_BASELINE", handle);
    handle.kind = RDMA_RESOURCE_CQ;
    changed_digest = digest_handle_schema("HANDLE_KIND", handle);
    expect_schema_digest_changed("HANDLE_KIND", baseline_digest,
                                 changed_digest);
    handle.kind = RDMA_RESOURCE_MR;
    handle.function_uid++;
    changed_digest = digest_handle_schema("HANDLE_FUNCTION_UID", handle);
    expect_schema_digest_changed("HANDLE_FUNCTION_UID", baseline_digest,
                                 changed_digest);
    handle.function_uid--;
    handle.object_id++;
    changed_digest = digest_handle_schema("HANDLE_OBJECT_ID", handle);
    expect_schema_digest_changed("HANDLE_OBJECT_ID", baseline_digest,
                                 changed_digest);
    handle.object_id--;
    handle.generation++;
    changed_digest = digest_handle_schema("HANDLE_GENERATION", handle);
    expect_schema_digest_changed("HANDLE_GENERATION", baseline_digest,
                                 changed_digest);
    handle.generation--;

    identity = make_identity("schema_identity");
    bdf = identity.key.bdf;
    baseline_digest = digest_bdf_schema("BDF_BASELINE", bdf);
    bdf.segment++;
    changed_digest = digest_bdf_schema("BDF_SEGMENT", bdf);
    expect_schema_digest_changed("BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    bdf.segment--;
    bdf.bus++;
    changed_digest = digest_bdf_schema("BDF_BUS", bdf);
    expect_schema_digest_changed("BDF_BUS", baseline_digest,
                                 changed_digest);
    bdf.bus--;
    bdf.device++;
    changed_digest = digest_bdf_schema("BDF_DEVICE", bdf);
    expect_schema_digest_changed("BDF_DEVICE", baseline_digest,
                                 changed_digest);
    bdf.device--;
    bdf.function_num++;
    changed_digest = digest_bdf_schema("BDF_FUNCTION", bdf);
    expect_schema_digest_changed("BDF_FUNCTION", baseline_digest,
                                 changed_digest);
    bdf.function_num--;

    route = identity.route_key();
    baseline_digest = digest_route_schema("ROUTE_BASELINE", route);
    route.host_topology_key++;
    changed_digest = digest_route_schema("ROUTE_HOST", route);
    expect_schema_digest_changed("ROUTE_HOST", baseline_digest,
                                 changed_digest);
    route.host_topology_key--;
    route.root_id++;
    changed_digest = digest_route_schema("ROUTE_ROOT", route);
    expect_schema_digest_changed("ROUTE_ROOT", baseline_digest,
                                 changed_digest);
    route.root_id--;
    route.segment++;
    route.bdf.segment++;
    changed_digest = digest_route_schema("ROUTE_SEGMENT", route);
    expect_schema_digest_changed("ROUTE_SEGMENT", baseline_digest,
                                 changed_digest);
    route.segment--;
    route.bdf.segment--;
    route.bdf.bus++;
    changed_digest = digest_route_schema("ROUTE_BDF", route);
    expect_schema_digest_changed("ROUTE_BDF", baseline_digest,
                                 changed_digest);
    route.bdf.bus--;

    baseline_digest = digest_identity_schema(
      "IDENTITY_BASELINE", identity
    );
    identity.key.root_id++;
    changed_digest = digest_identity_schema("IDENTITY_ROOT", identity);
    expect_schema_digest_changed("IDENTITY_ROOT", baseline_digest,
                                 changed_digest);
    identity.key.root_id--;
    identity.key.host_topology_key++;
    changed_digest = digest_identity_schema("IDENTITY_HOST", identity);
    expect_schema_digest_changed("IDENTITY_HOST", baseline_digest,
                                 changed_digest);
    identity.key.host_topology_key--;

    saved_key = identity.key;
    identity.key.function_kind = RDMA_FUNCTION_PF;
    identity.key.parent_pf_bdf = '0;
    identity.key.vf_index = 0;
    changed_digest = digest_identity_schema("IDENTITY_KIND", identity);
    expect_schema_digest_changed("IDENTITY_KIND", baseline_digest,
                                 changed_digest);
    identity.key = saved_key;

    identity.key.parent_pf_bdf.segment++;
    identity.key.bdf.segment++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_SEGMENT", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_SEGMENT",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.segment--;
    identity.key.bdf.segment--;
    identity.key.parent_pf_bdf.bus++;
    changed_digest = digest_identity_schema("IDENTITY_PARENT_BUS", identity);
    expect_schema_digest_changed("IDENTITY_PARENT_BUS", baseline_digest,
                                 changed_digest);
    identity.key.parent_pf_bdf.bus--;
    identity.key.parent_pf_bdf.device++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_DEVICE", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_DEVICE",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.device--;
    identity.key.parent_pf_bdf.function_num++;
    changed_digest = digest_identity_schema(
      "IDENTITY_PARENT_FUNCTION", identity
    );
    expect_schema_digest_changed("IDENTITY_PARENT_FUNCTION",
                                 baseline_digest, changed_digest);
    identity.key.parent_pf_bdf.function_num--;
    identity.key.vf_index++;
    changed_digest = digest_identity_schema("IDENTITY_VF_INDEX", identity);
    expect_schema_digest_changed("IDENTITY_VF_INDEX", baseline_digest,
                                 changed_digest);
    identity.key.vf_index--;

    identity.key.bdf.segment++;
    identity.key.parent_pf_bdf.segment++;
    changed_digest = digest_identity_schema(
      "IDENTITY_BDF_SEGMENT", identity
    );
    expect_schema_digest_changed("IDENTITY_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    identity.key.bdf.segment--;
    identity.key.parent_pf_bdf.segment--;
    identity.key.bdf.bus++;
    changed_digest = digest_identity_schema("IDENTITY_BDF_BUS", identity);
    expect_schema_digest_changed("IDENTITY_BDF_BUS", baseline_digest,
                                 changed_digest);
    identity.key.bdf.bus--;
    identity.key.bdf.device++;
    changed_digest = digest_identity_schema("IDENTITY_BDF_DEVICE", identity);
    expect_schema_digest_changed("IDENTITY_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    identity.key.bdf.device--;
    identity.key.bdf.function_num++;
    changed_digest = digest_identity_schema(
      "IDENTITY_BDF_FUNCTION", identity
    );
    expect_schema_digest_changed("IDENTITY_BDF_FUNCTION", baseline_digest,
                                 changed_digest);
    identity.key.bdf.function_num--;
    identity.global_function_id++;
    changed_digest = digest_identity_schema("IDENTITY_GLOBAL_ID", identity);
    expect_schema_digest_changed("IDENTITY_GLOBAL_ID", baseline_digest,
                                 changed_digest);
    identity.global_function_id--;
    identity.function_uid++;
    changed_digest = digest_identity_schema("IDENTITY_UID", identity);
    expect_schema_digest_changed("IDENTITY_UID", baseline_digest,
                                 changed_digest);
    identity.function_uid--;
    identity.generation++;
    changed_digest = digest_identity_schema("IDENTITY_GENERATION", identity);
    expect_schema_digest_changed("IDENTITY_GENERATION", baseline_digest,
                                 changed_digest);
    identity.generation--;
    identity.reset_epoch++;
    changed_digest = digest_identity_schema("IDENTITY_RESET_EPOCH", identity);
    expect_schema_digest_changed("IDENTITY_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    identity.reset_epoch--;

    key = make_key("schema_opcode_key");
    baseline_digest = digest_opcode_schema("OPCODE_BASELINE", key);
    key.profile_name = "generic_profile_2";
    changed_digest = digest_opcode_schema("OPCODE_PROFILE", key);
    expect_schema_digest_changed("OPCODE_PROFILE", baseline_digest,
                                 changed_digest);
    key.profile_name = "generic_profile";
    key.opcode++;
    changed_digest = digest_opcode_schema("OPCODE_VALUE", key);
    expect_schema_digest_changed("OPCODE_VALUE", baseline_digest,
                                 changed_digest);
    key.opcode--;
    key.variant = "query_2";
    changed_digest = digest_opcode_schema("OPCODE_VARIANT", key);
    expect_schema_digest_changed("OPCODE_VARIANT", baseline_digest,
                                 changed_digest);
    key.variant = "query";

    owner = make_owner(
      "schema_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("OWNER_SCHEMA_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    baseline_digest = digest_owner_schema("OWNER_BASELINE", owner);
    saved_workflow = owner.workflow;
    saved_kind = owner.resource_h.kind;
    owner.workflow = RDMA_CMQ_WORKFLOW_QP;
    owner.resource_h.kind = RDMA_RESOURCE_QP;
    changed_digest = digest_owner_schema("OWNER_WORKFLOW", owner);
    expect_schema_digest_changed("OWNER_WORKFLOW", baseline_digest,
                                 changed_digest);
    owner.workflow = saved_workflow;
    owner.resource_h.kind = saved_kind;
    owner.resource_h.object_id++;
    changed_digest = digest_owner_schema("OWNER_RESOURCE", owner);
    expect_schema_digest_changed("OWNER_RESOURCE", baseline_digest,
                                 changed_digest);
    owner.resource_h.object_id--;
    owner.transaction_id++;
    changed_digest = digest_owner_schema("OWNER_TRANSACTION", owner);
    expect_schema_digest_changed("OWNER_TRANSACTION", baseline_digest,
                                 changed_digest);
    owner.transaction_id--;
    owner.allowed_actions[RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION] = 1'b1;
    changed_digest = digest_owner_schema("OWNER_ACTIONS", owner);
    expect_schema_digest_changed("OWNER_ACTIONS", baseline_digest,
                                 changed_digest);
    owner.allowed_actions[RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION] = 1'b0;
    owner.function_identity.reset_epoch++;
    changed_digest = digest_owner_schema("OWNER_IDENTITY", owner);
    expect_schema_digest_changed("OWNER_IDENTITY", baseline_digest,
                                 changed_digest);
    owner.function_identity.reset_epoch--;
    owner.admission_attempt_id++;
    changed_digest = digest_owner_schema("OWNER_ATTEMPT", owner);
    expect_schema_digest_changed("OWNER_ATTEMPT", baseline_digest,
                                 changed_digest);
    owner.admission_attempt_id--;

    // Concrete owner 的 frozen 唯一合法值为 1；没有第二个合法值可比较 digest，
    // 因此这里直接证明变为 0 时整个 schema 原子拒绝且不能产生候选 bytes。
    owner.frozen = 1'b0;
    writer = new();
    if (rdma_cmq_append_recovery_owner_v1(writer, owner))
      `uvm_error("OWNER_FROZEN", "unfrozen concrete owner was canonicalized")
    owner.frozen = 1'b1;
  endfunction

  // 功能：逐字段变更 IMAGE、CMQ-COMMAND 与 CMQ-TICKET V1 fixture，证明
  //   metadata、body projection、nullable image 和 slot identity 都进入 digest。
  // 输入/输出及副作用：无显式输入；创建本地 graph，每次 mutation 后恢复原值。
  // 失败/边界：IMAGE length 与 byte count、ticket sequence/index/wrap 成组保持合法；
  //   任一 production encoder 拒绝合法 fixture 或 digest 不变时报告 UVM_ERROR。
  function automatic void check_command_schema_field_mutations();
    rdma_function_identity identity;
    rdma_cmq_recovery_owner owner;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_hw_image image;
    rdma_hw_image signature_image;
    byte unsigned body_bytes[];
    byte unsigned removed_byte;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;

    identity = make_identity("command_schema_identity");
    owner = make_owner(
      "command_schema_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("COMMAND_SCHEMA_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    function_h = make_function("command_schema_function");
    cmq_h = make_cmq("command_schema_cmq", function_h);
    key = make_key("command_schema_opcode");
    body = make_body("command_schema_body", function_h, cmq_h);

    image = make_image(
      "schema_image", RDMA_IMAGE_CMQ_SQE, 8, TEST_GENERATION
    );
    image.field_summary.push_back("schema-field");
    baseline_digest = digest_image_schema("IMAGE_BASELINE", image);
    image.bytes.push_back(8'h6b);
    image.length++;
    changed_digest = digest_image_schema("IMAGE_LENGTH", image);
    expect_schema_digest_changed("IMAGE_LENGTH", baseline_digest,
                                 changed_digest);
    removed_byte = image.bytes.pop_back();
    image.length--;
    if (removed_byte != 8'h6b)
      `uvm_error("IMAGE_LENGTH", "image byte queue restore drifted")
    image.alignment++;
    changed_digest = digest_image_schema("IMAGE_ALIGNMENT", image);
    expect_schema_digest_changed("IMAGE_ALIGNMENT", baseline_digest,
                                 changed_digest);
    image.alignment--;
    image.endian = RDMA_ENDIAN_LITTLE;
    changed_digest = digest_image_schema("IMAGE_ENDIAN", image);
    expect_schema_digest_changed("IMAGE_ENDIAN", baseline_digest,
                                 changed_digest);
    image.endian = RDMA_ENDIAN_BIG;
    image.image_kind = RDMA_IMAGE_CQC;
    changed_digest = digest_image_schema("IMAGE_KIND", image);
    expect_schema_digest_changed("IMAGE_KIND", baseline_digest,
                                 changed_digest);
    image.image_kind = RDMA_IMAGE_CMQ_SQE;
    image.hardware_version++;
    changed_digest = digest_image_schema("IMAGE_HW_VERSION", image);
    expect_schema_digest_changed("IMAGE_HW_VERSION", baseline_digest,
                                 changed_digest);
    image.hardware_version--;
    image.function_generation++;
    changed_digest = digest_image_schema("IMAGE_FUNCTION_GENERATION", image);
    expect_schema_digest_changed("IMAGE_FUNCTION_GENERATION",
                                 baseline_digest, changed_digest);
    image.function_generation--;
    image.write_target_kind = RDMA_HW_TARGET_BACKING;
    changed_digest = digest_image_schema("IMAGE_TARGET_KIND", image);
    expect_schema_digest_changed("IMAGE_TARGET_KIND", baseline_digest,
                                 changed_digest);
    image.write_target_kind = RDMA_HW_TARGET_NONE;
    image.backing_target.value++;
    changed_digest = digest_image_schema("IMAGE_BACKING_TARGET", image);
    expect_schema_digest_changed("IMAGE_BACKING_TARGET", baseline_digest,
                                 changed_digest);
    image.backing_target.value--;
    image.hmc_target.value++;
    changed_digest = digest_image_schema("IMAGE_HMC_TARGET", image);
    expect_schema_digest_changed("IMAGE_HMC_TARGET", baseline_digest,
                                 changed_digest);
    image.hmc_target.value--;
    image.bar_target.value++;
    changed_digest = digest_image_schema("IMAGE_BAR_TARGET", image);
    expect_schema_digest_changed("IMAGE_BAR_TARGET", baseline_digest,
                                 changed_digest);
    image.bar_target.value--;
    image.bytes[0] ^= 8'h01;
    changed_digest = digest_image_schema("IMAGE_BYTES", image);
    expect_schema_digest_changed("IMAGE_BYTES", baseline_digest,
                                 changed_digest);
    image.bytes[0] ^= 8'h01;
    image.field_summary[0] = "schema-field-mutated";
    changed_digest = digest_image_schema("IMAGE_SUMMARY_VALUE", image);
    expect_schema_digest_changed("IMAGE_SUMMARY_VALUE", baseline_digest,
                                 changed_digest);
    image.field_summary[0] = "schema-field";
    image.field_summary.push_back("schema-field-2");
    changed_digest = digest_image_schema("IMAGE_SUMMARY_COUNT", image);
    expect_schema_digest_changed("IMAGE_SUMMARY_COUNT", baseline_digest,
                                 changed_digest);
    void'(image.field_summary.pop_back());

    command = rdma_cmq_command_desc::type_id::create(
      "command_schema_command"
    );
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 64'h0102_0304_0506_0708;
    command.recovery_owner = owner;
    body_bytes = new[0];
    baseline_digest = digest_command_schema(
      "COMMAND_BASELINE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    command.function_h.object_id++;
    changed_digest = digest_command_schema(
      "COMMAND_FUNCTION", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_FUNCTION", baseline_digest,
                                 changed_digest);
    command.function_h.object_id--;
    command.opcode_key.opcode++;
    changed_digest = digest_command_schema(
      "COMMAND_OPCODE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_OPCODE", baseline_digest,
                                 changed_digest);
    command.opcode_key.opcode--;
    changed_digest = digest_command_schema(
      "COMMAND_BODY_TAG", command, "CMQ-BODY-OCC-FLUSH-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_BODY_TAG", baseline_digest,
                                 changed_digest);
    body_bytes = '{8'ha5};
    changed_digest = digest_command_schema(
      "COMMAND_BODY_BYTES", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_BODY_BYTES", baseline_digest,
                                 changed_digest);
    body_bytes = new[0];
    signature_image = make_image(
      "command_signature", RDMA_IMAGE_QPC, 8, TEST_GENERATION
    );
    command.qpc_signature_source = signature_image;
    changed_digest = digest_command_schema(
      "COMMAND_SIGNATURE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_SIGNATURE", baseline_digest,
                                 changed_digest);
    command.qpc_signature_source = null;
    command.vfid_override = 1'b0;
    changed_digest = digest_command_schema(
      "COMMAND_VFID_OVERRIDE", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_VFID_OVERRIDE", baseline_digest,
                                 changed_digest);
    command.vfid_override = 1'b1;
    command.use_vfid++;
    changed_digest = digest_command_schema(
      "COMMAND_USE_VFID", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_USE_VFID", baseline_digest,
                                 changed_digest);
    command.use_vfid--;
    command.timeout++;
    changed_digest = digest_command_schema(
      "COMMAND_TIMEOUT", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_TIMEOUT", baseline_digest,
                                 changed_digest);
    command.timeout--;
    command.recovery_owner.transaction_id++;
    changed_digest = digest_command_schema(
      "COMMAND_OWNER", command, "CMQ-BODY-EMPTY-V1", body_bytes
    );
    expect_schema_digest_changed("COMMAND_OWNER", baseline_digest,
                                 changed_digest);
    command.recovery_owner.transaction_id--;

    ticket = make_ticket(
      "ticket_schema_ticket", function_h, cmq_h, key
    );
    baseline_digest = digest_ticket_schema("TICKET_BASELINE", ticket);
    ticket.command_id++;
    changed_digest = digest_ticket_schema("TICKET_COMMAND_ID", ticket);
    expect_schema_digest_changed("TICKET_COMMAND_ID", baseline_digest,
                                 changed_digest);
    ticket.command_id--;
    ticket.function_h.object_id++;
    changed_digest = digest_ticket_schema("TICKET_FUNCTION", ticket);
    expect_schema_digest_changed("TICKET_FUNCTION", baseline_digest,
                                 changed_digest);
    ticket.function_h.object_id--;
    ticket.cmq_h.object_id++;
    changed_digest = digest_ticket_schema("TICKET_CMQ", ticket);
    expect_schema_digest_changed("TICKET_CMQ", baseline_digest,
                                 changed_digest);
    ticket.cmq_h.object_id--;
    ticket.slot_sequence += 64;
    changed_digest = digest_ticket_schema("TICKET_SEQUENCE", ticket);
    expect_schema_digest_changed("TICKET_SEQUENCE", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence -= 64;
    ticket.slot_sequence++;
    ticket.sq_index++;
    changed_digest = digest_ticket_schema("TICKET_SQ_INDEX", ticket);
    expect_schema_digest_changed("TICKET_SQ_INDEX", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence--;
    ticket.sq_index--;
    ticket.slot_sequence += 32;
    ticket.sq_wrap ^= 1'b1;
    changed_digest = digest_ticket_schema("TICKET_SQ_WRAP", ticket);
    expect_schema_digest_changed("TICKET_SQ_WRAP", baseline_digest,
                                 changed_digest);
    ticket.slot_sequence -= 32;
    ticket.sq_wrap ^= 1'b1;
    ticket.opcode_key.opcode++;
    changed_digest = digest_ticket_schema("TICKET_OPCODE", ticket);
    expect_schema_digest_changed("TICKET_OPCODE", baseline_digest,
                                 changed_digest);
    ticket.opcode_key.opcode--;
    ticket.absolute_deadline++;
    changed_digest = digest_ticket_schema("TICKET_DEADLINE", ticket);
    expect_schema_digest_changed("TICKET_DEADLINE", baseline_digest,
                                 changed_digest);
    ticket.absolute_deadline--;
  endfunction

  // 功能：逐字段变更 DMA-CONTEXT、DMA-MAPPING-PUBLIC 与 FUNCTION-BINDING
  //   V1 fixture，覆盖 nested BDF、六个 BAR、全部 capability 和 vector entry。
  // 输入/输出及副作用：无显式输入；只修改本地 fixture，并在每次编码后恢复基线。
  // 失败/边界：PASID-valid mutation 使用 pasid=0 的合法子基线；任一合法字段变化
  //   被 encoder 拒绝或未改变 digest，以及 identity 重配置失败时报告 UVM_ERROR。
  function automatic void check_dma_binding_schema_field_mutations();
    rdma_function_identity identity;
    rdma_function_identity changed_identity;
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_function_binding binding;
    rdma_interrupt_vector_binding vector;
    rdma_interrupt_vector_binding saved_vector;
    bit [19:0] saved_pasid;
    rdma_status status;
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t field_baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    string label;

    identity = make_identity("dma_schema_identity");
    dma_context = make_dma_context("dma_schema_context", identity);
    baseline_digest = digest_dma_context_schema(
      "DMA_CONTEXT_BASELINE", dma_context
    );
    dma_context.function_h.object_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_FUNCTION", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_FUNCTION", baseline_digest,
                                 changed_digest);
    dma_context.function_h.object_id--;
    dma_context.requester_bdf.bus++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_REQUESTER", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_REQUESTER", baseline_digest,
                                 changed_digest);
    dma_context.requester_bdf.bus--;

    saved_pasid = dma_context.pasid;
    dma_context.pasid = 0;
    field_baseline_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID_VALID_BASELINE", dma_context
    );
    dma_context.pasid_valid = 1'b0;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_PASID_VALID",
                                 field_baseline_digest, changed_digest);
    dma_context.pasid_valid = 1'b1;
    dma_context.pasid = saved_pasid;
    dma_context.pasid++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_PASID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_PASID", baseline_digest,
                                 changed_digest);
    dma_context.pasid--;
    dma_context.dma_domain_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_DOMAIN_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    dma_context.dma_domain_valid ^= 1'b1;
    dma_context.dma_domain_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_DOMAIN_ID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    dma_context.dma_domain_id--;
    dma_context.route.host_topology_key++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROUTE", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROUTE", baseline_digest,
                                 changed_digest);
    dma_context.route.host_topology_key--;
    dma_context.reset_epoch++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_RESET_EPOCH", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    dma_context.reset_epoch--;
    dma_context.route_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROUTE_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROUTE_VALID", baseline_digest,
                                 changed_digest);
    dma_context.route_valid ^= 1'b1;
    dma_context.epoch_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_EPOCH_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_EPOCH_VALID", baseline_digest,
                                 changed_digest);
    dma_context.epoch_valid ^= 1'b1;
    dma_context.owner_h.object_id++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_OWNER", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_OWNER", baseline_digest,
                                 changed_digest);
    dma_context.owner_h.object_id--;
    dma_context.queue_role_valid ^= 1'b1;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROLE_VALID", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROLE_VALID", baseline_digest,
                                 changed_digest);
    dma_context.queue_role_valid ^= 1'b1;
    dma_context.queue_role++;
    changed_digest = digest_dma_context_schema(
      "DMA_CONTEXT_ROLE", dma_context
    );
    expect_schema_digest_changed("DMA_CONTEXT_ROLE", baseline_digest,
                                 changed_digest);
    dma_context.queue_role--;

    mapping = make_mapping("dma_schema_mapping", identity);
    baseline_digest = digest_mapping_schema("MAPPING_BASELINE", mapping);
    mapping.function_h.object_id++;
    changed_digest = digest_mapping_schema("MAPPING_FUNCTION", mapping);
    expect_schema_digest_changed("MAPPING_FUNCTION", baseline_digest,
                                 changed_digest);
    mapping.function_h.object_id--;
    mapping.requester_bdf.bus++;
    changed_digest = digest_mapping_schema("MAPPING_REQUESTER", mapping);
    expect_schema_digest_changed("MAPPING_REQUESTER", baseline_digest,
                                 changed_digest);
    mapping.requester_bdf.bus--;

    saved_pasid = mapping.pasid;
    mapping.pasid = 0;
    field_baseline_digest = digest_mapping_schema(
      "MAPPING_PASID_VALID_BASELINE", mapping
    );
    mapping.pasid_valid = 1'b0;
    changed_digest = digest_mapping_schema("MAPPING_PASID_VALID", mapping);
    expect_schema_digest_changed("MAPPING_PASID_VALID",
                                 field_baseline_digest, changed_digest);
    mapping.pasid_valid = 1'b1;
    mapping.pasid = saved_pasid;
    mapping.pasid++;
    changed_digest = digest_mapping_schema("MAPPING_PASID", mapping);
    expect_schema_digest_changed("MAPPING_PASID", baseline_digest,
                                 changed_digest);
    mapping.pasid--;
    mapping.dma_domain_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_DOMAIN_VALID", mapping);
    expect_schema_digest_changed("MAPPING_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    mapping.dma_domain_valid ^= 1'b1;
    mapping.dma_domain_id++;
    changed_digest = digest_mapping_schema("MAPPING_DOMAIN_ID", mapping);
    expect_schema_digest_changed("MAPPING_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    mapping.dma_domain_id--;
    mapping.route.host_topology_key++;
    changed_digest = digest_mapping_schema("MAPPING_ROUTE", mapping);
    expect_schema_digest_changed("MAPPING_ROUTE", baseline_digest,
                                 changed_digest);
    mapping.route.host_topology_key--;
    mapping.reset_epoch++;
    changed_digest = digest_mapping_schema("MAPPING_RESET_EPOCH", mapping);
    expect_schema_digest_changed("MAPPING_RESET_EPOCH", baseline_digest,
                                 changed_digest);
    mapping.reset_epoch--;
    mapping.route_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_ROUTE_VALID", mapping);
    expect_schema_digest_changed("MAPPING_ROUTE_VALID", baseline_digest,
                                 changed_digest);
    mapping.route_valid ^= 1'b1;
    mapping.epoch_valid ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_EPOCH_VALID", mapping);
    expect_schema_digest_changed("MAPPING_EPOCH_VALID", baseline_digest,
                                 changed_digest);
    mapping.epoch_valid ^= 1'b1;
    mapping.backing_addr.value++;
    changed_digest = digest_mapping_schema("MAPPING_BACKING", mapping);
    expect_schema_digest_changed("MAPPING_BACKING", baseline_digest,
                                 changed_digest);
    mapping.backing_addr.value--;
    mapping.iova.value++;
    changed_digest = digest_mapping_schema("MAPPING_IOVA", mapping);
    expect_schema_digest_changed("MAPPING_IOVA", baseline_digest,
                                 changed_digest);
    mapping.iova.value--;
    mapping.size++;
    changed_digest = digest_mapping_schema("MAPPING_SIZE", mapping);
    expect_schema_digest_changed("MAPPING_SIZE", baseline_digest,
                                 changed_digest);
    mapping.size--;
    mapping.direction = RDMA_DMA_DEVICE_WRITE;
    changed_digest = digest_mapping_schema("MAPPING_DIRECTION", mapping);
    expect_schema_digest_changed("MAPPING_DIRECTION", baseline_digest,
                                 changed_digest);
    mapping.direction = RDMA_DMA_DEVICE_READ;
    mapping.permissions.device_read ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_READ_PERMISSION", mapping);
    expect_schema_digest_changed("MAPPING_READ_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.device_read ^= 1'b1;
    mapping.permissions.device_write ^= 1'b1;
    changed_digest = digest_mapping_schema(
      "MAPPING_WRITE_PERMISSION", mapping
    );
    expect_schema_digest_changed("MAPPING_WRITE_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.device_write ^= 1'b1;
    mapping.permissions.atomic ^= 1'b1;
    changed_digest = digest_mapping_schema(
      "MAPPING_ATOMIC_PERMISSION", mapping
    );
    expect_schema_digest_changed("MAPPING_ATOMIC_PERMISSION", baseline_digest,
                                 changed_digest);
    mapping.permissions.atomic ^= 1'b1;
    mapping.state = RDMA_MAPPING_FROZEN;
    changed_digest = digest_mapping_schema("MAPPING_STATE", mapping);
    expect_schema_digest_changed("MAPPING_STATE", baseline_digest,
                                 changed_digest);
    mapping.state = RDMA_MAPPING_ACTIVE;
    mapping.owner_h.object_id++;
    changed_digest = digest_mapping_schema("MAPPING_OWNER", mapping);
    expect_schema_digest_changed("MAPPING_OWNER", baseline_digest,
                                 changed_digest);
    mapping.owner_h.object_id--;
    mapping.umem_backed ^= 1'b1;
    changed_digest = digest_mapping_schema("MAPPING_UMEM_BACKED", mapping);
    expect_schema_digest_changed("MAPPING_UMEM_BACKED", baseline_digest,
                                 changed_digest);
    mapping.umem_backed ^= 1'b1;
    mapping.umem_page_count++;
    changed_digest = digest_mapping_schema("MAPPING_UMEM_PAGES", mapping);
    expect_schema_digest_changed("MAPPING_UMEM_PAGES", baseline_digest,
                                 changed_digest);
    mapping.umem_page_count--;

    binding = make_binding("schema_binding", identity);
    baseline_digest = digest_binding_schema("BINDING_BASELINE", binding);
    binding.function_uid++;
    changed_digest = digest_binding_schema("BINDING_FUNCTION_UID", binding);
    expect_schema_digest_changed("BINDING_FUNCTION_UID", baseline_digest,
                                 changed_digest);
    binding.function_uid--;
    changed_identity = make_identity("schema_binding_changed_identity");
    changed_identity.reset_epoch++;
    status = binding.configure_identity(changed_identity);
    expect_status("BINDING_IDENTITY_CONFIGURE", status, RDMA_SC_OK);
    changed_digest = digest_binding_schema("BINDING_IDENTITY", binding);
    expect_schema_digest_changed("BINDING_IDENTITY", baseline_digest,
                                 changed_digest);
    status = binding.configure_identity(identity);
    expect_status("BINDING_IDENTITY_RESTORE", status, RDMA_SC_OK);

    binding.pcie.bdf.segment++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_SEGMENT", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.segment--;
    binding.pcie.bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.bus--;
    binding.pcie.bdf.device++;
    changed_digest = digest_binding_schema("BINDING_PCIE_BDF_DEVICE", binding);
    expect_schema_digest_changed("BINDING_PCIE_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    binding.pcie.bdf.device--;
    binding.pcie.bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_PCIE_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_PCIE_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.pcie.bdf.function_num--;

    binding.pcie.parent_pf_bdf.segment++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_SEGMENT", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_SEGMENT",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.segment--;
    binding.pcie.parent_pf_bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_PARENT_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_PARENT_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.pcie.parent_pf_bdf.bus--;
    binding.pcie.parent_pf_bdf.device++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_DEVICE", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_DEVICE",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.device--;
    binding.pcie.parent_pf_bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_PARENT_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_PARENT_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.pcie.parent_pf_bdf.function_num--;
    binding.pcie.vf_index++;
    changed_digest = digest_binding_schema("BINDING_VF_INDEX", binding);
    expect_schema_digest_changed("BINDING_VF_INDEX", baseline_digest,
                                 changed_digest);
    binding.pcie.vf_index--;
    binding.pcie.mse ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_MSE", binding);
    expect_schema_digest_changed("BINDING_MSE", baseline_digest,
                                 changed_digest);
    binding.pcie.mse ^= 1'b1;
    binding.pcie.bme ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_BME", binding);
    expect_schema_digest_changed("BINDING_BME", baseline_digest,
                                 changed_digest);
    binding.pcie.bme ^= 1'b1;

    foreach (binding.pcie.bar[i]) begin
      label = $sformatf("BINDING_BAR_%0d_ID", i);
      binding.pcie.bar[i].bar_id++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].bar_id--;
      label = $sformatf("BINDING_BAR_%0d_BASE", i);
      binding.pcie.bar[i].base.value++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].base.value--;
      label = $sformatf("BINDING_BAR_%0d_SIZE", i);
      binding.pcie.bar[i].size++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].size--;
      label = $sformatf("BINDING_BAR_%0d_ENABLED", i);
      binding.pcie.bar[i].enabled ^= 1'b1;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.pcie.bar[i].enabled ^= 1'b1;
    end

    binding.notify_bar_id++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_BAR", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_BAR", baseline_digest,
                                 changed_digest);
    binding.notify_bar_id--;
    binding.notify_base.value++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_BASE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_BASE", baseline_digest,
                                 changed_digest);
    binding.notify_base.value--;
    binding.notify_size++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_SIZE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_SIZE", baseline_digest,
                                 changed_digest);
    binding.notify_size--;
    binding.notify_table_sel++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_TABLE", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_TABLE", baseline_digest,
                                 changed_digest);
    binding.notify_table_sel--;
    binding.notify_table_index++;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_INDEX", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_INDEX", baseline_digest,
                                 changed_digest);
    binding.notify_table_index--;
    binding.host_id++;
    changed_digest = digest_binding_schema("BINDING_HOST_ID", binding);
    expect_schema_digest_changed("BINDING_HOST_ID", baseline_digest,
                                 changed_digest);
    binding.host_id--;
    binding.pfvf_id++;
    changed_digest = digest_binding_schema("BINDING_PFVF_ID", binding);
    expect_schema_digest_changed("BINDING_PFVF_ID", baseline_digest,
                                 changed_digest);
    binding.pfvf_id--;
    binding.rdma_vf_id++;
    changed_digest = digest_binding_schema("BINDING_RDMA_VF_ID", binding);
    expect_schema_digest_changed("BINDING_RDMA_VF_ID", baseline_digest,
                                 changed_digest);
    binding.rdma_vf_id--;
    binding.global_function_id++;
    changed_digest = digest_binding_schema("BINDING_GLOBAL_ID", binding);
    expect_schema_digest_changed("BINDING_GLOBAL_ID", baseline_digest,
                                 changed_digest);
    binding.global_function_id--;
    binding.vsi_id++;
    changed_digest = digest_binding_schema("BINDING_VSI_ID", binding);
    expect_schema_digest_changed("BINDING_VSI_ID", baseline_digest,
                                 changed_digest);
    binding.vsi_id--;

    binding.queue_dma.requester_bdf.segment++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_SEGMENT", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_SEGMENT", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.segment--;
    binding.queue_dma.requester_bdf.bus++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_BUS", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_BUS", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.bus--;
    binding.queue_dma.requester_bdf.device++;
    changed_digest = digest_binding_schema("BINDING_DMA_BDF_DEVICE", binding);
    expect_schema_digest_changed("BINDING_DMA_BDF_DEVICE", baseline_digest,
                                 changed_digest);
    binding.queue_dma.requester_bdf.device--;
    binding.queue_dma.requester_bdf.function_num++;
    changed_digest = digest_binding_schema(
      "BINDING_DMA_BDF_FUNCTION", binding
    );
    expect_schema_digest_changed("BINDING_DMA_BDF_FUNCTION",
                                 baseline_digest, changed_digest);
    binding.queue_dma.requester_bdf.function_num--;
    binding.queue_dma.pasid_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMA_PASID_VALID", binding);
    expect_schema_digest_changed("BINDING_DMA_PASID_VALID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.pasid_valid ^= 1'b1;
    binding.queue_dma.pasid++;
    changed_digest = digest_binding_schema("BINDING_DMA_PASID", binding);
    expect_schema_digest_changed("BINDING_DMA_PASID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.pasid--;
    binding.queue_dma.dma_domain_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMA_DOMAIN_VALID", binding);
    expect_schema_digest_changed("BINDING_DMA_DOMAIN_VALID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.dma_domain_valid ^= 1'b1;
    binding.queue_dma.dma_domain_id++;
    changed_digest = digest_binding_schema("BINDING_DMA_DOMAIN_ID", binding);
    expect_schema_digest_changed("BINDING_DMA_DOMAIN_ID", baseline_digest,
                                 changed_digest);
    binding.queue_dma.dma_domain_id--;

    binding.queue_caps.min_cq_depth++;
    changed_digest = digest_binding_schema("BINDING_MIN_CQ", binding);
    expect_schema_digest_changed("BINDING_MIN_CQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.min_cq_depth--;
    binding.queue_caps.max_cq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_CQ", binding);
    expect_schema_digest_changed("BINDING_MAX_CQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_cq_depth--;
    binding.queue_caps.min_srq_depth++;
    changed_digest = digest_binding_schema("BINDING_MIN_SRQ", binding);
    expect_schema_digest_changed("BINDING_MIN_SRQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.min_srq_depth--;
    binding.queue_caps.max_srq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_SRQ", binding);
    expect_schema_digest_changed("BINDING_MAX_SRQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_srq_depth--;
    binding.queue_caps.max_ceq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_CEQ", binding);
    expect_schema_digest_changed("BINDING_MAX_CEQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_ceq_depth--;
    binding.queue_caps.max_aeq_depth++;
    changed_digest = digest_binding_schema("BINDING_MAX_AEQ", binding);
    expect_schema_digest_changed("BINDING_MAX_AEQ", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_aeq_depth--;
    binding.queue_caps.max_wq_sge++;
    changed_digest = digest_binding_schema("BINDING_MAX_WQ_SGE", binding);
    expect_schema_digest_changed("BINDING_MAX_WQ_SGE", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_wq_sge--;
    binding.queue_caps.max_queue_ring_bytes++;
    changed_digest = digest_binding_schema("BINDING_MAX_RING", binding);
    expect_schema_digest_changed("BINDING_MAX_RING", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_queue_ring_bytes--;
    binding.queue_caps.max_sgb_bytes++;
    changed_digest = digest_binding_schema("BINDING_MAX_SGB", binding);
    expect_schema_digest_changed("BINDING_MAX_SGB", baseline_digest,
                                 changed_digest);
    binding.queue_caps.max_sgb_bytes--;

    foreach (binding.interrupt_vectors[i]) begin
      label = $sformatf("BINDING_VECTOR_%0d_LOCAL", i);
      binding.interrupt_vectors[i].function_local_vector++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].function_local_vector--;
      label = $sformatf("BINDING_VECTOR_%0d_HARDWARE", i);
      binding.interrupt_vectors[i].hardware_eq_vector++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].hardware_eq_vector--;
      label = $sformatf("BINDING_VECTOR_%0d_MSIX", i);
      binding.interrupt_vectors[i].msix_table_index++;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].msix_table_index--;
      label = $sformatf("BINDING_VECTOR_%0d_ENABLED", i);
      binding.interrupt_vectors[i].enabled ^= 1'b1;
      changed_digest = digest_binding_schema(label, binding);
      expect_schema_digest_changed(label, baseline_digest, changed_digest);
      binding.interrupt_vectors[i].enabled ^= 1'b1;
    end
    saved_vector = binding.interrupt_vectors[0];
    binding.interrupt_vectors[0] = binding.interrupt_vectors[1];
    binding.interrupt_vectors[1] = saved_vector;
    changed_digest = digest_binding_schema("BINDING_VECTOR_ORDER", binding);
    expect_schema_digest_changed("BINDING_VECTOR_ORDER", baseline_digest,
                                 changed_digest);
    saved_vector = binding.interrupt_vectors[0];
    binding.interrupt_vectors[0] = binding.interrupt_vectors[1];
    binding.interrupt_vectors[1] = saved_vector;
    vector = '{
      function_local_vector:32'd9,
      hardware_eq_vector:32'd29,
      msix_table_index:32'd19,
      enabled:1'b1
    };
    binding.interrupt_vectors.push_back(vector);
    changed_digest = digest_binding_schema("BINDING_VECTOR_COUNT", binding);
    expect_schema_digest_changed("BINDING_VECTOR_COUNT", baseline_digest,
                                 changed_digest);
    void'(binding.interrupt_vectors.pop_back());

    binding.state = RDMA_BIND_ERROR;
    changed_digest = digest_binding_schema("BINDING_STATE", binding);
    expect_schema_digest_changed("BINDING_STATE", baseline_digest,
                                 changed_digest);
    binding.state = RDMA_BIND_ACTIVE;
    binding.generation++;
    changed_digest = digest_binding_schema("BINDING_GENERATION", binding);
    expect_schema_digest_changed("BINDING_GENERATION", baseline_digest,
                                 changed_digest);
    binding.generation--;
    binding.owner_h.object_id++;
    changed_digest = digest_binding_schema("BINDING_OWNER", binding);
    expect_schema_digest_changed("BINDING_OWNER", baseline_digest,
                                 changed_digest);
    binding.owner_h.object_id--;
    binding.notify_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_VALID", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_VALID", baseline_digest,
                                 changed_digest);
    binding.notify_valid ^= 1'b1;
    binding.notify_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_NOTIFY_READY", binding);
    expect_schema_digest_changed("BINDING_NOTIFY_READY", baseline_digest,
                                 changed_digest);
    binding.notify_ready ^= 1'b1;
    binding.dmi_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMI_VALID", binding);
    expect_schema_digest_changed("BINDING_DMI_VALID", baseline_digest,
                                 changed_digest);
    binding.dmi_valid ^= 1'b1;
    binding.dmi_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_DMI_READY", binding);
    expect_schema_digest_changed("BINDING_DMI_READY", baseline_digest,
                                 changed_digest);
    binding.dmi_ready ^= 1'b1;
    binding.vft_valid ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_VFT_VALID", binding);
    expect_schema_digest_changed("BINDING_VFT_VALID", baseline_digest,
                                 changed_digest);
    binding.vft_valid ^= 1'b1;
    binding.vft_ready ^= 1'b1;
    changed_digest = digest_binding_schema("BINDING_VFT_READY", binding);
    expect_schema_digest_changed("BINDING_VFT_READY", baseline_digest,
                                 changed_digest);
    binding.vft_ready ^= 1'b1;
  endfunction

  // 功能：逐一验证 FUNCTION-BINDING-V1 拒绝 state=9..15 的未分配编码，防止
  //   删除或放宽 RDMA_BIND_ERROR 上界后把 spare state 固化进 journal authority。
  // 输入/输出及副作用：无显式输入；每轮构造新 writer、预置 8'ha5，并比较调用前后字节。
  // 失败/边界：任一 spare state 被接受或使失败 writer 发生部分追加时发布 UVM_ERROR；
  //   合法 0..8 状态仍由逐字段 schema mutation 检查覆盖。
  function automatic void check_binding_spare_state_canonicalization();
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_cmq_canonical_writer writer;
    byte unsigned before_bytes[];
    byte unsigned after_bytes[];
    string label;
    bit encoded;

    identity = make_identity("binding_spare_identity");
    binding = make_binding("binding_spare", identity);

    for (int unsigned state_value = 9; state_value <= 15; state_value++) begin
      label = $sformatf("BINDING_SPARE_STATE_%0d", state_value);
      binding.state = rdma_binding_state_e'(state_value);
      writer = new();
      if (!writer.append_u8(8'ha5)) begin
        `uvm_error(label, "failed to seed canonical writer sentinel")
        continue;
      end
      writer.snapshot(before_bytes);
      encoded = rdma_cmq_append_function_binding_v1(writer, binding);
      writer.snapshot(after_bytes);

      if (encoded)
        `uvm_error(label, "spare binding state was canonicalized")
      expect_bytes(label, after_bytes, before_bytes);
    end
  endfunction

  // 功能：验证 FNV 已知答案、item 双域 literal golden、字段覆盖和 opaque authority 分离。
  // 输入/输出及副作用：无显式输入；构造 request-owned 图并反复独立计算 digest。
  // 失败/边界：null/长度漂移/owner 不一致不发布 digest；private token 不进入公开字节，
  //   schema/domain/header/顺序或宽度漂移必须偏离仓库外手算的两个 256-bit literal。
  function automatic void check_journal_digest_contract();
    byte unsigned digest_bytes[];
    byte unsigned body_bytes[];
    rdma_function_identity identity;
    rdma_cmq_recovery_owner owner;
    rdma_cmq_recovery_owner mismatched_owner;
    rdma_function_handle function_h;
    rdma_handle cmq_h;
    rdma_cmq_opcode_key key;
    rdma_cmq_sqe_model body;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_dma_request_context dma_context;
    rdma_dma_mapping mapping;
    rdma_hw_image sqe_image;
    rdma_hw_image dependency_image;
    rdma_cmq_journal_digest_t image_digest;
    rdma_cmq_journal_digest_t authority_digest;
    rdma_cmq_journal_digest_t baseline_image_digest;
    rdma_cmq_journal_digest_t baseline_authority_digest;
    rdma_cmq_journal_digest_t second_image_digest;
    rdma_cmq_journal_digest_t second_authority_digest;
    rdma_mock_dma_mapping first_private_mapping;
    rdma_mock_dma_mapping second_private_mapping;
    rdma_mock_release_seal first_seal;
    rdma_mock_release_seal second_seal;
    rdma_status status;

    digest_bytes = new[0];
    expect_digest(
      "DIGEST_EMPTY",
      digest_bytes,
      256'hd6e8feb86659fd939e3779b97f4a7c1584222325cbf29ce4cbf29ce484222325
    );
    digest_bytes = '{8'h00, 8'h01, 8'h7f, 8'h80, 8'hff};
    expect_digest(
      "DIGEST_ASYMMETRIC",
      digest_bytes,
      256'hc4dd9f5b971ab9405e8f446e17f9bf86a7d453fabd35e4b5a5bcd1d1065f84b6
    );
    check_canonical_writer_contract();

    identity = make_identity("digest_identity");
    owner = make_owner(
      "digest_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("DIGEST_OWNER_FREEZE",
                  owner.freeze_for_journal(identity, 37), RDMA_SC_OK);
    function_h = make_function("digest_function");
    cmq_h = make_cmq("digest_cmq", function_h);
    key = make_key("digest_key");
    body = make_body("digest_body", function_h, cmq_h);
    command = rdma_cmq_command_desc::type_id::create("digest_command");
    command.function_h = function_h;
    command.opcode_key = key;
    command.body = body;
    command.qpc_signature_source = null;
    command.vfid_override = 1'b1;
    command.use_vfid = 11'h345;
    command.timeout = 64'h0102_0304_0506_0708;
    command.recovery_owner = owner;
    ticket = make_ticket("digest_ticket", function_h, cmq_h, key);
    dma_context = make_dma_context("digest_dma_context", identity);
    mapping = make_mapping("digest_mapping", identity);
    sqe_image = make_image(
      "digest_sqe", RDMA_IMAGE_CMQ_SQE, 64, TEST_GENERATION
    );
    sqe_image.field_summary.push_back("sqe-field");
    dependency_image = make_image(
      "digest_dependency", RDMA_IMAGE_CQC, 8, TEST_GENERATION
    );
    dependency_image.field_summary.push_back("dependency-field");
    body_bytes = new[0];

    status = rdma_cmq_compute_item_digests(
      command,
      "CMQ-BODY-EMPTY-V1",
      body_bytes,
      ticket,
      owner,
      identity,
      dma_context,
      sqe_image,
      mapping,
      64'h1020_3040_5060_7080,
      dependency_image,
      baseline_image_digest,
      baseline_authority_digest
    );
    expect_status("ITEM_DIGEST_BASELINE", status, RDMA_SC_OK);
    expect_digest_value(
      "ITEM_IMAGE_GOLDEN",
      baseline_image_digest,
      256'hffba8058_ff68e14c_321bf650_07c3bc02_4cdbd6c6_a065f317_801a4d57_bc178a12
    );
    expect_digest_value(
      "ITEM_AUTHORITY_GOLDEN",
      baseline_authority_digest,
      256'hc6e16ef0_cd315821_86165b8b_a6c07b23_254b32aa_cfd33588_36b7067c_be6b9913
    );

    status = rdma_cmq_compute_item_digests(
      command,
      "CMQ-BODY-EMPTY-V1",
      body_bytes,
      ticket,
      owner,
      identity,
      dma_context,
      sqe_image,
      mapping,
      64'h1020_3040_5060_7080,
      dependency_image,
      image_digest,
      authority_digest
    );
    expect_status("ITEM_DIGEST_REPEAT", status, RDMA_SC_OK);
    if (image_digest != baseline_image_digest ||
        authority_digest != baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_REPEAT", "same graph was not deterministic")

    sqe_image.bytes[0] ^= 8'h01;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_SQE_BYTE", status, RDMA_SC_OK);
    if (image_digest == baseline_image_digest ||
        authority_digest != baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_SQE_BYTE", "image domain coverage drifted")
    sqe_image.bytes[0] ^= 8'h01;

    dependency_image.alignment++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DEPENDENCY_METADATA", status, RDMA_SC_OK);
    if (image_digest == baseline_image_digest)
      `uvm_error("ITEM_DIGEST_DEPENDENCY_METADATA",
                 "dependency metadata was omitted")
    dependency_image.alignment--;

    command.opcode_key.opcode++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_COMMAND_OPCODE", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_COMMAND_OPCODE", "command opcode was omitted")
    command.opcode_key.opcode--;

    body_bytes = '{8'ha5};
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_BODY_BYTES", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_BODY_BYTES", "body bytes were omitted")
    body_bytes = new[0];

    ticket.command_id++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_TICKET", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_TICKET", "ticket identity was omitted")
    ticket.command_id--;

    owner.transaction_id++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_OWNER", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_OWNER", "recovery owner was omitted")
    owner.transaction_id--;

    dma_context.queue_role++;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DMA_CONTEXT", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_DMA_CONTEXT", "DMA context field was omitted")
    dma_context.queue_role--;

    mapping.iova.value += 64'h1000;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_MAPPING", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_MAPPING", "public mapping field was omitted")
    mapping.iova.value -= 64'h1000;

    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7081, dependency_image,
      image_digest, authority_digest
    );
    expect_status("ITEM_DIGEST_DEPENDENCY_OFFSET", status, RDMA_SC_OK);
    if (authority_digest == baseline_authority_digest)
      `uvm_error("ITEM_DIGEST_DEPENDENCY_OFFSET", "offset was omitted")

    mismatched_owner = make_owner(
      "mismatched_digest_owner", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    expect_status("MISMATCHED_OWNER_FREEZE",
                  mismatched_owner.freeze_for_journal(identity, 37),
                  RDMA_SC_OK);
    image_digest = '1;
    authority_digest = '1;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket,
      mismatched_owner, identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    if (status == null || status.ok() || image_digest != '0 ||
        authority_digest != '0)
      `uvm_error("ITEM_DIGEST_OWNER_MISMATCH",
                 "owner mismatch published a partial digest")

    dependency_image.length++;
    image_digest = '1;
    authority_digest = '1;
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    if (status == null || status.ok() || image_digest != '0 ||
        authority_digest != '0)
      `uvm_error("ITEM_DIGEST_BAD_IMAGE",
                 "malformed image published a partial digest")
    dependency_image.length--;

    first_private_mapping = new("first_private_mapping");
    second_private_mapping = new("second_private_mapping");
    first_seal = new("first_private_seal");
    second_seal = new("second_private_seal");
    expect_status("PRIVATE_MAPPING_FIRST_TOKEN",
                  first_private_mapping.initialize_allocation_token(first_seal),
                  RDMA_SC_OK);
    expect_status("PRIVATE_MAPPING_SECOND_TOKEN",
                  second_private_mapping.initialize_allocation_token(second_seal),
                  RDMA_SC_OK);
    first_private_mapping.function_h = mapping.function_h;
    first_private_mapping.requester_bdf = mapping.requester_bdf;
    first_private_mapping.pasid_valid = mapping.pasid_valid;
    first_private_mapping.pasid = mapping.pasid;
    first_private_mapping.dma_domain_valid = mapping.dma_domain_valid;
    first_private_mapping.dma_domain_id = mapping.dma_domain_id;
    first_private_mapping.route = mapping.route;
    first_private_mapping.reset_epoch = mapping.reset_epoch;
    first_private_mapping.route_valid = mapping.route_valid;
    first_private_mapping.epoch_valid = mapping.epoch_valid;
    first_private_mapping.backing_addr = mapping.backing_addr;
    first_private_mapping.iova = mapping.iova;
    first_private_mapping.size = mapping.size;
    first_private_mapping.direction = mapping.direction;
    first_private_mapping.permissions = mapping.permissions;
    first_private_mapping.state = mapping.state;
    first_private_mapping.owner_h = mapping.owner_h;
    first_private_mapping.umem_backed = mapping.umem_backed;
    first_private_mapping.umem_page_count = mapping.umem_page_count;
    second_private_mapping.copy(first_private_mapping);

    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, first_private_mapping,
      64'h1020_3040_5060_7080, dependency_image,
      image_digest, authority_digest
    );
    expect_status("PRIVATE_MAPPING_FIRST_DIGEST", status, RDMA_SC_OK);
    status = rdma_cmq_compute_item_digests(
      command, "CMQ-BODY-EMPTY-V1", body_bytes, ticket, owner,
      identity, dma_context, sqe_image, second_private_mapping,
      64'h1020_3040_5060_7080, dependency_image,
      second_image_digest, second_authority_digest
    );
    expect_status("PRIVATE_MAPPING_SECOND_DIGEST", status, RDMA_SC_OK);
    if (authority_digest != second_authority_digest ||
        image_digest != second_image_digest)
      `uvm_error("PRIVATE_MAPPING_PUBLIC_DIGEST",
                 "opaque allocation token entered public digest")
    status = first_private_mapping.release_authority_status(
      second_private_mapping
    );
    if (status == null || status.ok())
      `uvm_error("PRIVATE_MAPPING_AUTHORITY",
                 "matching public digest authorized a different allocation")
  endfunction

  // 功能：验证 batch authority literal golden、ordered tuple 覆盖及 mutable lifecycle 字段排除。
  // 输入/输出及副作用：无显式输入；从 record/request 两份图分别重算并比较 digest。
  // 失败/边界：空或不等长 tuple 不发布 digest；任一 domain/schema/宽度/顺序漂移或
  //   included 字段 mutation 必须偏离仓库外手算的完整 batch literal。
  function automatic void check_batch_digest_contract();
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_function_binding identity_binding;
    rdma_handle cmq_h;
    rdma_hw_image doorbell_image;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    rdma_cmq_journal_digest_t request_digest;
    rdma_cmq_batch_submission_record record;
    rdma_cmq_submission_recovery_request request;
    rdma_status status;

    identity = make_identity("batch_identity");
    binding = make_binding("batch_binding", identity);
    cmq_h = make_resource_handle(
      "batch_cmq", RDMA_RESOURCE_CMQ, 32'h55
    );
    doorbell_image = make_image(
      "batch_doorbell", RDMA_IMAGE_DOORBELL, 8, TEST_GENERATION
    );
    doorbell_image.write_target_kind = RDMA_HW_TARGET_BAR;
    doorbell_image.bar_target.value = 64'h8000_2040;
    doorbell_image.field_summary.push_back("batch-doorbell");
    request_indices = '{32'd2, 32'd9};
    image_digests = '{256'h0102, 256'h0304};
    authority_digests = '{256'h0506, 256'h0708};

    status = rdma_cmq_compute_batch_digest(
      identity,
      binding,
      cmq_h,
      doorbell_image,
      13,
      1'b1,
      64'd100,
      64'd102,
      request_indices,
      image_digests,
      authority_digests,
      baseline_digest
    );
    expect_status("BATCH_DIGEST_BASELINE", status, RDMA_SC_OK);
    expect_digest_value(
      "BATCH_DIGEST_GOLDEN",
      baseline_digest,
      256'h2adfd3c7_c8fe5ae1_dbe15121_a7222187_8bf755de_5a6c173e_3066a809_dd828d97
    );

    record = new("batch_digest_record");
    record.batch_key = "batch-key";
    record.batch_id = 64'h101;
    record.attempt_id = 64'h202;
    record.function_identity = identity;
    record.binding = binding;
    record.cmq_h = cmq_h;
    record.start_sequence = 100;
    record.end_sequence = 102;
    record.doorbell_image = doorbell_image;
    record.final_pi = 13;
    record.final_polarity = 1'b1;
    record.batch_digest = baseline_digest;
    request = new("batch_digest_request");
    request.batch_key = record.batch_key;
    request.batch_id = record.batch_id;
    request.expected_attempt_id = record.attempt_id;
    request.expected_function_identity = identity;
    request.binding = binding;
    request.cmq_h = cmq_h;
    request.start_sequence = record.start_sequence;
    request.end_sequence = record.end_sequence;
    request.doorbell_image = doorbell_image;
    request.final_pi = record.final_pi;
    request.final_polarity = record.final_polarity;
    request.batch_digest = baseline_digest;
    status = rdma_cmq_compute_batch_digest(
      request.expected_function_identity,
      request.binding,
      request.cmq_h,
      request.doorbell_image,
      request.final_pi,
      request.final_polarity,
      request.start_sequence,
      request.end_sequence,
      request_indices,
      image_digests,
      authority_digests,
      request_digest
    );
    expect_status("BATCH_DIGEST_REQUEST", status, RDMA_SC_OK);
    if (request_digest != record.batch_digest)
      `uvm_error("BATCH_DIGEST_PROJECTION",
                 "record and recovery request projections differ")

    identity.reset_epoch++;
    identity_binding = make_binding("batch_identity_binding", identity);
    status = rdma_cmq_compute_batch_digest(
      identity, identity_binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_IDENTITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_IDENTITY", "Function identity was omitted")
    identity.reset_epoch--;

    binding.notify_table_index++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_BINDING", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_BINDING", "binding field was omitted")
    binding.notify_table_index--;

    cmq_h.object_id++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_CMQ", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_CMQ", "CMQ handle was omitted")
    cmq_h.object_id--;

    doorbell_image.bytes[0] ^= 8'h80;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_DOORBELL_BYTE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_DOORBELL_BYTE", "doorbell byte was omitted")
    doorbell_image.bytes[0] ^= 8'h80;

    doorbell_image.bar_target.value++;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_DOORBELL_METADATA", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_DOORBELL_METADATA", "doorbell metadata omitted")
    doorbell_image.bar_target.value--;

    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 14, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_PI", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_PI", "final PI was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b0,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_POLARITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_POLARITY", "final polarity was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      99, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_START", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_START", "start sequence was omitted")
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 103, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_END", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_END", "end sequence was omitted")

    request_indices = '{32'd9, 32'd2};
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_ORDER", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_ORDER", "request order was omitted")
    request_indices = '{32'd2, 32'd9};
    image_digests[0] ^= 256'h1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_IMAGE_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_IMAGE_DIGEST", "image digest was omitted")
    image_digests[0] ^= 256'h1;
    authority_digests[1] ^= 256'h1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_AUTHORITY_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("BATCH_DIGEST_AUTHORITY_DIGEST",
                 "authority digest was omitted")
    authority_digests[1] ^= 256'h1;

    record.attempt_id++;
    record.state = RDMA_CMQ_SUBMISSION_COMPLETED;
    record.submission_effect = RDMA_SUBMIT_EFFECT_MMIO_VISIBLE;
    record.attempt_effect = RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED;
    record.observer_armed = 1'b1;
    record.publication_retry_safe = 1'b1;
    status = rdma_cmq_compute_batch_digest(
      record.function_identity,
      record.binding,
      record.cmq_h,
      record.doorbell_image,
      record.final_pi,
      record.final_polarity,
      record.start_sequence,
      record.end_sequence,
      request_indices,
      image_digests,
      authority_digests,
      changed_digest
    );
    expect_status("BATCH_DIGEST_EXCLUDED_LIFECYCLE", status, RDMA_SC_OK);
    if (changed_digest != baseline_digest)
      `uvm_error("BATCH_DIGEST_EXCLUDED_LIFECYCLE",
                 "mutable lifecycle field changed batch authority")

    request_indices.delete();
    changed_digest = '1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("BATCH_DIGEST_EMPTY", "empty tuple published digest")
    request_indices.push_back(2);
    changed_digest = '1;
    status = rdma_cmq_compute_batch_digest(
      identity, binding, cmq_h, doorbell_image, 13, 1'b1,
      100, 102, request_indices, image_digests, authority_digests,
      changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("BATCH_DIGEST_LENGTH", "unequal tuple published digest")
  endfunction

  // 功能：验证 reset proof literal golden、ordered 四字段 tuple 和 mutable transition 排除。
  // 输入/输出及副作用：无显式输入；构造不对称 proof 并逐项 mutation 后重算。
  // 失败/边界：零 ID、空/不等长 tuple 或非法 owner 必须失败且输出清零；任一
  //   domain/header/宽度/顺序漂移必须偏离仓库外手算的完整 proof literal。
  function automatic void check_reset_proof_value();
    rdma_function_identity isolated_identity;
    rdma_function_identity replacement_identity;
    rdma_cmq_recovery_owner owners[$];
    rdma_cmq_recovery_owner first_owner;
    rdma_cmq_recovery_owner second_owner;
    int unsigned request_indices[$];
    rdma_cmq_journal_digest_t image_digests[$];
    rdma_cmq_journal_digest_t authority_digests[$];
    rdma_cmq_journal_digest_t baseline_digest;
    rdma_cmq_journal_digest_t changed_digest;
    rdma_cmq_reset_isolation_proof proof;
    rdma_status status;

    isolated_identity = make_identity("proof_isolated_identity");
    replacement_identity = make_identity("proof_replacement_identity");
    replacement_identity.reset_epoch++;
    first_owner = make_owner(
      "proof_owner_mr", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH
    );
    second_owner = make_owner(
      "proof_owner_qp", RDMA_CMQ_WORKFLOW_QP, RDMA_RESOURCE_QP,
      RDMA_CMQ_RECOVERY_CONFIRM_RESET_ISOLATION
    );
    expect_status("PROOF_OWNER_MR_FREEZE",
                  first_owner.freeze_for_journal(isolated_identity, 37),
                  RDMA_SC_OK);
    expect_status("PROOF_OWNER_QP_FREEZE",
                  second_owner.freeze_for_journal(isolated_identity, 37),
                  RDMA_SC_OK);
    owners = '{first_owner, second_owner};
    request_indices = '{32'd1, 32'd7};
    image_digests = '{256'h1122, 256'h3344};
    authority_digests = '{256'h5566, 256'h7788};

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key",
      64'h101,
      "batch-key",
      64'h202,
      64'h303,
      64'h404,
      64'h505,
      isolated_identity,
      256'h0123_4567_89ab_cdef,
      request_indices,
      image_digests,
      authority_digests,
      owners,
      baseline_digest
    );
    expect_status("RESET_PROOF_BASELINE", status, RDMA_SC_OK);
    expect_digest_value(
      "RESET_PROOF_GOLDEN",
      baseline_digest,
      256'h566d7583_584213fe_f287c531_6b843754_45071d95_8af83cc3_7f13b868_cf7f9724
    );

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key-2", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_KEY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_KEY", "proof key was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h102, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ID", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ID", "proof ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key-2", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_KEY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_KEY", "batch key was omitted")

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h203, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_ID", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_ID", "batch ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h304,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ATTEMPT", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ATTEMPT", "attempt ID was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h405, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_ENGINE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_ENGINE", "engine instance was omitted")
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h506, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_INCARNATION", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_INCARNATION", "engine incarnation omitted")

    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdee, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_BATCH_DIGEST", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_BATCH_DIGEST", "batch digest was omitted")
    request_indices[0]++;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_REQUEST_INDEX", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_REQUEST_INDEX", "request index was omitted")
    request_indices[0]--;
    image_digests[0] ^= 256'h1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_IMAGE", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_IMAGE", "image digest was omitted")
    image_digests[0] ^= 256'h1;
    authority_digests[1] ^= 256'h1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_AUTHORITY", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_AUTHORITY", "authority digest was omitted")
    authority_digests[1] ^= 256'h1;
    first_owner.transaction_id++;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 64'h101, "batch-key", 64'h202, 64'h303,
      64'h404, 64'h505, isolated_identity,
      256'h0123_4567_89ab_cdef, request_indices, image_digests,
      authority_digests, owners, changed_digest
    );
    expect_status("RESET_PROOF_OWNER", status, RDMA_SC_OK);
    if (changed_digest == baseline_digest)
      `uvm_error("RESET_PROOF_OWNER", "full recovery owner was omitted")
    first_owner.transaction_id--;

    proof = new("reset_proof_value");
    proof.proof_key = "proof-key";
    proof.proof_id = 64'h101;
    proof.batch_key = "batch-key";
    proof.batch_id = 64'h202;
    proof.attempt_id = 64'h303;
    proof.engine_instance_id = 64'h404;
    proof.engine_incarnation = 64'h505;
    proof.isolated_identity = isolated_identity;
    proof.replacement_identity = replacement_identity;
    proof.batch_digest = 256'h0123_4567_89ab_cdef;
    proof.isolated_request_indices = request_indices;
    proof.isolated_image_digests = image_digests;
    proof.isolated_authority_digests = authority_digests;
    proof.isolated_recovery_owners = owners;
    proof.proof_digest = baseline_digest;
    proof.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
    proof.backing_release_confirmed = 1'b1;
    replacement_identity.reset_epoch++;
    proof.state = RDMA_CMQ_RESET_PROOF_READY;
    proof.backing_release_confirmed = 1'b0;
    status = rdma_cmq_compute_reset_proof_digest(
      proof.proof_key, proof.proof_id, proof.batch_key, proof.batch_id,
      proof.attempt_id, proof.engine_instance_id, proof.engine_incarnation,
      proof.isolated_identity, proof.batch_digest,
      proof.isolated_request_indices, proof.isolated_image_digests,
      proof.isolated_authority_digests, proof.isolated_recovery_owners,
      changed_digest
    );
    expect_status("RESET_PROOF_MUTABLE_EXCLUDED", status, RDMA_SC_OK);
    if (changed_digest != baseline_digest)
      `uvm_error("RESET_PROOF_MUTABLE_EXCLUDED",
                 "replacement/state/release changed stable proof digest")

    changed_digest = '1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 0, "batch-key", 64'h202, 64'h303, 64'h404,
      64'h505, isolated_identity, 256'h1, request_indices,
      image_digests, authority_digests, owners, changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("RESET_PROOF_ZERO_ID", "zero ID published proof digest")
    owners.delete();
    changed_digest = '1;
    status = rdma_cmq_compute_reset_proof_digest(
      "proof-key", 1, "batch-key", 2, 3, 4, 5,
      isolated_identity, 256'h1, request_indices,
      image_digests, authority_digests, owners, changed_digest
    );
    if (status == null || status.ok() || changed_digest != '0)
      `uvm_error("RESET_PROOF_TUPLE_LENGTH",
                 "unequal proof tuple published digest")
  endfunction

  // 功能：直接调用 Function/handle package snapshot API，冻结基类、子类与 hostile clone 边界。
  // 输入/输出及副作用：无显式输入；构造局部 handle，读取 clone 计数并通过 UVM error 发布偏差。
  // 失败/边界：覆盖 null/null-clone/self/错类型/mutation 拒绝的精确诊断与 output 清空；第三等值对象保持可接受。
  function automatic void check_typed_handle_snapshot_contract();
    rdma_status status;
    rdma_function_handle function_base;
    rdma_function_handle function_snapshot;
    rdma_function_handle function_prefill;
    rdma_function_handle function_expected;
    rdma_function_handle function_different_name;
    rdma_cmq_snapshot_function_handle function_source;
    rdma_cmq_snapshot_function_handle function_typed_snapshot;
    rdma_cmq_snapshot_function_name_peer function_name_peer;
    rdma_handle handle_base;
    rdma_handle handle_snapshot;
    rdma_handle handle_prefill;
    rdma_handle handle_expected;
    rdma_handle handle_different_name;
    rdma_cmq_snapshot_handle handle_source;
    rdma_cmq_snapshot_handle handle_typed_snapshot;
    rdma_cmq_snapshot_handle_name_peer handle_name_peer;

    function_base = new("typed_function_base");
    fill_snapshot_function(function_base, 32'h1001);
    status = rdma_cmq_checked_function_snapshot(
      function_base, "DIRECT_FUNCTION_BASE", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_status("TYPED_FUNCTION_BASE_STATUS", status, RDMA_SC_OK);
    if (function_snapshot == null || function_snapshot == function_base ||
        !rdma_cmq_same_handle_value(function_base, function_snapshot))
      `uvm_error("TYPED_FUNCTION_BASE",
                 "base Function snapshot was null, aliased or changed")

    function_prefill = new("typed_function_null_prefill");
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      null, "DIRECT_FUNCTION_NULL", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_NULL Function is null"
    );
    if (function_snapshot != null)
      `uvm_error("TYPED_FUNCTION_NULL_CLEAR",
                 "null Function rejection retained prefilled output")

    function_source = new("typed_function_source");
    fill_snapshot_function(function_source, 32'h1002);
    function_source.extension_value = 32'ha5a5;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_SUBTYPE", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_status("TYPED_FUNCTION_SUBTYPE_STATUS", status, RDMA_SC_OK);
    if (!$cast(function_typed_snapshot, function_snapshot) ||
        function_snapshot == function_source ||
        function_source.clone_calls != 1 ||
        !rdma_cmq_same_handle_value(function_source, function_snapshot))
      `uvm_error("TYPED_FUNCTION_SUBTYPE",
                 "registered Function subtype was not cloned once")

    function_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_NULL;
    function_source.clone_calls = 0;
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_CLONE_NULL",
      RDMA_SC_INVALID_STATE, function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_CLONE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_CLONE_NULL Function snapshot clone contract failed"
    );
    if (function_snapshot != null || function_source.clone_calls != 1)
      `uvm_error("TYPED_FUNCTION_CLONE_NULL",
                 "null clone did not clear output or clone exactly once")

    function_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    function_source.clone_calls = 0;
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_SELF", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_SELF_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_SELF Function snapshot clone contract failed"
    );
    if (function_snapshot != null || function_source.clone_calls != 1)
      `uvm_error("TYPED_FUNCTION_SELF",
                 "self clone did not clear output or clone exactly once")

    function_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE;
    function_source.clone_calls = 0;
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_WRONG", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_WRONG_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_WRONG Function snapshot clone contract failed"
    );
    if (function_snapshot != null || function_source.clone_calls != 1)
      `uvm_error("TYPED_FUNCTION_WRONG",
                 "wrong-type clone did not atomically reject")

    function_expected = new("typed_function_expected");
    fill_snapshot_function(function_expected, 32'h1002);
    function_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    function_source.clone_calls = 0;
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_MUTATE", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_MUTATE_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_MUTATE Function snapshot changed its source value"
    );
    if (function_snapshot != null || function_source.clone_calls != 1 ||
        !rdma_cmq_same_handle_value(function_source, function_expected))
      `uvm_error("TYPED_FUNCTION_MUTATE",
                 "mutating Function clone was not rejected/restored")

    function_different_name = new("typed_function_different_name");
    fill_snapshot_function(function_different_name, 32'h1002);
    function_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL;
    function_source.third_equal_value = function_different_name;
    function_source.clone_calls = 0;
    function_snapshot = function_prefill;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_DIFFERENT_NAME",
      RDMA_SC_INVALID_STATE, function_snapshot
    );
    expect_snapshot_failure(
      "TYPED_FUNCTION_DIFFERENT_NAME_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_FUNCTION_DIFFERENT_NAME Function snapshot clone contract failed"
    );
    if (function_snapshot != null || function_source.clone_calls != 1)
      `uvm_error("TYPED_FUNCTION_DIFFERENT_NAME",
                 "cast-compatible different type name was accepted")

    function_name_peer = new("typed_function_name_peer");
    fill_snapshot_function(function_name_peer, 32'h1002);
    if (function_name_peer.get_object_type() ==
          function_source.get_object_type() ||
        function_name_peer.get_type_name() !=
          function_source.get_type_name())
      `uvm_error("TYPED_FUNCTION_NAME_PEER_FIXTURE",
                 "Function peer did not separate wrapper from type name")
    function_source.third_equal_value = function_name_peer;
    function_source.clone_calls = 0;
    status = rdma_cmq_checked_function_snapshot(
      function_source, "DIRECT_FUNCTION_THIRD", RDMA_SC_INVALID_STATE,
      function_snapshot
    );
    expect_status("TYPED_FUNCTION_THIRD_STATUS", status, RDMA_SC_OK);
    if (function_snapshot != function_name_peer ||
        function_snapshot == function_source ||
        function_source.clone_calls != 1)
      `uvm_error("TYPED_FUNCTION_THIRD",
                 "equal same-name/different-wrapper Function was rejected")

    handle_base = new("typed_handle_base");
    fill_snapshot_handle(handle_base, RDMA_RESOURCE_MR, 32'h2001);
    status = rdma_cmq_checked_handle_snapshot(
      handle_base, "DIRECT_HANDLE_BASE", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_status("TYPED_HANDLE_BASE_STATUS", status, RDMA_SC_OK);
    if (handle_snapshot == null || handle_snapshot == handle_base ||
        !rdma_cmq_same_handle_value(handle_base, handle_snapshot))
      `uvm_error("TYPED_HANDLE_BASE",
                 "base handle snapshot was null, aliased or changed")

    handle_prefill = new("typed_handle_null_prefill");
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      null, "DIRECT_HANDLE_NULL", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_NULL_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_NULL handle is null"
    );
    if (handle_snapshot != null)
      `uvm_error("TYPED_HANDLE_NULL_CLEAR",
                 "null handle rejection retained prefilled output")

    handle_source = new("typed_handle_source");
    fill_snapshot_handle(handle_source, RDMA_RESOURCE_MR, 32'h2002);
    handle_source.extension_value = 32'ha5a5;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_SUBTYPE", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_status("TYPED_HANDLE_SUBTYPE_STATUS", status, RDMA_SC_OK);
    if (!$cast(handle_typed_snapshot, handle_snapshot) ||
        handle_snapshot == handle_source || handle_source.clone_calls != 1 ||
        !rdma_cmq_same_handle_value(handle_source, handle_snapshot))
      `uvm_error("TYPED_HANDLE_SUBTYPE",
                 "registered handle subtype was not cloned once")

    handle_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_NULL;
    handle_source.clone_calls = 0;
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_CLONE_NULL", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_CLONE_NULL_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_CLONE_NULL handle snapshot clone contract failed"
    );
    if (handle_snapshot != null || handle_source.clone_calls != 1)
      `uvm_error("TYPED_HANDLE_CLONE_NULL",
                 "null handle clone did not atomically reject")

    handle_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    handle_source.clone_calls = 0;
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_SELF", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_SELF_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_SELF handle snapshot clone contract failed"
    );
    if (handle_snapshot != null || handle_source.clone_calls != 1)
      `uvm_error("TYPED_HANDLE_SELF",
                 "self handle clone did not atomically reject")

    handle_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE;
    handle_source.clone_calls = 0;
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_WRONG", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_WRONG_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_WRONG handle snapshot clone contract failed"
    );
    if (handle_snapshot != null || handle_source.clone_calls != 1)
      `uvm_error("TYPED_HANDLE_WRONG",
                 "wrong-type handle clone did not atomically reject")

    handle_expected = new("typed_handle_expected");
    fill_snapshot_handle(handle_expected, RDMA_RESOURCE_MR, 32'h2002);
    handle_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    handle_source.clone_calls = 0;
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_MUTATE", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_MUTATE_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_MUTATE handle snapshot changed its source value"
    );
    if (handle_snapshot != null || handle_source.clone_calls != 1 ||
        !rdma_cmq_same_handle_value(handle_source, handle_expected))
      `uvm_error("TYPED_HANDLE_MUTATE",
                 "mutating handle clone was not rejected/restored")

    handle_different_name = new("typed_handle_different_name");
    fill_snapshot_handle(
      handle_different_name, RDMA_RESOURCE_MR, 32'h2002
    );
    handle_source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL;
    handle_source.third_equal_value = handle_different_name;
    handle_source.clone_calls = 0;
    handle_snapshot = handle_prefill;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_DIFFERENT_NAME",
      RDMA_SC_INVALID_ARGUMENT, handle_snapshot
    );
    expect_snapshot_failure(
      "TYPED_HANDLE_DIFFERENT_NAME_STATUS", status,
      RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_HANDLE_DIFFERENT_NAME handle snapshot clone contract failed"
    );
    if (handle_snapshot != null || handle_source.clone_calls != 1)
      `uvm_error("TYPED_HANDLE_DIFFERENT_NAME",
                 "cast-compatible different handle type name was accepted")

    handle_name_peer = new("typed_handle_name_peer");
    fill_snapshot_handle(handle_name_peer, RDMA_RESOURCE_MR, 32'h2002);
    if (handle_name_peer.get_object_type() == handle_source.get_object_type() ||
        handle_name_peer.get_type_name() != handle_source.get_type_name())
      `uvm_error("TYPED_HANDLE_NAME_PEER_FIXTURE",
                 "handle peer did not separate wrapper from type name")
    handle_source.third_equal_value = handle_name_peer;
    handle_source.clone_calls = 0;
    status = rdma_cmq_checked_handle_snapshot(
      handle_source, "DIRECT_HANDLE_THIRD", RDMA_SC_INVALID_ARGUMENT,
      handle_snapshot
    );
    expect_status("TYPED_HANDLE_THIRD_STATUS", status, RDMA_SC_OK);
    if (handle_snapshot != handle_name_peer ||
        handle_snapshot == handle_source ||
        handle_source.clone_calls != 1)
      `uvm_error("TYPED_HANDLE_THIRD",
                 "equal same-name/different-wrapper handle was rejected")
  endfunction

  // 功能：直接调用 opcode package snapshot API，冻结 validate-before-clone 优先级与 clone 故障语义。
  // 输入/输出及副作用：无显式输入；改写局部 key 的文本/故障模式，读取 clone_calls 并发布断言。
  // 失败/边界：空文本与分隔符必须以原 validate 诊断在零 clone 时拒绝；clone 故障均清空预填 output。
  function automatic void check_typed_opcode_snapshot_contract();
    rdma_status status;
    rdma_cmq_opcode_key base_source;
    rdma_cmq_opcode_key snapshot;
    rdma_cmq_opcode_key prefill;
    rdma_cmq_snapshot_opcode_key source;
    rdma_cmq_snapshot_opcode_key typed_snapshot;
    string saved_profile_name;
    bit [31:0] saved_opcode;
    string saved_variant;

    base_source = new("typed_opcode_base");
    fill_snapshot_opcode(base_source);
    status = rdma_cmq_checked_opcode_snapshot(
      base_source, "DIRECT_OPCODE_BASE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_OPCODE_BASE_STATUS", status, RDMA_SC_OK);
    if (snapshot == null || snapshot == base_source ||
        !rdma_cmq_same_opcode_value(base_source, snapshot))
      `uvm_error("TYPED_OPCODE_BASE",
                 "base opcode snapshot was null, aliased or changed")

    prefill = new("typed_opcode_prefill");
    fill_snapshot_opcode(prefill);
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      null, "DIRECT_OPCODE_NULL", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_OPCODE_NULL opcode key is null"
    );
    if (snapshot != null)
      `uvm_error("TYPED_OPCODE_NULL_CLEAR",
                 "null opcode rejection retained prefilled output")

    source = new("typed_opcode_source");
    fill_snapshot_opcode(source);
    source.extension_value = 32'ha5a5;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_SUBTYPE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_OPCODE_SUBTYPE_STATUS", status, RDMA_SC_OK);
    if (!$cast(typed_snapshot, snapshot) || snapshot == source ||
        source.clone_calls != 1 ||
        !rdma_cmq_same_opcode_value(source, snapshot))
      `uvm_error("TYPED_OPCODE_SUBTYPE",
                 "registered opcode subtype was not cloned once")

    source.profile_name = "";
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_VALIDATE_EMPTY", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_VALIDATE_EMPTY_STATUS", status,
      RDMA_SC_INVALID_ARGUMENT, "CMQ profile name is empty"
    );
    if (snapshot != null || source.clone_calls != 0)
      `uvm_error("TYPED_OPCODE_VALIDATE_EMPTY",
                 "empty profile reached clone or retained output")

    fill_snapshot_opcode(source);
    source.variant = "query|fast";
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_VALIDATE_SEPARATOR", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_VALIDATE_SEPARATOR_STATUS", status,
      RDMA_SC_INVALID_ARGUMENT, "CMQ opcode variant contains '|'"
    );
    if (snapshot != null || source.clone_calls != 0)
      `uvm_error("TYPED_OPCODE_VALIDATE_SEPARATOR",
                 "separator validation reached clone or retained output")

    fill_snapshot_opcode(source);
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_NULL;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_CLONE_NULL", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_CLONE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_OPCODE_CLONE_NULL opcode snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_OPCODE_CLONE_NULL",
                 "null opcode clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_SELF", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_SELF_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_OPCODE_SELF opcode snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_OPCODE_SELF",
                 "self opcode clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_WRONG", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_WRONG_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_OPCODE_WRONG opcode snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_OPCODE_WRONG",
                 "wrong-type opcode clone did not atomically reject")

    saved_profile_name = source.profile_name;
    saved_opcode = source.opcode;
    saved_variant = source.variant;
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_opcode_snapshot(
      source, "DIRECT_OPCODE_MUTATE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_OPCODE_MUTATE_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_OPCODE_MUTATE opcode snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        source.profile_name != saved_profile_name ||
        source.opcode != saved_opcode || source.variant != saved_variant)
      `uvm_error("TYPED_OPCODE_MUTATE",
                 "mutating opcode clone was not rejected/restored")
  endfunction

  // 功能：直接调用 expected-response package snapshot API，冻结 validate、
  // clone/latch/restore、第三对象接受及 clone-contract 错误优先级。
  // 输入/输出及副作用：无显式输入；创建局部 base/subtype/candidate，切换 clone_mode，
  // 读取 clone_calls/source 恢复值并通过 UVM error 发布断言结果。
  // 失败/边界：source validation 必须在零 clone 时原样拒绝；所有 clone/value 失败
  // 清空预填 output；mutating-self 必须恢复 source 但仍优先报告 clone-contract。
  function automatic void check_typed_expected_snapshot_contract();
    rdma_status status;
    rdma_cmq_expected_response base_source;
    rdma_cmq_expected_response snapshot;
    rdma_cmq_expected_response prefill;
    rdma_cmq_expected_response candidate;
    rdma_cmq_snapshot_expected_response source;
    rdma_cmq_snapshot_expected_response typed_snapshot;
    bit [31:0] saved_hardware_opcode;
    string saved_variant;

    base_source = new("typed_expected_base");
    fill_snapshot_expected(base_source);
    status = rdma_cmq_checked_expected_snapshot(
      base_source, "DIRECT_EXPECTED_BASE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_EXPECTED_BASE_STATUS", status, RDMA_SC_OK);
    if (snapshot == null || snapshot == base_source ||
        snapshot.hardware_opcode != base_source.hardware_opcode ||
        snapshot.variant != base_source.variant)
      `uvm_error("TYPED_EXPECTED_BASE",
                 "base expected snapshot was null, aliased or changed")

    prefill = new("typed_expected_prefill");
    fill_snapshot_expected(prefill);
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      null, "DIRECT_EXPECTED_NULL", RDMA_SC_INVALID_ARGUMENT, snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_NULL_STATUS", status, RDMA_SC_INVALID_ARGUMENT,
      "DIRECT_EXPECTED_NULL expected response is null"
    );
    if (snapshot != null)
      `uvm_error("TYPED_EXPECTED_NULL_CLEAR",
                 "null expected rejection retained prefilled output")

    source = new("typed_expected_source");
    fill_snapshot_expected(source);
    source.extension_value = 32'ha5a5;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_SUBTYPE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_EXPECTED_SUBTYPE_STATUS", status, RDMA_SC_OK);
    if (!$cast(typed_snapshot, snapshot) || snapshot == source ||
        source.clone_calls != 1 ||
        snapshot.hardware_opcode != source.hardware_opcode ||
        snapshot.variant != source.variant)
      `uvm_error("TYPED_EXPECTED_SUBTYPE",
                 "registered expected subtype was not cloned once")

    source.variant = "";
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_VALIDATE_EMPTY", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_VALIDATE_EMPTY_STATUS", status,
      RDMA_SC_INVALID_ARGUMENT, "CMQ expected response variant is empty"
    );
    if (snapshot != null || source.clone_calls != 0)
      `uvm_error("TYPED_EXPECTED_VALIDATE_EMPTY",
                 "empty expected variant reached clone or retained output")

    fill_snapshot_expected(source);
    source.variant = "query|fast";
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_VALIDATE_SEPARATOR", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_VALIDATE_SEPARATOR_STATUS", status,
      RDMA_SC_INVALID_ARGUMENT,
      "CMQ expected response variant contains '|'"
    );
    if (snapshot != null || source.clone_calls != 0)
      `uvm_error("TYPED_EXPECTED_VALIDATE_SEPARATOR",
                 "separator expected validation reached clone")

    fill_snapshot_expected(source);
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_NULL;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_CLONE_NULL", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_CLONE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_CLONE_NULL expected snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_CLONE_NULL",
                 "null expected clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_SELF", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_SELF_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_SELF expected snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_SELF",
                 "self expected clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_WRONG", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_WRONG_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_WRONG expected snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_WRONG",
                 "wrong-type expected clone did not atomically reject")

    candidate = new("typed_expected_third_equal");
    fill_snapshot_expected(candidate);
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL;
    source.clone_candidate = candidate;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_THIRD", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_EXPECTED_THIRD_STATUS", status, RDMA_SC_OK);
    if (snapshot != candidate || snapshot == source || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_THIRD",
                 "detached equal base candidate was not accepted")

    candidate = new("typed_expected_drift_candidate");
    fill_snapshot_expected(candidate);
    candidate.variant = "query-drift";
    source.clone_candidate = candidate;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_DRIFT", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_DRIFT_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_DRIFT expected snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_DRIFT",
                 "drifted expected candidate was not rejected")

    candidate = new("typed_expected_opcode_drift_candidate");
    fill_snapshot_expected(candidate);
    candidate.hardware_opcode ^= 32'h0000_0001;
    source.clone_candidate = candidate;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_OPCODE_DRIFT", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_OPCODE_DRIFT_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_OPCODE_DRIFT expected snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_EXPECTED_OPCODE_DRIFT",
                 "opcode-drifted expected candidate was not rejected")

    candidate = new("typed_expected_original_candidate");
    fill_snapshot_expected(candidate);
    fill_snapshot_expected(source);
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    source.mutate_hardware_opcode = 1'b1;
    source.mutate_variant = 1'b1;
    source.clone_candidate = candidate;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_MUTATE_THIRD", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_MUTATE_THIRD_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_MUTATE_THIRD expected snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant)
      `uvm_error("TYPED_EXPECTED_MUTATE_THIRD",
                 "mutation latch did not reject and restore source")

    fill_snapshot_expected(source);
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    source.mutate_hardware_opcode = 1'b1;
    source.mutate_variant = 1'b0;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_MUTATE_OPCODE", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_MUTATE_OPCODE_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_MUTATE_OPCODE expected snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant)
      `uvm_error("TYPED_EXPECTED_MUTATE_OPCODE",
                 "opcode-only mutation was not latched and restored")

    fill_snapshot_expected(source);
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    source.mutate_hardware_opcode = 1'b0;
    source.mutate_variant = 1'b1;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_MUTATE_VARIANT", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_MUTATE_VARIANT_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_MUTATE_VARIANT expected snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant)
      `uvm_error("TYPED_EXPECTED_MUTATE_VARIANT",
                 "variant-only mutation was not latched and restored")

    fill_snapshot_expected(source);
    saved_hardware_opcode = source.hardware_opcode;
    saved_variant = source.variant;
    source.clone_candidate = source;
    source.mutate_hardware_opcode = 1'b1;
    source.mutate_variant = 1'b1;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_expected_snapshot(
      source, "DIRECT_EXPECTED_MUTATE_SELF", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_EXPECTED_MUTATE_SELF_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_EXPECTED_MUTATE_SELF expected snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        source.hardware_opcode != saved_hardware_opcode ||
        source.variant != saved_variant)
      `uvm_error("TYPED_EXPECTED_MUTATE_SELF",
                 "mutating self did not preserve priority and restore source")
  endfunction

  // 功能：直接调用 image/canonical-image package API，冻结 factory capture、全字段恢复、深拷贝与 shape 时序。
  // 输入/输出及副作用：使用已安装且 disarm 的 image_fault；在受控窗口注入 factory 故障并读取 clone/create 计数。
  // 失败/边界：null factory 窗口必须零 FCTTYP，wrong-type 窗口必须恰好一次；
  //   非 canonical helper 保留宽松 shape，canonical 必须先 clone 一次再拒绝。
  function automatic void check_typed_image_snapshot_contract();
    rdma_status status;
    rdma_hw_image snapshot;
    rdma_hw_image prefill;
    rdma_hw_image expected_source;
    rdma_hw_image factory_candidate;
    rdma_cmq_snapshot_image source;
    rdma_cmq_snapshot_image typed_snapshot;
    rdma_cmq_snapshot_factory_fatal_catcher null_catcher;
    rdma_cmq_snapshot_factory_fatal_catcher wrong_catcher;
    byte unsigned detached_byte;
    string detached_summary;

    source = new("typed_image_source");
    fill_snapshot_image(source);
    source.extension_value = 32'ha5a5;
    prefill = new("typed_image_prefill");
    fill_snapshot_image(prefill);
    expected_source = new("typed_image_expected");
    expected_source.copy(source);

    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      null, "DIRECT_IMAGE_NULL", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_NULL image is null"
    );
    if (snapshot != null)
      `uvm_error("TYPED_IMAGE_NULL_CLEAR",
                 "null image rejection retained prefilled output")

    if (image_fault == null) begin
      `uvm_error("TYPED_IMAGE_FACTORY_SETUP",
                 "image factory fault wrapper was not configured")
    end
    else begin
      null_catcher = new("typed_image_factory_null_catcher");
      image_fault.arm(1'b0);
      uvm_report_cb::add(null, null_catcher);
      snapshot = prefill;
      status = rdma_cmq_checked_image_snapshot(
        source, "DIRECT_IMAGE_FACTORY_NULL", RDMA_SC_INVALID_STATE,
        snapshot
      );
      uvm_report_cb::delete(null, null_catcher);
      image_fault.disarm();
      expect_snapshot_failure(
        "TYPED_IMAGE_FACTORY_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
        "DIRECT_IMAGE_FACTORY_NULL image value capture failed"
      );
      if (snapshot != null || null_catcher.caught_count != 0 ||
          image_fault.call_count() != 1 || source.clone_calls != 0)
        `uvm_error("TYPED_IMAGE_FACTORY_NULL",
                   "null factory emitted FCTTYP, cloned, or leaked output")

      wrong_catcher = new("typed_image_factory_wrong_catcher");
      image_fault.arm(1'b1);
      uvm_report_cb::add(null, wrong_catcher);
      snapshot = prefill;
      status = rdma_cmq_checked_image_snapshot(
        source, "DIRECT_IMAGE_FACTORY_WRONG", RDMA_SC_INVALID_STATE,
        snapshot
      );
      uvm_report_cb::delete(null, wrong_catcher);
      image_fault.disarm();
      expect_snapshot_failure(
        "TYPED_IMAGE_FACTORY_WRONG_STATUS", status, RDMA_SC_INVALID_STATE,
        "DIRECT_IMAGE_FACTORY_WRONG image value capture failed"
      );
      if (snapshot != null || wrong_catcher.caught_count != 1 ||
          image_fault.call_count() != 1 || source.clone_calls != 0)
        `uvm_error("TYPED_IMAGE_FACTORY_WRONG",
                   "wrong saved-value factory did not fail before clone")
    end

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_NULL;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_CLONE_NULL", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_CLONE_NULL_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_CLONE_NULL image snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_IMAGE_CLONE_NULL",
                 "null image clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_SELF;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_SELF", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_SELF_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_SELF image snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_IMAGE_SELF",
                 "self image clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_WRONG_TYPE;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_WRONG", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_WRONG_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_WRONG image snapshot clone contract failed"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_IMAGE_WRONG",
                 "wrong-type image clone did not atomically reject")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_MUTATE", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_MUTATE_STATUS", status, RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_MUTATE image snapshot changed its source value"
    );
    if (snapshot != null || source.clone_calls != 1 ||
        !rdma_cmq_same_image_value(source, expected_source))
      `uvm_error("TYPED_IMAGE_MUTATE",
                 "mutating image clone was not rejected/restored")

    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    source.clone_calls = 0;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_DEEP", RDMA_SC_INVALID_STATE, snapshot
    );
    expect_status("TYPED_IMAGE_DEEP_STATUS", status, RDMA_SC_OK);
    if (!$cast(typed_snapshot, snapshot) || snapshot == source ||
        source.clone_calls != 1 ||
        !rdma_cmq_same_image_value(source, snapshot))
      `uvm_error("TYPED_IMAGE_DEEP",
                 "image subtype clone was not detached and equal")
    if (snapshot != null) begin
      detached_byte = snapshot.bytes[0];
      detached_summary = snapshot.field_summary[0];
      source.bytes[0] ^= 8'hff;
      source.field_summary[0] = "mutated-after-publish";
      if (snapshot.bytes[0] != detached_byte ||
          snapshot.field_summary[0] != detached_summary)
        `uvm_error("TYPED_IMAGE_QUEUE_DEEP_COPY",
                   "published bytes or summary alias the source queue")
      source.copy(expected_source);
    end

    source.length++;
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_GOOD;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_image_snapshot(
      source, "DIRECT_IMAGE_NONCANONICAL", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_status("TYPED_IMAGE_NONCANONICAL_STATUS", status, RDMA_SC_OK);
    if (snapshot == null || source.clone_calls != 1 ||
        !rdma_cmq_same_image_value(source, snapshot))
      `uvm_error("TYPED_IMAGE_NONCANONICAL",
                 "noncanonical equal image was rejected by primitive")

    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_canonical_image_snapshot(
      source, "DIRECT_IMAGE_CANONICAL_INVALID", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_snapshot_failure(
      "TYPED_IMAGE_CANONICAL_INVALID_STATUS", status,
      RDMA_SC_INVALID_STATE,
      "DIRECT_IMAGE_CANONICAL_INVALID canonical image value is invalid"
    );
    if (snapshot != null || source.clone_calls != 1)
      `uvm_error("TYPED_IMAGE_CANONICAL_INVALID",
                 "canonical shape rejection moved before clone or leaked output")

    source.copy(expected_source);
    factory_candidate = new("typed_image_factory_candidate");
    factory_candidate.copy(source);
    source.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_THIRD_EQUAL;
    source.third_equal_value = factory_candidate;
    source.clone_calls = 0;
    snapshot = prefill;
    status = rdma_cmq_checked_canonical_image_snapshot(
      source, "DIRECT_IMAGE_CANONICAL_BASE", RDMA_SC_INVALID_STATE,
      snapshot
    );
    expect_status("TYPED_IMAGE_CANONICAL_BASE_STATUS", status, RDMA_SC_OK);
    if (snapshot == null || snapshot == source ||
        snapshot == factory_candidate || source.clone_calls != 1 ||
        snapshot.get_object_type() != rdma_hw_image::get_type() ||
        !rdma_cmq_same_image_value(snapshot, source))
      `uvm_error("TYPED_IMAGE_CANONICAL_BASE",
                 "canonical success did not publish an exact detached base")
  endfunction

  // 功能：直接验证 body-value package 的 exact wrapper、七类 body shell、递归
  // key 与 caller-owned graph node 追加契约。
  // 输入/输出及副作用：无显式输入；创建 base/subtype body 与 nested fixture，
  // 改写代表字段并向局部 nodes queue 追加引用；偏差通过具名 UVM error 发布。
  // 失败/边界：覆盖 null/subtype/unsupported、optional-null、URC exact/cast 差异、
  // SQE null/递归 context 及 append no-clear/no-dedup/order；不调用 engine、profile 或 I/O。
  function automatic void check_body_value_contract();
    uvm_object_wrapper null_type;
    rdma_function_handle function_h;
    rdma_handle target_h;
    rdma_cmq_snapshot_handle subtype_handle;
    rdma_cmq_sqe_model sqe;
    rdma_cmq_body_sqe_subtype subtype_sqe;
    rdma_qpc_model qpc;
    rdma_qpc_rc_ext rc_ext;
    rdma_qpc_ud_ext ud_ext;
    rdma_qpc_urc_ext urc_ext;
    rdma_cmq_body_urc_ext_subtype subtype_urc_ext;
    rdma_urc_queue_config queues;
    rdma_cmq_body_urc_queue_subtype subtype_queues;
    rdma_cqc_model cqc;
    rdma_mrt_model mrt;
    rdma_srqc_model srqc;
    rdma_ceqc_model ceqc;
    rdma_aeqc_model aeqc;
    rdma_ring_position ring;
    rdma_page_table_layout page_layout;
    rdma_address_vector address_vector;
    rdma_mr_page_layout mr_page_layout;
    rdma_qpc_behavior behavior;
    rdma_cmq_null_status_body unsupported_body;
    rdma_cmq_value_wrong_factory_object sentinel;
    uvm_object nodes[$];
    uvm_object expected_nodes[$];
    string key_before;
    string key_after;

    function_h = make_function("body_contract_function");
    target_h = make_resource_handle(
      "body_contract_target", RDMA_RESOURCE_QP, 32'h101
    );
    subtype_handle = new("body_contract_subtype_handle");
    subtype_handle.kind = target_h.kind;
    subtype_handle.function_uid = target_h.function_uid;
    subtype_handle.object_id = target_h.object_id;
    subtype_handle.generation = target_h.generation;
    null_type = null;

    expect_value_contract(
      "BODY_TYPE_NULL_VALUE",
      rdma_cmq_has_exact_object_type(null, rdma_handle::get_type()), 1'b0
    );
    expect_value_contract(
      "BODY_TYPE_NULL_EXPECTED",
      rdma_cmq_has_exact_object_type(target_h, null_type), 1'b0
    );
    expect_value_contract(
      "BODY_TYPE_EXACT",
      rdma_cmq_has_exact_object_type(target_h, rdma_handle::get_type()),
      1'b1
    );
    expect_value_contract(
      "BODY_TYPE_SUBTYPE",
      rdma_cmq_has_exact_object_type(
        subtype_handle, rdma_handle::get_type()
      ),
      1'b0
    );
    expect_value_contract(
      "BODY_TYPE_OPTIONAL_NULL",
      rdma_cmq_has_optional_exact_object_type(null, null_type), 1'b1
    );
    expect_value_contract(
      "BODY_TYPE_OPTIONAL_BAD_EXPECTED",
      rdma_cmq_has_optional_exact_object_type(target_h, null_type), 1'b0
    );
    if (rdma_cmq_handle_value_key(null) != "<null-handle>" ||
        rdma_cmq_handle_value_key(target_h) !=
          $sformatf("%0d:%016h:%08h:%08h", target_h.kind,
                    target_h.function_uid, target_h.object_id,
                    target_h.generation))
      `uvm_error("BODY_HANDLE_KEY",
                 "handle key sentinel, format or field order changed")

    sqe = make_body("body_contract_sqe", function_h, target_h);
    subtype_sqe = new("body_contract_sqe_subtype");
    subtype_sqe.opcode = sqe.opcode;
    subtype_sqe.command_id = sqe.command_id;
    subtype_sqe.function_h = function_h;
    subtype_sqe.target_h = target_h;
    qpc = new("body_contract_qpc");
    qpc.qp_h = make_resource_handle(
      "body_contract_qp", RDMA_RESOURCE_QP, 32'h201
    );
    qpc.pd_h = make_resource_handle(
      "body_contract_pd", RDMA_RESOURCE_PD, 32'h202
    );
    qpc.send_cq_h = make_resource_handle(
      "body_contract_send_cq", RDMA_RESOURCE_CQ, 32'h203
    );
    qpc.recv_cq_h = make_resource_handle(
      "body_contract_recv_cq", RDMA_RESOURCE_CQ, 32'h204
    );
    qpc.srq_h = null;
    rc_ext = new("body_contract_rc_ext");
    qpc.transport_ext = rc_ext;

    cqc = new("body_contract_cqc");
    cqc.cq_h = make_resource_handle(
      "body_contract_cq", RDMA_RESOURCE_CQ, 32'h301
    );
    cqc.ceq_h = null;
    mrt = new("body_contract_mrt");
    mrt.mr_h = make_resource_handle(
      "body_contract_mr", RDMA_RESOURCE_MR, 32'h401
    );
    mrt.pd_h = make_resource_handle(
      "body_contract_mr_pd", RDMA_RESOURCE_PD, 32'h402
    );
    srqc = new("body_contract_srqc");
    srqc.srq_h = make_resource_handle(
      "body_contract_srq", RDMA_RESOURCE_SRQ, 32'h501
    );
    srqc.pd_h = make_resource_handle(
      "body_contract_srq_pd", RDMA_RESOURCE_PD, 32'h502
    );
    ceqc = new("body_contract_ceqc");
    ceqc.ceq_h = make_resource_handle(
      "body_contract_ceq", RDMA_RESOURCE_CEQ, 32'h601
    );
    aeqc = new("body_contract_aeqc");
    aeqc.aeq_h = make_resource_handle(
      "body_contract_aeq", RDMA_RESOURCE_AEQ, 32'h701
    );

    expect_value_contract(
      "BODY_SHELL_NULL", rdma_cmq_core_body_shell_is_exact(null), 1'b0
    );
    expect_value_contract(
      "BODY_SHELL_SQE", rdma_cmq_core_body_shell_is_exact(sqe), 1'b1
    );
    expect_value_contract(
      "BODY_SHELL_SQE_SUBTYPE_ROOT",
      rdma_cmq_core_body_shell_is_exact(subtype_sqe), 1'b0
    );
    sqe.target_h = subtype_handle;
    expect_value_contract(
      "BODY_SHELL_SQE_SUBTYPE",
      rdma_cmq_core_body_shell_is_exact(sqe), 1'b0
    );
    sqe.target_h = target_h;
    expect_value_contract(
      "BODY_SHELL_QPC_RC", rdma_cmq_core_body_shell_is_exact(qpc), 1'b1
    );
    ud_ext = new("body_contract_ud_ext");
    qpc.transport_ext = ud_ext;
    expect_value_contract(
      "BODY_SHELL_QPC_UD", rdma_cmq_core_body_shell_is_exact(qpc), 1'b1
    );
    urc_ext = new("body_contract_urc_ext");
    urc_ext.queues = null;
    qpc.transport_ext = urc_ext;
    expect_value_contract(
      "BODY_SHELL_QPC_URC_NULL",
      rdma_cmq_core_body_shell_is_exact(qpc), 1'b0
    );
    queues = new("body_contract_queues");
    urc_ext.queues = queues;
    expect_value_contract(
      "BODY_SHELL_QPC_URC", rdma_cmq_core_body_shell_is_exact(qpc), 1'b1
    );
    subtype_queues = new("body_contract_queue_subtype");
    urc_ext.queues = subtype_queues;
    expect_value_contract(
      "BODY_SHELL_QPC_URC_QUEUE_SUBTYPE",
      rdma_cmq_core_body_shell_is_exact(qpc), 1'b0
    );
    subtype_urc_ext = new("body_contract_urc_ext_subtype");
    subtype_urc_ext.queues = queues;
    qpc.transport_ext = subtype_urc_ext;
    expect_value_contract(
      "BODY_SHELL_QPC_URC_EXT_SUBTYPE",
      rdma_cmq_core_body_shell_is_exact(qpc), 1'b0
    );
    if (rdma_cmq_nested_value_key(subtype_urc_ext) != "")
      `uvm_error("BODY_NESTED_URC_SUBTYPE",
                 "nested key accepted a non-exact URC extension")
    subtype_urc_ext.queues = subtype_queues;
    urc_ext.queues = queues;
    qpc.transport_ext = urc_ext;
    expect_value_contract(
      "BODY_SHELL_CQC", rdma_cmq_core_body_shell_is_exact(cqc), 1'b1
    );
    expect_value_contract(
      "BODY_SHELL_MRT", rdma_cmq_core_body_shell_is_exact(mrt), 1'b1
    );
    expect_value_contract(
      "BODY_SHELL_SRQC", rdma_cmq_core_body_shell_is_exact(srqc), 1'b1
    );
    expect_value_contract(
      "BODY_SHELL_CEQC", rdma_cmq_core_body_shell_is_exact(ceqc), 1'b1
    );
    expect_value_contract(
      "BODY_SHELL_AEQC", rdma_cmq_core_body_shell_is_exact(aeqc), 1'b1
    );
    unsupported_body = new("body_contract_unsupported");
    expect_value_contract(
      "BODY_SHELL_UNSUPPORTED",
      rdma_cmq_core_body_shell_is_exact(unsupported_body), 1'b0
    );

    if (rdma_cmq_nested_value_key(null) != "<null-object>" ||
        rdma_cmq_nested_value_key(subtype_handle) != "" ||
        rdma_cmq_nested_value_key(target_h) !=
          {"handle:", rdma_cmq_handle_value_key(target_h)})
      `uvm_error("BODY_NESTED_SENTINELS",
                 "nested handle/null/unsupported result changed")
    ring = new("body_contract_ring");
    ring.index = 17;
    ring.wrap = 1'b1;
    if (rdma_cmq_nested_value_key(ring) != "ring:17:1")
      `uvm_error("BODY_NESTED_RING", "ring key format changed")
    page_layout = new("body_contract_page_layout");
    page_layout.sd_base.value = 64'h1000;
    key_before = rdma_cmq_nested_value_key(page_layout);
    page_layout.next_valid = 1'b1;
    key_after = rdma_cmq_nested_value_key(page_layout);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_PAGE",
                 "page-layout key omitted a branch or next_valid")
    address_vector = new("body_contract_address_vector");
    address_vector.destination_ip[0] = 8'h11;
    key_before = rdma_cmq_nested_value_key(address_vector);
    address_vector.destination_ip[15] = 8'haa;
    key_after = rdma_cmq_nested_value_key(address_vector);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_AV",
                 "address-vector key omitted destination IP order")
    key_before = rdma_cmq_nested_value_key(queues);
    queues.sq_completion_threshold_entries = 8;
    key_after = rdma_cmq_nested_value_key(queues);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_URC_QUEUES",
                 "URC queue key omitted its trailing threshold")
    mr_page_layout = new("body_contract_mr_page");
    key_before = rdma_cmq_nested_value_key(mr_page_layout);
    mr_page_layout.mr_serial = 9;
    key_after = rdma_cmq_nested_value_key(mr_page_layout);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_MR_PAGE",
                 "MR page key omitted its serial")
    behavior = new("body_contract_behavior");
    key_before = rdma_cmq_nested_value_key(behavior);
    behavior.\priority = 3;
    key_after = rdma_cmq_nested_value_key(behavior);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_BEHAVIOR",
                 "behavior key omitted priority")
    key_before = rdma_cmq_nested_value_key(rc_ext);
    rc_ext.rnr_retry_count = 4;
    key_after = rdma_cmq_nested_value_key(rc_ext);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_RC", "RC key omitted retry count")
    key_before = rdma_cmq_nested_value_key(ud_ext);
    ud_ext.qkey = 32'h1122_3344;
    key_after = rdma_cmq_nested_value_key(ud_ext);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_UD", "UD key omitted qkey")
    key_before = rdma_cmq_nested_value_key(urc_ext);
    urc_ext.dpsn = 24'h123456;
    key_after = rdma_cmq_nested_value_key(urc_ext);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_NESTED_URC", "URC key omitted dpsn/queues")

    if (rdma_cmq_body_value_key(null) != "<null-body>" ||
        rdma_cmq_body_value_key(unsupported_body) != "" ||
        rdma_cmq_body_value_key(subtype_sqe) != "")
      `uvm_error("BODY_VALUE_SENTINELS",
                 "body key null, unsupported or subtype result changed")
    if (rdma_cmq_body_value_key(sqe) !=
        $sformatf("sqe:%0d:%016h:%08h:%s:%s:%s", sqe.opcode,
                  sqe.command_id, sqe.flags,
                  rdma_cmq_handle_value_key(sqe.function_h),
                  rdma_cmq_handle_value_key(sqe.target_h),
                  "<null-context>"))
      `uvm_error("BODY_VALUE_SQE_NULL_CONTEXT",
                 "SQE key format or null-context sentinel changed")
    sqe.context_model = qpc;
    key_before = rdma_cmq_body_value_key(sqe);
    qpc.host_id++;
    key_after = rdma_cmq_body_value_key(sqe);
    if (key_before == "" || key_before == key_after)
      `uvm_error("BODY_VALUE_SQE_RECURSION",
                 "SQE key did not recurse into context body")
    if (rdma_cmq_body_value_key(qpc) == "" ||
        rdma_cmq_body_value_key(cqc) == "" ||
        rdma_cmq_body_value_key(mrt) == "" ||
        rdma_cmq_body_value_key(srqc) == "" ||
        rdma_cmq_body_value_key(ceqc) == "" ||
        rdma_cmq_body_value_key(aeqc) == "")
      `uvm_error("BODY_VALUE_BRANCHES",
                 "one or more exact body branches returned an empty key")

    sentinel = new("body_contract_sentinel");
    nodes.push_back(sentinel);
    expected_nodes = nodes;
    rdma_cmq_append_body_graph_nodes(null, nodes);
    expect_body_node_contract("BODY_NODES_NULL", nodes, expected_nodes);

    rdma_cmq_append_body_graph_nodes(sqe, nodes);
    expected_nodes.push_back(sqe);
    expected_nodes.push_back(sqe.function_h);
    expected_nodes.push_back(sqe.target_h);
    expect_body_node_contract("BODY_NODES_SQE", nodes, expected_nodes);
    foreach (nodes[i]) begin
      if (nodes[i] == sqe.context_model)
        `uvm_error("BODY_NODES_SQE_CONTEXT",
                   "SQE append unexpectedly included context_model")
    end

    qpc.srq_h = make_resource_handle(
      "body_contract_qpc_srq", RDMA_RESOURCE_SRQ, 32'h205
    );
    qpc.transport_ext = subtype_urc_ext;
    nodes.delete();
    expected_nodes.delete();
    nodes.push_back(qpc.qp_h);
    expected_nodes.push_back(qpc.qp_h);
    rdma_cmq_append_body_graph_nodes(qpc, nodes);
    expected_nodes.push_back(qpc);
    expected_nodes.push_back(qpc.qp_h);
    expected_nodes.push_back(qpc.pd_h);
    expected_nodes.push_back(qpc.send_cq_h);
    expected_nodes.push_back(qpc.recv_cq_h);
    expected_nodes.push_back(qpc.srq_h);
    expected_nodes.push_back(qpc.address_vector);
    expected_nodes.push_back(qpc.behavior);
    expected_nodes.push_back(qpc.transport_ext);
    expected_nodes.push_back(subtype_urc_ext.queues);
    expect_body_node_contract("BODY_NODES_QPC", nodes, expected_nodes);

    cqc.ceq_h = make_resource_handle(
      "body_contract_cqc_ceq", RDMA_RESOURCE_CEQ, 32'h302
    );
    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(cqc, nodes);
    expected_nodes.push_back(cqc);
    expected_nodes.push_back(cqc.cq_h);
    expected_nodes.push_back(cqc.ceq_h);
    expected_nodes.push_back(cqc.page_layout);
    expected_nodes.push_back(cqc.producer);
    expected_nodes.push_back(cqc.consumer);
    expect_body_node_contract("BODY_NODES_CQC", nodes, expected_nodes);

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(mrt, nodes);
    expected_nodes.push_back(mrt);
    expected_nodes.push_back(mrt.mr_h);
    expected_nodes.push_back(mrt.pd_h);
    expected_nodes.push_back(mrt.page_layout);
    expect_body_node_contract("BODY_NODES_MRT", nodes, expected_nodes);

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(srqc, nodes);
    expected_nodes.push_back(srqc);
    expected_nodes.push_back(srqc.srq_h);
    expected_nodes.push_back(srqc.pd_h);
    expected_nodes.push_back(srqc.producer);
    expect_body_node_contract("BODY_NODES_SRQC", nodes, expected_nodes);

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(ceqc, nodes);
    expected_nodes.push_back(ceqc);
    expected_nodes.push_back(ceqc.ceq_h);
    expected_nodes.push_back(ceqc.page_layout);
    expected_nodes.push_back(ceqc.producer);
    expected_nodes.push_back(ceqc.consumer);
    expect_body_node_contract("BODY_NODES_CEQC", nodes, expected_nodes);

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(aeqc, nodes);
    expected_nodes.push_back(aeqc);
    expected_nodes.push_back(aeqc.aeq_h);
    expected_nodes.push_back(aeqc.page_layout);
    expected_nodes.push_back(aeqc.producer);
    expected_nodes.push_back(aeqc.consumer);
    expect_body_node_contract("BODY_NODES_AEQC", nodes, expected_nodes);

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(unsupported_body, nodes);
    expected_nodes.push_back(unsupported_body);
    expect_body_node_contract(
      "BODY_NODES_UNSUPPORTED", nodes, expected_nodes
    );

    nodes.delete();
    expected_nodes.delete();
    rdma_cmq_append_body_graph_nodes(subtype_sqe, nodes);
    expected_nodes.push_back(subtype_sqe);
    expect_body_node_contract(
      "BODY_NODES_SQE_SUBTYPE_ROOT_ONLY", nodes, expected_nodes
    );
  endfunction

  // 功能：直接验证六个 journal 纯值 comparator 的 shape、instance/detached、
  // optional-owner、外部引用和逐字段 mutation 契约。
  // 输入/输出及副作用：无显式输入或返回值；创建测试局部 owner/context/mapping/
  // command identity 图，并通过唯一 UVM check_name 报告偏差，不安装真实 journal。
  // 失败/边界：owner 的 null/subtype/legacy 混用和 command 前置非法值应 fail-closed；
  // context/mapping/command subtype 及 invalid-but-equal 宽松值边界必须保持。每次
  // mutation 在 fixture 继续复用前恢复基线；被测 comparator 不得调用 clone、
  // adapter 或 I/O。
  function automatic void check_journal_value_contract();
    rdma_function_identity owner_identity_lhs;
    rdma_function_identity owner_identity_rhs;
    rdma_cmq_recovery_owner owner_lhs;
    rdma_cmq_recovery_owner owner_rhs;
    rdma_cmq_recovery_owner queue_owner_lhs;
    rdma_cmq_recovery_owner queue_owner_rhs;
    rdma_cmq_recovery_owner legacy_lhs;
    rdma_cmq_recovery_owner legacy_rhs;
    rdma_cmq_journal_owner_subtype owner_subtype;
    rdma_handle owner_resource_rhs;
    rdma_function_identity dma_identity;
    rdma_dma_request_context dma_lhs;
    rdma_dma_request_context dma_rhs;
    rdma_cmq_journal_dma_context_subtype dma_subtype_lhs;
    rdma_cmq_journal_dma_context_subtype dma_subtype_rhs;
    rdma_function_handle dma_function_lhs;
    rdma_function_handle dma_function_rhs;
    rdma_handle dma_owner_lhs;
    rdma_handle dma_owner_rhs;
    rdma_function_identity mapping_identity;
    rdma_dma_mapping mapping_lhs;
    rdma_dma_mapping mapping_rhs;
    rdma_cmq_journal_mapping_subtype mapping_subtype_lhs;
    rdma_cmq_journal_mapping_subtype mapping_subtype_rhs;
    rdma_function_handle mapping_function_lhs;
    rdma_function_handle mapping_function_rhs;
    rdma_handle mapping_owner_lhs;
    rdma_handle mapping_owner_rhs;
    rdma_umem shared_umem;
    rdma_umem other_umem;
    rdma_pbl shared_pbl;
    rdma_pbl other_pbl;
    rdma_mw_binding shared_mw;
    rdma_mw_binding other_mw;
    rdma_cmq_command_identity command_lhs;
    rdma_cmq_command_identity command_rhs;
    rdma_cmq_journal_command_identity_subtype command_subtype_lhs;
    rdma_cmq_journal_command_identity_subtype command_subtype_rhs;

    // Owner comparator 先冻结 exact concrete 图，并覆盖 legacy 与 subtype gate。
    owner_identity_lhs = make_identity("journal_owner_identity_lhs");
    owner_identity_rhs = make_identity("journal_owner_identity_rhs");
    owner_lhs = make_frozen_owner(
      "journal_owner_lhs", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH, owner_identity_lhs, 64'h55
    );
    owner_rhs = make_frozen_owner(
      "journal_owner_rhs", RDMA_CMQ_WORKFLOW_MR, RDMA_RESOURCE_MR,
      RDMA_CMQ_RECOVERY_RETRY_PUBLISH, owner_identity_rhs, 64'h55
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_EQUAL", owner_lhs, owner_rhs, 1'b1
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_NULL", owner_lhs, null, 1'b0
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_NULL_LHS", null, owner_rhs, 1'b0
    );
    owner_resource_rhs = owner_rhs.resource_h;
    owner_rhs.resource_h = null;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_NULL_RESOURCE", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.resource_h = owner_resource_rhs;

    legacy_lhs = rdma_cmq_recovery_owner::legacy_unmigrated();
    legacy_rhs = rdma_cmq_recovery_owner::legacy_unmigrated();
    expect_journal_owner_contract(
      "JOURNAL_OWNER_LEGACY_EQUAL", legacy_lhs, legacy_rhs, 1'b1
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_LEGACY_CONCRETE", legacy_lhs, owner_rhs, 1'b0
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_CONCRETE_LEGACY", owner_lhs, legacy_rhs, 1'b0
    );
    legacy_rhs.allowed_actions = 3'b010;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_LEGACY_MUTATED", legacy_lhs, legacy_rhs, 1'b0
    );

    owner_subtype = new("journal_owner_subtype");
    owner_subtype.workflow = owner_lhs.workflow;
    owner_subtype.resource_h = owner_lhs.resource_h;
    owner_subtype.transaction_id = owner_lhs.transaction_id;
    owner_subtype.allowed_actions = owner_lhs.allowed_actions;
    owner_subtype.function_identity = owner_lhs.function_identity;
    owner_subtype.admission_attempt_id = owner_lhs.admission_attempt_id;
    owner_subtype.frozen = owner_lhs.frozen;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_SUBTYPE_LHS", owner_subtype, owner_rhs, 1'b0
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_SUBTYPE_RHS", owner_lhs, owner_subtype, 1'b0
    );

    queue_owner_lhs = make_frozen_owner(
      "journal_queue_owner_lhs", RDMA_CMQ_WORKFLOW_QUEUE,
      RDMA_RESOURCE_CQ, RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
      owner_identity_lhs, 64'h55
    );
    queue_owner_rhs = make_frozen_owner(
      "journal_queue_owner_rhs", RDMA_CMQ_WORKFLOW_QUEUE,
      RDMA_RESOURCE_SRQ, RDMA_CMQ_RECOVERY_RETRY_PUBLISH,
      owner_identity_rhs, 64'h55
    );
    expect_journal_owner_contract(
      "JOURNAL_OWNER_RESOURCE_KIND", queue_owner_lhs, queue_owner_rhs,
      1'b0
    );

    owner_rhs.workflow = RDMA_CMQ_WORKFLOW_QP;
    owner_rhs.resource_h.kind = RDMA_RESOURCE_QP;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_WORKFLOW", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.workflow = owner_lhs.workflow;
    owner_rhs.resource_h.kind = owner_lhs.resource_h.kind;
    owner_rhs.resource_h.object_id++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_RESOURCE", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.resource_h.object_id = owner_lhs.resource_h.object_id;
    owner_rhs.resource_h.function_uid++;
    owner_rhs.function_identity.function_uid++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_RESOURCE_FUNCTION_UID", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.resource_h.function_uid = owner_lhs.resource_h.function_uid;
    owner_rhs.function_identity.function_uid =
      owner_lhs.function_identity.function_uid;
    owner_rhs.resource_h.generation++;
    owner_rhs.function_identity.generation++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_RESOURCE_GENERATION", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.resource_h.generation = owner_lhs.resource_h.generation;
    owner_rhs.function_identity.generation =
      owner_lhs.function_identity.generation;
    owner_rhs.transaction_id++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_TRANSACTION", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.transaction_id = owner_lhs.transaction_id;
    owner_rhs.allowed_actions = 3'b100;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_ACTIONS", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.allowed_actions = owner_lhs.allowed_actions;
    owner_rhs.function_identity.global_function_id++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_FUNCTION_IDENTITY", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.function_identity.global_function_id =
      owner_lhs.function_identity.global_function_id;
    owner_rhs.admission_attempt_id++;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_ATTEMPT", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.admission_attempt_id = owner_lhs.admission_attempt_id;
    owner_rhs.frozen = 1'b0;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_FROZEN", owner_lhs, owner_rhs, 1'b0
    );
    owner_rhs.frozen = 1'b1;
    owner_rhs.function_identity = null;
    expect_journal_owner_contract(
      "JOURNAL_OWNER_NULL_IDENTITY", owner_lhs, owner_rhs, 1'b0
    );

    // DMA context 两条路径共享标量矩阵，但分别使用 instance/value handle helper。
    dma_identity = make_identity("journal_dma_identity");
    dma_lhs = make_dma_context("journal_dma_lhs", dma_identity);
    dma_rhs = make_dma_context("journal_dma_rhs", dma_identity);
    dma_function_lhs = dma_lhs.function_h;
    dma_function_rhs = dma_rhs.function_h;
    dma_owner_lhs = dma_lhs.owner_h;
    dma_owner_rhs = dma_rhs.owner_h;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_EQUAL", dma_lhs, dma_rhs, 1'b1
    );
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_NULL", dma_lhs, null, 1'b0
    );
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_NULL_LHS", null, dma_rhs, 1'b0
    );
    dma_rhs.function_h = null;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_NULL_FUNCTION", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.function_h = dma_function_rhs;
    dma_lhs.function_h = null;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_NULL_FUNCTION_LHS", dma_lhs, dma_rhs, 1'b0
    );
    dma_lhs.function_h = dma_function_lhs;
    dma_subtype_lhs = new("journal_dma_subtype_lhs");
    dma_subtype_rhs = new("journal_dma_subtype_rhs");
    dma_subtype_lhs.function_h = dma_lhs.function_h;
    dma_subtype_rhs.function_h = dma_rhs.function_h;
    dma_subtype_lhs.requester_bdf = dma_lhs.requester_bdf;
    dma_subtype_rhs.requester_bdf = dma_rhs.requester_bdf;
    dma_subtype_lhs.pasid_valid = dma_lhs.pasid_valid;
    dma_subtype_rhs.pasid_valid = dma_rhs.pasid_valid;
    dma_subtype_lhs.pasid = dma_lhs.pasid;
    dma_subtype_rhs.pasid = dma_rhs.pasid;
    dma_subtype_lhs.dma_domain_valid = dma_lhs.dma_domain_valid;
    dma_subtype_rhs.dma_domain_valid = dma_rhs.dma_domain_valid;
    dma_subtype_lhs.dma_domain_id = dma_lhs.dma_domain_id;
    dma_subtype_rhs.dma_domain_id = dma_rhs.dma_domain_id;
    dma_subtype_lhs.route = dma_lhs.route;
    dma_subtype_rhs.route = dma_rhs.route;
    dma_subtype_lhs.reset_epoch = dma_lhs.reset_epoch;
    dma_subtype_rhs.reset_epoch = dma_rhs.reset_epoch;
    dma_subtype_lhs.route_valid = dma_lhs.route_valid;
    dma_subtype_rhs.route_valid = dma_rhs.route_valid;
    dma_subtype_lhs.epoch_valid = dma_lhs.epoch_valid;
    dma_subtype_rhs.epoch_valid = dma_rhs.epoch_valid;
    dma_subtype_lhs.owner_h = dma_lhs.owner_h;
    dma_subtype_rhs.owner_h = dma_rhs.owner_h;
    dma_subtype_lhs.queue_role_valid = dma_lhs.queue_role_valid;
    dma_subtype_rhs.queue_role_valid = dma_rhs.queue_role_valid;
    dma_subtype_lhs.queue_role = dma_lhs.queue_role;
    dma_subtype_rhs.queue_role = dma_rhs.queue_role;
    dma_subtype_lhs.extension_value = 32'h1111;
    dma_subtype_rhs.extension_value = 32'h2222;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_SUBTYPE_EXTENSION_IGNORED",
      dma_subtype_lhs, dma_subtype_rhs, 1'b1
    );
    dma_rhs.function_h.object_id++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_FUNCTION", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.function_h.object_id = dma_lhs.function_h.object_id;
    dma_rhs.owner_h.object_id++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_OWNER", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.owner_h.object_id = dma_lhs.owner_h.object_id;
    dma_rhs.owner_h = null;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_OWNER_PARITY", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.owner_h = dma_owner_rhs;
    dma_lhs.owner_h = null;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_OWNER_PARITY_LHS", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.owner_h = null;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_BOTH_OWNER_NULL", dma_lhs, dma_rhs, 1'b1
    );
    dma_lhs.owner_h = dma_owner_lhs;
    dma_rhs.owner_h = dma_owner_rhs;
    dma_rhs.requester_bdf.bus++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_BDF", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.requester_bdf = dma_lhs.requester_bdf;
    dma_rhs.pasid_valid = !dma_lhs.pasid_valid;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_PASID_VALID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.pasid_valid = dma_lhs.pasid_valid;
    dma_rhs.pasid++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_PASID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.pasid = dma_lhs.pasid;
    dma_rhs.dma_domain_valid = !dma_lhs.dma_domain_valid;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_DOMAIN_VALID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.dma_domain_valid = dma_lhs.dma_domain_valid;
    dma_rhs.dma_domain_id++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_DOMAIN", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.dma_domain_id = dma_lhs.dma_domain_id;
    dma_rhs.route.root_id++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_ROUTE", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.route = dma_lhs.route;
    dma_rhs.reset_epoch++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_EPOCH", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.reset_epoch = dma_lhs.reset_epoch;
    dma_rhs.route_valid = !dma_lhs.route_valid;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_ROUTE_VALID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.route_valid = dma_lhs.route_valid;
    dma_rhs.epoch_valid = !dma_lhs.epoch_valid;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_EPOCH_VALID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.epoch_valid = dma_lhs.epoch_valid;
    dma_rhs.queue_role_valid = !dma_lhs.queue_role_valid;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_QUEUE_ROLE_VALID", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.queue_role_valid = dma_lhs.queue_role_valid;
    dma_rhs.queue_role++;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_QUEUE_ROLE", dma_lhs, dma_rhs, 1'b0
    );
    dma_rhs.queue_role = dma_lhs.queue_role;
    dma_lhs.function_h.kind = RDMA_RESOURCE_MR;
    dma_rhs.function_h.kind = RDMA_RESOURCE_MR;
    expect_journal_dma_context_contract(
      "JOURNAL_DMA_INVALID_EQUAL", dma_lhs, dma_rhs, 1'b1
    );
    dma_lhs.function_h.kind = RDMA_RESOURCE_FUNCTION;
    dma_rhs.function_h.kind = RDMA_RESOURCE_FUNCTION;

    // Mapping 比较保留 non-owning external reference identity 和全部公开字段。
    mapping_identity = make_identity("journal_mapping_identity");
    mapping_lhs = make_mapping("journal_mapping_lhs", mapping_identity);
    mapping_rhs = make_mapping("journal_mapping_rhs", mapping_identity);
    mapping_function_lhs = mapping_lhs.function_h;
    mapping_function_rhs = mapping_rhs.function_h;
    mapping_owner_lhs = mapping_lhs.owner_h;
    mapping_owner_rhs = mapping_rhs.owner_h;
    shared_umem = new("journal_shared_umem");
    other_umem = new("journal_other_umem");
    shared_pbl = new("journal_shared_pbl");
    other_pbl = new("journal_other_pbl");
    shared_mw = new("journal_shared_mw");
    other_mw = new("journal_other_mw");
    mapping_lhs.umem_ref = shared_umem;
    mapping_rhs.umem_ref = shared_umem;
    mapping_lhs.pbl_ref = shared_pbl;
    mapping_rhs.pbl_ref = shared_pbl;
    mapping_lhs.mw_ref = shared_mw;
    mapping_rhs.mw_ref = shared_mw;
    expect_value_contract(
      "JOURNAL_MAPPING_EQUAL",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b1
    );
    mapping_subtype_lhs = new("journal_mapping_subtype_lhs");
    mapping_subtype_rhs = new("journal_mapping_subtype_rhs");
    mapping_subtype_lhs.function_h = mapping_lhs.function_h;
    mapping_subtype_rhs.function_h = mapping_rhs.function_h;
    mapping_subtype_lhs.requester_bdf = mapping_lhs.requester_bdf;
    mapping_subtype_rhs.requester_bdf = mapping_rhs.requester_bdf;
    mapping_subtype_lhs.pasid_valid = mapping_lhs.pasid_valid;
    mapping_subtype_rhs.pasid_valid = mapping_rhs.pasid_valid;
    mapping_subtype_lhs.pasid = mapping_lhs.pasid;
    mapping_subtype_rhs.pasid = mapping_rhs.pasid;
    mapping_subtype_lhs.dma_domain_valid = mapping_lhs.dma_domain_valid;
    mapping_subtype_rhs.dma_domain_valid = mapping_rhs.dma_domain_valid;
    mapping_subtype_lhs.dma_domain_id = mapping_lhs.dma_domain_id;
    mapping_subtype_rhs.dma_domain_id = mapping_rhs.dma_domain_id;
    mapping_subtype_lhs.route = mapping_lhs.route;
    mapping_subtype_rhs.route = mapping_rhs.route;
    mapping_subtype_lhs.reset_epoch = mapping_lhs.reset_epoch;
    mapping_subtype_rhs.reset_epoch = mapping_rhs.reset_epoch;
    mapping_subtype_lhs.route_valid = mapping_lhs.route_valid;
    mapping_subtype_rhs.route_valid = mapping_rhs.route_valid;
    mapping_subtype_lhs.epoch_valid = mapping_lhs.epoch_valid;
    mapping_subtype_rhs.epoch_valid = mapping_rhs.epoch_valid;
    mapping_subtype_lhs.backing_addr = mapping_lhs.backing_addr;
    mapping_subtype_rhs.backing_addr = mapping_rhs.backing_addr;
    mapping_subtype_lhs.iova = mapping_lhs.iova;
    mapping_subtype_rhs.iova = mapping_rhs.iova;
    mapping_subtype_lhs.size = mapping_lhs.size;
    mapping_subtype_rhs.size = mapping_rhs.size;
    mapping_subtype_lhs.direction = mapping_lhs.direction;
    mapping_subtype_rhs.direction = mapping_rhs.direction;
    mapping_subtype_lhs.permissions = mapping_lhs.permissions;
    mapping_subtype_rhs.permissions = mapping_rhs.permissions;
    mapping_subtype_lhs.state = mapping_lhs.state;
    mapping_subtype_rhs.state = mapping_rhs.state;
    mapping_subtype_lhs.owner_h = mapping_lhs.owner_h;
    mapping_subtype_rhs.owner_h = mapping_rhs.owner_h;
    mapping_subtype_lhs.umem_ref = mapping_lhs.umem_ref;
    mapping_subtype_rhs.umem_ref = mapping_rhs.umem_ref;
    mapping_subtype_lhs.pbl_ref = mapping_lhs.pbl_ref;
    mapping_subtype_rhs.pbl_ref = mapping_rhs.pbl_ref;
    mapping_subtype_lhs.mw_ref = mapping_lhs.mw_ref;
    mapping_subtype_rhs.mw_ref = mapping_rhs.mw_ref;
    mapping_subtype_lhs.umem_backed = mapping_lhs.umem_backed;
    mapping_subtype_rhs.umem_backed = mapping_rhs.umem_backed;
    mapping_subtype_lhs.umem_page_count = mapping_lhs.umem_page_count;
    mapping_subtype_rhs.umem_page_count = mapping_rhs.umem_page_count;
    mapping_subtype_lhs.extension_value = 32'h3333;
    mapping_subtype_rhs.extension_value = 32'h4444;
    expect_value_contract(
      "JOURNAL_MAPPING_SUBTYPE_EXTENSION_IGNORED",
      rdma_cmq_same_journal_mapping_public_value(
        mapping_subtype_lhs, mapping_subtype_rhs
      ), 1'b1
    );
    expect_value_contract(
      "JOURNAL_MAPPING_NULL",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, null), 1'b0
    );
    expect_value_contract(
      "JOURNAL_MAPPING_NULL_LHS",
      rdma_cmq_same_journal_mapping_public_value(null, mapping_rhs), 1'b0
    );
    mapping_rhs.function_h = null;
    expect_value_contract(
      "JOURNAL_MAPPING_NULL_FUNCTION",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.function_h = mapping_function_rhs;
    mapping_lhs.function_h = null;
    expect_value_contract(
      "JOURNAL_MAPPING_NULL_FUNCTION_LHS",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_lhs.function_h = mapping_function_lhs;
    mapping_rhs.function_h.object_id++;
    expect_value_contract(
      "JOURNAL_MAPPING_FUNCTION",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.function_h.object_id = mapping_lhs.function_h.object_id;
    mapping_rhs.owner_h.object_id++;
    expect_value_contract(
      "JOURNAL_MAPPING_OWNER",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.owner_h.object_id = mapping_lhs.owner_h.object_id;
    mapping_rhs.owner_h = null;
    expect_value_contract(
      "JOURNAL_MAPPING_OWNER_PARITY",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.owner_h = mapping_owner_rhs;
    mapping_lhs.owner_h = null;
    expect_value_contract(
      "JOURNAL_MAPPING_OWNER_PARITY_LHS",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.owner_h = null;
    expect_value_contract(
      "JOURNAL_MAPPING_BOTH_OWNER_NULL",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b1
    );
    mapping_lhs.owner_h = mapping_owner_lhs;
    mapping_rhs.owner_h = mapping_owner_rhs;
    mapping_rhs.requester_bdf.bus++;
    expect_value_contract(
      "JOURNAL_MAPPING_BDF",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.requester_bdf = mapping_lhs.requester_bdf;
    mapping_rhs.pasid_valid = !mapping_lhs.pasid_valid;
    expect_value_contract(
      "JOURNAL_MAPPING_PASID_VALID",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.pasid_valid = mapping_lhs.pasid_valid;
    mapping_rhs.pasid++;
    expect_value_contract(
      "JOURNAL_MAPPING_PASID",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.pasid = mapping_lhs.pasid;
    mapping_rhs.dma_domain_valid = !mapping_lhs.dma_domain_valid;
    expect_value_contract(
      "JOURNAL_MAPPING_DOMAIN_VALID",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.dma_domain_valid = mapping_lhs.dma_domain_valid;
    mapping_rhs.dma_domain_id++;
    expect_value_contract(
      "JOURNAL_MAPPING_DOMAIN",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.dma_domain_id = mapping_lhs.dma_domain_id;
    mapping_rhs.route.root_id++;
    expect_value_contract(
      "JOURNAL_MAPPING_ROUTE",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.route = mapping_lhs.route;
    mapping_rhs.reset_epoch++;
    expect_value_contract(
      "JOURNAL_MAPPING_EPOCH",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.reset_epoch = mapping_lhs.reset_epoch;
    mapping_rhs.route_valid = !mapping_lhs.route_valid;
    expect_value_contract(
      "JOURNAL_MAPPING_ROUTE_VALID",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.route_valid = mapping_lhs.route_valid;
    mapping_rhs.epoch_valid = !mapping_lhs.epoch_valid;
    expect_value_contract(
      "JOURNAL_MAPPING_EPOCH_VALID",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.epoch_valid = mapping_lhs.epoch_valid;
    mapping_rhs.backing_addr.value++;
    expect_value_contract(
      "JOURNAL_MAPPING_BACKING",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.backing_addr = mapping_lhs.backing_addr;
    mapping_rhs.iova.value++;
    expect_value_contract(
      "JOURNAL_MAPPING_IOVA",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.iova = mapping_lhs.iova;
    mapping_rhs.size++;
    expect_value_contract(
      "JOURNAL_MAPPING_SIZE",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.size = mapping_lhs.size;
    mapping_rhs.direction = RDMA_DMA_DEVICE_WRITE;
    expect_value_contract(
      "JOURNAL_MAPPING_DIRECTION",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.direction = mapping_lhs.direction;
    mapping_rhs.permissions.device_write = 1'b1;
    expect_value_contract(
      "JOURNAL_MAPPING_PERMISSIONS",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.permissions = mapping_lhs.permissions;
    mapping_rhs.state = RDMA_MAPPING_FROZEN;
    expect_value_contract(
      "JOURNAL_MAPPING_STATE",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.state = mapping_lhs.state;
    mapping_rhs.umem_ref = other_umem;
    expect_value_contract(
      "JOURNAL_MAPPING_UMEM_REF",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.umem_ref = shared_umem;
    mapping_rhs.pbl_ref = other_pbl;
    expect_value_contract(
      "JOURNAL_MAPPING_PBL_REF",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.pbl_ref = shared_pbl;
    mapping_rhs.mw_ref = other_mw;
    expect_value_contract(
      "JOURNAL_MAPPING_MW_REF",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.mw_ref = shared_mw;
    mapping_rhs.umem_backed = !mapping_lhs.umem_backed;
    expect_value_contract(
      "JOURNAL_MAPPING_UMEM_BACKED",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.umem_backed = mapping_lhs.umem_backed;
    mapping_rhs.umem_page_count++;
    expect_value_contract(
      "JOURNAL_MAPPING_PAGE_COUNT",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b0
    );
    mapping_rhs.umem_page_count = mapping_lhs.umem_page_count;
    mapping_lhs.size = 0;
    mapping_rhs.size = 0;
    expect_value_contract(
      "JOURNAL_MAPPING_INVALID_EQUAL",
      rdma_cmq_same_journal_mapping_public_value(mapping_lhs, mapping_rhs),
      1'b1
    );
    mapping_lhs.size = 64'h2000;
    mapping_rhs.size = 64'h2000;

    // Command identity 只预检 kind/UID/generation/非空文本，分隔符与零 opcode/GFID 保持值语义。
    command_lhs = make_command_identity("journal_command_lhs");
    command_rhs = make_command_identity("journal_command_rhs");
    expect_value_contract(
      "JOURNAL_COMMAND_EQUAL",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b1
    );
    command_subtype_lhs = new("journal_command_subtype_lhs");
    command_subtype_rhs = new("journal_command_subtype_rhs");
    command_subtype_lhs.function_kind = command_lhs.function_kind;
    command_subtype_rhs.function_kind = command_rhs.function_kind;
    command_subtype_lhs.function_uid = command_lhs.function_uid;
    command_subtype_rhs.function_uid = command_rhs.function_uid;
    command_subtype_lhs.global_function_id = command_lhs.global_function_id;
    command_subtype_rhs.global_function_id = command_rhs.global_function_id;
    command_subtype_lhs.generation = command_lhs.generation;
    command_subtype_rhs.generation = command_rhs.generation;
    command_subtype_lhs.profile_name = command_lhs.profile_name;
    command_subtype_rhs.profile_name = command_rhs.profile_name;
    command_subtype_lhs.opcode = command_lhs.opcode;
    command_subtype_rhs.opcode = command_rhs.opcode;
    command_subtype_lhs.variant = command_lhs.variant;
    command_subtype_rhs.variant = command_rhs.variant;
    command_subtype_lhs.extension_value = 32'h5555;
    command_subtype_rhs.extension_value = 32'h6666;
    expect_value_contract(
      "JOURNAL_COMMAND_SUBTYPE_EXTENSION_IGNORED",
      rdma_cmq_same_journal_command_identity_value(
        command_subtype_lhs, command_subtype_rhs
      ), 1'b1
    );
    expect_value_contract(
      "JOURNAL_COMMAND_NULL",
      rdma_cmq_same_journal_command_identity_value(command_lhs, null), 1'b0
    );
    expect_value_contract(
      "JOURNAL_COMMAND_NULL_LHS",
      rdma_cmq_same_journal_command_identity_value(null, command_rhs), 1'b0
    );
    command_lhs.function_kind = RDMA_RESOURCE_MR;
    command_rhs.function_kind = RDMA_RESOURCE_MR;
    expect_value_contract(
      "JOURNAL_COMMAND_KIND",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.function_kind = RDMA_RESOURCE_FUNCTION;
    command_rhs.function_kind = RDMA_RESOURCE_FUNCTION;
    command_lhs.function_uid = 0;
    command_rhs.function_uid = 0;
    expect_value_contract(
      "JOURNAL_COMMAND_ZERO_UID",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.function_uid = TEST_FUNCTION_UID;
    command_rhs.function_uid = TEST_FUNCTION_UID;
    command_lhs.generation = 0;
    command_rhs.generation = 0;
    expect_value_contract(
      "JOURNAL_COMMAND_ZERO_GENERATION",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.generation = TEST_GENERATION;
    command_rhs.generation = TEST_GENERATION;
    command_lhs.profile_name = "";
    command_rhs.profile_name = "";
    expect_value_contract(
      "JOURNAL_COMMAND_EMPTY_PROFILE",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.profile_name = "generic_profile";
    command_rhs.profile_name = "generic_profile";
    command_lhs.variant = "";
    command_rhs.variant = "";
    expect_value_contract(
      "JOURNAL_COMMAND_EMPTY_VARIANT",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.variant = "query";
    command_rhs.variant = "query";
    command_rhs.function_uid++;
    expect_value_contract(
      "JOURNAL_COMMAND_UID",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_rhs.function_uid = command_lhs.function_uid;
    command_rhs.global_function_id++;
    expect_value_contract(
      "JOURNAL_COMMAND_GLOBAL_FUNCTION",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_rhs.global_function_id = command_lhs.global_function_id;
    command_rhs.generation++;
    expect_value_contract(
      "JOURNAL_COMMAND_GENERATION",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_rhs.generation = command_lhs.generation;
    command_rhs.profile_name = "other_profile";
    expect_value_contract(
      "JOURNAL_COMMAND_PROFILE",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_rhs.profile_name = command_lhs.profile_name;
    command_rhs.opcode++;
    expect_value_contract(
      "JOURNAL_COMMAND_OPCODE",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_rhs.opcode = command_lhs.opcode;
    command_rhs.variant = "modify";
    expect_value_contract(
      "JOURNAL_COMMAND_VARIANT",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b0
    );
    command_lhs.profile_name = "profile|segment";
    command_rhs.profile_name = command_lhs.profile_name;
    command_lhs.variant = "variant|segment";
    command_rhs.variant = command_lhs.variant;
    expect_value_contract(
      "JOURNAL_COMMAND_SEPARATOR_VALUE",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b1
    );
    command_lhs.global_function_id = 0;
    command_rhs.global_function_id = 0;
    command_lhs.opcode = 0;
    command_rhs.opcode = 0;
    expect_value_contract(
      "JOURNAL_COMMAND_ZERO_GFID_OPCODE",
      rdma_cmq_same_journal_command_identity_value(
        command_lhs, command_rhs
      ), 1'b1
    );
  endfunction

  // 功能：直接刻画 journal Function-binding comparator 的 exact outer/identity gate、
  // PCIe/BAR、DMA/capability、vector、owner、lifecycle 与 readiness 完整投影。
  // 输入/输出及副作用：无显式输入；独立构造 lhs/rhs 及所有嵌套节点，逐项 mutation
  // 后立即恢复；binding accessor 可分配瞬态 status/identity，不调用 engine 或 I/O。
  // 失败/边界：null、registered outer/identity subtype、required PCIe/BAR 缺失、
  // 任一字段/顺序/动态 cardinality 漂移必须返回 0；validator-invalid 但显式投影
  // 相等、PCIe/BAR permissive subtype、both-null owner 与 both-empty vector 保持既有语义。
  function automatic void check_journal_binding_comparator_contract();
    rdma_function_identity identity_lhs;
    rdma_function_identity identity_rhs;
    rdma_function_identity changed_identity;
    rdma_function_binding lhs;
    rdma_function_binding rhs;
    rdma_function_binding changed_binding;
    rdma_function_binding invalid_lhs;
    rdma_function_binding invalid_rhs;
    rdma_function_binding identity_subtype_binding_lhs;
    rdma_function_binding identity_subtype_binding_rhs;
    rdma_cmq_journal_binding_subtype outer_subtype_lhs;
    rdma_cmq_journal_binding_subtype outer_subtype_rhs;
    rdma_cmq_journal_binding_identity_subtype identity_subtype_lhs;
    rdma_cmq_journal_binding_identity_subtype identity_subtype_rhs;
    rdma_cmq_journal_binding_pcie_subtype pcie_subtype_lhs;
    rdma_cmq_journal_binding_pcie_subtype pcie_subtype_rhs;
    rdma_pcie_identity saved_pcie_lhs;
    rdma_pcie_identity saved_pcie_rhs;
    rdma_pcie_identity bar_subtype_pcie_lhs;
    rdma_pcie_identity bar_subtype_pcie_rhs;
    rdma_bar_info saved_bar_lhs;
    rdma_bar_info saved_bar_rhs;
    rdma_bar_info swapped_bar;
    rdma_handle saved_owner_lhs;
    rdma_handle saved_owner_rhs;
    rdma_handle base_owner;
    rdma_cmq_snapshot_handle subtype_owner_lhs;
    rdma_cmq_snapshot_handle subtype_owner_rhs;
    rdma_interrupt_vector_binding extra_vector;
    rdma_interrupt_vector_binding swapped_vector;
    rdma_interrupt_vector_binding saved_vectors_lhs[$];
    rdma_interrupt_vector_binding saved_vectors_rhs[$];
    bit bar_subtype_fixture_detached;

    identity_lhs = make_identity("journal_binding_identity_lhs");
    identity_rhs = make_identity("journal_binding_identity_rhs");
    lhs = make_binding("journal_binding_lhs", identity_lhs);
    rhs = make_binding("journal_binding_rhs", identity_rhs);
    if (lhs == rhs || identity_lhs == identity_rhs ||
        lhs.pcie == rhs.pcie || lhs.pcie.bar[5] == rhs.pcie.bar[5] ||
        lhs.owner_h == rhs.owner_h)
      `uvm_error(
        "JOURNAL_BINDING_COMPARATOR_FIXTURE_DETACHED",
        "independent binding fixtures retained a top-level or nested alias"
      )

    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NULL_BOTH", null, null, 1'b0
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NULL_LHS", null, rhs, 1'b0
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NULL_RHS", lhs, null, 1'b0
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_EQUAL", lhs, rhs, 1'b1
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_ALIAS_EQUAL", lhs, lhs, 1'b1
    );

    outer_subtype_lhs = make_journal_binding_outer_subtype(
      "journal_binding_outer_subtype_lhs", lhs, 32'h1111
    );
    outer_subtype_rhs = make_journal_binding_outer_subtype(
      "journal_binding_outer_subtype_rhs", rhs, 32'h2222
    );
    if (outer_subtype_lhs == null || outer_subtype_rhs == null)
      `uvm_error(
        "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_SETUP",
        "valid detached outer subtype fixture construction failed"
      )
    else begin
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_LHS",
        outer_subtype_lhs, rhs, 1'b0
      );
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_RHS",
        lhs, outer_subtype_rhs, 1'b0
      );
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_BOTH",
        outer_subtype_lhs, outer_subtype_rhs, 1'b0
      );
    end

    saved_pcie_lhs = lhs.pcie;
    saved_pcie_rhs = rhs.pcie;
    lhs.pcie = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_LHS", lhs, rhs, 1'b0
    );
    lhs.pcie = saved_pcie_lhs;
    rhs.pcie = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_RHS", lhs, rhs, 1'b0
    );
    rhs.pcie = saved_pcie_rhs;
    lhs.pcie = null;
    rhs.pcie = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_BOTH", lhs, rhs, 1'b0
    );
    lhs.pcie = saved_pcie_lhs;
    rhs.pcie = saved_pcie_rhs;

    invalid_lhs = new("journal_binding_invalid_identity_lhs");
    invalid_rhs = new("journal_binding_invalid_identity_rhs");
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_INVALID_IDENTITY_EQUAL",
      invalid_lhs, invalid_rhs, 1'b0
    );

    identity_subtype_lhs = make_journal_binding_identity_subtype(
      "journal_binding_identity_subtype_lhs"
    );
    identity_subtype_rhs = make_journal_binding_identity_subtype(
      "journal_binding_identity_subtype_rhs"
    );
    identity_subtype_binding_lhs = make_binding(
      "journal_binding_with_identity_subtype_lhs", identity_subtype_lhs
    );
    identity_subtype_binding_rhs = make_binding(
      "journal_binding_with_identity_subtype_rhs", identity_subtype_rhs
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_BOTH",
      identity_subtype_binding_lhs, identity_subtype_binding_rhs, 1'b0
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_LHS",
      identity_subtype_binding_lhs, rhs, 1'b0
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_RHS",
      lhs, identity_subtype_binding_rhs, 1'b0
    );

    changed_identity = make_identity("journal_binding_epoch_identity");
    changed_identity.reset_epoch++;
    changed_binding = make_binding(
      "journal_binding_epoch_changed", changed_identity
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_IDENTITY_RESET_EPOCH",
      lhs, changed_binding, 1'b0
    );
    changed_identity = make_identity("journal_binding_route_identity");
    changed_identity.key.root_id++;
    changed_binding = make_binding(
      "journal_binding_route_changed", changed_identity
    );
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_IDENTITY_ROUTE",
      lhs, changed_binding, 1'b0
    );

    pcie_subtype_lhs = make_journal_binding_pcie_subtype(
      "journal_binding_pcie_subtype_lhs", lhs.pcie
    );
    pcie_subtype_rhs = make_journal_binding_pcie_subtype(
      "journal_binding_pcie_subtype_rhs", rhs.pcie
    );
    if (pcie_subtype_lhs != null && pcie_subtype_rhs != null) begin
      pcie_subtype_lhs.extension_value = 32'h1111;
      pcie_subtype_rhs.extension_value = 32'h2222;
      lhs.pcie = pcie_subtype_lhs;
      rhs.pcie = pcie_subtype_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_EXTENSION_IGNORED",
        lhs, rhs, 1'b1
      );
      rhs.pcie = saved_pcie_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_BASE",
        lhs, rhs, 1'b1
      );
      lhs.pcie = saved_pcie_lhs;
      rhs.pcie = pcie_subtype_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_PCIE_BASE_SUBTYPE",
        lhs, rhs, 1'b1
      );
      rhs.pcie = saved_pcie_rhs;
    end
    else begin
      `uvm_error(
        "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_FIXTURE",
        "PCIe subtype fixture construction failed"
      )
      lhs.pcie = saved_pcie_lhs;
      rhs.pcie = saved_pcie_rhs;
    end

    bar_subtype_pcie_lhs = make_journal_binding_bar_subtypes(
      "journal_binding_bar_subtypes_lhs", lhs.pcie, 32'hcafe_2000
    );
    bar_subtype_pcie_rhs = make_journal_binding_bar_subtypes(
      "journal_binding_bar_subtypes_rhs", rhs.pcie, 32'hbeef_3000
    );
    bar_subtype_fixture_detached =
      bar_subtype_pcie_lhs != null && bar_subtype_pcie_rhs != null;
    if (bar_subtype_fixture_detached) begin
      bar_subtype_fixture_detached &=
        bar_subtype_pcie_lhs != lhs.pcie &&
        bar_subtype_pcie_rhs != rhs.pcie &&
        bar_subtype_pcie_lhs != bar_subtype_pcie_rhs;
      foreach (bar_subtype_pcie_lhs.bar[i]) begin
        bar_subtype_fixture_detached &=
          bar_subtype_pcie_lhs.bar[i] != lhs.pcie.bar[i] &&
          bar_subtype_pcie_rhs.bar[i] != rhs.pcie.bar[i] &&
          bar_subtype_pcie_lhs.bar[i] != bar_subtype_pcie_rhs.bar[i];
      end
    end
    if (bar_subtype_fixture_detached) begin
      lhs.pcie = bar_subtype_pcie_lhs;
      rhs.pcie = bar_subtype_pcie_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_EXTENSION_IGNORED",
        lhs, rhs, 1'b1
      );
      rhs.pcie = saved_pcie_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_BASE", lhs, rhs, 1'b1
      );
      lhs.pcie = saved_pcie_lhs;
      rhs.pcie = bar_subtype_pcie_rhs;
      expect_journal_binding_contract(
        "JOURNAL_BINDING_COMPARATOR_BAR_BASE_SUBTYPE", lhs, rhs, 1'b1
      );
      rhs.pcie = saved_pcie_rhs;
    end
    else begin
      `uvm_error(
        "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_FIXTURE",
        "BAR subtype fixtures are null or retain a source/cross-fixture alias"
      )
      lhs.pcie = saved_pcie_lhs;
      rhs.pcie = saved_pcie_rhs;
    end

    rhs.function_uid++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_FUNCTION_UID", lhs, rhs, 1'b0
    );
    rhs.function_uid = lhs.function_uid;
    rhs.pcie.bdf.bus++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_BDF", lhs, rhs, 1'b0
    );
    rhs.pcie.bdf = lhs.pcie.bdf;
    rhs.pcie.parent_pf_bdf.bus++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_PARENT_BDF", lhs, rhs, 1'b0
    );
    rhs.pcie.parent_pf_bdf = lhs.pcie.parent_pf_bdf;
    rhs.pcie.vf_index++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_VF_INDEX", lhs, rhs, 1'b0
    );
    rhs.pcie.vf_index = lhs.pcie.vf_index;
    rhs.pcie.mse ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_MSE", lhs, rhs, 1'b0
    );
    rhs.pcie.mse = lhs.pcie.mse;
    rhs.pcie.bme ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PCIE_BME", lhs, rhs, 1'b0
    );
    rhs.pcie.bme = lhs.pcie.bme;

    rhs.notify_bar_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_BAR_ID", lhs, rhs, 1'b0
    );
    rhs.notify_bar_id = lhs.notify_bar_id;
    rhs.notify_base.value++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_BASE", lhs, rhs, 1'b0
    );
    rhs.notify_base = lhs.notify_base;
    rhs.notify_size++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_SIZE", lhs, rhs, 1'b0
    );
    rhs.notify_size = lhs.notify_size;
    rhs.notify_table_sel++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_TABLE_SEL", lhs, rhs, 1'b0
    );
    rhs.notify_table_sel = lhs.notify_table_sel;
    rhs.notify_table_index++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_TABLE_INDEX", lhs, rhs, 1'b0
    );
    rhs.notify_table_index = lhs.notify_table_index;
    rhs.host_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_HOST_ID", lhs, rhs, 1'b0
    );
    rhs.host_id = lhs.host_id;
    rhs.pfvf_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_PFVF_ID", lhs, rhs, 1'b0
    );
    rhs.pfvf_id = lhs.pfvf_id;
    rhs.rdma_vf_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_RDMA_VF_ID", lhs, rhs, 1'b0
    );
    rhs.rdma_vf_id = lhs.rdma_vf_id;
    rhs.global_function_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_GLOBAL_FUNCTION_ID", lhs, rhs, 1'b0
    );
    rhs.global_function_id = lhs.global_function_id;
    rhs.vsi_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VSI_ID", lhs, rhs, 1'b0
    );
    rhs.vsi_id = lhs.vsi_id;

    rhs.queue_dma.requester_bdf.bus++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_REQUESTER_BDF",
      lhs, rhs, 1'b0
    );
    rhs.queue_dma.requester_bdf = lhs.queue_dma.requester_bdf;
    rhs.queue_dma.pasid_valid ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_PASID_VALID",
      lhs, rhs, 1'b0
    );
    rhs.queue_dma.pasid_valid = lhs.queue_dma.pasid_valid;
    rhs.queue_dma.pasid++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_PASID", lhs, rhs, 1'b0
    );
    rhs.queue_dma.pasid = lhs.queue_dma.pasid;
    rhs.queue_dma.dma_domain_valid ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_DOMAIN_VALID",
      lhs, rhs, 1'b0
    );
    rhs.queue_dma.dma_domain_valid = lhs.queue_dma.dma_domain_valid;
    rhs.queue_dma.dma_domain_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_DOMAIN_ID",
      lhs, rhs, 1'b0
    );
    rhs.queue_dma.dma_domain_id = lhs.queue_dma.dma_domain_id;

    rhs.queue_caps.min_cq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MIN_CQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.min_cq_depth = lhs.queue_caps.min_cq_depth;
    rhs.queue_caps.max_cq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_CQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_cq_depth = lhs.queue_caps.max_cq_depth;
    rhs.queue_caps.min_srq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MIN_SRQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.min_srq_depth = lhs.queue_caps.min_srq_depth;
    rhs.queue_caps.max_srq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_SRQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_srq_depth = lhs.queue_caps.max_srq_depth;
    rhs.queue_caps.max_ceq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_CEQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_ceq_depth = lhs.queue_caps.max_ceq_depth;
    rhs.queue_caps.max_aeq_depth++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_AEQ", lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_aeq_depth = lhs.queue_caps.max_aeq_depth;
    rhs.queue_caps.max_wq_sge++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_WQ_SGE", lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_wq_sge = lhs.queue_caps.max_wq_sge;
    rhs.queue_caps.max_queue_ring_bytes++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_RING_BYTES",
      lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_queue_ring_bytes =
      lhs.queue_caps.max_queue_ring_bytes;
    rhs.queue_caps.max_sgb_bytes++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_SGB_BYTES",
      lhs, rhs, 1'b0
    );
    rhs.queue_caps.max_sgb_bytes = lhs.queue_caps.max_sgb_bytes;

    saved_bar_lhs = lhs.pcie.bar[5];
    saved_bar_rhs = rhs.pcie.bar[5];
    lhs.pcie.bar[5] = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR_NULL_LHS", lhs, rhs, 1'b0
    );
    lhs.pcie.bar[5] = saved_bar_lhs;
    rhs.pcie.bar[5] = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR_NULL_RHS", lhs, rhs, 1'b0
    );
    rhs.pcie.bar[5] = saved_bar_rhs;
    lhs.pcie.bar[5] = null;
    rhs.pcie.bar[5] = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR_NULL_BOTH", lhs, rhs, 1'b0
    );
    lhs.pcie.bar[5] = saved_bar_lhs;
    rhs.pcie.bar[5] = saved_bar_rhs;
    rhs.pcie.bar[5].bar_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR5_ID", lhs, rhs, 1'b0
    );
    rhs.pcie.bar[5].bar_id = lhs.pcie.bar[5].bar_id;
    rhs.pcie.bar[5].base.value++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR5_BASE", lhs, rhs, 1'b0
    );
    rhs.pcie.bar[5].base = lhs.pcie.bar[5].base;
    rhs.pcie.bar[5].size++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR5_SIZE", lhs, rhs, 1'b0
    );
    rhs.pcie.bar[5].size = lhs.pcie.bar[5].size;
    rhs.pcie.bar[5].enabled ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR5_ENABLED", lhs, rhs, 1'b0
    );
    rhs.pcie.bar[5].enabled = lhs.pcie.bar[5].enabled;
    swapped_bar = rhs.pcie.bar[4];
    rhs.pcie.bar[4] = rhs.pcie.bar[5];
    rhs.pcie.bar[5] = swapped_bar;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_BAR_ORDER", lhs, rhs, 1'b0
    );
    swapped_bar = rhs.pcie.bar[4];
    rhs.pcie.bar[4] = rhs.pcie.bar[5];
    rhs.pcie.bar[5] = swapped_bar;

    extra_vector = rhs.interrupt_vectors[1];
    extra_vector.function_local_vector++;
    rhs.interrupt_vectors.push_back(extra_vector);
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_RHS_EXTRA", lhs, rhs, 1'b0
    );
    void'(rhs.interrupt_vectors.pop_back());
    extra_vector = lhs.interrupt_vectors[1];
    extra_vector.hardware_eq_vector++;
    lhs.interrupt_vectors.push_back(extra_vector);
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_LHS_EXTRA", lhs, rhs, 1'b0
    );
    void'(lhs.interrupt_vectors.pop_back());
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_CARDINALITY_RESTORED",
      lhs, rhs, 1'b1
    );
    rhs.interrupt_vectors[1].function_local_vector++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_FUNCTION_LOCAL", lhs, rhs, 1'b0
    );
    rhs.interrupt_vectors[1].function_local_vector =
      lhs.interrupt_vectors[1].function_local_vector;
    rhs.interrupt_vectors[1].hardware_eq_vector++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_HARDWARE_EQ", lhs, rhs, 1'b0
    );
    rhs.interrupt_vectors[1].hardware_eq_vector =
      lhs.interrupt_vectors[1].hardware_eq_vector;
    rhs.interrupt_vectors[1].msix_table_index++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_MSIX_INDEX", lhs, rhs, 1'b0
    );
    rhs.interrupt_vectors[1].msix_table_index =
      lhs.interrupt_vectors[1].msix_table_index;
    rhs.interrupt_vectors[1].enabled ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_ENABLED", lhs, rhs, 1'b0
    );
    rhs.interrupt_vectors[1].enabled = lhs.interrupt_vectors[1].enabled;
    swapped_vector = rhs.interrupt_vectors[0];
    rhs.interrupt_vectors[0] = rhs.interrupt_vectors[1];
    rhs.interrupt_vectors[1] = swapped_vector;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_ORDER", lhs, rhs, 1'b0
    );
    swapped_vector = rhs.interrupt_vectors[0];
    rhs.interrupt_vectors[0] = rhs.interrupt_vectors[1];
    rhs.interrupt_vectors[1] = swapped_vector;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_RESTORED", lhs, rhs, 1'b1
    );
    saved_vectors_lhs = lhs.interrupt_vectors;
    saved_vectors_rhs = rhs.interrupt_vectors;
    lhs.interrupt_vectors.delete();
    rhs.interrupt_vectors.delete();
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VECTOR_BOTH_EMPTY", lhs, rhs, 1'b1
    );
    lhs.interrupt_vectors = saved_vectors_lhs;
    rhs.interrupt_vectors = saved_vectors_rhs;

    rhs.state = RDMA_BIND_PREPARED;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_STATE", lhs, rhs, 1'b0
    );
    rhs.state = lhs.state;
    rhs.generation++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_GENERATION", lhs, rhs, 1'b0
    );
    rhs.generation = lhs.generation;
    rhs.notify_valid ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_VALID", lhs, rhs, 1'b0
    );
    rhs.notify_valid = lhs.notify_valid;
    rhs.notify_ready ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_NOTIFY_READY", lhs, rhs, 1'b0
    );
    rhs.notify_ready = lhs.notify_ready;
    rhs.dmi_valid ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_DMI_VALID", lhs, rhs, 1'b0
    );
    rhs.dmi_valid = lhs.dmi_valid;
    rhs.dmi_ready ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_DMI_READY", lhs, rhs, 1'b0
    );
    rhs.dmi_ready = lhs.dmi_ready;
    rhs.vft_valid ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VFT_VALID", lhs, rhs, 1'b0
    );
    rhs.vft_valid = lhs.vft_valid;
    rhs.vft_ready ^= 1'b1;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VFT_READY", lhs, rhs, 1'b0
    );
    rhs.vft_ready = lhs.vft_ready;

    saved_owner_lhs = lhs.owner_h;
    saved_owner_rhs = rhs.owner_h;
    rhs.owner_h = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_RHS", lhs, rhs, 1'b0
    );
    rhs.owner_h = saved_owner_rhs;
    lhs.owner_h = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_LHS", lhs, rhs, 1'b0
    );
    rhs.owner_h = null;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_BOTH", lhs, rhs, 1'b1
    );
    lhs.owner_h = saved_owner_lhs;
    rhs.owner_h = saved_owner_rhs;
    rhs.owner_h.object_id++;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_INCARNATION", lhs, rhs, 1'b0
    );
    rhs.owner_h.object_id = lhs.owner_h.object_id;
    base_owner = new("journal_binding_base_owner");
    base_owner.kind = lhs.owner_h.kind;
    base_owner.function_uid = lhs.owner_h.function_uid;
    base_owner.object_id = lhs.owner_h.object_id;
    base_owner.generation = lhs.owner_h.generation;
    rhs.owner_h = base_owner;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_WRAPPER", lhs, rhs, 1'b0
    );

    subtype_owner_lhs = new("journal_binding_subtype_owner_lhs");
    subtype_owner_rhs = new("journal_binding_subtype_owner_rhs");
    fill_snapshot_handle(
      subtype_owner_lhs, RDMA_RESOURCE_FUNCTION, lhs.owner_h.object_id
    );
    fill_snapshot_handle(
      subtype_owner_rhs, RDMA_RESOURCE_FUNCTION, lhs.owner_h.object_id
    );
    subtype_owner_lhs.extension_value = 32'h1111;
    subtype_owner_rhs.extension_value = 32'h2222;
    subtype_owner_lhs.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    subtype_owner_rhs.clone_mode = RDMA_CMQ_SNAPSHOT_CLONE_MUTATE;
    lhs.owner_h = subtype_owner_lhs;
    rhs.owner_h = subtype_owner_rhs;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_OWNER_SUBTYPE_EXTENSION_IGNORED",
      lhs, rhs, 1'b1
    );
    if (subtype_owner_lhs.clone_calls != 0 ||
        subtype_owner_rhs.clone_calls != 0 ||
        subtype_owner_lhs.object_id != saved_owner_lhs.object_id ||
        subtype_owner_rhs.object_id != saved_owner_rhs.object_id)
      `uvm_error(
        "JOURNAL_BINDING_COMPARATOR_OWNER_SUBTYPE_NO_CLONE",
        "binding comparator cloned or mutated a subtype owner"
      )
    lhs.owner_h = saved_owner_lhs;
    rhs.owner_h = saved_owner_rhs;

    lhs.queue_caps.min_cq_depth = 0;
    rhs.queue_caps.min_cq_depth = 0;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_VALIDATOR_INVALID_EQUAL",
      lhs, rhs, 1'b1
    );
    lhs.queue_caps.min_cq_depth = 16;
    rhs.queue_caps.min_cq_depth = 16;
    expect_journal_binding_contract(
      "JOURNAL_BINDING_COMPARATOR_RESTORED", lhs, rhs, 1'b1
    );
  endfunction

  // 功能：直接刻画 recovery batch 的有序 item tuple package 谓词，对照独立的
  // request/journal item 图，冻结 null、数量、顺序、三列差异与重复相等值。
  // 输入/输出及副作用：无显式输入；构造局部 fixture，逐项 mutation 并恢复，
  // 通过 expect helper 同时断言结果与每次调用后输入图不变，不触发 engine/I/O。
  // 失败/边界：empty/null item 必须拒绝；非 tuple 字段不参与相等判定；digest
  // typedef 是 bit[255:0]，X 输入在写入时归零，不能把用例误称为运行时四态覆盖。
  function automatic void check_journal_ordered_item_tuple_contract();
    rdma_cmq_submission_recovery_request request;
    rdma_cmq_batch_submission_record journal_record;
    rdma_cmq_submission_recovery_item request_items[$];
    rdma_cmq_batch_submission_item_record record_items[$];
    rdma_cmq_submission_recovery_item extra_request;
    rdma_cmq_batch_submission_item_record extra_record;
    rdma_cmq_batch_submission_item_record swapped_record;
    int unsigned second_request_index;
    rdma_cmq_journal_digest_t second_request_image;
    rdma_cmq_journal_digest_t second_record_image;
    rdma_cmq_journal_digest_t second_request_authority;
    rdma_cmq_journal_digest_t second_record_authority;
    logic [255:0] four_state_digest;

    make_journal_ordered_tuple_fixture(
      "journal_ordered_tuple", request, journal_record
    );
    request_items = request.items;
    record_items = journal_record.items;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_BOTH", null, null, 1'b0
    );
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_REQUEST", null, journal_record, 1'b0
    );
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_RECORD", request, null, 1'b0
    );

    request.items.delete();
    journal_record.items.delete();
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_EMPTY_BOTH", request, journal_record, 1'b0
    );
    journal_record.items = record_items;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_EMPTY_REQUEST", request, journal_record, 1'b0
    );
    request.items = request_items;
    journal_record.items.delete();
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_EMPTY_RECORD", request, journal_record, 1'b0
    );
    journal_record.items = record_items;

    void'(request.items.pop_back());
    void'(journal_record.items.pop_back());
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_SINGLE_EQUAL", request, journal_record, 1'b1
    );
    request.items = request_items;
    journal_record.items = record_items;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_MULTI_EQUAL_IGNORES_OTHER_FIELDS",
      request, journal_record, 1'b1
    );

    extra_request = new("journal_ordered_tuple_extra_request");
    request.items.push_back(extra_request);
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_REQUEST_EXTRA", request, journal_record, 1'b0
    );
    void'(request.items.pop_back());
    extra_record = new("journal_ordered_tuple_extra_record");
    journal_record.items.push_back(extra_record);
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_RECORD_EXTRA", request, journal_record, 1'b0
    );
    void'(journal_record.items.pop_back());
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_CARDINALITY_RESTORED",
      request, journal_record, 1'b1
    );

    request.items[1] = null;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_REQUEST_ITEM",
      request, journal_record, 1'b0
    );
    request.items[1] = request_items[1];
    journal_record.items[1] = null;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_RECORD_ITEM",
      request, journal_record, 1'b0
    );
    request.items[1] = null;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NULL_BOTH_ITEMS",
      request, journal_record, 1'b0
    );
    request.items[1] = request_items[1];
    journal_record.items[1] = record_items[1];

    journal_record.items[1].request_index++;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_REQUEST_INDEX", request, journal_record, 1'b0
    );
    journal_record.items[1].request_index = request.items[1].request_index;
    journal_record.items[1].image_digest ^= 256'h1;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_IMAGE_DIGEST", request, journal_record, 1'b0
    );
    journal_record.items[1].image_digest = request.items[1].image_digest;
    journal_record.items[1].authority_digest ^= 256'h1;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_AUTHORITY_DIGEST",
      request, journal_record, 1'b0
    );
    journal_record.items[1].authority_digest =
      request.items[1].authority_digest;

    swapped_record = journal_record.items[0];
    journal_record.items[0] = journal_record.items[1];
    journal_record.items[1] = swapped_record;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_ORDER", request, journal_record, 1'b0
    );
    swapped_record = journal_record.items[0];
    journal_record.items[0] = journal_record.items[1];
    journal_record.items[1] = swapped_record;

    second_request_index = request.items[1].request_index;
    second_request_image = request.items[1].image_digest;
    second_record_image = journal_record.items[1].image_digest;
    second_request_authority = request.items[1].authority_digest;
    second_record_authority = journal_record.items[1].authority_digest;
    request.items[1].request_index = request.items[0].request_index;
    journal_record.items[1].request_index =
      journal_record.items[0].request_index;
    request.items[1].image_digest = request.items[0].image_digest;
    journal_record.items[1].image_digest =
      journal_record.items[0].image_digest;
    request.items[1].authority_digest = request.items[0].authority_digest;
    journal_record.items[1].authority_digest =
      journal_record.items[0].authority_digest;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_DUPLICATE_EQUAL", request, journal_record, 1'b1
    );
    request.items[1].request_index = second_request_index;
    journal_record.items[1].request_index = second_request_index;
    request.items[1].image_digest = second_request_image;
    journal_record.items[1].image_digest = second_record_image;
    request.items[1].authority_digest = second_request_authority;
    journal_record.items[1].authority_digest = second_record_authority;

    four_state_digest = 'x;
    request.items[1].image_digest = four_state_digest;
    journal_record.items[1].image_digest = '0;
    if (!$isunknown(four_state_digest) ||
        request.items[1].image_digest !== '0 ||
        journal_record.items[1].image_digest !== '0)
      `uvm_error(
        "JOURNAL_ORDERED_TUPLE_DIGEST_X_NORMALIZATION",
        "four-state input did not normalize in the two-state digest field"
      )
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_NORMALIZED_DIGEST_EQUAL",
      request, journal_record, 1'b1
    );
    request.items[1].image_digest = second_request_image;
    journal_record.items[1].image_digest = second_record_image;
    expect_journal_ordered_tuple_contract(
      "JOURNAL_ORDERED_TUPLE_RESTORED", request, journal_record, 1'b1
    );
  endfunction

  // 功能：直接验证 CMQ 共享值契约的 null、shape、instance/detached 语义，
  //   并对 handle/ticket 的每项 mutation 同时检查 instance 与 detached helper。
  // 输入/输出及副作用：无显式输入或返回值；创建测试局部
  //   handle/status/image/mapping/ticket 值，并用唯一 UVM check_name 发布契约偏差。
  // 失败/边界：每次 mutation 后都恢复基线；不调用 engine、adapter 或 I/O，
  //   不把 same_instance 值相等误解为 SystemVerilog 引用 alias。
  function automatic void check_cmq_value_contract();
    rdma_handle handle_lhs;
    rdma_handle handle_rhs;
    logic [3:0] unknown_kind_source;
    logic [63:0] unknown_uid_source;
    rdma_status status_lhs;
    rdma_status status_rhs;
    rdma_cmq_spoofed_status_subtype status_subtype;
    byte unsigned byte_lhs[$];
    byte unsigned byte_rhs[$];
    string string_lhs[$];
    string string_rhs[$];
    rdma_hw_image image_lhs;
    rdma_hw_image image_rhs;
    rdma_cmq_expected_response expected_lhs;
    rdma_cmq_expected_response expected_rhs;
    rdma_cmq_opcode_key opcode_lhs;
    rdma_cmq_opcode_key opcode_rhs;
    rdma_bdf_t bdf_lhs;
    rdma_bdf_t bdf_rhs;
    rdma_function_identity mapping_identity;
    rdma_dma_mapping mapping_lhs;
    rdma_dma_mapping mapping_rhs;
    rdma_function_handle function_lhs;
    rdma_function_handle function_rhs;
    rdma_handle cmq_lhs;
    rdma_handle cmq_rhs;
    rdma_cmq_ticket ticket_lhs;
    rdma_cmq_ticket ticket_shared;
    rdma_cmq_ticket ticket_detached;

    // Handle instance/value 两个 API 都比较 incarnation 值，不把对象引用相等当作隐含条件。
    handle_lhs = new("value_contract_handle_lhs");
    handle_rhs = new("value_contract_handle_rhs");
    handle_lhs.kind = RDMA_RESOURCE_MR;
    handle_lhs.function_uid = TEST_FUNCTION_UID;
    handle_lhs.object_id = 32'h88;
    handle_lhs.generation = TEST_GENERATION;
    handle_rhs.kind = handle_lhs.kind;
    handle_rhs.function_uid = handle_lhs.function_uid;
    handle_rhs.object_id = handle_lhs.object_id;
    handle_rhs.generation = handle_lhs.generation;
    if (handle_lhs == handle_rhs)
      `uvm_error("VALUE_HANDLE_FIXTURE",
                 "detached handle fixture unexpectedly aliases source")
    expect_value_contract(
      "VALUE_HANDLE_SAME_OBJECT",
      rdma_cmq_same_handle_instance(handle_lhs, handle_lhs), 1'b1
    );
    expect_value_contract(
      "VALUE_HANDLE_DETACHED_INSTANCE",
      rdma_cmq_same_handle_instance(handle_lhs, handle_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_HANDLE_DETACHED_VALUE",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_HANDLE_NULL_INSTANCE",
      rdma_cmq_same_handle_instance(null, handle_rhs), 1'b0
    );
    expect_value_contract(
      "VALUE_HANDLE_NULL_VALUE",
      rdma_cmq_same_handle_value(handle_lhs, null), 1'b0
    );

    handle_rhs.kind = RDMA_RESOURCE_CQ;
    expect_value_contract(
      "VALUE_HANDLE_KIND_INSTANCE",
      rdma_cmq_same_handle_instance(handle_lhs, handle_rhs), 1'b0
    );
    expect_value_contract(
      "VALUE_HANDLE_KIND_DETACHED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.kind = handle_lhs.kind;
    handle_rhs.function_uid++;
    expect_value_contract(
      "VALUE_HANDLE_FUNCTION_UID_INSTANCE",
      rdma_cmq_same_handle_instance(handle_lhs, handle_rhs), 1'b0
    );
    expect_value_contract(
      "VALUE_HANDLE_FUNCTION_UID_DETACHED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.function_uid = handle_lhs.function_uid;
    handle_rhs.object_id++;
    expect_value_contract(
      "VALUE_HANDLE_OBJECT_ID_INSTANCE",
      rdma_cmq_same_handle_instance(handle_lhs, handle_rhs), 1'b0
    );
    expect_value_contract(
      "VALUE_HANDLE_OBJECT_ID_DETACHED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.object_id = handle_lhs.object_id;
    handle_rhs.generation++;
    expect_value_contract(
      "VALUE_HANDLE_GENERATION_INSTANCE",
      rdma_cmq_same_handle_instance(handle_lhs, handle_rhs), 1'b0
    );
    expect_value_contract(
      "VALUE_HANDLE_GENERATION_DETACHED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.generation = handle_lhs.generation;

    // rdma_handle 公开字段是二态类型；四态源的 X/Z 强转会归并为 0。
    // 此处只证明归并后的 0 不会误匹配非零有效 fixture，不宣称直接覆盖 $isunknown 分支。
    unknown_kind_source = 4'bxxxx;
    handle_rhs.kind = rdma_resource_kind_e'(unknown_kind_source);
    expect_value_contract(
      "VALUE_HANDLE_X_SOURCE_NORMALIZED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.kind = handle_lhs.kind;
    unknown_uid_source = 64'bz;
    handle_rhs.function_uid = unknown_uid_source;
    expect_value_contract(
      "VALUE_HANDLE_Z_SOURCE_NORMALIZED",
      rdma_cmq_same_handle_value(handle_lhs, handle_rhs), 1'b0
    );
    handle_rhs.function_uid = handle_lhs.function_uid;

    // Status 基线使用 exact base wrapper，随后覆盖 shape gate 和每个已比较字段。
    status_lhs = new("value_contract_status_lhs");
    status_rhs = new("value_contract_status_rhs");
    status_lhs.category = RDMA_STATUS_DMA;
    status_lhs.code = RDMA_SC_DMA_PERMISSION;
    status_lhs.hardware_code = 32'ha5a5_5a5a;
    status_lhs.hardware_code_valid = 1'b1;
    status_lhs.source_engine = RDMA_ENGINE_DMA;
    status_lhs.function_uid = TEST_FUNCTION_UID;
    status_lhs.generation = TEST_GENERATION;
    status_lhs.resource_id = 64'h101;
    status_lhs.command_id = 64'h202;
    status_lhs.wr_id = 64'h303;
    status_lhs.severity = RDMA_SEVERITY_ERROR;
    status_lhs.retryable = 1'b1;
    status_lhs.message = "value contract status";
    status_rhs.copy(status_lhs);
    expect_value_contract(
      "VALUE_STATUS_EQUAL",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_STATUS_NULL",
      rdma_cmq_same_status_value(null, status_rhs), 1'b0
    );
    status_subtype = new("value_contract_status_subtype");
    expect_value_contract(
      "VALUE_STATUS_SUBTYPE",
      rdma_cmq_same_status_value(status_subtype, status_subtype), 1'b0
    );

    status_rhs.category = RDMA_STATUS_STATE;
    expect_value_contract(
      "VALUE_STATUS_CATEGORY",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.category = status_lhs.category;
    status_rhs.code = RDMA_SC_DMA_TRANSLATION;
    expect_value_contract(
      "VALUE_STATUS_CODE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.code = status_lhs.code;
    status_rhs.hardware_code++;
    expect_value_contract(
      "VALUE_STATUS_HARDWARE_CODE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.hardware_code = status_lhs.hardware_code;
    status_rhs.hardware_code_valid = !status_lhs.hardware_code_valid;
    expect_value_contract(
      "VALUE_STATUS_HARDWARE_VALID",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.hardware_code_valid = status_lhs.hardware_code_valid;
    status_rhs.source_engine = RDMA_ENGINE_CMQ;
    expect_value_contract(
      "VALUE_STATUS_SOURCE_ENGINE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.source_engine = status_lhs.source_engine;
    status_rhs.function_uid++;
    expect_value_contract(
      "VALUE_STATUS_FUNCTION_UID",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.function_uid = status_lhs.function_uid;
    status_rhs.generation++;
    expect_value_contract(
      "VALUE_STATUS_GENERATION",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.generation = status_lhs.generation;
    status_rhs.resource_id++;
    expect_value_contract(
      "VALUE_STATUS_RESOURCE_ID",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.resource_id = status_lhs.resource_id;
    status_rhs.command_id++;
    expect_value_contract(
      "VALUE_STATUS_COMMAND_ID",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.command_id = status_lhs.command_id;
    status_rhs.wr_id++;
    expect_value_contract(
      "VALUE_STATUS_WR_ID",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.wr_id = status_lhs.wr_id;
    status_rhs.severity = RDMA_SEVERITY_FATAL;
    expect_value_contract(
      "VALUE_STATUS_SEVERITY",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.severity = status_lhs.severity;
    status_rhs.retryable = !status_lhs.retryable;
    expect_value_contract(
      "VALUE_STATUS_RETRYABLE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.retryable = status_lhs.retryable;
    status_rhs.message = "mutated value contract status";
    expect_value_contract(
      "VALUE_STATUS_MESSAGE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.message = status_lhs.message;

    status_rhs.category = rdma_status_category_e'(4'hf);
    expect_value_contract(
      "VALUE_STATUS_CATEGORY_SHAPE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.category = status_lhs.category;
    status_rhs.code = rdma_status_code_e'(5'h1f);
    expect_value_contract(
      "VALUE_STATUS_CODE_SHAPE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.code = status_lhs.code;
    status_rhs.source_engine = rdma_engine_kind_e'(4'hf);
    expect_value_contract(
      "VALUE_STATUS_ENGINE_SHAPE",
      rdma_cmq_same_status_value(status_lhs, status_rhs), 1'b0
    );
    status_rhs.source_engine = status_lhs.source_engine;

    // Queue helper 显式覆盖空值、cardinality 以及首/中/尾 mutation。
    expect_value_contract(
      "VALUE_BYTE_EMPTY",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b1
    );
    byte_rhs.push_back(8'h11);
    expect_value_contract(
      "VALUE_BYTE_LENGTH",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b0
    );
    byte_lhs = '{8'h11, 8'h22, 8'h33};
    byte_rhs = byte_lhs;
    byte_rhs[0]++;
    expect_value_contract(
      "VALUE_BYTE_FIRST",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b0
    );
    byte_rhs = byte_lhs;
    byte_rhs[1]++;
    expect_value_contract(
      "VALUE_BYTE_MIDDLE",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b0
    );
    byte_rhs = byte_lhs;
    byte_rhs[2]++;
    expect_value_contract(
      "VALUE_BYTE_LAST",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b0
    );
    byte_rhs = byte_lhs;
    expect_value_contract(
      "VALUE_BYTE_EQUAL",
      rdma_cmq_same_byte_queue_value(byte_lhs, byte_rhs), 1'b1
    );

    expect_value_contract(
      "VALUE_STRING_EMPTY",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b1
    );
    string_rhs.push_back("first");
    expect_value_contract(
      "VALUE_STRING_LENGTH",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b0
    );
    string_lhs = '{"first", "middle", "last"};
    string_rhs = string_lhs;
    string_rhs[0] = "mutated-first";
    expect_value_contract(
      "VALUE_STRING_FIRST",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b0
    );
    string_rhs = string_lhs;
    string_rhs[1] = "mutated-middle";
    expect_value_contract(
      "VALUE_STRING_MIDDLE",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b0
    );
    string_rhs = string_lhs;
    string_rhs[2] = "mutated-last";
    expect_value_contract(
      "VALUE_STRING_LAST",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b0
    );
    string_rhs = string_lhs;
    expect_value_contract(
      "VALUE_STRING_EQUAL",
      rdma_cmq_same_string_queue_value(string_lhs, string_rhs), 1'b1
    );

    // Image 矩阵分别改写 bytes、metadata、write target、三种目标地址与 summary。
    image_lhs = make_image(
      "value_contract_image_lhs", RDMA_IMAGE_CMQ_SQE, 3, TEST_GENERATION
    );
    image_rhs = make_image(
      "value_contract_image_rhs", RDMA_IMAGE_CMQ_SQE, 3, TEST_GENERATION
    );
    image_lhs.write_target_kind = RDMA_HW_TARGET_BACKING;
    image_lhs.backing_target.value = 64'h1000;
    image_lhs.hmc_target.value = 64'h2000;
    image_lhs.bar_target.value = 64'h3000;
    image_lhs.field_summary = '{"opcode", "owner", "signature"};
    image_rhs.write_target_kind = image_lhs.write_target_kind;
    image_rhs.backing_target = image_lhs.backing_target;
    image_rhs.hmc_target = image_lhs.hmc_target;
    image_rhs.bar_target = image_lhs.bar_target;
    image_rhs.field_summary = image_lhs.field_summary;
    expect_value_contract(
      "VALUE_IMAGE_EQUAL",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_IMAGE_NULL", rdma_cmq_same_image_value(image_lhs, null), 1'b0
    );
    image_rhs.bytes.push_back(8'h5a);
    expect_value_contract(
      "VALUE_IMAGE_BYTE_LENGTH",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.bytes = image_lhs.bytes;
    image_rhs.bytes[1]++;
    expect_value_contract(
      "VALUE_IMAGE_BYTE_CONTENT",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.bytes = image_lhs.bytes;
    image_rhs.length++;
    expect_value_contract(
      "VALUE_IMAGE_LENGTH",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.length = image_lhs.length;
    image_rhs.alignment++;
    expect_value_contract(
      "VALUE_IMAGE_ALIGNMENT",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.alignment = image_lhs.alignment;
    image_rhs.endian = RDMA_ENDIAN_LITTLE;
    expect_value_contract(
      "VALUE_IMAGE_ENDIAN",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.endian = image_lhs.endian;
    image_rhs.image_kind = RDMA_IMAGE_CMQ_CQE;
    expect_value_contract(
      "VALUE_IMAGE_KIND",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.image_kind = image_lhs.image_kind;
    image_rhs.hardware_version++;
    expect_value_contract(
      "VALUE_IMAGE_HARDWARE_VERSION",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.hardware_version = image_lhs.hardware_version;
    image_rhs.function_generation++;
    expect_value_contract(
      "VALUE_IMAGE_GENERATION",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.function_generation = image_lhs.function_generation;
    image_rhs.write_target_kind = RDMA_HW_TARGET_HMC_FVM;
    expect_value_contract(
      "VALUE_IMAGE_WRITE_TARGET",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.write_target_kind = image_lhs.write_target_kind;
    image_rhs.backing_target.value++;
    expect_value_contract(
      "VALUE_IMAGE_BACKING_TARGET",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.backing_target = image_lhs.backing_target;
    image_rhs.hmc_target.value++;
    expect_value_contract(
      "VALUE_IMAGE_HMC_TARGET",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.hmc_target = image_lhs.hmc_target;
    image_rhs.bar_target.value++;
    expect_value_contract(
      "VALUE_IMAGE_BAR_TARGET",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.bar_target = image_lhs.bar_target;
    image_rhs.field_summary[1] = "mutated-owner";
    expect_value_contract(
      "VALUE_IMAGE_SUMMARY",
      rdma_cmq_same_image_value(image_lhs, image_rhs), 1'b0
    );
    image_rhs.field_summary = image_lhs.field_summary;

    // Expected response 和 opcode key 分别覆盖 null 与所有公开字段的单项 mutation。
    expected_lhs = new("value_contract_expected_lhs");
    expected_rhs = new("value_contract_expected_rhs");
    expected_lhs.hardware_opcode = 32'h1020_3040;
    expected_lhs.variant = "query";
    expected_rhs.hardware_opcode = expected_lhs.hardware_opcode;
    expected_rhs.variant = expected_lhs.variant;
    expect_value_contract(
      "VALUE_EXPECTED_EQUAL",
      rdma_cmq_same_expected_value(expected_lhs, expected_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_EXPECTED_NULL",
      rdma_cmq_same_expected_value(null, expected_rhs), 1'b0
    );
    expected_rhs.hardware_opcode++;
    expect_value_contract(
      "VALUE_EXPECTED_OPCODE",
      rdma_cmq_same_expected_value(expected_lhs, expected_rhs), 1'b0
    );
    expected_rhs.hardware_opcode = expected_lhs.hardware_opcode;
    expected_rhs.variant = "mutated";
    expect_value_contract(
      "VALUE_EXPECTED_VARIANT",
      rdma_cmq_same_expected_value(expected_lhs, expected_rhs), 1'b0
    );

    opcode_lhs = make_key("value_contract_opcode_lhs");
    opcode_rhs = make_key("value_contract_opcode_rhs");
    expect_value_contract(
      "VALUE_OPCODE_EQUAL",
      rdma_cmq_same_opcode_value(opcode_lhs, opcode_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_OPCODE_NULL",
      rdma_cmq_same_opcode_value(opcode_lhs, null), 1'b0
    );
    opcode_rhs.profile_name = "mutated_profile";
    expect_value_contract(
      "VALUE_OPCODE_PROFILE",
      rdma_cmq_same_opcode_value(opcode_lhs, opcode_rhs), 1'b0
    );
    opcode_rhs.profile_name = opcode_lhs.profile_name;
    opcode_rhs.opcode++;
    expect_value_contract(
      "VALUE_OPCODE_VALUE",
      rdma_cmq_same_opcode_value(opcode_lhs, opcode_rhs), 1'b0
    );
    opcode_rhs.opcode = opcode_lhs.opcode;
    opcode_rhs.variant = "mutated_variant";
    expect_value_contract(
      "VALUE_OPCODE_VARIANT",
      rdma_cmq_same_opcode_value(opcode_lhs, opcode_rhs), 1'b0
    );
    opcode_rhs.variant = opcode_lhs.variant;

    // BDF helper 保留整体 `==` 表达式，四个坐标任一改变都必须不等。
    bdf_lhs = '{
      segment:16'h1, bus:8'h20, device:5'h3, function_num:3'h1
    };
    bdf_rhs = bdf_lhs;
    expect_value_contract(
      "VALUE_BDF_EQUAL", rdma_cmq_same_bdf_value(bdf_lhs, bdf_rhs), 1'b1
    );
    bdf_rhs.segment++;
    expect_value_contract(
      "VALUE_BDF_SEGMENT", rdma_cmq_same_bdf_value(bdf_lhs, bdf_rhs), 1'b0
    );
    bdf_rhs = bdf_lhs;
    bdf_rhs.bus++;
    expect_value_contract(
      "VALUE_BDF_BUS", rdma_cmq_same_bdf_value(bdf_lhs, bdf_rhs), 1'b0
    );
    bdf_rhs = bdf_lhs;
    bdf_rhs.device++;
    expect_value_contract(
      "VALUE_BDF_DEVICE", rdma_cmq_same_bdf_value(bdf_lhs, bdf_rhs), 1'b0
    );
    bdf_rhs = bdf_lhs;
    bdf_rhs.function_num++;
    expect_value_contract(
      "VALUE_BDF_FUNCTION", rdma_cmq_same_bdf_value(bdf_lhs, bdf_rhs),
      1'b0
    );

    // Mapping 的嵌套 handle 是独立对象但 incarnation 值相同；随后逐项改写现有权威字段。
    mapping_identity = make_identity("value_contract_mapping_identity");
    mapping_lhs = make_mapping("value_contract_mapping_lhs", mapping_identity);
    mapping_rhs = make_mapping("value_contract_mapping_rhs", mapping_identity);
    if (mapping_lhs.function_h == mapping_rhs.function_h ||
        mapping_lhs.owner_h == mapping_rhs.owner_h)
      `uvm_error("VALUE_MAPPING_FIXTURE",
                 "detached mapping handles unexpectedly alias source")
    expect_value_contract(
      "VALUE_MAPPING_EQUAL",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b1
    );
    expect_value_contract(
      "VALUE_MAPPING_NULL",
      rdma_cmq_same_mapping_instance_value(null, mapping_rhs), 1'b0
    );
    mapping_rhs.function_h = null;
    expect_value_contract(
      "VALUE_MAPPING_NULL_FUNCTION",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.function_h = make_function("value_contract_mapping_function");
    mapping_rhs.function_h.generation++;
    expect_value_contract(
      "VALUE_MAPPING_FUNCTION",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.function_h.generation = mapping_lhs.function_h.generation;
    mapping_rhs.requester_bdf.bus++;
    expect_value_contract(
      "VALUE_MAPPING_BDF",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.requester_bdf = mapping_lhs.requester_bdf;
    mapping_rhs.pasid_valid = !mapping_lhs.pasid_valid;
    expect_value_contract(
      "VALUE_MAPPING_PASID_VALID",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.pasid_valid = mapping_lhs.pasid_valid;
    mapping_rhs.pasid++;
    expect_value_contract(
      "VALUE_MAPPING_PASID",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.pasid = mapping_lhs.pasid;
    mapping_rhs.dma_domain_valid = !mapping_lhs.dma_domain_valid;
    expect_value_contract(
      "VALUE_MAPPING_DOMAIN_VALID",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.dma_domain_valid = mapping_lhs.dma_domain_valid;
    mapping_rhs.dma_domain_id++;
    expect_value_contract(
      "VALUE_MAPPING_DOMAIN_ID",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.dma_domain_id = mapping_lhs.dma_domain_id;
    mapping_rhs.backing_addr.value++;
    expect_value_contract(
      "VALUE_MAPPING_BACKING",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.backing_addr = mapping_lhs.backing_addr;
    mapping_rhs.iova.value++;
    expect_value_contract(
      "VALUE_MAPPING_IOVA",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.iova = mapping_lhs.iova;
    mapping_rhs.size++;
    expect_value_contract(
      "VALUE_MAPPING_SIZE",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.size = mapping_lhs.size;
    mapping_rhs.direction = RDMA_DMA_DEVICE_WRITE;
    expect_value_contract(
      "VALUE_MAPPING_DIRECTION",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.direction = mapping_lhs.direction;
    mapping_rhs.permissions.atomic = !mapping_lhs.permissions.atomic;
    expect_value_contract(
      "VALUE_MAPPING_PERMISSIONS",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.permissions = mapping_lhs.permissions;
    mapping_rhs.state = RDMA_MAPPING_FROZEN;
    expect_value_contract(
      "VALUE_MAPPING_STATE",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.state = mapping_lhs.state;
    mapping_rhs.owner_h.generation++;
    expect_value_contract(
      "VALUE_MAPPING_OWNER",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );
    mapping_rhs.owner_h.generation = mapping_lhs.owner_h.generation;
    mapping_rhs.owner_h = null;
    expect_value_contract(
      "VALUE_MAPPING_NULL_OWNER",
      rdma_cmq_same_mapping_instance_value(mapping_lhs, mapping_rhs), 1'b0
    );

    // Ticket 同时构造共享嵌套节点与完全 detached 图，证明两类 API 都不以引用 alias 作为相等依据。
    function_lhs = make_function("value_contract_ticket_function_lhs");
    function_rhs = make_function("value_contract_ticket_function_rhs");
    cmq_lhs = make_cmq("value_contract_ticket_cmq_lhs", function_lhs);
    cmq_rhs = make_cmq("value_contract_ticket_cmq_rhs", function_rhs);
    opcode_lhs = make_key("value_contract_ticket_opcode_lhs");
    opcode_rhs = make_key("value_contract_ticket_opcode_rhs");
    ticket_lhs = make_ticket(
      "value_contract_ticket_lhs", function_lhs, cmq_lhs, opcode_lhs
    );
    ticket_shared = make_ticket(
      "value_contract_ticket_shared", function_lhs, cmq_lhs, opcode_lhs
    );
    ticket_detached = make_ticket(
      "value_contract_ticket_detached", function_rhs, cmq_rhs, opcode_rhs
    );
    if (ticket_lhs == ticket_detached || function_lhs == function_rhs ||
        cmq_lhs == cmq_rhs || opcode_lhs == opcode_rhs)
      `uvm_error("VALUE_TICKET_FIXTURE",
                 "detached ticket graph unexpectedly aliases source")
    expect_value_contract(
      "VALUE_TICKET_SHARED_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_shared), 1'b1
    );
    expect_value_contract(
      "VALUE_TICKET_DETACHED_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b1
    );
    expect_value_contract(
      "VALUE_TICKET_DETACHED_VALUE",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b1
    );
    expect_value_contract(
      "VALUE_TICKET_NULL_INSTANCE",
      rdma_cmq_same_ticket_instance_value(null, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_NULL_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, null), 1'b0
    );

    ticket_detached.function_h = null;
    expect_value_contract(
      "VALUE_TICKET_NULL_FUNCTION_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_NULL_FUNCTION_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.function_h = function_rhs;
    ticket_detached.cmq_h = null;
    expect_value_contract(
      "VALUE_TICKET_NULL_CMQ_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_NULL_CMQ_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.cmq_h = cmq_rhs;
    ticket_detached.opcode_key = null;
    expect_value_contract(
      "VALUE_TICKET_NULL_OPCODE_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_NULL_OPCODE_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.opcode_key = opcode_rhs;

    ticket_detached.command_id++;
    expect_value_contract(
      "VALUE_TICKET_COMMAND_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_COMMAND_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.command_id = ticket_lhs.command_id;
    ticket_detached.function_h.generation++;
    expect_value_contract(
      "VALUE_TICKET_FUNCTION_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_FUNCTION_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.function_h.generation = ticket_lhs.function_h.generation;
    ticket_detached.cmq_h.object_id++;
    expect_value_contract(
      "VALUE_TICKET_CMQ_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_CMQ_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.cmq_h.object_id = ticket_lhs.cmq_h.object_id;
    ticket_detached.slot_sequence++;
    expect_value_contract(
      "VALUE_TICKET_SLOT_SEQUENCE_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_SLOT_SEQUENCE_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.slot_sequence = ticket_lhs.slot_sequence;
    ticket_detached.sq_index++;
    expect_value_contract(
      "VALUE_TICKET_SQ_INDEX_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_SQ_INDEX_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.sq_index = ticket_lhs.sq_index;
    ticket_detached.sq_wrap = !ticket_lhs.sq_wrap;
    expect_value_contract(
      "VALUE_TICKET_SQ_WRAP_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_SQ_WRAP_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.sq_wrap = ticket_lhs.sq_wrap;
    ticket_detached.opcode_key.variant = "mutated_ticket_variant";
    expect_value_contract(
      "VALUE_TICKET_OPCODE_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_OPCODE_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.opcode_key.variant = ticket_lhs.opcode_key.variant;
    ticket_detached.absolute_deadline++;
    expect_value_contract(
      "VALUE_TICKET_DEADLINE_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b0
    );
    expect_value_contract(
      "VALUE_TICKET_DEADLINE_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b0
    );
    ticket_detached.absolute_deadline = ticket_lhs.absolute_deadline;
    expect_value_contract(
      "VALUE_TICKET_RESTORED_INSTANCE",
      rdma_cmq_same_ticket_instance_value(ticket_lhs, ticket_detached), 1'b1
    );
    expect_value_contract(
      "VALUE_TICKET_RESTORED_DETACHED",
      rdma_cmq_same_ticket_detached_value(ticket_lhs, ticket_detached), 1'b1
    );
  endfunction

  // 功能：直接验证 reset-isolation-proof package comparator 的完整公开投影、
  // ordered tuple、outer subtype 与 intentionally permissive invalid-equal 边界。
  // 输入/输出及副作用：无显式输入；构造独立 lhs/rhs proof，逐字段 mutation 并在
  // 继续复用前恢复；仅通过 UVM error 发布偏差，不计算 digest 或推进 reset lifecycle。
  // 失败/边界：null/required identity 缺失、replacement parity/incarnation、任一顶层
  // 字段、queue cardinality、tuple 顺序或 item 字段漂移必须返回 0；outer subtype
  // 扩展差异和 validator-invalid 但 comparator-equal 的值必须保持返回 1。
  function automatic void check_reset_proof_comparator_contract();
    rdma_cmq_reset_isolation_proof lhs;
    rdma_cmq_reset_isolation_proof rhs;
    rdma_cmq_reset_isolation_proof invalid_lhs;
    rdma_cmq_reset_isolation_proof invalid_rhs;
    rdma_cmq_journal_reset_proof_subtype subtype_lhs;
    rdma_cmq_journal_reset_proof_subtype subtype_rhs;
    rdma_function_identity saved_identity_lhs;
    rdma_function_identity saved_identity_rhs;
    rdma_function_identity saved_replacement_lhs;
    rdma_function_identity saved_replacement_rhs;
    rdma_cmq_recovery_owner saved_owner;
    int unsigned saved_request_index;
    rdma_cmq_journal_digest_t saved_image_digest;
    rdma_cmq_journal_digest_t saved_authority_digest;

    lhs = new("reset_proof_comparator_lhs");
    rhs = new("reset_proof_comparator_rhs");
    fill_reset_proof_comparator_fixture(lhs, "reset_proof_comparator_lhs");
    fill_reset_proof_comparator_fixture(rhs, "reset_proof_comparator_rhs");

    expect_value_contract(
      "RESET_PROOF_COMPARATOR_NULL_BOTH",
      rdma_cmq_same_reset_isolation_proof_value(null, null), 1'b0
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_NULL_LHS",
      rdma_cmq_same_reset_isolation_proof_value(null, rhs), 1'b0
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_NULL_RHS",
      rdma_cmq_same_reset_isolation_proof_value(lhs, null), 1'b0
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_EQUAL",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b1
    );

    saved_identity_lhs = lhs.isolated_identity;
    lhs.isolated_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ISOLATED_NULL_LHS",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    lhs.isolated_identity = saved_identity_lhs;
    saved_identity_rhs = rhs.isolated_identity;
    rhs.isolated_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ISOLATED_NULL_RHS",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    lhs.isolated_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ISOLATED_NULL_BOTH",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    lhs.isolated_identity = saved_identity_lhs;
    rhs.isolated_identity = saved_identity_rhs;

    rhs.proof_key = "proof-key-mutated";
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_PROOF_KEY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.proof_key = lhs.proof_key;
    rhs.proof_id++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_PROOF_ID",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.proof_id--;
    rhs.batch_key = "batch-key-mutated";
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_BATCH_KEY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.batch_key = lhs.batch_key;
    rhs.batch_id++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_BATCH_ID",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.batch_id--;
    rhs.attempt_id++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ATTEMPT_ID",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.attempt_id--;
    rhs.engine_instance_id++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ENGINE_INSTANCE",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.engine_instance_id--;
    rhs.engine_incarnation++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ENGINE_INCARNATION",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.engine_incarnation--;
    rhs.isolated_identity.reset_epoch++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_ISOLATED_INCARNATION",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.isolated_identity.reset_epoch--;

    saved_replacement_lhs = lhs.replacement_identity;
    saved_replacement_rhs = rhs.replacement_identity;
    rhs.replacement_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_RHS",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.replacement_identity = saved_replacement_rhs;
    lhs.replacement_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_LHS",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.replacement_identity = null;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_BOTH",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b1
    );
    lhs.replacement_identity = saved_replacement_lhs;
    rhs.replacement_identity = saved_replacement_rhs;
    rhs.replacement_identity.reset_epoch++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REPLACEMENT_INCARNATION",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.replacement_identity.reset_epoch--;

    rhs.batch_digest ^= 256'h1;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_BATCH_DIGEST",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.batch_digest ^= 256'h1;
    rhs.proof_digest ^= 256'h1;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_PROOF_DIGEST",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.proof_digest ^= 256'h1;
    rhs.state = RDMA_CMQ_RESET_PROOF_AWAITING_REBIND;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_STATE",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.state = lhs.state;
    rhs.backing_release_confirmed = !rhs.backing_release_confirmed;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_BACKING_RELEASE",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.backing_release_confirmed = lhs.backing_release_confirmed;

    rhs.isolated_request_indices.push_back(32'hdead_beef);
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REQUEST_CARDINALITY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    saved_request_index = rhs.isolated_request_indices.pop_back();
    rhs.isolated_image_digests.push_back(256'hdead_beef);
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_IMAGE_CARDINALITY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    saved_image_digest = rhs.isolated_image_digests.pop_back();
    rhs.isolated_authority_digests.push_back(256'hfeed_face);
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_AUTHORITY_CARDINALITY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    saved_authority_digest = rhs.isolated_authority_digests.pop_back();
    rhs.isolated_recovery_owners.push_back(
      rhs.isolated_recovery_owners[0]
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_OWNER_CARDINALITY",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    saved_owner = rhs.isolated_recovery_owners.pop_back();

    rhs.isolated_request_indices[0]++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_REQUEST_INDEX",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.isolated_request_indices[0]--;
    rhs.isolated_image_digests[0] ^= 256'h1;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_IMAGE_DIGEST",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.isolated_image_digests[0] ^= 256'h1;
    rhs.isolated_authority_digests[0] ^= 256'h1;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_AUTHORITY_DIGEST",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.isolated_authority_digests[0] ^= 256'h1;
    rhs.isolated_recovery_owners[0].transaction_id++;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_OWNER_VALUE",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    rhs.isolated_recovery_owners[0].transaction_id--;

    saved_request_index = rhs.isolated_request_indices[0];
    rhs.isolated_request_indices[0] = rhs.isolated_request_indices[1];
    rhs.isolated_request_indices[1] = saved_request_index;
    saved_image_digest = rhs.isolated_image_digests[0];
    rhs.isolated_image_digests[0] = rhs.isolated_image_digests[1];
    rhs.isolated_image_digests[1] = saved_image_digest;
    saved_authority_digest = rhs.isolated_authority_digests[0];
    rhs.isolated_authority_digests[0] =
      rhs.isolated_authority_digests[1];
    rhs.isolated_authority_digests[1] = saved_authority_digest;
    saved_owner = rhs.isolated_recovery_owners[0];
    rhs.isolated_recovery_owners[0] = rhs.isolated_recovery_owners[1];
    rhs.isolated_recovery_owners[1] = saved_owner;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_TUPLE_ORDER",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b0
    );
    saved_request_index = rhs.isolated_request_indices[0];
    rhs.isolated_request_indices[0] = rhs.isolated_request_indices[1];
    rhs.isolated_request_indices[1] = saved_request_index;
    saved_image_digest = rhs.isolated_image_digests[0];
    rhs.isolated_image_digests[0] = rhs.isolated_image_digests[1];
    rhs.isolated_image_digests[1] = saved_image_digest;
    saved_authority_digest = rhs.isolated_authority_digests[0];
    rhs.isolated_authority_digests[0] =
      rhs.isolated_authority_digests[1];
    rhs.isolated_authority_digests[1] = saved_authority_digest;
    saved_owner = rhs.isolated_recovery_owners[0];
    rhs.isolated_recovery_owners[0] = rhs.isolated_recovery_owners[1];
    rhs.isolated_recovery_owners[1] = saved_owner;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_RESTORED",
      rdma_cmq_same_reset_isolation_proof_value(lhs, rhs), 1'b1
    );

    subtype_lhs = new("reset_proof_comparator_subtype_lhs");
    subtype_rhs = new("reset_proof_comparator_subtype_rhs");
    fill_reset_proof_comparator_fixture(
      subtype_lhs, "reset_proof_comparator_subtype_lhs"
    );
    fill_reset_proof_comparator_fixture(
      subtype_rhs, "reset_proof_comparator_subtype_rhs"
    );
    subtype_lhs.extension_value = 32'h1111;
    subtype_rhs.extension_value = 32'h2222;
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_SUBTYPE_EXTENSION_IGNORED",
      rdma_cmq_same_reset_isolation_proof_value(subtype_lhs, subtype_rhs),
      1'b1
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_BASE_SUBTYPE",
      rdma_cmq_same_reset_isolation_proof_value(lhs, subtype_rhs), 1'b1
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_SUBTYPE_BASE",
      rdma_cmq_same_reset_isolation_proof_value(subtype_lhs, rhs), 1'b1
    );

    invalid_lhs = new("reset_proof_comparator_invalid_lhs");
    invalid_rhs = new("reset_proof_comparator_invalid_rhs");
    invalid_lhs.isolated_identity = rdma_function_identity::type_id::create(
      "reset_proof_comparator_invalid_lhs_identity"
    );
    invalid_rhs.isolated_identity = rdma_function_identity::type_id::create(
      "reset_proof_comparator_invalid_rhs_identity"
    );
    expect_value_contract(
      "RESET_PROOF_COMPARATOR_INVALID_EQUAL",
      rdma_cmq_same_reset_isolation_proof_value(invalid_lhs, invalid_rhs),
      1'b1
    );
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

  // 功能：比较 CMQ ambiguity policy 的实际分类与期望值，统一报告 label 和输入场景。
  // 输入/输出及副作用：label 标识测试矩阵条目，actual/expected 为只读 bit；函数只在
  //   不一致时发布 UVM error，不修改 status、ticket 或 completion，也不拥有其生命周期。
  // 失败/边界：actual 与 expected 不同表示公共 policy 或 caller profile 破坏既有证据
  //   语义；label 为空不会改变断言结果，只影响诊断文本。
  function automatic void expect_ambiguity_policy(
    string label,
    bit actual,
    bit expected
  );
    if (actual !== expected)
      `uvm_error("CMQ_AMBIGUITY_POLICY",
                 $sformatf("%s expected=%0d actual=%0d",
                           label, expected, actual))
  endfunction

  // 功能：覆盖 queue/QP 两种 ambiguity profile 在 null status、timeout、完整 completion、
  //   无证据成功、no-submit 失败和缺 status completion 壳下的差异矩阵。
  // 输入/输出及副作用：函数构造局部 status/completion fixture，调用真实纯值 policy，
  //   通过 UVM error 输出不符合历史契约的组合；不触碰 CMQ adapter 或 runtime 状态。
  // 失败/边界：任何 profile 把 timeout/reset 或缺少适用 no-submit 证明误判为确定结果，
  //   或把显式允许的成功/no-submit 仍判为 ambiguous，均导致测试失败。
  function automatic void check_cmq_ambiguity_policy();
    rdma_status success_status;
    rdma_status failure_status;
    rdma_status timeout_status;
    rdma_cmq_completion completion_shell;
    rdma_cmq_completion completed;

    success_status = rdma_status::success("policy success");
    failure_status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "policy failure");
    timeout_status = rdma_status::make(RDMA_SC_TIMEOUT,
                                       "policy timeout");
    completion_shell = rdma_cmq_completion::type_id::create(
      "ambiguity_completion_shell"
    );
    completed = rdma_cmq_completion::type_id::create(
      "ambiguity_completed"
    );
    completed.status = success_status;

    expect_ambiguity_policy(
      "NULL_STATUS_QUEUE", rdma_cmq_ambiguity_policy::is_ambiguous(
        null, null, null, 1'b1, 1'b0, 1'b0, 1'b0), 1'b1
    );
    expect_ambiguity_policy(
      "TIMEOUT_QP", rdma_cmq_ambiguity_policy::is_ambiguous(
        timeout_status, null, null, 1'b1, 1'b1, 1'b0, 1'b1), 1'b1
    );
    expect_ambiguity_policy(
      "COMPLETE_BOTH", rdma_cmq_ambiguity_policy::is_ambiguous(
        success_status, null, completed, 1'b0, 1'b0, 1'b0, 1'b0), 1'b0
    );
    expect_ambiguity_policy(
      "NULL_SUCCESS_QUEUE", rdma_cmq_ambiguity_policy::is_ambiguous(
        success_status, null, null, 1'b1, 1'b0, 1'b0, 1'b0), 1'b1
    );
    expect_ambiguity_policy(
      "NULL_SUCCESS_QP", rdma_cmq_ambiguity_policy::is_ambiguous(
        success_status, null, null, 1'b1, 1'b1, 1'b0, 1'b1), 1'b0
    );
    expect_ambiguity_policy(
      "NO_SUBMIT_FAILURE_QUEUE", rdma_cmq_ambiguity_policy::is_ambiguous(
        failure_status, null, null, 1'b1, 1'b0, 1'b0, 1'b0), 1'b0
    );
    expect_ambiguity_policy(
      "NO_SUBMIT_FAILURE_QP", rdma_cmq_ambiguity_policy::is_ambiguous(
        failure_status, null, null, 1'b1, 1'b1, 1'b0, 1'b1), 1'b0
    );
    expect_ambiguity_policy(
      "SHELL_FAILURE_QUEUE", rdma_cmq_ambiguity_policy::is_ambiguous(
        failure_status, null, completion_shell, 1'b1, 1'b0, 1'b1, 1'b0), 1'b0
    );
    expect_ambiguity_policy(
      "SHELL_FAILURE_QP", rdma_cmq_ambiguity_policy::is_ambiguous(
        failure_status, null, completion_shell, 1'b1, 1'b1, 1'b1, 1'b1), 1'b0
    );
    expect_ambiguity_policy(
      "SHELL_FAILURE_QP_STRICT", rdma_cmq_ambiguity_policy::is_ambiguous(
        failure_status, null, completion_shell, 1'b1, 1'b1, 1'b0, 1'b1), 1'b1
    );
    expect_ambiguity_policy(
      "MISSING_TICKET_COMPLETE_QUEUE", rdma_cmq_ambiguity_policy::is_ambiguous(
        success_status, null, completed, 1'b0, 1'b0, 1'b0, 1'b0), 1'b0
    );
    expect_ambiguity_policy(
      "MISSING_TICKET_COMPLETE_QP", rdma_cmq_ambiguity_policy::is_ambiguous(
        success_status, null, completed, 1'b0, 1'b1, 1'b0, 1'b1), 1'b1
    );
  endfunction

  // 功能：驱动 CMQ 模型 fixture、校验 submission effect 顺序，并验证对象校验、
  // body/journal value 与 expected-response 等 typed snapshot 深拷贝契约。
  // 输入/输出及副作用：phase 由 UVM 提供；task 持有 objection，调用断言并在结束时释放。
  // 失败/边界：任一 ordering、validation、body/journal-value 或 snapshot 契约失败均产生
  // UVM error；task 仍释放 objection，且不接管 DUT 资源。
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
    rdma_cmq_diagnostic diagnostic;
    rdma_cmq_runtime_desc runtime_desc;

    rdma_cmq_opcode_key key_snapshot;
    rdma_cmq_command_desc command_snapshot;
    rdma_cmq_slot_context slot_snapshot;
    rdma_cmq_expected_response expected_snapshot;
    rdma_cmq_decoded_cqe decoded_snapshot;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion completion_snapshot;
    rdma_cmq_diagnostic diagnostic_snapshot;
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
    check_cmq_value_contract();
    check_body_value_contract();
    check_journal_value_contract();
    check_journal_binding_comparator_contract();
    check_journal_ordered_item_tuple_contract();
    check_reset_proof_comparator_contract();
    check_submission_effect_ordering();
    check_cmq_ambiguity_policy();
    check_recovery_owner_contract();
    check_execution_value_defaults();
    check_typed_handle_snapshot_contract();
    check_typed_opcode_snapshot_contract();
    check_typed_expected_snapshot_contract();
    check_typed_image_snapshot_contract();
    check_required_status_snapshot_validation();
    check_schema_golden_vectors();
    check_identity_schema_field_mutations();
    check_command_schema_field_mutations();
    check_dma_binding_schema_field_mutations();
    check_binding_spare_state_canonicalization();
    check_journal_digest_contract();
    check_batch_digest_contract();
    check_batch_state_reducer();
    check_attempt_effect_fold();
    check_recovery_required_classifier();
    check_reset_proof_value();

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

    diagnostic = rdma_cmq_diagnostic::type_id::create("diagnostic");
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;
    diagnostic.status = rdma_status::make(
      RDMA_SC_TIMEOUT, "late completion"
    );
    diagnostic.raw_cqe = completion.raw_cqe;

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
    expect_status("DIAGNOSTIC_VALID", diagnostic.validate(), RDMA_SC_OK);
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

    diagnostic.status = null;
    expect_status("DIAGNOSTIC_NULL_STATUS", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.status = rdma_status::make(RDMA_SC_TIMEOUT,
                                          "late completion");
    diagnostic.raw_cqe = null;
    expect_status("DIAGNOSTIC_NULL_CQE", diagnostic.validate(),
                  RDMA_SC_INVALID_ARGUMENT);
    diagnostic.raw_cqe = completion.raw_cqe;
    diagnostic.kind = RDMA_CMQ_DIAG_UNKNOWN_CQE;
    diagnostic.ticket = null;
    expect_status("DIAGNOSTIC_UNKNOWN_WITHOUT_TICKET",
                  diagnostic.validate(), RDMA_SC_OK);
    diagnostic.kind = RDMA_CMQ_DIAG_LATE_COMPLETION;
    diagnostic.ticket = ticket;

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

    cloned_object = diagnostic.clone();
    if (!$cast(diagnostic_snapshot, cloned_object))
      `uvm_error("DIAGNOSTIC_CLONE", "diagnostic clone has wrong type")

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
    if (diagnostic_snapshot != null &&
        (diagnostic_snapshot.ticket == diagnostic.ticket ||
         diagnostic_snapshot.status == diagnostic.status ||
         diagnostic_snapshot.raw_cqe == diagnostic.raw_cqe))
      `uvm_error("DIAGNOSTIC_DEEP_COPY",
                 "diagnostic nested objects alias the source")
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
    diagnostic.status.message = "mutated diagnostic status";

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
    if (diagnostic_snapshot == null ||
        diagnostic_snapshot.ticket.function_h.generation !=
          TEST_GENERATION ||
        diagnostic_snapshot.status.message != "late completion" ||
        diagnostic_snapshot.raw_cqe.bytes[0] != 8'h5a ||
        diagnostic_snapshot.kind != RDMA_CMQ_DIAG_LATE_COMPLETION)
      `uvm_error("DIAGNOSTIC_SNAPSHOT", "diagnostic snapshot changed")
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
