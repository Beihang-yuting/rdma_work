// 目录/层次：integration/project；RDMA AIP 命令与生命周期适配层。
// 职责：参考 virtio_aip_pkg，把 rdma_env 绑定到唯一命令注册表，并将 rdma_init、rdma_run、rdma_stop
//   映射为可由 Tcl 或其他 AIP 客户端调用的 sequence；本 package 不创建 env、DPU、PCIe 或 Host memory。
// 依赖：aip_core_pkg 提供命令/取消 registry，rdma_env_pkg 提供环境句柄，rdma_project_pkg 提供运行期 sequence。
// 所有权/生命周期：registry 借用外部 rdma_env；命令对象常驻到仿真结束；每次 sequence 由命令 worker 创建并
//   在同一 reset epoch 内登记，stop 只取消仍在登记的流量 sequence。
package rdma_aip_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  import aip_core_pkg::*;
  import rdma_types_pkg::*;
  import rdma_env_pkg::*;
  import rdma_project_pkg::*;
  `include "uvm_macros.svh"

  typedef class rdma_aip_target;
  typedef class rdma_aip_command;

  // 功能：保存一个组合项目的 RDMA 命令目标和最小生命周期状态。
  // 输入/输出及副作用：env 为外部拥有的已连接环境引用；configured/init_attempted/busy 只记录命令门禁，
  //   不复制或接管环境资源。
  // 失败/边界：env 为空时所有命令均拒绝；初始化尝试一旦开始即锁定当前 reset epoch，stop 不解除该锁定。
  class rdma_aip_target;
    rdma_env env;
    bit configured;
    bit init_attempted;
    bit busy;

    // 功能：构造未配置、未初始化的 RDMA 命令目标。
    // 输入/输出及副作用：env 保存非拥有引用；生命周期状态清零，不访问 DUT 或创建 sequence。
    // 失败/边界：空 env 允许构造但不能绑定注册，调用方必须在命令执行前完成 bind_and_register。
    function new(rdma_env env0);
      env = env0;
      configured = 1'b0;
      init_attempted = 1'b0;
      busy = 1'b0;
    endfunction

    // 功能：记录项目配置 sequence 是否成功完成，使 rdma_init 不能绕过 dut_config。
    // 输入/输出及副作用：configured 写入目标门禁；置零不会清除已发生的初始化尝试。
    // 失败/边界：env 不为空但未完成真实表配置时仍可被标记，调用方必须只在配置 sequence 返回后调用。
    function void mark_configured(bit value);
      configured = value;
    endfunction

    // 功能：在 rdma_init 前检查外部 env、配置完成、未重入和未初始化状态。
    // 输入/输出及副作用：why 返回首个拒绝原因；只读状态，不访问 driver。
    // 失败/边界：空 env、configured=0、busy=1 或 init_attempted=1 均拒绝。
    function bit can_initialize(output string why);
      why = "rdma_init requires configured, idle RDMA target";
      if (env == null || !configured || busy || init_attempted)
        return 0;
      why = "";
      return 1;
    endfunction

    // 功能：原子占用初始化门禁，防止多个 Tcl worker 同时 probe 同一个环境。
    // 输入/输出及副作用：成功置 busy/init_attempted；why 输出拒绝原因，不启动 driver。
    // 失败/边界：与 can_initialize 相同；成功后即使底层 probe 失败也不允许在本 epoch 重试。
    function bit begin_initialize(output string why);
      if (!can_initialize(why))
        return 0;
      busy = 1'b1;
      init_attempted = 1'b1;
      why = "";
      return 1;
    endfunction

    // 功能：释放 rdma_init 命令的短期 busy 标志。
    // 输入/输出及副作用：busy 置零；不改变 init_attempted、configured 或 env ready。
    // 失败/边界：重复调用幂等；只有命令 worker 完成 sequence 后才能调用。
    function void end_initialize();
      busy = 1'b0;
    endfunction

    // 功能：检查 rdma_run 是否可以使用已经初始化的环境。
    // 输入/输出及副作用：why 返回拒绝原因；只读 env.ready 和生命周期状态。
    // 失败/边界：空 env、未配置、未初始化、初始化 busy 或 env 尚未 ready 均拒绝。
    function bit can_run(output string why);
      why = "rdma_run requires successful rdma_init and a ready RDMA target";
      if (env == null || !configured || !init_attempted || busy || !env.is_ready())
        return 0;
      why = "";
      return 1;
    endfunction
  endclass

  // 功能：绑定一个 rdma_env，并为其注册三个常驻 AIP 命令。
  // 输入/输出及副作用：bound 输出 registry 持有的目标；成功后创建 rdma_init/rdma_run/rdma_stop 命令对象。
  // 失败/边界：空 env、不同 env 重复绑定或已有同名命令均拒绝；同一 env 重复调用保持幂等。
  class rdma_aip_registry;
    static rdma_aip_target target;

    // 功能：把已连接的 rdma_env 纳入唯一 AIP 命令上下文。
    // 输入/输出及副作用：env 只保存借用引用；bound 返回常驻 target，不启动任何 sequence。
    // 失败/边界：不同环境不能共用同一进程级命令名；已有命令冲突时不留下部分注册。
    static function bit bind_and_register(rdma_env env, output rdma_aip_target bound,
                                          output string why);
      string names[$] = '{"rdma_init", "rdma_run", "rdma_stop"};
      rdma_aip_command command;

      bound = null;
      why = "";
      if (env == null) begin
        why = "RDMA AIP binding requires a non-null rdma_env";
        return 0;
      end
      if (target != null) begin
        if (target.env != env) begin
          why = "RDMA AIP commands are already bound to another rdma_env";
          return 0;
        end
        bound = target;
        return 1;
      end
      foreach (names[i]) begin
        if (aip_cmd::get_handle(names[i]) != null) begin
          why = {"RDMA AIP command already registered: ", names[i]};
          return 0;
        end
      end
      target = new(env);
      foreach (names[i])
        command = new(names[i], names[i], target);
      bound = target;
      return 1;
    endfunction

    // 功能：提供不需要暴露 target 句柄的环境注册入口。
    // 输入/输出及副作用：env 绑定到本 package 的唯一 target，并注册三个常驻命令；why 返回诊断。
    // 失败/边界：沿用带 bound 重载的空 env、异源 env 和命令重名拒绝条件；成功后 target 由 registry 持有。
    static function bit bind_and_register(rdma_env env, output string why);
      rdma_aip_target ignored;

      return bind_and_register(env, ignored, why);
    endfunction

    // 功能：更新绑定 target 的配置完成状态。
    // 输入/输出及副作用：只更新命令门禁；不创建或释放任何 RDMA 资源。
    // 失败/边界：env 为空、未绑定或不是当前 target 时返回假，避免跨项目误改状态。
    static function bit mark_configured(rdma_env env, bit value);
      if (target == null || target.env != env)
        return 0;
      target.mark_configured(value);
      return 1;
    endfunction

    // 功能：查询绑定 target 是否已开始初始化，供项目配置命令阻止反序重配。
    // 输入/输出及副作用：返回只读状态，不改变命令或环境。
    // 失败/边界：未绑定或 env 不匹配返回 0，调用方应把它视为不可用上下文而拒绝操作。
    static function bit initialization_started(rdma_env env);
      return target != null && target.env == env && target.init_attempted;
    endfunction
  endclass

  // 功能：把一个 AIP 命令名映射到 rdma_init/rdma_run/rdma_stop sequence。
  // 输入/输出及副作用：命令对象保存 target 非拥有引用；cmd_exec 结束后通过 AIP 返回 status/result_out。
  // 失败/边界：unknown command、非法参数、生命周期反序和 sequence 失败均返回非零，不伪造完成。
  class rdma_aip_command extends aip_cmd_user_task;
    rdma_aip_target target;
    string operation;

    // 功能：构造并注册一个 RDMA sequence 命令。
    // 输入/输出及副作用：name 注册到 AIP，operation 选择分支，target 保存非拥有引用；构造不启动 sequence。
    // 失败/边界：重复 name 由 AIP registry 报错；空 target 会在执行时返回结构化失败。
    function new(string name, string operation0, rdma_aip_target target0);
      super.new(name);
      operation = operation0;
      target = target0;
      group = "rdma";
      description = "RDMA sequence command";
      param_info = operation == "rdma_run" ?
        "f0=<global id> f1=<global id> [qps=<positive integer>|group=<index>]" : "";
    endfunction

    // 功能：在 AIP 局部结果上下文中执行一个 RDMA 命令，并支持 AIP 原生 wait=0 后台 worker。
    // 输入/输出及副作用：读取 args_in，更新 status/result_out；sequence 登记到取消 registry 后启动。
    // 失败/边界：execute 的拒绝不修改环境；后台取消由 rdma_stop 处理，已发出的 driver 事务不回滚。
    virtual task cmd_exec();
      bit owns_scope;
      bit ok;
      string why;

      owns_scope = begin_macro_result_scope();
      execute(ok, why);
      status = ok ? 0 : 1;
      result_out = why == "" ? (ok ? "OK" : "RDMA command failed") : why;
      end_macro_result_scope(owns_scope);
    endtask

    // 功能：解析当前命令参数并创建对应初始化、流量或停止 sequence。
    // 输入/输出及副作用：可能调用 rdma_env.initialize、创建 QP/CQ/MR、投递 WR 或取消后台 rdma_run；结果写回 ok/why。
    // 失败/边界：初始化和流量的资源门禁由 target 检查；rdma_stop 幂等，不解除初始化 epoch 或释放资源。
    task execute(output bit ok, output string why);
      rdma_init_seq init_seq;
      rdma_run_seq run_seq;
      rdma_stop_seq stop_seq;
      string f0_arg;
      string f1_arg;
      string group_arg;
      string qps_arg;
      longint unsigned f0;
      longint unsigned f1;
      longint unsigned group;
      longint unsigned qps;

      ok = 0;
      why = "RDMA AIP target is unavailable or busy";
      if (target == null || target.env == null || target.busy)
        return;
      if (operation != "rdma_run" && args_in != "") begin
        why = {operation, " takes no arguments"};
        return;
      end
      case (operation)
        "rdma_init": begin
          if (!target.begin_initialize(why))
            return;
          init_seq = rdma_init_seq::type_id::create("rdma_init");
          init_seq.env = target.env;
          aip_cmd_seq_registry::register("rdma_init", init_seq);
          init_seq.start(null);
          aip_cmd_seq_registry::unregister("rdma_init");
          target.end_initialize();
          ok = init_seq.success;
          why = init_seq.error_msg;
        end
        "rdma_run": begin
          f0_arg = aip_cmd::get_arg(args_in, "f0");
          f1_arg = aip_cmd::get_arg(args_in, "f1");
          group_arg = aip_cmd::get_arg(args_in, "group");
          qps_arg = aip_cmd::get_arg(args_in, "qps");
          if (!target.can_run(why))
            return;
          if (group_arg != "") begin
            group = aip_cmd::parse_int64_arg(group_arg, '1);
            if (f0_arg != "" || f1_arg != "" || qps_arg != "" ||
                group >= target.env.cfg.flow_groups.size()) begin
              why = "rdma_run group requires an existing flow group without f0/f1/qps";
              return;
            end
            f0 = target.env.cfg.flow_groups[group].f0_global_id;
            f1 = target.env.cfg.flow_groups[group].f1_global_id;
            qps = target.env.cfg.flow_groups[group].qp_count;
          end else begin
            f0 = aip_cmd::parse_int64_arg(f0_arg, '1);
            f1 = aip_cmd::parse_int64_arg(f1_arg, '1);
            qps = qps_arg == "" ? 1 : aip_cmd::parse_int64_arg(qps_arg, '1);
          end
          if (f0 >= 256 || f1 >= 256 || f0 == f1 || qps == 0 || qps > 32'hffff_ffff) begin
            why = "rdma_run requires two distinct global IDs in [0:255] and positive qps";
            return;
          end
          run_seq = rdma_run_seq::type_id::create("rdma_run");
          run_seq.env = target.env;
          run_seq.f0 = int'(f0);
          run_seq.f1 = int'(f1);
          run_seq.qp_count = int'(qps);
          aip_cmd_seq_registry::register("rdma_run", run_seq);
          run_seq.start(null);
          aip_cmd_seq_registry::unregister("rdma_run");
          ok = run_seq.success;
          why = run_seq.error_msg;
        end
        "rdma_stop": begin
          stop_seq = rdma_stop_seq::type_id::create("rdma_stop");
          aip_cmd_seq_registry::register("rdma_stop", stop_seq);
          stop_seq.start(null);
          aip_cmd_seq_registry::unregister("rdma_stop");
          ok = stop_seq.success;
          why = stop_seq.error_msg;
        end
        default: begin
          why = {"unknown RDMA command: ", operation};
        end
      endcase
    endtask
  endclass
endpackage : rdma_aip_pkg
