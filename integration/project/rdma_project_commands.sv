// 目录/层次：integration/project；独立 RDMA 案例的 Tcl 命令注册与 sequence 启动入口。
// 职责：保持参数加载、硬件配置、RDMA 初始化和流量四个显式入口；命令只负责生命周期校验、参数解析和启动 sequence。
// 依赖：同一编译单元的 project_context/project_rc_sqr、rdma_project_pkg 与
//   rdma_project_runtime_pkg；不自动 include。
// 所有权/生命周期：命令借用当前 test、env 和 RC；sequence 在命令中创建并登记到 AIP 取消 registry，恢复不重复注册。

// 功能：在调用任何项目操作前验证最终案例上下文。
// 输入/输出及副作用：handle 为同名命令句柄，失败写 status/result_out。
// 失败/边界：未 connect 或 prepare 进行中拒绝，不等待其他命令解除状态。
function bit rdma_project_command_ready(aip_cmd handle);
  if (project_context == null || project_context.project == null || project_context.preparing) begin
    handle.status = 1;
    handle.result_out = "project is unavailable or platform preparation is active";
    return 0;
  end
  return 1;
endfunction

// 功能：把正常返回的项目结果写回 AIP，避免命令宏用空结果补 OK。
// 输入/输出及副作用：handle/ok/why 为输入，更新本次命令的 status/result_out。
// 失败/边界：why 为空时仍输出明确成功/失败文字，不处理父类 fatal。
function void rdma_project_command_result(aip_cmd handle, bit ok, string why);
  handle.status = ok ? 0 : 1;
  handle.result_out = why == "" ? (ok ? "OK" : "project operation failed") : why;
endfunction

// 功能：准备平台并启动 RDMA-only 配置 sequence，向管理 BAR 写入公共、Notify 和 RNET 表。
// 输入/输出及副作用：读取 dut_config handle，调用一次 prepare_platform 和 rdma_project_cfg_seq；成功更新 test.configured。
// 失败/边界：busy/初始化后/无 RC/prepare 失败或 BAR map 打印失败不启动 sequence；sequence 失败可在未初始化前重试。
task project_dut_config();
  aip_cmd handle;
  rdma_project_cfg_seq seq;
  bit ok;
  string why;

  handle = aip_cmd::get_handle("dut_config");
  if (!rdma_project_command_ready(handle))
    return;
  if (project_context.busy || project_context.init_attempted) begin
    rdma_project_command_result(handle, 0, "dut_config requires idle pre-initialization lifecycle");
    return;
  end
  if (project_context.project.rc == null) begin
    rdma_project_command_result(handle, 0, "dut_config requires a bound management RC");
    return;
  end

  project_context.preparing = 1;
  project_context.prepare_platform(ok, why);
  project_context.preparing = 0;
  if (!ok) begin
    rdma_project_command_result(handle, 0, why);
    return;
  end

  project_context.busy = 1;
  project_context.configured = 0;
  if (project_context.project.cfg.dpu.print_bar_map) begin
    if (!project_context.project.cfg.dpu.bar_map.print_bar_map(why, 1)) begin
      project_context.busy = 0;
      rdma_project_command_result(handle, 0, why);
      return;
    end
    project_context.prints++;
  end
  seq = rdma_project_cfg_seq::type_id::create("project_configuration");
  seq.rdma_functions = project_context.project.cfg.functions;
  seq.rdma_grants = project_context.project.cfg.rdma.grants;
  seq.hw_plan = project_context.project.cfg.hw_plan;
  aip_cmd_seq_registry::register("dut_config", seq);
  seq.start(project_context.project.rc);
  aip_cmd_seq_registry::unregister("dut_config");
  project_context.configured = seq.success;
  project_context.busy = 0;
  rdma_project_command_result(handle, seq.success, seq.error_msg);
endtask

// 功能：显式启动 RDMA 初始化 sequence，完成 probe、资源登记和 ready 发布。
// 输入/输出及副作用：读取 rdma_init handle，借用 project.rdma 执行一次 rdma_init_seq。
// 失败/边界：未成功配置、busy、重复初始化或空环境拒绝；初始化失败仍锁定当前 reset epoch，不允许重试。
task project_rdma_init();
  aip_cmd handle;
  rdma_init_seq seq;

  handle = aip_cmd::get_handle("rdma_init");
  if (!rdma_project_command_ready(handle))
    return;
  if (project_context.project.rdma == null) begin
    rdma_project_command_result(handle, 0, "rdma_init requires an RDMA-enabled project");
    return;
  end
  if (!project_context.configured || project_context.busy || project_context.init_attempted) begin
    rdma_project_command_result(handle, 0,
      "rdma_init requires successful dut_config and no previous initialization attempt");
    return;
  end

  project_context.busy = 1;
  project_context.init_attempted = 1;
  seq = rdma_init_seq::type_id::create("rdma_init");
  seq.env = project_context.project.rdma;
  aip_cmd_seq_registry::register("rdma_init", seq);
  seq.start(null);
  aip_cmd_seq_registry::unregister("rdma_init");
  project_context.busy = 0;
  rdma_project_command_result(handle, seq.success, seq.error_msg);
