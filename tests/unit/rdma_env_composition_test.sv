// 目录：测试层 tests/unit/rdma_env_composition_test.sv。
// 职责：验证 rdma_env 四种装配模式、配置快照、可选适配器能力门控和 responder seal。
// 依赖：依赖 rdma_core_pkg 中的 rdma_env/rdma_env_config 及 UVM；不引入外部 VIP。
// 所有权与生命周期：测试拥有配置和 env fixture；适配器句柄若注入则由测试创建，env 只保存非拥有引用。

// 设计说明：该 wrapper 只替代本测试中的单个 UVM object registry，验证
// rdma_env.configure() 在候选 factory 返回 null 时保留旧组合；关闭窗口后继续
// 委托原 registry，避免把故障注入传播到其他测试。
class rdma_env_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected bit armed_state;

  // 功能：保存目标类型的原 registry，并初始化关闭故障的 wrapper。
  // 输入/输出及副作用：name/delegate_value 为输入；保存非拥有 delegate，不创建 env 对象。
  // 失败/边界：delegate_value 为空时关闭窗口也返回 null，调用方必须检查 factory fixture。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    armed_state = 1'b0;
  endfunction

  // 功能：在故障窗口返回 null，否则转发原 registry 的 object 创建请求。
  // 输入/输出及副作用：name 为 UVM object 名；返回候选对象或 null，不修改 env 组合。
  // 失败/边界：armed 时始终返回 null；delegate 缺失时同样 fail-closed。
  virtual function uvm_object create_object(string name = "");
    if (armed_state || delegate == null)
      return null;
    return delegate.create_object(name);
  endfunction

  // 功能：返回 wrapper 在 UVM factory 中显示的稳定类型名。
  // 输入/输出及副作用：无输入；只读返回 wrapper_type_name，不创建或修改对象。
  // 失败/边界：名称仅供 factory 诊断，不可替代动态类型检查。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：开启 null factory 故障窗口。
  // 输入/输出及副作用：无输入输出；设置 armed_state，后续 create_object 返回 null。
  // 失败/边界：重复开启只覆盖同一窗口，不替换 delegate 或 factory 注册。
  function void arm();
    armed_state = 1'b1;
  endfunction

  // 功能：关闭 null factory 故障窗口并恢复原 registry 委托。
  // 输入/输出及副作用：无输入输出；清除 armed_state，不改变已提交 env 组合。
  // 失败/边界：重复关闭幂等；type override 保留供本测试后续窗口使用。
  function void disarm();
    armed_state = 1'b0;
  endfunction
endclass

