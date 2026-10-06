// 目录：驱动层 src/drv/rdma_drv_verbs.sv。
// 职责：内核态 verbs 的 PD/MR/CQ/SRQ 控制路径：mr.c（alloc_pd、reg_mr：stag + setup_pble + KEY_ALLOC，
//   dereg_mr：OCC flush + MR_DEREGISTER + TX flush）、cq.c（create/destroy/req_notify）、
//   srq.c（create/modify limit/destroy）。数据路径（post/poll、resize、EQ 处理）在 rdma_drv_wr.sv。
// 依赖：rdma_drv_dev、rdma_drv_kbuf、rdma_drv_pble、rdma_defs.svh。
// 所有权与生命周期：每个对象拥有自己的缓冲与位图号，destroy/dealloc 释放。

class rdma_drv_pd extends uvm_object;
  `rdma_object_utils(rdma_drv_pd)

  int unsigned pd_id;

  // 功能：构造 PD。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_pd");
    super.new(name);
  endfunction

  // 功能：xtrdma_ib_alloc_pd：首次适配分配 PD 号（无硬件命令）。
  // 输入/输出及副作用：pd 输出。
  // 失败/边界：号用尽返回 RESOURCE_EXHAUSTED。
  static function rdma_status alloc(rdma_drv_dev dev, output rdma_drv_pd pd);
    pd = rdma_drv_pd::type_id::create("pd");
    if (!dev.pd_ids.alloc_first(pd.pd_id))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "PD ids are exhausted");
    return rdma_status::success();
  endfunction

  // 功能：xtrdma_ib_dealloc_pd。
  // 输入/输出及副作用：释放 PD 号。
  // 失败/边界：无。
  function void dealloc(rdma_drv_dev dev);
    dev.pd_ids.free(pd_id);
  endfunction
endclass

class rdma_drv_mr extends uvm_object;
  `rdma_object_utils(rdma_drv_mr)

  bit [31:0] stag;
  bit [63:0] va;
  longint unsigned length;
  bit [4:0] rights;
  int unsigned pbl_mode;
  int unsigned first_pble;
  int unsigned pble_cnt;
  int unsigned mr_sn;
  protected static int unsigned next_mr_sn = 0;

  // 功能：构造 MR。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_mr");
    super.new(name);
  endfunction

  // 功能：lkey/rkey（驱动两者相同）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function bit [31:0] key();
    return stag;
  endfunction

  // 功能：xtrdma_get_access：IB 权限 → MRT 权限位；任何写/原子权限隐含本地写。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function bit [4:0] rights_of(bit local_write, bit remote_read, bit remote_write,
                                      bit remote_atomic);
    bit [4:0] r;

    r = '0;
    if (local_write || remote_write || remote_atomic)
      r |= RDMA_RIGHT_LOCAL_WRITE;
    if (remote_read)
      r |= RDMA_RIGHT_REMOTE_READ;
    if (remote_write)
      r |= RDMA_RIGHT_REMOTE_WRITE;
    if (remote_atomic)
      r |= RDMA_RIGHT_REMOTE_ATOMIC;
    return r;
  endfunction

  // 功能：注册内核内存（reg_user_mr_type_mem 的内核等价）：create_stag（轮转索引 + 8 位 key）、
  //   setup_pble（连续页 MODE_0、两页 MODE_1、其余 MODE_2 写 PBLE）、mr_sn、KEY_ALLOC(st=VALID)。
  // 输入/输出及副作用：pages 为按 4KiB 的 DMA 页地址；mr 输出。
  // 失败/边界：stag/PBLE 用尽或命令失败返回错误并回退已分配资源。
  static task reg_mr(rdma_drv_dev dev, rdma_drv_pd pd, bit [63:0] va_arg, longint unsigned len,
                  bit [4:0] rights_arg, bit [63:0] pages[$], output rdma_drv_mr mr,
                  output rdma_status status);
    int unsigned idx;
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    bit contiguous;

    mr = rdma_drv_mr::type_id::create("mr");
    mr.va = va_arg;
    mr.length = len;
    mr.rights = rights_arg;
    mr.pble_cnt = 0;
    status = rdma_status::success();
    if (!dev.mr_ids.alloc_next(idx)) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "MR stag indexes are exhausted");
      return;
    end
    mr.stag = {idx[23:0], 8'($urandom)};
    contiguous = 1'b1;
    foreach (pages[i])
      if (i > 0 && pages[i] != pages[i - 1] + RDMA_HMC_PAGE_BYTES)
        contiguous = 1'b0;
    mr.pbl_mode = RDMA_PBL_MODE_2;
    if (contiguous)
      mr.pbl_mode = RDMA_PBL_MODE_0;
    else if (pages.size() == 2)
      mr.pbl_mode = RDMA_PBL_MODE_1;
    if (mr.pbl_mode == RDMA_PBL_MODE_2) begin
      status = dev.pble.get(pages.size(), mr.first_pble);
      if (!status.ok()) begin
        dev.mr_ids.free(idx);
        return;
      end
      mr.pble_cnt = pages.size();
      foreach (pages[i])
        if (status.ok())
          status = dev.pble.write_entry(mr.first_pble + i, pages[i]);
    end
    mr.mr_sn = next_mr_sn++;
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_KEY_ALLOC);
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_STAG_IDX, idx)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_NXT_ST, RDMA_MR_ST_VALID)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_STAG_KEY, mr.stag[7:0])
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_PARENT_STAG_IDX, idx)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_PD_IDX, pd.pd_id)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_RIGHT, mr.rights)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_TYPE, RDMA_MEM_TYPE_MR)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_HOST_PG_SIZE, RDMA_HOST_PAGE_4K)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_PBL_MODE, mr.pbl_mode)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_ADDR_MODE, RDMA_ADDR_TYPE_VA_BASED)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_ST, RDMA_MR_ST_VALID)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_LEN, len)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_INFO_STAG_KEY, mr.stag[7:0])
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_START_VA, va_arg)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_MR_SN, mr.mr_sn)
    if (mr.pbl_mode == RDMA_PBL_MODE_2) begin
      `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_FIRST_PBL_IDX, mr.first_pble)
    end
    else begin
      `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_PAYLOAD_PBA0, pages[0] >> 12)
      if (mr.pbl_mode == RDMA_PBL_MODE_1) begin
        `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_PAYLOAD_PBA1, pages[1] >> 12)
      end
    end
    if (status.ok())
      dev.cmq.exec(sqe, cqe, status);
    if (!status.ok()) begin
      if (mr.pble_cnt != 0)
        dev.pble.put(mr.first_pble, mr.pble_cnt);
      dev.mr_ids.free(idx);
    end
  endtask

  // 功能：xtrdma_dereg_mr：MODE_2 时 OCC_FLUSH(PBLE, MR_SN)，MR_DEREGISTER(NXT_ST=INVALID)，
  //   hw_flush_tx（TX_FLUSH doorbell），释放 stag 与 PBLE。
  // 输入/输出及副作用：下发命令与 doorbell，释放资源。
  // 失败/边界：命令失败返回错误且不释放（与驱动一致）。
  task dereg(rdma_drv_dev dev, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    bit [63:0] db;

    status = rdma_status::success();
    if (pbl_mode == RDMA_PBL_MODE_2) begin
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_OCC_FLUSH);
      `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_MR_SERIAL_FLUSH, 1)
      `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_PBLE, 1)
      `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_MR_SERIAL, mr_sn)
      dev.cmq.exec(sqe, cqe, status);
      if (!status.ok())
        return;
    end
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_MR_DEREGISTER);
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_STAG_IDX, stag[31:8])
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_NXT_ST, RDMA_MR_ST_INVALID)
    `RDMA_DRV_SET(sqe, RDMA_MRT_BODY_STAG_KEY, stag[7:0])
    dev.cmq.exec(sqe, cqe, status);
    if (!status.ok())
      return;
    db = '0;
    db[RDMA_NOTIFY_QP_DST_PORT_LSB +: RDMA_NOTIFY_QP_DST_PORT_WIDTH] = RDMA_TX_FLUSH_DST_PORT;
    db[RDMA_NOTIFY_QP_DB_TYPE_LSB +: RDMA_NOTIFY_QP_DB_TYPE_WIDTH] = RDMA_DB_TYPE_TX_FLUSH;
    dev.hw.notify(RDMA_DB_TX_FLUSH_OFFSET, db, status);
    dev.mr_ids.free(stag[31:8]);
    if (pble_cnt != 0)
      dev.pble.put(first_pble, pble_cnt);
  endtask
endclass

class rdma_drv_cq extends uvm_object;
  `rdma_object_utils(rdma_drv_cq)

  localparam int unsigned CQE_BYTES = 32;
  localparam int unsigned MIN_CQE = 512;
  // URC 信息区在 CQC 槽中的偏移（与普通 CQ shadow 同址，cq.h:33）。
  localparam int unsigned URC_INFO_OFFSET = 48;

  int unsigned cqn;
  int unsigned size;
  int unsigned ceqn;
  rdma_drv_kbuf mem_kbuf;
  rdma_drv_dma ctx_page;
  int unsigned ctx_offset;
  // 软件 CI 与 polarity（wr.c move_cq_ring_tail），arm 序号（cq.c）。
  longint unsigned tail;
  bit polarity;
  bit ci_wrap;
  int unsigned arm_sn;
  int unsigned last_arm_st;
  // URC（cq.h urc_cq_info）。原始 CQ：frag 列表、按 CQE 槽的 frag 占用图与轮询游标；
  //   urc_flag 置位后 poll 只遍历 frag。frag CQ：共享原始缓冲，自 start_idx 起占槽；
  //   send/recv 环（大小 = SQ/RQ 深度）记录软件已完成位置，recv_vld 为 RQ CQE 有效 polarity。
  bit urc_flag;
  rdma_drv_cq frags[$];
  bit frag_bm[];
  int unsigned urc_cur_polled;
  rdma_drv_cq original;
  int unsigned start_idx;
  int unsigned slots;
  bit send_flag;
  bit recv_flag;
  int unsigned send_qpn;
  int unsigned recv_qpn;
  int unsigned send_size;
  int unsigned recv_size;
  longint unsigned send_tail;
  longint unsigned recv_tail;
  bit recv_vld;

  // 功能：构造 CQ。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_cq");
    super.new(name);
    mem_kbuf = null;
    tail = 0;
    polarity = 1'b1;
    ci_wrap = 1'b0;
    arm_sn = 0;
    last_arm_st = RDMA_CQC_ARM_ST_NO_EVENT;
    urc_flag = 1'b0;
    urc_cur_polled = 0;
    original = null;
    start_idx = 0;
    send_flag = 1'b0;
    recv_flag = 1'b0;
    send_tail = 0;
    recv_tail = 0;
    recv_vld = 1'b1;
  endfunction

  // 功能：init_cq 的 CQC_CREATE SQE（56B CQC 在 SQE 字节 8 起）：尺寸、状态、当前/下一 PBA、CI 门限、
  //   OM、LAST_ARM_SN、CEQN、shadow 地址；frag CQ 另带 URC_CQ_START_IDX（覆盖 CQ_PI）。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  static function rdma_bytes_t cqc_sqe(int unsigned cqn, int unsigned size, bit [63:0] pba,
                                       int unsigned om, int unsigned ceqn, bit [63:0] ctx_iova,
                                       int unsigned start);
    rdma_bytes_t sqe;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_CREATE);
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQN, cqn)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQ_SIZE, $clog2(size))
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQ_ST, RDMA_CQC_ST_VALID)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CUR_PBA_VLD, 1)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CUR_CQ_PD_PBA, pba)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_NXT_CQ_PD_PBA_H, pba >> 44)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_NXT_CQ_PD_PBA_L, pba)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_LOAD_CQ_CI_DONE, 1)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_LOAD_CQ_CI_TH, 2)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQ_OM, om)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_NXT_PBA_VLD, 1)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_URC_CQ_START_IDX, start)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_LAST_ARM_SN, 1)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CEQN, ceqn)
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_SHADOW_PA, ctx_iova >> 6)
    return sqe;
  endfunction

  // 功能：xtrdma_ib_create_cq（内核）：cqe_num=roundup_pow2(max(cqe,512)*2)，32B CQE，偏好大页缓冲，
  //   CQC 写入 HMC 槽（shadow 为槽内 +48）后以 CQC_CREATE 下发同一 56B。
  // 输入/输出及副作用：分配 CQN/缓冲/命令；cq 输出。
  // 失败/边界：失败按 goto 链回退并返回错误。
  static task create_cq(rdma_drv_dev dev, int unsigned cqe, int unsigned comp_vector,
                     output rdma_drv_cq cq, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe_bytes;
    bit [63:0] pba;
    int unsigned want;

    cq = rdma_drv_cq::type_id::create("cq");
    want = cqe;
    if (want < MIN_CQE)
      want = MIN_CQE;
    cq.size = 1 << $clog2(want * 2);
    cq.ceqn = 0;
    if (comp_vector < dev.cfg.ceq_cnt)
      cq.ceqn = dev.cfg.first_ceqn + comp_vector;
    if (!dev.cq_ids.alloc_next(cq.cqn)) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "CQ numbers are exhausted");
      return;
    end
    cq.mem_kbuf = rdma_drv_kbuf::type_id::create("cq_buf");
    status = cq.mem_kbuf.alloc(dev.hw, cq.size * CQE_BYTES, 1'b1, dev.cfg.vf_id);
    if (!status.ok()) begin
      dev.cq_ids.free(cq.cqn);
      return;
    end
    void'(dev.hmc[rdma_drv_dev::HMC_CQC].locate(cq.cqn, cq.ctx_page, cq.ctx_offset));
    pba = cq.mem_kbuf.base_iova() >> 12;
    sqe = cqc_sqe(cq.cqn, cq.size, pba, cq.mem_kbuf.alloc_type, cq.ceqn,
                  cq.ctx_page.iova + cq.ctx_offset, 0);
    cq.frag_bm = new[cq.size];
    status = dev.hw.write(cq.ctx_page, cq.ctx_offset, rdma_be::slice(sqe, 8, RDMA_CQC_BYTES));
    if (status.ok())
      dev.cmq.exec(sqe, cqe_bytes, status);
    if (!status.ok()) begin
      void'(cq.mem_kbuf.free(dev.hw));
      dev.cq_ids.free(cq.cqn);
      return;
    end
    dev.cq_table[cq.cqn] = cq;
  endtask

  // 功能：xtrdma_ib_destroy_cq：CQC_DELETE（携带 HMC 中的 56B CQC）失败只记录；HUGE 缓冲无 PD flush；
  //   cleanup_ceqes 清除所属 CEQ 中该 CQ 的 CEQE；释放缓冲与 CQN。
  // 输入/输出及副作用：下发命令，释放资源。
  // 失败/边界：status 返回 CQC_DELETE 的结果，资源总是释放（与驱动一致）。
  task destroy(rdma_drv_dev dev, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t ctx;
    rdma_bytes_t cqe_bytes;
    rdma_status cleanup_status;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_DELETE);
    status = dev.hw.read(ctx_page, ctx_offset, RDMA_CQC_BYTES - 8, ctx);
    foreach (ctx[i])
      sqe[8 + i] = ctx[i];
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQN, cqn)
    if (status.ok())
      dev.cmq.exec(sqe, cqe_bytes, status);
    foreach (dev.ceqs[i])
      if (dev.ceqs[i].eqn == ceqn)
        dev.ceqs[i].cleanup(dev.hw, cqn, cleanup_status);
    void'(mem_kbuf.free(dev.hw));
    dev.cq_ids.free(cqn);
    dev.cq_table.delete(cqn);
  endtask

  // 功能：xtrdma_urc_create_cq_kernel + urc_alloc_frag：在原始 CQ 的槽位图中找 queue_size 个连续空槽，
  //   新建 frag CQ（新 CQN，共享原始缓冲，尺寸 roundup_pow2(queue_size)，CQC 带 URC_CQ_START_IDX），
  //   CQC_CREATE 后挂入原始 CQ 的 frag 列表并置原始 CQ urc_flag。
  // 输入/输出及副作用：占用槽位与 CQN，下发命令；frag 输出。
  // 失败/边界：无连续空槽返回 RESOURCE_EXHAUSTED；命令失败回退槽位与 CQN。
  task create_frag(rdma_drv_dev dev, int unsigned queue_size, output rdma_drv_cq frag,
                   output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe_bytes;
    int unsigned start;
    bit found;

    frag = null;
    found = 1'b0;
    for (int unsigned s0 = 0; s0 + queue_size <= size && !found; s0++) begin
      found = 1'b1;
      for (int unsigned k = 0; k < queue_size && found; k++)
        found = !frag_bm[s0 + k];
      start = s0;
    end
    if (!found) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "no free CQ area for a URC frag");
      return;
    end
    frag = rdma_drv_cq::type_id::create("urc_frag_cq");
    if (!dev.cq_ids.alloc_next(frag.cqn)) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "CQ numbers are exhausted");
      frag = null;
      return;
    end
    frag.original = this;
    frag.size = 1 << $clog2(queue_size);
    frag.ceqn = ceqn;
    frag.mem_kbuf = mem_kbuf;
    frag.start_idx = start;
    frag.slots = queue_size;
    void'(dev.hmc[rdma_drv_dev::HMC_CQC].locate(frag.cqn, frag.ctx_page, frag.ctx_offset));
    sqe = cqc_sqe(frag.cqn, frag.size, mem_kbuf.base_iova() >> 12, mem_kbuf.alloc_type, ceqn,
                  frag.ctx_page.iova + frag.ctx_offset, start);
    status = dev.hw.write(frag.ctx_page, frag.ctx_offset,
                          rdma_be::slice(sqe, 8, RDMA_CQC_BYTES));
    if (status.ok())
      dev.cmq.exec(sqe, cqe_bytes, status);
    if (!status.ok()) begin
      dev.cq_ids.free(frag.cqn);
      frag = null;
      return;
    end
    for (int unsigned k = 0; k < queue_size; k++)
      frag_bm[start + k] = 1'b1;
    frags.push_back(frag);
    urc_flag = 1'b1;
    dev.cq_table[frag.cqn] = frag;
  endtask

  // 功能：xtrdma_urc_destroy_cq + urc_free_frag：CQC_DELETE、cleanup_ceqes、释放 CQN 与槽位并移出
  //   列表；原始 CQ 不再有 frag 时清 urc_flag 并重置其 CQE polarity（CI 之前为当前 polarity，其后取反）。
  // 输入/输出及副作用：下发命令，改写原始 CQ 缓冲。
  // 失败/边界：status 为 CQC_DELETE 结果，资源总是释放。
  task destroy_frag(rdma_drv_dev dev, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t ctx;
    rdma_bytes_t cqe_bytes;
    rdma_bytes_t init;
    rdma_status ignored;
    int unsigned ci;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_DELETE);
    status = dev.hw.read(ctx_page, ctx_offset, RDMA_CQC_BYTES - 8, ctx);
    foreach (ctx[i])
      sqe[8 + i] = ctx[i];
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQN, cqn)
    if (status.ok())
      dev.cmq.exec(sqe, cqe_bytes, status);
    foreach (dev.ceqs[i])
      if (dev.ceqs[i].eqn == ceqn)
        dev.ceqs[i].cleanup(dev.hw, cqn, ignored);
    dev.cq_ids.free(cqn);
    dev.cq_table.delete(cqn);
    for (int unsigned k = 0; k < slots; k++)
      original.frag_bm[start_idx + k] = 1'b0;
    foreach (original.frags[i])
      if (original.frags[i] == this) begin
        original.frags.delete(i);
        break;
      end
    original.urc_cur_polled = 0;
    if (original.frags.size() != 0)
      return;
    original.urc_flag = 1'b0;
    ci = original.tail % original.size;
    init = rdma_be::zeros(CQE_BYTES);
    for (int unsigned i = 0; i < original.size; i++) begin
      init[0][7] = (i <= ci) ? original.polarity : !original.polarity;
      ignored = original.mem_kbuf.write(dev.hw, i * CQE_BYTES, init);
    end
  endtask

  // 功能：xtrdma_qp_set/clear_cqc_urc_flag 的一条 CQC_MODIFY：NXT_CQ_ST=VALID、URC_FLAG、SQ/RQ 尺寸
  //   （log2）与 flush 时上报 SQ/RQ CEQE 的有效位。
  // 输入/输出及副作用：下发命令。
  // 失败/边界：命令失败返回错误。
  task modify_urc(rdma_drv_dev dev, bit urc, bit sq_ceqe, bit rq_ceqe, int unsigned sq_log,
                  int unsigned rq_log, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe_bytes;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_MODIFY);
    `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQN, cqn)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_NXT_CQ_ST, RDMA_CQC_ST_VALID)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_URC_FLAG, urc)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_URC_SQ_CEQE_VLD, sq_ceqe)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_URC_RQ_CEQE_VLD, rq_ceqe)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_URC_SQ_SIZE, sq_log)
    `RDMA_DRV_SET(sqe, RDMA_CQC_MODIFY_URC_RQ_SIZE, rq_log)
    dev.cmq.exec(sqe, cqe_bytes, status);
  endtask

  // 功能：读 frag CQ 的 URC 信息区（CQC 槽 +48 起 16B，cq.h:33-105）。
  // 输入/输出及副作用：读 HMC；info 输出。
  // 失败/边界：读失败返回错误。
  function rdma_status read_urc_info(rdma_drv_dev dev, output rdma_bytes_t info);
    return dev.hw.read(ctx_page, ctx_offset + URC_INFO_OFFSET, 16, info);
  endfunction

  // 功能：写 frag CQ 的 URC 信息区。
  // 输入/输出及副作用：写 HMC。
  // 失败/边界：写失败返回错误。
  function rdma_status write_urc_info(rdma_drv_dev dev, rdma_bytes_t info);
    return dev.hw.write(ctx_page, ctx_offset + URC_INFO_OFFSET, info);
  endfunction

  // 功能：move_cq_ring_tail：tail 加一，回绕时翻转 polarity 与 ci_wrap。
  // 输入/输出及副作用：修改软件 CI 状态。
  // 失败/边界：无。
  function void advance_tail();
    tail++;
    if (tail % size == 0) begin
      polarity = !polarity;
      ci_wrap = !ci_wrap;
    end
  endfunction

  // 功能：xtrdma_kernel_update_cq_shadow_ci：CQ shadow（CQC+52）写 be32(ci_wrap<<23 | CI)。
  // 输入/输出及副作用：写 HMC 中的 CQ shadow。
  // 失败/边界：写失败返回错误。
  function rdma_status update_shadow_ci(rdma_drv_dev dev);
    rdma_bytes_t ci;
    bit [31:0] word;

    word = (32'(ci_wrap) << 23) | (tail % size);
    ci = rdma_be::zeros(4);
    foreach (ci[i])
      ci[i] = word[31 - 8 * i -: 8];
    return dev.hw.write(ctx_page, ctx_offset + RDMA_CQC_RUNTIME_SHADOW_BYTE_OFFSET, ci);
  endfunction

  // 功能：__xtrdma_cq_clean：从 tail 起找到最后一个有效 CQE，倒序遍历：属于 qpn 的丢弃（SRQ 接收释放
  //   槽位），其余向后平移 nfreed 格（跨圈时翻转 polarity）；最后 tail 前移 nfreed，ci_wrap/polarity 按
  //   新 tail 重算并更新 shadow CI。
  // 输入/输出及副作用：改写 CQ 缓冲与软件 CI 状态。
  // 失败/边界：读写失败返回错误。
  task clean(rdma_drv_dev dev, int unsigned qpn, rdma_drv_srq srq, output rdma_status status);
    rdma_bytes_t entry;
    longint unsigned prod;
    int unsigned nfreed;
    int unsigned idx;

    status = rdma_status::success();
    prod = tail;
    forever begin
      status = mem_kbuf.read(dev.hw, (prod % size) * CQE_BYTES, CQE_BYTES, entry);
      if (!status.ok())
        return;
      if (entry[0][7] != !((prod / size) & 1) || prod > tail + size)
        break;
      prod++;
    end
    nfreed = 0;
    while (prod > tail) begin
      prod--;
      status = mem_kbuf.read(dev.hw, (prod % size) * CQE_BYTES, CQE_BYTES, entry);
      if (!status.ok())
        return;
      if (rdma_be::field(entry, RDMA_CQE_QPN_WORD_BYTE_OFFSET, RDMA_CQE_QPN_LSB,
                         RDMA_CQE_QPN_WIDTH) == qpn) begin
        if (srq != null &&
            rdma_be::field(entry, RDMA_CQE_RQ_CQE_WORD_BYTE_OFFSET, RDMA_CQE_RQ_CQE_LSB, 1) &&
            rdma_be::field(entry, RDMA_CQE_SRFQ_WORD_BYTE_OFFSET, RDMA_CQE_SRFQ_LSB, 1)) begin
          idx = rdma_be::field(entry, RDMA_CQE_WQE_INDEX_WORD_BYTE_OFFSET,
                               RDMA_CQE_WQE_INDEX_LSB, RDMA_CQE_WQE_INDEX_WIDTH);
          srq.slot_used[idx % srq.depth] = 1'b0;
          srq.tail++;
        end
        nfreed++;
      end
      else if (nfreed != 0) begin
        if (((prod + nfreed) / size) % 2 != (prod / size) % 2)
          entry[0][7] = !entry[0][7];
        status = mem_kbuf.write(dev.hw, ((prod + nfreed) % size) * CQE_BYTES, entry);
        if (!status.ok())
          return;
      end
    end
    if (nfreed == 0)
      return;
    tail += nfreed;
    ci_wrap = (tail / size) & 1;
    polarity = !ci_wrap;
    status = update_shadow_ci(dev);
  endtask

  // 功能：xtrdma_ib_resize_cq（内核）：cqe 小于当前 ibcq.cqe 拒绝、相等直接返回；n=roundup_pow2(cqe*2)，
  //   新缓冲按 init_resize_cq_polarity 初始化（[0..CI] 为当前 polarity，其后取反），CQC_RESIZE 携带新
  //   PBA/尺寸/OM 与旧 CI/CI_WRAP；随后 copy_resize_cqes：从旧 CI 起把未消费 CQE 复制到新缓冲 CI+1 起
  //   （源下标 ≥ 旧尺寸的翻转 polarity），直到遇到 RESIZE CQE；tail = ci_wrap*n + CI + 1，换用新缓冲。
  // 输入/输出及副作用：分配新缓冲、下发命令、释放旧缓冲；更新 size/tail。
  // 失败/边界：参数非法返回 INVALID_ARGUMENT；命令失败释放新缓冲并返回错误；未找到 RESIZE CQE 返回
  //   INVALID_STATE（驱动的 "Ring wraped"）。
  task resize(rdma_drv_dev dev, int unsigned cqe, output rdma_status status);
    rdma_drv_kbuf new_buf;
    rdma_bytes_t init;
    rdma_bytes_t sqe;
    rdma_bytes_t cqe_bytes;
    rdma_bytes_t entry;
    int unsigned n;
    int unsigned old_ci;
    longint unsigned ci;

    status = rdma_status::success();
    if (cqe < size / 2) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "CQ depth reduction is unsupported");
      return;
    end
    if (cqe == size / 2)
      return;
    n = 1 << $clog2(cqe * 2);
    old_ci = tail % size;
    new_buf = rdma_drv_kbuf::type_id::create("cq_resize_buf");
    status = new_buf.alloc(dev.hw, n * CQE_BYTES, 1'b1, dev.cfg.vf_id);
    if (!status.ok())
      return;
    init = rdma_be::zeros(n * CQE_BYTES);
    for (int unsigned i = 0; i < n; i++)
      init[i * CQE_BYTES][7] = (i <= old_ci) ? polarity : !polarity;
    status = new_buf.write(dev.hw, 0, init);
    if (status.ok()) begin
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CQC_RESIZE);
      `RDMA_DRV_SET(sqe, RDMA_CQC_BODY_CQN, cqn)
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_CQ_SD_OR_PD_PBA, new_buf.base_iova() >> 12)
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_CQ_SIZE, $clog2(n))
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_CQ_OM, new_buf.alloc_type)
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_LOAD_CQ_CI_TH, 2)
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI_WRAP, ci_wrap)
      `RDMA_DRV_SET(sqe, RDMA_CQC_RESIZE_OLD_CQ_CI, old_ci)
      dev.cmq.exec(sqe, cqe_bytes, status);
    end
    if (!status.ok()) begin
      void'(new_buf.free(dev.hw));
      return;
    end
    ci = old_ci;
    forever begin
      status = mem_kbuf.read(dev.hw, (ci % size) * CQE_BYTES, CQE_BYTES, entry);
      if (!status.ok())
        return;
      if (rdma_be::field(entry, RDMA_CQE_RESIZE_CQE_WORD_BYTE_OFFSET, RDMA_CQE_RESIZE_CQE_LSB, 1))
        break;
      if (ci >= size)
        entry[0][7] = !entry[0][7];
      status = new_buf.write(dev.hw, ((ci + 1) % n) * CQE_BYTES, entry);
      if (!status.ok())
        return;
      ci++;
      if (ci % size == old_ci) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "resize CQE not found in the old CQ");
        return;
      end
    end
    void'(mem_kbuf.free(dev.hw));
    mem_kbuf = new_buf;
    size = n;
    tail = longint'(ci_wrap) * n + old_ci + 1;
  endtask

  // 功能：xtrdma_uk_cq_request_notification：比较 shadow 中硬件记录的 ARM_SN 与本地 arm_sn，
  //   已武装同级事件则跳过；否则写 shadow arm 字节并敲 CQ doorbell（ARM、ST、SN、CI、CQN）。
  // 输入/输出及副作用：写 shadow、doorbell。
  // 失败/边界：读写失败返回错误。
  task arm(rdma_drv_dev dev, bit solicited, output rdma_status status);
    bit [63:0] shadow;
    int unsigned st;
    int unsigned cmd_sn;
    bit [63:0] db;
    rdma_bytes_t one;

    st = RDMA_CQC_ARM_ST_NEXT_COMP;
    if (solicited)
      st = RDMA_CQC_ARM_ST_NEXT_SE;
    status = dev.hw.read_qword(ctx_page, ctx_offset + RDMA_CQC_SHADOW_AREA_OFFSET, shadow);
    if (!status.ok())
      return;
    cmd_sn = arm_sn & 3;
    if (shadow[33:32] == cmd_sn &&
        (last_arm_st == RDMA_CQC_ARM_ST_NEXT_COMP ||
         (last_arm_st == RDMA_CQC_ARM_ST_NEXT_SE && st == RDMA_CQC_ARM_ST_NEXT_SE)))
      return;
    last_arm_st = st;
    one = rdma_be::zeros(1);
    one[0] = (st << 2) | cmd_sn;
    status = dev.hw.write(ctx_page, ctx_offset + RDMA_CQC_SHADOW_AREA_OFFSET + 3, one);
    if (!status.ok())
      return;
    db = '0;
    db[RDMA_NOTIFY_CQ_ARM_LSB] = 1'b1;
    db[RDMA_NOTIFY_CQ_ARM_ST_LSB +: RDMA_NOTIFY_CQ_ARM_ST_WIDTH] = st;
    db[RDMA_NOTIFY_CQ_ARM_SN_LSB +: RDMA_NOTIFY_CQ_ARM_SN_WIDTH] = cmd_sn;
    db[RDMA_NOTIFY_CQ_CI_WRAP_LSB] = ci_wrap;
    db[RDMA_NOTIFY_CQ_CI_LSB +: RDMA_NOTIFY_CQ_CI_WIDTH] = tail % size;
    db[RDMA_NOTIFY_CQ_HOST_ID_LSB +: RDMA_NOTIFY_CQ_HOST_ID_WIDTH] = dev.cfg.host_id;
    db[RDMA_NOTIFY_CQ_CQN_LSB +: RDMA_NOTIFY_CQ_CQN_WIDTH] = cqn;
    dev.hw.notify(RDMA_DB_CQ_OFFSET, db, status);
  endtask
