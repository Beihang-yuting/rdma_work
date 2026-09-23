// 目录：测试层 tests/unit/rdma_cq_shadow_flush_test.sv。
// 职责：验证共享 URC CQ shadow 的配置、精确一次 flush、detached replay 以及
//   代际/Function 拒绝边界。
// 依赖：rdma_model_pkg、rdma_core_pkg 与 UVM；测试只拥有本地句柄和快照 fixture。
// 所有权与生命周期：CQ facade 不拥有外部资源；本测试创建的 UVM 对象随测试任务结束释放。

// 设计说明：该空对象用于证明 CQ shadow raw-factory 边界会拒绝不可 cast 的动态类型；
// 它不携带任何 RDMA authority，不能被误用为有效 snapshot 或 handle。
class rdma_cq_shadow_wrong_factory_object extends uvm_object;
  `uvm_object_utils(rdma_cq_shadow_wrong_factory_object)

  // 功能：构造不兼容的 factory 返回对象，供 snapshot/handle 类型故障注入。
  // 输入/输出及副作用：name 为输入并传给 uvm_object；不登记或修改 CQ/Function 状态。
  // 失败/边界：对象可正常创建，但必须无法 cast 为 rdma_cq_shadow_snapshot/rdma_handle。
  function new(string name = "rdma_cq_shadow_wrong_factory_object");
    super.new(name);
  endfunction
endclass

// 设计说明：typed registry 会把错误 override 升级为 fatal；本 wrapper 按精确实例名
// 一次性返回 null/错误类型，未命中时委托原 wrapper，使测试覆盖生产 raw-factory 分支。
class rdma_cq_shadow_factory_fault_wrapper extends uvm_object_wrapper;
  protected string wrapper_type_name;
  protected uvm_object_wrapper delegate;
  protected string target_name;
  protected bit armed_state;
  protected bit wrong_type_state;
  protected bit fired_state;

  // 功能：保存被覆盖 requested type 的原 wrapper，并以未注入状态启动。
  // 输入/输出及副作用：name/delegate_value 为输入，保存非拥有引用；不修改 UVM factory。
  // 失败/边界：delegate_value=null 时未命中的 create 也返回 null，调用方必须报告失败。
  function new(string name, uvm_object_wrapper delegate_value);
    wrapper_type_name = name;
    delegate = delegate_value;
    target_name = "";
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
    fired_state = 1'b0;
  endfunction

  // 功能：对 armed 的精确 target_name 返回一次 null 或不兼容对象，其余创建委托原类型。
  // 输入/输出及副作用：name 为 factory 实例名；命中时记录 fired 并自动关闭窗口，
  //   返回 raw uvm_object，不直接修改 CQ facade、cache 或 evidence。
  // 失败/边界：wrong_type_state=0 返回 null，=1 返回错误动态类型；delegate 缺失时
  //   非目标创建也返回 null，测试用 fired_state 区分是否命中预期边界。
  virtual function uvm_object create_object(string name = "");
    rdma_cq_shadow_wrong_factory_object wrong_object;

    if (armed_state && name == target_name) begin
      armed_state = 1'b0;
      fired_state = 1'b1;
      if (!wrong_type_state)
        return null;
      wrong_object = new(name);
      return wrong_object;
    end
    if (delegate == null)
      return null;
    return delegate.create_object(name);
  endfunction

  // 功能：返回 factory 诊断使用的稳定 wrapper 名称。
  // 输入/输出及副作用：无输入；只读 wrapper_type_name，不改变注入窗口或 delegate。
  // 失败/边界：名称不参与 RDMA authority，也不能替代调用方的显式动态类型检查。
  virtual function string get_type_name();
    return wrapper_type_name;
  endfunction

  // 功能：为下一次指定实例创建打开 null 或错误类型的一次性故障窗口。
  // 输入/输出及副作用：instance_name/wrong_type 为输入；覆盖旧 target 并清零 fired。
  // 失败/边界：空名称不会命中正常对象；重复 arm 会替换尚未消费的窗口。
  function void arm(string instance_name, bit wrong_type);
    target_name = instance_name;
    wrong_type_state = wrong_type;
    fired_state = 1'b0;
    armed_state = 1'b1;
  endfunction

  // 功能：关闭故障窗口，恢复后续创建对原 wrapper 的委托。
  // 输入/输出及副作用：无输入输出；清除 target/armed/wrong，保留 fired 供断言读取。
  // 失败/边界：重复 disarm 幂等；不会撤销已创建对象或全局 type override。
  function void disarm();
    target_name = "";
    armed_state = 1'b0;
    wrong_type_state = 1'b0;
  endfunction

  // 功能：报告最近一次 arm 窗口是否命中过精确实例名。
  // 输入/输出及副作用：无输入；返回 fired_state，不清除记录或重新打开窗口。
  // 失败/边界：未 arm、未命中或 delegate 自身失败均返回 0。
  function bit fired();
    return fired_state;
  endfunction
endclass

// 设计说明：测试同时验证首次 mutation 与重复 replay；每次 replay 都使用调用方提供的
// 冻结 authority 值匹配；payload 必须来自 facade cache，shared-only 路径不宣称具有
// live binding 认证能力。
class rdma_cq_shadow_flush_test extends uvm_test;
  `uvm_component_utils(rdma_cq_shadow_flush_test)

  // 功能：创建 CQ shadow 测试组件并建立 UVM 父子关系，不触碰外部设备资源。
  // 输入/输出及副作用：name、parent 为输入；构造函数仅初始化 UVM 组件状态并返回 void。
  // 失败/边界：构造不执行配置；任何依赖缺失由测试任务显式报告，不能伪造通过结果。
  function new(string name = "rdma_cq_shadow_flush_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：构造带指定 Function UID/generation/object ID 的本地 CQ/QP authority 句柄。
  // 输入/输出及副作用：kind、uid、generation、object_id 为输入；返回新句柄，
  //   不登记 resource manager，也不修改外部对象。
  // 失败/边界：kind 必须是合法资源类型；零 UID/generation 或越界 object_id
  //   由被测配置入口拒绝；fixture factory 失败会使测试无法继续并由调用场景暴露。
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

  // 功能：构造只携带冻结 shared-CQ authority 的 replay request，payload 保持构造默认零。
  // 输入/输出及副作用：name、cq_h、identity 为输入；返回拥有独立 CQ handle 的 snapshot，
  //   不读取 facade cache、不修改 identity 或 source handle。
  // 失败/边界：cq_h/identity 为空或 snapshot factory 失败时返回 null；调用方不得把
  //   null 当作已认证 replay，字段合法性仍由 flush_shadow 完整校验。
  function rdma_cq_shadow_snapshot make_replay_request(
    string name,
    rdma_handle cq_h,
    rdma_function_identity identity
  );
    rdma_cq_shadow_snapshot request;

    if (cq_h == null || identity == null)
      return null;
    request = rdma_cq_shadow_snapshot::type_id::create(name);
    if (request == null)
      return null;
    request.cq_h = make_handle(cq_h.kind, cq_h.function_uid,
                               cq_h.generation, cq_h.object_id);
    request.function_uid = identity.function_uid;
    request.generation = identity.generation;
    request.reset_epoch = identity.reset_epoch;
    return request;
  endfunction

  // 功能：调用 replay 并断言 stale/cross authority 被原子拒绝，不向 caller 泄露 cache。
  // 输入/输出及副作用：cq/request/label 为输入；任务调用 flush_shadow，并比较 request
  //   对象、nested handle 与全部 authority/payload 字段，唯一允许的新对象是失败 status。
  // 失败/边界：预期 RDMA_SC_STALE_GENERATION；request=null、字段/句柄变化或 count!=1
  //   均发布 UVM error，任务不修复被测状态。
  task automatic expect_replay_authority_rejected_unchanged(
    rdma_cq_engine cq,
    inout rdma_cq_shadow_snapshot request,
    input string label
  );
    rdma_cq_shadow_snapshot original_request;
    rdma_handle original_handle;
    rdma_status status;
    longint unsigned function_uid;
    int unsigned generation;
    rdma_reset_epoch_t reset_epoch;
    int unsigned sq_ci;
    int unsigned rq_ci;
    bit [1:0] arm_state;
    longint unsigned sequence_value;

    original_request = request;
    original_handle = request == null ? null : request.cq_h;
    function_uid = request == null ? 0 : request.function_uid;
    generation = request == null ? 0 : request.generation;
    reset_epoch = request == null ? 0 : request.reset_epoch;
    sq_ci = request == null ? 0 : request.sq_ci;
    rq_ci = request == null ? 0 : request.rq_ci;
    arm_state = request == null ? '0 : request.arm_state;
    sequence_value = request == null ? 0 : request.\sequence ;

    status = cq.flush_shadow(request);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
        request != original_request || request == null ||
        request.cq_h != original_handle ||
        request.function_uid != function_uid || request.generation != generation ||
        request.reset_epoch != reset_epoch || request.sq_ci != sq_ci ||
        request.rq_ci != rq_ci || request.arm_state != arm_state ||
        request.\sequence != sequence_value || cq.shadow_flush_count != 1)
      `uvm_error(label, "replay authority rejection changed caller/cache state")
  endtask

  // 功能：把 CQ shadow 测试安装的 type override 恢复到调用前 wrapper。
  // 输入/输出及副作用：factory/requested_type/saved_override/label 为输入；已有
  //   override 精确写回，原本无 override 时保留已 disarm 的委托代理。
  // 失败/边界：factory/requested_type 缺失或显式恢复后 wrapper 不等于 saved_override
  //   时发布 UVM error；saved_override 等于 requested_type 时不执行危险的 base-to-base。
  function void restore_factory_override(
    uvm_factory factory,
    uvm_object_wrapper requested_type,
    uvm_object_wrapper saved_override,
    string label
  );
    if (factory == null || requested_type == null) begin
      `uvm_error(label, "factory restore inputs are incomplete")
      return;
    end
    if (saved_override != null && saved_override != requested_type)
      factory.set_type_override_by_type(requested_type, saved_override, 1'b1);
    else if (saved_override == requested_type) begin
      // UVM 1.2 没有 clear_type_override，且 W-2024.09 把 base->base 解析为
      // OVRDLOOP；已 disarm 的 wrapper 只委托 saved base，不改变后续对象语义。
    end
    if (saved_override != requested_type &&
        factory.find_override_by_type(requested_type, "") != saved_override)
      `uvm_error(label, "factory override was not restored")
  endfunction

  // 功能：验证 shared/URC 首次 flush 捕获游标并清除一次，后续调用从冻结缓存重建
  //   detached 快照，而不是保留 caller 对 payload、handle 或 success status 的篡改。
  // 输入/输出及副作用：phase 为输入；任务创建 CQ/QP/Function authority，先捕获 shadow，
  //   再篡改多轮输出并以冻结 authority replay，检查 detached cache、拒绝原子性和 evidence。
  // 失败/边界：配置/flush 失败、replay 未恢复全部 authority/payload、caller/status alias
  //   污染后续结果、post-cache stale 输入泄露 cache、计数不为 1 或 null replay 成功
  //   均报告错误；shared-only 场景不模拟 live binding reset。
  task automatic test_shared_urc_shadow_flush_is_exactly_once(uvm_phase phase);
    rdma_cq_engine cq;
    rdma_cq_shadow_snapshot shadow;
    rdma_cq_shadow_snapshot previous_shadow;
    rdma_handle previous_shadow_handle;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_status status;
    rdma_status first_status;
    rdma_cq_shadow_snapshot replay_request;
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
        shadow.function_uid != identity.function_uid ||
        shadow.generation != identity.generation || shadow.cq_h == null ||
        shadow.cq_h.object_id != 11 ||
        cq.shadow_flush_count != 1)
      `uvm_error("CQ_SHADOW", "first URC shadow flush did not capture expected state")

    previous_shadow = shadow;
    previous_shadow_handle = shadow.cq_h;
    first_status = status;
    first_status.code = RDMA_SC_UNKNOWN_HW_ERROR;
    first_status.message = "caller-mutated flush success";
    shadow.sq_ci = 99;
    shadow.rq_ci = 98;
    shadow.arm_state = 2'b0;
    shadow.\sequence = 64'hdead;
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() ||
        status.message != "" || shadow == previous_shadow ||
        shadow.cq_h == previous_shadow_handle ||
        cq.shadow_flush_count != 1 || shadow.sq_ci != 12 || shadow.rq_ci != 9 ||
        shadow.arm_state != 2'b1 || shadow.\sequence != 64'h55 ||
        shadow.function_uid != identity.function_uid ||
        shadow.generation != identity.generation ||
        shadow.reset_epoch != identity.reset_epoch)
      `uvm_error("CQ_SHADOW",
                 "URC shadow replay did not return detached canonical values")

    // 篡改 replay 输出的 handle 和 payload 后，使用独立 authority-only 对象再次调用；
    // 若 facade 把内部缓存直接暴露给 caller，本次返回会携带被污染的值。
    previous_shadow = shadow;
    previous_shadow_handle = shadow.cq_h;
    shadow.cq_h.object_id = 99;
    shadow.sq_ci = 77;
    replay_request = make_replay_request(
      "shadow_replay_authority", cq_h, identity);
    status = cq.flush_shadow(replay_request);
    if (status == null || !status.ok() || replay_request == previous_shadow ||
        replay_request.cq_h == previous_shadow_handle ||
        replay_request.cq_h == null || replay_request.cq_h.object_id != 11 ||
        replay_request.function_uid != identity.function_uid ||
        replay_request.generation != identity.generation ||
        replay_request.reset_epoch != identity.reset_epoch ||
        replay_request.sq_ci != 12 || replay_request.rq_ci != 9 ||
        replay_request.arm_state != 2'b1 || replay_request.\sequence != 64'h55 ||
        cq.shadow_flush_count != 1)
      `uvm_error("CQ_SHADOW", "caller alias corrupted cached shadow replay")

    // cache 建立后的五类 authority 拒绝都必须保持 caller 原值；随后再以有效
    // request replay，证明拒绝既未泄露也未破坏 canonical cache。
    replay_request = make_replay_request("replay_bad_uid", cq_h, identity);
    replay_request.function_uid ^= 64'h1;
    replay_request.cq_h.function_uid ^= 64'h1;
    replay_request.sq_ci = 101;
    expect_replay_authority_rejected_unchanged(
      cq, replay_request, "CQ_REPLAY_UID_GATE");

    replay_request = make_replay_request("replay_bad_generation", cq_h, identity);
    replay_request.generation++;
    replay_request.cq_h.generation++;
    replay_request.rq_ci = 102;
    expect_replay_authority_rejected_unchanged(
      cq, replay_request, "CQ_REPLAY_GENERATION_GATE");

    replay_request = make_replay_request("replay_bad_epoch", cq_h, identity);
    replay_request.reset_epoch++;
    replay_request.arm_state = 2'b10;
    expect_replay_authority_rejected_unchanged(
      cq, replay_request, "CQ_REPLAY_EPOCH_GATE");

    replay_request = make_replay_request("replay_bad_object", cq_h, identity);
    replay_request.cq_h.object_id++;
    replay_request.\sequence = 64'h103;
    expect_replay_authority_rejected_unchanged(
      cq, replay_request, "CQ_REPLAY_OBJECT_GATE");

    replay_request = make_replay_request("replay_bad_kind", cq_h, identity);
    replay_request.cq_h.kind = RDMA_RESOURCE_QP;
    replay_request.sq_ci = 104;
    expect_replay_authority_rejected_unchanged(
      cq, replay_request, "CQ_REPLAY_KIND_GATE");

    replay_request = make_replay_request("replay_after_rejections", cq_h, identity);
    status = cq.flush_shadow(replay_request);
    if (status == null || !status.ok() || replay_request == null ||
        replay_request.cq_h == null || replay_request.cq_h.object_id != 11 ||
        replay_request.sq_ci != 12 || replay_request.rq_ci != 9 ||
        replay_request.arm_state != 2'b1 || replay_request.\sequence != 64'h55 ||
        cq.shadow_flush_count != 1)
      `uvm_error("CQ_REPLAY_REJECTION_ATOMIC",
                 "authority rejection damaged canonical replay cache")

    if (data_engine.last_urc_evidence == null ||
        data_engine.last_urc_evidence.urc_sq_ci != 12 ||
        data_engine.last_urc_evidence.urc_rq_ci != 9 ||
        data_engine.last_urc_evidence.urc_arm_state != 2'b1 ||
        data_engine.last_urc_evidence.urc_sequence != 64'h55)
      `uvm_error("CQ_SHADOW", "URC shadow was not captured as recovery evidence")
    // replay 没有任何 caller authority 输入时，禁止把旧快照重新发布。
    shadow = null;
    status = cq.flush_shadow(shadow);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION || shadow != null)
      `uvm_error("CQ_SHADOW", "null replay incorrectly returned stale cached shadow")
  endtask

  // 功能：验证 stale/cross-function shadow 在 flush 前被拒绝且不改变内部 shadow 状态。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务使用错误代际和错误 Function UID 快照调用 flush_shadow。
  // 失败/边界：任一拒绝未返回 RDMA_SC_STALE_GENERATION，或拒绝后内部状态被清除，均报告错误。
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

    // 保留调用方携带的原 authority 快照才能合法重放；无快照的拒绝边界
    // 由 shared/URC 场景覆盖。
    status = cq.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null ||
        shadow.cq_h == null || shadow.cq_h.object_id != 12 ||
        shadow.sq_ci != 7 || shadow.rq_ci != 8 ||
        shadow.\sequence != 64'h66 || cq.shadow_flush_count != 1)
      `uvm_error("CQ_CONFIG_GATE", "rejected reconfiguration changed cached shadow")
  endtask

  // 功能：向 shared handle、首次 cache 和 replay 的 raw factory 边界注入 null/错误类型，
  //   验证所有分配故障均非致命、原子且可重试。
  // 输入/输出及副作用：phase 为输入；任务短时安装 snapshot/handle/evidence type override，驱动
  //   configure_shared/flush_shadow，并在退出前恢复原 wrapper；不访问真实 PCIe/Host-memory。
  // 失败/边界：每次注入必须返回 RESOURCE_EXHAUSTED 且精确命中；配置失败不得置位，
  //   首刷（含 evidence candidate）失败不得发布 evidence/cache/count，replay 失败不得改 caller/evidence/count；
  //   disarm 后必须成功恢复 canonical 值，factory 恢复失败也报告 UVM error。
  task automatic test_shadow_factory_failure_atomicity(uvm_phase phase);
    rdma_cq_engine cq;
    rdma_queue_data_engine data_engine;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_handle qp_h;
    rdma_cq_shadow_snapshot caller;
    rdma_cq_shadow_snapshot original_caller;
    rdma_handle original_caller_handle;
    rdma_queue_txn_evidence first_evidence;
    rdma_status status;
    uvm_factory factory;
    uvm_object_wrapper saved_snapshot_override;
    uvm_object_wrapper saved_handle_override;
    uvm_object_wrapper saved_evidence_override;
    rdma_cq_shadow_factory_fault_wrapper snapshot_fault;
    rdma_cq_shadow_factory_fault_wrapper handle_fault;
    rdma_cq_shadow_factory_fault_wrapper evidence_fault;

    cq = rdma_cq_engine::type_id::create("factory_atomic_cq");
    data_engine = rdma_queue_data_engine::type_id::create(
      "factory_atomic_evidence_engine");
    identity = rdma_function_identity::type_id::create("factory_atomic_identity");
    identity.function_uid = 64'h4444;
    identity.generation = 9;
    identity.reset_epoch = 7;
    cq_h = make_handle(RDMA_RESOURCE_CQ, identity.function_uid,
                       identity.generation, 41);
    qp_h = make_handle(RDMA_RESOURCE_QP, identity.function_uid,
                       identity.generation, 42);
    factory = uvm_factory::get();
    if (cq == null || data_engine == null || identity == null ||
        cq_h == null || qp_h == null || factory == null) begin
      `uvm_error("CQ_SHADOW_FACTORY", "factory atomicity fixture is incomplete")
      return;
    end

    saved_snapshot_override = factory.find_override_by_type(
      rdma_cq_shadow_snapshot::get_type(), "");
    saved_handle_override = factory.find_override_by_type(
      rdma_handle::get_type(), "");
    saved_evidence_override = factory.find_override_by_type(
      rdma_queue_txn_evidence::get_type(), "");
    snapshot_fault = new("cq_shadow_snapshot_fault", saved_snapshot_override);
    handle_fault = new("cq_shadow_handle_fault", saved_handle_override);
    evidence_fault = new("cq_shadow_evidence_fault", saved_evidence_override);
    factory.set_type_override_by_type(
      rdma_cq_shadow_snapshot::get_type(), snapshot_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_handle::get_type(), handle_fault, 1'b1);
    factory.set_type_override_by_type(
      rdma_queue_txn_evidence::get_type(), evidence_fault, 1'b1);

    // CQ 与 completion-QP 是 shared 配置的两个分配点；两种动态返回失败后同一
    // facade 仍应可成功配置，证明任一 clone 都没有发布部分 authority。
    for (int unsigned target_kind = 0; target_kind < 2; target_kind++) begin
      for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
        handle_fault.arm(
          target_kind == 0 ? "shared_cq_handle" :
                             "shared_completion_qp_handle", wrong_type);
        status = cq.configure_shared(
          cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
          31, 27, 2'b10, 64'h4455, data_engine);
        if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
            !handle_fault.fired() || cq.shadow_flush_count != 0 ||
            data_engine.last_urc_evidence != null)
          `uvm_error("CQ_CONFIG_FACTORY_ATOMIC", $sformatf(
                     "shared handle failure was not atomic target=%0d mode=%0d",
                     target_kind, wrong_type))
        handle_fault.disarm();
      end
    end

    status = cq.configure_shared(
      cq_h, qp_h, RDMA_TRANSPORT_URC, identity,
      31, 27, 2'b10, 64'h4455, data_engine);
    if (status == null || !status.ok())
      `uvm_error("CQ_CONFIG_FACTORY_RETRY",
                 "shared configuration did not recover after factory failures")
    else begin
      caller = make_replay_request("factory_first_flush_caller", cq_h, identity);
      caller.sq_ci = 201;
      caller.rq_ci = 202;
      caller.arm_state = 2'b01;
      caller.\sequence = 64'h203;
      original_caller = caller;
      original_caller_handle = caller.cq_h;

      // 首刷输出 snapshot/handle 与 cached snapshot/handle 都是 evidence 前的可失败
      // 点；分别覆盖 null 与错误类型，失败后 caller 和 active shadow 必须仍可重试。
      for (int unsigned target_kind = 0; target_kind < 2; target_kind++) begin
        for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
          if (target_kind == 0)
            snapshot_fault.arm("flushed_cq_shadow", wrong_type);
          else
            handle_fault.arm("flushed_cq_shadow_handle", wrong_type);
          status = cq.flush_shadow(caller);
          if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
              (target_kind == 0 && !snapshot_fault.fired()) ||
              (target_kind == 1 && !handle_fault.fired()) ||
              caller != original_caller || caller.cq_h != original_caller_handle ||
              caller.sq_ci != 201 || caller.rq_ci != 202 ||
              caller.arm_state != 2'b01 || caller.\sequence != 64'h203 ||
              cq.shadow_flush_count != 0 || data_engine.last_urc_evidence != null)
            `uvm_error("CQ_FIRST_SNAPSHOT_FACTORY", $sformatf(
                       "first output failure was not atomic target=%0d mode=%0d",
                       target_kind, wrong_type))
          snapshot_fault.disarm();
          handle_fault.disarm();
        end
      end

      // cached snapshot/handle 是 evidence 前最后两个可失败点；分别覆盖 null 与
      // 错误类型，失败后 caller 和 active shadow 必须仍可用于下一次尝试。
      for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
        snapshot_fault.arm("cached_cq_shadow", wrong_type);
        status = cq.flush_shadow(caller);
        if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
            !snapshot_fault.fired() || caller != original_caller ||
            caller.cq_h != original_caller_handle || caller.sq_ci != 201 ||
            caller.rq_ci != 202 || caller.arm_state != 2'b01 ||
            caller.\sequence != 64'h203 || cq.shadow_flush_count != 0 ||
            data_engine.last_urc_evidence != null)
          `uvm_error("CQ_CACHE_SNAPSHOT_FACTORY", $sformatf(
                     "cache snapshot failure was not atomic mode=%0d", wrong_type))
        snapshot_fault.disarm();
      end
      for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
        handle_fault.arm("cached_cq_shadow_handle", wrong_type);
        status = cq.flush_shadow(caller);
        if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
            !handle_fault.fired() || caller != original_caller ||
            caller.cq_h != original_caller_handle || caller.sq_ci != 201 ||
            caller.rq_ci != 202 || caller.arm_state != 2'b01 ||
            caller.\sequence != 64'h203 || cq.shadow_flush_count != 0 ||
            data_engine.last_urc_evidence != null)
          `uvm_error("CQ_CACHE_HANDLE_FACTORY", $sformatf(
                     "cache handle failure was not atomic mode=%0d", wrong_type))
        handle_fault.disarm();
      end

      // evidence candidate 是两个 detached snapshot 成功后的最后一个 factory 点；
      // null/错误动态类型均必须在发布 last_urc_evidence 前返回可重试失败。
      for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
        evidence_fault.arm("urc_shadow_evidence", wrong_type);
        status = cq.flush_shadow(caller);
        if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
            !evidence_fault.fired() || caller != original_caller ||
            caller.cq_h != original_caller_handle || caller.sq_ci != 201 ||
            caller.rq_ci != 202 || caller.arm_state != 2'b01 ||
            caller.\sequence != 64'h203 || cq.shadow_flush_count != 0 ||
            data_engine.last_urc_evidence != null)
          `uvm_error("CQ_EVIDENCE_FACTORY_ATOMIC", $sformatf(
                     "evidence factory failure was not atomic mode=%0d",
                     wrong_type))
        evidence_fault.disarm();
      end

      status = cq.flush_shadow(caller);
      if (status == null || !status.ok() || caller == original_caller ||
          caller.cq_h == original_caller_handle || caller.sq_ci != 31 ||
          caller.rq_ci != 27 || caller.arm_state != 2'b10 ||
          caller.\sequence != 64'h4455 || cq.shadow_flush_count != 1 ||
          data_engine.last_urc_evidence == null)
        `uvm_error("CQ_CACHE_FACTORY_RETRY",
                   "first flush did not recover after cache factory failures")
      first_evidence = data_engine.last_urc_evidence;

      caller = make_replay_request("factory_replay_caller", cq_h, identity);
      caller.sq_ci = 301;
      caller.rq_ci = 302;
      caller.arm_state = 2'b01;
      caller.\sequence = 64'h303;
      original_caller = caller;
      original_caller_handle = caller.cq_h;

      for (int unsigned target_kind = 0; target_kind < 2; target_kind++) begin
        for (int unsigned wrong_type = 0; wrong_type < 2; wrong_type++) begin
          if (target_kind == 0)
            snapshot_fault.arm("replayed_cq_shadow", wrong_type);
          else
            handle_fault.arm("replayed_cq_shadow_handle", wrong_type);
          status = cq.flush_shadow(caller);
          if (status == null || status.code != RDMA_SC_RESOURCE_EXHAUSTED ||
              (target_kind == 0 && !snapshot_fault.fired()) ||
              (target_kind == 1 && !handle_fault.fired()) ||
              caller != original_caller || caller.cq_h != original_caller_handle ||
              caller.sq_ci != 301 || caller.rq_ci != 302 ||
              caller.arm_state != 2'b01 || caller.\sequence != 64'h303 ||
              cq.shadow_flush_count != 1 ||
              data_engine.last_urc_evidence != first_evidence)
            `uvm_error("CQ_REPLAY_FACTORY_ATOMIC", $sformatf(
                       "replay factory failure changed state target=%0d mode=%0d",
                       target_kind, wrong_type))
          snapshot_fault.disarm();
          handle_fault.disarm();
        end
      end

      status = cq.flush_shadow(caller);
      if (status == null || !status.ok() || caller == original_caller ||
          caller.cq_h == original_caller_handle || caller.sq_ci != 31 ||
          caller.rq_ci != 27 || caller.arm_state != 2'b10 ||
          caller.\sequence != 64'h4455 || cq.shadow_flush_count != 1 ||
          data_engine.last_urc_evidence != first_evidence)
        `uvm_error("CQ_REPLAY_FACTORY_RETRY",
                   "replay did not recover after factory failures")
    end

    snapshot_fault.disarm();
    handle_fault.disarm();
    evidence_fault.disarm();
    restore_factory_override(
      factory, rdma_cq_shadow_snapshot::get_type(),
      saved_snapshot_override, "CQ_SNAPSHOT_FACTORY_RESTORE");
    restore_factory_override(
      factory, rdma_handle::get_type(),
      saved_handle_override, "CQ_HANDLE_FACTORY_RESTORE");
    restore_factory_override(
      factory, rdma_queue_txn_evidence::get_type(),
      saved_evidence_override, "CQ_EVIDENCE_FACTORY_RESTORE");
  endtask

  // 功能：启动四个 CQ shadow 场景并管理 objection，作为 VCS test 入口。
  // 输入/输出及副作用：phase 为 UVM phase 输入；任务按正常、拒绝、宽度和 factory
  //   原子性顺序运行测试，factory 场景自行恢复 override，结束时释放 objection。
  // 失败/边界：场景内部错误通过 UVM report 发布；任务本身不吞掉被测状态或外部资源。
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    test_shared_urc_shadow_flush_is_exactly_once(phase);
    test_shadow_flush_rejects_stale_or_cross_function(phase);
    test_shared_config_width_and_one_shot(phase);
    test_shadow_factory_failure_atomicity(phase);
    phase.drop_objection(this);
  endtask
endclass
