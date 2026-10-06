// 目录：驱动层 src/drv/rdma_drv_qp.sv。
// 职责：qp.c 内核态 QP 控制路径：create（QPN/qp_sn、SQ/RQ/SGB 缓冲、ORQ/EIRQ/UAQ、HMC QPC 槽与 shadow、
//   512B QPC 镜像、签名 QPC_CREATE）、modify（属性写入 QPC 镜像；INIT→RTR、RTR→RTS 全量签名修改，
//   其余仅状态修改；RTS↔SQD 与转 ERR 的 doorbell）、destroy（转 ERR、OCC flush、QPC_DELETE、释放）。
//   URC 与 rc_to_urc 转换未建模。数据路径在 rdma_drv_wr.sv。
// 依赖：rdma_drv_dev、rdma_drv_cq/srq/pd、rdma_drv_kbuf、rdma_defs.svh。
// 所有权与生命周期：QP 拥有其缓冲与 QPN，destroy 释放；CQ/SRQ/PD 只借用。

typedef enum int {
  RDMA_DRV_QPT_RC,
  RDMA_DRV_QPT_UD
} rdma_drv_qp_type_e;

// IB QP 状态（ib_qp_state 顺序）。
typedef enum int {
  RDMA_DRV_QPS_RESET,
  RDMA_DRV_QPS_INIT,
  RDMA_DRV_QPS_RTR,
  RDMA_DRV_QPS_RTS,
  RDMA_DRV_QPS_SQD,
  RDMA_DRV_QPS_SQE,
  RDMA_DRV_QPS_ERR
} rdma_drv_qp_state_e;

class rdma_drv_qp_init_attr extends uvm_object;
  `rdma_object_utils(rdma_drv_qp_init_attr)

  rdma_drv_qp_type_e qp_type;
  rdma_drv_pd pd;
  rdma_drv_cq send_cq;
  rdma_drv_cq recv_cq;
  rdma_drv_srq srq;
  int unsigned max_send_wr;
  int unsigned max_recv_wr;
  int unsigned max_send_sge;
  int unsigned max_recv_sge;
  int unsigned max_inline;
  bit sig_all;

  // 功能：以 RC、单 SGE、无 inline 的默认值构造。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_qp_init_attr");
    super.new(name);
    qp_type = RDMA_DRV_QPT_RC;
    pd = null;
    send_cq = null;
    recv_cq = null;
    srq = null;
    max_send_wr = 256;
    max_recv_wr = 256;
    max_send_sge = 1;
    max_recv_sge = 1;
    max_inline = 0;
    sig_all = 1'b0;
  endfunction
endclass

// ib_qp_attr 的子集；mask 位对应 IB_QP_* 属性。
class rdma_drv_qp_attr extends uvm_object;
  `rdma_object_utils(rdma_drv_qp_attr)

  localparam int unsigned M_STATE = 1 << 0;
  localparam int unsigned M_ACCESS = 1 << 3;
  localparam int unsigned M_QKEY = 1 << 5;
  localparam int unsigned M_AV = 1 << 7;
  localparam int unsigned M_PATH_MTU = 1 << 8;
  localparam int unsigned M_TIMEOUT = 1 << 9;
  localparam int unsigned M_RETRY_CNT = 1 << 10;
  localparam int unsigned M_RNR_RETRY = 1 << 11;
  localparam int unsigned M_RQ_PSN = 1 << 12;
  localparam int unsigned M_MAX_RD_ATOMIC = 1 << 13;
  localparam int unsigned M_MIN_RNR = 1 << 15;
  localparam int unsigned M_SQ_PSN = 1 << 16;
  localparam int unsigned M_DEST_QPN = 1 << 20;

  int unsigned mask;
  rdma_drv_qp_state_e state;
  bit [4:0] access;
  bit [31:0] qkey;
  int unsigned path_mtu;
  int unsigned timeout;
  int unsigned retry_cnt;
  int unsigned rnr_retry;
  int unsigned min_rnr;
  int unsigned max_rd_atomic;
  bit [23:0] rq_psn;
  bit [23:0] sq_psn;
  bit [23:0] dest_qpn;
  bit [47:0] dmac;
  byte unsigned dest_ip[16];

  // 功能：构造空属性（mask=0）。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_qp_attr");
    super.new(name);
    mask = 0;
    path_mtu = 4096;
  endfunction
endclass

