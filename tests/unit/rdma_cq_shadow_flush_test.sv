// 目录：测试层 tests/unit/rdma_cq_shadow_flush_test.sv。
// 职责：验证共享 URC CQ shadow 的配置、精确一次 flush 以及代际/Function 拒绝边界。
// 依赖：rdma_model_pkg、rdma_core_pkg 与 UVM；测试只拥有本地句柄和快照 fixture。
// 所有权与生命周期：CQ facade 不拥有外部资源；本测试创建的 UVM 对象随测试任务结束释放。

class rdma_cq_shadow_flush_test extends uvm_test;
  `uvm_component_utils(rdma_cq_shadow_flush_test)

  // 功能：创建 CQ shadow 测试组件并建立 UVM 父子关系，不触碰外部设备资源。
  // 输入/输出及副作用：name、parent 为输入；构造函数仅初始化 UVM 组件状态并返回 void。
  // 失败边界：构造不执行配置；任何依赖缺失由测试任务显式报告，不能伪造通过结果。
  function new(string name = "rdma_cq_shadow_flush_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造带指定 Function UID、generation 的本地句柄，用于模拟 CQ/QP authority。
  // 输入/输出及副作用：kind、uid、generation 为输入；返回新建句柄，不修改外部对象。
  // 失败边界：kind 必须是合法资源类型；句柄字段为零时由被测配置入口拒绝。
  function rdma_handle make_handle(rdma_resource_kind_e kind,
                                    longint unsigned uid,
                                    int unsigned generation,
                                    int unsigned object_id);
    rdma_handle h;
    h = rdma_handle::type_id::create("shadow_handle");
    h.kind = kind;
    h.function_uid = uid;
    h.generation = generation;
    h.object_id = object_id;
    return h;
  endfunction

  // 功能：运行 shared/URC shadow flush 主场景，断言首次 flush 捕获 SQ/RQ CI 并清除，重复调用保持同一结果且只计数一次。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务创建本地 CQ/QP/Function 快照并调用被测接口，向日志发布断言结果。
  // 失败边界：配置、flush 返回非 OK、快照字段不符或 flush 计数非 1 均报告错误并结束本场景。
  task automatic test_shared_urc_shadow_flush_is_exactly_once(uvm_phase phase);
    rdma_cq_engine cq;
    rdma_cq_shadow_snapshot shadow;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_status status;
    rdma_queue_data_engine data_engine;

    cq = rdma_cq_engine::type_id::create("shared_urc_cq");
    data_engine = rdma_queue_data_engine::type_id::create("evidence_engine");
    identity = rdma_function_identity::type_id::create("shadow_identity");
    identity.function_uid = 64'h1234;
    identity.generation = 7;
    identity.reset_epoch = 3;
    cq_h = make_handle(RDMA_RESOURCE_CQ, identity.function_uid,
                       identity.generation, 11);
    qp_h = make_handle(RDMA_RESOURCE_QP, identity.function_uid,
                       identity.generation, 22);

    status = cq.configure_shared(cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
                                 12, 9, 2'b1, 64'h55, data_engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_SHADOW", "shared URC CQ configuration failed")
      return;
    end
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null ||
        shadow.sq_ci != 12 || shadow.rq_ci != 9 || shadow.arm_state != 2'b1 ||
        shadow.\sequence  != 64'h55 || shadow.reset_epoch != 3 ||
        shadow.cq_h == null || shadow.cq_h.object_id != 11 ||
        cq.shadow_flush_count != 1)
      `uvm_error("CQ_SHADOW", "first URC shadow flush did not capture expected state")
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || cq.shadow_flush_count != 1 ||
        shadow.sq_ci != 12 || shadow.rq_ci != 9)
      `uvm_error("CQ_SHADOW", "URC shadow flush is not idempotent")
    if (data_engine.last_urc_evidence == null ||
        data_engine.last_urc_evidence.urc_sq_ci != 12 ||
        data_engine.last_urc_evidence.urc_rq_ci != 9 ||
        data_engine.last_urc_evidence.urc_arm_state != 2'b1 ||
        data_engine.last_urc_evidence.urc_sequence != 64'h55)
      `uvm_error("CQ_SHADOW", "URC shadow was not captured as recovery evidence")
    shadow.sq_ci = 99;
    shadow = null;
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null || shadow.sq_ci != 12)
      `uvm_error("CQ_SHADOW", "null replay did not return detached cached shadow")
  endtask

  // 功能：验证 stale/cross-function shadow 在 flush 前被拒绝且不改变内部 shadow 状态。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务使用错误代际和错误 Function UID 快照调用 flush_shadow。
  // 失败边界：任一拒绝未返回 RDMA_SC_STALE_GENERATION，或拒绝后内部状态被清除，均报告错误。
  task automatic test_shadow_flush_rejects_stale_or_cross_function(uvm_phase phase);
    rdma_cq_engine cq;
    rdma_cq_shadow_snapshot stale;
    rdma_cq_shadow_snapshot cross_shadow;
    rdma_cq_shadow_snapshot wrong_kind;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_status status;
    rdma_queue_data_engine data_engine;

    cq = rdma_cq_engine::type_id::create("reject_cq");
    data_engine = rdma_queue_data_engine::type_id::create("reject_evidence_engine");
    identity = rdma_function_identity::type_id::create("reject_identity");
    identity.function_uid = 64'h2222;
    identity.generation = 3;
    identity.reset_epoch = 4;
    cq_h = make_handle(RDMA_RESOURCE_CQ, identity.function_uid, identity.generation, 1);
    qp_h = make_handle(RDMA_RESOURCE_QP, identity.function_uid, identity.generation, 2);
    status = cq.configure_shared(cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
                                 4, 5, 2'b1, 8, data_engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_SHADOW", "reject fixture configuration failed")
      return;
    end
    stale = rdma_cq_shadow_snapshot::type_id::create("stale_shadow");
    stale.cq_h = rdma_clone_handle_value(cq_h, "stale shadow CQ");
    stale.function_uid = identity.function_uid;
    stale.generation = identity.generation - 1;
    stale.reset_epoch = identity.reset_epoch;
    status = cq.flush_shadow(stale);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        cq.shadow_flush_count != 0)
      `uvm_error("CQ_SHADOW", "stale shadow was not rejected without mutation")
    cross_shadow = rdma_cq_shadow_snapshot::type_id::create("cross_shadow");
    cross_shadow.cq_h = rdma_clone_handle_value(cq_h, "cross shadow CQ");
    cross_shadow.function_uid = 64'hdead;
    cross_shadow.generation = identity.generation;
    cross_shadow.reset_epoch = identity.reset_epoch;
    status = cq.flush_shadow(cross_shadow);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        cq.shadow_flush_count != 0)
      `uvm_error("CQ_SHADOW", "cross-function shadow was not rejected without mutation")
    wrong_kind = rdma_cq_shadow_snapshot::type_id::create("wrong_kind_shadow");
    wrong_kind.cq_h = make_handle(RDMA_RESOURCE_QP, identity.function_uid,
                                   identity.generation, cq_h.object_id);
    wrong_kind.function_uid = identity.function_uid;
    wrong_kind.generation = identity.generation;
    wrong_kind.reset_epoch = identity.reset_epoch;
    status = cq.flush_shadow(wrong_kind);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        cq.shadow_flush_count != 0)
      `uvm_error("CQ_SHADOW", "non-CQ shadow handle was not rejected")

    status = cq.configure_shared(cq_h, cq_h, RDMA_TRANSPORT_RC, identity,
                                 1, 1, 0, 1, null);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("CQ_SHADOW", "non-QP completion handle was accepted")
    identity.reset_epoch = 0;
    status = cq.configure_shared(cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
                                 1, 1, 0, 1, data_engine);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("CQ_SHADOW", "zero reset epoch was accepted")
  endtask

  // 功能：验证 shared CQ 配置接受 21-bit 本地 QPN 上限，并拒绝第二次
  // 覆盖活动 authority。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务创建两个本地 CQ/QP 句柄，先以
  // 高位 QPN 完成一次配置和 flush，再尝试用不同 CQ/游标重配置并检查原 shadow 仍可重放。
  // 失败/边界：21-bit 上限 QPN 必须被接受；已配置 facade 的第二次调用
  // 必须返回 INVALID_STATE，且不得清空首个 active shadow 或改变 flush
  // 计数/快照。
  task automatic test_shared_config_width_and_one_shot(uvm_phase phase);
    rdma_cq_engine cq;
    rdma_queue_data_engine data_engine;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_handle replacement_cq_h;
    rdma_cq_shadow_snapshot shadow;
    rdma_status status;

    cq = rdma_cq_engine::type_id::create("width_gate_cq");
    data_engine = rdma_queue_data_engine::type_id::create("width_gate_engine");
    identity = rdma_function_identity::type_id::create("width_gate_identity");
    identity.function_uid = 64'h3333;
    identity.generation = 5;
    identity.reset_epoch = 6;
    cq_h = make_handle(RDMA_RESOURCE_CQ, identity.function_uid,
                       identity.generation, 12);
    // 0x1fffff 是真实驱动 21-bit 资源句柄可表达的最大本地 QPN。
    qp_h = make_handle(RDMA_RESOURCE_QP, identity.function_uid,
                       identity.generation, 21'h1f_ffff);
    status = cq.configure_shared(cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
                                 7, 8, 2'b1, 64'h66, data_engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_QPN_WIDTH", "21-bit shared-CQ QPN was rejected")
      return;
    end

    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null ||
        shadow.sq_ci != 7 || shadow.rq_ci != 8 || cq.shadow_flush_count != 1) begin
      `uvm_error("CQ_QPN_WIDTH", "initial high-QPN shadow flush failed")
      return;
    end

    replacement_cq_h = make_handle(RDMA_RESOURCE_CQ, identity.function_uid,
                                   identity.generation, 13);
    status = cq.configure_shared(replacement_cq_h, qp_h, RDMA_TRANSPORT_URC,
                                 identity, 99, 100, 2'b0, 64'h77, data_engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE) begin
      `uvm_error("CQ_CONFIG_GATE", "active shared CQ accepted a second configuration")
      return;
    end

    shadow = null;
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null ||
        shadow.cq_h == null || shadow.cq_h.object_id != 12 ||
        shadow.sq_ci != 7 || shadow.rq_ci != 8 ||
        shadow.\sequence != 64'h66 || cq.shadow_flush_count != 1)
      `uvm_error("CQ_CONFIG_GATE", "rejected reconfiguration changed cached shadow")
  endtask

  // 功能：启动三个 CQ shadow 场景并管理 objection，作为 VCS test 入口。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务运行测试并在结束时释放 objection。
  // 失败/边界：场景内部错误通过 UVM report 发布；任务本身不吞掉被测状态或外部资源。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_shared_urc_shadow_flush_is_exactly_once(phase);
    test_shadow_flush_rejects_stale_or_cross_function(phase);
    test_shared_config_width_and_one_shot(phase);
    phase.drop_objection(this);
  endtask
endclass
