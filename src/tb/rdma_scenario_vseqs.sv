// 目录：验证组件层 tb/rdma_scenario_vseqs.sv。
// 层：验证组件。
// 职责：场景虚拟序列（每个场景一个类，结果由 scoreboard 预测/比对与协议检查判定）：
//   - rdma_errors_vseq：错误 rkey/越界/权限/PD 不符（REM_ACCESS）、接收容量不足、QP 转 ERR 的 flush、
//     UD Q_Key 不符丢弃；错误后同 QP 的请求按预测 flush。
//   - rdma_reliability_vseq：链路故障下的可靠传输：丢中间包（双向）、复制、乱序、损坏、RNR 重试；有响应
//     超时时另测丢 ACK、丢 READ 响应末包、丢 ATOMIC ACK（重复请求不重复执行）。
//   - rdma_srq_vseq：两个 QP 共享 SRQ，双向各一遍。
//   - rdma_qp_lifecycle_vseq：SQD 暂停新 WR、恢复后发送；按序销毁全部资源后重建并恢复流量。
//   - rdma_multifunc_vseq：两对 Function 并行流量；VF FLR、PF FLR（含 VF）、整设备复位只影响范围内
//     Function，恢复（驱动 remove/probe）后重建资源、流量恢复。
//   - rdma_random_vseq：随机方向/QP 类型/操作/长度/SGE/数据模式的流量。
// 依赖：rdma_base_vseq、rdma_link_fault、rdma_dpu_system 的复位范围。
// 所有权：序列只借用资源句柄。
// 生命周期：测试 run_phase 启动。