class rdma_drv_qp extends uvm_object;
  `rdma_object_utils(rdma_drv_qp)

  localparam int unsigned MIN_WR = 256;
  localparam int unsigned MAX_WR = 32768;
  // xtrdma_hw.h XTRDMA_MIN_URC_QP_ENTRIES；qp.h XTRDMA_SERVICE_TYPE_URC。
  localparam int unsigned MIN_URC_WR = 8;
  localparam int unsigned SERVICE_URC = 6;
  localparam int unsigned SGB_BYTES = 512;
  // rf->urc_rnr_code 默认值（qp.h:139，debugfs 可调未建模）。
  localparam int unsigned URC_RNR_CODE = 8;
  localparam int unsigned SHADOW_OFFSET = 504;
  localparam int unsigned SERVICE_RC = 0;
  localparam int unsigned SERVICE_UD = 3;

  rdma_drv_qp_type_e qp_type;
  int unsigned qpn;
  bit [7:0] qp_sn;
  rdma_drv_qp_state_e cur_state;
  rdma_drv_pd pd;
  rdma_drv_cq send_cq;
  rdma_drv_cq recv_cq;
  rdma_drv_srq srq;
  bit sig_all;
  // URC（cfg.rc_to_urc 下由 RC 转来；ibqp 类型仍为 RC）：send_cq/recv_cq 换成 frag CQ，
  //   orig_* 为用户给的原始 CQ。
  bit urc;
  rdma_drv_cq orig_send_cq;
  rdma_drv_cq orig_recv_cq;
  int unsigned max_send_sge;
  int unsigned max_recv_sge;
  int unsigned max_inline;
  int unsigned sgb_shift;
  int unsigned sq_depth;
  int unsigned rq_depth;
  rdma_drv_kbuf sq_kbuf;
  rdma_drv_kbuf rq_kbuf;
  rdma_drv_dma sq_sgb[$];
  rdma_drv_dma rq_sgb[$];
  // UAQ（全部类型），RC 另有 ORQ、EIRQ、EIRQ_EXTRA（依次为 [1]、[2]、[3]）。
  rdma_drv_dma side_bufs[$];
  rdma_drv_dma ctx_page;
  int unsigned ctx_offset;
  rdma_bytes_t qpc;
  // 数据路径状态（wr.c）：环头尾、polarity、doorbell 计数、wr_id 与完成后环头。
  longint unsigned sq_head;
  longint unsigned sq_tail;
  bit sq_polarity;
  bit [6:0] sw_ring_db_cnt;
  longint unsigned rq_head;
  longint unsigned rq_tail;
  bit rq_polarity;
  longint unsigned sq_wr_id[];
  longint unsigned sq_ring_head[];
  longint unsigned rq_wr_id[];
  longint unsigned rq_ring_head[];

  // 功能：构造 QP。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_qp");
    super.new(name);
    cur_state = RDMA_DRV_QPS_RESET;
    sq_kbuf = null;
    rq_kbuf = null;
    ctx_page = null;
    sq_head = 0;
    sq_tail = 0;
    sq_polarity = 1'b0;
    sw_ring_db_cnt = '0;
    rq_head = 0;
    rq_tail = 0;
    rq_polarity = 1'b0;
  endfunction

  // 功能：QPC 中的 qp_st 编码（INIT1、RTR2、RTS3、ERR4、SQD/SQE5）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：RESET 编码为 0。
  static function int unsigned qpc_state(rdma_drv_qp_state_e s);
    case (s)
      RDMA_DRV_QPS_INIT: return 1;
      RDMA_DRV_QPS_RTR: return 2;
      RDMA_DRV_QPS_RTS: return 3;
      RDMA_DRV_QPS_ERR: return 4;
      RDMA_DRV_QPS_SQD, RDMA_DRV_QPS_SQE: return 5;
      default: return 0;
    endcase
  endfunction

  // 功能：MTU 字节数 → xtrdma_mtu 编码（256→0 … 4096→4）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：非 2 的幂按向上取整。
  static function int unsigned mtu_code(int unsigned mtu);
    return $clog2(mtu) - 8;
  endfunction

  // 功能：xtrdma_ib_create_qp（内核 RC/UD；cfg.rc_to_urc 时 RC 转 URC）：参数检查与深度取整，
  //   alloc_qpn，URC 先换 frag CQ，SQ/RQ（偏好大页）与 SGB 页，RC 的 ORQ/EIRQ/EIRQ_EXTRA（URC 为
  //   RSQ/RDSQ/DSQ）与 UAQ 页，HMC QPC 槽（shadow 在 +504），填 QPC 镜像，URC 先 CQC_MODIFY 置 URC
  //   标志，签名 QPC_CREATE，URC 记录 frag 信息。失败按 goto 链逆序释放。
  // 输入/输出及副作用：分配资源并下发命令；qp 输出。
  // 失败/边界：参数越界返回 INVALID_ARGUMENT；资源用尽或命令失败返回其错误。
  static task create_qp(rdma_drv_dev dev, rdma_drv_qp_init_attr attr, output rdma_drv_qp qp,
                     output rdma_status status);
    qp = rdma_drv_qp::type_id::create("qp");
    if (attr.max_send_sge > 32 || attr.max_recv_sge > 32 || attr.max_inline > 512 ||
        attr.max_send_wr > MAX_WR || attr.max_recv_wr > MAX_WR || attr.pd == null ||
        attr.send_cq == null || attr.recv_cq == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "QP create attributes are invalid");
      return;
    end
    qp.qp_type = attr.qp_type;
    qp.urc = dev.cfg.rc_to_urc && attr.qp_type == RDMA_DRV_QPT_RC;
    if (qp.urc && attr.srq != null) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "URC QP does not support SRQ");
      return;
    end
    qp.pd = attr.pd;
    qp.send_cq = attr.send_cq;
    qp.recv_cq = attr.recv_cq;
    qp.srq = attr.srq;
    qp.sig_all = attr.sig_all;
    qp.max_send_sge = attr.max_send_sge;
    qp.max_recv_sge = attr.max_recv_sge;
    qp.max_inline = attr.max_inline;
    qp.sq_depth = round_depth(attr.max_send_wr, qp.urc);
    qp.rq_depth = round_depth(attr.max_recv_wr, qp.urc);
    qp.sgb_shift = 0;
    if (attr.qp_type == RDMA_DRV_QPT_UD || attr.max_send_sge > 2 || attr.max_recv_sge > 2)
      qp.sgb_shift = 9;
    if (!dev.qp_ids.alloc_next(qp.qpn)) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "QP numbers are exhausted");
      return;
    end
    if (!dev.qp_sn.exists(qp.qpn))
      dev.qp_sn[qp.qpn] = 0;
    qp.qp_sn = dev.qp_sn[qp.qpn]++;
    status = rdma_status::success();
    if (qp.urc)
      qp.make_frags(dev, status);
    if (status.ok())
      status = qp.alloc_buffers(dev);
    if (status.ok()) begin
      void'(dev.hmc[rdma_drv_dev::HMC_QPC].locate(qp.qpn, qp.ctx_page, qp.ctx_offset));
      status = dev.hw.write(qp.ctx_page, qp.ctx_offset, rdma_be::zeros(RDMA_QPC_BYTES));
    end
    if (status.ok()) begin
      qp.fill_qpc(dev);
      if (qp.urc)
        qp.set_cqc_urc(dev, 1'b1, status);
      if (status.ok())
        qp.hw_qpc_cmd(dev, RDMA_OP_QPC_CREATE, 1'b1, status);
    end
    if (!status.ok()) begin
      qp.free_buffers(dev);
      if (qp.urc)
        qp.drop_frags(dev);
      dev.qp_ids.free(qp.qpn);
      return;
    end
    if (qp.urc)
      qp.set_urc_info();
    qp.sq_wr_id = new[qp.sq_depth];
    qp.sq_ring_head = new[qp.sq_depth];
    qp.rq_wr_id = new[qp.rq_depth];
    qp.rq_ring_head = new[qp.rq_depth];
    dev.qp_table[qp.qpn] = qp;
  endtask

  // 功能：xtrdma_set_qp_param：clamp(wr, 256（URC 为 8）, 32768) 后取 2 的幂。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function int unsigned round_depth(int unsigned wr, bit urc = 1'b0);
    if (!urc && wr < MIN_WR)
      wr = MIN_WR;
    if (urc && wr < MIN_URC_WR)
      wr = MIN_URC_WR;
    return 1 << $clog2(wr);
  endfunction

  // 功能：xtrdma_qp_urc_shared_cq_process：同一 CQ 时取一个 sq+rq 槽的 frag，否则发送 CQ 取 sq 槽、
  //   接收 CQ 取 rq 槽各一个 frag；QP 的 send_cq/recv_cq 换成 frag。
  // 输入/输出及副作用：创建 frag CQ。
  // 失败/边界：失败回退已建 frag 并恢复原始 CQ。
  protected task make_frags(rdma_drv_dev dev, output rdma_status status);
    rdma_drv_cq frag;
    rdma_status ignored;

    orig_send_cq = send_cq;
    orig_recv_cq = recv_cq;
    if (send_cq == recv_cq) begin
      orig_send_cq.create_frag(dev, sq_depth + rq_depth, frag, status);
      if (!status.ok())
        return;
      send_cq = frag;
      recv_cq = frag;
      return;
    end
    orig_send_cq.create_frag(dev, sq_depth, frag, status);
    if (!status.ok())
      return;
    send_cq = frag;
    orig_recv_cq.create_frag(dev, rq_depth, frag, status);
    if (!status.ok()) begin
      send_cq.destroy_frag(dev, ignored);
      send_cq = orig_send_cq;
      return;
    end
    recv_cq = frag;
  endtask

  // 功能：销毁 frag CQ 并恢复原始 CQ（创建失败与 destroy 共用）。
  // 输入/输出及副作用：下发 CQC_DELETE。
  // 失败/边界：命令错误忽略。
  protected task drop_frags(rdma_drv_dev dev);
    rdma_status ignored;

    if (send_cq != null && send_cq.original != null)
      send_cq.destroy_frag(dev, ignored);
    if (recv_cq != null && recv_cq != send_cq && recv_cq.original != null)
      recv_cq.destroy_frag(dev, ignored);
    send_cq = orig_send_cq;
    recv_cq = orig_recv_cq;
  endtask

  // 功能：xtrdma_qp_set_cqc_urc_flag / clear_cqc_urc_flag：同一 frag 一条 CQC_MODIFY（SQ/RQ CEQE 均
  //   有效，带 SQ/RQ 尺寸）；不同 frag 时发送侧 {SQ CEQE, sq 尺寸}、接收侧 {RQ CEQE, rq 尺寸}，
  //   接收侧失败回退发送侧。清除时全部为 0。
  // 输入/输出及副作用：下发命令。
  // 失败/边界：命令失败返回错误。
  protected task set_cqc_urc(rdma_drv_dev dev, bit set, output rdma_status status);
    rdma_status ignored;
    int unsigned sq_log;
    int unsigned rq_log;

    sq_log = set ? $clog2(sq_depth) : 0;
    rq_log = set ? $clog2(rq_depth) : 0;
    if (send_cq == recv_cq) begin
      send_cq.modify_urc(dev, set, set, set, sq_log, rq_log, status);
      return;
    end
    send_cq.modify_urc(dev, set, set, 1'b0, sq_log, 0, status);
    if (!status.ok())
      return;
    recv_cq.modify_urc(dev, set, 1'b0, set, 0, rq_log, status);
    if (!status.ok() && set)
      send_cq.modify_urc(dev, 1'b0, 1'b0, 1'b0, 0, 0, ignored);
  endtask

  // 功能：xtrdma_qp_set_urc_info：frag 记录本 QP 的 QPN 与方向，send/recv 环大小取 SQ/RQ 深度。
  // 输入/输出及副作用：修改 frag CQ 软件状态。
  // 失败/边界：无。
  protected function void set_urc_info();
    send_cq.send_flag = 1'b1;
    send_cq.send_qpn = qpn;
    send_cq.send_size = sq_depth;
    send_cq.send_tail = 0;
    recv_cq.recv_flag = 1'b1;
    recv_cq.recv_qpn = qpn;
    recv_cq.recv_size = rq_depth;
    recv_cq.recv_tail = 0;
    recv_cq.recv_vld = 1'b1;
  endfunction

  // 功能：xtrdma_create_qp_kernel + set_qpc_basic_param 的缓冲：SQ/RQ = depth*64B（偏好大页），
  //   有 SGB 时每队列 depth*512B（4KiB 页，8 槽一页），RC 另有 ORQ/EIRQ/EIRQ_EXTRA，全部有 UAQ。
  // 输入/输出及副作用：分配 DMA。
  // 失败/边界：任一失败返回错误（由调用方 free_buffers）。
  protected function rdma_status alloc_buffers(rdma_drv_dev dev);
    rdma_drv_dma page;
    rdma_status status;
    int unsigned side;

    sq_kbuf = rdma_drv_kbuf::type_id::create("sq_buf");
    status = sq_kbuf.alloc(dev.hw, sq_depth * RDMA_WQE_BYTES, 1'b1, dev.cfg.vf_id);
    if (status.ok() && srq == null) begin
      rq_kbuf = rdma_drv_kbuf::type_id::create("rq_buf");
      status = rq_kbuf.alloc(dev.hw, rq_depth * RDMA_RQE_BYTES, 1'b1, dev.cfg.vf_id);
    end
    for (int unsigned i = 0; status.ok() && sgb_shift != 0 && i < sq_depth / 8; i++) begin
      status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        sq_sgb.push_back(page);
    end
    for (int unsigned i = 0; status.ok() && sgb_shift != 0 && srq == null && i < rq_depth / 8;
         i++) begin
      status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        rq_sgb.push_back(page);
    end
    // RC：UAQ、ORQ、EIRQ、EIRQ_EXTRA；URC：UAQ、RSQ、RDSQ（各 4KiB）与 DSQ（8KiB）；UD：UAQ。
    side = 1;
    if (qp_type == RDMA_DRV_QPT_RC)
      side = urc ? 3 : 4;
    for (int unsigned i = 0; status.ok() && i < side; i++) begin
      status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        side_bufs.push_back(page);
    end
    if (status.ok() && urc) begin
      status = dev.hw.alloc_dma(2 * RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        side_bufs.push_back(page);
    end
    return status;
  endfunction

  // 功能：释放全部缓冲。
  // 输入/输出及副作用：释放 DMA。
  // 失败/边界：未分配部分跳过。
  protected function void free_buffers(rdma_drv_dev dev);
    if (sq_kbuf != null)
      void'(sq_kbuf.free(dev.hw));
    if (rq_kbuf != null)
      void'(rq_kbuf.free(dev.hw));
    foreach (sq_sgb[i])
      void'(dev.hw.free_dma(sq_sgb[i]));
    foreach (rq_sgb[i])
      void'(dev.hw.free_dma(rq_sgb[i]));
    foreach (side_bufs[i])
      void'(dev.hw.free_dma(side_bufs[i]));
    sq_sgb.delete();
    rq_sgb.delete();
    side_bufs.delete();
  endfunction

  // 功能：SGB 槽地址（xtrdma_kernel_get_sgb_addr）：page[i/8] + (i%8)*512。
  // 输入/输出及副作用：page/offset 输出。
  // 失败/边界：无 SGB 返回 0 且 page 为 null。
  function bit [63:0] sgb_addr(bit rq, int unsigned idx, output rdma_drv_dma page,
                               output int unsigned offset);
    page = null;
    offset = (idx % 8) * SGB_BYTES;
    if (rq && rq_sgb.size() != 0)
      page = rq_sgb[idx / 8];
    if (!rq && sq_sgb.size() != 0)
      page = sq_sgb[idx / 8];
    if (page == null)
      return 64'h0;
    return page.iova + offset;
  endfunction

  // 功能：xtrdma_fill_rc_ud_qpc_info 的 create 初值：服务类型、身份、shadow 地址、端序/fence、
  //   ORQ/EIRQ/UAQ 与大小、INIT 状态、PMTU、重试门限、PD/SRQ、DSCP/ECN/hoplimit/UDP 源端口、
  //   SQ/RQ PBA/大小/OM、CQN。
  // 输入/输出及副作用：重建 qpc 镜像。
  // 失败/边界：无。
  protected function void fill_qpc(rdma_drv_dev dev);
    bit [63:0] orq;

    qpc = rdma_be::zeros(RDMA_QPC_BYTES);
    `RDMA_DRV_SET(qpc, RDMA_QPC_HOST_ID, dev.cfg.host_id)
    `RDMA_DRV_SET(qpc, RDMA_QPC_VF_ID, dev.cfg.vf_id)
    `RDMA_DRV_SET(qpc, RDMA_QPC_ICOS, 3)
    `RDMA_DRV_SET(qpc, RDMA_QPC_QPN, qpn)
    `RDMA_DRV_SET(qpc, RDMA_QPC_PKEY, 16'hffff)
    if (urc) begin
      fill_urc_qpc();
    end
    else if (qp_type == RDMA_DRV_QPT_RC) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_SERVICE_TYPE, SERVICE_RC)
      orq = side_bufs[1].iova >> 12;
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_ORQ_PBA_H, orq >> 48)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_ORQ_PBA_L, orq)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_ORQ_SIZE, 6)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_EIRQ_PBA, side_bufs[2].iova >> 12)
      `RDMA_DRV_SET(qpc, RDMA_QPC_EIRQ_PBA_EXTRA, side_bufs[3].iova >> 12)
      `RDMA_DRV_SET(qpc, RDMA_QPC_FC_EN, 1)
      `RDMA_DRV_SET(qpc, RDMA_QPC_ECN, 2)
    end
    else begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_SERVICE_TYPE, SERVICE_UD)
    end
    `RDMA_DRV_SET(qpc, RDMA_QPC_SHADOW_PBA, (ctx_page.iova + ctx_offset) >> 9)
    `RDMA_DRV_SET(qpc, RDMA_QPC_TX_ENDIAN_SWAP, 1)
    `RDMA_DRV_SET(qpc, RDMA_QPC_RX_ENDIAN_SWAP, 1)
    `RDMA_DRV_SET(qpc, RDMA_QPC_SQ_CE_EN, sig_all)
    `RDMA_DRV_SET(qpc, RDMA_QPC_RA_FENCE, 1)
    `RDMA_DRV_SET(qpc, RDMA_QPC_AA_FENCE, 1)
    `RDMA_DRV_SET(qpc, RDMA_QPC_QP_ST, qpc_state(RDMA_DRV_QPS_INIT))
    `RDMA_DRV_SET(qpc, RDMA_QPC_PMTU, mtu_code(4096))
    `RDMA_DRV_SET(qpc, RDMA_QPC_RNR_RETRY_TH, 6)
    `RDMA_DRV_SET(qpc, RDMA_QPC_QP_SN, qp_sn)
    `RDMA_DRV_SET(qpc, RDMA_QPC_PD_IDX, pd.pd_id)
    if (srq != null) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_SRFQ, 1)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_SRFQN, srq.srqn)
    end
    if (!urc) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_IRQ_SIZE, 7)
      `RDMA_DRV_SET(qpc, RDMA_QPC_UAQ_IRQ_PBA, side_bufs[0].iova >> 12)
    end
    `RDMA_DRV_SET(qpc, RDMA_QPC_UAQ_SIZE, 7)
    `RDMA_DRV_SET(qpc, RDMA_QPC_PSN_RETRY_TH, 6)
    `RDMA_DRV_SET(qpc, RDMA_QPC_ACK_REQ_TH, 3)
    `RDMA_DRV_SET(qpc, RDMA_QPC_DSCP, 6'h18)
    `RDMA_DRV_SET(qpc, RDMA_QPC_HOPLIMIT, 255)
    `RDMA_DRV_SET(qpc, RDMA_QPC_CUR_UDP_SPORT, 16'hc000 | 16'($urandom_range(0, 16'h3fff)))
    `RDMA_DRV_SET(qpc, RDMA_QPC_SQ_PBA, sq_kbuf.base_iova() >> 12)
    `RDMA_DRV_SET(qpc, RDMA_QPC_SQ_SIZE, $clog2(sq_depth))
    `RDMA_DRV_SET(qpc, RDMA_QPC_SQ_OM, sq_kbuf.alloc_type)
    if (srq == null) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_PBA, rq_kbuf.base_iova() >> 12)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_SIZE, $clog2(rq_depth))
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_OM, rq_kbuf.alloc_type)
    end
    else begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_PBA, srq.srq_kbuf.base_iova() >> 12)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_SIZE, $clog2(srq.depth))
      `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_OM, srq.srq_kbuf.alloc_type)
    end
    `RDMA_DRV_SET(qpc, RDMA_QPC_SQ_CQN, send_cq.cqn)
    `RDMA_DRV_SET(qpc, RDMA_QPC_RQ_CQN, recv_cq.cqn)
    `RDMA_DRV_SET(qpc, RDMA_QPC_LOAD_RQ_PI_TH, 8'h05)
  endfunction

  // 功能：fill_urc_qpc_info 中与 RC 不同的部分（qp.c:1226）：服务类型 6，RSQ/RDSQ/DSQ 地址与大小，
  //   RBSN/RPSN 初值 0x1000、DBSN/DPSN 初值 0，RDSQ/DSQ 预取数 8，LOCAL_RNR_CODE = urc_rnr_code，
  //   SQ CE/RQ SE 门限，FC/ECN 同 RC；不写 ORQ/EIRQ/UAQ_IRQ 地址。
  // 输入/输出及副作用：修改 qpc 镜像。
  // 失败/边界：无。
  protected function void fill_urc_qpc();
    bit [63:0] rsq;
    bit [63:0] dsq;

    `RDMA_DRV_SET(qpc, RDMA_QPC_SERVICE_TYPE, SERVICE_URC)
    rsq = side_bufs[1].iova >> 12;
    dsq = side_bufs[3].iova >> 12;
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RSQ_PBA_H, rsq >> 48)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RSQ_PBA_L, rsq)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RSQ_SIZE, 6)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RDSQ_PBA, side_bufs[2].iova >> 12)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RDSQ_SIZE, 6)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_TX_RBSN, 24'h1000)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RX_RBSN, 24'h1000)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_CUR_TX_RPSN, 24'h1000)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_TPE_RPSN_MAX, 24'h1000)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_NXT_RDSQ_FETCH_NUM, 8)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_NXT_DSQ_FETCH_NUM, 8)
    `RDMA_DRV_SET(qpc, RDMA_QPC_LOCAL_RNR_CODE, URC_RNR_CODE)
    if (rq_depth >= 8) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_URC_RQ_SE_TH, $clog2(rq_depth >> 3))
    end
    if (!sig_all && sq_depth >= 8) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_URC_SQ_CE_TH, $clog2(sq_depth >> 3))
    end
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_CUR_DSQ_PBA_H, dsq >> 12)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_CUR_DSQ_PBA_L, dsq)
    `RDMA_DRV_SET(qpc, RDMA_QPC_URC_NXT_DSQ_PBA, (side_bufs[3].iova + RDMA_HMC_PAGE_BYTES) >> 12)
    `RDMA_DRV_SET(qpc, RDMA_QPC_FC_EN, 1)
    `RDMA_DRV_SET(qpc, RDMA_QPC_ECN, 2)
  endfunction

  // 功能：QPC_CREATE / QPC_MODIFY / QPC_DELETE：SQE 带 QPN 与 CQN；full 时 QPC 镜像写入 4KiB cmdq
  //   缓冲，SQE 带缓冲地址（>>9）与 QPC 签名；仅状态修改与删除不带缓冲与签名。
  // 输入/输出及副作用：分配并释放 cmdq 缓冲，下发命令。
  // 失败/边界：分配或命令失败返回错误。
  protected task hw_qpc_cmd(rdma_drv_dev dev, bit [7:0] opcode, bit full,
                            output rdma_status status);
    rdma_drv_dma cmd_buf;
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;

    cmd_buf = null;
    sqe = rdma_drv_cmq::new_sqe(opcode);
    `RDMA_DRV_SET(sqe, RDMA_CMQ_QPN, qpn)
    `RDMA_DRV_SET(sqe, RDMA_CMQ_SQ_CQN, send_cq.cqn)
    `RDMA_DRV_SET(sqe, RDMA_CMQ_RQ_CQN, recv_cq.cqn)
    if (opcode == RDMA_OP_QPC_MODIFY) begin
      `RDMA_DRV_SET(sqe, RDMA_CMQ_NEXT_QP_STATE,
                    rdma_be::field(qpc, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                                   RDMA_QPC_QP_ST_WIDTH))
      if (full) begin
        `RDMA_DRV_SET(sqe, RDMA_CMQ_MODIFY_MODE, RDMA_QPC_MODIFY_FULL)
        // qp.c:2625 URC 的全量修改带 WBE 模板 1（XTRDMA_WBE_URC）。
        `RDMA_DRV_SET(sqe, RDMA_CMQ_WBE_TPL_NUM, urc)
      end
    end
    if (!full) begin
      dev.cmq.exec(sqe, cqe, status);
      return;
    end
    status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, cmd_buf);
    if (status.ok())
      status = dev.hw.write(cmd_buf, 0, qpc);
    if (status.ok()) begin
      `RDMA_DRV_SET(sqe, RDMA_CMQ_QPC_BUFFER_ADDR, cmd_buf.iova >> RDMA_CMQ_QPC_BUFFER_ADDR_LSB)
      dev.cmq.exec_signed(sqe, 1'b1, qpc, cqe, status);
    end
    void'(dev.hw.free_dma(cmd_buf));
  endtask

  // 功能：xtrdma_ib_modify_qp：update_qp_context 把属性写入 QPC 镜像；目标状态不是 INIT 时
  //   hw_modify_qp（INIT→RTR、RTR→RTS 全量签名，其余仅状态），RTS→SQD/SQD→RTS 敲对应 doorbell，
  //   转 ERR 敲 QP flush doorbell。
  // 输入/输出及副作用：修改 QPC 镜像，下发命令与 doorbell，更新 cur_state。
  // 失败/边界：非法状态迁移返回 INVALID_ARGUMENT；命令失败返回其错误且不更新 cur_state。
  task modify(rdma_drv_dev dev, rdma_drv_qp_attr attr, output rdma_status status);
    rdma_drv_qp_state_e next;
    bit full;

    next = cur_state;
    if (attr.mask & rdma_drv_qp_attr::M_STATE)
      next = attr.state;
    if (!transition_ok(cur_state, next)) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "illegal QP state transition");
      return;
    end
    apply_attr(attr, next);
    status = rdma_status::success();
    if (next != RDMA_DRV_QPS_INIT) begin
      full = (cur_state == RDMA_DRV_QPS_INIT && next == RDMA_DRV_QPS_RTR) ||
             (cur_state == RDMA_DRV_QPS_RTR && next == RDMA_DRV_QPS_RTS);
      hw_qpc_cmd(dev, RDMA_OP_QPC_MODIFY, full, status);
      if (status.ok() && cur_state == RDMA_DRV_QPS_RTS && next == RDMA_DRV_QPS_SQD)
        qp_doorbell(dev, RDMA_DB_RTS2SQD_OFFSET, RDMA_DB_TYPE_RTS2SQD, status);
      if (status.ok() && cur_state == RDMA_DRV_QPS_SQD && next == RDMA_DRV_QPS_RTS)
        qp_doorbell(dev, RDMA_DB_SQD2RTS_OFFSET, RDMA_DB_TYPE_SQD2RTS, status);
      if (status.ok() && next == RDMA_DRV_QPS_ERR)
        qp_doorbell(dev, RDMA_DB_QP_FLUSH_OFFSET, RDMA_DB_TYPE_QP_FLUSH, status);
    end
    if (status.ok())
      cur_state = next;
  endtask

  // 功能：ib_modify_qp_is_ok 的简化：允许 RESET→INIT、INIT→INIT/RTR、RTR→RTS、RTS→RTS/SQD、
  //   SQD→RTS/SQD，任意状态→RESET/ERR。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：其余组合返回 0。
  static function bit transition_ok(rdma_drv_qp_state_e cur, rdma_drv_qp_state_e next);
    if (next inside {RDMA_DRV_QPS_RESET, RDMA_DRV_QPS_ERR})
      return 1'b1;
    case (cur)
      RDMA_DRV_QPS_RESET: return next == RDMA_DRV_QPS_INIT;
      RDMA_DRV_QPS_INIT: return next inside {RDMA_DRV_QPS_INIT, RDMA_DRV_QPS_RTR};
      RDMA_DRV_QPS_RTR: return next == RDMA_DRV_QPS_RTS;
      RDMA_DRV_QPS_RTS: return next inside {RDMA_DRV_QPS_RTS, RDMA_DRV_QPS_SQD};
      RDMA_DRV_QPS_SQD: return next inside {RDMA_DRV_QPS_RTS, RDMA_DRV_QPS_SQD};
      default: return 1'b0;
    endcase
  endfunction

  // 功能：xtrdma_update_qp_context：按 mask 把属性写入 QPC 镜像（PSN 写入全部镜像字段）。
  // 输入/输出及副作用：修改 qpc。
  // 失败/边界：无。
  protected function void apply_attr(rdma_drv_qp_attr a, rdma_drv_qp_state_e next);
    if (a.mask & rdma_drv_qp_attr::M_DEST_QPN) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_DST_QPN, a.dest_qpn)
    end
    if (a.mask & rdma_drv_qp_attr::M_QKEY) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_UD_QKEY_H, a.qkey >> 24)
      `RDMA_DRV_SET(qpc, RDMA_QPC_UD_QKEY_L, a.qkey)
    end
    if (a.mask & rdma_drv_qp_attr::M_SQ_PSN) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_TPE_CUR_SQ_PSN, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_LAST_READ_PSN, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_PSN_MAX_RPE, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_EPSN_RSP, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_PSN_MAX_TPE, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_RETRY_FPSN, a.sq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_RETRY_PSN, a.sq_psn)
    end
    if (a.mask & rdma_drv_qp_attr::M_RQ_PSN) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_EPSN_REQ, a.rq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_EIRQ_PSN_MAX, a.rq_psn)
      `RDMA_DRV_SET(qpc, RDMA_QPC_EIRQ_CUR_SEND_PSN, a.rq_psn)
    end
    if (a.mask & rdma_drv_qp_attr::M_RNR_RETRY) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RNR_RETRY_TH, a.rnr_retry)
    end
    if (a.mask & rdma_drv_qp_attr::M_RETRY_CNT) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_PSN_RETRY_TH, a.retry_cnt)
    end
    if (a.mask & rdma_drv_qp_attr::M_TIMEOUT) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RTO_CODE, a.timeout)
    end
    // URC 忽略 MIN_RNR，保持 create 时的 urc_rnr_code（qp.c:2513）。
    if ((a.mask & rdma_drv_qp_attr::M_MIN_RNR) && !urc) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_LOCAL_RNR_CODE, a.min_rnr)
    end
    if (a.mask & rdma_drv_qp_attr::M_ACCESS) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_QP_ACCESS_FLAG, a.access | RDMA_RIGHT_LOCAL_WRITE)
    end
    if (a.mask & rdma_drv_qp_attr::M_PATH_MTU) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_PMTU, mtu_code(a.path_mtu))
    end
    if (a.mask & rdma_drv_qp_attr::M_MAX_RD_ATOMIC) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_RC_ORQ_SIZE, $clog2(a.max_rd_atomic))
    end
    if (a.mask & rdma_drv_qp_attr::M_AV) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_DMAC, a.dmac)
      foreach (a.dest_ip[i])
        qpc[80 + i] = a.dest_ip[i];
    end
    if (a.mask & rdma_drv_qp_attr::M_STATE) begin
      `RDMA_DRV_SET(qpc, RDMA_QPC_QP_ST, qpc_state(next))
    end
  endfunction

  // 功能：QP 控制 doorbell（qp.c xtrdma_knock_*_db）：DST_PORT、QP_SN、DB_TYPE、QPN。
  // 输入/输出及副作用：写 doorbell。
  // 失败/边界：BAR 写失败返回错误。
  protected task qp_doorbell(rdma_drv_dev dev, bit [63:0] offset, int unsigned db_type,
                             output rdma_status status);
    bit [63:0] db;

    db = '0;
    db[RDMA_NOTIFY_QP_DST_PORT_LSB +: RDMA_NOTIFY_QP_DST_PORT_WIDTH] =
      rdma_be::field(qpc, RDMA_QPC_DST_PORT_WORD_BYTE_OFFSET, RDMA_QPC_DST_PORT_LSB,
                     RDMA_QPC_DST_PORT_WIDTH);
    db[RDMA_NOTIFY_QP_SN_LSB +: RDMA_NOTIFY_QP_SN_WIDTH] = qp_sn;
    db[RDMA_NOTIFY_QP_DB_TYPE_LSB +: RDMA_NOTIFY_QP_DB_TYPE_WIDTH] = db_type;
    db[RDMA_NOTIFY_QP_QPN_LSB +: RDMA_NOTIFY_QP_QPN_WIDTH] = qpn;
    dev.hw.notify(offset, db, status);
  endtask

  // 功能：xtrdma_ib_destroy_qp：非 ERR 先转 ERR（仅状态 + flush doorbell），OCC_FLUSH（EIRQE/ORQE/UAQE，
  //   错误忽略），QPC_DELETE（失败即返回），cq_clean 收/发 CQ 中该 QP 的 CQE，释放缓冲与 QPN。
  // 输入/输出及副作用：下发命令，释放资源。
  // 失败/边界：转 ERR 或删除失败返回错误且不释放（与驱动一致）。
  task destroy(rdma_drv_dev dev, output rdma_status status);
    rdma_drv_qp_attr attr;
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    rdma_status ignored;

    status = rdma_status::success();
    if (cur_state != RDMA_DRV_QPS_ERR) begin
      attr = rdma_drv_qp_attr::type_id::create("to_err");
      attr.mask = rdma_drv_qp_attr::M_STATE;
      attr.state = RDMA_DRV_QPS_ERR;
      modify(dev, attr, status);
      if (!status.ok())
        return;
    end
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_OCC_FLUSH);
    `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_QPN, qpn)
    `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_EIRQE, 1)
    `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_ORQE, 1)
    `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_UAQE, 1)
    dev.cmq.exec(sqe, cqe, ignored);
    hw_qpc_cmd(dev, RDMA_OP_QPC_DELETE, 1'b0, status);
    if (!status.ok())
      return;
    if (urc) begin
      // clear_cqc_urc_flag；URC 的 cq_clean 把环直接跳到头（cq.c:1732）；随后销毁 frag。
      set_cqc_urc(dev, 1'b0, ignored);
      sq_tail = sq_head;
      rq_tail = rq_head;
      drop_frags(dev);
    end
    else begin
      recv_cq.clean(dev, qpn, srq, status);
      if (status.ok() && send_cq != recv_cq)
        send_cq.clean(dev, qpn, null, status);
      if (!status.ok())
        return;
    end
    free_buffers(dev);
    dev.qp_ids.free(qpn);
    dev.qp_table.delete(qpn);
    cur_state = RDMA_DRV_QPS_RESET;
  endtask
endclass
