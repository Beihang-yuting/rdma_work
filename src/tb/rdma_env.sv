// 目录：验证组件层 tb/rdma_env.sv。
// 层：验证组件。
// 职责：RDMA 验证环境：按配置建立 dpu_common 系统（每个 Function 的内存 + 设备 + 驱动）、资源库、控制面
//   agent、每 Function 一个数据面 agent、链路（factory 按名字创建）、scoreboard 与虚拟 sequencer；
//   initialize 显式完成 probe/登记/就绪；模型 run_phase 自动调用，外部由平台命令调用。插件在各阶段扩展。
// 依赖：rdma_env_cfg、rdma_dpu_system、各组件。
// 所有权：env 拥有模型 dpu 系统与全部组件；外部系统及其平台依赖为非拥有引用，生命周期由平台覆盖。
// 生命周期：build 装配，initialize 成功后由虚拟序列驱动；失败后该环境生命周期不可重试。

class rdma_vsequencer extends uvm_sequencer;
  `uvm_component_utils(rdma_vsequencer)

  rdma_env env;

  // 功能：构造尚未绑定 RDMA 环境的虚拟 sequencer，作为跨控制面/数据面 sequence 的协调入口。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；env 保持非拥有空引用，不创建子 sequencer。
  // 失败/边界：必须由 rdma_env.connect_phase 绑定 env 后才能启动访问环境资源的虚拟 sequence。
  function new(string name = "rdma_vsequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass

class rdma_env extends uvm_env;
  `uvm_component_utils(rdma_env)

  localparam bit [47:0] MAC_BASE = 48'h02_00_00_00_10_00;

  rdma_env_cfg cfg;
  rdma_dpu_system sys;
  rdma_res_db res;
  rdma_ctrl_agent ctrl;
  rdma_verb_agent verb[];
  rdma_link link;
  rdma_scoreboard sb;
  rdma_proto_checker checker;
  rdma_coverage cov;
  rdma_vsequencer vseqr;
  // 控制面命令进行中（驱动内部等待自己处理 AEQ，monitor 暂停取 AEQ）。
  bit ctrl_busy;
  protected bit ready;
  protected bit	initialization_started;

  // 功能：构造空的 RDMA UVM 环境容器，并以 ctrl_busy=0、ready=0 开始其 build/run 生命周期。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；cfg、系统及全部子组件句柄保持 null，随后由
  //   build_phase 创建组件；模型系统由 env 拥有，外部系统由平台拥有。
  // 失败/边界：构造阶段不能运行 sequence 或访问 Function；缺失 cfg 将在 build_phase 以 UVM_FATAL 拒绝。
  function new(string name = "rdma_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：取配置（键 "cfg"）→ 插件 pre_build → 配置 finalize（校验单一scenario及环境配置）并打印
  //   最终生效配置 → 虚拟build_system取得系统 → 建组件（链路按 cfg.link_type）→ 插件 build。
  // 输入/输出及副作用：创建子组件与系统；以 UVM_LOW 打印生效配置。
  // 失败/边界：缺配置、配置校验失败、系统建立失败或链路类型无效时 UVM_FATAL。
  extern function void build_phase(uvm_phase	phase);

  // 功能：提供系统装配虚拟钩子；默认模型声明Host/Function后build，默认外部借用external_system。
  // 输入/输出及副作用：读取cfg并设置sys；模型创建自有系统，外部不重新解析/分配，派生实现须保持来源及所有权契约。
  // 失败/边界：要求cfg已finalize；默认模型sys.build失败fatal；钩子不得执行probe或发布ready，初始化仍统一预检。
  extern protected virtual function void build_system();

  // 功能：在 dpu_common 系统发布后检查每条 flow group 的 global Function ID 是否存在于同一快照。
  // 输入/输出及副作用：只读 cfg.flow_groups 与 sys.nodes，返回首个无效端点的 status；不分配 QP、不改变快照。
  // 失败/边界：零 QP/相同端点由配置层拒绝；未知 ID、未绑定系统或远端 ID 返回 INVALID_ARGUMENT，避免流量阶段才失败。
  extern protected function rdma_status validate_flow_groups();

  // 功能：连接组件：agent 绑定 Function，数据面与资源事件 → scoreboard，链路 → 协议检查，各事件 →
  //   覆盖率（verb 经 scoreboard 转发，已带预测状态）。
  // 输入/输出及副作用：把 env 非拥有引用注入 driver/checker/coverage/vsequencer，建立资源、verb、链路与
  //   scoreboard/coverage 的 analysis TLM 连接。
  // 失败/边界：要求 build_phase 已成功创建必选组件，verb 数量与本地加远端 Function 数一致；关闭的
  //   checker/cov 为 null 时有意跳过其全部连接。
  function void connect_phase(uvm_phase phase);
    ctrl.driver.env = this;
    sb.res = res;
    res.ap.connect(sb.res_export);
    vseqr.env = this;
    if (checker != null) begin
      checker.env = this;
      link.tx_ap.connect(checker.tx_export);
      link.rx_ap.connect(checker.rx_export);
    end
    foreach (verb[i]) begin
      verb[i].bind_func(this, i);
      verb[i].driver.posted_ap.connect(sb.posted_export);
      verb[i].monitor.cqe_ap.connect(sb.cqe_export);
      verb[i].monitor.aeq_ap.connect(sb.aeq_export);
    end
    if (cov != null) begin
      cov.env = this;
      res.ap.connect(cov.res_export);
      ctrl.driver.ap.connect(cov.ctrl_export);
      link.tx_ap.connect(cov.wire_export);
      sb.predicted_ap.connect(cov.verb_export);
      foreach (verb[i])
        verb[i].monitor.cqe_ap.connect(cov.cqe_export);
    end
  endfunction

  // 功能：保持模型自动启动语义；外部配置环境等待平台显式调用 initialize。
  // 输入/输出及副作用：模型调用 initialize 并在失败时 UVM_FATAL；外部立即返回且不执行 probe/MMIO。
  // 失败/边界：外部单纯等待时间不会就绪；模型初始化失败保持 ready=0。
  extern task run_phase(uvm_phase	phase);

  // 功能：一次性执行全系统预检、probe、设备登记与链路/插件启动，最后发布 ready。
  // 输入/输出及副作用：status 返回首个失败；开始时锁定 sys 绑定；全部 probe 成功才发布资源和启动模型 NIC。
  // 失败/边界：重复/并发初始化 INVALID_STATE；预检失败无 MMIO/驱动变更；部分 probe 失败不登记业务资源且 ready=0，禁止重试。
  extern task initialize(output rdma_status	status);

  // 功能：纯查询环境是否完成全部初始化阶段，不触发驱动或平台动作。
  // 输入/输出及副作用：返回 ready 当前值；不等待，不改变状态。
  // 失败/边界：未初始化、预检/probe 失败或初始化仍在进行时均返回 0。
  extern function bit is_ready();

  // 功能：按 dpu_common 发布的 global Function ID 查找本地节点下标，供项目流量组绑定 data-plane agent。
  // 输入/输出及副作用：global_id 只读，返回 sys.nodes 中的稳定下标；不创建资源、不修改快照。
  // 失败/边界：环境未绑定或 ID 不存在返回 -1；远端 RXE Function 没有本地 dpu 节点，不能通过本接口查询。
  extern function int find_function_index(int unsigned global_id);

  // 功能：把已 probe Function 的 CMQ、全部 CEQ 与 AEQ 包装成资源对象并登记到环境资源库。
  // 输入/输出及副作用：f 及其驱动队列保持外部所有权；新建 wrapper，写 res，并为每个 EQ 调用 add_eq。
  // 失败/边界：要求 f 非空、driver probe 成功且 res 已建立；同一 Function 重复登记会产生重复资源，
  //   正常路径每个 probe/recover epoch 只调用一次并由资源库先处理失效对象。
  function void register_device(rdma_res_func f);
    rdma_res_cmq q;

    q = rdma_res_cmq::type_id::create("cmq");
    q.owner = f;
    q.cmq = f.drv().cmq;
    res.add(q);
    foreach (f.drv().ceqs[i])
      add_eq(f, f.drv().ceqs[i]);
    add_eq(f, f.drv().aeq);
  endfunction

  // 功能：把驱动 EQ 的编号、AEQ/CEQ 类型和深度投影到一个属于 Function 的资源 wrapper。
  // 输入/输出及副作用：借用 f/eq 引用，新建 rdma_res_eq 并写入 res；不接管驱动 EQ 生命周期。
  // 失败/边界：要求 f、eq 与 res 非空且 eqn 在该 Function 当前 epoch 唯一；本辅助函数不去重。
  protected function void add_eq(rdma_res_func f, rdma_drv_eq eq);
    rdma_res_eq e;

    e = rdma_res_eq::type_id::create("eq");
    e.owner = f;
    e.id = eq.eqn;
    e.eq = eq;
    e.is_aeq = eq.is_aeq;
    e.entries = eq.entries;
    res.add(e);
  endfunction

  // 功能：阻塞调用 task，直到全部本地 Function probe/链路接入及插件 start 完成后 ready 被置位。
  // 输入/输出及副作用：只等待本 env 的 ready，不持有 objection，也不推进其他状态。
  // 失败/边界：没有内部超时；run_phase 在置位前 fatal、被取消或插件 start 永不返回时，本 task 持续等待。
  task wait_ready();
    wait (ready);
  endtask

  // 功能：等待 scoreboard 全部期望结算。
  // 输入/输出及副作用：轮询，阻塞至多 timeout。
  // 失败/边界：超时报 UVM_ERROR。
  task wait_idle(time timeout);
    time deadline;

    deadline = $time + timeout;
    while (!sb.idle()) begin
      if ($time >= deadline) begin
        `uvm_error("RDMA_ENV", "traffic did not drain before timeout")
        return;
      end
      #(cfg.poll_interval);
    end
  endtask

  // 功能：报告阶段汇总每个本地设备 NIC 留存的协议错误，并按配置顺序调用插件收尾检查。
  // 输入/输出及副作用：phase 不被修改；非空 errors 产生 UVM_ERROR，插件可报告并释放其自有外部资源。
  // 失败/边界：要求 build 已建立 sys/cfg；外部节点无 dev 时跳过；远端错误由插件负责，错误列表不清除。
  extern function void report_phase(uvm_phase	phase);

  // 功能：在尚未启动初始化的唯一资源边界预检项目提交的 RDMA 候选。
  // 输入/输出及副作用：candidate 为只读候选；查询驱动和资源状态并返回 status。
  // 失败/边界：初始化曾开始、资源或驱动已经存在均拒绝，即使当前空闲；无释放到未初始化 API。
  extern function rdma_status validate_runtime_candidate(rdma_env_cfg	candidate);

  // 功能：在全项目事务预检之后原地应用 RDMA 候选。
  // 输入/输出及副作用：candidate 传给 cfg 原地复制；不替换 env/sys/场景句柄，不产生 MMIO。
  // 失败/边界：调用方必须在同一无时间推进事务中完成预检；本接口不注册或执行独立重载命令。
  extern function void apply_runtime_candidate(rdma_env_cfg	candidate);
endclass

// 功能：取配置（键 "cfg"）→ 插件 pre_build → 配置 finalize（校验单一scenario及环境配置）并打印
//   最终生效配置 → 虚拟build_system取得系统 → 建组件（链路按 cfg.link_type）→ 插件 build。
// 输入/输出及副作用：创建子组件与系统；以 UVM_LOW 打印生效配置。
// 失败/边界：缺配置、配置校验失败、系统建立失败或链路类型无效时 UVM_FATAL。
function void rdma_env::build_phase(uvm_phase	phase);
  uvm_component	c;
  rdma_dut_link	dut_link;
  rdma_status	link_status;
  int unsigned	dut_port;
  bit [47:0]	dut_mac;

  super.build_phase(phase);
  if (!uvm_config_db#(rdma_env_cfg)::get(this, "", "cfg", cfg))
    `uvm_fatal("RDMA_ENV", "rdma_env_cfg not set (config_db key \"cfg\")")
  foreach (cfg.plugins[i])
    cfg.plugins[i].pre_build(this);
  link_status = cfg.finalize();
  if (!link_status.ok())
    `uvm_fatal("RDMA_ENV", {"configuration rejected: ", link_status.convert2string()})
  `uvm_info("RDMA_ENV", cfg.describe(), UVM_LOW)
  if (cfg.flow_plan != null && cfg.resolved_config == null) begin
    link_status = rdma_flow_resolver::resolve(cfg.flow_plan,
                                              cfg.resolved_config,
                                              cfg.dut_link_snapshot);
    if (!link_status.ok())
      `uvm_fatal("RDMA_ENV", {"flow plan resolve failed: ", link_status.convert2string()})
  end
  if (cfg.resolved_config != null && cfg.dut_link_snapshot == null)
    `uvm_warning("RDMA_ENV", "resolved_config is provided without a DUT link snapshot")
  build_system();
  link_status = validate_flow_groups();
  if (!link_status.ok())
    `uvm_fatal("RDMA_ENV", {"flow group validation failed: ", link_status.convert2string()})
  res = rdma_res_db::type_id::create("res", this);
  ctrl = rdma_ctrl_agent::type_id::create("ctrl", this);
  verb = new[sys.nodes.size() + cfg.remote_funcs];
  foreach (verb[i])
    verb[i] = rdma_verb_agent::type_id::create($sformatf("verb%0d", i), this);
  c = uvm_factory::get().create_component_by_name(cfg.link_type, get_full_name(), "link", this);
  if (!$cast(link, c))
    `uvm_fatal("RDMA_ENV", {"link_type is not an rdma_link: ", cfg.link_type})
  if (cfg.link_type == "rdma_dut_link") begin
    if (!$cast(dut_link, link))
      `uvm_fatal("RDMA_ENV", "rdma_dut_link factory object did not cast to rdma_dut_link")
    if (cfg.dut_link_snapshot != null) begin
      link_status = dut_link.bind_snapshot(cfg.dut_link_snapshot);
      if (!link_status.ok())
        `uvm_fatal("RDMA_ENV", {"DUT link snapshot bind failed: ", link_status.convert2string()})
    end
    dut_port = cfg.dut_port;
    dut_mac = cfg.dut_mac;
    if (cfg.dut_link_snapshot != null && dut_port == 0 && cfg.dut_link_snapshot.dut_port != 0)
      dut_port = cfg.dut_link_snapshot.dut_port;
    if (dut_mac == 0 && cfg.dut_link_snapshot != null)
      dut_mac = cfg.dut_link_snapshot.dut_mac;
    if (cfg.dut_endpoint == null)
      `uvm_fatal("RDMA_ENV", "rdma_dut_link requires cfg.dut_endpoint")
    link_status = dut_link.bind_endpoint(cfg.dut_endpoint, dut_port, dut_mac);
    if (!link_status.ok())
      `uvm_fatal("RDMA_ENV", {"DUT endpoint bind failed: ", link_status.convert2string()})
  end
  sb = rdma_scoreboard::type_id::create("sb", this);
  if (cfg.checker_enable)
    checker = rdma_proto_checker::type_id::create("checker", this);
  if (cfg.cov_enable)
    cov = rdma_coverage::type_id::create("cov", this);
  vseqr = rdma_vsequencer::type_id::create("vseqr", this);
  foreach (cfg.plugins[i])
    cfg.plugins[i].build(this);
  foreach (cfg.deviations[i])
    `uvm_info("RDMA_ENV", {"declared deviation: ", cfg.deviations[i]}, UVM_LOW)
endfunction

// 功能：提供系统装配虚拟钩子；默认模型声明Host/Function后build，默认外部借用external_system。
// 输入/输出及副作用：读取cfg并设置sys；模型创建自有系统，外部不重新解析/分配，派生实现须保持来源及所有权契约。
// 失败/边界：要求cfg已finalize；默认模型sys.build失败fatal；钩子不得执行probe或发布ready，初始化仍统一预检。
function void rdma_env::build_system();
  bit	hosts[int unsigned];
  rdma_status	status;

  if (cfg.external_configuration) begin
    sys = cfg.external_system;
    return;
  end
  sys = rdma_dpu_system::type_id::create("dpu");
  foreach (cfg.funcs[i])
    if (!hosts.exists(cfg.funcs[i].host)) begin
      hosts[cfg.funcs[i].host] = 1'b1;
      sys.add_host(cfg.funcs[i].host);
    end
  foreach (cfg.funcs[i])
    sys.add_function(cfg.funcs[i].host, cfg.funcs[i].pf, cfg.funcs[i].kind, cfg.funcs[i].vf);
  status = sys.build();
  if (!status.ok())
    `uvm_fatal("RDMA_ENV", {"dpu system build failed: ", status.convert2string()})
endfunction

// 功能：在 dpu_common 系统发布后检查每条 flow group 的 global Function ID 是否存在于同一快照。
// 输入/输出及副作用：只读 cfg.flow_groups 与 sys.nodes，返回首个无效端点的 status；不分配 QP、不改变快照。
// 失败/边界：零 QP/相同端点由配置层拒绝；未知 ID、未绑定系统或远端 ID 返回 INVALID_ARGUMENT，避免流量阶段才失败。
function rdma_status rdma_env::validate_flow_groups();
  if (sys == null)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "flow groups require a bound dpu_common system");
  foreach (cfg.flow_groups[i]) begin
    int left;
    int right;

    left = find_function_index(cfg.flow_groups[i].f0_global_id);
    right = find_function_index(cfg.flow_groups[i].f1_global_id);
    if (left < 0 || right < 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
        $sformatf("flow group %0d references a global Function ID absent from the snapshot", i));
    if (left == right)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
        $sformatf("flow group %0d resolves both endpoints to one Function", i));
  end
  return rdma_status::success();
