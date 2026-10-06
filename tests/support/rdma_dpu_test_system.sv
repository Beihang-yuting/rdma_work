// 目录：测试支撑层 tests/support/rdma_dpu_test_system.sv。
// 层：测试支撑。
// 职责：单元测试的 dpu_common 夹具：每个 Function 一个独立 mock 主机内存域的工厂，以及建立
//   “Host0：PF0 + VF1..VF<vf_count>” 的 rdma_dpu_system 的快捷方法。
// 依赖：rdma_dpu_adapter_pkg（dpu_common）、rdma_mock_host_mem。
// 所有权：返回的 system 由调用方持有。
// 生命周期：随测试存在。
class rdma_mock_mem_factory extends rdma_dpu_mem_factory;
  `uvm_object_utils(rdma_mock_mem_factory)

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_mock_mem_factory");
    super.new(name);
  endfunction

  // 功能：为 Function 新建独立 IOVA 域的 mock 内存。
  // 输入/输出及副作用：返回新对象。
  // 失败/边界：无。
  virtual function rdma_host_mem_api make(rdma_dpu_function f);
    return rdma_mock_host_mem::type_id::create($sformatf("mock_mem_f%0d", f.global_id));
  endfunction
endclass

class rdma_dpu_test_system extends uvm_object;
  `uvm_object_utils(rdma_dpu_test_system)

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_dpu_test_system");
    super.new(name);
  endfunction

  // 功能：建立并 build Host0：PF0 + VF1..VF<vf_count> 的系统（mock 内存，不启动 NIC、不 probe）。
  // 输入/输出及副作用：返回新系统。
  // 失败/边界：build 失败报告 UVM_FATAL。
  static function rdma_dpu_system single_host(string name, int unsigned vf_count = 0);
    rdma_dpu_system sys;
    rdma_status status;

    sys = rdma_dpu_system::type_id::create(name);
    sys.mem_factory = rdma_mock_mem_factory::type_id::create({name, "_mem_factory"});
    sys.add_host(0);
    sys.add_function(0, 0, DPU_FUNCTION_PF, 0);
    for (int unsigned v = 1; v <= vf_count; v++)
      sys.add_function(0, 0, DPU_FUNCTION_VF, v);
    status = sys.build();
    if (!status.ok())
      `uvm_fatal("DPU_TEST", $sformatf("%s: dpu system build failed: %s", name,
                                       status.convert2string()))
    return sys;
  endfunction
endclass
