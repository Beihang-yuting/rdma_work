// 目录/层次：integration/virtio；在 virtio_work project_env 上增加一个 RDMA env。
// 职责：父类拥有 DPU、每 Host 的 VIO、Intel PCIe 和共享 pool；本层只绑定 RDMA 并编排显式操作。
// 依赖：project_env_pkg、RDMA 外部系统和组合 cfg_seq；不复制父类资源创建/连接逻辑。
// 所有权/生命周期：RDMA 借用同一冻结快照和 pool；配置/初始化/发包均由 Tcl 显式调用。

// RDMA 与 VIO 同挂 DPU 子树，保证 dpu_common 先发布快照，RDMA 再借用同源资源。
// 基础 rdma_env 通过已有 plugin pre_build 钩子完成 snapshot/resource/grant 绑定，生产层不再派生 RDMA env。
class rdma_virtio_bind_plugin extends rdma_env_plugin;
  `uvm_object_utils(rdma_virtio_bind_plugin)

  project_env_cfg project_cfg;

  // 功能：构造只保存组合 project_cfg 非拥有引用的绑定插件。
  // 输入/输出及副作用：name 传给 UVM；project_cfg 由组合 env 在 rdma_env 创建前注入。
  // 失败/边界：构造不访问 DPU 快照或分配资源；缺少 project_cfg 时 pre_build 明确 fatal。
  function new(string name = "rdma_virtio_bind_plugin");
    super.new(name);
  endfunction

  // 功能：在基础 rdma_env finalize 前把 dpu_common 快照、资源和平台 grant 绑定到外部系统。
  // 输入/输出及副作用：更新 rdma_cfg.external_system；系统只借用 DPU snapshot、resource_snapshot 和共享 Host pool。
  // 失败/边界：父级不是 dpu_device_env、快照不同源、重复绑定或 grant 不匹配时 fatal；不执行 probe/初始化。
  virtual function void pre_build(rdma_env env);
    dpu_device_env dpu;
    rdma_status status;

    if (project_cfg == null || env == null || !$cast(dpu, env.get_parent()))
      `uvm_fatal("RDMA_VIRTIO", "RDMA plugin requires a dpu_device_env parent and project_cfg")
    if (project_cfg.rdma_cfg.external_system != null)
      `uvm_fatal("RDMA_VIRTIO",
        "combined env owns the RDMA projection; do not inject a second system")
    project_cfg.rdma_cfg.external_system = rdma_dpu_system::type_id::create("rdma_projection");
    status = project_cfg.rdma_cfg.external_system.bind_snapshot(
      dpu.get_snapshot(), project_cfg.rdma_functions, project_cfg.host_mem_pool_binding);
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO", status.convert2string())
    status = project_cfg.rdma_cfg.external_system.bind_resources(dpu.get_resource_snapshot());
    if (!status.ok())
      `uvm_fatal("RDMA_VIRTIO", status.convert2string())
    if (project_cfg.rdma_cfg.grants.size() != 0) begin
      status = project_cfg.rdma_cfg.external_system.bind_grants(project_cfg.rdma_cfg.grants);
      if (!status.ok())
        `uvm_fatal("RDMA_VIRTIO", status.convert2string())
    end
  endfunction
endclass

// 继承保留 virtio 原始 env 的公共生命周期；project_cfg 与父类 cfg 是同一个 overlay 配置对象。
class rdma_virtio_env extends project_env;
  `uvm_component_utils(rdma_virtio_env)

  project_env_cfg project_cfg;
  rdma_env rdma;
  bit busy;
  bit configured;
  bit init_attempted;

  // 功能：构造尚未配置/初始化的组合环境。
  // 输入/输出及副作用：name/parent 透传，状态位默认零；组件由 build 创建。
  // 失败/边界：父类 cfg 必须是本 integration filelist 提供的 project_env_cfg；RDMA 关闭时不创建子环境。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 功能：完整复用 virtio 项目构建，再在其 DPU 子树加入唯一 RDMA env。
  // 输入/输出及副作用：phase 透传；project_cfg 与继承 cfg 指向同一对象。
  // 失败/边界：cfg 类型不符 fatal；父类负责 Intel VIF、Host pool 和 VIO 配置检查。
  virtual function void build_phase(uvm_phase phase);
    rdma_virtio_bind_plugin binder;

    super.build_phase(phase);
    project_cfg = cfg;
    if (!project_cfg.rdma_enabled)
      return;
    binder = rdma_virtio_bind_plugin::type_id::create("rdma_bind");
    binder.project_cfg = project_cfg;
    project_cfg.rdma_cfg.plugins.push_back(binder);
    uvm_config_db#(rdma_env_cfg)::set(dpu_env, "rdma", "cfg", project_cfg.rdma_cfg);
    rdma = rdma_env::type_id::create("rdma", dpu_env);
  endfunction

  // 功能：复用 virtio 的真实 PCIe/协议连接，在同源 BAR map 上追加 RDMA 单 bank 目录。
  // 输入/输出及副作用：platform_controls 增加 Notify/RNET，通过 DPU publish API 重新冻结配置值。
  // 失败/边界：拒绝重复 RDMA catalog 或无效编码；快照、map、pool 句柄不变，不发送寄存器事务。
  virtual function void connect_phase(uvm_phase phase);
    dpu_control_cfg_t controls[$];
    string why;

    super.connect_phase(phase);
    if (!project_cfg.rdma_enabled)
      return;
    foreach (cfg.dpu_cfg.platform_controls[i])
      if (cfg.dpu_cfg.platform_controls[i].ctx.kind inside {DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET})
        `uvm_fatal("RDMA_VIRTIO",
          "combined env generates the full RDMA catalog; duplicate input is not allowed")
    if (!rdma_project_cfg_seq::make_catalog_for_grants(dpu_env.get_snapshot(), cfg.dpu_cfg.bar_map,
        project_cfg.rdma_functions, project_cfg.rdma_cfg.grants, controls, why))
      `uvm_fatal("RDMA_VIRTIO", why)
    foreach (controls[i])
      cfg.dpu_cfg.platform_controls.push_back(controls[i]);
    // 父类 publish 不是虚函数；使用公共同源重发布契约补齐配置值，不改父仓库或冻结身份。
    // 此时仍在 connect，Tcl/配置 sequence 尚未运行；父类安装的消息和路由保持同一来源。
    if (!cfg.dpu_cfg.publish(dpu_env.get_snapshot(), dpu_env.get_resource_snapshot(),
        cfg.dpu_cfg.bar_map, why))
      `uvm_fatal("RDMA_VIRTIO", why)
  endfunction

  // 功能：先校验 RDMA 候选，再复用父类的 DPU/VIO 全项目事务，最后原地提交 RDMA。
  // 输入/输出及副作用：ok/why 报告结果；成功保留所有 cfg/snapshot/pool 句柄并清 configured。
  // 失败/边界：busy、初始化尝试后、活动 VIO 代或任一候选无效时不提交；不自动释放队列或重新配置 DUT。
  task load_params(output bit ok, output string why);
    rdma_env_cfg candidate;
    rdma_status status;

    ok = 0;
    why = "load_params requires idle project before RDMA initialization";
    if (busy || init_attempted)
      return;
    if (!project_cfg.rdma_enabled) begin
      busy = 1;
      super.load_params(ok, why);
      if (ok)
        configured = 0;
      busy = 0;
      return;
    end
    if (rdma == null)
      return;
    status = rdma_aip_cfg_loader::make_runtime_candidate(project_cfg.rdma_cfg, candidate);
    if (status.ok())
      status = rdma.validate_runtime_candidate(candidate);
    if (!status.ok()) begin
      why = status.convert2string();
      return;
    end
    // 当前 virtio load_params 的候选检查和提交均无等待；前后两侧已通过检查后原子提交。
    // 依赖版本由 dependencies.tsv 固定，不复制父类的 VIO/消息目录重载实现。
    busy = 1;
    super.load_params(ok, why);
    if (ok) begin
      rdma.apply_runtime_candidate(candidate);
      configured = 0;
    end
    busy = 0;
  endtask

  // 功能：在平台准备与写表之前检查组合配置窗口，避免重置仍有活动 ring 的 VIO。
  // 输入/输出及副作用：why 返回拒绝原因；只读 busy、RDMA 初始化状态及各 Host VIO 代。
  // 失败/边界：忙、已尝试 RDMA 初始化或任一 VIO setup 存活时返回假；调用方须显式释放后再配。
  function bit can_configure(output string why);
    why = "dut_config requires idle project before RDMA initialization";
    if (busy || init_attempted)
      return 0;
    foreach (vio_envs[h]) begin
      if (vio_envs[h].get_external_setup() != null) begin
        why = "release existing VIO generation before dut_config";
        return 0;
      end
    end
    why = "";
    return 1;
  endfunction

  // 功能：显式运行共享公共表、RDMA Notify/RNET 和 VIO 队列的单一配置序列。
  // 输入/输出及副作用：ok/why 返回 seq 结果；实际 seq 登记到 AIP 取消 registry。
  // 失败/边界：busy、初始化尝试后、活动 VIO 代或缺管理 RC 拒绝；硬件失败/取消不伪装回滚。
  task configure(output bit ok, output string why);
    dpu_cfg_seq seq;
    dpu_pcie_bar_map map;
    dpu_bar_target_t target;
    uvm_sequencer #(pcie_tl_tlp) rc;

    ok = 0;
    if (!can_configure(why))
      return;
    if (!$cast(map, cfg.dpu_cfg.bar_map) || !map.resolve_name("h0.pf0.bar0", target, why) ||
        !map.get_sequencer(target, rc, why))
      return;
    busy = 1;
    configured = 0;
    if (project_cfg.rdma_enabled) begin
      rdma_virtio_cfg_seq rdma_seq;

      rdma_seq = rdma_virtio_cfg_seq::type_id::create("dut_config");
      rdma_seq.rdma_enabled = 1;
      rdma_seq.rdma_functions = project_cfg.rdma_functions;
      rdma_seq.rdma_grants = project_cfg.rdma_cfg.grants;
      seq = rdma_seq;
    end else begin
      seq = vio_dpu_cfg_seq::type_id::create("dut_config");
    end
    aip_cmd_seq_registry::register("dut_config", seq);
    seq.start(rc);
    aip_cmd_seq_registry::unregister("dut_config");
    configured = seq.success;
    ok = configured;
    why = seq.error_msg;
    busy = 0;
  endtask

  // 功能：在组合配置成功后执行一次 RDMA 硬件/资源初始化。
  // 输入/输出及副作用：status 为核心 initialize 结果，开始尝试即关闭参数重载窗口。
  // 失败/边界：未配置、busy 或重复尝试拒绝；缺真实硬件/grant 仍明确失败，不把 VIO grant 当 RDMA grant。
  task initialize(output rdma_status status);
    if (!project_cfg.rdma_enabled || rdma == null || !configured || busy || init_attempted) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
        "rdma_init requires dut_config and no prior initialization attempt");
      return;
    end
    busy = 1;
    init_attempted = 1;
    rdma.initialize(status);
    busy = 0;
  endtask

  // 功能：从同一权威目录选择两个 Function，复用 RDMA 场景 sequence 创建业务资源并发包。
  // 输入/输出及副作用：first/second 为 global ID，qps 为对称 QP 数；ok/why 返回记分板完成结果。
  // 失败/边界：busy、未ready、重复/不存在的 ID 或零 QP 拒绝；取消保留 busy 以禁止不安全重入。
  task run_traffic(int unsigned first, int unsigned second, int unsigned qps,
                   output bit ok, output string why);
    rdma_traffic_vseq seq;
    int left;
    int right;

    ok = 0;
    why = "rdma_run requires ready RDMA, two valid distinct global IDs and qps>0";
    if (!project_cfg.rdma_enabled || rdma == null || busy || !rdma.is_ready() ||
        first == second || qps == 0)
      return;
    left = rdma.find_function_index(first);
    right = rdma.find_function_index(second);
    if (left < 0 || right < 0)
      return;
    busy = 1;
    seq = rdma_traffic_vseq::type_id::create("rdma_run");
    seq.f0 = left;
    seq.f1 = right;
    seq.qp_count = qps;
    aip_cmd_seq_registry::register("rdma_run", seq);
    seq.start(rdma.vseqr);
    aip_cmd_seq_registry::unregister("rdma_run");
    ok = rdma.sb.errors == 0 && rdma.sb.idle();
    why = ok ? "traffic completed" : "RDMA scoreboard did not drain cleanly";
    busy = 0;
  endtask
endclass
