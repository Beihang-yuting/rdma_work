// 目录：验证组件层 tb/rdma_tb_env.sv。
// 层：验证组件。
// 职责：多节点 RDMA 验证环境：每节点一个 verb agent（经驱动模型投递/轮询），各节点设备模型的
//   NIC 经共享 wire 互连，记分板比对完成与内存。
// 依赖：rdma_verb_agent、rdma_wire、rdma_tb_scoreboard、rdma_dev（节点设备 NIC）。
// 所有权：节点资源（设备/驱动/内存）由测试创建后经 configure() 下发，env 只借用。
// 生命周期：configure() 后 run_phase 启动各节点 NIC；wire 可经 factory override 替换
//   （如 net_packet 帧编解码实现）。

class rdma_tb_env extends uvm_env;
  `uvm_component_utils(rdma_tb_env)

  int unsigned num_nodes;
  rdma_verb_agent agents[];
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
    foreach (agents[n])
      agents[n] = rdma_verb_agent::type_id::create($sformatf("agent%0d", n), this);
    fabric = rdma_wire::type_id::create("fabric", this);
    sb = rdma_tb_scoreboard::type_id::create("sb", this);
  endfunction

  // 功能：连接 agent→记分板。
  // 输入/输出及副作用：建立 TLM 连接。
  // 失败/边界：无。
  function void connect_phase(uvm_phase phase);
    foreach (agents[n]) begin
      agents[n].driver.posted_ap.connect(sb.posted_export);
      agents[n].monitor.cqe_ap.connect(sb.cqe_export);
    end
  endfunction

  // 功能：等待 configure() 后启动各节点设备 NIC 的 TX/RX 循环。
  // 输入/输出及副作用：派生常驻进程。
  // 失败/边界：无。
  task run_phase(uvm_phase phase);
    wait (nodes.size() == num_nodes);
    foreach (nodes[n]) begin
      automatic rdma_dev dev = nodes[n].dev;
      fork
        dev.nic.run();
      join_none
    end
  endtask

  // 功能：下发节点配置（node_id 须为 0..num_nodes-1），把各节点 NIC 接到 wire，组件随即开始工作。
  // 输入/输出及副作用：设置所有组件的 cfg/nodes 与各 NIC 的出口端口。
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
      all[n].dev.nic.port = fabric.attach(n, all[n].dev, all[n].mac);
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
