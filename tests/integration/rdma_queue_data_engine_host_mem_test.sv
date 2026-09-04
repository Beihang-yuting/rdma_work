// 目录：测试层 integration/rdma_queue_data_engine_host_mem_test.sv。
// 职责：验证 rdma_queue_data_engine_host_mem_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：rdma_queue_data_engine_host_mem_test.sv 属于集成测试，验证真实适配器与队列/控制面之间的联调。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// End-to-end queue data-plane test using the pinned host_mem implementation.
// The test intentionally reuses the lifecycle fixture from the core package,
// replacing only its host-memory adapter with a delegating real adapter.

import rdma_unit_test_pkg::*;
import rdma_codec_pkg::*;

class rdma_real_host_mem_proxy extends rdma_mock_host_mem;
  `uvm_object_utils(rdma_real_host_mem_proxy)

  rdma_host_mem_adapter delegate;

  // 功能：构造 rdma_real_host_mem_proxy，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：delegate=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_real_host_mem_proxy 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_real_host_mem_proxy");
    super.new(name);
    delegate = null;
  endfunction

  // 功能：在 rdma_real_host_mem_proxy 中，allocate 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、mapping（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  virtual function rdma_status allocate(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_dma_mapping mapping
  );
    if (delegate == null) begin
      mapping = null;
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    end
    return delegate.allocate(request_context, size, alignment, direction,
                              mapping);
  endfunction

  // 功能：在 rdma_real_host_mem_proxy 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending
  //   journal，并通过 output 返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  virtual function rdma_status write(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    byte data[]
  );
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    return delegate.write(mapping, offset, data);
  endfunction

  // 功能：在 rdma_real_host_mem_proxy 中，read 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：mapping（输入）、offset（输入）、size（输入）、data（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status read(
    rdma_dma_mapping mapping,
    longint unsigned offset,
    int unsigned size,
    output byte data[]
  );
    if (delegate == null) begin
      data = new[0];
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    end
    return delegate.read(mapping, offset, size, data);
  endfunction

  // 功能：在 rdma_real_host_mem_proxy 中，release 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    return delegate.\release (mapping);
  endfunction
endclass

class rdma_queue_data_engine_host_mem_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_host_mem_test)

  // 功能：构造 rdma_queue_data_engine_host_mem_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_data_engine_host_mem_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_data_engine_host_mem_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：在 rdma_queue_data_engine_host_mem_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    $unit::host_mem_manager host_manager;
    rdma_host_mem_adapter real_adapter;
    rdma_real_host_mem_proxy proxy;
    rdma_queue_data_engine_fixture fixture;
    rdma_status status;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_post_send_req send_request;
    rdma_hw_cqe_model cqe;
    rdma_destroy_resource_req destroy_request;
    rdma_control_result destroy_result;
    int unsigned leak_count;
    byte actual_entry[];

    phase.raise_objection(this);

    host_manager = $unit::host_mem_manager::type_id::create("queue_hm_real");
    host_manager.init_region(64'h0000_0008_0000_0000,
                             64'h0000_0008_00ff_ffff);
    real_adapter = rdma_host_mem_adapter::type_id::create(
      "queue_real_adapter");
    real_adapter.mem = host_manager;
    real_adapter.iova_base = 64'h0000_0010_0000_0000;
    proxy = rdma_real_host_mem_proxy::type_id::create("queue_mem_proxy");
    proxy.delegate = real_adapter;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      "queue_real_fixture");
    fixture.mem = proxy;
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("REAL_SETUP", status == null ? "null setup status" :
                 status.convert2string())
      phase.drop_objection(this);
      return;
    end

    send_request = fixture.make_send(64'hcafe_0000_0000_0001);
    fixture.engine.post_send(send_request, posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("REAL_POST", status == null ? "null status" :
                 status.convert2string())
    end
    else begin
      status = fixture.read_qp_entry(1'b1, posted.index, actual_entry);
      if (status == null || !status.ok() || actual_entry.size() != 64)
        `uvm_error("REAL_SQ_READ", status == null ? "null status" :
                   status.convert2string())
      else foreach (actual_entry[i])
        if (actual_entry[i] !== posted.image.bytes[i])
          `uvm_error("REAL_SQ_BYTES",
                     $sformatf("SQ byte %0d differs from returned image", i))
    end

    cqe = rdma_hw_cqe_model::type_id::create("real_device_cqe");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "real CQE QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted == null ? 0 : posted.index;
    cqe.wqe_wrap = posted == null ? 0 : posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.status = rdma_status::success();
    status = fixture.write_cq_entry(0, cqe);
    if (status == null || !status.ok())
      `uvm_error("REAL_CQE_WRITE", status == null ? "null status" :
                 status.convert2string())

    completion = null;
    fixture.engine.poll_cqe(fixture.cq.handle, 0, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != send_request.wr_id ||
        completion.completion_status == null ||
        !completion.completion_status.ok())
      `uvm_error("REAL_POLL", status == null ? "null status" :
                 status.convert2string())

    // Destroying the lifecycle resources releases the real pinned allocations
    // through the adapter's ownership ledger.  The final leak check is the
    // integration contract: no test backing may survive the transaction.
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_qp");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.qp.handle;
    fixture.qp_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2001,
      destroy_result);
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_cq");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.cq.handle;
    fixture.queue_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2002,
      destroy_result);
    destroy_request = rdma_destroy_resource_req::type_id::create(
      "real_destroy_ceq");
    destroy_request.owner = fixture.binding.make_handle();
    destroy_request.target_h = fixture.ceq.handle;
    fixture.queue_executor.destroy_locked(fixture.binding,
      fixture.binding.make_handle(), destroy_request, 64'h2003,
      destroy_result);
    status = real_adapter.check_leaks(leak_count);
    if (status == null || !status.ok() || leak_count != 0)
      `uvm_error("REAL_LEAK", status == null ? "null status" :
                 $sformatf("%s leaks=%0d", status.convert2string(),
                           leak_count))

    phase.drop_objection(this);
  endtask
endclass
