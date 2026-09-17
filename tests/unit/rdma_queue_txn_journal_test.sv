// 目录：测试层 unit/rdma_queue_txn_journal_test.sv。
// 职责：验证 queue transaction evidence 的快照隔离、阶段转换、恢复、release-plan 和终态拒绝。
// 依赖：依赖 rdma_queue_txn_evidence、context/request/image 模型及 UVM test 基类。
// 所有权与生命周期：run_phase 创建并拥有所有 evidence 与输入对象；capture API 只保存独立快照，UVM 在 phase 结束回收本地对象。

// 设计说明：本测试把 fail-closed 的 null-status 原子性与后续正常事务分开断言，避免故障注入污染合法阶段/恢复路径。

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
  // 功能：构造 rdma_queue_txn_journal_test 的 UVM 组件节点，供 run_phase 建立独立 transaction evidence 场景。
  // 输入/输出及副作用：name、parent（输入）；仅传给 super.new 建立层级，不创建 request、image、handle 或外部后端资源。
  // 失败/边界：parent 可为 null；构造完成不代表事务已配置或激活，本测试没有 configure/build/activate 阶段，所有业务对象只在 run_phase 本地持有。
  function new(string name = "rdma_queue_txn_journal_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction
  // 功能：执行 null-status、快照隔离、合法/非法阶段推进、恢复、release-plan、complete 与 abort 的 transaction-evidence 场景。
  // 输入/输出及副作用：phase（输入）；raise/drop objection 包围全部断言；task 创建并修改本地 evidence、request、image、handle，失败通过 UVM error 发布。
  // 失败/边界：任一检查失配后 task 仍继续执行其余独立场景以聚合错误；不具备 configure/build/activate 或 stop-on-failure gate，末尾负责 drop objection。
  task run_phase(uvm_phase phase);
    rdma_queue_txn_evidence evidence, submitted, evidence_copy;
    rdma_queue_txn_evidence null_shadow_evidence;
    rdma_hw_image image, cqe, cqe_snapshot_image;
    rdma_function_identity identity;
    rdma_function_key_t key;
    rdma_handle queue_h;
    rdma_semantic_request request;
    rdma_null_shadow_validate null_shadow;
    rdma_null_request_validate null_request;
    rdma_status status, source_failure;
    uvm_object cloned;
    phase.raise_objection(this);
    evidence = rdma_queue_txn_evidence::type_id::create("evidence");

    // 设计：capture_urc_shadow 在 virtual validate 返回 null 时必须归一化为
    // INVALID_STATE；失败前写入的四个 URC 字段必须保持原值，不能发布部分 shadow。
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

    // 设计：capture_request 的 null-status 拒绝是原子的。已有 request_snapshot 必须保留
    // 原句柄，不能因为失败的 clone/assignment 被替换为故障注入 request。
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

    // 设计：成功 capture 后各输入再被原地改写；evidence 和 clone 都必须保有 detached
    // snapshot，既不随 source 改变，也不得与彼此共享 queue_h/failure_status 句柄。
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
    // 设计：NONE 只能合法前进到 RESERVED；跳过 PAYLOAD_WRITTEN 到 MAYBE_SUBMITTED、
    // 从 RESERVED 回滚到 NONE 都必须返回 INVALID_STATE。已知 no-submit 才允许 retry。
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
    // 设计：进入 PAYLOAD_WRITTEN 后 MMIO 是否提交已变得歧义；即使调用方声称 no-submit，
    // RETRY_NO_SUBMIT 也必须拒绝。FINALIZE_SUBMITTED 则要求已经捕获 image。
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

    // 设计：独立的 submitted evidence 先捕获 SQE image，再走到 MAYBE_SUBMITTED；
    // 因而 FINALIZE_SUBMITTED 可保留 image 和 MMIO 标志，而不是把不完整事务误判完成。
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

    // 设计：同一 index/wrap 的 release 必须幂等而不增加计划；不同 index/wrap 必须形成
    // 独立条目。只有 CONSUMER_COMMITTED 且 release-plan 已记录后 complete 才能进入终态。
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

    // 设计：直接写 phase 是故障注入，不能绕过 complete() 的真实转换前置条件；
    // COMPLETED 同样是终态，之后 advance 必须返回 INVALID_STATE。
    submitted.phase = RDMA_QUEUE_TXN_RESERVED;
    status = submitted.complete();
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "completion bypassed transition validation")

    // 设计：ABORT_AND_DETACH 使原 evidence 进入 aborted 终态；之后的 advance 必须被拒绝，
    // 防止已撤销事务重新发布 payload 证据。
    status = evidence.recover(RDMA_MODEL_RECOVERY_ABORT_AND_DETACH);
    if (!status.ok() || !evidence.aborted)
      `uvm_error("TXN", "abort-and-detach recovery failed")
    status = evidence.advance(RDMA_QUEUE_TXN_PAYLOAD_WRITTEN);
    if (status.ok() || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("TXN", "aborted transaction advanced")
    phase.drop_objection(this);
  endtask
endclass
