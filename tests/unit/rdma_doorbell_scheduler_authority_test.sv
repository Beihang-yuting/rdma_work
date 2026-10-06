// 目录：测试层 tests/unit。
// 职责：验证 doorbell scheduler 在 model/binding authority 返回空值或错误动态类型时
//   fail-closed，并保持 observed envelope 非空且不触发 Host-memory/PCIe 副作用。
// 依赖：依赖 rdma_doorbell_scheduler_test 的合法 fixture helper、UVM factory wrapper
//   以及 rdma_mock_host_mem/rdma_mock_pcie 调用 trace。
// 所有权与生命周期：测试拥有本地 scheduler、adapter、binding 和 descriptor；传入
//   scheduler 的 adapter 仍是非拥有引用，测试结束前由本 phase 保持有效。

// 设计说明：这些 hostile 类型只破坏 status/type 返回契约，不改变任何硬件位域或
//   外部资源；测试因此能把“边界防御缺失”与正常 doorbell 业务路径分开定位。
class rdma_doorbell_null_validate_model extends rdma_doorbell_model;
  `uvm_object_utils(rdma_doorbell_null_validate_model)

  // 功能：构造一个动态类型合法但 validate() 故意返回 null 的 doorbell model。
  // 输入/输出及副作用：name 传给 rdma_doorbell_model；只初始化本地字段，不接管资源。
  // 失败/边界：null status 仅用于验证 scheduler 的 fail-closed 行为，不能作为业务模型使用。
  function new(string name = "rdma_doorbell_null_validate_model");
    super.new(name);
  endfunction

  // 功能：注入 model validation 的空返回，模拟 hostile factory/model 实现违约。
  // 输入/输出及副作用：无输入；恒定返回 null，不修改 kind/target_h 或外部状态。
  // 失败/边界：调用方必须把 null 转换为非空 INVALID_STATE，禁止直接调用 status.ok()。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 设计说明：该 binding 子类保留真实 identity、BAR 和 DMA 字段，只让 validator
//   返回 null，用于覆盖 preflight 的第一层 authority 边界。
class rdma_doorbell_null_binding_validate extends rdma_function_binding;
  `uvm_object_utils(rdma_doorbell_null_binding_validate)

  // 功能：构造可被 factory 替换的 binding hostile fixture，复用生产默认拓扑。
  // 输入/输出及副作用：name 传给 rdma_function_binding；不创建外部 adapter 或资源。
  // 失败/边界：只有 validate() 被调用时注入故障，其余 identity 读写仍沿生产实现。
  function new(string name = "rdma_doorbell_null_binding_validate");
    super.new(name);
  endfunction

  // 功能：注入 Function binding authority validation 的空返回。
  // 输入/输出及副作用：无输入；恒定返回 null，不修改 binding 的 identity 或镜像字段。
  // 失败/边界：scheduler 必须把该违约归类为 INVALID_STATE，并在任何外部 I/O 前停止。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 设计说明：该 binding fixture 让 UVM clone 入口直接返回 null，用于证明
