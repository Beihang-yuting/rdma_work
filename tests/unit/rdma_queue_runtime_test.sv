// 目录/层次：tests/unit，rdma_core_pkg 内 queue runtime 的纯状态机单元测试。
// 文件职责：覆盖 host/device producer 方向隔离、depth/wrap/credit、consumer
// commit、route/reset-epoch authority、quiesce/resize、recovery 阶段与非致命 factory 故障。
// 主要依赖：UVM test/factory、rdma_types_pkg/model_pkg/core_pkg；不连接真实
// Host-memory、PCIe scheduler 或网络后端，VCS 仿真仍必须在指定 simulation host 执行。
// 所有权/生命周期：每个 task 拥有其 runtime、handle、cursor、image 与 pending
// fixture；factory fault wrapper 持有原 registry 的非拥有引用，并在每个注入窗口后 disarm。

// 设计说明：该载体只用于证明 raw factory 返回了不兼容类型；它不模拟
// 任何 RDMA 业务值，避免错误类型恰好满足被测接口。
class rdma_queue_runtime_wrong_factory_object extends uvm_object;
  `uvm_object_utils(rdma_queue_runtime_wrong_factory_object)

  // 功能：构造无 RDMA 字段的 UVM 对象，作为 factory 错误类型载体。
  // 输入输出及副作用：name（输入）仅传给 uvm_object；不登记 RDMA 资源。
  // 失败边界：对象可被创建，但必须无法 cast 成任一被测 RDMA 类型。
  function new(string name = "rdma_queue_runtime_wrong_factory_object");
    super.new(name);
  endfunction
endclass

// 设计说明：UVM registry::create() 会将 null/错误类型升级为 FCTTYP fatal，
// 因此测试用可 disarm 的 raw wrapper 注入这两类结果。未 arm 时它直接
// 委托原 wrapper，使持久 type override 不影响后续场景。
class rdma_queue_runtime_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;
  protected bit wrong_type_state;

  // 功能：保存被覆盖类型的原 factory wrapper，并以 disarmed 状态启动。
  // 输入输出及副作用：name/delegate_value（输入）被保存为非拥有引用；无输出。
  // 失败边界：delegate_value 为 null 时 disarmed create 也只返回 null，不触发 fatal。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction

  // 功能：为当前故障窗口返回 null 或不兼容的 UVM 对象。
  // 输入输出及副作用：name（输入）传给 delegate/错误载体；返回工厂对象。
  // 失败边界：armed 且 wrong_type_state=0 返回 null；为 1 返回错误类型；
  // disarmed 但 delegate 缺失时保守返回 null。
  virtual function uvm_object create_object(string name = "");
    rdma_queue_runtime_wrong_factory_object wrong_object;

    if (!armed_state) begin
      if (delegate == null) return null;
      return delegate.create_object(name);
    end
    if (!wrong_type_state) return null;
    wrong_object = new(name);
    return wrong_object;
  endfunction

  // 功能：返回该故障 wrapper 的唯一测试类型名，供 UVM factory 记录 override。
  // 输入输出及副作用：无输入；返回 wrapper_type_name，不修改注册表。
  // 失败边界：名称只用于测试识别，不作为 RDMA 类型 authority。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：开启持续到 disarm 的 factory 故障窗口。
  // 输入输出及副作用：wrong_type（输入）选择 null 或错误类型；更新本 wrapper。
  // 失败边界：重复 arm 只覆盖模式，不更换 delegate 或创建对象。
  function void arm(bit wrong_type);
    armed_state = 1'b1;
    wrong_type_state = wrong_type;
  endfunction

  // 功能：关闭故障注入，恢复对原 wrapper 的直接委托。
  // 输入输出及副作用：无输入输出；清除 armed_state/wrong_type_state。
  // 失败边界：disarm 幂等；不删除 UVM type override，不影响已创建对象。
  function void disarm();
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction
endclass

// 设计说明：public recovery 转移会在进入 QUIESCING 前消费 retry confirmation，
// 因而 copy gate 的防御式不变量需要受限 test-only 子类注入该单一 protected bit；
// 被测 copy_ring_state 仍是生产实现，测试不改写 pending、游标或锁。
class rdma_queue_runtime_retry_authority_probe extends rdma_queue_runtime;
  `uvm_object_utils(rdma_queue_runtime_retry_authority_probe)

  // 功能：构造未配置的 runtime probe，仅复用生产状态机并开放 retry bit 注入。
  // 输入输出及副作用：name 为对象名；调用基类构造，不配置 queue/route 或状态。
  // 失败边界：未完成 configure 的 probe 与生产 runtime 一样拒绝业务入口。
  function new(string name = "rdma_queue_runtime_retry_authority_probe");
    super.new(name);
  endfunction

  // 功能：set_retry_confirmation_for_test 精确设置 copy gate 应拒绝的一次性恢复授权。
  // 输入输出及副作用：value 为输入；仅修改 recovery_retry_confirmed，不触碰
  //   pending、reservation、cursor、ledger、state 或 semaphore。
  // 失败边界：该 helper 仅供本文件在 QUIESCING source/空 ATTACHED target 上构造
  //   public transition 当前不可达的不一致状态，禁止用于正向 runtime 行为测试。
  function void set_retry_confirmation_for_test(bit value);
    recovery_retry_confirmed = value;
  endfunction
endclass

