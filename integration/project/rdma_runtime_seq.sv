// 目录/层次：integration/project；RDMA 运行期 sequence 入口。
// 职责：把基础 rdma_env 的初始化和业务流量封装成可由任意项目 Tcl 命令启动的 sequence；不创建 env、
//   不解析 dpu_common 身份，也不拥有 snapshot、Host memory 或 driver 资源；stop sequence 只取消
//   AIP 登记的业务 sequence，不假设已经发出的 PCIe/DMA 事务可以回滚。
// 依赖：rdma_env_pkg 提供 rdma_env/rdma_vsequencer，rdma_traffic_vseq 提供业务资源和报文流程，
//   aip_core_pkg 提供 sequence 取消登记。
// 所有权/生命周期：sequence 只借用 env；调用方拥有 sequence 句柄并在同一 reset epoch 内启动一次。

// 功能：显式执行 RDMA 环境的 probe、资源登记和 ready 发布。
// 输入/输出及副作用：env 为已 build/connect 的基础环境；body 完成后 status/success/error_msg 可读，
//   可能产生真实 driver probe、EQ/资源登记和 link/plugin 启动副作用。
// 失败/边界：env 为空或 initialize 已开始时返回结构化失败；失败尝试不提供重试入口，调用方必须停止当前 epoch。
class rdma_init_seq extends uvm_sequence;
  `uvm_object_utils(rdma_init_seq)

  rdma_env env;
  rdma_status status;
  bit success;
  string error_msg;

  // 功能：构造尚未绑定环境的初始化 sequence。
  // 输入/输出及副作用：name 传给 UVM；env 为空、success=0，构造不访问 DUT。
  // 失败/边界：启动前必须由 Tcl 命令绑定同一 project_env.rdma；sequence 不自行创建替代环境。
  function new(string name = "rdma_init_seq");
    super.new(name);
    success = 0;
    error_msg = "RDMA initialization sequence has not run";
  endfunction

  // 功能：调用基础 rdma_env.initialize，完成 probe 和资源就绪，不启动业务流量。
  // 输入/输出及副作用：更新 status/success/error_msg；失败保持 ready=0 并关闭该环境的重试窗口。
  // 失败/边界：env 为空时不触碰 driver；底层 status 非成功时 sequence 只报告失败，不伪造 ready。
  virtual task body();
    if (env == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "rdma_init_seq requires a bound rdma_env");
      error_msg = status.convert2string();
      return;
    end
    env.initialize(status);
    success = status.ok();
    error_msg = status.convert2string();
  endtask
endclass

// 功能：按两个 global Function ID 启动一条 RDMA 流量 sequence。
// 输入/输出及副作用：env/f0/f1/qp_count 是只读运行输入；body 创建并启动 rdma_traffic_vseq，
//   更新 scoreboard 期望并等待流量排空，最后写 success/error_msg。
// 失败/边界：环境未 ready、端点不存在/相同或 QP 数为零时不创建资源；业务失败不回滚已创建的 QP/CQ/MR。
class rdma_run_seq extends uvm_sequence;
  `uvm_object_utils(rdma_run_seq)

  rdma_env env;
  int unsigned f0;
  int unsigned f1;
  int unsigned qp_count;
  bit success;
  string error_msg;

  // 功能：构造默认 Function 0↔1、单 QP 的业务 sequence。
  // 输入/输出及副作用：name 传给 UVM；不分配资源，调用方可在启动前覆盖 f0/f1/qp_count。
  // 失败/边界：默认端点只适用于存在对应 global ID 的环境，body 会再次校验并拒绝无效输入。
  function new(string name = "rdma_run_seq");
    super.new(name);
    f0 = 0;
    f1 = 1;
    qp_count = 1;
    success = 0;
    error_msg = "RDMA traffic sequence has not run";
  endfunction

  // 功能：校验 ready 环境和端点后启动 rdma_traffic_vseq，完成指定 QP 数的双向业务。
  // 输入/输出及副作用：可能创建并登记 PD/CQ/QP/MR、投递报文并更新 scoreboard；完成后返回业务结果。
  // 失败/边界：空 env、未初始化、相同/未知 Function 或零 QP 均无资源副作用；scoreboard 非空或未 idle 返回失败。
  virtual task body();
    rdma_traffic_vseq traffic;
    int left;
    int right;

    success = 0;
    error_msg = "rdma_run_seq requires ready RDMA, two distinct global IDs and qp_count>0";
    if (env == null || !env.is_ready() || f0 == f1 || qp_count == 0)
      return;
    left = env.find_function_index(f0);
    right = env.find_function_index(f1);
    if (left < 0 || right < 0)
      return;

    traffic = rdma_traffic_vseq::type_id::create("traffic");
    traffic.f0 = left;
    traffic.f1 = right;
    traffic.qp_count = qp_count;
    traffic.start(env.vseqr);
    success = env.sb.errors == 0 && env.sb.idle();
    error_msg = success ? "traffic completed" : "RDMA scoreboard did not drain cleanly";
  endtask
endclass

// 功能：停止当前 AIP 登记的 RDMA 流量 sequence，并返回取消结果。
// 输入/输出及副作用：target_cmd 指向 rdma_run 的 sequence 登记名；body 只取消尚未结束的业务 sequence，
//   不销毁已创建的 PD/CQ/QP/MR，也不重置 driver 或复位 DUT。
// 失败/边界：没有活动 rdma_run 时幂等成功；AIP registry 不可用或取消数异常时返回失败，已提交到
//   driver 的事务仍由平台 quiesce/reset 流程负责收尾。
class rdma_stop_seq extends uvm_sequence;
  `uvm_object_utils(rdma_stop_seq)

  string target_cmd;
  int killed;
  bit success;
  string error_msg;

  // 功能：构造默认停止 rdma_run 的 sequence。
  // 输入/输出及副作用：name 传给 UVM；target_cmd 固定为 AIP 业务登记名，不访问环境资源。
  // 失败/边界：构造阶段不取消任何 sequence；调用方必须在 AIP 命令 worker 中启动。
  function new(string name = "rdma_stop_seq");
    super.new(name);
    target_cmd = "rdma_run";
    killed = 0;
    success = 0;
    error_msg = "RDMA stop sequence has not run";
  endfunction

  // 功能：通过 AIP sequence registry 取消当前 rdma_run，并报告是否存在待停止业务。
  // 输入/输出及副作用：更新 killed/success/error_msg；不会改写 RDMA env 的 ready 或资源库状态。
  // 失败/边界：kill_one 返回零表示已空闲，按幂等停止成功；非默认 target_cmd 或 registry 异常拒绝。
  virtual task body();
    if (target_cmd != "rdma_run") begin
      error_msg = "rdma_stop_seq only accepts the rdma_run registry name";
      return;
    end
    killed = aip_cmd_seq_registry::kill_one(target_cmd);
    success = 1'b1;
    error_msg = killed == 0 ? "RDMA traffic was already idle" :
      $sformatf("RDMA traffic stop requested; cancelled=%0d", killed);
  endtask
endclass
