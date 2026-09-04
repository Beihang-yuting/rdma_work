// 目录：测试层 unit/rdma_function_identity_test.sv。
// 职责：验证 rdma_function_identity_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：覆盖 Function identity 的拓扑隔离与 incarnation 比较契约。
class rdma_function_identity_test extends uvm_test;
  `uvm_component_utils(rdma_function_identity_test)
  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_function_identity_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行 UVM 阶段任务，驱动测试场景并在结束时释放阶段 objection（接口 run_phase）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task run_phase(uvm_phase phase);
    rdma_function_identity lhs, rhs, copy;
    rdma_function_binding binding;
    rdma_function_identity snapshot;
    rdma_function_handle handle;
    uvm_object cloned;
    rdma_route_key_t lhs_route, rhs_route;
    rdma_function_key_t key;
    rdma_status status;
    phase.raise_objection(this);
    key = '{root_id:16'h1, host_topology_key:32'h10, function_kind:RDMA_FUNCTION_VF,
            parent_pf_bdf:'{segment:0,bus:8'h20,device:5'h1,function_num:0},
            vf_index:16'h2, bdf:'{segment:0,bus:8'h30,device:5'h4,function_num:1}};
    lhs = rdma_function_identity::type_id::create("lhs");
    rhs = rdma_function_identity::type_id::create("rhs");
    status = lhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok()) `uvm_error("IDENTITY", $sformatf("lhs configure failed: %s", status.convert2string()))
    key.host_topology_key = 32'h11;
    status = rhs.configure(key, 7, 64'h1234, 1, 9);
    if (!status.ok()) `uvm_error("IDENTITY", $sformatf("rhs configure failed: %s", status.convert2string()))
    if (lhs.same_function(rhs)) `uvm_error("IDENTITY", "different host route compared equal")
    lhs_route = lhs.route_key();
    rhs_route = rhs.route_key();
    if ((lhs_route.host_topology_key == rhs_route.host_topology_key &&
         lhs_route.root_id == rhs_route.root_id &&
         lhs_route.segment == rhs_route.segment &&
         lhs_route.bdf.segment == rhs_route.bdf.segment &&
         lhs_route.bdf.bus == rhs_route.bdf.bus &&
         lhs_route.bdf.device == rhs_route.bdf.device &&
         lhs_route.bdf.function_num == rhs_route.bdf.function_num) ||
        lhs_route.host_topology_key != 32'h10 ||
        lhs_route.root_id != 16'h1 || lhs_route.segment != 16'h0 ||
        lhs_route.bdf.segment != lhs.key.bdf.segment ||
        lhs_route.bdf.bus != lhs.key.bdf.bus ||
        lhs_route.bdf.device != lhs.key.bdf.device ||
        lhs_route.bdf.function_num != lhs.key.bdf.function_num ||
        rhs_route.host_topology_key != 32'h11)
      `uvm_error("IDENTITY", "route key fields are incorrect")
    cloned = lhs.clone();
    if (cloned == null || !$cast(copy, cloned)) begin
      `uvm_error("IDENTITY", "identity clone failed")
    end
    else begin
      copy.reset_epoch = lhs.reset_epoch + 1;
      if (!lhs.same_function(copy) || lhs.same_incarnation(copy))
        `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    end
    key = lhs.key;
    status = rhs.configure(key, 7, 64'h1234, 1, 10);
    if (!status.ok() || !lhs.same_function(rhs) || lhs.same_incarnation(rhs))
      `uvm_error("IDENTITY", "reset epoch did not separate incarnation")
    status = lhs.configure(key, 7, 64'h1234, 0, 10);
    if (status.ok() || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("IDENTITY", "zero generation accepted")

    // Identity is the sole authority: legacy scalar fields cannot create a
    // usable handle when no valid identity has been configured.
    binding = rdma_function_binding::type_id::create("binding");
    binding.function_uid = 64'hfeed;
    binding.global_function_id = 32'hbeef;
    binding.generation = 32'h7;
    handle = binding.make_handle();
    if (handle != null)
      `uvm_error("IDENTITY", "legacy scalar fallback created a handle")

    // Explicit compatibility configuration migrates the legacy mirrors while
    // still requiring a deterministic host/root/PCIe route.
    binding.pcie.bdf = '{segment:0, bus:8'h20, device:5'h1,
                         function_num:3'h0};
    status = binding.configure_identity_from_legacy_mirrors(
      16'h0, 32'h1, RDMA_FUNCTION_PF);
    if (!status.ok())
      `uvm_error("IDENTITY", $sformatf("legacy identity migration failed: %s",
                                        status.convert2string()))
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != 64'hfeed ||
        handle.object_id != 32'hbeef || handle.generation != 32'h7)
      `uvm_error("IDENTITY", "explicit legacy migration did not create handle")

    status = binding.configure_identity(rhs);
    if (!status.ok())
      `uvm_error("IDENTITY", $sformatf("binding identity configure failed: %s",
                                        status.convert2string()))
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != rhs.function_uid ||
        handle.object_id != rhs.global_function_id ||
        handle.generation != rhs.generation)
      `uvm_error("IDENTITY", "identity authority did not produce expected handle")
    snapshot = binding.identity_snapshot();
    snapshot.key.host_topology_key = 32'hdead;
    snapshot.function_uid = 64'h123;
    handle = binding.make_handle();
    if (handle == null || handle.function_uid != rhs.function_uid ||
        binding.function_identity_snapshot().key.host_topology_key !=
          rhs.key.host_topology_key)
      `uvm_error("IDENTITY", "identity accessor leaked mutable authority")

    // Global function ID zero is a legal value; UID and generation remain
    // the required non-zero incarnation discriminators.
    key.host_topology_key = 32'h10;
    status = lhs.configure(key, 0, 64'h4321, 1, 11);
    if (!status.ok())
      `uvm_error("IDENTITY", "global function ID zero was rejected")

    // Host0 is a valid explicit route; incomplete BDF and malformed VF parent
    // data remain rejected.
    key.host_topology_key = 0;
    status = rhs.configure(key, 1, 64'h7777, 1, 1);
    if (!status.ok())
      `uvm_error("IDENTITY", "explicit Host0 route was rejected")
    key.host_topology_key = 32'h20;
    key.bdf = '{segment:0,bus:0,device:0,function_num:0};
    status = rhs.configure(key, 1, 64'h7777, 1, 1);
    if (status.ok() || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("IDENTITY", "invalid zero BDF route was accepted")
    phase.drop_objection(this);
  endtask
endclass
