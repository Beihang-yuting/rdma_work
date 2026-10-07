// 目录：验证组件层 tb/rdma_scoreboard.sv。
// 层：验证组件。
// 职责：端到端判定：投递事件把原始数据写入期望内存并建立期望完成；完成事件按 QP 结算，比对状态/长度/
//   立即数/源 QP，按操作语义（WRITE、READ、ATOMIC、SEND→RECV、UD GRH）更新期望内存，并立即比对该 WR
//   的目的区域（无其它在途 WR 重叠时；URC WRITE 不等 ACK，留给结束比对）；结束时整块比对全部 buffer。
// 依赖：rdma_mem_model、rdma_expect、rdma_res_db（按 QPN 找 QP）。
// 所有权：只读资源；期望归子对象。
// 生命周期：env 创建，仿真期间常驻。

`uvm_analysis_imp_decl(_posted)
`uvm_analysis_imp_decl(_cqe)
`uvm_analysis_imp_decl(_aeq)

class rdma_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rdma_scoreboard)

  localparam int unsigned GRH_BYTES = 40;

  rdma_res_db res;
  rdma_mem_model mem;
  rdma_expect exp;
  uvm_analysis_imp_posted #(rdma_verb_item, rdma_scoreboard) posted_export;
  uvm_analysis_imp_cqe #(rdma_verb_completion, rdma_scoreboard) cqe_export;
  uvm_analysis_imp_aeq #(rdma_aeq_event, rdma_scoreboard) aeq_export;
  int unsigned checked;
  int unsigned errors;
  int unsigned aeq_events;

  // 功能：构造。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    posted_export = new("posted_export", this);
    cqe_export = new("cqe_export", this);
    aeq_export = new("aeq_export", this);
    mem = rdma_mem_model::type_id::create("mem");
    exp = rdma_expect::type_id::create("exp");
  endfunction

  // 功能：投递：跟踪涉及的 buffer，原始数据写入源区域镜像，登记期望。
  // 输入/输出及副作用：修改期望内存与队列。
  // 失败/边界：无。
  function void write_posted(rdma_verb_item item);
    mem.track(item.lmr.mem);
    if (item.rmr != null)
      mem.track(item.rmr.mem);
    if (item.data.size() != 0)
      mem.write(item.lmr.mem, loff(item), item.data);
    exp.post(item);
  endfunction

  // 功能：完成：按 QPN 找 QP 后分 SQ/RQ 结算。
  // 输入/输出及副作用：见 settle_*。
  // 失败/边界：QPN 未知报错。
  function void write_cqe(rdma_verb_completion c);
    rdma_res_qp qp;

    qp = res.qp(c.func, c.qpn);
    if (qp == null)
      fail({"completion on unknown QP: ", c.convert2string()});
    else if (c.rq)
      settle_recv(qp, c);
    else
      settle_send(qp, c);
  endfunction

  // 功能：AEQ 事件计数（错误预测在 S3 接入）。
  // 输入/输出及副作用：aeq_events 加一。
  // 失败/边界：无。
  function void write_aeq(rdma_aeq_event e);
    aeq_events++;
  endfunction

  // 功能：结束检查：无未结算项，全部 buffer 与期望一致。
  // 输入/输出及副作用：读真实内存；报告统计。
  // 失败/边界：不一致报 UVM_ERROR。
  function void check_phase(uvm_phase phase);
    string left[$];

    exp.leftovers(left);
    foreach (left[i])
      fail(left[i]);
    errors += mem.compare_all();
    `uvm_info("RDMA_SB", $sformatf("checked=%0d errors=%0d aeq=%0d", checked, errors, aeq_events),
              UVM_LOW)
  endfunction

  // 功能：全部期望是否已结算。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit idle();
    return exp.idle();
  endfunction

  // 功能：记录错误。
  // 输入/输出及副作用：errors 加一并报 UVM_ERROR。
  // 失败/边界：无。
  protected function void fail(string message);
    errors++;
    `uvm_error("RDMA_SB", message)
  endfunction

  // 功能：本地区域在其 buffer 内的偏移。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function int unsigned loff(rdma_verb_item it);
    return rdma_verb_driver::buf_offset(it.lmr, it.local_offset);
  endfunction

  // 功能：远端区域在其 buffer 内的偏移。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function int unsigned roff(rdma_verb_item it);
    return rdma_verb_driver::buf_offset(it.rmr, it.remote_offset);
  endfunction

  // 功能：WR 的目的区域（RECV/READ/ATOMIC 为本地，WRITE 类为远端；SEND 无）。
  // 输入/输出及副作用：b/off/len 输出。
  // 失败/边界：无目的区域返回 0。
  protected function bit dest(rdma_verb_item it, output rdma_res_buf b, output int unsigned off,
                              output int unsigned len);
    len = it.atomic() ? 8 : it.length;
    if (it.op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM}) begin
      b = it.rmr.mem;
      off = roff(it);
      return 1'b1;
    end
    b = it.lmr.mem;
    off = loff(it);
    return it.op inside {RDMA_VERB_RECV, RDMA_VERB_READ} || it.atomic();
  endfunction

  // 功能：立即比对 it 的目的区域与期望（其它在途 WR 的目的区域与之重叠时跳过，留给结束比对）。
  // 输入/输出及副作用：读真实内存；checked 加一。
  // 失败/边界：差异计入 errors。
  protected function void check_region(rdma_verb_item it);
    rdma_verb_item others[$];
    rdma_res_buf b;
    rdma_res_buf ob;
    int unsigned off;
    int unsigned len;
    int unsigned ooff;
    int unsigned olen;

    if (!dest(it, b, off, len))
      return;
    exp.pending(others);
    foreach (others[i])
      if (others[i] != it && dest(others[i], ob, ooff, olen) && ob == b &&
          ooff < off + len && off < ooff + olen)
        return;
    checked++;
    errors += mem.compare(b, off, len, it.convert2string());
  endfunction

  // 功能：SQ 完成：按序结算到该 wr_id；最后一个比对状态，期望成功的应用效果并立即比对。
  // 输入/输出及副作用：修改期望内存。
  // 失败/边界：找不到请求或状态不符时报错。
  protected function void settle_send(rdma_res_qp qp, rdma_verb_completion c);
    rdma_verb_item done[$];
    bit last;

    if (!exp.settle_send(qp, c.wr_id, done)) begin
      fail({"SQ completion matches no request: ", c.convert2string()});
      return;
    end
    foreach (done[i]) begin
      last = i == done.size() - 1;
      if (last) begin
        checked++;
        if (c.status != done[i].expect_status)
          fail($sformatf("status %s != expected %s for %s", c.status.name(),
                         done[i].expect_status.name(), done[i].convert2string()));
      end
      if (done[i].expect_status != RDMA_DRV_WC_SUCCESS ||
          (last && c.status != RDMA_DRV_WC_SUCCESS))
        continue;
      apply_send(done[i]);
      if (!(qp.urc && done[i].op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM}))
        check_region(done[i]);
    end
  endfunction

  // 功能：SQ 请求的内存效果：WRITE 写远端；READ 远端 → 本地；ATOMIC 读改写远端（小端 8B）、原值写回本地。
  // 输入/输出及副作用：修改期望内存。
  // 失败/边界：SEND 由 RQ 完成结算。
  protected function void apply_send(rdma_verb_item it);
    byte unsigned d[$];
    bit [63:0] orig;
    bit [63:0] value;

    if (it.op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM})
      mem.write(it.rmr.mem, roff(it), it.data);
    else if (it.op == RDMA_VERB_READ) begin
      mem.read(it.rmr.mem, roff(it), it.length, d);
      mem.write(it.lmr.mem, loff(it), d);
    end
    else if (it.atomic()) begin
      mem.read(it.rmr.mem, roff(it), 8, d);
      orig = {d[7], d[6], d[5], d[4], d[3], d[2], d[1], d[0]};
      if (it.op == RDMA_VERB_CMP_SWAP)
        value = orig == it.compare_value ? it.swap_add_value : orig;
      else
        value = orig + it.swap_add_value;
      mem.write(it.rmr.mem, roff(it), le8(value));
      mem.write(it.lmr.mem, loff(it), le8(orig));
    end
  endfunction

  // 功能：64 位值的小端 8 字节。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function rdma_byte_q le8(bit [63:0] v);
    rdma_byte_q q;

    for (int k = 0; k < 8; k++)
      q.push_back(v[8 * k +: 8]);
    return q;
  endfunction

  // 功能：RQ 完成：与入站请求配对，比对状态、长度（UD 含 40B GRH）、立即数、UD 源 QP；SEND 数据写入
  //   RECV buffer（UD 先预测 GRH），WRITE_IMM 的数据写入其远端区域；随后立即比对。
  // 输入/输出及副作用：修改期望内存。
  // 失败/边界：不匹配报错。
  protected function void settle_recv(rdma_res_qp qp, rdma_verb_completion c);
    rdma_verb_item recv;
    rdma_verb_item src;
    int unsigned grh;

    if (!exp.settle_recv(qp, c.wr_id, recv, src)) begin
      fail({"RQ completion matches no RECV/inbound request: ", c.convert2string()});
      return;
    end
    checked++;
    grh = qp.ud() ? GRH_BYTES : 0;
    if (c.status != RDMA_DRV_WC_SUCCESS)
      fail({"RQ completion failed: ", c.convert2string()});
    if (c.byte_len != src.length + grh)
      fail($sformatf("RQ byte_len %0d != %0d for %s", c.byte_len, src.length + grh,
                     src.convert2string()));
    if (src.op inside {RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM} && c.imm != src.imm)
      fail($sformatf("RQ imm %08h != %08h for %s", c.imm, src.imm, src.convert2string()));
    if (qp.ud() && c.src_qp != src.qp.id)
      fail($sformatf("UD src_qp %0d != %0d", c.src_qp, src.qp.id));
    if (src.op == RDMA_VERB_WRITE_IMM) begin
      mem.write(src.rmr.mem, roff(src), src.data);
      if (!qp.urc)
        check_region(src);
      return;
    end
    if (grh != 0)
      mem.write(recv.lmr.mem, loff(recv), grh_bytes(src.length));
    mem.write(recv.lmr.mem, loff(recv) + grh, src.data);
    check_region(recv);
  endfunction

  // 功能：UD 接收缓冲开头 40B GRH（RoCEv2 IPv4：前 20B 为 0，IPv4 头 0x45、总长 = IP+UDP+BTH+DETH+
  //   载荷+ICRC、TTL 64、协议 UDP，其余为 0）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function rdma_byte_q grh_bytes(int unsigned len);
    rdma_byte_q g;
    int unsigned total;

    total = 20 + 8 + 12 + 8 + len + 4;
    repeat (GRH_BYTES) g.push_back(8'h00);
    g[20] = 8'h45;
    g[22] = total[15:8];
    g[23] = total[7:0];
    g[28] = 8'd64;
    g[29] = 8'd17;
    return g;
  endfunction
endclass
