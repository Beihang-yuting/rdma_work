// 目录：测试层 tests/unit/rdma_aeqe_f5_e2e_test.sv。
// 职责：在真实 lifecycle 资源、Host-memory AEQ backing 与 consumer doorbell
//   路径上覆盖四类非 QP AEQE，以及 CQ-flush 双 caller publish 与 partial poll
//   合同，并覆盖 F5-C 的 single-owner lifecycle miss、Function
//   reset-epoch fail-closed 与 target/wire/width 预留前原子拒绝矩阵。
// 依赖：依赖 route-consume 测试提供的 event topology、fixture lifecycle helper、
//   queue-data engine 公开 API 和 mock Host-memory/PCIe 可观察 ledger。
// 所有权与生命周期：本测试只拥有额外创建的 SRQ、其 RC QP、F5-B 各行独立
//   topology、F5-C 每行独立 topology 与局部 factory wrapper；backing/
//   runtime 和外部 adapter 仍由 fixture/helper 管理，并在 run_phase
//   反序释放或复位 factory state。

// 设计说明：四个 ecode 的 owner authority 虽都通过同一个 AEQ ring 发布，但其
// wire owner 坐标并不相同：SRQ 使用 qword1 SRFQN，CQ/CEQ/AEQ 使用 qword0
// split CQN/EQN。本枚举使每个公开合同保持独立，同时避免测试依据实现内部分类器
// 反算期望值而掩盖 ecode 或 owner route 回归。
typedef enum int unsigned {
  RDMA_AEQE_F5_SRQ,
  RDMA_AEQE_F5_CQ,
  RDMA_AEQE_F5_CEQ,
  RDMA_AEQE_F5_AEQ
} rdma_aeqe_f5_positive_e;

// 设计说明：F5-C 每个 negative row 只改变一类 authority 输入。
// 枚举名直接记录测试能捕住的生产回归：kind 分派错误、同 kind
// 实例比较缺失，或 wire ID 没有作为唯一 route authority。
typedef enum int unsigned {
  RDMA_AEQE_F5_TARGET_KIND_MISMATCH,
  RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH,
  RDMA_AEQE_F5_WIRE_ID_MISMATCH
} rdma_aeqe_f5_negative_e;

// 设计说明：width row 需要在 manager 仍认可的范围内生成 SRQ/CQ
// 的首个不可编码 local ID。CEQ/AEQ 的 manager 本身只接受 12 bit，
// 因此两行保持正常 allocator，专门验证 raw split 13th bit 不会别名。
typedef enum int unsigned {
  RDMA_AEQE_F5_WIDTH_SRQ,
  RDMA_AEQE_F5_WIDTH_CQ,
  RDMA_AEQE_F5_WIDTH_CEQ_RAW,
  RDMA_AEQE_F5_WIDTH_AEQ_RAW
} rdma_aeqe_f5_width_e;

// 设计说明：UVM factory override 无可移除接口，本 test-only manager
// 使用一个静态 mode 在构造时只调整目标 kind 的 protected allocator 起点；
// 每行 cleanup 随即调用既有 passthrough reset，不向生产 manager 增加 seam。
class rdma_aeqe_f5_width_manager extends rdma_resource_manager;
  `uvm_object_utils(rdma_aeqe_f5_width_manager)

  static rdma_aeqe_f5_width_e width_mode = RDMA_AEQE_F5_WIDTH_SRQ;

  // 功能：构造 F5-C width manager，并依 width_mode 把 SRQ 或 CQ
  //   的首个 local ID 放在对应 wire 宽度之外。
  // 输入/输出及副作用：name 为输入；只修改新 manager 实例的
  //   next_local_id，不修改全局 registry、已存资源或外部 lifecycle。
  // 失败/边界：CEQ/AEQ raw mode 不绕过 manager 12-bit 上限；未指定
  //   mode 也保持基类分配，宽度拒绝仍由真实 publish route 完成。
  function new(string name = "rdma_aeqe_f5_width_manager");
    super.new(name);
    case (width_mode)
      RDMA_AEQE_F5_WIDTH_SRQ:
        next_local_id[RDMA_RESOURCE_SRQ] = 32'h0000_1000;
      RDMA_AEQE_F5_WIDTH_CQ:
        next_local_id[RDMA_RESOURCE_CQ] = 32'h0008_0000;
      default: begin
      end
    endcase
  endfunction
endclass

// 设计说明：F5-C 的 stale 和 width 行必须拥有独立 topology，且
// 销毁后的 created/attached flag 必须与统一 cleanup 共享。该容器只保存
// 非拥有引用和状态位，所有真实资源仍由 fixture/executor 拥有。
class rdma_aeqe_f5_topology_state extends uvm_object;
  `uvm_object_utils(rdma_aeqe_f5_topology_state)

  rdma_queue_data_engine_fixture fixture;
  rdma_ceq lifecycle_ceq;
  rdma_ceq wrong_ceq;
  rdma_aeq lifecycle_aeq;
  rdma_cq lifecycle_cq;
  rdma_qp event_qp;
  rdma_qp foreign_qp;
  rdma_srq srq;
  rdma_qp srq_qp;
  rdma_srq alternate_srq;
  rdma_qp alternate_srq_qp;
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
  bit srq_created;
  bit srq_qp_created;
  bit srq_qp_attached;
  bit alternate_srq_created;
  bit alternate_srq_qp_created;
  bit alternate_srq_qp_attached;

  // 功能：构造一个空 F5-C topology 状态容器，使任意部分 setup
  //   失败都能进入同一无条件 cleanup。
  // 输入/输出及副作用：name 为输入；所有引用置 null、created/
  //   attached flag 置零，不创建 fixture 或 lifecycle resource。
  // 失败/边界：构造不验证 factory；只有对应公开 create/attach 成功后
  //   才能置位 flag，不得把非空引用当作拥有权证据。
  function new(string name = "rdma_aeqe_f5_topology_state");
    super.new(name);
    fixture = null;
    lifecycle_ceq = null;
    wrong_ceq = null;
    lifecycle_aeq = null;
    lifecycle_cq = null;
    event_qp = null;
    foreign_qp = null;
    srq = null;
    srq_qp = null;
    alternate_srq = null;
    alternate_srq_qp = null;
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
    srq_created = 1'b0;
    srq_qp_created = 1'b0;
    srq_qp_attached = 1'b0;
    alternate_srq_created = 1'b0;
    alternate_srq_qp_created = 1'b0;
    alternate_srq_qp_attached = 1'b0;
  endfunction
endclass

// 设计说明：event topology 的 fixture 由 UVM factory 创建，空对象只会在该边界
// 返回。这个 test-only wrapper 按固定实例名单次返回 null，未命中时委托原 wrapper，
// 因而真实保留 topology 的 status/cleanup 路径，不伪造 setup 的输出状态。
class rdma_aeqe_f5_fixture_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected string target_name;
  protected bit armed_state;
  protected bit fired_state;

  // 功能：构造 F5-A fixture factory wrapper，并保存被覆盖 fixture 类型的原始
  //   wrapper 作为非拥有委托目标。
  // 输入/输出及副作用：name、delegate_value 为输入；初始化一次性故障状态，不修改
  //   UVM factory、topology、tracked fixture 或外部 lifecycle 资源。
  // 失败/边界：delegate_value 为空时未命中创建会返回 null；调用方必须先安装有效
  //   type override，且本 wrapper 不拥有或释放 delegate 所创建的 fixture。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    target_name = "";
    armed_state = 1'b0;
    fired_state = 1'b0;
  endfunction

  // 功能：只对 armed 的精确 fixture 实例名注入一次 null，其余创建保持原 factory
  //   类型的行为，以触发 setup_event_publish_topology 的真实资源耗尽分支。
  // 输入/输出及副作用：name 为 factory instance name；命中时置 fired、自动 disarm
  //   并返回 null，未命中时把创建委托给 delegate，不修改已创建 fixture。
  // 失败/边界：空 target 不会命中；delegate 为空或 delegate 创建失败时返回 null，
  //   调用方必须以 fired 区分本注入与原 factory 的独立分配失败。
  virtual function uvm_object create_object(string name = "");
    if (armed_state && name == target_name) begin
      armed_state = 1'b0;
      fired_state = 1'b1;
      return null;
    end
    if (delegate == null) begin
      return null;
    end
    return delegate.create_object(name);
  endfunction

  // 功能：返回 wrapper 在 UVM factory 诊断中使用的稳定类型名。
  // 输入/输出及副作用：无显式输入；返回构造时保存的 wrapper_type_name，不改变
  //   armed、fired、delegate 或任一 RDMA resource 的所有权。
  // 失败/边界：名称只用于 factory 识别；空名称不改变 create_object 的匹配规则。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：为一次 event topology fixture 创建打开精确名称的 null 注入窗口。
  // 输入/输出及副作用：instance_name 为输入；覆盖旧 target、清零 fired 并置 armed，
  //   不立即创建对象、不重置全局 type override 或修改真实 lifecycle 状态。
  // 失败/边界：空名称不能命中正常 topology；重复 arm 覆盖未消费窗口，调用方必须
  //   在 setup 返回后读取 fired 以证明 factory 边界确实被覆盖。
  function void arm_null_once(string instance_name);
    target_name = instance_name;
    fired_state = 1'b0;
    armed_state = 1'b1;
  endfunction

  // 功能：关闭尚未命中的注入窗口，避免故障泄露到后续正常 topology setup。
  // 输入/输出及副作用：无显式输入；清空 target 和 armed，保留 fired 供紧邻断言
  //   读取，不删除 factory override 或释放 delegate/fixture。
  // 失败/边界：重复调用保持幂等；不能撤销已被 factory 创建的对象或已消费的命中。
  function void disarm();
    target_name = "";
    armed_state = 1'b0;
  endfunction

  // 功能：报告最近一次 arm 是否由精确 fixture 创建实际消费。
  // 输入/输出及副作用：无显式输入；只读并返回 fired_state，不重新 arm、不清零
  //   命中记录，也不影响 factory 或 topology。
  // 失败/边界：未 arm、未命中或 delegate 自行返回 null 时均返回 0。
  function bit fired();
    return fired_state;
  endfunction
endclass

