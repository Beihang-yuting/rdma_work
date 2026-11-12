// 目录/层次：integration/virtio；组合项目的 Tcl 配置命令与平台 hook 入口。
// 职责：复用 virtio_work 的 cfg/build/connect 和平台 hook；VIO 由 project_env 绑定，RDMA init/run/stop
//   由本组合 test 在连接完成后交给 rdma_aip_pkg 注册，本文件保留平台 prepare、dut_config 与统一 load_params。
// 依赖：project_base_test、project_env、rdma_project_pkg、rdma_virtio_cfg_seq；平台实现三个既有 hook。
// 所有权/生命周期：test 借用 project_env 及其子组件；sequence 由命令临时拥有，env 不启动任何运行期 sequence。
typedef class rdma_virtio_test;

// 父类 load_params 不是 virtual，因此用 AIP 公开 unregister API 接管同名入口；RDMA 业务命令不在本类重复注册。
// 本类命令只解析参数、准备平台和启动配置 sequence，不把 RDMA 初始化/流量实现塞回 test。
class rdma_virtio_command extends aip_cmd_user_task;
  rdma_virtio_test owner_test;

  // 功能：构造一个绑定唯一组合 test 的项目 Tcl 命令。
  // 输入/输出及副作用：name 注册到 AIP，owner 保存为非拥有引用；不启动 sequence 或访问 env。
  // 失败/边界：owner 为空时命令执行会返回结构化错误；重复命令名由注册阶段拒绝。
  function new(string name, rdma_virtio_test owner);
    super.new(name);
    owner_test = owner;
  endfunction

  // 功能：在 AIP 宏结果作用域内执行项目命令并返回 status/result_out。
  // 输入/输出及副作用：读取 args_in，允许 wait=0/取消由 AIP 基类处理；不改变 busy 的最终语义。
  // 失败/边界：普通拒绝写非零状态，平台 fatal 保持原 UVM 终止契约。
  extern virtual task cmd_exec();

  // 功能：校验命令上下文并分派参数重载、DUT 配置、RDMA 初始化或流量 sequence。
  // 输入/输出及副作用：ok/why 返回命令结果；仅 dut_config 调用 prepare_platform，其余命令不隐式补步骤。
  // 失败/边界：空上下文、重入、反序生命周期、非法参数和未知 Function 均拒绝且不创建对应资源。
  extern task execute(output bit ok, output string why);
endclass

// 组合 test 不派生新的 env：project_base_test 直接创建本 filelist 提供的 project_env。
// project_env 只负责组件 build/connect 和 virtio_work 契约中的 load_params/vio_release。
virtual class rdma_virtio_test extends project_base_test;
  project_env project;
  bit commands_registered;
  bit busy;
  bit configured;

  // 功能：构造可由真实平台继承的 Tcl 驱动 test 外壳。
  // 输入/输出及副作用：name/parent 透传；运行期状态从空闲、未配置、未初始化开始。
  // 失败/边界：本类为虚类，派生平台必须实现 bind_platform_handles/prepare_platform/finish_platform。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 功能：使用 integration project_env_cfg 并让基类直接创建同名 project_env。
  // 输入/输出及副作用：向 config_db 发布唯一 cfg；build 后 project 与 env 指向同一组件。
  // 失败/边界：cfg 类型缺失或 env 不是本 overlay 的 project_env 时 fatal，不使用 factory 派生 env。
  virtual function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg)) begin
      cfg = project_env_cfg::type_id::create("cfg");
      uvm_config_db#(project_env_cfg)::set(this, "", "project_cfg", cfg);
    end
    super.build_phase(phase);
    if (!$cast(project, env))
      `uvm_fatal("RDMA_VIRTIO_TEST", "project_base_test did not create the integration project_env")
  endfunction

  // 功能：检查是否仍处于可以启动 dut_config 的空闲窗口。
  // 输入/输出及副作用：只读 busy、RDMA AIP 初始化状态和各 Host VIO setup，why 返回首个拒绝原因。
  // 失败/边界：已有配置 sequence、RDMA 初始化尝试或活动 VIO ring 时拒绝，不自动释放或重置。
  function bit can_configure(output string why);
    why = "dut_config requires an idle pre-initialization project";
    if (busy || rdma_aip_registry::initialization_started(project.rdma))
      return 0;
    foreach (project.vio_envs[h]) begin
      if (project.vio_envs[h].get_external_setup() != null) begin
        why = "release existing VIO generation before dut_config";
        return 0;
      end
    end
    why = "";
    return 1;
  endfunction

  // 功能：判断组合环境是否存在实际 VIO Function，用于选择 RDMA-only 或合并配置 sequence。
  // 输入/输出及副作用：只读各 Host 的 function_instances；返回值不改变配置或组件状态。
  // 失败/边界：空 Host/VIO 返回假，RDMA-only sequence 仍可配置 RDMA 表。
  function bit has_vio_functions();
    foreach (project.vio_envs[h])
      if (project.vio_envs[h].function_instances.size() != 0)
        return 1;
    return 0;
  endfunction

  // 功能：从冻结 BAR map 找到管理 RC sequencer，供配置 sequence 发送公共/RDMA 表事务。
  // 输入/输出及副作用：rc 输出借用句柄；只读 cfg.dpu_cfg.bar_map，不发送 PCIe 请求。
  // 失败/边界：map 未发布、h0.pf0.bar0 缺失或无 sequencer 时返回假，调用方不得启动 sequence。
  function bit get_management_rc(output uvm_sequencer #(pcie_tl_tlp) rc, output string why);
    dpu_pcie_bar_map map;
    dpu_bar_target_t target;

    rc = null;
    why = "project PCIe BAR map is not ready";
    if (!$cast(map, cfg.dpu_cfg.bar_map) || map == null)
      return 0;
    return map.resolve_name("h0.pf0.bar0", target, why) && map.get_sequencer(target, rc, why);
  endfunction

  // 功能：在全部连接完成后登记 VIO/RDMA package 命令，并替换原 load_params 命令。
  // 输入/输出及副作用：VIO 绑定由 project_env 复用 virtio_work 入口；RDMA 由本 test 把已连接 env
  //   交给 rdma_aip_pkg；本 test 另外注册 dut_config 和统一 loader，保留 AIP 唯一参数加载入口。
  // 失败/边界：原 loader 缺失、RDMA env 为空、命令重名或重复 EOE 立即 fatal，不注册第二个加载范围。
  virtual function void end_of_elaboration_phase(uvm_phase phase);
    project_env_pkg::__aip_cmd_load_params inherited_loader;
    rdma_virtio_command command;
    string why;
    string names[$] = '{"dut_config"};

    super.end_of_elaboration_phase(phase);
    if (commands_registered || !$cast(inherited_loader, aip_cmd::get_handle("load_params")))
      `uvm_fatal("RDMA_VIRTIO_TEST", "load_params is not the original virtio project command")
    foreach (names[i])
      if (aip_cmd::get_handle(names[i]) != null)
        `uvm_fatal("RDMA_VIRTIO_TEST", {"project command already exists: ", names[i]})

    project.register_aip_commands();
    if (cfg.rdma_enabled &&
        !rdma_aip_registry::bind_and_register(project.rdma, why))
      `uvm_fatal("RDMA_AIP", why)
    aip_cmd::unregister("load_params");
    names.push_back("load_params");
    foreach (names[i])
      command = new(names[i], this);
    commands_registered = 1;
  endfunction

  // 功能：只运行 Tcl bridge 和平台收尾，不自动准备、配置、初始化或发包。
  // 输入/输出及副作用：objection 覆盖 bridge 生命周期；所有操作必须由 Tcl 命令显式触发。
  // 失败/边界：没有命令时仿真保持空闲；finish_platform 仍需检查真实业务完成和外部资源回收。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    aip_tcl_bridge::run_loop();
    finish_platform();
    phase.drop_objection(this);
  endtask
