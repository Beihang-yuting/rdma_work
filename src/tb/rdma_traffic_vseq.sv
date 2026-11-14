// 目录：验证组件层 tb/rdma_traffic_vseq.sv。
// 层：验证组件（序列库）。
// 职责：按业务场景生成流量。每个 flow group 在两个 Function 端点之间建立可变数量的对称 QP，PD、缓冲
//   和 MR 在端点侧共享，CQ/QP 按 qp_count 独立创建；QP 链路参数、报文属性和流量分布全部取统一场景。
// 依赖：rdma_base_vseq（控制面/数据面动作）、rdma_scenario_cfg、rdma_env_cfg.spec（分布表达式求值器）。
// 所有权：场景资源由资源库登记；本序列只持有句柄。
// 生命周期：测试 run_phase 启动；全部兼容操作共享资源，最后等待流量排空。

// 一个业务边在 f0/f1 两个端点的资源（下标 0 为 f0 侧，1 为 f1 侧）；qp[2] 保留首个 QP 兼容旧序列，
// qp_list 保存同一端点的全部 QP。这里的两个下标只描述一条点到点业务边，不限制 env 的 Function 总数。
class rdma_traffic_pair extends uvm_object;
  `uvm_object_utils(rdma_traffic_pair)

  rdma_scenario_cfg	scenario;
  rdma_res_pd	pd[2];
  rdma_res_cq	cq[2];
  rdma_res_qp	qp[2];
  rdma_res_cq	cq_list[2][$];
  rdma_res_qp	qp_list[2][$];
  rdma_res_buf	mem[2];
  rdma_res_mr	mr[2];
  int unsigned	qp_count;

  // 功能：构造空的场景资源组，句柄由 rdma_traffic_vseq::setup_scenario 填写。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：未经 setup_scenario 填写的资源组不得用于生成消息。
  extern function new(string	name = "rdma_traffic_pair");
endclass

  // 功能：构造空的场景资源组，句柄由 rdma_traffic_vseq::setup_scenario 填写。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：未经 setup_scenario 填写的资源组不得用于生成消息。
function rdma_traffic_pair::new(string	name = "rdma_traffic_pair");
    super.new(name);
    qp_count = 0;
endfunction

// 设计说明：单操作和兼容 mix 在每个 flow group 内共享端点 PD/内存，按 QP 数量创建独立 CQ/QP；
//   每个 QP 轮转使用同一份 MR 槽区，本地槽区在 MR 前半，远端/接收槽区在后半，与 rdma_random_vseq
//   的布局一致，scoreboard 能按区域比对。
class rdma_traffic_vseq extends rdma_base_vseq;
  `uvm_object_utils(rdma_traffic_vseq)

  // UD 接收缓冲前 40 字节为 GRH。
  localparam int unsigned	GRH_BYTES = 40;

  int unsigned	f0 = 0;
  int unsigned	f1 = 1;
  int unsigned	qp_count = 1;
  bit	tx_only;
  bit	tx_success;
  int unsigned	tx_dest_qpn;
  bit [31:0]	tx_dest_qkey;
  bit [47:0]	tx_dmac;
  rdma_flow_group_t	flow_groups[$];
  time	drain = 5ms;

  // 功能：构造默认在 Function 0 ↔ 1 之间运行、每个业务结束等待 5ms 排空的业务序列；qp_count=1
  //   仅是无 flow_groups 时的兼容默认值，flow_groups 非空时由每个条目覆盖端点和 QP 数量。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：f0/f1 必须在启动前指向已存在的 Function，flow group 的 ID/数量由 body 再校验。
  extern function new(string	name = "rdma_traffic_vseq");

  // 功能：校验统一场景后按显式 flow_groups 或 cfg.flow_groups 逐条建资源、投递流量并等待排空；无组时保留 f0/f1 兼容路径。
  // 输入/输出及副作用：每个 flow group 追加资源库对象并投递其消息；不修改 dpu_common 快照或配置目录。
  // 失败/边界：ID 不存在、端点相同、QP 数为零、场景无效或远端 URC 在创建资源前 fatal；TX-only 只接受单一发送端和有效目的。
  extern task body();

  // 功能：为双端或 TX-only 业务建立 PD、缓冲/MR、CQ/QP；TX-only 只创建发送端并把 UD QP 推到 RTS。
  // 输入/输出及副作用：b 为已 finalize 的场景，requested_qps 为 QP 数，p 输出资源组；控制面创建结果登记到 res。
  // 失败/边界：requested_qps=0、场景未 finalize、TX-only 目的缺失或控制面失败时 fatal；资源已创建后失败不伪装成可重试事务。
  extern task setup_scenario(rdma_scenario_cfg	b, output rdma_traffic_pair	p,
                             input int unsigned requested_qps = 1);

  // 功能：按场景流量分布生成 traffic.count 条消息。unsigned WR 只有在同一 QP 后续出现 signaled WR 时才会被
  //   回收与结算，且投递时源数据就写入本地槽，因此按方向分别计数连续 unsigned：达到 min(QP 深度/2,
  //   槽数-1) 时强制 signaled（其完成意味着之前的 WR 全部完成），保证一个槽被再次写入前旧 WR 已执行；
  //   全部消息之后，对每个 QP/方向仍有未结算 unsigned 的队列各补一条 signaled 消息。
  // 输入/输出及副作用：p 为场景资源组；双端投递消息及所需 RECV，TX-only 只投递发送 WR。
  // 失败/边界：分布表达式非法时 uvm_fatal（见 rdma_scenario_cfg::draw）；补发消息不计入 traffic.count。
  extern task traffic(rdma_traffic_pair	p);

  // 功能：生成一条消息：选方向（dir_override ≥ 0 时固定方向并强制 signaled）与 verb，按槽计算本地/远端
  //   偏移，按表达式抽长度与 SGE（原子固定 8 字节单 SGE；UD 长度不超过 MTU 与“槽 - GRH”；远端
  //   Function 单 SGE），随机数据模式/立即数/原子操作数，消耗 RQE 的 verb 先在对端投递一个整槽 RECV。
  // 输入/输出及副作用：p 为资源组、i 为消息序号；quiet 按方向/QP 保存连续 unsigned 计数，
  //   qp_override>=0 用于尾部补发时指定 QP。
  // 失败/边界：长度与 SGE 抽样越界立即 fatal，禁止裁剪或重复求值；TX-only 目的字段缺失或某方向连续 unsigned 达到 min(QP 深度/2, 槽数-1) 时本条
  //   强制 signaled。
  extern task one(rdma_traffic_pair	p, int unsigned	i, int	dir_override,
                  ref int unsigned	quiet[2][$], input int	qp_override = -1);

  // 功能：返回一个方向允许的连续 unsigned WR 上限：min(QP 深度/2, 槽数-1)。
  // 输入/输出及副作用：b 为业务场景，纯计算。
  // 失败/边界：深度 1 或单槽时返回 0，即全部 signaled。
  extern function int unsigned unsigned_limit(rdma_scenario_cfg	b);

  // 功能：把 dpu_common 发布的 global Function ID 映射为 env 中稳定的本地节点/资源下标。
  // 输入/输出及副作用：只读 env.sys 节点；返回 -1 表示未找到，不创建资源。
  // 失败/边界：env 未绑定、Function 尚未发布或 ID 属于远端 Function 时返回 -1。
  extern function int find_global_function(int unsigned global_id);

  // 功能：按当前场景把一个 WR 的 payload/立即数表达式物化到 item，确保同一 WR 后续路径复用同一值。
  // 输入/输出及副作用：b 为冻结场景、item 为待投递 item；写入 data_fixed/data_pattern/imm，不修改配置。
  // 失败/边界：FIXED/PATTERN 缺少对应表达式、PATTERN 缺少花括号或任一元素越界时 fatal；空 IMM 保持兼容随机默认。
  extern function void materialize_payload(rdma_scenario_cfg b, rdma_verb_item item);
