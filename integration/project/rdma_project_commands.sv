// 目录/层次：integration/project；最终test package显式纳入的命令注册示例。
// 职责：保持五个唯一入口，参数读取/取消复用AIP；普通失败均写非零status/result_out。
// 依赖：同一编译单元project_context与project_rc_sqr；禁止由可复用包自动include。
// 所有权/生命周期：宏注册对象常驻，context/RC是非拥有引用；恢复不重复注册。

// 功能：在调用任何项目操作前验证最终案例上下文。
// 输入/输出及副作用：handle为同名命令句柄，失败写status/result_out。
// 失败/边界：未connect或prepare进行中拒绝，不等待其他命令解除状态。
function bit rdma_project_command_ready(aip_cmd	handle);
  if (project_context == null || project_context.project == null || project_context.preparing) begin
    handle.status = 1;
    handle.result_out = "project is unavailable or platform preparation is active";
    return 0;
  end
  return 1;
endfunction

// 功能：把正常返回的项目结果写回AIP，防止宏空结果补OK。
// 输入/输出及副作用：handle/ok/why输入，更新该次命令status/result_out。
// 失败/边界：空why也明确给出成功/失败文字，不处理父类fatal。
function void rdma_project_command_result(aip_cmd	handle, bit	ok, string	why);
  handle.status = ok ? 0 : 1;
  handle.result_out = why == "" ? (ok ? "OK" : "project operation failed") : why;
endfunction

// 功能：先检查生命周期、准备平台，再运行独立配置sequence。
// 输入/输出及副作用：读取dut_config handle，prepare只能从这里调用，结果写回同名handle。
// 失败/边界：busy/初始化后拒绝且不prepare；prepare失败无配置，配置fatal保持原契约。
task project_dut_config();
  aip_cmd	handle;
  bit	ok;
  string	why;

  handle = aip_cmd::get_handle("dut_config");
  if (!rdma_project_command_ready(handle))
    return;
  if (project_context.project.busy || project_context.project.init_attempted) begin
    rdma_project_command_result(handle, 0, "dut_config requires idle pre-initialization lifecycle");
    return;
  end
  project_context.preparing = 1;
  project_context.prepare_platform(ok, why);
  project_context.preparing = 0;
  if (ok) project_context.project.configure(ok, why);
  rdma_project_command_result(handle, ok, why);
endtask

// 功能：显式初始化已配置项目，不等待后续dut_config。
// 输入/输出及副作用：读取rdma_init handle，调用一次initialize并返回结构化错误文字。
// 失败/边界：反序/重复或硬件初始化失败均非零，失败尝试不可重载重试。
task project_rdma_init();
  aip_cmd	handle;
  rdma_status	status;

  handle = aip_cmd::get_handle("rdma_init");
  if (!rdma_project_command_ready(handle))
    return;
  project_context.project.initialize(status);
  rdma_project_command_result(handle, status.ok(), status.convert2string());
endtask

// 功能：按显式 f0/f1 global ID 或已配置 group 索引启动统一场景；可选 qps 控制该业务边的对称 QP 数量。
// 输入/输出及副作用：rdma_run handle 的数字参数使用 AIP 既有解析；完成状态写回 handle。
// 失败/边界：group 与 f0/f1 不能混用，缺键/非法数字/不存在或重复端点/零 QP 拒绝，绝不默认绑定第二端点。
task project_rdma_run();
  aip_cmd	handle;
  string	first;
  string	second;
  string	group_arg;
  string	qps_arg;
  string	why;
  bit	ok;
  longint unsigned	left;
  longint unsigned	right;
  longint unsigned	group;
  longint unsigned	qps;

  handle = aip_cmd::get_handle("rdma_run");
  if (!rdma_project_command_ready(handle))
    return;
  group_arg = aip_cmd::get_arg(handle.args_in, "group");
  first = aip_cmd::get_arg(handle.args_in, "f0");
  second = aip_cmd::get_arg(handle.args_in, "f1");
  qps_arg = aip_cmd::get_arg(handle.args_in, "qps");
  if (group_arg != "") begin
    group = aip_cmd::parse_int64_arg(group_arg, '1);
    if (first != "" || second != "" || group == '1) begin
      rdma_project_command_result(handle, 0, "rdma_run group requires a valid group index without f0/f1");
      return;
    end
    project_context.project.run_flow_group(group, ok, why);
    rdma_project_command_result(handle, ok, why);
    return;
  end
  left = aip_cmd::parse_int64_arg(first, '1);
  right = aip_cmd::parse_int64_arg(second, '1);
  qps = qps_arg == "" ? 1 : aip_cmd::parse_int64_arg(qps_arg, '1);
  if (first == "" || second == "" || left >= 256 || right >= 256 || qps == 0 || qps == '1) begin
    rdma_project_command_result(handle, 0, "rdma_run requires explicit f0/f1 global IDs in [0:255]");
    return;
  end
  project_context.project.run_traffic(left, right, qps, ok, why);
  rdma_project_command_result(handle, ok, why);
endtask

// 功能：调用项目唯一候选事务，不分别提交DPU或RDMA loader。
// 输入/输出及副作用：读取load_params同名handle并返回事务状态。
// 失败/边界：活动或任一候选失败保持原对象和值，恢复后也必须显式调用。
task rdma_project_load_params();
  aip_cmd	handle;
  bit	ok;
  string	why;

  handle = aip_cmd::get_handle("load_params");
  if (!rdma_project_command_ready(handle))
    return;
  project_context.project.load_params(ok, why);
  rdma_project_command_result(handle, ok, why);
endtask

`aip_cmd_task(dut_config, project_dut_config)
`aip_cmd_task(rdma_init, project_rdma_init)
`aip_cmd_task(rdma_run, project_rdma_run)
`aip_cmd_task(load_params, rdma_project_load_params)
`aip_cmd_reg(reg_acc, dpu_bar_reg_seq, project_rc_sqr, seq.error_msg, seq.check_read_data)
