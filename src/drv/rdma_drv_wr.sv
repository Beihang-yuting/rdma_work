// 目录：驱动层 src/drv/rdma_drv_wr.sv。
// 职责：wr.c/event.c 内核态数据路径：post_send（RC/UD WQE、inline/SGE/SGB、签名、polarity，
//   notify_sq_db 的 hw_drop_db_cnt 判定与 SQ doorbell）、post_recv（RQE、shadow PI、RQ doorbell）、
//   poll_cq（32B CQE、wr_id 回查、shadow CI）、CEQ/AEQ 处理与 CI doorbell。
// 依赖：rdma_drv_dev/qp/cq、rdma_be、rdma_defs.svh。
// 所有权与生命周期：WR/WC 对象为值对象；本文件不分配持久资源。

typedef enum int {
  RDMA_DRV_WR_SEND,
  RDMA_DRV_WR_SEND_IMM,
  RDMA_DRV_WR_SEND_INV,
  RDMA_DRV_WR_WRITE,
  RDMA_DRV_WR_WRITE_IMM,
  RDMA_DRV_WR_READ,
  RDMA_DRV_WR_CAS,
  RDMA_DRV_WR_FAA,
  RDMA_DRV_WR_LOCAL_INV
} rdma_drv_wr_opcode_e;

typedef enum int {
  RDMA_DRV_WC_SUCCESS,
  RDMA_DRV_WC_FLUSH_ERR,
  RDMA_DRV_WC_REM_INV_REQ_ERR,
  RDMA_DRV_WC_GENERAL_ERR
} rdma_drv_wc_status_e;

class rdma_drv_sge extends uvm_object;
  `rdma_object_utils(rdma_drv_sge)

  bit [63:0] addr;
  int unsigned length;
  bit [31:0] lkey;

  // 功能：构造 SGE。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_sge");
    super.new(name);
  endfunction

  // 功能：便捷构造。
  // 输入/输出及副作用：返回新对象。
  // 失败/边界：无。
  static function rdma_drv_sge make(bit [63:0] addr, int unsigned length, bit [31:0] lkey);
    rdma_drv_sge s;

    s = rdma_drv_sge::type_id::create("sge");
    s.addr = addr;
    s.length = length;
    s.lkey = lkey;
    return s;
  endfunction
endclass

class rdma_drv_send_wr extends uvm_object;
  `rdma_object_utils(rdma_drv_send_wr)

  longint unsigned wr_id;
  rdma_drv_wr_opcode_e opcode;
  rdma_drv_sge sges[$];
  bit signaled;
  bit solicited;
  bit inline_data;
  bit [31:0] imm;
  bit [31:0] rkey;
  bit [63:0] remote_va;
  bit [63:0] compare_add;
  bit [63:0] swap;
  // UD 地址（ah 的等价）。
  bit [23:0] dest_qpn;
  bit [31:0] qkey;
  bit [47:0] dmac;
  byte unsigned dest_ip[16];

  // 功能：构造空 WR（默认 signaled）。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_send_wr");
    super.new(name);
    signaled = 1'b1;
  endfunction
endclass

class rdma_drv_recv_wr extends uvm_object;
  `rdma_object_utils(rdma_drv_recv_wr)

  longint unsigned wr_id;
  rdma_drv_sge sges[$];

  // 功能：构造空 WR。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_recv_wr");
    super.new(name);
  endfunction
endclass

class rdma_drv_wc extends uvm_object;
  `rdma_object_utils(rdma_drv_wc)

  longint unsigned wr_id;
  rdma_drv_wc_status_e status;
  bit [7:0] vendor_err;
  bit is_recv;
  bit [7:0] pkt_opcode;
  int unsigned byte_len;
  bit [31:0] imm;
  int unsigned qpn;
  int unsigned src_qp;

  // 功能：构造空 WC。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_wc");
    super.new(name);
  endfunction
endclass

