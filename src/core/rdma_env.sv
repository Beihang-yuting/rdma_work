// 目录：核心执行层 src/core/rdma_env.sv。
// 职责：组合 RDMA 自有 codec/resource/responder 对象，并通过 UVM config_db 接收抽象 adapter 引用。
// 依赖：依赖 rdma_env_config、responder registry、rdma_adapter_pkg 和 model identity；不依赖或创建外部 pcie_env/axis_env。
// 所有权与生命周期：env 拥有内部 registry/config/codec/resource 对象；pcie、host_mem、net 仅为非拥有句柄，释放由上层 adapter 环境负责。

class rdma_env_event_route extends uvm_object;
  `uvm_object_utils(rdma_env_event_route)
  rdma_function_identity target_function;
  int unsigned vector;
  int unsigned generation;

  // 功能：构造空事件路由，要求发布前显式绑定 Function、vector 和 generation。
  // 输入输出及副作用：name 为 UVM 对象名；初始化字段为 null/0，不修改 env 账本。
  // 失败边界：空 Function 或零 generation 的事件不可提交；vector=0 仍可作为合法硬件向量。
  function new(string name = "rdma_env_event_route");
    super.new(name);
    target_function = null;
    vector = 0;
    generation = 0;
  endfunction

  // 功能：校验事件携带完整 target Function、vector 和 generation，阻止裸 vector 串线。
  // 输入输出及副作用：读取当前字段返回 rdma_status；不更新任何队列或 scoreboard 状态。
  // 失败边界：target_function 为空/非法、generation 为零或与 Function generation 不一致时返回错误。
  function rdma_status validate();
    if (target_function == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "event target Function is missing");
    if (!target_function.validate().ok())
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "event target Function is invalid");
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
  rdma_env_config config_snapshot;
  rdma_function_identity function_identity_snapshot;
  rdma_function_binding function_binding_snapshot;
  protected string m_capability[string];
  protected int unsigned m_pending_count;

  // 功能：构造 rdma_env，建立空 adapter 引用、内部组件句柄和 pending 计数。
  // 输入输出及副作用：name、parent 为 UVM 层级参数；只初始化本地状态，不创建外部环境组件。
  // 失败边界：adapter 缺失不在构造阶段报错；build_phase 按 required/optional 策略处理。
  function new(string name = "rdma_env", uvm_component parent = null);
    super.new(name, parent);
    pcie = null;
    host_mem = null;
    net = null;
    responders = null;
    codecs = null;
    resources = null;
    config_snapshot = null;
    function_identity_snapshot = null;
    function_binding_snapshot = null;
    m_pending_count = 0;
    m_capability["pcie"] = "disabled";
    m_capability["host_mem"] = "disabled";
    m_capability["net"] = "disabled";
  endfunction

  // 功能：从 uvm_config_db 取配置和抽象 adapter，执行 required fatal、optional capability gate，再冻结 env 组件。
  // 输入输出及副作用：phase 为 UVM build phase；读取 cfg/adapter/identity 引用并调用 configure，不创建 pcie_env/axis_env。
  // 失败边界：缺少 cfg、cfg.validate/configure 失败或 required adapter 缺失触发 uvm_fatal；optional 缺失只标记 passive/disabled。
  function void build_phase(uvm_phase phase);
    rdma_env_config supplied_cfg;
    rdma_function_identity supplied_identity;
    rdma_function_binding supplied_binding;
    bit found;
    rdma_status status;
    super.build_phase(phase);
    if (!uvm_config_db#(rdma_env_config)::get(this, "", "cfg", supplied_cfg) &&
        !uvm_config_db#(rdma_env_config)::get(this, "", "rdma_env_config", supplied_cfg))
      `uvm_fatal("RDMA_ENV_CFG", "rdma_env_config is missing from uvm_config_db")
    if (supplied_cfg == null)
      `uvm_fatal("RDMA_ENV_CFG", "rdma_env_config handle is null")
    config_snapshot = rdma_env_config::type_id::create("config_snapshot");
    config_snapshot.copy(supplied_cfg);

    found = uvm_config_db#(rdma_pcie_api)::get(this, "", "pcie", pcie);
    if (config_snapshot.pcie_required && !found)
      `uvm_fatal("RDMA_ENV_PCIE", "required PCIe adapter is missing")
    m_capability["pcie"] = config_snapshot.pcie_enabled ? (found ? "enabled" : "passive") : "disabled";
    found = uvm_config_db#(rdma_host_mem_api)::get(this, "", "host_mem", host_mem);
    if (config_snapshot.host_mem_required && !found)
      `uvm_fatal("RDMA_ENV_HOST", "required host-memory adapter is missing")
    m_capability["host_mem"] = config_snapshot.host_mem_enabled ? (found ? "enabled" : "passive") : "disabled";
    found = uvm_config_db#(rdma_net_api)::get(this, "", "net", net);
    if (config_snapshot.net_required && !found)
      `uvm_fatal("RDMA_ENV_NET", "required network adapter is missing")
    m_capability["net"] = config_snapshot.net_enabled ? (found ? "enabled" : "passive") : "disabled";

    if (uvm_config_db#(rdma_function_identity)::get(this, "", "function_identity", supplied_identity)) begin
      function_identity_snapshot = rdma_function_identity::type_id::create("function_identity_snapshot");
      function_identity_snapshot.copy(supplied_identity);
    end else if (config_snapshot.function_identity != null) begin
      function_identity_snapshot = rdma_function_identity::type_id::create("function_identity_snapshot");
      function_identity_snapshot.copy(config_snapshot.function_identity);
    end
    if (uvm_config_db#(rdma_function_binding)::get(this, "", "function_binding", supplied_binding)) begin
      function_binding_snapshot = rdma_function_binding::type_id::create("function_binding_snapshot");
      function_binding_snapshot.copy(supplied_binding);
      if (function_identity_snapshot == null)
        function_identity_snapshot = function_binding_snapshot.identity_snapshot();
    end else if (config_snapshot.function_binding != null) begin
      function_binding_snapshot = rdma_function_binding::type_id::create("function_binding_snapshot");
      function_binding_snapshot.copy(config_snapshot.function_binding);
      if (function_identity_snapshot == null)
        function_identity_snapshot = function_binding_snapshot.identity_snapshot();
    end
    status = configure(config_snapshot);
    if (!status.ok())
      `uvm_fatal("RDMA_ENV_CONFIG", status.message)
  endfunction

  // 功能：按 cfg 快照创建内部 registry/codec/resource 对象，逐项 claim region 后 seal，提交完整一致的组合结果。
  // 输入输出及副作用：cfg 为输入配置；更新 env 内部 owned 对象和 config snapshot，adapter 仍保持 borrowed 引用。
  // 失败边界：cfg 为空/validate 失败、claim 冲突/溢出或 seal 失败时返回错误，旧 responder registry 不被部分替换。
  function rdma_status configure(rdma_env_config cfg);
    rdma_responder_registry candidate_registry;
    rdma_codec_registry candidate_codecs;
    rdma_resource_manager candidate_resources;
    rdma_responder_region source_region;
    rdma_responder_region claimed_region;
    rdma_status status;
    if (cfg == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "rdma_env_config is null");
    status = cfg.validate();
    if (!status.ok()) return status;
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
      if (!status.ok()) return status;
    end
    status = candidate_registry.seal();
    if (!status.ok()) return status;
    responders = candidate_registry;
    codecs = candidate_codecs;
    resources = candidate_resources;
    return rdma_status::success();
  endfunction

  // 功能：查询指定 adapter capability 的 enabled/disabled/passive 状态并封装为 rdma_status.message。
  // 输入输出及副作用：capability 为字符串输入；返回独立状态对象，不修改 env。
  // 失败边界：未知 capability 返回 INVALID_ARGUMENT；已知 capability 始终返回其当前状态文本。
  function rdma_status capability_status(string capability);
    if (!m_capability.exists(capability))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "unknown capability");
    return rdma_status::success(m_capability[capability]);
  endfunction

  // 功能：返回 env 自有 scoreboard/事务的 pending 数量汇总。
  // 输入输出及副作用：无输入；读取本地计数，不触碰 adapter 或外部资源。
  // 失败边界：计数仅由 begin_pending/end_pending 更新，未激活环境时保持零。
  function int unsigned pending_count();
    return m_pending_count;
  endfunction

  // 功能：登记一个待完成事件，使 pending_count 反映 env 自有 outstanding 工作。
  // 输入输出及副作用：无输入；递增本地计数，不创建或拥有外部事务。
  // 失败边界：计数达到 32'hffff_ffff 时拒绝递增并保持饱和值。
  function void begin_pending();
    if (m_pending_count != 32'hffff_ffff) m_pending_count++;
  endfunction

  // 功能：完成一个待完成事件并递减 pending_count，保持重复完成不会下溢。
  // 输入输出及副作用：无输入；更新本地计数，不释放 adapter 资源。
  // 失败边界：计数为零时视为幂等 no-op，避免无符号下溢。
  function void end_pending();
    if (m_pending_count != 0) m_pending_count--;
  endfunction

  // 功能：校验并接受带完整 Function/vector/generation 的事件路由，作为后续 scoreboard 路由入口。
  // 输入输出及副作用：event 为输入；成功时递增 pending_count，失败不改变计数。
  // 失败边界：空事件、身份不一致或 generation 过期返回错误，拒绝裸 vector 事件。
  function rdma_status route_event(rdma_env_event_route event_route);
    rdma_status status;
    if (event_route == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "event route is null");
    status = event_route.validate();
    if (!status.ok()) return status;
    if (function_identity_snapshot != null &&
        !function_identity_snapshot.same_incarnation(event_route.target_function))
      return rdma_status::make(RDMA_SC_STALE_GENERATION, "event target Function is not env owner");
    begin_pending();
    return rdma_status::success();
  endfunction
endclass
