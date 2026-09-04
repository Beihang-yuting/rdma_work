// 目录：测试层 unit/rdma_sq_models_test.sv。
// 职责：验证 rdma_sq_models_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_sq_models_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_models_test extends uvm_test;
  `uvm_component_utils(rdma_sq_models_test)

  // 功能：初始化对象字段、同步 UVM 名称并建立可用的初始生命周期状态（接口 new）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  function new(string name = "rdma_sq_models_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：执行 UVM 阶段任务，驱动测试场景并在结束时释放阶段 objection（接口 run_phase）。
  // 输入/输出及副作用：输入参数和 output/inout 参数以签名为准；返回值传递状态或结果，
  //   void/task 通过对象字段、队列或日志产生副作用，不转移未声明的资源所有权。
  // 失败/边界：空句柄、非法枚举、越界值或生命周期不满足时拒绝操作并返回错误（若有返回值）。
  task run_phase(uvm_phase phase);
    longint unsigned logical_bytes, storage_bytes;
    rdma_status s; rdma_address_vector av, av_copy; uvm_object cloned;
    phase.raise_objection(this);
    if (!rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_UD, 1, 1))
      `uvm_error("SQ_CAP", "UD did not require SQ SGB")
    if (!rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_RC, 3, 1) ||
        rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_RC, 2, 2) ||
        rdma_qp_needs_sq_sgb(RDMA_TRANSPORT_URC, 32, 32))
      `uvm_error("SQ_CAP", "RC/URC SQ SGB thresholds are incorrect")
    s = rdma_qp_sq_sgb_geometry(16, logical_bytes, storage_bytes);
    if (s == null || !s.ok() || logical_bytes != 8192 || storage_bytes != 8192)
      `uvm_error("SQ_GEOMETRY", "16-slot SQ SGB geometry is incorrect")
    av = rdma_address_vector::type_id::create("av");
    av.\priority = 3; av.multicast = 1; av.forwarding_mode = 2;
    cloned = av.clone();
    if (cloned == null || !$cast(av_copy, cloned) || av_copy == av ||
        av_copy.\priority != 3 || !av_copy.multicast ||
        av_copy.forwarding_mode != 2)
      `uvm_error("SQ_AV", "AV clone lost detached UD WQE fields")
    phase.drop_objection(this);
  endtask
endclass
