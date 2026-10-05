// 目录：验证组件层 tb/rdma_nic_model.sv。
// 职责：RDMA 网卡行为模型（无 RTL DUT 时充当设备）：
//   TX：发现 SQ 新 WQE → 从 host 内存读取并解码 SQE → 按 lkey 读取本地数据 → 按 MTU 分段发包，
//       RC 等待 ACK/NAK、READ 响应或 ATOMIC ACK 后发布 SQ CQE；
//   RX：按目的 QPN 分发；SEND 消费 RQE 并散写数据，WRITE 按 RETH 写入，READ 读出并分段回包，
//       ATOMIC 读改写并回原值；按需发布 RQ CQE 并回 ACK/NAK。
//   传输：RC 全部操作并等 ACK；URC 仅 SEND/WRITE(+IMM)，发出即完成、不回 ACK；UD 仅单包 SEND，
//       目的 QPN 取自 WQE。SGE 来自 WQE 内联或 SQ/RQ 外部 SGB（rdma_tb_dma.sqe_sges/rqe_sges）。
// 依赖：rdma_tb_node_cfg、rdma_tb_dma、rdma_wire、queue_data_engine 的设备侧 CQE 发布接口。
// 所有权与生命周期：模型只拥有每 QP 的设备侧游标/PSN 状态；队列、MR、内存归 engine/manager/host_mem。

