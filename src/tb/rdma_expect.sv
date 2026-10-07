// 目录：验证组件层 tb/rdma_expect.sv。
// 层：验证组件。
// 职责：期望完成：按 QP（资源 uid）维护在途 SQ 请求、已投递的 RECV（SRQ 上的按 SRQ）与发往该 QP、
//   会消耗 RQE 的入站请求；投递时依据资源库预测完成状态，完成时依序结算（SQ 含 unsignaled，RQ 按入站
//   顺序配对，SRQ 按 wr_id）。
//   预测：远端访问（MR 属于对端 Function 与对端 QP 的 PD、范围内、权限齐全，否则 REM_ACCESS_ERR）；
//   接收容量不足（请求方 REM_INV_REQ_ERR，远端响应方为 REM_OP_ERR；接收端错误完成；UD 请求方成功）；
//   UD Q_Key 不符（接收端丢弃）；QP 进入 ERR（在途可 FLUSH，之后投递的全部 FLUSH）；请求方致命错误后
//   QP 进入错误态、剩余 SQ/RQ 全部 FLUSH（IBTA）；
//   QP 销毁/FLR 撤销其期望。
// 依赖：rdma_verb_item、rdma_res_qp/mr。
// 所有权：只引用 item。
// 生命周期：scoreboard 创建，仿真期间常驻。

