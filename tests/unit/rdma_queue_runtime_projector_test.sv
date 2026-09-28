// 目录/层次：tests/unit；职责：独立验证 runtime 值投影，不构造 runtime 或生命周期环境。
// 依赖：UVM factory、runtime transaction models 和 rdma_queue_runtime_projector。
// 所有权/生命周期：测试拥有合成对象图与临时 factory；结束恢复原 factory，不申请外部资源。

// 错型对象不携带任何 RDMA 值字段，确保所有 typed cast 都必须拒绝。
class rdma_runtime_value_wrong extends uvm_object;
  // 功能：构造 factory 错型载体，仅用于值复制的非致命拒绝测试。
  // 输入/输出及副作用：name 传给基类，不注册或持有任何生产资源。
  // 失败/边界：不能 cast 成 pending、request、handle、cursor、image 或 status。
  function new(string name = "runtime_value_wrong");
    super.new(name);
  endfunction
endclass

// 按创建名注入单次 null/错型，另在外层 image 创建回调中递归复制第二份 pending。
class rdma_runtime_value_factory extends uvm_default_factory;
  string fail_name;
  bit wrong_type;
  bit fired;
  bit reenter;
  int unsigned calls;
  rdma_queue_pending_operation inner_source;
  rdma_queue_pending_operation inner_copy;
  rdma_status inner_status;

  // 功能：构造默认无故障、无重入的 factory，供本 test 的短窗口安装。
  // 输入/输出及副作用：无参数；清零计数，inner_* 初始为空且仅由测试持有。
  // 失败/边界：不自动安装全局 factory；调用方必须保存并恢复原 factory。
  function new();
    super.new();
    fail_name = "";
    wrong_type = 1'b0;
    fired = 1'b0;
    reenter = 1'b0;
    calls = 0;
  endfunction

  // 功能：截获精确名称的一次创建，或在 image 窗口递归进入同一 static automatic 值链。
  // 输入/输出及副作用：requested_type/parent_inst_path/name 默认透传；累计 calls，
  //   命中故障置 fired；重入前清 reenter，inner_copy/inner_status 保存嵌套结果。
  // 失败/边界：注入返回 null 或独立错型对象；不改变原 source，不持续递归，不吞生产错误。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    rdma_runtime_value_wrong wrong;

    calls++;
    if (reenter && name == "nonfatal_image_copy") begin
      reenter = 1'b0;
      inner_status = rdma_queue_runtime_projector::clone_pending_value(inner_source, inner_copy);
    end
    if (!fired && fail_name != "" && name == fail_name) begin
      fired = 1'b1;
      if (!wrong_type)
        return null;
      wrong = new();
      return wrong;
    end
    return super.create_object_by_type(requested_type, parent_inst_path, name);
  endfunction
endclass