class rdma_aeqe_f5_e2e_test
    extends rdma_queue_event_route_consume_test;
  `uvm_component_utils(rdma_aeqe_f5_e2e_test)

  protected rdma_aeqe_f5_fixture_fault_wrapper fixture_factory_fault;

  // 功能：构造 F5-A AEQE 端到端测试组件，并接入父类既有 lifecycle fixture 与
  //   UVM factory 层级。
  // 输入/输出及副作用：name、parent 是 UVM 层级输入；仅调用 super.new，不创建
  //   SRQ/QP、queue runtime、Host-memory mapping 或 PCIe 事务。
  // 失败/边界：构造阶段不验证 engine 或 topology；run_phase 必须在 setup/create
  //   失败后仍执行所有可达的 cleanup，不能把未初始化对象当作可发布资源。
  function new(string name = "rdma_aeqe_f5_e2e_test",
               uvm_component parent = null);
    super.new(name, parent);
    fixture_factory_fault = new(
      "f5_a_event_fixture_factory_fault",
      rdma_queue_data_engine_fixture::get_type());
  endfunction

  // 功能：setup_f5_c_topology 为一个 F5-C row 创建独立的真实
  //   event topology，并把每个 lifecycle 阶段 flag 保存在共享容器。
  // 输入/输出及副作用：label 仅用于容器命名；topology/status 为输出；
  //   成功时 manager、Host-memory 与 engine 拥有独立资源和 attachment。
  // 失败/边界：容器分配失败返回 RESOURCE_EXHAUSTED；部分 topology
  //   失败保留已置位 flag，caller 必须仍调用 cleanup_f5_c_topology。
  task automatic setup_f5_c_topology(
    string label,
    output rdma_aeqe_f5_topology_state topology,
    output rdma_status status
  );
    topology = rdma_aeqe_f5_topology_state::type_id::create(
      {label, "_topology"});
    if (topology == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 {label, ": topology state allocation failed"});
      return;
    end
    setup_event_publish_topology(
      topology.fixture, topology.lifecycle_ceq, topology.wrong_ceq,
      topology.lifecycle_aeq, topology.lifecycle_cq, topology.event_qp,
      topology.foreign_qp, topology.lifecycle_ceq_created,
      topology.lifecycle_ceq_attached, topology.wrong_ceq_created,
      topology.wrong_ceq_attached, topology.lifecycle_aeq_created,
      topology.lifecycle_aeq_attached, topology.lifecycle_cq_created,
      topology.lifecycle_cq_attached, topology.event_qp_created,
      topology.event_qp_attached, topology.foreign_qp_created,
      topology.foreign_qp_attached, status);
  endtask

  // 功能：cleanup_f5_c_topology 先回收可选 alternate SRQ route，再复用
  //   F5-A epilogue 按 QP→SRQ→CQ→AEQ→CEQ 反依赖顺序完成清理。
  // 输入/输出及副作用：label/topology/transaction_id 为输入，status 为
  //   输出；会调用公开 destroy/detach、factory reset 和 tracked-fixture cleanup。
  // 失败/边界：topology=null 时仍 reset factory 并清理 tracked fixture；
  //   任一 destroy 失败会报告但不阻断后续清理，status 保留首个失败。
  task automatic cleanup_f5_c_topology(
    string label,
    rdma_aeqe_f5_topology_state topology,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_status cleanup_status;
    rdma_status first_failure;

    first_failure = null;
    if (topology == null) begin
      reset_device_publish_factory_state();
      cleanup_tracked_fixtures(cleanup_status);
      status = cleanup_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          {label, ": null cleanup status"}) : cleanup_status;
      return;
    end
    if (topology.fixture != null) begin
      topology.fixture.destroy_lifecycle_owned_qp(
        topology.alternate_srq_qp == null ? null :
          topology.alternate_srq_qp.handle,
        topology.alternate_srq_qp_created,
        topology.alternate_srq_qp_attached,
        transaction_id, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok()) begin
        `uvm_error({label, "_ALT_SRQ_QP_CLEANUP"},
                   "alternate SRQ QP cleanup failed")
        first_failure = cleanup_status == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "alternate SRQ QP cleanup returned null") :
          cleanup_status;
      end
    end
    destroy_lifecycle_owned_srq(
      topology.fixture,
      topology.alternate_srq == null ? null : topology.alternate_srq.handle,
      topology.alternate_srq_created, transaction_id + 1, cleanup_status);
    if ((cleanup_status == null || !cleanup_status.ok()) && first_failure == null) begin
      `uvm_error({label, "_ALT_SRQ_CLEANUP"},
                 "alternate SRQ cleanup failed")
      first_failure = cleanup_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "alternate SRQ cleanup returned null") : cleanup_status;
    end
    cleanup_f5_a_resources(
      topology.fixture, topology.lifecycle_ceq, topology.wrong_ceq,
      topology.lifecycle_aeq, topology.lifecycle_cq, topology.event_qp,
      topology.foreign_qp, topology.srq, topology.srq_qp,
      topology.lifecycle_ceq_created, topology.lifecycle_ceq_attached,
      topology.wrong_ceq_created, topology.wrong_ceq_attached,
      topology.lifecycle_aeq_created, topology.lifecycle_aeq_attached,
      topology.lifecycle_cq_created, topology.lifecycle_cq_attached,
      topology.event_qp_created, topology.event_qp_attached,
      topology.foreign_qp_created, topology.foreign_qp_attached,
      topology.srq_created, topology.srq_qp_created,
      topology.srq_qp_attached, transaction_id + 2, cleanup_status);
    if ((cleanup_status == null || !cleanup_status.ok()) && first_failure == null)
      first_failure = cleanup_status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "F5-C topology cleanup returned null") : cleanup_status;
    status = first_failure == null ? rdma_status::success() : first_failure;
  endtask

  // 功能：make_f5_c_model 从真实 owner 资源构造 SRQ/CQ/CEQ/AEQ
  //   或 Function 的 canonical AEQE，为 stale 与 negative row 提供同一合法基线。
  // 输入/输出及副作用：label/kind/topology/owner_resource 为输入；model/status
  //   为输出；只读真实 producer polarity 并克隆 target handle，不 publish。
  // 失败/边界：fixture/event AEQ/owner 错型、factory 或 handle clone 失败时
  //   model 保持 null 或不完整并返回非成功；Function 行忽略 owner_resource。
  task automatic make_f5_c_model(
    string label,
    rdma_aeqe_f5_positive_e kind,
    rdma_aeqe_f5_topology_state topology,
    rdma_resource owner_resource,
    output rdma_hw_aeqe_model model,
    output rdma_status status
  );
    rdma_srq srq;
    rdma_cq cq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    bit polarity;

    model = null;
    if (topology == null || topology.fixture == null ||
        topology.fixture.engine == null || topology.fixture.aeq == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": model topology is incomplete"});
      return;
    end
    status = topology.fixture.engine.query_runtime_producer_polarity(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) return;
    model = rdma_hw_aeqe_model::type_id::create({label, "_model"});
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 {label, ": model allocation failed"});
      return;
    end
    model.valid = polarity;
    case (kind)
      RDMA_AEQE_F5_SRQ: begin
        if (!$cast(srq, owner_resource) || srq == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": SRQ owner is invalid"});
          return;
        end
        status = clone_test_handle_value(srq.handle, model.target_h);
        model.ecode = 8'h79;
        model.srfq_en = 1'b0;
        model.srfqn = srq.local_srq_id;
        model.srfqe_idx = 16'h1357;
      end
      RDMA_AEQE_F5_CQ: begin
        if (!$cast(cq, owner_resource) || cq == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": CQ owner is invalid"});
          return;
        end
        status = clone_test_handle_value(cq.handle, model.target_h);
        model.ecode = 8'hf4;
        model.packet_opcode = 8'h00;
        model.cqn_eqn_high = cq.local_cq_id >> 6;
        model.cqn_eqn_low = cq.local_cq_id & 6'h3f;
      end
      RDMA_AEQE_F5_CEQ: begin
        if (!$cast(ceq, owner_resource) || ceq == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": CEQ owner is invalid"});
          return;
        end
        status = clone_test_handle_value(ceq.handle, model.target_h);
        model.ecode = 8'hf7;
        model.cqn_eqn_high = ceq.local_ceq_id >> 6;
        model.cqn_eqn_low = ceq.local_ceq_id & 6'h3f;
      end
      RDMA_AEQE_F5_AEQ: begin
        if (!$cast(aeq, owner_resource) || aeq == null) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": AEQ owner is invalid"});
          return;
        end
        status = clone_test_handle_value(aeq.handle, model.target_h);
        model.ecode = 8'hfb;
        model.cqn_eqn_high = aeq.local_aeq_id >> 6;
        model.cqn_eqn_low = aeq.local_aeq_id & 6'h3f;
      end
      default: begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   {label, ": model kind is invalid"});
        return;
      end
    endcase
    if (status == null || !status.ok() || model.target_h == null) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   {label, ": target clone failed"});
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：make_f5_c_function_model 构造 diagnostic 或 TX-flush Function
  //   AEQE，使 control、wrong-target 与 object-pollution 行共享合法基线。
  // 输入/输出及副作用：label/topology/tx_flush 为输入；model/status 为
  //   输出；只读 polarity，并按值克隆 binding 公开 Function handle。
  // 失败/边界：binding/AEQ/engine 不完整、model/handle 分配失败时返回
  //   非成功；TX-flush 只设 ecode=07，不携带任何 object ID。
  task automatic make_f5_c_function_model(
    string label,
    rdma_aeqe_f5_topology_state topology,
    bit tx_flush,
    output rdma_hw_aeqe_model model,
    output rdma_status status
  );
    rdma_handle function_h;
    bit polarity;

    model = null;
    if (topology == null || topology.fixture == null ||
        topology.fixture.binding == null || topology.fixture.engine == null ||
        topology.fixture.aeq == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": Function topology is incomplete"});
      return;
    end
    status = topology.fixture.engine.query_runtime_producer_polarity(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) return;
    function_h = topology.fixture.binding.make_handle();
    model = rdma_hw_aeqe_model::type_id::create({label, "_model"});
    if (function_h == null || model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 {label, ": Function model allocation failed"});
      return;
    end
    status = clone_test_handle_value(function_h, model.target_h);
    if (status == null || !status.ok() || model.target_h == null) return;
    model.valid = polarity;
    model.ecode = tx_flush ? 8'h07 : 8'h1f;
    status = rdma_status::success();
  endtask

  // 功能：check_f5_c_atomic_reject 对一行非法 AEQE 在调用前抓取真实
  //   backing/runtime/外部调用基线，验证指定状态码为预留前原子拒绝。
  // 输入/输出及副作用：label/topology/model/expected_code 为输入；任务
  //   调用真实 publish_aeqe，只允许失败状态返回，不执行修复或 poll。
  // 失败/边界：capture 失败时不 publish；status/result、PI/PW、CI/CW、
  //   used/pending/reservation/backing 或 Host-memory read/write/MMIO 任一变化都报错。
  task automatic check_f5_c_atomic_reject(
    string label,
    rdma_aeqe_f5_topology_state topology,
    rdma_hw_aeqe_model model,
    rdma_status_code_e expected_code
  );
    rdma_queue_device_publish_result published;
    rdma_status status;
    byte before_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    int unsigned writes_before;
    int unsigned reads_before;
    int unsigned mmio_before;
    int unsigned writes_after;
    int unsigned reads_after;
    int unsigned mmio_after;
    bit before_pi_wrap;
    bit before_ci_wrap;

    if (topology == null || topology.fixture == null || model == null) begin
      `uvm_error(label, "atomic reject fixture/model is incomplete")
      return;
    end
    capture_publish_queue_state(
      topology.fixture, topology.fixture.aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi,
      before_pi_wrap, before_ci, before_ci_wrap, before_used, status);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "atomic reject pre-state capture failed")
      return;
    end
    writes_before = count_host_mem_calls(topology.fixture.mem, "write");
    reads_before = count_host_mem_calls(topology.fixture.mem, "read");
    mmio_before = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    published = null;
    topology.fixture.engine.publish_aeqe(
      topology.fixture.aeq.handle, model, published, status);
    writes_after = count_host_mem_calls(topology.fixture.mem, "write");
    reads_after = count_host_mem_calls(topology.fixture.mem, "read");
    mmio_after = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    check_rejected_publish_atomic(
      label, topology.fixture, topology.fixture.aeq, RDMA_QUEUE_RUNTIME_AEQ,
      RDMA_QUEUE_ROLE_AEQ_RING, 16, before_bytes, before_pi, before_pi_wrap,
      before_ci, before_ci_wrap, before_used, published, status, expected_code);
    if (writes_after != writes_before || reads_after != reads_before ||
        mmio_after != mmio_before)
      `uvm_error({label, "_EXTERNAL"},
                 "rejected AEQE entered Host-memory or MMIO")
  endtask

  // 功能：big_endian_qword 将 AEQ backing/image 的连续八个大端字节手工重组为
  //   一个物理 qword，供测试以 codec 之外的字面坐标检查实际存储内容。
  // 输入/输出及副作用：data、offset 是输入；返回 data[offset:offset+7] 的大端值，
  //   不修改 byte array、backing、runtime 或任何 resource handle。
  // 失败/边界：data 为空、offset 后不足八字节时返回全零；调用任务先验证 16-byte
  //   image/backing 长度，因此全零不是合法 AEQE 成功证据。
  function automatic bit [63:0] big_endian_qword(
    byte data[],
    int unsigned offset
  );
    bit [63:0] value;

    value = '0;
    if (data.size() < offset + 8)
      return value;
    for (int unsigned i = 0; i < 8; i++)
      value = (value << 8) | data[offset + i];
    return value;
  endfunction

  // 功能：create_attached_srq_route 创建 owned-backing SRQ，再创建引用该 SRQ
  //   的真实 RC QP 并 attach 到 queue-data engine，建立 SRQ AEQE 的真实 runtime
  //   route，而非只构造 manager 内对象。
  // 输入/输出及副作用：label、fixture、target_cq 为输入；输出 SRQ/QP 和每个创建、
  //   attach 阶段 flag/status。成功会在 manager、CMQ、Host-memory 与 engine 新增资源。
  // 失败/边界：fixture/binding/PD/CQ/executor 缺失、request allocation/create/cast/
  //   attach 失败均保留确定的空输出；flag 只在相应公开操作成功后置位，供无条件 QP→SRQ
  //   epilogue 安全回收部分创建资源。
  task automatic create_attached_srq_route(
    string label,
    rdma_queue_data_engine_fixture fixture,
    rdma_cq target_cq,
    output rdma_srq srq,
    output rdma_qp srq_qp,
    output bit srq_created,
    output bit srq_qp_created,
    output bit srq_qp_attached,
    output rdma_status status
  );
    rdma_create_srq_req srq_request;
    rdma_create_qp_req qp_request;
    rdma_resource created_resource;
    rdma_control_result control_result;

    srq = null;
    srq_qp = null;
    srq_created = 1'b0;
    srq_qp_created = 1'b0;
    srq_qp_attached = 1'b0;
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "F5-A SRQ route is incomplete");
    if (fixture == null || fixture.binding == null || fixture.pd == null ||
        fixture.pd.handle == null || target_cq == null || target_cq.handle == null ||
        fixture.queue_executor == null || fixture.qp_executor == null ||
        fixture.engine == null)
      return;

    srq_request = rdma_create_srq_req::type_id::create({label, "_srq_request"});
    if (srq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ request allocation failed");
      return;
    end
    srq_request.owner = fixture.binding.make_handle();
    srq_request.depth = 16;
    srq_request.max_sge = 4;
    srq_request.limit_threshold = 16;
    srq_request.pd_h = rdma_clone_handle_value(fixture.pd.handle,
                                                {label, "_srq_pd"});
    srq_request.payload_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    if (srq_request.owner == null || srq_request.pd_h == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ handle clone failed");
      return;
    end
    created_resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), srq_request, 64'ha501,
      created_resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                         "F5-A SRQ create returned no control result") :
      control_result.status;
    if (status == null || !status.ok() || created_resource == null ||
        !$cast(srq, created_resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "F5-A SRQ create returned wrong resource");
      return;
    end
    srq_created = 1'b1;

    qp_request = rdma_create_qp_req::type_id::create({label, "_qp_request"});
    if (qp_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ QP request allocation failed");
      return;
    end
    qp_request.owner = fixture.binding.make_handle();
    qp_request.transport = RDMA_TRANSPORT_RC;
    qp_request.sq_depth = 16;
    qp_request.rq_depth = 16;
    qp_request.max_send_sge = 4;
    qp_request.max_recv_sge = 4;
    qp_request.max_inline_data = 32;
    qp_request.pd_h = rdma_clone_handle_value(fixture.pd.handle,
                                               {label, "_qp_pd"});
    qp_request.send_cq_h = rdma_clone_handle_value(target_cq.handle,
                                                    {label, "_send_cq"});
    qp_request.recv_cq_h = rdma_clone_handle_value(target_cq.handle,
                                                    {label, "_recv_cq"});
    qp_request.srq_h = rdma_clone_handle_value(srq.handle, {label, "_srq"});
    qp_request.context_attrs = fixture.make_transport_attrs(
      {label, "_attrs"}, RDMA_TRANSPORT_RC);
    if (qp_request.owner == null || qp_request.pd_h == null ||
        qp_request.send_cq_h == null || qp_request.recv_cq_h == null ||
        qp_request.srq_h == null || qp_request.context_attrs == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ QP request is incomplete");
      return;
    end
    control_result = null;
    fixture.qp_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), qp_request, 64'ha502,
      srq_qp, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                         "F5-A SRQ QP create returned no control result") :
      control_result.status;
    if (status == null || !status.ok() || srq_qp == null)
      return;
    srq_qp_created = 1'b1;
    status = fixture.engine.attach_qp(srq_qp.handle);
    if (status == null || !status.ok())
      return;
    srq_qp_attached = 1'b1;
    status = rdma_status::success();
  endtask

  // 功能：destroy_lifecycle_owned_srq 通过公开 queue executor 回收本测试创建的 SRQ，
  //   保持 QP 已先销毁时的 owner/backing release 顺序。
  // 输入/输出及副作用：fixture、srq_h、created、transaction_id 是输入，status 为输出；
  //   created=1 时向 executor 发出 destroy_locked，不直接改写 manager 内部表。
  // 失败/边界：created=0 是幂等成功；created=1 时 fixture/binding/executor/handle/
  //   transaction 缺失或 control result 无效均返回失败，不阻断后续 topology cleanup。
  task automatic destroy_lifecycle_owned_srq(
    rdma_queue_data_engine_fixture fixture,
    rdma_handle srq_h,
    bit created,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_destroy_resource_req request;
    rdma_control_result control_result;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "F5-A SRQ teardown is incomplete");
    if (!created) begin
      status = rdma_status::success();
      return;
    end
    if (fixture == null || fixture.binding == null || fixture.queue_executor == null ||
        srq_h == null || transaction_id == 0)
      return;
    request = rdma_destroy_resource_req::type_id::create("f5_a_srq_destroy");
    if (request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ destroy request allocation failed");
      return;
    end
    request.owner = fixture.binding.make_handle();
    request.target_h = srq_h;
    if (request.owner == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "F5-A SRQ destroy owner clone failed");
      return;
    end
    control_result = null;
    fixture.queue_executor.destroy_locked(
      fixture.binding, fixture.binding.make_handle(), request, transaction_id,
      control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                         "F5-A SRQ destroy returned no control result") :
      control_result.status;
    if (status == null)
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "F5-A SRQ destroy returned null status");
  endtask

  // 功能：run_non_qp_positive 对一个真实 non-QP owner 进行 AEQE 发布、真实 AEQ
  //   backing 读取和 poll 消费，验证 hand-derived wire qword、cursor、MMIO 与
  //   detached route status 的完整可观察合同。
  // 输入/输出及副作用：label/kind/fixture/event_aeq/owner_resource 为输入，status 为
  //   输出；成功会临时写入并消费 event_aeq 的一个槽位，不改变 owner 的生命周期。
  // 失败/边界：owner null/错型/超 wire 宽度，或 CEQ/AEQ 超 lifecycle 12-bit manager
  //   宽度、publish/backing/poll 或任一 cursor/MMIO 断言失败均返回明确状态；非零
  //   hardware ecode 只要求 operation OK，绝不错误要求 event_status.ok()。
  task automatic run_non_qp_positive(
    string label,
    rdma_aeqe_f5_positive_e positive_kind,
    rdma_queue_data_engine_fixture fixture,
    rdma_aeq event_aeq,
    rdma_resource owner_resource,
    output rdma_status status
  );
    rdma_srq srq;
    rdma_cq cq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_hw_aeqe_model model;
    rdma_hw_aeqe_model polled_model;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status poll_status;
    byte backing_bytes[];
    bit [63:0] backing_qword0;
    bit [63:0] backing_qword1;
    bit [63:0] expected_qword0;
    bit [63:0] expected_qword1;
    int unsigned owner_id;
    int unsigned pi_before;
    int unsigned ci_before;
    int unsigned pi_after_publish;
    int unsigned ci_after_publish;
    int unsigned pi_after_poll;
    int unsigned ci_after_poll;
    int unsigned used_before;
    int unsigned used_after_publish;
    int unsigned used_after_poll;
    int unsigned mmio_before;
    int unsigned mmio_after_publish;
    int unsigned mmio_after_poll;
    bit pi_wrap_before;
    bit ci_wrap_before;
    bit pi_wrap_after_publish;
    bit ci_wrap_after_publish;
    bit pi_wrap_after_poll;
    bit ci_wrap_after_poll;
    bit pending;
    bit polarity;
    bit expected_pi_wrap;
    bit expected_ci_wrap;
    int unsigned expected_pi;
    int unsigned expected_ci;

    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               {label, ": non-QP oracle is incomplete"});
    srq = null;
    cq = null;
    ceq = null;
    aeq = null;
    model = null;
    published = null;
    event_result = null;
    owner_id = 0;
    expected_qword0 = '0;
    expected_qword1 = '0;
    if (fixture == null || fixture.engine == null || fixture.pcie == null ||
        event_aeq == null || event_aeq.handle == null || owner_resource == null ||
        owner_resource.handle == null)
      return;

    case (positive_kind)
      RDMA_AEQE_F5_SRQ: begin
        if (!$cast(srq, owner_resource) || srq == null || srq.handle == null ||
            srq.local_srq_id > 12'hfff) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": SRQ owner is invalid"});
          return;
        end
        owner_id = srq.local_srq_id;
      end
      RDMA_AEQE_F5_CQ: begin
        if (!$cast(cq, owner_resource) || cq == null || cq.handle == null ||
            cq.local_cq_id > 19'h7ffff) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": CQ owner exceeds split width"});
          return;
        end
        owner_id = cq.local_cq_id;
      end
      RDMA_AEQE_F5_CEQ: begin
        if (!$cast(ceq, owner_resource) || ceq == null || ceq.handle == null ||
            ceq.local_ceq_id > 12'hfff) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": CEQ owner exceeds lifecycle width"});
          return;
        end
        owner_id = ceq.local_ceq_id;
      end
      RDMA_AEQE_F5_AEQ: begin
        if (!$cast(aeq, owner_resource) || aeq == null || aeq.handle == null ||
            aeq.local_aeq_id > 12'hfff) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     {label, ": AEQ owner exceeds lifecycle width"});
          return;
        end
        owner_id = aeq.local_aeq_id;
      end
      default: begin
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   {label, ": unknown positive kind"});
        return;
      end
    endcase

    status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pi_before, pi_wrap_before,
      ci_before, ci_wrap_before);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used_before, pending);
    if (status == null || !status.ok() || used_before != 0 || pending) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": pre-publish occupancy is not empty"});
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) return;
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");

    model = rdma_hw_aeqe_model::type_id::create({label, "_model"});
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 {label, ": AEQE model allocation failed"});
      return;
    end
    status = clone_test_handle_value(owner_resource.handle, model.target_h);
    if (status == null || !status.ok() || model.target_h == null) return;
    model.valid = polarity;
    case (positive_kind)
      RDMA_AEQE_F5_SRQ: begin
        model.ecode = 8'h79;
        model.srfq_en = 1'b0;
        model.srfqn = srq.local_srq_id;
        model.srfqe_idx = 16'h1357;
        expected_qword0 = (64'(polarity) << 63) | (64'h79 << 24);
        expected_qword1 = (64'(srq.local_srq_id) << 16) | 64'h1357;
      end
      RDMA_AEQE_F5_CQ: begin
        model.ecode = 8'hf4;
        model.packet_opcode = 8'h00;
        model.qpn = '0;
        model.cqn_eqn_high = owner_id >> 6;
        model.cqn_eqn_low = owner_id & 6'h3f;
        expected_qword0 = (64'(polarity) << 63) |
          (64'(owner_id >> 6) << 40) | (64'hf4 << 24) |
          (64'(owner_id & 6'h3f) << 18);
      end
      RDMA_AEQE_F5_CEQ: begin
        model.ecode = 8'hf7;
        model.qpn = '0;
        model.cqn_eqn_high = owner_id >> 6;
        model.cqn_eqn_low = owner_id & 6'h3f;
        expected_qword0 = (64'(polarity) << 63) |
          (64'(owner_id >> 6) << 40) | (64'hf7 << 24) |
          (64'(owner_id & 6'h3f) << 18);
      end
      RDMA_AEQE_F5_AEQ: begin
        model.ecode = 8'hfb;
        model.qpn = '0;
        model.cqn_eqn_high = owner_id >> 6;
        model.cqn_eqn_low = owner_id & 6'h3f;
        expected_qword0 = (64'(polarity) << 63) |
          (64'(owner_id >> 6) << 40) | (64'hfb << 24) |
          (64'(owner_id & 6'h3f) << 18);
      end
      default: begin
      end
    endcase

    fixture.engine.publish_aeqe(event_aeq.handle, model, published, status);
    if (status == null || !status.ok() || published == null ||
        published.status == null || !published.status.ok() ||
        published.image == null || published.image.length != 16 ||
        published.image.bytes.size() != 16 || published.index != pi_before ||
        published.wrap != pi_wrap_before || !published.occupancy_valid ||
        published.occupancy != 1) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": publish result is incomplete"});
      return;
    end
    status = read_queue_backing_slot(fixture, event_aeq, RDMA_QUEUE_ROLE_AEQ_RING,
                                     published.index, 16, backing_bytes);
    if (status == null || !status.ok() || backing_bytes.size() != 16) return;
    foreach (backing_bytes[i])
      if (backing_bytes[i] !== published.image.bytes[i]) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   $sformatf("%s: backing byte %0d differs", label, i));
        return;
      end
    backing_qword0 = big_endian_qword(backing_bytes, 0);
    backing_qword1 = big_endian_qword(backing_bytes, 8);
    if (backing_qword0 !== expected_qword0 || backing_qword1 !== expected_qword1 ||
        backing_qword0[31:24] != model.ecode || backing_qword0[17:0] != 0) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": literal AEQE qword oracle failed"});
      return;
    end
    if (positive_kind == RDMA_AEQE_F5_SRQ) begin
      if (backing_qword0[59] != 0 || backing_qword1[27:16] != srq.local_srq_id ||
          backing_qword0[52:40] != 0 || backing_qword0[23:18] != 0) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   {label, ": SRQ wire owner is wrong"});
        return;
      end
    end
    else if (((backing_qword0[52:40] << 6) | backing_qword0[23:18]) != owner_id ||
             backing_qword1[27:16] != 0 ||
             (positive_kind == RDMA_AEQE_F5_CQ &&
              backing_qword0[36:32] == 5'h1d)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": split owner or non-flush wire is wrong"});
      return;
    end

    status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pi_after_publish,
      pi_wrap_after_publish, ci_after_publish, ci_wrap_after_publish);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used_after_publish, pending);
    mmio_after_publish = count_pcie_calls(fixture.pcie, "mmio_write");
    expected_pi = pi_before + 1 >= event_aeq.depth ? 0 : pi_before + 1;
    expected_pi_wrap = pi_before + 1 >= event_aeq.depth ? !pi_wrap_before :
                                                        pi_wrap_before;
    if (status == null || !status.ok() || pi_after_publish != expected_pi ||
        pi_wrap_after_publish != expected_pi_wrap || ci_after_publish != ci_before ||
        ci_wrap_after_publish != ci_wrap_before || used_after_publish != 1 || pending ||
        mmio_after_publish != mmio_before) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": publish state/MMIO contract failed"});
      return;
    end

    event_result = null;
    poll_status = null;
    fixture.engine.poll_aeqe(event_aeq.handle, 0, event_result, poll_status);
    if (poll_status == null || !poll_status.ok() || event_result == null ||
        event_result.event_status == null ||
        !event_result.event_status.hardware_code_valid ||
        event_result.event_status.hardware_code[7:0] != model.ecode ||
        event_result.secondary_target_h != null || event_result.event_model == null ||
        !$cast(polled_model, event_result.event_model) || polled_model == null ||
        polled_model.target_h == null ||
        !same_test_handle_value(polled_model.target_h, owner_resource.handle) ||
        polled_model.raw_qword0 != backing_qword0 ||
        polled_model.raw_qword1 != backing_qword1) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": poll route/raw result is wrong"});
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pi_after_poll, pi_wrap_after_poll,
      ci_after_poll, ci_wrap_after_poll);
    if (status == null || !status.ok()) return;
    status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used_after_poll, pending);
    mmio_after_poll = count_pcie_calls(fixture.pcie, "mmio_write");
    expected_ci = ci_before + 1 >= event_aeq.depth ? 0 : ci_before + 1;
    expected_ci_wrap = ci_before + 1 >= event_aeq.depth ? !ci_wrap_before :
                                                        ci_wrap_before;
    if (status == null || !status.ok() || pi_after_poll != pi_after_publish ||
        pi_wrap_after_poll != pi_wrap_after_publish || ci_after_poll != expected_ci ||
        ci_wrap_after_poll != expected_ci_wrap || used_after_poll != 0 || pending ||
        mmio_after_poll != mmio_before + 1) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": poll state/MMIO contract failed"});
      return;
    end
    event_result = null;
    poll_status = null;
    fixture.engine.poll_aeqe(event_aeq.handle, 0, event_result, poll_status);
    if (poll_status == null || poll_status.code != RDMA_SC_QUEUE_EMPTY ||
        event_result != null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 {label, ": second poll did not return empty"});
      return;
    end
    status = rdma_status::success();
  endtask

  // 功能：check_f5_c_single_owner_stale 先合法发布一条 non-QP AEQE 并保存
  //   真实 16B slot，再经公开 executor destroy 使唯一 owner 过期，验证 poll
  //   把明确 stale/released route 当作 miss 丢弃并正常 ack。
  // 输入/输出及副作用：label/kind/topology 为输入；任务发布、读 backing、
  //   销毁 owner/必需依赖，并消费一条 carrier AEQ entry，成功销毁后清零 flag。
  // 失败/边界：SRQ 必须先销毁 attached QP，CQ/CEQ 必须先销毁依赖；
  //   manager 只允许 INVALID_ARGUMENT 或 STALE_GENERATION 且 found=null；raw ID
  //   变化、poll 非 OK/result 非 null 或 PI/CI/used/pending/MMIO 不符均报错。
  task automatic check_f5_c_single_owner_stale(
    string label,
    rdma_aeqe_f5_positive_e kind,
    rdma_aeqe_f5_topology_state topology
  );
    rdma_resource owner_resource;
    rdma_resource found_resource;
    rdma_function_handle function_owner;
    rdma_hw_aeqe_model model;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status status;
    rdma_status destroy_status;
    byte backing_bytes[];
    bit [63:0] raw_qword0;
    bit [63:0] raw_qword1;
    int unsigned released_id;
    int unsigned pi_before_poll;
    int unsigned ci_before_poll;
    int unsigned pi_after_poll;
    int unsigned ci_after_poll;
    int unsigned used_before_poll;
    int unsigned used_after_poll;
    int unsigned mmio_before_poll;
    int unsigned mmio_after_poll;
    bit pi_wrap_before_poll;
    bit ci_wrap_before_poll;
    bit pi_wrap_after_poll;
    bit ci_wrap_after_poll;
    bit pending;
    int unsigned expected_ci;
    bit expected_ci_wrap;

    if (topology == null || topology.fixture == null) begin
      `uvm_error(label, "stale topology is incomplete")
      return;
    end
    case (kind)
      RDMA_AEQE_F5_SRQ: owner_resource = topology.srq;
      RDMA_AEQE_F5_CQ: owner_resource = topology.lifecycle_cq;
      RDMA_AEQE_F5_CEQ: owner_resource = topology.lifecycle_ceq;
      RDMA_AEQE_F5_AEQ: owner_resource = topology.lifecycle_aeq;
      default: owner_resource = null;
    endcase
    make_f5_c_model(label, kind, topology, owner_resource, model, status);
    if (status == null || !status.ok() || model == null) begin
      `uvm_error(label, "stale model setup failed")
      return;
    end
    published = null;
    topology.fixture.engine.publish_aeqe(
      topology.fixture.aeq.handle, model, published, status);
    if (status == null || !status.ok() || published == null) begin
      `uvm_error(label, "stale baseline publish failed")
      return;
    end
    status = read_queue_backing_slot(
      topology.fixture, topology.fixture.aeq, RDMA_QUEUE_ROLE_AEQ_RING,
      published.index, 16, backing_bytes);
    if (status == null || !status.ok() || backing_bytes.size() != 16) begin
      `uvm_error(label, "stale baseline backing read failed")
      return;
    end
    raw_qword0 = big_endian_qword(backing_bytes, 0);
    raw_qword1 = big_endian_qword(backing_bytes, 8);

    // 生命周期设计：销毁顺序只通过公开 executor/detach 路径。
    // 每个成功 destroy 紧邻清零 created/attached flag，使后续统一
    // cleanup 不会重复销毁，也不会利用内部表伪造 stale。
    case (kind)
      RDMA_AEQE_F5_SRQ: begin
        released_id = topology.srq.local_srq_id;
        topology.fixture.destroy_lifecycle_owned_qp(
          topology.srq_qp.handle, topology.srq_qp_created,
          topology.srq_qp_attached, 64'hc101, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.srq_qp_created = 1'b0;
          topology.srq_qp_attached = 1'b0;
        end
        if (destroy_status == null || !destroy_status.ok()) begin
          `uvm_error(label, "SRQ dependent QP destroy failed")
          return;
        end
        destroy_lifecycle_owned_srq(
          topology.fixture, topology.srq.handle, topology.srq_created,
          64'hc102, destroy_status);
        if (destroy_status != null && destroy_status.ok())
          topology.srq_created = 1'b0;
      end
      RDMA_AEQE_F5_CQ: begin
        released_id = topology.lifecycle_cq.local_cq_id;
        topology.fixture.destroy_lifecycle_owned_qp(
          topology.event_qp.handle, topology.event_qp_created,
          topology.event_qp_attached, 64'hc111, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.event_qp_created = 1'b0;
          topology.event_qp_attached = 1'b0;
        end
        if (destroy_status == null || !destroy_status.ok()) begin
          `uvm_error(label, "CQ dependent QP destroy failed")
          return;
        end
        topology.fixture.destroy_lifecycle_owned_queue(
          topology.lifecycle_cq.handle, topology.lifecycle_cq_created,
          topology.lifecycle_cq_attached, 64'hc112, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.lifecycle_cq_created = 1'b0;
          topology.lifecycle_cq_attached = 1'b0;
        end
      end
      RDMA_AEQE_F5_CEQ: begin
        released_id = topology.lifecycle_ceq.local_ceq_id;
        topology.fixture.destroy_lifecycle_owned_qp(
          topology.event_qp.handle, topology.event_qp_created,
          topology.event_qp_attached, 64'hc121, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.event_qp_created = 1'b0;
          topology.event_qp_attached = 1'b0;
        end
        if (destroy_status == null || !destroy_status.ok()) begin
          `uvm_error(label, "CEQ dependent QP destroy failed")
          return;
        end
        topology.fixture.destroy_lifecycle_owned_queue(
          topology.lifecycle_cq.handle, topology.lifecycle_cq_created,
          topology.lifecycle_cq_attached, 64'hc122, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.lifecycle_cq_created = 1'b0;
          topology.lifecycle_cq_attached = 1'b0;
        end
        if (destroy_status == null || !destroy_status.ok()) begin
          `uvm_error(label, "CEQ dependent CQ destroy failed")
          return;
        end
        topology.fixture.destroy_lifecycle_owned_queue(
          topology.lifecycle_ceq.handle, topology.lifecycle_ceq_created,
          topology.lifecycle_ceq_attached, 64'hc123, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.lifecycle_ceq_created = 1'b0;
          topology.lifecycle_ceq_attached = 1'b0;
        end
      end
      RDMA_AEQE_F5_AEQ: begin
        released_id = topology.lifecycle_aeq.local_aeq_id;
        topology.fixture.destroy_lifecycle_owned_queue(
          topology.lifecycle_aeq.handle, topology.lifecycle_aeq_created,
          topology.lifecycle_aeq_attached, 64'hc131, destroy_status);
        if (destroy_status != null && destroy_status.ok()) begin
          topology.lifecycle_aeq_created = 1'b0;
          topology.lifecycle_aeq_attached = 1'b0;
        end
      end
      default: begin
        destroy_status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                           "unknown stale kind");
      end
    endcase
    if (destroy_status == null || !destroy_status.ok()) begin
      `uvm_error(label, "public owner destroy failed")
      return;
    end
    if (!$cast(function_owner, topology.fixture.binding.owner_h) ||
        function_owner == null) begin
      `uvm_error(label, "Function owner cast failed")
      return;
    end
    found_resource = null;
    status = topology.fixture.manager.lookup_local_resource(
      function_owner, owner_resource.handle.kind, released_id, found_resource);
    if (status == null ||
        !(status.code inside {RDMA_SC_INVALID_ARGUMENT,
                              RDMA_SC_STALE_GENERATION}) ||
        found_resource != null) begin
      `uvm_error(label, status == null ?
                 "manager released-route lookup returned null status" :
                 $sformatf("manager released-route lookup code=%0d found=%s",
                           status.code,
                           found_resource == null ? "null" : "non-null"))
      return;
    end
    if ((kind == RDMA_AEQE_F5_SRQ && raw_qword1[27:16] != released_id) ||
        (kind != RDMA_AEQE_F5_SRQ &&
         (((int'(raw_qword0[52:40]) << 6) | int'(raw_qword0[23:18])) !=
          released_id))) begin
      `uvm_error(label, "saved raw route coordinate changed from released ID")
      return;
    end

    status = topology.fixture.engine.query_runtime_cursors(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      pi_before_poll, pi_wrap_before_poll, ci_before_poll, ci_wrap_before_poll);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "stale pre-poll cursor query failed")
      return;
    end
    status = topology.fixture.engine.query_runtime_occupancy(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      used_before_poll, pending);
    if (status == null || !status.ok() || used_before_poll != 1 || pending) begin
      `uvm_error(label, "stale pre-poll occupancy is not one committed entry")
      return;
    end
    mmio_before_poll = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    event_result = null;
    topology.fixture.engine.poll_aeqe(
      topology.fixture.aeq.handle, 0, event_result, status);
    if (status == null || !status.ok() || event_result != null) begin
      `uvm_error(label, "single-owner stale poll did not return OK/null")
      return;
    end
    status = topology.fixture.engine.query_runtime_cursors(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      pi_after_poll, pi_wrap_after_poll, ci_after_poll, ci_wrap_after_poll);
    expected_ci = ci_before_poll + 1 >= topology.fixture.aeq.depth ?
                  0 : ci_before_poll + 1;
    expected_ci_wrap = ci_before_poll + 1 >= topology.fixture.aeq.depth ?
                       !ci_wrap_before_poll : ci_wrap_before_poll;
    if (status == null || !status.ok() || pi_after_poll != pi_before_poll ||
        pi_wrap_after_poll != pi_wrap_before_poll ||
        ci_after_poll != expected_ci || ci_wrap_after_poll != expected_ci_wrap)
      `uvm_error(label, "single-owner stale poll cursor contract failed")
    status = topology.fixture.engine.query_runtime_occupancy(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      used_after_poll, pending);
    mmio_after_poll = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    if (status == null || !status.ok() || used_after_poll != 0 || pending ||
        mmio_after_poll != mmio_before_poll + 1)
      `uvm_error(label, "single-owner stale poll ack contract failed")
  endtask

  // 功能：run_f5_c_single_owner_stale_case 为一类 owner 创建全新
  //   topology，必要时创建真实 attached SRQ route，运行 stale oracle 后清理。
  // 输入/输出及副作用：label/kind 为输入；每次创建并回收独立
  //   manager/backing/attachments，不与其他 stale row 共享被销毁 owner。
  // 失败/边界：setup/SRQ create/stale oracle 失败都只报告本 label；无论
  //   哪一阶段失败都进入 cleanup，factory/tracked fixture 必须复位。
  task automatic run_f5_c_single_owner_stale_case(
    string label,
    rdma_aeqe_f5_positive_e kind
  );
    rdma_aeqe_f5_topology_state topology;
    rdma_status status;
    rdma_status cleanup_status;

    setup_f5_c_topology(label, topology, status);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "single-owner stale topology setup failed")
    end
    else begin
      if (kind == RDMA_AEQE_F5_SRQ) begin
        create_attached_srq_route(
          {label, "_srq"}, topology.fixture, topology.lifecycle_cq,
          topology.srq, topology.srq_qp, topology.srq_created,
          topology.srq_qp_created, topology.srq_qp_attached, status);
      end
      if (status != null && status.ok())
        check_f5_c_single_owner_stale(label, kind, topology);
      else
        `uvm_error(label, "single-owner stale owner setup failed")
    end
    cleanup_f5_c_topology(label, topology, 64'hc180, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error({label, "_CLEANUP"}, "single-owner stale cleanup failed")
  endtask

  // 功能：check_f5_c_function_case 发布一条合法 diagnostic Function AEQE；
  //   control 行验证 Function primary 与正常 ack，stale 行推进公开 binding
  //   reset epoch 后验证 poll 在 backing/Host-memory 访问前 fail-closed 且不消费。
  // 输入/输出及副作用：label/topology/make_stale 为输入；任务写一个
  //   真实 AEQ slot，control 行消费并 MMIO+1；stale 行保留 pre-poll 16-byte
  //   slot，记录 poll 前后 Host-memory 计数，并在计数窗口外重读同一 published.index。
  // 失败/边界：publish/backing 失败终止本行；stale 状态必须非 OK、
  //   result=null，PI/CI/used/MMIO/backing 完全不变且 poll 不得读写 Host-memory；
  //   verification reread 不计入 poll 访问窗口，也不得倒退单调 identity epoch。
  task automatic check_f5_c_function_case(
    string label,
    rdma_aeqe_f5_topology_state topology,
    bit make_stale
  );
    rdma_hw_aeqe_model model;
    rdma_hw_aeqe_model polled_model;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status status;
    byte backing_bytes[];
    byte backing_bytes_after[];
    rdma_reset_epoch_t saved_epoch;
    int unsigned pi_before_poll;
    int unsigned ci_before_poll;
    int unsigned pi_after_poll;
    int unsigned ci_after_poll;
    int unsigned used_before_poll;
    int unsigned used_after_poll;
    int unsigned mmio_before_poll;
    int unsigned mmio_after_poll;
    int unsigned writes_before_poll;
    int unsigned writes_after_poll;
    int unsigned reads_before_poll;
    int unsigned reads_after_poll;
    bit pi_wrap_before_poll;
    bit ci_wrap_before_poll;
    bit pi_wrap_after_poll;
    bit ci_wrap_after_poll;
    bit pending;
    int unsigned expected_ci;
    bit expected_ci_wrap;

    make_f5_c_function_model(label, topology, 1'b0, model, status);
    if (status == null || !status.ok() || model == null) begin
      `uvm_error(label, "Function model setup failed")
      return;
    end
    published = null;
    topology.fixture.engine.publish_aeqe(
      topology.fixture.aeq.handle, model, published, status);
    if (status == null || !status.ok() || published == null) begin
      `uvm_error(label, "Function baseline publish failed")
      return;
    end
    status = read_queue_backing_slot(
      topology.fixture, topology.fixture.aeq, RDMA_QUEUE_ROLE_AEQ_RING,
      published.index, 16, backing_bytes);
    if (status == null || !status.ok() || backing_bytes.size() != 16 ||
        big_endian_qword(backing_bytes, 0)[31:24] != 8'h1f) begin
      `uvm_error(label, "Function actual backing oracle failed")
      return;
    end
    status = topology.fixture.engine.query_runtime_cursors(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      pi_before_poll, pi_wrap_before_poll, ci_before_poll, ci_wrap_before_poll);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "Function pre-poll cursor query failed")
      return;
    end
    status = topology.fixture.engine.query_runtime_occupancy(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      used_before_poll, pending);
    if (status == null || !status.ok() || used_before_poll != 1 || pending) begin
      `uvm_error(label, "Function pre-poll occupancy is invalid")
      return;
    end
    saved_epoch = topology.fixture.binding.function_reset_epoch();
    if (make_stale) begin
      // binding epoch 与 attachment 冻结 epoch 不一致是 authority 失败，
      // 不是可 ack 的 object route miss；poll 前后必须保持 entry 可见。
      status = topology.fixture.advance_binding_reset_epoch(saved_epoch + 1);
      if (status == null || !status.ok()) begin
        `uvm_error(label, "Function reset epoch advance failed")
        return;
      end
    end
    writes_before_poll = count_host_mem_calls(topology.fixture.mem, "write");
    reads_before_poll = count_host_mem_calls(topology.fixture.mem, "read");
    mmio_before_poll = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    event_result = null;
    topology.fixture.engine.poll_aeqe(
      topology.fixture.aeq.handle, 0, event_result, status);
    writes_after_poll = count_host_mem_calls(topology.fixture.mem, "write");
    reads_after_poll = count_host_mem_calls(topology.fixture.mem, "read");
    mmio_after_poll = count_pcie_calls(topology.fixture.pcie, "mmio_write");
    if (make_stale) begin
      if (status == null || status.ok() || event_result != null)
        `uvm_error(label, "stale Function binding did not fail closed")
      if (writes_after_poll != writes_before_poll ||
          reads_after_poll != reads_before_poll)
        `uvm_error(label, "stale Function poll accessed Host-memory")
      status = read_queue_backing_slot(
        topology.fixture, topology.fixture.aeq, RDMA_QUEUE_ROLE_AEQ_RING,
        published.index, 16, backing_bytes_after);
      if (status == null || !status.ok() ||
          backing_bytes_after.size() != backing_bytes.size()) begin
        `uvm_error(label, "stale Function backing reread failed")
      end
      else begin
        foreach (backing_bytes[i]) begin
          if (backing_bytes_after[i] !== backing_bytes[i])
            `uvm_error(label, $sformatf(
              "stale Function poll changed backing byte %0d", i))
        end
      end
    end
    else begin
      polled_model = null;
      if (status == null || !status.ok() || event_result == null ||
          event_result.secondary_target_h != null ||
          event_result.event_model == null ||
          !$cast(polled_model, event_result.event_model) ||
          polled_model == null || polled_model.target_h == null ||
          polled_model.target_h.kind != RDMA_RESOURCE_FUNCTION ||
          !same_test_handle_value(polled_model.target_h, model.target_h))
        `uvm_error(label, "live Function control route/result failed")
    end
    status = topology.fixture.engine.query_runtime_cursors(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      pi_after_poll, pi_wrap_after_poll, ci_after_poll, ci_wrap_after_poll);
    if (make_stale) begin
      if (status == null || !status.ok() || pi_after_poll != pi_before_poll ||
          pi_wrap_after_poll != pi_wrap_before_poll ||
          ci_after_poll != ci_before_poll || ci_wrap_after_poll != ci_wrap_before_poll ||
          mmio_after_poll != mmio_before_poll)
        `uvm_error(label, "stale Function poll changed cursor/MMIO")
    end
    else begin
      expected_ci = ci_before_poll + 1 >= topology.fixture.aeq.depth ?
                    0 : ci_before_poll + 1;
      expected_ci_wrap = ci_before_poll + 1 >= topology.fixture.aeq.depth ?
                         !ci_wrap_before_poll : ci_wrap_before_poll;
      if (status == null || !status.ok() || pi_after_poll != pi_before_poll ||
          pi_wrap_after_poll != pi_wrap_before_poll ||
          ci_after_poll != expected_ci || ci_wrap_after_poll != expected_ci_wrap ||
          mmio_after_poll != mmio_before_poll + 1)
        `uvm_error(label, "live Function control ack contract failed")
    end
    status = topology.fixture.engine.query_runtime_occupancy(
      topology.fixture.aeq.handle, RDMA_QUEUE_RUNTIME_AEQ,
      used_after_poll, pending);
    if (status == null || !status.ok() || pending ||
        used_after_poll != (make_stale ? 1 : 0))
      `uvm_error(label, "Function poll changed occupancy incorrectly")
  endtask

  // 功能：run_f5_c_function_case 在独立 topology 上运行 Function live
  //   control 或 stale-binding fail-closed 用例，结束后无条件复位资源。
  // 输入/输出及副作用：label/make_stale 为输入；创建、使用并回收
  //   一组真实 manager/backing/AEQ attachment，不与 stale owner 矩阵共享。
  // 失败/边界：setup 失败仍清理部分 fixture；任务不会把本行错误
  //   转成 route miss；stale fixture 保持新 epoch 直接走公开 cleanup，
  //   cleanup 失败使用独立 label 报告，不与 production RED 合并。
  task automatic run_f5_c_function_case(string label, bit make_stale);
    rdma_aeqe_f5_topology_state topology;
    rdma_status status;
    rdma_status cleanup_status;

    setup_f5_c_topology(label, topology, status);
    if (status == null || !status.ok())
      `uvm_error(label, "Function topology setup failed")
    else
      check_f5_c_function_case(label, topology, make_stale);
    cleanup_f5_c_topology(label, topology, 64'hc280, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error({label, "_CLEANUP"}, "Function topology cleanup failed")
  endtask

  // 功能：run_f5_c_owner_negative_row 从一个合法 non-QP model 出发，
  //   仅替换 target kind、同 kind instance 或 wire ID 中的一类 authority，
  //   验证生产 preflight 不能用另一个输入掩盖该错误。
  // 输入/输出及副作用：label/kind/negative_kind/topology 为输入；任务只改
  //   新建 detached model，然后执行真实 publish 及完整原子性 oracle。
  // 失败/边界：alternate SRQ/CQ/CEQ/AEQ 必须是真实 live instance；任一
  //   clone/类型转换失败不 publish；三类 row 的字面期望均为 INVALID_STATE。
  task automatic run_f5_c_owner_negative_row(
    string label,
    rdma_aeqe_f5_positive_e kind,
    rdma_aeqe_f5_negative_e negative_kind,
    rdma_aeqe_f5_topology_state topology
  );
    rdma_resource owner_resource;
    rdma_handle replacement_target;
    rdma_hw_aeqe_model model;
    rdma_status status;

    owner_resource = null;
    replacement_target = null;
    case (kind)
      RDMA_AEQE_F5_SRQ: owner_resource = topology.srq;
      RDMA_AEQE_F5_CQ: owner_resource = topology.lifecycle_cq;
      RDMA_AEQE_F5_CEQ: owner_resource = topology.lifecycle_ceq;
      RDMA_AEQE_F5_AEQ: owner_resource = topology.lifecycle_aeq;
      default: begin
      end
    endcase
    make_f5_c_model(label, kind, topology, owner_resource, model, status);
    if (status == null || !status.ok() || model == null) begin
      `uvm_error(label, "negative-row legal baseline model failed")
      return;
    end

    case (negative_kind)
      RDMA_AEQE_F5_TARGET_KIND_MISMATCH: begin
        case (kind)
          RDMA_AEQE_F5_SRQ:
            replacement_target = topology.lifecycle_cq.handle;
          RDMA_AEQE_F5_CQ:
            replacement_target = topology.event_qp.handle;
          RDMA_AEQE_F5_CEQ:
            replacement_target = topology.lifecycle_aeq.handle;
          RDMA_AEQE_F5_AEQ:
            replacement_target = topology.lifecycle_ceq.handle;
          default: replacement_target = null;
        endcase
        status = clone_test_handle_value(replacement_target, model.target_h);
      end
      RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH: begin
        case (kind)
          RDMA_AEQE_F5_SRQ:
            replacement_target = topology.alternate_srq.handle;
          RDMA_AEQE_F5_CQ:
            replacement_target = topology.fixture.cq.handle;
          RDMA_AEQE_F5_CEQ:
            replacement_target = topology.wrong_ceq.handle;
          RDMA_AEQE_F5_AEQ:
            replacement_target = topology.fixture.aeq.handle;
          default: replacement_target = null;
        endcase
        status = clone_test_handle_value(replacement_target, model.target_h);
      end
      RDMA_AEQE_F5_WIRE_ID_MISMATCH: begin
        status = rdma_status::success();
        case (kind)
          RDMA_AEQE_F5_SRQ:
            model.srfqn = topology.alternate_srq.local_srq_id;
          RDMA_AEQE_F5_CQ: begin
            model.cqn_eqn_high = topology.fixture.cq.local_cq_id >> 6;
            model.cqn_eqn_low = topology.fixture.cq.local_cq_id & 6'h3f;
          end
          RDMA_AEQE_F5_CEQ: begin
            model.cqn_eqn_high = topology.wrong_ceq.local_ceq_id >> 6;
            model.cqn_eqn_low = topology.wrong_ceq.local_ceq_id & 6'h3f;
          end
          RDMA_AEQE_F5_AEQ: begin
            model.cqn_eqn_high = topology.fixture.aeq.local_aeq_id >> 6;
            model.cqn_eqn_low = topology.fixture.aeq.local_aeq_id & 6'h3f;
          end
          default:
            status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                       "unknown wire mismatch kind");
        endcase
      end
      default:
        status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "unknown negative-row kind");
    endcase
    if (status == null || !status.ok() || model.target_h == null) begin
      `uvm_error(label, "negative-row mutation setup failed")
      return;
    end
    check_f5_c_atomic_reject(label, topology, model, RDMA_SC_INVALID_STATE);
  endtask

  // 功能：check_f5_c_authority_negative_matrix 在一组真实 topology 上执行
  //   SRQ/CQ/CEQ/AEQ 各三行 authority mismatch，再执行 Function wrong-target
  //   和 object-field pollution 两行，每行都重新 capture 独立基线。
  // 输入/输出及副作用：无显式输入；创建两个真实 SRQ/QP route 以
  //   提供 same-kind alternate，所有 reject 均不应写 AEQ，最后反序销毁。
  // 失败/边界：任一 setup 失败跳过依赖矩阵但仍 cleanup；Function
  //   wrong target 必须 INVALID_STATE，只污染 qpn 的 diagnostic 必须 CODEC_ERROR。
  task automatic check_f5_c_authority_negative_matrix();
    rdma_aeqe_f5_topology_state topology;
    rdma_hw_aeqe_model model;
    rdma_status status;
    rdma_status cleanup_status;

    setup_f5_c_topology("AEQE_F5_NEGATIVE_MATRIX", topology, status);
    if (status != null && status.ok()) begin
      create_attached_srq_route(
        "f5_c_negative_srq", topology.fixture, topology.lifecycle_cq,
        topology.srq, topology.srq_qp, topology.srq_created,
        topology.srq_qp_created, topology.srq_qp_attached, status);
    end
    if (status != null && status.ok()) begin
      create_attached_srq_route(
        "f5_c_negative_alternate_srq", topology.fixture, topology.lifecycle_cq,
        topology.alternate_srq, topology.alternate_srq_qp,
        topology.alternate_srq_created, topology.alternate_srq_qp_created,
        topology.alternate_srq_qp_attached, status);
    end
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_F5_NEGATIVE_MATRIX_SETUP",
                 "authority negative matrix topology/SRQ setup failed")
    end
    else begin
      run_f5_c_owner_negative_row(
        "AEQE_F5_SRQ_TARGET_KIND_MISMATCH", RDMA_AEQE_F5_SRQ,
        RDMA_AEQE_F5_TARGET_KIND_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_SRQ_TARGET_INSTANCE_MISMATCH", RDMA_AEQE_F5_SRQ,
        RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_SRQ_WIRE_ID_MISMATCH", RDMA_AEQE_F5_SRQ,
        RDMA_AEQE_F5_WIRE_ID_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CQ_TARGET_KIND_MISMATCH", RDMA_AEQE_F5_CQ,
        RDMA_AEQE_F5_TARGET_KIND_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CQ_TARGET_INSTANCE_MISMATCH", RDMA_AEQE_F5_CQ,
        RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CQ_WIRE_ID_MISMATCH", RDMA_AEQE_F5_CQ,
        RDMA_AEQE_F5_WIRE_ID_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CEQ_TARGET_KIND_MISMATCH", RDMA_AEQE_F5_CEQ,
        RDMA_AEQE_F5_TARGET_KIND_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CEQ_TARGET_INSTANCE_MISMATCH", RDMA_AEQE_F5_CEQ,
        RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_CEQ_WIRE_ID_MISMATCH", RDMA_AEQE_F5_CEQ,
        RDMA_AEQE_F5_WIRE_ID_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_AEQ_TARGET_KIND_MISMATCH", RDMA_AEQE_F5_AEQ,
        RDMA_AEQE_F5_TARGET_KIND_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_AEQ_TARGET_INSTANCE_MISMATCH", RDMA_AEQE_F5_AEQ,
        RDMA_AEQE_F5_TARGET_INSTANCE_MISMATCH, topology);
      run_f5_c_owner_negative_row(
        "AEQE_F5_AEQ_WIRE_ID_MISMATCH", RDMA_AEQE_F5_AEQ,
        RDMA_AEQE_F5_WIRE_ID_MISMATCH, topology);

      make_f5_c_function_model(
        "AEQE_F5_FUNCTION_WRONG_TARGET", topology, 1'b0, model, status);
      if (status != null && status.ok() && model != null)
        status = clone_test_handle_value(
          topology.lifecycle_cq.handle, model.target_h);
      if (status == null || !status.ok() || model == null ||
          model.target_h == null)
        `uvm_error("AEQE_F5_FUNCTION_WRONG_TARGET",
                   "Function wrong-target model setup failed")
      else
        check_f5_c_atomic_reject(
          "AEQE_F5_FUNCTION_WRONG_TARGET", topology, model,
          RDMA_SC_INVALID_STATE);

      make_f5_c_function_model(
        "AEQE_F5_FUNCTION_OBJECT_POLLUTION", topology, 1'b0, model, status);
      if (status == null || !status.ok() || model == null)
        `uvm_error("AEQE_F5_FUNCTION_OBJECT_POLLUTION",
                   "Function pollution model setup failed")
      else begin
        model.qpn = topology.event_qp.local_qp_id;
        check_f5_c_atomic_reject(
          "AEQE_F5_FUNCTION_OBJECT_POLLUTION", topology, model,
          RDMA_SC_CODEC_ERROR);
      end
    end
    cleanup_f5_c_topology(
      "AEQE_F5_NEGATIVE_MATRIX", topology, 64'hc380, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("AEQE_F5_NEGATIVE_MATRIX_CLEANUP",
                 "authority negative matrix cleanup failed")
  endtask

  // 功能：run_f5_c_factory_reset_smoke 在 width override 复位后创建全新
  //   普通 topology，执行真实 CQ publish/backing/poll 正例以证明全局
  //   resource-manager factory 没有泄漏上一行的 allocator 起点。
  // 输入/输出及副作用：label 为输入；任务创建、写入、消费并
  //   清理一个独立 fixture，不重用 width row 的 manager 或 handle。
  // 失败/边界：setup/positive/cleanup 任一失败均以本 label 报错；
  //   正例要求正常 CQ ID 位于 19-bit wire 内，否则直接判定 factory 泄漏。
  task automatic run_f5_c_factory_reset_smoke(string label);
    rdma_aeqe_f5_topology_state topology;
    rdma_status status;
    rdma_status cleanup_status;

    setup_f5_c_topology(label, topology, status);
    if (status == null || !status.ok() || topology == null ||
        topology.lifecycle_cq == null ||
        topology.lifecycle_cq.local_cq_id > 19'h7ffff) begin
      `uvm_error(label, "factory-reset smoke topology retained wide CQ state")
    end
    else begin
      run_non_qp_positive(
        label, RDMA_AEQE_F5_CQ, topology.fixture, topology.fixture.aeq,
        topology.lifecycle_cq, status);
      if (status == null || !status.ok())
        `uvm_error(label, "factory-reset normal CQ positive failed")
    end
    cleanup_f5_c_topology(label, topology, 64'hc480, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error({label, "_CLEANUP"}, "factory-reset smoke cleanup failed")
  endtask

  // 功能：run_f5_c_width_row 通过 test-only manager factory 构造一个
  //   SRQ/CQ 不可编码的 live owner，或 CEQ/AEQ 第 13 个 raw split bit，
  //   验证 low-bit alias 在 reserve 前以 INVALID_STATE 原子拒绝。
  // 输入/输出及副作用：label/width_kind 为输入；安装一次全局 manager
  //   override，创建真实 topology/model 并执行 publish reject，结束立即 reset。
  // 失败/边界：SRQ 必须精确取得 0x1000，CQ 必须不小于
  //   0x80000；CEQ/AEQ 不伪造 manager owner，只传入 raw split=0x1000。
  //   无论 setup/reject 是否成功都 cleanup/reset，然后立即运行正常正例。
  task automatic run_f5_c_width_row(
    string label,
    rdma_aeqe_f5_width_e width_kind
  );
    rdma_aeqe_f5_topology_state topology;
    rdma_resource owner_resource;
    rdma_hw_aeqe_model model;
    rdma_status status;
    rdma_status cleanup_status;
    rdma_aeqe_f5_positive_e positive_kind;

    reset_device_publish_factory_state();
    rdma_aeqe_f5_width_manager::width_mode = width_kind;
    rdma_resource_manager::type_id::set_type_override(
      rdma_aeqe_f5_width_manager::get_type());
    setup_f5_c_topology(label, topology, status);
    owner_resource = null;
    positive_kind = RDMA_AEQE_F5_CEQ;
    if (status != null && status.ok()) begin
      case (width_kind)
        RDMA_AEQE_F5_WIDTH_SRQ: begin
          positive_kind = RDMA_AEQE_F5_SRQ;
          create_attached_srq_route(
            {label, "_srq"}, topology.fixture, topology.lifecycle_cq,
            topology.srq, topology.srq_qp, topology.srq_created,
            topology.srq_qp_created, topology.srq_qp_attached, status);
          owner_resource = topology.srq;
          if (status == null || !status.ok() || topology.srq == null ||
              topology.srq.local_srq_id != 32'h0000_1000) begin
            `uvm_error(label, "wide SRQ did not retain full manager-valid ID")
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "wide SRQ setup mismatch");
          end
        end
        RDMA_AEQE_F5_WIDTH_CQ: begin
          positive_kind = RDMA_AEQE_F5_CQ;
          owner_resource = topology.lifecycle_cq;
          if (topology.lifecycle_cq == null ||
              topology.lifecycle_cq.local_cq_id < 32'h0008_0000) begin
            `uvm_error(label, "wide CQ did not retain full manager-valid ID")
            status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                       "wide CQ setup mismatch");
          end
        end
        RDMA_AEQE_F5_WIDTH_CEQ_RAW: begin
          positive_kind = RDMA_AEQE_F5_CEQ;
          owner_resource = topology.lifecycle_ceq;
        end
        RDMA_AEQE_F5_WIDTH_AEQ_RAW: begin
          positive_kind = RDMA_AEQE_F5_AEQ;
          owner_resource = topology.lifecycle_aeq;
        end
        default: begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "unknown width row");
        end
      endcase
    end
    if (status == null || !status.ok()) begin
      `uvm_error(label, "width-row topology/owner setup failed")
    end
    else begin
      make_f5_c_model(
        label, positive_kind, topology, owner_resource, model, status);
      if (status != null && status.ok() && model != null &&
          width_kind inside {RDMA_AEQE_F5_WIDTH_CEQ_RAW,
                             RDMA_AEQE_F5_WIDTH_AEQ_RAW}) begin
        // manager 本身不容许 CEQ/AEQ local ID 0x1000；该 raw wire
        // 坐标因此必须是 unknown owner，不得截断为 ID 0 命中。
        model.cqn_eqn_high = 13'h0040;
        model.cqn_eqn_low = 6'h00;
      end
      if (status == null || !status.ok() || model == null)
        `uvm_error(label, "width-row model setup failed")
      else
        check_f5_c_atomic_reject(
          label, topology, model, RDMA_SC_INVALID_STATE);
    end
    cleanup_f5_c_topology(label, topology, 64'hc580, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error({label, "_CLEANUP"}, "width-row cleanup failed")
    // factory reset 由 cleanup helper 在本 row 最后一个 lifecycle destroy 后立即执行；
    // 下一个动作必须是新 fixture 的正常 positive smoke。
    run_f5_c_factory_reset_smoke({label, "_FACTORY_RESET_SMOKE"});
  endtask

  // 功能：check_f5_c_width_contracts 按固定顺序执行 SRQ 12-bit、
  //   CQ 19-bit、CEQ 12-bit 与 AEQ 12-bit 四个 width authority row。
  // 输入/输出及副作用：无显式输入；每行都独立 override/setup/
  //   reject/reset/smoke，不得复用上一行的 manager 或被截断 model。
  // 失败/边界：任一 row 或 smoke 失败只报告稳定 label；本任务结束
  //   前再次 reset factory，确保后续 package tests 看不到 width manager。
  task automatic check_f5_c_width_contracts();
    run_f5_c_width_row("AEQE_F5_WIDE_SRQ_12", RDMA_AEQE_F5_WIDTH_SRQ);
    run_f5_c_width_row("AEQE_F5_WIDE_CQ_19", RDMA_AEQE_F5_WIDTH_CQ);
    run_f5_c_width_row("AEQE_F5_WIDE_CEQ_RAW_12",
                       RDMA_AEQE_F5_WIDTH_CEQ_RAW);
    run_f5_c_width_row("AEQE_F5_WIDE_AEQ_RAW_12",
                       RDMA_AEQE_F5_WIDTH_AEQ_RAW);
    reset_device_publish_factory_state();
  endtask

  // 功能：check_legacy_flush_secondary_required 验证 legacy 四参数 publish 对 CQ
  //   flush 缺失 secondary caller authority 的请求在 reservation 前原子拒绝。
  // 输入/输出及副作用：fixture/event_aeq/primary_cq/secondary_qp 为真实 topology
  //   输入；任务读取 backing、cursor、occupancy、pending、reservation 与外部调用
  //   计数，只在实现错误发布时额外 poll 该条目以隔离后续合同，不改 manager 私有状态。
  // 失败/边界：输入不完整、返回码不是 INVALID_ARGUMENT、result 非空或任一 backing/
  //   runtime/Host-memory/MMIO 状态变化时仅报告指定 contract ID；错误成功后的隔离
  //   poll 不能替代原子性失败证据，也不得隐藏 legacy API 的缺权缺陷。
  task automatic check_legacy_flush_secondary_required(
    rdma_queue_data_engine_fixture fixture,
    rdma_aeq event_aeq,
    rdma_cq primary_cq,
    rdma_qp secondary_qp
  );
    rdma_hw_aeqe_model model;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result discarded_result;
    rdma_queue_pending_operation pending_operation;
    rdma_queue_cursor_snapshot reservation;
    rdma_status status;
    rdma_status query_status;
    byte before_bytes[];
    byte after_bytes[];
    int unsigned before_pi;
    int unsigned before_ci;
    int unsigned before_used;
    int unsigned after_pi;
    int unsigned after_ci;
    int unsigned after_used;
    int unsigned writes_before;
    int unsigned reads_before;
    int unsigned mmio_before;
    int unsigned writes_after_publish;
    int unsigned reads_after_publish;
    int unsigned mmio_after_publish;
    bit before_pi_wrap;
    bit before_ci_wrap;
    bit after_pi_wrap;
    bit after_ci_wrap;
    bit has_pending;
    bit reservation_valid;
    bit polarity;
    bit contract_ok;

    contract_ok = fixture != null && fixture.engine != null &&
      fixture.mem != null && fixture.pcie != null && event_aeq != null &&
      event_aeq.handle != null && primary_cq != null &&
      primary_cq.handle != null && secondary_qp != null &&
      secondary_qp.handle != null;
    if (!contract_ok) begin
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ-flush topology is incomplete")
      return;
    end
    capture_publish_queue_state(
      fixture, event_aeq, RDMA_QUEUE_RUNTIME_AEQ, RDMA_QUEUE_ROLE_AEQ_RING,
      16, before_bytes, before_pi, before_pi_wrap, before_ci, before_ci_wrap,
      before_used, status);
    if (status == null || !status.ok()) begin
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ-flush could not capture the pre-publish state")
      return;
    end
    query_status = fixture.engine.query_runtime_producer_polarity(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (query_status == null || !query_status.ok()) begin
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ-flush could not read producer polarity")
      return;
    end

    model = rdma_hw_aeqe_model::type_id::create("f5_b_legacy_flush_model");
    contract_ok = model != null;
    if (contract_ok) begin
      status = clone_test_handle_value(primary_cq.handle, model.target_h);
      contract_ok = status != null && status.ok() && model.target_h != null;
    end
    if (!contract_ok) begin
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ-flush could not create its detached model")
      return;
    end
    model.valid = polarity;
    model.ecode = 8'hf4;
    model.packet_opcode = 8'h1d;
    model.cqn_eqn_high = primary_cq.local_cq_id >> 6;
    model.cqn_eqn_low = primary_cq.local_cq_id & 6'h3f;
    model.qpn = secondary_qp.local_qp_id;

    writes_before = count_host_mem_calls(fixture.mem, "write");
    reads_before = count_host_mem_calls(fixture.mem, "read");
    mmio_before = count_pcie_calls(fixture.pcie, "mmio_write");
    published = null;
    fixture.engine.publish_aeqe(event_aeq.handle, model, published, status);
    writes_after_publish = count_host_mem_calls(fixture.mem, "write");
    reads_after_publish = count_host_mem_calls(fixture.mem, "read");
    mmio_after_publish = count_pcie_calls(fixture.pcie, "mmio_write");

    contract_ok = status != null && status.code == RDMA_SC_INVALID_ARGUMENT &&
      published == null && writes_after_publish == writes_before &&
      reads_after_publish == reads_before && mmio_after_publish == mmio_before;
    query_status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, after_pi, after_pi_wrap,
      after_ci, after_ci_wrap);
    contract_ok &= query_status != null && query_status.ok() &&
      after_pi == before_pi && after_pi_wrap == before_pi_wrap &&
      after_ci == before_ci && after_ci_wrap == before_ci_wrap;
    query_status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, after_used, has_pending);
    contract_ok &= query_status != null && query_status.ok() &&
      after_used == before_used && !has_pending;
    pending_operation = null;
    query_status = fixture.engine.query_runtime_pending(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pending_operation);
    contract_ok &= query_status != null &&
      query_status.code == RDMA_SC_INVALID_STATE && pending_operation == null;
    reservation_valid = 1'b1;
    reservation = null;
    query_status = fixture.engine.query_runtime_device_reservation(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, reservation_valid, reservation);
    contract_ok &= query_status != null && query_status.ok() &&
      !reservation_valid && reservation == null;
    query_status = read_queue_backing_slot(
      fixture, event_aeq, RDMA_QUEUE_ROLE_AEQ_RING, before_pi, 16, after_bytes);
    contract_ok &= query_status != null && query_status.ok() &&
      after_bytes == before_bytes;

    if (!contract_ok)
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ flush did not reject missing secondary authority atomically")

    // 回归隔离说明：若实现错误提交本应拒绝的条目，取得全部失败快照后只消费该
    // 错误条目恢复空环，避免后续独立合同被前一项失败污染。
    if (status != null && status.ok() && published != null) begin
      discarded_result = null;
      fixture.engine.poll_aeqe(
        event_aeq.handle, 0, discarded_result, query_status);
    end
  endtask

  // 功能：check_cq_flush_route_case 经 sibling 发布合法 CQ flush，再按期望公开
  //   销毁 CQ/QP owner，验证 poll 对三种 partial/miss 组合的结果与 ack 合同。
  // 输入/输出及副作用：label、expect_primary/secondary、真实 topology 及六个
  //   lifecycle flag 为输入或 inout；任务读取真实 backing、按需销毁 primary QP/CQ
  //   或 secondary QP，并消费一条 AEQE，成功销毁时清零 flag 交还统一 cleanup。
  // 失败/边界：publish/backing/destroy/poll、完整 literal qword、typed wire、result
  //   handle 或 CI/used/MMIO 任一不符都只报告 label；两路都 miss 必须
  //   OK+ack+result null，不能改 registry、allocator、attachment 或 decoded model
  //   伪造 route 状态。
  task automatic check_cq_flush_route_case(
    string label,
    bit expect_primary,
    bit expect_secondary,
    rdma_queue_data_engine_fixture fixture,
    rdma_aeq event_aeq,
    rdma_cq primary_cq,
    rdma_qp primary_qp,
    rdma_qp secondary_qp,
    inout bit primary_cq_created,
    inout bit primary_cq_attached,
    inout bit primary_qp_created,
    inout bit primary_qp_attached,
    inout bit secondary_qp_created,
    inout bit secondary_qp_attached
  );
    rdma_hw_aeqe_model model;
    rdma_hw_aeqe_model polled_model;
    rdma_queue_device_publish_result published;
    rdma_queue_event_result event_result;
    rdma_status status;
    rdma_status destroy_status;
    byte backing_bytes[];
    bit [63:0] raw_qword0;
    bit [63:0] raw_qword1;
    bit [63:0] expected_qword0;
    bit [63:0] expected_qword1;
    int unsigned pi_before;
    int unsigned ci_before;
    int unsigned pi_after;
    int unsigned ci_after;
    int unsigned used;
    int unsigned mmio_before_poll;
    int unsigned mmio_after_poll;
    bit pi_wrap_before;
    bit ci_wrap_before;
    bit pi_wrap_after;
    bit ci_wrap_after;
    bit pending;
    bit polarity;
    bit contract_ok;
    int unsigned expected_pi;
    int unsigned expected_ci;
    bit expected_pi_wrap;
    bit expected_ci_wrap;

    contract_ok = fixture != null && fixture.engine != null &&
      fixture.pcie != null && event_aeq != null && event_aeq.handle != null &&
      primary_cq != null && primary_cq.handle != null && primary_qp != null &&
      primary_qp.handle != null && secondary_qp != null &&
      secondary_qp.handle != null;
    if (!contract_ok) begin
      `uvm_error(label, "CQ-flush route-matrix topology is incomplete")
      return;
    end
    status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pi_before, pi_wrap_before,
      ci_before, ci_wrap_before);
    if (status == null || !status.ok()) begin
      `uvm_error(label, "CQ-flush route-matrix case could not read cursors")
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    model = rdma_hw_aeqe_model::type_id::create("f5_b_partial_flush_model");
    contract_ok = status != null && status.ok() && model != null;
    if (contract_ok) begin
      status = clone_test_handle_value(primary_cq.handle, model.target_h);
      contract_ok = status != null && status.ok() && model.target_h != null;
    end
    if (!contract_ok) begin
      `uvm_error(label, "CQ-flush route-matrix model allocation failed")
      return;
    end
    model.valid = polarity;
    model.ecode = 8'hf4;
    model.packet_opcode = 8'h1d;
    model.cqn_eqn_high = primary_cq.local_cq_id >> 6;
    model.cqn_eqn_low = primary_cq.local_cq_id & 6'h3f;
    model.qpn = secondary_qp.local_qp_id;
    // 设计说明：literal oracle 从全零 qword 独立填入协议位段，不调用 DUT
    // codec/helper，也不从实际 backing 反推期望；未赋值位因此必须保持零。
    expected_qword0 = '0;
    expected_qword0[63] = polarity;
    expected_qword0[52:40] = primary_cq.local_cq_id >> 6;
    expected_qword0[36:32] = 5'h1d;
    expected_qword0[31:24] = 8'hf4;
    expected_qword0[23:18] = primary_cq.local_cq_id & 6'h3f;
    expected_qword0[17:0] = secondary_qp.local_qp_id;
    expected_qword1 = 64'h0000_0000_0000_0000;
    published = null;
    fixture.engine.publish_aeqe_with_secondary(
      event_aeq.handle, model, secondary_qp.handle, published, status);
    contract_ok = status != null && status.ok() && published != null &&
      published.image != null && published.image.length == 16 &&
      published.image.bytes.size() == 16 && published.index == pi_before &&
      published.wrap == pi_wrap_before;
    if (contract_ok) begin
      status = read_queue_backing_slot(
        fixture, event_aeq, RDMA_QUEUE_ROLE_AEQ_RING, published.index, 16,
        backing_bytes);
      contract_ok = status != null && status.ok() && backing_bytes.size() == 16;
      if (contract_ok)
        foreach (backing_bytes[i])
          contract_ok &= backing_bytes[i] === published.image.bytes[i];
    end
    if (contract_ok) begin
      raw_qword0 = big_endian_qword(backing_bytes, 0);
      raw_qword1 = big_endian_qword(backing_bytes, 8);
      contract_ok = raw_qword0 === expected_qword0 &&
                    raw_qword1 === expected_qword1;
    end
    if (!contract_ok) begin
      `uvm_error(label, "CQ-flush route-matrix publish/backing oracle failed")
      return;
    end

    contract_ok = 1'b1;
    if (!expect_primary) begin
      fixture.destroy_lifecycle_owned_qp(
        primary_qp.handle, primary_qp_created, primary_qp_attached,
        64'hb501, destroy_status);
      if (destroy_status != null && destroy_status.ok()) begin
        primary_qp_created = 1'b0;
        primary_qp_attached = 1'b0;
      end
      contract_ok &= destroy_status != null && destroy_status.ok();
      fixture.destroy_lifecycle_owned_queue(
        primary_cq.handle, primary_cq_created, primary_cq_attached,
        64'hb502, destroy_status);
      if (destroy_status != null && destroy_status.ok()) begin
        primary_cq_created = 1'b0;
        primary_cq_attached = 1'b0;
      end
      contract_ok &= destroy_status != null && destroy_status.ok();
    end
    if (!expect_secondary) begin
      fixture.destroy_lifecycle_owned_qp(
        secondary_qp.handle, secondary_qp_created, secondary_qp_attached,
        64'hb503, destroy_status);
      if (destroy_status != null && destroy_status.ok()) begin
        secondary_qp_created = 1'b0;
        secondary_qp_attached = 1'b0;
      end
      contract_ok &= destroy_status != null && destroy_status.ok();
    end
    status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used, pending);
    contract_ok &= status != null && status.ok() && used == 1 && !pending;
    mmio_before_poll = count_pcie_calls(fixture.pcie, "mmio_write");
    event_result = null;
    fixture.engine.poll_aeqe(event_aeq.handle, 0, event_result, status);
    polled_model = null;
    contract_ok &= status != null && status.ok();
    if (!expect_primary && !expect_secondary) begin
      contract_ok &= event_result == null;
    end
    else begin
      contract_ok &= event_result != null;
      if (event_result != null) begin
        contract_ok &= event_result.event_status != null &&
          event_result.event_status.hardware_code_valid &&
          event_result.event_status.hardware_code[7:0] == 8'hf4 &&
          event_result.event_model != null &&
          $cast(polled_model, event_result.event_model) && polled_model != null;
      end
      if (polled_model != null) begin
        contract_ok &= expect_primary ?
          (polled_model.target_h != null &&
           same_test_handle_value(polled_model.target_h, primary_cq.handle)) :
          polled_model.target_h == null;
        contract_ok &= expect_secondary ?
          (event_result.secondary_target_h != null &&
           same_test_handle_value(event_result.secondary_target_h,
                                  secondary_qp.handle)) :
          event_result.secondary_target_h == null;
        contract_ok &= polled_model.raw_qwords_valid &&
          polled_model.raw_qword0 == raw_qword0 &&
          polled_model.raw_qword1 == raw_qword1 && polled_model.ecode == 8'hf4 &&
          polled_model.cqn_eqn_high == (primary_cq.local_cq_id >> 6) &&
          polled_model.cqn_eqn_low == (primary_cq.local_cq_id & 6'h3f) &&
          polled_model.qpn == secondary_qp.local_qp_id &&
          polled_model.packet_opcode[4:0] == 5'h1d &&
          polled_model.profile_class_valid && polled_model.profile_owner_valid &&
          polled_model.profile_class == RDMA_AEQE_EVENT_CQ &&
          polled_model.profile_owner_kind == RDMA_RESOURCE_CQ;
      end
    end
    status = fixture.engine.query_runtime_cursors(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, pi_after, pi_wrap_after,
      ci_after, ci_wrap_after);
    expected_ci = ci_before + 1 >= event_aeq.depth ? 0 : ci_before + 1;
    expected_ci_wrap = ci_before + 1 >= event_aeq.depth ? !ci_wrap_before :
                                                        ci_wrap_before;
    expected_pi = pi_before + 1 >= event_aeq.depth ? 0 : pi_before + 1;
    expected_pi_wrap = pi_before + 1 >= event_aeq.depth ? !pi_wrap_before :
                                                        pi_wrap_before;
    contract_ok &= status != null && status.ok() && pi_after == expected_pi &&
      pi_wrap_after == expected_pi_wrap && ci_after == expected_ci &&
      ci_wrap_after == expected_ci_wrap;
    status = fixture.engine.query_runtime_occupancy(
      event_aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, used, pending);
    mmio_after_poll = count_pcie_calls(fixture.pcie, "mmio_write");
    contract_ok &= status != null && status.ok() && used == 0 && !pending &&
      mmio_after_poll == mmio_before_poll + 1;
    if (!contract_ok)
      `uvm_error(label, "CQ-flush route-matrix poll/ack contract failed")
  endtask

  // 功能：run_cq_flush_route_case 为一行 CQ-flush partial/miss matrix 创建独立
  //   topology，执行真实 backing/poll oracle，并在该行结束后完整反序回收。
  // 输入/输出及副作用：label 与两路期望为输入；任务创建 fixture、两组 CQ/QP
  //   route，调用 row oracle 后 cleanup topology、factory 与 tracked fixture。
  // 失败/边界：setup 失败仅以 label 报告且仍清理部分资源；每次调用均独占
  //   topology，已销毁 owner 的 flag 不得泄漏到相邻 matrix row 或重复 destroy。
  task automatic run_cq_flush_route_case(
    string label,
    bit expect_primary,
    bit expect_secondary
  );
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_status status;
    rdma_status cleanup_status;
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
      `uvm_error(label, "CQ-flush route-matrix topology setup failed")
    end
    else begin
      check_cq_flush_route_case(
        label, expect_primary, expect_secondary,
        fixture, fixture.aeq, lifecycle_cq, event_qp, foreign_qp,
        lifecycle_cq_created, lifecycle_cq_attached,
        event_qp_created, event_qp_attached,
        foreign_qp_created, foreign_qp_attached);
    end
    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp,
      lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached,
      lifecycle_aeq_created, lifecycle_aeq_attached,
      lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached,
      foreign_qp_created, foreign_qp_attached);
    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error({label, "_CLEANUP"},
                 "CQ-flush route-matrix fixture cleanup failed")
  endtask

  // 功能：check_f5_b_contracts 先在独立 topology 验证 legacy 缺 secondary 的原子
  //   拒绝，再逐行执行 CQ hit/QP miss、CQ miss/QP hit 与 both miss 完整矩阵。
  // 输入/输出及副作用：无显式输入；legacy 行和每个 matrix row 都独立创建、销毁
  //   lifecycle/backing fixture，不复用已销毁 owner，也不改变生产 factory 类型。
  // 失败/边界：setup/contract/cleanup 异常由对应稳定 ID 报告；legacy 行无论成败
  //   都先结束 cleanup，才进入后续独立矩阵，factory wrapper 最终保持 disarm。
  task automatic check_f5_b_contracts();
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_status status;
    rdma_status cleanup_status;
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
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED",
                 "legacy CQ-flush topology setup failed")
    end
    else begin
      check_legacy_flush_secondary_required(
        fixture, fixture.aeq, lifecycle_cq, foreign_qp);
    end
    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp,
      lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached,
      lifecycle_aeq_created, lifecycle_aeq_attached,
      lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached,
      foreign_qp_created, foreign_qp_attached);
    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("AEQE_F5_LEGACY_FLUSH_SECONDARY_REQUIRED_CLEANUP",
                 "legacy CQ-flush fixture cleanup failed")

    run_cq_flush_route_case(
      "AEQE_F5_CQ_HIT_QP_MISS", 1'b1, 1'b0);
    run_cq_flush_route_case(
      "AEQE_F5_PRIMARY_MISS_SECONDARY_HIT", 1'b0, 1'b1);
    run_cq_flush_route_case(
      "AEQE_F5_BOTH_MISS", 1'b0, 1'b0);
  endtask

  // 功能：check_f5_c_contracts 统一编排四个 single-owner stale、Function
  //   live/stale 边界、target/wire 矩阵与四个 width 原子拒绝行。
  // 输入/输出及副作用：无显式输入；每个 stale/Function/width row
  //   创建独立 topology，authority reject 矩阵只共享未被修改的 live fixture。
  // 失败/边界：某行失败不跳过后续独立 coverage；每行 helper 自行
  //   cleanup/reset，本任务最后再次 reset factory 作为 package 隔离底线。
  task automatic check_f5_c_contracts();
    run_f5_c_single_owner_stale_case(
      "AEQE_F5_STALE_SRQ", RDMA_AEQE_F5_SRQ);
    run_f5_c_single_owner_stale_case(
      "AEQE_F5_STALE_CQ", RDMA_AEQE_F5_CQ);
    run_f5_c_single_owner_stale_case(
      "AEQE_F5_STALE_CEQ", RDMA_AEQE_F5_CEQ);
    run_f5_c_single_owner_stale_case(
      "AEQE_F5_STALE_AEQ", RDMA_AEQE_F5_AEQ);
    run_f5_c_function_case("AEQE_F5_FUNCTION_LIVE_CONTROL", 1'b0);
    run_f5_c_function_case("AEQE_F5_FUNCTION_STALE_BINDING", 1'b1);
    check_f5_c_authority_negative_matrix();
    check_f5_c_width_contracts();
    reset_device_publish_factory_state();
  endtask

  // 功能：configure_fixture_factory_fault 将 F5-A 的透明 fixture wrapper 安装到
  //   UVM factory，使 focused null-fixture 测试可命中真实 topology factory 边界。
  // 输入/输出及副作用：无显式输入；为 rdma_queue_data_engine_fixture 设置本测试
  //   wrapper type override，不创建 fixture，也不改变已建立的 resource ownership。
  // 失败/边界：wrapper 为空时只报告 UVM_ERROR；已安装时重复调用只覆盖为同一透明
  //   wrapper，未 arm 的 create_object 必须完整委托原始类型创建。
  function void configure_fixture_factory_fault();
    uvm_factory factory;

    if (fixture_factory_fault == null) begin
      `uvm_error("F5_A_FACTORY", "F5-A fixture factory wrapper is null")
      return;
    end
    factory = uvm_factory::get();
    factory.set_type_override_by_type(
      rdma_queue_data_engine_fixture::get_type(), fixture_factory_fault, 1'b1);
  endfunction

  // 功能：cleanup_f5_a_resources 按 SRQ QP、SRQ、event topology、factory state、
  //   tracked fixture 的依赖逆序执行 F5-A epilogue，并汇总第一项可观察清理失败。
  // 输入/输出及副作用：fixture、所有资源/created/attached flag 与 transaction_id
  //   为输入，status 为输出；会调用公开 lifecycle cleanup、重置 factory fault 并
  //   清空 inherited tracked fixture，不直接改写 manager 私有状态。
  // 失败/边界：任何单项 cleanup 失败均报告但不阻断后续清理；fixture 为 null 时仅在
  //   SRQ QP 已创建/attach 的矛盾状态报告错误，仍继续 SRQ、topology、factory 与
  //   tracked-fixture cleanup，确保 caller 仍能执行 phase.drop_objection。
  task automatic cleanup_f5_a_resources(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq lifecycle_ceq,
    rdma_ceq wrong_ceq,
    rdma_aeq lifecycle_aeq,
    rdma_cq lifecycle_cq,
    rdma_qp event_qp,
    rdma_qp foreign_qp,
    rdma_srq srq,
    rdma_qp srq_qp,
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
    bit foreign_qp_attached,
    bit srq_created,
    bit srq_qp_created,
    bit srq_qp_attached,
    longint unsigned transaction_id,
    output rdma_status status
  );
    rdma_status cleanup_status;
    longint unsigned cleanup_transaction_id;

    status = rdma_status::success();
    cleanup_transaction_id = transaction_id;
    cleanup_status = rdma_status::success();
    if (fixture == null) begin
      if (srq_qp_created || srq_qp_attached) begin
        cleanup_status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "F5-A null fixture cannot own an SRQ QP cleanup");
        `uvm_error("F5_A_SRQ_QP_CLEANUP", cleanup_status.convert2string())
        status = cleanup_status;
      end
    end
    else begin
      fixture.destroy_lifecycle_owned_qp(
        srq_qp == null ? null : srq_qp.handle,
        srq_qp_created, srq_qp_attached, cleanup_transaction_id++, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok()) begin
        `uvm_error("F5_A_SRQ_QP_CLEANUP", cleanup_status == null ?
                   "F5-A SRQ QP cleanup returned null status" : cleanup_status.convert2string())
        status = cleanup_status == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "F5-A SRQ QP cleanup returned null status") : cleanup_status;
      end
    end
    destroy_lifecycle_owned_srq(
      fixture, srq == null ? null : srq.handle,
      srq_created, cleanup_transaction_id++, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok()) begin
      `uvm_error("F5_A_SRQ_CLEANUP", cleanup_status == null ?
                 "F5-A SRQ cleanup returned null status" : cleanup_status.convert2string())
      if (status == null || status.ok()) begin
        status = cleanup_status == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "F5-A SRQ cleanup returned null status") : cleanup_status;
      end
    end
    cleanup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp,
      lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached,
      lifecycle_aeq_created, lifecycle_aeq_attached,
      lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached,
      foreign_qp_created, foreign_qp_attached);
    reset_device_publish_factory_state();
    cleanup_tracked_fixtures(cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok()) begin
      `uvm_error("F5_A_FIXTURE_CLEANUP", cleanup_status == null ?
                 "F5-A fixture cleanup returned null status" : cleanup_status.convert2string())
      if (status == null || status.ok()) begin
        status = cleanup_status == null ?
          rdma_status::make(RDMA_SC_INVALID_STATE,
                            "F5-A fixture cleanup returned null status") : cleanup_status;
      end
    end
  endtask

  // 功能：check_null_fixture_cleanup_path 通过真实 factory-null 注入执行 topology
  //   失败后的完整 F5-A cleanup，验证该拒绝路径仍可回到 run_phase 的正常 epilogue。
  // 输入/输出及副作用：无显式输入；安装并单次 arm fixture wrapper，调用实际 setup
  //   与 cleanup helper，检查 RESOURCE_EXHAUSTED、无 fixture 与 tracked fixture 清空。
  // 失败/边界：factory 未命中、setup 返回非资源耗尽、产生 fixture、cleanup 非成功或
  //   tracked fixture 残留都会报告 UVM_ERROR；无论断言结果如何都 disarm 防止泄露。
  task automatic check_null_fixture_cleanup_path();
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_srq srq;
    rdma_qp srq_qp;
    rdma_status setup_status;
    rdma_status cleanup_status;
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
    bit srq_created;
    bit srq_qp_created;
    bit srq_qp_attached;

    fixture = null;
    lifecycle_ceq = null;
    wrong_ceq = null;
    lifecycle_aeq = null;
    lifecycle_cq = null;
    event_qp = null;
    foreign_qp = null;
    srq = null;
    srq_qp = null;
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
    srq_created = 1'b0;
    srq_qp_created = 1'b0;
    srq_qp_attached = 1'b0;

    reset_device_publish_factory_state();
    configure_fixture_factory_fault();
    if (fixture_factory_fault == null) begin
      return;
    end
    fixture_factory_fault.arm_null_once("event_publish_fixture");
    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, setup_status);
    if (!fixture_factory_fault.fired() || fixture != null || setup_status == null ||
        setup_status.code != RDMA_SC_RESOURCE_EXHAUSTED) begin
      `uvm_error("F5_A_NULL_FIXTURE_SETUP",
                 "null fixture injection did not reach the expected topology failure")
    end
    cleanup_f5_a_resources(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp, srq, srq_qp,
      lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached,
      lifecycle_aeq_created, lifecycle_aeq_attached,
      lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached,
      foreign_qp_created, foreign_qp_attached,
      srq_created, srq_qp_created, srq_qp_attached,
      64'ha57f, cleanup_status);
    fixture_factory_fault.disarm();
    if (cleanup_status == null || !cleanup_status.ok() ||
        tracked_fixtures.size() != 0) begin
      `uvm_error("F5_A_NULL_FIXTURE_CLEANUP",
                 "null fixture path did not finish every applicable cleanup")
    end
  endtask

  // 功能：run_phase 先验证 F5-A factory-null epilogue 与四类 non-QP 正例，
  //   再执行 F5-B CQ-flush 合同和 F5-C lifecycle/Function/atomic negative 矩阵，
  //   最后 drop objection。
  // 输入/输出及副作用：phase 为 UVM 输入；任务短暂安装/arm test-only factory wrapper，
  //   创建测试资源、写入/消费四条 AEQE，以 UVM_ERROR 报告合同与 cleanup 问题，不修改
  //   生产 manager 内部状态；F5-C width override 每行立即 reset 并跟随正例。
  // 失败/边界：factory-null、topology 或 SRQ route 创建失败时跳过依赖正例但不跳过
  //   applicable cleanup；任一 F5-A/B/C 行失败不阻断随后独立用例，
  //   QP/SRQ/topology/factory/fixture cleanup 后始终到达 phase.drop_objection。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_ceq lifecycle_ceq;
    rdma_ceq wrong_ceq;
    rdma_aeq lifecycle_aeq;
    rdma_cq lifecycle_cq;
    rdma_qp event_qp;
    rdma_qp foreign_qp;
    rdma_srq srq;
    rdma_qp srq_qp;
    rdma_status status;
    rdma_status cleanup_status;
    longint unsigned transaction_id;
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
    bit srq_created;
    bit srq_qp_created;
    bit srq_qp_attached;

    fixture = null;
    lifecycle_ceq = null;
    wrong_ceq = null;
    lifecycle_aeq = null;
    lifecycle_cq = null;
    event_qp = null;
    foreign_qp = null;
    srq = null;
    srq_qp = null;
    lifecycle_ceq_created = 0;
    lifecycle_ceq_attached = 0;
    wrong_ceq_created = 0;
    wrong_ceq_attached = 0;
    lifecycle_aeq_created = 0;
    lifecycle_aeq_attached = 0;
    lifecycle_cq_created = 0;
    lifecycle_cq_attached = 0;
    event_qp_created = 0;
    event_qp_attached = 0;
    foreign_qp_created = 0;
    foreign_qp_attached = 0;
    srq_created = 0;
    srq_qp_created = 0;
    srq_qp_attached = 0;
    transaction_id = 64'ha580;

    phase.raise_objection(this);
    check_null_fixture_cleanup_path();
    setup_event_publish_topology(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq, event_qp,
      foreign_qp, lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached, lifecycle_aeq_created,
      lifecycle_aeq_attached, lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached, foreign_qp_created,
      foreign_qp_attached, status);
    if (status == null || !status.ok()) begin
      `uvm_error("F5_A_SETUP", status == null ?
                 "F5-A topology setup returned null status" : status.convert2string())
    end
    else begin
      create_attached_srq_route("f5_a_srq", fixture, lifecycle_cq, srq, srq_qp,
                                srq_created, srq_qp_created, srq_qp_attached, status);
      if (status == null || !status.ok()) begin
        `uvm_error("F5_A_SRQ_ROUTE", status == null ?
                   "F5-A SRQ route returned null status" : status.convert2string())
      end
      else begin
        run_non_qp_positive("F5_A_SRQ", RDMA_AEQE_F5_SRQ, fixture, fixture.aeq,
                            srq, status);
        if (status == null || !status.ok())
          `uvm_error("F5_A_SRQ", status == null ? "SRQ positive returned null status" :
                     status.convert2string())
      end
      run_non_qp_positive("F5_A_CQ", RDMA_AEQE_F5_CQ, fixture, fixture.aeq,
                          lifecycle_cq, status);
      if (status == null || !status.ok())
        `uvm_error("F5_A_CQ", status == null ? "CQ positive returned null status" :
                   status.convert2string())
      run_non_qp_positive("F5_A_CEQ", RDMA_AEQE_F5_CEQ, fixture, fixture.aeq,
                          lifecycle_ceq, status);
      if (status == null || !status.ok())
        `uvm_error("F5_A_CEQ", status == null ? "CEQ positive returned null status" :
                   status.convert2string())
      run_non_qp_positive("F5_A_AEQ", RDMA_AEQE_F5_AEQ, fixture, fixture.aeq,
                          lifecycle_aeq, status);
      if (status == null || !status.ok())
        `uvm_error("F5_A_AEQ", status == null ? "AEQ positive returned null status" :
                   status.convert2string())
    end

    cleanup_f5_a_resources(
      fixture, lifecycle_ceq, wrong_ceq, lifecycle_aeq, lifecycle_cq,
      event_qp, foreign_qp, srq, srq_qp,
      lifecycle_ceq_created, lifecycle_ceq_attached,
      wrong_ceq_created, wrong_ceq_attached,
      lifecycle_aeq_created, lifecycle_aeq_attached,
      lifecycle_cq_created, lifecycle_cq_attached,
      event_qp_created, event_qp_attached,
      foreign_qp_created, foreign_qp_attached,
      srq_created, srq_qp_created, srq_qp_attached,
      transaction_id, cleanup_status);
    check_f5_b_contracts();
    check_f5_c_contracts();
    phase.drop_objection(this);
  endtask
endclass