//   scheduler 的锁内 snapshot 不依赖可覆盖的 clone/type_id 路径。
class rdma_doorbell_binding_clone_fault extends rdma_function_binding;
  `uvm_object_utils(rdma_doorbell_binding_clone_fault)

  // 功能：构造不改变 Function authority 值的 clone-fault fixture。
  // 输入/输出及副作用：name 传给 rdma_function_binding；不创建 adapter 或外部资源。
  // 失败/边界：故障由 clone() 注入；本对象本身的 validate 仍沿基类契约执行。
  function new(string name = "rdma_doorbell_binding_clone_fault");
    super.new(name);
  endfunction

  // 功能：拒绝 binding 的 UVM clone 请求，模拟 detached snapshot 复制边界违约。
  // 输入/输出及副作用：无输入；恒定返回 null，不修改当前 authority 或嵌套值。
  // 失败/边界：该故障只用于验证 scheduler 的 nonfatal snapshot seam，不能
  //   作为生产 binding 使用。
  virtual function uvm_object clone();
    return null;
  endfunction
endclass

// 设计说明：该测试继承既有合法 fixture，专门把 factory/type/status 防御场景置于
//   独立 UVM test，避免故障注入提前终止长期运行的 scheduler 顺序回归。
class rdma_doorbell_scheduler_authority_test extends rdma_doorbell_scheduler_test;
  `uvm_component_utils(rdma_doorbell_scheduler_authority_test)

  // 功能：构造 authority 边界测试组件，沿用父测试的 fixture helper。
  // 输入/输出及副作用：name/parent 传给 uvm_test；构造阶段不配置 adapter 或创建事务。
  // 失败/边界：parent 可为 null；具体故障只在 run_phase 中按场景安装和撤销。
  function new(string name = "rdma_doorbell_scheduler_authority_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行 model/binding hostile 场景，断言非空错误 envelope 和零外部副作用。
  // 输入/输出及副作用：phase 由 UVM 提供；创建 mock adapter、安装短时 factory override，
  //   调用 scheduler.submit_observed 并发布断言；phase 结束前恢复 base type override。
  // 失败/边界：任一场景若 status 为空、错误码不为 INVALID_STATE、effect 非 PRE_SUBMIT_REJECTED
  //   或 adapter 有调用记录即报错；测试不接受 fatal/空句柄作为“通过”。
  task run_phase(uvm_phase phase);
    rdma_mock_call_trace trace;
    rdma_mock_host_mem mem;
    rdma_mock_pcie pcie;
    rdma_host_mem_api mem_api;
    rdma_pcie_api pcie_api;
    rdma_doorbell_scheduler scheduler;
    rdma_function_binding binding;
    rdma_function_binding source_binding;
    rdma_doorbell_null_binding_validate null_binding;
    rdma_doorbell_desc desc;
    rdma_doorbell_submission_result observed;
    uvm_factory factory;
    rdma_cmq_value_factory_fault_wrapper model_fault;
    rdma_doorbell_binding_clone_fault binding_clone;

    phase.raise_objection(this);

    trace = rdma_mock_call_trace::type_id::create("authority_trace");
    mem = rdma_mock_host_mem::type_id::create("authority_mem");
    pcie = rdma_mock_pcie::type_id::create("authority_pcie");
    mem.set_call_trace(trace);
    pcie.set_call_trace(trace);
    mem_api = mem;
    pcie_api = pcie;
    scheduler = rdma_doorbell_scheduler::type_id::create(
      "authority_scheduler"
    );
    expect_status("AUTHORITY_CONFIGURE",
                  scheduler.configure(mem_api, pcie_api), RDMA_SC_OK);

    binding = make_binding("authority_binding", 64'h1234, 7, 3);
    desc = make_desc("authority_desc", binding);
    factory = uvm_factory::get();

    // 场景零：binding 的动态 clone 入口返回 null 时，scheduler 仍必须以
    //   direct detached snapshot 继续 authority 检查，而不能把空 clone 当失败。
    source_binding = binding;
    binding_clone = new("doorbell_binding_clone_fault");
    binding_clone.copy(source_binding);
    binding = binding_clone;
    desc = make_desc("authority_binding_clone_desc", binding);
    trace.clear();
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("AUTHORITY_BINDING_CLONE", observed.status,
                  RDMA_SC_OK);
    if (observed == null || observed.doorbell_result == null ||
        observed.submission_effect != RDMA_SUBMIT_EFFECT_MMIO_VISIBLE)
      `uvm_error("AUTHORITY_BINDING_CLONE",
                 "binding snapshot unexpectedly failed or lost effect")
    binding = source_binding;
    desc = make_desc("authority_desc_after_clone", binding);

    // 场景一：model factory 返回 null；target_kind_status 不能解引用空 model。
    model_fault = new("doorbell_model_null_fault",
                      rdma_doorbell_model::get_type());
    factory.set_type_override_by_type(
      rdma_doorbell_model::get_type(), model_fault, 1'b1
    );
    model_fault.arm(1'b0);
    trace.clear();
    mem.calls.delete();
    pcie.calls.delete();
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("AUTHORITY_MODEL_NULL", observed.status,
                  RDMA_SC_INVALID_STATE);
    if (observed == null || observed.submission_effect !=
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      `uvm_error("AUTHORITY_MODEL_NULL", "null model was not fail-closed")
    if (trace.calls.size() != 0 || mem.calls.size() != 0 ||
        pcie.calls.size() != 0)
      `uvm_error("AUTHORITY_MODEL_NULL", "null model caused external I/O")
    model_fault.disarm();

    // 场景二：factory 返回不兼容动态类型；typed cast 失败也必须转为状态。
    model_fault.arm(1'b1);
    trace.clear();
    mem.calls.delete();
    pcie.calls.delete();
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("AUTHORITY_MODEL_WRONG_TYPE", observed.status,
                  RDMA_SC_INVALID_STATE);
    if (observed == null || observed.submission_effect !=
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      `uvm_error("AUTHORITY_MODEL_WRONG_TYPE",
                 "wrong model type was not fail-closed")
    if (trace.calls.size() != 0 || mem.calls.size() != 0 ||
        pcie.calls.size() != 0)
      `uvm_error("AUTHORITY_MODEL_WRONG_TYPE",
                 "wrong model type caused external I/O")
    model_fault.disarm();

    // 场景三：binding validator 返回 null；authority 入口同样必须保持非空状态。
    // 直接构造 hostile subtype，避免让 binding factory override 改写 fixture
    //   的 constructor-owned identity/BAR 拓扑；source_binding 只提供合法值图。
    source_binding = make_binding("authority_null_binding_source", 64'h5678, 8, 4);
    null_binding = new("authority_null_binding");
    null_binding.copy(source_binding);
    binding = null_binding;
    desc = make_desc("authority_null_binding_desc", binding);
    trace.clear();
    mem.calls.delete();
    pcie.calls.delete();
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("AUTHORITY_BINDING_STATUS_NULL", observed.status,
                  RDMA_SC_INVALID_STATE);
    if (observed == null || observed.submission_effect !=
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      `uvm_error("AUTHORITY_BINDING_STATUS_NULL",
                 "null binding status was not fail-closed")
    if (trace.calls.size() != 0 || mem.calls.size() != 0 ||
        pcie.calls.size() != 0)
      `uvm_error("AUTHORITY_BINDING_STATUS_NULL",
                 "null binding status caused external I/O")

    // 恢复合法 binding fixture，确保下一个场景只命中 model validation 边界。
    binding = source_binding;
    desc = make_desc("authority_model_status_null_desc", binding);

    // 场景四：动态 model 合法但 validate 返回 null；preflight 不能调用 null.ok()。
    // 该场景放在 binding authority 场景之后，避免用“base 类型覆盖 base 类型”
    // 恢复 factory（UVM 会为这种恢复动作产生 TYPDUP warning）。
    factory.set_type_override_by_type(
      rdma_doorbell_model::get_type(),
      rdma_doorbell_null_validate_model::get_type(), 1'b1
    );
    trace.clear();
    mem.calls.delete();
    pcie.calls.delete();
    scheduler.submit_observed(binding, desc, null, observed);
    expect_status("AUTHORITY_MODEL_STATUS_NULL", observed.status,
                  RDMA_SC_INVALID_STATE);
    if (observed == null || observed.submission_effect !=
        RDMA_SUBMIT_EFFECT_PRE_SUBMIT_REJECTED)
      `uvm_error("AUTHORITY_MODEL_STATUS_NULL",
                 "null model status was not fail-closed")
    if (trace.calls.size() != 0 || mem.calls.size() != 0 ||
        pcie.calls.size() != 0)
      `uvm_error("AUTHORITY_MODEL_STATUS_NULL",
                 "null model status caused external I/O")
    phase.drop_objection(this);
  endtask
endclass

// 设计说明：该测试把 reset epoch 当作独立于 Function UID/generation 的
//   authority 代际，故意在同一 Function 的 lock 等待窗口中完成一次 reset，
//   验证等待者不能把旧入口快照升级成新的 MMIO 提交。
class rdma_doorbell_scheduler_reset_epoch_test
  extends rdma_doorbell_scheduler_test;
  `uvm_component_utils(rdma_doorbell_scheduler_reset_epoch_test)

  // 功能：构造 reset epoch 并发边界测试组件，复用基础 scheduler fixture helper。
  // 输入/输出及副作用：name/parent 传给 uvm_test；不在构造阶段配置 adapter 或 semaphore。
  // 失败/边界：parent 可为 null；所有 reset、锁竞争和外部 I/O 断言都在 run_phase 执行。
  function new(string name = "rdma_doorbell_scheduler_reset_epoch_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在持锁的第一笔 doorbell 与等待锁的第二笔 doorbell 之间推进
  //   binding.reset_epoch，并断言第二笔在任何 Host-memory/PCIe I/O 前返回 STALE_GENERATION。
  // 输入/输出及副作用：phase 提供 UVM objection；task 创建 mock adapter、scheduler、
  //   active binding 和两个 descriptor，启动并发 submit，修改 binding authority 后释放阻塞 barrier。
  // 失败/边界：barrier 未进入、reset epoch 配置失败、watchdog 超时、第二笔产生任一
  //   外部调用或未返回 STALE_GENERATION 均报错；第一笔必须仍以原快照成功完成。
  task run_phase(uvm_phase phase);
    rdma_mock_call_trace trace;
    rdma_mock_host_mem mem;
    rdma_doorbell_blocking_pcie blocking_pcie;
    rdma_doorbell_scheduler scheduler;
    rdma_function_binding binding;
    rdma_function_identity route;
    rdma_doorbell_desc first_desc;
    rdma_doorbell_desc second_desc;
    rdma_doorbell_result first_result;
    rdma_doorbell_result second_result;
    rdma_status status;
    rdma_status first_status;
    rdma_status second_status;
    rdma_pcie_api pcie_api;
    rdma_host_mem_api mem_api;
    bit first_done;
    bit second_done;
    bit watchdog_fired;
    bit epoch_update_ok;

    phase.raise_objection(this);

    trace = rdma_mock_call_trace::type_id::create("reset_epoch_trace");
    mem = rdma_mock_host_mem::type_id::create("reset_epoch_mem");
    blocking_pcie = rdma_doorbell_blocking_pcie::type_id::create(
      "reset_epoch_pcie"
    );
    mem.set_call_trace(trace);
    blocking_pcie.set_call_trace(trace);
    mem_api = mem;
    pcie_api = blocking_pcie;

    scheduler = rdma_doorbell_scheduler::type_id::create(
      "reset_epoch_scheduler"
    );
    expect_status("RESET_EPOCH_CONFIGURE",
                  scheduler.configure(mem_api, pcie_api), RDMA_SC_OK);

    binding = make_binding("reset_epoch_binding", 64'h9a9a, 11, 5);
    // make_binding 的 identity epoch 为 0；这里沿同一 dpu_common route 显式建立非零 epoch，
    //   使 scheduler 能区分“未知旧 fixture”与真实 reset 代际漂移。
    route = binding.function_identity_snapshot();
    status = binding.configure_identity_from_legacy_mirrors(
      route.key.root_id, route.key.host_topology_key, route.key.function_kind,
      route.key.vf_index, 64'd1
    );
    if (status == null || !status.ok()) begin
      `uvm_error("RESET_EPOCH_SETUP",
                 "failed to configure non-zero binding reset epoch")
      phase.drop_objection(this);
      return;
    end
    binding.owner_h = binding.make_handle();
    first_desc = make_desc("reset_epoch_first_desc", binding);
    second_desc = make_desc("reset_epoch_second_desc", binding);
    first_desc.timeout = 200ns;
    second_desc.timeout = 200ns;

    blocking_pcie.blocked_function_uid = binding.function_uid;
    blocking_pcie.blocked_method = "dma_visibility_barrier";
    blocking_pcie.block_enabled = 1'b1;
    blocking_pcie.barrier_entered = 1'b0;
    blocking_pcie.release_barrier = 1'b0;
    blocking_pcie.blocked_call_count = 0;
    blocking_pcie.calls.delete();
    mem.calls.delete();
    trace.clear();
    first_done = 1'b0;
    second_done = 1'b0;
    watchdog_fired = 1'b0;
    epoch_update_ok = 1'b0;

    // 第一笔持有 Function lock 并停在 DMA barrier；第二笔只能排队等待。
    fork : reset_epoch_submit_workers
      begin
        scheduler.submit(binding, first_desc, first_result, first_status);
        first_done = 1'b1;
      end
      begin
        wait (blocking_pcie.barrier_entered);
        scheduler.submit(binding, second_desc, second_result, second_status);
        second_done = 1'b1;
      end
    join_none

    // 先确认第一笔已进入外部 barrier，再让第二笔建立 lock waiter；随后
    //   只改 authority 的 reset epoch，绝不修改 Function UID/generation。
    fork : reset_epoch_watchdog
      begin
        wait (blocking_pcie.barrier_entered);
        #1ns;
        status = binding.configure_identity_from_legacy_mirrors(
          route.key.root_id, route.key.host_topology_key, route.key.function_kind,
          route.key.vf_index, 64'd2
        );
        epoch_update_ok = (status != null && status.ok());
        #1ns;
        blocking_pcie.release_barrier = 1'b1;
        wait (first_done && second_done);
      end
      begin
        #100ns;
        watchdog_fired = 1'b1;
        blocking_pcie.release_barrier = 1'b1;
      end
    join_any
    disable reset_epoch_watchdog;

    blocking_pcie.release_barrier = 1'b1;
    wait (first_done && second_done);
    disable reset_epoch_submit_workers;
    blocking_pcie.block_enabled = 1'b0;

    if (watchdog_fired)
      `uvm_error("RESET_EPOCH_WATCHDOG",
                 "reset epoch lock scenario did not complete before deadline")
    if (!epoch_update_ok)
      `uvm_error("RESET_EPOCH_SETUP",
                 "binding reset epoch update failed inside lock wait")
    expect_status("RESET_EPOCH_FIRST", first_status, RDMA_SC_OK);
    expect_status("RESET_EPOCH_SECOND", second_status,
                  RDMA_SC_STALE_GENERATION);
    if (first_result == null)
      `uvm_error("RESET_EPOCH_FIRST", "first snapshot lost its result")
    if (second_result != null)
      `uvm_error("RESET_EPOCH_SECOND",
                 "stale reset epoch published a doorbell result")
    if (blocking_pcie.calls.size() != 3)
      `uvm_error("RESET_EPOCH_SIDE_EFFECT",
                 $sformatf("expected one first-submit PCIe sequence, got %0d calls",
                           blocking_pcie.calls.size()))
    if (mem.calls.size() != 0 || trace.calls.size() != 3)
      `uvm_error("RESET_EPOCH_SIDE_EFFECT",
                 "reset epoch waiter performed unexpected Host-memory I/O")

    phase.drop_objection(this);
  endtask
endclass
