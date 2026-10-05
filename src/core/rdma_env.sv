// 目录：核心执行层 src/core/rdma_env.sv。
// 职责：组合 RDMA 自有 codec/resource/responder 对象，经 UVM config_db 接收抽象 adapter 引用。
// 依赖：rdma_env_config、responder registry、rdma_adapter_pkg、model identity；不创建外部 pcie_env/axis_env。
// 所有权与生命周期：env 拥有内部 registry/config/codec/resource；pcie、host_mem、net 为非拥有
//   句柄，释放由上层 adapter 环境负责。

class rdma_env_event_route extends uvm_object;
  `uvm_object_utils(rdma_env_event_route)
  rdma_function_identity target_function;
  int unsigned vector;
  int unsigned generation;

  // 功能：构造未绑定目标的事件路由对象。
  // 输入/输出及副作用：name 为 UVM 名；target_function 置 null，vector/generation 置 0。
  // 失败/边界：不校验，发布前须 validate() 通过。
  function new(string name = "rdma_env_event_route");
    super.new(name);
    target_function = null;
    vector = 0;
    generation = 0;
  endfunction

  // 功能：校验事件携带完整 target Function、vector 和 generation，阻止裸 vector 串线。
  // 输入/输出及副作用：只读字段，返回 rdma_status，无副作用。
  // 失败/边界：target_function 为空/校验失败/generation 为零返回 INVALID_ARGUMENT 或
  //   INVALID_STATE，generation 与 Function 不一致返回 STALE_GENERATION；vector 不做范围拒绝。
  function rdma_status validate();
    rdma_status identity_status;

    if (target_function == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "event target Function is missing"
      );
    identity_status = target_function.validate();
    if (identity_status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "event target Function validation returned null"
      );
    if (!identity_status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "event target Function is invalid"
      );
    if (generation == 0 || generation != target_function.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "event generation is stale");
    return rdma_status::success();
  endfunction
endclass

// 别名便于中断/队列分析器使用统一语义名称；类型仍携带完整 Function authority。
typedef rdma_env_event_route rdma_env_event;

class rdma_env extends uvm_env;
  `uvm_component_utils(rdma_env)

  rdma_pcie_api pcie;
  rdma_host_mem_api host_mem;
  rdma_net_api net;
  rdma_responder_registry responders;
  rdma_codec_registry codecs;
  rdma_resource_manager resources;
  rdma_queue_data_engine queue_data;
  rdma_sq_engine sq;
  rdma_rq_engine rq;
  rdma_cq_engine cq;
  rdma_eq_engine eq;
  rdma_env_config config_snapshot;
  rdma_function_identity function_identity_snapshot;
  rdma_function_binding function_binding_snapshot;
  protected string m_capability[string];
  protected int unsigned m_pending_count;

  // 功能：构造 rdma_env，初始化 adapter 借用句柄、内部组件句柄和 pending 计数。
  // 输入/输出及副作用：name、parent 为 UVM 层级参数；不创建外部组件。
  // 失败/边界：adapter 缺失到 build_phase 才处理；未构建完成的 env 不可用于数据路径。
  function new(string name = "rdma_env", uvm_component parent = null);
    super.new(name, parent);
    pcie = null;
    host_mem = null;
    net = null;
    responders = null;
    codecs = null;
    resources = null;
    queue_data = null;
    sq = null;
    rq = null;
    cq = null;
    eq = null;
    config_snapshot = null;
    function_identity_snapshot = null;
    function_binding_snapshot = null;
    m_pending_count = 0;
    m_capability["pcie"] = "disabled";
    m_capability["host_mem"] = "disabled";
    m_capability["net"] = "disabled";
  endfunction

  // 功能：从 config_db 取配置与抽象 adapter，处理 required/optional 缺失，冻结 env 组件。
  // 输入/输出及副作用：读取 cfg、adapter、Function identity/binding，建立 detached snapshot
  //   并调用 configure；adapter 句柄仍归注入方。
  // 失败/边界：cfg 缺失、snapshot 失败、required adapter 缺失、null identity/binding 或
  //   configure 失败均 uvm_fatal 并返回；optional adapter 缺失仅记为 passive/disabled。
  function void build_phase(uvm_phase phase);
    rdma_env_config supplied_cfg;
    rdma_function_identity supplied_identity;
    rdma_function_binding supplied_binding;
    bit found;
    rdma_status status;
    super.build_phase(phase);
    if (!uvm_config_db#(rdma_env_config)::get(this, "", "cfg", supplied_cfg) &&
        !uvm_config_db#(rdma_env_config)::get(this, "", "rdma_env_config", supplied_cfg))
      begin `uvm_fatal("RDMA_ENV_CFG", "rdma_env_config is missing from uvm_config_db"); return; end
    if (supplied_cfg == null)
      begin `uvm_fatal("RDMA_ENV_CFG", "rdma_env_config handle is null"); return; end
    config_snapshot = rdma_env_config::type_id::create("config_snapshot");
    if (config_snapshot == null) begin
      `uvm_fatal("RDMA_ENV_CFG", "rdma_env_config snapshot allocation failed")
      return;
    end
    config_snapshot.copy(supplied_cfg);

    found = uvm_config_db#(rdma_pcie_api)::get(this, "", "pcie", pcie);
    found = found && (pcie != null);
    if (!found) found = uvm_config_db#(rdma_pcie_api)::get(this, "", "pcie_api", pcie) && (pcie != null);
    if (config_snapshot.pcie_required && !found)
      begin `uvm_fatal("RDMA_ENV_PCIE", "required PCIe adapter is missing"); return; end
    m_capability["pcie"] = config_snapshot.pcie_enabled ? (found ? "enabled" : "passive") : "disabled";
    found = uvm_config_db#(rdma_host_mem_api)::get(this, "", "host_mem", host_mem);
    found = found && (host_mem != null);
    if (!found) found = uvm_config_db#(rdma_host_mem_api)::get(this, "", "host_mem_api", host_mem) && (host_mem != null);
    if (config_snapshot.host_mem_required && !found)
      begin `uvm_fatal("RDMA_ENV_HOST", "required host-memory adapter is missing"); return; end
    m_capability["host_mem"] = config_snapshot.host_mem_enabled ? (found ? "enabled" : "passive") : "disabled";
    found = uvm_config_db#(rdma_net_api)::get(this, "", "net", net);
    found = found && (net != null);
    if (!found) found = uvm_config_db#(rdma_net_api)::get(this, "", "net_api", net) && (net != null);
    if (config_snapshot.net_required && !found)
      begin `uvm_fatal("RDMA_ENV_NET", "required network adapter is missing"); return; end
    m_capability["net"] = config_snapshot.net_enabled ? (found ? "enabled" : "passive") : "disabled";

    if (uvm_config_db#(rdma_function_identity)::get(this, "", "function_identity", supplied_identity)) begin
      if (supplied_identity == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "injected Function identity handle is null")
        return;
      end
      function_identity_snapshot = rdma_function_identity::type_id::create("function_identity_snapshot");
      if (function_identity_snapshot == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "Function identity snapshot allocation failed")
        return;
      end
      function_identity_snapshot.copy(supplied_identity);
    end else if (config_snapshot.function_identity != null) begin
      function_identity_snapshot = rdma_function_identity::type_id::create("function_identity_snapshot");
      if (function_identity_snapshot == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "Function identity snapshot allocation failed")
        return;
      end
      function_identity_snapshot.copy(config_snapshot.function_identity);
    end
    if (uvm_config_db#(rdma_function_binding)::get(this, "", "function_binding", supplied_binding)) begin
      if (supplied_binding == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "injected Function binding handle is null")
        return;
      end
      function_binding_snapshot = rdma_function_binding::type_id::create("function_binding_snapshot");
      if (function_binding_snapshot == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "Function binding snapshot allocation failed")
        return;
      end
      function_binding_snapshot.copy(supplied_binding);
      if (function_identity_snapshot == null)
        function_identity_snapshot = function_binding_snapshot.identity_snapshot();
    end else if (config_snapshot.function_binding != null) begin
      function_binding_snapshot = rdma_function_binding::type_id::create("function_binding_snapshot");
      if (function_binding_snapshot == null) begin
        `uvm_fatal("RDMA_ENV_CONFIG", "Function binding snapshot allocation failed")
        return;
      end
      function_binding_snapshot.copy(config_snapshot.function_binding);
      if (function_identity_snapshot == null)
        function_identity_snapshot = function_binding_snapshot.identity_snapshot();
    end
    if (function_identity_snapshot != null && function_binding_snapshot != null &&
        !function_identity_snapshot.same_incarnation(
          function_binding_snapshot.identity_snapshot()))
      begin
        `uvm_fatal("RDMA_ENV_CONFIG", "injected Function identity and binding disagree")
        return;
      end
    if (function_identity_snapshot != null)
      config_snapshot.function_identity = function_identity_snapshot;
    if (function_binding_snapshot != null)
      config_snapshot.function_binding = function_binding_snapshot;
    status = configure(config_snapshot);
    if (status == null) begin
      `uvm_fatal("RDMA_ENV_CONFIG", "rdma_env configure returned null status")
      return;
    end
    if (!status.ok()) begin
      `uvm_fatal("RDMA_ENV_CONFIG", status.message)
      return;
    end
  endfunction

  // 功能：按 cfg 构造候选 responder registry、codec/resource manager 和 queue engine，
  //   逐项 claim region 并 seal，候选全部就绪后一次提交。
  // 输入/输出及副作用：成功时替换 env 自有 registry、engine、config 和 Function 快照；
  //   外部 adapter 引用不转移。
  // 失败/边界：cfg 为空/校验失败、region claim 冲突/溢出、候选创建失败或 seal 失败时返回
  //   status；发布点前旧组合保持不变。
  function rdma_status configure(rdma_env_config cfg);
    rdma_env_config candidate_cfg;
    rdma_responder_registry candidate_registry;
    rdma_codec_registry candidate_codecs;
    rdma_resource_manager candidate_resources;
    rdma_responder_region source_region;
    rdma_responder_region claimed_region;
    rdma_status status;
    rdma_queue_data_engine candidate_queue_data;
    rdma_sq_engine candidate_sq;
    rdma_rq_engine candidate_rq;
    rdma_cq_engine candidate_cq;
    rdma_eq_engine candidate_eq;
    rdma_function_identity candidate_identity_snapshot;
    rdma_function_binding candidate_binding_snapshot;
    if (cfg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma_env_config is null");
    status = rdma_status::nonnull(
      cfg.validate(),
      "rdma_env configuration validation returned null"
    );
    if (!status.ok())
      return status;
    candidate_cfg = rdma_env_config::type_id::create("config_candidate");
    if (candidate_cfg == null) return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "config snapshot allocation failed");
    candidate_cfg.copy(cfg);
    candidate_registry = rdma_responder_registry::type_id::create("responders");
    candidate_codecs = rdma_codec_registry::type_id::create("codecs");
    candidate_resources = rdma_resource_manager::type_id::create("resources");
    if (candidate_registry == null || candidate_codecs == null || candidate_resources == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "RDMA core object allocation failed");
    foreach (cfg.responder_regions[index]) begin
      source_region = cfg.responder_regions[index];
      status = rdma_status::nonnull(
        candidate_registry.claim(source_region.domain, source_region.mode,
          source_region.route, source_region.base,
          source_region.size, source_region.owner,
          claimed_region),
        "responder registry claim returned null status"
      );
      if (!status.ok())
        return status;
    end
    status = rdma_status::nonnull(
      candidate_registry.seal(),
      "responder registry seal returned null status"
    );
    if (!status.ok())
      return status;
    candidate_queue_data = rdma_queue_data_engine::type_id::create("queue_data");
    candidate_sq = rdma_sq_engine::type_id::create("sq");
    candidate_rq = rdma_rq_engine::type_id::create("rq");
    candidate_cq = rdma_cq_engine::type_id::create("cq");
    candidate_eq = rdma_eq_engine::type_id::create("eq");
    if (candidate_queue_data == null || candidate_sq == null || candidate_rq == null || candidate_cq == null || candidate_eq == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue engine anchor allocation failed");

    // Function identity/binding 快照也须在主组合提交前完成，否则快照失败会留下
    // 半新半旧的 env；候选失败只丢弃本地候选。
    if (candidate_cfg.function_identity != null) begin
      candidate_identity_snapshot = rdma_function_identity::type_id::create(
        "function_identity_snapshot");
      if (candidate_identity_snapshot == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function identity snapshot allocation failed"
        );
      candidate_identity_snapshot.copy(candidate_cfg.function_identity);
    end
    if (candidate_cfg.function_binding != null) begin
      candidate_binding_snapshot = rdma_function_binding::type_id::create(
        "function_binding_snapshot");
      if (candidate_binding_snapshot == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function binding snapshot allocation failed"
        );
      candidate_binding_snapshot.copy(candidate_cfg.function_binding);
    end

    responders = candidate_registry;
    codecs = candidate_codecs;
    resources = candidate_resources;
    queue_data = candidate_queue_data;
    sq = candidate_sq;
    rq = candidate_rq;
    cq = candidate_cq;
    eq = candidate_eq;
    config_snapshot = candidate_cfg;
    function_identity_snapshot = candidate_identity_snapshot;
    function_binding_snapshot = candidate_binding_snapshot;
    return rdma_status::success();
  endfunction

  // 功能：把上层 fixture 创建的 resource manager、binding、host-memory、doorbell、codec
  //   注入 env 自有 queue-data engine。
  // 输入/输出及副作用：各依赖及 timeout 为输入，可选 context_api 仅提供 QPC shadow 读取；
  //   成功时 queue_data 保存非拥有引用并建立数据路径。
  // 失败/边界：env 未 configure、依赖为空、timeout 为零、Function 快照不一致或
  //   queue_data.configure 失败时返回错误；已有 attachment 的回滚语义由 queue_data 保持。
  function rdma_status bind_data_path(
    rdma_resource_manager resource_manager,
    rdma_function_binding function_binding,
    rdma_host_mem_api memory,
    rdma_doorbell_scheduler scheduler,
    rdma_codec_registry codec_registry,
    time timeout,
    rdma_context_backing_api context_api = null
  );
    rdma_status status;
    rdma_function_identity identity;

    if (queue_data == null || config_snapshot == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "rdma_env is not configured");
    if (resource_manager == null || function_binding == null || memory == null ||
        scheduler == null || codec_registry == null || timeout == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "rdma_env data-path dependency is missing");
    identity = function_binding.identity_snapshot();
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "rdma_env data-path Function identity is invalid");
    status = identity.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "rdma_env data-path Function identity validation returned null"
      );
    if (!status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "rdma_env data-path Function identity is invalid"
      );
    if (function_identity_snapshot != null &&
        !function_identity_snapshot.same_incarnation(identity))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "rdma_env data-path Function identity is stale");
    status = queue_data.configure(resource_manager, function_binding, memory,
                                  scheduler, codec_registry, timeout,
                                  context_api);
    return status == null ?
      rdma_status::make(RDMA_SC_INVALID_STATE,
                        "rdma_env data-path configure returned null status") : status;
  endfunction

  // 功能：把发送请求转发到已绑定的 queue-data engine。
  // 输入/输出及副作用：request 输入，result/status 输出；成功时推进 SQ producer 并写 backing。
  // 失败/边界：未绑定 data path、authority 失配或无 credit 时返回错误，不发布半成品 result。
  task automatic post_send(
    rdma_post_send_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = null;
    if (queue_data == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "rdma_env data path is not bound");
      return;
    end
    queue_data.post_send(request, result, status);
  endtask

  // 功能：把接收请求转发到已绑定的 queue-data engine。
  // 输入/输出及副作用：request 输入，result/status 输出；成功时推进 RQ producer 并写 backing。
  // 失败/边界：未绑定 data path、QP/SGE authority 失配或无 credit 时返回错误，不推进 producer。
  task automatic post_recv(
    rdma_post_recv_req request,
    output rdma_queue_post_result result,
    output rdma_status status
  );
    result = null;
    if (queue_data == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "rdma_env data path is not bound");
      return;
    end
    queue_data.post_recv(request, result, status);
  endtask

  // 功能：从已绑定的 queue-data engine 消费 CQE。
  // 输入/输出及副作用：cq_h、timeout 输入，completion/status 输出；成功时推进 CQ consumer，
  //   释放对应 SQ/RQ slot 和 credit。
  // 失败/边界：未绑定 data path、CQ authority 失配或超时返回错误，completion 置空。
  task automatic poll_completion(
    rdma_handle cq_h,
    time timeout,
    output rdma_queue_completion_result completion,
    output rdma_status status
  );
    completion = null;
    if (queue_data == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "rdma_env data path is not bound");
      return;
    end
    queue_data.poll_cqe(cq_h, timeout, completion, status);
  endtask

  // 功能：查询 adapter capability 的 enabled/disabled/passive 状态，放入 status.message。
  // 输入/输出及副作用：capability 输入；返回新状态对象，不修改 env。
  // 失败/边界：未知 capability 返回 INVALID_ARGUMENT。
  function rdma_status capability_status(string capability);
    if (!m_capability.exists(capability))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown capability");
    return rdma_status::success(m_capability[capability]);
  endfunction

  // 功能：返回 pending 数量。
  // 输入/输出及副作用：只读本地计数。
  // 失败/边界：无。
  function int unsigned pending_count();
    return m_pending_count;
  endfunction

  // 功能：登记一个待完成事件，pending 计数加一。
  // 输入/输出及副作用：仅递增本地计数。
  // 失败/边界：计数达 32'hffff_ffff 时保持饱和。
  function void begin_pending();
    if (m_pending_count != 32'hffff_ffff) m_pending_count++;
  endfunction

  // 功能：完成一个待完成事件，pending 计数减一。
  // 输入/输出及副作用：仅更新本地计数。
  // 失败/边界：计数为零时为 no-op，避免下溢。
  function void end_pending();
    if (m_pending_count != 0) m_pending_count--;
  endfunction

  // 功能：校验并接受带完整 Function/vector/generation 的事件路由。
  // 输入/输出及副作用：成功时 pending_count 加一，失败不改计数。
  // 失败/边界：空事件、身份不一致或 generation 过期返回错误，拒绝裸 vector 事件。
  function rdma_status route_event(rdma_env_event_route event_route);
    rdma_status status;
    if (event_route == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "event route is null");
    status = rdma_status::nonnull(
      event_route.validate(),
      "event route validation returned null status"
    );
    if (!status.ok())
      return status;
    if (function_identity_snapshot != null &&
        !function_identity_snapshot.same_incarnation(event_route.target_function))
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "event target Function is not env owner");
    begin_pending();
    return rdma_status::success();
  endfunction
endclass