endfunction

// 功能：保持模型自动启动语义；外部配置环境等待平台显式调用 initialize。
// 输入/输出及副作用：模型调用 initialize 并在失败时 UVM_FATAL；外部立即返回且不执行 probe/MMIO。
// 失败/边界：外部单纯等待时间不会就绪；模型初始化失败保持 ready=0。
task rdma_env::run_phase(uvm_phase	phase);
  rdma_status	status;

  if (cfg.external_configuration)
    return;
  initialize(status);
  if (!status.ok())
    `uvm_fatal("RDMA_ENV", {"initialize failed: ", status.convert2string()})
endtask

// 功能：一次性执行全系统预检、probe、设备登记与链路/插件启动，最后发布 ready。
// 输入/输出及副作用：status 返回首个失败；开始时锁定 sys 绑定；全部 probe 成功才发布资源和启动模型 NIC。
// 失败/边界：重复/并发初始化 INVALID_STATE；预检失败无 MMIO/驱动变更；部分 probe 失败不登记业务资源且 ready=0，禁止重试。
task rdma_env::initialize(output rdma_status	status);
  rdma_res_func	f;
  rdma_dut_link	dut_link;

  if (initialization_started || sys == null || res == null || link == null) begin
    status = rdma_status::make(RDMA_SC_INVALID_STATE, "environment initialization is unavailable or already started");
    return;
  end
  initialization_started = 1;
  sys.lock_bindings();
  status = sys.validate_initialization();
  if (!status.ok())
    return;
  // probe 可等待 MMIO 完成；此时 ready 始终为 0，控制面和数据面均被 wait_ready 隔离。
  // 先完成全部 probe，再发布资源，避免失败节点留下可被业务使用的半个环境。
  foreach (sys.nodes[i]) begin
    sys.probe(i, status, sys.nodes[i].drv_cfg);
    if (!status.ok())
      return;
  end
  foreach (sys.nodes[i]) begin
    f = res.add_func(sys.nodes[i], MAC_BASE + i);
    register_device(f);
    if (sys.nodes[i].dev != null)
      sys.nodes[i].dev.nic.port = link.attach(f);
  end
  sys.start();
  if ($cast(dut_link, link))
    dut_link.wait_started();
  foreach (cfg.plugins[i])
    cfg.plugins[i].start(this);
  ready = 1;
  status = rdma_status::success();
endtask

// 功能：纯查询环境是否完成全部初始化阶段，不触发驱动或平台动作。
// 输入/输出及副作用：返回 ready 当前值；不等待，不改变状态。
// 失败/边界：未初始化、预检/probe 失败或初始化仍在进行时均返回 0。
function bit rdma_env::is_ready();
  return ready;
endfunction

// 功能：按 dpu_common 发布的 global Function ID 查找本地节点下标，供项目流量组绑定 data-plane agent。
// 输入/输出及副作用：global_id 只读，返回 sys.nodes 中的稳定下标；不创建资源、不修改快照。
// 失败/边界：环境未绑定或 ID 不存在返回 -1；远端 RXE Function 没有本地 dpu 节点，不能通过本接口查询。
function int rdma_env::find_function_index(int unsigned global_id);
  if (sys == null)
    return -1;
  foreach (sys.nodes[i])
    if (sys.nodes[i].func != null && sys.nodes[i].func.global_id == global_id)
      return i;
  return -1;
endfunction

// 功能：报告阶段汇总每个本地设备 NIC 留存的协议错误，并按配置顺序调用插件收尾检查。
// 输入/输出及副作用：phase 不被修改；非空 errors 产生 UVM_ERROR，插件可报告并释放其自有外部资源。
// 失败/边界：要求 build 已建立 sys/cfg；外部节点无 dev 时跳过；远端错误由插件负责，错误列表不清除。
function void rdma_env::report_phase(uvm_phase	phase);
  foreach (sys.nodes[i])
    if (sys.nodes[i].dev != null && sys.nodes[i].dev.nic.errors.size() != 0)
      `uvm_error("RDMA_ENV", $sformatf("f%0d device errors: %p", i,
                 sys.nodes[i].dev.nic.errors))
  foreach (cfg.plugins[i])
    cfg.plugins[i].report(this);
endfunction

// 功能：在尚未启动初始化的唯一资源边界预检项目提交的 RDMA 候选。
// 输入/输出及副作用：candidate 为只读候选；查询驱动和资源状态并返回 status。
// 失败/边界：初始化曾开始、资源或驱动已经存在均拒绝，即使当前空闲；无释放到未初始化 API。
function rdma_status rdma_env::validate_runtime_candidate(rdma_env_cfg	candidate);
  if (initialization_started || cfg == null || sys == null || res == null || res.funcs.size() != 0)
    return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA reload requires the pre-initialization resource boundary");
  foreach (sys.nodes[i])
    if (sys.nodes[i].drv != null)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "RDMA reload cannot change existing driver configuration");
  return cfg.validate_runtime_candidate(candidate);
endfunction

// 功能：在全项目事务预检之后原地应用 RDMA 候选。
// 输入/输出及副作用：candidate 传给 cfg 原地复制；不替换 env/sys/场景句柄，不产生 MMIO。
// 失败/边界：调用方必须在同一无时间推进事务中完成预检；本接口不注册或执行独立重载命令。
function void rdma_env::apply_runtime_candidate(rdma_env_cfg	candidate);
  cfg.apply_runtime_candidate(candidate);
endfunction
