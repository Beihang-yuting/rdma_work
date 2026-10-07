// 目录：验证组件层 tb/rdma_expect.sv。
// 层：验证组件。
// 职责：期望完成：按 QP（资源 uid）维护在途 SQ 请求、已投递的 RECV（SRQ 上的按 SRQ）与发往该 QP、
//   会消耗 RQE 的入站请求；按完成依序结算（SQ 含 unsignaled，RQ 按入站顺序配对）。
// 依赖：rdma_verb_item、rdma_res_qp。
// 所有权：只引用 item。
// 生命周期：scoreboard 创建，仿真期间常驻。

class rdma_expect extends uvm_object;
  `uvm_object_utils(rdma_expect)

  protected rdma_verb_item sq[longint unsigned][$];
  protected rdma_verb_item rq[longint unsigned][$];
  protected rdma_verb_item inbound[longint unsigned][$];

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

  // 功能：登记投递：RECV 进接收队列；SQ 请求进发送队列，期望成功且消耗 RQE 的同时进对端入站队列。
  // 输入/输出及副作用：修改队列。
  // 失败/边界：无。
  function void post(rdma_verb_item item);
    if (item.op == RDMA_VERB_RECV) begin
      rq[item.srq != null ? item.srq.uid : item.qp.uid].push_back(item);
      return;
    end
    sq[item.qp.uid].push_back(item);
    if (item.consumes_rqe() && item.expect_status == RDMA_DRV_WC_SUCCESS)
      inbound[item.qp.peer.uid].push_back(item);
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

  // 功能：RQ 完成：接收队列队首须为 wr_id 的 RECV，与 qp 最早的入站请求配对。
  // 输入/输出及副作用：recv/src 输出并出队。
  // 失败/边界：不匹配返回 0，队列不变。
  function bit settle_recv(rdma_res_qp qp, longint unsigned wr_id, output rdma_verb_item recv,
                           output rdma_verb_item src);
    longint unsigned k;

    k = rq_key(qp);
    if (!rq.exists(k) || rq[k].size() == 0 || rq[k][0].wr_id != wr_id ||
        !inbound.exists(qp.uid) || inbound[qp.uid].size() == 0)
      return 1'b0;
    recv = rq[k].pop_front();
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

  // 功能：SQ 请求与入站 RQE 消耗是否全部结算（未被消耗的 RECV 不算在途）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit idle();
    foreach (sq[k])
      if (sq[k].size() != 0)
        return 1'b0;
    foreach (inbound[k])
      if (inbound[k].size() != 0)
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
  endfunction
endclass