class rdma_drv_wr extends uvm_object;
  `rdma_object_utils(rdma_drv_wr)

  localparam int unsigned PAYLOAD_OFFSET = 32;
  localparam int unsigned S_PAYLOAD_MAX = 32;
  localparam int unsigned S_SGE_MAX = 2;
  localparam int unsigned SGE_BYTES = 16;
  localparam int unsigned RQE_OPCODE = 9;
  localparam int unsigned RX_CE = 1;
  localparam int unsigned TX_CE = 2;
  localparam bit [7:0] DB_CNT_SIGN_MASK = 8'h40;

  // 功能：构造（只含静态方法）。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_wr");
    super.new(name);
  endfunction

  // 功能：WR opcode → SQ WQE opcode（xtrdma_wqe_opcode_map_table）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function bit [3:0] wqe_opcode(rdma_drv_wr_opcode_e op);
    case (op)
      RDMA_DRV_WR_SEND: return RDMA_SQ_OPCODE_SEND;
      RDMA_DRV_WR_SEND_IMM: return RDMA_SQ_OPCODE_SEND_WITH_IMM;
      RDMA_DRV_WR_SEND_INV: return RDMA_SQ_OPCODE_SEND_WITH_INV;
      RDMA_DRV_WR_WRITE: return RDMA_SQ_OPCODE_WRITE;
      RDMA_DRV_WR_WRITE_IMM: return RDMA_SQ_OPCODE_WRITE_WITH_IMM;
      RDMA_DRV_WR_READ: return RDMA_SQ_OPCODE_READ;
      RDMA_DRV_WR_CAS: return RDMA_SQ_OPCODE_ATOMIC_CMP_AND_SWP;
      RDMA_DRV_WR_FAA: return RDMA_SQ_OPCODE_ATOMIC_FETCH_AND_ADD;
      default: return RDMA_SQ_OPCODE_LOCAL_INV;
    endcase
  endfunction

  // 功能：SGE 列表的 16B 描述符（xtrdma_set_sge：LEN[62:32]|LKEY[31:0]，VA），跳过 0 长度 SGE。
  // 输入/输出及副作用：返回新数组。
  // 失败/边界：无。
  static function rdma_bytes_t sge_descriptors(rdma_drv_sge sges[$]);
    rdma_bytes_t out;
    int unsigned n;

    n = 0;
    out = rdma_be::zeros(sges.size() * SGE_BYTES);
    foreach (sges[i])
      if (sges[i].length != 0) begin
        rdma_be::put_qword(out, n * SGE_BYTES,
                           (64'(sges[i].length & 32'h7fff_ffff) << 32) | sges[i].lkey);
        rdma_be::put_qword(out, n * SGE_BYTES + 8, sges[i].addr);
        n++;
      end
    return rdma_be::slice(out, 0, n * SGE_BYTES);
  endfunction

  // 功能：xtrdma_copy_inline_data：按 SGE 顺序读出 inline 负载（驱动从 VA 拷贝，这里按 DMA 地址读）。
  // 输入/输出及副作用：data 输出；读主机内存。
  // 失败/边界：读失败返回错误。
  static function rdma_status gather(rdma_drv_dev dev, rdma_drv_sge sges[$],
                                     output rdma_bytes_t data);
    byte raw[];
    rdma_status status;

    data = new[0];
    foreach (sges[i]) begin
      if (sges[i].length == 0)
        continue;
      status = dev.hw.host_mem.dma_read(sges[i].addr, sges[i].length, raw);
      if (!status.ok())
        return status;
      foreach (raw[k])
        data = {data, byte'(raw[k])};
    end
    return rdma_status::success();
  endfunction

  // 功能：xtrdma_post_send（单个 WR）：状态与容量检查，按 RC/UD 填 WQE 与数据区（inline/SGE 在 WQE
  //   字节 32 起，超出时写 SGB 槽并填 SGB_PA），首槽翻转 polarity，签名覆盖头、WQE 其余字节与 SGB 有效
  //   部分，最后写头；随后 notify_sq_db。
  // 输入/输出及副作用：写 SQ/SGB、读 shadow、可能敲 SQ doorbell；推进 sq_head。
  // 失败/边界：RESET/INIT/RTR 返回 INVALID_STATE；环满返回 QUEUE_FULL；负载或 SGE 数越界返回
  //   INVALID_ARGUMENT。
  static task post_send(rdma_drv_dev dev, rdma_drv_qp qp, rdma_drv_send_wr wr,
                        output rdma_status status);
    rdma_bytes_t wqe;
    rdma_bytes_t data;
    rdma_bytes_t sgb;
    rdma_drv_dma sgb_page;
    int unsigned sgb_offset;
    bit [63:0] sgb_pa;
    int unsigned idx;
    int unsigned sge_num;
    longint unsigned payload;
    bit use_inline;
    bit use_sgb;
    bit atomic;
    bit [63:0] hdr;
    int unsigned ce;

    if (qp.cur_state inside {RDMA_DRV_QPS_RESET, RDMA_DRV_QPS_INIT, RDMA_DRV_QPS_RTR}) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "QP state does not allow post_send");
      return;
    end
    if (qp.sq_head - qp.sq_tail >= qp.sq_depth) begin
      status = rdma_status::make(RDMA_SC_QUEUE_FULL, "send queue is full");
      return;
    end
    idx = qp.sq_head % qp.sq_depth;
    wqe = rdma_be::zeros(RDMA_WQE_BYTES);
    atomic = wr.opcode inside {RDMA_DRV_WR_CAS, RDMA_DRV_WR_FAA};
    sge_num = 0;
    payload = 0;
    foreach (wr.sges[i])
      if (wr.sges[i].length != 0) begin
        sge_num++;
        payload += wr.sges[i].length;
      end
    if (payload > 64'h8000_0000 || sge_num > qp.max_send_sge) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "send payload or SGE count is invalid");
      return;
    end
    use_inline = wr.inline_data && !atomic &&
                 (payload <= S_PAYLOAD_MAX ||
                  (qp.sgb_shift != 0 && payload <= (1 << qp.sgb_shift)));
    if (use_inline && payload > qp.max_inline) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "inline payload exceeds max_inline");
      return;
    end
    use_sgb = qp.qp_type == RDMA_DRV_QPT_UD;
    if (qp.qp_type == RDMA_DRV_QPT_RC && payload != 0 && !atomic) begin
      if (use_inline)
        use_sgb = payload > S_PAYLOAD_MAX;
      else
        use_sgb = sge_num > S_SGE_MAX;
    end
    status = rdma_status::success();
    if (use_inline) begin
      status = gather(dev, wr.sges, data);
      data = {data, rdma_be::zeros((SGE_BYTES - data.size() % SGE_BYTES) % SGE_BYTES)};
      sge_num = (payload + SGE_BYTES - 1) / SGE_BYTES;
    end
    else
      data = sge_descriptors(wr.sges);
    if (!status.ok())
      return;
    sgb = new[0];
    if (use_sgb) begin
      sgb_pa = qp.sgb_addr(1'b0, idx, sgb_page, sgb_offset);
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_SGB_PA, sgb_pa >> 9)
      sgb = data;
      status = dev.hw.write(sgb_page, sgb_offset, sgb);
      if (!status.ok())
        return;
    end
    else if (!atomic) begin
      foreach (data[i])
        wqe[PAYLOAD_OFFSET + i] = data[i];
    end
    if (qp.qp_type == RDMA_DRV_QPT_RC)
      fill_rc(wqe, wr, sge_num, payload);
    else
      fill_ud(wqe, qp, wr, sge_num, payload);
    if (idx == 0)
      qp.sq_polarity = !qp.sq_polarity;
    ce = 0;
    if (wr.signaled || qp.sig_all)
      ce = RX_CE;
    if (ce != 0 && (qp.qp_type == RDMA_DRV_QPT_UD || wr.opcode == RDMA_DRV_WR_LOCAL_INV))
      ce = TX_CE;
    hdr = '0;
    hdr[RDMA_SQ_WQE_QPN_LSB +: RDMA_SQ_WQE_QPN_WIDTH] = qp.qpn;
    if (qp.qp_type == RDMA_DRV_QPT_RC)
      hdr[RDMA_SQ_WQE_ICOS_LSB +: RDMA_SQ_WQE_ICOS_WIDTH] = 3;
    hdr[RDMA_SQ_WQE_QP_SN_LSB +: RDMA_SQ_WQE_QP_SN_WIDTH] = qp.qp_sn;
    hdr[RDMA_SQ_WQE_OPCODE_LSB +: RDMA_SQ_WQE_OPCODE_WIDTH] = wqe_opcode(wr.opcode);
    hdr[RDMA_SQ_WQE_INDEX_LSB +: RDMA_SQ_WQE_INDEX_WIDTH] = idx;
    hdr[RDMA_SQ_WQE_WRAP_LSB] = (qp.sq_head / qp.sq_depth) & 1;
    hdr[RDMA_SQ_WQE_SIGN_EN_LSB] = 1'b1;
    hdr[RDMA_SQ_WQE_SE_LSB] = wr.solicited &&
      (wr.opcode inside {RDMA_DRV_WR_SEND, RDMA_DRV_WR_SEND_IMM, RDMA_DRV_WR_SEND_INV,
                         RDMA_DRV_WR_WRITE_IMM});
    hdr[RDMA_SQ_WQE_INLINE_LOCAL_QPC_RD_LSB] = use_inline;
    hdr[RDMA_SQ_WQE_CE_LSB +: RDMA_SQ_WQE_CE_WIDTH] = ce;
    hdr[RDMA_SQ_WQE_VALID_LSB] = qp.sq_polarity;
    sign(wqe, hdr, sgb, use_sgb);
    status = qp.sq_kbuf.write(dev.hw, idx * RDMA_WQE_BYTES, wqe);
    if (!status.ok())
      return;
    qp.sq_wr_id[idx] = wr.wr_id;
    qp.sq_head++;
    qp.sq_ring_head[idx] = qp.sq_head;
    notify_sq_db(dev, qp, hdr, status);
  endtask

  // 功能：xtrdma_set_rc_wqe：按 opcode 写 RC 字段（长度/立即数、SGE 数、远端 VA/KEY、原子操作数）。
  // 输入/输出及副作用：修改 wqe。
  // 失败/边界：无。
  static function void fill_rc(inout rdma_bytes_t wqe, input rdma_drv_send_wr wr,
                               input int unsigned sge_num, input longint unsigned payload);
    if (wr.opcode inside {RDMA_DRV_WR_CAS, RDMA_DRV_WR_FAA}) begin
      if (wr.opcode == RDMA_DRV_WR_CAS) begin
        `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_CAS_CMP_DATA, wr.compare_add)
        `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_CAS_SWAP_DATA, wr.swap)
      end
      else begin
        `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_FAA_ADD_DATA, wr.compare_add)
      end
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_L_VA, wr.sges[0].addr)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_L_LEN, 8)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_L_KEY, wr.sges[0].lkey)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_R_VA, wr.remote_va)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_SGE_NUM, 1)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_ATOMIC_R_KEY, wr.rkey)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN, 8)
      return;
    end
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_TOTAL_PAYLOAD_LEN, payload)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_SGE_NUM, sge_num)
    if (wr.opcode inside {RDMA_DRV_WR_SEND_IMM, RDMA_DRV_WR_WRITE_IMM}) begin
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_IMMEDIATE, wr.imm)
    end
    if (wr.opcode inside {RDMA_DRV_WR_SEND_INV, RDMA_DRV_WR_LOCAL_INV}) begin
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_IMMEDIATE, wr.rkey)
    end
    if (wr.opcode inside {RDMA_DRV_WR_WRITE, RDMA_DRV_WR_WRITE_IMM, RDMA_DRV_WR_READ}) begin
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_REMOTE_KEY, wr.rkey)
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_REMOTE_VA, wr.remote_va)
    end
  endfunction

  // 功能：xtrdma_set_ud_wqe：目的 IP、hoplimit/DST_QPN/QKEY、PD、SGE 数/DMAC、长度与立即数。
  // 输入/输出及副作用：修改 wqe。
  // 失败/边界：无。
  static function void fill_ud(inout rdma_bytes_t wqe, input rdma_drv_qp qp,
                               input rdma_drv_send_wr wr, input int unsigned sge_num,
                               input longint unsigned payload);
    foreach (wr.dest_ip[i])
      wqe[48 + i] = wr.dest_ip[i];
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_HOPLIMIT, 255)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_DST_QPN, wr.dest_qpn)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_DST_Q_KEY, wr.qkey)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_PD_IDX, qp.pd.pd_id)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_SGE_NUM, sge_num)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_DMAC, wr.dmac)
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_UD_TOTAL_PAYLOAD_LEN, payload)
    if (wr.opcode == RDMA_DRV_WR_SEND_IMM) begin
      `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_RC_IMMEDIATE, wr.imm)
    end
  endfunction

  // 功能：xtrdma_calculate_wqe_signature：~(头 8B 异或 ^ WQE 8..63 异或 ^ SGB 有效部分异或)，
  //   写入 qword2 的 SIGNATURE（头也写入 wqe）。
  // 输入/输出及副作用：修改 wqe。
  // 失败/边界：无。
  static function void sign(inout rdma_bytes_t wqe, input bit [63:0] hdr, input rdma_bytes_t sgb,
                            input bit use_sgb);
    bit [7:0] sum;

    rdma_be::put_qword(wqe, 0, hdr);
    sum = rdma_be::xor_bytes(wqe);
    if (use_sgb)
      sum ^= rdma_be::xor_bytes(sgb);
    `RDMA_DRV_SET(wqe, RDMA_SQ_WQE_SIGNATURE, ~sum)
  endfunction

  // 功能：xtrdma_notify_sq_db：读 QP shadow（QPC+504）的 HW_DROP_DB_CNT[54:48]；(hw - sw) 的 bit6 为 0 时
  //   sw = hw+1 并把本 WQE 头写入 SQ doorbell，否则硬件仍在处理上次 doorbell，不再敲。
  // 输入/输出及副作用：读 shadow，可能写 doorbell。
  // 失败/边界：读写失败返回错误。
  static task notify_sq_db(rdma_drv_dev dev, rdma_drv_qp qp, bit [63:0] hdr,
                           output rdma_status status);
    bit [63:0] shadow;
    bit [7:0] hw_drop;

    status = dev.hw.read_qword(qp.ctx_page, qp.ctx_offset + rdma_drv_qp::SHADOW_OFFSET, shadow);
    if (!status.ok())
      return;
    hw_drop = shadow[54:48];
    if (((hw_drop - qp.sw_ring_db_cnt) & DB_CNT_SIGN_MASK) != 0)
      return;
    qp.sw_ring_db_cnt = hw_drop + 1;
    dev.hw.notify(RDMA_DB_SQ_OFFSET, hdr, status);
  endtask

  // 功能：xtrdma_post_recv（单个 WR）：RQE（SGE ≤2 在字节 32 起，否则 RQ SGB），首槽翻转 polarity，
  //   使用 SGB 时签名，写头；shadow（QPC+510）写 be16(PI|wrap<<15)，敲 RQ doorbell。
  // 输入/输出及副作用：写 RQ/SGB/shadow/doorbell；推进 rq_head。
  // 失败/边界：SGE 数越界返回 INVALID_ARGUMENT；环满返回 QUEUE_FULL。
  static task post_recv(rdma_drv_dev dev, rdma_drv_qp qp, rdma_drv_recv_wr wr,
                        output rdma_status status);
    rdma_bytes_t wqe;
    rdma_bytes_t data;
    rdma_bytes_t half;
    rdma_drv_dma sgb_page;
    int unsigned sgb_offset;
    bit [63:0] sgb_pa;
    bit [63:0] hdr;
    bit [63:0] db;
    int unsigned idx;
    int unsigned sge_num;
    longint unsigned payload;
    bit use_sgb;
    bit [15:0] pi;

    if (wr.sges.size() > qp.max_recv_sge) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "receive SGE count is invalid");
      return;
    end
    if (qp.rq_head - qp.rq_tail >= qp.rq_depth) begin
      status = rdma_status::make(RDMA_SC_QUEUE_FULL, "receive queue is full");
      return;
    end
    idx = qp.rq_head % qp.rq_depth;
    wqe = rdma_be::zeros(RDMA_RQE_BYTES);
    data = sge_descriptors(wr.sges);
    sge_num = data.size() / SGE_BYTES;
    payload = 0;
    foreach (wr.sges[i])
      payload += wr.sges[i].length;
    use_sgb = sge_num > S_SGE_MAX;
    status = rdma_status::success();
    if (use_sgb) begin
      sgb_pa = qp.sgb_addr(1'b1, idx, sgb_page, sgb_offset);
      `RDMA_DRV_SET(wqe, RDMA_RQE_SGB_PA, sgb_pa >> 9)
      status = dev.hw.write(sgb_page, sgb_offset, data);
      if (!status.ok())
        return;
    end
    else begin
      foreach (data[i])
        wqe[PAYLOAD_OFFSET + i] = data[i];
    end
    if (idx == 0)
      qp.rq_polarity = !qp.rq_polarity;
    `RDMA_DRV_SET(wqe, RDMA_RQE_PAYLOAD_LEN, payload)
    `RDMA_DRV_SET(wqe, RDMA_RQE_SGE_NUM, sge_num)
    hdr = '0;
    hdr[RDMA_RQE_QPN_LSB +: RDMA_RQE_QPN_WIDTH] = qp.qpn;
    hdr[RDMA_RQE_QP_SN_LSB +: RDMA_RQE_QP_SN_WIDTH] = qp.qp_sn;
    hdr[RDMA_RQE_OPCODE_LSB +: RDMA_RQE_OPCODE_WIDTH] = RQE_OPCODE;
    hdr[RDMA_RQE_INDEX_LSB +: RDMA_RQE_INDEX_WIDTH] = idx;
    hdr[RDMA_RQE_WRAP_LSB] = (qp.rq_head / qp.rq_depth) & 1;
    hdr[RDMA_RQE_SIGN_EN_LSB] = use_sgb;
    hdr[RDMA_RQE_VALID_LSB] = qp.rq_polarity;
    if (use_sgb)
      sign(wqe, hdr, data, 1'b1);
    else
      rdma_be::put_qword(wqe, 0, hdr);
    status = qp.rq_kbuf.write(dev.hw, idx * RDMA_RQE_BYTES, wqe);
    if (!status.ok())
      return;
    qp.rq_wr_id[idx] = wr.wr_id;
    qp.rq_head++;
    qp.rq_ring_head[idx] = qp.rq_head;
    pi = (qp.rq_head % qp.rq_depth) | (((qp.rq_head / qp.rq_depth) & 1) << 15);
    half = rdma_be::zeros(2);
    half[0] = pi[15:8];
    half[1] = pi[7:0];
    status = dev.hw.write(qp.ctx_page, qp.ctx_offset + rdma_drv_qp::SHADOW_OFFSET + 6, half);
    if (!status.ok())
      return;
    db = '0;
    db[RDMA_NOTIFY_RQ_QPN_LSB +: RDMA_NOTIFY_RQ_QPN_WIDTH] = qp.qpn;
    db[RDMA_NOTIFY_RQ_ICOS_LSB +: RDMA_NOTIFY_RQ_ICOS_WIDTH] = 3;
    db[RDMA_NOTIFY_RQ_PI_LSB +: RDMA_NOTIFY_RQ_PI_WIDTH] = pi[14:0];
    db[RDMA_NOTIFY_RQ_PI_WRAP_LSB] = pi[15];
    dev.hw.notify(RDMA_DB_RQ_OFFSET, db, status);
  endtask

  // 功能：xtrdma_post_srq_recv（单个 WR）：get_srq_wqe 从 next_slot 起轮转取空闲槽（bitmap），SGE
  //   写入 WQE 字节 32 起，+8 TPL，SRFQ 首槽翻转 polarity，头 QPN=SRQN|QP_SN|RQ_WQE|IDX=槽|WRAP|VALID，
  //   写入 SRQ 缓冲槽并复制到 SRFQ 环 PI 槽；PI++，shadow（context+28）写 be16(wrap<<15|PI)，
  //   敲 SRFQ doorbell（LIMIT_INVLD|WRAP|PI|SRFQN）。
  // 输入/输出及副作用：写 SRQ/SRFQ/shadow/doorbell；推进 pi。
  // 失败/边界：SGE>2（SRQ SGB）未建模返回 INVALID_ARGUMENT；SRFQ 或槽位满返回 QUEUE_FULL。
  static task post_srq_recv(rdma_drv_dev dev, rdma_drv_srq srq, rdma_drv_recv_wr wr,
                            output rdma_status status);
    rdma_bytes_t wqe;
    rdma_bytes_t data;
    rdma_bytes_t half;
    bit [63:0] hdr;
    bit [63:0] db;
    int unsigned idx;
    int unsigned slot;
    longint unsigned payload;
    bit [15:0] pi;
    bit found;

    data = sge_descriptors(wr.sges);
    if (data.size() / SGE_BYTES > S_SGE_MAX) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SRQ SGB is not modeled");
      return;
    end
    found = 1'b0;
    for (int unsigned k = 0; k < srq.depth && !found; k++) begin
      idx = (srq.next_slot + k) % srq.depth;
      found = !srq.slot_used[idx];
    end
    if (!found || srq.pi - srq.tail >= srq.depth) begin
      status = rdma_status::make(RDMA_SC_QUEUE_FULL, "shared receive queue is full");
      return;
    end
    srq.next_slot = (idx + 1) % srq.depth;
    wqe = rdma_be::zeros(RDMA_RQE_BYTES);
    foreach (data[i])
      wqe[PAYLOAD_OFFSET + i] = data[i];
    payload = 0;
    foreach (wr.sges[i])
      payload += wr.sges[i].length;
    slot = srq.pi % srq.depth;
    if (slot == 0)
      srq.polarity = !srq.polarity;
    `RDMA_DRV_SET(wqe, RDMA_RQE_PAYLOAD_LEN, payload)
    `RDMA_DRV_SET(wqe, RDMA_RQE_SGE_NUM, data.size() / SGE_BYTES)
    hdr = '0;
    hdr[RDMA_RQE_QPN_LSB +: RDMA_RQE_QPN_WIDTH] = srq.srqn;
    hdr[RDMA_RQE_QP_SN_LSB +: RDMA_RQE_QP_SN_WIDTH] = srq.srq_sn;
    hdr[RDMA_RQE_OPCODE_LSB +: RDMA_RQE_OPCODE_WIDTH] = RQE_OPCODE;
    hdr[RDMA_RQE_INDEX_LSB +: RDMA_RQE_INDEX_WIDTH] = idx;
    hdr[RDMA_RQE_WRAP_LSB] = (srq.pi / srq.depth) & 1;
    hdr[RDMA_RQE_VALID_LSB] = srq.polarity;
    rdma_be::put_qword(wqe, 0, hdr);
    status = srq.srq_kbuf.write(dev.hw, idx * RDMA_RQE_BYTES, wqe);
    if (status.ok())
      status = srq.srfq_kbuf.write(dev.hw, slot * RDMA_RQE_BYTES, wqe);
    if (!status.ok())
      return;
    srq.slot_used[idx] = 1'b1;
    srq.wr_ids[idx] = wr.wr_id;
    srq.pi++;
    pi = (srq.pi % srq.depth) | (((srq.pi / srq.depth) & 1) << 15);
    half = rdma_be::zeros(2);
    half[0] = pi[15:8];
    half[1] = pi[7:0];
    status = dev.hw.write(srq.ctx_page, srq.ctx_offset + rdma_drv_srq::SHADOW_OFFSET, half);
    if (!status.ok())
      return;
    db = '0;
    db[RDMA_NOTIFY_SRQ_LIMIT_INVALID_LSB] = 1'b1;
    db[RDMA_NOTIFY_SRFQ_WRAP_LSB] = pi[15];
    db[RDMA_NOTIFY_SRFQ_PI_LSB +: RDMA_NOTIFY_SRFQ_PI_WIDTH] = pi[14:0];
    db[RDMA_NOTIFY_SRFQN_LSB +: RDMA_NOTIFY_SRFQN_WIDTH] = srq.srqn;
    dev.hw.notify(RDMA_DB_SRFQ_OFFSET, db, status);
  endtask

  // 功能：xtrdma_ib_poll_cq（普通 CQ）：取 polarity 匹配的 32B CQE，按 QPN 找 QP，按 WQE_INDEX 回查
  //   wr_id 并把 SQ/RQ 尾推进到该 WR 之后，映射 ecode 到 WC 状态；推进 CQ 尾（回绕翻转 polarity 与
  //   ci_wrap），最后把 be32(ci_wrap<<23|CI) 写入 CQ shadow（CQC+52）。flush CQE（0x08/0x8F）按
  //   flush_err_prepare_fake_wc 为每个未完成 WQE 生成 FLUSH 完成，环空后跳过。
  // 输入/输出及副作用：wcs 追加完成；更新 QP/CQ 软件状态与 shadow。
  // 失败/边界：CQE 指向未知 QP 返回 INVALID_STATE；读写失败返回错误。
  static task poll_cq(rdma_drv_dev dev, rdma_drv_cq cq, int unsigned max_wc,
                      inout rdma_drv_wc wcs[$], output rdma_status status);
    rdma_bytes_t cqe;
    rdma_drv_wc wc;
    rdma_drv_qp qp;
    bit [7:0] ecode;
    int unsigned idx;
    int unsigned n;
    bit moved;
    bit move_ci;

    status = rdma_status::success();
    n = 0;
    moved = 1'b0;
    while (n < max_wc) begin
      status = cq.mem_kbuf.read(dev.hw, (cq.tail % cq.size) * rdma_drv_cq::CQE_BYTES,
                                rdma_drv_cq::CQE_BYTES, cqe);
      if (!status.ok())
        return;
      if (rdma_be::field(cqe, RDMA_CQE_POLARITY_WORD_BYTE_OFFSET, RDMA_CQE_POLARITY_LSB, 1) !=
          cq.polarity)
        break;
      wc = rdma_drv_wc::type_id::create("wc");
      wc.qpn = rdma_be::field(cqe, RDMA_CQE_QPN_WORD_BYTE_OFFSET, RDMA_CQE_QPN_LSB,
                              RDMA_CQE_QPN_WIDTH);
      if (!dev.qp_table.exists(wc.qpn)) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "CQE refers to an unknown QP");
        return;
      end
      qp = dev.qp_table[wc.qpn];
      idx = rdma_be::field(cqe, RDMA_CQE_WQE_INDEX_WORD_BYTE_OFFSET, RDMA_CQE_WQE_INDEX_LSB,
                           RDMA_CQE_WQE_INDEX_WIDTH);
      ecode = rdma_be::field(cqe, RDMA_CQE_ECODE_WORD_BYTE_OFFSET, RDMA_CQE_ECODE_LSB,
                             RDMA_CQE_ECODE_WIDTH);
      wc.is_recv = rdma_be::field(cqe, RDMA_CQE_RQ_CQE_WORD_BYTE_OFFSET, RDMA_CQE_RQ_CQE_LSB, 1);
      move_ci = 1'b1;
      if (ecode inside {RDMA_ECODE_XTRDMA_CQE_ECODE_SQ_FLUSH_ERR,
                        RDMA_ECODE_XTRDMA_CQE_ECODE_RQ_FLUSH_ERR}) begin
        // flush_err_prepare_fake_wc：环非空时以环当前 CI 为 WQE 下标且不推进 CQ（同一 flush CQE 为
        //   每个未完成 WQE 生成 WC）；环空（或 SRQ 接收）则跳过该 CQE。
        if (wc.is_recv && qp.srq == null && qp.rq_head != qp.rq_tail) begin
          idx = qp.rq_tail % qp.rq_depth;
          move_ci = 1'b0;
        end
        else if (!wc.is_recv && qp.sq_head != qp.sq_tail) begin
          idx = qp.sq_tail % qp.sq_depth;
          move_ci = 1'b0;
        end
        else begin
          cq.advance_tail();
          moved = 1'b1;
          continue;
        end
      end
      wc.pkt_opcode = rdma_be::field(cqe, RDMA_CQE_PKT_OPCODE_WORD_BYTE_OFFSET,
                                     RDMA_CQE_PKT_OPCODE_LSB, RDMA_CQE_PKT_OPCODE_WIDTH);
      wc.byte_len = rdma_be::field(cqe, RDMA_CQE_PAYLOAD_LEN_WORD_BYTE_OFFSET,
                                   RDMA_CQE_PAYLOAD_LEN_LSB, RDMA_CQE_PAYLOAD_LEN_WIDTH);
      wc.imm = rdma_be::field(cqe, RDMA_CQE_IMMDT_DATA_WORD_BYTE_OFFSET, RDMA_CQE_IMMDT_DATA_LSB,
                              RDMA_CQE_IMMDT_DATA_WIDTH);
      wc.src_qp = wc.qpn;
      if (qp.qp_type == RDMA_DRV_QPT_UD)
        wc.src_qp = rdma_be::field(cqe, RDMA_CQE_UD_SRC_QPN_WORD_BYTE_OFFSET,
                                   RDMA_CQE_UD_SRC_QPN_LSB, RDMA_CQE_UD_SRC_QPN_WIDTH);
      if (wc.is_recv &&
          rdma_be::field(cqe, RDMA_CQE_SRFQ_WORD_BYTE_OFFSET, RDMA_CQE_SRFQ_LSB, 1)) begin
        // SRQ：IDX 为 SRQ 槽位图下标；释放槽位并推进 SRFQ 消费者计数。
        wc.wr_id = qp.srq.wr_ids[idx % qp.srq.depth];
        qp.srq.slot_used[idx % qp.srq.depth] = 1'b0;
        qp.srq.tail++;
      end
      else if (wc.is_recv) begin
        wc.wr_id = qp.rq_wr_id[idx % qp.rq_depth];
        qp.rq_tail = qp.rq_ring_head[idx % qp.rq_depth];
      end
      else begin
        wc.wr_id = qp.sq_wr_id[idx % qp.sq_depth];
        qp.sq_tail = qp.sq_ring_head[idx % qp.sq_depth];
      end
      wc.vendor_err = ecode;
      wc.status = RDMA_DRV_WC_GENERAL_ERR;
      if (ecode inside {8'h00, 8'h01, 8'h78, 8'h80, 8'h81})
        wc.status = RDMA_DRV_WC_SUCCESS;
      else if (ecode inside {8'h08, 8'h8f})
        wc.status = RDMA_DRV_WC_FLUSH_ERR;
      else if (ecode == 8'hb9)
        wc.status = RDMA_DRV_WC_REM_INV_REQ_ERR;
      wcs.push_back(wc);
      n++;
      if (move_ci) begin
        cq.advance_tail();
        moved = 1'b1;
      end
    end
    if (moved)
      status = cq.update_shadow_ci(dev);
  endtask

  // 功能：xtrdma_process_ceq：取有效 CEQE（bit63 与当前圈 polarity 一致），记录 CQN 并递增该 CQ 的
  //   arm_sn（ce_handler），推进 CI（回绕翻转），每条敲 CEQ doorbell（CI_WRAP|CI|CEQN）。
  // 输入/输出及副作用：cqns 追加完成通知的 CQN；更新 EQ/CQ 软件状态与 doorbell。
  // 失败/边界：读写失败返回错误。
  static task process_ceq(rdma_drv_dev dev, rdma_drv_eq eq, inout int unsigned cqns[$],
                          output rdma_status status);
    rdma_bytes_t ceqe;
    int unsigned cqn;

    status = rdma_status::success();
    forever begin
      status = eq.mem_kbuf.read(dev.hw, (eq.tail % eq.entries) * RDMA_CEQE_BYTES,
                                RDMA_CEQE_BYTES, ceqe);
      if (!status.ok() || ceqe[0][7] != eq.polarity)
        return;
      cqn = rdma_be::field(ceqe, RDMA_CEQE_CQN_WORD_BYTE_OFFSET, RDMA_CEQE_CQN_LSB,
                           RDMA_CEQE_CQN_WIDTH);
      cqns.push_back(cqn);
      if (dev.cq_table.exists(cqn))
        dev.cq_table[cqn].arm_sn++;
      eq.tail++;
      if (eq.tail % eq.entries == 0)
        eq.polarity = !eq.polarity;
      eq.ack(dev.hw, status);
      if (!status.ok())
        return;
    end
  endtask

  // 功能：xtrdma_process_aeq：取有效 AEQE，记录 {ECODE, QPN}（SRFQ 事件记录 SRFQN），推进 CI 并敲
  //   AEQ doorbell。
  // 输入/输出及副作用：events 追加 {ecode[7:0], qpn 或 srqn[23:0]}；更新 EQ 状态与 doorbell。
  // 失败/边界：读写失败返回错误。
  static task process_aeq(rdma_drv_dev dev, inout bit [31:0] events[$],
                          output rdma_status status);
    rdma_bytes_t aeqe;
    rdma_drv_eq eq;
    bit [63:0] word0;
    bit [63:0] db;

    eq = dev.aeq;
    status = rdma_status::success();
    forever begin
      status = eq.mem_kbuf.read(dev.hw, (eq.tail % eq.entries) * RDMA_AEQE_BYTES,
                                RDMA_AEQE_BYTES, aeqe);
      if (!status.ok() || aeqe[0][7] != eq.polarity)
        return;
      word0 = rdma_be::qword(aeqe, 0);
      if (rdma_be::field(aeqe, RDMA_AEQE_SRFQ_EN_WORD_BYTE_OFFSET, RDMA_AEQE_SRFQ_EN_LSB, 1))
        events.push_back({word0[31:24], 12'b0,
                          12'(rdma_be::field(aeqe, RDMA_AEQE_SRFQN_WORD_BYTE_OFFSET,
                                             RDMA_AEQE_SRFQN_LSB, RDMA_AEQE_SRFQN_WIDTH))});
      else
        events.push_back({word0[31:24], 6'b0, word0[17:0]});
      eq.tail++;
      if (eq.tail % eq.entries == 0)
        eq.polarity = !eq.polarity;
      db = '0;
      db[RDMA_NOTIFY_AEQ_CI_WRAP_LSB] = (eq.tail / eq.entries) & 1;
      db[RDMA_NOTIFY_AEQ_CI_LSB +: RDMA_NOTIFY_AEQ_CI_WIDTH] = eq.tail % eq.entries;
      db[RDMA_NOTIFY_AEQ_AEQN_LSB +: RDMA_NOTIFY_AEQ_AEQN_WIDTH] = eq.eqn;
      dev.hw.notify(RDMA_DB_AEQ_OFFSET, db, status);
      if (!status.ok())
        return;
    end
  endtask
endclass
