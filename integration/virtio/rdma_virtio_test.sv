// 目录/层次：integration/virtio；沿用 virtio project_base_test 平台钩子的显式 Tcl 案例。
// 职责：只替换项目 cfg/env 类型和自动配置 run_phase，保留原始 VIO 业务命令。
// 依赖：AIP user-task/bridge、project_env_pkg；平台实现 bind/prepare/finish 三个既有钩子。
// 所有权/生命周期：test 拥有组合 env；命令常驻借用 test，不在 restore 时再次注册。
typedef class rdma_virtio_test;

// 父类 load_params 不是 virtual，因此用 AIP 公开 unregister API 在 EOE 接管同名入口。
// 单个适配类只负责四个项目命令，结果和异步执行仍走 AIP user-task 的原生机制。
class rdma_virtio_command extends aip_cmd_user_task;
  rdma_virtio_test owner_test;

  // 功能：注册一个项目命令并借用唯一 test 上下文。
  // 输入/输出及副作用：name 为 AIP 名称，owner 在构建完成后传入；super 将对象登记至 registry。
  // 失败/边界：调用方先确认名称空闲，重复名称保留 AIP 原有报错；owner_test 生命周期覆盖 bridge。
  function new(string name, rdma_virtio_test owner);
    super.new(name);
    owner_test = owner;
  endfunction

  // 功能：按 AIP 宏相同的局部结果作用域执行本命令。
  // 输入/输出及副作用：读取 args_in，更新 status/result_out；支持原生 wait=0 和取消路径。
  // 失败/边界：普通拒绝非零返回，平台 fatal 保持终止语义；不在命令结束时重置项目 busy。
  extern virtual task cmd_exec();

  // 功能：校验参数后分派统一重载、平台准备/配置、RDMA 初始化或指定业务边。
  // 输入/输出及副作用：ok/why 返回项目结果；dut_config 是唯一调用 prepare_platform 的入口。
  // 失败/边界：空上下文、重入、错误参数、未初始化或无效 group/端点拒绝，不自动补调用其他命令。
  extern task execute(output bit ok, output string why);
endclass

// 不继承 virtio 自动 configure 的 run 顺序；平台仍实现相同的三个纯虚钩子。
virtual class rdma_virtio_test extends project_base_test;
  rdma_virtio_env project;
  bit commands_registered;

  // 功能：创建可由真实平台继承的测试壳。
  // 输入/输出及副作用：name/parent 传给 virtio 基类；不启动 bridge、配置或业务。
  // 失败/边界：本类为虚类，平台必须实现 bind_platform_handles/prepare_platform/finish_platform。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 功能：在 virtio 原构建流程中使用组合 cfg 和 env，保留其平台句柄注入时机。
  // 输入/输出及副作用：允许 config_db 提供派生 cfg；局部 factory override 只影响本 test 的 env。
  // 失败/边界：用户提供的 cfg 必须可转为 rdma_virtio_env_cfg，否则 fatal；不修改外部仓库或全局类型。
  virtual function void build_phase(uvm_phase phase);
    rdma_virtio_env_cfg combined;

    if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg)) begin
      combined = rdma_virtio_env_cfg::type_id::create("cfg");
      cfg = combined;
      uvm_config_db#(project_env_cfg)::set(this, "", "project_cfg", cfg);
    end
    if (!$cast(combined, cfg))
      `uvm_fatal("RDMA_VIRTIO_TEST", "project_cfg must include both VIO and RDMA configuration")
    project_env::type_id::set_inst_override(rdma_virtio_env::get_type(), "env", this);
    super.build_phase(phase);
    if (!$cast(project, env))
      `uvm_fatal("RDMA_VIRTIO_TEST", "combined project env was not created")
  endfunction

  // 功能：在全部连接完成后登记 VIO 业务和四个项目命令，统一接管 load_params。
  // 输入/输出及副作用：原 vio_release 及 VIO 业务实现保留；load_params registry 始终只有一个有效对象。
  // 失败/边界：重复调用或已有第三方同名命令 fatal；只允许替换父 package 自带的 load_params 对象。
  virtual function void end_of_elaboration_phase(uvm_phase phase);
    project_env_pkg::__aip_cmd_load_params inherited_loader;
    rdma_virtio_command command;
    string names[$] = '{"dut_config", "rdma_init", "rdma_run"};

    super.end_of_elaboration_phase(phase);
    if (commands_registered || !$cast(inherited_loader, aip_cmd::get_handle("load_params")))
      `uvm_fatal("RDMA_VIRTIO_TEST", "load_params is not the original virtio project command")
    foreach (names[i])
      if (aip_cmd::get_handle(names[i]) != null)
        `uvm_fatal("RDMA_VIRTIO_TEST", {"project command already exists: ", names[i]})
    project.register_aip_commands();
    aip_cmd::unregister("load_params");
    names.push_back("load_params");
    foreach (names[i])
      command = new(names[i], this);
    commands_registered = 1;
  endfunction

  // 功能：仅运行 Tcl bridge 和原平台收尾，取消 virtio 示例原有的自动准备/配置。
  // 输入/输出及副作用：objection 覆盖 run_loop 和 finish；Tcl 可显式选择 VIO 或 RDMA 业务。
  // 失败/边界：没有命令就不会配置、初始化或发包；finish 必须核对真实完成并按平台契约释放资源。
  virtual task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    aip_tcl_bridge::run_loop();
    finish_platform();
    phase.drop_objection(this);
  endtask