endclass

// 功能：按 AIP 宏相同的局部结果作用域执行一个项目命令。
// 输入/输出及副作用：更新 status/result_out；wait=0 和取消交给 AIP 基类，sequence 由 execute 启动。
// 失败/边界：execute 失败不会改写 project 的生命周期状态为成功。
task rdma_virtio_command::cmd_exec();
  bit owns_scope;
  bit ok;
  string why;

  owns_scope = begin_macro_result_scope();
  execute(ok, why);
  status = ok ? 0 : 1;
  result_out = why == "" ? (ok ? "OK" : "project command failed") : why;
  end_macro_result_scope(owns_scope);
endtask

// 功能：准备平台并启动配置或参数重载 sequence；RDMA init/run/stop 由 rdma_aip_pkg 独立处理。
// 输入/输出及副作用：可能调用平台 prepare、发送 DPU/VIO/RDMA 表事务；结果写回 ok/why。
// 失败/边界：命令不自动串联缺失步骤；配置失败不标记 RDMA 可初始化，参数重载失败保持原配置。
task rdma_virtio_command::execute(output bit ok, output string why);
  uvm_sequencer #(pcie_tl_tlp) rc;

  ok = 0;
  why = "project unavailable or busy";
  if (owner_test == null || owner_test.project == null || owner_test.busy)
    return;
  if (cmd_name != "dut_config" && args_in != "") begin
    why = {cmd_name, " takes no arguments"};
    return;
  end

  case (cmd_name)
    "load_params": begin
      owner_test.project.load_params(ok, why);
      if (ok) begin
        owner_test.configured = 0;
        void'(rdma_aip_registry::mark_configured(owner_test.project.rdma, 0));
      end
    end
    "dut_config": begin
      dpu_cfg_seq config_seq;

      if (!owner_test.can_configure(why))
        return;
      if (!owner_test.get_management_rc(rc, why))
        return;
      owner_test.busy = 1;
      owner_test.configured = 0;
      void'(rdma_aip_registry::mark_configured(owner_test.project.rdma, 0));
      owner_test.prepare_platform();
      if (owner_test.cfg.rdma_enabled) begin
        if (owner_test.has_vio_functions()) begin
          rdma_virtio_cfg_seq merged_seq;

          merged_seq = rdma_virtio_cfg_seq::type_id::create("dut_config");
          merged_seq.rdma_enabled = 1;
          merged_seq.rdma_functions = owner_test.cfg.rdma_functions;
          merged_seq.rdma_grants = owner_test.cfg.rdma_cfg.grants;
          config_seq = merged_seq;
        end else begin
          rdma_project_cfg_seq rdma_seq;

          rdma_seq = rdma_project_cfg_seq::type_id::create("dut_config");
          rdma_seq.rdma_functions = owner_test.cfg.rdma_functions;
          rdma_seq.rdma_grants = owner_test.cfg.rdma_cfg.grants;
          config_seq = rdma_seq;
        end
      end else begin
        config_seq = vio_dpu_cfg_seq::type_id::create("dut_config");
      end
      aip_cmd_seq_registry::register("dut_config", config_seq);
      config_seq.start(rc);
      aip_cmd_seq_registry::unregister("dut_config");
      owner_test.configured = config_seq.success;
      void'(rdma_aip_registry::mark_configured(owner_test.project.rdma, config_seq.success));
      ok = config_seq.success;
      why = config_seq.error_msg;
      owner_test.busy = 0;
    end
    default: begin
      why = {"unknown project command: ", cmd_name};
    end
  endcase
endtask
