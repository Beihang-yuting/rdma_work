// 目录：测试层 unit/rdma_cq_engine_test.sv，覆盖 CQ facade 的消费顺序契约。
// 职责：验证 CQ facade 复用共享 runtime，透明发布 CQE，并完成 CQE 解码、CI 提交和 completion 发布。
// 依赖：rdma_core_pkg、queue-data fixture、XTR v1 CQE codec 和 mock Host-memory 后端。
// 所有权与生命周期：测试只拥有本地 fixture；CQ facade 不拥有 runtime 或 backing mapping。

class rdma_cq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cq_engine_test)

  // 功能：创建 UVM CQ 测试组件并建立父组件关系，不访问设备资源。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cq_engine_test 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：clone_test_handle_value 为 CQ facade 测试分配 detached handle 并逐字段
  //   复制身份，避免通用 clone/cast 的 fatal 路径掩盖委托结果。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功仅创建测试拥有的值快照，
  //   不修改 source、manager、runtime 或 backing。
  // 失败/边界：source 或 factory 分配为空时返回明确错误且 copy 保持 null，调用方
  //   必须停止 model 构造，不能以共享原 handle 退化替代。
  function automatic rdma_status clone_test_handle_value(
    rdma_handle source,
    output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ facade test handle source is null");
    candidate = rdma_handle::type_id::create("cq_facade_handle_copy");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "CQ facade test handle allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：make_publish_cqe 根据真实 outstanding SQ post 构造可发布 CQE，供 direct
  //   delegate 与 facade 在等价初态下执行同一业务事务。
  // 输入/输出及副作用：fixture、posted、polarity 为输入，model/status 为输出；
  //   仅分配 model/handle 快照，不推进 cursor、不写 backing、不释放 WQE ledger。
  // 失败/边界：fixture/QP/post 或分配不完整时返回非成功且 model 为 null；packed
  //   字段只接受 fixture 已分配的可表示 QPN，不伪造截断 authority。
  task automatic make_publish_cqe(
    rdma_queue_data_engine_fixture fixture,
    rdma_queue_post_result posted,
    bit polarity,
    output rdma_hw_cqe_model model,
    output rdma_status status
  );
    model = null;
    status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "CQ facade publish fixture is incomplete");
    if (fixture == null || fixture.qp == null || fixture.qp.handle == null ||
        posted == null || posted.status == null || !posted.status.ok()) return;
    model = rdma_hw_cqe_model::type_id::create("cq_facade_publish_model");
    if (model == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "CQ facade model allocation failed");
      return;
    end
    status = clone_test_handle_value(fixture.qp.handle, model.qp_h);
    if (status == null || !status.ok() || model.qp_h == null) begin
      model = null;
      return;
    end
    model.wr_id = posted.wr_id;
    model.opcode = RDMA_WR_SEND;
    model.status = rdma_status::success();
    model.qpn = fixture.qp.local_qp_id;
    model.wqe_index = posted.index;
    model.wqe_wrap = posted.wrap;
    model.rq_cqe = 1'b0;
    model.polarity = polarity;
    model.packet_opcode = 8'h01;
    model.ecode = RDMA_CMQ_SUCCESS_ECODE;
    model.payload_len = 32;
    model.immediate_data = 0;
    model.signature = 0;
    status = rdma_status::success();
  endtask

  // 功能：check_publish_delegate_equivalence 以两个等价真实 fixture 比较 direct
  //   publish_cqe 与 facade publish_cqe 的成功输出及确定性拒绝输出。
  // 输入/输出及副作用：无显式输入；两边各 post/publish 一个 WQE 并写各自 backing，
  //   逐字段比较 queue_h、image、index/wrap/occupancy/status，不共享可变 runtime。
  // 失败/边界：任一 setup/configure/post/model/publish 失败立即报告；null model 拒绝
  //   必须保留 delegate 的精确 code/message 且 direct/facade result 都为 null。
  task automatic check_publish_delegate_equivalence();
    rdma_queue_data_engine_fixture direct_fixture;
    rdma_queue_data_engine_fixture facade_fixture;
    rdma_cq_engine facade;
    rdma_queue_post_result direct_posted;
    rdma_queue_post_result facade_posted;
    rdma_queue_device_publish_result direct_result;
    rdma_queue_device_publish_result facade_result;
    rdma_hw_cqe_model direct_model;
    rdma_hw_cqe_model facade_model;
    rdma_status direct_status;
    rdma_status facade_status;
    bit direct_polarity;
    bit facade_polarity;

    direct_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cq_direct_publish_fixture");
    facade_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cq_forward_publish_fixture");
    if (direct_fixture == null || facade_fixture == null) begin
      `uvm_error("CQ_DELEGATE_FIXTURE", "CQ equivalence fixture allocation failed")
      return;
    end
    direct_fixture.setup(direct_status);
    facade_fixture.setup(facade_status);
    if (direct_status == null || !direct_status.ok() ||
        facade_status == null || !facade_status.ok()) begin
      `uvm_error("CQ_DELEGATE_SETUP", "CQ equivalence fixture setup failed")
      return;
    end
    facade = rdma_cq_engine::type_id::create("cq_publish_equivalence_facade");
    facade_status = facade.configure(
      facade_fixture.manager, facade_fixture.binding, facade_fixture.mem,
      facade_fixture.scheduler, facade_fixture.registry, 2us,
      facade_fixture.engine);
    if (facade_status == null || !facade_status.ok()) begin
      `uvm_error("CQ_DELEGATE_CONFIGURE", "CQ equivalence facade configure failed")
      return;
    end

    direct_fixture.engine.post_send(
      direct_fixture.make_send(64'h5151), direct_posted, direct_status);
    facade_fixture.engine.post_send(
      facade_fixture.make_send(64'h5151), facade_posted, facade_status);
    if (direct_status == null || !direct_status.ok() || direct_posted == null ||
        facade_status == null || !facade_status.ok() || facade_posted == null) begin
      `uvm_error("CQ_DELEGATE_POST", "CQ equivalence WQE post failed")
      return;
    end
    direct_status = direct_fixture.engine.query_runtime_producer_polarity(
      direct_fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, direct_polarity);
    facade_status = facade_fixture.engine.query_runtime_producer_polarity(
      facade_fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, facade_polarity);
    if (direct_status == null || !direct_status.ok() ||
        facade_status == null || !facade_status.ok()) begin
      `uvm_error("CQ_DELEGATE_POLARITY", "CQ equivalence polarity query failed")
      return;
    end
    make_publish_cqe(
      direct_fixture, direct_posted, direct_polarity, direct_model, direct_status);
    make_publish_cqe(
      facade_fixture, facade_posted, facade_polarity, facade_model, facade_status);
    if (direct_status == null || !direct_status.ok() || direct_model == null ||
        facade_status == null || !facade_status.ok() || facade_model == null) begin
      `uvm_error("CQ_DELEGATE_MODEL", "CQ equivalence model construction failed")
      return;
    end
    direct_fixture.engine.publish_cqe(
      direct_fixture.cq.handle, direct_model, direct_result, direct_status);
    facade.publish_cqe(
      facade_fixture.cq.handle, facade_model, facade_result, facade_status);
    if (direct_status == null || !direct_status.ok() || direct_result == null ||
        facade_status == null || !facade_status.ok() || facade_result == null ||
        direct_result.queue_h == null || facade_result.queue_h == null ||
        !direct_result.queue_h.same_instance(direct_fixture.cq.handle) ||
        !facade_result.queue_h.same_instance(facade_fixture.cq.handle) ||
        direct_result.queue_h == direct_fixture.cq.handle ||
        facade_result.queue_h == facade_fixture.cq.handle ||
        direct_result.queue_h.kind != facade_result.queue_h.kind ||
        direct_result.queue_h.function_uid != facade_result.queue_h.function_uid ||
        direct_result.queue_h.object_id != facade_result.queue_h.object_id ||
        direct_result.queue_h.generation != facade_result.queue_h.generation ||
        direct_result.index != facade_result.index ||
        direct_result.wrap != facade_result.wrap ||
        direct_result.occupancy != facade_result.occupancy ||
        direct_result.occupancy_valid != facade_result.occupancy_valid ||
        direct_result.image == null || facade_result.image == null ||
        direct_result.image.bytes != facade_result.image.bytes ||
        direct_result.image.length != facade_result.image.length ||
        direct_result.image.alignment != facade_result.image.alignment ||
        direct_result.image.image_kind != facade_result.image.image_kind ||
        direct_result.status == null || facade_result.status == null ||
        direct_result.status.code != facade_result.status.code ||
        direct_result.status.message != facade_result.status.message ||
        direct_status.code != facade_status.code ||
        direct_status.message != facade_status.message)
      `uvm_error("CQ_DELEGATE_SUCCESS",
                 "CQ facade success output differs from direct delegate")

    direct_fixture.engine.publish_cqe(
      direct_fixture.cq.handle, null, direct_result, direct_status);
    facade.publish_cqe(
      facade_fixture.cq.handle, null, facade_result, facade_status);
    if (direct_status == null || direct_status.ok() ||
        direct_status.code != RDMA_SC_INVALID_ARGUMENT ||
        facade_status == null || facade_status.ok() ||
        direct_status.code != facade_status.code ||
        direct_status.message != facade_status.message ||
        direct_result != null || facade_result != null)
      `uvm_error("CQ_DELEGATE_REJECT",
                 "CQ facade rejection differs from direct delegate")
  endtask

  // 功能：check_cqe_stride_profile 通过 CQ facade 连续发布两个真实 SQ completion，
  //   验证 32/64/128-byte profile 都以 index*cqe_size 定位且完整保留 slot 0。
  // 输入/输出及副作用：cqe_size 为输入；task 创建独立 lifecycle fixture/facade，
  //   post 两个 WQE、写 CQ backing、读取两个 slot 并 poll 回收，最后统一 cleanup。
  // 失败/边界：setup/codec/publish/readback/poll 任一步失败报告 UVM_ERROR；image
  //   length/alignment 必须等于 cqe_size，第二项必须 index=1，失败也继续回收资源。
  task automatic check_cqe_stride_profile(input int unsigned cqe_size);
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_engine facade;
    rdma_queue_post_result posted0, posted1;
    rdma_queue_device_publish_result published0, published1;
    rdma_queue_completion_result completion;
    rdma_hw_cqe_model cqe0, cqe1;
    rdma_status status, model_status, cleanup_status;
    byte slot0[], slot1[];
    bit polarity;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      $sformatf("cq_stride_%0d_fixture", cqe_size));
    begin : stride_flow
      if (fixture == null) begin
        `uvm_error("CQ_STRIDE_FACTORY", "stride fixture allocation failed")
        disable stride_flow;
      end
      fixture.setup(status, 16, cqe_size, 16, 16);
      if (status == null || !status.ok()) begin
        `uvm_error("CQ_STRIDE_SETUP", status == null ?
                   "stride setup returned null" : status.convert2string())
        disable stride_flow;
      end
      facade = rdma_cq_engine::type_id::create(
        $sformatf("cq_stride_%0d_facade", cqe_size));
      status = facade.configure(
        fixture.manager, fixture.binding, fixture.mem, fixture.scheduler,
        fixture.registry, 2us, fixture.engine);
      if (status == null || !status.ok()) begin
        `uvm_error("CQ_STRIDE_CONFIGURE", "stride facade configure failed")
        disable stride_flow;
      end

      fixture.engine.post_send(
        fixture.make_send(64'h6000 + cqe_size), posted0, status);
      if (status == null || !status.ok() || posted0 == null) begin
        `uvm_error("CQ_STRIDE_POST0", "first stride WQE post failed")
        disable stride_flow;
      end
      status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      make_publish_cqe(fixture, posted0, polarity, cqe0, model_status);
      if (status == null || !status.ok() || model_status == null ||
          !model_status.ok() || cqe0 == null) begin
        `uvm_error("CQ_STRIDE_MODEL0", "first stride CQE model failed")
        disable stride_flow;
      end
      facade.publish_cqe(fixture.cq.handle, cqe0, published0, status);
      if (status == null || !status.ok() || published0 == null ||
          published0.index != 0 || published0.wrap ||
          published0.occupancy != 1 || !published0.occupancy_valid ||
          published0.image == null || published0.image.length != cqe_size ||
          published0.image.alignment != cqe_size ||
          published0.image.bytes.size() != cqe_size) begin
        `uvm_error("CQ_STRIDE_PUBLISH0", "first stride publish geometry failed")
        disable stride_flow;
      end

      fixture.engine.post_send(
        fixture.make_send(64'h7000 + cqe_size), posted1, status);
      if (status == null || !status.ok() || posted1 == null) begin
        `uvm_error("CQ_STRIDE_POST1", "second stride WQE post failed")
        disable stride_flow;
      end
      status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      make_publish_cqe(fixture, posted1, polarity, cqe1, model_status);
      if (status == null || !status.ok() || model_status == null ||
          !model_status.ok() || cqe1 == null) begin
        `uvm_error("CQ_STRIDE_MODEL1", "second stride CQE model failed")
        disable stride_flow;
      end
      facade.publish_cqe(fixture.cq.handle, cqe1, published1, status);
      if (status == null || !status.ok() || published1 == null ||
          published1.index != 1 || published1.wrap ||
          published1.occupancy != 2 || !published1.occupancy_valid ||
          published1.image == null || published1.image.length != cqe_size ||
          published1.image.alignment != cqe_size ||
          published1.image.bytes.size() != cqe_size) begin
        `uvm_error("CQ_STRIDE_PUBLISH1", "second stride publish geometry failed")
        disable stride_flow;
      end
      status = fixture.read_cq_entry(0, cqe_size, slot0);
      if (status == null || !status.ok() ||
          slot0.size() != published0.image.bytes.size()) begin
        `uvm_error("CQ_STRIDE_SLOT0", "slot zero changed after index-one publish")
        disable stride_flow;
      end
      // dynamic array 与 image byte queue 在 VCS 中不能直接聚合比较；逐字节校验
      // 同时确保第二次 publish 没有污染 slot 0 的任何 padding 或有效载荷。
      foreach (slot0[i]) begin
        if (slot0[i] != published0.image.bytes[i]) begin
          `uvm_error("CQ_STRIDE_SLOT0",
                     "slot zero changed after index-one publish")
          disable stride_flow;
        end
      end
      status = fixture.read_cq_entry(1, cqe_size, slot1);
      if (status == null || !status.ok() ||
          slot1.size() != published1.image.bytes.size()) begin
        `uvm_error("CQ_STRIDE_SLOT1",
                   "index-one readback does not match index*cqe_size offset")
        disable stride_flow;
      end
      // slot 1 逐字节对照 facade 返回的编码镜像，避免不同集合类型的隐式转换
      // 掩盖 stride offset 或尾部 padding 错位。
      foreach (slot1[i]) begin
        if (slot1[i] != published1.image.bytes[i]) begin
          `uvm_error("CQ_STRIDE_SLOT1",
                     "index-one readback does not match index*cqe_size offset")
          disable stride_flow;
        end
      end
      facade.poll_cqe(fixture.cq.handle, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.wr_id != posted0.wr_id) begin
        `uvm_error("CQ_STRIDE_POLL0", "first stride completion did not poll")
        disable stride_flow;
      end
      completion = null;
      facade.poll_cqe(fixture.cq.handle, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null || completion.cqe.wr_id != posted1.wr_id)
        `uvm_error("CQ_STRIDE_POLL1", "second stride completion did not poll")
    end
    if (fixture != null) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("CQ_STRIDE_CLEANUP", cleanup_status == null ?
                   "stride cleanup returned null" : cleanup_status.convert2string())
    end
  endtask

  // 功能：check_variable_cqe_strides 逐项运行 32/64/128-byte CQE profile，
  //   防止 facade 或 fixture 把 CQ slot offset 固定为 64 bytes。
  // 输入/输出及副作用：无显式输入输出；每个 profile 使用独立 fixture，彼此不
  //   共享 cursor/backing；只通过 UVM 报告暴露结果。
  // 失败/边界：单个 profile 失败不跳过后续 stride，便于一次运行收集完整矩阵。
  task automatic check_variable_cqe_strides();
    check_cqe_stride_profile(32);
    check_cqe_stride_profile(64);
    check_cqe_stride_profile(128);
  endtask

  // 功能：配置 CQ facade，向共享 CQ runtime 发布一条 CQE并验证 CI 只提交一次，
  //   同时执行 direct/facade producer 等价性与配置门禁矩阵。
  // 输入/输出及副作用：phase 为输入；task 通过 objection、日志和
  //   断言暴露结果，并在统一 epilogue 释放 fixture 持有的全部资源。
  // 失败/边界：CQE owner、QPN 或 Function 不匹配时不应发布
  //   completion；任一 setup/post/publish 失败仍必须 cleanup，非零 timeout
  //   的空槽位必须返回 TIMEOUT。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_engine facade;
    rdma_cq_engine unconfigured_facade;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_status status;
    rdma_status cleanup_status;
    bit producer_polarity;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("cq_fixture");
    // 中文设计：主流程的任一失败都跳到同一 cleanup epilogue，
    // 避免新增 Function/PD/AEQ ownership 后仍沿用旧的早退路径。
    begin : cq_flow
      if (fixture == null) begin
        `uvm_error("CQ_FIXTURE", "queue-data fixture allocation failed")
        disable cq_flow;
      end
      fixture.setup(status);
      if (status == null || !status.ok()) begin
        `uvm_error("CQ_FIXTURE", "queue-data fixture setup failed")
        disable cq_flow;
      end

    facade = rdma_cq_engine::type_id::create("cq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_CONFIGURE", "CQ facade configuration failed")
      disable cq_flow;
    end

    fixture.engine.post_send(fixture.make_send(64'h5050), posted, status);
    if (status == null || !status.ok() || posted == null) begin
      `uvm_error("CQ_POST", "CQ fixture WQE post failed")
      disable cq_flow;
    end
    cqe = rdma_hw_cqe_model::type_id::create("cq_device_entry");
    if (cqe == null) begin
      `uvm_error("CQ_MODEL", "CQ facade model allocation failed")
      disable cq_flow;
    end
    status = clone_test_handle_value(fixture.qp.handle, cqe.qp_h);
    if (status == null || !status.ok() || cqe.qp_h == null) begin
      `uvm_error("CQ_MODEL_HANDLE", "CQ facade QP handle clone failed")
      disable cq_flow;
    end
    cqe.qpn = fixture.qp.local_qp_id;
    cqe.wqe_index = posted.index;
    cqe.wqe_wrap = posted.wrap;
    cqe.rq_cqe = 1'b0;
    status = fixture.engine.query_runtime_producer_polarity(
      fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_polarity);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_PUBLISH_POLARITY", "CQ publish polarity query failed")
      disable cq_flow;
    end
    cqe.polarity = producer_polarity;
    cqe.packet_opcode = 8'h01;
    cqe.ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqe.payload_len = 32;
    cqe.status = rdma_status::success();
    // 设计说明：device consumer 只读取已提交 occupancy；不能再以直接 backing
    // 写入伪造可见 CQE，必须经 facade→publish pipeline 建立 reservation/commit。
    published = null;
    facade.publish_cqe(fixture.cq.handle, cqe, published, status);
    if (status == null || !status.ok() || published == null ||
        published.queue_h == null || !published.queue_h.same_instance(fixture.cq.handle) ||
        published.image == null) begin
      `uvm_error("CQ_PUBLISH", "CQ facade did not forward committed publish")
      disable cq_flow;
    end

    facade.poll_cqe(fixture.cq.handle, completion, status);
    if (status == null || !status.ok() || completion == null ||
        completion.cqe == null || completion.cqe.wr_id != 64'h5050)
      `uvm_error("CQ_FORWARD", $sformatf(
                 "direct CQE poll failed: status=%s completion=%p polarity=%0b",
                 status == null ? "<null>" : status.convert2string(),
                 completion, cqe.polarity))

    completion = null;
    facade.poll_cqe(fixture.cq.handle, completion, status);
    // 非零 facade timeout 会把下一个空槽映射为 TIMEOUT；该结果证明 CI 已推进，
    // 否则 stale CI 会重复读取同一 CQE，并在 WQE release 校验处失败。
    if (status == null || status.code != RDMA_SC_TIMEOUT || completion != null)
      `uvm_error("CQ_CI", $sformatf("CQ facade did not preserve CI commit semantics: status=%s completion=%p",
                                      status == null ? "<null>" : status.convert2string(),
                                      completion))

    // 功能：以独立、从未 configure 的 facade 验证 publish 门禁，避免该负例
    // 与基线 direct-write CQ consumer 场景共享对象状态。
    // 输入/输出及副作用：fixture CQ/model 为输入，published/status 为输出；只读
    // 入参且不接触 engine/backing/runtime，观察未配置对象的公开拒绝结果。
    // 失败边界：必须为 INVALID_STATE/空 result；任何成功表示 facade 绕过配置。
    unconfigured_facade = rdma_cq_engine::type_id::create("idle_cq_facade");
    unconfigured_facade.publish_cqe(fixture.cq.handle, null, published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE || published != null)
      `uvm_error("CQ_PUBLISH_UNCONFIGURED", "unconfigured CQ facade published")

    check_publish_delegate_equivalence();
    check_variable_cqe_strides();
    end

    if (fixture != null) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("CQ_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end

    phase.drop_objection(this);
  endtask
endclass
