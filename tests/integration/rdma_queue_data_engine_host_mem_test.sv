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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_real_host_mem_proxy");
    super.new(name);
    delegate = null;
  endfunction

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
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

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 mapping, offset, data 用于执行 write；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
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

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
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

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  virtual function rdma_status \release (rdma_dma_mapping mapping);
    if (delegate == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "real host-memory delegate is null");
    return delegate.\release (mapping);
  endfunction
endclass

class rdma_queue_data_engine_host_mem_test extends uvm_test;
  `uvm_component_utils(rdma_queue_data_engine_host_mem_test)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_queue_data_engine_host_mem_test",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase 控制 UVM 调度；task 驱动事务、断言和 objection，测试 fixture 由本层负责清理。
  //   阶段提前结束或前置 setup 失败时必须释放 objection 并停止后续访问。
  // 失败/边界：setup 失败或阶段被终止时停止新增事务，确保 objection、临时对象和外部引用按测试生命周期收尾。
  task run_phase(uvm_phase phase);
    $unit::host_mem_manager host_manager;
    rdma_host_mem_adapter real_adapter;
    rdma_real_host_mem_proxy proxy;
    rdma_queue_data_engine_fixture fixture;
    rdma_status status;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_post_send_req send_request;
    rdma_xtr_v1_cqe_model cqe;
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

    cqe = rdma_xtr_v1_cqe_model::type_id::create("real_device_cqe");
    cqe.qp_h = rdma_clone_handle_value(fixture.qp.handle, "real CQE QP");
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted == null ? 0 : posted.index;
    cqe.wqe_wrap = posted == null ? 0 : posted.wrap;
    cqe.rq_cqe = 1'b0;
    cqe.polarity = 1'b1;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = XTR_V1_CMQ_SUCCESS_ECODE;
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
