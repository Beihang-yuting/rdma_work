// 目录/层次：tests/unit；职责：验证 SQ/RQ/SRQ 公共提交尾段的七类失败续接和成功旁路。
// 依赖：真实 lifecycle fixture、poll 测试的 shared-SRQ 建拆 helper、codec、runtime 与 mock I/O。
// 所有权/生命周期：每例独立 fixture/factory；probe 只借用 attachment，公开恢复后逆序释放资源。

typedef enum int {
  HOST_TAIL_OK, HOST_TAIL_GATE, HOST_TAIL_GATE_NULL, HOST_TAIL_WRITE, HOST_TAIL_READ,
  HOST_TAIL_RESULT_NULL, HOST_TAIL_RESULT_TYPE, HOST_TAIL_HANDLE,
  HOST_TAIL_NEXT_NULL, HOST_TAIL_NEXT_TYPE, HOST_TAIL_NEXT_STATUS,
  HOST_TAIL_DOORBELL, HOST_TAIL_COMMIT, HOST_TAIL_COMMIT_NULL
} rdma_host_tail_fault_e;

// 只替换调用者的 detached handle；第一次 result clone 可失败，后续 pending clone 恢复正常。
class rdma_host_tail_handle extends rdma_handle;
  bit fail_once;
  bit fired;

  // 功能：构造默认正常的测试句柄；identity 由 case 从真实 queue handle 复制。
  // 输入/输出及副作用：name 透传；不注册 factory、不取得队列或 mapping 所有权。
  // 失败/边界：未填 identity 前不能传入事务，fail_once 只作用于一次 clone。
  function new(string name = "host_tail_handle");
    super.new(name);
    fail_once = 1'b0;
    fired = 1'b0;
  endfunction

  // 功能：按需拒绝一次 result queue clone，其余调用返回完整的普通 rdma_handle 快照。
  // 输入/输出及副作用：无参数；消耗 fail_once 并记录 fired，成功按四个 identity 字段复制。
  // 失败/边界：故障返回 null，不修改源 identity；返回普通基类避免把测试故障传播到 runtime。
  virtual function uvm_object clone();
    rdma_handle copy;

    if (fail_once) begin
      fail_once = 1'b0;
      fired = 1'b1;
      return null;
    end
    copy = new("host_tail_handle_copy");
    copy.kind = kind;
    copy.function_uid = function_uid;
    copy.object_id = object_id;
    copy.generation = generation;
    return copy;
  endfunction
endclass

// 精确名称控制 result/next/legacy pending 的创建，绝不向 rdma_status::make 返回 null。
class rdma_host_tail_factory extends uvm_default_factory;
  rdma_host_tail_fault_e fault;
  bit armed;
  bit fired;
  bit fail_pending;
  bit next_created;
  int unsigned pending_creates;

  // 功能：构造尚未 armed 的 factory，默认正常创建对象且不拒绝 pending。
  // 输入/输出及副作用：无参数；不安装全局 factory，不拥有任何 fixture 资源。
  // 失败/边界：调用者必须在 setup/编码完成后才 armed，case 完成后恢复原 factory。
  function new();
    super.new();
    fault = HOST_TAIL_OK;
    armed = 1'b0;
    fired = 1'b0;
    fail_pending = 1'b0;
    next_created = 1'b0;
    pending_creates = 0;
  endfunction

  // 功能：在尾段窗口注入 result/next 空或错型、next 的 nonfatal status 空和 pending 空。
  // 输入/输出及副作用：requested_type/parent_inst_path/name 默认透传；计数 queue_pending
  //   创建次数；next status 仅匹配 queue_data_engine_status，不影响普通 status::make。
  // 失败/边界：每个主故障只触发一次，pending 拒绝可独立叠加；未 armed 不改变 factory 行为。
  virtual function uvm_object create_object_by_type(
    uvm_object_wrapper requested_type, string parent_inst_path = "", string name = ""
  );
    rdma_hw_image wrong;

    if (armed && name == "queue_pending") begin
      pending_creates++;
      if (fail_pending)
        return null;
    end
    if (armed && !fired) begin
      if ((name == "tail_result" && fault inside {HOST_TAIL_RESULT_NULL, HOST_TAIL_RESULT_TYPE}) ||
          (name == "tail_next_cursor" &&
           fault inside {HOST_TAIL_NEXT_NULL, HOST_TAIL_NEXT_TYPE})) begin
        fired = 1'b1;
        if (fault inside {HOST_TAIL_RESULT_TYPE, HOST_TAIL_NEXT_TYPE}) begin
          wrong = new("wrong_tail_type");
          return wrong;
        end
        return null;
      end
      if (fault == HOST_TAIL_NEXT_STATUS && next_created &&
          name == "queue_data_engine_status") begin
        fired = 1'b1;
        return null;
      end
    end
    if (armed && name == "tail_next_cursor") next_created = 1'b1;
    return super.create_object_by_type(requested_type, parent_inst_path, name);
  endfunction
