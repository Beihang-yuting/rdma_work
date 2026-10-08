// 目录：验证组件层 tb/rdma_expect.sv。
// 层：验证组件。
// 职责：期望完成：按 QP（资源 uid）维护在途 SQ 请求、已投递的 RECV（SRQ 上的按 SRQ）与发往该 QP、
//   会消耗 RQE 的入站请求；投递时依据资源库预测完成状态，完成时依序结算（SQ 含 unsignaled，RQ 按入站
//   顺序配对，SRQ 按 wr_id）。
//   预测：本地访问（本地 MR 属于本端 QP 的 PD 且覆盖本地区域，否则 GENERAL_ERR）；远端访问（MR 属于
//   对端 Function 与对端 QP 的 PD、范围内、权限齐全，否则 REM_ACCESS_ERR）；
//   接收容量不足（请求方 REM_INV_REQ_ERR，远端响应方为 REM_OP_ERR；接收端错误完成；UD 请求方成功）；
//   UD Q_Key 不符（接收端丢弃）；QP 进入 ERR（在途可 FLUSH，之后投递的全部 FLUSH）；请求方致命错误后
//   QP 进入错误态、剩余 SQ/RQ 全部 FLUSH，回致命 NAK 的 RC 响应方 QP 同样进入错误态（IBTA）；
//   QP 销毁/FLR 撤销其期望。
// 依赖：rdma_verb_item、rdma_res_qp/mr。
// 所有权：不拥有 item、QP 或 MR；队列只保存由 sequencer/资源库管理的非拥有句柄。
// 生命周期：scoreboard 创建后在仿真期间常驻；资源移除事件通过 forget 清除可能失效的句柄。

