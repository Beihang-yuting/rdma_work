// 目录：验证组件层 tb/rdma_scoreboard.sv。
// 层：验证组件。
// 职责：端到端判定：投递事件把原始数据写入期望内存并建立期望完成（rdma_expect 预测状态）；完成事件按
//   QP 结算，比对状态/长度/立即数/源 QP，按操作语义（WRITE、READ、ATOMIC、SEND→RECV、UD GRH；远端
//   Function 写入的 GRH 取实际值）更新期望内存，并立即比对该 WR 的目的区域（无其它在途 WR 重叠时；
//   URC WRITE 不等 ACK，留给结束比对）；结束时整块比对全部 buffer。资源事件：QP 进入 ERR 时在途项可
//   FLUSH；QP 销毁/FLR 撤销期望，其目的区域以实际内容为准。
// 依赖：rdma_mem_model、rdma_expect、rdma_res_db（按 QPN 找 QP、资源事件）。
// 所有权：只读资源；期望归子对象。
// 生命周期：env 创建，仿真期间常驻。

`uvm_analysis_imp_decl(_posted)
`uvm_analysis_imp_decl(_cqe)
`uvm_analysis_imp_decl(_aeq)
`uvm_analysis_imp_decl(_res)

class rdma_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rdma_scoreboard)

  localparam int unsigned GRH_BYTES = 40;

  rdma_res_db res;
  rdma_mem_model mem;
  rdma_expect exp;
  uvm_analysis_imp_posted #(rdma_verb_item, rdma_scoreboard) posted_export;
  uvm_analysis_imp_cqe #(rdma_verb_completion, rdma_scoreboard) cqe_export;
  uvm_analysis_imp_aeq #(rdma_aeq_event, rdma_scoreboard) aeq_export;
  uvm_analysis_imp_res #(rdma_res_event, rdma_scoreboard) res_export;
  // 投递的 verb 填好预测状态后转发（覆盖率订阅）。
  uvm_analysis_port #(rdma_verb_item) predicted_ap;
  int unsigned checked;
  int unsigned errors;
  int unsigned aeq_events;

  // 功能：构造 scoreboard、四个输入 export、预测输出端口，以及独占的期望内存和完成队列模型。
  // 输入/输出及副作用：name/parent 建立 UVM 层级；本组件拥有端口、mem 与 exp，res 保持待绑定的
  //   非拥有空引用，checked/errors/aeq_events 从零开始。
  // 失败/边界：接收完成或资源事件前必须由 env 绑定 res 并连接各端口；factory 必须返回非空模型对象。
  function new(string name = "rdma_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    posted_export = new("posted_export", this);
    cqe_export = new("cqe_export", this);
    aeq_export = new("aeq_export", this);
    res_export = new("res_export", this);
    predicted_ap = new("predicted_ap", this);
    mem = rdma_mem_model::type_id::create("mem");
    exp = rdma_expect::type_id::create("exp");
  endfunction

  // 功能：处理已成功投递的 verb：跟踪本地/可选远端 buffer，把 driver 生成的源数据写入镜像，登记
  //   完成与入站预测，再将带预测字段的 item 转发给 coverage。
  // 输入/输出及副作用：修改 mem/exp，predicted_ap 发布同一非拥有 item 引用；不修改真实设备内存。
  // 失败/边界：要求 item、lmr 及其 buffer 有效且偏移已由 driver 门禁；rmr 为空时跳过远端跟踪，
  //   空 data 不覆盖本地镜像。
  function void write_posted(rdma_verb_item item);
    mem.track(item.lmr.mem);
    if (item.rmr != null)
      mem.track(item.rmr.mem);
    if (item.data.size() != 0)
      mem.write(item.lmr.mem, loff(item), item.data);
    exp.post(item);
    predicted_ap.write(item);
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

  // 功能：消费 QP 资源事件：进入 ERROR 时把在途项标为可 flush；移除时撤销其期望，并以实际内容接受
  //   已撤销 WR 可能触及的目的区域。
  // 输入/输出及副作用：更新 exp 和 mem；非 QP 事件、非 ERROR 的 CHANGED 以及非 REMOVED 均不处理。
  // 失败/边界：dest 不存在的撤销项无区域可接受；要求 e/e.res 有效，mem.accept 读取失败会自行报错。
  function void write_res(rdma_res_event e);
    rdma_res_qp qp;
    rdma_verb_item dropped[$];
    rdma_res_buf b;
    int unsigned off;
    int unsigned len;

    if (!$cast(qp, e.res))
      return;
    if (e.what == RDMA_RES_CHANGED && qp.state == RDMA_RES_ERROR)
      exp.qp_error(qp);
    if (e.what != RDMA_RES_REMOVED)
      return;
    exp.forget(qp, dropped);
    foreach (dropped[i])
      if (dest(dropped[i], b, off, len))
        mem.accept(b, off, len);
  endfunction

  // 功能：记录 monitor 发布的 AEQ 事件总数，供结束摘要确认异步路径被观测。
  // 输入/输出及副作用：每次调用仅将 aeq_events 加一；e 的内容由场景断言消费，本 scoreboard 不保留引用。
  // 失败/边界：所有 ecode 均计数且不去重；调用者应传非空事件，但本函数有意不解引用其字段。
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

  // 功能：查询 SQ/RQ/入站完成模型中是否已没有待结算期望。
  // 输入/输出及副作用：直接返回 exp.idle，不修改队列、内存模型或统计计数。
  // 失败/边界：只代表 scoreboard 期望为空，不证明链路/设备 mailbox 已空，也不执行最终整块内存比对。
  function bit idle();
    return exp.idle();
  endfunction

  // 功能：把一条 scoreboard 契约违例同时计入本地 errors 并发布为 UVM_ERROR。
  // 输入/输出及副作用：errors 无条件加一，message 原样进入 RDMA_SB 报告；不停止后续结算。
  // 失败/边界：空 message 仍形成有效错误；函数不去重，同一根因的独立检查可能分别计数。
  protected function void fail(string message);
    errors++;
    `uvm_error("RDMA_SB", message)
  endfunction

  // 功能：把 verb 的 local_offset 从 MR 相对坐标换算成其 backing buffer 相对坐标。
  // 输入/输出及副作用：读取 it.lmr 的 VA、buffer IOVA 与 item 偏移并返回差值，不修改资源。
  // 失败/边界：要求 it/lmr/mem 非空且 MR VA 不低于 buffer IOVA；范围合法性由投递门禁保证。
  protected function int unsigned loff(rdma_verb_item it);
    return rdma_verb_driver::buf_offset(it.lmr, it.local_offset);
  endfunction

  // 功能：把 verb 的 remote_offset 从远端 MR 相对坐标换算成其 backing buffer 相对坐标。
  // 输入/输出及副作用：读取 it.rmr 的 VA、buffer IOVA 与 item 偏移并返回差值，不修改资源。
  // 失败/边界：仅适用于需要 rmr 的 WRITE/READ/ATOMIC，要求 it/rmr/mem 非空且范围已通过门禁。
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

  // 功能：SQ 完成：按序结算到该 wr_id。最后一个比对状态（预测值，或 QP 转 ERR 时在途的 FLUSH）；
  //   成功的应用内存效果并立即比对；被 flush 的不再到达对端；致命错误使 QP 进入错误态（预测）。
  // 输入/输出及副作用：修改期望内存与期望。
  // 失败/边界：找不到请求或状态不符时报错。
  protected function void settle_send(rdma_res_qp qp, rdma_verb_completion c);
    rdma_verb_item done[$];
    rdma_verb_item it;
    bit ok;

    if (!exp.settle_send(qp, c.wr_id, done)) begin
      fail({"SQ completion matches no request: ", c.convert2string()});
      return;
    end
    it = done[done.size() - 1];
    checked++;
    if (c.status != it.expect_status && !(it.may_flush && c.status == RDMA_DRV_WC_FLUSH_ERR))
      fail($sformatf("status %s != expected %s for %s", c.status.name(), it.expect_status.name(),
                     it.convert2string()));
    foreach (done[i]) begin
      ok = i < done.size() - 1 ? done[i].expect_status == RDMA_DRV_WC_SUCCESS || done[i].may_flush :
           c.status == RDMA_DRV_WC_SUCCESS;
      if (!ok) begin
        if (!done[i].overflow)
          exp.drop_inbound(done[i]);
        continue;
      end
      apply_send(done[i]);
      if (!(qp.urc && done[i].op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM}))
        check_region(done[i]);
    end
    if (!(c.status inside {RDMA_DRV_WC_SUCCESS, RDMA_DRV_WC_FLUSH_ERR}))
      exp.requester_error(qp);
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

  // 功能：把 64 位原子值按最低有效字节优先转换成恰好 8 项的字节队列。
  // 输入/输出及副作用：读取 v，返回新队列 q，不修改调用者数据或内存模型。
  // 失败/边界：输入宽度固定为 64 位，零值仍返回八个零字节，不执行地址对齐或权限判断。
  protected function rdma_byte_q le8(bit [63:0] v);
    rdma_byte_q q;

    for (int k = 0; k < 8; k++)
      q.push_back(v[8 * k +: 8]);
    return q;
  endfunction

  // 功能：RQ 完成：FLUSH 完成须是期望 flush 的 RECV；其余与入站请求配对，比对状态（容量不足为错误）、
  //   长度（UD 含 40B GRH）、立即数、UD 源 QP；SEND 数据写入 RECV buffer（UD 先放 GRH），WRITE_IMM 的
  //   数据写入其远端区域；随后立即比对。
  // 输入/输出及副作用：修改期望内存。
  // 失败/边界：不匹配报错。
  protected function void settle_recv(rdma_res_qp qp, rdma_verb_completion c);
    rdma_verb_item recv;
    rdma_verb_item src;
    int unsigned grh;
    bit flushed;

    flushed = c.status == RDMA_DRV_WC_FLUSH_ERR;
    if (!exp.settle_recv(qp, c.wr_id, flushed, recv, src)) begin
      fail({"RQ completion matches no RECV/inbound request: ", c.convert2string()});
      return;
    end
    checked++;
    if (flushed) begin
      if (recv.expect_status != RDMA_DRV_WC_FLUSH_ERR && !recv.may_flush)
        fail({"unexpected RQ flush: ", recv.convert2string()});
      return;
    end
    grh = qp.ud() ? GRH_BYTES : 0;
    if (src.overflow) begin
      if (c.status == RDMA_DRV_WC_SUCCESS)
        fail({"RQ completion succeeded although the RECV is too small: ", src.convert2string()});
      mem.accept(recv.lmr.mem, loff(recv), recv.length);
      return;
    end
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
    if (grh != 0 && qp.owner.remote)
      mem.accept(recv.lmr.mem, loff(recv), grh);
    else if (grh != 0)
      mem.write(recv.lmr.mem, loff(recv), grh_bytes(src.length));
    mem.write(recv.lmr.mem, loff(recv) + grh, src.data);
    check_region(recv);
  endfunction

  // 功能：UD 接收缓冲开头 40B GRH（RoCEv2 IPv4：前 20B 为 0，IPv4 头 0x45、总长 = IP+UDP+BTH+DETH+
  //   载荷+ICRC、TTL 64、协议 UDP，其余为 0）。
  // 输入/输出及副作用：len 为 RDMA payload 字节数；返回固定 40B 的新队列，仅填 IPv4 版本、总长、
  //   TTL 与 UDP 协议字段，不修改模型状态。
  // 失败/边界：调用者必须保证计算后的 IPv4 total 可由 16 位字段表示；校验和与地址保持零，真实远端
  //   GRH 由 mem.accept 路径处理而不使用此模板。
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