class rdma_expect extends uvm_object;
  `uvm_object_utils(rdma_expect)

  protected rdma_verb_item sq[longint unsigned][$];
  protected rdma_verb_item rq[longint unsigned][$];
  protected rdma_verb_item inbound[longint unsigned][$];
  protected bit errored[longint unsigned];

  // 功能：构造。
  // 输入/输出及副作用：name 为 UVM 名。
  // 失败/边界：无。
  function new(string name = "rdma_expect");
    super.new(name);
  endfunction

  // 功能：RECV 所在队列的键（SRQ 上为 SRQ uid）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function longint unsigned rq_key(rdma_res_qp qp);
    return qp.srq != null ? qp.srq.uid : qp.uid;
  endfunction

  // 功能：登记投递并预测状态。RECV 进接收队列（所属 QP 已出错则 FLUSH）；SQ 请求进发送队列，期望到达
  //   对端且消耗 RQE 的同时进对端入站队列。
  // 输入/输出及副作用：修改队列与 item 的预测字段。
  // 失败/边界：无。
  function void post(rdma_verb_item it);
    if (it.op == RDMA_VERB_RECV) begin
      it.expect_status = it.srq == null && failed(it.qp) ? RDMA_DRV_WC_FLUSH_ERR :
                         RDMA_DRV_WC_SUCCESS;
      rq[it.srq != null ? it.srq.uid : it.qp.uid].push_back(it);
      return;
    end
    it.expect_status = failed(it.qp) ? RDMA_DRV_WC_FLUSH_ERR : predict(it);
    sq[it.qp.uid].push_back(it);
    if (it.consumes_rqe() && arrives(it))
      inbound[it.qp.peer.uid].push_back(it);
  endfunction

  // 功能：QP 是否已出错（资源状态 ERROR 或预测的致命错误）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit failed(rdma_res_qp qp);
    return qp.state == RDMA_RES_ERROR || errored.exists(qp.uid);
  endfunction

  // 功能：SQ 请求的完成状态预测（见文件头）；置 overflow。
  // 输入/输出及副作用：修改 it.overflow。
  // 失败/边界：消耗的 RECV 尚未投递时不预测容量错误。
  protected function rdma_drv_wc_status_e predict(rdma_verb_item it);
    rdma_res_qp peer;
    rdma_verb_item recv;

    peer = it.qp.peer;
    if (!(it.op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM}) && !access_ok(it))
      return RDMA_DRV_WC_REM_ACCESS_ERR;
    if (!(it.op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM}))
      return RDMA_DRV_WC_SUCCESS;
    recv = upcoming_recv(peer);
    it.overflow = recv != null && it.length + (peer.ud() ? 40 : 0) > recv.length;
    if (!it.overflow || it.qp.ud())
      return RDMA_DRV_WC_SUCCESS;
    return peer.owner.remote ? RDMA_DRV_WC_REM_OP_ERR : RDMA_DRV_WC_REM_INV_REQ_ERR;
  endfunction

  // 功能：远端访问是否合法：MR 存活、属于对端 Function 且与对端 QP 同 PD、范围内、权限齐全。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function bit access_ok(rdma_verb_item it);
    rdma_res_mr m;
    rdma_res_qp peer;
    bit [4:0] right;

    m = it.rmr;
    peer = it.qp.peer;
    right = it.op == RDMA_VERB_READ ? RDMA_RIGHT_REMOTE_READ :
            it.atomic() ? RDMA_RIGHT_REMOTE_ATOMIC : RDMA_RIGHT_REMOTE_WRITE;
    return m != null && m.owner == peer.owner && m.deps[0] == peer.deps[0] &&
           m.covers(m.va + it.remote_offset, it.atomic() ? 8 : it.length, right);
  endfunction

  // 功能：对端下一个将被消耗的 RECV（排在已入站请求之后）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：尚未投递返回 null。
  protected function rdma_verb_item upcoming_recv(rdma_res_qp peer);
    longint unsigned k;
    int unsigned n;

    k = rq_key(peer);
    n = inbound.exists(peer.uid) ? inbound[peer.uid].size() : 0;
    if (!rq.exists(k) || rq[k].size() <= n)
      return null;
    return rq[k][n];
  endfunction

  // 功能：请求是否到达对端并消耗 RQE（成功或容量错误；UD Q_Key 不符被丢弃）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  protected function bit arrives(rdma_verb_item it);
    if (it.qp.ud() && it.ud_qkey != 0 && it.ud_qkey != it.qp.peer.qkey)
      return 1'b0;
    return it.expect_status == RDMA_DRV_WC_SUCCESS || it.overflow;
  endfunction

  // 功能：QP 进入 ERR（资源事件）：其在途 SQ 与 RQ 项都可能以 FLUSH 完成。
  // 输入/输出及副作用：置 may_flush。
  // 失败/边界：无。
  function void qp_error(rdma_res_qp qp);
    if (sq.exists(qp.uid))
      foreach (sq[qp.uid][i])
        sq[qp.uid][i].may_flush = 1'b1;
    if (qp.srq == null && rq.exists(qp.uid))
      foreach (rq[qp.uid][i])
        rq[qp.uid][i].may_flush = 1'b1;
  endfunction

  // 功能：请求方致命错误（非 FLUSH 的错误完成）：QP 进入错误态，剩余 SQ 与 RQ 项期望 FLUSH。
  // 输入/输出及副作用：修改 errored 与剩余项的预测；被 flush 的 SEND 不再到达对端。
  // 失败/边界：无。
  function void requester_error(rdma_res_qp qp);
    if (qp.ud())
      return;
    errored[qp.uid] = 1'b1;
    if (sq.exists(qp.uid))
      foreach (sq[qp.uid][i]) begin
        sq[qp.uid][i].expect_status = RDMA_DRV_WC_FLUSH_ERR;
        drop_inbound(sq[qp.uid][i]);
      end
    if (qp.srq == null && rq.exists(qp.uid))
      foreach (rq[qp.uid][i])
        rq[qp.uid][i].expect_status = RDMA_DRV_WC_FLUSH_ERR;
  endfunction

  // 功能：从对端入站队列移除 it（被 flush、不会到达）。
  // 输入/输出及副作用：修改 inbound。
  // 失败/边界：不在队列中则无动作。
  function void drop_inbound(rdma_verb_item it);
    if (!it.consumes_rqe() || !inbound.exists(it.qp.peer.uid))
      return;
    foreach (inbound[it.qp.peer.uid][i])
      if (inbound[it.qp.peer.uid][i] == it) begin
        inbound[it.qp.peer.uid].delete(i);
        return;
      end
  endfunction

  // 功能：QP 销毁/FLR：撤销其全部期望（含发往它的入站请求与其非 SRQ 的 RECV）。
  // 输入/输出及副作用：dropped 输出被撤销的项。
  // 失败/边界：无。
  function void forget(rdma_res_qp qp, ref rdma_verb_item dropped[$]);
    dropped = {};
    if (sq.exists(qp.uid))
      dropped = {dropped, sq[qp.uid]};
    if (qp.srq == null && rq.exists(qp.uid))
      dropped = {dropped, rq[qp.uid]};
    sq.delete(qp.uid);
    inbound.delete(qp.uid);
    if (qp.srq == null)
      rq.delete(qp.uid);
    errored.delete(qp.uid);
  endfunction

  // 功能：SQ 完成：弹出 qp 发送队列中直到 wr_id 的全部请求（前面的是 unsignaled 且已隐式完成）。
  // 输入/输出及副作用：done 输出按序弹出的请求，最后一个即该完成对应的请求。
  // 失败/边界：wr_id 不在队列中返回 0，队列不变。
  function bit settle_send(rdma_res_qp qp, longint unsigned wr_id, output rdma_verb_item done[$]);
    done = {};
    if (!sq.exists(qp.uid))
      return 1'b0;
    foreach (sq[qp.uid][j])
      if (sq[qp.uid][j].wr_id == wr_id) begin
        repeat (j + 1)
          done.push_back(sq[qp.uid].pop_front());
        return 1'b1;
      end
    return 1'b0;
  endfunction

  // 功能：RQ 完成：flush 完成按 wr_id 取出 RECV（不配对）；其余与 qp 最早的入站请求配对，RECV 为
  //   接收队列队首（SRQ 按 wr_id，多个 QP 的完成可能交错）。
  // 输入/输出及副作用：recv/src 输出并出队（flush 时 src 为 null）。
  // 失败/边界：不匹配返回 0，队列不变。
  function bit settle_recv(rdma_res_qp qp, longint unsigned wr_id, bit flushed,
                           output rdma_verb_item recv, output rdma_verb_item src);
    longint unsigned k;
    int idx;

    k = rq_key(qp);
    src = null;
    idx = -1;
    if (rq.exists(k))
      foreach (rq[k][i])
        if (idx < 0 && rq[k][i].wr_id == wr_id)
          idx = i;
    if (idx < 0 || (idx != 0 && qp.srq == null && !flushed))
      return 1'b0;
    if (!flushed && (!inbound.exists(qp.uid) || inbound[qp.uid].size() == 0))
      return 1'b0;
    recv = rq[k][idx];
    rq[k].delete(idx);
    if (!flushed)
      src = inbound[qp.uid].pop_front();
    return 1'b1;
  endfunction

  // 功能：全部在途项（用于目的区域重叠判断）。
  // 输入/输出及副作用：out 输出。
  // 失败/边界：无。
  function void pending(ref rdma_verb_item out[$]);
    out = {};
    foreach (sq[k]) out = {out, sq[k]};
    foreach (rq[k]) out = {out, rq[k]};
  endfunction

  // 功能：SQ 请求、入站 RQE 消耗与期望 FLUSH 的 RECV 是否全部结算（其余未被消耗的 RECV 不算在途）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit idle();
    foreach (sq[k])
      if (sq[k].size() != 0)
        return 1'b0;
    foreach (inbound[k])
      if (inbound[k].size() != 0)
        return 1'b0;
    foreach (rq[k])
      foreach (rq[k][i])
        if (rq[k][i].expect_status == RDMA_DRV_WC_FLUSH_ERR)
          return 1'b0;
    return 1'b1;
  endfunction

  // 功能：未结算项描述（结束检查用）。
  // 输入/输出及副作用：out 输出。
  // 失败/边界：无。
  function void leftovers(ref string out[$]);
    out = {};
    foreach (sq[k])
      foreach (sq[k][i])
        out.push_back({"never completed: ", sq[k][i].convert2string()});
    foreach (inbound[k])
      foreach (inbound[k][i])
        out.push_back({"never received: ", inbound[k][i].convert2string()});
    foreach (rq[k])
      foreach (rq[k][i])
        if (rq[k][i].expect_status == RDMA_DRV_WC_FLUSH_ERR)
          out.push_back({"never flushed: ", rq[k][i].convert2string()});
  endfunction
endclass