class rdma_env_composition_test extends uvm_test;
  `uvm_component_utils(rdma_env_composition_test)

  rdma_env envs[4];
  rdma_env_config cfgs[4];
  bit fatal_seen[string];
  protected uvm_object_wrapper saved_cfg_override;
  protected uvm_object_wrapper saved_queue_override;

  class env_fatal_catcher extends uvm_report_catcher;
    bit caught[string];
    // 功能：构造 negative-build fatal 捕获器，初始化按 report ID 的捕获账本。
    // 输入/输出及副作用：name 为 UVM 对象名；只建立本地 caught map。
    // 失败/边界：非 RDMA_ENV_* fatal 继续抛出，避免掩盖无关结构错误。
    function new(string name = "env_fatal_catcher"); super.new(name); endfunction
    // 功能：捕获 rdma_env 对缺失 cfg 或 required adapter 发出的 fatal，并将其转换为 CAUGHT 供负测试断言。
    // 输入/输出及副作用：无显式输入；更新 caught[report_id]，不改变 env 配置。
    // 失败/边界：仅捕获 RDMA_ENV_CFG/PCIE/HOST/NET，其他报告保持 THROW。
    virtual function action_e catch();
      if (get_severity() == UVM_FATAL && get_id().len() >= 9 &&
          get_id().substr(0, 8) == "RDMA_ENV_") begin
        caught[get_id()] = 1'b1;
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass
  env_fatal_catcher catcher;

  // 功能：恢复本测试覆盖的 env_config/queue_data factory 到进入测试前的 override。
  // 输入/输出及副作用：无输入；仅在原 override 不是请求类型自身时写回全局 factory，
  //   避免 UVM 对 base->base 的清理调用发出 TYPDUP/TPREGR warning。
  // 失败/边界：只应在故障 wrapper 关闭后调用；若原 factory 无显式 override，则保留
  //   已 disarm 的 passthrough wrapper，行为等价且不会产生 warning。
  function automatic void reset_env_factory_state();
    uvm_factory factory;

    factory = uvm_factory::get();
    if (saved_cfg_override != null &&
        saved_cfg_override != rdma_env_config::get_type())
      factory.set_type_override_by_type(
        rdma_env_config::get_type(), saved_cfg_override, 1'b1);
    if (saved_queue_override != null &&
        saved_queue_override != rdma_queue_data_engine::get_type())
      factory.set_type_override_by_type(
        rdma_queue_data_engine::get_type(), saved_queue_override, 1'b1);
  endfunction

  // 功能：构造组合层测试组件并建立空的配置/env 句柄。
  // 输入/输出及副作用：name、parent 为 UVM 层级参数；只初始化本地句柄，不创建外部 adapter。
  // 失败/边界：构造阶段不验证配置；缺少 cfg 或 required adapter 的拒绝由 rdma_env.build_phase 负责。
  function new(string name = "rdma_env_composition_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 test build 阶段注入 core-only 配置并取得待测 rdma_env，验证配置通过 UVM config_db 传递。
  // 输入/输出及副作用：无显式输入；向 config_db 写入 cfg，UVM 随后调用 env.build_phase；不创建 pcie_env/axis_env 子组件。
  // 失败/边界：配置对象为空或 validate 失败时 env 必须 fatal；本测试使用合法 core-only 默认配置。
  function void build_phase(uvm_phase phase);
    rdma_env_config required_cfg;
    super.build_phase(phase);
    catcher = new("catcher");
    uvm_report_cb::add(null, catcher);
    for (int i = 0; i < 4; i++) begin
      cfgs[i] = rdma_env_config::type_id::create($sformatf("cfg_%0d", i));
      cfgs[i].mode = rdma_env_mode_e'(i);
      cfgs[i].responder_regions.push_back(make_region());
      if (i == 1) cfgs[i].pcie_enabled = 1'b1; // 缺失 optional adapter => passive
      envs[i] = rdma_env::type_id::create($sformatf("env_%0d", i), this);
      uvm_config_db#(rdma_env_config)::set(this, $sformatf("env_%0d", i), "cfg", cfgs[i]);
    end
    // 两个独立 negative fixture 在 build 阶段必须发出可捕获的 fatal。
    rdma_env::type_id::create("env_missing_cfg", this);
    required_cfg = rdma_env_config::type_id::create("required_cfg");
    required_cfg.pcie_enabled = 1'b1;
    required_cfg.pcie_required = 1'b1;
    rdma_env::type_id::create("env_required_missing", this);
    uvm_config_db#(rdma_env_config)::set(this, "env_required_missing", "cfg", required_cfg);
  endfunction

  // 功能：构造合法 route/region，用于验证环境 build 后 registry 已 seal 且配置列表是深拷贝快照。
  // 输入/输出及副作用：region 为输出新建值对象；仅写入本地 route/base/size/owner，不登记外部资源。
  // 失败/边界：返回对象仅在合法 BDF 和非零 size 下可供 registry.claim；调用方仍需检查 claim 状态。
  function rdma_responder_region make_region();
    rdma_responder_region region;
    region = rdma_responder_region::type_id::create("test_region");
    region.domain = RDMA_RESPONDER_MMIO;
    region.mode = RDMA_RESPONDER_DUT;
    region.route.host_topology_key = 1;
    region.route.root_id = 0;
    region.route.segment = 0;
    region.route.bdf = '{segment:0, bus:8'h1, device:0, function_num:0};
    region.base.value = 64'h1000;
    region.size = 64;
    region.owner = "composition_test";
    return region;
  endfunction

  // 功能：执行四种 mode 的 validate 纯配置检查、snapshot 隔离检查及 capability 状态断言。
  // 输入/输出及副作用：phase 为 UVM phase；修改原始 cfg.responder_regions 以证明 env 使用 detached snapshot，并读取 env 状态。
  // 失败/边界：若 snapshot 受原始数组修改影响、registry 未 seal、可选能力未返回 disabled/passive 或产生外部 env 子组件则测试失败。
  task run_phase(uvm_phase phase);
    rdma_responder_region source_region;
    rdma_status status;
    string capability;
    uvm_component children[$];
    rdma_env_factory_fault_wrapper cfg_fault;
    rdma_env_factory_fault_wrapper queue_fault;
    rdma_env_config replacement_cfg;
    rdma_status failure_status;
    rdma_responder_registry old_responders;
    rdma_codec_registry old_codecs;
    rdma_resource_manager old_resources;
    rdma_queue_data_engine old_queue_data;
    rdma_sq_engine old_sq;
    rdma_rq_engine old_rq;
    rdma_cq_engine old_cq;
    rdma_eq_engine old_eq;
    rdma_env_config old_config_snapshot;
    uvm_factory factory;

    phase.raise_objection(this);
    source_region = cfgs[0].responder_regions[0];
    `uvm_info("RDMA_ENV_TEST", "测试 CORE_ONLY/MODEL_ONLY/DUT/HYBRID 配置枚举", UVM_LOW)
    for (int mode_index = 0; mode_index < 4; mode_index++) begin
      status = cfgs[mode_index].validate();
      if (!status.ok()) `uvm_error("RDMA_ENV_CFG", $sformatf("mode %0d validate failed: %s", cfgs[mode_index].mode, status.message))
      if (envs[mode_index] == null || envs[mode_index].responders == null ||
          !envs[mode_index].responders.is_sealed() ||
          envs[mode_index].queue_data == null || envs[mode_index].sq == null ||
          envs[mode_index].rq == null || envs[mode_index].cq == null ||
          envs[mode_index].eq == null)
        `uvm_error("RDMA_ENV_ASSEMBLY", $sformatf("mode %0d env assembly/seal failed", mode_index))
      if (mode_index == 1 && envs[mode_index].capability_status("pcie").message != "passive")
        `uvm_error("RDMA_ENV_CAP", "enabled optional PCIe adapter omission must be passive")
    end
    #1;
    foreach (envs[env_index]) begin
      envs[env_index].get_children(children);
      foreach (children[child_index]) begin
        if (children[child_index].get_name() == "pcie_env" ||
            children[child_index].get_name() == "axis_env")
          `uvm_error("RDMA_ENV_CHILD", "rdma_env 不得创建 pcie_env/axis_env 子组件")
      end
    end
    cfgs[0].responder_regions.delete();
    if (envs[0].responders.active_count() != 1)
      `uvm_error("RDMA_ENV_SNAPSHOT", "env 必须保留原始 cfg region 的 detached snapshot")
    if (envs[0].pending_count() != 0)
      `uvm_error("RDMA_ENV_PENDING", "新建环境 pending_count 必须为零")

    // configure() 的候选 factory 失败不能替换既有组合；使用合法 replacement
    // config 先建立 fixture，再分别注入 config/queue engine 的 null 返回。
    replacement_cfg = rdma_env_config::type_id::create("replacement_cfg");
    replacement_cfg.responder_regions.push_back(make_region());
    old_responders = envs[0].responders;
    old_codecs = envs[0].codecs;
    old_resources = envs[0].resources;
    old_queue_data = envs[0].queue_data;
    old_sq = envs[0].sq;
    old_rq = envs[0].rq;
    old_cq = envs[0].cq;
    old_eq = envs[0].eq;
    old_config_snapshot = envs[0].config_snapshot;
    factory = uvm_factory::get();
    saved_cfg_override = factory.find_override_by_type(
      rdma_env_config::get_type(), "");
    saved_queue_override = factory.find_override_by_type(
      rdma_queue_data_engine::get_type(), "");
    cfg_fault = new("env_config_fault", rdma_env_config::get_type());
    queue_fault = new("env_queue_data_fault",
                      rdma_queue_data_engine::get_type());
    factory.set_type_override_by_type(
      rdma_env_config::get_type(), cfg_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), queue_fault, 1'b1);

    cfg_fault.arm();
    failure_status = envs[0].configure(replacement_cfg);
    if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        envs[0].responders != old_responders || envs[0].codecs != old_codecs ||
        envs[0].resources != old_resources || envs[0].queue_data != old_queue_data ||
        envs[0].sq != old_sq || envs[0].rq != old_rq || envs[0].cq != old_cq ||
        envs[0].eq != old_eq || envs[0].config_snapshot != old_config_snapshot)
      `uvm_error("RDMA_ENV_ATOMIC", "null config factory changed old env composition")
    cfg_fault.disarm();

    queue_fault.arm();
    failure_status = envs[0].configure(replacement_cfg);
    if (failure_status == null || failure_status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
        envs[0].responders != old_responders || envs[0].codecs != old_codecs ||
        envs[0].resources != old_resources || envs[0].queue_data != old_queue_data ||
        envs[0].sq != old_sq || envs[0].rq != old_rq || envs[0].cq != old_cq ||
        envs[0].eq != old_eq || envs[0].config_snapshot != old_config_snapshot)
      `uvm_error("RDMA_ENV_ATOMIC", "null queue engine factory changed old env composition")
    queue_fault.disarm();
    begin
      rdma_env_event_route event_route;
      rdma_function_identity event_identity;
      rdma_function_key_t event_key;
      event_identity = rdma_function_identity::type_id::create("event_identity");
      event_key = '{root_id:0, host_topology_key:1, function_kind:RDMA_FUNCTION_PF,
                   parent_pf_bdf:'0, vf_index:0,
                   bdf:'{segment:0,bus:8'h1,device:0,function_num:0}};
      void'(event_identity.configure(event_key, 1, 64'h1, 1, 1));
      event_route = rdma_env_event_route::type_id::create("bare_event");
      status = envs[0].route_event(event_route);
      if (status.ok() || envs[0].pending_count() != 0)
        `uvm_error("RDMA_ENV_EVENT", "bare event route must be rejected")
      event_route.target_function = event_identity;
      event_route.vector = 2;
      event_route.generation = 1;
      status = envs[0].route_event(event_route);
      if (!status.ok() || envs[0].pending_count() != 1)
        `uvm_error("RDMA_ENV_EVENT", "valid Function-qualified event must increment pending")
      event_route.generation = 2;
      status = envs[0].route_event(event_route);
      if (status.ok() || envs[0].pending_count() != 1)
        `uvm_error("RDMA_ENV_EVENT", "stale event must be rejected without pending change")
      event_route.target_function = null;
      envs[0].end_pending();
      envs[0].begin_pending();
      if (envs[0].pending_count() != 1) `uvm_error("RDMA_ENV_PENDING", "begin_pending failed")
      envs[0].end_pending();
      if (envs[0].pending_count() != 0) `uvm_error("RDMA_ENV_PENDING", "end_pending failed")
    end
    foreach (catcher.caught[id]) fatal_seen[id] = catcher.caught[id];
    if (!fatal_seen.exists("RDMA_ENV_CFG") || !fatal_seen["RDMA_ENV_CFG"] ||
        !fatal_seen.exists("RDMA_ENV_PCIE") || !fatal_seen["RDMA_ENV_PCIE"])
      `uvm_error("RDMA_ENV_FATAL", "missing cfg/required adapter fatal was not observed")
    reset_env_factory_state();
    uvm_report_cb::delete(null, catcher);
    phase.drop_objection(this);
  endtask
endclass
