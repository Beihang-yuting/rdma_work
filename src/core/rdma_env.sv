// 目录：核心执行层 src/core/rdma_env.sv。
// 职责：组合 RDMA 自有 codec/resource/responder 对象，并通过 UVM config_db 接收抽象 adapter 引用。
// 依赖：依赖 rdma_env_config、responder registry、rdma_adapter_pkg 和 model identity；不依赖或创建外部 pcie_env/axis_env。
// 所有权与生命周期：env 拥有内部 registry/config/codec/resource 对象；pcie、host_mem、net 仅为非拥有句柄，释放由上层 adapter 环境负责。

class rdma_env_event_route extends uvm_object;
  `uvm_object_utils(rdma_env_event_route)
  rdma_function_identity target_function;
  int unsigned vector;
  int unsigned generation;

  // 功能：构造一个尚未绑定目标的事件路由对象，为后续 route_event 提供可填充的
  //   Function、vector 和 generation 字段。
  // 输入/输出及副作用：name 为 UVM 对象名输入；函数把 target_function 置 null、
  //   vector/generation 置 0 并返回 void，不访问 env 账本，也不取得外部资源所有权。
  // 失败/边界：构造函数不执行身份或向量范围校验；调用方在发布前必须让 validate()
  //   通过，vector=0 本身不会在本函数中被拒绝。
  function new(string name = "rdma_env_event_route");
    super.new(name);
    target_function = null;
    vector = 0;
    generation = 0;
  endfunction

  // 功能：校验事件携带完整 target Function、vector 和 generation，阻止裸 vector 串线。
  // 输入/输出及副作用：只读 target_function、vector 和 generation，返回 rdma_status；
  //   不更新队列、scoreboard、pending 计数或外部 adapter。
  // 失败/边界：target_function 为空、其 validate() 返回 null/失败、generation 为零或
  //   与 target_function.generation 不一致时分别返回 INVALID_ARGUMENT、INVALID_STATE
  //   或 STALE_GENERATION；vector 当前只被携带，不单独做范围拒绝。
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

  // 功能：构造 rdma_env，建立空 adapter 引用、内部组件句柄和 pending 计数。
  // 输入/输出及副作用：name、parent 为 UVM 层级参数；函数初始化 adapter 借用句柄、
  //   内部组件句柄、能力字符串和 pending 计数，不创建外部环境组件或转移资源所有权。
  // 失败/边界：adapter 缺失不在构造阶段报错；build_phase 才按 required/optional 配置
  //   处理缺失依赖，未构建完成的 env 不可用于数据路径操作。
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

  // 功能：从 uvm_config_db 取配置和抽象 adapter，执行 required fatal、
  //   optional capability gate，再冻结 env 组件。
  // 输入/输出及副作用：phase 为 UVM build phase 输入；从 uvm_config_db 读取 cfg、
  //   adapter、Function identity/binding，建立 detached snapshot 并调用 configure；
  //   pcie_env/axis_env 等外部组件不由本函数创建，adapter 句柄仍归注入方所有。
  // 失败/边界：cfg 缺失/为空、snapshot factory/copy 失败、required adapter 缺失、
  //   注入 null identity/binding 或 configure 返回 null/失败均触发对应 uvm_fatal 并提前
  //   返回；optional adapter 缺失只记录 passive/disabled 能力。
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

  // 功能：按 cfg 构造候选 responder registry、codec/resource manager 和各类 queue
  //   engine，逐项 claim region 后 seal，并在所有候选快照准备完毕后提交完整组合。
  // 输入/输出及副作用：cfg 为输入配置；成功时替换 env 自有 registry、engine、config
  //   和 Function detached snapshots，外部 adapter 引用仍由注入方拥有且不转移。
  // 失败/边界：cfg 为空或 validate 失败、region claim 冲突/溢出、候选 factory/copy
  //   分配失败或 seal 返回 null/失败时返回相应 status；最终发布点前旧组合保持不变，
  //   候选失败不会留下半新半旧的 env 状态。
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
    status = cfg.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
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
      status = candidate_registry.claim(source_region.domain, source_region.mode,
                                        source_region.route, source_region.base,
                                        source_region.size, source_region.owner,
                                        claimed_region);
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "responder registry claim returned null status"
        );
      if (!status.ok())
        return status;
    end
    status = candidate_registry.seal();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
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

    // Function identity/binding snapshot 也必须在主组合提交前完成。否则
    // snapshot factory 失败会留下已替换的 registry/engine，下一次 configure
    // 看到的是半新半旧的 env；候选快照失败只丢弃本地候选并保留旧组合。
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

  // 功能：bind_data_path 把已由上层 fixture 创建的资源管理器、Function
  // binding、host-memory、doorbell 和 codec 注入 env 自有 queue-data engine。
  // 输入/输出及副作用：resource_manager、function_binding、memory、scheduler、
  //   codec_registry、timeout 和可选 context_api 为输入；成功时 queue_data 保存这些
  //   对象的非拥有引用并建立数据路径，context_api 仅提供 QPC runtime shadow 读取能力。
  // 失败/边界：env 未 configure、必需依赖为空、timeout 为零、Function snapshot 不一致
  //   或 queue_data.configure 返回 null/失败时返回错误；本函数不释放调用方对象，已有
  //   attachment 的拒绝/回滚语义由 queue_data 保持。
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

  // 功能：post_send 将发送语义请求转发到 env 已绑定的 queue-data engine，
  // 作为 transport sequence 的统一提交入口。
  // 输入/输出及副作用：request 为输入；result/status 为输出；成功时推进 SQ
  // producer 并写入真实 queue backing，资源生命周期仍由 queue-data 管理。
  // 失败/边界：未绑定 data path、请求 authority 失配或队列无 credit 时返回错误，
  // 不发布半成品 result。
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

  // 功能：post_recv 将接收语义请求转发到 env 已绑定的 queue-data engine，
  // 作为 transport sequence 的统一 RQ 提交入口。
  // 输入/输出及副作用：request 为输入；result/status 为输出；成功时推进 RQ
  // producer 并写入真实 queue backing，不复制外部 host-memory 所有权。
  // 失败/边界：未绑定 data path、目标 QP/SGE authority 失配或队列无 credit 时
  // 返回错误且不推进 producer。
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

  // 功能：poll_completion 从 env 已绑定的 queue-data engine 消费 CQE，
  // 作为 transport sequence 的统一 CQ completion 入口。
  // 输入/输出及副作用：cq_h、timeout 为输入；completion/status 为输出；成功时
  // 推进 CQ consumer、释放对应 SQ/RQ slot 和 credit，不修改外部 adapter 账本。
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

  // 功能：查询指定 adapter capability 的 enabled/disabled/passive 状态并封装为 rdma_status.message。
  // 输入/输出及副作用：capability 为字符串输入；返回独立状态对象，不修改 env。
  // 失败/边界：未知 capability 返回 INVALID_ARGUMENT；已知 capability 始终返回其当前状态文本。
  function rdma_status capability_status(string capability);
    if (!m_capability.exists(capability))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown capability");
    return rdma_status::success(m_capability[capability]);
  endfunction

  // 功能：返回 env 自有 scoreboard/事务的 pending 数量汇总。
  // 输入/输出及副作用：无输入；读取本地计数，不触碰 adapter 或外部资源。
  // 失败/边界：计数仅由 begin_pending/end_pending 更新，未激活环境时保持零。
  function int unsigned pending_count();
    return m_pending_count;
  endfunction

  // 功能：登记一个待完成事件，使 pending_count 反映 env 自有 outstanding 工作。
  // 输入/输出及副作用：无输入；递增本地计数，不创建或拥有外部事务。
  // 失败/边界：计数达到 32'hffff_ffff 时拒绝递增并保持饱和值。
  function void begin_pending();
    if (m_pending_count != 32'hffff_ffff) m_pending_count++;
  endfunction

  // 功能：完成一个待完成事件并递减 pending_count，保持重复完成不会下溢。
  // 输入/输出及副作用：无输入；更新本地计数，不释放 adapter 资源。
  // 失败/边界：计数为零时视为幂等 no-op，避免无符号下溢。
  function void end_pending();
    if (m_pending_count != 0) m_pending_count--;
  endfunction

  // 功能：校验并接受带完整 Function/vector/generation 的事件路由，作为后续 scoreboard 路由入口。
  // 输入/输出及副作用：event 为输入；成功时递增 pending_count，失败不改变计数。
  // 失败/边界：空事件、身份不一致或 generation 过期返回错误，拒绝裸 vector 事件。
  function rdma_status route_event(rdma_env_event_route event_route);
    rdma_status status;
    if (event_route == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "event route is null");
    status = event_route.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
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
