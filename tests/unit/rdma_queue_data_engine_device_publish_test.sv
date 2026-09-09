// 目录：测试层 unit/rdma_queue_data_engine_device_publish_test.sv。
// 职责：验证 CQE/CEQE/AEQE device-producer publish、真实 backing 写入、route、
//   authority/polarity/full 原子性，以及 poll 释放 WQE/事件的端到端契约。
// 依赖：依赖 rdma_queue_data_engine_fixture、mock Host-memory、CQE codec 与 UVM。
// 所有权与生命周期：测试只拥有本地 fixture；queue、mapping、runtime 和 Host-memory
//   都由 fixture 或其生命周期执行器管理，测试仅读取其已发布快照。

// 设计说明：CQ 的 allocation 必须完整满足 lifecycle 的 DEVICE_WRITE 契约，故
// 不能借由修改 allocation snapshot 伪造 publish 预检失败。engine 通过 factory
// 创建 backing-access；此 test-only 子类仅在 setup 完成后被静态开关命中的首次
// write_device 调用处返回权限拒绝，模拟 access 已完成 span 预检但尚未触及 backend。
class rdma_cq_device_write_preflight_fault_access extends rdma_queue_backing_access;
  `uvm_object_utils(rdma_cq_device_write_preflight_fault_access)

  // 设计说明：factory 创建的 CQ/SQ/RQ access 都是独立对象，测试须用共享的一次性
  // 开关精确命中 setup 后的 publish 调用，不能获取或修改 engine 私有 attachment。
  static bit reject_next_device_write;

  // 功能：构造 CQ device-write 预检故障 access，默认不拒绝调用，使 fixture
  //   setup、普通 post 和未显式 armed 的 publish 保持基类行为。
  // 输入/输出及副作用：name 为输入；构造不改变静态一次性开关、不申请 mapping，
  //   也不修改 runtime、Host-memory 或 lifecycle 对资源的所有权。
  // 失败边界：构造不验证 factory 或外部依赖；access 未经 configure/attach 时仍由
  //   基类接口拒绝，不能把该测试类当作绕过生产 lifecycle 校验的通道。
  function new(string name = "rdma_cq_device_write_preflight_fault_access");
    super.new(name);
  endfunction

  // 功能：write_device 在 armed 的首次设备发布预检处注入 DMA permission 拒绝，
  //   验证 engine 取消 reservation 而不向 Host-memory backend 发起 write。
  // 输入/输出及副作用：offset、data 为输入，backend_write_started 为输出；命中
  //   开关时清除一次性开关并保持输出为 0，未命中时完全委托基类实现。
  // 失败边界：仅 armed 的第一笔调用返回 RDMA_SC_DMA_PERMISSION；不访问 backing、
  //   不伪造已开始写入，后续调用恢复基类行为，避免泄露故障到其他测试事务。
  virtual function rdma_status write_device(
    longint unsigned offset,
    byte data[],
    output bit backend_write_started
  );
    if (reject_next_device_write) begin
      reject_next_device_write = 1'b0;
      backend_write_started = 1'b0;
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "injected CQ device-write preflight failure");
    end
    return super.write_device(offset, data, backend_write_started);
  endfunction
endclass

// 设计说明：CQ/event poll 需要分别命中 prepared pending、最终 result 与 nested
// value 的某一次 raw factory 创建；按类型全局返回故障会更早破坏 lookup/status，
// 无法证明目标分配发生在 scheduler 前。该 wrapper 因而按精确 instance name
// 一次性注入，并在未命中时委托原 registry wrapper。
class rdma_queue_poll_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected string target_name;
  protected bit armed_state;
  protected bit wrong_type_state;
  protected bit fired_state;
  protected bit scheduler_result_role;
  protected bit scheduler_status_role;
  static bit allocation_guard_active;
  static bit scheduler_guard_armed;
  static bit scheduler_result_seen;
  static int unsigned guarded_factory_creates;
  static string first_guarded_factory_create;

  // 功能：构造 poll 专用 factory wrapper，保存原类型 wrapper 并保持未注入状态。
  // 输入/输出及副作用：name/delegate_value 为输入并保存为非拥有引用；只初始化
  //   target/armed/wrong/fired 与 scheduler guard role 字段，不修改 UVM factory
  //   或创建 RDMA 对象。
  // 失败/边界：delegate_value 为空时未命中创建也返回 null；调用方必须先安装有效
  //   registry wrapper，不能用本对象替代生产类型注册。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    target_name = "";
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
    fired_state = 1'b0;
    scheduler_result_role = 1'b0;
    scheduler_status_role = 1'b0;
  endfunction

  // 功能：仅在 armed 且 instance name 精确匹配时返回一次 null/错误类型，其他
  //   创建直接委托原 wrapper，使同一 poll 的前置 status/handle 不受干扰。
  // 输入/输出及副作用：name 为 factory instance name；命中时置 fired 并自动
  //   disarm，返回值用于被测 non-fatal cast 分支，不修改 runtime/backing/ledger。
  // 失败/边界：wrong_type_state=0 返回 null，=1 返回不可 cast 的载体；delegate
  //   为空或其创建失败时原样返回 null，测试必须结合 fired_state 区分是否命中。
  virtual function uvm_object create_object(string name = "");
    rdma_queue_runtime_wrong_factory_object wrong_object;
    uvm_object created;

    if (armed_state && name == target_name) begin
      armed_state = 1'b0;
      fired_state = 1'b1;
      if (!wrong_type_state) return null;
      wrong_object = new(name);
      return wrong_object;
    end
    if (delegate == null) return null;
    created = delegate.create_object(name);
    // 中文设计：scheduler 的最终成功 status 是 submit() 返回前最后一个已知
    // factory event。先观察 result，再观察紧随其后的 success status，才能把
    // scheduler 自身合法的 snapshot/result 分配排除在 post-scheduler guard 之外。
    if (scheduler_guard_armed && scheduler_result_role &&
        name == "doorbell_result")
      scheduler_result_seen = 1'b1;
    if (scheduler_guard_armed && scheduler_status_role &&
        scheduler_result_seen && name == "rdma_status") begin
      scheduler_guard_armed = 1'b0;
      scheduler_result_seen = 1'b0;
      allocation_guard_active = 1'b1;
    end
    else if (allocation_guard_active) begin
      guarded_factory_creates++;
      if (first_guarded_factory_create == "")
        first_guarded_factory_create = {wrapper_type_name, ":", name};
    end
    return created;
  endfunction

  // 功能：返回 wrapper 在 UVM factory 中显示的稳定测试类型名。
  // 输入/输出及副作用：无显式输入；返回 wrapper_type_name，不修改注入窗口。
  // 失败/边界：名称不参与 RDMA authority，也不保证与 delegate 的生产类型名相同。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：为下一次指定 instance name 创建开启 null 或错误类型的一次性故障。
  // 输入/输出及副作用：instance_name/wrong_type 为输入；清零 fired 并更新本地
  //   target/armed 状态，不立即调用 factory 或影响已创建对象。
  // 失败/边界：空 instance_name 不会命中正常命名创建；重复 arm 覆盖旧窗口，
  //   调用方应在每次 poll 后用 fired() 验证目标确实到达。
  function void arm(string instance_name, bit wrong_type);
    target_name = instance_name;
    wrong_type_state = wrong_type;
    fired_state = 1'b0;
    armed_state = 1'b1;
  endfunction

  // 功能：关闭当前故障窗口，避免未命中的 target 泄露到后续 fixture。
  // 输入/输出及副作用：无显式输入；清除 armed/target/wrong 字段，保留 fired
  //   供紧邻断言读取，不删除 factory override。
  // 失败/边界：重复 disarm 幂等；不恢复 delegate 之外的全局 override 链。
  function void disarm();
    target_name = "";
    wrong_type_state = 1'b0;
    armed_state = 1'b0;
  endfunction

  // 功能：返回最近一次 arm 窗口是否精确命中过目标创建。
  // 输入/输出及副作用：无显式输入；只读 fired_state，不清除或重开窗口。
  // 失败/边界：从未 arm 或目标未到达时返回 0；delegate 自身返回 null 不会置位。
  function bit fired();
    return fired_state;
  endfunction

  // 功能：set_scheduler_guard_role 指定本 wrapper 是否观察 scheduler result 或
  //   随后的最终 success status，以精确打开 post-scheduler allocation 窗口。
  // 输入/输出及副作用：result_role/status_role 为输入；只更新本 wrapper 的观测
  //   角色，不 arm factory fault，也不改变全局 guard counter。
  // 失败/边界：两个 role 同时为零表示普通计数 wrapper；同时为一只用于测试错误，
  //   正常配置必须把 result/status 分配给不同 requested type。
  function void set_scheduler_guard_role(bit result_role, bit status_role);
    scheduler_result_role = result_role;
    scheduler_status_role = status_role;
  endfunction

  // 功能：arm_scheduler_allocation_guard 清空旧计数，并等待一次完整 scheduler
  //   success result/status 后自动开始统计后续 factory 创建。
  // 输入/输出及副作用：无显式输入；重置全局 guard 状态，仅影响测试 wrapper
  //   观测，不阻止或替换任何生产对象创建。
  // 失败/边界：若 scheduler 没有成功 result，guard 不会开启；调用方必须结合
  //   poll status 与 PCIe history 判断目标 transaction 是否真的进入 scheduler。
  static function void arm_scheduler_allocation_guard();
    allocation_guard_active = 1'b0;
    scheduler_guard_armed = 1'b1;
    scheduler_result_seen = 1'b0;
    guarded_factory_creates = 0;
    first_guarded_factory_create = "";
  endfunction

  // 功能：arm_immediate_allocation_guard 从调用点立即统计 factory 创建，用于
  //   已有 SUCCESS pending 的本地 recovery continuation。
  // 输入/输出及副作用：无显式输入；清零旧计数并打开全局 guard，不修改 runtime
  //   pending、codec registry 或 scheduler history。
  // 失败/边界：guard 会统计测试随后执行的查询分配；调用方必须在被测 API 返回后
  //   立即 disable，再进行其它 status/snapshot 断言。
  static function void arm_immediate_allocation_guard();
    allocation_guard_active = 1'b1;
    scheduler_guard_armed = 1'b0;
    scheduler_result_seen = 1'b0;
    guarded_factory_creates = 0;
    first_guarded_factory_create = "";
  endfunction

  // 功能：disable_allocation_guard 关闭所有 allocation 统计窗口，并返回命中数
  //   与第一笔 factory type/name 供断言诊断。
  // 输入/输出及副作用：creates/first_create 为输出；读取并关闭静态 guard，保留
  //   factory override 委托关系，不清除任何已创建对象。
  // 失败/边界：未 arm 时稳定返回零/空字符串；本函数不把命中自动报告为错误，
  //   由具体 poll/recovery 契约决定期望值。
  static function void disable_allocation_guard(
    output int unsigned creates,
    output string first_create
  );
    creates = guarded_factory_creates;
    first_create = first_guarded_factory_create;
    allocation_guard_active = 1'b0;
    scheduler_guard_armed = 1'b0;
    scheduler_result_seen = 1'b0;
  endfunction
endclass

// 设计说明：consumer doorbell 的 registry/codec 异常必须经真实 poll preparation
// 触发，不能增加生产 virtual seam。该 registry 仅向测试开放 protected codec 表的
// 单项替换能力；未调用 replace/remove 时与生产 defaults registry 完全一致。
class rdma_queue_consumer_fault_registry
  extends rdma_hw_doorbell_codec_registry;
  `uvm_object_utils(rdma_queue_consumer_fault_registry)

  // 功能：构造尚未注入 codec 故障的 doorbell registry，沿用生产 defaults 状态。
  // 输入/输出及副作用：name 为对象名；只调用基类构造，不注册、删除或替换 codec。
  // 失败/边界：必须由 fixture 的 register_defaults/register_queue_codecs 完成配置；
  //   未配置对象的 lookup 行为仍由基类明确拒绝。
  function new(string name = "rdma_queue_consumer_fault_registry");
    super.new(name);
  endfunction

  // 功能：replace_codec_for_test 把一个精确 key 的现有 codec 暂时替换为 caller
  //   提供的 codec（允许 null），并返回原始非拥有引用供用例恢复。
  // 输入/输出及副作用：key/replacement 为输入，original 为输出；成功只更新本
  //   registry 的单个 codecs 条目，不修改其它 queue/doorbell profile。
  // 失败/边界：key canonicalize 失败或原条目不存在时返回 0 且 original=null；
  //   replacement=null 专用于验证 lookup success+null codec 的 fail-safe 路径。
  function bit replace_codec_for_test(
    rdma_codec_key key,
    rdma_codec_base replacement,
    output rdma_codec_base original
  );
    string canonical;
    rdma_status status;

    original = null;
    status = canonicalize(key, canonical);
    if (status == null || !status.ok() || !codecs.exists(canonical))
      return 1'b0;
    original = codecs[canonical];
    codecs[canonical] = replacement;
    return 1'b1;
  endfunction

  // 功能：remove_codec_for_test 删除一个精确 registry 条目并返回原始 codec，
  //   使 consumer preparation 走真实 lookup error 分支。
  // 输入/输出及副作用：key 为输入，original 为输出；成功只删除 canonical key，
  //   调用方可用 replace_codec_for_test 恢复同一非拥有 codec 引用。
  // 失败/边界：key 非法或条目不存在时返回 0 且不修改 registry；不得在 fixture
  //   setup 注册 defaults 期间调用，以免把测试故障扩散到其它 profile。
  function bit remove_codec_for_test(
    rdma_codec_key key,
    output rdma_codec_base original
  );
    string canonical;
    rdma_status status;

    original = null;
    status = canonicalize(key, canonical);
    if (status == null || !status.ok() || !codecs.exists(canonical))
      return 1'b0;
    original = codecs[canonical];
    codecs.delete(canonical);
    return 1'b1;
  endfunction

  // 功能：restore_codec_for_test 恢复 remove/replace 保存的精确 codec 引用。
  // 输入/输出及副作用：key/original 为输入；成功覆盖本 registry 的一个条目，
  //   不重新构造 codec，也不修改 defaults_registered 或其它 profile。
  // 失败/边界：key canonicalize 失败或 original=null 时返回 0 且保持当前表；
  //   调用方必须在每个故障 poll 后立即恢复，避免污染后续正常消费。
  function bit restore_codec_for_test(
    rdma_codec_key key,
    rdma_codec_base original
  );
    string canonical;
    rdma_status status;

    status = canonicalize(key, canonical);
    if (status == null || !status.ok() || original == null)
      return 1'b0;
    codecs[canonical] = original;
    return 1'b1;
  endfunction
endclass

// 设计说明：codec guard 保存原 codec 的非拥有引用，通过标准 virtual codec
// interface 注入 encode null/error/null-image，并在 SUCCESS recovery 中阻断任何
// CQE decode。它不复制 codec，也不改变 production registry 类的接口。
class rdma_queue_consumer_codec_guard extends rdma_codec_base;
  rdma_codec_base delegate;
  rdma_status injected_error;
  bit return_null_encode_status;
  bit return_error_encode_status;
  bit return_null_encode_image;
  bit block_decode;
  int unsigned encode_calls;
  int unsigned decode_calls;

  // 功能：构造 codec guard 并保存 delegate 非拥有引用，默认完全透传所有操作。
  // 输入/输出及副作用：name/delegate_value 为输入；清零 fault flags/counters，
  //   injected_error 保持 null，由具体用例在 arm 前预物化。
  // 失败/边界：delegate_value=null 时透传入口返回 injected_error/null；测试必须
  //   在替换 registry 前验证 delegate 有效，不能把 guard 当作独立 codec。
  function new(string name, rdma_codec_base delegate_value);
    super.new(name);
    delegate = delegate_value;
    injected_error = null;
    return_null_encode_status = 1'b0;
    return_error_encode_status = 1'b0;
    return_null_encode_image = 1'b0;
    block_decode = 1'b0;
    encode_calls = 0;
    decode_calls = 0;
  endfunction

  // 功能：encode 记录 consumer doorbell encode 调用，并按一次用例配置返回 null、
  //   预物化错误或 success+null image；无故障时委托真实 codec。
  // 输入/输出及副作用：model 为输入，image 为输出；递增 encode_calls，故障时
  //   image=null 且不调用 delegate，透传时不取得返回 image 的所有权。
  // 失败/边界：injected_error 缺失时 error 模式返回 null；三个 fault flag 由测试
  //   保证互斥，null status/image 都必须由 engine 在 scheduler 前 fail-safe 拒绝。
  virtual function rdma_status encode(
    rdma_hw_model model,
    output rdma_hw_image image
  );
    rdma_status status;

    encode_calls++;
    image = null;
    if (return_null_encode_status)
      return null;
    if (return_error_encode_status)
      return injected_error;
    if (return_null_encode_image) begin
      if (delegate == null) return injected_error;
      status = delegate.validate_model(model);
      return status;
    end
    if (delegate == null) return injected_error;
    return delegate.encode(model, image);
  endfunction

  // 功能：decode 统计 CQE decode；block_decode 时返回预物化错误，证明 confirmed
  //   SUCCESS recovery 不能重新 lookup/decode 原 CQE image。
  // 输入/输出及副作用：image 为输入，model 为输出；递增 decode_calls，透传时
  //   直接发布 delegate 结果，block 时保持 model=null。
  // 失败/边界：delegate 或 injected_error 为空时返回 null；初始 poll 必须在
  //   block_decode=0 下完成，只有 recovery continuation 才允许 arm。
  virtual function rdma_status decode(
    rdma_hw_image image,
    output rdma_hw_model model
  );
    decode_calls++;
    model = null;
    if (block_decode)
      return injected_error;
    if (delegate == null) return injected_error;
    return delegate.decode(image, model);
  endfunction

  // 功能：validate_model 把模型合法性检查委托给原 codec，供 null-image fault
  //   返回一个真实 success status 而不编码 image。
  // 输入/输出及副作用：model 为输入；返回 delegate status，不修改 model/counter。
  // 失败/边界：delegate=null 时返回 injected_error（可能为 null）；engine 必须安全
  //   处理 codec 返回的 null status。
  virtual function rdma_status validate_model(rdma_hw_model model);
    if (delegate == null) return injected_error;
    return delegate.validate_model(model);
  endfunction

  // 功能：validate_image 把 image metadata 检查委托给原 codec。
  // 输入/输出及副作用：image 为输入；只读并返回 delegate status。
  // 失败/边界：delegate=null 时返回 injected_error；不尝试构造替代 status。
  virtual function rdma_status validate_image(rdma_hw_image image);
    if (delegate == null) return injected_error;
    return delegate.validate_image(image);
  endfunction

  // 功能：hardware_endian 返回原 codec 的 hardware byte order。
  // 输入/输出及副作用：无显式输入；只读 delegate，不修改 guard 或 codec。
  // 失败/边界：delegate=null 时返回 RDMA_ENDIAN_BIG 安全测试默认；该值不会使
  //   缺失 delegate 的 encode/decode 获得成功。
  virtual function rdma_byte_endian_e hardware_endian();
    if (delegate == null) return RDMA_ENDIAN_BIG;
    return delegate.hardware_endian();
  endfunction

  // 功能：describe_fields 返回稳定的测试 guard 描述，不调用可能分配的 delegate
  //   文本格式化路径。
  // 输入/输出及副作用：无显式输入；返回固定字符串，不修改任何状态。
  // 失败/边界：描述不代表 profile authority；registry key 仍是唯一选择依据。
  virtual function string describe_fields();
    return "queue consumer codec guard";
  endfunction
endclass

// 设计说明：CQ poll 的 doorbell、CQ CI commit 与 WQE release 必须经过唯一的
// 三个 transaction seam，测试才能在不读取或修改 runtime 私有账本的前提下证明
// 相对顺序并一次性注入阶段故障。recovery allocation guard 也只在既有
// commit/release seam 的首个入口打开，不为生产 engine 增加第四个 virtual seam。
class rdma_queue_data_engine_ordering_fault extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_data_engine_ordering_fault)

  bit fail_commit_once;
  bit fail_release_once;
  bit fail_doorbell_once;
  bit inject_ambiguous_doorbell;
  bit inject_none_doorbell;
  bit inject_not_applicable_doorbell;
  bit null_doorbell_status_once;
  bit null_commit_status_once;
  bit null_release_status_once;
  bit arm_recovery_allocation_guard_once;
  bit hold_release_gate_after_commit_once;
  bit held_release_gate_active;
  rdma_queue_runtime held_release_runtime;
  rdma_status held_release_status;
  int unsigned commit_calls;
  int unsigned release_calls;
  int unsigned doorbell_calls;
  string trace[$];
  bit prepared_pending_visible;
  rdma_queue_pending_operation prepared_pending_snapshot;

  // 功能：构造未注入故障的 CQ poll 顺序观测 engine，并清空三个阶段的计数与 trace。
  // 输入/输出及副作用：name 为输入并传给基类；只初始化当前测试对象字段，不配置
  //   manager、scheduler、runtime 或 backing，也不改变全局 factory。
  // 失败/边界：构造不建立 fixture authority；公开事务仍须先由 fixture.configure/setup
  //   完成依赖绑定，所有一次性开关默认关闭且不会跨对象共享。
  function new(string name = "rdma_queue_data_engine_ordering_fault");
    super.new(name);
    fail_commit_once = 1'b0;
    fail_release_once = 1'b0;
    fail_doorbell_once = 1'b0;
    inject_ambiguous_doorbell = 1'b0;
    inject_none_doorbell = 1'b0;
    inject_not_applicable_doorbell = 1'b0;
    null_doorbell_status_once = 1'b0;
    null_commit_status_once = 1'b0;
    null_release_status_once = 1'b0;
    arm_recovery_allocation_guard_once = 1'b0;
    hold_release_gate_after_commit_once = 1'b0;
    held_release_gate_active = 1'b0;
    held_release_runtime = null;
    held_release_status = null;
    commit_calls = 0;
    release_calls = 0;
    doorbell_calls = 0;
    trace.delete();
    prepared_pending_visible = 1'b0;
    prepared_pending_snapshot = null;
  endfunction

  // 功能：记录 consumer doorbell 阶段，并在 armed 的首次调用返回确定 NO_SUBMIT
  //   或 AMBIGUOUS 故障；未注入时委托真实 scheduler 路径。
  // 输入/输出及副作用：attachment/next/routed_link 为输入；result/status/evidence
  //   为输出；每次调用递增 doorbell_calls 并向 trace 追加 "doorbell"。
  // 失败/边界：fail_doorbell_once 只消费一次并保持 result=null；NO_SUBMIT 表示未进入
  //   scheduler，AMBIGUOUS 表示结果不可重发，后续调用恢复基类行为。
  protected virtual task submit_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_result result,
    output rdma_status status,
    output rdma_queue_mmio_evidence_e evidence,
    input rdma_queue_data_qp_link routed_link,
    input rdma_doorbell_desc prepared_desc = null,
    input rdma_status prepared_status = null
  );
    rdma_status pending_status;

    doorbell_calls++;
    trace.push_back("doorbell");
    prepared_pending_snapshot = null;
    prepared_pending_visible = 1'b0;
    if (attachment != null && attachment.runtime != null) begin
      pending_status = attachment.runtime.query_pending(
        prepared_pending_snapshot);
      prepared_pending_visible = pending_status != null &&
                                 pending_status.ok() &&
                                 prepared_pending_snapshot != null;
    end
    if (null_doorbell_status_once) begin
      null_doorbell_status_once = 1'b0;
      result = null;
      status = null;
      evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
      return;
    end
    if (fail_doorbell_once) begin
      fail_doorbell_once = 1'b0;
      result = null;
      if (prepared_status != null) begin
        void'(set_engine_status_noalloc(
          prepared_status, RDMA_SC_PCIE_COMPLETION,
          "injected consumer doorbell failure"));
        status = prepared_status;
      end
      else
        status = rdma_status::make(RDMA_SC_PCIE_COMPLETION,
                                   "injected consumer doorbell failure");
      if (inject_none_doorbell)
        evidence = RDMA_QUEUE_MMIO_NONE;
      else if (inject_not_applicable_doorbell)
        evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
      else
        evidence = inject_ambiguous_doorbell ?
                   RDMA_QUEUE_MMIO_AMBIGUOUS : RDMA_QUEUE_MMIO_NO_SUBMIT;
      return;
    end
    super.submit_consumer_doorbell(attachment, next, result, status,
                                   evidence, routed_link, prepared_desc,
                                   prepared_status);
  endtask

  // 功能：记录 CQ consumer commit 阶段；可在 armed 的首次调用拒绝 CI，或在一次
  //   成功 commit 后用预建 status 抢先持有 CQ release gate，验证 engine 自身 gate。
  // 输入/输出及副作用：cq_attachment/cursor/prepared_status 为输入；
  //   递增 commit_calls、追加 "commit"；正常先委托真实 commit，hold 模式保存
  //   runtime 非拥有引用并调用 begin_consumer_release_noalloc 持有其 lock。
  // 失败/边界：fail_commit_once 只返回一次 INVALID_STATE 且不修改 CQ CI/used；
  //   hold 模式不创建 status，缺预建 slot/runtime 时 held flag 保持 0，让测试失败；
  //   测试必须在退出前以 finish(false) 归还注入 gate，不能把 lock 泄漏到后续用例。
  protected virtual function rdma_status commit_cq_consumer(
    rdma_queue_data_attachment cq_attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_status prepared_status = null
  );
    rdma_status delegated_status;

    if (arm_recovery_allocation_guard_once) begin
      arm_recovery_allocation_guard_once = 1'b0;
      rdma_queue_poll_factory_fault_wrapper::arm_immediate_allocation_guard();
    end
    commit_calls++;
    trace.push_back("commit");
    if (null_commit_status_once) begin
      null_commit_status_once = 1'b0;
      return null;
    end
    if (fail_commit_once) begin
      fail_commit_once = 1'b0;
      if (prepared_status != null) begin
        void'(set_engine_status_noalloc(
          prepared_status, RDMA_SC_INVALID_STATE,
          "injected CQ consumer commit failure"));
        return prepared_status;
      end
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "injected CQ consumer commit failure");
    end
    delegated_status = super.commit_cq_consumer(
      cq_attachment, cursor, prepared_status);
    if (hold_release_gate_after_commit_once && delegated_status != null &&
        delegated_status.ok()) begin
      hold_release_gate_after_commit_once = 1'b0;
      held_release_runtime = cq_attachment == null ? null :
                             cq_attachment.runtime;
      held_release_gate_active =
        held_release_runtime != null && held_release_status != null &&
        held_release_runtime.begin_consumer_release_noalloc(
          held_release_status);
    end
    return delegated_status;
  endfunction

  // 功能：记录 CQ WQE release 阶段，并在 armed 的首次调用拒绝 ledger mutation。
  // 输入/输出及副作用：wqe_attachment/cqe/prepared_status 与 frozen
  //   target 为输入，released 为输出；递增 release_calls、追加 "release"，
  //   armed 时在入口打开 factory guard，未注入时委托对应 release 实现。
  // 失败/边界：fail_release_once 命中时清空 released 并返回 INVALID_STATE，保证
  //   SQ/RQ/SRQ ledger 不变；下一次 recovery 调用恢复真实 release。
  protected virtual function rdma_status release_cq_wqe(
    rdma_queue_data_attachment wqe_attachment,
    rdma_hw_cqe_model cqe,
    output rdma_queue_slot_ledger_entry released[$],
    input rdma_status prepared_status = null,
    input bit frozen_target_valid = 1'b0,
    input int unsigned frozen_target_index = 0,
    input bit frozen_target_wrap = 1'b0
  );
    if (arm_recovery_allocation_guard_once) begin
      arm_recovery_allocation_guard_once = 1'b0;
      rdma_queue_poll_factory_fault_wrapper::arm_immediate_allocation_guard();
    end
    release_calls++;
    trace.push_back("release");
    if (null_release_status_once) begin
      null_release_status_once = 1'b0;
      released.delete();
      return null;
    end
    if (fail_release_once) begin
      fail_release_once = 1'b0;
      released.delete();
      if (prepared_status != null) begin
        void'(set_engine_status_noalloc(
          prepared_status, RDMA_SC_INVALID_STATE,
          "injected CQ WQE release failure"));
        return prepared_status;
      end
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "injected CQ WQE release failure");
    end
    return super.release_cq_wqe(
      wqe_attachment, cqe, released, prepared_status,
      frozen_target_valid, frozen_target_index, frozen_target_wrap);
  endfunction
endclass

