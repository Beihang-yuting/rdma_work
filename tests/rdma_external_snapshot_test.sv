// 目录/层次：tests，外部快照与显式初始化集成契约测试。
// 职责：使用 DPU 正式 resolver 检查身份投影、资源同源、8-bit ID 和无隐式 MMIO；模型夹具覆盖成功及部分失败。
// 依赖：dpu_resource_pkg、host_mem_pkg、rdma_dpu_adapter_pkg、rdma_env_pkg；不依赖外部 VIO 或 PCIe 包。
// 所有权与生命周期：测试拥有配置、公共Host pool、BAR 和环境；环境借用平台系统，测试结束前全部保持有效。
package rdma_external_snapshot_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dpu_resource_pkg::*;
  import host_mem_pkg::*;
  import rdma_types_pkg::*;
  import rdma_drv_pkg::*;
  import rdma_dpu_adapter_pkg::*;
  import rdma_env_pkg::*;

  // 计数器只计实际 write64 调用，返回失败可定位 probe 的首个 MMIO 边界。
  class rdma_snapshot_counting_bar extends rdma_drv_bar;
    `uvm_object_utils(rdma_snapshot_counting_bar)
    int unsigned	writes;

    // 功能：构造写计数为零的拒绝型 BAR fixture，不拥有设备或传输句柄。
    // 输入/输出及副作用：name 用于 UVM 对象名；不发起事务。
    // 失败/边界：每次 write64 都明确失败，仅用于未启动检查与故障注入。
    extern function new(string	name = "rdma_snapshot_counting_bar");
    // 功能：记录一次真实 MMIO 调用并注入 INVALID_STATE，模拟第二节点 probe 失败。
    // 输入/输出及副作用：offset/value 为待写内容；writes 加一，status 输出故障。
    // 失败/边界：不转发、不等待、不成功写寄存器；等待时间不会增加 writes。
    extern virtual task write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
  endclass

  // 功能：构造写计数为零的拒绝型 BAR fixture，不拥有设备或传输句柄。
  // 输入/输出及副作用：name 用于 UVM 对象名；不发起事务。
  // 失败/边界：每次 write64 都明确失败，仅用于未启动检查与故障注入。
  function rdma_snapshot_counting_bar::new(string	name = "rdma_snapshot_counting_bar");
    super.new(name);
    writes = 0;
  endfunction

  // 功能：记录一次真实 MMIO 调用并注入 INVALID_STATE，模拟第二节点 probe 失败。
  // 输入/输出及副作用：offset/value 为待写内容；writes 加一，status 输出故障。
  // 失败/边界：不转发、不等待、不成功写寄存器；等待时间不会增加 writes。
  task rdma_snapshot_counting_bar::write64(bit [63:0]	offset, bit [63:0]	value, output rdma_status	status);
    writes++;
    status = rdma_status::make(RDMA_SC_INVALID_STATE, "injected BAR failure");
  endtask

  // 仅测试模型的手动启动：覆盖 run_phase 避免自动 probe，生产外部环境使用原 rdma_env。
  class rdma_manual_model_env extends rdma_env;
    `uvm_component_utils(rdma_manual_model_env)
    // 功能：构造仍未建立系统的手动启动模型环境，沿用基类资源所有权。
    // 输入/输出及副作用：name/parent 创建层次；不更改 cfg 或 ready。
    // 失败/边界：测试必须在 build 传入模型配置并显式 initialize。
    extern function new(string	name = "rdma_manual_model_env", uvm_component	parent = null);
    // 功能：抑制模型自动启动，以便测试在同一 initialize 入口检查成功和部分失败。
    // 输入/输出及副作用：phase 不变；立即返回且没有 MMIO 或 objection。
    // 失败/边界：测试未显式初始化时 ready 一直为 0，不会由时间流逝触发。
    extern task run_phase(uvm_phase	phase);
  endclass

  // 功能：构造仍未建立系统的手动启动模型环境，沿用基类资源所有权。
  // 输入/输出及副作用：name/parent 创建层次；不更改 cfg 或 ready。
  // 失败/边界：测试必须在 build 传入模型配置并显式 initialize。
  function rdma_manual_model_env::new(string	name = "rdma_manual_model_env", uvm_component	parent = null);
    super.new(name, parent);
  endfunction

  // 功能：抑制模型自动启动，以便测试在同一 initialize 入口检查成功和部分失败。
  // 输入/输出及副作用：phase 不变；立即返回且没有 MMIO 或 objection。
  // 失败/边界：测试未显式初始化时 ready 一直为 0，不会由时间流逝触发。
  task rdma_manual_model_env::run_phase(uvm_phase	phase);
  endtask

  class rdma_external_snapshot_test extends uvm_test;
    `uvm_component_utils(rdma_external_snapshot_test)
    rdma_env	external_env;
    rdma_manual_model_env	success_env;
    rdma_manual_model_env	partial_env;
    rdma_dpu_system	external_system;
    rdma_snapshot_counting_bar	external_bar;
    dpu_device_snapshot	device;
    dpu_resource_snapshot	resources;

    // 功能：建立空测试容器，fixture 在 build_phase 中解析并装配。
    // 输入/输出及副作用：name/parent 建立 UVM 层次；句柄保持 null。
    // 失败/边界：build 前不读取环境或快照。
    extern function new(string	name = "rdma_external_snapshot_test", uvm_component	parent = null);
    // 功能：核对 status 与预期枚举，失败给出可定位的 UVM_FATAL。
    // 输入/输出及副作用：what/code/status 只读，不修改 fixture。
    // 失败/边界：null status 或错误码不符均终止，避免后续依赖空句柄。
    extern function void expect_code(string	what, rdma_status_code_e	code, rdma_status	status);
    // 功能：解析含真实 VIO 单 qpair 请求和 RDMA 服务的独立设备/资源快照，仅用于同源验证。
    // 输入/输出及副作用：source/leases 输出正式 resolver 结果；默认 DUT caps 和 virtio.qpair profile 来自显式硬件能力。
    // 失败/边界：任何解析失败 fatal；绝不手填 normalized capacity，也不把 VIO grant 视为 RDMA shared grant。
    extern function void resolve_lineage(output dpu_device_snapshot	source, output dpu_resource_snapshot	leases);
    // 功能：按冻结source的GPA建立公共Host pool，供外部系统借用。
    // 输入/输出及副作用：source只读，返回测试拥有的pool；每Host一个独立manager，不创建Function视图。
    // 失败/边界：GPA缺失/为空或create_host失败fatal，不伪造内存范围、不发MMIO。
    extern function host_mem_pool make_pool(dpu_device_snapshot	source);
    // 功能：构建外部环境和两个手动模型环境，检查pool缺项/GPA/身份/替换拒绝及快照同源。
    // 输入/输出及副作用：phase 透传基类；发布 config_db 并创建子环境，保存平台句柄至测试结束。
    // 失败/边界：任何 fixture 装配或身份断言失败 fatal；不运行 initialize。
    extern function void build_phase(uvm_phase	phase);
    // 功能：正式 resolver 生成 257 个 Function，检查 global ID 255 可投影、256 及重复/非RDMA/未冻结均原子拒绝。
    // 输入/输出及副作用：创建独立配置/系统并核对节点数量和句柄；无 MMIO。
    // 失败/边界：任何解析或预期边界不符 fatal；失败系统不发布 source/nodes。
    extern function void check_projection_boundaries();
    // 功能：等待后验证外部未自动启动，再检查外部预检、复位拒绝和模型初始化成功/部分失败。
    // 输入/输出及副作用：持有 objection，调用 initialize；第二模型节点 BAR 注入失败，检查 ready 和资源发布。
    // 失败/边界：重复初始化及关闭后的绑定必须拒绝；部分 probe 失败不能发布业务资源或启动链路。
    extern task run_phase(uvm_phase	phase);
  endclass

  // 功能：建立空测试容器，fixture 在 build_phase 中解析并装配。
  // 输入/输出及副作用：name/parent 建立 UVM 层次；句柄保持 null。
  // 失败/边界：build 前不读取环境或快照。
  function rdma_external_snapshot_test::new(string	name = "rdma_external_snapshot_test", uvm_component	parent = null);
    super.new(name, parent);
  endfunction

  // 功能：核对 status 与预期枚举，失败给出可定位的 UVM_FATAL。
  // 输入/输出及副作用：what/code/status 只读，不修改 fixture。
  // 失败/边界：null status 或错误码不符均终止，避免后续依赖空句柄。
  function void rdma_external_snapshot_test::expect_code(string	what, rdma_status_code_e	code, rdma_status	status);
    if (status == null || status.code != code)
      `uvm_fatal("EXTERNAL_SNAPSHOT", $sformatf("%s: %s expected %s", what,
        status == null ? "null" : status.convert2string(), code.name()))
  endfunction

  // 功能：解析含真实 VIO 单 qpair 请求和 RDMA 服务的独立设备/资源快照，仅用于同源验证。
  // 输入/输出及副作用：source/leases 输出正式 resolver 结果；默认 DUT caps 和 virtio.qpair profile 来自显式硬件能力。
  // 失败/边界：任何解析失败 fatal；绝不手填 normalized capacity，也不把 VIO grant 视为 RDMA shared grant。
  function void rdma_external_snapshot_test::resolve_lineage(output dpu_device_snapshot	source, output dpu_resource_snapshot	leases);
    dpu_device_cfg	cfg;
    dpu_resource_placement_cfg	placement;
    dpu_vio_placement_request	request;
    dpu_resource_pool_config_t	profile;
    dpu_configuration_resolver	resolver;
    dpu_placement_diagnostic	diagnostic;

    cfg = dpu_device_cfg::type_id::create("rdma_vio_lineage_cfg");
    rdma_dpu_topology::add_host(cfg, 0);
    rdma_dpu_topology::add_function(cfg, 0, 0, DPU_FUNCTION_PF, 0);
    rdma_dpu_topology::add_function(cfg, 0, 1, DPU_FUNCTION_PF, 0);
    cfg.functions[0].eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
    cfg.functions[1].services.delete();
    placement = dpu_resource_placement_cfg::type_id::create("vio_lineage_placement");
    profile = '{name: "virtio.qpair", class_id: 0, kind: DPU_RESOURCE_KIND_QUEUE,
      capacity: cfg.dut_caps.vio_global_qpair_count,
      max_per_function: cfg.dut_caps.max_vio_net_qpairs_per_device};
    placement.profiles.push_back(profile);
    request = dpu_vio_placement_request::type_id::create("actual_vio_request");
    request.request_id = 1;
    request.total_qpairs = 1;
    request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
    request.device_policy = DPU_VIO_DEVICE_FIXED;
    request.fixed_devices.push_back(cfg.functions[0].key);
    placement.vio_requests.push_back(request);
    resolver = dpu_configuration_resolver::type_id::create("lineage_resolver");
    if (!resolver.resolve(cfg, placement, source, leases, diagnostic))
      `uvm_fatal("EXTERNAL_SNAPSHOT", diagnostic.message)
  endfunction

  // 功能：按冻结source的GPA建立公共Host pool，供外部系统借用。
  // 输入/输出及副作用：source只读，返回测试拥有的pool；每Host一个独立manager，不创建Function视图。
  // 失败/边界：GPA缺失/为空或create_host失败fatal，不伪造内存范围、不发MMIO。
  function host_mem_pool rdma_external_snapshot_test::make_pool(dpu_device_snapshot	source);
    host_mem_pool	pool;
    dpu_host_info_t	hosts[$];

    pool = host_mem_pool::type_id::create("platform_memory");
    source.list_hosts(hosts);
    foreach (hosts[i]) begin
      if (!hosts[i].has_gpa_aperture || hosts[i].gpa_limit <= hosts[i].gpa_base ||
          !pool.create_host(hosts[i].host_id, hosts[i].gpa_base, hosts[i].gpa_limit - 1, MODE_BUDDY, 16))
        `uvm_fatal("EXTERNAL_SNAPSHOT", "shared pool requires frozen Host GPA")
    end
    return pool;
  endfunction

  // 功能：构建外部环境和两个手动模型环境，检查pool缺项/GPA/身份/替换拒绝及快照同源。
  // 输入/输出及副作用：phase 透传基类；发布 config_db 并创建子环境，保存平台句柄至测试结束。
  // 失败/边界：任何 fixture 装配或身份断言失败 fatal；不运行 initialize。
  function void rdma_external_snapshot_test::build_phase(uvm_phase	phase);
    rdma_env_cfg	cfg;
    rdma_drv_config	driver_cfg;
    rdma_drv_hw	hw;
    dpu_function_key_t	keys[$];
    dpu_device_snapshot	other_device;
    dpu_resource_snapshot	other_resources;
    dpu_bar_pair_lease_t	bar;
    dpu_pcie_function_id_t	pcie_id;
    string	why;
    int unsigned	global_id;
    host_mem_pool	pool;
    host_mem_pool	invalid_pool;
    host_mem_manager	manager;
    dpu_host_info_t	host;

    super.build_phase(phase);
    resolve_lineage(device, resources);
    resolve_lineage(other_device, other_resources);
    keys.push_back('{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0});
    pool = make_pool(device);
    external_system = rdma_dpu_system::type_id::create("external_system");
    expect_code("null pool", RDMA_SC_INVALID_ARGUMENT, external_system.bind_snapshot(device, keys, null));
    invalid_pool = host_mem_pool::type_id::create("invalid_pool");
    expect_code("missing Host", RDMA_SC_INVALID_STATE, external_system.bind_snapshot(device, keys, invalid_pool));
    if (!device.lookup_host(0, host, why) ||
        !invalid_pool.create_host(0, host.gpa_base, host.gpa_base + 4095, MODE_BUDDY, 16))
      `uvm_fatal("EXTERNAL_SNAPSHOT", "could not create narrow GPA fixture")
    expect_code("GPA mismatch", RDMA_SC_INVALID_STATE, external_system.bind_snapshot(device, keys, invalid_pool));
    manager = pool.get_host(0);
    manager.set_host_id(1);
    expect_code("Host identity", RDMA_SC_INVALID_STATE, external_system.bind_snapshot(device, keys, pool));
    manager.set_host_id(0);
    if (external_system.mem_pool != null || external_system.snapshot != null || external_system.nodes.size() != 0)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "rejected pool partially published")
    expect_code("bind snapshot", RDMA_SC_OK, external_system.bind_snapshot(device, keys, pool));
    expect_code("replace bound pool", RDMA_SC_INVALID_STATE,
      external_system.bind_snapshot(device, keys, invalid_pool));
    if (external_system.mem_pool != pool || external_system.nodes[0].mem.mem != pool.get_host(0))
      `uvm_fatal("EXTERNAL_SNAPSHOT", "snapshot binding replaced or copied shared manager")
    if (!device.get_bar(keys[0], DPU_BAR_DEVICE_MEMORY, bar, why) ||
        !device.get_pcie_id(keys[0], pcie_id, why) ||
        !device.get_global_function_id(keys[0], global_id, why))
      `uvm_fatal("EXTERNAL_SNAPSHOT", why)
    if (external_system.snapshot != device || external_system.nodes[0].source_snapshot != device ||
        !dpu_same_function_key(external_system.nodes[0].func.key, keys[0]) ||
        external_system.nodes[0].func.global_id != global_id ||
        external_system.nodes[0].func.pcie_id != pcie_id || external_system.nodes[0].func.bar0 != bar ||
        external_system.router != null || external_system.nodes[0].dev != null ||
        external_system.nodes[0].interrupt_ctrl != null)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "external projection changed authority or created model objects")
    expect_code("foreign resources", RDMA_SC_INVALID_STATE, external_system.bind_resources(other_resources));
    if (external_system.resources != null)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "foreign resources were published")
    expect_code("same-source resources", RDMA_SC_OK, external_system.bind_resources(resources));
    external_bar = rdma_snapshot_counting_bar::type_id::create("external_bar");
    hw = rdma_drv_hw::type_id::create("external_hw");
    expect_code("bind hw", RDMA_SC_OK, hw.bind_hw(external_bar, external_system.nodes[0].mem));
    driver_cfg = rdma_drv_config::type_id::create("explicit_driver_cfg");
    expect_code("bind external hw", RDMA_SC_OK, external_system.bind_external_hw(0, hw, driver_cfg));
    cfg = rdma_env_cfg::type_id::create("external_cfg");
    cfg.external_configuration = 1;
    cfg.external_system = external_system;
    uvm_config_db#(rdma_env_cfg)::set(this, "external_env", "cfg", cfg);
    external_env = rdma_env::type_id::create("external_env", this);
    cfg = rdma_env_cfg::type_id::create("model_success_cfg");
    cfg.add_func(0);
    uvm_config_db#(rdma_env_cfg)::set(this, "success_env", "cfg", cfg);
    success_env = rdma_manual_model_env::type_id::create("success_env", this);
    cfg = rdma_env_cfg::type_id::create("model_partial_cfg");
    cfg.add_func(0);
    cfg.add_func(1);
    uvm_config_db#(rdma_env_cfg)::set(this, "partial_env", "cfg", cfg);
    partial_env = rdma_manual_model_env::type_id::create("partial_env", this);
    check_projection_boundaries();
  endfunction

  // 功能：正式 resolver 生成 257 个 Function，检查 global ID 255 可投影、256 及重复/非RDMA/未冻结均原子拒绝。
  // 输入/输出及副作用：创建独立配置/系统并核对节点数量和句柄；无 MMIO。
  // 失败/边界：任何解析或预期边界不符 fatal；失败系统不发布 source/nodes。
  function void rdma_external_snapshot_test::check_projection_boundaries();
    dpu_device_cfg	cfg;
    dpu_device_resolver	resolver;
    dpu_device_snapshot	source;
    dpu_device_snapshot	unfrozen;
    dpu_function_key_t	keys[$];
    dpu_function_key_t	selection[$];
    rdma_dpu_system	system;
    string	why;
    int unsigned	global_id;
    bit	seen_255;
    bit	seen_256;
    host_mem_pool	pool;

    seen_255 = 0;
    seen_256 = 0;
    cfg = dpu_device_cfg::type_id::create("wide_cfg");
    cfg.dut_caps.max_pfs_per_host = 16;
    rdma_dpu_topology::add_host(cfg, 0);
    rdma_dpu_topology::add_host(cfg, 1);
    cfg.hosts[0].pcie_domains[0].bdf_ranges[0].last_bdf = 16'h7fff;
    for (int unsigned pf = 0; pf < 16; pf++) begin
      rdma_dpu_topology::add_function(cfg, 0, pf, DPU_FUNCTION_PF, 0);
      for (int unsigned vf = 1; vf < 16; vf++)
        rdma_dpu_topology::add_function(cfg, 0, pf, DPU_FUNCTION_VF, vf);
    end
    rdma_dpu_topology::add_function(cfg, 1, 0, DPU_FUNCTION_PF, 0);
    resolver = dpu_device_resolver::type_id::create("wide_resolver");
    if (!resolver.resolve(cfg, source, why))
      `uvm_fatal("EXTERNAL_SNAPSHOT", why)
    source.list_functions(keys);
    pool = make_pool(source);
    foreach (keys[i]) begin
      if (!source.get_global_function_id(keys[i], global_id, why))
        `uvm_fatal("EXTERNAL_SNAPSHOT", why)
      if (global_id == 255 || global_id == 256) begin
        if (global_id == 255)
          seen_255 = 1;
        else
          seen_256 = 1;
        system = rdma_dpu_system::type_id::create($sformatf("id%0d", global_id));
        selection = '{keys[i]};
        expect_code("ID boundary", global_id == 255 ? RDMA_SC_OK : RDMA_SC_INVALID_ARGUMENT,
          system.bind_snapshot(source, selection, pool));
        if (global_id == 256 && (system.snapshot != null || system.nodes.size() != 0))
          `uvm_fatal("EXTERNAL_SNAPSHOT", "ID overflow partially published")
      end
    end
    if (!seen_255 || !seen_256)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "resolver fixture did not reach both 8-bit ID boundaries")
    system = rdma_dpu_system::type_id::create("duplicate");
    selection = '{keys[0], keys[0]};
    expect_code("duplicate keys", RDMA_SC_INVALID_ARGUMENT, system.bind_snapshot(source, selection, pool));
    if (system.snapshot != null || system.nodes.size() != 0)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "duplicate selection partially published")
    selection = '{'{host_id: 0, pf_id: 1, kind: DPU_FUNCTION_PF, vf_id: 0}};
    expect_code("non-RDMA", RDMA_SC_INVALID_ARGUMENT, system.bind_snapshot(device, selection, pool));
    unfrozen = dpu_device_snapshot::type_id::create("unfrozen");
    expect_code("unfrozen", RDMA_SC_INVALID_STATE, system.bind_snapshot(unfrozen, selection, pool));
  endfunction

  // 功能：等待后验证外部未自动启动，再检查外部预检、复位拒绝和模型初始化成功/部分失败。
  // 输入/输出及副作用：持有 objection，调用 initialize；第二模型节点 BAR 注入失败，检查 ready 和资源发布。
  // 失败/边界：重复初始化及关闭后的绑定必须拒绝；部分 probe 失败不能发布业务资源或启动链路。
  task rdma_external_snapshot_test::run_phase(uvm_phase	phase);
    rdma_status	status;
    rdma_snapshot_counting_bar	failing_bar;
    int unsigned	scope[$];
    rdma_dpu_bar	model_bar;

    phase.raise_objection(this);
    #1us;
    if (external_env.is_ready() || external_bar.writes != 0 || external_system.nodes[0].drv != null)
      `uvm_fatal("MANUAL_START", "external environment started without a command")
    external_env.initialize(status);
    expect_code("missing RDMA grants", RDMA_SC_INVALID_STATE, status);
    if (external_env.is_ready() || external_bar.writes != 0 || external_system.nodes[0].drv != null ||
        external_env.res.funcs.size() != 0)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "failed external preflight changed driver or issued MMIO")
    external_env.initialize(status);
    expect_code("repeat external initialize", RDMA_SC_INVALID_STATE, status);
    expect_code("late resources", RDMA_SC_INVALID_STATE, external_system.bind_resources(resources));
    expect_code("late hardware", RDMA_SC_INVALID_STATE,
      external_system.bind_external_hw(0, external_system.nodes[0].hw, external_system.nodes[0].drv_cfg));
    scope = '{0};
    expect_code("external FLR", RDMA_SC_INVALID_STATE, external_system.flr(scope));
    external_system.recover(scope, status);
    expect_code("external recover", RDMA_SC_INVALID_STATE, status);
    if (external_bar.writes != 0)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "external reset wrote MMIO")
    if (!$cast(model_bar, success_env.sys.nodes[0].bar))
      `uvm_fatal("EXTERNAL_SNAPSHOT", "model fixture BAR cast failed")
    if (success_env.is_ready() || model_bar.written_offsets.size() != 0)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "manual model started early")
    success_env.initialize(status);
    expect_code("model initialize", RDMA_SC_OK, status);
    if (!success_env.is_ready() || success_env.res.funcs.size() != 1)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "successful initialize did not publish ready/resources")
    success_env.initialize(status);
    expect_code("repeat model initialize", RDMA_SC_INVALID_STATE, status);
    failing_bar = rdma_snapshot_counting_bar::type_id::create("second_node_failure");
    expect_code("inject BAR", RDMA_SC_OK,
      partial_env.sys.nodes[1].hw.bind_hw(failing_bar, partial_env.sys.nodes[1].mem));
    partial_env.initialize(status);
    expect_code("partial probe failure", RDMA_SC_INVALID_STATE, status);
    if (partial_env.is_ready() || partial_env.res.funcs.size() != 0 || failing_bar.writes == 0 ||
        partial_env.sys.nodes[0].drv == null || !partial_env.sys.nodes[0].drv.probed)
      `uvm_fatal("EXTERNAL_SNAPSHOT", "partial probe lifecycle contract violated")
    partial_env.initialize(status);
    expect_code("repeat partial initialize", RDMA_SC_INVALID_STATE, status);
    phase.drop_objection(this);
  endtask
endpackage

// 独立扩展入口：原 sim/filelists 不变，验证执行者额外编译本文件并选此 top。
module rdma_external_snapshot_top;
  import uvm_pkg::*;
  import rdma_external_snapshot_test_pkg::*;
  initial run_test();
endmodule
