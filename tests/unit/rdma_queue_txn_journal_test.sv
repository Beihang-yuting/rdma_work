// 目录：测试层 unit/rdma_queue_txn_journal_test.sv。
// 职责：验证 rdma_queue_txn_journal_test 对应模块的接口、错误路径和边界行为。
// 依赖：依赖被测 package、UVM 测试基类和必要的 mock/fixture。
// 所有权与生命周期：测试对象只拥有本地 fixture；外部后端句柄由测试环境提供并在测试结束释放。

// 中文说明：覆盖 queue transaction evidence 的单调阶段与恢复前置条件。

// 功能：构造一个只用于故障注入的 CQ shadow，模拟可扩展 shadow 实现返回空状态句柄。
// 输入/输出及副作用：name（输入）；构造函数只初始化 UVM 对象，不修改 shadow authority 或 evidence。
// 失败/边界：该对象故意不提供有效校验状态；调用方必须把 validate() 的 null 返回当作失败，不能解引用。
class rdma_null_shadow_validate extends rdma_cq_shadow_snapshot;
  // 功能：创建故障注入用 CQ shadow，并复用基类的确定性零值字段初始化。
  // 输入/输出及副作用：name（输入）；new 只调用基类构造函数，不拥有或修改外部 CQ 资源。
  // 失败/边界：构造成功并不代表 shadow 可用于提交；本类的 validate() 始终返回 null，调用方必须继续做状态句柄检查。
  function new(string name = "rdma_null_shadow_validate");
    super.new(name);
  endfunction

  // 功能：模拟故障注入的 CQ shadow 校验器，返回空 rdma_status 以验证调用方的 fail-closed 处理。
  // 输入/输出及副作用：无显式输入；函数不修改 shadow 字段并返回 null 状态句柄。
  // 失败/边界：null 返回值是本测试刻意制造的异常；任何直接调用 status.ok() 的生产路径都应被该场景捕获。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

// 功能：构造一个只用于故障注入的 semantic request，模拟扩展请求返回空状态句柄。
// 输入/输出及副作用：name（输入）；构造函数只初始化 UVM 对象，不修改 request authority 或 evidence。
// 失败/边界：该对象故意不提供有效校验状态；capture_request 必须返回确定的 INVALID_STATE，而不是解引用空句柄。
class rdma_null_request_validate extends rdma_semantic_request;
  // 功能：创建故障注入用 semantic request，并复用基类默认请求字段。
  // 输入/输出及副作用：name（输入）；new 只调用基类构造函数，不取得请求所有权之外的资源。
  // 失败/边界：构造成功并不代表请求通过校验；本类的 validate() 始终返回 null，调用方必须将其归一化为失败状态。
  function new(string name = "rdma_null_request_validate");
    super.new(name);
  endfunction

  // 功能：模拟故障注入的 semantic request 校验器，返回空 rdma_status 以验证事务快照入口的防御。
  // 输入/输出及副作用：无显式输入；函数不修改 request 字段并返回 null 状态句柄。
  // 失败/边界：null 返回值是本测试刻意制造的异常；调用方不得继续执行 clone 或读取 request 状态。
  virtual function rdma_status validate();
    return null;
  endfunction
endclass

