// 目录：验证组件层 tb/rdma_biz_vseqs.sv。
// 层：验证组件（序列库）。
// 职责：按业务模板生成流量。每个启用的业务在 Function f0 ↔ f1 之间建立自己的一组资源（PD、CQ、
//   一个 QP、缓冲与 MR），QP 链路参数、报文属性、缓冲与 MR 权限全部取该业务模板；随后按模板的流量
//   分布逐条生成消息（verb 按权重、长度/SGE 按表达式、数据模式按候选、signaled 按比例、方向按 dir）。
// 依赖：rdma_base_vseq（控制面/数据面动作）、rdma_biz_cfg、rdma_env_cfg.spec（分布表达式求值器）。
// 所有权：业务资源由资源库登记；本序列只持有句柄。
// 生命周期：测试 run_phase 启动；业务依次执行，最后等待流量排空。

// 一个业务在 f0/f1 两端的资源（下标 0 为 f0 侧，1 为 f1 侧）。
class rdma_biz_pair extends uvm_object;
  `uvm_object_utils(rdma_biz_pair)

  rdma_biz_cfg biz;
  rdma_res_pd pd[2];
  rdma_res_cq cq[2];
  rdma_res_qp qp[2];
  rdma_res_buf mem[2];
  rdma_res_mr mr[2];

  // 功能：构造空的业务资源组，句柄由 rdma_biz_vseq::setup_biz 填写。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：未经 setup_biz 填写的资源组不得用于生成消息。
  function new(string name = "rdma_biz_pair");
    super.new(name);
  endfunction
endclass

// 设计说明：每个业务独立建资源，使不同业务的 QP 参数（MTU、深度、PSN、报文属性）与内存参数互不
//   影响；消息按槽轮转，本地槽区在 MR 前半，远端/接收槽区在后半，与 rdma_random_vseq 的布局一致，
//   scoreboard 能按区域比对。
class rdma_biz_vseq extends rdma_base_vseq;
  `uvm_object_utils(rdma_biz_vseq)

  // UD 接收缓冲前 40 字节为 GRH。
  localparam int unsigned GRH_BYTES = 40;

  int unsigned f0 = 0;
  int unsigned f1 = 1;
  time drain = 5ms;

  // 功能：构造默认在 Function 0 ↔ 1 之间运行、每个业务结束等待 5ms 排空的业务序列。
  // 输入/输出及副作用：name 为 UVM 名；不创建资源。
  // 失败/边界：f0/f1 必须在启动前指向已存在的 Function。
  function new(string name = "rdma_biz_vseq");
    super.new(name);
  endfunction

  // 功能：依次执行每个启用的业务：建资源 → 生成流量 → 等待排空。
  // 输入/输出及副作用：创建业务资源并投递消息。
  // 失败/边界：URC 业务在任一端为远端 Function 时跳过（rxe 不支持 URC）；没有启用的业务时报错。
  task body();
    rdma_biz_pair p;
    int unsigned ran;

    ran = 0;
    foreach (env.cfg.biz[i]) begin
      if (!env.cfg.biz[i].enable)
        continue;
      if (env.cfg.biz[i].urc() && (env.res.funcs[f0].remote || env.res.funcs[f1].remote)) begin
        `uvm_info("RDMA_BIZ", "skip urc: a remote Function has no URC", UVM_LOW)
        continue;
      end
      setup_biz(env.cfg.biz[i], p);
      traffic(p);
      env.wait_idle(drain);
      ran++;
    end
    if (ran == 0)
      `uvm_error("RDMA_BIZ", "no business is enabled (check +rdma.biz.en)")
  endtask

  // 功能：为一个业务在 f0/f1 两端各建 PD、CQ（深度 = qp.depth）、QP（类型/URC/深度/SGE 与链路参数取
  //   模板）、缓冲（mem.buf_bytes）与 MR（偏移 mem.mr_offset，远端权限取模板），然后把两个 QP 连到 RTS。
  // 输入/输出及副作用：b 为已 finalize 的模板，p 输出资源组；经控制面创建并登记资源。
  // 失败/边界：控制面失败由 ctrl 报 UVM_FATAL；模板未 finalize 时报错并照常使用当前值。
  task setup_biz(rdma_biz_cfg b, output rdma_biz_pair p);
    int unsigned f[2];
    rdma_ctrl_item it;
    bit [4:0] rights;

    if (!b.is_final())
      `uvm_error("RDMA_BIZ", {b.biz_name(), ": template used before finalize"})
    f = '{f0, f1};
    p = rdma_biz_pair::type_id::create({"biz_", b.biz_name()});
    p.biz = b;
    rights = rdma_drv_mr::rights_of(1'b1, b.mem.mr_remote_read, b.mem.mr_remote_write,
                                    b.mem.mr_remote_atomic);
    foreach (f[n]) begin
      alloc_pd(f[n], p.pd[n]);
      create_cq(f[n], b.qp.depth, p.cq[n]);
      it = new_ctrl(RDMA_CTRL_CREATE_QP, f[n]);
      it.pd = p.pd[n];
      it.qp_type = b.qp_type();
      it.urc = b.urc();
      it.send_cq = p.cq[n];
      it.recv_cq = p.cq[n];
      it.size = b.qp.depth;
      it.max_sge = b.qp.max_sge;
      it.biz = b;
      ctrl(it);
      void'($cast(p.qp[n], it.res));
      alloc_buf(f[n], b.mem.buf_bytes, p.mem[n]);
      reg_mr(p.pd[n], p.mem[n], p.mr[n], rights, b.mem.mr_offset);
    end
    connect(p.qp[0], p.qp[1]);
    `uvm_info("RDMA_BIZ", $sformatf("%s: QP f%0d#%0d <-> f%0d#%0d", b.biz_name(), f0, p.qp[0].id,
                                    f1, p.qp[1].id), UVM_MEDIUM)
  endtask

  // 功能：按模板流量分布生成 trf.count 条消息。unsigned WR 只有在同一 QP 后续出现 signaled WR 时才会被
  //   回收与结算，因此按方向分别计数连续 unsigned：达到 QP 深度一半时强制 signaled；全部消息之后，
  //   对仍有未结算 unsigned 的方向各补一条 signaled 消息。
  // 输入/输出及副作用：p 为业务资源组；投递消息（及所需的对端 RECV）。
  // 失败/边界：分布表达式非法时 uvm_fatal（见 rdma_biz_cfg::draw）；补发消息不计入 trf.count。
  task traffic(rdma_biz_pair p);
    int unsigned quiet[2];

    quiet = '{0, 0};
    for (int unsigned i = 0; i < p.biz.trf.count; i++)
      one(p, i, -1, quiet);
    foreach (quiet[n])
      if (quiet[n] != 0)
        one(p, p.biz.trf.count + n, n, quiet);
  endtask

  // 功能：生成一条消息：选方向（dir_override ≥ 0 时固定方向并强制 signaled）与 verb，按槽计算本地/远端
  //   偏移，按表达式抽长度与 SGE（原子固定 8 字节单 SGE；UD 长度不超过 MTU 与“槽 - GRH”；远端
  //   Function 单 SGE），随机数据模式/立即数/原子操作数，消耗 RQE 的 verb 先在对端投递一个整槽 RECV。
  // 输入/输出及副作用：p 为资源组、i 为消息序号；quiet 为两个方向的连续 unsigned 计数（输入输出）。
  // 失败/边界：长度与 SGE 被夹到合法范围；某方向连续 unsigned 达到 QP 深度一半时本条强制 signaled。
  task one(rdma_biz_pair p, int unsigned i, int dir_override, ref int unsigned quiet[2]);
    rdma_biz_cfg b;
    rdma_verb_item it;
    rdma_verb_op_e op;
    int unsigned n;
    int unsigned slot;
    int unsigned base;
    int unsigned len_max;
    int unsigned len;
    int unsigned sge_max;
    bit remote_side;

    b = p.biz;
    n = b.trf.dir == 2 ? $urandom_range(1, 0) : b.trf.dir;
    if (dir_override >= 0)
      n = dir_override;
    op = b.pick_op();
    slot = (i % b.mem.slots) * b.mem.slot_bytes;
    base = b.mem.slots * b.mem.slot_bytes;
    remote_side = env.res.funcs[n == 0 ? f0 : f1].remote;
    len_max = b.mem.slot_bytes;
    if (b.kind == RDMA_BIZ_UD)
      len_max = b.qp.mtu < b.mem.slot_bytes - GRH_BYTES ? b.qp.mtu : b.mem.slot_bytes - GRH_BYTES;
    it = verb(op, p.qp[n], p.mr[n], slot, 0, null, base + slot);
    if (!(op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM}))
      it.rmr = p.mr[1 - n];
    len = it.atomic() ? 8 : b.draw("len", b.trf.len, 1, len_max, env.cfg.spec);
    it.length = len;
    sge_max = b.qp.max_sge < len ? b.qp.max_sge : len;
    it.sge_count = it.atomic() || remote_side ? 1 : b.draw("sge", b.trf.sge, 1, sge_max,
                                                           env.cfg.spec);
    it.data_mode = b.pick_data_mode();
    it.data_fixed = $urandom;
    it.data_pattern = '{$urandom, $urandom, $urandom};
    it.imm = $urandom;
    it.compare_value = $urandom_range(1, 0);
    it.swap_add_value = {$urandom, $urandom};
    it.signaled = dir_override >= 0 || quiet[n] + 1 >= b.qp.depth / 2 ||
                  $urandom_range(99, 0) < b.trf.signaled_pct;
    quiet[n] = it.signaled ? 0 : quiet[n] + 1;
    if (it.consumes_rqe())
      post(verb(RDMA_VERB_RECV, p.qp[1 - n], p.mr[1 - n], base + slot, b.mem.slot_bytes));
    post(it);
  endtask
endclass
