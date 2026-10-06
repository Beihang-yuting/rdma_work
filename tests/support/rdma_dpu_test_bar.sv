// 目录：测试支撑层 tests/support/rdma_dpu_test_bar.sv。
// 层：测试支撑。
// 职责：单设备单元测试的 dpu_common 连线：声明 Host0 上 PF0 及 vf_count 个 VF，解析冻结快照，取第
//   pick 个 Function，驱动的 BAR 写经快照 BAR0 解码送到给定设备；并记录 BAR 内偏移与值供断言。
// 依赖：rdma_dpu_adapter_pkg（dpu_common）、rdma_dev。
// 所有权：快照与路由器由本对象持有；设备只借用。
// 生命周期：随测试存在。
class rdma_dpu_test_bar extends rdma_dpu_bar;
  `uvm_object_utils(rdma_dpu_test_bar)

  dpu_device_snapshot snapshot;
  bit [63:0] written_offsets[$];
  bit [63:0] written_values[$];

  // 功能：构造未连接的 BAR。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_dpu_test_bar");
    super.new(name);
    snapshot = null;
  endfunction

  // 功能：建立 dpu_common 拓扑（Host0：PF0 + VF1..VF<vf_count>）并返回连到 dev、代表快照中第 pick
  //   个 Function 的 BAR。
  // 输入/输出及副作用：返回新 BAR（持有快照与路由器）。
  // 失败/边界：解析失败或 pick 越界报告 UVM_FATAL。
  static function rdma_dpu_test_bar make(string name, rdma_dev dev, int unsigned vf_count = 0,
                                         int unsigned pick = 0);
    dpu_device_cfg cfg;
    rdma_dpu_function funcs[$];
    rdma_dpu_test_bar bar;
    rdma_status status;

    cfg = dpu_device_cfg::type_id::create({name, "_dpu_cfg"});
    rdma_dpu_topology::add_host(cfg, 0);
    rdma_dpu_topology::add_function(cfg, 0, 0, DPU_FUNCTION_PF, 0);
    for (int unsigned v = 1; v <= vf_count; v++)
      rdma_dpu_topology::add_function(cfg, 0, 0, DPU_FUNCTION_VF, v);
    bar = rdma_dpu_test_bar::type_id::create(name);
    status = rdma_dpu_topology::resolve(cfg, bar.snapshot, funcs);
    if (!status.ok() || pick >= funcs.size())
      `uvm_fatal("DPU_TEST_BAR", $sformatf("%s: dpu_common topology failed: %s", name,
                                           status.convert2string()))
    bar.router = rdma_dpu_bar_router::type_id::create({name, "_router"});
    bar.router.snapshot = bar.snapshot;
    bar.router.attach(funcs[pick], dev);
    bar.func = funcs[pick];
    return bar;
  endfunction

  // 功能：记录 BAR 内偏移与值后经路由器写入。
  // 输入/输出及副作用：见 rdma_dpu_bar.write64。
  // 失败/边界：同 rdma_dpu_bar.write64。
  virtual task write64(bit [63:0] offset, bit [63:0] value, output rdma_status status);
    written_offsets.push_back(offset);
    written_values.push_back(value);
    super.write64(offset, value, status);
  endtask
endclass