endclass

class rdma_drv_srq extends uvm_object;
  `rdma_object_utils(rdma_drv_srq)

  localparam int unsigned MIN_LIMIT = 16;
  localparam int unsigned CTX_BYTES = 32;
  localparam int unsigned SHADOW_OFFSET = 28;
  localparam int unsigned SGB_BYTES = 512;

  int unsigned srqn;
  int unsigned srq_sn;
  int unsigned depth;
  int unsigned limit;
  int unsigned arm_sn;
  rdma_drv_kbuf srq_kbuf;
  rdma_drv_kbuf srfq_kbuf;
  rdma_drv_dma ctx_page;
  int unsigned ctx_offset;
  // SGE>2 的 SRQ WQE 用的 SGB：每页 8 个 512B，按槽位图下标。
  rdma_drv_dma sgb[$];
  // post_srq_recv 状态：WQE 槽位图、SRFQ 生产者/消费者计数与 polarity、wr_id。
  bit slot_used[];
  int unsigned next_slot;
  longint unsigned pi;
  longint unsigned tail;
  bit polarity;
  longint unsigned wr_ids[];

  // 功能：构造 SRQ。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_srq");
    super.new(name);
    srq_kbuf = null;
    srfq_kbuf = null;
    ctx_page = null;
    arm_sn = 0;
    next_slot = 0;
    pi = 0;
    tail = 0;
    polarity = 1'b0;
  endfunction

  // 功能：xtrdma_ib_create_srq（内核）：wqe_cnt=roundup_pow2(max_wr)，limit=max(limit,16)，
  //   SRQ 与 SRFQ 缓冲各 cnt*64B，SGB 页（每槽 512B），context 页 + (srqn%128)*32（shadow 在 +28），SRFQC_CREATE。
  // 输入/输出及副作用：分配 SRQN/缓冲/命令；srq 输出。
  // 失败/边界：失败回退并返回错误。
  static task create_srq(rdma_drv_dev dev, rdma_drv_pd pd, int unsigned max_wr,
                     int unsigned limit_arg, output rdma_drv_srq srq, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    rdma_drv_dma page;

    srq = rdma_drv_srq::type_id::create("srq");
    srq.depth = 1 << $clog2(max_wr);
    srq.limit = limit_arg;
    if (srq.limit < MIN_LIMIT)
      srq.limit = MIN_LIMIT;
    srq.slot_used = new[srq.depth];
    srq.wr_ids = new[srq.depth];
    if (!dev.srq_ids.alloc_first(srq.srqn)) begin
      status = rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED, "SRQ numbers are exhausted");
      return;
    end
    srq.srq_sn = 0;
    srq.srq_kbuf = rdma_drv_kbuf::type_id::create("srq_buf");
    srq.srfq_kbuf = rdma_drv_kbuf::type_id::create("srfq_buf");
    status = srq.srq_kbuf.alloc(dev.hw, srq.depth * RDMA_WQE_BYTES, 1'b1, dev.cfg.vf_id);
    if (status.ok())
      status = srq.srfq_kbuf.alloc(dev.hw, srq.depth * RDMA_WQE_BYTES, 1'b1, dev.cfg.vf_id);
    for (int unsigned i = 0; status.ok() && i < (srq.depth + 7) / 8; i++) begin
      status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (status.ok())
        srq.sgb.push_back(page);
    end
    if (status.ok())
      status = dev.hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, srq.ctx_page);
    srq.ctx_offset = (srq.srqn % 128) * CTX_BYTES;
    if (status.ok()) begin
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_SRFQC_CREATE);
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQN, srq.srqn)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQ_ST, RDMA_SRQC_ST_VALID)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_LOAD_SRFQ_PI_TH, 8)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SHADOW_PA, srq.ctx_page.iova >> 12)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_PD_IDX, pd.pd_id)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQ_PBA, srq.srfq_kbuf.base_iova() >> 12)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQ_SIZE, $clog2(srq.depth))
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQ_OM, srq.srfq_kbuf.alloc_type)
      `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_LIMIT_TH, srq.limit >> 2)
      dev.cmq.exec(sqe, cqe, status);
    end
    if (!status.ok())
      srq.free_all(dev);
  endtask

  // 功能：xtrdma_ib_modify_srq（limit）：th=ALIGN(limit,4)>>2，arm_sn++，写 shadow+2 的
  //   be16(th<<2|arm_sn&3)，敲 SRFQ doorbell（PI 无效、LIMIT、ARM_SN、SRFQN）。
  // 输入/输出及副作用：写 shadow 与 doorbell。
  // 失败/边界：limit 超过深度返回 INVALID_ARGUMENT。
  task modify_limit(rdma_drv_dev dev, int unsigned limit_arg, output rdma_status status);
    int unsigned th;
    rdma_bytes_t half;
    bit [63:0] db;
    bit [15:0] word;

    if (limit_arg > depth) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "SRQ limit exceeds the queue depth");
      return;
    end
    th = (limit_arg + 3) / 4;
    arm_sn++;
    word = (th << 2) | (arm_sn & 3);
    half = rdma_be::zeros(2);
    half[0] = word[15:8];
    half[1] = word[7:0];
    status = dev.hw.write(ctx_page, ctx_offset + SHADOW_OFFSET + 2, half);
    if (!status.ok())
      return;
    db = '0;
    db[RDMA_NOTIFY_SRQ_PI_INVALID_LSB] = 1'b1;
    db[RDMA_NOTIFY_SRQ_LIMIT_LSB +: RDMA_NOTIFY_SRQ_LIMIT_WIDTH] = th;
    db[RDMA_NOTIFY_SRQ_ARM_SN_LSB +: RDMA_NOTIFY_SRQ_ARM_SN_WIDTH] = arm_sn & 3;
    db[RDMA_NOTIFY_SRFQN_LSB +: RDMA_NOTIFY_SRFQN_WIDTH] = srqn;
    dev.hw.notify(RDMA_DB_SRFQ_OFFSET, db, status);
    limit = limit_arg;
  endtask

  // 功能：xtrdma_ib_destroy_srq：SRFQC_DELETE 失败即返回（HUGE 缓冲无 PD flush），成功后释放。
  // 输入/输出及副作用：下发命令，释放资源。
  // 失败/边界：命令失败返回错误且不释放（与驱动一致）。
  task destroy(rdma_drv_dev dev, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;

    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_SRFQC_DELETE);
    `RDMA_DRV_SET(sqe, RDMA_SRQC_BODY_SRFQN, srqn)
    dev.cmq.exec(sqe, cqe, status);
    if (status.ok())
      free_all(dev);
  endtask

  // 功能：释放缓冲、context 页与 SRQN。
  // 输入/输出及副作用：释放资源。
  // 失败/边界：未分配部分跳过。
  function void free_all(rdma_drv_dev dev);
    if (srq_kbuf != null)
      void'(srq_kbuf.free(dev.hw));
    if (srfq_kbuf != null)
      void'(srfq_kbuf.free(dev.hw));
    foreach (sgb[i])
      void'(dev.hw.free_dma(sgb[i]));
    sgb.delete();
    void'(dev.hw.free_dma(ctx_page));
    dev.srq_ids.free(srqn);
  endfunction
endclass