endtask

// 功能：解析显式 global Function ID 或 flow group，并启动 RDMA 流量 sequence。
// 输入/输出及副作用：读取 rdma_run 的 f0/f1/group/qps 参数，借用 project.rdma 创建 QP、投递报文并等待 scoreboard 排空。
// 失败/边界：group 不能与端点/qps 混用；未初始化、未知/相同端点、零或超范围 QP 均不创建业务资源。
task project_rdma_run();
  aip_cmd handle;
  rdma_run_seq seq;
  string first_arg;
  string second_arg;
  string group_arg;
  string qps_arg;
  string why;
  bit ok;
  longint unsigned first;
  longint unsigned second;
  longint unsigned group;
  longint unsigned qps;

  handle = aip_cmd::get_handle("rdma_run");
  if (!rdma_project_command_ready(handle))
    return;
  first_arg = aip_cmd::get_arg(handle.args_in, "f0");
  second_arg = aip_cmd::get_arg(handle.args_in, "f1");
  group_arg = aip_cmd::get_arg(handle.args_in, "group");
  qps_arg = aip_cmd::get_arg(handle.args_in, "qps");
  if (group_arg != "") begin
    group = aip_cmd::parse_int64_arg(group_arg, '1);
    if (first_arg != "" || second_arg != "" || qps_arg != "" ||
        group == '1 || group >= project_context.project.cfg.rdma.flow_groups.size()) begin
      rdma_project_command_result(handle, 0,
        "rdma_run group requires an existing index without f0/f1/qps");
      return;
    end
    first = project_context.project.cfg.rdma.flow_groups[group].f0_global_id;
    second = project_context.project.cfg.rdma.flow_groups[group].f1_global_id;
    qps = project_context.project.cfg.rdma.flow_groups[group].qp_count;
  end else begin
    first = aip_cmd::parse_int64_arg(first_arg, '1);
    second = aip_cmd::parse_int64_arg(second_arg, '1);
    qps = qps_arg == "" ? 1 : aip_cmd::parse_int64_arg(qps_arg, '1);
  end
  if (!project_context.configured || !project_context.init_attempted || project_context.busy ||
      project_context.project.rdma == null || !project_context.project.rdma.is_ready() ||
      first == '1 || second == '1 || first >= 256 || second >= 256 || first == second ||
      qps == 0 || qps == '1 || qps > 32'hffff_ffff) begin
    rdma_project_command_result(handle, 0,
      "rdma_run requires rdma_init and valid distinct global IDs in [0:255] with positive qps");
    return;
  end

  seq = rdma_run_seq::type_id::create("rdma_run");
  seq.env = project_context.project.rdma;
  seq.f0 = int'(first);
  seq.f1 = int'(second);
  seq.qp_count = int'(qps);
  project_context.busy = 1;
  aip_cmd_seq_registry::register("rdma_run", seq);
  seq.start(null);
  aip_cmd_seq_registry::unregister("rdma_run");
  project_context.busy = 0;
  ok = seq.success;
  why = seq.error_msg;
  rdma_project_command_result(handle, ok, why);
endtask

// 功能：调用项目唯一参数候选事务，保持 DPU/RDMA 参数在同一个提交点。
// 输入/输出及副作用：读取 load_params handle，更新同名命令结果，不发送 MMIO 或启动 driver。
// 失败/边界：活动 sequence、初始化尝试或任一候选失败保持原对象和值；恢复后仍需显式调用。
task rdma_project_load_params();
  aip_cmd handle;
  bit ok;
  string why;

  handle = aip_cmd::get_handle("load_params");
  if (!rdma_project_command_ready(handle))
    return;
  if (project_context.busy || project_context.init_attempted) begin
    rdma_project_command_result(handle, 0,
      "load_params requires idle pre-initialization lifecycle");
    return;
  end
  project_context.project.load_params(ok, why);
  if (ok)
    project_context.configured = 0;
  rdma_project_command_result(handle, ok, why);
endtask

`aip_cmd_task(dut_config, project_dut_config)
`aip_cmd_task(rdma_init, project_rdma_init)
`aip_cmd_task(rdma_run, project_rdma_run)
`aip_cmd_task(load_params, rdma_project_load_params)
`aip_cmd_reg(reg_acc, dpu_bar_reg_seq, project_rc_sqr, seq.error_msg, seq.check_read_data)