// 值比较不等于业务 admission；合成 source 只覆盖字段与复制，不声称可直接安装 runtime。
class rdma_queue_runtime_projector_test extends uvm_test;
  `uvm_component_utils(rdma_queue_runtime_projector_test)
  typedef rdma_queue_runtime_projector values;

  // 功能：建立独立的 projector UVM test，不构造 engine、runtime、manager 或外部 adapter。
  // 输入/输出及副作用：name/parent 透传，资源只在 run_phase 中创建。
  // 失败/边界：构造不安装 factory，不发布队列或改变全局 authority。
  function new(string name = "rdma_queue_runtime_projector_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造包含 send/recv 请求、nullable SGE、image/status/cursor 与阶段位的合成 pending。
  // 输入/输出及副作用：receive 选择请求类型，tag 区分内外层对象图；返回测试独占 source。
  // 失败/边界：使用直接 new 排除 fixture 工厂故障；不执行 request.validate 或 runtime admission。
  function rdma_queue_pending_operation make_source(bit receive, int unsigned tag);
    rdma_queue_pending_operation pending;
    rdma_post_send_req send_request;
    rdma_post_recv_req recv_request;
    rdma_semantic_request request;
    rdma_sge sge;

    pending = new("source");
    pending.queue_h = new("queue");
    pending.queue_h.kind = RDMA_RESOURCE_QP;
    pending.queue_h.function_uid = 9;
    pending.queue_h.object_id = tag;
    pending.queue_h.generation = 7;
    pending.routed_qp_h = pending.queue_h;
    pending.cursor = new("cursor");
    pending.cursor.index = 3;
    pending.cursor.wrap = 1'b1;
    pending.next_cursor = new("next");
    pending.next_cursor.index = 4;
    pending.next_cursor.wrap = 1'b1;
    pending.committed_consumer_cursor = pending.next_cursor;
    pending.image = new("image");
    pending.image.length = 2;
    pending.image.alignment = 64;
    pending.image.bytes.push_back(8'h29);
    pending.image.bytes.push_back(byte'(tag));
    pending.image.field_summary.push_back("runtime value image");
    pending.failure_status = rdma_status::make_direct(RDMA_SC_DMA_TRANSLATION, "source failure");
    pending.failure_status.hardware_code_valid = 1'b1;
    pending.failure_status.hardware_code = 31;
    pending.failure_status.retryable = 1'b1;
    sge = new("sge");
    sge.iova.value = 64'h100000;
    sge.length = tag;
    sge.lkey = 123;
    if (receive) begin
      recv_request = new("recv");
      recv_request.target_h = pending.queue_h;
      recv_request.completion_qp_h = pending.queue_h;
      recv_request.wr_id = tag;
      recv_request.sges.push_back(sge);
      recv_request.sges.push_back(null);
      request = recv_request;
    end
    else begin
      send_request = new("send");
      send_request.qp_h = pending.queue_h;
      send_request.completion_qp_h = pending.queue_h;
      send_request.mr_h = pending.queue_h;
      send_request.mw_h = pending.queue_h;
      send_request.authority_h = pending.queue_h;
      send_request.wr_id = tag;
      send_request.transport = RDMA_TRANSPORT_UD;
      send_request.address_vector = new("av");
      send_request.address_vector.destination_ip[0] = 32'h12345678;
      send_request.address_vector.destination_mac = 48'h010203040506;
      send_request.address_vector.\priority = 3;
      send_request.payload.push_back(8'h81);
      send_request.sges.push_back(sge);
      send_request.sges.push_back(null);
      request = send_request;
    end
    request.owner = new("owner");
    request.owner.function_uid = 9;
    request.owner.generation = 7;
    request.request_id = tag;
    request.correlation_id = tag + 1;
    pending.request_snapshot = request;
    pending.kind = receive ? RDMA_QUEUE_RUNTIME_RQ : RDMA_QUEUE_RUNTIME_SQ;
    pending.producer = 1'b1;
    pending.wr_id = tag;
    pending.entry_size = 64;
    pending.entry_offset = 192;
    pending.route = '1;
    pending.route_valid = 1'b1;
    pending.epoch_valid = 1'b1;
    pending.reset_epoch = tag;
    pending.mmio_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
    pending.mmio_maybe_submitted = 1'b1;
    pending.consumer_committed = 1'b1;
    pending.consumer_shadow_attempted = 1'b1;
    pending.consumer_shadow_published = 1'b1;
    return pending;
  endfunction

  // 功能：确认 send/recv 的 pending 全图复制隔离，逐个改变九类 immutable evidence 检查拒绝。
  // 输入/输出及副作用：receive 决定类型；只改变 detached copy，source 必须保留原值。
  // 失败/边界：clone/status/类型缺失 fatal；alias、阶段丢失或比较放宽 error；不构造 live ledger。
  function void check_graph(bit receive);
    rdma_queue_pending_operation source, copy;
    rdma_post_send_req send_source, send_copy;
    rdma_post_recv_req recv_source, recv_copy;
    rdma_status status;

    source = make_source(receive, 229);
    for (int unsigned field = 0; field < 9; field++) begin
      status = values::clone_pending_value(source, copy);
      if (!values::status_is_ok(status) || copy == null)
        `uvm_fatal("RUNTIME_VALUE", "pending clone failed")
      if (!values::pending_immutable_evidence_equal(source, copy) || copy == source ||
          copy.queue_h == source.queue_h || copy.cursor == source.cursor ||
          copy.next_cursor == source.next_cursor || copy.image == source.image ||
          copy.failure_status == source.failure_status ||
          copy.request_snapshot == source.request_snapshot ||
          copy.request_snapshot.owner == source.request_snapshot.owner ||
          copy.routed_qp_h == source.routed_qp_h ||
          copy.committed_consumer_cursor == source.committed_consumer_cursor ||
          !copy.consumer_committed || !copy.consumer_shadow_attempted ||
          !copy.consumer_shadow_published || copy.mmio_evidence != RDMA_QUEUE_MMIO_AMBIGUOUS)
        `uvm_error("RUNTIME_VALUE", "pending graph alias or value loss")
      if (receive) begin
        if (!$cast(recv_source, source.request_snapshot) ||
            !$cast(recv_copy, copy.request_snapshot))
          `uvm_fatal("RUNTIME_VALUE", "receive type lost")
        if (recv_copy.sges[0] == recv_source.sges[0] || recv_copy.sges[1] != null)
          `uvm_error("RUNTIME_VALUE", "receive SGE alias/null shape")
      end
      else begin
        if (!$cast(send_source, source.request_snapshot) ||
            !$cast(send_copy, copy.request_snapshot))
          `uvm_fatal("RUNTIME_VALUE", "send type lost")
        if (send_copy.sges[0] == send_source.sges[0] || send_copy.sges[1] != null ||
            send_copy.address_vector == send_source.address_vector ||
            send_copy.qp_h == send_source.qp_h || send_copy.authority_h == send_source.authority_h)
          `uvm_error("RUNTIME_VALUE", "send nested alias/null shape")
      end
      case (field)
        0: copy.queue_h.generation++;
        1: copy.next_cursor.wrap = !copy.next_cursor.wrap;
        2: copy.image.bytes[0]++;
        3: copy.failure_status.message = "changed";
        4: copy.request_snapshot.owner.function_uid++;
        5: copy.request_snapshot.request_id++;
        6: copy.route = '0;
        7: copy.reset_epoch++;
        8: copy.consumer_shadow_value++;
        default: `uvm_fatal("RUNTIME_VALUE", "unknown mutation field")
      endcase
      if (values::pending_immutable_evidence_equal(source, copy))
        `uvm_error("RUNTIME_VALUE", $sformatf("immutable mutation %0d accepted", field))
    end
  endfunction

  // 功能：对十二个真实创建名各注入 null/错型，覆盖 send/recv、nested graph 与 slot 外壳。
  // 输入/输出及副作用：factory 是已安装的测试工厂；每例 armed 一次并检查命中，末尾 disarm。
  // 失败/边界：任何故障必须 RESOURCE_EXHAUSTED 且无半成品；正常副本在故障移除后可再次创建。
  function void check_factory_faults(rdma_runtime_value_factory factory);
    string names[12] = '{"nonfatal_pending_copy", "nonfatal_handle_copy", "nonfatal_cursor_copy",
      "nonfatal_image_copy", "nonfatal_status_copy", "nonfatal_post_request_copy",
      "nonfatal_recv_request_copy", "nonfatal_owner_copy", "nonfatal_address_vector_copy",
      "nonfatal_sge_0", "nonfatal_recv_sge_0", "release_range_slot_copy"};
    rdma_queue_pending_operation source, copy;
    rdma_queue_slot_ledger_entry slot, slot_copy;
    rdma_status status;

    foreach (names[i]) begin
      for (int wrong = 0; wrong < 2; wrong++) begin
        source = make_source(i inside {6, 10}, 229);
        slot = new("slot");
        slot.request_snapshot = source.request_snapshot;
        slot.image = source.image;
        slot.completion_status = source.failure_status;
        factory.fail_name = names[i];
        factory.wrong_type = bit'(wrong);
        factory.fired = 1'b0;
        if (i == 11) begin
          status = values::clone_slot_value_nonfatal(slot, slot_copy);
          if (slot_copy != null)
            `uvm_error("RUNTIME_VALUE", "failed slot published partial value")
        end
        else begin
          status = values::clone_pending_value(source, copy);
          if (copy != null)
            `uvm_error("RUNTIME_VALUE", "failed pending published partial value")
        end
        if (!factory.fired || status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED)
          `uvm_error("RUNTIME_VALUE", {"factory fault missed: ", names[i]})
        factory.fail_name = "";
      end
    end
    status = values::clone_slot_value_nonfatal(slot, slot_copy);
    if (!values::status_is_ok(status) || slot_copy == null || slot_copy == slot ||
        slot_copy.request_snapshot == slot.request_snapshot || slot_copy.image == slot.image ||
        !values::request_value_equal(slot_copy.request_snapshot, slot.request_snapshot))
      `uvm_error("RUNTIME_VALUE", "slot clone did not recover")
  endfunction

  // 功能：验证 status null/错型 fallback、无分配初始化、nullable 和必要证据的边界。
  // 输入/输出及副作用：factory 用于计数/故障；只构造合成值，检查 status 字段清零与比较语义。
  // 失败/边界：空 pending/不完整 device evidence 非成功，nullable handle 合法空成功；不改 authority。
  function void check_boundaries(rdma_runtime_value_factory factory);
    rdma_status status;
    rdma_queue_pending_operation source, copy;
    rdma_handle handle_copy;
    rdma_semantic_request unsupported, request_copy;
    int unsigned calls_before;

    for (int wrong = 0; wrong < 2; wrong++) begin
      factory.fail_name = "runtime_status";
      factory.wrong_type = bit'(wrong);
      factory.fired = 1'b0;
      status = values::make_runtime_status(RDMA_SC_RESOURCE_BUSY, "fallback");
      if (!factory.fired || status == null || status.code != RDMA_SC_RESOURCE_BUSY ||
          status.message != "fallback" || status.severity != RDMA_SEVERITY_ERROR)
        `uvm_fatal("RUNTIME_VALUE", "status fallback changed")
      factory.fail_name = "";
    end
    status.hardware_code_valid = 1'b1;
    status.hardware_code = '1;
    status.function_uid = '1;
    status.retryable = 1'b1;
    calls_before = factory.calls;
    if (!values::set_runtime_status_noalloc(status, RDMA_SC_OK, "reset") ||
        !status.ok() || status.hardware_code_valid || status.hardware_code != 0 ||
        status.function_uid != 0 || status.retryable || factory.calls != calls_before ||
        values::set_runtime_status_noalloc(null, RDMA_SC_OK))
      `uvm_error("RUNTIME_VALUE", "noalloc status contract changed")
    status = values::clone_handle_value_nonfatal(null, handle_copy);
    if (!values::status_is_ok(status) || handle_copy != null ||
        !values::handle_value_equal(null, null) || values::status_is_ok(null) ||
        values::factory_create_object_nonfatal(null, "absent") != null)
      `uvm_error("RUNTIME_VALUE", "nullable value contract changed")
    status = values::clone_pending_value(null, copy);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT || copy != null)
      `uvm_error("RUNTIME_VALUE", "null pending accepted")
    source = make_source(1'b0, 229);
    source.device_producer = 1'b1;
    source.image = null;
    status = values::clone_pending_value(source, copy);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT || copy != null)
      `uvm_error("RUNTIME_VALUE", "incomplete device evidence accepted")
    unsupported = new("unsupported");
    status = values::clone_request_value_nonfatal(unsupported, request_copy);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT || request_copy != null)
      `uvm_error("RUNTIME_VALUE", "unsupported semantic request accepted")
    if (!values::handle_value_matches_snapshot(source.queue_h, RDMA_RESOURCE_QP, 9, 229, 7) ||
        values::handle_value_matches_snapshot(source.queue_h, RDMA_RESOURCE_QP, 9, 229, 8) ||
        !values::same_route_epoch_value('0, 0, '0, 0) ||
        values::same_route_epoch_value('0, 0, '0, 1) ||
        !values::cursor_equal(3, 1'b1, 3, 1'b1) || values::cursor_equal(3, 1'b1, 3, 1'b0))
      `uvm_error("RUNTIME_VALUE", "identity/route/cursor comparison changed")
  endfunction

  // 功能：运行独立对象图/故障/边界测试，并在 image factory 窗口嵌套第二次完整 pending clone。
  // 输入/输出及副作用：phase 管理 objection；临时替换全局 factory，完成后恢复 saved_factory。
  // 失败/边界：内外层 source/tag/copy 不得串扰；完成标记不能替代 runner 的 UVM error 检查。
  task run_phase(uvm_phase phase);
    uvm_coreservice_t service;
    uvm_factory saved_factory;
    rdma_runtime_value_factory factory;
    rdma_queue_pending_operation source, copy;
    rdma_status status;

    phase.raise_objection(this);
    service = uvm_coreservice_t::get();
    saved_factory = service.get_factory();
    factory = new();
    service.set_factory(factory);
    check_graph(1'b0);
    check_graph(1'b1);
    check_factory_faults(factory);
    check_boundaries(factory);
    source = make_source(1'b0, 229);
    factory.inner_source = make_source(1'b1, 230);
    factory.reenter = 1'b1;
    status = values::clone_pending_value(source, copy);
    if (!values::status_is_ok(status) || !values::status_is_ok(factory.inner_status) ||
        factory.reenter || copy == factory.inner_copy ||
        !values::pending_immutable_evidence_equal(source, copy) ||
        !values::pending_immutable_evidence_equal(factory.inner_source, factory.inner_copy))
      `uvm_error("RUNTIME_VALUE", "nested factory corrupted automatic locals")
    service.set_factory(saved_factory);
    `uvm_info("RUNTIME_VALUE", "completed runtime projector values and 24 factory faults", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
