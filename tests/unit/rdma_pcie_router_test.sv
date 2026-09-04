// 目录：tests/unit/，位于 PCIe router 的单元测试层。
// 职责：验证多 Host 相同 BDF 的歧义保护、identity provenance、完整 Function handle
//       路由和 endpoint BDF 一致性。
// 依赖：rdma_pcie_router、rdma_mock_pcie、UVM；mock endpoint 不连接真实 PCIe VIP。
// 所有权与生命周期：测试拥有 mock endpoint 和 route entry；router 只保存非拥有 endpoint 引用。
class rdma_pcie_router_test extends uvm_test;
  `uvm_component_utils(rdma_pcie_router_test)

  // 功能：构造 UVM PCIe router 测试组件。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_pcie_router_test", uvm_component parent=null);
    super.new(name,parent);
  endfunction

  // 功能：搭建两个 Host 的相同 BDF 场景，验证 route identity 必须来自 set_identity()，
  //       裸 BDF 歧义被拒绝，完整 Function handle 可正确选择 endpoint。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：仿真超时、事务返回错误或断言不满足时报告 UVM_ERROR/UVM_FATAL；空 fixture 不得被当作成功。
  task run_phase(uvm_phase phase);
    rdma_pcie_router router;
    rdma_pcie_route_entry entries[$];
    rdma_mock_pcie endpoint0;
    rdma_mock_pcie endpoint1;
    rdma_pcie_function_info function_info;
    rdma_bdf_t bdf;
    rdma_status status;
    rdma_function_handle function_h0;
    rdma_function_handle function_h1;
    rdma_function_handle bad_handle;
    rdma_function_identity identity0;
    rdma_function_identity identity1;
    rdma_pcie_route_entry raw_entry;
    rdma_pcie_route_entry raw_entries[$];
    rdma_function_key_t key0;
    rdma_function_key_t key1;
    byte data[];

    phase.raise_objection(this);
    router = rdma_pcie_router::type_id::create("router");
    endpoint0 = rdma_mock_pcie::type_id::create("endpoint0");
    endpoint1 = rdma_mock_pcie::type_id::create("endpoint1");
    endpoint0.function_info_response =
      rdma_pcie_function_info::type_id::create("function_info0");
    endpoint1.function_info_response =
      rdma_pcie_function_info::type_id::create("function_info1");

    bdf = '{segment:0, bus:1, device:0, function_num:0};
    endpoint0.function_info_response.bdf = bdf;
    endpoint1.function_info_response.bdf = bdf;
    key0 = '{root_id:0, host_topology_key:0,
            function_kind:RDMA_FUNCTION_PF, parent_pf_bdf:'0,
            vf_index:0, bdf:bdf};
    key1 = '{root_id:1, host_topology_key:1,
            function_kind:RDMA_FUNCTION_PF, parent_pf_bdf:'0,
            vf_index:0, bdf:bdf};

    identity0 = rdma_function_identity::type_id::create("identity0");
    identity1 = rdma_function_identity::type_id::create("identity1");
    status = identity0.configure(key0, 2, 11, 1, 0);
    if (!status.ok())
      `uvm_fatal("PCIE_ROUTE","identity fixture failed");
    status = identity1.configure(key1, 3, 22, 1, 0);
    if (!status.ok())
      `uvm_fatal("PCIE_ROUTE","identity fixture failed");

    entries.push_back(rdma_pcie_route_entry::type_id::create("entry0"));
    entries[0].endpoint = endpoint0;
    entries.push_back(rdma_pcie_route_entry::type_id::create("entry1"));
    entries[1].endpoint = endpoint1;
    status = entries[0].set_identity(identity0);
    if (!status.ok())
      `uvm_fatal("PCIE_ROUTE","route identity setup failed");
    status = entries[1].set_identity(identity1);
    if (!status.ok())
      `uvm_fatal("PCIE_ROUTE","route identity setup failed");

    // 直接填写 authority 字段不得绕过 set_identity() 的 provenance 检查。
    raw_entry = rdma_pcie_route_entry::type_id::create("raw_entry");
    raw_entry.route = entries[0].route;
    raw_entry.endpoint = endpoint0;
    raw_entry.function_uid = 11;
    raw_entry.global_function_id = 2;
    raw_entry.generation = 1;
    raw_entries.push_back(raw_entry);
    status = router.configure(raw_entries);
    if (status.ok())
      `uvm_error("PCIE_ROUTE","hand-written Function authority accepted");

    status = router.configure(entries);
    if (!status.ok())
      `uvm_fatal("PCIE_ROUTE","configure failed");
    status = router.get_function_info(bdf, function_info);
    if (status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("PCIE_ROUTE","ambiguous BDF accepted");

    function_h0 = rdma_function_handle::type_id::create("function_h0");
    function_h0.kind = RDMA_RESOURCE_FUNCTION;
    function_h0.function_uid = 11;
    function_h0.object_id = 2;
    function_h0.generation = 1;
    function_h1 = rdma_function_handle::type_id::create("function_h1");
    function_h1.kind = RDMA_RESOURCE_FUNCTION;
    function_h1.function_uid = 22;
    function_h1.object_id = 3;
    function_h1.generation = 1;
    bad_handle = rdma_function_handle::type_id::create("bad_handle");
    bad_handle.kind = RDMA_RESOURCE_FUNCTION;
    bad_handle.function_uid = 99;
    bad_handle.object_id = 9;
    bad_handle.generation = 1;

    router.mmio_write(function_h0, '0, data, status);
    if (!status.ok())
      `uvm_error("PCIE_ROUTE","Host0 handle rejected");
    router.mmio_write(function_h1, '0, data, status);
    if (!status.ok())
      `uvm_error("PCIE_ROUTE","Host1 handle rejected");
    router.mmio_write(bad_handle, '0, data, status);
    if (status.ok())
      `uvm_error("PCIE_ROUTE","bad handle accepted");

    phase.drop_objection(this);
  endtask
endclass
