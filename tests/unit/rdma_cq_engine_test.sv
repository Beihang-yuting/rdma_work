// 目录：测试层 unit/rdma_cq_engine_test.sv，覆盖 CQ facade 的 operation envelope。
// 职责：验证 poll/publish/resize 的配置与 Function authority 门禁、status 归一化、
//   CQE 解码/CI 提交，以及 facade 与 direct producer 的等价性。
// 依赖：rdma_core_pkg、queue-data fixture、XTR v1 CQE codec、Function binding 和
//   mock Host-memory 后端。
// 所有权与生命周期：测试拥有本地 fixture/sentinel；facade 只借用 runtime、binding
//   与 backing mapping，统一 epilogue 释放 fixture 资源。

// 功能：提供 CQ facade 的 hostile delegate seam，模拟 poll/publish/resize 返回
//   null 或显式失败 status，同时夹带未认证 completion/result。
// 输入/输出及副作用：注入模式、最后返回的 status 句柄和调用计数由测试控制；
//   各 seam 不访问 runtime、backing 或 cursor，只写 output 并记录观测状态。
// 失败/边界：null 模式必须归一化为 INVALID_STATE，失败模式必须保留原 code/
//   message；poll/publish 的 result 在两种模式下都必须被 facade 清空。
// 设计说明：用受保护 virtual seam 注入不可信 delegate 输出，可只验证 facade 外壳，
// 不把真实 queue runtime 的合法性检查混入 null-status 和对象身份断言。
class rdma_cq_hostile_facade extends rdma_cq_engine;
  `uvm_object_utils(rdma_cq_hostile_facade)

  bit inject_failure_status;
  rdma_status last_returned_status;
  int unsigned poll_calls;
  int unsigned publish_calls;
  int unsigned resize_calls;

  // 功能：构造 CQ hostile facade，默认注入 null status 故障。
  // 输入/输出及副作用：name 为输入；初始化模式、最后返回的 status 和调用计数，
  //   不分配 CQ、runtime 或 backing。
  // 失败/边界：必须先通过父类 configure 建立 authority，才能调用三个 seam。
  function new(string name = "rdma_cq_hostile_facade");
    super.new(name);
    inject_failure_status = 1'b0;
    last_returned_status = null;
    poll_calls = 0;
    publish_calls = 0;
    resize_calls = 0;
  endfunction

  // 功能：模拟 CQ poll delegate 返回未认证 completion 与 null/失败 status。
  // 输入/输出及副作用：cq_h/timeout 为输入；result 被设置为测试对象，status
  //   按模式输出并同步到 last_returned_status；不读取 backing、不推进 CI。
  // 失败/边界：任何模式都不得被调用方视为成功事务；公开 poll_cqe 必须清空
  //   result 并规范化 null status。
  protected virtual task call_delegate_poll_cqe(
    rdma_handle cq_h,
    time timeout,
    output rdma_queue_completion_result result,
    output rdma_status status
  );
    poll_calls++;
    result = rdma_queue_completion_result::type_id::create(
      "cq_untrusted_poll_result");
    status = inject_failure_status ?
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "injected CQ poll failure") : null;
    last_returned_status = status;
  endtask

  // 功能：模拟 CQ publish delegate 返回未认证 publish result 与 null/失败 status。
  // 输入/输出及副作用：cq_h/model 为输入；result/status 按模式输出，status 同步到
  //   last_returned_status；不预留槽位、不写 backing、不提交 producer cursor。
  // 失败/边界：公开 publish_cqe 必须丢弃 result；null 归一化为 INVALID_STATE，
  //   显式失败保留原始错误。
  protected virtual task call_delegate_publish_cqe(
    rdma_handle cq_h,
    rdma_hw_cqe_model model,
    output rdma_queue_device_publish_result result,
    output rdma_status status
  );
    publish_calls++;
    result = rdma_queue_device_publish_result::type_id::create(
      "cq_untrusted_publish_result");
    status = inject_failure_status ?
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "injected CQ publish failure") : null;
    last_returned_status = status;
  endtask

  // 功能：模拟 CQ resize delegate 返回 null/失败 status，验证 resize 边界归一化。
  // 输入/输出及副作用：cq_h/new_depth/new_cqe_bytes 为输入；递增计数、记录并返回
  //   last_returned_status，不修改 attachment geometry 或旧 runtime。
  // 失败/边界：null 必须由公开 resize 归一化为 INVALID_STATE，显式失败必须原样
  //   传播；调用方不能据此认为 ring 已切换。
  protected virtual function rdma_status call_delegate_resize_cq(
    rdma_handle cq_h,
    int unsigned new_depth,
    int unsigned new_cqe_bytes
  );
    resize_calls++;
    last_returned_status = inject_failure_status ?
      rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                        "injected CQ resize failure") : null;
    return last_returned_status;
  endfunction
endclass

// 设计说明：主测试同时驱动真实 delegate 与 hostile seam，前者锁定数据路径，后者
// 锁定 facade 拒绝顺序；二者共用同一 ACTIVE Function fixture，避免 authority 差异
// 掩盖 operation-envelope 回归。
class rdma_cq_engine_test extends uvm_test;
  `uvm_component_utils(rdma_cq_engine_test)

  // 功能：创建 CQ facade UVM 测试组件并建立 parent 层级；fixture 在 run_phase 分配。
  // 输入/输出及副作用：name、parent 为输入；new 仅调用 uvm_test 构造，不创建
  //   manager、binding、runtime、Host-memory 或测试 sentinel。
  // 失败/边界：parent 可按 UVM 顶层规则为空；构造阶段没有可清理资源，run_phase
  //   fixture/setup 失败会报告错误并进入统一 epilogue。
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

  // 功能：验证 configure 与 configure_shared 共享唯一 delegate 所有权；两种
  //   调用顺序都拒绝 foreign engine，并允许同一 engine 补齐独立配置。
  // 输入/输出及副作用：fixture 提供真实 binding/CQ/delegate；task 创建两个 facade
  //   和一个只借用相同依赖的 foreign engine，不访问 foreign runtime/backing。
  // 失败/边界：foreign 或跨 Function UID/generation 请求必须保持既有配置原子不变；
  //   随后同 engine 配置和 shadow flush 必须成功并保留初始游标，证明
  //   delegate/authority/shadow 未被替换。
  task automatic check_dual_configuration_delegate_ownership(
    rdma_queue_data_engine_fixture fixture
  );
    rdma_cq_engine configure_first;
    rdma_cq_engine shared_first;
    rdma_queue_data_engine foreign_engine;
    rdma_function_identity identity;
    rdma_handle cq_h;
    rdma_cq_shadow_snapshot shadow;
    rdma_status status;
    longint unsigned saved_function_uid;
    int unsigned saved_generation;

    configure_first = rdma_cq_engine::type_id::create("cq_configure_first");
    shared_first = rdma_cq_engine::type_id::create("cq_shared_first");
    foreign_engine = rdma_queue_data_engine::type_id::create(
      "cq_foreign_delegate");
    identity = fixture.binding.function_identity_snapshot();
    if (configure_first == null || shared_first == null ||
        foreign_engine == null || identity == null) begin
      `uvm_error("CQ_DUAL_CONFIG_FACTORY",
                 "CQ dual-configuration fixture allocation failed")
      return;
    end
    foreign_engine.manager = fixture.manager;
    foreign_engine.binding = fixture.binding;
    foreign_engine.host_mem = fixture.mem;
    foreign_engine.doorbells = fixture.scheduler;
    foreign_engine.registry = fixture.registry;

    // configure_shared 要求非零 reset epoch；该 helper 只验证两个配置入口的
    // delegate 原子性，不把 detached identity 写回 fixture 的活动 binding。
    identity.reset_epoch = 1;
    cq_h = rdma_handle::type_id::create("cq_dual_config_handle");
    cq_h.kind = RDMA_RESOURCE_CQ;
    cq_h.function_uid = identity.function_uid;
    cq_h.generation = identity.generation;
    cq_h.object_id = 12;

    status = configure_first.configure(
      fixture.manager, fixture.binding, fixture.mem, fixture.scheduler,
      fixture.registry, 2us, fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_DUAL_CONFIG_FIRST",
                 "CQ configure-first setup failed")
      return;
    end

    // configure_shared 补齐的是同一 queue-data delegate 的 CQ；即使 caller 同时
    // 改写 handle 与 identity，跨 Function UID/generation 也不能把新 authority
    // 发布到普通 configure 已绑定的旧 engine。
    saved_function_uid = identity.function_uid;
    saved_generation = identity.generation;
    identity.function_uid = saved_function_uid ^ 64'h1;
    cq_h.function_uid = identity.function_uid;
    status = configure_first.configure_shared(
      cq_h, null, RDMA_TRANSPORT_RC, identity,
      7, 3, 2'b1, 64'h71, fixture.engine);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("CQ_CONFIGURE_CROSS_UID",
                 "cross-Function UID shared configuration was accepted")
    identity.function_uid = saved_function_uid;
    cq_h.function_uid = saved_function_uid;

    identity.generation = saved_generation + 1;
    cq_h.generation = identity.generation;
    status = configure_first.configure_shared(
      cq_h, null, RDMA_TRANSPORT_RC, identity,
      7, 3, 2'b1, 64'h71, fixture.engine);
    if (status == null || status.code != RDMA_SC_STALE_GENERATION)
      `uvm_error("CQ_CONFIGURE_CROSS_GENERATION",
                 "cross-generation shared configuration was accepted")
    identity.generation = saved_generation;
    cq_h.generation = saved_generation;

    status = configure_first.configure_shared(
      cq_h, null, RDMA_TRANSPORT_RC, identity,
      7, 3, 2'b1, 64'h71, foreign_engine);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("CQ_CONFIGURE_THEN_FOREIGN_SHARED",
                 "CQ configure_shared replaced configured delegate")
    status = configure_first.configure_shared(
      cq_h, null, RDMA_TRANSPORT_RC, identity,
      7, 3, 2'b1, 64'h71, fixture.engine);
    if (status == null || !status.ok())
      `uvm_error("CQ_CONFIGURE_THEN_SAME_SHARED", $sformatf(
                 "CQ configure_shared rejected identical delegate: %s",
                 status == null ? "<null>" : status.convert2string()))
    else begin
      shadow = null;
      status = configure_first.flush_shadow(shadow);
      if (status == null || !status.ok() || shadow == null ||
          shadow.sq_ci != 7 || shadow.rq_ci != 3 ||
          shadow.\sequence != 64'h71)
        `uvm_error("CQ_CONFIGURE_THEN_SHARED_ATOMIC",
                   "CQ foreign shared failure mutated existing configuration")
    end

    status = shared_first.configure_shared(
      cq_h, null, RDMA_TRANSPORT_RC, identity,
      9, 4, 2'b10, 64'h92, fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_DUAL_SHARED_FIRST", $sformatf(
                 "CQ shared-first setup failed: %s",
                 status == null ? "<null>" : status.convert2string()))
      return;
    end
    status = shared_first.configure(
      fixture.manager, fixture.binding, fixture.mem, fixture.scheduler,
      fixture.registry, 2us, foreign_engine);
    if (status == null || status.code != RDMA_SC_INVALID_ARGUMENT)
      `uvm_error("CQ_SHARED_THEN_FOREIGN_CONFIGURE",
                 "CQ configure replaced shared delegate")
    status = shared_first.configure(
      fixture.manager, fixture.binding, fixture.mem, fixture.scheduler,
      fixture.registry, 2us, fixture.engine);
    if (status == null || !status.ok())
      `uvm_error("CQ_SHARED_THEN_SAME_CONFIGURE",
                 "CQ configure rejected identical shared delegate")
    shadow = null;
    status = shared_first.flush_shadow(shadow);
    if (status == null || !status.ok() || shadow == null ||
        shadow.sq_ci != 9 || shadow.rq_ci != 4 ||
        shadow.\sequence != 64'h92)
      `uvm_error("CQ_SHARED_THEN_CONFIGURE_ATOMIC",
                 "CQ foreign configure failure mutated shared shadow")
  endtask

  // 功能：make_publish_cqe 根据真实 outstanding SQ post 构造显式 RC variant CQE，
  //   供 direct delegate 与 facade 在等价初态下执行同一业务事务。
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
    // 两个等价 fixture 均由默认 RC QP/CQ lifecycle 建立；显式保留 RC overlay
    // 与 send/SQ 标志，避免 facade 测试依赖 CQE model 的隐含初值。
    model.srfq = 1'b0;
    model.variant = RDMA_CQE_VARIANT_RC;
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
  // 失败/边界：任一 setup/configure/post/model/publish 失败立即报告并进入 epilogue；
  //   null model 拒绝必须保留精确 code/message，两个 fixture 各自独立完成清理。
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
    rdma_status direct_cleanup_status;
    rdma_status facade_cleanup_status;
    bit direct_polarity;
    bit facade_polarity;

    direct_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cq_direct_publish_fixture");
    facade_fixture = rdma_queue_data_engine_fixture::type_id::create(
      "cq_forward_publish_fixture");
    begin : delegate_equivalence_flow
      if (direct_fixture == null || facade_fixture == null) begin
        `uvm_error("CQ_DELEGATE_FIXTURE", "CQ equivalence fixture allocation failed")
        disable delegate_equivalence_flow;
      end
      // 正向等价性场景必须显式提供 CQC context backing；真实驱动的 CQ CI
      // 通过 host-memory shadow 回写，不再使用 CQ consumer MMIO doorbell。
      direct_fixture.setup(direct_status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1);
      facade_fixture.setup(facade_status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1);
      if (direct_status == null || !direct_status.ok() ||
          facade_status == null || !facade_status.ok()) begin
        `uvm_error("CQ_DELEGATE_SETUP", "CQ equivalence fixture setup failed")
        disable delegate_equivalence_flow;
      end
      facade = rdma_cq_engine::type_id::create("cq_publish_equivalence_facade");
      facade_status = facade.configure(
        facade_fixture.manager, facade_fixture.binding, facade_fixture.mem,
        facade_fixture.scheduler, facade_fixture.registry, 2us,
        facade_fixture.engine);
      if (facade_status == null || !facade_status.ok()) begin
        `uvm_error("CQ_DELEGATE_CONFIGURE", "CQ equivalence facade configure failed")
        disable delegate_equivalence_flow;
      end

    direct_fixture.engine.post_send(
      direct_fixture.make_send(64'h5151), direct_posted, direct_status);
    facade_fixture.engine.post_send(
      facade_fixture.make_send(64'h5151), facade_posted, facade_status);
    if (direct_status == null || !direct_status.ok() || direct_posted == null ||
        facade_status == null || !facade_status.ok() || facade_posted == null) begin
      `uvm_error("CQ_DELEGATE_POST", "CQ equivalence WQE post failed")
      disable delegate_equivalence_flow;
    end
    direct_status = direct_fixture.engine.query_runtime_producer_polarity(
      direct_fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, direct_polarity);
    facade_status = facade_fixture.engine.query_runtime_producer_polarity(
      facade_fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, facade_polarity);
    if (direct_status == null || !direct_status.ok() ||
        facade_status == null || !facade_status.ok()) begin
      `uvm_error("CQ_DELEGATE_POLARITY", "CQ equivalence polarity query failed")
      disable delegate_equivalence_flow;
    end
    make_publish_cqe(
      direct_fixture, direct_posted, direct_polarity, direct_model, direct_status);
    make_publish_cqe(
      facade_fixture, facade_posted, facade_polarity, facade_model, facade_status);
    if (direct_status == null || !direct_status.ok() || direct_model == null ||
        facade_status == null || !facade_status.ok() || facade_model == null) begin
      `uvm_error("CQ_DELEGATE_MODEL", "CQ equivalence model construction failed")
      disable delegate_equivalence_flow;
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
    end

    if (direct_fixture != null && direct_fixture.needs_cleanup()) begin
      direct_fixture.cleanup(direct_cleanup_status);
      if (direct_cleanup_status == null || !direct_cleanup_status.ok())
        `uvm_error("CQ_DELEGATE_DIRECT_CLEANUP",
                   direct_cleanup_status == null ?
                   "direct fixture cleanup returned null" :
                   direct_cleanup_status.convert2string())
    end
    if (facade_fixture != null && facade_fixture.needs_cleanup()) begin
      facade_fixture.cleanup(facade_cleanup_status);
      if (facade_cleanup_status == null || !facade_cleanup_status.ok())
        `uvm_error("CQ_DELEGATE_FACADE_CLEANUP",
                   facade_cleanup_status == null ?
                   "facade fixture cleanup returned null" :
                   facade_cleanup_status.convert2string())
    end
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
    bit initial_polarity;
    bit initial_polarity_found;
    int unsigned cq_used;
    int unsigned sq_used;
    bit cq_pending;
    bit sq_pending;

    fixture = rdma_queue_data_engine_fixture::type_id::create(
      $sformatf("cq_stride_%0d_fixture", cqe_size));
    begin : stride_flow
      if (fixture == null) begin
        `uvm_error("CQ_STRIDE_FACTORY", "stride fixture allocation failed")
        disable stride_flow;
      end
      // stride 正向场景验证真实 CQC shadow publication，因此 backing 不能省略。
      fixture.setup(status, 16, cqe_size, 16, 16, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("CQ_STRIDE_SETUP", status == null ?
                   "stride setup returned null" : status.convert2string())
        disable stride_flow;
      end
      initial_polarity = 1'b0;
      initial_polarity_found = 1'b0;
      foreach (fixture.cq.queue_plan.rings[i]) begin
        if (fixture.cq.queue_plan.rings[i] != null &&
            fixture.cq.queue_plan.rings[i].role == RDMA_QUEUE_ROLE_CQ_RING) begin
          initial_polarity =
            fixture.cq.queue_plan.rings[i].initial_polarity;
          initial_polarity_found = 1'b1;
        end
      end
      if (!initial_polarity_found) begin
        `uvm_error("CQ_STRIDE_LAYOUT", "CQ initial polarity is unavailable")
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
      if (status == null || !status.ok() || posted0 == null ||
          posted0.wr_id != 64'h6000 + cqe_size ||
          posted0.index != 0 || posted0.wrap) begin
        `uvm_error("CQ_STRIDE_POST0", "first stride WQE post failed")
        disable stride_flow;
      end
      status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (status == null || !status.ok() || polarity != initial_polarity) begin
        `uvm_error("CQ_STRIDE_POLARITY0",
                   "first CQ polarity differs from layout oracle")
        disable stride_flow;
      end
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
      if (status == null || !status.ok() || posted1 == null ||
          posted1.wr_id != 64'h7000 + cqe_size ||
          posted1.index != 1 || posted1.wrap) begin
        `uvm_error("CQ_STRIDE_POST1", "second stride WQE post failed")
        disable stride_flow;
      end
      status = fixture.engine.query_runtime_producer_polarity(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
      if (status == null || !status.ok() || polarity != initial_polarity) begin
        `uvm_error("CQ_STRIDE_POLARITY1",
                   "second CQ polarity differs from layout oracle")
        disable stride_flow;
      end
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
          completion.cqe == null ||
          completion.cqe.wr_id != 64'h6000 + cqe_size ||
          completion.cqe.qpn != fixture.qp.local_qp_id ||
          completion.cqe.wqe_index != 0 || completion.cqe.wqe_wrap ||
          completion.cqe.polarity != initial_polarity ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != 64'h6000 + cqe_size ||
          completion.released_slots[0].index != 0 ||
          completion.released_slots[0].wrap) begin
        `uvm_error("CQ_STRIDE_POLL0", $sformatf(
          "first stride completion did not poll: cqe_size=%0d status=%s",
          cqe_size, status == null ? "<null>" : status.convert2string()))
        disable stride_flow;
      end
      completion = null;
      facade.poll_cqe(fixture.cq.handle, completion, status);
      if (status == null || !status.ok() || completion == null ||
          completion.cqe == null ||
          completion.cqe.wr_id != 64'h7000 + cqe_size ||
          completion.cqe.qpn != fixture.qp.local_qp_id ||
          completion.cqe.wqe_index != 1 || completion.cqe.wqe_wrap ||
          completion.cqe.polarity != initial_polarity ||
          completion.released_slots.size() != 1 ||
          completion.released_slots[0] == null ||
          completion.released_slots[0].wr_id != 64'h7000 + cqe_size ||
          completion.released_slots[0].index != 1 ||
          completion.released_slots[0].wrap)
        `uvm_error("CQ_STRIDE_POLL1", "second stride completion did not poll")
      status = fixture.engine.query_runtime_occupancy(
        fixture.cq.handle, RDMA_QUEUE_RUNTIME_CQ, cq_used, cq_pending);
      if (status == null || !status.ok() || cq_used != 0 || cq_pending) begin
        `uvm_error("CQ_STRIDE_CQ_DRAIN", "stride CQ occupancy did not return to zero")
        disable stride_flow;
      end
      status = fixture.engine.query_runtime_occupancy(
        fixture.qp.handle, RDMA_QUEUE_RUNTIME_SQ, sq_used, sq_pending);
      if (status == null || !status.ok() || sq_used != 0 || sq_pending)
        `uvm_error("CQ_STRIDE_SQ_DRAIN", "stride SQ occupancy did not return to zero")
    end
    if (fixture != null && fixture.needs_cleanup()) begin
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

  // 功能：配置 CQ facade，验证三个普通入口的 operation envelope、one-shot 配置、
  //   CQE publish/poll/CI、shared shadow live-authority replay，以及 producer 等价性。
  // 输入/输出及副作用：phase 为输入；task 管理 objection，驱动真实 CQ runtime 和
  //   hostile seam，通过断言暴露 status/result/counter，并在 epilogue 释放 fixture。
  // 失败/边界：未配置入口必须清空 sentinel；重复配置、stale/inactive Function、
  //   CQE owner/QPN 错误、null/失败 delegate 均不得发布可信结果；reset epoch 漂移
  //   还必须保持 replay caller/cache/count 不变。
  task run_phase(uvm_phase phase);
    rdma_queue_data_engine_fixture fixture;
    rdma_cq_engine facade;
    rdma_cq_engine unconfigured_facade;
    rdma_cq_engine inactive_facade;
    rdma_queue_post_result posted;
    rdma_queue_completion_result completion;
    rdma_queue_device_publish_result published;
    rdma_hw_cqe_model cqe;
    rdma_status status;
    rdma_status cleanup_status;
    rdma_status stale_status;
    rdma_cq_hostile_facade hostile_facade;
    rdma_queue_completion_result hostile_completion;
    rdma_cq_shadow_snapshot live_shadow;
    rdma_cq_shadow_snapshot stale_shadow_reference;
    rdma_handle stale_shadow_handle;
    rdma_handle shared_cq_handle;
    rdma_function_identity shared_identity;
    int unsigned poll_calls_before_stale;
    int unsigned publish_calls_before_stale;
    int unsigned resize_calls_before_stale;
    rdma_reset_epoch_t saved_reset_epoch;
    longint unsigned saved_function_uid;
    bit producer_polarity;
    bit shadow_replay_ready;

    phase.raise_objection(this);
    fixture = rdma_queue_data_engine_fixture::type_id::create("cq_fixture");
    // 中文设计：主流程的任一失败都跳到同一 cleanup epilogue，
    // 避免新增 Function/PD/AEQ ownership 后仍沿用旧的早退路径。
    begin : cq_flow
      if (fixture == null) begin
        `uvm_error("CQ_FIXTURE", "queue-data fixture allocation failed")
        disable cq_flow;
      end
    // 主 CQ facade 流程覆盖真实 shadow CI 提交；缺失 backing 的拒绝路径由
    // 专门的 device-publish/context-contract 测试负责，避免混淆两种契约。
    fixture.setup(status, 16, RDMA_CQE_BYTES, 16, 16, 1'b1);
      if (status == null || !status.ok()) begin
        `uvm_error("CQ_FIXTURE", "queue-data fixture setup failed")
        disable cq_flow;
      end

    // RED：CQ facade 必须拒绝非 ACTIVE Function binding；validate() 返回 OK
    // 不能绕过显式 state 门禁或保存不可用的 delegate。
    inactive_facade = rdma_cq_engine::type_id::create("cq_inactive_facade");
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    status = inactive_facade.configure(fixture.manager, fixture.binding,
                                        fixture.mem, fixture.scheduler,
                                        fixture.registry, 2us, fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_CONFIGURE_ACTIVE_GATE",
                 "CQ facade accepted a non-ACTIVE Function binding")
    fixture.binding.state = RDMA_BIND_ACTIVE;

    facade = rdma_cq_engine::type_id::create("cq_facade");
    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_CONFIGURE", "CQ facade configuration failed")
      disable cq_flow;
    end

    // RED/GREEN：hostile CQ seam 同时覆盖 null status 与显式失败 status；两者
    // 都携带未认证 result，facade 必须 fail-closed 且保留显式失败错误。
    hostile_facade = rdma_cq_hostile_facade::type_id::create("cq_hostile_facade");
    status = hostile_facade.configure(
      fixture.manager, fixture.binding, fixture.mem, fixture.scheduler,
      fixture.registry, 2us, fixture.engine);
    if (status == null || !status.ok()) begin
      `uvm_error("CQ_HOSTILE_CONFIG", "CQ hostile facade configuration failed")
      disable cq_flow;
    end
    hostile_completion = null;
    hostile_facade.poll_cqe(fixture.cq.handle, hostile_completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ delegate poll_cqe returned null status" ||
        hostile_completion != null)
      `uvm_error("CQ_NULL_POLL_DELEGATE",
                 "CQ facade exposed null-status poll result")

    hostile_facade.publish_cqe(fixture.cq.handle, null, published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ delegate publish_cqe returned null status" ||
        published != null)
      `uvm_error("CQ_NULL_PUBLISH_DELEGATE",
                 "CQ facade exposed null-status publish result")

    status = hostile_facade.resize(fixture.cq.handle, 16, RDMA_CQE_BYTES);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ delegate resize_cq returned null status")
      `uvm_error("CQ_NULL_RESIZE_DELEGATE",
                 "CQ facade exposed null-status resize result")

    hostile_facade.inject_failure_status = 1'b1;
    hostile_completion = null;
    hostile_facade.poll_cqe(fixture.cq.handle, hostile_completion, status);
    if (status == null || status != hostile_facade.last_returned_status ||
        status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        status.message != "injected CQ poll failure" || hostile_completion != null)
      `uvm_error("CQ_FAILURE_POLL_DELEGATE",
                 "CQ facade did not clear failed poll result")
    published = null;
    hostile_facade.publish_cqe(fixture.cq.handle, null, published, status);
    if (status == null || status != hostile_facade.last_returned_status ||
        status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        status.message != "injected CQ publish failure" || published != null)
      `uvm_error("CQ_FAILURE_PUBLISH_DELEGATE",
                 "CQ facade did not clear failed publish result")
    status = hostile_facade.resize(fixture.cq.handle, 16, RDMA_CQE_BYTES);
    if (status == null || status != hostile_facade.last_returned_status ||
        status.code != RDMA_SC_UNKNOWN_HW_ERROR ||
        status.message != "injected CQ resize failure")
      `uvm_error("CQ_FAILURE_RESIZE_DELEGATE",
                 "CQ facade did not preserve failed resize status")

    status = facade.configure(fixture.manager, fixture.binding, fixture.mem,
                              fixture.scheduler, fixture.registry, 2us,
                              fixture.engine);
    if (status == null || status.code != RDMA_SC_INVALID_STATE)
      `uvm_error("CQ_CONFIGURE_GATE", "configured CQ facade accepted reconfiguration")

    // RED：frozen Function coordinates are the stale-authority source of truth;
    // report STALE_GENERATION before binding.validate() can classify mirror drift.
    saved_function_uid = fixture.binding.function_uid;
    fixture.binding.function_uid = saved_function_uid ^ 64'h1;
    completion = null;
    facade.poll_cqe(fixture.cq.handle, completion, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_STALE_GENERATION ||
        completion != null)
      `uvm_error("CQ_STALE_ORDER",
                 "CQ facade did not report stale authority before validation")
    fixture.binding.function_uid = saved_function_uid;

    // RED：已配置 CQ facade 在 binding 失活后必须阻断 poll，不能因为
    // frozen UID/generation/epoch 仍相同而继续读取 CQ ring。
    fixture.binding.state = RDMA_BIND_DISCOVERED;
    completion = null;
    facade.poll_cqe(fixture.cq.handle, completion, stale_status);
    if (stale_status == null || stale_status.code != RDMA_SC_INVALID_STATE ||
        completion != null)
      `uvm_error("CQ_LIVE_ACTIVE_GATE",
                 "CQ facade continued after Function binding became inactive")
    fixture.binding.state = RDMA_BIND_ACTIVE;

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
    // cq_flow 使用 fixture.setup() 的基础 RC QP；publish facade 仍须接收显式
    // RC variant，而不是把 model 构造默认值当作 route authority。
    cqe.srfq = 1'b0;
    cqe.variant = RDMA_CQE_VARIANT_RC;
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

    // 功能：以独立、从未 configure 的 facade 验证 poll/publish/resize 共享配置门禁。
    // 输入/输出及副作用：使用 fixture handle 和 null model，预置两个 typed sentinel；
    //   只观察公开 result/status，不访问 delegate、backing、runtime 或 shadow。
    // 失败边界：三入口都必须返回固定 INVALID_STATE/message，poll/publish 清空 sentinel；
    //   任一成功、消息漂移或残留结果都表示 operation envelope 被绕过。
    unconfigured_facade = rdma_cq_engine::type_id::create("idle_cq_facade");
    completion = rdma_queue_completion_result::type_id::create(
      "cq_unconfigured_poll_result_sentinel");
    unconfigured_facade.poll_cqe(fixture.cq.handle, completion, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ facade is not configured" || completion != null)
      `uvm_error("CQ_POLL_UNCONFIGURED", "unconfigured CQ facade polled")

    published = rdma_queue_device_publish_result::type_id::create(
      "cq_unconfigured_publish_result_sentinel");
    unconfigured_facade.publish_cqe(fixture.cq.handle, null, published, status);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ facade is not configured" || published != null)
      `uvm_error("CQ_PUBLISH_UNCONFIGURED", "unconfigured CQ facade published")

    status = unconfigured_facade.resize(
      fixture.cq.handle, 16, RDMA_CQE_BYTES);
    if (status == null || status.code != RDMA_SC_INVALID_STATE ||
        status.message != "CQ facade is not configured")
      `uvm_error("CQ_RESIZE_UNCONFIGURED", "unconfigured CQ facade resized")

    check_publish_delegate_equivalence();
    check_dual_configuration_delegate_ownership(fixture);
    check_variable_cqe_strides();

    // 中文设计：shared identity 使用非零冻结 epoch，普通 facade authority 仍保存
    // 当前 binding epoch；首次 flush 后推进 live binding，replay 必须先被普通
    // configure 的 authority gate 拒绝，不能仅凭 caller/cache 字段匹配成功。
    shadow_replay_ready = 1'b0;
    shared_identity = fixture.binding.function_identity_snapshot();
    if (shared_identity == null) begin
      `uvm_error("CQ_SHADOW_RESET_SETUP",
                 "CQ shared identity snapshot is unavailable")
    end
    else begin
      shared_identity.reset_epoch = fixture.binding.function_reset_epoch() + 1;
      // CQ lifecycle handles carry the manager's kind-prefix incarnation ID
      // (for example 0x3xxxxxxx), while configure_shared() consumes the
      // hardware-projected 21-bit local CQ number.  Build that detached
      // projection explicitly so this test exercises the shadow contract
      // instead of passing a manager handle through a context-width gate.
      shared_cq_handle = rdma_handle::type_id::create(
        "cq_shared_projected_handle");
      if (shared_cq_handle == null) begin
        `uvm_error("CQ_SHADOW_RESET_SETUP",
                   "CQ shared projected handle allocation failed")
      end
      else begin
        shared_cq_handle.kind = RDMA_RESOURCE_CQ;
        shared_cq_handle.function_uid = shared_identity.function_uid;
        shared_cq_handle.generation = shared_identity.generation;
        shared_cq_handle.object_id = fixture.cq.local_cq_id;
        status = facade.configure_shared(
          shared_cq_handle, null, RDMA_TRANSPORT_RC, shared_identity,
          14, 6, 2'b10, 64'h146, fixture.engine);
        if (status == null || !status.ok())
          `uvm_error("CQ_SHADOW_RESET_SETUP",
                     $sformatf("CQ shared replay gate configuration failed: %s",
                               status == null ? "<null>" : status.convert2string()))
        else begin
          live_shadow = null;
          status = facade.flush_shadow(live_shadow);
          if (status == null || !status.ok() || live_shadow == null ||
              live_shadow.sq_ci != 14 || live_shadow.rq_ci != 6 ||
              live_shadow.\sequence != 64'h146 ||
              facade.shadow_flush_count != 1)
            `uvm_error("CQ_SHADOW_RESET_SETUP",
                       "CQ shared replay gate first flush failed")
          else begin
            live_shadow.sq_ci = 909;
            live_shadow.\sequence = 64'h909;
            stale_shadow_reference = live_shadow;
            stale_shadow_handle = live_shadow.cq_h;
            shadow_replay_ready = 1'b1;
          end
        end
      end
    end

    // reset epoch 只能单调前进。先释放主 fixture 持有的生命周期资源，再把漂移
    // 场景放在本流程末尾，避免测试为了继续执行而尝试回退 epoch。
    if (fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("CQ_CLEANUP_BEFORE_RESET_DRIFT", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end

    // RED/GREEN：reset epoch 漂移必须在三个 CQ delegate seam 前阻断；调用计数
    //   保持不变，证明没有 ring 读取、设备发布或 resize geometry 副作用。
    poll_calls_before_stale = hostile_facade.poll_calls;
    publish_calls_before_stale = hostile_facade.publish_calls;
    resize_calls_before_stale = hostile_facade.resize_calls;
    saved_reset_epoch = fixture.binding.function_reset_epoch();
    status = fixture.advance_binding_reset_epoch(saved_reset_epoch + 1);
    if (status == null || !status.ok())
      `uvm_error("CQ_RESET_EPOCH_SETUP", "CQ reset epoch drift setup failed")
    else begin
      hostile_completion = rdma_queue_completion_result::type_id::create(
        "cq_stale_poll_result_sentinel");
      hostile_facade.poll_cqe(fixture.cq.handle, hostile_completion, status);
      if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
          hostile_completion != null ||
          hostile_facade.poll_calls != poll_calls_before_stale)
        `uvm_error("CQ_RESET_EPOCH_GATE",
                   "CQ facade called poll delegate after reset epoch drift")

      published = rdma_queue_device_publish_result::type_id::create(
        "cq_stale_publish_result_sentinel");
      hostile_facade.publish_cqe(
        fixture.cq.handle, null, published, status);
      if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
          published != null ||
          hostile_facade.publish_calls != publish_calls_before_stale)
        `uvm_error("CQ_RESET_EPOCH_PUBLISH_GATE",
                   "CQ facade called publish delegate after reset epoch drift")

      status = hostile_facade.resize(
        fixture.cq.handle, 16, RDMA_CQE_BYTES);
      if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
          hostile_facade.resize_calls != resize_calls_before_stale)
        `uvm_error("CQ_RESET_EPOCH_RESIZE_GATE",
                   "CQ facade called resize delegate after reset epoch drift")

      if (shadow_replay_ready) begin
        status = facade.flush_shadow(live_shadow);
        if (status == null || status.code != RDMA_SC_STALE_GENERATION ||
            live_shadow != stale_shadow_reference ||
            live_shadow.cq_h != stale_shadow_handle ||
            live_shadow.sq_ci != 909 || live_shadow.\sequence != 64'h909 ||
            facade.shadow_flush_count != 1)
          `uvm_error("CQ_RESET_EPOCH_SHADOW_GATE",
                     "CQ facade published cached shadow after reset epoch drift")
      end
    end
    end

    if (fixture != null && fixture.needs_cleanup()) begin
      fixture.cleanup(cleanup_status);
      if (cleanup_status == null || !cleanup_status.ok())
        `uvm_error("CQ_CLEANUP", cleanup_status == null ?
                   "fixture cleanup returned null" :
                   cleanup_status.convert2string())
    end

    phase.drop_objection(this);
  endtask
endclass