// 设计说明：runtime admission/cancel 的真实默认实现由 data engine 的 protected
// virtual 边界统一调用。此 test-only engine 只返回一次确定性失败，让公开
// publish/query/recover API 走 engine 自己的 unclaimed/recovery 分支，绝不暴露或
// 改写 lifecycle-owned attachment/backing。
class rdma_device_publish_recovery_fault_engine extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_device_publish_recovery_fault_engine)

  static int unsigned admission_failures_remaining;
  static int unsigned cancel_failures_remaining;

  // 功能：构造 device publish recovery 故障 engine，默认不消耗 admission 或
  //   cancel 注入次数，使未 armed 的 fixture 完全采用生产 data-engine 行为。
  // 输入/输出及副作用：name 为输入；构造只建立 engine 自身默认状态，不配置
  //   manager/Host-memory，也不改变静态故障计数或外部资源所有权。
  // 失败边界：构造不验证依赖；未执行 configure 的对象仍由基类公开 API 返回
  //   INVALID_STATE，不能作为直接操作 queue runtime 的测试后门。
  function new(string name = "rdma_device_publish_recovery_fault_engine");
    super.new(name);
  endfunction

  // 功能：admit_device_publish_recovery 在 armed 次数内拒绝 runtime 接管，促使
  //   基类 enter_device_publish_recovery 按真实代码保留 unclaimed evidence。
  // 输入/输出及副作用：attachment、prepared_pending 为输入；命中时仅递减静态
  //   计数并返回错误，不触碰 pending、runtime、backing 或 engine 表；未命中委托基类。
  // 失败边界：每次命中返回 RESOURCE_BUSY；计数归零后必须恢复真实 admission，
  //   以验证 retry/abort 的配对清理而非永久伪造 recovery 状态。
  protected virtual function rdma_status admit_device_publish_recovery(
    rdma_queue_data_attachment attachment,
    rdma_queue_pending_operation prepared_pending
  );
    if (admission_failures_remaining != 0) begin
      admission_failures_remaining--;
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "injected device recovery admission failure");
    end
    return super.admit_device_publish_recovery(attachment, prepared_pending);
  endfunction

  // 功能：cancel_device_publish_reservation 在 armed 次数内拒绝 preflight cancel，
  //   让基类 finish_device_producer_cancel 保存可观测 pending/reservation。
  // 输入/输出及副作用：attachment、reservation 为输入；命中时仅消耗计数并返回
  //   RESOURCE_BUSY，不修改 runtime cursor、reservation、backing 或生命周期资源。
  // 失败边界：每次命中返回 RESOURCE_BUSY；计数归零后委托基类真实 cancel，避免
  //   后续 retry/abort 继续被故障注入阻断。
  protected virtual function rdma_status cancel_device_publish_reservation(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot reservation
  );
    if (cancel_failures_remaining != 0) begin
      cancel_failures_remaining--;
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "injected device reservation cancel failure");
    end
    return super.cancel_device_publish_reservation(attachment, reservation);
  endfunction

  // 功能：hold_detach_lock_for_test 占用 data-engine 已有 resize/detach 互斥锁，
  //   让公开 recover_queue 的 abort 在真正 detach 前稳定返回 RESOURCE_BUSY。
  // 输入/输出及副作用：无显式输入；成功时本测试 engine 持有一个 resize_lock token，
  //   不修改 attachment、runtime pending、reservation、backing 或外部 mapping。
  // 失败边界：锁为空或已被占用时返回 RESOURCE_BUSY；调用方必须配对调用
  //   release_detach_lock_for_test，且本 helper 只用于观察事务顺序而不伪造 detach 结果。
  function rdma_status hold_detach_lock_for_test();
    if (resize_lock == null || !resize_lock.try_get(1))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "injected detach lock is unavailable");
    return rdma_status::success();
  endfunction

  // 功能：release_detach_lock_for_test 归还 hold_detach_lock_for_test 取得的唯一
  //   token，使同一 recovery 可再次经真实 detach 路径完成 abort。
  // 输入/输出及副作用：无显式输入；向 resize_lock 归还一个 token，不修改 queue
  //   recovery evidence、cursor、backing bytes 或 lifecycle mapping 所有权。
  // 失败边界：仅允许在本 fixture 已成功占锁后调用；测试保证严格配对，重复归还会
  //   破坏 semaphore 容量，因此任何提前返回都必须先显式释放已持有 token。
  function void release_detach_lock_for_test();
    resize_lock.put(1);
  endfunction
endclass

// 设计说明：CQE 的 18-bit qpn 不能承载 resource manager 合法的 21-bit QP
// local ID。测试 manager 只把本 fixture 的下一 QP authority 置于首个超宽值，
// 让生产 publish 在 encode 前验证完整 int unsigned，而不截断 packed model 字段。
class rdma_device_publish_width_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_device_publish_width_manager)

  // 功能：构造 width manager，并把 QP local-ID 分配起点设为 18'h4_0000。
  // 输入/输出及副作用：name 为输入；只初始化本测试对象的 protected 分配账本，
  //   不修改全局 binding、外部 manager 或已分配资源。
  // 失败/边界：该对象只用于最后一个独立 fixture；超过 manager 21-bit 上限仍由
  //   生产分配器拒绝，不能作为绕过 lifecycle/authority 校验的 seam。
  function new(string name = "rdma_device_publish_width_manager");
    super.new(name);
    next_local_id[RDMA_RESOURCE_QP] = 32'h0004_0000;
  endfunction
endclass

// 设计说明：CEQE width 负例需要一个 producer_index=65536 的真实 runtime；逐条
// 发布 65536 次会引入无关 WQE/backing 负担。本 test-only 子类只在已 attach CQ 上
// 替换 runtime 快照，不为 production 增加 seam，publish 仍走完整公开校验路径。
class rdma_device_publish_width_runtime_engine extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_device_publish_width_runtime_engine)

  // 功能：构造 width runtime engine，保持所有生产依赖未配置的默认状态。
  // 输入/输出及副作用：name 为输入；只建立本地 engine，不修改 factory 或 queue。
  // 失败/边界：调用 install 前仍须走 fixture configure/attach；未配置公开 API 按基类拒绝。
  function new(string name = "rdma_device_publish_width_runtime_engine");
    super.new(name);
  endfunction

  // 功能：install_wide_cq_runtime 为已 attach CQ 安装 depth=131072、PI=65536 的
  //   device runtime，并注入与本 width 场景目标 CEQ 一致的 detached dependency。
  // 输入/输出及副作用：cq_h、ceq_h 为输入；成功时只替换本测试 engine 的 CQ
  //   runtime/ceq_h 快照，不修改 manager resource、queue backing 或调用者 model。
  // 失败/边界：handle/attachment/binding/identity/clone/runtime 配置或激活失败时
  //   返回原错误；不发布半配置状态，且该入口只供 width 负例、不得写 backing。
  function rdma_status install_wide_cq_runtime(
    rdma_handle cq_h,
    rdma_handle ceq_h
  );
    rdma_queue_runtime runtime;
    rdma_function_identity identity;
    rdma_handle ceq_snapshot;
    rdma_status status;
    string key;

    if (cq_h == null || ceq_h == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "wide CQ runtime handle/dependency is null");
    status = ensure_handle(ceq_h, RDMA_RESOURCE_CEQ);
    if (status == null || !status.ok()) return status;
    status = clone_publish_handle(ceq_h, "wide CQ dependency", ceq_snapshot);
    if (status == null || !status.ok() || ceq_snapshot == null)
      return status == null || status.ok() ?
        rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                          "wide CQ dependency snapshot is unavailable") : status;
    key = attachment_key(cq_h, RDMA_QUEUE_RUNTIME_CQ);
    if (key == "" || !attachments.exists(key) || attachments[key] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "wide CQ runtime attachment is missing");
    runtime = rdma_queue_runtime::type_id::create("wide_cq_runtime");
    if (runtime == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "wide CQ runtime allocation failed");
    status = runtime.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ,
                               131072, 65536, 1'b0, 0, 1'b0, 1'b0);
    if (status == null || !status.ok()) return status;
    identity = binding == null ? null : binding.function_identity_snapshot();
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "wide CQ runtime Function identity is missing");
    status = runtime.set_route_epoch(identity.route_key(), identity.reset_epoch);
    if (status == null || !status.ok()) return status;
    status = runtime.activate();
    if (status == null || !status.ok()) return status;
    attachments[key].runtime = runtime;
    attachments[key].ceq_h = ceq_snapshot;
    return rdma_status::success();
  endfunction
endclass

// 设计说明：UVM 1.2 不提供可移除 type override 的可移植接口；测试以无行为变化的
// passthrough 类型作为 fixture 间 reset 目标，避免 fault/width 子类泄露到后续场景。
class rdma_device_publish_passthrough_engine extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_device_publish_passthrough_engine)

  // 功能：构造不带 fault seam 的 queue-data engine reset 目标，全部行为继承生产基类。
  // 输入/输出及副作用：name 为输入；只建立默认 engine 状态，不配置或拥有外部资源。
  // 失败边界：未 configure 时仍由生产基类拒绝公开 API；本类不改变任何返回码。
  function new(string name = "rdma_device_publish_passthrough_engine");
    super.new(name);
  endfunction
endclass