endclass

  // 功能：构造默认在 Function 0 ↔ 1 之间运行、每个业务结束等待 5ms 排空的业务序列。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：f0/f1 必须在启动前指向已存在的 Function。
function rdma_traffic_vseq::new(string	name = "rdma_traffic_vseq");
    super.new(name);
endfunction

  // 功能：校验单一场景与端点后建资源一次，生成单操作或 mix 流量并排空。
  // 输入/输出及副作用：创建场景资源并投递消息。
  // 失败/边界：端点缺失/相同、场景无效或远端 URC 在创建资源前 fatal。
task rdma_traffic_vseq::body();
    rdma_traffic_pair	p;
    rdma_status	status;
    int	left;
    int	right;
    int unsigned	groups;
    time	deadline;

    status = env.cfg.scenario.validate();
    if (!status.ok())
      `uvm_fatal("RDMA_SCENARIO", status.convert2string())
    if (tx_only) begin
      if (flow_groups.size() != 0 || tx_dest_qpn == 0 || tx_dmac == '0 ||
          (env.cfg.scenario.qp.kind == RDMA_SCENARIO_UD && tx_dest_qkey == 0))
        `uvm_fatal("RDMA_SCENARIO",
                   "TX-only requires no flow groups and complete destination fields")
      if (!(env.cfg.scenario.qp.kind inside {RDMA_SCENARIO_RC, RDMA_SCENARIO_UD}))
        `uvm_fatal("RDMA_SCENARIO", "TX-only supports RC or UD only")
      if (env.cfg.scenario.weight(RDMA_VERB_WRITE) != 0 ||
          env.cfg.scenario.weight(RDMA_VERB_WRITE_IMM) != 0 ||
          env.cfg.scenario.weight(RDMA_VERB_READ) != 0 ||
          env.cfg.scenario.weight(RDMA_VERB_CMP_SWAP) != 0 ||
          env.cfg.scenario.weight(RDMA_VERB_FETCH_ADD) != 0)
        `uvm_fatal("RDMA_SCENARIO", "TX-only supports SEND and SEND_IMM only")
      if (qp_count == 0 || env.cfg.scenario.traffic.count == 0 ||
          env.cfg.scenario.traffic.count > env.cfg.scenario.mem.slots)
        `uvm_fatal("RDMA_SCENARIO", "TX-only requires nonzero count/QPs, independent slots")
      if (env.cfg.scenario.qp.kind == RDMA_SCENARIO_RC &&
          env.cfg.scenario.traffic.count > qp_count)
        `uvm_fatal("RDMA_SCENARIO", "TX-only RC permits one first SEND per QP")
      if (env.cfg.scenario.qp.kind == RDMA_SCENARIO_UD &&
          ((env.cfg.scenario.traffic.count - 1) / qp_count + 1) > env.cfg.scenario.qp.depth)
        `uvm_fatal("RDMA_SCENARIO", "TX-only UD exceeds the per-QP SQ window")
      if (f0 >= env.res.funcs.size() || env.res.funcs[f0].remote)
        `uvm_fatal("RDMA_SCENARIO", "TX-only sender Function is missing or remote")
      env.sb.begin_tx();
      setup_scenario(env.cfg.scenario, p, qp_count);
      traffic(p);
      // 完整帧匹配才结束；独立槽一直保留，不借助 ACK/CQE 回收或重复写入。
      deadline = $time + env.cfg.response_timeout;
      while (!env.sb.tx_complete(env.cfg.scenario.traffic.count) &&
             env.sb.errors == 0 && $time < deadline)
        #(env.cfg.poll_interval);
      tx_success = env.sb.tx_complete(env.cfg.scenario.traffic.count);
      if (!tx_success)
        env.sb.tx_failure("TX frame verification failed or timed out");
      return;
    end
    // 配置中的 flow_groups 是项目级拓扑声明；序列字段仍保留给旧用例和平台临时覆盖。
    if (flow_groups.size() == 0 && env.cfg.flow_groups.size() != 0)
      flow_groups = env.cfg.flow_groups;
    groups = flow_groups.size() == 0 ? 1 : flow_groups.size();
    for (int unsigned g = 0; g < groups; g++) begin
      if (flow_groups.size() == 0) begin
        left = int'(f0);
        right = int'(f1);
        if (left == right || left < 0 || right < 0 ||
            left >= int'(env.res.funcs.size()) || right >= int'(env.res.funcs.size()))
          `uvm_fatal("RDMA_SCENARIO", "traffic requires two distinct existing Function indexes")
      end
      else begin
        left = find_global_function(flow_groups[g].f0_global_id);
        right = find_global_function(flow_groups[g].f1_global_id);
        if (left < 0 || right < 0 || left == right)
          `uvm_fatal("RDMA_SCENARIO", $sformatf("flow group %0d references missing or identical global Function IDs", g))
        qp_count = flow_groups[g].qp_count;
      end
      if (flow_groups.size() == 0 && qp_count == 0)
        `uvm_fatal("RDMA_SCENARIO", "traffic requires at least one QP")
      if (flow_groups.size() != 0 && flow_groups[g].qp_count == 0)
        `uvm_fatal("RDMA_SCENARIO", $sformatf("flow group %0d requests zero QPs", g))
      if (env.cfg.scenario.urc() && (env.res.funcs[left].remote || env.res.funcs[right].remote))
        `uvm_fatal("RDMA_SCENARIO", "URC is unsupported by a remote Function")
      f0 = left;
      f1 = right;
      setup_scenario(env.cfg.scenario, p, qp_count);
      traffic(p);
      env.wait_idle(drain);
    end
endtask

  // 功能：为一条业务边在 f0/f1 两端各建 PD、CQ（深度 = qp.depth）、QP（类型/URC/深度/SGE 与链路参数取
  //   场景）、缓冲（mem.buf_bytes）与 MR（偏移 mem.mr_offset，远端权限取场景），然后把两个 QP 连到 RTS。
  // 输入/输出及副作用：b 为已 finalize 的场景，p 输出资源组；经控制面创建并登记资源。
  // 失败/边界：控制面失败由 ctrl 报 UVM_FATAL；场景未 finalize 时 fatal，不继续分配。
task rdma_traffic_vseq::setup_scenario(rdma_scenario_cfg	b, output rdma_traffic_pair	p,
                                       input int unsigned requested_qps = 1);
    int unsigned	f[2];
    rdma_ctrl_item	it;
    bit [4:0]	rights;

    if (!b.is_final())
      `uvm_fatal("RDMA_SCENARIO", "scenario used before finalize")
    if (requested_qps == 0)
      `uvm_fatal("RDMA_SCENARIO", "flow group must request at least one QP")
    f = '{f0, f1};
    p = rdma_traffic_pair::type_id::create("traffic_pair");
    p.scenario = b;
    p.qp_count = requested_qps;
    rights = rdma_drv_mr::rights_of(1'b1, b.mem.mr_remote_read, b.mem.mr_remote_write,
                                    b.mem.mr_remote_atomic);
    if (tx_only) begin
      f[0] = f0;
      alloc_pd(f[0], p.pd[0]);
      alloc_buf(f[0], b.mem.buf_bytes, p.mem[0]);
      reg_mr(p.pd[0], p.mem[0], p.mr[0], rights, b.mem.mr_offset);
      for (int unsigned q = 0; q < requested_qps; q++) begin
        rdma_res_cq cq;
        rdma_res_qp qp;
        rdma_drv_qp_state_e states[3] = '{RDMA_DRV_QPS_INIT, RDMA_DRV_QPS_RTR, RDMA_DRV_QPS_RTS};

        create_cq(f[0], b.qp.depth, cq);
        it = new_ctrl(RDMA_CTRL_CREATE_QP, f[0]);
        it.pd = p.pd[0];
        it.qp_type = b.qp_type();
        it.urc = 1'b0;
        it.send_cq = cq;
        it.recv_cq = cq;
        it.size = b.qp.depth;
        it.max_sge = b.qp.max_sge;
        ctrl(it);
        void'($cast(qp, it.res));
        p.cq_list[0].push_back(cq);
        p.qp_list[0].push_back(qp);
        for (int unsigned s = 0; s < 3; s++) begin
          rdma_ctrl_item mod;

          mod = new_ctrl(RDMA_CTRL_MODIFY_QP, f[0]);
          mod.qp = qp;
          mod.state = states[s];
          mod.tx_only = 1'b1;
          mod.tx_dest_qpn = tx_dest_qpn;
          mod.tx_dest_psn = b.qp.psn;
          mod.tx_dest_dmac = tx_dmac;
          ctrl(mod);
        end
      end
      p.cq[0] = p.cq_list[0][0];
      p.qp[0] = p.qp_list[0][0];
      return;
    end
    foreach (f[n]) begin
      alloc_pd(f[n], p.pd[n]);
      alloc_buf(f[n], b.mem.buf_bytes, p.mem[n]);
      reg_mr(p.pd[n], p.mem[n], p.mr[n], rights, b.mem.mr_offset);
      for (int unsigned q = 0; q < requested_qps; q++) begin
        rdma_res_cq	cq;
        rdma_res_qp	qp;

        create_cq(f[n], b.qp.depth, cq);
        it = new_ctrl(RDMA_CTRL_CREATE_QP, f[n]);
        it.pd = p.pd[n];
        it.qp_type = b.qp_type();
        it.urc = b.urc();
        it.send_cq = cq;
        it.recv_cq = cq;
        it.size = b.qp.depth;
        it.max_sge = b.qp.max_sge;
        ctrl(it);
        void'($cast(qp, it.res));
        p.cq_list[n].push_back(cq);
        p.qp_list[n].push_back(qp);
      end
      p.cq[n] = p.cq_list[n][0];
      p.qp[n] = p.qp_list[n][0];
    end
    for (int unsigned q = 0; q < requested_qps; q++) begin
      connect(p.qp_list[0][q], p.qp_list[1][q]);
      `uvm_info("RDMA_SCENARIO", $sformatf("%s: QP f%0d#%0d <-> f%0d#%0d", b.traffic.op, f0,
                                      p.qp_list[0][q].id, f1, p.qp_list[1][q].id), UVM_MEDIUM)
    end
endtask

  // 功能：按场景流量分布生成 traffic.count 条消息。unsigned WR 只有在同一 QP 后续出现 signaled WR 时才会被
  //   回收与结算，且投递时源数据就写入本地槽，因此按方向分别计数连续 unsigned：达到 min(QP 深度/2,
  //   槽数-1) 时强制 signaled（其完成意味着之前的 WR 全部完成），保证一个槽被再次写入前旧 WR 已执行；
  //   全部消息之后，对仍有未结算 unsigned 的方向各补一条 signaled 消息。
  // 输入/输出及副作用：p 为场景资源组；投递消息（及所需的对端 RECV）。
  // 失败/边界：分布表达式非法时 uvm_fatal（见 rdma_scenario_cfg::draw）；补发消息不计入 traffic.count。
task rdma_traffic_vseq::traffic(rdma_traffic_pair	p);
    int unsigned	quiet[2][$];

    foreach (quiet[n]) begin
      for (int unsigned q = 0; q < p.qp_count; q++)
        quiet[n].push_back(0);
    end
    for (int unsigned	i = 0; i < p.scenario.traffic.count; i++)
      one(p, i, -1, quiet);
    if (!tx_only)
      foreach (quiet[n])
        foreach (quiet[n][q])
          if (quiet[n][q] != 0)
            one(p, p.scenario.traffic.count + n * p.qp_count + q, n, quiet, q);
endtask

  // 功能：生成一条消息：选方向（dir_override ≥ 0 时固定方向并强制 signaled）与 verb，按槽计算本地/远端
  //   偏移，按表达式抽长度与 SGE（原子固定 8 字节单 SGE；UD 长度不超过 MTU 与“槽 - GRH”；远端
  //   Function 单 SGE），随机数据模式/立即数/原子操作数，消耗 RQE 的 verb 先在对端投递一个整槽 RECV。
  // 输入/输出及副作用：p 为资源组、i 为消息序号；quiet 为两个方向的连续 unsigned 计数（输入输出）。
  // 失败/边界：长度与 SGE 抽样越界立即 fatal，禁止裁剪或重复求值；某方向连续 unsigned 达到 min(QP 深度/2, 槽数-1) 时本条
  //   强制 signaled。
task rdma_traffic_vseq::one(rdma_traffic_pair	p, int unsigned	i, int	dir_override,
                            ref int unsigned	quiet[2][$], input int	qp_override = -1);
    rdma_scenario_cfg	b;
    rdma_verb_item	it;
    rdma_verb_op_e	op;
    int unsigned	n;
    int unsigned	slot;
    int unsigned	base;
    int unsigned	len_max;
    int unsigned	len;
    int unsigned	sge_max;
    int unsigned	qp_slot;
    bit	remote_side;
    rdma_res_qp	active_qp[2];

    b = p.scenario;
    n = tx_only ? 0 : (b.traffic.dir == 2 ? $urandom_range(1, 0) : b.traffic.dir);
    if (dir_override >= 0)
      n = dir_override;
    op = b.pick_op();
    qp_slot = qp_override >= 0 ? qp_override : i % p.qp_count;
    active_qp[0] = p.qp_list[0][qp_slot];
    active_qp[1] = tx_only ? null : p.qp_list[1][qp_slot];
    slot = (i % b.mem.slots) * b.mem.slot_bytes;
    base = b.mem.slots * b.mem.slot_bytes;
    remote_side = env.res.funcs[n == 0 ? f0 : f1].remote;
    len_max = b.mem.slot_bytes;
    if (tx_only && b.qp.mtu < len_max)
      len_max = b.qp.mtu;
    if (!tx_only && b.qp.kind == RDMA_SCENARIO_UD)
      len_max = b.qp.mtu < b.mem.slot_bytes - GRH_BYTES ? b.qp.mtu : b.mem.slot_bytes - GRH_BYTES;
    it = verb(op, active_qp[n], p.mr[n], slot, 0, null, base + slot);
    if (!(op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM}))
      it.rmr = p.mr[1 - n];
    len = it.atomic() ? 8 : b.draw("len", b.traffic.len, 1, len_max, env.cfg.spec);
    it.length = len;
    sge_max = b.qp.max_sge < len ? b.qp.max_sge : len;
    it.sge_count = it.atomic() || remote_side ? 1 : b.draw("sge", b.traffic.sge, 1, sge_max,
                                                           env.cfg.spec);
    it.data_mode = b.pick_data_mode();
    materialize_payload(b, it);
    it.compare_value = $urandom_range(1, 0);
    it.swap_add_value = {$urandom, $urandom};
    it.signaled = tx_only || dir_override >= 0 || quiet[n][qp_slot] + 1 >= unsigned_limit(b) ||
                  $urandom_range(99, 0) < b.traffic.signaled_pct;
    quiet[n][qp_slot] = it.signaled ? 0 : quiet[n][qp_slot] + 1;
    if (!tx_only && it.consumes_rqe())
      post(verb(RDMA_VERB_RECV, active_qp[1 - n], p.mr[1 - n], base + slot, b.mem.slot_bytes));
    if (tx_only) begin
      if (!(op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM}))
        `uvm_fatal("RDMA_SCENARIO", "TX-only supports SEND and SEND_IMM only")
      it.tx_only = 1'b1;
      it.tx_dest_qpn = tx_dest_qpn;
      it.tx_dest_qkey = tx_dest_qkey;
      it.tx_dmac = tx_dmac;
    end
    post(it);
endtask

// 功能：按 payload 模式解析并物化场景中的 FIXED/PATTERN/IMM 值，供 driver、DMA 和期望路径共同使用。
// 输入/输出及副作用：b 提供原始表达式和统一求值器，item 接收本次 WR 的固定字节/模式集合/立即数。
// 失败/边界：FIXED 或 PATTERN 未提供表达式、PATTERN 非 `{...}`、元素抽样超出字节范围时立即 fatal；RANDOM/INCREMENT
//   不填固定集合，空 IMM 才保留旧的随机默认。
function void rdma_traffic_vseq::materialize_payload(rdma_scenario_cfg b, rdma_verb_item item);
  string spec;
  string body;
  string parts[$];

  item.data_pattern.delete();
  case (item.data_mode)
    PAYLOAD_FIXED: begin
      if (rdma_value_spec::strip(b.traffic.data_fixed) == "")
        `uvm_fatal("RDMA_SCENARIO",
                   {"rdma.traffic.data_fixed is required when data_mode ",
                    "selects FIXED"})
      item.data_fixed = b.draw("data_fixed", b.traffic.data_fixed, 0, 8'hff, env.cfg.spec);
    end
    PAYLOAD_PATTERN: begin
      spec = rdma_value_spec::strip(b.traffic.data_pattern);
      if (spec.len() < 2 || spec[0] != "{" || spec[spec.len() - 1] != "}")
        `uvm_fatal("RDMA_SCENARIO",
                   {"rdma.traffic.data_pattern must be an ordered collection ",
                    "such as {0xde,0xad}"})
      body = rdma_value_spec::strip(spec.substr(1, spec.len() - 2));
      rdma_value_spec::split_top(body, parts);
      if (parts.size() == 0 || rdma_value_spec::strip(parts[0]) == "")
        `uvm_fatal("RDMA_SCENARIO", "rdma.traffic.data_pattern must not be empty")
      foreach (parts[k])
        item.data_pattern.push_back(
          byte'(b.draw("data_pattern", parts[k], 0, 8'hff, env.cfg.spec)));
    end
    default: begin
      item.data_fixed = 0;
    end
  endcase
  if (rdma_value_spec::strip(b.traffic.imm) != "")
    item.imm = b.draw("imm", b.traffic.imm, 0, 32'hffff_ffff, env.cfg.spec);
  else
    item.imm = $urandom;
endfunction

  // 功能：返回一个方向允许的连续 unsigned WR 上限：min(QP 深度/2, 槽数-1)。
  // 输入/输出及副作用：b 为业务场景，纯计算。
  // 失败/边界：深度 1 或单槽时返回 0，即全部 signaled。
function int unsigned rdma_traffic_vseq::unsigned_limit(rdma_scenario_cfg	b);
    int unsigned	by_depth;

    by_depth = b.qp.depth / 2;
    return by_depth < b.mem.slots - 1 ? by_depth : b.mem.slots - 1;
endfunction

// 功能：把 dpu_common 发布的 global Function ID 映射为 env 中稳定的本地节点/资源下标。
// 输入/输出及副作用：只读 env.sys 节点；返回 -1 表示未找到，不创建资源。
// 失败/边界：env 未绑定、Function 尚未发布或 ID 属于远端 Function 时返回 -1。
function int rdma_traffic_vseq::find_global_function(int unsigned global_id);
    return env.find_function_index(global_id);
endfunction