class rdma_queue_txn_journal_test extends uvm_test;
  `uvm_component_utils(rdma_queue_txn_journal_test)
  // 功能：构造 rdma_queue_txn_journal_test，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name、parent（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_txn_journal_test 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_txn_journal_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  // 功能：在 rdma_queue_txn_journal_test 中，run_phase 驱动 UVM 阶段中的场景初始化、事务执行和断言收尾，并在退出前释放 objection 或测试资源。
  // 输入/输出及副作用：phase（输入）；phase 由 UVM 提供；task 通过 objection、日志和断言暴露结果，可能调用 DUT 接口但不改变其所有权规则。
  // 失败/边界：run_phase 的 setup/阶段驱动失败时停止新增事务，并按测试生命周期清理 objection 与临时引用。
  task run_phase(uvm_phase phase);
    rdma_queue_txn_evidence evidence, submitted, evidence_copy;
    rdma_queue_txn_evidence null_shadow_evidence;
    rdma_hw_image image, cqe, cqe_snapshot_image;
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_handle queue_h;
    rdma_semantic_request request;
    rdma_cq_shadow_snapshot null_shadow;
    rdma_semantic_request null_request;
    rdma_status status, source_failure;
    uvm_object cloned;
    phase.raise_objection(this);
    evidence = rdma_queue_txn_evidence::type_id::create("evidence");

    // 空校验状态是可扩展对象边界：必须 fail-closed，不能发布部分
    // URC 证据，也不能解引用空句柄。
    null_shadow_evidence = rdma_queue_txn_evidence::type_id::create(
      "null_shadow_evidence"
    );
    null_shadow_evidence.urc_sq_ci = 17;
    null_shadow_evidence.urc_rq_ci = 19;
    null_shadow_evidence.urc_arm_state = 2'b01;
    null_shadow_evidence.urc_sequence = 64'h55;
    null_shadow = new("null_shadow");
    status = null_shadow_evidence.capture_urc_shadow(null_shadow);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("NULL_SHADOW_STATUS", $sformatf(
        "null shadow validation was not normalized: %s",
        status == null ? "null" : status.convert2string()))
    if (null_shadow_evidence.urc_sq_ci != 17 ||
        null_shadow_evidence.urc_rq_ci != 19 ||
        null_shadow_evidence.urc_arm_state != 2'b01 ||
        null_shadow_evidence.urc_sequence != 64'h55)
      `uvm_error("NULL_SHADOW_MUTATION",
        "null shadow validation published partial URC evidence")

    null_request = new("null_request");
    request = rdma_semantic_request::type_id::create("prior_request");
    request.request_id = 64'hcafe;
    evidence.request_snapshot = request;
    status = evidence.capture_request(null_request);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("NULL_REQUEST_STATUS", $sformatf(
        "null request validation was not normalized: %s",
        status == null ? "null" : status.convert2string()))
    if (evidence.request_snapshot != request)
      `uvm_error("NULL_REQUEST_MUTATION",
        "null request validation replaced the existing snapshot")

    key = '{root_id:16'h1, host_topology_key:32'h10, function_kind:RDMA_FUNCTION_VF,
            parent_pf_bdf:'{segment:0,bus:8'h20,device:5'h1,function_num:0},
            vf_index:16'h2, bdf:'{segment:0,bus:8'h30,device:5'h4,function_num:1}};
    identity = rdma_function_identity::type_id::create("identity");
    status = identity.configure(key, 0, 64'h1234, 1, 1);
    if (!status.ok() || !evidence.capture_function_identity(identity).ok())
      `uvm_error("TXN", "identity evidence capture failed")
    queue_h = rdma_handle::type_id::create("queue_h");
    queue_h.kind = RDMA_RESOURCE_QP;
    queue_h.function_uid = 64'h1234;
    queue_h.object_id = 32'h55;
    queue_h.generation = 1;
    request = rdma_semantic_request::type_id::create("request");
    request.request_id = 64'ha5;
    cqe = rdma_hw_image::type_id::create("cqe");
    cqe.image_kind = RDMA_IMAGE_CQE;
    source_failure = rdma_status::make(RDMA_SC_TIMEOUT, "timeout captured");
    source_failure.command_id = 64'h77;
    if (!evidence.capture_queue_h(queue_h).ok() ||
        !evidence.capture_request_snapshot(request).ok() ||
        !evidence.capture_cqe_snapshot(cqe).ok() ||
        !evidence.set_failure_status(source_failure).ok())
      `uvm_error("TXN", "transaction evidence capture API failed")
    cloned = evidence.clone();
    if (cloned == null || !$cast(evidence_copy, cloned))
      `uvm_error("TXN", "transaction evidence clone failed")
    else begin
      queue_h.object_id = 32'haa;
      request.request_id = 64'hbb;
      cqe.image_kind = RDMA_IMAGE_SQE;
      source_failure.command_id = 64'hcc;
      if (!$cast(cqe_snapshot_image, evidence.cqe_snapshot))
        `uvm_error("TXN", "CQE snapshot type was not preserved")
      if (evidence.queue_h.object_id != 32'h55 ||
          evidence.request_snapshot.request_id != 64'ha5 ||
          cqe_snapshot_image == null || cqe_snapshot_image.image_kind != RDMA_IMAGE_CQE ||
          evidence.failure_status.command_id != 64'h77 ||
          evidence_copy.queue_h == evidence.queue_h ||
          evidence_copy.failure_status == evidence.failure_status)
        `uvm_error("TXN", "transaction snapshots are not isolated")
    end
    status = evidence.advance(RDMA_QUEUE_TXN_RESERVED);
    if (!status.ok() || evidence.phase != RDMA_QUEUE_TXN_RESERVED)
      `uvm_error("TXN", "reserve phase failed")
    status = evidence.advance(RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "illegal phase skip accepted")
    status = evidence.advance(RDMA_QUEUE_TXN_NONE);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "illegal phase rollback accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b0);
    if (status.ok() || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("TXN", "retry without no-submit confirmation accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b1);
    if (!status.ok()) `uvm_error("TXN", $sformatf("known no-submit retry rejected: %s", status.convert2string()))
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (!status.ok()) `uvm_error("TXN", "payload phase failed")
    status = evidence.mark_mmio_maybe_submitted();
    if (!status.ok()) `uvm_error("TXN", "MMIO transition failed")
    status = evidence.recover(RDMA_MODEL_RECOVERY_RETRY_NO_SUBMIT, 1'b1);
    if (status.ok() || status.code != RDMA_SC_RECOVERY_REQUIRED)
      `uvm_error("TXN", "ambiguous MMIO retry accepted")
    status = evidence.recover(RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED, 1'b0);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "missing image finalize accepted")

    submitted = rdma_queue_txn_evidence::type_id::create("submitted");
    image = rdma_hw_image::type_id::create("image");
    image.image_kind = RDMA_IMAGE_SQE;
    status = submitted.capture_image(image);
    if (!status.ok()) `uvm_error("TXN", "image snapshot capture failed")
    submitted.advance(RDMA_QUEUE_TXN_RESERVED);
    submitted.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    submitted.mark_mmio_maybe_submitted();
    status = submitted.recover(RDMA_MODEL_RECOVERY_FINALIZE_SUBMITTED, 1'b0);
    if (!status.ok()) `uvm_error("TXN", "submitted image finalize rejected")
    if (!submitted.mmio_maybe_submitted || submitted.image == null ||
        submitted.phase != RDMA_QUEUE_TXN_DOORBELL_MAYBE_SUBMITTED)
      `uvm_error("TXN", "finalize recovery lost submitted evidence")
    submitted.advance(RDMA_QUEUE_TXN_CONSUMER_COMMITTED);

    // Release plans are idempotent and completion is only legal after release.
    status = submitted.mark_wqe_release(3, 1'b0);
    if (!status.ok() || submitted.release_plan.size() != 1 ||
        !submitted.release_plan[0].released)
      `uvm_error("TXN", "initial WQE release plan missing")
    status = submitted.mark_wqe_release(3, 1'b0);
    if (!status.ok() || submitted.release_plan.size() != 1 ||
        !submitted.release_plan[0].released)
      `uvm_error("TXN", "duplicate WQE release was not idempotent")
    status = submitted.mark_wqe_release(4, 1'b1);
    if (!status.ok() || submitted.release_plan.size() != 2 ||
        !submitted.release_plan[1].released ||
        submitted.release_plan[1].index != 4 ||
        !submitted.release_plan[1].wrap)
      `uvm_error("TXN", "distinct partial WQE release was not recorded")
    status = submitted.complete();
    if (!status.ok() || submitted.phase != RDMA_QUEUE_TXN_COMPLETED)
      `uvm_error("TXN", "transaction completion rejected after release")
    status = submitted.advance(RDMA_QUEUE_TXN_RESERVED);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "advance accepted after terminal completion")

    // Direct phase writes do not bypass complete() transition validation.
    submitted.phase = RDMA_QUEUE_TXN_RESERVED;
    status = submitted.complete();
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "completion bypassed transition validation")

    status = evidence.recover(RDMA_MODEL_RECOVERY_ABORT_AND_DETACH);
    if (!status.ok() || !evidence.aborted)
      `uvm_error("TXN", "abort-and-detach recovery failed")
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "aborted transaction advanced")
    phase.drop_objection(this);
  endtask
endclass
