// 目录：验证组件层 tb/rdma_env.sv。
// 层：验证组件。
// 职责：RDMA 验证环境：按配置建立 dpu_common 系统（每个 Function 的内存 + 设备 + 驱动）、资源库、控制面
//   agent、每 Function 一个数据面 agent、链路（factory 按名字创建）、scoreboard 与虚拟 sequencer；
//   run_phase probe 全部 Function、登记设备级队列、把 NIC 接入链路后宣告就绪。插件在各阶段扩展。
// 依赖：rdma_env_cfg、rdma_dpu_system、各组件。
// 所有权：env 拥有 dpu 系统与全部组件；内存由配置的工厂提供。
// 生命周期：build 建立，run_phase 就绪后由虚拟序列驱动。

class rdma_vsequencer extends uvm_sequencer;
  `uvm_component_utils(rdma_vsequencer)

  rdma_env env;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
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
  rdma_vsequencer vseqr;
  // 控制面命令进行中（驱动内部等待自己处理 AEQ，monitor 暂停取 AEQ）。
  bit ctrl_busy;
  protected bit ready;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：取配置（键 "cfg"）→ 插件 pre_build → 建 dpu 系统 → 建组件（链路按 cfg.link_type）→ 插件 build。
  // 输入/输出及副作用：创建子组件与系统。
  // 失败/边界：缺配置、系统建立失败或链路类型无效时 UVM_FATAL。
  function void build_phase(uvm_phase phase);
    uvm_component c;

    super.build_phase(phase);
    if (!uvm_config_db#(rdma_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("RDMA_ENV", "rdma_env_cfg not set (config_db key \"cfg\")")
    foreach (cfg.plugins[i])
      cfg.plugins[i].pre_build(this);
    build_system();
    res = rdma_res_db::type_id::create("res", this);
    ctrl = rdma_ctrl_agent::type_id::create("ctrl", this);
    verb = new[cfg.funcs.size() + cfg.remote_funcs];
    foreach (verb[i])
      verb[i] = rdma_verb_agent::type_id::create($sformatf("verb%0d", i), this);
    c = uvm_factory::get().create_component_by_name(cfg.link_type, get_full_name(), "link", this);
    if (!$cast(link, c))
      `uvm_fatal("RDMA_ENV", {"link_type is not an rdma_link: ", cfg.link_type})
    sb = rdma_scoreboard::type_id::create("sb", this);
    vseqr = rdma_vsequencer::type_id::create("vseqr", this);
    foreach (cfg.plugins[i])
      cfg.plugins[i].build(this);
  endfunction

  // 功能：按配置声明 Host/Function 并建立 dpu 系统。
  // 输入/输出及副作用：设置 sys。
  // 失败/边界：失败 UVM_FATAL。
  protected function void build_system();
    bit hosts[int unsigned];
    rdma_status status;

    sys = rdma_dpu_system::type_id::create("dpu");
    sys.mem_factory = cfg.mem_factory;
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

  // 功能：连接组件：agent 绑定 Function，数据面 → scoreboard。
  // 输入/输出及副作用：建立 TLM 连接。
  // 失败/边界：无。
  function void connect_phase(uvm_phase phase);
    ctrl.driver.env = this;
    sb.res = res;
    vseqr.env = this;
    foreach (verb[i]) begin
      verb[i].bind_func(this, i);
      verb[i].driver.posted_ap.connect(sb.posted_export);
      verb[i].monitor.cqe_ap.connect(sb.cqe_export);
      verb[i].monitor.aeq_ap.connect(sb.aeq_export);
    end
  endfunction

  // 功能：probe 每个 Function，登记到资源库与设备级队列，NIC 接入链路；启动 NIC；插件 start（远端
  //   Function 在此登记）后就绪。
  // 输入/输出及副作用：设置 ready。
  // 失败/边界：probe 失败 UVM_FATAL。
  task run_phase(uvm_phase phase);
    rdma_res_func f;
    rdma_status status;

    foreach (sys.nodes[i]) begin
      sys.probe(i, status);
      if (!status.ok())
        `uvm_fatal("RDMA_ENV", $sformatf("probe f%0d failed: %s", i, status.convert2string()))
      f = res.add_func(sys.nodes[i], MAC_BASE + i);
      register_device(f);
      sys.nodes[i].dev.nic.port = link.attach(f);
    end
    sys.start();
    foreach (cfg.plugins[i])
      cfg.plugins[i].start(this);
    ready = 1'b1;
  endtask

  // 功能：把 Function 驱动 probe 建立的设备级队列（CMQ、CEQ、AEQ）登记到资源库。
  // 输入/输出及副作用：写资源库。
  // 失败/边界：无。
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

  // 功能：登记一个 EQ。
  // 输入/输出及副作用：写资源库。
  // 失败/边界：无。
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

  // 功能：等待 env 就绪（全部 Function probe 并接入链路）。
  // 输入/输出及副作用：阻塞。
  // 失败/边界：无。
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

  // 功能：结束报告：设备模型内部错误、插件检查。
  // 输入/输出及副作用：报 UVM_ERROR。
  // 失败/边界：无。
  function void report_phase(uvm_phase phase);
    foreach (sys.nodes[i])
      if (sys.nodes[i].dev.nic.errors.size() != 0)
        `uvm_error("RDMA_ENV", $sformatf("f%0d device errors: %p", i,
                   sys.nodes[i].dev.nic.errors))
    foreach (cfg.plugins[i])
      cfg.plugins[i].report(this);
  endfunction
endclass
