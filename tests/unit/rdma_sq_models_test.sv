// 目录：测试层 unit/rdma_sq_models_test.sv。
// 职责：验证 rdma_sq_models_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_sq_models_test.sv 属于单元测试，覆盖对应模型、编码器或执行器契约。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_sq_models_test extends uvm_test;
  `uvm_component_utils(rdma_sq_models_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_sq_models_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
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