endclass

// gate/commit/admission 只在既有 virtual seam 注入，prepare、I/O、pending 与 runtime 均走生产实现。
class rdma_host_tail_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_host_tail_probe)
  rdma_host_tail_factory injector;
  rdma_status stage_failure;
  rdma_status admission_failure;
  int unsigned admission_mode;
  int unsigned admission_calls;
  int unsigned commit_calls;
  rdma_route_key_t frozen_route;
  rdma_reset_epoch_t frozen_epoch;

  // 功能：构造默认正常的 host tail probe，清空本例的提交和接管计数。
  // 输入/输出及副作用：name 透传；injector/status 是 case 借用引用，不拥有外部资源。
  // 失败/边界：fixture.setup 与 injector 配置完成前不能调用 attempt。
  function new(string name = "rdma_host_tail_probe");
    super.new(name);
    admission_mode = 0;
    admission_calls = 0;
    commit_calls = 0;
  endfunction

  // 功能：为真实 SQ/RQ/SRQ reserve 并编码 WQE；prior_write 用三 SGE 进入外置 SGB
  //   模式并实际写入/回读 SQ SGB，再调用公共尾段。
  // 输入/输出及副作用：fixture、queue_h/kind/completion_qp/local_id/prior_write 输入，
  //   result/status 输出；冻结 route/epoch，借用真实 attachment，factory 仅在 tail 内 armed。
  // 失败/边界：setup/reserve/model/encode/SGB 不完整 fatal；prior_write 只允许 SQ；
  //   不绕过 tail 的 gate/I/O/commit，不以该机制入口替代公开 post_send/post_recv 的 admission 测试。
  task attempt(
    rdma_queue_data_engine_fixture fixture, rdma_host_tail_handle queue_h,
    rdma_queue_runtime_kind_e kind, rdma_handle completion_qp, int unsigned local_id,
    bit prior_write, output rdma_queue_post_result result, output rdma_status status
  );
    rdma_queue_data_attachment attachment;
    rdma_queue_data_qp_link link;
    rdma_queue_cursor_snapshot cursor;
    rdma_post_send_req send_request;
    rdma_post_recv_req recv_request;
    rdma_semantic_request snapshot;
    rdma_hw_sqe_model sqe;
    rdma_hw_rqe_model rqe;
    rdma_hw_image image;
    rdma_sge sge;
    bit route_valid;
    bit epoch_valid;

    status = lookup_attachment(queue_h, kind, attachment);
    if (status == null || !status.ok() || attachment == null ||
        !qp_links.exists(value_ops::identity_key(completion_qp)))
      `uvm_fatal("HOST_TAIL", "attachment/link missing")
    link = qp_links[value_ops::identity_key(completion_qp)];
    status = reserve_host_producer_cursor(attachment, cursor, frozen_route, frozen_epoch,
                                           route_valid, epoch_valid);
    if (status == null || !status.ok() || cursor == null || !route_valid || !epoch_valid)
      `uvm_fatal("HOST_TAIL", "reservation failed")
    if (kind == RDMA_QUEUE_RUNTIME_SQ) begin
      send_request = fixture.make_send(64'h228);
      if (prior_write) begin
        // 单 SGE 存在 SQE 内，不能只填 sgb_iova 就声称已发生外置写入。
        send_request.sges.delete();
        for (int unsigned i = 0; i < 3; i++) begin
          sge = new($sformatf("tail_sgb_sge%0d", i));
          sge.iova.value = 64'h0000_1000_0000_1000 + i * 64;
          sge.length = 8;
          sge.lkey = 32'ha0a0_a000 + i;
          send_request.sges.push_back(sge);
        end
        send_request.sgb_iova.value = fixture.qp.qp_plan.sq_sgb_ref.mapping.iova.value +
                                     fixture.qp.qp_plan.sq_sgb_ref.mapping_offset;
      end
      snapshot = send_request;
      status = make_sqe(send_request, link, cursor, sqe);
      if (status == null || !status.ok() || sqe == null)
        `uvm_fatal("HOST_TAIL", "SQE preparation failed")
      status = encode_queue_model(sqe, RDMA_IMAGE_SQE, "sqe", "rc", image);
    end
    else begin
      if (prior_write)
        `uvm_fatal("HOST_TAIL", "SGB is SQ-only")
      recv_request = fixture.make_recv(64'h228);
      recv_request.target_h = queue_h;
      recv_request.completion_qp_h = completion_qp;
      snapshot = recv_request;
      status = make_rqe(recv_request, link, cursor, rqe);
      if (status == null || !status.ok() || rqe == null)
        `uvm_fatal("HOST_TAIL", "RQE preparation failed")
      status = encode_queue_model(rqe, RDMA_IMAGE_RQE, "rqe", "default", image);
    end
    if (status == null || !status.ok() || image == null)
      `uvm_fatal("HOST_TAIL", "WQE encode failed")
    if (prior_write) begin
      status = write_sgb_and_verify(link, sqe, cursor, image);
      if (status == null || !status.ok())
        `uvm_fatal("HOST_TAIL", status == null ? "prior SGB write returned null" :
                   {"prior SGB write failed: ", status.convert2string()})
    end
    queue_h.fail_once = injector.fault == HOST_TAIL_HANDLE;
    injector.armed = 1'b1;
    complete_host_producer_tail(
      attachment, queue_h, kind, cursor, longint'(cursor.index) * 64, image,
      snapshot, 64'h228, 1'b1, kind == RDMA_QUEUE_RUNTIME_SQ ? image : null, local_id,
      "tail_next", "tail write", "tail doorbell", "tail commit", "tail_result",
      "tail result queue", result, status, frozen_route, frozen_epoch, route_valid,
      epoch_valid, prior_write);
    injector.armed = 1'b0;
  endtask

  // 功能：在 tail 的入口 gate 注入原错误或 null，核对 prior_host_write 对恢复权限的影响。
  // 输入/输出及副作用：attachment/cursor 透传；未命中时执行真实 route/epoch 校验。
  // 失败/边界：故障不修改 binding/runtime，不触碰 I/O；返回 null 由 caller 归一化。
  protected virtual function rdma_status validate_host_producer_reservation_window(
    rdma_queue_data_attachment attachment, rdma_queue_cursor_snapshot cursor
  );
    if (injector.fault == HOST_TAIL_GATE)
      return stage_failure;
    if (injector.fault == HOST_TAIL_GATE_NULL)
      return null;
    return super.validate_host_producer_reservation_window(attachment, cursor);
  endfunction

  // 功能：计数 ledger commit 调用，按 case 返回一次指定错误/null，或提交真实 runtime。
  // 输入/输出及副作用：attachment/cursor/request/wr_id/signaled/image 原样透传；失败不推进 PI。
  // 失败/边界：恢复前 case 会关闭主故障；不把“已提交再失败”伪造成此处的提交拒绝。
  protected virtual function rdma_status commit_host_producer_ledger(
    rdma_queue_data_attachment attachment, rdma_queue_cursor_snapshot cursor,
    rdma_semantic_request request, longint unsigned wr_id, bit signaled, rdma_hw_image image
  );
    commit_calls++;
    if (injector.fault == HOST_TAIL_COMMIT)
      return stage_failure;
    if (injector.fault == HOST_TAIL_COMMIT_NULL)
      return null;
    return super.commit_host_producer_ledger(attachment, cursor, request, wr_id, signaled, image);
  endfunction

  // 功能：计数并注入 legacy host recovery admission 的 null/错误，正常模式调用真实接管。
  // 输入/输出及副作用：attachment/pending/mmio_maybe_submitted 透传；只读 pending，
  //   admission_mode=0 才允许 runtime 安装 evidence，1 返回 null，2 返回 admission_failure。
  // 失败/边界：拒绝时不伪造 pending 保留；本测试锁定现有返回语义，不扩展 host unclaimed 能力。
  protected virtual function rdma_status admit_host_producer_recovery(
    rdma_queue_data_attachment attachment, rdma_queue_pending_operation pending,
    bit mmio_maybe_submitted
  );
    admission_calls++;
    if (admission_mode == 1)
      return null;
    if (admission_mode == 2)
      return admission_failure;
    return super.admit_host_producer_recovery(attachment, pending, mmio_maybe_submitted);
  endfunction
endclass

// 复用 poll 测试的 SRQ 生命周期 helper，覆盖真实 shared queue；run_phase 只执行本矩阵。
class rdma_host_producer_exit_test extends rdma_queue_data_engine_poll_test;
  `uvm_component_utils(rdma_host_producer_exit_test)

  // 功能：构造 host tail 矩阵组件，不执行继承类的 poll 场景。
  // 输入/输出及副作用：name/parent 透传；资源由 run_case 建立并回收。
  // 失败/边界：构造不创建 fixture，不替换全局 factory。
  function new(string name = "rdma_host_producer_exit_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：验证真实 posting ring 的阶段错误、单次恢复、PI/credit、I/O 前缀与公开 retry/abort。
  // 输入/输出及副作用：kind/fault 选择主场景，prior_write 选择实际 SQ SGB，fail_pending
  //   叠加 evidence 分配失败，admission_mode 选择接管结果；最终按 QP→SRQ→fixture 逆序清理。
  // 失败/边界：setup/关键证据/teardown 缺失 fatal；其它不符 error；pending 未接管时只验证
  //   原始拒绝与可清理性；AMBIGUOUS 即使确认也拒绝 retry，只能 abort，不声称已回滚写入。
  task run_case(
    rdma_queue_runtime_kind_e kind, rdma_host_tail_fault_e fault,
    bit prior_write = 1'b0, bit fail_pending = 1'b0, int unsigned admission_mode = 0
  );
    uvm_coreservice_t service;
    uvm_factory saved_factory;
    rdma_host_tail_factory factory;
    rdma_host_tail_probe probe;
    rdma_queue_data_engine_fixture fixture;
    rdma_host_tail_handle queue_h;
    rdma_handle source_h;
    rdma_handle completion_qp;
    rdma_srq srq;
    rdma_qp srq_qp;
    rdma_status status;
    rdma_queue_post_result result;
    rdma_queue_pending_operation pending;
    rdma_status_code_e expected_code;
    bit srq_created, srq_qp_created, srq_qp_attached, srq_attached;
    bit recovery, claimed, ambiguous, has_pending;
    bit pi_wrap, ci_wrap;
    int unsigned pi, ci, used, local_id, mem_before, pcie_before, mem_delta, pcie_delta;
    string failure_label;

    service = uvm_coreservice_t::get();
    saved_factory = service.get_factory();
    factory = new();
    factory.set_type_override_by_type(
      rdma_queue_data_engine::get_type(), rdma_host_tail_probe::get_type());
    service.set_factory(factory);
    fixture = new("host_tail_fixture");
    fixture.setup(status);
    if (status == null || !status.ok() || !$cast(probe, fixture.engine))
      `uvm_fatal("HOST_TAIL", "fixture setup failed")
    source_h = fixture.qp.handle;
    completion_qp = source_h;
    local_id = fixture.qp.local_qp_id;
    if (kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      create_shared_srq_poll_route("host_tail", fixture, fixture.cq, srq, srq_qp,
        srq_created, srq_qp_created, srq_qp_attached, srq_attached, status);
      if (status == null || !status.ok() || !srq_created || !srq_qp_created ||
          !srq_qp_attached || !srq_attached)
        `uvm_fatal("HOST_TAIL", "shared SRQ route setup failed")
      source_h = srq.handle;
      completion_qp = srq_qp.handle;
      local_id = srq.local_srq_id;
    end
    queue_h = new();
    queue_h.kind = source_h.kind;
    queue_h.function_uid = source_h.function_uid;
    queue_h.object_id = source_h.object_id;
    queue_h.generation = source_h.generation;
    recovery = fault != HOST_TAIL_OK &&
               (!(fault inside {HOST_TAIL_GATE, HOST_TAIL_GATE_NULL}) || prior_write);
    claimed = recovery && !fail_pending && admission_mode == 0;
    ambiguous = fault inside {HOST_TAIL_DOORBELL, HOST_TAIL_COMMIT, HOST_TAIL_COMMIT_NULL};
    expected_code = RDMA_SC_RESOURCE_EXHAUSTED;
    failure_label = "tail_result";
    case (fault)
      HOST_TAIL_OK: expected_code = RDMA_SC_OK;
      HOST_TAIL_GATE: begin
        expected_code = RDMA_SC_STALE_GENERATION;
        failure_label = "tail write";
      end
      HOST_TAIL_GATE_NULL: begin
        expected_code = RDMA_SC_INVALID_STATE;
        failure_label = "tail write";
      end
      HOST_TAIL_WRITE, HOST_TAIL_READ: begin
        expected_code = RDMA_SC_DMA_TRANSLATION;
        failure_label = "tail write";
      end
      HOST_TAIL_NEXT_NULL, HOST_TAIL_NEXT_TYPE, HOST_TAIL_NEXT_STATUS: failure_label = "tail_next";
      HOST_TAIL_DOORBELL: begin
        expected_code = RDMA_SC_PCIE_COMPLETION;
        failure_label = "tail doorbell";
      end
      HOST_TAIL_COMMIT, HOST_TAIL_COMMIT_NULL: begin
        if (fault == HOST_TAIL_COMMIT)
          expected_code = RDMA_SC_RESOURCE_BUSY;
        else
          expected_code = RDMA_SC_INVALID_STATE;
        failure_label = "tail commit";
      end
      default: begin end
    endcase
    probe.injector = factory;
    probe.stage_failure = rdma_status::make_direct(expected_code, "injected host tail stage");
    probe.admission_failure = rdma_status::make_direct(
      RDMA_SC_RESOURCE_BUSY, "injected host admission");
    probe.admission_mode = admission_mode;
    factory.fault = fault;
    factory.fail_pending = fail_pending;
    if (fault inside {HOST_TAIL_WRITE, HOST_TAIL_READ}) begin
      status = fixture.mem.fail_next(
        fault == HOST_TAIL_WRITE ? "write" : "read", probe.stage_failure);
      if (status == null || !status.ok())
        `uvm_fatal("HOST_TAIL", "memory fault arm failed")
    end
    if (fault == HOST_TAIL_DOORBELL) begin
      status = fixture.pcie.fail_next("mmio_write", probe.stage_failure);
      if (status == null || !status.ok())
        `uvm_fatal("HOST_TAIL", "doorbell fault arm failed")
    end
    mem_before = fixture.mem.calls.size();
    pcie_before = fixture.pcie.calls.size();
    probe.attempt(fixture, queue_h, kind, completion_qp, local_id, prior_write, result, status);
    service.set_factory(saved_factory);
    if (fail_pending) expected_code = RDMA_SC_RESOURCE_EXHAUSTED;
    if (admission_mode == 1) expected_code = RDMA_SC_RECOVERY_REQUIRED;
    if (admission_mode == 2) expected_code = RDMA_SC_RESOURCE_BUSY;
    if (status == null || status.code != expected_code ||
        (result != null) != (fault == HOST_TAIL_OK) ||
        (fail_pending && status.message != {failure_label, " recovery evidence clone failed"}) ||
        (admission_mode == 2 && status != probe.admission_failure))
      `uvm_error("HOST_TAIL", $sformatf("kind=%0d fault=%s pending_fail=%0b admission=%0d",
                                      kind, fault.name(), fail_pending, admission_mode))
    if (factory.pending_creates != (recovery ? 1 : 0) ||
        probe.admission_calls != (recovery && !fail_pending ? 1 : 0) ||
        probe.commit_calls !=
          (fault inside {HOST_TAIL_OK, HOST_TAIL_COMMIT, HOST_TAIL_COMMIT_NULL} ? 1 : 0) ||
        (fault == HOST_TAIL_HANDLE && !queue_h.fired) ||
        (fault inside {HOST_TAIL_RESULT_NULL, HOST_TAIL_RESULT_TYPE, HOST_TAIL_NEXT_NULL,
                       HOST_TAIL_NEXT_TYPE, HOST_TAIL_NEXT_STATUS} && !factory.fired))
      `uvm_error("HOST_TAIL", "failure seam skipped or repeated")
    mem_delta = fault inside {HOST_TAIL_GATE, HOST_TAIL_GATE_NULL} ? 0 :
                (fault == HOST_TAIL_WRITE ? 1 : 2);
    if (prior_write) mem_delta += 2;
    pcie_delta = fault inside {HOST_TAIL_OK, HOST_TAIL_DOORBELL,
                              HOST_TAIL_COMMIT, HOST_TAIL_COMMIT_NULL} ? 3 : 0;
    if (fixture.mem.calls.size() != mem_before + mem_delta ||
        fixture.pcie.calls.size() != pcie_before + pcie_delta ||
        (mem_delta > 0 && fixture.mem.calls[mem_before].method_name != "write") ||
        (mem_delta > 1 && fixture.mem.calls[mem_before + 1].method_name != "read") ||
        (pcie_delta > 0 &&
         (fixture.pcie.calls[pcie_before].method_name != "dma_visibility_barrier" ||
          fixture.pcie.calls[pcie_before + 1].method_name != "mmio_ordering_barrier" ||
          fixture.pcie.calls[pcie_before + 2].method_name != "mmio_write")))
      `uvm_error("HOST_TAIL", "I/O count/order changed")
    if (prior_write && fixture.mem.calls[mem_before].data.size() != 512)
      `uvm_error("HOST_TAIL", "prior write did not target a complete SGB slot")
    status = probe.query_runtime_cursors(queue_h, kind, pi, pi_wrap, ci, ci_wrap);
    if (status == null || !status.ok() || pi != (fault == HOST_TAIL_OK ? 1 : 0) ||
        pi_wrap || ci != 0 || ci_wrap)
      `uvm_error("HOST_TAIL", "failed stage moved cursor")
    status = probe.query_runtime_occupancy(queue_h, kind, used, has_pending);
    if (status == null || !status.ok() || used != (fault == HOST_TAIL_OK ? 1 : 0) ||
        has_pending != claimed)
      `uvm_error("HOST_TAIL", "credit/pending changed")
    if (claimed) begin
      status = probe.query_runtime_pending(queue_h, kind, pending);
      if (status == null || !status.ok() || pending == null || pending.cursor == null ||
          pending.next_cursor == null || pending.image == null ||
          pending.request_snapshot == null || pending.queue_h == null)
        `uvm_fatal("HOST_TAIL", "recovery evidence unavailable")
      if (!pending.producer || pending.device_producer || pending.kind != kind ||
          !pending.queue_h.same_instance(queue_h) ||
          pending.cursor.index != 0 || pending.next_cursor.index != 1 ||
          !pending.route_valid || !pending.epoch_valid || pending.route != probe.frozen_route ||
          pending.reset_epoch != probe.frozen_epoch || pending.wr_id != 64'h228 ||
          pending.mmio_evidence !=
            (ambiguous ? RDMA_QUEUE_MMIO_AMBIGUOUS : RDMA_QUEUE_MMIO_NO_SUBMIT))
        `uvm_error("HOST_TAIL", "pending authority/stage changed")
      factory.fault = HOST_TAIL_OK;
      if (ambiguous) begin
        mem_before = fixture.mem.calls.size();
        pcie_before = fixture.pcie.calls.size();
        probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0, status);
        if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT ||
            fixture.mem.calls.size() != mem_before || fixture.pcie.calls.size() != pcie_before)
          `uvm_error("HOST_TAIL", "ambiguous retry bypassed caller confirmation")
        probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
        if (status == null || status.code != RDMA_SC_RECOVERY_REQUIRED ||
            fixture.mem.calls.size() != mem_before || fixture.pcie.calls.size() != pcie_before)
          `uvm_error("HOST_TAIL", "confirmed ambiguous retry repeated I/O")
        probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH, 1'b0, status);
        if (status == null || !status.ok())
          `uvm_fatal("HOST_TAIL", "ambiguous abort failed")
        if (kind == RDMA_QUEUE_RUNTIME_SRQ)
          srq_attached = 1'b0;
        else
          fixture.qp_attached = 1'b0;
      end
      else begin
        probe.recover_queue(queue_h, RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b1, status);
        if (status == null || !status.ok())
          `uvm_fatal("HOST_TAIL", "confirmed retry failed")
        status = probe.query_runtime_occupancy(queue_h, kind, used, has_pending);
        if (status == null || !status.ok() || used != 1 || has_pending)
          `uvm_error("HOST_TAIL", "retry failed to commit exactly one slot")
      end
    end
    if (kind == RDMA_QUEUE_RUNTIME_SRQ) begin
      fixture.destroy_lifecycle_owned_qp(
        srq_qp.handle, srq_qp_created, srq_qp_attached, 64'h2281, status);
      if (status == null || !status.ok())
        `uvm_fatal("HOST_TAIL", "SRQ QP cleanup failed")
      destroy_shared_srq_poll_route(
        fixture, srq.handle, srq_created, srq_attached, 64'h2282, status);
      if (status == null || !status.ok())
        `uvm_fatal("HOST_TAIL", "SRQ cleanup failed")
    end
    fixture.cleanup(status);
    if (status == null || !status.ok() || fixture.mem.live_allocations() != 0)
      `uvm_error("HOST_TAIL", "fixture cleanup leaked resources")
  endtask

  // 功能：执行三队列 × 十四种退出、两个真实 SGB gate、七类 pending 构造失败及两类接管拒绝。
  // 输入/输出及副作用：phase 管理 objection，共 53 cases；每例恢复 factory 并回收独立 fixture。
  // 失败/边界：SGB 只在 SQ 测试；完成标记不能替代 runner 对 UVM_ERROR/FATAL 的检查。
  task run_phase(uvm_phase phase);
    rdma_queue_runtime_kind_e kinds[3] = '{
      RDMA_QUEUE_RUNTIME_SQ, RDMA_QUEUE_RUNTIME_RQ, RDMA_QUEUE_RUNTIME_SRQ};
    rdma_host_tail_fault_e label_faults[7] = '{
      HOST_TAIL_GATE, HOST_TAIL_WRITE, HOST_TAIL_RESULT_NULL,
      HOST_TAIL_HANDLE, HOST_TAIL_NEXT_NULL, HOST_TAIL_DOORBELL, HOST_TAIL_COMMIT};
    rdma_host_tail_fault_e fault;

    phase.raise_objection(this);
    foreach (kinds[i]) begin
      fault = fault.first();
      do begin
        run_case(kinds[i], fault);
        fault = fault.next();
      end while (fault != fault.first());
    end
    run_case(RDMA_QUEUE_RUNTIME_SQ, HOST_TAIL_GATE, 1'b1);
    run_case(RDMA_QUEUE_RUNTIME_SQ, HOST_TAIL_GATE_NULL, 1'b1);
    foreach (label_faults[i])
      run_case(RDMA_QUEUE_RUNTIME_SQ, label_faults[i], label_faults[i] == HOST_TAIL_GATE, 1'b1);
    run_case(RDMA_QUEUE_RUNTIME_SQ, HOST_TAIL_COMMIT, 1'b0, 1'b0, 1);
    run_case(RDMA_QUEUE_RUNTIME_SQ, HOST_TAIL_COMMIT, 1'b0, 1'b0, 2);
    `uvm_info("HOST_TAIL", "completed 53 host producer exit cases", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass
