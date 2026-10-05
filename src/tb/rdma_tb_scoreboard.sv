// 目录：验证组件层 tb/rdma_tb_scoreboard.sv。
// 职责：端到端记分板：用每节点数据 MR 的影子内存预测 SEND/RECV、WRITE(+IMM)、READ、ATOMIC 的效果，
//   比对每个完成（wr_id、状态、RQ 长度/立即数），结束时逐字节比对影子与真实 host 内存。
// 依赖：rdma_tb_node_cfg、verb driver 的 posted 事件、verb monitor 的完成事件。
// 所有权与生命周期：只读节点配置；影子内存在首个投递事件时从真实内存整体载入。
// 约定：READ/ATOMIC 的预测读取影子当前值，依赖它们的序列须等前序完成后再投递。

`uvm_analysis_imp_decl(_posted)
`uvm_analysis_imp_decl(_cqe)

class rdma_tb_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(rdma_tb_scoreboard)

  rdma_tb_node_cfg nodes[int unsigned];
  uvm_analysis_imp_posted #(rdma_verb_item, rdma_tb_scoreboard) posted_export;
  uvm_analysis_imp_cqe #(rdma_verb_completion, rdma_tb_scoreboard) cqe_export;
  int unsigned checked;
  int unsigned errors;

  // 影子内存：node → 数据 MR 内偏移处的字节。
  protected byte unsigned shadow[int unsigned][$];
  protected bit loaded;
  // 按投递顺序排队的 SQ 请求与 RECV：键为 node*65536+qp_index。
  protected rdma_verb_item sq_pending[int unsigned][$];
  protected rdma_verb_item rq_posted[int unsigned][$];
  // 发往某 (node,qp) 且会消耗 RQE 的入站请求（SEND/SEND_IMM/WRITE_IMM），按顺序配对。
  protected rdma_verb_item inbound[int unsigned][$];

  // 功能：构造记分板与 analysis export。
  // 输入/输出及副作用：name/parent 为 UVM 层级。
  // 失败/边界：无。
  function new(string name = "rdma_tb_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    posted_export = new("posted_export", this);
    cqe_export = new("cqe_export", this);
    checked = 0;
    errors = 0;
    loaded = 1'b0;
  endfunction

  // 功能：投递事件：首次时载入影子；记录源数据写入，把请求排入对应队列。
  // 输入/输出及副作用：更新影子与待完成队列。
  // 失败/边界：无。
  function void write_posted(rdma_verb_item item);
    rdma_tb_qp_link link;

    if (!loaded)
      load_shadow();
    foreach (item.data[k])
      shadow[item.node_id][item.local_offset + k] = item.data[k];
    if (item.op == RDMA_VERB_RECV) begin
      rq_posted[key(item.node_id, item.qp_index)].push_back(item);
      return;
    end
    sq_pending[key(item.node_id, item.qp_index)].push_back(item);
    link = nodes[item.node_id].qps[item.qp_index];
    if (item.op inside {RDMA_VERB_SEND, RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM} &&
        !item.expect_error)
      inbound[key(link.peer_node, link.peer_qp_index)].push_back(item);
  endfunction

  // 功能：完成事件：SQ 完成按 wr_id 依序结算该 QP 之前的全部请求（含 unsignaled），
  //   RQ 完成与入站请求配对并预测接收 buffer 内容。
  // 输入/输出及副作用：更新影子、计数；不匹配时报 UVM_ERROR。
  // 失败/边界：找不到对应请求时报错。
  function void write_cqe(rdma_verb_completion done);
    if (done.rq)
      settle_recv(done);
    else
      settle_send(done);
  endfunction

  // 功能：结束检查：待完成队列应为空，影子与真实内存逐字节一致。
  // 输入/输出及副作用：读 host 内存；报告统计。
  // 失败/边界：不一致报 UVM_ERROR（每节点最多报前 8 个差异）。
  function void check_phase(uvm_phase phase);
    foreach (sq_pending[k])
      if (sq_pending[k].size() != 0)
        fail($sformatf("%0d SQ requests never completed, first: %s",
                       sq_pending[k].size(), sq_pending[k][0].convert2string()));
    foreach (inbound[k])
      if (inbound[k].size() != 0)
        fail($sformatf("queue %0h has %0d unmatched inbound requests", k, inbound[k].size()));
    if (loaded)
      foreach (nodes[n])
        compare_memory(n);
    `uvm_info("RDMA_SB", $sformatf("checked=%0d errors=%0d", checked, errors), UVM_LOW)
  endfunction

  // 功能：是否所有已投递的 SQ 请求与入站 RQE 消耗都已结算。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit idle();
    foreach (sq_pending[k])
      if (sq_pending[k].size() != 0)
        return 1'b0;
    foreach (inbound[k])
      if (inbound[k].size() != 0)
        return 1'b0;
    return 1'b1;
  endfunction

  // 功能：(node,qp) 队列键。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：qp_index 须小于 65536。
  protected function int unsigned key(int unsigned node, int unsigned qp_index);
    return node * 65536 + qp_index;
  endfunction

  // 功能：记录一个错误。
  // 输入/输出及副作用：errors 加一并报 UVM_ERROR。
  // 失败/边界：无。
  protected function void fail(string message);
    errors++;
    `uvm_error("RDMA_SB", message)
  endfunction

  // 功能：从每个节点的真实内存载入整个数据 MR 作为影子初值。
  // 输入/输出及副作用：读 host 内存。
  // 失败/边界：读取失败报错并留空影子。
  protected function void load_shadow();
    rdma_tb_node_cfg cfg;
    rdma_status status;
    byte raw[];

    loaded = 1'b1;
    foreach (nodes[n]) begin
      cfg = nodes[n];
      status = cfg.engine.host_mem.read(cfg.data_mapping, data_base(cfg),
                                        cfg.data_mr.length, raw);
      if (status == null || !status.ok()) begin
        fail($sformatf("node %0d shadow load failed", n));
        continue;
      end
      shadow[n] = {};
      foreach (raw[k])
        shadow[n].push_back(raw[k]);
    end
  endfunction

  // 功能：数据 MR 起点在 backing mapping 内的偏移。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function longint unsigned data_base(rdma_tb_node_cfg cfg);
    return cfg.data_mr.iova.value - cfg.data_mapping.iova.value;
  endfunction

  // 功能：结算 SQ 完成：弹出该 QP 队列中直到 wr_id 的全部请求并应用预测；只比对最后一个的状态。
  // 输入/输出及副作用：更新影子与计数。
  // 失败/边界：wr_id 不在任何 QP 队列中时报错。
  protected function void settle_send(rdma_verb_completion done);
    rdma_verb_item item;

    foreach (sq_pending[k]) begin
      if (k / 65536 != done.node_id)
        continue;
      foreach (sq_pending[k][j]) begin
        if (sq_pending[k][j].wr_id != done.wr_id)
          continue;
        for (int unsigned m = 0; m <= j; m++) begin
          item = sq_pending[k].pop_front();
          if (m == j)
            check_status(item, done);
          if (!item.expect_error && (m < j || done.ok))
            apply_send(item);
        end
        return;
      end
    end
    fail({"SQ completion matches no request: ", done.convert2string()});
  endfunction

  // 功能：比对完成状态与预期。
  // 输入/输出及副作用：checked 加一。
  // 失败/边界：不一致报错。
  protected function void check_status(rdma_verb_item item, rdma_verb_completion done);
    checked++;
    if (done.ok == item.expect_error)
      fail($sformatf("status mismatch: expect_error=%0b got %s for %s", item.expect_error,
                     done.convert2string(), item.convert2string()));
  endfunction

  // 功能：按请求类型更新影子内存（WRITE 写远端；READ 远端→本地；ATOMIC 读改写远端并回写原值）。
  // 输入/输出及副作用：更新影子。
  // 失败/边界：SEND 类不在此结算（由 RQ 完成负责）。
  protected function void apply_send(rdma_verb_item item);
    rdma_tb_qp_link link;
    int unsigned peer;
    bit [63:0] orig;
    bit [63:0] value;

    link = nodes[item.node_id].qps[item.qp_index];
    peer = link.peer_node;
    if (item.op inside {RDMA_VERB_WRITE, RDMA_VERB_WRITE_IMM}) begin
      foreach (item.data[k])
        shadow[peer][item.remote_offset + k] = item.data[k];
    end
    else if (item.op == RDMA_VERB_READ) begin
      for (int unsigned k = 0; k < item.length; k++)
        shadow[item.node_id][item.local_offset + k] = shadow[peer][item.remote_offset + k];
    end
    else if (rdma_verb_is_atomic(item.op)) begin
      orig = '0;
      for (int k = 7; k >= 0; k--)
        orig = (orig << 8) | {56'b0, shadow[peer][item.remote_offset + k]};
      if (item.op == RDMA_VERB_CMP_SWAP)
        value = (orig == item.compare_value) ? item.swap_add_value : orig;
      else
        value = orig + item.swap_add_value;
      for (int k = 0; k < 8; k++) begin
        shadow[peer][item.remote_offset + k] = value >> (8 * k);
        shadow[item.node_id][item.local_offset + k] = orig >> (8 * k);
      end
    end
  endfunction

  // 功能：结算 RQ 完成：找到对应 RECV，与该队列最早的入站请求配对；SEND 把数据写入 RECV buffer
  //   影子，并比对长度与立即数。
  // 输入/输出及副作用：更新影子与计数。
  // 失败/边界：RECV 或入站请求缺失、长度/立即数不符时报错。
  protected function void settle_recv(rdma_verb_completion done);
    rdma_verb_item recv;
    rdma_verb_item src;
    int unsigned k;
    bit found;

    found = 1'b0;
    foreach (rq_posted[q]) begin
      if (q / 65536 == done.node_id && rq_posted[q].size() != 0 &&
          rq_posted[q][0].wr_id == done.wr_id) begin
        k = q;
        found = 1'b1;
        break;
      end
    end
    if (!found || !inbound.exists(k) || inbound[k].size() == 0) begin
      fail({"RQ completion matches no RECV/inbound request: ", done.convert2string()});
      return;
    end
    recv = rq_posted[k].pop_front();
    src = inbound[k].pop_front();
    checked++;
    if (!done.ok)
      fail({"RQ completion failed: ", done.convert2string()});
    if (done.byte_len != src.length)
      fail($sformatf("RQ byte_len %0d != %0d for %s", done.byte_len, src.length,
                     src.convert2string()));
    if (src.op inside {RDMA_VERB_SEND_IMM, RDMA_VERB_WRITE_IMM} && done.imm != src.imm)
      fail($sformatf("RQ imm %08h != %08h", done.imm, src.imm));
    if (src.op != RDMA_VERB_WRITE_IMM)
      foreach (src.data[b])
        shadow[recv.node_id][recv.local_offset + b] = src.data[b];
  endfunction

  // 功能：比对一个节点的影子与真实数据 MR 内容。
  // 输入/输出及副作用：读 host 内存。
  // 失败/边界：读取失败或不一致时报错，最多列出 8 个差异字节。
  protected function void compare_memory(int unsigned n);
    rdma_tb_node_cfg cfg;
    rdma_status status;
    byte raw[];
    int unsigned diffs;

    cfg = nodes[n];
    status = cfg.engine.host_mem.read(cfg.data_mapping, data_base(cfg),
                                      cfg.data_mr.length, raw);
    if (status == null || !status.ok() || raw.size() != shadow[n].size()) begin
      fail($sformatf("node %0d final memory read failed", n));
      return;
    end
    diffs = 0;
    foreach (raw[k]) begin
      if (byte'(shadow[n][k]) == raw[k])
        continue;
      diffs++;
      if (diffs <= 8)
        fail($sformatf("node %0d offset %0h: memory %02h != expected %02h", n, k,
                       raw[k], shadow[n][k]));
    end
    checked++;
  endfunction
endclass