endclass

// 功能：按 AIP 宏相同的局部结果作用域执行本命令。
// 输入/输出及副作用：读取 args_in，更新 status/result_out；支持原生 wait=0 和取消路径。
// 失败/边界：普通拒绝非零返回，平台 fatal 保持终止语义；不在命令结束时重置项目 busy。
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

// 功能：校验参数后分派统一重载、平台准备/配置、RDMA 初始化或指定业务边。
// 输入/输出及副作用：ok/why 返回项目结果；dut_config 是唯一调用 prepare_platform 的入口。
// 失败/边界：空上下文、重入、错误参数、未初始化或无效 group/端点拒绝，不自动补调用其他命令。
task rdma_virtio_command::execute(output bit ok, output string why);
  rdma_virtio_env project;
  rdma_status init_status;
  string group_arg;
  string first_arg;
  string second_arg;
  string qps_arg;
  longint unsigned first;
  longint unsigned second;
  longint unsigned qps;
  longint unsigned group_index;

  ok = 0;
  why = "project unavailable or busy";
  if (owner_test == null || owner_test.project == null || owner_test.project.busy)
    return;
  project = owner_test.project;
  if (cmd_name != "rdma_run" && args_in != "") begin
    why = {cmd_name, " takes no arguments"};
    return;
  end
  case (cmd_name)
    "load_params": project.load_params(ok, why);
    "dut_config": begin
      if (!project.can_configure(why))
        return;
      project.busy = 1;
      owner_test.prepare_platform();
      project.busy = 0;
      project.configure(ok, why);
    end
    "rdma_init": begin
      project.initialize(init_status);
      ok = init_status.ok();
      why = init_status.convert2string();
    end
    "rdma_run": begin
      group_arg = aip_cmd::get_arg(args_in, "group");
      first_arg = aip_cmd::get_arg(args_in, "f0");
      second_arg = aip_cmd::get_arg(args_in, "f1");
      qps_arg = aip_cmd::get_arg(args_in, "qps");
      if (group_arg != "") begin
        group_index = aip_cmd::parse_int64_arg(group_arg, '1);
        if (first_arg != "" || second_arg != "" || qps_arg != "" ||
            group_index >= project.project_cfg.rdma_cfg.flow_groups.size()) begin
          why = "group must name an existing RDMA flow group without f0/f1/qps";
          return;
        end
        first = project.project_cfg.rdma_cfg.flow_groups[group_index].f0_global_id;
        second = project.project_cfg.rdma_cfg.flow_groups[group_index].f1_global_id;
        qps = project.project_cfg.rdma_cfg.flow_groups[group_index].qp_count;
      end else begin
        first = aip_cmd::parse_int64_arg(first_arg, '1);
        second = aip_cmd::parse_int64_arg(second_arg, '1);
        qps = qps_arg == "" ? 1 : aip_cmd::parse_int64_arg(qps_arg, '1);
      end
      if (first >= 256 || second >= 256 || qps == 0 || qps > 32'hffff_ffff) begin
        why = "rdma_run requires f0/f1 global IDs in [0:255] and positive 32-bit qps";
        return;
      end
      project.run_traffic(first, second, qps, ok, why);
    end
    default: why = "unknown project command";
  endcase
endtask