// 设计说明：测试只通过 runtime 公开查询和事务入口观察状态，
// 不直接读写 reservation、pending、occupancy 或 PI/CI 内部字段。
class rdma_queue_runtime_test extends uvm_test;
  `uvm_component_utils(rdma_queue_runtime_test)

  protected rdma_queue_runtime_factory_fault_wrapper handle_fault;
  protected rdma_queue_runtime_factory_fault_wrapper cursor_fault;
  protected rdma_queue_runtime_factory_fault_wrapper image_fault;
  protected rdma_queue_runtime_factory_fault_wrapper status_fault;
  protected rdma_queue_runtime_factory_fault_wrapper request_fault;
  protected rdma_queue_runtime_factory_fault_wrapper pending_fault;

  // 功能：构造 runtime 单测 component，建立 UVM 层级；具体 fixture 留给各 task。
  // 输入输出及副作用：name/parent（输入）传给 uvm_test；不创建 runtime、
  //   不安装 factory override，也不 raise objection。
  // 失败边界：parent 可为 null；factory wrapper 必须等 run_phase 显式配置后使用。
  function new(string name = "rdma_queue_runtime_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：为 runtime 内部六类值副本与 pending 外壳安装可 disarm 的 raw
  //   factory wrapper，使单测可非致命地注入 null 和错误类型。
  // 输入输出及副作用：无显式参数；更新六个 wrapper 字段并在全局
  //   UVM factory 安装 type override，每个 wrapper 默认委托原 registry。
  // 失败边界：本 helper 必须在首次被测创建之前只调用一次；重复安装
  //   会把 delegate 指向旧故障 wrapper，因此 run_phase 不重复调用。
  function automatic void configure_factory_faults();
    uvm_factory factory;

    factory = uvm_factory::get();
    handle_fault = new("runtime_handle_fault", rdma_handle::get_type());
    cursor_fault = new("runtime_cursor_fault",
                       rdma_queue_cursor_snapshot::get_type());
    image_fault = new("runtime_image_fault", rdma_hw_image::get_type());
    status_fault = new("runtime_status_fault", rdma_status::get_type());
    request_fault = new("runtime_request_fault",
                        rdma_post_send_req::get_type());
    pending_fault = new("runtime_pending_fault",
                        rdma_queue_pending_operation::get_type());
    factory.set_type_override_by_type(rdma_handle::get_type(),
                                      handle_fault, 1'b1);
    factory.set_type_override_by_type(rdma_queue_cursor_snapshot::get_type(),
                                      cursor_fault, 1'b1);
    factory.set_type_override_by_type(rdma_hw_image::get_type(),
                                      image_fault, 1'b1);
    factory.set_type_override_by_type(rdma_status::get_type(),
                                      status_fault, 1'b1);
    factory.set_type_override_by_type(rdma_post_send_req::get_type(),
                                      request_fault, 1'b1);
    factory.set_type_override_by_type(rdma_queue_pending_operation::get_type(),
                                      pending_fault, 1'b1);
  endfunction

  // 功能：关闭全部 factory 故障窗口，使后续正向场景继续委托原类型。
  // 输入输出及副作用：无显式参数；只清除六个 wrapper 的 arm 状态。
  // 失败边界：任一 wrapper 未初始化时跳过它；调用幂等且不移除 type override。
  function automatic void disarm_factory_faults();
    if (handle_fault != null) handle_fault.disarm();
    if (cursor_fault != null) cursor_fault.disarm();
    if (image_fault != null) image_fault.disarm();
    if (status_fault != null) status_fault.disarm();
    if (request_fault != null) request_fault.disarm();
    if (pending_fault != null) pending_fault.disarm();
  endfunction

  // 功能：queue_handle 构造固定 Function UID/generation、由调用方指定 kind/
  //   object_id 的 queue identity fixture。
  // 输入输出及副作用：name/kind/object_id（输入）；返回调用 task 拥有的
  //   rdma_handle，不登记 lifecycle resource 或修改 runtime。
  // 失败边界：该 helper 仅在 handle factory disarm 时调用；factory 返回 null 会
  //   使 fixture 无法建立，故障注入路径应直接调用被测 non-fatal clone 接口。
  function automatic rdma_handle queue_handle(
    string name,
    rdma_resource_kind_e kind,
    int unsigned object_id
  );
    rdma_handle result;
    result = rdma_handle::type_id::create(name);
    result.kind = kind;
    result.function_uid = 64'h1234;
    result.object_id = object_id;
    result.generation = 5;
    return result;
  endfunction

  // 功能：fixture_route 根据 seed 构造 route.segment 与 bdf.segment 一致、且 BDF 非零的测试路由 authority。
  // 输入/输出及副作用：seed（输入）决定 host/root/bus 值；返回独立 rdma_route_key_t packed 值，不修改 runtime 或共享 fixture。
  // 失败/边界：任意 seed 都通过固定非零 device/function_num 保持 BDF 有效；该 helper 不模拟 route lookup 失败。
  function automatic rdma_route_key_t fixture_route(bit [7:0] seed);
    rdma_route_key_t route;
    route.host_topology_key = 32'h4000 + seed;
    route.root_id = 16'h40 + seed;
    route.segment = 16'h2;
    route.bdf.segment = route.segment;
    route.bdf.bus = 8'h20 + seed;
    route.bdf.device = 5'h3;
    route.bdf.function_num = 3'h1;
    return route;
  endfunction

  // 功能：make_consumer_recovery_fixture 构造一个已有单条 committed entry 的
  //   CQ runtime，并生成指向当前 CI 的完整 detached consumer recovery evidence。
  // 输入/输出及副作用：name/object_id/seed/evidence（输入）决定对象身份和初始
  //   MMIO 证据；runtime/pending（输出）由调用方持有，helper 会真实执行一次 device
  //   producer reserve/commit 以建立 occupancy=1。
  // 失败/边界：任一 factory/configure/authority/commit 步骤失败时返回原始非成功
  //   status，输出可能仅含已完成的局部 fixture，调用方必须停止依赖后续对象。
  function automatic rdma_status make_consumer_recovery_fixture(
    string name,
    int unsigned object_id,
    bit [7:0] seed,
    rdma_queue_mmio_evidence_e evidence,
    output rdma_queue_runtime runtime,
    output rdma_queue_pending_operation pending
  );
    rdma_handle cq_h;
    rdma_queue_cursor_snapshot producer;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    rdma_status status;

    runtime = null;
    pending = null;
    cq_h = queue_handle({name, "_handle"}, RDMA_RESOURCE_CQ, object_id);
    route = fixture_route(seed);
    epoch = rdma_reset_epoch_t'(64'h200 + seed);
    runtime = rdma_queue_runtime::type_id::create({name, "_runtime"});
    if (runtime == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "consumer runtime allocation failed");
    status = runtime.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 4,
                               0, 1'b0, 0, 1'b0, 1'b0);
    if (status == null || !status.ok()) return status;
    status = runtime.set_route_epoch(route, epoch);
    if (status == null || !status.ok()) return status;
    status = runtime.activate();
    if (status == null || !status.ok()) return status;
    status = runtime.reserve_device_producer(producer);
    if (status == null || !status.ok() || producer == null) return status;
    status = runtime.commit_device_producer(producer);
    if (status == null || !status.ok()) return status;

    pending = rdma_queue_pending_operation::type_id::create(
      {name, "_pending"});
    if (pending == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "consumer pending allocation failed");
    pending.queue_h = queue_handle({name, "_pending_handle"},
                                   RDMA_RESOURCE_CQ, object_id);
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.producer = 1'b0;
    pending.device_producer = 1'b0;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      {name, "_cursor"});
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      {name, "_next"});
    pending.image = rdma_hw_image::type_id::create({name, "_image"});
    pending.failure_status = rdma_status::make(
      RDMA_SC_PCIE_COMPLETION, "injected consumer doorbell failure");
    if (pending.queue_h == null || pending.cursor == null ||
        pending.next_cursor == null || pending.image == null ||
        pending.failure_status == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "consumer evidence allocation failed");
    pending.cursor.index = 0;
    pending.cursor.wrap = 1'b0;
    pending.next_cursor.index = 1;
    pending.next_cursor.wrap = 1'b0;
    pending.entry_size = 64;
    pending.entry_offset = 0;
    pending.image.length = pending.entry_size;
    pending.image.alignment = pending.entry_size;
    pending.image.endian = RDMA_ENDIAN_BIG;
    pending.image.image_kind = RDMA_IMAGE_CQE;
    pending.image.hardware_version = RDMA_HW_VERSION;
    pending.image.function_generation = 5;
    for (int unsigned i = 0; i < pending.entry_size; i++)
      pending.image.bytes.push_back(byte'(8'h80 + i));
    pending.mmio_evidence = evidence;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：expect_ok 断言被测入口返回非 null 且 code=RDMA_SC_OK。
  // 输入输出及副作用：label/status（输入）；失败时产生带 status 文本的
  //   UVM_ERROR，不修改 status 或任何 DUT 状态。
  // 失败边界：status=null 作为独立契约错误报告；helper 不终止 task，调用方在
  //   后续解引用前仍需显式 return。
  function automatic void expect_ok(string label, rdma_status status);
    if (status == null || !status.ok())
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：expect_code 断言被测拒绝路径返回指定 rdma_status_code_e。
  // 输入输出及副作用：label/status/code（输入）；不修改输入，失配时产生包含
  //   实际 status 的 UVM_ERROR。
  // 失败边界：status=null 必须失败；helper 不检查额外消息文本，也不停止调用 task。
  function automatic void expect_code(
    string label,
    rdma_status status,
    rdma_status_code_e code
  );
    if (status == null || status.code != code)
      `uvm_error(label, status == null ? "null status" :
                 status.convert2string())
  endfunction

  // 功能：验证 runtime attachment 配置只经带锁值查询公开，并且 queue handle
  //   返回 detached snapshot，caller 修改查询结果不能伪造内部 identity authority。
  // 输入/输出及副作用：无显式参数；配置一个 device CQ runtime，两次调用
  //   query_attachment_config，并在两次查询之间修改第一次返回的 handle generation。
  // 失败/边界：未配置/clone 失败必须返回非成功且输出安全清零；成功查询应保持
  //   kind=CQ、host_produced=0、initial_polarity=1，第二次 identity 不受篡改影响。
  task automatic test_attachment_config_query_is_detached();
    rdma_queue_runtime runtime;
    rdma_handle configured_h;
    rdma_handle first_h;
    rdma_handle second_h;
    rdma_queue_runtime_kind_e runtime_kind;
    rdma_status status;
    bit host_direction;
    bit initial_owner_polarity;

    runtime = rdma_queue_runtime::type_id::create(
      "attachment_config_runtime");
    configured_h = queue_handle(
      "attachment_config_cq", RDMA_RESOURCE_CQ, 44);
    if (runtime == null || configured_h == null) begin
      `uvm_error("ATTACHMENT_CONFIG_FIXTURE", "fixture allocation failed")
      return;
    end
    status = runtime.configure(
      configured_h, RDMA_QUEUE_RUNTIME_CQ, 4,
      0, 1'b0, 0, 1'b0, 1'b0, 1'b1);
    expect_ok("ATTACHMENT_CONFIG_CONFIGURE", status);
    if (status == null || !status.ok()) return;

    status = runtime.query_attachment_config(
      first_h, runtime_kind, host_direction, initial_owner_polarity);
    expect_ok("ATTACHMENT_CONFIG_QUERY_FIRST", status);
    if (status == null || !status.ok() || first_h == null) return;
    if (first_h == configured_h || runtime_kind != RDMA_QUEUE_RUNTIME_CQ ||
        host_direction || !initial_owner_polarity ||
        !first_h.same_instance(configured_h))
      `uvm_error("ATTACHMENT_CONFIG_QUERY_FIRST",
                 "query did not return detached configuration values")

    first_h.generation++;
    second_h = null;
    runtime_kind = RDMA_QUEUE_RUNTIME_SQ;
    host_direction = 1'b1;
    initial_owner_polarity = 1'b0;
    status = runtime.query_attachment_config(
      second_h, runtime_kind, host_direction, initial_owner_polarity);
    expect_ok("ATTACHMENT_CONFIG_QUERY_SECOND", status);
    if (status == null || !status.ok() || second_h == null ||
        second_h == first_h || !second_h.same_instance(configured_h) ||
        runtime_kind != RDMA_QUEUE_RUNTIME_CQ || host_direction ||
        !initial_owner_polarity)
      `uvm_error("ATTACHMENT_CONFIG_DETACHED",
                 "caller mutation changed runtime attachment authority")
  endtask

  // 功能：验证 activate 只执行 ATTACHED->ACTIVE 状态迁移，无 route/epoch 时
  //   publish authority 查询、prepared recovery 和 resize-copy 仍分别 fail-closed。
  // 输入输出及副作用：无显式参数；构造 source/target CQ runtime 与一份完整但
  //   缺 route/epoch 的 consumer pending，通过公开状态/query/copy 接口观察结果。
  // 失败边界：configure 后 activate 必须成功；缺 authority 的 query/pending/copy
  //   必须拒绝且 output 归零、source 不进入 recovery、target 保持 ATTACHED。
  task automatic test_activate_without_authority_preserves_boundaries();
    rdma_queue_runtime runtime;
    rdma_queue_runtime copy_target;
    rdma_queue_pending_operation pending;
    rdma_queue_runtime_state_e runtime_state;
    rdma_handle cq_h;
    rdma_route_key_t route_snapshot;
    rdma_reset_epoch_t epoch_snapshot;
    bit route_snapshot_valid;
    bit epoch_snapshot_valid;
    rdma_status status;

    runtime = rdma_queue_runtime::type_id::create("authority_gate_runtime");
    if (runtime == null) begin
      `uvm_error("ACTIVATE_AUTHORITY_FIXTURE", "runtime allocation failed")
      return;
    end
    cq_h = queue_handle("authority_gate_cq", RDMA_RESOURCE_CQ, 41);
    if (cq_h == null) begin
      `uvm_error("ACTIVATE_AUTHORITY_FIXTURE", "queue handle allocation failed")
      return;
    end
    status = runtime.configure(
      cq_h,
      RDMA_QUEUE_RUNTIME_CQ, 2, 0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("ACTIVATE_AUTHORITY_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = runtime.activate();
    expect_ok("ACTIVATE_WITHOUT_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    expect_ok("ACTIVATE_AUTHORITY_STATE", runtime.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      `uvm_error("ACTIVATE_AUTHORITY_STATE",
                 "activation without authority did not publish ACTIVE")
      return;
    end

    route_snapshot = '1;
    route_snapshot_valid = 1'b1;
    epoch_snapshot = '1;
    epoch_snapshot_valid = 1'b1;
    status = runtime.query_route_epoch(
      route_snapshot, route_snapshot_valid, epoch_snapshot,
      epoch_snapshot_valid);
    expect_code("PUBLISH_AUTHORITY_REQUIRED", status,
                RDMA_SC_INVALID_STATE);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        route_snapshot != '0 || route_snapshot_valid || epoch_snapshot != '0 ||
        epoch_snapshot_valid) begin
      `uvm_error("PUBLISH_AUTHORITY_DEFAULTS",
                 "missing publish authority leaked non-default outputs")
      return;
    end

    pending = rdma_queue_pending_operation::type_id::create(
      "authority_gate_pending");
    if (pending == null) begin
      `uvm_error("ACTIVATE_AUTHORITY_FIXTURE", "pending allocation failed")
      return;
    end
    pending.queue_h = queue_handle(
      "authority_gate_pending_cq", RDMA_RESOURCE_CQ, 41);
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "authority_gate_cursor");
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "authority_gate_next");
    pending.image = rdma_hw_image::type_id::create("authority_gate_image");
    pending.failure_status = rdma_status::make(
      RDMA_SC_PCIE_COMPLETION, "injected missing-authority recovery");
    if (pending.queue_h == null || pending.cursor == null ||
        pending.next_cursor == null || pending.image == null ||
        pending.failure_status == null) begin
      `uvm_error("ACTIVATE_AUTHORITY_FIXTURE",
                 "prepared evidence allocation failed")
      return;
    end
    pending.cursor.index = 0;
    pending.cursor.wrap = 1'b0;
    pending.next_cursor.index = 1;
    pending.next_cursor.wrap = 1'b0;
    pending.entry_size = 64;
    pending.entry_offset = 0;
    pending.image.length = pending.entry_size;
    pending.image.alignment = pending.entry_size;
    pending.image.endian = RDMA_ENDIAN_BIG;
    pending.image.image_kind = RDMA_IMAGE_CQE;
    pending.image.hardware_version = RDMA_HW_VERSION;
    for (int unsigned i = 0; i < pending.entry_size; i++)
      pending.image.bytes.push_back(byte'(i));
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    pending.route = '0;
    pending.route_valid = 1'b0;
    pending.reset_epoch = '0;
    pending.epoch_valid = 1'b0;
    expect_code("PREPARED_AUTHORITY_REQUIRED",
                runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("PREPARED_AUTHORITY_STATE",
              runtime.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      `uvm_error("PREPARED_AUTHORITY_ATOMIC",
                 "rejected prepared recovery changed source state")
      return;
    end

    expect_ok("COPY_AUTHORITY_QUIESCE", runtime.begin_quiesce());
    copy_target = rdma_queue_runtime::type_id::create(
      "authority_gate_copy_target");
    if (copy_target == null) begin
      `uvm_error("ACTIVATE_AUTHORITY_FIXTURE", "copy target allocation failed")
      return;
    end
    status = copy_target.configure(
      queue_handle("authority_gate_copy_cq", RDMA_RESOURCE_CQ, 41),
      RDMA_QUEUE_RUNTIME_CQ, 2, 0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_AUTHORITY_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    expect_code("COPY_AUTHORITY_REQUIRED",
                copy_target.copy_ring_state(runtime),
                RDMA_SC_INVALID_STATE);
    expect_ok("COPY_AUTHORITY_TARGET_STATE",
              copy_target.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ATTACHED)
      `uvm_error("COPY_AUTHORITY_ATOMIC",
                 "rejected authority copy changed target state")
  endtask

  // 功能：验证 device-produced CQ runtime 的 reservation、commit 与 consumer 可见性边界，并确认 host/device producer API 方向隔离。
  // 输入/输出及副作用：在本地构造 CQ 与 SQ runtime，调用 configure/activate/reserve/commit/query 接口并产生 UVM 断言；不接管外部句柄所有权。
  // 失败/边界：若配置、激活或 reservation 前置步骤失败则提前返回；未提交 reservation 必须保持 occupancy 为零且 peek 返回 RDMA_SC_QUEUE_EMPTY，方向错误必须返回 RDMA_SC_INVALID_STATE。
  task automatic test_device_ring_reserve_commit_and_visibility();
    rdma_queue_runtime runtime;
    rdma_queue_runtime host_runtime;
    rdma_queue_cursor_snapshot reservation, consumer;
    rdma_status status;
    int unsigned occupancy;

    runtime = rdma_queue_runtime::type_id::create("device_runtime");
    status = runtime.configure(queue_handle("cq", RDMA_RESOURCE_CQ, 7),
                               RDMA_QUEUE_RUNTIME_CQ, 2, 0, 1'b0,
                               0, 1'b0, 1'b0);
    expect_ok("DEVICE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = runtime.set_route_epoch(
      fixture_route(8'h07), rdma_reset_epoch_t'(64'h307));
    expect_ok("DEVICE_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = runtime.activate();
    expect_ok("DEVICE_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = runtime.reserve_device_producer(reservation);
    expect_ok("DEVICE_RESERVE", status);
    if (status == null || !status.ok() || reservation == null) return;
    status = runtime.query_occupancy(occupancy);
    if (status == null || occupancy != 0)
      `uvm_error("DEVICE_OCCUPANCY", "reservation changed committed occupancy")
    status = runtime.peek_consumer(consumer);
    if (status == null || status.code != RDMA_SC_QUEUE_EMPTY || consumer != null)
      `uvm_error("DEVICE_VISIBILITY", "uncommitted slot became visible")
    expect_ok("DEVICE_COMMIT", runtime.commit_device_producer(reservation));
    status = runtime.query_occupancy(occupancy);
    if (status == null || occupancy != 1)
      `uvm_error("DEVICE_OCCUPANCY", "committed occupancy is incorrect")

    host_runtime = rdma_queue_runtime::type_id::create("host_runtime");
    expect_ok("HOST_CONFIGURE", host_runtime.configure(
      queue_handle("sq", RDMA_RESOURCE_QP, 9), RDMA_QUEUE_RUNTIME_SQ,
      2, 0, 1'b0, 0, 1'b0, 1'b1));
    status = host_runtime.set_route_epoch(
      fixture_route(8'h09), rdma_reset_epoch_t'(64'h309));
    expect_ok("HOST_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = host_runtime.activate();
    expect_ok("HOST_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    expect_code("HOST_DEVICE_RESERVE",
                host_runtime.reserve_device_producer(reservation),
                RDMA_SC_INVALID_STATE);
    expect_code("DEVICE_HOST_RESERVE",
                runtime.reserve_producer(reservation),
                RDMA_SC_INVALID_STATE);
  endtask

  // 功能：验证 device ring 的 consumer credit、重复 reservation、recovery pending 与 abort 隔离。
  // 输入/输出及副作用：构造 AEQ runtime 与 detached pending，调用 producer/consumer/recovery 接口并产生 UVM 断言；fixture 句柄仍由测试持有。
  // 失败/边界：任一前置配置失败即返回；空 ring 的 consumer commit、重复 reservation、stale producer commit 和 pending quiesce 必须拒绝且不改变账本。
  task automatic test_device_consumer_credit_and_recovery();
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot producer, duplicate, consumer, current_empty;
    rdma_queue_cursor_snapshot stale, remaining;
    rdma_queue_pending_operation pending;
    rdma_status status;
    int unsigned occupancy;
    bit reservation_valid;
    rdma_queue_runtime_state_e runtime_state;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;

    runtime = rdma_queue_runtime::type_id::create("device_credit_runtime");
    route = fixture_route(8'h08);
    epoch = rdma_reset_epoch_t'(64'h108);
    expect_ok("CREDIT_CONFIGURE", runtime.configure(
      queue_handle("aeq", RDMA_RESOURCE_AEQ, 8), RDMA_QUEUE_RUNTIME_AEQ,
      4, 0, 1'b0, 0, 1'b0, 1'b0));
    expect_ok("CREDIT_ROUTE_EPOCH", runtime.set_route_epoch(route, epoch));
    expect_ok("CREDIT_ACTIVATE", runtime.activate());
    expect_ok("CREDIT_RESERVE", runtime.reserve_device_producer(producer));
    expect_code("CREDIT_DUPLICATE_RESERVE",
                runtime.reserve_device_producer(duplicate), RDMA_SC_RESOURCE_BUSY);
    if (duplicate != null) `uvm_error("CREDIT_DUPLICATE_RESERVE", "output was published")
    expect_ok("CREDIT_COMMIT", runtime.commit_device_producer(producer));
    expect_ok("CREDIT_PEEK", runtime.peek_consumer(consumer));
    expect_ok("CREDIT_CONSUMER_COMMIT", runtime.commit_consumer(consumer));
    expect_ok("CREDIT_QUERY", runtime.query_occupancy(occupancy));
    if (occupancy != 0) `uvm_error("CREDIT_QUERY", "consumer did not release credit")
    // consumer snapshot 已在前一次 commit 后变为 stale；空 ring 的 CI
    // 提交必须 fail-closed，不能把旧快照当成新的 credit 释放请求。
    expect_code("CREDIT_EMPTY_COMMIT", runtime.commit_consumer(consumer),
                RDMA_SC_INVALID_STATE);
    current_empty = rdma_queue_cursor_snapshot::type_id::create(
      "current_empty_consumer");
    if (current_empty == null) begin
      `uvm_error("CREDIT_EMPTY_CURRENT", "cursor allocation failed")
      return;
    end
    current_empty.index = consumer.index + 1;
    current_empty.wrap = consumer.wrap;
    if (current_empty.index >= 4) begin
      current_empty.index = 0;
      current_empty.wrap = ~current_empty.wrap;
    end
    expect_code("CREDIT_EMPTY_CURRENT",
                runtime.commit_consumer(current_empty),
                RDMA_SC_INVALID_STATE);

    expect_ok("RECOVERY_RESERVE", runtime.reserve_device_producer(producer));
    pending = rdma_queue_pending_operation::type_id::create("device_pending_test");
    pending.queue_h = queue_handle("aeq", RDMA_RESOURCE_AEQ, 8);
    pending.kind = RDMA_QUEUE_RUNTIME_AEQ;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = 1'b1;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_next");
    pending.next_cursor.index = producer.index + 1;
    pending.next_cursor.wrap = producer.wrap;
    if (pending.next_cursor.index >= 4) begin
      pending.next_cursor.index = 0;
      pending.next_cursor.wrap = ~pending.next_cursor.wrap;
    end
    pending.entry_size = 16;
    pending.entry_offset = producer.index * pending.entry_size;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "device_pending_cursor");
    pending.cursor.index = producer.index;
    pending.cursor.wrap = producer.wrap;
    pending.image = rdma_hw_image::type_id::create("device_pending_image");
    pending.image.length = pending.entry_size;
    pending.image.alignment = pending.entry_size;
    pending.image.endian = RDMA_ENDIAN_BIG;
    pending.image.image_kind = RDMA_IMAGE_AEQE;
    pending.image.hardware_version = RDMA_HW_VERSION;
    pending.image.function_generation = 5;
    for (int image_index = 0; image_index < pending.entry_size;
         image_index++)
      pending.image.bytes.push_back(byte'(image_index));
    pending.failure_status = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "injected device write failure");
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    expect_ok("RECOVERY_ENTER", runtime.enter_recovery_prepared(pending));
    // prepared admission 已先把 runtime 切到 RECOVERY_REQUIRED；quiesce 的
    // state gate 优先于 ACTIVE 状态下的 outstanding-work busy 检查。
    expect_code("QUIESCE_PENDING", runtime.begin_quiesce(),
                RDMA_SC_INVALID_STATE);
    stale = rdma_queue_cursor_snapshot::type_id::create("stale_device_cursor");
    stale.index = producer.index;
    stale.wrap = ~producer.wrap;
    expect_code("STALE_DEVICE_COMMIT", runtime.commit_device_producer(stale),
                RDMA_SC_INVALID_STATE);
    expect_ok("RECOVERY_ABORT", runtime.abort_recovery());
    expect_ok("ABORT_QUERY_RESERVATION",
              runtime.query_device_reservation(reservation_valid, remaining));
    expect_ok("ABORT_QUERY_STATE", runtime.query_state(runtime_state));
    if (reservation_valid || remaining != null ||
        runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("RECOVERY_ABORT", "abort retained device recovery state")
  endtask

  // 功能：验证 pending detached copy、MMIO evidence 投影和 recovery completion 的 fail-closed 顺序。
  // 输入/输出及副作用：构造带 image/cursor/failure status 的 device pending，查询副本并尝试非法阶段推进；不修改外部 backing。
  // 失败/边界：缺失 recovery authorization、未清 reservation 或阶段顺序错误必须返回非成功状态；abort 后 pending/reservation 必须同时清空。
  task automatic test_pending_copy_and_mmio_evidence();
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot producer, next;
    rdma_queue_pending_operation pending, snapshot;
    rdma_status status;
    bit pending_present;
    bit valid;
    int unsigned i;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;

    runtime = rdma_queue_runtime::type_id::create("pending_copy_runtime");
    route = fixture_route(8'h0b);
    epoch = rdma_reset_epoch_t'(64'h10b);
    expect_ok("PENDING_CONFIGURE", runtime.configure(
      queue_handle("cq_pending", RDMA_RESOURCE_CQ, 11),
      RDMA_QUEUE_RUNTIME_CQ, 4, 0, 1'b0, 0, 1'b0, 1'b0));
    expect_ok("PENDING_ROUTE_EPOCH", runtime.set_route_epoch(route, epoch));
    expect_ok("PENDING_ACTIVATE", runtime.activate());
    expect_ok("PENDING_RESERVE", runtime.reserve_device_producer(producer));
    next = rdma_queue_cursor_snapshot::type_id::create("pending_next");
    next.index = producer.index + 1;
    next.wrap = producer.wrap;
    if (next.index >= 4) begin next.index = 0; next.wrap = ~next.wrap; end
    pending = rdma_queue_pending_operation::type_id::create("prepared_pending");
    pending.queue_h = queue_handle("cq_pending", RDMA_RESOURCE_CQ, 11);
    pending.kind = RDMA_QUEUE_RUNTIME_CQ;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = 1'b1;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "pending_cursor");
    pending.cursor.index = producer.index;
    pending.cursor.wrap = producer.wrap;
    pending.next_cursor = next;
    pending.entry_size = 16;
    pending.entry_offset = producer.index * 16;
    pending.image = rdma_hw_image::type_id::create("pending_image");
    pending.image.length = 16;
    for (i = 0; i < 16; i++) pending.image.bytes.push_back(byte'(i));
    pending.failure_status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                               "pending write failure");
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    expect_ok("PENDING_ENTER", runtime.enter_recovery_prepared(pending));
    expect_code("PENDING_CANCEL_AFTER_WRITE",
                runtime.cancel_device_producer(producer),
                RDMA_SC_RECOVERY_REQUIRED);
    expect_ok("PENDING_CANCEL_RESERVATION",
              runtime.query_device_reservation(valid, next));
    if (!valid || next == null || next.index != producer.index ||
        next.wrap != producer.wrap)
      `uvm_error("PENDING_CANCEL_AFTER_WRITE",
                 "cancel lost the attempted-write reservation")
    expect_ok("PENDING_QUERY", runtime.query_pending(snapshot));
    if (snapshot == null || snapshot == pending ||
        snapshot.queue_h == null || snapshot.queue_h == pending.queue_h ||
        snapshot.cursor == null || snapshot.cursor == pending.cursor ||
        snapshot.next_cursor == null ||
        snapshot.next_cursor == pending.next_cursor ||
        snapshot.image == null || snapshot.image == pending.image ||
        snapshot.failure_status == null ||
        snapshot.failure_status == pending.failure_status)
      `uvm_error("PENDING_DETACHED", "query_pending leaked mutable references")
    expect_ok("PENDING_PRESENT", runtime.query_has_pending(pending_present));
    if (!pending_present) `uvm_error("PENDING_PRESENT", "pending presence was lost")
    expect_ok("PENDING_MMIO_NA", runtime.record_recovery_failure(
      RDMA_QUEUE_MMIO_NOT_APPLICABLE));
    expect_code("PENDING_COMPLETE_GUARD", runtime.complete_recovery_retry(),
                RDMA_SC_INVALID_STATE);
    expect_ok("PENDING_ABORT", runtime.abort_recovery());
    expect_ok("PENDING_RESERVATION_CLEAR",
              runtime.query_device_reservation(valid, producer));
    if (valid) `uvm_error("PENDING_ABORT", "abort retained producer reservation")
  endtask

  // 功能：验证 host-produced ring 的 configure 只能从空 ledger 对应的相等
  //   PI/CI/wrap 启动，outstanding cursor 必须通过 resize copy 或 recovery 导入。
  // 输入/输出及副作用：构造两个 SQ runtime，分别提交 index 距离和 wrap 距离；
  //   通过 query_state 观察失败原子性，不创建 request/image 或外部 backing。
  // 失败/边界：PI!=CI 或相同 index 但 wrap 不同均返回 INVALID_ARGUMENT，runtime
  //   保持 DETACHED；合法空 host 配置由主 run_phase 继续覆盖。
  task automatic test_host_configure_empty_ledger_invariant();
    rdma_queue_runtime index_runtime;
    rdma_queue_runtime wrap_runtime;
    rdma_queue_runtime_state_e runtime_state;
    rdma_status status;

    index_runtime = rdma_queue_runtime::type_id::create(
      "host_nonempty_index_runtime");
    if (index_runtime == null) begin
      `uvm_error("HOST_NONEMPTY_INDEX", "runtime allocation failed")
      return;
    end
    expect_code("HOST_NONEMPTY_INDEX",
                index_runtime.configure(
                  queue_handle("host_nonempty_index", RDMA_RESOURCE_QP, 30),
                  RDMA_QUEUE_RUNTIME_SQ, 4, 1, 1'b0, 0, 1'b0, 1'b1),
                RDMA_SC_INVALID_ARGUMENT);
    status = index_runtime.query_state(runtime_state);
    expect_ok("HOST_NONEMPTY_INDEX_STATE", status);
    if (status == null || !status.ok() ||
        runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("HOST_NONEMPTY_INDEX_ATOMIC",
                 "rejected index distance changed runtime state")

    wrap_runtime = rdma_queue_runtime::type_id::create(
      "host_nonempty_wrap_runtime");
    if (wrap_runtime == null) begin
      `uvm_error("HOST_NONEMPTY_WRAP", "runtime allocation failed")
      return;
    end
    expect_code("HOST_NONEMPTY_WRAP",
                wrap_runtime.configure(
                  queue_handle("host_nonempty_wrap", RDMA_RESOURCE_QP, 31),
                  RDMA_QUEUE_RUNTIME_SQ, 4, 0, 1'b1, 0, 1'b0, 1'b1),
                RDMA_SC_INVALID_ARGUMENT);
    status = wrap_runtime.query_state(runtime_state);
    expect_ok("HOST_NONEMPTY_WRAP_STATE", status);
    if (status == null || !status.ok() ||
        runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("HOST_NONEMPTY_WRAP_ATOMIC",
                 "rejected wrap distance changed runtime state")
  endtask

  // 功能：验证 copy_ring_state 在 resize staging/publish 边界继承或匹配成对
  //   route/epoch authority，并在 authority 冲突或目标深度容不下游标时原子拒绝。
  // 输入/输出及副作用：构造一个已 QUIESCING 的空 CQ source 及四个 ATTACHED
  //   target；成功 copy 只发布 source 的 cursor/polarity/authority，失败 target
  //   激活后仍从 configure 时的 producer cursor 预留。
  // 失败/边界：source authority 缺失、target 半有效/不相等或 source PI/CI
  //   大于等于 target depth 时必须返回非成功状态，且不得部分覆盖 target。
  task automatic test_copy_ring_state_authority_and_geometry();
    rdma_queue_runtime source;
    rdma_queue_runtime inherited_target;
    rdma_queue_runtime matching_target;
    rdma_queue_runtime mismatch_target;
    rdma_queue_runtime narrow_target;
    rdma_handle cq_h;
    rdma_route_key_t source_route;
    rdma_route_key_t mismatch_route;
    rdma_route_key_t observed_route;
    rdma_reset_epoch_t source_epoch;
    rdma_reset_epoch_t observed_epoch;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    bit observed_route_valid;
    bit observed_epoch_valid;

    cq_h = queue_handle("copy_cq", RDMA_RESOURCE_CQ, 12);
    source_route = fixture_route(8'h0c);
    mismatch_route = fixture_route(8'h0d);
    source_epoch = rdma_reset_epoch_t'(64'h10c);
    source = rdma_queue_runtime::type_id::create("copy_source");
    status = source.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                              5, 1'b0, 5, 1'b0, 1'b0);
    expect_ok("COPY_SOURCE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = source.set_route_epoch(source_route, source_epoch);
    expect_ok("COPY_SOURCE_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = source.activate();
    expect_ok("COPY_SOURCE_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = source.begin_quiesce();
    expect_ok("COPY_SOURCE_QUIESCE", status);
    if (status == null || !status.ok()) return;

    inherited_target = rdma_queue_runtime::type_id::create(
      "copy_inherited_target");
    status = inherited_target.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                                         0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_INHERIT_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = inherited_target.copy_ring_state(source);
    expect_ok("COPY_INHERIT", status);
    if (status == null || !status.ok()) return;
    status = inherited_target.query_route_epoch(
      observed_route, observed_route_valid, observed_epoch,
      observed_epoch_valid);
    expect_ok("COPY_INHERIT_QUERY", status);
    if (status == null || !status.ok() || !observed_route_valid ||
        !observed_epoch_valid || observed_route != source_route ||
        observed_epoch != source_epoch)
      `uvm_error("COPY_INHERIT_QUERY",
                 "source authority was not inherited atomically")
    status = inherited_target.activate();
    expect_ok("COPY_INHERIT_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = inherited_target.reserve_device_producer(reservation);
    expect_ok("COPY_INHERIT_CURSOR", status);
    if (status == null || !status.ok() || reservation == null ||
        reservation.index != 5 || reservation.wrap != 1'b0)
      `uvm_error("COPY_INHERIT_CURSOR", "source PI was not copied")

    matching_target = rdma_queue_runtime::type_id::create(
      "copy_matching_target");
    status = matching_target.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                                        0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_MATCH_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = matching_target.set_route_epoch(source_route, source_epoch);
    expect_ok("COPY_MATCH_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    expect_ok("COPY_MATCH", matching_target.copy_ring_state(source));

    mismatch_target = rdma_queue_runtime::type_id::create(
      "copy_mismatch_target");
    status = mismatch_target.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                                        0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_MISMATCH_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = mismatch_target.set_route_epoch(mismatch_route, source_epoch);
    expect_ok("COPY_MISMATCH_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    expect_code("COPY_MISMATCH", mismatch_target.copy_ring_state(source),
                RDMA_SC_INVALID_ARGUMENT);
    status = mismatch_target.query_route_epoch(
      observed_route, observed_route_valid, observed_epoch,
      observed_epoch_valid);
    if (status == null || !status.ok() || observed_route != mismatch_route ||
        observed_epoch != source_epoch)
      `uvm_error("COPY_MISMATCH_ATOMIC",
                 "authority mismatch changed target state")
    status = mismatch_target.activate();
    expect_ok("COPY_MISMATCH_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = mismatch_target.reserve_device_producer(reservation);
    if (status == null || !status.ok() || reservation == null ||
        reservation.index != 0 || reservation.wrap != 1'b0)
      `uvm_error("COPY_MISMATCH_ATOMIC", "mismatch changed target PI")

    narrow_target = rdma_queue_runtime::type_id::create("copy_narrow_target");
    status = narrow_target.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 4,
                                      0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_NARROW_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = narrow_target.set_route_epoch(source_route, source_epoch);
    expect_ok("COPY_NARROW_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    expect_code("COPY_NARROW", narrow_target.copy_ring_state(source),
                RDMA_SC_INVALID_ARGUMENT);
    status = narrow_target.activate();
    expect_ok("COPY_NARROW_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = narrow_target.reserve_device_producer(reservation);
    if (status == null || !status.ok() || reservation == null ||
        reservation.index != 0 || reservation.wrap != 1'b0)
      `uvm_error("COPY_NARROW_ATOMIC", "geometry failure changed target PI")
  endtask

  // 功能：验证 copy_ring_state 的 source 与 target gate 都显式拒绝尚未消费的
  //   recovery_retry_confirmed，避免 resize 把一次性 retry authority 复制或覆盖。
  // 输入输出及副作用：构造同 identity/route 的 QUIESCING source 与 ATTACHED target，
  //   仅用 probe 注入单一 retry bit；通过生产 copy API 和公开 cursor 查询观察结果。
  // 失败边界：任一侧带 authorization 时 copy 必须原子拒绝；两侧清零后同一 source/
  //   target 必须成功复制，证明拒绝并非由其它 geometry/authority 条件造成。
  task automatic test_copy_ring_state_rejects_retry_confirmation();
    rdma_queue_runtime_retry_authority_probe source;
    rdma_queue_runtime_retry_authority_probe target;
    rdma_handle cq_h;
    rdma_route_key_t route;
    rdma_status status;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    cq_h = queue_handle("copy_retry_cq", RDMA_RESOURCE_CQ, 52);
    route = fixture_route(8'h52);
    source = rdma_queue_runtime_retry_authority_probe::type_id::create(
      "copy_retry_source");
    target = rdma_queue_runtime_retry_authority_probe::type_id::create(
      "copy_retry_target");
    if (source == null || target == null || cq_h == null) begin
      `uvm_error("COPY_RETRY_FIXTURE", "runtime probe allocation failed")
      return;
    end
    status = source.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                              3, 1'b0, 3, 1'b0, 1'b0);
    expect_ok("COPY_RETRY_SOURCE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    expect_ok("COPY_RETRY_SOURCE_ROUTE",
              source.set_route_epoch(route, rdma_reset_epoch_t'(64'h552)));
    expect_ok("COPY_RETRY_SOURCE_ACTIVATE", source.activate());
    expect_ok("COPY_RETRY_SOURCE_QUIESCE", source.begin_quiesce());
    status = target.configure(cq_h, RDMA_QUEUE_RUNTIME_CQ, 8,
                              0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("COPY_RETRY_TARGET_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    expect_ok("COPY_RETRY_TARGET_ROUTE",
              target.set_route_epoch(route, rdma_reset_epoch_t'(64'h552)));

    source.set_retry_confirmation_for_test(1'b1);
    expect_code("COPY_RETRY_SOURCE_GATE", target.copy_ring_state(source),
                RDMA_SC_RESOURCE_BUSY);
    status = target.query_cursors(producer_index, producer_wrap,
                                  consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 0 ||
        producer_wrap || consumer_index != 0 || consumer_wrap)
      `uvm_error("COPY_RETRY_SOURCE_ATOMIC",
                 "source retry rejection changed target cursors")

    source.set_retry_confirmation_for_test(1'b0);
    target.set_retry_confirmation_for_test(1'b1);
    expect_code("COPY_RETRY_TARGET_GATE", target.copy_ring_state(source),
                RDMA_SC_INVALID_STATE);
    status = target.query_cursors(producer_index, producer_wrap,
                                  consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 0 ||
        producer_wrap || consumer_index != 0 || consumer_wrap)
      `uvm_error("COPY_RETRY_TARGET_ATOMIC",
                 "target retry rejection changed target cursors")

    target.set_retry_confirmation_for_test(1'b0);
    expect_ok("COPY_RETRY_AFTER_CLEAR", target.copy_ring_state(source));
    status = target.query_cursors(producer_index, producer_wrap,
                                  consumer_index, consumer_wrap);
    if (status == null || !status.ok() || producer_index != 3 ||
        producer_wrap || consumer_index != 3 || consumer_wrap)
      `uvm_error("COPY_RETRY_AFTER_CLEAR",
                 "copy did not succeed after both retry gates cleared")
  endtask

  // 功能：验证 mmio_evidence 是 consumer recovery 的唯一 authority，NONE
  //   不得升级、兼容 marker 不得制造 SUCCESS，NO_SUBMIT 只有消费一次 caller
  //   confirmation 后才能接受真实 backend 的 SUCCESS。
  // 输入/输出及副作用：构造三笔独立 CQ recovery transaction，调用 record、
  //   recover、marker 与 detached query；只更新各自 runtime 的 recovery evidence。
  // 失败/边界：未经确认的 NO_SUBMIT->SUCCESS、NONE marker、SUCCESS 降级及
  //   confirmation 重放都必须拒绝并保持原 enum/兼容投影一致。
  task automatic test_mmio_evidence_authority_transitions();
    rdma_queue_runtime none_runtime;
    rdma_queue_runtime unauthorized_runtime;
    rdma_queue_runtime authorized_runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_status status;

    status = make_consumer_recovery_fixture(
      "mmio_none", 20, 8'h20, RDMA_QUEUE_MMIO_NONE,
      none_runtime, pending);
    expect_ok("MMIO_NONE_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = none_runtime.enter_recovery_prepared(pending);
    expect_ok("MMIO_NONE_ENTER", status);
    if (status == null || !status.ok()) return;
    expect_ok("MMIO_NONE_RECORD",
              none_runtime.record_recovery_failure(RDMA_QUEUE_MMIO_NONE));
    status = none_runtime.query_pending(snapshot);
    expect_ok("MMIO_NONE_QUERY", status);
    if (status == null || !status.ok() || snapshot == null) return;
    if (snapshot.mmio_evidence != RDMA_QUEUE_MMIO_NONE ||
        snapshot.known_no_mmio || snapshot.mmio_maybe_submitted ||
        snapshot.consumer_doorbell_succeeded)
      `uvm_error("MMIO_NONE_QUERY", "NONE was upgraded or misprojected")
    expect_code("MMIO_NONE_MARKER",
                none_runtime.mark_pending_consumer_doorbell_succeeded(),
                RDMA_SC_INVALID_STATE);
    status = none_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.mmio_evidence != RDMA_QUEUE_MMIO_NONE)
      `uvm_error("MMIO_NONE_MARKER", "marker manufactured SUCCESS evidence")

    status = make_consumer_recovery_fixture(
      "mmio_unauthorized", 21, 8'h21, RDMA_QUEUE_MMIO_NO_SUBMIT,
      unauthorized_runtime, pending);
    expect_ok("MMIO_UNAUTHORIZED_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = unauthorized_runtime.enter_recovery_prepared(pending);
    expect_ok("MMIO_UNAUTHORIZED_ENTER", status);
    if (status == null || !status.ok()) return;
    expect_code("MMIO_UNAUTHORIZED_SUCCESS",
                unauthorized_runtime.record_recovery_failure(
                  RDMA_QUEUE_MMIO_SUCCESS),
                RDMA_SC_INVALID_STATE);
    status = unauthorized_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
        !snapshot.known_no_mmio || snapshot.consumer_doorbell_succeeded)
      `uvm_error("MMIO_UNAUTHORIZED_SUCCESS",
                 "unauthorized transition changed pending evidence")

    status = make_consumer_recovery_fixture(
      "mmio_authorized", 22, 8'h22, RDMA_QUEUE_MMIO_NO_SUBMIT,
      authorized_runtime, pending);
    expect_ok("MMIO_AUTHORIZED_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = authorized_runtime.enter_recovery_prepared(pending);
    expect_ok("MMIO_AUTHORIZED_ENTER", status);
    if (status == null || !status.ok()) return;
    expect_code("MMIO_CONFIRM_REQUIRED",
                authorized_runtime.recover(
                  RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("MMIO_CONFIRM",
              authorized_runtime.recover(
                RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1));
    expect_ok("MMIO_AUTHORIZED_SUCCESS",
              authorized_runtime.record_recovery_failure(
                RDMA_QUEUE_MMIO_SUCCESS));
    expect_ok("MMIO_SUCCESS_MARKER",
              authorized_runtime.mark_pending_consumer_doorbell_succeeded());
    expect_code("MMIO_SUCCESS_DOWNGRADE",
                authorized_runtime.record_recovery_failure(
                  RDMA_QUEUE_MMIO_NO_SUBMIT),
                RDMA_SC_INVALID_STATE);
    status = authorized_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        snapshot.known_no_mmio || snapshot.mmio_maybe_submitted ||
        !snapshot.consumer_doorbell_succeeded)
      `uvm_error("MMIO_AUTHORIZED_SUCCESS",
                 "SUCCESS projection was not stable")
  endtask

  // 功能：验证 record_recovery_failure 拒绝 consumer 的 NOT_APPLICABLE 转换时，
  //   不得消费此前由 recover 记录的一次性 retry confirmation。
  // 输入/输出及副作用：无显式参数；构造 NO_SUBMIT consumer pending，依次执行
  //   confirm、非法转换和合法 SUCCESS 转换，并通过 detached query 观察 enum 投影。
  // 失败/边界：非法方向转换必须返回 INVALID_STATE 且保持 NO_SUBMIT；紧随其后的
  //   SUCCESS 不重新确认也必须成功，证明拒绝路径未清除 authorization。
  task automatic test_rejected_mmio_transition_preserves_confirmation();
    rdma_queue_runtime runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_status status;

    status = make_consumer_recovery_fixture(
      "mmio_reject_atomic", 41, 8'h41, RDMA_QUEUE_MMIO_NO_SUBMIT,
      runtime, pending);
    expect_ok("MMIO_REJECT_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = runtime.enter_recovery_prepared(pending);
    expect_ok("MMIO_REJECT_ENTER", status);
    if (status == null || !status.ok()) return;
    status = runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1);
    expect_ok("MMIO_REJECT_CONFIRM", status);
    if (status == null || !status.ok()) return;

    expect_code("MMIO_REJECT_DIRECTION",
                runtime.record_recovery_failure(
                  RDMA_QUEUE_MMIO_NOT_APPLICABLE),
                RDMA_SC_INVALID_STATE);
    status = runtime.query_pending(snapshot);
    expect_ok("MMIO_REJECT_QUERY", status);
    if (status == null || !status.ok() || snapshot == null) return;
    if (snapshot.mmio_evidence != RDMA_QUEUE_MMIO_NO_SUBMIT ||
        !snapshot.known_no_mmio || snapshot.consumer_doorbell_succeeded)
      `uvm_error("MMIO_REJECT_ATOMIC",
                 "rejected transition changed pending evidence")

    status = runtime.record_recovery_failure(RDMA_QUEUE_MMIO_SUCCESS);
    expect_ok("MMIO_REJECT_CONTINUATION", status);
    if (status == null || !status.ok()) return;
    status = runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS ||
        !snapshot.consumer_doorbell_succeeded || snapshot.known_no_mmio)
      `uvm_error("MMIO_REJECT_CONTINUATION",
                 "preserved confirmation did not authorize SUCCESS")
  endtask

  // 功能：验证重复 enter_recovery_prepared 只有完整 immutable transaction
  //   evidence 按值相等时才允许合并，覆盖 image、nested request SGE 和 routed QP。
  // 输入/输出及副作用：无显式参数；分别建立 CQ consumer 与 SQ producer pending，
  //   从 query_pending 取得 detached 副本后篡改单个嵌套字段并尝试重复 admission。
  // 失败/边界：每个不一致必须返回 INVALID_STATE；拒绝后再次查询必须仍保留原
  //   image byte、SGE lkey 或 routed_qp_h object_id，不能发布部分 evidence/阶段。
  task automatic test_prepared_immutable_evidence_atomicity();
    rdma_queue_runtime consumer_runtime;
    rdma_queue_runtime request_runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_pending_operation original;
    rdma_post_send_req request;
    rdma_post_send_req request_snapshot;
    rdma_sge sge;
    rdma_handle sq_h;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    rdma_status status;
    byte unsigned original_image_byte;
    bit [31:0] original_lkey;
    int unsigned original_routed_object_id;

    status = make_consumer_recovery_fixture(
      "immutable_consumer", 42, 8'h42, RDMA_QUEUE_MMIO_SUCCESS,
      consumer_runtime, pending);
    expect_ok("IMMUTABLE_CONSUMER_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.routed_qp_h = queue_handle(
      "immutable_consumer_qp", RDMA_RESOURCE_QP, 142);
    if (pending.routed_qp_h == null) begin
      `uvm_error("IMMUTABLE_CONSUMER_FIXTURE",
                 "routed QP allocation failed")
      return;
    end
    status = consumer_runtime.enter_recovery_prepared(pending);
    expect_ok("IMMUTABLE_CONSUMER_ENTER", status);
    if (status == null || !status.ok()) return;

    status = consumer_runtime.query_pending(snapshot);
    expect_ok("IMMUTABLE_IMAGE_QUERY", status);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.image == null || snapshot.image.bytes.size() == 0) return;
    original_image_byte = snapshot.image.bytes[0];
    snapshot.image.bytes[0] ^= 8'hff;
    expect_code("IMMUTABLE_IMAGE_MISMATCH",
                consumer_runtime.enter_recovery_prepared(snapshot),
                RDMA_SC_INVALID_STATE);
    status = consumer_runtime.query_pending(original);
    if (status == null || !status.ok() || original == null ||
        original.image == null || original.image.bytes.size() == 0 ||
        original.image.bytes[0] != original_image_byte)
      `uvm_error("IMMUTABLE_IMAGE_ATOMIC",
                 "image mismatch changed original pending")

    status = consumer_runtime.query_pending(snapshot);
    expect_ok("IMMUTABLE_ROUTED_QP_QUERY", status);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.routed_qp_h == null) return;
    original_routed_object_id = snapshot.routed_qp_h.object_id;
    snapshot.routed_qp_h.object_id++;
    expect_code("IMMUTABLE_ROUTED_QP_MISMATCH",
                consumer_runtime.enter_recovery_prepared(snapshot),
                RDMA_SC_INVALID_STATE);
    status = consumer_runtime.query_pending(original);
    if (status == null || !status.ok() || original == null ||
        original.routed_qp_h == null ||
        original.routed_qp_h.object_id != original_routed_object_id)
      `uvm_error("IMMUTABLE_ROUTED_QP_ATOMIC",
                 "routed QP mismatch changed original pending")

    sq_h = queue_handle("immutable_request_sq", RDMA_RESOURCE_QP, 43);
    route = fixture_route(8'h43);
    epoch = rdma_reset_epoch_t'(64'h443);
    request_runtime = rdma_queue_runtime::type_id::create(
      "immutable_request_runtime");
    if (sq_h == null || request_runtime == null) begin
      `uvm_error("IMMUTABLE_REQUEST_FIXTURE",
                 "host runtime allocation failed")
      return;
    end
    status = request_runtime.configure(
      sq_h, RDMA_QUEUE_RUNTIME_SQ, 4, 0, 1'b0, 0, 1'b0, 1'b1);
    expect_ok("IMMUTABLE_REQUEST_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = request_runtime.set_route_epoch(route, epoch);
    expect_ok("IMMUTABLE_REQUEST_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = request_runtime.activate();
    expect_ok("IMMUTABLE_REQUEST_ACTIVATE", status);
    if (status == null || !status.ok()) return;

    pending = rdma_queue_pending_operation::type_id::create(
      "immutable_request_pending");
    request = rdma_post_send_req::type_id::create(
      "immutable_request_value");
    sge = rdma_sge::type_id::create("immutable_request_sge");
    if (pending == null || request == null || sge == null) begin
      `uvm_error("IMMUTABLE_REQUEST_FIXTURE",
                 "pending request allocation failed")
      return;
    end
    pending.queue_h = queue_handle(
      "immutable_request_pending_sq", RDMA_RESOURCE_QP, 43);
    pending.kind = RDMA_QUEUE_RUNTIME_SQ;
    pending.producer = 1'b1;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "immutable_request_cursor");
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "immutable_request_next");
    pending.image = rdma_hw_image::type_id::create(
      "immutable_request_image");
    pending.failure_status = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "immutable request injected failure");
    request.qp_h = queue_handle(
      "immutable_request_qp", RDMA_RESOURCE_QP, 43);
    if (pending.queue_h == null || pending.cursor == null ||
        pending.next_cursor == null || pending.image == null ||
        pending.failure_status == null || request.qp_h == null) begin
      `uvm_error("IMMUTABLE_REQUEST_FIXTURE",
                 "nested request evidence allocation failed")
      return;
    end
    pending.cursor.index = 0;
    pending.cursor.wrap = 1'b0;
    pending.next_cursor.index = 1;
    pending.next_cursor.wrap = 1'b0;
    pending.entry_size = 64;
    pending.entry_offset = 0;
    pending.image.length = 64;
    pending.image.alignment = 64;
    pending.image.endian = RDMA_ENDIAN_BIG;
    pending.image.image_kind = RDMA_IMAGE_SQE;
    pending.image.hardware_version = RDMA_HW_VERSION;
    pending.image.function_generation = 5;
    for (int unsigned i = 0; i < 64; i++)
      pending.image.bytes.push_back(byte'(i));
    sge.iova.value = 64'h1000;
    sge.length = 16;
    sge.lkey = 32'h1234_5678;
    request.sges.push_back(sge);
    pending.request_snapshot = request;
    pending.wr_id = 64'h4243;
    pending.signaled = 1'b1;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    status = request_runtime.enter_recovery_prepared(pending);
    expect_ok("IMMUTABLE_REQUEST_ENTER", status);
    if (status == null || !status.ok()) return;

    status = request_runtime.query_pending(snapshot);
    expect_ok("IMMUTABLE_REQUEST_QUERY", status);
    if (status == null || !status.ok() || snapshot == null ||
        !$cast(request_snapshot, snapshot.request_snapshot) ||
        request_snapshot.sges.size() != 1 ||
        request_snapshot.sges[0] == null) return;
    original_lkey = request_snapshot.sges[0].lkey;
    request_snapshot.sges[0].lkey ^= 32'hffff_ffff;
    expect_code("IMMUTABLE_REQUEST_MISMATCH",
                request_runtime.enter_recovery_prepared(snapshot),
                RDMA_SC_INVALID_STATE);
    status = request_runtime.query_pending(original);
    if (status == null || !status.ok() || original == null ||
        !$cast(request_snapshot, original.request_snapshot) ||
        request_snapshot.sges.size() != 1 ||
        request_snapshot.sges[0] == null ||
        request_snapshot.sges[0].lkey != original_lkey)
      `uvm_error("IMMUTABLE_REQUEST_ATOMIC",
                 "nested SGE mismatch changed original pending")
  endtask

  // 功能：验证 consumer recovery 的 committed 阶段必须与 runtime CI 和
  //   next_cursor 同步，覆盖初次 admission、重复 merge、兼容 marker 和 complete。
  // 输入/输出及副作用：构造五笔独立 CQ fixture，注入伪造 committed evidence、
  //   执行一次合法 CI commit，并通过 detached query 检查 pending/occupancy/state。
  // 失败/边界：旧 CI 上的 committed 声明、未推进 CI 的 marker、merge 后阶段跳跃
  //   和 complete 伪造都必须原子拒绝；合法 SUCCESS->CI commit->complete 必须成功。
  task automatic test_consumer_recovery_commit_invariant();
    rdma_queue_runtime admission_runtime;
    rdma_queue_runtime merge_runtime;
    rdma_queue_runtime marker_runtime;
    rdma_queue_runtime completion_runtime;
    rdma_queue_runtime valid_runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_cursor_snapshot committed_cursor;
    rdma_queue_runtime_state_e runtime_state;
    rdma_status status;
    int unsigned occupancy;

    status = make_consumer_recovery_fixture(
      "consumer_admission", 23, 8'h23, RDMA_QUEUE_MMIO_SUCCESS,
      admission_runtime, pending);
    expect_ok("CONSUMER_ADMISSION_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.consumer_committed = 1'b1;
    pending.cq_consumer_committed = 1'b1;
    pending.committed_consumer_cursor =
      rdma_queue_cursor_snapshot::type_id::create(
        "consumer_admission_forged_cursor");
    if (pending.committed_consumer_cursor == null) begin
      `uvm_error("CONSUMER_ADMISSION_FIXTURE",
                 "committed cursor allocation failed")
      return;
    end
    pending.committed_consumer_cursor.index = pending.cursor.index;
    pending.committed_consumer_cursor.wrap = pending.cursor.wrap;
    expect_code("CONSUMER_ADMISSION_INVARIANT",
                admission_runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_STATE);
    expect_ok("CONSUMER_ADMISSION_STATE",
              admission_runtime.query_state(runtime_state));
    expect_ok("CONSUMER_ADMISSION_OCCUPANCY",
              admission_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 1)
      `uvm_error("CONSUMER_ADMISSION_ATOMIC",
                 "rejected committed evidence changed runtime state")

    status = make_consumer_recovery_fixture(
      "consumer_merge", 24, 8'h24, RDMA_QUEUE_MMIO_SUCCESS,
      merge_runtime, pending);
    expect_ok("CONSUMER_MERGE_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = merge_runtime.enter_recovery_prepared(pending);
    expect_ok("CONSUMER_MERGE_ENTER", status);
    if (status == null || !status.ok()) return;
    status = merge_runtime.query_pending(snapshot);
    expect_ok("CONSUMER_MERGE_QUERY", status);
    if (status == null || !status.ok() || snapshot == null) return;
    snapshot.consumer_committed = 1'b1;
    snapshot.cq_consumer_committed = 1'b1;
    snapshot.committed_consumer_cursor =
      rdma_queue_cursor_snapshot::type_id::create(
        "consumer_merge_committed_cursor");
    if (snapshot.committed_consumer_cursor == null) begin
      `uvm_error("CONSUMER_MERGE_QUERY", "committed cursor allocation failed")
      return;
    end
    snapshot.committed_consumer_cursor.index = snapshot.next_cursor.index;
    snapshot.committed_consumer_cursor.wrap = snapshot.next_cursor.wrap;
    expect_code("CONSUMER_MERGE_INVARIANT",
                merge_runtime.enter_recovery_prepared(snapshot),
                RDMA_SC_INVALID_STATE);
    status = merge_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.consumer_committed ||
        snapshot.committed_consumer_cursor != null)
      `uvm_error("CONSUMER_MERGE_ATOMIC",
                 "failed merge published committed evidence")

    status = make_consumer_recovery_fixture(
      "consumer_marker", 25, 8'h25, RDMA_QUEUE_MMIO_SUCCESS,
      marker_runtime, pending);
    expect_ok("CONSUMER_MARKER_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = marker_runtime.enter_recovery_prepared(pending);
    expect_ok("CONSUMER_MARKER_ENTER", status);
    if (status == null || !status.ok()) return;
    expect_code("CONSUMER_MARKER_INVARIANT",
                marker_runtime.mark_pending_consumer_committed(),
                RDMA_SC_INVALID_STATE);
    status = marker_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.consumer_committed ||
        snapshot.committed_consumer_cursor != null)
      `uvm_error("CONSUMER_MARKER_ATOMIC",
                 "marker claimed commit while runtime CI remained old")

    status = make_consumer_recovery_fixture(
      "consumer_completion", 26, 8'h26, RDMA_QUEUE_MMIO_SUCCESS,
      completion_runtime, pending);
    expect_ok("CONSUMER_COMPLETE_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = completion_runtime.enter_recovery_prepared(pending);
    expect_ok("CONSUMER_COMPLETE_ENTER", status);
    if (status == null || !status.ok()) return;
    // enter_recovery_prepared 成功后 runtime 接管 pending；这里故意模拟违约调用方
    // 持有旧别名并篡改阶段，验证 complete 自身仍执行 fail-closed invariant。
    pending.consumer_committed = 1'b1;
    pending.cq_consumer_committed = 1'b1;
    committed_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "consumer_completion_forged_cursor");
    if (committed_cursor == null) begin
      `uvm_error("CONSUMER_COMPLETE_FIXTURE", "committed cursor allocation failed")
      return;
    end
    committed_cursor.index = pending.cursor.index;
    committed_cursor.wrap = pending.cursor.wrap;
    pending.committed_consumer_cursor = committed_cursor;
    expect_code("CONSUMER_COMPLETE_INVARIANT",
                completion_runtime.complete_recovery_retry(),
                RDMA_SC_INVALID_STATE);
    expect_ok("CONSUMER_COMPLETE_STATE",
              completion_runtime.query_state(runtime_state));
    expect_ok("CONSUMER_COMPLETE_OCCUPANCY",
              completion_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED || occupancy != 1)
      `uvm_error("CONSUMER_COMPLETE_ATOMIC",
                 "invalid complete cleared pending or consumed credit")

    status = make_consumer_recovery_fixture(
      "consumer_valid", 27, 8'h27, RDMA_QUEUE_MMIO_SUCCESS,
      valid_runtime, pending);
    expect_ok("CONSUMER_VALID_FIXTURE", status);
    if (status == null || !status.ok()) return;
    status = valid_runtime.enter_recovery_prepared(pending);
    expect_ok("CONSUMER_VALID_ENTER", status);
    if (status == null || !status.ok()) return;
    expect_ok("CONSUMER_VALID_GATE", valid_runtime.enable_recovery_commit());
    expect_ok("CONSUMER_VALID_COMMIT",
              valid_runtime.commit_consumer(pending.cursor));
    status = valid_runtime.query_pending(snapshot);
    if (status == null || !status.ok() || snapshot == null ||
        !snapshot.consumer_committed ||
        snapshot.committed_consumer_cursor == null ||
        snapshot.committed_consumer_cursor.index != snapshot.next_cursor.index ||
        snapshot.committed_consumer_cursor.wrap != snapshot.next_cursor.wrap)
      `uvm_error("CONSUMER_VALID_QUERY",
                 "valid commit did not publish the next cursor evidence")
    expect_ok("CONSUMER_VALID_COMPLETE",
              valid_runtime.complete_recovery_retry());
    expect_ok("CONSUMER_VALID_STATE", valid_runtime.query_state(runtime_state));
    expect_ok("CONSUMER_VALID_OCCUPANCY",
              valid_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 0)
      `uvm_error("CONSUMER_VALID_FINAL",
                 "valid recovery did not return an empty ring to ACTIVE")
    expect_code("CONSUMER_VALID_COMPLETE_IDEMPOTENCY",
                valid_runtime.complete_recovery_retry(),
                RDMA_SC_INVALID_STATE);
    expect_code("CONSUMER_VALID_COMMIT_IDEMPOTENCY",
                valid_runtime.commit_consumer(pending.cursor),
                RDMA_SC_INVALID_STATE);
  endtask

  // 功能：对一个已安装 pending 的 runtime 注入单个 factory 故障，验证
  //   query_pending 的错误状态、安全 output 和原子性。
  // 输入输出及副作用：label/runtime/fault/wrong_type（输入）；短暂 arm
  //   wrapper，执行失败查询后立即 disarm，并以成功查询复核原 pending。
  // 失败边界：runtime/fault 为 null 时报告 UVM_ERROR 并返回；故障路径
  //   必须返回非空 RESOURCE_EXHAUSTED、snapshot=null，且 pending/occupancy 不变。
  task automatic check_pending_factory_failure(
    string label,
    rdma_queue_runtime runtime,
    rdma_queue_runtime_factory_fault_wrapper fault,
    bit wrong_type
  );
    rdma_queue_pending_operation snapshot;
    rdma_queue_runtime_state_e runtime_state;
    rdma_status status;
    int unsigned occupancy;

    if (runtime == null || fault == null) begin
      `uvm_error(label, "factory failure fixture is null")
      return;
    end
    snapshot = rdma_queue_pending_operation::type_id::create(
      {label, "_sentinel"});
    fault.arm(wrong_type);
    status = runtime.query_pending(snapshot);
    fault.disarm();
    expect_code(label, status, RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        snapshot != null) begin
      `uvm_error(label,
                 "factory failure returned null/wrong status or output")
      return;
    end
    status = runtime.query_pending(snapshot);
    expect_ok({label, "_REQUERY"}, status);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.queue_h == null || snapshot.cursor == null ||
        snapshot.next_cursor == null || snapshot.image == null ||
        snapshot.failure_status == null) begin
      `uvm_error({label, "_ATOMIC"},
                 "factory failure damaged pending evidence")
      return;
    end
    expect_ok({label, "_STATE"}, runtime.query_state(runtime_state));
    expect_ok({label, "_OCCUPANCY"}, runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_RECOVERY_REQUIRED ||
        occupancy != 1)
      `uvm_error({label, "_ATOMIC"},
                 "factory failure changed recovery state or occupancy")
  endtask

  // 功能：覆盖 pending/handle/cursor/image/status 值副本和 host request 副本的
  //   raw-factory null/错误类型，并验证 host reservation 分配失败不推进 PI。
  // 输入输出及副作用：无显式参数；构造一个 CQ consumer pending、一个 SQ
  //   producer pending 和两个 SQ runtime，通过公开 query/reserve 产生断言。
  // 失败边界：每次故障后都先 disarm 再继续；任一 fixture 前置失败时
  //   提前返回，避免 null 解引用掩盖原始错误。
  task automatic test_nonfatal_factory_failures();
    rdma_queue_runtime consumer_runtime;
    rdma_queue_runtime request_runtime;
    rdma_queue_runtime reserve_runtime;
    rdma_queue_pending_operation consumer_pending;
    rdma_queue_pending_operation host_pending;
    rdma_queue_pending_operation snapshot;
    rdma_queue_cursor_snapshot reservation;
    rdma_post_send_req request;
    rdma_handle host_h;
    rdma_status status;
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;

    status = make_consumer_recovery_fixture(
      "factory_consumer", 30, 8'h30, RDMA_QUEUE_MMIO_SUCCESS,
      consumer_runtime, consumer_pending);
    expect_ok("FACTORY_CONSUMER_FIXTURE", status);
    if (status == null || !status.ok() || consumer_runtime == null ||
        consumer_pending == null) return;
    status = consumer_runtime.enter_recovery_prepared(consumer_pending);
    expect_ok("FACTORY_CONSUMER_ENTER", status);
    if (status == null || !status.ok()) return;

    check_pending_factory_failure("FACTORY_PENDING_NULL", consumer_runtime,
                                  pending_fault, 1'b0);
    check_pending_factory_failure("FACTORY_PENDING_TYPE", consumer_runtime,
                                  pending_fault, 1'b1);
    check_pending_factory_failure("FACTORY_HANDLE_NULL", consumer_runtime,
                                  handle_fault, 1'b0);
    check_pending_factory_failure("FACTORY_HANDLE_TYPE", consumer_runtime,
                                  handle_fault, 1'b1);
    check_pending_factory_failure("FACTORY_CURSOR_NULL", consumer_runtime,
                                  cursor_fault, 1'b0);
    check_pending_factory_failure("FACTORY_CURSOR_TYPE", consumer_runtime,
                                  cursor_fault, 1'b1);
    check_pending_factory_failure("FACTORY_IMAGE_NULL", consumer_runtime,
                                  image_fault, 1'b0);
    check_pending_factory_failure("FACTORY_IMAGE_TYPE", consumer_runtime,
                                  image_fault, 1'b1);
    check_pending_factory_failure("FACTORY_STATUS_NULL", consumer_runtime,
                                  status_fault, 1'b0);
    check_pending_factory_failure("FACTORY_STATUS_TYPE", consumer_runtime,
                                  status_fault, 1'b1);

    host_h = queue_handle("factory_request_sq", RDMA_RESOURCE_QP, 31);
    request_runtime = rdma_queue_runtime::type_id::create(
      "factory_request_runtime");
    if (host_h == null || request_runtime == null) begin
      `uvm_error("FACTORY_REQUEST_FIXTURE", "host fixture allocation failed")
      return;
    end
    status = request_runtime.configure(
      host_h, RDMA_QUEUE_RUNTIME_SQ, 4, 0, 1'b0, 0, 1'b0, 1'b1);
    expect_ok("FACTORY_REQUEST_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = request_runtime.set_route_epoch(
      fixture_route(8'h31), rdma_reset_epoch_t'(64'h331));
    expect_ok("FACTORY_REQUEST_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = request_runtime.activate();
    expect_ok("FACTORY_REQUEST_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    host_pending = rdma_queue_pending_operation::type_id::create(
      "factory_request_pending");
    request = rdma_post_send_req::type_id::create("factory_request_value");
    if (host_pending == null || request == null) begin
      `uvm_error("FACTORY_REQUEST_FIXTURE", "request evidence allocation failed")
      return;
    end
    host_pending.producer = 1'b1;
    host_pending.request_snapshot = request;
    status = request_runtime.enter_recovery(host_pending, 1'b0);
    expect_ok("FACTORY_REQUEST_ENTER", status);
    if (status == null || !status.ok()) return;
    request_fault.arm(1'b0);
    status = request_runtime.query_pending(snapshot);
    request_fault.disarm();
    expect_code("FACTORY_REQUEST_NULL", status,
                RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        snapshot != null)
      `uvm_error("FACTORY_REQUEST_NULL",
                 "request null failure was not fail-closed")
    request_fault.arm(1'b1);
    status = request_runtime.query_pending(snapshot);
    request_fault.disarm();
    expect_code("FACTORY_REQUEST_TYPE", status,
                RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        snapshot != null)
      `uvm_error("FACTORY_REQUEST_TYPE",
                 "request type failure was not fail-closed")
    status = request_runtime.query_pending(snapshot);
    expect_ok("FACTORY_REQUEST_REQUERY", status);
    if (status == null || !status.ok() || snapshot == null ||
        snapshot.request_snapshot == null)
      `uvm_error("FACTORY_REQUEST_ATOMIC",
                 "request clone failure damaged existing pending")

    reserve_runtime = rdma_queue_runtime::type_id::create(
      "factory_reserve_runtime");
    if (reserve_runtime == null) begin
      `uvm_error("FACTORY_RESERVE_FIXTURE", "runtime allocation failed")
      return;
    end
    status = reserve_runtime.configure(
      queue_handle("factory_reserve_sq", RDMA_RESOURCE_QP, 32),
      RDMA_QUEUE_RUNTIME_SQ, 4, 2, 1'b0, 2, 1'b0, 1'b1);
    expect_ok("FACTORY_RESERVE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = reserve_runtime.set_route_epoch(
      fixture_route(8'h32), rdma_reset_epoch_t'(64'h332));
    expect_ok("FACTORY_RESERVE_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = reserve_runtime.activate();
    expect_ok("FACTORY_RESERVE_ACTIVATE", status);
    if (status == null || !status.ok()) return;

    cursor_fault.arm(1'b0);
    status = reserve_runtime.reserve_producer(reservation);
    cursor_fault.disarm();
    expect_code("FACTORY_RESERVE_NULL", status,
                RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        reservation != null)
      `uvm_error("FACTORY_RESERVE_NULL",
                 "reserve null failure published output")
    cursor_fault.arm(1'b1);
    status = reserve_runtime.reserve_producer(reservation);
    cursor_fault.disarm();
    expect_code("FACTORY_RESERVE_TYPE", status,
                RDMA_SC_RESOURCE_EXHAUSTED);
    if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        reservation != null)
      `uvm_error("FACTORY_RESERVE_TYPE",
                 "reserve type failure published output")
    expect_ok("FACTORY_RESERVE_CURSORS", reserve_runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap));
    if (producer_index != 2 || producer_wrap ||
        consumer_index != 2 || consumer_wrap)
      `uvm_error("FACTORY_RESERVE_ATOMIC",
                 "failed reserve changed PI/CI")
    status = reserve_runtime.reserve_producer(reservation);
    expect_ok("FACTORY_RESERVE_RETRY", status);
    if (status == null || !status.ok() || reservation == null ||
        reservation.index != 2 || reservation.wrap)
      `uvm_error("FACTORY_RESERVE_RETRY",
                 "reserve did not recover after factory disarm")
  endtask

  // 功能：用 depth=2 的 CQ 走完 reserve/full/consumer-credit/wrap，并验证
  //   CEQ 的初始 full occupancy 与 AEQ quiesce/detach 状态守卫。
  // 输入输出及副作用：无显式参数；构造三个 device runtime，通过
  //   reserve/commit/peek/query/lifecycle 公开接口改变并观察本地账本。
  // 失败边界：任一配置或事务前置失败即返回；full 和 quiesce busy
  //   必须保持 output/游标/occupancy，DETACHED 不得被 restore 重新激活。
  task automatic test_device_depth_two_ceq_and_lifecycle();
    rdma_queue_runtime cq_runtime;
    rdma_queue_runtime ceq_runtime;
    rdma_queue_runtime aeq_runtime;
    rdma_queue_cursor_snapshot producer;
    rdma_queue_cursor_snapshot consumer;
    rdma_status status;
    int unsigned available;
    int unsigned occupancy;
    rdma_queue_runtime_state_e runtime_state;

    cq_runtime = rdma_queue_runtime::type_id::create("depth_two_cq_runtime");
    if (cq_runtime == null) begin
      `uvm_error("DEPTH2_FIXTURE", "CQ runtime allocation failed")
      return;
    end
    status = cq_runtime.configure(
      queue_handle("depth_two_cq", RDMA_RESOURCE_CQ, 33),
      RDMA_QUEUE_RUNTIME_CQ, 2, 0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("DEPTH2_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = cq_runtime.set_route_epoch(
      fixture_route(8'h33), rdma_reset_epoch_t'(64'h333));
    expect_ok("DEPTH2_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = cq_runtime.activate();
    expect_ok("DEPTH2_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    expect_ok("DEPTH2_AVAILABLE_EMPTY",
              cq_runtime.query_available(available));
    if (available != 2)
      `uvm_error("DEPTH2_AVAILABLE_EMPTY", "empty ring credit is not two")

    status = cq_runtime.reserve_device_producer(producer);
    expect_ok("DEPTH2_RESERVE0", status);
    if (status == null || !status.ok() || producer == null) return;
    expect_ok("DEPTH2_AVAILABLE_RESERVED",
              cq_runtime.query_available(available));
    expect_ok("DEPTH2_OCCUPANCY_RESERVED",
              cq_runtime.query_occupancy(occupancy));
    if (available != 1 || occupancy != 0)
      `uvm_error("DEPTH2_RESERVED_CREDIT",
                 "reservation did not consume only available credit")
    status = cq_runtime.commit_device_producer(producer);
    expect_ok("DEPTH2_COMMIT0", status);
    if (status == null || !status.ok()) return;

    status = cq_runtime.reserve_device_producer(producer);
    expect_ok("DEPTH2_RESERVE1", status);
    if (status == null || !status.ok() || producer == null ||
        producer.index != 1 || producer.wrap) begin
      `uvm_error("DEPTH2_RESERVE1", "second reservation cursor is wrong")
      return;
    end
    expect_ok("DEPTH2_AVAILABLE_LAST_RESERVED",
              cq_runtime.query_available(available));
    if (available != 0)
      `uvm_error("DEPTH2_AVAILABLE_LAST_RESERVED",
                 "last reservation left phantom credit")
    status = cq_runtime.commit_device_producer(producer);
    expect_ok("DEPTH2_COMMIT1", status);
    if (status == null || !status.ok()) return;
    producer = rdma_queue_cursor_snapshot::type_id::create(
      "depth_two_full_sentinel");
    status = cq_runtime.reserve_device_producer(producer);
    expect_code("DEPTH2_FULL", status, RDMA_SC_QUEUE_FULL);
    if (producer != null)
      `uvm_error("DEPTH2_FULL", "full reserve published an output")

    status = cq_runtime.peek_consumer(consumer);
    expect_ok("DEPTH2_PEEK0", status);
    if (status == null || !status.ok() || consumer == null ||
        consumer.index != 0 || consumer.wrap) return;
    status = cq_runtime.commit_consumer(consumer);
    expect_ok("DEPTH2_CONSUME0", status);
    if (status == null || !status.ok()) return;
    expect_ok("DEPTH2_AVAILABLE_RELEASED",
              cq_runtime.query_available(available));
    if (available != 1)
      `uvm_error("DEPTH2_AVAILABLE_RELEASED",
                 "consumer did not restore one credit")
    status = cq_runtime.reserve_device_producer(producer);
    expect_ok("DEPTH2_RESERVE_WRAP", status);
    if (status == null || !status.ok() || producer == null ||
        producer.index != 0 || !producer.wrap) begin
      `uvm_error("DEPTH2_RESERVE_WRAP", "producer did not wrap at depth two")
      return;
    end
    status = cq_runtime.commit_device_producer(producer);
    expect_ok("DEPTH2_COMMIT_WRAP", status);
    if (status == null || !status.ok()) return;
    status = cq_runtime.peek_consumer(consumer);
    if (status == null || !status.ok() || consumer == null ||
        consumer.index != 1 || consumer.wrap) begin
      `uvm_error("DEPTH2_PEEK1", "consumer order skipped second entry")
      return;
    end
    expect_ok("DEPTH2_CONSUME1", cq_runtime.commit_consumer(consumer));
    status = cq_runtime.peek_consumer(consumer);
    if (status == null || !status.ok() || consumer == null ||
        consumer.index != 0 || !consumer.wrap) begin
      `uvm_error("DEPTH2_PEEK_WRAP", "consumer did not observe wrapped entry")
      return;
    end
    expect_ok("DEPTH2_CONSUME_WRAP",
              cq_runtime.commit_consumer(consumer));
    expect_ok("DEPTH2_OCCUPANCY_FINAL",
              cq_runtime.query_occupancy(occupancy));
    if (occupancy != 0)
      `uvm_error("DEPTH2_OCCUPANCY_FINAL", "wrapped ring did not drain")

    ceq_runtime = rdma_queue_runtime::type_id::create("initial_full_ceq");
    if (ceq_runtime == null) begin
      `uvm_error("CEQ_FULL_FIXTURE", "CEQ runtime allocation failed")
      return;
    end
    status = ceq_runtime.configure(
      queue_handle("initial_full_ceq", RDMA_RESOURCE_CEQ, 34),
      RDMA_QUEUE_RUNTIME_CEQ, 2, 0, 1'b1, 0, 1'b0, 1'b0);
    expect_ok("CEQ_FULL_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = ceq_runtime.set_route_epoch(
      fixture_route(8'h34), rdma_reset_epoch_t'(64'h334));
    expect_ok("CEQ_FULL_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = ceq_runtime.activate();
    expect_ok("CEQ_FULL_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    expect_ok("CEQ_FULL_OCCUPANCY",
              ceq_runtime.query_occupancy(occupancy));
    expect_ok("CEQ_FULL_AVAILABLE",
              ceq_runtime.query_available(available));
    if (occupancy != 2 || available != 0)
      `uvm_error("CEQ_FULL_INITIAL", "CEQ full snapshot was not restored")
    expect_code("CEQ_FULL_RESERVE",
                ceq_runtime.reserve_device_producer(producer),
                RDMA_SC_QUEUE_FULL);
    status = ceq_runtime.peek_consumer(consumer);
    expect_ok("CEQ_FULL_PEEK", status);
    if (status == null || !status.ok() || consumer == null) return;
    expect_ok("CEQ_FULL_CONSUME", ceq_runtime.commit_consumer(consumer));
    expect_ok("CEQ_FULL_RELEASED",
              ceq_runtime.query_available(available));
    if (available != 1)
      `uvm_error("CEQ_FULL_RELEASED", "CEQ consume did not restore credit")

    aeq_runtime = rdma_queue_runtime::type_id::create("lifecycle_aeq");
    if (aeq_runtime == null) begin
      `uvm_error("LIFECYCLE_FIXTURE", "AEQ runtime allocation failed")
      return;
    end
    status = aeq_runtime.configure(
      queue_handle("lifecycle_aeq", RDMA_RESOURCE_AEQ, 35),
      RDMA_QUEUE_RUNTIME_AEQ, 2, 0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("LIFECYCLE_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = aeq_runtime.set_route_epoch(
      fixture_route(8'h35), rdma_reset_epoch_t'(64'h335));
    expect_ok("LIFECYCLE_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = aeq_runtime.activate();
    expect_ok("LIFECYCLE_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = aeq_runtime.reserve_device_producer(producer);
    expect_ok("LIFECYCLE_RESERVE", status);
    if (status == null || !status.ok() || producer == null) return;
    expect_ok("LIFECYCLE_COMMIT",
              aeq_runtime.commit_device_producer(producer));
    expect_code("LIFECYCLE_USED_BUSY", aeq_runtime.begin_quiesce(),
                RDMA_SC_RESOURCE_BUSY);
    status = aeq_runtime.peek_consumer(consumer);
    expect_ok("LIFECYCLE_PEEK", status);
    if (status == null || !status.ok() || consumer == null) return;
    expect_ok("LIFECYCLE_CONSUME", aeq_runtime.commit_consumer(consumer));
    status = aeq_runtime.reserve_device_producer(producer);
    expect_ok("LIFECYCLE_RESERVE_AGAIN", status);
    if (status == null || !status.ok() || producer == null) return;
    expect_code("LIFECYCLE_RESERVATION_BUSY", aeq_runtime.begin_quiesce(),
                RDMA_SC_RESOURCE_BUSY);
    expect_ok("LIFECYCLE_CANCEL",
              aeq_runtime.cancel_device_producer(producer));
    expect_ok("LIFECYCLE_QUIESCE", aeq_runtime.begin_quiesce());
    expect_code("LIFECYCLE_REPEAT_QUIESCE", aeq_runtime.begin_quiesce(),
                RDMA_SC_INVALID_STATE);
    expect_ok("LIFECYCLE_RESTORE", aeq_runtime.restore_active());
    expect_ok("LIFECYCLE_RESTORED_STATE",
              aeq_runtime.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE) begin
      `uvm_error("LIFECYCLE_RESTORED_STATE",
                 "restore_active did not publish ACTIVE")
      return;
    end
    expect_ok("LIFECYCLE_REQUIESCE", aeq_runtime.begin_quiesce());
    expect_ok("LIFECYCLE_DETACH", aeq_runtime.detach_quiesced());
    expect_code("LIFECYCLE_DETACHED_RESTORE", aeq_runtime.restore_active(),
                RDMA_SC_INVALID_STATE);
    expect_ok("LIFECYCLE_STATE", aeq_runtime.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("LIFECYCLE_STATE", "detached runtime was reactivated")
  endtask

  // 功能：验证 device-producer recovery 只允许一次 PI/occupancy 提交，且
  //   prepared admission 对缺 image、半有效 route、stale epoch 和非法 MMIO enum 原子拒绝。
  // 输入输出及副作用：无显式参数；构造一笔 AEQ producer recovery 并
  //   四笔 CQ consumer fixture，通过 recovery/query 公开入口观察状态。
  // 失败边界：任一成功前置失败即返回；重复 producer commit/complete
  //   必须返回 INVALID_STATE，所有 malformed admission 必须保持 ACTIVE 且 occupancy=1。
  task automatic test_device_recovery_and_malformed_prepared();
    rdma_queue_runtime producer_runtime;
    rdma_queue_runtime malformed_runtime;
    rdma_queue_pending_operation pending;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_runtime_state_e runtime_state;
    rdma_route_key_t route;
    rdma_reset_epoch_t epoch;
    rdma_status status;
    int unsigned occupancy;

    producer_runtime = rdma_queue_runtime::type_id::create(
      "single_commit_aeq_runtime");
    if (producer_runtime == null) begin
      `uvm_error("DEVICE_RECOVERY_FIXTURE", "runtime allocation failed")
      return;
    end
    route = fixture_route(8'h36);
    epoch = rdma_reset_epoch_t'(64'h336);
    status = producer_runtime.configure(
      queue_handle("single_commit_aeq", RDMA_RESOURCE_AEQ, 36),
      RDMA_QUEUE_RUNTIME_AEQ, 2, 0, 1'b0, 0, 1'b0, 1'b0);
    expect_ok("DEVICE_RECOVERY_CONFIGURE", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.set_route_epoch(route, epoch);
    expect_ok("DEVICE_RECOVERY_AUTHORITY", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.activate();
    expect_ok("DEVICE_RECOVERY_ACTIVATE", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.reserve_device_producer(reservation);
    expect_ok("DEVICE_RECOVERY_RESERVE", status);
    if (status == null || !status.ok() || reservation == null) return;

    pending = rdma_queue_pending_operation::type_id::create(
      "single_commit_aeq_pending");
    if (pending == null) begin
      `uvm_error("DEVICE_RECOVERY_FIXTURE", "pending allocation failed")
      return;
    end
    pending.queue_h = queue_handle("single_commit_aeq",
                                   RDMA_RESOURCE_AEQ, 36);
    pending.kind = RDMA_QUEUE_RUNTIME_AEQ;
    pending.device_producer = 1'b1;
    pending.device_write_attempted = 1'b1;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create(
      "single_commit_cursor");
    pending.next_cursor = rdma_queue_cursor_snapshot::type_id::create(
      "single_commit_next");
    pending.image = rdma_hw_image::type_id::create("single_commit_image");
    pending.failure_status = rdma_status::make(
      RDMA_SC_DMA_TRANSLATION, "injected replayable device failure");
    if (pending.queue_h == null || pending.cursor == null ||
        pending.next_cursor == null || pending.image == null ||
        pending.failure_status == null) begin
      `uvm_error("DEVICE_RECOVERY_FIXTURE", "evidence allocation failed")
      return;
    end
    pending.cursor.index = reservation.index;
    pending.cursor.wrap = reservation.wrap;
    pending.next_cursor.index = 1;
    pending.next_cursor.wrap = 1'b0;
    pending.entry_size = 16;
    pending.entry_offset = 0;
    pending.image.length = 16;
    pending.image.alignment = 16;
    pending.image.endian = RDMA_ENDIAN_BIG;
    pending.image.image_kind = RDMA_IMAGE_AEQE;
    pending.image.hardware_version = RDMA_HW_VERSION;
    pending.image.function_generation = 5;
    for (int unsigned i = 0; i < 16; i++)
      pending.image.bytes.push_back(byte'(i));
    pending.mmio_evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = epoch;
    pending.epoch_valid = 1'b1;
    status = producer_runtime.enter_recovery_prepared(pending);
    expect_ok("DEVICE_RECOVERY_ENTER", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.recover(
      RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1);
    expect_ok("DEVICE_RECOVERY_CONFIRM", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.enable_recovery_commit();
    expect_ok("DEVICE_RECOVERY_GATE", status);
    if (status == null || !status.ok()) return;
    status = producer_runtime.commit_device_producer(reservation);
    expect_ok("DEVICE_RECOVERY_COMMIT", status);
    if (status == null || !status.ok()) return;
    expect_code("DEVICE_RECOVERY_DUPLICATE_COMMIT",
                producer_runtime.commit_device_producer(reservation),
                RDMA_SC_INVALID_STATE);
    status = producer_runtime.complete_recovery_retry();
    expect_ok("DEVICE_RECOVERY_COMPLETE", status);
    if (status == null || !status.ok()) return;
    expect_code("DEVICE_RECOVERY_DUPLICATE_COMPLETE",
                producer_runtime.complete_recovery_retry(),
                RDMA_SC_INVALID_STATE);
    expect_ok("DEVICE_RECOVERY_OCCUPANCY",
              producer_runtime.query_occupancy(occupancy));
    expect_ok("DEVICE_RECOVERY_STATE",
              producer_runtime.query_state(runtime_state));
    if (occupancy != 1 || runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE)
      `uvm_error("DEVICE_RECOVERY_FINAL",
                 "single producer commit was not preserved")

    status = make_consumer_recovery_fixture(
      "malformed_route", 37, 8'h37, RDMA_QUEUE_MMIO_SUCCESS,
      malformed_runtime, pending);
    expect_ok("MALFORMED_ROUTE_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.route_valid = 1'b0;
    expect_code("MALFORMED_ROUTE",
                malformed_runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("MALFORMED_ROUTE_STATE",
              malformed_runtime.query_state(runtime_state));
    expect_ok("MALFORMED_ROUTE_OCCUPANCY",
              malformed_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 1)
      `uvm_error("MALFORMED_ROUTE_ATOMIC",
                 "route rejection changed runtime")

    status = make_consumer_recovery_fixture(
      "malformed_epoch", 38, 8'h38, RDMA_QUEUE_MMIO_SUCCESS,
      malformed_runtime, pending);
    expect_ok("MALFORMED_EPOCH_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.reset_epoch++;
    expect_code("MALFORMED_EPOCH",
                malformed_runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("MALFORMED_EPOCH_STATE",
              malformed_runtime.query_state(runtime_state));
    expect_ok("MALFORMED_EPOCH_OCCUPANCY",
              malformed_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 1)
      `uvm_error("MALFORMED_EPOCH_ATOMIC",
                 "epoch rejection changed runtime")

    status = make_consumer_recovery_fixture(
      "malformed_mmio", 39, 8'h39, RDMA_QUEUE_MMIO_SUCCESS,
      malformed_runtime, pending);
    expect_ok("MALFORMED_MMIO_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.mmio_evidence = rdma_queue_mmio_evidence_e'(3'b111);
    expect_code("MALFORMED_MMIO",
                malformed_runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("MALFORMED_MMIO_STATE",
              malformed_runtime.query_state(runtime_state));
    expect_ok("MALFORMED_MMIO_OCCUPANCY",
              malformed_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 1)
      `uvm_error("MALFORMED_MMIO_ATOMIC",
                 "MMIO rejection changed runtime")

    status = make_consumer_recovery_fixture(
      "malformed_image", 40, 8'h40, RDMA_QUEUE_MMIO_SUCCESS,
      malformed_runtime, pending);
    expect_ok("MALFORMED_IMAGE_FIXTURE", status);
    if (status == null || !status.ok()) return;
    pending.image = null;
    expect_code("MALFORMED_IMAGE",
                malformed_runtime.enter_recovery_prepared(pending),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("MALFORMED_IMAGE_STATE",
              malformed_runtime.query_state(runtime_state));
    expect_ok("MALFORMED_IMAGE_OCCUPANCY",
              malformed_runtime.query_occupancy(occupancy));
    if (runtime_state != RDMA_QUEUE_RUNTIME_ACTIVE || occupancy != 1)
      `uvm_error("MALFORMED_IMAGE_ATOMIC",
                 "image rejection changed runtime")
  endtask

  // 功能：run_phase 安装可控 factory fault，依次运行 runtime 边界场景，再执行
  //   legacy host ledger/wrap/recovery 兼容回归。
  // 输入输出及副作用：phase（输入）由 UVM 提供；task raise/drop objection，
  //   创建本地 fixture 并通过 UVM report 发布全部断言结果。
  // 失败边界：关键 fixture 创建/configure/activate 失败时先 drop objection 再返回；
  //   子 task 自行 disarm 故障窗口，run_phase 不释放任何外部 backend 资源。
  task run_phase(uvm_phase phase);
    rdma_queue_runtime runtime;
    rdma_queue_cursor_snapshot reservation;
    rdma_queue_slot_ledger_entry released[$];
    rdma_queue_pending_operation pending;
    rdma_queue_pending_operation retry_pending;
    rdma_handle queue_h;
    rdma_handle cq_h;
    rdma_handle stale_h;
    rdma_post_send_req request;
    rdma_hw_image image;
    rdma_status status;
    rdma_queue_runtime_state_e runtime_state;
    int unsigned producer_index;
    int unsigned consumer_index;
    int unsigned occupancy;
    bit producer_wrap;
    bit consumer_wrap;

    phase.raise_objection(this);
    configure_factory_faults();
    test_attachment_config_query_is_detached();
    test_activate_without_authority_preserves_boundaries();
    test_device_ring_reserve_commit_and_visibility();
    test_device_consumer_credit_and_recovery();
    test_pending_copy_and_mmio_evidence();
    test_host_configure_empty_ledger_invariant();
    test_copy_ring_state_authority_and_geometry();
    test_copy_ring_state_rejects_retry_confirmation();
    test_mmio_evidence_authority_transitions();
    test_rejected_mmio_transition_preserves_confirmation();
    test_prepared_immutable_evidence_atomicity();
    test_consumer_recovery_commit_invariant();
    test_nonfatal_factory_failures();
    test_device_depth_two_ceq_and_lifecycle();
    test_device_recovery_and_malformed_prepared();
    runtime = rdma_queue_runtime::type_id::create("runtime");
    queue_h = queue_handle("qp", RDMA_RESOURCE_QP, 9);

    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 3,
                               0, 1'b0, 0, 1'b0, 1'b1);
    expect_code("POWER_OF_TWO", status, RDMA_SC_INVALID_ARGUMENT);
    status = runtime.configure(queue_h, RDMA_QUEUE_RUNTIME_SQ, 4,
                               3, 1'b0, 3, 1'b0, 1'b1);
    expect_ok("CONFIGURE", status);
    if (status == null || !status.ok()) begin
      phase.drop_objection(this);
      return;
    end
    status = runtime.set_route_epoch(
      fixture_route(8'h09), rdma_reset_epoch_t'(64'h409));
    expect_ok("AUTHORITY", status);
    if (status == null || !status.ok()) begin
      phase.drop_objection(this);
      return;
    end
    status = runtime.activate();
    expect_ok("ACTIVATE", status);
    if (status == null || !status.ok()) begin
      phase.drop_objection(this);
      return;
    end

    request = rdma_post_send_req::type_id::create("request");
    image = rdma_hw_image::type_id::create("image");
    image.length = 64;
    status = runtime.reserve_producer(reservation);
    expect_ok("RESERVE_WRAP", status);
    if (reservation == null || reservation.index != 3 || reservation.wrap)
      `uvm_error("RESERVE_WRAP", "wrong producer reservation")
    status = runtime.commit_producer(reservation, request, 64'h11, 1'b0,
                                     image);
    expect_ok("COMMIT_WRAP", status);
    expect_ok("COMMIT_WRAP_CURSORS", runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap));
    expect_ok("COMMIT_WRAP_OCCUPANCY",
              runtime.query_occupancy(occupancy));
    if (producer_index != 0 || producer_wrap != 1'b1 || occupancy != 1 ||
        runtime.available_slots() != 3)
      `uvm_error("COMMIT_WRAP", "producer wrap/credit update is wrong")

    // 中文设计：填满剩余 credit，并证明 QUEUE_FULL 拒绝不会发布 reservation。
    for (int unsigned fill_index = 0; fill_index < 3; fill_index++) begin
      expect_ok("RESERVE_FILL", runtime.reserve_producer(reservation));
      expect_ok("COMMIT_FILL", runtime.commit_producer(
        reservation, request, 64'h21 + fill_index, fill_index == 2,
        image));
    end
    reservation = rdma_queue_cursor_snapshot::type_id::create("sentinel");
    reservation.index = 99;
    status = runtime.reserve_producer(reservation);
    expect_code("QUEUE_FULL", status, RDMA_SC_QUEUE_FULL);
    if (reservation != null)
      `uvm_error("QUEUE_FULL", "failed reserve published an output")

    // 中文设计：末项 completion 连续释放其前方全部 unsignaled slot，并按同一
    // wrap 规则推进 CI；重复 completion 必须保持 released 为空。
    status = runtime.match_and_release(2, 1'b1, released);
    expect_ok("RELEASE_CONTIGUOUS", status);
    expect_ok("RELEASE_CURSORS", runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap));
    expect_ok("RELEASE_OCCUPANCY", runtime.query_occupancy(occupancy));
    if (released.size() != 4 || occupancy != 0 ||
        consumer_index != 3 || consumer_wrap != 1'b1)
      `uvm_error("RELEASE_CONTIGUOUS", "contiguous release is wrong")
    released.delete();
    status = runtime.match_and_release(2, 1'b1, released);
    expect_code("DUPLICATE_COMPLETION", status, RDMA_SC_INVALID_STATE);
    if (released.size() != 0)
      `uvm_error("DUPLICATE_COMPLETION", "failed match published slots")

    stale_h = rdma_clone_handle_value(queue_h, "stale runtime handle");
    stale_h.generation++;
    expect_code("GENERATION", runtime.validate_queue_handle(stale_h),
                RDMA_SC_STALE_GENERATION);

    pending = rdma_queue_pending_operation::type_id::create("pending");
    pending.producer = 1'b1;
    pending.cursor = rdma_queue_cursor_snapshot::type_id::create("cursor");
    expect_ok("RECOVERY_CURSOR_QUERY", runtime.query_cursors(
      producer_index, producer_wrap, consumer_index, consumer_wrap));
    pending.cursor.index = producer_index;
    pending.cursor.wrap = producer_wrap;
    expect_ok("ENTER_RECOVERY", runtime.enter_recovery(pending, 1'b1));
    expect_code("AMBIGUOUS_RETRY",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1),
                RDMA_SC_RECOVERY_REQUIRED);
    expect_ok("ABORT_RECOVERY",
              runtime.recover(RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0));
    expect_ok("ABORT_RECOVERY_STATE", runtime.query_state(runtime_state));
    if (runtime_state != RDMA_QUEUE_RUNTIME_DETACHED)
      `uvm_error("ABORT_RECOVERY", "runtime did not detach")

    // CQ/CEQ/AEQ consumer 必须携带完整 route/epoch/image/status authority，
    // 所以 legacy bit API 必须拒绝，同一 evidence 只能从 prepared 入口安装。
    status = make_consumer_recovery_fixture(
      "legacy_cq", 29, 8'h29, RDMA_QUEUE_MMIO_NO_SUBMIT,
      runtime, retry_pending);
    expect_ok("RETRY_FIXTURE", status);
    if (status == null || !status.ok()) begin
      phase.drop_objection(this);
      return;
    end
    status = runtime.enter_recovery(retry_pending, 1'b0);
    expect_code("LEGACY_CQ_REJECT", status, RDMA_SC_INVALID_STATE);
    if (status == null || status.ok()) begin
      phase.drop_objection(this);
      return;
    end
    expect_ok("RETRY_ENTER",
              runtime.enter_recovery_prepared(retry_pending));
    expect_code("RETRY_CONFIRM",
                runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0),
                RDMA_SC_INVALID_ARGUMENT);
    expect_ok("RETRY_ALLOWED",
              runtime.recover(RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1));
    expect_ok("RETRY_PENDING_QUERY", runtime.query_pending(pending));
    if (pending == null)
      `uvm_error("RETRY_ALLOWED", "retry did not retain pending authority")
    phase.drop_objection(this);
  endtask
endclass