// 场景公共部分：Function 对 f0/f1 与 verb 构造（Function n 的第 k 类 QP，远端缺省为对端 MR）。
class rdma_scenario_vseq extends rdma_base_vseq;
  `uvm_object_utils(rdma_scenario_vseq)

  localparam int unsigned BUF_BYTES = 'h4000;

  int unsigned f0 = 0;
  int unsigned f1 = 1;
  rdma_pair p;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_scenario_vseq");
    super.new(name);
  endfunction

  // 功能：新建 f0↔f1 标准拓扑（错误场景每次一对新 QP）。
  // 输入/输出及副作用：p 更新。
  // 失败/边界：见 setup_pair。
  task fresh();
    setup_pair(f0, f1, BUF_BYTES, p);
  endtask

  // 功能：Function n（0/1 对应 f0/f1）经第 k 类 QP 的 verb；rmr 缺省为对端 MR（SEND/RECV 无远端）。
  // 输入/输出及副作用：返回新 item。
  // 失败/边界：无。
  function rdma_verb_item v(int unsigned n, rdma_verb_op_e op, int unsigned local_offset,
                            int unsigned length, int unsigned remote_offset = 0,
                            int unsigned k = 0, rdma_res_mr rmr = null);
    if (rmr == null && !(op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_RECV}))
      rmr = p.mr[1 - n];
    return verb(op, p.qp[n][k], p.mr[n], local_offset, length, rmr, remote_offset);
  endfunction

  // 功能：Function n（0/1）是否为远端（rxe）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit remote(int unsigned n);
    return env.res.funcs[n == 0 ? f0 : f1].remote;
  endfunction
endclass

class rdma_errors_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_errors_vseq)

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_errors_vseq");
    super.new(name);
  endfunction

  // 功能：依次运行各错误场景（远端 Function 不能注册受限 MR/第二个 PD，跳过权限与 PD 场景）。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    bad_rkey();
    out_of_range();
    if (!remote(1)) begin
      rights();
      pd_mismatch();
    end
    overflow();
    qp_to_err();
    ud_qkey();
    env.wait_idle(500us);
  endtask

  // 功能：f0 用自己的 MR 作远端 WRITE（rkey 不属于对端）→ REM_ACCESS，随后同 QP 的 WRITE 按预测
  //   flush（远端响应方出错后 QP 进入 ERR、不再应答，故远端时不发）；f1 用自己的 MR 作远端 READ（被测
  //   设备作响应方，新 QP 对）→ REM_ACCESS。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task bad_rkey();
    fresh();
    post(v(0, RDMA_VERB_WRITE, 'h0000, 64, 0, 0, p.mr[0]));
    if (!remote(1))
      post(v(0, RDMA_VERB_WRITE, 'h0100, 64, 'h0100));
    fresh();
    post(v(1, RDMA_VERB_READ, 'h0200, 64, 0, 0, p.mr[1]));
  endtask

  // 功能：READ 越过对端 MR 末尾 → REM_ACCESS。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task out_of_range();
    fresh();
    post(v(0, RDMA_VERB_READ, 'h0000, 64, p.mr[1].len - 32));
  endtask

  // 功能：对端只读 MR（远端读）：READ 成功，WRITE → REM_ACCESS；ATOMIC（新 QP 对）→ REM_ACCESS。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task rights();
    rdma_res_mr ro;
    rdma_verb_item it;

    fresh();
    reg_mr(p.pd[1], p.mem[1], ro, rdma_drv_mr::rights_of(1, 1, 0, 0), 'h1000, 'h1000);
    post(v(0, RDMA_VERB_READ, 'h0000, 128, 0, 0, ro));
    post(v(0, RDMA_VERB_WRITE, 'h0100, 64, 0, 0, ro));
    fresh();
    reg_mr(p.pd[1], p.mem[1], ro, rdma_drv_mr::rights_of(1, 1, 0, 0), 'h1000, 'h1000);
    it = v(0, RDMA_VERB_FETCH_ADD, 'h0200, 8, 0, 0, ro);
    it.swap_add_value = 1;
    post(it);
  endtask

  // 功能：对端另一个 PD 上的 MR（与对端 QP 不同 PD）→ REM_ACCESS。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task pd_mismatch();
    rdma_res_pd pd2;
    rdma_res_mr mr2;

    fresh();
    alloc_pd(f1, pd2);
    reg_mr(pd2, p.mem[1], mr2);
    post(v(0, RDMA_VERB_WRITE, 'h0000, 64, 0, 0, mr2));
  endtask

  // 功能：64B 的 RECV 收 200B 的 SEND：请求方 REM_INV_REQ（rxe 响应方 REM_OP），接收端错误完成。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task overflow();
    fresh();
    post(v(1, RDMA_VERB_RECV, 'h1000, 64));
    post(v(0, RDMA_VERB_SEND, 'h0000, 200));
  endtask

  // 功能：f0 的 RC QP 投 3 个 RECV 后转 ERR → 3 个 FLUSH；ERR 状态下投递的 SEND 也 FLUSH。
  // 输入/输出及副作用：QP 进入错误态。
  // 失败/边界：无。
  task qp_to_err();
    fresh();
    for (int unsigned i = 0; i < 3; i++)
      post(v(0, RDMA_VERB_RECV, 'h1000 + 'h100 * i, 'h100));
    modify_qp(p.qp[0][0], RDMA_DRV_QPS_ERR);
    post(v(0, RDMA_VERB_SEND, 'h0000, 32));
  endtask

  // 功能：UD Q_Key 不符的 SEND 被接收端丢弃（发送端成功），随后正确 Q_Key 的 SEND 消耗该 RECV。
  // 输入/输出及副作用：f1 的 UD RECV 被写入。
  // 失败/边界：无。
  task ud_qkey();
    rdma_verb_item it;

    fresh();
    post(v(1, RDMA_VERB_RECV, 'h2000, 'h400, 0, 1));
    it = v(0, RDMA_VERB_SEND, 'h0000, 100, 0, 1);
    it.ud_qkey = p.qp[1][1].qkey ^ 32'h1;
    post(it);
    post(v(0, RDMA_VERB_SEND, 'h0100, 100, 0, 1));
  endtask
endclass

class rdma_reliability_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_reliability_vseq)

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_reliability_vseq");
    super.new(name);
  endfunction

  // 功能：见文件头；超时类场景只在配置了响应超时（cfg.timeout ≠ 0）时运行。
  // 输入/输出及副作用：注入链路故障并下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    fresh();
    lost_middle(0);
    lost_middle(1);
    duplicate();
    reorder();
    corrupted();
    rnr();
    if (env.cfg.timeout != 0) begin
      lost_ack();
      lost_read_response();
      lost_atomic_ack();
    end
    env.wait_idle(5ms);
  endtask

  // 功能：加一条故障规则（源为 Function n，0/1 对应 f0/f1）。
  // 输入/输出及副作用：修改链路故障表。
  // 失败/边界：无。
  function void fault(rdma_fault_e kind, int unsigned n, rdma_network_opcode_e op,
                      int unsigned skip = 0, time delay = 3us);
    rdma_link_fault f;

    f = rdma_link_fault::type_id::create("fault");
    f.kind = kind;
    f.src = n == 0 ? f0 : f1;
    f.opcode = int'(op);
    f.skip = skip;
    f.delay = delay;
    env.link.inject(f);
  endfunction

  // 功能：Function n 的 3 包 SEND 丢第 2 包：PSN 序列 NAK 后重传。
  // 输入/输出及副作用：对端 RECV 被写入。
  // 失败/边界：无。
  task lost_middle(int unsigned n);
    fault(RDMA_FAULT_DROP, n, RDMA_NET_SEND, 1);
    post(v(1 - n, RDMA_VERB_RECV, 'h1000, 'h1000));
    post(v(n, RDMA_VERB_SEND, 'h0000, 2500));
  endtask

  // 功能：SEND 包被复制：响应方按重复请求处理，只消耗一个 RECV（第二个 RECV 留给 corrupted）。
  // 输入/输出及副作用：对端 RECV 被写入。
  // 失败/边界：无。
  task duplicate();
    fault(RDMA_FAULT_DUP, 0, RDMA_NET_SEND);
    post(v(1, RDMA_VERB_RECV, 'h2000, 'h400));
    post(v(1, RDMA_VERB_RECV, 'h2400, 'h400));
    post(v(0, RDMA_VERB_SEND, 'h0000, 300));
  endtask

  // 功能：3 包 WRITE 的首包延迟（后两包先到）：序列 NAK 重传，迟到的首包作为重复包。
  // 输入/输出及副作用：对端 0x3000 区域被写入。
  // 失败/边界：无。
  task reorder();
    fault(RDMA_FAULT_DELAY, 0, RDMA_NET_RDMA_WRITE);
    post(v(0, RDMA_VERB_WRITE, 'h0000, 2500, 'h3000));
  endtask

  // 功能：SEND 包损坏（netpkt 上 ICRC 校验丢弃，其它链路等同丢包）后重传。
  // 输入/输出及副作用：对端 RECV 被写入（先消耗 duplicate 留下的 RECV）。
  // 失败/边界：无。
  task corrupted();
    fault(RDMA_FAULT_CORRUPT, 0, RDMA_NET_SEND, 1);
    post(v(0, RDMA_VERB_SEND, 'h0000, 1000));
    post(v(1, RDMA_VERB_RECV, 'h2800, 'h1000));
    post(v(0, RDMA_VERB_SEND, 'h0000, 2500));
  endtask

  // 功能：RECV 在 SEND 之后 30us 才投递：响应方 RNR NAK，请求方按定时器重试后成功。
  // 输入/输出及副作用：对端 RECV 被写入。
  // 失败/边界：无。
  task rnr();
    fork
      begin
        #30us;
        post(v(1, RDMA_VERB_RECV, 'h1000, 'h100));
      end
    join_none
    post(v(0, RDMA_VERB_SEND, 'h0000, 64));
    wait fork;
  endtask

  // 功能：丢 ACK：请求方超时重发，响应方识别重复请求、重发 ACK 而不重复执行。
  // 输入/输出及副作用：对端两个 RECV 各被写入一次。
  // 失败/边界：无。
  task lost_ack();
    fault(RDMA_FAULT_DROP, 1, RDMA_NET_ACK);
    post(v(1, RDMA_VERB_RECV, 'h1000, 'h100));
    post(v(1, RDMA_VERB_RECV, 'h1100, 'h100));
    post(v(0, RDMA_VERB_SEND, 'h0000, 64));
    post(v(0, RDMA_VERB_SEND, 'h0100, 32));
  endtask

  // 功能：3 包 READ 响应丢末包：超时后只重读缺失部分。
  // 输入/输出及副作用：本端 0x3000 区域被写入。
  // 失败/边界：无。
  task lost_read_response();
    fault(RDMA_FAULT_DROP, 1, RDMA_NET_RDMA_READ_RESP, 2);
    post(v(0, RDMA_VERB_READ, 'h3000, 2500, 'h0000));
  endtask

  // 功能：丢 ATOMIC ACK：重复的 FETCH_ADD 由响应方返回缓存结果，目标只加一次。
  // 输入/输出及副作用：对端 0x3800 的 8 字节被改写。
  // 失败/边界：无。
  task lost_atomic_ack();
    rdma_verb_item it;

    fault(RDMA_FAULT_DROP, 1, RDMA_NET_ATOMIC_ACK);
    it = v(0, RDMA_VERB_FETCH_ADD, 'h3800, 8, 'h3800);
    it.swap_add_value = 64'h11;
    post(it);
  endtask
endclass

class rdma_srq_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_srq_vseq)

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_srq_vseq");
    super.new(name);
  endfunction

  // 功能：f0→f1 与 f1→f0 各一遍。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    shared(f0, f1);
    shared(f1, f0);
    env.wait_idle(500us);
  endtask

  // 功能：接收方 r 一个 SRQ、两个 RC QP 绑定它，发送方 s 两个 RC QP 分别互连；SRQ 投 6 个 RECV，两个 QP
  //   交替 SEND 6 个（RECV 按到达顺序被消耗）。
  // 输入/输出及副作用：r 的缓冲被写入。
  // 失败/边界：无。
  task shared(int unsigned s, int unsigned r);
    rdma_res_pd pd[2];
    rdma_res_cq cq[2];
    rdma_res_buf mem[2];
    rdma_res_mr mr[2];
    rdma_res_srq srq;
    rdma_res_qp qs[2];
    rdma_res_qp qr[2];
    rdma_verb_item it;
    int unsigned f[2];

    f = '{s, r};
    foreach (f[n]) begin
      alloc_pd(f[n], pd[n]);
      create_cq(f[n], env.cfg.qp_depth, cq[n]);
      alloc_buf(f[n], BUF_BYTES, mem[n]);
      reg_mr(pd[n], mem[n], mr[n]);
    end
    create_srq(pd[1], 64, srq);
    for (int unsigned k = 0; k < 2; k++) begin
      create_qp(pd[0], RDMA_DRV_QPT_RC, cq[0], 1'b0, qs[k]);
      create_qp(pd[1], RDMA_DRV_QPT_RC, cq[1], 1'b0, qr[k], srq);
      connect(qs[k], qr[k]);
    end
    for (int unsigned i = 0; i < 6; i++) begin
      it = verb(RDMA_VERB_RECV, qr[i % 2], mr[1], 'h1000 + 'h200 * i, 'h200);
      it.srq = srq;
      post(it);
    end
    for (int unsigned i = 0; i < 6; i++)
      post(verb(RDMA_VERB_SEND, qs[i % 2], mr[0], 'h200 * i, 100 + 64 * i));
  endtask
endclass

class rdma_qp_lifecycle_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_qp_lifecycle_vseq)

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_qp_lifecycle_vseq");
    super.new(name);
  endfunction

  // 功能：SQD 暂停/恢复、销毁后重建（远端 Function 不支持，跳过）。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    if (remote(0) || remote(1))
      return;
    fresh();
    sqd();
    rebuild();
    env.wait_idle(500us);
  endtask

  // 功能：f0 的 RC QP 转 SQD 后投递的 SEND 不发出（20us 内对端无完成），转回 RTS 后发出并完成。
  // 输入/输出及副作用：对端 RECV 被写入。
  // 失败/边界：SQD 期间对端收到报 UVM_ERROR。
  task sqd();
    int unsigned done;

    post(v(1, RDMA_VERB_RECV, 'h1000, 'h100));
    modify_qp(p.qp[0][0], RDMA_DRV_QPS_SQD);
    done = env.sb.checked;
    fork
      post(v(0, RDMA_VERB_SEND, 'h0000, 64));
    join_none
    #20us;
    if (env.sb.checked != done)
      `uvm_error("LIFECYCLE", "SEND posted in SQD completed before SQD->RTS")
    modify_qp(p.qp[0][0], RDMA_DRV_QPS_RTS);
    wait fork;
  endtask

  // 功能：按依赖顺序销毁两侧全部资源（QP → CQ → MR → BUF → PD），重建同样拓扑后 SEND/WRITE/READ。
  // 输入/输出及副作用：资源编号可能复用（资源库 generation 递增）。
  // 失败/边界：销毁顺序错误由资源库报错。
  task rebuild();
    for (int unsigned n = 0; n < 2; n++) begin
      for (int unsigned k = 0; k < 3; k++)
        destroy(p.qp[n][k]);
      destroy(p.cq[n]);
      destroy(p.urc_cq[n]);
      destroy(p.mr[n]);
      destroy(p.mem[n]);
      destroy(p.pd[n]);
    end
    fresh();
    post(v(1, RDMA_VERB_RECV, 'h1000, 'h400));
    post(v(0, RDMA_VERB_SEND, 'h0000, 300));
    post(v(0, RDMA_VERB_WRITE, 'h0400, 500, 'h2000));
    post(v(0, RDMA_VERB_READ, 'h0800, 500, 'h2000));
  endtask
endclass

// 需要 4 个 Function：0 = Host0 PF0、1 = Host0 VF1、2 = Host1 PF0、3 = Host1 VF1（cfg 声明顺序即下标）。
class rdma_multifunc_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_multifunc_vseq)

  rdma_pair a;
  rdma_pair b;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_multifunc_vseq");
    super.new(name);
  endfunction

  // 功能：对 a（0↔2）、b（1↔3）：基线流量 → VF1 FLR（a 流量并行）→ Host0 PF0 FLR（含 VF1，期间 2↔3
  //   新对流量）→ 整设备复位；每次复位后恢复范围内 Function、重建受影响的对并跑流量。
  // 输入/输出及副作用：经 sequencer 下发 item 与控制面请求。
  // 失败/边界：结果由 scoreboard 判定；范围外的流量须不受影响。
  task body();
    int unsigned scope[$];

    setup_pair(0, 2, BUF_BYTES, a);
    setup_pair(1, 3, BUF_BYTES, b);
    traffic(a);
    traffic(b);
    fork
      traffic(a);
    join_none
    reset(RDMA_CTRL_FLR, '{1});
    wait fork;
    reset(RDMA_CTRL_RECOVER, '{1});
    setup_pair(1, 3, BUF_BYTES, b);
    traffic(b);
    env.sys.pf_scope(0, 0, scope);
    reset(RDMA_CTRL_FLR, scope);
    traffic_pair(2, 3);
    reset(RDMA_CTRL_RECOVER, scope);
    setup_pair(0, 2, BUF_BYTES, a);
    setup_pair(1, 3, BUF_BYTES, b);
    traffic(a);
    traffic(b);
    env.sys.device_scope(scope);
    reset(RDMA_CTRL_FLR, scope);
    reset(RDMA_CTRL_RECOVER, scope);
    setup_pair(0, 2, BUF_BYTES, a);
    traffic(a);
    env.wait_idle(500us);
  endtask

  // 功能：对 x 的一轮流量：RECV + SEND、WRITE、READ。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：无。
  task traffic(rdma_pair x);
    p = x;
    post(v(1, RDMA_VERB_RECV, 'h1000, 'h400));
    post(v(0, RDMA_VERB_SEND, 'h0000, 700));
    post(v(0, RDMA_VERB_WRITE, 'h0400, 600, 'h2000));
    post(v(0, RDMA_VERB_READ, 'h0800, 600, 'h2000));
  endtask

  // 功能：新建 m↔n 的对并跑一轮流量（复位范围外的 Function 间）。
  // 输入/输出及副作用：见 traffic。
  // 失败/边界：无。
  task traffic_pair(int unsigned m, int unsigned n);
    rdma_pair x;

    setup_pair(m, n, BUF_BYTES, x);
    traffic(x);
  endtask
endclass

// 随机流量：f0↔f1 标准拓扑上 count 个随机 verb：方向、QP 类型（RC/UD/URC，远端无 URC）、操作、长度、
//   SGE 数（远端单 SGE）、数据模式均随机（$urandom，随 +ntb_random_seed 复现）；消耗 RQE 的请求先在
//   对端投足够大的 RECV。本端区域在缓冲前半、远端目标在后半，按槽位轮转。
class rdma_random_vseq extends rdma_scenario_vseq;
  `uvm_object_utils(rdma_random_vseq)

  localparam int unsigned SLOT = 'h1000;
  localparam int unsigned SLOTS = 8;

  int unsigned count = 200;

  // 功能：构造。
  // 输入/输出及副作用：name 为实例名。
  // 失败/边界：无。
  function new(string name = "rdma_random_vseq");
    super.new(name);
  endfunction

  // 功能：建拓扑后运行 count 个随机 verb（+RDMA_RANDOM_COUNT 可改）。
  // 输入/输出及副作用：经 sequencer 下发 item。
  // 失败/边界：结果由 scoreboard 判定。
  task body();
    void'($value$plusargs("RDMA_RANDOM_COUNT=%d", count));
    setup_pair(f0, f1, 2 * SLOT * SLOTS, p);
    for (int unsigned i = 0; i < count; i++)
      one((i % SLOTS) * SLOT);
    env.wait_idle(5ms);
  endtask

  // 功能：一个随机 verb（本端偏移 slot，远端偏移 SLOT*SLOTS + slot）。
  // 输入/输出及副作用：可能先在对端投 RECV。
  // 失败/边界：无。
  task one(int unsigned slot);
    rdma_verb_op_e ops[$] = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE,
                              RDMA_VERB_WRITE_IMM, RDMA_VERB_READ, RDMA_VERB_CMP_SWAP,
                              RDMA_VERB_FETCH_ADD};
    rdma_verb_item it;
    int unsigned n;
    int unsigned k;

    n = $urandom_range(0, 1);
    k = $urandom_range(0, p.urc ? 2 : 1);
    if (k == 1)
      ops = '{RDMA_VERB_SEND, RDMA_VERB_SEND_IMM};
    it = v(n, ops[$urandom_range(0, ops.size() - 1)], slot, 0, SLOT * SLOTS + slot, k);
    it.length = it.atomic() ? 8 :
                $urandom_range(1, k == 1 ? p.qp[n][k].mtu : SLOT);
    it.sge_count = it.atomic() || p.qp[n][k].owner.remote ? 1 : $urandom_range(1, 4);
    it.data_mode = payload_mode_e'($urandom_range(0, 3));
    it.data_fixed = $urandom;
    it.data_pattern = '{$urandom, $urandom, $urandom};
    it.imm = $urandom;
    it.compare_value = $urandom_range(0, 1);
    it.swap_add_value = {$urandom, $urandom};
    if (it.consumes_rqe())
      post(v(1 - n, RDMA_VERB_RECV, SLOT * SLOTS + slot, SLOT, 0, k));
    post(it);
  endtask
endclass