// 设计说明：backing-access fault override 同样无法移除；独立 passthrough 子类让
// 后续 fixture 恢复生产 span/DMA permission 行为，而不暴露额外测试 seam。
class rdma_device_publish_passthrough_access extends rdma_queue_backing_access;
  `uvm_object_utils(rdma_device_publish_passthrough_access)

  // 功能：构造不注入 preflight fault 的 backing-access reset 目标，继承真实 span I/O。
  // 输入/输出及副作用：name 为输入；不申请、不 attach 或释放 lifecycle mapping。
  // 失败边界：未 configure/attach 的访问仍按生产基类拒绝；本类不放宽 DMA permission。
  function new(string name = "rdma_device_publish_passthrough_access");
    super.new(name);
  endfunction
endclass

// 设计说明：width manager 会修改 QP local-ID 起点；使用无定制分配策略的子类覆盖
// factory，可防止超宽 authority 泄露到随后依赖标准 fixture identity 的场景。
class rdma_device_publish_passthrough_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_device_publish_passthrough_manager)

  // 功能：构造使用生产 local-ID 分配规则的 resource-manager reset 目标。
  // 输入/输出及副作用：name 为输入；只初始化基类账本，不创建 Function/queue/QP。
  // 失败边界：所有 allocation/authority 失败沿用生产基类；不保留 width fixture 起点。
  function new(string name = "rdma_device_publish_passthrough_manager");
    super.new(name);
  endfunction
endclass

// 设计说明：本 UVM test 通过公开 publish/poll/recovery/query API 串联真实 runtime、
// backing 与 doorbell mock；只在三条 transaction seam 和非致命 factory 边界注入故障，
// 从消费者可见结果验证顺序、原子性与幂等性，不读取或复制生产私有账本。
class rdma_queue_data_engine_device_publish_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_device_publish_test)

  protected rdma_queue_poll_factory_fault_wrapper poll_pending_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_result_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_event_result_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_slot_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_handle_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_image_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_status_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_cursor_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_cqe_model_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_doorbell_result_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_cq_db_model_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_ceq_db_model_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_aeq_db_model_fault;
  protected rdma_queue_poll_factory_fault_wrapper poll_db_desc_fault;

  // 功能：构造 UVM 测试组件，不预先绑定 queue-data fixture，保持每次 run 独立。
  // 输入/输出及副作用：name、parent 为输入；只建立组件层级，不申请 queue 或 mapping。
  // 失败边界：构造不校验依赖；fixture setup 失败时 run_phase 必须报告错误并释放 objection。
  function new(string name = "rdma_queue_data_engine_device_publish_test",
               uvm_component parent = null);
    super.new(name, parent);
    poll_pending_fault = null;
    poll_result_fault = null;
    poll_event_result_fault = null;
    poll_slot_fault = null;
    poll_handle_fault = null;
    poll_image_fault = null;
    poll_status_fault = null;
    poll_cursor_fault = null;
    poll_cqe_model_fault = null;
    poll_doorbell_result_fault = null;
    poll_cq_db_model_fault = null;
    poll_ceq_db_model_fault = null;
    poll_aeq_db_model_fault = null;
    poll_db_desc_fault = null;
  endfunction

  // 功能：为 CQ/event poll admission 所需的结果/证据对象安装按 instance name 命中的
  //   raw factory wrapper，供 null/错误类型分配故障保持非致命且可重复验证。
  // 输入/输出及副作用：无显式输入；首次调用创建 wrapper 并覆盖 pending/result/
  //   slot/handle/image/status/cursor/model/descriptor/result 类型；后续调用保持既有
  //   override，不形成 wrapper 链，并为 scheduler result/status 配置 guard 角色。
  // 失败/边界：必须在目标 fixture setup 完成后、首次 arm 前调用；全局 override
  //   持续到本 UVM test 结束，未 armed 时只委托原 registry，不改变生产行为。
  function automatic void configure_poll_factory_faults();
    uvm_factory factory;

    if (poll_pending_fault != null) return;
    factory = uvm_factory::get();
    poll_pending_fault = new(
      "poll_pending_factory_fault", rdma_queue_pending_operation::get_type());
    poll_result_fault = new(
      "poll_result_factory_fault", rdma_queue_completion_result::get_type());
    poll_event_result_fault = new(
      "poll_event_result_factory_fault", rdma_queue_event_result::get_type());
    poll_slot_fault = new(
      "poll_slot_factory_fault", rdma_queue_slot_ledger_entry::get_type());
    poll_handle_fault = new(
      "poll_handle_factory_fault", rdma_handle::get_type());
    poll_image_fault = new(
      "poll_image_factory_fault", rdma_hw_image::get_type());
    poll_status_fault = new(
      "poll_status_factory_fault", rdma_status::get_type());
    poll_cursor_fault = new(
      "poll_cursor_factory_fault", rdma_queue_cursor_snapshot::get_type());
    poll_cqe_model_fault = new(
      "poll_cqe_model_factory_fault", rdma_hw_cqe_model::get_type());
    poll_doorbell_result_fault = new(
      "poll_doorbell_result_factory_fault", rdma_doorbell_result::get_type());
    poll_cq_db_model_fault = new(
      "poll_cq_db_model_factory_fault", rdma_hw_cq_doorbell_model::get_type());
    poll_ceq_db_model_fault = new(
      "poll_ceq_db_model_factory_fault", rdma_hw_ceq_doorbell_model::get_type());
    poll_aeq_db_model_fault = new(
      "poll_aeq_db_model_factory_fault", rdma_hw_aeq_doorbell_model::get_type());
    poll_db_desc_fault = new(
      "poll_db_desc_factory_fault", rdma_doorbell_desc::get_type());
    poll_doorbell_result_fault.set_scheduler_guard_role(1'b1, 1'b0);
    poll_status_fault.set_scheduler_guard_role(1'b0, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_pending_operation::get_type(), poll_pending_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_completion_result::get_type(), poll_result_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_event_result::get_type(), poll_event_result_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_slot_ledger_entry::get_type(), poll_slot_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_handle::get_type(), poll_handle_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_image::get_type(), poll_image_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_status::get_type(), poll_status_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_cursor_snapshot::get_type(), poll_cursor_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_cqe_model::get_type(), poll_cqe_model_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_doorbell_result::get_type(), poll_doorbell_result_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_cq_doorbell_model::get_type(), poll_cq_db_model_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_ceq_doorbell_model::get_type(), poll_ceq_db_model_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_aeq_doorbell_model::get_type(), poll_aeq_db_model_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_doorbell_desc::get_type(), poll_db_desc_fault, 1'b1);
  endfunction

  // 功能：reset_device_publish_factory_state 把三个被本文件覆盖的基类恢复到无故障
  //   passthrough 类型，并清零所有静态 fault 开关/计数，隔离下一 fixture。
  // 输入/输出及副作用：无显式输入；更新全局 UVM factory 的 engine/access/manager
  //   type override，并清除 admission/cancel/preflight 静态注入状态。
  // 失败边界：只应在 fixture 事务之间调用；已创建对象不受 override 变化影响，故
  //   不能用它中途撤销正在运行的 fault，也不会释放任何 lifecycle 资源。
  function automatic void reset_device_publish_factory_state();
    uvm_factory factory;

    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(),
      rdma_device_publish_passthrough_engine::get_type(), 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_backing_access::get_type(),
      rdma_device_publish_passthrough_access::get_type(), 1'b1);
    factory.set_type_override_by_type(
      rdma_resource_manager::get_type(),
      rdma_device_publish_passthrough_manager::get_type(), 1'b1);
    factory.set_type_override_by_type(
      rdma_hw_doorbell_codec_registry::get_type(),
      rdma_queue_consumer_fault_registry::get_type(), 1'b1);
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 0;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 0;
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write = 1'b0;
  endfunction

  // 功能：clone_test_handle 手工复制 QP handle 的身份字段，避免测试辅助函数在
  //   clone/cast 注入故障时触发 fatal，使 CQE authority 错误可由 status 观察。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功时分配 detached handle，
  //   不修改 source、fixture 或资源管理器。
  // 失败边界：source 为空或候选分配失败返回非成功 status，copy 保持 null。
  function automatic rdma_status clone_test_handle(
    rdma_handle source,
    output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "test handle source is null");
    candidate = rdma_handle::type_id::create("test_handle_copy");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "test handle allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：clone_test_handle_value 为 lifecycle request 复制 detached handle 值，
  //   使 request 不借用 fixture 资源对象的可变 handle 实例。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功时分配并逐字段复制 kind、
  //   Function UID、object ID、generation，不修改 source 或 manager。
  // 失败边界：source 为空或 factory 分配失败返回非成功，copy 保持 null；调用方
  //   必须停止 create/attach，不能用 null 或 dependency-only 资源替代。
  function automatic rdma_status clone_test_handle_value(
    rdma_handle source,
    output rdma_handle copy
  );
    return clone_test_handle(source, copy);
  endfunction

  // 功能：make_cqe_for_outstanding_send 仅利用 post_send 已发布的 slot/wr_id
  //   evidence 构造 CQE，验证 CQ poll 能精确释放对应 SQ WQE。
  // 输入/输出及副作用：qp_h、qpn、post_result、polarity 为输入，status 为输出；
  //   成功时返回新的 CQE model，不读取 CQ backing 或修改 post_result。
  // 失败边界：QP authority、post status 或对象分配不完整时返回 null，并保持
  //   非成功 status；绝不创建可被 publish 的半成品 model。
  function automatic rdma_hw_cqe_model make_cqe_for_outstanding_send(
    rdma_handle qp_h,
    int unsigned qpn,
    rdma_queue_post_result post_result,
    bit polarity,
    output rdma_status status
  );
    rdma_hw_cqe_model model;

    status = rdma_status::success();
    model = null;
    if (qp_h == null || qp_h.kind != RDMA_RESOURCE_QP ||
        post_result == null || post_result.status == null ||
        !post_result.status.ok()) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "posted send evidence is incomplete");
      return null;
    end
    model = rdma_hw_cqe_model::type_id::create("test_cqe");
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "test CQE model allocation failed");
      return null;
    end
    status = clone_test_handle(qp_h, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      if (status == null)
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "test CQE QP clone returned null status");
      model = null;
      return null;
    end
    model.wr_id = post_result.wr_id;
    model.opcode = RDMA_WR_SEND;
    model.status = rdma_status::success();
    model.qpn = qpn;
    model.wqe_index = post_result.index;
    model.wqe_wrap = post_result.wrap;
    model.rq_cqe = 1'b0;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = 8'h00;
    model.payload_len = 32;
    model.immediate_data = 32'h0;
    model.signature = 8'h0;
    return model;
  endfunction

  // 功能：publish_cqe_for_test 只经公开 publish_cqe API 发起 CQE，防止测试
  //   绕过 reservation、device write/readback 或 commit pipeline。
  // 输入/输出及副作用：queue_data、cq_h、model 为输入，result/status 为输出；
  //   不修改 fixture、backing 或 model 的所有权。
  // 失败边界：queue_data 为空时返回 INVALID_ARGUMENT；其余拒绝由生产 API 原样发布。
  task automatic publish_cqe_for_test(
    rdma_queue_data_engine queue_data,
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    result = null;
    status = null;
    if (queue_data == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "queue-data engine is null");
      return;
    end
    queue_data.publish_cqe(cq_h, model, result, status);
  endtask

  // 功能：read_queue_backing_slot 从 lifecycle queue plan 的指定 ring 读取一个
  //   完整槽位，供拒绝前后逐字节比较真实 backing 原子性。
  // 输入/输出及副作用：fixture、queue、role、index、size 为输入，data 为输出；
  //   只经 mock Host-memory read 观察 bytes，不推进 runtime cursor 或取得 mapping 所有权。
  // 失败边界：任一对象/size/role/mapping 缺失或读越界时返回错误且 data 为空；
  //   不以 Host-memory call 数量替代 backing 内容证据。
  function automatic rdma_status read_queue_backing_slot(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_backing_role_e role,
    int unsigned index,
    int unsigned size,
    output byte data[]
  );
    rdma_queue_backing_ref backing;

    data = new[0];
    backing = null;
    if (fixture == null || fixture.mem == null || queue == null ||
        queue.queue_plan == null || size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue backing observation input is incomplete");
    foreach (queue.queue_plan.refs[i])
      if (queue.queue_plan.refs[i] != null &&
          queue.queue_plan.refs[i].role == role)
        backing = queue.queue_plan.refs[i];
    if (backing == null || backing.mapping == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "queue backing observation role is missing");
    return fixture.mem.read(backing.mapping,
      backing.mapping_offset + longint'(index) * longint'(size), size, data);
  endfunction

  // 功能：count_host_mem_calls 统计 mock Host-memory 已记录的指定 method_name，
  //   使 fault case 能区分 write/read 与无关 query/allocate 调用。
  // 输入/输出及副作用：mem、method_name 为输入；返回匹配 calls 条目的数量，只读
  //   mock ledger，不消费故障、不修改 mapping 或 transaction 顺序。
  // 失败边界：mem 为空时返回 0；调用方必须先验证 fixture 完整，不能把安全默认值
  //   当成“backend 未调用”的充分证据。
  function automatic int unsigned count_host_mem_calls(
    rdma_mock_host_mem mem,
    string method_name
  );
    int unsigned count;

    count = 0;
    if (mem == null)
      return 0;
    foreach (mem.calls[i])
      if (mem.calls[i] != null &&
          mem.calls[i].method_name == method_name)
        count++;
    return count;
  endfunction

  // 功能：count_pcie_calls 统计 mock PCIe 公开 history 中指定 method_name 的调用，
  //   区分 consumer doorbell 的本地 NO_SUBMIT、真实 scheduler 失败与恢复重发。
  // 输入/输出及副作用：pcie/method_name 为输入；返回匹配记录数，只读 calls queue，
  //   不消费 fail_next、不修改 scheduler、runtime 或 MMIO backing。
  // 失败/边界：pcie 为空时返回 0；调用方须先验证 fixture，不能把安全默认值单独
  //   当作“从未提交”的证明，仍需结合 pending enum 与 ordering trace。
  function automatic int unsigned count_pcie_calls(
    rdma_mock_pcie pcie,
    string method_name
  );
    int unsigned count;

    count = 0;
    if (pcie == null)
      return 0;
    foreach (pcie.calls[i])
      if (pcie.calls[i] != null &&
          pcie.calls[i].method_name == method_name)
        count++;
    return count;
  endfunction

  // 功能：same_test_handle_value 比较两个 detached handle 的完整资源身份，供
  //   recovery 前后确认 queue/QP authority 没有被 retry 或 detach 失败替换。
  // 输入/输出及副作用：left、right 为输入；返回 null 对称性及 kind、Function UID、
  //   object ID、generation 的逐字段比较结果，不修改任一 handle。
  // 失败边界：仅一侧为 null 时返回 0；两侧都为 null 时返回 1，本函数不把对象地址
  //   相同当作值相等，也不查询 manager 当前 generation。
  function automatic bit same_test_handle_value(
    rdma_handle left,
    rdma_handle right
  );
    if (left == null || right == null)
      return left == null && right == null;
    return left.kind == right.kind &&
           left.function_uid == right.function_uid &&
           left.object_id == right.object_id &&
           left.generation == right.generation;
  endfunction

  // 功能：same_test_cursor_value 比较两个 cursor 快照的 index/wrap，用于验证
  //   recovery reservation、当前 cursor 与 next_cursor 都保持同一 ring 位置。
  // 输入/输出及副作用：left、right 为输入；返回 null 对称性和 index/wrap 比较结果，
  //   不推进 runtime，也不取得 cursor 所有权。
  // 失败边界：仅一侧为 null 时返回 0；两侧都为 null 时返回 1；本函数不知道 depth，
  //   因而不额外判断 index 是否越界。
  function automatic bit same_test_cursor_value(
    rdma_queue_cursor_snapshot left,
    rdma_queue_cursor_snapshot right
  );
    if (left == null || right == null)
      return left == null && right == null;
    return left.index == right.index && left.wrap == right.wrap;
  endfunction

  // 功能：same_test_status_value 比较 pending 中冻结的 failure_status 全部公开字段，
  //   防止 retry 失败悄悄覆盖原始 DMA 诊断或 authority 上下文。
  // 输入/输出及副作用：left、right 为输入；返回 status 标量与 message 的值比较，
  //   不调用 clone、factory 或 status.ok()，也不修改诊断对象。
  // 失败边界：仅一侧为 null 时返回 0，两侧都为 null 时返回 1；字符串按精确值比较，
  //   因而任何错误消息改写都会被视为 evidence 变化。
  function automatic bit same_test_status_value(
    rdma_status left,
    rdma_status right
  );
    if (left == null || right == null)
      return left == null && right == null;
    return left.category == right.category &&
           left.code == right.code &&
           left.hardware_code == right.hardware_code &&
           left.hardware_code_valid == right.hardware_code_valid &&
           left.source_engine == right.source_engine &&
           left.function_uid == right.function_uid &&
           left.generation == right.generation &&
           left.resource_id == right.resource_id &&
           left.command_id == right.command_id &&
           left.wr_id == right.wr_id &&
           left.severity == right.severity &&
           left.retryable == right.retryable &&
           left.message == right.message;
  endfunction

  // 功能：same_device_pending_value 对 device-producer pending 的完整公开快照做
  //   值比较，覆盖身份、方向/阶段、image、cursor、route/epoch、MMIO 与失败状态。
  // 输入/输出及副作用：left、right 为输入；返回所有公开 evidence 字段的合取结果，
  //   只读取 detached snapshot，不访问 attachment、backing 或 runtime 内部状态。
  // 失败边界：null 不对称、image/request/committed cursor 等对象存在性不同或任一
  //   标量/byte 或 completion WQ kind 不同均返回 0；device recovery 的
  //   request_snapshot 必须保持同一 null 性。
  function automatic bit same_device_pending_value(
    rdma_queue_pending_operation left,
    rdma_queue_pending_operation right
  );
    if (left == null || right == null)
      return left == null && right == null;
    if (!same_test_handle_value(left.queue_h, right.queue_h) ||
        !same_test_handle_value(left.routed_qp_h, right.routed_qp_h) ||
        !same_test_cursor_value(left.cursor, right.cursor) ||
        !same_test_cursor_value(left.next_cursor, right.next_cursor) ||
        !same_test_cursor_value(left.committed_consumer_cursor,
                                right.committed_consumer_cursor) ||
        !same_test_status_value(left.failure_status, right.failure_status))
      return 1'b0;
    if (left.image == null || right.image == null) begin
      if (!(left.image == null && right.image == null))
        return 1'b0;
    end
    else if (left.image.length != right.image.length ||
             left.image.alignment != right.image.alignment ||
             left.image.endian != right.image.endian ||
             left.image.image_kind != right.image.image_kind ||
             left.image.hardware_version != right.image.hardware_version ||
             left.image.function_generation !=
               right.image.function_generation ||
             left.image.write_target_kind != right.image.write_target_kind ||
             left.image.backing_target != right.image.backing_target ||
             left.image.hmc_target != right.image.hmc_target ||
             left.image.bar_target != right.image.bar_target ||
             left.image.field_summary != right.image.field_summary ||
             left.image.bytes != right.image.bytes)
      return 1'b0;
    if ((left.request_snapshot == null) != (right.request_snapshot == null))
      return 1'b0;
    return left.kind == right.kind &&
           left.producer == right.producer &&
           left.device_producer == right.device_producer &&
           left.device_write_attempted == right.device_write_attempted &&
           left.consumer_committed == right.consumer_committed &&
           left.cq_consumer_committed == right.cq_consumer_committed &&
           left.completion_released == right.completion_released &&
           left.consumer_doorbell_succeeded ==
             right.consumer_doorbell_succeeded &&
           left.entry_offset == right.entry_offset &&
           left.wr_id == right.wr_id &&
           left.signaled == right.signaled &&
           left.completion_index == right.completion_index &&
           left.completion_wrap == right.completion_wrap &&
           left.completion_target_valid == right.completion_target_valid &&
           left.completion_wq_kind == right.completion_wq_kind &&
           left.mmio_maybe_submitted == right.mmio_maybe_submitted &&
           left.known_no_mmio == right.known_no_mmio &&
           left.mmio_evidence == right.mmio_evidence &&
           left.entry_size == right.entry_size &&
           left.route == right.route &&
           left.route_valid == right.route_valid &&
           left.reset_epoch == right.reset_epoch &&
           left.epoch_valid == right.epoch_valid;
  endfunction

  // 功能：host_mem_mapping_call_since 在指定 calls 起点之后查找某 mapping 的
  //   method_name 记录，用于区分 borrowed target destroy 与 source owner release。
  // 输入/输出及副作用：mem、method_name、mapping、start_index 为输入；按唯一 IOVA
  //   比较 mock call 的 detached mapping 快照并返回命中位，只读调用账本。
  // 失败边界：mem/mapping 为空或 start_index 超出当前 calls 时返回 0；fixture 中每次
  //   allocate 产生唯一 IOVA，本 helper 不可用于地址可能复用的跨 reset 比较。
  function automatic bit host_mem_mapping_call_since(
    rdma_mock_host_mem mem,
    string method_name,
    rdma_dma_mapping mapping,
    int unsigned start_index
  );
    if (mem == null || mapping == null || start_index > mem.calls.size())
      return 1'b0;
    for (int unsigned i = start_index; i < mem.calls.size(); i++) begin
      if (mem.calls[i] != null &&
          mem.calls[i].method_name == method_name &&
          mem.calls[i].mapping != null &&
          mem.calls[i].mapping.iova.value == mapping.iova.value)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  // 功能：make_cq_backing_slice 把真实 Host-memory mapping 的一个 4KiB 范围描述为
  //   lifecycle borrowed CQ slice，并显式发布其逻辑 queue offset。
  // 输入/输出及副作用：name、mapping、logical_offset 为输入；返回新 slice 值对象，
  //   不修改 mapping 权限/状态，也不取得 allocation release authority。
  // 失败边界：mapping 为空时返回 null；offset 必须由调用方选择 0 或 4096，最终
  //   对齐、连续性和 DEVICE_WRITE authority 仍由 lifecycle planner 完整校验。
  function automatic rdma_queue_backing_slice make_cq_backing_slice(
    string name,
    rdma_dma_mapping mapping,
    longint unsigned logical_offset
  );
    rdma_queue_backing_slice slice;

    if (mapping == null)
      return null;
    slice = rdma_queue_backing_slice::type_id::create(name);
    if (slice == null)
      return null;
    slice.role = RDMA_QUEUE_ROLE_CQ_RING;
    slice.mapping = mapping;
    slice.mapping_offset = 0;
    slice.length = 4096;
    slice.logical_queue_offset = logical_offset;
    return slice;
  endfunction

  // 功能：setup_segmented_cq_topology 建立真实 lifecycle CQ(depth=128, 64B CQE)，
  //   其 8KiB ring 借用两个 source lifecycle CQ 各自拥有的 4KiB mapping。
  // 输入/输出及副作用：label 为输入；输出 fixture、两个 source CQ、target CQ、
  //   primary/additional mapping 与 ref；source lifecycle 保持唯一 release owner。
  // 失败边界：任一 source/target create 或 plan shape 失败立即返回；mapping 必须先
  //   来自 source CQ plan，再由 target 返回 plan 输出，测试不得 attach 或直接 allocate。
  task automatic setup_segmented_cq_topology(
    string label,
    output rdma_queue_data_engine_fixture fixture,
    output rdma_cq source_cq_first,
    output rdma_cq source_cq_second,
    output rdma_cq segmented_cq,
    output rdma_queue_backing_ref backing,
    output rdma_dma_mapping first_mapping,
    output rdma_dma_mapping second_mapping,
    output rdma_status status
  );
    rdma_queue_backing_ref source_backing;
    rdma_queue_backing_slice slice;
    rdma_create_cq_req request;
    rdma_queue_resource resource;
    rdma_control_result control_result;

    fixture = null;
    source_cq_first = null;
    source_cq_second = null;
    segmented_cq = null;
    backing = null;
    first_mapping = null;
    second_mapping = null;
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "segmented CQ setup is incomplete");
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      {label, "_fixture"});
    if (fixture == null)
      return;
    fixture.setup(status);
    if (status == null || !status.ok())
      return;
    request = rdma_create_cq_req::type_id::create(
      {label, "_source_first_request"});
    if (request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "first source CQ request allocation failed");
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.depth = 16;
    request.cqe_size_bytes = 64;
    status = clone_test_handle_value(fixture.ceq.handle, request.ceq_h);
    if (status == null || !status.ok() || request.ceq_h == null)
      return;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), request, 64'h9201,
      resource, control_result);
    status = control_result == null ? null : control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(source_cq_first, resource))
      return;
    source_backing = null;
    foreach (source_cq_first.queue_plan.refs[i])
      if (source_cq_first.queue_plan.refs[i] != null &&
          source_cq_first.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        source_backing = source_cq_first.queue_plan.refs[i];
    if (source_backing == null || source_backing.mapping == null ||
        source_backing.length != 4096) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "first source CQ mapping is unavailable");
      return;
    end
    first_mapping = source_backing.mapping;

    request = rdma_create_cq_req::type_id::create(
      {label, "_source_second_request"});
    if (request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "second source CQ request allocation failed");
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.depth = 16;
    request.cqe_size_bytes = 64;
    status = clone_test_handle_value(fixture.ceq.handle, request.ceq_h);
    if (status == null || !status.ok() || request.ceq_h == null)
      return;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), request, 64'h9202,
      resource, control_result);
    status = control_result == null ? null : control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(source_cq_second, resource))
      return;
    source_backing = null;
    foreach (source_cq_second.queue_plan.refs[i])
      if (source_cq_second.queue_plan.refs[i] != null &&
          source_cq_second.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        source_backing = source_cq_second.queue_plan.refs[i];
    if (source_backing == null || source_backing.mapping == null ||
        source_backing.length != 4096) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "second source CQ mapping is unavailable");
      return;
    end
    second_mapping = source_backing.mapping;

    request = rdma_create_cq_req::type_id::create({label, "_cq_request"});
    if (request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "segmented CQ request allocation failed");
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.depth = 128;
    request.cqe_size_bytes = 64;
    status = clone_test_handle_value(fixture.ceq.handle, request.ceq_h);
    if (status == null || !status.ok() || request.ceq_h == null)
      return;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_BORROWED;
    request.ring_backing.slices.delete();
    slice = make_cq_backing_slice({label, "_primary_slice"},
                                  first_mapping, 0);
    if (slice == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "segmented CQ primary slice allocation failed");
      return;
    end
    request.ring_backing.slices.push_back(slice);
    slice = make_cq_backing_slice({label, "_additional_slice"},
                                  second_mapping, 4096);
    if (slice == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "segmented CQ additional slice allocation failed");
      return;
    end
    request.ring_backing.slices.push_back(slice);
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), request, 64'h9203,
      resource, control_result);
    status = control_result == null ? null : control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(segmented_cq, resource))
      return;
    foreach (segmented_cq.queue_plan.refs[i]) begin
      if (segmented_cq.queue_plan.refs[i] != null &&
          segmented_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING)
        backing = segmented_cq.queue_plan.refs[i];
    end
    if (backing == null || backing.mapping == null ||
        backing.additional_segments.size() != 1 ||
        backing.additional_segments[0] == null ||
        backing.additional_segments[0].mapping == null ||
        backing.length != 4096 ||
        backing.additional_segments[0].logical_queue_offset != 4096 ||
        backing.additional_segments[0].length != 4096) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "segmented CQ plan did not retain two mappings");
      return;
    end
    first_mapping = backing.mapping;
    second_mapping = backing.additional_segments[0].mapping;
    status = rdma_status::success();
  endtask

  // 功能：cleanup_segmented_cq_topology 按 target CQ、source CQ2、source CQ1 的
  //   借用依赖反序清理 plan-shape fixture，并核对 mapping 的唯一 release owner。
  // 输入/输出及副作用：fixture、三个可空 CQ 和两个 source mapping 为输入；调用
  //   lifecycle executor 销毁资源，target 不 release，source destroy 各 release 一份。
  // 失败边界：fixture 为空时安全返回；单项 destroy/ownership 断言失败均报告
  //   UVM_ERROR，但继续清理后续资源，避免首个 teardown 错误掩盖 source 泄漏。
  task automatic cleanup_segmented_cq_topology(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_cq source_cq_first,
    rdma_cq source_cq_second,
    rdma_cq segmented_cq,
    rdma_dma_mapping first_mapping,
    rdma_dma_mapping second_mapping
  );
    rdma_status cleanup_status;
    int unsigned calls_before_destroy;

    if (fixture == null)
      return;
    if (segmented_cq != null) begin
      calls_before_destroy = fixture.mem == null ? 0 : fixture.mem.calls.size();
      fixture.destroy_lifecycle_owned_queue(
        segmented_cq.handle, 1'b1, 1'b0,
        64'h92f2, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error({label, "_CQ_TEARDOWN"},
                         "segmented target CQ teardown failed");
      if (host_mem_mapping_call_since(
            fixture.mem, "release", first_mapping, calls_before_destroy) ||
          host_mem_mapping_call_since(
            fixture.mem, "release", second_mapping, calls_before_destroy) ||
          host_mem_mapping_call_since(
            fixture.mem, "release_opaque", first_mapping,
            calls_before_destroy) ||
          host_mem_mapping_call_since(
            fixture.mem, "release_opaque", second_mapping,
            calls_before_destroy))
        uvm_report_error({label, "_BORROWED_RELEASE"},
                         "segmented target CQ released source mapping");
    end
    if (source_cq_second != null) begin
      calls_before_destroy = fixture.mem == null ? 0 : fixture.mem.calls.size();
      fixture.destroy_lifecycle_owned_queue(
        source_cq_second.handle, 1'b1, 1'b0, 64'h92f3, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error({label, "_SOURCE_SECOND_TEARDOWN"},
                         "segmented second source CQ teardown failed");
      if (second_mapping != null && !host_mem_mapping_call_since(
            fixture.mem, "release", second_mapping, calls_before_destroy))
        uvm_report_error({label, "_SOURCE_SECOND_RELEASE"},
                         "second source CQ did not release owned mapping");
    end
    if (source_cq_first != null) begin
      calls_before_destroy = fixture.mem == null ? 0 : fixture.mem.calls.size();
      fixture.destroy_lifecycle_owned_queue(
        source_cq_first.handle, 1'b1, 1'b0, 64'h92f4, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error({label, "_SOURCE_FIRST_TEARDOWN"},
                         "segmented first source CQ teardown failed");
      if (first_mapping != null && !host_mem_mapping_call_since(
            fixture.mem, "release", first_mapping, calls_before_destroy))
        uvm_report_error({label, "_SOURCE_FIRST_RELEASE"},
                         "first source CQ did not release owned mapping");
    end
  endtask

  // 功能：check_rejected_publish_atomic 验证一次 CQ/CEQ/AEQ publish 确定性拒绝
  //   没有改变 backing、PI/CI、used、pending、reservation，且 result 保持 null。
  // 输入/输出及副作用：label、fixture、queue/kind/role/entry size、调用前快照、
  //   result/status 与期望错误码为输入；只调用公开 query/read API 并报告差异。
  // 失败边界：任一查询失败、status 为空/错误码不符、bytes/cursor/occupancy 变化、
  //   pending/reservation 出现或 result 非空均报告 UVM_ERROR；helper 不修复状态。
  task automatic check_rejected_publish_atomic(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_backing_role_e role,
    int unsigned entry_size,
    byte before_bytes[],
    int unsigned before_pi,
    bit before_pi_wrap,
    int unsigned before_ci,
    bit before_ci_wrap,
    int unsigned before_used,
    rdma_queue_device_publish_result result,
    rdma_status publish_status,
    rdma_status_code_e expected_code
  );
    byte after_bytes[];
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    int unsigned after_pi;
    int unsigned after_ci;
    int unsigned after_used;
    bit after_pi_wrap;
    bit after_ci_wrap;
    bit has_pending;
    bit reservation_valid;

    if (publish_status == null || publish_status.code != expected_code ||
        result != null)
      `uvm_error(label, publish_status == null ? "publish returned null status" :
                 $sformatf("unexpected rejection code=%0d message=%s result=%s",
                           publish_status.code, publish_status.message,
                           result == null ? "null" : "non-null"))
    status = fixture.engine.query_runtime_cursors(
      queue.handle, kind, after_pi, after_pi_wrap, after_ci, after_ci_wrap);
    if (status == null || !status.ok() || after_pi != before_pi ||
        after_pi_wrap != before_pi_wrap || after_ci != before_ci ||
        after_ci_wrap != before_ci_wrap)
      `uvm_error({label, "_CURSOR"}, "rejected publish changed PI/CI")
    status = fixture.engine.query_runtime_occupancy(
      queue.handle, kind, after_used, has_pending);
    if (status == null || !status.ok() || after_used != before_used || has_pending)
      `uvm_error({label, "_USED"}, "rejected publish changed used/pending")
    pending = null;
    status = fixture.engine.query_runtime_pending(queue.handle, kind, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE || pending != null)
      `uvm_error({label, "_PENDING"}, "rejected publish retained pending evidence")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      queue.handle, kind, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error({label, "_RESERVATION"}, "rejected publish retained reservation")
    status = read_queue_backing_slot(fixture, queue, role, before_pi,
                                     entry_size, after_bytes);
    if (status == null || !status.ok() || after_bytes != before_bytes)
      `uvm_error({label, "_BACKING"}, "rejected publish changed backing bytes")
  endtask

  // 功能：capture_publish_queue_state 在负例调用前取得 queue 的 backing、PI/CI、
  //   used 与 pending 基线，确保每个拒绝断言都有独立原子性证据。
  // 输入/输出及副作用：fixture、queue/kind/role/entry size 为输入，其余为输出；
  //   只读公开 runtime 与 Host-memory，不创建 reservation 或推进 cursor。
  // 失败边界：任一 query/read 失败或队列已有 pending 时 status 非成功；所有数值和
  //   bytes 先归一化为安全默认值，调用方不得在失败后继续 publish。
  task automatic capture_publish_queue_state(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_resource queue,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_backing_role_e role,
    int unsigned entry_size,
    output byte bytes[],
    output int unsigned pi,
    output bit pi_wrap,
    output int unsigned ci,
    output bit ci_wrap,
    output int unsigned used,
    output rdma_status status
  );
    bit pending;

    bytes = new[0];
    pi = 0;
    pi_wrap = 1'b0;
    ci = 0;
    ci_wrap = 1'b0;
    used = 0;
    status = fixture.engine.query_runtime_cursors(
      queue.handle, kind, pi, pi_wrap, ci, ci_wrap);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      queue.handle, kind, used, pending);
    if (status == null || !status.ok() || pending) begin
      if (status != null && status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "queue state capture found pending operation");
      return;
    end
    status = read_queue_backing_slot(fixture, queue, role, pi,
                                     entry_size, bytes);
  endtask

  // 功能：check_cqe_authority_rejections 逐项覆盖 foreign QPN、错误 QP identity/
  //   Function、stale generation、错误 rq_cqe、非 outstanding WQE 与 polarity。
  // 输入/输出及副作用：无显式输入；每个 case 使用同一真实 posted SQ WQE 和独立
  //   调用前快照，调用公开 publish_cqe 后验证完整拒绝原子性。
  // 失败边界：fixture/post/model/snapshot 失败会报告并停止；任一拒绝错误码、result、
  //   backing、PI/CI、used/pending/reservation 变化由公共原子性 helper 报告。
  task automatic check_cqe_authority_rejections();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_status status;
    rdma_status model_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    bit before_pi_wrap;
    bit before_ci_wrap;
    longint unsigned saved_function_uid;
    int unsigned saved_object_id;
    int unsigned saved_generation;
    bit saved_polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cqe_authority_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_AUTH_SETUP", "CQE authority fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'ha001), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_AUTH_POST", "CQE authority post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, saved_polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, saved_polarity, model_status);
    capture_publish_queue_state(fixture, fixture.cq, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, fixture.cq.cqe_size_bytes, before_bytes,
      before_pi, before_pi_wrap, before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_AUTH_MODEL", "CQE authority baseline is incomplete")
      return;
    end

    cqe.qpn = fixture.qp.local_qp_id + 1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_FOREIGN_QPN", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    cqe.qpn = fixture.qp.local_qp_id;

    saved_object_id = cqe.qp_h.object_id;
    cqe.qp_h.object_id = saved_object_id + 1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_WRONG_QP_HANDLE", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    cqe.qp_h.object_id = saved_object_id;

    saved_function_uid = cqe.qp_h.function_uid;
    cqe.qp_h.function_uid = saved_function_uid + 1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_WRONG_FUNCTION", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
    cqe.qp_h.function_uid = saved_function_uid;

    saved_generation = cqe.qp_h.generation;
    cqe.qp_h.generation = saved_generation + 1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_STALE_GENERATION", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_STALE_GENERATION);
    cqe.qp_h.generation = saved_generation;

    cqe.rq_cqe = 1'b1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_WRONG_RQ_CQE", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    cqe.rq_cqe = 1'b0;

    cqe.wqe_index = posted.index + 1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_WQE_LEDGER", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    cqe.wqe_index = posted.index;

    cqe.polarity = ~saved_polarity;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_POLARITY", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
  endtask

  // 功能：check_cqe_full_atomic 用十六个真实 outstanding SQ WQE 填满 CQ，验证
  //   下一次合法 CQE 因 credit exhausted 返回 QUEUE_FULL 且保持事务原子性。
  // 输入/输出及副作用：无显式输入；成功场景先发布完整 CQ ring，再检查 full
  //   拒绝的 backing/PI/CI/used/pending/result，最后 poll 全部 CQE 释放 ledger。
  // 失败边界：任一 post/publish/snapshot/poll 失败报告 UVM_ERROR；full 拒绝不得
  //   占用 reservation 或改变已满 ring，cleanup poll 必须恰好消费 depth 条。
  task automatic check_cqe_full_atomic();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted[$];
    rdma_hw_cqe_model cqe;
    rdma_hw_cqe_model retry_cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_status status;
    rdma_status model_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    int unsigned fill_start_pi;
    int unsigned fill_start_ci;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit fill_start_pi_wrap;
    bit fill_start_ci_wrap;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create("cqe_full_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_FULL_SETUP", "CQE full fixture setup failed")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, fill_start_pi,
      fill_start_pi_wrap, fill_start_ci, fill_start_ci_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_FULL_START", "CQE initial cursor query failed")
      return;
    end
    for (int unsigned i = 0; i < fixture.cq.depth; i++) begin
      rdma_queue_post_result one_post;
      fixture.engine.post_send(fixture.make_send(64'hb000 + i), one_post, status);
      if (status == null || !status.ok() || one_post == null) begin
        `uvm_error("CQE_FULL_POST", $sformatf("post %0d failed", i))
        return;
      end
      posted.push_back(one_post);
      status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
        fixture.qp.local_qp_id, one_post, polarity, model_status);
      if (status == null || !status.ok() || model_status == null ||
          !model_status.ok() || cqe == null) begin
        `uvm_error("CQE_FULL_MODEL", $sformatf("model %0d failed", i))
        return;
      end
      publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                           published, status);
      if (status == null || !status.ok() || published == null) begin
        `uvm_error("CQE_FULL_FILL", $sformatf("publish %0d failed", i))
        return;
      end
      if (i == 0 && !$cast(retry_cqe, cqe.clone())) begin
        `uvm_error("CQE_FULL_RETRY_MODEL", "retry CQE clone failed")
        return;
      end
    end
    capture_publish_queue_state(fixture, fixture.cq, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, fixture.cq.cqe_size_bytes, before_bytes,
      before_pi, before_pi_wrap, before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok() || before_pi != fill_start_pi ||
        before_pi_wrap == fill_start_pi_wrap || before_ci != fill_start_ci ||
        before_ci_wrap != fill_start_ci_wrap || before_used != fixture.cq.depth)
      `uvm_error("CQE_FULL_WRAP",
                 "filling one CQ depth did not toggle only producer wrap")
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    retry_cqe.polarity = polarity;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, retry_cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_FULL", fixture, fixture.cq,
      RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_QUEUE_FULL);
    for (int unsigned i = 0; i < fixture.cq.depth; i++) begin
      fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
      if (status == null || !status.ok() || completion == null)
        `uvm_error("CQE_FULL_DRAIN", $sformatf("poll %0d failed", i))
    end
  endtask

  // 功能：check_cqe_authority_width 以完整 local_qp_id=18'h4_0000 验证 CQE
  //   producer 在 packed qpn 编码前拒绝不可表示的 QP authority。
  // 输入/输出及副作用：无显式输入；通过 factory 创建独立 width manager fixture，
  //   发布一个真实 SQ WQE，再用合法 packed qpn=0 调用 publish_cqe。
  // 失败边界：fixture 未取得指定超宽 QPN、publish 非 INVALID_ARGUMENT，或 backing/
  //   PI/CI/used/pending/result 任一变化均报告 UVM_ERROR；不修改 model 字段宽度。
  task automatic check_cqe_authority_width();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_status status;
    rdma_status model_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit polarity;

    rdma_resource_manager::type_id::set_type_override(
      rdma_device_publish_width_manager::get_type());
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cqe_width_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() || fixture.qp == null ||
        fixture.qp.local_qp_id != 32'h0004_0000) begin
      `uvm_error("CQE_WIDTH_SETUP", "wide QP fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hc001), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_WIDTH_POST", "wide QP WQE post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_WIDTH_POLARITY", "wide CQ polarity query failed")
      return;
    end
    // model.qpn 是合法 18-bit 0；完整超宽 authority 只保留在 attached QP link。
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle, 0, posted,
                                         polarity, model_status);
    capture_publish_queue_state(fixture, fixture.cq, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, fixture.cq.cqe_size_bytes, before_bytes,
      before_pi, before_pi_wrap, before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_WIDTH_MODEL", "wide QP CQE setup failed")
      return;
    end
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    check_rejected_publish_atomic("CQE_WIDE_QPN_AUTHORITY", fixture,
      fixture.cq, RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_ROLE_CQ_RING,
      fixture.cq.cqe_size_bytes, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
  endtask

  // 功能：check_ceqe_runtime_width 让 routed CQ committed PI=65536，验证
  //   publish_ceqe 在把 PI 写入 16-bit cq_pi 之前由生产边界拒绝。
  // 输入/输出及副作用：无显式输入；创建 lifecycle-owned CEQ 并 attach，CQ runtime
  //   由 test-only engine 设为超宽，模型 cq_pi 保持合法 packed 0。
  // 失败/边界：fixture/CEQ/runtime setup、cast 或快照失败报告错误；publish 必须返回
  //   INVALID_ARGUMENT，且 CEQ backing/PI/CI/used/pending/result 完全不变。
  task automatic check_ceqe_runtime_width();
    rdma_queue_data_engine_fixture fixture;
    rdma_device_publish_width_runtime_engine width_engine;
    rdma_create_ceq_req request;
    rdma_queue_resource resource;
    rdma_control_result control_result;
    rdma_ceq ceq;
    rdma_hw_ceqe_model ceqe;
    rdma_queue_device_publish_result published;
    rdma_status status;
    rdma_status cleanup_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit polarity;
    bit ceq_created;
    bit ceq_attached;

    rdma_queue_data_engine::type_id::set_type_override(
      rdma_device_publish_width_runtime_engine::get_type());
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "ceqe_width_fixture");
    fixture.setup(status);
    ceq = null;
    ceq_created = 1'b0;
    ceq_attached = 1'b0;
    if (status == null || !status.ok() ||
        !$cast(width_engine, fixture.engine)) begin
      `uvm_error("CEQE_WIDTH_SETUP", "width engine fixture setup failed")
      return;
    end
    request = rdma_create_ceq_req::type_id::create("ceqe_width_ceq_request");
    if (request == null) begin
      `uvm_error("CEQE_WIDTH_REQUEST", "width CEQ request allocation failed")
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.depth = 16;
    request.vector_id = 1;
    request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    fixture.queue_executor.create_locked(fixture.binding,
      fixture.binding.make_handle(), request, 64'h9101, resource, control_result);
    status = control_result == null ? null : control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(ceq, resource)) begin
      `uvm_error("CEQE_WIDTH_CEQ", "width CEQ create failed")
      return;
    end
    ceq_created = 1'b1;
    status = fixture.engine.attach_ceq(ceq.handle);
    if (status == null || !status.ok()) begin
      `uvm_error("CEQE_WIDTH_ATTACH", "width CEQ attach failed")
    end else begin
      ceq_attached = 1'b1;
      status = width_engine.install_wide_cq_runtime(
        fixture.cq.handle, ceq.handle);
      if (status == null || !status.ok())
        `uvm_error("CEQE_WIDTH_RUNTIME", "wide CQ runtime install failed")
      else begin
        status = fixture.engine.query_runtime_producer_polarity(
          ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
        ceqe = rdma_hw_ceqe_model::type_id::create("wide_runtime_ceqe");
        if (status == null || !status.ok() || ceqe == null) begin
          `uvm_error("CEQE_WIDTH_MODEL", "width CEQE allocation/polarity failed")
        end else begin
          status = clone_test_handle(fixture.cq.handle, ceqe.cq_h);
          if (status == null || !status.ok() || ceqe.cq_h == null) begin
            `uvm_error("CEQE_WIDTH_HANDLE", "width CEQE CQ clone failed")
          end else begin
            ceqe.cqn = fixture.cq.local_cq_id;
            ceqe.qpn = 0;
            ceqe.cq_pi = 16'h0;
            ceqe.cq_pi_wrap = 1'b0;
            ceqe.valid = polarity;
            ceqe.ecode = 0;
            ceqe.packet_opcode = 0;
            capture_publish_queue_state(fixture, ceq, RDMA_QUEUE_RUNTIME_CEQ,
              RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi,
              before_pi_wrap, before_ci, before_ci_wrap, before_used, status);
            if (status == null || !status.ok()) begin
              `uvm_error("CEQE_WIDTH_STATE", "width CEQ state capture failed")
            end else begin
              fixture.engine.publish_ceqe(ceq.handle, ceqe, published, status);
              check_rejected_publish_atomic("CEQE_WIDE_PI", fixture, ceq,
                RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_ROLE_CEQ_RING, 16,
                before_bytes, before_pi, before_pi_wrap, before_ci,
                before_ci_wrap, before_used, published, status,
                RDMA_SC_INVALID_ARGUMENT);
            end
          end
        end
      end
    end
    fixture.destroy_lifecycle_owned_queue(
      ceq.handle, ceq_created, ceq_attached, 64'h9111, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("CEQE_WIDTH_TEARDOWN", "width CEQ teardown failed")
  endtask

  // 功能：make_ceqe_from_committed_cq 读取已提交 CQ producer cursor，构造指向
  //   同一 CQ/QP route 的 CEQE，供真实 CEQ publish/poll 路径消费。
  // 输入/输出及副作用：queue_data、cq_h、cqn、qpn、valid 为输入，model/status
  //   为输出；只读取 runtime cursor 并分配 detached model/handle，不修改 backing。
  // 失败边界：engine/CQ 为空、cursor 查询失败、PI 超过 CEQE 16 位表示范围或
  //   factory/handle clone 失败时返回非成功，model 保持 null。
  task automatic make_ceqe_from_committed_cq(
    rdma_queue_data_engine queue_data,
    rdma_handle cq_h,
    int unsigned cqn,
    int unsigned qpn,
    bit valid,
    output rdma_hw_ceqe_model model,
    output rdma_status status
  );
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    model = null;
    status = rdma_status::success();
    if (queue_data == null || cq_h == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ runtime query input is null");
      return;
    end
    status = queue_data.query_runtime_cursors(
      cq_h, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    if (producer_index > 16'hffff) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "CQ producer index cannot fit in CEQE");
      return;
    end
    model = rdma_hw_ceqe_model::type_id::create("test_ceqe");
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "test CEQE model allocation failed");
      return;
    end
    status = clone_test_handle(cq_h, model.cq_h);
    if (status == null || !status.ok() || model.cq_h == null) begin
      model = null;
      if (status == null)
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "test CEQE CQ handle clone returned null status");
      return;
    end
    model.cqn = cqn;
    model.qpn = qpn;
    model.cq_pi = producer_index & 16'hffff;
    model.cq_pi_wrap = producer_wrap;
    model.valid = valid;
    model.ecode = 8'h00;
    model.packet_opcode = 8'h00;
    status = rdma_status::success();
  endtask

  // 功能：setup_event_publish_topology 创建并 attach 独立的 lifecycle-owned
  //   两个 CEQ、AEQ、CQ，以及分别属于事件 CQ 和基础 CQ 的两个真实 RC QP。
  // 输入/输出及副作用：输出 fixture、正确/错误 CEQ、AEQ、CQ、两个 QP、每项
  //   created/attached 阶段状态与 status；成功会在 manager/Host-memory 建立资源，
  //   并把非拥有 route 登记到 queue-data engine。
  // 失败边界：任一 factory/create/cast/clone/attach 失败立即返回非成功 status；所有
  //   已发布的部分资源仍经输出交给统一 cleanup，不以 dependency-only CEQ 替代。
  task automatic setup_event_publish_topology(
    output rdma_queue_data_engine_fixture fixture,
    output rdma_ceq lifecycle_ceq,
    output rdma_ceq wrong_ceq,
    output rdma_aeq lifecycle_aeq,
    output rdma_cq lifecycle_cq,
    output rdma_qp event_qp,
    output rdma_qp foreign_qp,
    output bit lifecycle_ceq_created,
    output bit lifecycle_ceq_attached,
    output bit wrong_ceq_created,
    output bit wrong_ceq_attached,
    output bit lifecycle_aeq_created,
    output bit lifecycle_aeq_attached,
    output bit lifecycle_cq_created,
    output bit lifecycle_cq_attached,
    output bit event_qp_created,
    output bit event_qp_attached,
    output bit foreign_qp_created,
    output bit foreign_qp_attached,
    output rdma_status status
  );
    rdma_create_ceq_req ceq_request;
    rdma_create_aeq_req aeq_request;
    rdma_create_cq_req cq_request;
    rdma_queue_resource resource;
    rdma_control_result control_result;

    fixture = null;
    lifecycle_ceq = null;
    wrong_ceq = null;
    lifecycle_aeq = null;
    lifecycle_cq = null;
    event_qp = null;
    foreign_qp = null;
    lifecycle_ceq_created = 1'b0;
    lifecycle_ceq_attached = 1'b0;
    wrong_ceq_created = 1'b0;
    wrong_ceq_attached = 1'b0;
    lifecycle_aeq_created = 1'b0;
    lifecycle_aeq_attached = 1'b0;
    lifecycle_cq_created = 1'b0;
    lifecycle_cq_attached = 1'b0;
    event_qp_created = 1'b0;
    event_qp_attached = 1'b0;
    foreign_qp_created = 1'b0;
    foreign_qp_attached = 1'b0;
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "event topology setup is incomplete");

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "event_publish_fixture");
    if (fixture == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "event fixture allocation failed");
      return;
    end
    fixture.setup(status);
    if (status == null || !status.ok()) return;

    ceq_request = rdma_create_ceq_req::type_id::create("publish_ceq_request");
    if (ceq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "CEQ request allocation failed");
      return;
    end
    ceq_request.owner = fixture.binding.make_handle();
    ceq_request.depth = 16;
    ceq_request.vector_id = 1;
    ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), ceq_request, 64'h9001,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "CEQ create returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(lifecycle_ceq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "CEQ create returned invalid resource");
      return;
    end
    lifecycle_ceq_created = 1'b1;
    status = fixture.engine.attach_ceq(lifecycle_ceq.handle);
    if (status == null || !status.ok()) return;
    lifecycle_ceq_attached = 1'b1;

    ceq_request = rdma_create_ceq_req::type_id::create(
      "publish_wrong_ceq_request");
    if (ceq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "wrong CEQ request allocation failed");
      return;
    end
    ceq_request.owner = fixture.binding.make_handle();
    ceq_request.depth = 16;
    ceq_request.vector_id = 1;
    ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), ceq_request, 64'h9006,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "wrong CEQ create returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(wrong_ceq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "wrong CEQ create returned invalid resource");
      return;
    end
    wrong_ceq_created = 1'b1;
    status = fixture.engine.attach_ceq(wrong_ceq.handle);
    if (status == null || !status.ok()) return;
    wrong_ceq_attached = 1'b1;

    aeq_request = rdma_create_aeq_req::type_id::create("publish_aeq_request");
    if (aeq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "AEQ request allocation failed");
      return;
    end
    aeq_request.owner = fixture.binding.make_handle();
    aeq_request.depth = 16;
    aeq_request.vector_id = 2;
    aeq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), aeq_request, 64'h9002,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "AEQ create returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(lifecycle_aeq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "AEQ create returned invalid resource");
      return;
    end
    lifecycle_aeq_created = 1'b1;
    status = fixture.engine.attach_aeq(lifecycle_aeq.handle);
    if (status == null || !status.ok()) return;
    lifecycle_aeq_attached = 1'b1;

    cq_request = rdma_create_cq_req::type_id::create("publish_cq_request");
    if (cq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "CQ request allocation failed");
      return;
    end
    cq_request.owner = fixture.binding.make_handle();
    cq_request.depth = 16;
    cq_request.cqe_size_bytes = RDMA_CQE_BYTES;
    status = clone_test_handle_value(lifecycle_ceq.handle, cq_request.ceq_h);
    if (status == null || !status.ok() || cq_request.ceq_h == null) return;
    cq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), cq_request, 64'h9003,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "CQ create returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(lifecycle_cq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "CQ create returned invalid resource");
      return;
    end
    lifecycle_cq_created = 1'b1;
    status = fixture.engine.attach_cq(lifecycle_cq.handle, RDMA_TRANSPORT_RC);
    if (status == null || !status.ok()) return;
    lifecycle_cq_attached = 1'b1;

    fixture.create_transport_qp_for_cq(
      "event_publish_qp", RDMA_TRANSPORT_RC, lifecycle_cq, event_qp, status);
    if (status == null || !status.ok() || event_qp == null) return;
    event_qp_created = 1'b1;
    status = fixture.engine.attach_qp(event_qp.handle);
    if (status == null || !status.ok()) return;
    event_qp_attached = 1'b1;

    fixture.create_transport_qp_for_cq(
      "event_foreign_qp", RDMA_TRANSPORT_RC, fixture.cq, foreign_qp, status);
    if (status == null || !status.ok() || foreign_qp == null) return;
    foreign_qp_created = 1'b1;
    status = fixture.engine.attach_qp(foreign_qp.handle);
    if (status == null || !status.ok()) return;
    foreign_qp_attached = 1'b1;

    status = rdma_status::success();
  endtask

  // 功能：check_ceqe_publish_cases 在真实 CQ/CEQ/QP route 上验证 qpn=0、非零
  //   qpn、显式 CQ poll、authority/PI/polarity 拒绝以及满环 credit 契约。
  // 输入/输出及副作用：fixture、正确/错误 lifecycle CEQ、CQ 与两个 QP 为输入，
  //   status 为输出；成功路径写入并消费 CQE/CEQE，拒绝路径只读取原子性快照。
  // 失败边界：正向 prerequisite 失败立即返回；每个负例必须保持 backing、cursor、
  //   used、pending/reservation 和 result 不变，完整填充一圈必须显式翻转 producer wrap。
  task automatic check_ceqe_publish_cases(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq lifecycle_ceq,
    rdma_ceq wrong_ceq,
    rdma_cq lifecycle_cq,
    rdma_qp event_qp,
    rdma_qp foreign_qp,
    output rdma_status status
  );
    rdma_post_send_req send_request;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_ceqe_model polled_ceqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_queue_completion_result completion;
    rdma_status model_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    int unsigned fill_start_pi;
    int unsigned fill_start_ci;
    int unsigned saved_cqn;
    int unsigned saved_cq_pi;
    int unsigned saved_object_id;
    int unsigned saved_generation;
    longint unsigned saved_function_uid;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit fill_start_pi_wrap;
    bit fill_start_ci_wrap;
    bit saved_cq_pi_wrap;
    bit ceq_polarity;
    bit wrong_ceq_polarity;
    bit has_pending;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "CEQE publish cases are incomplete");
    send_request = fixture.make_send(64'h9004);
    model_status = clone_test_handle_value(event_qp.handle, send_request.qp_h);
    if (model_status == null || !model_status.ok() ||
        send_request.qp_h == null) begin
      status = model_status;
      return;
    end
    fixture.engine.post_send(send_request, posted, status);
    if (status == null || !status.ok() || posted == null) return;
    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_cq.handle, RDMA_QUEUE_RUNTIME_CQ, ceq_polarity);
    if (status == null || !status.ok()) return;
    cqe = make_cqe_for_outstanding_send(
      event_qp.handle, event_qp.local_qp_id, posted, ceq_polarity, model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      status = model_status;
      return;
    end
    publish_cqe_for_test(
      fixture.engine, lifecycle_cq.handle, cqe, published, status);
    if (status == null || !status.ok() || published == null) return;

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, ceq_polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
      ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    if (status == null || !status.ok() || published == null) return;
    fixture.engine.poll_ceqe(
      lifecycle_ceq.handle, 0, event_result, status);
    polled_ceqe = null;
    if (status == null || !status.ok() || event_result == null ||
        event_result.queue_h == null ||
        !event_result.queue_h.same_instance(lifecycle_ceq.handle) ||
        !$cast(polled_ceqe, event_result.event_model) ||
        polled_ceqe.cq_h == null ||
        !polled_ceqe.cq_h.same_instance(lifecycle_cq.handle) ||
        polled_ceqe.cqn != lifecycle_cq.local_cq_id) begin
      uvm_report_error("EVENT_PUBLISH_CEQE_POLL",
                       "CEQE poll did not preserve CEQ/CQ route identity");
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CEQE poll route identity mismatch");
      return;
    end
    fixture.engine.poll_cqe(
      lifecycle_cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != 64'h9004) return;

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, ceq_polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id,
      event_qp.local_qp_id, ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    if (status == null || !status.ok() || published == null) return;
    fixture.engine.poll_ceqe(
      lifecycle_ceq.handle, 0, event_result, status);
    if (status == null || !status.ok() || event_result == null) return;

    // 设计说明：cqn/cq_h 只能证明事件来源 CQ，不能授权目标 CEQ。这里选择同一
    // Function 内另一个已 attach 的真实 CEQ，并令 valid 匹配该错误 CEQ 的当前
    // producer polarity，确保拒绝只能来自被冻结的 CQ→CEQ dependency。
    status = fixture.engine.query_runtime_producer_polarity(
      wrong_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, wrong_ceq_polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
      wrong_ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    capture_publish_queue_state(
      fixture, wrong_ceq, RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_ROLE_CEQ_RING,
      16, before_bytes, before_pi, before_pi_wrap, before_ci, before_ci_wrap,
      before_used, status);
    if (status == null || !status.ok()) return;
    fixture.engine.publish_ceqe(wrong_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_WRONG_CEQ", fixture, wrong_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);

    capture_publish_queue_state(
      fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok()) return;

    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id,
      foreign_qp.local_qp_id, ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_FOREIGN_QPN", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);

    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id,
      event_qp.local_qp_id, ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    saved_cqn = ceqe.cqn;
    ceqe.cqn = saved_cqn + 1;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_WRONG_CQN", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    ceqe.cqn = saved_cqn;

    saved_object_id = ceqe.cq_h.object_id;
    ceqe.cq_h.object_id = saved_object_id + 1;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_WRONG_CQ_HANDLE", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    ceqe.cq_h.object_id = saved_object_id;

    saved_function_uid = ceqe.cq_h.function_uid;
    ceqe.cq_h.function_uid = saved_function_uid + 1;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_WRONG_FUNCTION", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
    ceqe.cq_h.function_uid = saved_function_uid;

    saved_generation = ceqe.cq_h.generation;
    ceqe.cq_h.generation = saved_generation + 1;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_STALE_GENERATION", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_STALE_GENERATION);
    ceqe.cq_h.generation = saved_generation;

    saved_cq_pi = ceqe.cq_pi;
    ceqe.cq_pi = saved_cq_pi + 1;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_PI", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
    ceqe.cq_pi = saved_cq_pi;

    saved_cq_pi_wrap = ceqe.cq_pi_wrap;
    ceqe.cq_pi_wrap = ~saved_cq_pi_wrap;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_CQ_WRAP", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
    ceqe.cq_pi_wrap = saved_cq_pi_wrap;

    ceqe.valid = ~ceqe.valid;
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_POLARITY", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);

    status = fixture.engine.query_runtime_cursors(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, fill_start_pi,
      fill_start_pi_wrap, fill_start_ci, fill_start_ci_wrap);
    if (status == null || !status.ok()) return;
    for (int unsigned i = 0; i < lifecycle_ceq.depth; i++) begin
      status = fixture.engine.query_runtime_producer_polarity(
        lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, ceq_polarity);
      if (status == null || !status.ok()) return;
      make_ceqe_from_committed_cq(
        fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
        ceq_polarity, ceqe, model_status);
      if (model_status == null || !model_status.ok() || ceqe == null) begin
        status = model_status;
        return;
      end
      fixture.engine.publish_ceqe(
        lifecycle_ceq.handle, ceqe, published, status);
      if (status == null || !status.ok() || published == null) return;
    end
    capture_publish_queue_state(
      fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok()) return;
    if (before_pi != fill_start_pi ||
        before_pi_wrap == fill_start_pi_wrap ||
        before_ci != fill_start_ci ||
        before_ci_wrap != fill_start_ci_wrap ||
        before_used != lifecycle_ceq.depth)
      uvm_report_error(
        "CEQE_FULL_WRAP",
        "filling one CEQ depth did not toggle only producer wrap");
    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, ceq_polarity);
    if (status == null || !status.ok()) return;
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
      ceq_polarity, ceqe, model_status);
    if (model_status == null || !model_status.ok() || ceqe == null) begin
      status = model_status;
      return;
    end
    fixture.engine.publish_ceqe(
      lifecycle_ceq.handle, ceqe, published, status);
    check_rejected_publish_atomic(
      "CEQE_FULL", fixture, lifecycle_ceq, RDMA_QUEUE_RUNTIME_CEQ,
      RDMA_QUEUE_ROLE_CEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_QUEUE_FULL);
    for (int unsigned i = 0; i < lifecycle_ceq.depth; i++) begin
      fixture.engine.poll_ceqe(
        lifecycle_ceq.handle, 0, event_result, status);
      if (status == null || !status.ok() || event_result == null) return;
    end
    status = fixture.engine.query_runtime_occupancy(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, before_used, has_pending);
    if (status == null || !status.ok() || before_used != 0 || has_pending) begin
      if (status != null && status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "CEQ drain did not restore credit");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：check_aeqe_publish_cases 验证真实非零 QP 目标的 AEQE 发布、16-byte
  //   write/readback recovery、poll 身份、target/Function/generation/polarity 拒绝
  //   以及满环 credit 与恢复。
  // 输入/输出及副作用：fixture、lifecycle_aeq、event_qp/foreign_qp 为输入，
  //   status 为输出；成功路径写入/消费 AEQ，负例仅观察原子性快照。
  // 失败边界：目标必须是同 Function/代际的 attached QP 且 qpn 非零；满一整圈
  //   必须只翻转 producer wrap，full 拒绝与最终 drain 不得遗留 pending/占用。
  task automatic check_aeqe_publish_cases(
    rdma_queue_data_engine_fixture fixture,
    rdma_aeq lifecycle_aeq,
    rdma_qp event_qp,
    rdma_qp foreign_qp,
    output rdma_status status
  );
    rdma_hw_aeqe_model aeqe;
    rdma_hw_aeqe_model polled_aeqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_queue_pending_operation recovery_pending;
    rdma_status clone_status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    int unsigned fill_start_pi;
    int unsigned fill_start_ci;
    int unsigned saved_qpn;
    int unsigned saved_object_id;
    int unsigned saved_generation;
    longint unsigned saved_function_uid;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit fill_start_pi_wrap;
    bit fill_start_ci_wrap;
    bit aeq_polarity;
    bit has_pending;
    int unsigned recovery_writes_before;
    int unsigned recovery_reads_before;

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, aeq_polarity);
    aeqe = rdma_hw_aeqe_model::type_id::create("test_aeqe");
    if (status == null || !status.ok() || aeqe == null) begin
      if (status != null && status.ok())
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "AEQE model allocation failed");
      return;
    end
    clone_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
    if (clone_status == null || !clone_status.ok() || aeqe.target_h == null) begin
      status = clone_status;
      return;
    end
    aeqe.qpn = event_qp.local_qp_id;
    aeqe.valid = aeq_polarity;
    aeqe.ecode = 0;
    aeqe.packet_opcode = 0;
    recovery_writes_before = count_host_mem_calls(fixture.mem, "write");
    recovery_reads_before = count_host_mem_calls(fixture.mem, "read");
    fixture.mem.corrupt_next_readback = 1'b1;
    published = null;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQE readback mismatch was not retained");
      return;
    end
    recovery_pending = null;
    status = fixture.engine.query_runtime_pending(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, recovery_pending);
    if (status == null || !status.ok() || recovery_pending == null ||
        !recovery_pending.device_producer ||
        !recovery_pending.device_write_attempted ||
        recovery_pending.image == null || recovery_pending.image.length != 16 ||
        recovery_pending.cursor == null || recovery_pending.next_cursor == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQE recovery evidence is incomplete");
      return;
    end
    fixture.engine.recover_queue(
      lifecycle_aeq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQE unconfirmed retry was accepted");
      return;
    end
    fixture.engine.recover_queue(
      lifecycle_aeq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok() ||
        count_host_mem_calls(fixture.mem, "write") !=
          recovery_writes_before + 2 ||
        count_host_mem_calls(fixture.mem, "read") !=
          recovery_reads_before + 2) begin
      if (status != null && status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "AEQE recovery did not replay 16-byte I/O once");
      return;
    end
    fixture.engine.poll_aeqe(
      lifecycle_aeq.handle, 0, event_result, status);
    polled_aeqe = null;
    if (status == null || !status.ok() || event_result == null ||
        event_result.queue_h == null ||
        !event_result.queue_h.same_instance(lifecycle_aeq.handle) ||
        !$cast(polled_aeqe, event_result.event_model) ||
        polled_aeqe.target_h == null ||
        !polled_aeqe.target_h.same_instance(event_qp.handle) ||
        polled_aeqe.qpn != event_qp.local_qp_id) begin
      uvm_report_error("EVENT_PUBLISH_AEQE_POLL",
                       "AEQE poll did not preserve AEQ/QP route identity");
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "AEQE poll route identity mismatch");
      return;
    end

    capture_publish_queue_state(
      fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok()) return;

    saved_object_id = aeqe.target_h.object_id;
    aeqe.target_h.object_id = saved_object_id + 1;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_WRONG_TARGET", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    aeqe.target_h.object_id = saved_object_id;

    saved_qpn = aeqe.qpn;
    aeqe.qpn = foreign_qp.local_qp_id;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_FOREIGN_QPN", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_STATE);
    aeqe.qpn = saved_qpn;

    saved_function_uid = aeqe.target_h.function_uid;
    aeqe.target_h.function_uid = saved_function_uid + 1;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_WRONG_FUNCTION", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);
    aeqe.target_h.function_uid = saved_function_uid;

    saved_generation = aeqe.target_h.generation;
    aeqe.target_h.generation = saved_generation + 1;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_STALE_GENERATION", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_STALE_GENERATION);
    aeqe.target_h.generation = saved_generation;

    aeqe.valid = ~aeqe.valid;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_POLARITY", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_INVALID_ARGUMENT);

    status = fixture.engine.query_runtime_cursors(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, fill_start_pi,
      fill_start_pi_wrap, fill_start_ci, fill_start_ci_wrap);
    if (status == null || !status.ok()) return;
    for (int unsigned i = 0; i < lifecycle_aeq.depth; i++) begin
      status = fixture.engine.query_runtime_producer_polarity(
        lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, aeq_polarity);
      if (status == null || !status.ok()) return;
      aeqe.valid = aeq_polarity;
      fixture.engine.publish_aeqe(
        lifecycle_aeq.handle, aeqe, published, status);
      if (status == null || !status.ok() || published == null) return;
    end
    capture_publish_queue_state(
      fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok()) return;
    if (before_pi != fill_start_pi ||
        before_pi_wrap == fill_start_pi_wrap ||
        before_ci != fill_start_ci ||
        before_ci_wrap != fill_start_ci_wrap ||
        before_used != lifecycle_aeq.depth)
      uvm_report_error(
        "AEQE_FULL_WRAP",
        "filling one AEQ depth did not toggle only producer wrap");
    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, aeq_polarity);
    if (status == null || !status.ok()) return;
    aeqe.valid = aeq_polarity;
    fixture.engine.publish_aeqe(
      lifecycle_aeq.handle, aeqe, published, status);
    check_rejected_publish_atomic(
      "AEQE_FULL", fixture, lifecycle_aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status,
      RDMA_SC_QUEUE_FULL);
    for (int unsigned i = 0; i < lifecycle_aeq.depth; i++) begin
      fixture.engine.poll_aeqe(
        lifecycle_aeq.handle, 0, event_result, status);
      if (status == null || !status.ok() || event_result == null) return;
    end
    status = fixture.engine.query_runtime_occupancy(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, before_used, has_pending);
    if (status == null || !status.ok() || before_used != 0 || has_pending) begin
      if (status != null && status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "AEQ drain did not restore credit");
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：cleanup_event_publish_topology 按 foreign QP、event QP、CQ、AEQ、错误
  //   CEQ、正确 CEQ 的依赖反序销毁本测试创建的 lifecycle-owned 资源。
  // 输入/输出及副作用：fixture、六个可空资源及每项 created/attached 状态为输入；
  //   每个已创建资源依次按阶段 detach/destroy，并通过 UVM 报告清理结果，不接管
  //   基础 fixture 的资源。
  // 失败边界：fixture 为空时安全返回；单项失败只报告、不阻断后续独立资源清理，
  //   从而避免首个 teardown 错误掩盖其余生命周期泄漏。
  task automatic cleanup_event_publish_topology(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq lifecycle_ceq,
    rdma_ceq wrong_ceq,
    rdma_aeq lifecycle_aeq,
    rdma_cq lifecycle_cq,
    rdma_qp event_qp,
    rdma_qp foreign_qp,
    bit lifecycle_ceq_created,
    bit lifecycle_ceq_attached,
    bit wrong_ceq_created,
    bit wrong_ceq_attached,
    bit lifecycle_aeq_created,
    bit lifecycle_aeq_attached,
    bit lifecycle_cq_created,
    bit lifecycle_cq_attached,
    bit event_qp_created,
    bit event_qp_attached,
    bit foreign_qp_created,
    bit foreign_qp_attached
  );
    rdma_status cleanup_status;

    if (fixture == null) return;
    if (foreign_qp != null) begin
      fixture.destroy_lifecycle_owned_qp(
        foreign_qp.handle, foreign_qp_created, foreign_qp_attached,
        64'h9015, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_FOREIGN_QP_TEARDOWN",
                         "foreign QP teardown failed");
    end
    if (event_qp != null) begin
      fixture.destroy_lifecycle_owned_qp(
        event_qp.handle, event_qp_created, event_qp_attached,
        64'h9014, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_PUBLISH_QP_TEARDOWN",
                         "event QP teardown failed");
    end
    if (lifecycle_cq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        lifecycle_cq.handle, lifecycle_cq_created, lifecycle_cq_attached,
        64'h9013, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_PUBLISH_CQ_TEARDOWN",
                         "lifecycle CQ teardown failed");
    end
    if (lifecycle_aeq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        lifecycle_aeq.handle, lifecycle_aeq_created, lifecycle_aeq_attached,
        64'h9012, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_PUBLISH_AEQ_TEARDOWN",
                         "lifecycle AEQ teardown failed");
    end
    if (wrong_ceq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        wrong_ceq.handle, wrong_ceq_created, wrong_ceq_attached,
        64'h9016, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_WRONG_CEQ_TEARDOWN",
                         "wrong lifecycle CEQ teardown failed");
    end
    if (lifecycle_ceq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        lifecycle_ceq.handle, lifecycle_ceq_created, lifecycle_ceq_attached,
        64'h9011, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        uvm_report_error("EVENT_PUBLISH_CEQ_TEARDOWN",
                         "lifecycle CEQ teardown failed");
    end
  endtask

  // 功能：check_event_publish_api 编排 topology、CEQE、AEQE 与统一清理四个阶段，
  //   使每个事件类型的 authority/full/route 断言保持独立可读。
  // 输入/输出及副作用：无显式输入；创建真实 lifecycle backing，运行公开 producer/
  //   poll API，并无条件进入逆序 cleanup；只通过 UVM 报告暴露测试结果。
  // 失败边界：topology 失败时跳过 producer 但仍清理部分资源；CEQE 失败不阻断
  //   独立 AEQE 矩阵，任一阶段 null/non-success status 都产生明确 UVM_ERROR。
  task automatic check_event_publish_api();
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_status status;
    bit lifecycle_ceq_created;
    bit lifecycle_ceq_attached;
    bit wrong_ceq_created;
    bit wrong_ceq_attached;
    bit lifecycle_aeq_created;
    bit lifecycle_aeq_attached;
    bit lifecycle_cq_created;
    bit lifecycle_cq_attached;
    bit event_qp_created;
    bit event_qp_attached;
    bit foreign_qp_created;
    bit foreign_qp_attached;

    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, status);
    if (status == null || !status.ok()) begin
      uvm_report_error(
        "EVENT_PUBLISH_SETUP",
        status == null ? "event topology returned null status" :
                         status.convert2string());
    end else begin
      check_ceqe_publish_cases(
        fixture, lifecycle_ceq, wrong_ceq, lifecycle_cq, event_qp, foreign_qp,
        status);
      if (status == null || !status.ok())
        uvm_report_error(
          "EVENT_PUBLISH_CEQE",
          status == null ? "CEQE matrix returned null status" :
                           status.convert2string());
      check_aeqe_publish_cases(
        fixture, lifecycle_aeq, event_qp, foreign_qp, status);
      if (status == null || !status.ok())
        uvm_report_error(
          "EVENT_PUBLISH_AEQE",
          status == null ? "AEQE matrix returned null status" :
                           status.convert2string());
    end
    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached);
  endtask

  // 功能：check_device_publish_calls 断言 publish 在 mock Host-memory 中先发起
  //   一次真实 write、再发起同槽位 readback，且两次都使用 CQ mapping。
  // 输入/输出及副作用：mem、start、offset、image 为输入；任务只报告
  //   调用序列和方向契约，不修改 mock 记录或 backing bytes。
  // 失败边界：调用数量不足、顺序/映射/偏移/大小不匹配，或 write/read 方向不是
  //   DEVICE_READ 时报告 UVM_ERROR；mock call.direction 表示 host_mem API 访问
  //   方向而非 backing permission，故还必须断言快照为 device_write=1/read=0。
  task automatic check_device_publish_calls(
    rdma_mock_host_mem mem,
    int unsigned start,
    longint unsigned offset,
    rdma_hw_image image
  );
    if (mem == null || image == null) begin
      `uvm_error("CQE_HOST_CALL", "Host-memory call evidence is incomplete")
      return;
    end
    if (mem.calls.size() < start + 2 || mem.calls[start] == null ||
        mem.calls[start + 1] == null) begin
      `uvm_error("CQE_HOST_CALL", "publish did not record write/readback")
      return;
    end
    if (mem.calls[start].method_name != "write" ||
        mem.calls[start + 1].method_name != "read" ||
        mem.calls[start].mapping == null || mem.calls[start + 1].mapping == null ||
        !mem.calls[start].mapping.permissions.device_write ||
        !mem.calls[start + 1].mapping.permissions.device_write ||
        mem.calls[start].mapping.permissions.device_read ||
        mem.calls[start + 1].mapping.permissions.device_read ||
        mem.calls[start].offset != offset ||
        mem.calls[start + 1].offset != offset ||
        mem.calls[start].size != image.bytes.size() ||
        mem.calls[start + 1].size != image.bytes.size() ||
        mem.calls[start].direction != RDMA_DMA_DEVICE_READ ||
        mem.calls[start + 1].direction != RDMA_DMA_DEVICE_READ)
      `uvm_error("CQE_HOST_CALL", "device publish Host-memory direction/order is wrong")
  endtask

  // 功能：check_device_publish_fault_recovery 对首次 backend write、首次 read 与
  //   readback mismatch 三类已开始设备写入故障执行完整原子快照、pending 查询和 retry。
  // 输入/输出及副作用：label、fault_kind 为输入；任务建立独立 lifecycle fixture，
  //   在注入前读取 backing/runtime 基线，故障后比较公开 detached evidence，恢复成功后
  //   poll CQE 释放该测试提前 post 的 SQ WQE。
  // 失败边界：write-fail 必须只有一次 write 且 backing 不变；read-fail/mismatch 必须
  //   恰有一次 write/read 且 backing 等于 pending image。三者都不得推进 committed
  //   PI/CI/occupancy 或发布 result，并须保留完整 pending/reservation 后才能 retry。
  task automatic check_device_publish_fault_recovery(
    string label,
    int unsigned fault_kind
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation pending_after;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    rdma_status injected;
    byte backing_before[];
    byte backing_after[];
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    bit backing_matches_image;
    bit expected_next_wrap;
    int unsigned occupancy;
    int unsigned pi_before;
    int unsigned pi_after;
    int unsigned ci_before;
    int unsigned ci_after;
    int unsigned used_before;
    int unsigned calls_before;
    int unsigned writes_before;
    int unsigned reads_before;
    int unsigned expected_next_index;
    int unsigned expected_write_delta;
    int unsigned expected_read_delta;
    bit pi_wrap_before;
    bit pi_wrap_after;
    bit ci_wrap_before;
    bit ci_wrap_after;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      {label, "_fixture"});
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_SETUP"}, "device publish fault fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd500_0000 + fault_kind),
                             posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error({label, "_POST"}, "device publish fault setup post failed")
      return;
    end
    polarity = 1'b0;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_POLARITY"}, "device publish fault polarity query failed")
      return;
    end
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error({label, "_MODEL"}, "device publish fault CQE build failed")
      return;
    end
    capture_publish_queue_state(fixture, fixture.cq, RDMA_QUEUE_RUNTIME_CQ,
      RDMA_QUEUE_ROLE_CQ_RING, fixture.cq.cqe_size_bytes, backing_before,
      pi_before, pi_wrap_before, ci_before, ci_wrap_before, used_before,
      status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_SNAPSHOT"},
                 "device publish fault baseline snapshot failed")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending != null) begin
      `uvm_error({label, "_PENDING_BEFORE"},
                 "device publish fault baseline already has pending evidence")
      return;
    end
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation);
    if (status == null || !status.ok() || reservation_valid ||
        reservation != null) begin
      `uvm_error({label, "_RESERVATION_BEFORE"},
                 "device publish fault baseline already has a reservation")
      return;
    end
    calls_before = fixture.mem.calls.size();
    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    case (fault_kind)
      0: begin
        injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "injected device write failure");
        status = fixture.mem.fail_next("write", injected);
      end
      1: begin
        injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                     "injected device read failure");
        status = fixture.mem.fail_next("read", injected);
      end
      2: begin
        fixture.mem.corrupt_next_readback = 1'b1;
        status = rdma_status::success();
      end
      default: status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                           "unknown device publish fault");
    endcase
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_INJECT"}, "device publish fault injection failed")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error({label, "_PUBLISH"},
                 "started device publish fault did not retain recovery")
      return;
    end
    expected_write_delta = 1;
    expected_read_delta = fault_kind == 0 ? 0 : 1;
    if (fixture.mem.calls.size() != calls_before + expected_write_delta +
                                      expected_read_delta ||
        count_host_mem_calls(fixture.mem, "write") !=
          writes_before + expected_write_delta ||
        count_host_mem_calls(fixture.mem, "read") !=
          reads_before + expected_read_delta)
      `uvm_error({label, "_CALL_DELTA"},
                 $sformatf("initial failure I/O delta is not write=%0d read=%0d",
                           expected_write_delta, expected_read_delta))
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        !pending.device_producer || !pending.device_write_attempted ||
        pending.cursor == null || pending.next_cursor == null ||
        pending.image == null || pending.failure_status == null ||
        pending.image.length != fixture.cq.cqe_size_bytes ||
        pending.image.bytes.size() != fixture.cq.cqe_size_bytes ||
        pending.image.alignment != fixture.cq.cqe_size_bytes ||
        pending.image.endian != RDMA_ENDIAN_BIG ||
        pending.image.image_kind != RDMA_IMAGE_CQE ||
        !same_test_handle_value(pending.queue_h, fixture.cq.handle) ||
        pending.routed_qp_h != null ||
        pending.kind != RDMA_QUEUE_RUNTIME_CQ || pending.producer ||
        pending.consumer_committed || pending.cq_consumer_committed ||
        pending.completion_released ||
        pending.consumer_doorbell_succeeded ||
        pending.committed_consumer_cursor != null ||
        pending.request_snapshot != null || pending.wr_id != 0 ||
        pending.signaled || pending.completion_index != 0 ||
        pending.completion_wrap || pending.completion_target_valid ||
        pending.cursor.index != pi_before ||
        pending.cursor.wrap != pi_wrap_before ||
        pending.entry_offset != longint'(pi_before) *
                                longint'(fixture.cq.cqe_size_bytes) ||
        pending.entry_size != fixture.cq.cqe_size_bytes ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NOT_APPLICABLE ||
        pending.mmio_maybe_submitted || !pending.known_no_mmio ||
        !pending.route_valid || !pending.epoch_valid) begin
      `uvm_error({label, "_PENDING"},
                 "started device publish fault lost replay evidence")
      return;
    end
    expected_next_index = pi_before + 1;
    expected_next_wrap = pi_wrap_before;
    if (expected_next_index >= fixture.cq.depth) begin
      expected_next_index = 0;
      expected_next_wrap = ~expected_next_wrap;
    end
    if (pending.next_cursor.index != expected_next_index ||
        pending.next_cursor.wrap != expected_next_wrap)
      `uvm_error({label, "_NEXT_CURSOR"},
                 "initial failure pending next cursor is incorrect")
    if ((fault_kind inside {0, 1}) &&
        !same_test_status_value(injected, pending.failure_status))
      `uvm_error({label, "_FAILURE_STATUS"},
                 "initial backend failure status was not preserved")
    if (fault_kind == 2 &&
        pending.failure_status.code != RDMA_SC_DMA_TRANSLATION)
      `uvm_error({label, "_MISMATCH_STATUS"},
                 "readback mismatch failure status is not DMA_TRANSLATION")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    if (status == null || !status.ok() || pi_after != pi_before ||
        pi_wrap_after != pi_wrap_before || ci_after != ci_before ||
        ci_wrap_after != ci_wrap_before)
      `uvm_error({label, "_CURSOR_AFTER"},
                 "initial failure changed committed PI/CI")
    occupancy = 0;
    occupancy_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != used_before ||
        !occupancy_pending)
      `uvm_error({label, "_OCCUPANCY"},
                 "failed device publish changed occupancy or hid pending")
    reservation_valid = 1'b0;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || !reservation_valid ||
        !same_test_cursor_value(reservation, pending.cursor)) begin
      `uvm_error({label, "_RESERVATION"},
                 "failed device publish lost the reserved slot")
      return;
    end
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pi_before, fixture.cq.cqe_size_bytes,
      backing_after);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_BACKING_AFTER"},
                 "initial failure backing snapshot failed")
      return;
    end
    backing_matches_image = backing_after.size() == pending.image.bytes.size();
    if (backing_matches_image) begin
      foreach (backing_after[i]) begin
        if (backing_after[i] !== pending.image.bytes[i])
          backing_matches_image = 1'b0;
      end
    end
    if ((fault_kind == 0 && backing_after != backing_before) ||
        (fault_kind != 0 && !backing_matches_image))
      `uvm_error({label, "_BACKING_CONTRACT"},
                 fault_kind == 0 ?
                   "first write failure changed backing bytes" :
                   "post-write read failure backing differs from pending image")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || !status.ok() ||
        !same_device_pending_value(pending, pending_after))
      `uvm_error({label, "_DETACHED_PENDING"},
                 "public detached pending snapshot changed after observation")
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_RETRY"}, "device publish recovery retry failed")
      return;
    end
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 1 || occupancy_pending)
      `uvm_error({label, "_RETRY_OCCUPANCY"},
                 "device publish retry did not commit exactly one CQE")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error({label, "_RETRY_RESERVATION"},
                 "device publish retry retained a committed reservation")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error({label, "_POLL"}, "recovered device CQE did not release WQE")
  endtask

  // 功能：check_device_publish_retry_chain 从 CQ readback mismatch 建立 pending，
  //   依次验证未确认 retry、确认后 read 故障、再次确认成功与成功后的重复 retry。
  // 输入/输出及副作用：无显式输入；任务建立独立 lifecycle-owned CQ/QP，注入一次
  //   mismatch 和一次 recovery read 故障，并最终 poll 唯一提交的 CQE 释放 SQ WQE。
  // 失败边界：每个失败阶段的完整 pending/backing/PI/CI/wrap/occupancy/reservation/
  //   result 必须保持不变；I/O delta 必须分别为 0、write+read 各 1、各 1，末次 retry
  //   必须返回 INVALID_STATE 且不得再次访问 Host-memory。
  task automatic check_device_publish_retry_chain();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending_before;
    rdma_queue_pending_operation pending_after;
    rdma_queue_cursor_snapshot reservation_before;
    rdma_queue_cursor_snapshot reservation_after;
    rdma_status status;
    rdma_status model_status;
    rdma_status injected;
    byte backing_before[];
    byte backing_after[];
    int unsigned pi_before;
    int unsigned pi_after;
    int unsigned ci_before;
    int unsigned ci_after;
    int unsigned used_before;
    int unsigned used_after;
    int unsigned calls_before;
    int unsigned writes_before;
    int unsigned reads_before;
    bit pi_wrap_before;
    bit pi_wrap_after;
    bit ci_wrap_before;
    bit ci_wrap_after;
    bit pending_present;
    bit reservation_valid;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_retry_chain_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_RETRY_CHAIN_SETUP", "retry-chain fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd540_0000), posted, status);
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || posted == null ||
        model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_RETRY_CHAIN_MODEL", "retry-chain CQE setup failed")
      return;
    end

    fixture.mem.corrupt_next_readback = 1'b1;
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    fixture.mem.corrupt_next_readback = 1'b0;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error("CQE_RETRY_CHAIN_MISMATCH",
                 "readback mismatch did not retain a null-result recovery")
      return;
    end
    pending_before = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_before);
    if (status == null || !status.ok() || pending_before == null ||
        pending_before.image == null || pending_before.cursor == null ||
        pending_before.next_cursor == null ||
        !pending_before.device_producer ||
        !pending_before.device_write_attempted) begin
      `uvm_error("CQE_RETRY_CHAIN_PENDING", "retry-chain pending is incomplete")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_before, pi_wrap_before,
      ci_before, ci_wrap_before);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_RETRY_CHAIN_CURSOR", "retry-chain cursor snapshot failed")
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_before, pending_present);
    if (status == null || !status.ok() || !pending_present) begin
      `uvm_error("CQE_RETRY_CHAIN_USED", "retry-chain occupancy snapshot failed")
      return;
    end
    reservation_before = null;
    reservation_valid = 1'b0;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation_before);
    if (status == null || !status.ok() || !reservation_valid ||
        !same_test_cursor_value(reservation_before, pending_before.cursor)) begin
      `uvm_error("CQE_RETRY_CHAIN_RESERVATION",
                 "retry-chain reservation snapshot failed")
      return;
    end
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_before);
    if (status == null || !status.ok() ||
        backing_before.size() != pending_before.image.bytes.size()) begin
      `uvm_error("CQE_RETRY_CHAIN_BACKING",
                 "mismatch recovery backing does not contain the pending image")
      return;
    end
    foreach (backing_before[i]) begin
      if (backing_before[i] !== pending_before.image.bytes[i]) begin
        `uvm_error("CQE_RETRY_CHAIN_BACKING",
                   $sformatf("mismatch backing byte %0d differs", i))
        return;
      end
    end

    calls_before = fixture.mem.calls.size();
    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        published != null || fixture.mem.calls.size() != calls_before ||
        count_host_mem_calls(fixture.mem, "write") != writes_before ||
        count_host_mem_calls(fixture.mem, "read") != reads_before)
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED",
                 "unconfirmed retry changed result or issued backend I/O")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || !status.ok() ||
        !same_device_pending_value(pending_before, pending_after))
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED_PENDING",
                 "unconfirmed retry changed pending evidence")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    if (status == null || !status.ok() || pi_after != pi_before ||
        pi_wrap_after != pi_wrap_before || ci_after != ci_before ||
        ci_wrap_after != ci_wrap_before)
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED_CURSOR",
                 "unconfirmed retry changed PI/CI")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_after, pending_present);
    if (status == null || !status.ok() || used_after != used_before ||
        !pending_present)
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED_USED",
                 "unconfirmed retry changed occupancy")
    reservation_after = null;
    reservation_valid = 1'b0;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation_after);
    if (status == null || !status.ok() || !reservation_valid ||
        !same_test_cursor_value(reservation_before, reservation_after))
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED_RESERVATION",
                 "unconfirmed retry changed reservation")
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_after);
    if (status == null || !status.ok() || backing_after != backing_before)
      `uvm_error("CQE_RETRY_CHAIN_UNCONFIRMED_BACKING",
                 "unconfirmed retry changed backing bytes")

    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "injected retry-chain read failure");
    status = fixture.mem.fail_next("read", injected);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_RETRY_CHAIN_INJECT", "retry read fault injection failed")
      return;
    end
    calls_before = fixture.mem.calls.size();
    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_DMA_TRANSLATION ||
        published != null || fixture.mem.calls.size() != calls_before + 2 ||
        count_host_mem_calls(fixture.mem, "write") != writes_before + 1 ||
        count_host_mem_calls(fixture.mem, "read") != reads_before + 1)
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL",
                 "confirmed retry did not stop after one write/read pair")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || !status.ok() ||
        !same_device_pending_value(pending_before, pending_after))
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL_PENDING",
                 "retry read failure changed pending evidence")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    if (status == null || !status.ok() || pi_after != pi_before ||
        pi_wrap_after != pi_wrap_before || ci_after != ci_before ||
        ci_wrap_after != ci_wrap_before)
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL_CURSOR",
                 "retry read failure changed PI/CI")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_after, pending_present);
    if (status == null || !status.ok() || used_after != used_before ||
        !pending_present)
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL_USED",
                 "retry read failure changed occupancy")
    reservation_after = null;
    reservation_valid = 1'b0;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation_after);
    if (status == null || !status.ok() || !reservation_valid ||
        !same_test_cursor_value(reservation_before, reservation_after))
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL_RESERVATION",
                 "retry read failure changed reservation")
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_after);
    if (status == null || !status.ok() || backing_after != backing_before)
      `uvm_error("CQE_RETRY_CHAIN_READ_FAIL_BACKING",
                 "retry read failure changed backing image")

    calls_before = fixture.mem.calls.size();
    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok() || published != null ||
        fixture.mem.calls.size() != calls_before + 2 ||
        count_host_mem_calls(fixture.mem, "write") != writes_before + 1 ||
        count_host_mem_calls(fixture.mem, "read") != reads_before + 1)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS",
                 "confirmed retry did not commit after one write/read pair")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    if (status == null || !status.ok() ||
        pi_after != pending_before.next_cursor.index ||
        pi_wrap_after != pending_before.next_cursor.wrap ||
        ci_after != ci_before || ci_wrap_after != ci_wrap_before)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS_CURSOR",
                 "successful retry did not advance PI exactly once")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_after, pending_present);
    if (status == null || !status.ok() || used_after != used_before + 1 ||
        pending_present)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS_USED",
                 "successful retry did not publish exactly one CQE")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending_after != null)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS_PENDING",
                 "successful retry retained pending evidence")
    reservation_after = null;
    reservation_valid = 1'b1;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation_after);
    if (status == null || !status.ok() || reservation_valid ||
        reservation_after != null)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS_RESERVATION",
                 "successful retry retained reservation")
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_after);
    if (status == null || !status.ok() || backing_after != backing_before)
      `uvm_error("CQE_RETRY_CHAIN_SUCCESS_BACKING",
                 "successful retry changed the committed CQE image")

    calls_before = fixture.mem.calls.size();
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        published != null || fixture.mem.calls.size() != calls_before)
      `uvm_error("CQE_RETRY_CHAIN_REPEAT",
                 "retry after successful commit was not an I/O-free INVALID_STATE")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error("CQE_RETRY_CHAIN_POLL",
                 "retry-chain CQE did not release exactly one WQE")
  endtask

  // 功能：check_unclaimed_pending_kind_authority 让 runtime admission 一次失败，
  //   验证同一 CQ identity 的错误 runtime kind 不能读取 engine-owned evidence。
  // 输入/输出及副作用：无显式输入；任务只经公开 publish/query API 建立并读取
  //   unclaimed recovery，不直接取得 attachment、runtime 或 backing 可变引用。
  // 失败边界：setup/post/故障注入失败时报告 UVM_ERROR；错误 kind 若返回成功或
  //   非空 pending 即为 authority 泄漏，正确 CQ kind 必须仍能查询同一 evidence。
  task automatic check_unclaimed_pending_kind_authority();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation correct_pending;
    rdma_queue_pending_operation wrong_pending;
    rdma_status status;
    rdma_status model_status;
    rdma_status injected;
    bit polarity;
    bit occupancy_pending;
    bit reservation_valid;
    int unsigned occupancy;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    rdma_queue_cursor_snapshot reservation;

    rdma_queue_data_engine::type_id::set_type_override(
      rdma_device_publish_recovery_fault_engine::get_type());
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 1;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 0;
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "unclaimed_kind_authority_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_KIND_SETUP", "unclaimed kind fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd530_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_UNCLAIMED_KIND_POST", "unclaimed kind setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_UNCLAIMED_KIND_MODEL", "unclaimed kind CQE setup failed")
      return;
    end
    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "injected unclaimed device write failure");
    status = fixture.mem.fail_next("write", injected);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_KIND_INJECT", "unclaimed write injection failed")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error("CQE_UNCLAIMED_KIND_PUBLISH",
                 "admission failure did not retain unclaimed recovery")
      return;
    end
    wrong_pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CEQ, wrong_pending);
    if (status == null || status.ok() || wrong_pending != null)
      `uvm_error("CQE_UNCLAIMED_KIND_LEAK",
                 "wrong runtime kind read CQ unclaimed evidence")
    correct_pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, correct_pending);
    if (status == null || !status.ok() || correct_pending == null ||
        !correct_pending.device_producer || correct_pending.cursor == null)
      `uvm_error("CQE_UNCLAIMED_KIND_CORRECT",
                 "correct runtime kind lost retained unclaimed evidence")
    occupancy = 1;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_UNCLAIMED_INVISIBLE_OCCUPANCY",
                 "unclaimed CQE changed committed occupancy before recovery")
    reservation_valid = 1'b0;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || !reservation_valid || reservation == null ||
        reservation.index != correct_pending.cursor.index ||
        reservation.wrap != correct_pending.cursor.wrap)
      `uvm_error("CQE_UNCLAIMED_RESERVATION",
                 "unclaimed recovery lost the reserved CQ slot")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_QUEUE_EMPTY || completion != null)
      `uvm_error("CQE_UNCLAIMED_INVISIBLE_POLL",
                 "unclaimed CQE was visible to poll before recovery")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 0 || producer_wrap ||
        consumer_index != 0 || consumer_wrap)
      `uvm_error("CQE_UNCLAIMED_CURSOR", "unclaimed CQE advanced a cursor")
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_RETRY", "unclaimed CQE retry did not succeed")
      return;
    end
    correct_pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, correct_pending);
    if (status == null || status.ok() || correct_pending != null ||
        status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_UNCLAIMED_RETRY_CLEANUP",
                 "retry did not delete paired unclaimed evidence")
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 1 || occupancy_pending)
      `uvm_error("CQE_UNCLAIMED_RETRY_OCCUPANCY",
                 "unclaimed retry did not commit exactly one CQE")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error("CQE_UNCLAIMED_RETRY_RESERVATION",
                 "unclaimed retry retained a committed reservation")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error("CQE_UNCLAIMED_RETRY_POLL",
                 "unclaimed retry CQE did not become consumable")
  endtask

  // 功能：check_unclaimed_pending_abort 让 admission 连续拒绝 publish 与 abort 的
  //   runtime 接管，验证 abort fallback 取消 reservation、detach 并成对删除 evidence。
  // 输入/输出及副作用：无显式输入；任务仅通过公开 publish/query/recover/poll API
  //   观察 unclaimed 生命周期，不修改 queue plan、attachment 或 Host-memory backing。
  // 失败边界：初始 unclaimed 不可查询、abort 非成功、仍可查询 pending/occupancy，
  //   或 abort 前 poll 非 QUEUE_EMPTY 时报告 UVM_ERROR；失败 detach 前后完整 image、
  //   cursor/stage/MMIO、PI/CI/wrap、occupancy、reservation、backing 与 I/O 数必须相同。
  task automatic check_unclaimed_pending_abort();
    rdma_queue_data_engine_fixture fixture;
    rdma_device_publish_recovery_fault_engine fault_engine;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation pending_before;
    rdma_queue_pending_operation pending_after;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_cursor_snapshot reservation_before;
    rdma_queue_cursor_snapshot reservation_after;
    rdma_status status;
    rdma_status model_status;
    rdma_status injected;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned calls_before_abort;
    int unsigned calls_before_final_abort;
    int unsigned writes_before_abort;
    int unsigned reads_before_abort;
    int unsigned pi_before_abort;
    int unsigned pi_after_abort;
    int unsigned ci_before_abort;
    int unsigned ci_after_abort;
    int unsigned occupancy_before_abort;
    int unsigned occupancy_after_abort;
    bit pi_wrap_before_abort;
    bit pi_wrap_after_abort;
    bit ci_wrap_before_abort;
    bit ci_wrap_after_abort;
    bit pending_before_abort;
    byte backing_before_abort[];
    byte backing_after_abort[];

    rdma_queue_data_engine::type_id::set_type_override(
      rdma_device_publish_recovery_fault_engine::get_type());
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 2;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 0;
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "unclaimed_abort_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() ||
        !$cast(fault_engine, fixture.engine)) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_SETUP", "unclaimed abort fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd531_0000), posted, status);
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || posted == null ||
        model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_MODEL", "unclaimed abort setup failed")
      return;
    end
    injected = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "injected unclaimed abort write failure");
    status = fixture.mem.fail_next("write", injected);
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_PUBLISH", "unclaimed abort was not retained")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_PENDING", "abort input evidence is absent")
      return;
    end
    pending_before = pending;
    reservation_valid = 1'b0;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || !reservation_valid || reservation == null)
      `uvm_error("CQE_UNCLAIMED_ABORT_RESERVATION", "abort input reservation is absent")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_QUEUE_EMPTY || completion != null)
      `uvm_error("CQE_UNCLAIMED_ABORT_INVISIBLE", "unclaimed abort CQE was visible")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_before_abort,
      pi_wrap_before_abort, ci_before_abort, ci_wrap_before_abort);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_CURSOR_BEFORE",
                 "unclaimed abort cursor snapshot failed")
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy_before_abort,
      pending_before_abort);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_USED_BEFORE",
                 "unclaimed abort occupancy snapshot failed")
      return;
    end
    reservation_before = reservation;
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_before_abort);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_BACKING_BEFORE",
                 "unclaimed abort backing snapshot failed")
      return;
    end
    calls_before_abort = fixture.mem.calls.size();
    writes_before_abort = count_host_mem_calls(fixture.mem, "write");
    reads_before_abort = count_host_mem_calls(fixture.mem, "read");
    status = fault_engine.hold_detach_lock_for_test();
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_ABORT_ARM", "unclaimed detach lock failed")
      return;
    end
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
    fault_engine.release_detach_lock_for_test();
    if (status == null || status.ok())
      `uvm_error("CQE_UNCLAIMED_ABORT_BUSY",
                 "unclaimed abort ignored detach lock failure")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || !status.ok() ||
        !same_device_pending_value(pending_before, pending_after) ||
        published != null || fixture.mem.calls.size() != calls_before_abort ||
        count_host_mem_calls(fixture.mem, "write") != writes_before_abort ||
        count_host_mem_calls(fixture.mem, "read") != reads_before_abort)
      `uvm_error("CQE_UNCLAIMED_ABORT_RETAIN",
                 "failed unclaimed detach lost evidence or touched mapping")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after_abort,
      pi_wrap_after_abort, ci_after_abort, ci_wrap_after_abort);
    if (status == null || !status.ok() ||
        pi_after_abort != pi_before_abort ||
        pi_wrap_after_abort != pi_wrap_before_abort ||
        ci_after_abort != ci_before_abort ||
        ci_wrap_after_abort != ci_wrap_before_abort)
      `uvm_error("CQE_UNCLAIMED_ABORT_CURSOR_AFTER",
                 "failed unclaimed detach changed PI/CI")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy_after_abort,
      occupancy_pending);
    if (status == null || !status.ok() ||
        occupancy_after_abort != occupancy_before_abort ||
        occupancy_pending != pending_before_abort)
      `uvm_error("CQE_UNCLAIMED_ABORT_USED_AFTER",
                 "failed unclaimed detach changed occupancy")
    reservation_valid = 1'b0;
    reservation_after = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation_after);
    if (status == null || !status.ok() || !reservation_valid ||
        !same_test_cursor_value(reservation_before, reservation_after))
      `uvm_error("CQE_UNCLAIMED_ABORT_RETAIN_RESERVATION",
                 "failed unclaimed detach cancelled reservation")
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pending_before.cursor.index,
      fixture.cq.cqe_size_bytes, backing_after_abort);
    if (status == null || !status.ok() ||
        backing_after_abort != backing_before_abort)
      `uvm_error("CQE_UNCLAIMED_ABORT_BACKING_AFTER",
                 "failed unclaimed detach changed backing bytes")
    calls_before_final_abort = fixture.mem.calls.size();
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_UNCLAIMED_ABORT", "unclaimed abort did not detach")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null)
      `uvm_error("CQE_UNCLAIMED_ABORT_PENDING_CLEANUP",
                 "abort did not delete paired unclaimed evidence")
    occupancy = 1;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_UNCLAIMED_ABORT_OCCUPANCY",
                 "abort left an observable queue runtime")
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        published != null)
      `uvm_error("CQE_UNCLAIMED_ABORT_PUBLISH_STALE",
                 "unclaimed abort left publish attachment active")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null ||
        fixture.mem.calls.size() != calls_before_final_abort)
      `uvm_error("CQE_UNCLAIMED_ABORT_POLL_STALE",
                 "unclaimed abort left poll active or released mapping")
  endtask

  // 功能：check_claimed_abort_detach_failure_atomicity 在 CQ runtime 已接管 device
  //   pending 后占用真实 detach 锁，验证失败 abort 不会提前清除 pending/reservation，
  //   释放锁后同一 abort 可幂等完成并使旧 handle 的 publish/poll 都失效。
  // 输入/输出及副作用：无显式输入；任务建立 lifecycle-owned CQ/QP、发布真实 posted
  //   WQE 对应 CQE，并以 readback mismatch 进入 recovery；只借测试子类占用现有锁。
  // 失败边界：setup/query/注入失败立即报告并返回；RESOURCE_BUSY 前后 image/cursor/
  //   next_cursor、PI/CI/wrap、used、reservation 和 Host-memory 调用数必须不变，最终
  //   abort 不得触发 release/release_opaque，旧 attachment API 必须返回 INVALID_STATE。
  task automatic check_claimed_abort_detach_failure_atomicity();
    rdma_queue_data_engine_fixture fixture;
    rdma_device_publish_recovery_fault_engine fault_engine;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending_before;
    rdma_queue_pending_operation pending_after;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    int unsigned used_before;
    int unsigned used_after;
    int unsigned pi_before;
    int unsigned pi_after;
    int unsigned ci_before;
    int unsigned ci_after;
    int unsigned calls_before_abort;
    bit pending_present;
    bit reservation_valid;
    bit pw_before;
    bit pw_after;
    bit cw_before;
    bit cw_after;
    bit polarity;

    rdma_queue_data_engine::type_id::set_type_override(
      rdma_device_publish_recovery_fault_engine::get_type());
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 0;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 0;
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "claimed_abort_detach_failure_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() ||
        !$cast(fault_engine, fixture.engine)) begin
      `uvm_error("CQE_ABORT_SPLIT_SETUP",
                 "claimed abort detach-failure fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd533_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_ABORT_SPLIT_POST", "claimed abort setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_ABORT_SPLIT_MODEL", "claimed abort CQE setup failed")
      return;
    end
    fixture.mem.corrupt_next_readback = 1'b1;
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    fixture.mem.corrupt_next_readback = 1'b0;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error("CQE_ABORT_SPLIT_PUBLISH",
                 "readback mismatch did not establish claimed recovery")
      return;
    end
    pending_before = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_before);
    if (status == null || !status.ok() || pending_before == null ||
        pending_before.image == null || pending_before.cursor == null ||
        pending_before.next_cursor == null ||
        !pending_before.device_producer ||
        !pending_before.device_write_attempted) begin
      `uvm_error("CQE_ABORT_SPLIT_PENDING", "claimed pending is incomplete")
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_before,
      pending_present);
    if (status == null || !status.ok() || !pending_present) begin
      `uvm_error("CQE_ABORT_SPLIT_USED", "claimed occupancy query failed")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_before, pw_before,
      ci_before, cw_before);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_ABORT_SPLIT_CURSOR", "claimed cursor query failed")
      return;
    end
    reservation = null;
    reservation_valid = 1'b0;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation);
    if (status == null || !status.ok() || !reservation_valid ||
        reservation == null ||
        reservation.index != pending_before.cursor.index ||
        reservation.wrap != pending_before.cursor.wrap) begin
      `uvm_error("CQE_ABORT_SPLIT_RESERVATION",
                 "claimed reservation query failed")
      return;
    end
    calls_before_abort = fixture.mem.calls.size();
    status = fault_engine.hold_detach_lock_for_test();
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_ABORT_SPLIT_ARM", "detach lock injection failed")
      return;
    end
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
    fault_engine.release_detach_lock_for_test();
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY)
      `uvm_error("CQE_ABORT_SPLIT_STATUS",
                 "busy detach did not return RESOURCE_BUSY")
    pending_after = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending_after);
    if (status == null || !status.ok() || pending_after == null ||
        pending_after.image == null || pending_after.cursor == null ||
        pending_after.next_cursor == null ||
        pending_after.image.bytes != pending_before.image.bytes ||
        pending_after.cursor.index != pending_before.cursor.index ||
        pending_after.cursor.wrap != pending_before.cursor.wrap ||
        pending_after.next_cursor.index != pending_before.next_cursor.index ||
        pending_after.next_cursor.wrap != pending_before.next_cursor.wrap ||
        pending_after.device_write_attempted !=
          pending_before.device_write_attempted ||
        pending_after.mmio_evidence != pending_before.mmio_evidence)
      `uvm_error("CQE_ABORT_SPLIT_EVIDENCE",
                 "failed detach lost or changed claimed evidence")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_after,
      pending_present);
    if (status == null || !status.ok() || !pending_present ||
        used_after != used_before)
      `uvm_error("CQE_ABORT_SPLIT_USED_AFTER",
                 "failed detach changed claimed occupancy")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pw_after,
      ci_after, cw_after);
    if (status == null || !status.ok() || pi_after != pi_before ||
        pw_after != pw_before || ci_after != ci_before ||
        cw_after != cw_before)
      `uvm_error("CQE_ABORT_SPLIT_CURSOR_AFTER",
                 "failed detach changed claimed cursors")
    reservation = null;
    reservation_valid = 1'b0;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation);
    if (status == null || !status.ok() || !reservation_valid ||
        reservation == null || reservation.index != pending_before.cursor.index ||
        reservation.wrap != pending_before.cursor.wrap ||
        fixture.mem.calls.size() != calls_before_abort)
      `uvm_error("CQE_ABORT_SPLIT_ATOMIC",
                 "failed detach changed reservation or Host-memory calls")
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_ABORT_SPLIT_RETRY", "second abort did not detach")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        published != null)
      `uvm_error("CQE_ABORT_SPLIT_PUBLISH_STALE",
                 "aborted attachment still accepted publish")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null || fixture.mem.calls.size() != calls_before_abort)
      `uvm_error("CQE_ABORT_SPLIT_POLL_STALE",
                 "aborted attachment remained visible or released mapping")
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 0;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 0;
  endtask

  // 功能：check_segmented_cq_plan_ownership 用两个真实 source lifecycle CQ 的
  //   4KiB mapping 组成 8KiB borrowed target CQ，只验证公开 plan shape 与 release owner。
  // 输入/输出及副作用：无显式输入；经 lifecycle create/destroy 建立并清理三个 CQ，
  //   不 attach target、不调用 device publish，也不修改 mapping 私有 token 或 registry。
  // 失败边界：create/shape/ownership 任一不符均报告 UVM_ERROR；清理仍按 target、
  //   source CQ2、source CQ1 继续，并证明 target 不释放而 source 各释放自己的 mapping。
  task automatic check_segmented_cq_plan_ownership();
    rdma_queue_data_engine_fixture fixture;
    rdma_cq source_cq_first;
    rdma_cq source_cq_second;
    rdma_cq segmented_cq;
    rdma_queue_backing_ref backing;
    rdma_dma_mapping first_mapping;
    rdma_dma_mapping second_mapping;
    rdma_status status;

    setup_segmented_cq_topology(
      "segmented_plan", fixture, source_cq_first, source_cq_second,
      segmented_cq, backing, first_mapping, second_mapping, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_SEGMENT_PLAN_SETUP",
                 status == null ? "segmented plan setup returned null" :
                   $sformatf("segmented plan setup failed code=%0d message=%s",
                             status.code, status.message))
    end
    else if (backing == null || first_mapping == null ||
             second_mapping == null ||
             backing.ownership != RDMA_OWNERSHIP_BORROWED ||
             backing.mapping_offset != 0 || backing.length != 4096 ||
             backing.logical_queue_offset != 0 ||
             backing.additional_segments.size() != 1 ||
             backing.additional_segments[0] == null ||
             backing.additional_segments[0].ownership !=
               RDMA_OWNERSHIP_BORROWED ||
             backing.additional_segments[0].mapping_offset != 0 ||
             backing.additional_segments[0].length != 4096 ||
             backing.additional_segments[0].logical_queue_offset != 4096 ||
             first_mapping.iova.value == second_mapping.iova.value) begin
      `uvm_error("CQE_SEGMENT_PLAN_SHAPE",
                 "segmented lifecycle plan lost borrowed 4KiB slices")
    end
    cleanup_segmented_cq_topology(
      "CQE_SEGMENT_PLAN", fixture, source_cq_first, source_cq_second,
      segmented_cq, first_mapping, second_mapping);
  endtask

  // 功能：check_device_publish_preflight_failure 在 attachment access 的首次
  //   write_device 预检处注入 DEVICE_WRITE 拒绝，验证 reservation 被 cancel 且
  //   backend write/commit 均不可观察。
  // 输入/输出及副作用：无显式输入；任务在 setup 前注册 factory override、在 setup
  //   后 arm 一次性 access 故障，随后只读取 publish、Host-memory 和 runtime 观测值。
  // 失败边界：factory 注入、publish 拒绝、调用数/游标/occupancy/pending/reservation
  //   检查任一不符时报告 UVM_ERROR；该 access 只模拟未开始 backend 的预检失败，
  //   不能替代 mapping 权限或 lifecycle allocation 的独立覆盖。
  task automatic check_device_publish_preflight_failure();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned calls_before;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_preflight_fixture");
    rdma_queue_backing_access::type_id::set_type_override(
      rdma_cq_device_write_preflight_fault_access::get_type());
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b0;
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PREFLIGHT_SETUP", status == null ?
                 "preflight fixture setup returned null status" :
                 status.convert2string())
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd510_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_PREFLIGHT_POST", "preflight setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_PREFLIGHT_MODEL", "preflight CQE setup is incomplete")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PREFLIGHT_CURSOR", "preflight cursor query failed")
      return;
    end
    calls_before = fixture.mem.calls.size();
    published = null;
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write =
      1'b0;
    if (status == null || status.code != RDMA_SC_DMA_PERMISSION ||
        published != null || fixture.mem.calls.size() != calls_before)
      `uvm_error("CQE_PREFLIGHT_PUBLISH",
                 "preflight failure entered backend or published a CQE")
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_PREFLIGHT_OCCUPANCY", "preflight failure changed occupancy")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, polarity,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || occupancy != producer_index ||
        polarity != producer_wrap)
      `uvm_error("CQE_PREFLIGHT_CURSOR_AFTER", "preflight failure advanced PI")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null ||
        status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_PREFLIGHT_PENDING", "preflight failure retained pending")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error("CQE_PREFLIGHT_RESERVATION", "preflight failure retained reservation")
  endtask

  // 功能：check_lifecycle_owned_cq_permission_failure 经公开 CQ replacement API
  //   发布一个缺少 DEVICE_WRITE 的 control-plane owned 单 mapping，并验证真实 engine
  //   attachment 的生产 preflight 拒绝 CQE，而非借用 multi-segment 或测试 access seam。
  // 输入/输出及副作用：无显式输入；任务 detach CQ、begin resize、修改 detached
  //   candidate 的 ring ref/page mapping permission mirror、replace 并重新 attach，随后
  //   post 匹配 WQE 并调用公开 publish_cqe；mapping 的销毁权仍归 lifecycle executor。
  // 失败边界：候选不是唯一 CONTROL_PLANE CQ_RING、存在 additional segment、公开
  //   lifecycle 步骤失败或 publish 不返回 DMA_PERMISSION 时报告；拒绝前后 backing、
  //   PI/CI/wrap、occupancy、pending、reservation、result 与 backend 调用数必须不变。
  task automatic check_lifecycle_owned_cq_permission_failure();
    rdma_queue_data_engine_fixture fixture;
    rdma_resource candidate_resource;
    rdma_cq candidate_cq;
    rdma_queue_backing_ref ring_ref;
    rdma_queue_ring_layout ring;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    byte backing_before[];
    byte backing_after[];
    int unsigned ring_ref_count;
    int unsigned ring_count;
    int unsigned pi_before;
    int unsigned pi_after;
    int unsigned ci_before;
    int unsigned ci_after;
    int unsigned used_before;
    int unsigned used_after;
    int unsigned calls_before;
    int unsigned writes_before;
    int unsigned reads_before;
    bit pi_wrap_before;
    bit pi_wrap_after;
    bit ci_wrap_before;
    bit ci_wrap_after;
    bit pending_present;
    bit reservation_valid;
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "lifecycle_owned_cq_permission_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_SETUP",
                 "lifecycle-owned permission fixture setup failed")
      return;
    end
    candidate_resource = null;
    candidate_cq = null;
    status = fixture.manager.lookup(fixture.cq.handle, candidate_resource);
    if (status == null || !status.ok() || candidate_resource == null ||
        !$cast(candidate_cq, candidate_resource)) begin
      `uvm_error("CQE_OWNED_PERMISSION_LOOKUP",
                 "active CQ replacement candidate lookup failed")
      return;
    end
    ring_ref = null;
    ring = null;
    ring_ref_count = 0;
    ring_count = 0;
    if (candidate_cq.queue_plan != null) begin
      foreach (candidate_cq.queue_plan.refs[i]) begin
        if (candidate_cq.queue_plan.refs[i] != null &&
            candidate_cq.queue_plan.refs[i].role == RDMA_QUEUE_ROLE_CQ_RING) begin
          ring_ref_count++;
          ring_ref = candidate_cq.queue_plan.refs[i];
        end
      end
      foreach (candidate_cq.queue_plan.rings[i]) begin
        if (candidate_cq.queue_plan.rings[i] != null &&
            candidate_cq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING) begin
          ring_count++;
          ring = candidate_cq.queue_plan.rings[i];
        end
      end
    end
    if (ring_ref_count != 1 || ring_count != 1 || ring_ref == null ||
        ring == null || ring_ref.mapping == null ||
        ring_ref.ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        ring_ref.additional_segments.size() != 0 || ring.pages.size() == 0) begin
      `uvm_error("CQE_OWNED_PERMISSION_SHAPE",
                 "CQ replacement is not a lifecycle-owned single mapping")
      return;
    end
    status = fixture.engine.detach(fixture.cq.handle);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_DETACH",
                 "CQ detach before permission replacement failed")
      return;
    end
    status = fixture.manager.begin_cq_resize(fixture.cq.handle);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_BEGIN",
                 "CQ begin resize before permission replacement failed")
      return;
    end
    ring_ref.mapping.permissions.device_write = 1'b0;
    foreach (ring.pages[i]) begin
      if (ring.pages[i] == null || ring.pages[i].mapping == null) begin
        `uvm_error("CQE_OWNED_PERMISSION_PAGE",
                   "CQ ring page mapping mirror is incomplete")
        return;
      end
      ring.pages[i].mapping.permissions.device_write = 1'b0;
    end
    candidate_cq.queue_iova = ring_ref.mapping.iova;
    status = fixture.manager.replace_active_cq(candidate_cq);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_REPLACE",
                 status == null ? "CQ permission replacement returned null" :
                                  status.convert2string())
      return;
    end
    status = fixture.engine.attach_cq(fixture.cq.handle, RDMA_TRANSPORT_RC);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_ATTACH",
                 "CQ permission replacement attach failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd511_0000), posted, status);
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || posted == null ||
        model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_OWNED_PERMISSION_MODEL",
                 "CQ permission rejection model setup failed")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_before, pi_wrap_before,
      ci_before, ci_wrap_before);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_CURSOR_BEFORE",
                 "CQ permission cursor snapshot failed")
      return;
    end
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_before, pending_present);
    if (status == null || !status.ok() || pending_present) begin
      `uvm_error("CQE_OWNED_PERMISSION_USED_BEFORE",
                 "CQ permission occupancy baseline is not clean")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending != null) begin
      `uvm_error("CQE_OWNED_PERMISSION_PENDING_BEFORE",
                 "CQ permission baseline retained pending evidence")
      return;
    end
    reservation = null;
    reservation_valid = 1'b1;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation);
    if (status == null || !status.ok() || reservation_valid ||
        reservation != null) begin
      `uvm_error("CQE_OWNED_PERMISSION_RESERVATION_BEFORE",
                 "CQ permission baseline retained reservation")
      return;
    end
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pi_before, fixture.cq.cqe_size_bytes,
      backing_before);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_OWNED_PERMISSION_BACKING_BEFORE",
                 "CQ permission backing snapshot failed")
      return;
    end
    calls_before = fixture.mem.calls.size();
    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_DMA_PERMISSION ||
        published != null || fixture.mem.calls.size() != calls_before ||
        count_host_mem_calls(fixture.mem, "write") != writes_before ||
        count_host_mem_calls(fixture.mem, "read") != reads_before)
      `uvm_error("CQE_OWNED_PERMISSION_PUBLISH",
                 "lifecycle-owned permission rejection touched backend/result")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    if (status == null || !status.ok() || pi_after != pi_before ||
        pi_wrap_after != pi_wrap_before || ci_after != ci_before ||
        ci_wrap_after != ci_wrap_before)
      `uvm_error("CQE_OWNED_PERMISSION_CURSOR_AFTER",
                 "CQ permission rejection changed PI/CI")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, used_after, pending_present);
    if (status == null || !status.ok() || used_after != used_before ||
        pending_present)
      `uvm_error("CQE_OWNED_PERMISSION_USED_AFTER",
                 "CQ permission rejection changed occupancy")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending != null)
      `uvm_error("CQE_OWNED_PERMISSION_PENDING_AFTER",
                 "CQ permission rejection retained pending evidence")
    reservation = null;
    reservation_valid = 1'b1;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid,
      reservation);
    if (status == null || !status.ok() || reservation_valid ||
        reservation != null)
      `uvm_error("CQE_OWNED_PERMISSION_RESERVATION_AFTER",
                 "CQ permission rejection retained reservation")
    status = read_queue_backing_slot(fixture, fixture.cq,
      RDMA_QUEUE_ROLE_CQ_RING, pi_before, fixture.cq.cqe_size_bytes,
      backing_after);
    if (status == null || !status.ok() || backing_after != backing_before)
      `uvm_error("CQE_OWNED_PERMISSION_BACKING_AFTER",
                 "CQ permission rejection changed backing bytes")
  endtask

  // 功能：check_device_publish_cancel_failure 注入 access preflight 与 reservation
  // cancel 双重失败，验证 engine 将未写入 CQE 保留为可查询 recovery 后再由 abort 清理。
  // 输入/输出及副作用：无显式输入；任务通过 factory access/engine 的一次性故障驱动
  // 公开 publish/query/poll/recover API，不读取或修改 lifecycle-owned backing。
  // 失败边界：pending、reservation、poll 意外成功或推进 consumer cursor、或 abort
  // cleanup 任一不符报告 UVM_ERROR；空 backing 在初始 owner 位相同时可返回其他
  // 非成功校验状态，故不可把 consumer 不可见性错误限定为 QUEUE_EMPTY。
  task automatic check_device_publish_cancel_failure();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    rdma_queue_data_engine::type_id::set_type_override(
      rdma_device_publish_recovery_fault_engine::get_type());
    rdma_queue_backing_access::type_id::set_type_override(
      rdma_cq_device_write_preflight_fault_access::get_type());
    rdma_device_publish_recovery_fault_engine::admission_failures_remaining = 0;
    rdma_device_publish_recovery_fault_engine::cancel_failures_remaining = 1;
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write = 1'b0;
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_cancel_failure_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_CANCEL_SETUP", "cancel failure fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd532_0000), posted, status);
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || posted == null ||
        model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_CANCEL_MODEL", "cancel failure setup failed")
      return;
    end
    published = null;
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write = 1'b1;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    rdma_cq_device_write_preflight_fault_access::reject_next_device_write = 1'b0;
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        published != null) begin
      `uvm_error("CQE_CANCEL_PUBLISH", "cancel failure did not enter recovery")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        !pending.device_producer || pending.device_write_attempted) begin
      `uvm_error("CQE_CANCEL_PENDING", "cancel failure lost no-write recovery evidence")
      return;
    end
    occupancy = 1;
    occupancy_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || !occupancy_pending)
      `uvm_error("CQE_CANCEL_OCCUPANCY", "cancel failure changed committed occupancy")
    reservation_valid = 1'b0;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || !reservation_valid || reservation == null ||
        reservation.index != pending.cursor.index || reservation.wrap != pending.cursor.wrap)
      `uvm_error("CQE_CANCEL_RESERVATION", "cancel failure lost reserved slot")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.ok() || completion != null)
      `uvm_error("CQE_CANCEL_INVISIBLE",
                 "cancel-failed CQE produced a visible completion before abort")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 0 || producer_wrap ||
        consumer_index != 0 || consumer_wrap)
      `uvm_error("CQE_CANCEL_CURSOR",
                 "cancel-failed CQE advanced a cursor before abort")
    fixture.engine.recover_queue(fixture.cq.handle,
      RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b1, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_CANCEL_ABORT", "cancel failure abort did not detach")
      return;
    end
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null)
      `uvm_error("CQE_CANCEL_ABORT_CLEANUP", "cancel abort retained pending evidence")
  endtask

  // 功能：check_device_publish_stale_route 拍平 attachment 的冻结 route/epoch 与
  //   binding 当前 epoch 不一致场景，验证 publish 在 reserve 前 fail-closed。
  // 输入/输出及副作用：无显式输入；任务先建立有效 CQE，再经 fixture 公开 API
  //   更新 binding reset epoch；只读取 Host-memory/runtime 观测值。
  // 失败边界：未返回 STALE_GENERATION、出现 backend 调用、occupancy/pending 或
  //   reservation 非空时报告 UVM_ERROR；该场景故意不恢复旧 binding。
  task automatic check_device_publish_stale_route();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status model_status;
    bit polarity;
    bit reservation_valid;
    bit occupancy_pending;
    int unsigned occupancy;
    int unsigned calls_before;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_stale_route_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_STALE_ROUTE_SETUP", "stale route fixture setup failed")
      return;
    end
    fixture.engine.post_send(fixture.make_send(64'hd520_0000), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_STALE_ROUTE_POST", "stale route setup post failed")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_STALE_ROUTE_MODEL", "stale route CQE setup is incomplete")
      return;
    end
    calls_before = fixture.mem.calls.size();
    status = fixture.advance_binding_reset_epoch(1);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_STALE_ROUTE_INJECT", "stale route epoch injection failed")
      return;
    end
    published = null;
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        published != null || fixture.mem.calls.size() != calls_before)
      `uvm_error("CQE_STALE_ROUTE_PUBLISH",
                 "stale route publish reserved or entered Host-memory")
    occupancy = 0;
    occupancy_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, occupancy_pending);
    if (status == null || !status.ok() || occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_STALE_ROUTE_OCCUPANCY", "stale route changed occupancy")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.ok() || pending != null ||
        status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_STALE_ROUTE_PENDING", "stale route retained pending")
    reservation_valid = 1'b1;
    reservation = null;
    status = fixture.engine.query_runtime_device_reservation(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, reservation_valid, reservation);
    if (status == null || !status.ok() || reservation_valid || reservation != null)
      `uvm_error("CQE_STALE_ROUTE_RESERVATION", "stale route retained reservation")
  endtask

  // 功能：建立一笔已发布但尚未 poll 的 CQE，并确保 fixture 使用 ordering fault
  //   engine；供顺序与一次性阶段故障用例共享同一真实 post/publish 数据流。
  // 输入/输出及副作用：label 为对象命名前缀；输出 fixture/ordering/posted/cqe/status；
  //   成功时 SQ 与 CQ occupancy 各为 1，且清空 poll 阶段 trace/call counters。
  // 失败/边界：factory/setup/cast/post/polarity/model/publish 任一步失败时 status 为
  //   非成功且输出可能为空；调用方必须停止 poll，helper 不伪造 queue 或 ledger。
  task automatic prepare_ordering_cqe(
    string label,
    output rdma_queue_data_engine_fixture fixture,
    output rdma_queue_data_engine_ordering_fault ordering,
    output rdma_queue_post_result posted,
    output rdma_hw_cqe_model cqe,
    output rdma_status status
  );
    rdma_queue_device_publish_result published;
    rdma_status model_status;
    bit polarity;

    fixture = null;
    ordering = null;
    posted = null;
    cqe = null;
    status = null;
    reset_device_publish_factory_state();
    rdma_queue_data_engine::type_id::set_type_override(
      rdma_queue_data_engine_ordering_fault::get_type(), 1'b1);
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      {label, "_fixture"});
    if (fixture == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "ordering fixture allocation failed");
      return;
    end
    fixture.setup(status);
    if (status == null || !status.ok() ||
        !$cast(ordering, fixture.engine) || ordering == null) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "ordering engine setup/cast failed");
      return;
    end
    fixture.engine.post_send(
      fixture.make_send(64'hd800_0000_0000_0001), posted, status);
    if (status == null || !status.ok() || posted == null) return;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status == null || !status.ok()) return;
    cqe = make_cqe_for_outstanding_send(
      fixture.qp.handle, fixture.qp.local_qp_id, posted, polarity,
      model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      status = model_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "ordering CQE model returned null status") :
        model_status;
      return;
    end
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || !status.ok() || published == null) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "ordering CQE publish failed");
      return;
    end
    ordering.trace.delete();
    ordering.commit_calls = 0;
    ordering.release_calls = 0;
    ordering.doorbell_calls = 0;
    status = rdma_status::success();
  endtask

  // 功能：对已发布 CQE 的一个精确 prepared allocation 注入 null/错误类型，
  //   验证 poll 在 scheduler、CQ CI commit 与 WQE release 前无副作用返回。
  // 输入/输出及副作用：label/wrapper/target_name/wrong_type 与共享 fixture/ordering
  //   为输入；短暂 arm wrapper、执行公开 poll，再只读比较 trace/occupancy/CI/pending。
  // 失败/边界：目标未命中、返回码非 RESOURCE_EXHAUSTED、发布 result/调用任一 seam，
  //   或 CQ/SQ credit、CI、pending 改变时报告 UVM_ERROR；故障窗口退出前总是 disarm。
  task automatic check_cq_poll_factory_fault_case(
    string label,
    rdma_queue_poll_factory_fault_wrapper wrapper,
    string target_name,
    bit wrong_type,
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_data_engine_ordering_fault ordering
  );
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned cq_occupancy;
    int unsigned sq_occupancy;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit has_pending;
    bit fired;

    if (wrapper == null || fixture == null || ordering == null) begin
      `uvm_error(label, "factory fault fixture is incomplete")
      return;
    end
    ordering.trace.delete();
    ordering.doorbell_calls = 0;
    ordering.commit_calls = 0;
    ordering.release_calls = 0;
    wrapper.arm(target_name, wrong_type);
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    fired = wrapper.fired();
    wrapper.disarm();
    if (!fired || status == null ||
        status.code != RDMA_SC_RESOURCE_EXHAUSTED || completion != null)
      `uvm_error(label, status == null ?
                 "factory fault returned null status" : status.convert2string())
    if (ordering.trace.size() != 0 || ordering.doorbell_calls != 0 ||
        ordering.commit_calls != 0 || ordering.release_calls != 0)
      `uvm_error({label, "_SCHEDULER"},
                 "prepared allocation failure crossed a transaction seam")
    cq_occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_occupancy, has_pending);
    if (status == null || !status.ok() || cq_occupancy != 1 || has_pending)
      `uvm_error({label, "_CQ"},
                 "prepared allocation failure changed CQ credit/pending")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != 0 || consumer_wrap)
      `uvm_error({label, "_CI"},
                 "prepared allocation failure advanced CQ consumer cursor")
    sq_occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_occupancy, has_pending);
    if (status == null || !status.ok() || sq_occupancy != 1 || has_pending)
      `uvm_error({label, "_SQ"},
                 "prepared allocation failure changed SQ ledger")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending != null)
      `uvm_error({label, "_PENDING"},
                 "pre-admission failure installed recovery evidence")
  endtask

  // 功能：直接验证 runtime.snapshot_release_range 对两项 outstanding SQ ledger
  //   先完整深复制后才发布输出，且 null/错误类型 slot factory 故障保持只读原子性。
  // 输入/输出及副作用：无显式输入；构造独立 host SQ runtime、提交两个 WQE slot，
  //   通过 poll_slot_fault 调用公开 snapshot API，并只读比较 PI/CI/used 与 detached 值。
  // 失败/边界：configure/reserve/commit/正常快照任一步失败即报告并返回；两种 factory
  //   故障都必须返回 RESOURCE_EXHAUSTED、清空预置输出且不改变 ledger，caller 篡改
  //   成功快照后再次查询仍须得到原 wr_id/image，证明 runtime 没有泄露 owning 引用。
  task automatic check_snapshot_release_range_factory_atomicity();
    rdma_queue_runtime runtime;
    rdma_handle sq_h;
    rdma_post_send_req request;
    rdma_hw_image image;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_slot_ledger_entry snapshots[$];
    rdma_queue_slot_ledger_entry verification[$];
    rdma_status status;
    int unsigned occupancy;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit fired;

    configure_poll_factory_faults();
    runtime = rdma_queue_runtime::type_id::create(
      "release_snapshot_runtime");
    sq_h = rdma_handle::type_id::create("release_snapshot_sq");
    request = rdma_post_send_req::type_id::create(
      "release_snapshot_request");
    image = rdma_hw_image::type_id::create("release_snapshot_image");
    if (runtime == null || sq_h == null || request == null || image == null) begin
      `uvm_error("RELEASE_SNAPSHOT_FIXTURE",
                 "direct snapshot fixture allocation failed")
      return;
    end
    sq_h.kind = RDMA_RESOURCE_QP;
    sq_h.function_uid = 64'hd800_0000_0000_0100;
    sq_h.object_id = 32'h100;
    sq_h.generation = 1;
    request.qp_h = sq_h;
    request.wr_id = 64'hd800_0000_0000_0101;
    request.opcode = RDMA_WR_SEND;
    request.signaled = 1'b1;
    image.length = 2;
    image.alignment = 1;
    image.image_kind = RDMA_IMAGE_SQE;
    image.bytes.push_back(8'ha5);
    image.bytes.push_back(8'h5a);
    status = runtime.configure(
      sq_h, RDMA_QUEUE_RUNTIME_SQ, 4, 0, 1'b0, 0, 1'b0, 1'b1);
    if (status == null || !status.ok()) begin
      `uvm_error("RELEASE_SNAPSHOT_CONFIGURE", status == null ?
                 "runtime configure returned null" : status.convert2string())
      return;
    end
    status = runtime.activate();
    if (status == null || !status.ok()) begin
      `uvm_error("RELEASE_SNAPSHOT_ACTIVATE", status == null ?
                 "runtime activate returned null" : status.convert2string())
      return;
    end
    for (int unsigned i = 0; i < 2; i++) begin
      reservation = null;
      status = runtime.reserve_producer(reservation);
      if (status == null || !status.ok() || reservation == null) begin
        `uvm_error("RELEASE_SNAPSHOT_RESERVE", status == null ?
                   "runtime reserve returned null" : status.convert2string())
        return;
      end
      status = runtime.commit_producer(
        reservation, request, 64'hd800_0000_0000_0200 + i, 1'b1, image);
      if (status == null || !status.ok()) begin
        `uvm_error("RELEASE_SNAPSHOT_COMMIT", status == null ?
                   "runtime commit returned null" : status.convert2string())
        return;
      end
    end

    snapshots.delete();
    status = runtime.snapshot_release_range(1, 1'b0, snapshots);
    if (status == null || !status.ok() || snapshots.size() != 2 ||
        snapshots[0] == null || snapshots[1] == null ||
        snapshots[0].request_snapshot == null || snapshots[0].image == null ||
        snapshots[0].request_snapshot == request || snapshots[0].image == image ||
        snapshots[0].wr_id != 64'hd800_0000_0000_0200 ||
        snapshots[1].wr_id != 64'hd800_0000_0000_0201) begin
      `uvm_error("RELEASE_SNAPSHOT_BASELINE", status == null ?
                 "baseline snapshot returned null" : status.convert2string())
      return;
    end
    snapshots[0].posted = 1'b0;
    snapshots[0].wr_id = 64'hffff_ffff_ffff_ffff;
    snapshots[0].image.bytes[0] = 8'h00;

    poll_slot_fault.arm("release_range_slot_copy", 1'b0);
    status = runtime.snapshot_release_range(1, 1'b0, snapshots);
    fired = poll_slot_fault.fired();
    poll_slot_fault.disarm();
    if (!fired || status == null ||
        status.code != RDMA_SC_RESOURCE_EXHAUSTED || snapshots.size() != 0)
      `uvm_error("RELEASE_SNAPSHOT_NULL", status == null ?
                 "null clone returned null status" : status.convert2string())
    occupancy = 0;
    status = runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != 2)
      `uvm_error("RELEASE_SNAPSHOT_NULL_USED",
                 "null clone changed host WQE occupancy")
    status = runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 2 ||
        producer_wrap || consumer_index != 0 || consumer_wrap)
      `uvm_error("RELEASE_SNAPSHOT_NULL_CURSOR",
                 "null clone changed host WQE PI/CI")

    verification.push_back(null);
    poll_slot_fault.arm("release_range_slot_copy", 1'b1);
    status = runtime.snapshot_release_range(1, 1'b0, verification);
    fired = poll_slot_fault.fired();
    poll_slot_fault.disarm();
    if (!fired || status == null ||
        status.code != RDMA_SC_RESOURCE_EXHAUSTED || verification.size() != 0)
      `uvm_error("RELEASE_SNAPSHOT_WRONG", status == null ?
                 "wrong clone returned null status" : status.convert2string())
    occupancy = 0;
    status = runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != 2)
      `uvm_error("RELEASE_SNAPSHOT_WRONG_USED",
                 "wrong clone changed host WQE occupancy")
    status = runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 2 ||
        producer_wrap || consumer_index != 0 || consumer_wrap)
      `uvm_error("RELEASE_SNAPSHOT_WRONG_CURSOR",
                 "wrong clone changed host WQE PI/CI")

    verification.delete();
    status = runtime.snapshot_release_range(1, 1'b0, verification);
    if (status == null || !status.ok() || verification.size() != 2 ||
        verification[0] == null || verification[0].image == null ||
        !verification[0].posted || verification[0].consumed ||
        verification[0].wr_id != 64'hd800_0000_0000_0200 ||
        verification[0].image.bytes.size() != 2 ||
        verification[0].image.bytes[0] != 8'ha5)
      `uvm_error("RELEASE_SNAPSHOT_DETACHED", status == null ?
                 "verification snapshot returned null" : status.convert2string())
  endtask

  // 功能：check_cq_local_preparation_failure 验证一个 consumer doorbell 本地准备
  //   故障在 admission/scheduler 前结束，并保持 CQE、CQ CI 与 SQ WQE 全部可见。
  // 输入/输出及副作用：label/fixture/ordering/expected_code 为输入；执行一次公开
  //   poll，并读取 PCIe history、runtime occupancy/cursor/pending，不修改故障源。
  // 失败/边界：status code 不符、发布 completion、调用任一 transaction seam、
  //   PCIe 增长、CQ/SQ used 或 CI 改变、安装 pending 时报告 UVM_ERROR。
  task automatic check_cq_local_preparation_failure(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_data_engine_ordering_fault ordering,
    rdma_status_code_e expected_code
  );
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned pcie_before;
    int unsigned cq_occupancy;
    int unsigned sq_occupancy;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit has_pending;

    if (fixture == null || ordering == null) begin
      `uvm_error(label, "local preparation fixture is incomplete")
      return;
    end
    ordering.trace.delete();
    ordering.doorbell_calls = 0;
    ordering.commit_calls = 0;
    ordering.release_calls = 0;
    pcie_before = count_pcie_calls(fixture.pcie, "mmio_write");
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != expected_code || completion != null)
      `uvm_error(label, status == null ?
                 "local preparation returned null status" : status.convert2string())
    if (ordering.trace.size() != 0 || ordering.doorbell_calls != 0 ||
        ordering.commit_calls != 0 || ordering.release_calls != 0 ||
        count_pcie_calls(fixture.pcie, "mmio_write") != pcie_before)
      `uvm_error({label, "_NO_SUBMIT"},
                 "local preparation crossed admission/scheduler or local stages")
    cq_occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_occupancy, has_pending);
    if (status == null || !status.ok() || cq_occupancy != 1 || has_pending)
      `uvm_error({label, "_CQ"}, "local failure changed CQ used/pending")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ,
      producer_index, producer_wrap, consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != 0 || consumer_wrap)
      `uvm_error({label, "_CI"}, "local failure advanced CQ consumer cursor")
    sq_occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_occupancy, has_pending);
    if (status == null || !status.ok() || sq_occupancy != 1 || has_pending)
      `uvm_error({label, "_SQ"}, "local failure changed SQ WQE credit")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        pending != null)
      `uvm_error({label, "_PENDING"},
                 "local failure installed consumer recovery evidence")
  endtask

  // 功能：check_cq_consumer_codec_preparation_failures 用真实 registry lookup 与
  //   codec.encode 覆盖 missing/null codec、error/null status 和 success+null image，
  //   并确认恢复原 codec 后同一 CQE 仍能成功消费。
  // 输入/输出及副作用：无显式输入；建立 fault-registry fixture，逐次替换单个
  //   cq_rc_ud codec，调用 local-failure helper，最后恢复原引用并正常 poll。
  // 失败/边界：registry cast/replace/remove/restore 失败、任何故障跨 scheduler、
  //   或最终 trace/result 不完整时报告 UVM_ERROR；每个分支都恢复原 codec。
  task automatic check_cq_consumer_codec_preparation_failures();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_consumer_fault_registry fault_registry;
    rdma_queue_consumer_codec_guard codec_guard;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_codec_base original_codec;
    rdma_codec_base displaced_codec;
    rdma_codec_key key;
    rdma_status status;

    prepare_ordering_cqe(
      "cq_consumer_codec", fixture, ordering, posted, cqe, status);
    if (status == null || !status.ok() || fixture == null ||
        !$cast(fault_registry, fixture.registry) || fault_registry == null) begin
      `uvm_error("CQ_CONSUMER_CODEC_SETUP", status == null ?
                 "codec fixture returned null" : status.convert2string())
      return;
    end
    key = '{hw_version:"rdma", image_kind:RDMA_IMAGE_DOORBELL,
      object_type:"doorbell", variant:"cq_rc_ud", opcode:8'h00};
    original_codec = null;
    if (!fault_registry.remove_codec_for_test(key, original_codec) ||
        original_codec == null) begin
      `uvm_error("CQ_CONSUMER_CODEC_REMOVE", "doorbell codec remove failed")
      return;
    end
    check_cq_local_preparation_failure(
      "CQ_CONSUMER_LOOKUP_ERROR", fixture, ordering,
      RDMA_SC_UNSUPPORTED_OPCODE);
    if (!fault_registry.restore_codec_for_test(key, original_codec)) begin
      `uvm_error("CQ_CONSUMER_CODEC_RESTORE", "lookup codec restore failed")
      return;
    end

    displaced_codec = null;
    if (!fault_registry.replace_codec_for_test(key, null, displaced_codec) ||
        displaced_codec != original_codec) begin
      `uvm_error("CQ_CONSUMER_CODEC_NULL_INJECT", "null codec replace failed")
      return;
    end
    check_cq_local_preparation_failure(
      "CQ_CONSUMER_CODEC_NULL", fixture, ordering,
      RDMA_SC_RESOURCE_EXHAUSTED);
    if (!fault_registry.restore_codec_for_test(key, original_codec)) begin
      `uvm_error("CQ_CONSUMER_CODEC_NULL_RESTORE", "null codec restore failed")
      return;
    end

    codec_guard = new("cq_consumer_codec_guard", original_codec);
    codec_guard.injected_error = rdma_status::make(
      RDMA_SC_CODEC_ERROR, "injected consumer doorbell codec failure");
    displaced_codec = null;
    if (!fault_registry.replace_codec_for_test(
          key, codec_guard, displaced_codec) ||
        displaced_codec != original_codec) begin
      `uvm_error("CQ_CONSUMER_CODEC_GUARD", "codec guard replace failed")
      return;
    end
    codec_guard.return_error_encode_status = 1'b1;
    check_cq_local_preparation_failure(
      "CQ_CONSUMER_ENCODE_ERROR", fixture, ordering, RDMA_SC_CODEC_ERROR);
    codec_guard.return_error_encode_status = 1'b0;
    codec_guard.return_null_encode_status = 1'b1;
    check_cq_local_preparation_failure(
      "CQ_CONSUMER_ENCODE_NULL", fixture, ordering, RDMA_SC_INVALID_STATE);
    codec_guard.return_null_encode_status = 1'b0;
    codec_guard.return_null_encode_image = 1'b1;
    check_cq_local_preparation_failure(
      "CQ_CONSUMER_IMAGE_NULL", fixture, ordering, RDMA_SC_CODEC_ERROR);
    codec_guard.return_null_encode_image = 1'b0;
    if (!fault_registry.restore_codec_for_test(key, original_codec)) begin
      `uvm_error("CQ_CONSUMER_CODEC_FINAL_RESTORE", "codec restore failed")
      return;
    end

    ordering.trace.delete();
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        ordering.trace.size() != 3 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.trace[2] != "release")
      `uvm_error("CQ_CONSUMER_CODEC_FINAL", status == null ?
                 "restored codec poll returned null" : status.convert2string())
  endtask

  // 功能：check_cq_poll_post_scheduler_allocation_guard 在真实 scheduler 成功返回
  //   后监测所有相关 UVM factory，证明 CQ CI commit、WQE release、marker/finalize
  //   与结果发布不再创建 status/cursor/evidence 对象。
  // 输入/输出及副作用：无显式输入；建立一笔真实 CQE，arm result/status 边界
  //   guard 后执行公开 poll，返回即关闭 guard，再检查 trace 与 completion。
  // 失败/边界：scheduler 未成功、guard 未跨过边界、任一 post-scheduler factory
  //   create、顺序非 doorbell→commit→release 或结果不完整时报告 UVM_ERROR。
  task automatic check_cq_poll_post_scheduler_allocation_guard();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_status status;
    int unsigned guarded_creates;
    string first_create;

    prepare_ordering_cqe(
      "cq_post_scheduler_alloc", fixture, ordering, posted, cqe, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_POST_SCHED_ALLOC_SETUP", status == null ?
                 "allocation guard setup returned null" : status.convert2string())
      return;
    end
    configure_poll_factory_faults();
    rdma_queue_poll_factory_fault_wrapper::arm_scheduler_allocation_guard();
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    rdma_queue_poll_factory_fault_wrapper::disable_allocation_guard(
      guarded_creates, first_create);
    if (status == null || !status.ok() || completion == null ||
        ordering.trace.size() != 3 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.trace[2] != "release")
      `uvm_error("CQ_POST_SCHED_ALLOC_FLOW", status == null ?
                 "guarded poll returned null" : status.convert2string())
    if (guarded_creates != 0)
      `uvm_error("CQ_POST_SCHED_ALLOC", $sformatf(
        "post-scheduler factory creates=%0d first=%s",
        guarded_creates, first_create))
  endtask

  // 功能：覆盖 CQ prepared pending/result/release-slot 以及 nested handle/image/
  //   status 及 doorbell model/descriptor 的 null 与错误类型 factory 结果，最后
  //   确认同一可见 CQE 仍可正常消费。
  // 输入/输出及副作用：无显式输入；建立一笔真实 post/publish，依次驱动十二个
  //   pre-admission 故障矩阵，再执行一次成功 poll；只使用公开状态查询。
  // 失败/边界：任一故障若提前消费 CQE 或 WQE 会被逐项 atomicity 断言捕获；
  //   wrapper 未命中也必须失败，最终成功路径必须仍为 doorbell→commit→release。
  task automatic check_cq_poll_prepared_factory_failures();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_status status;

    prepare_ordering_cqe("cq_poll_factory", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_POLL_FACTORY_SETUP", status == null ?
                 "factory fixture returned null status" : status.convert2string())
      return;
    end
    configure_poll_factory_faults();
    check_cq_poll_factory_fault_case(
      "CQ_PENDING_NULL", poll_pending_fault, "prepared_consumer_pending",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_PENDING_WRONG", poll_pending_fault, "prepared_consumer_pending",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_RESULT_NULL", poll_result_fault, "prepared_cqe_result",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_RESULT_WRONG", poll_result_fault, "prepared_cqe_result",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_SLOT_NULL", poll_slot_fault, "release_range_slot_copy",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_SLOT_WRONG", poll_slot_fault, "release_range_slot_copy",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_HANDLE_NULL", poll_handle_fault, "CQ result queue_handle",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_HANDLE_WRONG", poll_handle_fault, "CQ result queue_handle",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_IMAGE_NULL", poll_image_fault, "cq_poll_pending_image",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_IMAGE_WRONG", poll_image_fault, "cq_poll_pending_image",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_STATUS_NULL", poll_status_fault, "CQ result model_status",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_STATUS_WRONG", poll_status_fault, "CQ result model_status",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_DB_MODEL_NULL", poll_cq_db_model_fault, "cq_ci_db_model",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_DB_MODEL_WRONG", poll_cq_db_model_fault, "cq_ci_db_model",
      1'b1, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_DB_DESC_NULL", poll_db_desc_fault, "consumer_db_desc",
      1'b0, fixture, ordering);
    check_cq_poll_factory_fault_case(
      "CQ_DB_DESC_WRONG", poll_db_desc_fault, "consumer_db_desc",
      1'b1, fixture, ordering);

    ordering.trace.delete();
    ordering.doorbell_calls = 0;
    ordering.commit_calls = 0;
    ordering.release_calls = 0;
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        ordering.trace.size() != 3 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.trace[2] != "release")
      `uvm_error("CQ_FACTORY_FINAL", status == null ?
                 "final CQ poll returned null status" : status.convert2string())
  endtask

  // 功能：验证一次正常 CQ poll 严格执行 doorbell、CQ CI commit、WQE release，
  //   并发布基于预快照 ledger 的 completion result。
  // 输入/输出及副作用：无显式输入；驱动真实 post/publish/poll，并读取 ordering.trace
  //   与公开 occupancy；成功会消费一项 CQE 和对应 SQ WQE。
  // 失败/边界：任一阶段缺失、重复、相对顺序错误，或最终 CQ/SQ occupancy 非零时
  //   报告 UVM_ERROR；仅 call count 正确但 trace 顺序错误同样失败。
  task automatic check_cq_poll_commit_before_release_order();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_status status;
    bit has_pending;
    int unsigned occupancy;

    prepare_ordering_cqe("cq_poll_order", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_POLL_ORDER_SETUP", status == null ?
                 "ordering setup returned null status" :
                 status.convert2string())
      return;
    end
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error("CQ_POLL_ORDER_RESULT", status == null ?
                 "normal poll returned null status" : status.convert2string())
    if (ordering.trace.size() != 3 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.trace[2] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("CQ_POLL_ORDER_TRACE",
                 $sformatf("trace=%p calls=%0d/%0d/%0d",
                           ordering.trace, ordering.doorbell_calls,
                           ordering.commit_calls, ordering.release_calls))
    occupancy = 32'hffff_ffff;
    has_pending = 1'b1;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_POLL_ORDER_CQ_FINAL", "CQ did not complete exactly once")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_POLL_ORDER_SQ_FINAL", "SQ WQE was not released exactly once")
  endtask

  // 功能：验证 CQ CI commit 一次性失败时绝不提前释放 WQE，并把 doorbell SUCCESS
  //   与未完成本地阶段保存在公开 detached pending 中供 caller-confirmed recovery。
  // 输入/输出及副作用：无显式输入；在真实 CQ poll 注入一次 commit 故障，读取
  //   CQ/SQ occupancy、cursor 与 query_runtime_pending，不修改 pending 内部状态。
  // 失败/边界：poll 发布 result、trace 出现 release、CQ/SQ credit 改变、pending 丢失
  //   或阶段/evidence/failure_status 不符时报告 UVM_ERROR。
  task automatic check_cq_poll_commit_failure_is_recoverable();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    bit has_pending;
    bit producer_wrap;
    bit consumer_wrap;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    int unsigned trace_before_retry;

    prepare_ordering_cqe("cq_commit_fail", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_COMMIT_FAIL_SETUP", status == null ?
                 "commit-fault setup returned null status" :
                 status.convert2string())
      return;
    end
    ordering.fail_commit_once = 1'b1;
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null)
      `uvm_error("CQ_COMMIT_FAIL_RESULT", status == null ?
                 "commit fault returned null status" : status.convert2string())
    if (ordering.trace.size() != 2 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.doorbell_calls != 1 ||
        ordering.commit_calls != 1 || ordering.release_calls != 0)
      `uvm_error("CQ_COMMIT_FAIL_TRACE",
                 $sformatf("trace=%p calls=%0d/%0d/%0d",
                           ordering.trace, ordering.doorbell_calls,
                           ordering.commit_calls, ordering.release_calls))
    occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || !has_pending)
      `uvm_error("CQ_COMMIT_FAIL_CQ", "commit failure changed CQ credit/evidence")
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() || consumer_index != 0 || consumer_wrap)
      `uvm_error("CQ_COMMIT_FAIL_CI", "commit failure advanced CQ consumer cursor")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_COMMIT_FAIL_SQ", "commit failure released the SQ WQE")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        !pending.consumer_doorbell_succeeded || pending.consumer_committed ||
        pending.cq_consumer_committed || pending.completion_released ||
        pending.committed_consumer_cursor != null ||
        pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_COMMIT_FAIL_PENDING", status == null ?
                 "commit failure pending query returned null status" :
                 status.convert2string())
    trace_before_retry = ordering.trace.size();
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        ordering.trace.size() != trace_before_retry)
      `uvm_error("CQ_COMMIT_FAIL_CONFIRM",
                 "unconfirmed retry changed transaction stages")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok())
      `uvm_error("CQ_COMMIT_FAIL_RECOVER", status == null ?
                 "confirmed retry returned null status" :
                 status.convert2string())
    if (ordering.trace.size() != 4 || ordering.trace[2] != "commit" ||
        ordering.trace[3] != "release" || ordering.doorbell_calls != 1 ||
        ordering.commit_calls != 2 || ordering.release_calls != 1)
      `uvm_error("CQ_COMMIT_FAIL_REPLAY_ORDER",
                 $sformatf("trace=%p calls=%0d/%0d/%0d",
                           ordering.trace, ordering.doorbell_calls,
                           ordering.commit_calls, ordering.release_calls))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_COMMIT_FAIL_CQ_FINAL", "CQ retry did not complete once")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_COMMIT_FAIL_SQ_FINAL", "SQ retry did not release once")
  endtask

  // 功能：验证 release 一次性失败发生在 CQ CI commit 之后，pending 立即保留两个
  //   consumer commit 位；caller-confirmed retry 只补 release，不重发 doorbell/CI。
  // 输入/输出及副作用：无显式输入；驱动真实 post/publish/poll/recover，并读取公开
  //   pending、CQ/SQ occupancy 与 ordering trace；最终只释放原 WQE 一次。
  // 失败/边界：未确认 retry 必须拒绝且无 trace；确认后 doorbell/commit 计数不变、
  //   release_calls 仅增加一次，任何阶段位、cursor 或 occupancy 不符均报告 UVM_ERROR。
  task automatic check_cq_poll_release_failure_is_idempotent();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    bit has_pending;
    int unsigned occupancy;
    int unsigned trace_before_retry;

    prepare_ordering_cqe("cq_release_fail", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_RELEASE_FAIL_SETUP", status == null ?
                 "release-fault setup returned null status" :
                 status.convert2string())
      return;
    end
    ordering.fail_release_once = 1'b1;
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null)
      `uvm_error("CQ_RELEASE_FAIL_RESULT", status == null ?
                 "release fault returned null status" : status.convert2string())
    if (ordering.trace.size() != 3 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.trace[2] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("CQ_RELEASE_FAIL_TRACE", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || !has_pending)
      `uvm_error("CQ_RELEASE_FAIL_CQ", "release failure lost committed CQ state")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_RELEASE_FAIL_SQ", "release fault changed SQ ledger")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        !pending.consumer_doorbell_succeeded || !pending.consumer_committed ||
        !pending.cq_consumer_committed || pending.completion_released ||
        pending.committed_consumer_cursor == null ||
        pending.next_cursor == null ||
        pending.committed_consumer_cursor.index != pending.next_cursor.index ||
        pending.committed_consumer_cursor.wrap != pending.next_cursor.wrap ||
        pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_RELEASE_FAIL_PENDING", status == null ?
                 "release failure pending query returned null" :
                 status.convert2string())
    trace_before_retry = ordering.trace.size();
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        ordering.trace.size() != trace_before_retry)
      `uvm_error("CQ_RELEASE_FAIL_CONFIRM",
                 "unconfirmed retry changed a completed stage")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok())
      `uvm_error("CQ_RELEASE_FAIL_RECOVER", status == null ?
                 "confirmed release retry returned null" :
                 status.convert2string())
    if (ordering.trace.size() != trace_before_retry + 1 ||
        ordering.trace[trace_before_retry] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 2)
      `uvm_error("CQ_RELEASE_FAIL_IDEMPOTENCE", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls, ordering.release_calls))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_RELEASE_FAIL_CQ_FINAL", "CQ pending was not completed")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_RELEASE_FAIL_SQ_FINAL", "SQ release retry was not exact")
  endtask

  // 功能：验证 engine 在 WQ release 前必须取得 CQ release gate；测试 seam 在成功
  //   commit 后抢先持锁，使本轮 poll 必须在调用 release_cq_wqe 前失败退出。
  // 输入/输出及副作用：无显式输入；以预建 status 注入一次 gate 竞争，观察 trace、
  //   CQ/SQ occupancy 与 detached pending，撤销注入后 caller-confirmed retry 只释放一次。
  // 失败/边界：首次 poll 若触碰 WQ ledger、发布 result 或遗失 committed pending 即报错；
  //   注入 gate 无论断言结果都显式 finish(false)，避免测试锁泄漏掩盖后续用例。
  task automatic check_cq_poll_release_gate_blocks_wq_mutation();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    bit has_pending;
    int unsigned occupancy;

    prepare_ordering_cqe("cq_release_gate_busy", fixture, ordering, posted,
                         cqe, status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_RELEASE_GATE_SETUP", status == null ?
                 "release-gate setup returned null status" :
                 status.convert2string())
      return;
    end
    ordering.held_release_status = rdma_status::make(
      RDMA_SC_OK, "prebuilt injected release gate status");
    ordering.hold_release_gate_after_commit_once = 1'b1;
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
        completion != null)
      `uvm_error("CQ_RELEASE_GATE_RESULT", status == null ?
                 "release-gate poll returned null status" :
                 status.convert2string())
    if (!ordering.held_release_gate_active ||
        ordering.held_release_runtime == null ||
        ordering.trace.size() != 2 || ordering.trace[0] != "doorbell" ||
        ordering.trace[1] != "commit" || ordering.doorbell_calls != 1 ||
        ordering.commit_calls != 1 || ordering.release_calls != 0)
      `uvm_error("CQ_RELEASE_GATE_TRACE", $sformatf(
        "held=%0b trace=%p calls=%0d/%0d/%0d",
        ordering.held_release_gate_active, ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls,
        ordering.release_calls))
    occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_RELEASE_GATE_SQ_HELD",
                 "CQ gate contention changed the routed SQ ledger")

    if (ordering.held_release_gate_active &&
        ordering.held_release_runtime != null) begin
      if (!ordering.held_release_runtime.finish_consumer_release_noalloc(
            1'b0, ordering.held_release_status))
        `uvm_error("CQ_RELEASE_GATE_CANCEL",
                   "injected CQ release gate could not be unlocked")
      else
        ordering.held_release_gate_active = 1'b0;
    end
    else
      `uvm_error("CQ_RELEASE_GATE_CANCEL",
                 "commit seam did not acquire the injected CQ release gate")

    occupancy = 32'hffff_ffff;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || !has_pending)
      `uvm_error("CQ_RELEASE_GATE_CQ_PENDING",
                 "gate contention lost the committed CQ pending state")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        !pending.consumer_committed || !pending.cq_consumer_committed ||
        pending.completion_released)
      `uvm_error("CQ_RELEASE_GATE_PENDING", status == null ?
                 "gate pending query returned null status" :
                 status.convert2string())

    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok())
      `uvm_error("CQ_RELEASE_GATE_RECOVER", status == null ?
                 "release-gate retry returned null status" :
                 status.convert2string())
    if (ordering.trace.size() != 3 || ordering.trace[2] != "release" ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 1 ||
        ordering.release_calls != 1)
      `uvm_error("CQ_RELEASE_GATE_RETRY", $sformatf(
        "trace=%p calls=%0d/%0d/%0d", ordering.trace,
        ordering.doorbell_calls, ordering.commit_calls,
        ordering.release_calls))
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_RELEASE_GATE_CQ_FINAL",
                 "release-gate retry did not complete CQ recovery")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_RELEASE_GATE_SQ_FINAL",
                 "release-gate retry did not release exactly one SQ WQE")
  endtask

  // 功能：验证 consumer doorbell 本地 NO_SUBMIT 保持 CQ/SQ 可见且无 PCIe write，
  //   只有 caller confirmation 后重发一次并继续 commit→release。
  // 输入/输出及副作用：无显式输入；通过 exact ordering seam 注入一次 NO_SUBMIT，
  //   比较 public pending、trace、PCIe history 和最终 occupancy。
  // 失败/边界：首次 poll 若出现 MMIO/CI/release，未确认 retry 若推进阶段，或确认后
  //   doorbell 重发不恰好一次，均报告 UVM_ERROR。
  task automatic check_cq_poll_no_submit_requires_confirmation();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned mmio_after_fault;
    int unsigned occupancy;
    bit has_pending;

    prepare_ordering_cqe("cq_no_submit", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_NO_SUBMIT_SETUP", status == null ?
                 "NO_SUBMIT setup returned null" : status.convert2string())
      return;
    end
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    ordering.fail_doorbell_once = 1'b1;
    ordering.inject_ambiguous_doorbell = 1'b0;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    mmio_after_fault = count_pcie_calls(fixture.pcie, "mmio_write");
    if (status == null || status.code != RDMA_SC_PCIE_COMPLETION ||
        completion != null || mmio_after_fault != mmio_before ||
        ordering.trace.size() != 1 || ordering.trace[0] != "doorbell" ||
        ordering.commit_calls != 0 || ordering.release_calls != 0)
      `uvm_error("CQ_NO_SUBMIT_FAULT", "local failure crossed scheduler/stages")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
        !pending.known_no_mmio || pending.mmio_maybe_submitted ||
        pending.consumer_doorbell_succeeded || pending.consumer_committed ||
        pending.completion_released || pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_PCIE_COMPLETION)
      `uvm_error("CQ_NO_SUBMIT_PENDING", "NO_SUBMIT evidence is incomplete")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
        ordering.doorbell_calls != 1)
      `uvm_error("CQ_NO_SUBMIT_CONFIRM", "unconfirmed retry was accepted")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || !status.ok() || ordering.trace.size() != 4 ||
        ordering.trace[1] != "doorbell" || ordering.trace[2] != "commit" ||
        ordering.trace[3] != "release" || ordering.doorbell_calls != 2 ||
        ordering.commit_calls != 1 || ordering.release_calls != 1 ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_before + 1)
      `uvm_error("CQ_NO_SUBMIT_RECOVER", status == null ?
                 "confirmed retry returned null" : status.convert2string())
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_NO_SUBMIT_CQ_FINAL", "CQ retry did not finish")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || has_pending)
      `uvm_error("CQ_NO_SUBMIT_SQ_FINAL", "SQ retry did not release")
  endtask

  // 功能：验证真实 scheduler/PCIe consumer doorbell 失败被标记为 AMBIGUOUS，
  //   CQ CI 与 WQE ledger 均不变，caller confirmation 也不能触发自动重发。
  // 输入/输出及副作用：无显式输入；向 mock PCIe 注入一次 mmio_write 失败，读取
  //   public pending、trace/history/occupancy，并最终显式 abort 清理 fixture。
  // 失败/边界：evidence 非 AMBIGUOUS、retry 返回非 RECOVERY_REQUIRED、PCIe/trace
  //   增加或本地 commit/release 发生时报告 UVM_ERROR。
  task automatic check_cq_poll_ambiguous_never_resends();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned mmio_before;
    int unsigned mmio_after_fault;
    int unsigned occupancy;
    bit has_pending;

    prepare_ordering_cqe("cq_ambiguous", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_AMBIGUOUS_SETUP", status == null ?
                 "AMBIGUOUS setup returned null" : status.convert2string())
      return;
    end
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    fixture.pcie.fail_next(
      "mmio_write", rdma_status::make(
        RDMA_SC_PCIE_COMPLETION, "injected ambiguous consumer doorbell"));
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    mmio_after_fault = count_pcie_calls(fixture.pcie, "mmio_write");
    if (status == null || status.code != RDMA_SC_PCIE_COMPLETION ||
        completion != null || mmio_after_fault != mmio_before + 1 ||
        ordering.trace.size() != 1 || ordering.trace[0] != "doorbell" ||
        ordering.commit_calls != 0 || ordering.release_calls != 0)
      `uvm_error("CQ_AMBIGUOUS_FAULT", "scheduler fault changed local stages")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_AMBIGUOUS ||
        !pending.mmio_maybe_submitted || pending.known_no_mmio ||
        pending.consumer_doorbell_succeeded || pending.consumer_committed ||
        pending.completion_released || pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_PCIE_COMPLETION)
      `uvm_error("CQ_AMBIGUOUS_PENDING", "ambiguous evidence is incomplete")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
        count_pcie_calls(fixture.pcie, "mmio_write") != mmio_after_fault ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 0 ||
        ordering.release_calls != 0)
      `uvm_error("CQ_AMBIGUOUS_RETRY", "ambiguous doorbell was replayed")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || !has_pending)
      `uvm_error("CQ_AMBIGUOUS_CQ", "ambiguous CQ state was not retained")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_AMBIGUOUS_SQ", "ambiguous path changed SQ ledger")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0, status);
    if (status == null || !status.ok())
      `uvm_error("CQ_AMBIGUOUS_ABORT", status == null ?
                 "ambiguous abort returned null" : status.convert2string())
  endtask

  // 功能：验证三个 transaction seam 分别返回 null status 时均被归一化为可记录
  //   的 INVALID_STATE，且只保留已经完成的单调阶段，不发布 completion。
  // 输入/输出及副作用：无显式输入；为 doorbell/commit/release 各建立独立 CQE，
  //   注入一次 null status 并读取 trace、pending 与 CQ/SQ occupancy。
  // 失败/边界：null 被透传、后续阶段被误执行、failure_status 丢失，或 commit/release
  //   前后 credit 不符合已完成阶段时报告 UVM_ERROR；测试不读取私有账本。
  task automatic check_cq_poll_null_seam_statuses();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned occupancy;
    bit has_pending;

    prepare_ordering_cqe("cq_null_doorbell", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_NULL_DOORBELL_SETUP", "null doorbell fixture setup failed")
      return;
    end
    ordering.null_doorbell_status_once = 1'b1;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null || ordering.trace.size() != 1 ||
        ordering.trace[0] != "doorbell" || ordering.commit_calls != 0 ||
        ordering.release_calls != 0)
      `uvm_error("CQ_NULL_DOORBELL", "null doorbell status crossed a later stage")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
        pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_NULL_DOORBELL_PENDING", "null doorbell evidence was not retained")

    prepare_ordering_cqe("cq_null_commit", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_NULL_COMMIT_SETUP", "null commit fixture setup failed")
      return;
    end
    ordering.null_commit_status_once = 1'b1;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null || ordering.trace.size() != 2 ||
        ordering.trace[0] != "doorbell" || ordering.trace[1] != "commit" ||
        ordering.release_calls != 0)
      `uvm_error("CQ_NULL_COMMIT", "null commit status crossed WQE release")
    occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || !has_pending)
      `uvm_error("CQ_NULL_COMMIT_CQ", "null commit changed CQ credit")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_NULL_COMMIT_SQ", "null commit changed SQ ledger")

    prepare_ordering_cqe("cq_null_release", fixture, ordering, posted, cqe,
                         status);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_NULL_RELEASE_SETUP", "null release fixture setup failed")
      return;
    end
    ordering.null_release_status_once = 1'b1;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        completion != null || ordering.trace.size() != 3 ||
        ordering.trace[0] != "doorbell" || ordering.trace[1] != "commit" ||
        ordering.trace[2] != "release")
      `uvm_error("CQ_NULL_RELEASE", "null release status lost stage order")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        !pending.consumer_committed || !pending.cq_consumer_committed ||
        pending.completion_released || pending.failure_status == null ||
        pending.failure_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_NULL_RELEASE_PENDING", "null release evidence was not retained")
    status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 0 || !has_pending)
      `uvm_error("CQ_NULL_RELEASE_CQ", "null release lost committed CQ state")
    status = fixture.engine.query_runtime_occupancy(
      fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error("CQ_NULL_RELEASE_SQ", "null release changed SQ ledger")
  endtask

  // 功能：验证 consumer seam 返回 NONE 或错误方向 NOT_APPLICABLE 时 recovery
  //   始终 fail-closed，caller confirmation 也不能把未知证据变成重发授权。
  // 输入/输出及副作用：label/not_applicable 为输入；建立真实 CQE，注入一次指定
  //   enum 的失败 doorbell，读取公开 pending 后调用 confirmed recover_queue。
  // 失败/边界：NOT_APPLICABLE 不得进入 consumer pending authority；两种情况均不得
  //   commit/release/重发，pending 的唯一 enum 必须保持 NONE。
  task automatic check_cq_poll_unknown_evidence_case(
    string label,
    bit not_applicable
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_queue_post_result posted;
    rdma_hw_cqe_model cqe;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status status;

    prepare_ordering_cqe(label, fixture, ordering, posted, cqe, status);
    if (status == null || !status.ok()) begin
      `uvm_error({label, "_SETUP"}, "unknown-evidence fixture setup failed")
      return;
    end
    ordering.fail_doorbell_once = 1'b1;
    ordering.inject_none_doorbell = !not_applicable;
    ordering.inject_not_applicable_doorbell = not_applicable;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || status.ok() || completion != null ||
        ordering.trace.size() != 1 || ordering.trace[0] != "doorbell" ||
        ordering.commit_calls != 0 || ordering.release_calls != 0)
      `uvm_error({label, "_POLL"}, "unknown evidence crossed a local stage")
    pending = null;
    status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (status == null || !status.ok() || pending == null ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NONE ||
        pending.consumer_doorbell_succeeded || pending.consumer_committed ||
        pending.completion_released || pending.failure_status == null ||
        pending.failure_status.code != (not_applicable ?
          RDMA_SC_INVALID_STATE : RDMA_SC_PCIE_COMPLETION))
      `uvm_error({label, "_PENDING"}, "unknown evidence was promoted")
    fixture.engine.recover_queue(
      fixture.cq.handle, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        ordering.doorbell_calls != 1 || ordering.commit_calls != 0 ||
        ordering.release_calls != 0)
      `uvm_error({label, "_RECOVER"}, "unknown evidence was replayed")
  endtask

  // 功能：分别驱动 NONE 与 consumer NOT_APPLICABLE 的 fail-closed recovery 矩阵。
  // 输入/输出及副作用：无显式输入；调用两个独立 fixture 场景，只产生测试报告。
  // 失败/边界：任一场景失败由其唯一 label 暴露；两者不共享 pending 或 fault 开关。
  task automatic check_cq_poll_unknown_evidence_fails_closed();
    check_cq_poll_unknown_evidence_case("CQ_MMIO_NONE", 1'b0);
    check_cq_poll_unknown_evidence_case("CQ_MMIO_NOT_APPLICABLE", 1'b1);
  endtask

  // 功能：check_event_db_model_factory_fault 对 CEQ/AEQ consumer doorbell model 的
  //   一次 null/错误类型 raw factory 结果执行公开 poll 原子性断言。
  // 输入/输出及副作用：label/fixture/ordering/queue_h/kind/wrapper/name/wrong_type
  //   为输入；短暂 arm wrapper，按 kind 调用 poll_ceqe/poll_aeqe 并查询 occupancy。
  // 失败/边界：只接受 CEQ/AEQ；未命中 factory、非 RESOURCE_EXHAUSTED、发布结果、
  //   trace/PCIe 增长、used/pending 改变时报告 UVM_ERROR，并始终 disarm wrapper。
  task automatic check_event_db_model_factory_fault(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_data_engine_ordering_fault ordering,
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind,
    rdma_queue_poll_factory_fault_wrapper wrapper,
    string target_name,
    bit wrong_type
  );
    rdma_queue_event_result event_result;
    rdma_status status;
    int unsigned occupancy;
    int unsigned pcie_before;
    bit has_pending;
    bit fired;

    if (fixture == null || ordering == null || queue_h == null ||
        wrapper == null || !(kind inside {RDMA_QUEUE_RUNTIME_CEQ,
                                         RDMA_QUEUE_RUNTIME_AEQ})) begin
      `uvm_error(label, "event model fault fixture is incomplete")
      return;
    end
    ordering.trace.delete();
    ordering.doorbell_calls = 0;
    ordering.commit_calls = 0;
    ordering.release_calls = 0;
    pcie_before = count_pcie_calls(fixture.pcie, "mmio_write");
    wrapper.arm(target_name, wrong_type);
    event_result = null;
    if (kind == RDMA_QUEUE_RUNTIME_CEQ)
      fixture.engine.poll_ceqe(queue_h, 0, event_result, status);
    else
      fixture.engine.poll_aeqe(queue_h, 0, event_result, status);
    fired = wrapper.fired();
    wrapper.disarm();
    if (!fired || status == null ||
        status.code != RDMA_SC_RESOURCE_EXHAUSTED || event_result != null)
      `uvm_error(label, status == null ?
                 "event model fault returned null" : status.convert2string())
    if (ordering.trace.size() != 0 || ordering.doorbell_calls != 0 ||
        ordering.commit_calls != 0 || ordering.release_calls != 0 ||
        count_pcie_calls(fixture.pcie, "mmio_write") != pcie_before)
      `uvm_error({label, "_NO_SUBMIT"},
                 "event model fault crossed scheduler/local stages")
    occupancy = 0;
    has_pending = 1'b0;
    status = fixture.engine.query_runtime_occupancy(
      queue_h, kind, occupancy, has_pending);
    if (status == null || !status.ok() || occupancy != 1 || has_pending)
      `uvm_error({label, "_STATE"},
                 "event model fault changed used or installed pending")
  endtask

  // 功能：检查 ordering seam 在 event doorbell 入口观察到的 prepared pending
  //   是否已冻结完整 queue/cursor/image/status/route evidence，且没有 CQ release 阶段。
  // 输入/输出及副作用：label/ordering/queue_h/kind 为输入；只读测试子类保存的
  //   detached pending snapshot，不查询或修改当前 runtime。
  // 失败/边界：snapshot 缺失、identity/kind/geometry/route 不完整，MMIO 非 NONE，
  //   或任一 CQ 专用 completion marker 被置位时报告 UVM_ERROR。
  task automatic check_prepared_event_pending_snapshot(
    string label,
    rdma_queue_data_engine_ordering_fault ordering,
    rdma_handle queue_h,
    rdma_queue_runtime_kind_e kind
  );
    rdma_queue_pending_operation pending;

    if (ordering == null) begin
      `uvm_error(label, "ordering engine is null")
      return;
    end
    pending = ordering.prepared_pending_snapshot;
    if (!ordering.prepared_pending_visible || pending == null ||
        pending.queue_h == null || queue_h == null ||
        !pending.queue_h.same_instance(queue_h) || pending.kind != kind ||
        pending.producer || pending.device_producer ||
        pending.cursor == null || pending.next_cursor == null ||
        pending.image == null || pending.image.length != 16 ||
        pending.image.bytes.size() != 16 || pending.failure_status == null ||
        pending.entry_size != 16 || !pending.route_valid ||
        !pending.epoch_valid ||
        pending.mmio_evidence != RDMA_QUEUE_MMIO_NONE ||
        pending.consumer_doorbell_succeeded || pending.consumer_committed ||
        pending.cq_consumer_committed || pending.completion_target_valid ||
        pending.completion_released ||
        pending.committed_consumer_cursor != null)
      `uvm_error(label, "event pending was not complete before doorbell")
  endtask

  // 功能：验证 CEQ/AEQ 都在 scheduler 前完成 event result 与 pending admission，
  //   成功顺序严格为 doorbell→consumer commit，且从不触碰 CQ WQE release seam。
  // 输入/输出及副作用：无显式输入；建立 lifecycle event topology，各发布一条
  //   CEQE/AEQE，先注入 doorbell model 与 prepared result null/wrong-type，再正常
  //   poll 并统一清理。
  // 失败/边界：model/result factory 故障必须保持 event 可见且无 pending/seam；
  //   正常路径必须在 doorbell 入口观察完整 pending，release_calls 始终为 0。
  task automatic check_event_poll_prepared_admission();
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_data_engine_ordering_fault ordering;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_hw_ceqe_model ceqe;
    rdma_hw_aeqe_model aeqe;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status status;
    rdma_status model_status;
    int unsigned occupancy;
    bit has_pending;
    bit polarity;
    bit fired;
    bit lifecycle_ceq_created;
    bit lifecycle_ceq_attached;
    bit wrong_ceq_created;
    bit wrong_ceq_attached;
    bit lifecycle_aeq_created;
    bit lifecycle_aeq_attached;
    bit lifecycle_cq_created;
    bit lifecycle_cq_attached;
    bit event_qp_created;
    bit event_qp_attached;
    bit foreign_qp_created;
    bit foreign_qp_attached;

    reset_device_publish_factory_state();
    rdma_queue_data_engine::type_id::set_type_override(
      rdma_queue_data_engine_ordering_fault::get_type(), 1'b1);
    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, status);
    if (status == null || !status.ok() ||
        !$cast(ordering, fixture.engine) || ordering == null) begin
      `uvm_error("EVENT_PREPARED_SETUP", status == null ?
                 "event prepared setup returned null" : status.convert2string())
      cleanup_event_publish_topology(
        fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
        event_qp, foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
        wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
        lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
        event_qp_created, event_qp_attached, foreign_qp_created,
        foreign_qp_attached);
      return;
    end
    configure_poll_factory_faults();

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
    make_ceqe_from_committed_cq(
      fixture.engine, lifecycle_cq.handle, lifecycle_cq.local_cq_id, 0,
      polarity, ceqe, model_status);
    if (status == null || !status.ok() || model_status == null ||
        !model_status.ok() || ceqe == null) begin
      `uvm_error("CEQ_PREPARED_MODEL", "CEQE preparation failed")
    end else begin
      fixture.engine.publish_ceqe(
        lifecycle_ceq.handle, ceqe, published, status);
      if (status == null || !status.ok() || published == null) begin
        `uvm_error("CEQ_PREPARED_PUBLISH", "CEQE publish failed")
      end else begin
        check_event_db_model_factory_fault(
          "CEQ_DB_MODEL_NULL", fixture, ordering, lifecycle_ceq.handle,
          RDMA_QUEUE_RUNTIME_CEQ, poll_ceq_db_model_fault,
          "ceq_ci_db_model", 1'b0);
        check_event_db_model_factory_fault(
          "CEQ_DB_MODEL_WRONG", fixture, ordering, lifecycle_ceq.handle,
          RDMA_QUEUE_RUNTIME_CEQ, poll_ceq_db_model_fault,
          "ceq_ci_db_model", 1'b1);
        ordering.trace.delete();
        ordering.doorbell_calls = 0;
        ordering.commit_calls = 0;
        ordering.release_calls = 0;
        poll_event_result_fault.arm("prepared_event_result", 1'b0);
        event_result = null;
        fixture.engine.poll_ceqe(
          lifecycle_ceq.handle, 0, event_result, status);
        fired = poll_event_result_fault.fired();
        poll_event_result_fault.disarm();
        if (!fired || status == null ||
            status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
            event_result != null || ordering.trace.size() != 0)
          `uvm_error("CEQ_PREPARED_RESULT_NULL",
                     "CEQ result allocation was not side-effect-free")
        occupancy = 0;
        has_pending = 1'b0;
        status = fixture.engine.query_runtime_occupancy(
          lifecycle_ceq.handle, RDMA_QUEUE_RUNTIME_CEQ,
          occupancy, has_pending);
        if (status == null || !status.ok() || occupancy != 1 || has_pending)
          `uvm_error("CEQ_PREPARED_RESULT_STATE",
                     "CEQ result allocation changed credit/pending")

        ordering.trace.delete();
        ordering.doorbell_calls = 0;
        ordering.commit_calls = 0;
        ordering.release_calls = 0;
        ordering.prepared_pending_visible = 1'b0;
        ordering.prepared_pending_snapshot = null;
        fixture.engine.poll_ceqe(
          lifecycle_ceq.handle, 0, event_result, status);
        if (status == null || !status.ok() || event_result == null ||
            ordering.trace.size() != 2 || ordering.trace[0] != "doorbell" ||
            ordering.trace[1] != "commit" || ordering.release_calls != 0)
          `uvm_error("CEQ_PREPARED_ORDER", "CEQ did not commit after doorbell")
        check_prepared_event_pending_snapshot(
          "CEQ_PREPARED_PENDING", ordering, lifecycle_ceq.handle,
          RDMA_QUEUE_RUNTIME_CEQ);
      end
    end

    status = fixture.engine.query_runtime_producer_polarity(
      lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    aeqe = rdma_hw_aeqe_model::type_id::create("prepared_aeqe");
    if (status == null || !status.ok() || aeqe == null) begin
      `uvm_error("AEQ_PREPARED_MODEL", "AEQE preparation failed")
    end else begin
      model_status = clone_test_handle_value(event_qp.handle, aeqe.target_h);
      aeqe.qpn = event_qp.local_qp_id;
      aeqe.valid = polarity;
      aeqe.ecode = 0;
      aeqe.packet_opcode = 0;
      if (model_status == null || !model_status.ok() || aeqe.target_h == null) begin
        `uvm_error("AEQ_PREPARED_HANDLE", "AEQE target clone failed")
      end else begin
        fixture.engine.publish_aeqe(
          lifecycle_aeq.handle, aeqe, published, status);
        if (status == null || !status.ok() || published == null) begin
          `uvm_error("AEQ_PREPARED_PUBLISH", "AEQE publish failed")
        end else begin
          check_event_db_model_factory_fault(
            "AEQ_DB_MODEL_NULL", fixture, ordering, lifecycle_aeq.handle,
            RDMA_QUEUE_RUNTIME_AEQ, poll_aeq_db_model_fault,
            "aeq_ci_db_model", 1'b0);
          check_event_db_model_factory_fault(
            "AEQ_DB_MODEL_WRONG", fixture, ordering, lifecycle_aeq.handle,
            RDMA_QUEUE_RUNTIME_AEQ, poll_aeq_db_model_fault,
            "aeq_ci_db_model", 1'b1);
          ordering.trace.delete();
          ordering.doorbell_calls = 0;
          ordering.commit_calls = 0;
          ordering.release_calls = 0;
          poll_event_result_fault.arm("prepared_event_result", 1'b1);
          event_result = null;
          fixture.engine.poll_aeqe(
            lifecycle_aeq.handle, 0, event_result, status);
          fired = poll_event_result_fault.fired();
          poll_event_result_fault.disarm();
          if (!fired || status == null ||
              status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
              event_result != null || ordering.trace.size() != 0)
            `uvm_error("AEQ_PREPARED_RESULT_WRONG",
                       "AEQ result allocation was not side-effect-free")
          occupancy = 0;
          has_pending = 1'b0;
          status = fixture.engine.query_runtime_occupancy(
            lifecycle_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
            occupancy, has_pending);
          if (status == null || !status.ok() || occupancy != 1 || has_pending)
            `uvm_error("AEQ_PREPARED_RESULT_STATE",
                       "AEQ result allocation changed credit/pending")

          ordering.trace.delete();
          ordering.doorbell_calls = 0;
          ordering.commit_calls = 0;
          ordering.release_calls = 0;
          ordering.prepared_pending_visible = 1'b0;
          ordering.prepared_pending_snapshot = null;
          fixture.engine.poll_aeqe(
            lifecycle_aeq.handle, 0, event_result, status);
          if (status == null || !status.ok() || event_result == null ||
              ordering.trace.size() != 2 ||
              ordering.trace[0] != "doorbell" ||
              ordering.trace[1] != "commit" || ordering.release_calls != 0)
            `uvm_error("AEQ_PREPARED_ORDER", "AEQ did not commit after doorbell")
          check_prepared_event_pending_snapshot(
            "AEQ_PREPARED_PENDING", ordering, lifecycle_aeq.handle,
            RDMA_QUEUE_RUNTIME_AEQ);
        end
      end
    end

    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached);
  endtask

  // 功能：run_phase 依次 post_send、以 runtime 查询的 polarity publish CQE、读取
  //   真实 CQ backing，并两次 poll 验证 WQE release 和 occupancy 归零。
  // 输入/输出及副作用：phase 为输入；任务驱动 fixture 事务并报告 publish 前后
  //   occupancy/pending/cursor/image/Host-memory 证据，不直接写 CQ backing。
  // 失败边界：setup、post、polarity、publish、readback 或 poll 任一失败都会报告
  //   UVM_ERROR；第二次 poll 必须为 QUEUE_EMPTY 且 completion 为空。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_queue_post_result posted;
    rdma_post_send_req request;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_queue_completion_result completion;
    rdma_queue_pending_operation pending;
    rdma_status setup_status, status, model_status, poll_status;
    rdma_status pending_status, polarity_status;
    rdma_status occupancy_status;
    byte backing_bytes[];
    bit polarity;
    int unsigned pre_occupancy;
    int unsigned host_call_start;
    int unsigned pre_index;
    bit pre_wrap;
    int unsigned post_index;
    bit post_wrap;
    int unsigned consumer_index;
    bit consumer_wrap;
    bit occupancy_pending;
    longint unsigned backing_offset;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "device_publish_fixture");
    fixture.setup(setup_status);
    if (setup_status == null || !setup_status.ok()) begin
      `uvm_error("CQE_FIXTURE", "fixture setup failed")
      phase.drop_objection(this);
      return;
    end
    pre_occupancy = 0;
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != 0 || occupancy_pending) begin
      `uvm_error("CQE_PRE_OCCUPANCY", "empty CQ occupancy is not zero")
      phase.drop_objection(this);
      return;
    end
    pre_index = 0;
    pre_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_index, pre_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) begin
      `uvm_error("CQE_PRE_CURSOR", "runtime CQ cursor query failed")
      phase.drop_objection(this);
      return;
    end
    pending = null;
    pending_status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (pending != null || pending_status == null || pending_status.ok() ||
        pending_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_PRE_PENDING", "empty CQ unexpectedly has recovery pending")
    polarity = 1'b0;
    polarity_status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (polarity_status == null || !polarity_status.ok()) begin
      `uvm_error("CQE_POLARITY", "runtime producer polarity query failed")
      phase.drop_objection(this);
      return;
    end
    request = fixture.make_send(64'h100);
    fixture.engine.post_send(request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQE_POST", "send WQE post failed")
      phase.drop_objection(this);
      return;
    end
    cqe = make_cqe_for_outstanding_send(fixture.qp.handle,
      fixture.qp.local_qp_id, posted, polarity, model_status);
    if (model_status == null || !model_status.ok() || cqe == null) begin
      `uvm_error("CQE_MODEL", "CQE model construction failed")
      phase.drop_objection(this);
      return;
    end
    host_call_start = fixture.mem.calls.size();
    publish_cqe_for_test(fixture.engine, fixture.cq.handle, cqe,
                         published, status);
    if (status == null || !status.ok() || published == null ||
        published.status == null || !published.status.ok() ||
        published.queue_h == null ||
        !published.queue_h.same_instance(fixture.cq.handle) ||
        published.index != pre_index || published.wrap != pre_wrap ||
        published.image == null || !published.occupancy_valid ||
        published.occupancy != pre_occupancy + 1) begin
      `uvm_error("CQE_PUBLISH", "device CQE publish result/cursor/occupancy is wrong")
      phase.drop_objection(this);
      return;
    end
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != published.occupancy || occupancy_pending)
      `uvm_error("CQE_POST_OCCUPANCY", "runtime occupancy differs from publish result")
    post_index = 0;
    post_wrap = 1'b0;
    consumer_index = 0;
    consumer_wrap = 1'b0;
    status = fixture.engine.query_runtime_cursors(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, post_index, post_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok() ||
        (post_index == pre_index && post_wrap == pre_wrap))
      `uvm_error("CQE_POST_CURSOR", "publish did not advance runtime producer cursor")
    backing_offset = longint'(published.index) *
      longint'(published.image.length);
    check_device_publish_calls(fixture.mem, host_call_start,
                               backing_offset, published.image);
    status = fixture.read_cq_entry(published.index, published.image.length,
                                   backing_bytes);
    if (status == null || !status.ok() ||
        backing_bytes.size() != published.image.bytes.size())
      `uvm_error("CQE_BACKING", "cannot read real CQ backing after publish")
    else foreach (backing_bytes[i]) begin
      if (backing_bytes[i] !== published.image.bytes[i])
        `uvm_error("CQE_BACKING", $sformatf("CQ backing byte %0d differs", i))
    end
    pending = null;
    pending_status = fixture.engine.query_runtime_pending(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pending);
    if (pending != null || pending_status == null || pending_status.ok() ||
        pending_status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQE_POST_PENDING", "committed CQE retained recovery pending")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, poll_status);
    if (poll_status == null || !poll_status.ok() || completion == null ||
        completion.released_slots.size() != 1)
      `uvm_error("CQE_CHAIN", "published CQE did not release one WQE")
    occupancy_pending = 1'b1;
    occupancy_status = fixture.engine.query_runtime_occupancy(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, pre_occupancy,
      occupancy_pending);
    if (occupancy_status == null || !occupancy_status.ok() ||
        pre_occupancy != 0 || occupancy_pending)
      `uvm_error("CQE_POLL_OCCUPANCY", "poll did not return CQ occupancy to zero")
    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, poll_status);
    if (poll_status == null || poll_status.code != RDMA_SC_QUEUE_EMPTY ||
        completion != null)
      `uvm_error("CQE_EMPTY", "second CQE poll did not prove occupancy is zero")
    reset_device_publish_factory_state();
    check_unclaimed_pending_kind_authority();
    reset_device_publish_factory_state();
    check_unclaimed_pending_abort();
    reset_device_publish_factory_state();
    check_claimed_abort_detach_failure_atomicity();
    reset_device_publish_factory_state();
    check_segmented_cq_plan_ownership();
    reset_device_publish_factory_state();
    check_lifecycle_owned_cq_permission_failure();
    reset_device_publish_factory_state();
    check_device_publish_preflight_failure();
    reset_device_publish_factory_state();
    check_device_publish_cancel_failure();
    reset_device_publish_factory_state();
    check_device_publish_fault_recovery("CQE_WRITE_FAIL", 0);
    reset_device_publish_factory_state();
    check_device_publish_fault_recovery("CQE_READ_FAIL", 1);
    reset_device_publish_factory_state();
    check_device_publish_fault_recovery("CQE_READ_MISMATCH", 2);
    reset_device_publish_factory_state();
    check_device_publish_retry_chain();
    reset_device_publish_factory_state();
    check_device_publish_stale_route();
    reset_device_publish_factory_state();
    check_snapshot_release_range_factory_atomicity();
    reset_device_publish_factory_state();
    check_cq_poll_post_scheduler_allocation_guard();
    reset_device_publish_factory_state();
    check_cq_consumer_codec_preparation_failures();
    reset_device_publish_factory_state();
    check_cq_poll_prepared_factory_failures();
    reset_device_publish_factory_state();
    check_cq_poll_commit_before_release_order();
    reset_device_publish_factory_state();
    check_cq_poll_commit_failure_is_recoverable();
    reset_device_publish_factory_state();
    check_cq_poll_release_failure_is_idempotent();
    reset_device_publish_factory_state();
    check_cq_poll_release_gate_blocks_wq_mutation();
    reset_device_publish_factory_state();
    check_cq_poll_no_submit_requires_confirmation();
    reset_device_publish_factory_state();
    check_cq_poll_ambiguous_never_resends();
    reset_device_publish_factory_state();
    check_cq_poll_null_seam_statuses();
    reset_device_publish_factory_state();
    check_cq_poll_unknown_evidence_fails_closed();
    reset_device_publish_factory_state();
    check_cqe_authority_rejections();
    reset_device_publish_factory_state();
    check_cqe_full_atomic();
    reset_device_publish_factory_state();
    check_event_poll_prepared_admission();
    reset_device_publish_factory_state();
    check_event_publish_api();
    reset_device_publish_factory_state();
    check_ceqe_runtime_width();
    reset_device_publish_factory_state();
    check_cqe_authority_width();
    reset_device_publish_factory_state();
    phase.drop_objection(this);
  endtask
endclass
