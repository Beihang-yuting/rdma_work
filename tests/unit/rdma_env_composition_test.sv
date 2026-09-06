// 目录：测试层 tests/unit/rdma_env_composition_test.sv。
// 职责：验证 rdma_env 四种装配模式、配置快照、可选适配器能力门控和 responder seal。
// 依赖：依赖 rdma_core_pkg 中的 rdma_env/rdma_env_config 及 UVM；不引入外部 VIP。
// 所有权与生命周期：测试拥有配置和 env fixture；适配器句柄若注入则由测试创建，env 只保存非拥有引用。

class rdma_env_composition_test extends uvm_test;
  `uvm_component_utils(rdma_env_composition_test)

  rdma_env envs[4];
  rdma_env_config cfgs[4];
  bit fatal_seen[string];

  class env_fatal_catcher extends uvm_report_catcher;
    bit caught[string];
    // 功能：构造 negative-build fatal 捕获器，初始化按 report ID 的捕获账本。
    // 输入输出及副作用：name 为 UVM 对象名；只建立本地 caught map。
    // 失败边界：非 RDMA_ENV_* fatal 继续抛出，避免掩盖无关结构错误。
    function new(string name = "env_fatal_catcher"); super.new(name); endfunction
    // 功能：捕获 rdma_env 对缺失 cfg 或 required adapter 发出的 fatal，并将其转换为 CAUGHT 供负测试断言。
    // 输入输出及副作用：无显式输入；更新 caught[report_id]，不改变 env 配置。
    // 失败边界：仅捕获 RDMA_ENV_CFG/PCIE/HOST/NET，其他报告保持 THROW。
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

  // 功能：构造组合层测试组件并建立空的配置/env 句柄。
  // 输入输出及副作用：name、parent 为 UVM 层级参数；只初始化本地句柄，不创建外部 adapter。
  // 失败边界：构造阶段不验证配置；缺少 cfg 或 required adapter 的拒绝由 rdma_env.build_phase 负责。
  function new(string name = "rdma_env_composition_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 test build 阶段注入 core-only 配置并取得待测 rdma_env，验证配置通过 UVM config_db 传递。
  // 输入输出及副作用：无显式输入；向 config_db 写入 cfg，UVM 随后调用 env.build_phase；不创建 pcie_env/axis_env 子组件。
  // 失败边界：配置对象为空或 validate 失败时 env 必须 fatal；本测试使用合法 core-only 默认配置。
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
  // 输入输出及副作用：region 为输出新建值对象；仅写入本地 route/base/size/owner，不登记外部资源。
  // 失败边界：返回对象仅在合法 BDF 和非零 size 下可供 registry.claim；调用方仍需检查 claim 状态。
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
  // 输入输出及副作用：phase 为 UVM phase；修改原始 cfg.responder_regions 以证明 env 使用 detached snapshot，并读取 env 状态。
  // 失败边界：若 snapshot 受原始数组修改影响、registry 未 seal、可选能力未返回 disabled/passive 或产生外部 env 子组件则测试失败。
  task run_phase(uvm_phase phase);
    rdma_responder_region source_region;
    rdma_status status;
    string capability;
    uvm_component children[$];

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
    begin
      rdma_env_event_route event_route;
      event_route = rdma_env_event_route::type_id::create("bare_event");
      status = envs[0].route_event(event_route);
      if (status.ok() || envs[0].pending_count() != 0)
        `uvm_error("RDMA_ENV_EVENT", "bare event route must be rejected")
      envs[0].begin_pending();
      if (envs[0].pending_count() != 1) `uvm_error("RDMA_ENV_PENDING", "begin_pending failed")
      envs[0].end_pending();
      if (envs[0].pending_count() != 0) `uvm_error("RDMA_ENV_PENDING", "end_pending failed")
    end
    foreach (catcher.caught[id]) fatal_seen[id] = catcher.caught[id];
    if (!fatal_seen.exists("RDMA_ENV_CFG") || !fatal_seen["RDMA_ENV_CFG"] ||
        !fatal_seen.exists("RDMA_ENV_PCIE") || !fatal_seen["RDMA_ENV_PCIE"])
      `uvm_error("RDMA_ENV_FATAL", "missing cfg/required adapter fatal was not observed")
    uvm_report_cb::delete(null, catcher);
    phase.drop_objection(this);
  endtask
endclass