// 每个 QP 的设备侧状态。
class rdma_nic_qp_state extends uvm_object;
  `uvm_object_utils(rdma_nic_qp_state)

  int unsigned sq_index;
  bit sq_wrap;
  int unsigned rq_index;
  bit rq_wrap;
  bit [23:0] send_psn;
  bit [23:0] expected_psn;
  bit [23:0] msn;
  // 正在接收的 SEND 消息。
  rdma_hw_rqe_model rx_rqe;
  rdma_sge rx_sges[$];
  int unsigned rx_index;
  bit rx_wrap;
  int unsigned rx_offset;
  bit rx_failed;
  // 正在接收的 WRITE 消息。
  bit [63:0] wr_va;
  bit [31:0] wr_rkey;
  int unsigned wr_len;
  int unsigned wr_offset;
  bit wr_failed;
  // 发往本 QP 请求方的响应报文（ACK/NAK/READ 响应/ATOMIC ACK）。
  mailbox #(rdma_packet) responses;

  // 功能：构造零游标、零 PSN 的 QP 状态。
  // 输入/输出及副作用：创建响应 mailbox。
  // 失败/边界：无。
  function new(string name = "rdma_nic_qp_state");
    super.new(name);
    sq_index = 0;
    sq_wrap = 1'b0;
    rq_index = 0;
    rq_wrap = 1'b0;
    send_psn = '0;
    expected_psn = '0;
    msn = '0;
    rx_rqe = null;
    rx_index = 0;
    rx_wrap = 1'b0;
    rx_offset = 0;
    rx_failed = 1'b0;
    wr_va = '0;
    wr_rkey = '0;
    wr_len = 0;
    wr_offset = 0;
    wr_failed = 1'b0;
    responses = new();
  endfunction
endclass

class rdma_nic_model extends uvm_component;
  `uvm_component_utils(rdma_nic_model)

  rdma_tb_node_cfg cfg;
  // 全部节点配置（按 node_id），用于取对端 QPN。
  rdma_tb_node_cfg nodes[int unsigned];
  rdma_wire fabric;
  protected rdma_tb_dma dma;
  protected rdma_nic_qp_state qps[$];
  protected mailbox #(rdma_packet) rx_mb;

  // 功能：构造未配置的 NIC 模型。
  // 输入/输出及副作用：创建接收 mailbox。
  // 失败/边界：run_phase 等待 cfg 设置；nodes、fabric 须同时就绪。
  function new(string name = "rdma_nic_model", uvm_component parent = null);
    super.new(name, parent);
    rx_mb = new();
    cfg = null;
    fabric = null;
  endfunction

  // 功能：wire 交付报文的入口：放入接收队列，由 rx_loop 处理。
  // 输入/输出及副作用：写 rx_mb。
  // 失败/边界：无。
  function void deliver(rdma_packet packet);
    void'(rx_mb.try_put(packet));
  endfunction

  // 功能：建立 DMA helper 与每 QP 状态，并并行运行 TX/RX 处理循环。
  // 输入/输出及副作用：读取 cfg；永不返回（由 phase 结束终止）。
  // 失败/边界：配置不完整时报 UVM_FATAL。
  task run_phase(uvm_phase phase);
    rdma_status status;

    wait (cfg != null);
    status = cfg.validate();
    if (status == null || !status.ok() || fabric == null)
      `uvm_fatal("RDMA_NIC", "NIC model configuration is incomplete")
    dma = rdma_tb_dma::type_id::create("dma");
    dma.cfg = cfg;
    foreach (cfg.qps[i])
      qps.push_back(rdma_nic_qp_state::type_id::create($sformatf("qp%0d", i)));
    fork
      tx_loop();
      rx_loop();
    join
  endtask

  // ---------------------------------------------------------------- TX

  // 功能：轮询所有 QP 的 SQ，按到达顺序逐条处理新 WQE。
  // 输入/输出及副作用：永久循环；空闲时等待 poll_interval。
  // 失败/边界：无。
  protected task tx_loop();
    bit busy;

    forever begin
      busy = 1'b0;
      foreach (qps[i]) begin
        if (ring_pending(i, 1'b1)) begin
          process_send_wqe(i);
          busy = 1'b1;
        end
      end
      if (!busy)
        #(cfg.poll_interval);
    end
  endtask

  // 功能：判断 QP 的 SQ（send=1）或 RQ 是否有设备尚未取走的 WQE。
  // 输入/输出及副作用：只读 engine runtime 游标。
  // 失败/边界：游标查询失败返回 0。
  protected function bit ring_pending(int unsigned i, bit send);
    rdma_status status;
    int unsigned pi;
    int unsigned ci;
    bit pw;
    bit cw;

    status = cfg.engine.query_runtime_cursors(
      cfg.qps[i].qp.handle, send ? RDMA_QUEUE_RUNTIME_SQ : RDMA_QUEUE_RUNTIME_RQ,
      pi, pw, ci, cw);
    if (status == null || !status.ok())
      return 1'b0;
    return send ? (pi != qps[i].sq_index || pw != qps[i].sq_wrap) :
                  (pi != qps[i].rq_index || pw != qps[i].rq_wrap);
  endfunction

  // 功能：设备侧游标前进一格，到达 depth 时回零并翻转 wrap。
  // 输入/输出及副作用：index/wrap 为 inout。
  // 失败/边界：depth 为零时保持不变。
  protected function void advance(inout int unsigned index, inout bit wrap,
                                  input int unsigned depth);
    if (depth == 0)
      return;
    index++;
    if (index >= depth) begin
      index = 0;
      wrap = ~wrap;
    end
  endfunction

  // 功能：处理一个 SQE：解码后按 opcode 执行 SEND/WRITE/READ/ATOMIC，并在需要时发布 SQ CQE。
  // 输入/输出及副作用：读 host 内存、发包、等待响应、写本地内存、发布 CQE；推进 SQ 设备游标。
  // 失败/边界：SQE 读取/解码失败报 UVM_ERROR 并跳过；本地 key/权限错误以
  //   EC_TPE_SQ_KEY_ERR 完成且不发包；对端 NAK 或响应超时以错误 ecode 完成。
  protected task process_send_wqe(int unsigned i);
    rdma_qp qp;
    rdma_nic_qp_state st;
    rdma_hw_model model;
    rdma_hw_sqe_model sqe;
    rdma_sge sges[$];
    bit [23:0] dst_qpn;
    rdma_packet stale;
    rdma_status status;
    byte unsigned payload[$];
    bit [7:0] ecode;
    int unsigned wqe_index;
    int unsigned byte_len;
    bit wqe_wrap;

    qp = cfg.qps[i].qp;
    st = qps[i];
    // 丢弃上一个请求超时后迟到的响应，避免被当作本请求的 ACK/响应。
    while (st.responses.try_get(stale))
      `uvm_warning("RDMA_NIC", $sformatf("node %0d QP%0d dropped late response PSN %0h",
                   cfg.node_id, i, stale.psn))
    status = dma.read_wqe(qp, 1'b1, st.sq_index, model);
    wqe_index = st.sq_index;
    wqe_wrap = st.sq_wrap;
    advance(st.sq_index, st.sq_wrap, qp.sq_depth);
    if (status == null || !status.ok() || !$cast(sqe, model)) begin
      `uvm_error("RDMA_NIC", $sformatf("node %0d SQE %0d decode failed: %s", cfg.node_id,
                 wqe_index, status == null ? "null" : status.convert2string()))
      return;
    end
    ecode = RDMA_CMQ_SUCCESS_ECODE;
    byte_len = 0;
    dst_qpn = (qp.transport == RDMA_TRANSPORT_UD) ? sqe.destination_qpn : '0;
    status = dma.sqe_sges(qp, sqe, sges);
    if (!status.ok()) begin
      `uvm_error("RDMA_NIC", $sformatf("node %0d SQE %0d SGE list: %s", cfg.node_id,
                 wqe_index, status.convert2string()))
      publish_cqe(i, wqe_index, wqe_wrap, 1'b0, RDMA_ECODE_EC_TPE_SQ_KEY_ERR, 0, '0);
      return;
    end
    case (sqe.opcode)
      RDMA_WR_SEND, RDMA_WR_SEND_WITH_IMM,
      RDMA_WR_RDMA_WRITE, RDMA_WR_WRITE_WITH_IMM: begin
        if (!gather(sges, payload))
          ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
        else if (qp.transport == RDMA_TRANSPORT_UD && payload.size() > cfg.mtu)
          ecode = RDMA_ECODE_EC_TPE_SQ_PAYLOAD_LEN_ABOVE;
        else begin
          byte_len = payload.size();
          send_message(i, net_opcode(sqe.opcode), payload, sqe.immediate_data,
                       sqe.remote_va.value, sqe.rkey, dst_qpn);
          // 仅 RC 可靠传输等待 ACK；UD/URC 发出即完成。
          if (qp.transport == RDMA_TRANSPORT_RC)
            wait_ack(i, ecode);
        end
      end
      RDMA_WR_RDMA_READ: begin
        byte_len = sge_total(sges);
        do_read(i, sqe, sges, byte_len, ecode);
      end
      RDMA_WR_ATOMIC_CMP_SWAP, RDMA_WR_ATOMIC_FETCH_ADD: begin
        byte_len = 8;
        do_atomic(i, sqe, ecode);
      end
      default: begin
        `uvm_error("RDMA_NIC", $sformatf("unsupported SQE opcode %s", sqe.opcode.name()))
        ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
      end
    endcase
    if (sqe.signaled || ecode != RDMA_CMQ_SUCCESS_ECODE)
      publish_cqe(i, wqe_index, wqe_wrap, 1'b0, ecode, byte_len, '0);
  endtask

  // 功能：WQE opcode 转网络 opcode（SEND/WRITE 类）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：其它 opcode 返回 SEND。
  protected function rdma_network_opcode_e net_opcode(rdma_work_opcode_e op);
    case (op)
      RDMA_WR_SEND_WITH_IMM:  return RDMA_NET_SEND_WITH_IMM;
      RDMA_WR_RDMA_WRITE:     return RDMA_NET_RDMA_WRITE;
      RDMA_WR_WRITE_WITH_IMM: return RDMA_NET_WRITE_WITH_IMM;
      default:                return RDMA_NET_SEND;
    endcase
  endfunction

  // 功能：SGE 列表长度之和。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function int unsigned sge_total(rdma_sge sges[$]);
    int unsigned total;

    total = 0;
    foreach (sges[k])
      total += sges[k].length;
    return total;
  endfunction

  // 功能：按 lkey 依次读取各 SGE 的数据并拼接。
  // 输入/输出及副作用：payload 输出；只读本地内存。
  // 失败/边界：任一 SGE 校验/读取失败返回 0。
  protected function bit gather(rdma_sge sges[$], output byte unsigned payload[$]);
    byte unsigned part[$];

    payload.delete();
    foreach (sges[k]) begin
      if (dma.read(sges[k].lkey, 1'b0, sges[k].iova.value, sges[k].length, part) !=
          RDMA_TB_DMA_OK)
        return 1'b0;
      payload = {payload, part};
    end
    return 1'b1;
  endfunction

  // 功能：把数据按 lkey 依次散写到 SGE 列表，从消息内偏移 offset 开始。
  // 输入/输出及副作用：写本地内存。
  // 失败/边界：超出 SGE 总容量或 DMA 失败返回 0。
  protected function bit scatter(rdma_sge sges[$], int unsigned offset,
                                 byte unsigned data[$]);
    int unsigned pos;
    int unsigned base;
    int unsigned take;
    int unsigned start;
    byte unsigned part[$];

    pos = 0;
    base = 0;
    foreach (sges[k]) begin
      if (pos >= data.size())
        break;
      if (sges[k] == null)
        continue;
      if (offset + pos < base + sges[k].length) begin
        start = offset + pos - base;
        take = sges[k].length - start;
        if (take > data.size() - pos)
          take = data.size() - pos;
        part = data[pos:pos + take - 1];
        if (dma.write(sges[k].lkey, 1'b0, 1'b0, sges[k].iova.value + start, part) !=
            RDMA_TB_DMA_OK)
          return 1'b0;
        pos += take;
      end
      base += sges[k].length;
    end
    return pos == data.size();
  endfunction

  // 功能：把一条消息按 MTU 分段发送到对端 QP；WRITE 首/单包携带 RETH，带立即数时尾/单包携带 ImmDt。
  // 输入/输出及副作用：推进 send_psn，经 wire 发包；dst_qpn 非零时覆盖目的 QPN（UD 取自 WQE）。
  // 失败/边界：空 payload 发送一个零长度单包。
  protected task send_message(int unsigned i, rdma_network_opcode_e op,
                              byte unsigned payload[$], bit [31:0] imm,
                              bit [63:0] va, bit [31:0] rkey, bit [23:0] dst_qpn);
    int unsigned count;
    int unsigned start;
    int unsigned take;
    rdma_packet pkt;

    count = (payload.size() + cfg.mtu - 1) / cfg.mtu;
    if (count == 0)
      count = 1;
    for (int unsigned k = 0; k < count; k++) begin
      pkt = new_packet(i, op, segment_of(k, count), qps[i].send_psn);
      if (dst_qpn != 0)
        pkt.destination_qpn = dst_qpn;
      qps[i].send_psn++;
      start = k * cfg.mtu;
      take = (payload.size() > start + cfg.mtu) ? cfg.mtu : payload.size() - start;
      if (take != 0)
        pkt.payload = payload[start:start + take - 1];
      pkt.reth_va = va;
      pkt.reth_rkey = rkey;
      pkt.reth_len = payload.size();
      pkt.imm = imm;
      transmit(i, pkt);
    end
  endtask

  // 功能：由包序号与总包数得到分段位置。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function rdma_packet_segment_e segment_of(int unsigned k, int unsigned count);
    if (count == 1)
      return RDMA_SEG_ONLY;
    if (k == 0)
      return RDMA_SEG_FIRST;
    return (k == count - 1) ? RDMA_SEG_LAST : RDMA_SEG_MIDDLE;
  endfunction

  // 功能：构造发往对端 QP 的报文骨架（transport、QPN、PSN、opcode/segment）。
  // 输入/输出及副作用：返回新报文。
  // 失败/边界：无。
  protected function rdma_packet new_packet(int unsigned i, rdma_network_opcode_e op,
                                            rdma_packet_segment_e seg, bit [23:0] psn);
    rdma_packet pkt;
    rdma_tb_qp_link link;

    link = cfg.qps[i];
    pkt = rdma_packet::type_id::create("nic_packet");
    pkt.transport = link.qp.transport;
    pkt.opcode = op;
    pkt.segment = seg;
    pkt.source_qpn = link.qp.local_qp_id;
    pkt.destination_qpn = nodes[link.peer_node].qps[link.peer_qp_index].qp.local_qp_id;
    pkt.psn = psn;
    return pkt;
  endfunction

  // 功能：序列化扩展头后经 wire 发往 QP 的对端节点。
  // 输入/输出及副作用：写 pkt.header_bytes。
  // 失败/边界：无。
  protected task transmit(int unsigned i, rdma_packet pkt);
    pkt.pack_headers();
    fabric.transmit(cfg.node_id, cfg.qps[i].peer_node, pkt);
  endtask

  // 功能：等待发往 QP i 请求方的下一个响应报文。
  // 输入/输出及副作用：pkt 输出；阻塞至多 response_timeout。
  // 失败/边界：超时返回 0，pkt 为 null。
  protected task get_response(int unsigned i, output rdma_packet pkt, output bit got);
    pkt = null;
    got = 1'b0;
    fork
      begin
        fork
          begin
            qps[i].responses.get(pkt);
            got = 1'b1;
          end
          #(cfg.response_timeout);
        join_any
        disable fork;
      end
    join
  endtask

  // 功能：等待 RC SEND/WRITE 的 ACK/NAK。
  // 输入/输出及副作用：消费一个响应报文；ecode 输出。
  // 失败/边界：NAK、非 ACK 报文或超时返回 EC_RPE_RC_URC_ACCESS_INVLD。
  protected task wait_ack(int unsigned i, output bit [7:0] ecode);
    rdma_packet pkt;
    bit got;

    get_response(i, pkt, got);
    ecode = (got && pkt.opcode inside {RDMA_NET_ACK, RDMA_NET_NAK} &&
             pkt.aeth_syndrome == RDMA_AETH_ACK) ?
            RDMA_CMQ_SUCCESS_ECODE : RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD;
    if (!got)
      `uvm_error("RDMA_NIC", $sformatf("node %0d QP%0d ACK timeout", cfg.node_id, i))
  endtask

  // 功能：执行 RDMA READ：发 READ 请求，接收 READ 响应并按 lkey 散写到本地 SGE。
  // 输入/输出及副作用：推进 send_psn（按响应包数）；写本地内存；ecode 输出。
  // 失败/边界：NAK/超时/响应长度不符返回 EC_RPE_RC_URC_ACCESS_INVLD；本地写失败返回
  //   EC_TPE_SQ_KEY_ERR。
  protected task do_read(int unsigned i, rdma_hw_sqe_model sqe, rdma_sge sges[$],
                         int unsigned total, output bit [7:0] ecode);
    rdma_packet pkt;
    int unsigned offset;
    int unsigned count;
    bit got;

    pkt = new_packet(i, RDMA_NET_RDMA_READ_REQUEST, RDMA_SEG_ONLY, qps[i].send_psn);
    pkt.reth_va = sqe.remote_va.value;
    pkt.reth_rkey = sqe.rkey;
    pkt.reth_len = total;
    count = (total + cfg.mtu - 1) / cfg.mtu;
    qps[i].send_psn += (count == 0) ? 1 : count;
    transmit(i, pkt);
    ecode = RDMA_CMQ_SUCCESS_ECODE;
    offset = 0;
    forever begin
      get_response(i, pkt, got);
      if (!got || pkt.opcode != RDMA_NET_RDMA_READ_RESP) begin
        ecode = RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD;
        if (!got)
          `uvm_error("RDMA_NIC", $sformatf("node %0d QP%0d READ response timeout",
                     cfg.node_id, i))
        return;
      end
      if (ecode == RDMA_CMQ_SUCCESS_ECODE && !scatter(sges, offset, pkt.payload))
        ecode = RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
      offset += pkt.payload.size();
      if (pkt.segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY})
        break;
    end
    if (ecode == RDMA_CMQ_SUCCESS_ECODE && offset != total)
      ecode = RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD;
  endtask

  // 功能：执行 ATOMIC CMP_SWAP/FETCH_ADD：发 AtomicETH 请求，收到 ATOMIC ACK 后把原值（小端 8 字节）
  //   写入本地 atomic buffer。
  // 输入/输出及副作用：推进 send_psn；写本地内存；ecode 输出。
  // 失败/边界：NAK/超时返回 EC_RPE_RC_URC_ACCESS_INVLD；本地写失败返回 EC_TPE_SQ_KEY_ERR。
  protected task do_atomic(int unsigned i, rdma_hw_sqe_model sqe, output bit [7:0] ecode);
    rdma_packet pkt;
    byte unsigned orig[$];
    bit got;

    pkt = new_packet(i, sqe.opcode == RDMA_WR_ATOMIC_CMP_SWAP ?
                     RDMA_NET_ATOMIC_CMP_SWAP : RDMA_NET_ATOMIC_FETCH_ADD,
                     RDMA_SEG_ONLY, qps[i].send_psn);
    qps[i].send_psn++;
    pkt.atomic_va = sqe.remote_va.value;
    pkt.atomic_rkey = sqe.rkey;
    pkt.atomic_swap_add = sqe.atomic_value;
    pkt.atomic_compare = sqe.atomic_compare;
    transmit(i, pkt);
    get_response(i, pkt, got);
    if (!got || pkt.opcode != RDMA_NET_ATOMIC_ACK ||
        pkt.aeth_syndrome != RDMA_AETH_ACK) begin
      ecode = RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD;
      return;
    end
    for (int k = 0; k < 8; k++)
      orig.push_back(pkt.atomic_orig >> (8 * k));
    ecode = (dma.write(sqe.atomic_local_lkey, 1'b0, 1'b0, sqe.atomic_local_iova.value,
                       orig) == RDMA_TB_DMA_OK) ?
            RDMA_CMQ_SUCCESS_ECODE : RDMA_ECODE_EC_TPE_SQ_KEY_ERR;
  endtask

  // 功能：向 QP i 的对端发送 ACK（syndrome=ACK）或 NAK。
  // 输入/输出及副作用：仅 ACK 推进 msn；经 wire 发包。
  // 失败/边界：无。
  protected task send_ack(int unsigned i, bit [23:0] psn, bit [7:0] syndrome);
    rdma_packet pkt;

    pkt = new_packet(i, syndrome == RDMA_AETH_ACK ? RDMA_NET_ACK : RDMA_NET_NAK,
                     RDMA_SEG_ONLY, psn);
    if (syndrome == RDMA_AETH_ACK)
      qps[i].msn++;
    pkt.aeth_syndrome = syndrome;
    pkt.aeth_msn = qps[i].msn;
    transmit(i, pkt);
  endtask

  // 功能：取 QP i 的下一个 RQE；不等待（rx_loop 串行处理，阻塞会拖住同节点的响应报文）。
  // 输入/输出及副作用：rqe/index/wrap 输出；推进 RQ 设备游标。
  // 失败/边界：无可用 RQE 或解码失败返回 0，调用方回 RNR/NAK。
  protected function bit fetch_rqe(int unsigned i, output rdma_hw_rqe_model rqe,
                                   output int unsigned index, output bit wrap);
    rdma_hw_model model;
    rdma_status status;

    rqe = null;
    index = qps[i].rq_index;
    wrap = qps[i].rq_wrap;
    if (!ring_pending(i, 1'b0))
      return 1'b0;
    status = dma.read_wqe(cfg.qps[i].qp, 1'b0, qps[i].rq_index, model);
    advance(qps[i].rq_index, qps[i].rq_wrap, cfg.qps[i].qp.rq_depth);
    if (status == null || !status.ok() || !$cast(rqe, model)) begin
      `uvm_error("RDMA_NIC", $sformatf("node %0d QP%0d RQE %0d decode failed: %s", cfg.node_id, i,
                 index, status == null ? "null" : status.convert2string()))
      return 1'b0;
    end
    return 1'b1;
  endfunction

  // 功能：响应方处理一个请求报文（SEND/WRITE/READ 请求/ATOMIC），按 PSN 顺序推进 expected_psn。
  // 输入/输出及副作用：可能写本地内存、发布 RQ CQE、回 ACK/NAK 或 READ 响应。
  // 失败/边界：PSN 不连续报 UVM_ERROR（链路无损时不应发生）；访问错误回 NAK 且不写内存。
  protected task handle_request(int unsigned i, rdma_packet pkt);
    rdma_nic_qp_state st;
    bit rc;
    bit last;

    st = qps[i];
    rc = cfg.qps[i].qp.transport == RDMA_TRANSPORT_RC;
    last = pkt.segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY};
    // UD 无连接，PSN 由各发送方独立维护，不做顺序检查。
    if (cfg.qps[i].qp.transport != RDMA_TRANSPORT_UD && pkt.psn != st.expected_psn)
      `uvm_error("RDMA_NIC", $sformatf("node %0d QP%0d PSN %0h != expected %0h",
                 cfg.node_id, i, pkt.psn, st.expected_psn))
    st.expected_psn = pkt.psn + 1;
    case (pkt.opcode)
      RDMA_NET_SEND, RDMA_NET_SEND_WITH_IMM: begin
        if (pkt.segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) begin
          st.rx_offset = 0;
          st.rx_failed = !fetch_rqe(i, st.rx_rqe, st.rx_index, st.rx_wrap);
          if (!st.rx_failed) begin
            rdma_status sge_status;

            sge_status = dma.rqe_sges(cfg.qps[i].qp, st.rx_rqe, st.rx_sges);
            if (!sge_status.ok()) begin
              `uvm_error("RDMA_NIC", $sformatf("node %0d QP%0d RQE SGE list: %s", cfg.node_id, i,
                         sge_status.convert2string()))
              st.rx_failed = 1'b1;
            end
          end
        end
        if (!st.rx_failed && !scatter(st.rx_sges, st.rx_offset, pkt.payload))
          st.rx_failed = 1'b1;
        st.rx_offset += pkt.payload.size();
        if (last) begin
          if (st.rx_rqe != null)
            publish_cqe(i, st.rx_index, st.rx_wrap, 1'b1,
                        st.rx_failed ? RDMA_ECODE_EC_RPE_RC_URC_ACCESS_INVLD :
                                       RDMA_CMQ_SUCCESS_ECODE,
                        st.rx_offset, pkt.has_immdt() ? pkt.imm : '0);
          if (rc)
            send_ack(i, pkt.psn, st.rx_rqe == null ? RDMA_AETH_RNR_NAK :
                                 st.rx_failed ? RDMA_AETH_NAK_INVALID_REQUEST :
                                                RDMA_AETH_ACK);
        end
      end
      RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM: begin
        if (pkt.segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) begin
          rdma_dma_mapping mapping;
          longint unsigned offset;

          st.wr_va = pkt.reth_va;
          st.wr_rkey = pkt.reth_rkey;
          st.wr_len = pkt.reth_len;
          st.wr_offset = 0;
          st.wr_failed = dma.resolve(pkt.reth_rkey, 1'b1, 1'b1, 1'b0, pkt.reth_va,
                                     pkt.reth_len, mapping, offset) != RDMA_TB_DMA_OK;
          if (st.wr_failed && rc)
            send_ack(i, pkt.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
        end
        if (!st.wr_failed && pkt.payload.size() != 0 &&
            dma.write(st.wr_rkey, 1'b1, 1'b0, st.wr_va + st.wr_offset, pkt.payload) !=
            RDMA_TB_DMA_OK) begin
          st.wr_failed = 1'b1;
          if (rc)
            send_ack(i, pkt.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
        end
        st.wr_offset += pkt.payload.size();
        if (last && !st.wr_failed) begin
          bit got;

          got = 1'b1;
          if (pkt.opcode == RDMA_NET_WRITE_WITH_IMM) begin
            rdma_hw_rqe_model rqe;
            int unsigned index;
            bit wrap;

            got = fetch_rqe(i, rqe, index, wrap);
            if (got)
              publish_cqe(i, index, wrap, 1'b1, RDMA_CMQ_SUCCESS_ECODE,
                          st.wr_len, pkt.imm);
          end
          if (rc)
            send_ack(i, pkt.psn, got ? RDMA_AETH_ACK : RDMA_AETH_RNR_NAK);
        end
      end
      RDMA_NET_RDMA_READ_REQUEST:
        serve_read(i, pkt);
      RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD:
        serve_atomic(i, pkt);
      default:
        `uvm_error("RDMA_NIC", $sformatf("unexpected request opcode %s", pkt.opcode.name()))
    endcase
  endtask

  // 功能：响应 READ 请求：按 rkey 读出数据并以 READ RESPONSE 分段回包（PSN 从请求 PSN 起连续）。
  // 输入/输出及副作用：推进 expected_psn；经 wire 发包。
  // 失败/边界：rkey/范围/权限错误回 NAK（remote access）。
  protected task serve_read(int unsigned i, rdma_packet req);
    byte unsigned data[$];
    rdma_packet pkt;
    int unsigned count;
    int unsigned start;
    int unsigned take;

    // 请求方已按响应包数推进 send_psn，NAK 时也须消耗同样的 PSN 区间。
    count = (req.reth_len + cfg.mtu - 1) / cfg.mtu;
    if (count == 0)
      count = 1;
    qps[i].expected_psn = req.psn + count;
    if (dma.read(req.reth_rkey, 1'b1, req.reth_va, req.reth_len, data) != RDMA_TB_DMA_OK) begin
      send_ack(i, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
      return;
    end
    qps[i].msn++;
    for (int unsigned k = 0; k < count; k++) begin
      pkt = new_packet(i, RDMA_NET_RDMA_READ_RESP, segment_of(k, count), req.psn + k);
      start = k * cfg.mtu;
      take = (data.size() > start + cfg.mtu) ? cfg.mtu : data.size() - start;
      if (take != 0)
        pkt.payload = data[start:start + take - 1];
      pkt.aeth_syndrome = RDMA_AETH_ACK;
      pkt.aeth_msn = qps[i].msn;
      transmit(i, pkt);
    end
  endtask

  // 功能：响应 ATOMIC 请求：8 字节对齐地址上按小端读改写，并以 ATOMIC ACK 返回原值。
  // 输入/输出及副作用：写本地内存；经 wire 发包。
  // 失败/边界：rkey/范围/权限/对齐错误回 NAK（remote access），内存不变。
  protected task serve_atomic(int unsigned i, rdma_packet req);
    rdma_dma_mapping mapping;
    longint unsigned offset;
    rdma_status status;
    rdma_packet pkt;
    byte raw[];
    bit [63:0] orig;
    bit [63:0] value;

    if (req.atomic_va[2:0] != 3'b000 ||
        dma.resolve(req.atomic_rkey, 1'b1, 1'b1, 1'b1, req.atomic_va, 8, mapping, offset) !=
        RDMA_TB_DMA_OK) begin
      send_ack(i, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
      return;
    end
    status = cfg.engine.host_mem.read(mapping, offset, 8, raw);
    if (status == null || !status.ok() || raw.size() != 8) begin
      send_ack(i, req.psn, RDMA_AETH_NAK_REMOTE_ACCESS);
      return;
    end
    orig = '0;
    for (int k = 7; k >= 0; k--)
      orig = (orig << 8) | {56'b0, raw[k]};
    if (req.opcode == RDMA_NET_ATOMIC_CMP_SWAP)
      value = (orig == req.atomic_compare) ? req.atomic_swap_add : orig;
    else
      value = orig + req.atomic_swap_add;
    for (int k = 0; k < 8; k++)
      raw[k] = value >> (8 * k);
    void'(cfg.engine.host_mem.write(mapping, offset, raw));
    pkt = new_packet(i, RDMA_NET_ATOMIC_ACK, RDMA_SEG_ONLY, req.psn);
    qps[i].msn++;
    pkt.aeth_syndrome = RDMA_AETH_ACK;
    pkt.aeth_msn = qps[i].msn;
    pkt.atomic_orig = orig;
    transmit(i, pkt);
  endtask

  // 功能：经 engine 设备侧接口向节点 CQ 发布一个 SQ/RQ CQE。
  // 输入/输出及副作用：持 cq_lock 查询 polarity 并 publish_cqe。
  // 失败/边界：发布失败报 UVM_ERROR。
  protected task publish_cqe(int unsigned i, int unsigned wqe_index, bit wqe_wrap, bit rq,
                             bit [7:0] ecode, int unsigned byte_len, bit [31:0] imm);
    rdma_qp qp;
    rdma_hw_cqe_model cqe;
    rdma_queue_device_publish_result published;
    rdma_status status;
    bit polarity;

    qp = cfg.qps[i].qp;
    cfg.cq_lock.get(1);
    status = cfg.engine.query_runtime_producer_polarity(
      cfg.cq.handle, RDMA_QUEUE_RUNTIME_CQ, polarity);
    if (status != null && status.ok()) begin
      cqe = rdma_hw_cqe_model::type_id::create("nic_cqe");
      cqe.qp_h = rdma_clone_handle_value(qp.handle, "NIC CQE QP");
      cqe.qpn = qp.local_qp_id;
      cqe.wqe_index = wqe_index;
      cqe.wqe_wrap = wqe_wrap;
      cqe.rq_cqe = rq;
      cqe.srfq = 1'b0;
      // engine 规定 RQ CQE 一律用 RQ/SRFQ overlay（含 UD，不携带源 QPN）。
      cqe.variant = rq ? RDMA_CQE_VARIANT_RQ_SRFQ :
                    qp.transport == RDMA_TRANSPORT_UD ? RDMA_CQE_VARIANT_UD :
                                                        RDMA_CQE_VARIANT_RC;
      cqe.polarity = polarity;
      cqe.packet_opcode = 8'h01;
      cqe.ecode = ecode;
      cqe.payload_len = byte_len;
      cqe.immediate_data = imm;
      cqe.status = rdma_status::success();
      cfg.engine.publish_cqe(cfg.cq.handle, cqe, published, status);
    end
    cfg.cq_lock.put(1);
    if (status == null || !status.ok())
      `uvm_error("RDMA_NIC", $sformatf("node %0d CQE publish failed: %s", cfg.node_id,
                 status == null ? "null" : status.convert2string()))
  endtask

  // ---------------------------------------------------------------- RX

  // 功能：处理接收队列：响应类报文转交请求方，请求类报文由响应方逻辑处理。
  // 输入/输出及副作用：永久循环。
  // 失败/边界：扩展头解析失败或目的 QPN 未知时报 UVM_ERROR 并丢弃。
  protected task rx_loop();
    rdma_packet pkt;
    int unsigned i;

    forever begin
      rx_mb.get(pkt);
      if (!pkt.unpack_headers()) begin
        `uvm_error("RDMA_NIC", "received packet extension headers are truncated")
        continue;
      end
      if (!cfg.find_qp(pkt.destination_qpn, i)) begin
        `uvm_error("RDMA_NIC", $sformatf("node %0d has no QPN %0h", cfg.node_id,
                   pkt.destination_qpn))
        continue;
      end
      if (pkt.opcode inside {RDMA_NET_ACK, RDMA_NET_NAK, RDMA_NET_RDMA_READ_RESP,
                             RDMA_NET_ATOMIC_ACK})
        void'(qps[i].responses.try_put(pkt));
      else
        handle_request(i, pkt);
    end
  endtask
endclass
