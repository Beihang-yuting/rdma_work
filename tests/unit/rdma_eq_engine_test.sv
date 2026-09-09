// 目录：测试层 unit/rdma_eq_engine_test.sv，覆盖 CEQ/AEQ facade 的消费入口。
// 职责：验证 EQ facade 将 CEQ/AEQ producer 与 consumer 调用透明委托给共享 runtime，
//   并拒绝把 CEQ handle 当作 AEQ 使用。
// 依赖：rdma_core_pkg、queue-data fixture、mock Host-memory/PCIe 后端。
// 所有权与生命周期：测试只拥有本地 fixture；EQ facade 借用共享 delegate 和 router 引用。

class rdma_eq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_eq_engine_test)

  // 功能：创建 UVM EQ 测试组件并保存父组件关系，不预先登记事件队列。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：CEQ/AEQ attachment 由 run_phase 显式建立，失败时停止后续访问；非零超时的空环返回 TIMEOUT。
  function new(string name = "rdma_eq_engine_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：clone_test_handle_value 为 EQ facade model 分配 detached handle 并复制
  //   kind、Function UID、object ID 与 generation。
  // 输入/输出及副作用：source 为输入、copy 为输出；成功只创建测试值快照，
  //   不修改源 handle、manager、event runtime 或 backing。
  // 失败/边界：source/factory 分配为空时返回错误且 copy 保持 null；调用方不得
  //   退化为借用源对象，否则无法证明 facade 没有重写 identity。
  function automatic rdma_status clone_test_handle_value(
    rdma_handle source,
    output rdma_handle copy
  );
    rdma_handle candidate;

    copy = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "EQ facade test handle source is null");
    candidate = rdma_handle::type_id::create("eq_facade_handle_copy");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "EQ facade test handle allocation failed");
    candidate.kind = source.kind;
    candidate.function_uid = source.function_uid;
    candidate.object_id = source.object_id;
    candidate.generation = source.generation;
    copy = candidate;
    return rdma_status::success();
  endfunction

  // 功能：setup_publish_event_rings 为一套 equivalence fixture 依次创建/attach
  //   lifecycle CEQ、AEQ、依赖该 CEQ 的 CQ，以及依赖该 CQ 的 RC QP。
  // 输入/输出及副作用：fixture 为输入，四个资源、各自 created/attached 状态及
  //   status 为输出；成功建立 owned backing 和同一套完整 event/transport route。
  // 失败/边界：request/create/cast/clone/attach 任一步失败立即返回；状态输出保留
  //   已完成阶段，使 cleanup 能销毁未 attach 的资源且不借用 dependency-only CQ/CEQ。
  task automatic setup_publish_event_rings(
    rdma_queue_data_engine_fixture fixture,
    output rdma_ceq ceq,
    output rdma_aeq aeq,
    output rdma_cq cq,
    output rdma_qp target_qp,
    output bit ceq_created,
    output bit ceq_attached,
    output bit aeq_created,
    output bit aeq_attached,
    output bit cq_created,
    output bit cq_attached,
    output bit qp_created,
    output bit qp_attached,
    output rdma_status status
  );
    rdma_create_ceq_req ceq_request;
    rdma_create_aeq_req aeq_request;
    rdma_create_cq_req cq_request;
    rdma_queue_resource resource;
    rdma_control_result control_result;

    ceq = null;
    aeq = null;
    cq = null;
    target_qp = null;
    ceq_created = 1'b0;
    ceq_attached = 1'b0;
    aeq_created = 1'b0;
    aeq_attached = 1'b0;
    cq_created = 1'b0;
    cq_attached = 1'b0;
    qp_created = 1'b0;
    qp_attached = 1'b0;
    status = rdma_status::make(RDMA_SC_INVALID_STATE,
                               "EQ publish rings are incomplete");
    if (fixture == null || fixture.binding == null ||
        fixture.queue_executor == null || fixture.engine == null) return;
    ceq_request = rdma_create_ceq_req::type_id::create("eq_publish_ceq_request");
    if (ceq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "EQ publish CEQ request allocation failed");
      return;
    end
    ceq_request.owner = fixture.binding.make_handle();
    ceq_request.depth = 16;
    ceq_request.vector_id = 1;
    ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), ceq_request, 64'ha101,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "EQ publish CEQ returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(ceq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "EQ publish CEQ resource is invalid");
      return;
    end
    ceq_created = 1'b1;
    status = fixture.engine.attach_ceq(ceq.handle);
    if (status == null || !status.ok()) return;
    ceq_attached = 1'b1;

    aeq_request = rdma_create_aeq_req::type_id::create("eq_publish_aeq_request");
    if (aeq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "EQ publish AEQ request allocation failed");
      return;
    end
    aeq_request.owner = fixture.binding.make_handle();
    aeq_request.depth = 16;
    aeq_request.vector_id = 2;
    aeq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), aeq_request, 64'ha102,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "EQ publish AEQ returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(aeq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "EQ publish AEQ resource is invalid");
      return;
    end
    aeq_created = 1'b1;
    status = fixture.engine.attach_aeq(aeq.handle);
    if (status == null || !status.ok()) return;
    aeq_attached = 1'b1;

    cq_request = rdma_create_cq_req::type_id::create("eq_publish_cq_request");
    if (cq_request == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "EQ publish CQ request allocation failed");
      return;
    end
    cq_request.owner = fixture.binding.make_handle();
    cq_request.depth = 16;
    cq_request.cqe_size_bytes = RDMA_CQE_BYTES;
    status = clone_test_handle_value(ceq.handle, cq_request.ceq_h);
    if (status == null || !status.ok() || cq_request.ceq_h == null) return;
    cq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    resource = null;
    control_result = null;
    fixture.queue_executor.create_locked(
      fixture.binding, fixture.binding.make_handle(), cq_request, 64'ha103,
      resource, control_result);
    status = control_result == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE, "EQ publish CQ returned no result") :
      control_result.status;
    if (status == null || !status.ok() || resource == null ||
        !$cast(cq, resource)) begin
      if (status == null || status.ok())
        status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                   "EQ publish CQ resource is invalid");
      return;
    end
    cq_created = 1'b1;
    status = fixture.engine.attach_cq(cq.handle, RDMA_TRANSPORT_RC);
    if (status == null || !status.ok()) return;
    cq_attached = 1'b1;

    fixture.create_transport_qp_for_cq(
      "eq_publish_event_qp", RDMA_TRANSPORT_RC, cq, target_qp, status);
    if (status == null || !status.ok() || target_qp == null) return;
    qp_created = 1'b1;
    status = fixture.engine.attach_qp(target_qp.handle);
    if (status == null || !status.ok()) return;
    qp_attached = 1'b1;
    status = rdma_status::success();
  endtask

  // 功能：make_publish_event_models 从 CQ committed cursor 与真实 attached QP
  //   构造 CEQE/AEQE，确保两种 facade 成功路径使用完整 authority。
  // 输入/输出及副作用：fixture、ceq、aeq、cq、非零 target_qp 为输入，ceqe/aeqe/status
  //   为输出；只读 runtime cursor/polarity并创建 detached model，不写 event backing。
  // 失败/边界：cursor 超过 CEQE 16-bit、polarity 查询、handle clone 或分配失败时
  //   两个输出归一化为 null；AEQE 始终使用非零 fixture QPN。
  task automatic make_publish_event_models(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq ceq,
    rdma_aeq aeq,
    rdma_cq cq,
    rdma_qp target_qp,
    output rdma_hw_ceqe_model ceqe,
    output rdma_hw_aeqe_model aeqe,
    output rdma_status status
  );
    int unsigned producer_index;
    int unsigned consumer_index;
    bit producer_wrap;
    bit consumer_wrap;
    bit polarity;

    ceqe = null;
    aeqe = null;
    status = fixture.engine.query_runtime_cursors(
      cq.handle, RDMA_QUEUE_RUNTIME_CQ, producer_index, producer_wrap,
      consumer_index, consumer_wrap);
    if (status == null || !status.ok()) return;
    if (producer_index > 16'hffff) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "EQ facade CQ PI does not fit CEQE");
      return;
    end
    status = fixture.engine.query_runtime_producer_polarity(
      ceq.handle, RDMA_QUEUE_RUNTIME_CEQ, polarity);
    if (status == null || !status.ok()) return;
    ceqe = rdma_hw_ceqe_model::type_id::create("eq_facade_ceqe");
    if (ceqe == null) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "EQ facade CEQE allocation failed");
      return;
    end
    status = clone_test_handle_value(cq.handle, ceqe.cq_h);
    if (status == null || !status.ok() || ceqe.cq_h == null) begin
      ceqe = null;
      return;
    end
    ceqe.cqn = cq.local_cq_id;
    ceqe.qpn = 0;
    ceqe.cq_pi = producer_index;
    ceqe.cq_pi_wrap = producer_wrap;
    ceqe.valid = polarity;
    ceqe.ecode = 0;
    ceqe.packet_opcode = 0;

    status = fixture.engine.query_runtime_producer_polarity(
      aeq.handle, RDMA_QUEUE_RUNTIME_AEQ, polarity);
    if (status == null || !status.ok()) begin
      ceqe = null;
      return;
    end
    aeqe = rdma_hw_aeqe_model::type_id::create("eq_facade_aeqe");
    if (aeqe == null) begin
      ceqe = null;
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "EQ facade AEQE allocation failed");
      return;
    end
    if (target_qp == null || target_qp.handle == null ||
        target_qp.local_qp_id == 0) begin
      ceqe = null;
      aeqe = null;
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "EQ facade AEQE target QP is zero/incomplete");
      return;
    end
    status = clone_test_handle_value(target_qp.handle, aeqe.target_h);
    if (status == null || !status.ok() || aeqe.target_h == null) begin
      ceqe = null;
      aeqe = null;
      return;
    end
    aeqe.qpn = target_qp.local_qp_id;
    aeqe.valid = polarity;
    aeqe.ecode = 0;
    aeqe.packet_opcode = 0;
    status = rdma_status::success();
  endtask

  // 功能：same_publish_result 比较 direct delegate 与 facade 的 detached 发布结果
  //   是否具有相同 slot、occupancy、image 和 status 值。
  // 输入/输出及副作用：lhs/rhs 为只读输入；返回值由所有公开结果字段逐项计算，
  //   不 clone 对象、不读取 backing、不改变 runtime。
  // 失败/边界：任一 result/queue_h/image/status 为空立即返回 0；两套 fixture 的
  //   queue identity 各自对输入 handle 断言，不能要求跨 manager 的 object ID 相同。
  function automatic bit same_publish_result(
    rdma_queue_device_publish_result lhs,
    rdma_queue_device_publish_result rhs
  );
    if (lhs == null || rhs == null || lhs.queue_h == null ||
        rhs.queue_h == null || lhs.image == null || rhs.image == null ||
        lhs.status == null || rhs.status == null) return 1'b0;
    return lhs.index == rhs.index && lhs.wrap == rhs.wrap &&
           lhs.occupancy == rhs.occupancy &&
           lhs.occupancy_valid == rhs.occupancy_valid &&
           lhs.image.bytes == rhs.image.bytes &&
           lhs.image.length == rhs.image.length &&
           lhs.image.alignment == rhs.image.alignment &&
           lhs.image.image_kind == rhs.image.image_kind &&
           lhs.status.code == rhs.status.code &&
           lhs.status.message == rhs.status.message;
  endfunction

  // 功能：cleanup_publish_event_rings 销毁 equivalence fixture 的 QP、CQ、AEQ、
  //   CEQ，证明完整依赖拓扑不会留给仿真结束隐式回收。
  // 输入/输出及副作用：fixture、四个资源及 created/attached 状态为输入；按
  //   QP→CQ→AEQ→CEQ 顺序清理并报告失败，不影响下一项资源清理。
  // 失败/边界：fixture 为空安全返回；QP 或 queue 单项 status 为空/非成功只报告，
  //   不提前退出，避免一个失败掩盖后续独立资源泄漏。
  task automatic cleanup_publish_event_rings(
    rdma_queue_data_engine_fixture fixture,
    rdma_ceq ceq,
    rdma_aeq aeq,
    rdma_cq cq,
    rdma_qp target_qp,
    bit ceq_created,
    bit ceq_attached,
    bit aeq_created,
    bit aeq_attached,
    bit cq_created,
    bit cq_attached,
    bit qp_created,
    bit qp_attached
  );
    rdma_status status;

    if (fixture == null) return;
    if (target_qp != null) begin
      fixture.destroy_lifecycle_owned_qp(
        target_qp.handle, qp_created, qp_attached, 64'ha114, status);
      if (status == null || !status.ok())
        `uvm_error("EQ_QP_TEARDOWN", "EQ publish QP teardown failed")
    end
    if (cq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        cq.handle, cq_created, cq_attached, 64'ha113, status);
      if (status == null || !status.ok())
        `uvm_error("EQ_CQ_TEARDOWN", "EQ publish CQ teardown failed")
    end
    if (aeq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        aeq.handle, aeq_created, aeq_attached, 64'ha112, status);
      if (status == null || !status.ok())
        `uvm_error("EQ_AEQ_TEARDOWN", "EQ publish AEQ teardown failed")
    end
    if (ceq != null) begin
      fixture.destroy_lifecycle_owned_queue(
        ceq.handle, ceq_created, ceq_attached, 64'ha111, status);
      if (status == null || !status.ok())
        `uvm_error("EQ_CEQ_TEARDOWN", "EQ publish CEQ teardown failed")
    end
  endtask

  // 功能：check_publish_delegate_equivalence 用两套等价真实 fixture 验证 CEQE 与
  //   AEQE facade 成功/拒绝输出与 direct delegate 完全一致。
  // 输入/输出及副作用：无显式输入；创建独立 event rings，分别执行 direct/facade
  //   publish 并逐字段比较结果，最后无条件尝试清理两套临时 ring。
  // 失败/边界：任一 setup/config/model/publish 失败报告错误；null model 必须让两路
  //   返回相同 code/message 且 result=null，清理错误不能掩盖原断言。
  task automatic check_publish_delegate_equivalence();
    rdma_queue_data_engine_fixture direct_fixture;
    rdma_queue_data_engine_fixture facade_fixture;
    rdma_ceq direct_ceq;
    rdma_ceq facade_ceq;
    rdma_aeq direct_aeq;
    rdma_aeq facade_aeq;
    rdma_cq direct_cq;
    rdma_cq facade_cq;
    rdma_qp direct_qp;
    rdma_qp facade_qp;
    rdma_eq_engine facade;
    rdma_hw_ceqe_model direct_ceqe;
    rdma_hw_ceqe_model facade_ceqe;
    rdma_hw_aeqe_model direct_aeqe;
    rdma_hw_aeqe_model facade_aeqe;
    rdma_queue_device_publish_result direct_result;
    rdma_queue_device_publish_result facade_result;
    rdma_status direct_status;
    rdma_status facade_status;
    bit ready;
    bit direct_ceq_created;
    bit direct_ceq_attached;
    bit direct_aeq_created;
    bit direct_aeq_attached;
    bit direct_cq_created;
    bit direct_cq_attached;
    bit direct_qp_created;
    bit direct_qp_attached;
    bit facade_ceq_created;
    bit facade_ceq_attached;
    bit facade_aeq_created;
    bit facade_aeq_attached;
    bit facade_cq_created;
    bit facade_cq_attached;
    bit facade_qp_created;
    bit facade_qp_attached;
    string setup_stage;

    direct_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "eq_direct_publish_fixture");
    facade_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "eq_forward_publish_fixture");
    direct_ceq = null;
    facade_ceq = null;
    direct_aeq = null;
    facade_aeq = null;
    direct_cq = null;
    facade_cq = null;
    direct_qp = null;
    facade_qp = null;
    setup_stage = "fixture allocation";
    ready = direct_fixture != null && facade_fixture != null;
    if (ready) begin
      setup_stage = "fixture setup";
      direct_fixture.setup(direct_status);
      facade_fixture.setup(facade_status);
      ready = direct_status != null && direct_status.ok() &&
              facade_status != null && facade_status.ok();
    end
    if (ready) begin
      setup_stage = "event ring setup";
      setup_publish_event_rings(
        direct_fixture, direct_ceq, direct_aeq, direct_cq, direct_qp,
        direct_ceq_created, direct_ceq_attached, direct_aeq_created,
        direct_aeq_attached, direct_cq_created, direct_cq_attached,
        direct_qp_created, direct_qp_attached, direct_status);
      setup_publish_event_rings(
        facade_fixture, facade_ceq, facade_aeq, facade_cq, facade_qp,
        facade_ceq_created, facade_ceq_attached, facade_aeq_created,
        facade_aeq_attached, facade_cq_created, facade_cq_attached,
        facade_qp_created, facade_qp_attached, facade_status);
      ready = direct_status != null && direct_status.ok() &&
              facade_status != null && facade_status.ok();
    end
    if (ready) begin
      setup_stage = "facade configure";
      facade = rdma_eq_engine::type_id::create("eq_publish_equivalence_facade");
      facade_status = facade.configure(
        facade_fixture.manager, facade_fixture.binding, facade_fixture.mem,
        facade_fixture.scheduler, facade_fixture.registry, 2us,
        facade_fixture.engine);
      ready = facade_status != null && facade_status.ok();
    end
    if (ready) begin
      setup_stage = "event model construction";
      make_publish_event_models(
        direct_fixture, direct_ceq, direct_aeq, direct_cq, direct_qp,
        direct_ceqe, direct_aeqe,
        direct_status);
      make_publish_event_models(
        facade_fixture, facade_ceq, facade_aeq, facade_cq, facade_qp,
        facade_ceqe, facade_aeqe,
        facade_status);
      ready = direct_status != null && direct_status.ok() &&
              facade_status != null && facade_status.ok() &&
              direct_ceqe != null && facade_ceqe != null &&
              direct_aeqe != null && facade_aeqe != null;
    end
    if (!ready) begin
      `uvm_error("EQ_DELEGATE_SETUP", $sformatf(
        "EQ publish equivalence failed at %s: direct=%s facade=%s",
        setup_stage,
        direct_status == null ? "<null>" : direct_status.convert2string(),
        facade_status == null ? "<null>" : facade_status.convert2string()))
    end else begin
      direct_fixture.engine.publish_ceqe(
        direct_ceq.handle, direct_ceqe, direct_result, direct_status);
      facade.publish_ceqe(
        facade_ceq.handle, facade_ceqe, facade_result, facade_status);
      if (direct_status == null || !direct_status.ok() ||
          facade_status == null || !facade_status.ok() ||
          direct_result == null || direct_result.queue_h == null ||
          facade_result == null || facade_result.queue_h == null ||
          !direct_result.queue_h.same_instance(direct_ceq.handle) ||
          !facade_result.queue_h.same_instance(facade_ceq.handle) ||
          direct_result.queue_h == direct_ceq.handle ||
          facade_result.queue_h == facade_ceq.handle ||
          !same_publish_result(direct_result, facade_result) ||
          direct_status.code != facade_status.code ||
          direct_status.message != facade_status.message)
        `uvm_error("EQ_CEQE_DELEGATE_SUCCESS",
                   "CEQE facade result differs from direct delegate")

      direct_fixture.engine.publish_aeqe(
        direct_aeq.handle, direct_aeqe, direct_result, direct_status);
      facade.publish_aeqe(
        facade_aeq.handle, facade_aeqe, facade_result, facade_status);
      if (direct_status == null || !direct_status.ok() || direct_result == null ||
          facade_status == null || !facade_status.ok() || facade_result == null)
        `uvm_error("EQ_AEQE_DELEGATE_STATUS", $sformatf(
          "AEQE publish failed: direct_result=%s direct_status=%s facade_result=%s facade_status=%s",
          direct_result == null ? "null" : "non-null",
          direct_status == null ? "<null>" : direct_status.convert2string(),
          facade_result == null ? "null" : "non-null",
          facade_status == null ? "<null>" : facade_status.convert2string()))
      else if (!direct_result.queue_h.same_instance(direct_aeq.handle) ||
               !facade_result.queue_h.same_instance(facade_aeq.handle) ||
               direct_result.queue_h == direct_aeq.handle ||
               facade_result.queue_h == facade_aeq.handle ||
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
        `uvm_error("EQ_AEQE_DELEGATE_SUCCESS",
                   "AEQE facade result differs from direct delegate")

      direct_fixture.engine.publish_ceqe(
        direct_ceq.handle, null, direct_result, direct_status);
      facade.publish_ceqe(
        facade_ceq.handle, null, facade_result, facade_status);
      if (direct_status == null || direct_status.ok() ||
          direct_status.code != RDMA_SC_INVALID_ARGUMENT ||
          facade_status == null || facade_status.ok() ||
          direct_status.code != facade_status.code ||
          direct_status.message != facade_status.message ||
          direct_result != null || facade_result != null)
        `uvm_error("EQ_CEQE_DELEGATE_REJECT",
                   "CEQE facade rejection differs from direct delegate")

      direct_fixture.engine.publish_aeqe(
        direct_aeq.handle, null, direct_result, direct_status);
      facade.publish_aeqe(
        facade_aeq.handle, null, facade_result, facade_status);
      if (direct_status == null || direct_status.ok() ||
          direct_status.code != RDMA_SC_INVALID_ARGUMENT ||
          facade_status == null || facade_status.ok() ||
          direct_status.code != facade_status.code ||
          direct_status.message != facade_status.message ||
          direct_result != null || facade_result != null)
        `uvm_error("EQ_AEQE_DELEGATE_REJECT",
                   "AEQE facade rejection differs from direct delegate")
    end
    cleanup_publish_event_rings(
      direct_fixture, direct_ceq, direct_aeq, direct_cq, direct_qp,
      direct_ceq_created, direct_ceq_attached, direct_aeq_created,
      direct_aeq_attached, direct_cq_created, direct_cq_attached,
      direct_qp_created, direct_qp_attached);
    cleanup_publish_event_rings(
      facade_fixture, facade_ceq, facade_aeq, facade_cq, facade_qp,
      facade_ceq_created, facade_ceq_attached, facade_aeq_created,
      facade_aeq_attached, facade_cq_created, facade_cq_attached,
      facade_qp_created, facade_qp_attached);
  endtask

  // 功能：配置 EQ facade，消费空 CEQ、拒绝错误 AEQ kind，并执行 CEQE/AEQE
  //   direct/facade producer 成功与确定性拒绝等价矩阵。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：未登记的 AEQ、错误 Function 或 stale handle 必须返回错误且不发布 event。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_eq_engine facade;
    rdma_queue_event_result event_result;
    rdma_queue_device_publish_result published;
    rdma_create_ceq_req ceq_request;
    rdma_queue_resource ceq_resource;
    rdma_control_result create_result;
    rdma_ceq runtime_ceq;
    rdma_status status;
    rdma_status cleanup_status;
    bit runtime_ceq_created;
    bit runtime_ceq_attached;

    phase.raise_objection(this);
    runtime_ceq = null;
    runtime_ceq_created = 1'b0;
    runtime_ceq_attached = 1'b0;
    fixture = rdma_queue_data_engine_fixture::type_id::create("eq_fixture");
    fixture.setup(status);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_FIXTURE", "queue-data fixture setup failed")
      phase.drop_objection(this);
      return;
    end
    facade = rdma_eq_engine::type_id::create("eq_facade");
    // 功能：验证两个 producer facade 入口在未配置时均不取得 event backing。
    // 输入/输出及副作用：使用 fixture 句柄和 null model 调用，published/status
    // 为输出；只观察配置门禁，不创建 reservation、不修改 runtime 或 Host-memory。
    // 失败边界：两个入口都必须返回 INVALID_STATE 且 published 为 null；若任一路径
    // 成功，说明 facade 绕过了 delegate 的生命周期 authority。
    facade.publish_ceqe(fixture.ceq.handle, null, published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE || published != null)
      `uvm_error("EQ_CEQE_UNCONFIGURED", "unconfigured EQ facade published CEQE")
    facade.publish_aeqe(fixture.ceq.handle, null, published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE || published != null)
      `uvm_error("EQ_AEQE_UNCONFIGURED", "unconfigured EQ facade published AEQE")
    // fixture.ceq 是 CQ 创建前登记的 dependency-only 资源，没有 queue plan；
    // 此处建立 lifecycle-owned CEQ，使 facade 走真实 Host-memory ring/backing，
    // 而不是只拿 synthetic handle 验证 kind。
    ceq_request = rdma_create_ceq_req::type_id::create("eq_ceq_request");
    ceq_request.owner = fixture.binding.make_handle();
    ceq_request.depth = 16;
    ceq_request.vector_id = 1;
    ceq_request.ring_backing.mode = RDMA_QUEUE_BACKING_OWNED;
    fixture.queue_executor.create_locked(fixture.binding,
                                         fixture.binding.make_handle(),
                                         ceq_request, 64'h1003,
                                         ceq_resource, create_result);
    if (create_result == null || create_result.status == null ||
        !create_result.status.ok() || ceq_resource == null ||
        !$cast(runtime_ceq, ceq_resource)) begin
      `uvm_error("EQ_CREATE", create_result == null || create_result.status == null ?
                 "CEQ lifecycle create returned no status" :
                 create_result.status.convert2string())
      phase.drop_objection(this);
      return;
    end
    runtime_ceq_created = 1'b1;
    status = fixture.engine.attach_ceq(runtime_ceq.handle);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_ATTACH", status == null ? "CEQ attachment setup failed: null status" :
                 status.convert2string())
      fixture.destroy_lifecycle_owned_queue(
        runtime_ceq.handle, runtime_ceq_created, runtime_ceq_attached,
        64'h1004, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("EQ_RUNTIME_CEQ_TEARDOWN",
                   "unattached runtime CEQ teardown failed")
      phase.drop_objection(this);
      return;
    end
    runtime_ceq_attached = 1'b1;

    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("EQ_CONFIGURE", "EQ facade configuration failed")
      fixture.destroy_lifecycle_owned_queue(
        runtime_ceq.handle, runtime_ceq_created, runtime_ceq_attached,
        64'h1004, cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("EQ_RUNTIME_CEQ_TEARDOWN",
                   "configured-path runtime CEQ teardown failed")
      phase.drop_objection(this);
      return;
    end

    facade.poll_ceqe(runtime_ceq.handle, event_result, status);
    // 已配置的非零 timeout 原样传给共享 engine，因此空 CEQ 等待后返回 TIMEOUT。
    if (status == null || status.code != RDMA_SC_TIMEOUT || event_result != null)
      `uvm_error("CEQ_FORWARD", "EQ facade did not forward empty CEQ poll")

    event_result = null;
    facade.poll_aeqe(runtime_ceq.handle, event_result, status);
    if (status == null || status.ok() || event_result != null)
      `uvm_error("AEQ_KIND", "EQ facade accepted a CEQ handle in AEQ path")

    check_publish_delegate_equivalence();

    fixture.destroy_lifecycle_owned_queue(
      runtime_ceq.handle, runtime_ceq_created, runtime_ceq_attached,
      64'h1004, cleanup_status);
    if (cleanup_status == null || !cleanup_status.ok())
      `uvm_error("EQ_RUNTIME_CEQ_TEARDOWN", "runtime CEQ teardown failed")

    phase.drop_objection(this);
  endtask
endclass
