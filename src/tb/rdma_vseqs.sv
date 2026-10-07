// 目录：验证组件层 tb/rdma_vseqs.sv。
// 层：验证组件。
// 职责：虚拟序列：rdma_base_vseq 提供控制面动作（建资源、连接）、verb 构造/投递与等待；
//   rdma_pair 为两 Function 的标准拓扑（各一 PD、CQ、URC 专用 CQ、RC/UD/URC QP、数据 MR，同类 QP
//   互连）；每个场景一个子类：basic_traffic、high_traffic。
// 依赖：rdma_env（vsequencer 持有）、控制面/数据面 sequencer。
// 所有权：序列只借用资源句柄。
// 生命周期：测试 run_phase 启动。

class rdma_pair extends uvm_object;
  `uvm_object_utils(rdma_pair)

  rdma_res_pd pd[2];
  rdma_res_buf mem[2];
  rdma_res_mr mr[2];
  // qp[n][0/1/2] = Function n 的 RC/UD/URC QP。
  rdma_res_qp qp[2][3];

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_pair");
    super.new(name);
  endfunction
endclass

class rdma_base_vseq extends uvm_sequence;
  `uvm_object_utils(rdma_base_vseq)
  `uvm_declare_p_sequencer(rdma_vsequencer)

  rdma_env env;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_base_vseq");
    super.new(name);
  endfunction

  // 功能：取 env 并等待就绪。
  // 输入/输出及副作用：阻塞到就绪。
  // 失败/边界：无。
  task pre_body();
    env = p_sequencer.env;
    env.wait_ready();
  endtask

  // 功能：执行控制面请求。
  // 输入/输出及副作用：阻塞到 driver 完成。
  // 失败/边界：非预期失败 UVM_FATAL（后续步骤依赖其结果）。
  task ctrl(rdma_ctrl_item it);
    start_item(it, -1, env.ctrl.sequencer);
    finish_item(it);
    if (!it.status.ok() && !it.expect_fail)
      `uvm_fatal("RDMA_VSEQ", {it.convert2string(), " failed: ", it.status.convert2string()})
  endtask

  // 功能：构造控制面请求。
  // 输入/输出及副作用：返回新 item。
  // 失败/边界：无。
  function rdma_ctrl_item new_ctrl(rdma_ctrl_op_e op, int unsigned func);
    rdma_ctrl_item it;

    it = rdma_ctrl_item::type_id::create(op.name());
    it.op = op;
    it.func = func;
    return it;
  endfunction

  // 功能：分配 PD。
  // 输入/输出及副作用：pd 输出。
  // 失败/边界：见 ctrl。
  task alloc_pd(int unsigned func, output rdma_res_pd pd);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_ALLOC_PD, func);
    ctrl(it);
    void'($cast(pd, it.res));
  endtask

  // 功能：分配 size 字节 DMA 缓冲。
  // 输入/输出及副作用：b 输出。
  // 失败/边界：见 ctrl。
  task alloc_buf(int unsigned func, int unsigned size, output rdma_res_buf b);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_ALLOC_BUF, func);
    it.size = size;
    ctrl(it);
    void'($cast(b, it.res));
  endtask

  // 功能：在整个 b 上注册全权限 MR。
  // 输入/输出及副作用：mr 输出。
  // 失败/边界：见 ctrl。
  task reg_mr(rdma_res_pd pd, rdma_res_buf b, output rdma_res_mr mr);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_REG_MR, pd.owner.index);
    it.pd = pd;
    it.mem = b;
    ctrl(it);
    void'($cast(mr, it.res));
  endtask

  // 功能：创建 depth 深度的 CQ。
  // 输入/输出及副作用：cq 输出。
  // 失败/边界：见 ctrl。
  task create_cq(int unsigned func, int unsigned depth, output rdma_res_cq cq);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_CREATE_CQ, func);
    it.size = depth;
    ctrl(it);
    void'($cast(cq, it.res));
  endtask

  // 功能：创建 QP（收发同一 CQ，深度取配置）。
  // 输入/输出及副作用：qp 输出。
  // 失败/边界：见 ctrl。
  task create_qp(rdma_res_pd pd, rdma_drv_qp_type_e qp_type, rdma_res_cq cq, bit urc,
                 output rdma_res_qp qp, input rdma_res_srq srq = null);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_CREATE_QP, pd.owner.index);
    it.pd = pd;
    it.qp_type = qp_type;
    it.urc = urc;
    it.send_cq = cq;
    it.recv_cq = cq;
    it.srq = srq;
    it.size = env.cfg.qp_depth;
    ctrl(it);
    void'($cast(qp, it.res));
  endtask

  // 功能：a ↔ b 互连并推到 RTS。
  // 输入/输出及副作用：修改两个 QP。
  // 失败/边界：见 ctrl。
  task connect(rdma_res_qp a, rdma_res_qp b);
    rdma_ctrl_item it;

    it = new_ctrl(RDMA_CTRL_CONNECT, a.owner.index);
    it.qp = a;
    it.peer = b;
    ctrl(it);
  endtask

  // 功能：建立 Function f0 ↔ f1 的标准拓扑（见文件头）。
  // 输入/输出及副作用：p 输出。
  // 失败/边界：见 ctrl。
  task setup_pair(int unsigned f0, int unsigned f1, int unsigned buf_bytes, output rdma_pair p);
    int unsigned f[2];
    rdma_res_cq cq;
    rdma_res_cq urc_cq;

    f = '{f0, f1};
    p = rdma_pair::type_id::create("pair");
    foreach (f[n]) begin
      alloc_pd(f[n], p.pd[n]);
      create_cq(f[n], env.cfg.qp_depth, cq);
      create_cq(f[n], env.cfg.qp_depth, urc_cq);
      create_qp(p.pd[n], RDMA_DRV_QPT_RC, cq, 1'b0, p.qp[n][0]);
      create_qp(p.pd[n], RDMA_DRV_QPT_UD, cq, 1'b0, p.qp[n][1]);
      create_qp(p.pd[n], RDMA_DRV_QPT_RC, urc_cq, 1'b1, p.qp[n][2]);
      alloc_buf(f[n], buf_bytes, p.mem[n]);
      reg_mr(p.pd[n], p.mem[n], p.mr[n]);
    end
    for (int unsigned k = 0; k < 3; k++)
      connect(p.qp[0][k], p.qp[1][k]);
  endtask

  // 功能：构造 verb：本地区域在 lmr，远端区域在 rmr（可空）。
  // 输入/输出及副作用：返回新 item。
  // 失败/边界：无。
  function rdma_verb_item verb(rdma_verb_op_e op, rdma_res_qp qp, rdma_res_mr lmr,
                               int unsigned local_offset, int unsigned length,
                               rdma_res_mr rmr = null, int unsigned remote_offset = 0,
                               int unsigned sge_count = 1);
    rdma_verb_item it;

    it = rdma_verb_item::type_id::create(op.name());
    it.op = op;
    it.qp = qp;
    it.lmr = lmr;
    it.local_offset = local_offset;
    it.length = length;
    it.rmr = rmr;
    it.remote_offset = remote_offset;
    it.sge_count = sge_count;
    return it;
  endfunction

  // 功能：在所属 Function 的数据面 sequencer 上投递（signaled SQ 请求阻塞到完成）。
  // 输入/输出及副作用：见 verb driver。
  // 失败/边界：无。
  task post(rdma_verb_item it);
    rdma_res_func f;

    f = it.srq != null ? it.srq.owner : it.qp.owner;
    start_item(it, -1, env.verb[f.index].sequencer);
    finish_item(it);
  endtask
endclass

// 两 Function 全功能流量：SEND/RECV 跨 MTU、SEND_IMM、WRITE(+IMM、unsignaled)、READ、ATOMIC、反向、
//   多 SGE/外部 SGB、UD、URC、越界访问错误。源数据轮流使用 net_packet 的四种负载模式。
class rdma_basic_traffic_vseq extends rdma_base_vseq;
  `uvm_object_utils(rdma_basic_traffic_vseq)

  localparam int unsigned BUF_BYTES = 'h10000;

  rdma_pair p;
  protected int unsigned count;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_basic_traffic_vseq");
    super.new(name);
  endfunction

  // 功能：建立 Function 0↔1 拓扑后依次运行全部场景，等待结算。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    setup_pair(0, 1, BUF_BYTES, p);
    send_recv();
    write_read();
    atomics();
    reverse_write();
    multi_sge();
    ud_send();
    urc_traffic();
    access_error();
    env.wait_idle(500us);
  endtask

  // 功能：Function n 经第 k 类 QP（0 RC/1 UD/2 URC）的 verb，远端为对端 MR；数据模式轮换。
  // 输入/输出及副作用：返回新 item。
  // 失败/边界：无。
  function rdma_verb_item v(int unsigned n, rdma_verb_op_e op, int unsigned local_offset,
                            int unsigned length, int unsigned remote_offset = 0,
                            int unsigned k = 0, int unsigned sges = 1);
    rdma_verb_item it;
    bit remote;

    remote = !(op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_RECV});
    it = verb(op, p.qp[n][k], p.mr[n], local_offset, length, remote ? p.mr[1 - n] : null,
              remote_offset, sges);
    it.data_mode = payload_mode_e'(count++ % 4);
    it.data_fixed = 8'h5a;
    it.data_pattern = '{8'hde, 8'had, 8'hbe, 8'hef, 8'h01};
    return it;
  endfunction

  // 功能：SEND 跨 3 个 MTU 包、SEND_IMM 单包；接收端先投 RECV。
  // 输入/输出及副作用：Function 1 的 0x2000/0x3000 区域被写入。
  // 失败/边界：无。
  task send_recv();
    rdma_verb_item it;

    post(v(1, RDMA_VERB_RECV, 'h2000, 'h1000));
    post(v(1, RDMA_VERB_RECV, 'h3000, 'h100));
    post(v(0, RDMA_VERB_SEND, 'h0000, 2500));
    it = v(0, RDMA_VERB_SEND_IMM, 'h1000, 100);
    it.imm = 32'hcafe_0001;
    post(it);
  endtask

  // 功能：unsignaled + signaled WRITE、WRITE_IMM（消耗 RQE），随后 READ 回读写入区域。
  // 输入/输出及副作用：Function 1 的 0x4000 区域写入，Function 0 的 0x6000 区域回读。
  // 失败/边界：无。
  task write_read();
    rdma_verb_item it;

    it = v(0, RDMA_VERB_WRITE, 'h0800, 300, 'h4000);
    it.signaled = 1'b0;
    post(it);
    post(v(0, RDMA_VERB_WRITE, 'h0a00, 2148, 'h4200));
    post(v(1, RDMA_VERB_RECV, 'h3100, 'h10));
    it = v(0, RDMA_VERB_WRITE_IMM, 'h1800, 64, 'h5000);
    it.imm = 32'hcafe_0002;
    post(it);
    post(v(0, RDMA_VERB_READ, 'h6000, 2448, 'h4000));
  endtask

  // 功能：FETCH_ADD 两次后 CMP_SWAP 一次命中、一次不命中（原值写回本地 0x7000 区域）。
  // 输入/输出及副作用：Function 1 的 0x7800 的 8 字节被改写。
  // 失败/边界：比较值基于该区域初始为零。
  task atomics();
    rdma_verb_item it;

    it = v(0, RDMA_VERB_FETCH_ADD, 'h7000, 8, 'h7800);
    it.swap_add_value = 64'h5;
    post(it);
    it = v(0, RDMA_VERB_FETCH_ADD, 'h7008, 8, 'h7800);
    it.swap_add_value = 64'h1_0000_0000;
    post(it);
    it = v(0, RDMA_VERB_CMP_SWAP, 'h7010, 8, 'h7800);
    it.compare_value = 64'h1_0000_0005;
    it.swap_add_value = 64'h1234_5678_9abc_def0;
    post(it);
    it = v(0, RDMA_VERB_CMP_SWAP, 'h7018, 8, 'h7800);
    it.compare_value = 64'h1;
    it.swap_add_value = 64'hdead;
    post(it);
  endtask

  // 功能：反方向 1 → 0 的 WRITE 与 SEND。
  // 输入/输出及副作用：Function 0 的 0x8000/0x9000 区域写入。
  // 失败/边界：无。
  task reverse_write();
    post(v(1, RDMA_VERB_WRITE, 'h0000, 1024, 'h8000));
    post(v(0, RDMA_VERB_RECV, 'h9000, 'h800));
    post(v(1, RDMA_VERB_SEND, 'h0400, 1025));
  endtask

  // 功能：多 SGE：4-SGE SEND 进 4-SGE RECV（外部 SGB）、3-SGE SEND 进 2-SGE RECV、3-SGE WRITE、
  //   READ 散写到 3 个 SGE。
  // 输入/输出及副作用：Function 1 的 0xa000/0xb000、Function 0 的 0xc000 区域写入。
  // 失败/边界：无。
  task multi_sge();
    post(v(1, RDMA_VERB_RECV, 'ha000, 'hc00, 0, 0, 4));
    post(v(1, RDMA_VERB_RECV, 'hac00, 'h400, 0, 0, 2));
    post(v(0, RDMA_VERB_SEND, 'h2000, 3000, 0, 0, 4));
    post(v(0, RDMA_VERB_SEND, 'h2c00, 1000, 0, 0, 3));
    post(v(0, RDMA_VERB_WRITE, 'h3000, 2000, 'hb000, 0, 3));
    post(v(0, RDMA_VERB_READ, 'hc000, 1800, 'hb100, 0, 3));
  endtask

  // 功能：UD SEND（3 个 SGE 经 SGB，单包 ≤ MTU）与 UD SEND_IMM。
  // 输入/输出及副作用：Function 1 的 0xd000/0xd400 区域写入（含 40B GRH）。
  // 失败/边界：无。
  task ud_send();
    rdma_verb_item it;

    post(v(1, RDMA_VERB_RECV, 'hd000, 'h400, 0, 1));
    post(v(1, RDMA_VERB_RECV, 'hd400, 'h100, 0, 1));
    post(v(0, RDMA_VERB_SEND, 'h4000, 700, 0, 1, 3));
    it = v(0, RDMA_VERB_SEND_IMM, 'h4400, 64, 0, 1);
    it.imm = 32'hcafe_0003;
    post(it);
  endtask

  // 功能：URC SEND（3 包）、WRITE 与 WRITE_IMM（不等 ACK 即完成）。
  // 输入/输出及副作用：Function 1 的 0xe000/0xf000/0xf800 区域写入。
  // 失败/边界：无。
  task urc_traffic();
    rdma_verb_item it;

    post(v(1, RDMA_VERB_RECV, 'he000, 'h900, 0, 2));
    post(v(1, RDMA_VERB_RECV, 'he900, 'h10, 0, 2));
    post(v(0, RDMA_VERB_SEND, 'h4800, 2100, 0, 2));
    post(v(0, RDMA_VERB_WRITE, 'h5000, 1500, 'hf000, 2));
    it = v(0, RDMA_VERB_WRITE_IMM, 'h5800, 40, 'hf800, 2);
    it.imm = 32'hcafe_0004;
    post(it);
  endtask

  // 功能：WRITE 越过对端 MR 末尾，期望 REM_ACCESS_ERR 完成且对端内存不变。
  // 输入/输出及副作用：RC QP 随后进入错误态，故放在最后。
  // 失败/边界：无。
  task access_error();
    rdma_verb_item it;

    it = v(0, RDMA_VERB_WRITE, 'h0000, 64, p.mr[1].len - 32);
    it.expect_status = RDMA_DRV_WC_REM_ACCESS_ERR;
    post(it);
  endtask
endclass

// 大流量：Function 0 → 1 RC SEND 4096 个（256B），每窗口 256：先投满 RQ（并验证再投一个返回
//   QUEUE_FULL），再连发 256 个（仅末个 signaled），等全部结算后下一窗口。RECV 槽位循环复用。
class rdma_high_traffic_vseq extends rdma_base_vseq;
  `uvm_object_utils(rdma_high_traffic_vseq)

  localparam int unsigned PACKETS = 4096;
  localparam int unsigned PAYLOAD = 256;
  localparam int unsigned WINDOW = 256;
  localparam int unsigned RX_SLOTS = 64;
  localparam int unsigned RX_BASE = 'h8000;

  rdma_pair p;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_high_traffic_vseq");
    super.new(name);
  endfunction

  // 功能：见类说明。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    rdma_verb_item it;

    setup_pair(0, 1, 'h10000, p);
    for (int unsigned w = 0; w < PACKETS / WINDOW; w++) begin
      for (int unsigned k = 0; k < WINDOW; k++)
        post(verb(RDMA_VERB_RECV, p.qp[1][0], p.mr[1], RX_BASE + (k % RX_SLOTS) * PAYLOAD,
                  PAYLOAD));
      check_rq_full();
      for (int unsigned k = 0; k < WINDOW; k++) begin
        it = verb(RDMA_VERB_SEND, p.qp[0][0], p.mr[0], k * PAYLOAD, PAYLOAD);
        it.signaled = k == WINDOW - 1;
        post(it);
      end
      env.wait_idle(10ms);
    end
  endtask

  // 功能：RQ 已满时再投一个 RECV（直接经驱动，不进 scoreboard），应返回 QUEUE_FULL。
  // 输入/输出及副作用：无（投递被拒绝）。
  // 失败/边界：返回其它结果报 UVM_ERROR。
  task check_rq_full();
    rdma_drv_recv_wr wr;
    rdma_status status;

    wr = rdma_drv_recv_wr::type_id::create("overflow");
    wr.wr_id = 64'hdead;
    wr.sges.push_back(rdma_drv_sge::make(p.mr[1].va + RX_BASE, PAYLOAD, p.mr[1].key));
    rdma_drv_wr::post_recv(p.qp[1][0].owner.drv(), p.qp[1][0].qp, wr, status);
    if (status.code != RDMA_SC_QUEUE_FULL)
      `uvm_error("HIGH_TRAFFIC", {"RECV beyond a full RQ returned ", status.convert2string()})
  endtask
endclass
