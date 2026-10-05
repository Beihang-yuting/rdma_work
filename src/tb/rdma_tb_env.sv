// 目录：验证组件层 tb/rdma_tb_env.sv。
// 职责：多节点 RDMA 验证环境：每节点一个 verb agent 与 NIC 行为模型，共享 wire 与记分板。
// 依赖：rdma_verb_agent、rdma_nic_model、rdma_wire、rdma_tb_scoreboard。
// 所有权与生命周期：节点资源由测试创建后经 configure() 下发；组件 run_phase 等待配置就绪。
//   wire 可经 factory override 替换（如 net_packet 帧编解码实现）。

class rdma_tb_env extends uvm_env;
  `uvm_component_utils(rdma_tb_env)

  int unsigned num_nodes;
  rdma_verb_agent agents[];
  rdma_nic_model nics[];
  rdma_wire fabric;
  rdma_tb_scoreboard sb;
  rdma_tb_node_cfg nodes[int unsigned];

  // 功能：构造环境。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_env", uvm_component parent = null);
    super.new(name, parent);
    num_nodes = 2;
  endfunction

  // 功能：按 config_db 的 num_nodes（默认 2）创建各节点组件、wire 与记分板。
  // 输入/输出及副作用：创建子组件。
  // 失败/边界：无。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int unsigned)::get(this, "", "num_nodes", num_nodes));
    agents = new[num_nodes];
    nics = new[num_nodes];
    foreach (agents[n]) begin
      agents[n] = rdma_verb_agent::type_id::create($sformatf("agent%0d", n), this);
      nics[n] = rdma_nic_model::type_id::create($sformatf("nic%0d", n), this);
    end
    fabric = rdma_wire::type_id::create("fabric", this);
    sb = rdma_tb_scoreboard::type_id::create("sb", this);
  endfunction

  // 功能：连接 agent→记分板、NIC↔wire。
  // 输入/输出及副作用：建立 TLM 连接与对象引用。
  // 失败/边界：无。
  function void connect_phase(uvm_phase phase);
    foreach (agents[n]) begin
      agents[n].driver.posted_ap.connect(sb.posted_export);
      agents[n].monitor.cqe_ap.connect(sb.cqe_export);
      fabric.attach(n, nics[n]);
      nics[n].fabric = fabric;
    end
  endfunction

  // 功能：下发节点配置（node_id 须为 0..num_nodes-1），组件随即开始工作。
  // 输入/输出及副作用：设置所有组件的 cfg/nodes。
  // 失败/边界：节点数不符或校验失败报 UVM_FATAL。
  function void configure(rdma_tb_node_cfg all[int unsigned]);
    rdma_status status;

    if (all.size() != num_nodes)
      `uvm_fatal("RDMA_ENV", $sformatf("expected %0d node configs, got %0d",
                 num_nodes, all.size()))
    foreach (all[n]) begin
      status = all[n].validate();
      if (!status.ok() || all[n].node_id != n)
        `uvm_fatal("RDMA_ENV", $sformatf("node %0d config invalid: %s", n,
                   status.convert2string()))
    end
    nodes = all;
    sb.nodes = all;
    foreach (agents[n]) begin
      nics[n].nodes = all;
      nics[n].cfg = all[n];
      agents[n].configure(all[n], all);
    end
  endfunction

  // 功能：等待记分板所有请求结算（含 RQ 侧），用于测试收尾。
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
      #(nodes[0].poll_interval);
    end
  endtask
endclass
