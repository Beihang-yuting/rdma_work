// 目录：集成测试层 integration/rdma_tb_e2e_high_traffic_test.sv。
// 层：集成测试。
// 职责：rdma_tb_e2e_test 环境（真实 host_mem + net_packet 帧 wire）上的高流量 SEND：4096 个 256B SEND
//   分 16 个整窗（窗口 = QP 深度 256）：每窗先投满 RQ（再投一个须返回 QUEUE_FULL），再发 255 个
//   unsignaled + 1 个 signaled SEND 填满 SQ，等记分板结算后进入下一窗。覆盖 SQ/RQ 满与回绕、CQ 回绕
//   （每节点 CQ 1024 项）、unsignaled 批量完成与逐包数据比对。
// 依赖：rdma_tb_e2e_test、rdma_tb_pkg。
// 所有权：继承父类。
// 生命周期：仿真期间常驻。

class rdma_tb_high_traffic_vseq extends uvm_sequence;
  `rdma_object_utils(rdma_tb_high_traffic_vseq)

  localparam int unsigned PACKETS = 4096;
  localparam int unsigned PAYLOAD = 256;
  localparam int unsigned WINDOW = 256;
  localparam int unsigned RX_SLOTS = 64;
  localparam int unsigned RX_BASE = 'h8000;

  rdma_tb_env env;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：运行前须设置 env。
  function new(string name = "rdma_tb_high_traffic_vseq");
    super.new(name);
  endfunction

  // 功能：在节点 node 上下发一个 verb 并等待 driver 完成该 item。
  // 输入/输出及副作用：经 sequencer 下发。
  // 失败/边界：无。
  task post(int unsigned node, rdma_verb_item item);
    rdma_verb_one_seq seq;

    seq = rdma_verb_one_seq::type_id::create("one");
    seq.item = item;
    seq.start(env.agents[node].sequencer);
  endtask

  // 功能：逐窗运行：投满 RQ 并验证再投被拒，填满 SQ（仅窗尾 signaled），等待结算。
  // 输入/输出及副作用：node1 的接收槽与 node0 的源缓冲被反复写入。
  // 失败/边界：RQ 未满或超额投递未被拒报 UVM_ERROR；数据由记分板判定。
  task body();
    rdma_verb_item item;
    int unsigned packet;

    for (int unsigned w = 0; w < PACKETS / WINDOW; w++) begin
      for (int unsigned k = 0; k < WINDOW; k++) begin
        item = rdma_verb_item::type_id::create("recv");
        item.op = RDMA_VERB_RECV;
        item.local_offset = RX_BASE + (k % RX_SLOTS) * PAYLOAD;
        item.length = PAYLOAD;
        post(1, item);
      end
      check_rq_full();
      for (int unsigned k = 0; k < WINDOW; k++) begin
        packet = w * WINDOW + k;
        item = rdma_verb_item::type_id::create("send");
        item.op = RDMA_VERB_SEND;
        item.local_offset = k * PAYLOAD;
        item.length = PAYLOAD;
        item.signaled = k == WINDOW - 1;
        for (int unsigned b = 0; b < PAYLOAD; b++)
          item.data.push_back(byte'(packet * 13 + b * 7 + (packet >> 8)));
        post(0, item);
      end
      env.wait_idle(10ms);
    end
  endtask

  // 功能：RQ 已投满时再直接经驱动投一个 RECV，须返回 QUEUE_FULL 且不改变环。
  // 输入/输出及副作用：一次被拒的 post_recv。
  // 失败/边界：被接受报 UVM_ERROR。
  task check_rq_full();
    rdma_drv_recv_wr wr;
    rdma_tb_node_cfg node;
    rdma_status status;

    node = env.nodes[1];
    wr = rdma_drv_recv_wr::type_id::create("overflow");
    wr.wr_id = 64'hdead;
    wr.sges.push_back(rdma_drv_sge::make(node.data_buf.iova + RX_BASE, PAYLOAD,
                                         node.data_mr.key()));
    rdma_drv_wr::post_recv(node.drv, node.qps[0].qp, wr, status);
    if (status.code != RDMA_SC_QUEUE_FULL)
      `uvm_error("HIGH_TRAFFIC", $sformatf("RECV beyond a full RQ returned %s",
                                           status.convert2string()))
  endtask
endclass

class rdma_tb_e2e_high_traffic_test extends rdma_tb_e2e_test;
  `uvm_component_utils(rdma_tb_e2e_high_traffic_test)

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_e2e_high_traffic_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：运行高流量序列。
  // 输入/输出及副作用：经 env 下发 verb。
  // 失败/边界：结果由记分板判定。
  virtual task run_traffic();
    rdma_tb_high_traffic_vseq vseq;

    vseq = rdma_tb_high_traffic_vseq::type_id::create("vseq");
    vseq.env = env;
    vseq.start(null);
  endtask
endclass
