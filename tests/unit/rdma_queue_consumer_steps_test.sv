// 目录/层次：tests/unit；职责：独立验证 consumer 公共通知/CI 步骤的故障、诊断和账本边界。
// 依赖：queue-data engine、真实 queue runtime 与值模型；seam 仅模拟 scheduler/commit 返回。
// 所有权与生命周期：probe 拥有本地 CEQ runtime 和预建值对象，无外部 mapping、PCIe 或
//   Host-memory；每个 case 重建 fixture，runtime 接管 pending 后测试仅查询 detached 快照。
// 本测试不替代公开 CQ shadow、CEQ/AEQ route、replay 幂等和真实 scheduler allocation 回归。

// 设计说明：以真实 CEQ ledger 隔离测试机制，分别选择三种诊断上下文；上下文不应改变
// 通知或 CI 行为。CQ 的 shadow/WQE 业务顺序由既有公开 poll/recovery 集成用例验证。
class rdma_queue_consumer_steps_probe extends rdma_queue_data_engine;
  `uvm_object_utils(rdma_queue_consumer_steps_probe)

  rdma_queue_data_attachment attachment;
  rdma_queue_pending_operation pending;
  rdma_doorbell_desc descriptor;
  rdma_doorbell_result seam_result;
  rdma_status seam_status;
  rdma_status status_slot;
  int unsigned fault;
  int unsigned doorbell_calls;
  int unsigned commit_calls;

  // 功能：构造无外部配置的步骤 probe，关闭故障并清空 seam 计数。
  // 输入/输出及副作用：name 传给 engine 基类；本地 fixture 引用默认 null，由 setup_case 拥有。
  // 失败/边界：构造不准入事务，不可直接执行公开 post/poll；每次测试前必须 setup_case 成功。
  function new(string name = "rdma_queue_consumer_steps_probe");
    super.new(name);
    fault = 0;
    doorbell_calls = 0;
    commit_calls = 0;
  endfunction

  // 功能：setup_case 创建 depth=4、occupancy=1 的 CEQ 和完整 consumer pending。
  // 输入/输出及副作用：admit 决定是否把 pending 交给 runtime，evidence 指定初始通知阶段；
  //   status 返回每步真实错误；预建 descriptor/result/status，重置两个 seam 计数，无外部 I/O。
  // 失败/边界：configure/route/activate/reserve/commit/admission 任一步失败即停止；admit=0
  //   专门模拟 continuation 时 runtime 已无 pending，不伪造可提交状态。
  function rdma_status setup_case(bit admit, rdma_queue_mmio_evidence_e evidence);
    rdma_status status;
    rdma_queue_cursor_snapshot producer;
    rdma_route_key_t route;

    attachment = new("step_attachment");
    attachment.queue_h = new("step_ceq");
    attachment.queue_h.kind = RDMA_RESOURCE_CEQ;
    attachment.queue_h.function_uid = 1;
    attachment.queue_h.object_id = 2;
    attachment.queue_h.generation = 3;
    attachment.kind = RDMA_QUEUE_RUNTIME_CEQ;
    attachment.runtime = new("step_runtime");
    route = '0;
    route.bdf.bus = 1;
    status = attachment.runtime.configure(
      attachment.queue_h, attachment.kind, 4, 0, 1'b0, 0, 1'b0, 1'b0);
    if (status == null || !status.ok())
      return status;
    status = attachment.runtime.set_route_epoch(route, 7);
    if (status == null || !status.ok())
      return status;
    status = attachment.runtime.activate();
    if (status == null || !status.ok())
      return status;
    status = attachment.runtime.reserve_device_producer(producer);
    if (status == null || !status.ok())
      return status;
    status = attachment.runtime.commit_device_producer(producer);
    if (status == null || !status.ok())
      return status;

    pending = new("step_pending");
    pending.queue_h = attachment.queue_h;
    pending.kind = attachment.kind;
    pending.cursor = new("step_old_cursor");
    pending.next_cursor = new("step_next_cursor");
    pending.next_cursor.index = 1;
    pending.entry_size = 16;
    pending.image = new("step_image");
    pending.image.length = 16;
    pending.image.image_kind = RDMA_IMAGE_CEQE;
    repeat (16) pending.image.bytes.push_back(0);
    pending.failure_status = rdma_status::make_direct(RDMA_SC_INVALID_STATE);
    pending.failure_status.message = "fixture sentinel";
    pending.route = route;
    pending.route_valid = 1'b1;
    pending.reset_epoch = 7;
    pending.epoch_valid = 1'b1;
    pending.mmio_evidence = evidence;
    descriptor = new("step_descriptor");
    seam_result = new("step_doorbell_result");
    seam_status = rdma_status::make_direct(RDMA_SC_OK);
    status_slot = rdma_status::make_direct(RDMA_SC_OK);
    doorbell_calls = 0;
    commit_calls = 0;
    if (admit)
      return attachment.runtime.enter_recovery_prepared(pending);
    return status;
  endfunction

  // 功能：按 fault 注入预建 doorbell 返回，覆盖 null、缺 result/证据及真实失败。
  // 输入/输出及副作用：标准 seam 输入仅供接口对齐；result/status/evidence 来自本地脚本，
  //   递增 doorbell_calls，不写 MMIO 或 ledger；所有返回对象均在 setup_case 预建。
  // 失败/边界：fault=1 空 status，2 缺 result，3/6/7 成功状态配错误证据，4/5/9 为真实错误；
  //   其余返回完整成功，8 由 fixture 缺 pending 制造证据保存失败。
  protected virtual task submit_consumer_doorbell(
    rdma_queue_data_attachment attachment,
    rdma_queue_cursor_snapshot next,
    output rdma_doorbell_result result,
    output rdma_status status,
    output rdma_queue_mmio_evidence_e evidence,
    input rdma_queue_data_qp_link routed_link,
    input rdma_doorbell_desc prepared_desc = null,
    input rdma_status prepared_status = null
  );
    doorbell_calls++;
    result = seam_result;
    status = seam_status;
    evidence = RDMA_QUEUE_MMIO_SUCCESS;
    case (fault)
      1: begin
        status = null;
        evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
      end
      2: result = null;
      3: evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
      4, 5, 9: begin
        void'(value_ops::set_status_noalloc(
          seam_status, RDMA_SC_PCIE_COMPLETION, "injected step failure"));
        seam_status.hardware_code = 8'h5a;
        seam_status.hardware_code_valid = 1'b1;
        evidence = fault == 5 ? RDMA_QUEUE_MMIO_AMBIGUOUS : RDMA_QUEUE_MMIO_NO_SUBMIT;
      end
      6: evidence = RDMA_QUEUE_MMIO_NONE;
      7: evidence = RDMA_QUEUE_MMIO_NOT_APPLICABLE;
      default: begin end
    endcase
  endtask

  // 功能：按 fault 注入 CI seam 的 null/真实失败，正常路径委托真实 runtime commit。
  // 输入/输出及副作用：cq_attachment/cursor/prepared_status 原样传给基类；递增 commit_calls，
  //   返回预建 seam_status 或基类状态；只有 fault=0 会改变真实 CI/used。
  // 失败/边界：fault=1 返回 null，2/4 返回带硬件诊断的失败；gate 拒绝时不得进入本 seam。
  protected virtual function rdma_status commit_cq_consumer(
    rdma_queue_data_attachment cq_attachment,
    rdma_queue_cursor_snapshot cursor,
    rdma_status prepared_status = null
  );
    commit_calls++;
    if (fault == 1)
      return null;
    if (fault inside {2, 4}) begin
      void'(value_ops::set_status_noalloc(
        seam_status, RDMA_SC_PCIE_COMPLETION, "injected step failure"));
      seam_status.hardware_code = 8'h5a;
      seam_status.hardware_code_valid = 1'b1;
      return seam_status;
    end
    return super.commit_cq_consumer(cq_attachment, cursor, prepared_status);
  endfunction

  // 功能：check_doorbell_case 对一个诊断上下文/故障组合检查 evidence、返回身份和零 CI 变化。
  // 输入/输出及副作用：diagnostic 选择 CQ/event/replay 固定文本，mode 选择 0..9 故障；
  //   创建独立 fixture，执行一次公共通知步骤，查询真实 occupancy/pending 并报告断言。
  // 失败/边界：只有 mode=0 可 completed；null/假成功不得穿过步骤，真实错误必须保留对象和
  //   硬件诊断，证据丢失须升级 RECOVERY_REQUIRED；任一行为不符报告 UVM_ERROR，不触碰外部资源。
  task check_doorbell_case(consumer_diagnostic_e diagnostic, int unsigned mode);
    rdma_status status;
    rdma_status observed;
    rdma_queue_pending_operation snapshot;
    rdma_status_code_e expected_code;
    rdma_queue_mmio_evidence_e expected_evidence;
    int unsigned occupancy;
    bit completed;
    string prefix;
    string expected_message;

    fault = mode;
    status = setup_case(mode < 8, RDMA_QUEUE_MMIO_NONE);
    if (status == null || !status.ok()) begin
      `uvm_error("STEP_SETUP", status == null ? "null setup" : status.convert2string())
      return;
    end
    prefix = diagnostic == CONSUMER_DIAG_CQ ? "CQ consumer" :
             diagnostic == CONSUMER_DIAG_EVENT ? "event consumer" : "consumer recovery";
    expected_code = RDMA_SC_INVALID_STATE;
    expected_message = {prefix, " doorbell returned incomplete success evidence"};
    expected_evidence = RDMA_QUEUE_MMIO_NO_SUBMIT;
    case (mode)
      0: expected_code = RDMA_SC_OK;
      1: expected_message = {prefix, " doorbell returned null status"};
      4, 5: begin
        expected_code = RDMA_SC_PCIE_COMPLETION;
        expected_message = "injected step failure";
      end
      7, 8, 9: begin
        expected_code = RDMA_SC_RECOVERY_REQUIRED;
        prefix = diagnostic == CONSUMER_DIAG_CQ ? "CQ doorbell" :
                 diagnostic == CONSUMER_DIAG_EVENT ? "event doorbell" :
                 "consumer recovery doorbell";
        expected_message = {prefix, mode == 8 ? " success" : " failure",
          diagnostic == CONSUMER_DIAG_REPLAY ? " could not be retained" :
                                              " evidence could not be retained"};
      end
      default: begin end
    endcase
    case (mode)
      0, 2: expected_evidence = RDMA_QUEUE_MMIO_SUCCESS;
      5: expected_evidence = RDMA_QUEUE_MMIO_AMBIGUOUS;
      6, 7: expected_evidence = RDMA_QUEUE_MMIO_NONE;
      default: begin end
    endcase
    submit_consumer_doorbell_recorded(
      attachment, pending.next_cursor, null, descriptor, status_slot,
      diagnostic, completed, observed);
    if (observed == null || observed.code != expected_code || completed != (mode == 0) ||
        doorbell_calls != 1 || commit_calls != 0)
      `uvm_error("STEP_DOORBELL", $sformatf("context=%0d mode=%0d", diagnostic, mode))
    if (mode != 0 && (observed == null || observed.message != expected_message))
      `uvm_error("STEP_DIAG", $sformatf("context=%0d mode=%0d", diagnostic, mode))
    if (mode inside {0, 4, 5}) begin
      if (observed != seam_status ||
          (mode != 0 && (!observed.hardware_code_valid || observed.hardware_code != 8'h5a)))
        `uvm_error("STEP_STATUS_IDENTITY", "seam status/diagnostic was replaced")
    end
    else if (observed != status_slot)
      `uvm_error("STEP_STATUS_SLOT", "normalized error did not use prebuilt slot")
    status = attachment.runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != 1)
      `uvm_error("STEP_CREDIT", "doorbell step changed consumer credit")
    status = attachment.runtime.query_pending(snapshot);
    if (mode < 8) begin
      if (status == null || !status.ok() || snapshot == null || snapshot.consumer_committed ||
          snapshot.mmio_evidence != expected_evidence ||
          (mode inside {[1:6]} &&
           (snapshot.failure_status.code != expected_code ||
            snapshot.failure_status.message != expected_message)))
        `uvm_error("STEP_EVIDENCE", "doorbell evidence/diagnostic was lost or CI was committed")
    end
    else if (status == null || status.ok() || snapshot != null)
      `uvm_error("STEP_MISSING_PENDING", "step manufactured a replacement transaction")
  endtask

  // 功能：check_commit_case 检查 CI gate、null/真实 seam 失败及失败证据无法保存的停止语义。
  // 输入/输出及副作用：diagnostic 仅选择文本，mode=0..4；构造 SUCCESS pending 后执行公共
  //   commit，mode=3 不安装 pending，mode=4 传非法 failure evidence；查询真实 CI marker/used。
  // 失败/边界：只有 mode=0 可推进一次 CI；gate 拒绝不得调用 seam；其余失败不消费 credit，
  //   null/保存失败使用 status_slot、真实错误保持原对象；任何断言失败报告 UVM_ERROR。
  task check_commit_case(consumer_diagnostic_e diagnostic, int unsigned mode);
    rdma_status status;
    rdma_status observed;
    rdma_queue_pending_operation snapshot;
    rdma_status_code_e expected_code;
    int unsigned occupancy;
    bit completed;
    string prefix;
    string expected_message;

    fault = mode;
    status = setup_case(mode != 3, RDMA_QUEUE_MMIO_SUCCESS);
    if (status == null || !status.ok()) begin
      `uvm_error("STEP_COMMIT_SETUP", status == null ? "null setup" : status.convert2string())
      return;
    end
    prefix = diagnostic == CONSUMER_DIAG_CQ ? "CQ consumer" :
             diagnostic == CONSUMER_DIAG_EVENT ? "event consumer" : "consumer recovery";
    expected_code = RDMA_SC_INVALID_STATE;
    expected_message = {prefix, " commit returned null status"};
    case (mode)
      0: expected_code = RDMA_SC_OK;
      2: begin
        expected_code = RDMA_SC_PCIE_COMPLETION;
        expected_message = "injected step failure";
      end
      3: expected_message = "queue runtime has no pending recovery";
      4: begin
        expected_code = RDMA_SC_RECOVERY_REQUIRED;
        expected_message = {prefix, " commit failure could not be retained"};
      end
      default: begin end
    endcase
    completed = commit_consumer_cursor_recorded(
      attachment, pending.cursor, status_slot,
      mode == 4 ? rdma_queue_mmio_evidence_e'(3'd7) : RDMA_QUEUE_MMIO_SUCCESS,
      diagnostic, observed);
    if (observed == null || observed.code != expected_code || completed != (mode == 0) ||
        commit_calls != (mode == 3 ? 0 : 1) || doorbell_calls != 0)
      `uvm_error("STEP_COMMIT", $sformatf("context=%0d mode=%0d", diagnostic, mode))
    if (mode != 0 && (observed == null || observed.message != expected_message))
      `uvm_error("STEP_COMMIT_DIAG", "commit diagnostic changed")
    if (observed != (mode == 2 ? seam_status : status_slot))
      `uvm_error("STEP_COMMIT_IDENTITY", "commit returned a replacement status")
    status = attachment.runtime.query_occupancy(occupancy);
    if (status == null || !status.ok() || occupancy != (mode == 0 ? 0 : 1))
      `uvm_error("STEP_COMMIT_CREDIT", "CI gate/failure changed consumer credit")
    status = attachment.runtime.query_pending(snapshot);
    if (mode != 3 && (status == null || !status.ok() || snapshot == null ||
        snapshot.consumer_committed != (mode == 0) ||
        snapshot.mmio_evidence != RDMA_QUEUE_MMIO_SUCCESS))
      `uvm_error("STEP_COMMIT_PENDING", "commit marker/evidence changed incorrectly")
    if (mode inside {1, 2} && snapshot != null &&
        (snapshot.failure_status.code != expected_code ||
         snapshot.failure_status.message != expected_message ||
         (mode == 2 && (!snapshot.failure_status.hardware_code_valid ||
                       snapshot.failure_status.hardware_code != 8'h5a))))
      `uvm_error("STEP_COMMIT_FAILURE", "recorded commit error lost diagnostic fields")
  endtask

  // 功能：run_matrix 遍历 CQ/event/replay 三种文本上下文与 15 种步骤场景，共 45 个 case。
  // 输入/输出及副作用：无参数；每个 case 独立建立真实 CEQ runtime，失败由 UVM 汇总。
  // 失败/边界：不共享 pending 或恢复锁，不测试 route/shadow/外部 MMIO，不将合成 evidence
  //   当作真实设备验证；正常结束打印完成标记，供 focused/full 日志验收检查。
  task run_matrix();
    for (int unsigned diagnostic = 0; diagnostic < 3; diagnostic++) begin
      for (int unsigned mode = 0; mode < 10; mode++)
        check_doorbell_case(consumer_diagnostic_e'(diagnostic), mode);
      for (int unsigned mode = 0; mode < 5; mode++)
        check_commit_case(consumer_diagnostic_e'(diagnostic), mode);
    end
    `uvm_info("CONSUMER_STEPS", "completed 45 consumer step cases", UVM_LOW)
  endtask
endclass

// 将机制矩阵注册为独立逻辑用例，使完整 core 回归必须执行，而非只编译 probe。
class rdma_queue_consumer_steps_test extends uvm_test;
  `uvm_component_utils(rdma_queue_consumer_steps_test)

  // 功能：构造机制矩阵的 UVM test，仅建立组件层级。
  // 输入/输出及副作用：name/parent 传给 uvm_test；不拥有外部资源或安装 factory override。
  // 失败/边界：fixture 延迟至 run_phase 构造，构造成功不代表任何事务已提交。
  function new(string name = "rdma_queue_consumer_steps_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：run_phase 创建本地 probe 并执行完整 45-case consumer 步骤矩阵。
  // 输入/输出及副作用：phase 控制 objection 生命周期；只创建本地对象并输出 UVM 结果。
  // 失败/边界：断言不终止后续 case；矩阵结束释放 objection，非零 UVM_ERROR 由外层门禁拒绝。
  task run_phase(uvm_phase phase);
    rdma_queue_consumer_steps_probe probe;

    phase.raise_objection(this);
    probe = new("consumer_steps_probe");
    probe.run_matrix();
    phase.drop_objection(this);
  endtask
endclass
