// 目录：测试层 tests/unit/rdma_env_composition_test.sv。
// 职责：验证 rdma_env 四种装配模式、配置快照、可选适配器能力门控和 responder seal。
// 依赖：依赖 rdma_core_pkg 中的 rdma_env/rdma_env_config 及 UVM；不引入外部 VIP。
// 所有权与生命周期：测试拥有配置和 env fixture；适配器句柄若注入则由测试创建，env 只保存非拥有引用。

class rdma_env_composition_test extends uvm_test;
  `uvm_component_utils(rdma_env_composition_test)

  rdma_env env;
  rdma_env_config cfg;

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
    super.build_phase(phase);
    cfg = rdma_env_config::type_id::create("cfg");
    cfg.responder_regions.push_back(make_region());
    env = rdma_env::type_id::create("env", this);
    uvm_config_db#(rdma_env_config)::set(this, "env", "cfg", cfg);
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
    source_region = cfg.responder_regions[0];
    `uvm_info("RDMA_ENV_TEST", "测试 CORE_ONLY/MODEL_ONLY/DUT/HYBRID 配置枚举", UVM_LOW)
    for (int mode_index = 0; mode_index < 4; mode_index++) begin
      cfg.mode = rdma_env_mode_e'(mode_index);
      status = cfg.validate();
      if (!status.ok()) `uvm_error("RDMA_ENV_CFG", $sformatf("mode %0d validate failed: %s", cfg.mode, status.message))
    end
    #1;
    if (!env.responders.is_sealed())
      `uvm_error("RDMA_ENV_SEAL", "rdma_env build 后 responder registry 必须 sealed")
    env.get_children(children);
    foreach (children[child_index]) begin
      if (children[child_index].get_name() == "pcie_env" ||
          children[child_index].get_name() == "axis_env")
        `uvm_error("RDMA_ENV_CHILD", "rdma_env 不得创建 pcie_env/axis_env 子组件")
    end
    capability = env.capability_status("pcie").message;
    if (capability != "disabled" && capability != "passive")
      `uvm_error("RDMA_ENV_CAP", $sformatf("missing optional pcie capability=%s", capability))
    cfg.responder_regions.delete();
    if (env.responders.active_count() != 1)
      `uvm_error("RDMA_ENV_SNAPSHOT", "env 必须保留原始 cfg region 的 detached snapshot")
    if (env.pending_count() != 0)
      `uvm_error("RDMA_ENV_PENDING", "新建环境 pending_count 必须为零")
    phase.drop_objection(this);
  endtask
endclass
