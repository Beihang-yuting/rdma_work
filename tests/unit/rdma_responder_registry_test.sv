// 目录：测试层 tests/unit/rdma_responder_registry_test.sv。
// 职责：验证 responder region 登记表的区间、路由隔离、租约和 seal 契约。
// 依赖：依赖 rdma_types_pkg、rdma_core_pkg 与 UVM；不创建或连接外部 PCIe/Host-memory 环境。
// 所有权与生命周期：测试只持有 registry 返回的临时句柄；region 的所有权由 registry 管理，测试结束前显式 release。

class rdma_responder_registry_test extends uvm_test;
  `uvm_component_utils(rdma_responder_registry_test)

  // 功能：构造测试组件并建立 UVM 组件层级关系。
  // 输入输出及副作用：name、parent 为 UVM 输入；仅调用父类构造，不分配 registry 或外部资源。
  // 失败边界：UVM 父组件为空是合法的顶层测试场景；其他构造异常由 UVM 报告。
  function new(string name = "rdma_responder_registry_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：生成一个完整且可路由的测试 route 快照。
  // 输入输出及副作用：seed 为输入，决定 bus/device/function；返回值为独立 packed route，不修改共享状态。
  // 失败边界：seed 的所有 8 位取值均可编码；seed=0 仍通过非零 device 保持 BDF 合法。
  function automatic rdma_route_key_t make_route(bit [7:0] seed);
    rdma_route_key_t route;
    route.host_topology_key = 32'h1000 + seed;
    route.root_id = 16'h20 + seed;
    route.segment = 16'h0;
    route.bdf.segment = 16'h0;
    route.bdf.bus = 8'h40 + seed;
    route.bdf.device = 5'h3;
    route.bdf.function_num = 3'h1;
    return route;
  endfunction

  // 功能：构造一个可用于 claim 的 BAR 起始地址值。
  // 输入输出及副作用：value 为输入；返回值为 rdma_bar_addr_t，不修改 registry 或地址所有权。
  // 失败边界：调用方仍负责保证 value 与 size 的 65 位和不溢出；本辅助函数不做范围拒绝。
  function automatic rdma_bar_addr_t make_base(longint unsigned value);
    rdma_bar_addr_t base;
    base.value = value;
    return base;
  endfunction

  // 功能：断言 status 的 code 与 resource engine 来源，统一检查登记表错误路径。
  // 输入输出及副作用：status 为输入句柄，expected_code 为期望错误码；失败时发出 UVM 错误，不修改 status。
  // 失败边界：status 为空或 code/source_engine 不匹配均报告错误；成功状态不应调用本辅助函数。
  function void expect_resource_error(rdma_status status, rdma_status_code_e expected_code);
    if (status == null)
      `uvm_error("REG_STATUS", "registry returned null status")
    else begin
      if (status.code != expected_code)
        `uvm_error("REG_STATUS", $sformatf("expected code %0d got %0d", expected_code, status.code))
      if (status.source_engine != RDMA_ENGINE_RESOURCE)
        `uvm_error("REG_STATUS", $sformatf("expected resource source got %0d", status.source_engine))
    end
  endfunction

  // 功能：执行 registry 的完整边界场景，包括四 domain、重叠、溢出、monitor、租约、seal 和重用。
  // 输入输出及副作用：phase 为 UVM 输入；task 创建并修改本地 registry 账本，最终释放成功登记的 region 并 drop objection。
  // 失败边界：任一断言失败会使测试报告 UVM_ERROR；claim/release 的失败路径必须保持 active_count 和既有条目不变。
  task run_phase(uvm_phase phase);
    rdma_responder_registry registry;
    rdma_responder_region region;
    rdma_responder_region monitor_region;
    rdma_responder_region duplicate_region;
    rdma_responder_registry reuse_registry;
    rdma_responder_region reuse_region;
    rdma_status status;
    rdma_route_key_t route;
    rdma_bar_addr_t base;
    int unsigned index;
    rdma_responder_domain_e domain;
    longint unsigned monitor_lease_id;

    phase.raise_objection(this);
    registry = rdma_responder_registry::type_id::create("registry");
    route = make_route(8'h1);
    base = make_base(64'h1000);

    for (index = 0; index < 4; index++) begin
      domain = rdma_responder_domain_e'(index);
      status = registry.claim(domain, RDMA_RESPONDER_DUT, route, base, 64, "owner", region);
      if (status == null || !status.ok())
        `uvm_error("REG_CLAIM", $sformatf("domain %0d claim failed", index))
      base.value += 64'h1000;
    end
    if (registry.active_count() != 4)
      `uvm_error("REG_COUNT", "four domain claims were not retained")

    status = registry.claim(RDMA_RESPONDER_CONFIG, RDMA_RESPONDER_DUT,
                            route, make_base(64'h1000), 64, "overlap", duplicate_region);
    expect_resource_error(status, RDMA_SC_INVALID_STATE);
    status = registry.claim(RDMA_RESPONDER_CONFIG, RDMA_RESPONDER_DUT,
                            route, make_base(64'h1030), 64, "partial", duplicate_region);
    expect_resource_error(status, RDMA_SC_INVALID_STATE);

    status = registry.claim(RDMA_RESPONDER_CONFIG, RDMA_RESPONDER_DUT,
                            route, make_base(64'hffff_ffff_ffff_fffe), 4,
                            "overflow", duplicate_region);
    expect_resource_error(status, RDMA_SC_INVALID_ARGUMENT);

    status = registry.claim(RDMA_RESPONDER_CONFIG, RDMA_RESPONDER_MONITOR_ONLY,
                            route, make_base(64'h1000), 64, "monitor", monitor_region);
    if (status == null || !status.ok())
      `uvm_error("REG_MONITOR", "monitor-only claim should bypass overlap")
    if (registry.active_count() != 5)
      `uvm_error("REG_MONITOR", "monitor-only region was not retained")

    monitor_lease_id = monitor_region.lease_id;
    monitor_region.owner = "attacker";
    status = registry.\release (monitor_region);
    expect_resource_error(status, RDMA_SC_INVALID_ARGUMENT);
    monitor_region.owner = "monitor";
    monitor_region.lease_id = 0;
    status = registry.\release (monitor_region);
    expect_resource_error(status, RDMA_SC_INVALID_ARGUMENT);
    monitor_region.lease_id = monitor_lease_id;
    status = registry.\release (monitor_region);
    if (status == null || !status.ok())
      `uvm_error("REG_RELEASE", "valid release failed")

    reuse_registry = rdma_responder_registry::type_id::create("reuse_registry");
    status = reuse_registry.claim(RDMA_RESPONDER_MMIO, RDMA_RESPONDER_DUT,
                                  route, make_base(64'h5000), 64, "reuse", reuse_region);
    if (status == null || !status.ok())
      `uvm_error("REG_REUSE", "initial reusable claim failed")
    status = reuse_registry.\release (reuse_region);
    if (status == null || !status.ok() || reuse_registry.active_count() != 0)
      `uvm_error("REG_REUSE", "release did not clear reusable lease")
    status = reuse_registry.claim(RDMA_RESPONDER_MMIO, RDMA_RESPONDER_DUT,
                                  route, make_base(64'h5000), 64, "reuse2", reuse_region);
    if (status == null || !status.ok())
      `uvm_error("REG_REUSE", "released interval could not be reclaimed")

    status = registry.seal();
    if (status == null || !status.ok() || !registry.is_sealed())
      `uvm_error("REG_SEAL", "seal did not latch")
    status = registry.seal();
    if (status == null || !status.ok())
      `uvm_error("REG_SEAL", "seal should be idempotent")
    status = registry.claim(RDMA_RESPONDER_NETWORK, RDMA_RESPONDER_DUT,
                            route, make_base(64'h9000), 64, "sealed", duplicate_region);
    expect_resource_error(status, RDMA_SC_INVALID_STATE);

    index = 0;
    region = registry.region_at(index);
    if (region == null)
      `uvm_error("REG_LOOKUP", "region_at returned null for active entry")
    else begin
      status = registry.\release (region);
      if (status == null || !status.ok())
        `uvm_error("REG_RELEASE", "release after seal failed")
    end
    if (registry.region_at(99) != null)
      `uvm_error("REG_LOOKUP", "out-of-range region_at returned an entry")
    phase.drop_objection(this);
  endtask
endclass