class rdma_expect extends uvm_object;
  `uvm_object_utils(rdma_expect)

  protected rdma_verb_item sq[longint unsigned][$];
  protected rdma_verb_item rq[longint unsigned][$];
  protected rdma_verb_item inbound[longint unsigned][$];
  protected bit errored[longint unsigned];

  // 功能：创建一个尚未登记投递、也未记录错误 QP 的完成期望跟踪器。
  // 输入/输出及副作用：name 传给 uvm_object 作为实例名；关联队列和 errored 映射保持为空。
  // 失败/边界：构造过程不接管 item 或资源所有权，必须由后续 post/资源事件逐步建立预测状态。
  function new(string name = "rdma_expect");
    super.new(name);
  endfunction

  // 功能：计算 qp 的接收队列索引；使用 SRQ 时共享 srq.uid，否则使用 qp.uid。
  // 输入/输出及副作用：输入 qp，返回对应资源 uid，不修改 QP、SRQ 或期望队列。
  // 失败/边界：qp 必须非空；qp.srq 为空是受支持的普通边界，此时退回 QP 自身 uid。
  static function longint unsigned rq_key(rdma_res_qp qp);
    return qp.srq != null ? qp.srq.uid : qp.uid;
  endfunction

  // 功能：登记投递并预测状态。RECV 进接收队列（所属 QP 已出错则 FLUSH）；SQ 请求进发送队列，期望到达
  //   对端且消耗 RQE 的同时进对端入站队列。
  // 输入/输出及副作用：输入 it；更新 expect_status/overflow，并把句柄加入 rq、sq 或 inbound，
  //   致命远端结果还可能经 responder_error 更新对端预测状态。
  // 失败/边界：it 与 it.qp 必须非空，需到达对端的请求还要求 qp.peer 完整；不检查重复投递，
  //   同一 item 重复调用会形成多个队列记录。
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
    if (it.expect_status inside {RDMA_DRV_WC_REM_ACCESS_ERR, RDMA_DRV_WC_REM_INV_REQ_ERR,
                                 RDMA_DRV_WC_REM_OP_ERR})
      responder_error(it.qp.peer);
  endfunction

  // 功能：判断 qp 是否已由资源状态或本跟踪器预测为错误态。
  // 输入/输出及副作用：输入 qp；当 qp.state 为 RDMA_RES_ERROR 或 errored 中存在 qp.uid 时返回 1，
  //   不修改任何预测状态。
  // 失败/边界：qp 必须非空；除资源 ERROR 和 errored 记录外的状态不会被推断为失败。
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
    if (!local_ok(it))
      return RDMA_DRV_WC_GENERAL_ERR;
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

  // 功能：检查本地 MR 是否与 QP 同 PD、覆盖请求区域，并在 READ/ATOMIC 时具备本地写权限。
  // 输入/输出及副作用：输入 it，依据 it.lmr、local_offset、length 和操作类型返回合法性，不修改资源。
  // 失败/边界：it 与 it.qp 必须非空；lmr 为空、PD 不匹配、越界或缺少所需权限均返回 0。
  protected function bit local_ok(rdma_verb_item it);
    rdma_res_mr m;

    m = it.lmr;
    return m != null && m.deps[0] == it.qp.deps[0] &&
           m.covers(m.va + it.local_offset, it.length,
                    it.op == RDMA_VERB_READ || it.atomic() ? RDMA_RIGHT_LOCAL_WRITE : 5'h0);
  endfunction

  // 功能：检查远端 MR 是否属于 peer Function/PD，并按 READ、ATOMIC 或 WRITE 验证范围与权限。
  // 输入/输出及副作用：输入 it，依据 rmr、remote_offset 和操作类型返回合法性，不修改资源或请求。
  // 失败/边界：it、it.qp 与 qp.peer 必须非空；rmr 为空、归属不符、越界或权限不足均返回 0；
  //   ATOMIC 固定检查 8 字节，其余操作检查 it.length。
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

  // 功能：判断一个会消耗 RQE 的请求是否应进入对端 inbound 队列。
  // 输入/输出及副作用：输入 it；UD Q_Key 匹配且预测成功或已标记 overflow 时返回 1，不修改 it。
  // 失败/边界：it、it.qp 与 qp.peer 必须完整；非零 UD Q_Key 不匹配时返回 0，其他失败状态且未
  //   overflow 时也返回 0。
  protected function bit arrives(rdma_verb_item it);
    if (it.qp.ud() && it.ud_qkey != 0 && it.ud_qkey != it.qp.peer.qkey)
      return 1'b0;
    return it.expect_status == RDMA_DRV_WC_SUCCESS || it.overflow;
  endfunction

  // 功能：响应 QP 进入 ERR 的资源事件，把其现有 SQ 与私有 RQ 项标为允许 FLUSH 完成。
  // 输入/输出及副作用：输入 qp；就地设置匹配 item 的 may_flush，不改变 qp.state 或 errored 映射。
  // 失败/边界：qp 必须非空；队列不存在时幂等无动作，SRQ 为共享资源，其 RECV 不在此处标记。
  function void qp_error(rdma_res_qp qp);
    if (sq.exists(qp.uid))
      foreach (sq[qp.uid][i])
        sq[qp.uid][i].may_flush = 1'b1;
    if (qp.srq == null && rq.exists(qp.uid))
      foreach (rq[qp.uid][i])
        rq[qp.uid][i].may_flush = 1'b1;
  endfunction

  // 功能：请求方致命错误（非 FLUSH 的错误完成）：QP 进入错误态，剩余 SQ 与 RQ 项期望 FLUSH。
  // 输入/输出及副作用：输入 qp；记录 errored，将剩余 SQ/私有 RQ 改为 FLUSH，并从对端 inbound
  //   删除不再到达的请求。
  // 失败/边界：qp 必须非空；UD 错误不触发连接态迁移而直接返回；空队列和重复通知均幂等，SRQ
  //   上的共享 RECV 不随单个 QP 刷新。
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

  // 功能：响应方回致命 NAK（远端访问错、接收容量不足）：RC QP 进入错误态，此后投递的期望 FLUSH，
  //   在途项可 FLUSH（错误到达前可能已完成）。URC/UD 不转 ERR。
  // 输入/输出及副作用：输入 qp；对 RC 记录 errored，并经 qp_error 设置现有 SQ/私有 RQ 的
  //   may_flush，资源对象的 qp.state 仍由外部事件维护。
  // 失败/边界：qp 必须非空；UD 与 URC 不因该响应转 ERR，直接返回；重复 RC 通知幂等。
  function void responder_error(rdma_res_qp qp);
    if (qp.ud() || qp.urc)
      return;
    errored[qp.uid] = 1'b1;
    qp_error(qp);
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

  // 功能：在 QP 销毁或 FLR 时清除其 SQ、入站索引、私有 RQ 和预测错误记录。
  // 输入/输出及副作用：输入 qp；先清空 dropped，再返回从该 QP 的 SQ 与非 SRQ RQ 撤销的 item；
  //   发往该 QP 的 inbound 索引直接删除，不加入 dropped。
  // 失败/边界：qp 必须非空；不存在的 uid 幂等返回空队列；SRQ 接收队列由共享资源继续保留。
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

  // 功能：汇总当前 SQ 与 RQ 中登记的 item，供目的区域重叠检查使用。
  // 输入/输出及副作用：先清空 out，再按关联数组遍历顺序追加非拥有 item 句柄；内部队列不变。
  // 失败/边界：没有登记项时返回空队列；inbound 是 SQ 请求的对端视图，不会再次加入结果。
  function void pending(ref rdma_verb_item out[$]);
    out = {};
    foreach (sq[k]) out = {out, sq[k]};
    foreach (rq[k]) out = {out, rq[k]};
  endfunction

  // 功能：判断 SQ 请求、入站 RQE 消耗及必须 FLUSH 的 RECV 是否已经全部结算。
  // 输入/输出及副作用：无输入；只读 sq、inbound 和 rq，满足结算条件时返回 1。
  // 失败/边界：普通未消耗且期望 SUCCESS 的 RECV 不算在途；任一非空 SQ/inbound 或 FLUSH RECV
  //   都使结果为 0。
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

  // 功能：生成结束检查所需的未完成 SQ、未接收 inbound 和未 FLUSH RQ 描述。
  // 输入/输出及副作用：先清空 out，再追加包含 item.convert2string() 的诊断字符串，不修改队列。
  // 失败/边界：不存在未结算项时返回空队列；普通未被消耗的 SUCCESS RECV 按 idle 语义不报告。
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
