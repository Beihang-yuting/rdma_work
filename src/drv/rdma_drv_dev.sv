// 目录：驱动层 src/drv/rdma_drv_dev.sv。
// 职责：一个 RDMA Function 的驱动设备对象（xt_pci_f）：probe（ctrl_init_hw：CMQ、资源位图、HMC；
//   rt_init_hw：CEQ/AEQ、PBLE；modify_qp0_to_err）与 remove（TQ/OCC VF flush、删除 EQ、清 SD、释放）。
//   HMC 按 g_addr_mode=1（4K INDIRECT，每 SD 2MiB/512 个 PD 页）建表：每类对象 IFA_UPDATE，
//   按对象实际字节数分配 PD 页，SD_UPDATE 每批至多 34 个 SD。
// 依赖：rdma_drv_hw、rdma_drv_cmq、rdma_drv_kbuf/rdma_drv_pble、rdma_hw_cmq_field_body、rdma_defs.svh。
// 所有权与生命周期：拥有 CMQ、HMC 页、EQ 缓冲与位图；remove 后全部释放。

// 驱动模块参数与 GRM/ETH 驱动提供的值（func_spec.c 的计算结果直接给出，便于仿真缩小规模）。
class rdma_drv_config extends uvm_object;
  `rdma_object_utils(rdma_drv_config)

  int unsigned vf_id;
  int unsigned host_id;
  int unsigned max_qp;
  int unsigned max_cq;
  int unsigned max_mr;
  int unsigned max_pbl;
  int unsigned max_pd;
  int unsigned max_srq;
  int unsigned first_qp;
  // GRM：本 Function 的首个 SD 号、首个 CEQN；EQ 深度（驱动固定 256K，仿真可缩小）。
  int unsigned first_sd;
  int unsigned first_ceqn;
  int unsigned ceq_cnt;
  int unsigned eq_entries;

  // 功能：以小规模仿真默认值构造配置。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_config");
    super.new(name);
    vf_id = 0;
    host_id = 0;
    max_qp = 64;
    max_cq = 64;
    max_mr = 64;
    max_pbl = 1024;
    max_pd = 16;
    max_srq = 16;
    first_qp = 0;
    first_sd = 0;
    first_ceqn = 0;
    ceq_cnt = 1;
    eq_entries = 256;
  endfunction
endclass

// 一类 HMC 对象（hmc.h xtrdma_hmc_obj_info + sd_rsrc）。
class rdma_drv_hmc_obj extends uvm_object;
  `rdma_object_utils(rdma_drv_hmc_obj)

  int unsigned obj_type;
  int unsigned max_cnt;
  int unsigned size;
  int unsigned fvm_soa;
  rdma_drv_dma pages[$];

  // 功能：构造空对象类描述。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_hmc_obj");
    super.new(name);
  endfunction

  // 功能：xtrdma_set_context_addr：对象 id 所在页与页内偏移（页从对象类首字节起按 4KiB 排列）。
  // 输入/输出及副作用：page/offset 输出。
  // 失败/边界：id 越界返回 0。
  function bit locate(int unsigned id, output rdma_drv_dma page, output int unsigned offset);
    longint unsigned byte_offset;

    page = null;
    offset = 0;
    if (id >= max_cnt)
      return 1'b0;
    byte_offset = longint'(id) * size;
    page = pages[byte_offset / RDMA_HMC_PAGE_BYTES];
    offset = byte_offset % RDMA_HMC_PAGE_BYTES;
    return 1'b1;
  endfunction
endclass

// 一个 CEQ 或 AEQ（event.c xtrdma_sc_ceq/aeq）。
class rdma_drv_eq extends uvm_object;
  `rdma_object_utils(rdma_drv_eq)

  bit is_aeq;
  int unsigned eqn;
  int unsigned entries;
  int unsigned msix_idx;
  rdma_drv_kbuf mem_kbuf;
  longint unsigned tail;
  bit polarity;

  // 功能：构造未创建的 EQ。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_eq");
    super.new(name);
    mem_kbuf = null;
    tail = 0;
    polarity = 1'b1;
  endfunction

  // 功能：xtrdma_sc_ceq_ack：敲 CEQ doorbell 报告 CI（CI_WRAP|CI|CEQN）。
  // 输入/输出及副作用：MMIO 写。
  // 失败/边界：写失败经 status 返回。
  task ack(rdma_drv_hw hw, output rdma_status status);
    bit [63:0] db;

    db = '0;
    db[RDMA_NOTIFY_CEQ_CI_WRAP_LSB] = (tail / entries) & 1;
    db[RDMA_NOTIFY_CEQ_CI_LSB +: RDMA_NOTIFY_CEQ_CI_WIDTH] = tail % entries;
    db[RDMA_NOTIFY_CEQ_CEQN_LSB +: RDMA_NOTIFY_CEQ_CEQN_WIDTH] = eqn;
    hw.notify(RDMA_DB_CEQ_OFFSET, db, status);
  endtask

  // 功能：xtrdma_sc_cleanup_ceqes：从 tail 起找到最后一个有效 CEQE，倒序遍历：CQN 匹配的丢弃，其余
  //   向后平移已丢弃数（跨圈时翻转 bit63）；tail 前移丢弃数，polarity 按新 tail 重算并 ack。
  // 输入/输出及副作用：改写 CEQ 缓冲、CI 状态并敲 doorbell。
  // 失败/边界：读写失败返回错误。
  task cleanup(rdma_drv_hw hw, int unsigned cqn, output rdma_status status);
    rdma_bytes_t ceqe;
    longint unsigned prod;
    int unsigned removed;

    status = rdma_status::success();
    prod = tail;
    forever begin
      status = mem_kbuf.read(hw, (prod % entries) * RDMA_CEQE_BYTES, RDMA_CEQE_BYTES, ceqe);
      if (!status.ok())
        return;
      if (ceqe[0][7] != !((prod / entries) & 1) || prod > tail + entries)
        break;
      prod++;
    end
    removed = 0;
    while (prod > tail) begin
      prod--;
      status = mem_kbuf.read(hw, (prod % entries) * RDMA_CEQE_BYTES, RDMA_CEQE_BYTES, ceqe);
      if (!status.ok())
        return;
      if (rdma_be::field(ceqe, RDMA_CEQE_CQN_WORD_BYTE_OFFSET, RDMA_CEQE_CQN_LSB,
                         RDMA_CEQE_CQN_WIDTH) == cqn) begin
        removed++;
      end
      else if (removed != 0) begin
        if (((prod + removed) / entries) % 2 != (prod / entries) % 2)
          ceqe[0][7] = !ceqe[0][7];
        status = mem_kbuf.write(hw, ((prod + removed) % entries) * RDMA_CEQE_BYTES, ceqe);
        if (!status.ok())
          return;
      end
    end
    if (removed == 0)
      return;
    tail += removed;
    polarity = !((tail / entries) & 1);
    ack(hw, status);
  endtask
endclass

class rdma_drv_dev extends uvm_object;
  `rdma_object_utils(rdma_drv_dev)

  localparam int unsigned SD_BYTES = RDMA_HMC_PAGE_BYTES * RDMA_HMC_PD_PER_SD;
  localparam int unsigned HMC_QPC = 0;
  localparam int unsigned HMC_CQC = 1;
  localparam int unsigned HMC_MRT = 2;
  localparam int unsigned HMC_PBL = 3;
  localparam int unsigned QP_STATE_ERR = 4;

  rdma_drv_config cfg;
  rdma_drv_hw hw;
  rdma_drv_cmq cmq;
  rdma_drv_hmc_obj hmc[4];
  rdma_drv_dma sd_tables[$];
  rdma_drv_pble pble;
  rdma_drv_bitmap qp_ids;
  rdma_drv_bitmap cq_ids;
  rdma_drv_bitmap mr_ids;
  rdma_drv_bitmap pd_ids;
  rdma_drv_bitmap srq_ids;
  // rf->qp_sn[qpn]：每次分配该 QPN 时后增（u8）。
  bit [7:0] qp_sn[int unsigned];
  rdma_drv_eq ceqs[$];
  // xa_store 的 qp_table/cq_table：poll 与 EQ 处理按号查找对象。
  rdma_drv_qp qp_table[int unsigned];
  rdma_drv_cq cq_table[int unsigned];
  rdma_drv_eq aeq;
  bit probed;

  // 功能：构造未 probe 的设备。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_drv_dev");
    super.new(name);
    cfg = null;
    hw = null;
    aeq = null;
    probed = 1'b0;
  endfunction

  // 功能：xtrdma_probe：ctrl_init_hw（CMQ、位图、HMC）→ rt_init_hw（CEQ、AEQ、PBLE）→ QP0 置 ERR。
  //   任一步失败按驱动 goto 链逆序回退。
  // 输入/输出及副作用：分配全部 Function 级资源并向设备下发命令。
  // 失败/边界：返回首个失败；回退后设备回到未 probe 状态。
  task probe(rdma_drv_config cfg_arg, rdma_drv_hw hw_arg, output rdma_status status);
    cfg = cfg_arg;
    hw = hw_arg;
    cmq = rdma_drv_cmq::type_id::create({get_name(), "_cmq"});
    cmq.create_cmq(hw, status);
    if (!status.ok())
      return;
    init_bitmaps();
    hmc_setup(status);
    if (status.ok())
      setup_eqs(status);
    if (status.ok()) begin
      init_pble();
      status = modify_qp0_to_err();
    end
    if (!status.ok()) begin
      teardown(1'b0);
      return;
    end
    probed = 1'b1;
  endtask

  // 功能：xtrdma_remove：vf_disable_flush_hw（TQ_FLUSH、OCC VF flush）后逆序拆除。
  // 输入/输出及副作用：向设备下发清理命令并释放全部资源。
  // 失败/边界：flush 失败只记录到 status，继续拆除（驱动 remove 不可失败）。
  task remove(output rdma_status status);
    rdma_bytes_t cqe;
    rdma_bytes_t sqe;
    rdma_status one;

    status = rdma_status::success();
    if (!probed)
      return;
    cmq.exec(rdma_drv_cmq::new_sqe(RDMA_OP_TQ_FLUSH), cqe, one);
    keep_first(status, one);
    sqe = rdma_drv_cmq::new_sqe(RDMA_OP_OCC_FLUSH);
    `RDMA_DRV_SET(sqe, RDMA_CMQ_OCC_VF_FLUSH, 1)
    // OCC qword1 bits 63..55：QPC/CQC/MRT/PBLE/SQRQE/SGB_IRQE/EIRQE/ORQE/UAQE 全部置位。
    rdma_be::set_field(sqe, RDMA_CMQ_OCC_UAQE_WORD_BYTE_OFFSET, RDMA_CMQ_OCC_UAQE_LSB, 9, 9'h1ff);
    cmq.exec(sqe, cqe, one);
    keep_first(status, one);
    teardown(1'b1);
    probed = 1'b0;
  endtask

  // 功能：保留第一个失败。
  // 输入/输出及副作用：可能修改 status。
  // 失败/边界：无。
  protected function void keep_first(inout rdma_status status, input rdma_status one);
    if (status.ok() && !one.ok())
      status = one;
  endfunction

  // 功能：xtrdma_initialize_hw_rsrc：QP/CQ/MR/PD 位图，QPN 0/1 预留给 SMI/GSI；SRQN（驱动由 GRM
  //   分配）用本地位图代替。
  // 输入/输出及副作用：重建位图。
  // 失败/边界：无。
  protected function void init_bitmaps();
    qp_ids = rdma_drv_bitmap::type_id::create("qp_ids");
    cq_ids = rdma_drv_bitmap::type_id::create("cq_ids");
    mr_ids = rdma_drv_bitmap::type_id::create("mr_ids");
    pd_ids = rdma_drv_bitmap::type_id::create("pd_ids");
    srq_ids = rdma_drv_bitmap::type_id::create("srq_ids");
    qp_ids.init(cfg.max_qp, cfg.first_qp);
    qp_ids.reserve(0);
    qp_ids.reserve(1);
    cq_ids.init(cfg.max_cq);
    mr_ids.init(cfg.max_mr);
    pd_ids.init(cfg.max_pd);
    srq_ids.init(cfg.max_srq);
  endfunction

  // 功能：xtrdma_hmc_setup：计算各类对象区（QPC、CQC、MRT、PBL 依次排列，各自按 SD 对齐），
  //   IFA_UPDATE 配置每类，分配 SD 的 PD 表与覆盖对象字节的 PD 页，最后 SD_UPDATE。
  // 输入/输出及副作用：分配 HMC 页、下发 IFA_UPDATE/SD_UPDATE。
  // 失败/边界：任一步失败返回错误（已分配页由 teardown 释放）。
  protected task hmc_setup(output rdma_status status);
    int unsigned counts[4];
    int unsigned sizes[4];
    longint unsigned fvm_bytes;
    longint unsigned obj_bytes;
    rdma_drv_dma page;
    rdma_hw_cmq_field_body body;
    rdma_bytes_t cqe;
    int unsigned pd;

    counts = '{cfg.max_qp, cfg.max_cq, cfg.max_mr, cfg.max_pbl};
    sizes = '{RDMA_QPC_BYTES, RDMA_CQC_BYTES, 64, 8};
    fvm_bytes = longint'(cfg.first_sd) * SD_BYTES;
    status = rdma_status::success();
    for (int t = 0; t < 4; t++) begin
      hmc[t] = rdma_drv_hmc_obj::type_id::create($sformatf("hmc_%0d", t));
      hmc[t].obj_type = t;
      hmc[t].max_cnt = counts[t];
      hmc[t].size = sizes[t];
      hmc[t].fvm_soa = fvm_bytes >> RDMA_HMC_FVM_SOA_SHIFT;
      obj_bytes = longint'(counts[t]) * sizes[t];
      body = rdma_hw_cmq_field_body::type_id::create("ifa_body");
      body.values["obj_type"] = t;
      body.values["data"] = ifa_data(hmc[t], $clog2(sizes[t]));
      cmq.exec_fields(RDMA_OP_IFA_UPDATE, body, cqe, status);
      if (!status.ok())
        return;
      fvm_bytes += (obj_bytes + SD_BYTES - 1) / SD_BYTES * SD_BYTES;
    end
    for (longint unsigned s = cfg.first_sd; s < fvm_bytes / SD_BYTES; s++) begin
      status = hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
      if (!status.ok())
        return;
      sd_tables.push_back(page);
    end
    for (int t = 0; t < 4; t++) begin
      obj_bytes = longint'(hmc[t].max_cnt) * hmc[t].size;
      for (longint unsigned off = 0; off < obj_bytes; off += RDMA_HMC_PAGE_BYTES) begin
        status = hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, page);
        if (!status.ok())
          return;
        hmc[t].pages.push_back(page);
        pd = ((longint'(hmc[t].fvm_soa) << RDMA_HMC_FVM_SOA_SHIFT) + off) / RDMA_HMC_PAGE_BYTES;
        status = hw.write_qword(sd_tables[pd / RDMA_HMC_PD_PER_SD - cfg.first_sd],
                                (pd % RDMA_HMC_PD_PER_SD) * 8, pd_entry(page.iova));
        if (!status.ok())
          return;
      end
    end
    update_sds(1'b1, status);
  endtask

  // 功能：IFA_UPDATE 的 data 字：VALID|MODE(INDIRECT)|SIZE(log2)|MOUNT(max_cnt-1)|FVM_SOA。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function bit [63:0] ifa_data(rdma_drv_hmc_obj obj, int unsigned size_factor);
    bit [63:0] data;

    data = '0;
    data[RDMA_IFA_DATA_VALID_LSB] = 1'b1;
    data[RDMA_IFA_DATA_OBJ_MODE_LSB +: RDMA_IFA_DATA_OBJ_MODE_WIDTH] = RDMA_ALLOC_TYPE_INDIRECT;
    data[RDMA_IFA_DATA_OBJ_SIZE_LSB +: RDMA_IFA_DATA_OBJ_SIZE_WIDTH] = size_factor;
    data[RDMA_IFA_DATA_OBJ_MOUNT_LSB +: RDMA_IFA_DATA_OBJ_MOUNT_WIDTH] = obj.max_cnt - 1;
    data[RDMA_IFA_DATA_FVM_SOA_LSB +: RDMA_IFA_DATA_FVM_SOA_WIDTH] = obj.fvm_soa;
    return data;
  endfunction

  // 功能：PD/SD 表项：PBA|VF_ID|VLD。
  // 输入/输出及副作用：纯函数。
  // 失败/边界：无。
  protected function bit [63:0] pd_entry(bit [63:0] iova);
    bit [63:0] entry;

    entry = '0;
    entry[RDMA_PD_ENTRY_PBA_LSB +: RDMA_PD_ENTRY_PBA_WIDTH] = iova >> RDMA_PD_ENTRY_PBA_LSB;
    entry[RDMA_PD_ENTRY_VF_ID_LSB +: RDMA_PD_ENTRY_VF_ID_WIDTH] = cfg.vf_id;
    entry[RDMA_PD_ENTRY_VLD_LSB] = 1'b1;
    return entry;
  endfunction

  // 功能：xtrdma_update_hmc_sd_info / clean_hmc_sd_info：每批至多 34 个 SD；前 2 个 16B 表项放 SQE，
  //   其余写入 4KiB 暂存缓冲并把其地址填入 sd_buf_addr。valid=0 时 data 为 0（清除）。
  // 输入/输出及副作用：分配/释放暂存缓冲，下发 SD_UPDATE。
  // 失败/边界：任一批失败返回错误。
  protected task update_sds(bit valid, output rdma_status status);
    rdma_drv_dma scratch;
    rdma_hw_cmq_field_body body;
    rdma_bytes_t cqe;
    rdma_bytes_t entries;
    int unsigned done;
    int unsigned n;
    bit [63:0] data;

    status = hw.alloc_dma(RDMA_HMC_PAGE_BYTES, RDMA_HMC_PAGE_BYTES, scratch);
    if (!status.ok())
      return;
    done = 0;
    while (done < sd_tables.size() && status.ok()) begin
      n = sd_tables.size() - done;
      if (n > RDMA_SD_MAX_PER_UPDATE)
        n = RDMA_SD_MAX_PER_UPDATE;
      entries = rdma_be::zeros(n * RDMA_SD_ENTRY_BYTES);
      for (int unsigned i = 0; i < n; i++) begin
        rdma_be::set_field(entries, i * RDMA_SD_ENTRY_BYTES + RDMA_SD_ENTRY_IDX_WORD_BYTE_OFFSET,
                           RDMA_SD_ENTRY_IDX_LSB, RDMA_SD_ENTRY_IDX_WIDTH,
                           cfg.first_sd + done + i);
        data = '0;
        if (valid)
          data = pd_entry(sd_tables[done + i].iova);
        rdma_be::put_qword(entries, i * RDMA_SD_ENTRY_BYTES + RDMA_SD_ENTRY_PA_WORD_BYTE_OFFSET,
                           data);
      end
      body = rdma_hw_cmq_field_body::type_id::create("sd_body");
      body.values["sd_num"] = n;
      body.blobs["sd_data"] = rdma_be::slice(entries, 0,
                                             RDMA_SD_CARRIED_IN_SQE * RDMA_SD_ENTRY_BYTES);
      body.blobs["sd_extra_data"] = new[0];
      if (n > RDMA_SD_CARRIED_IN_SQE) begin
        body.blobs["sd_extra_data"] =
          rdma_be::slice(entries, RDMA_SD_CARRIED_IN_SQE * RDMA_SD_ENTRY_BYTES,
                         (n - RDMA_SD_CARRIED_IN_SQE) * RDMA_SD_ENTRY_BYTES);
        body.values["sd_buf_addr"] = scratch.iova;
        status = hw.write(scratch, 0, body.blobs["sd_extra_data"]);
      end
      if (status.ok())
        cmq.exec_fields(RDMA_OP_SD_UPDATE, body, cqe, status);
      done += n;
    end
    void'(hw.free_dma(scratch));
  endtask

  // 功能：xtrdma_setup_ceqs / xtrdma_setup_aeq：EQ 缓冲为普通页（INDIRECT），CEQC/AEQC_CREATE。
  // 输入/输出及副作用：分配 EQ 缓冲并下发创建命令。
  // 失败/边界：任一失败返回错误（已建 EQ 由 teardown 删除）。
  protected task setup_eqs(output rdma_status status);
    rdma_drv_eq eq;

    status = rdma_status::success();
    for (int unsigned i = 0; i < cfg.ceq_cnt && status.ok(); i++) begin
      eq = rdma_drv_eq::type_id::create($sformatf("ceq_%0d", i));
      eq.eqn = cfg.first_ceqn + i;
      eq.msix_idx = i + 1;
      create_eq(eq, status);
      if (status.ok())
        ceqs.push_back(eq);
    end
    if (!status.ok())
      return;
    eq = rdma_drv_eq::type_id::create("aeq");
    eq.is_aeq = 1'b1;
    eq.eqn = cfg.vf_id;
    eq.msix_idx = 0;
    create_eq(eq, status);
    if (status.ok())
      aeq = eq;
  endtask

  // 功能：xtrdma_sc_ceq_init + hw_create_eq：EQC 为 ST=VALID、SIZE=log2(entries)、
  //   CUR/NXT PBA=缓冲基址>>12、CUR_PBA_VLD、OM、MSIX，PI/CI 从 0 开始。
  // 输入/输出及副作用：分配缓冲，下发 CEQC_CREATE 或 AEQC_CREATE。
  // 失败/边界：分配或命令失败返回错误并释放缓冲。
  protected task create_eq(rdma_drv_eq eq, output rdma_status status);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    bit [63:0] pba;

    eq.entries = cfg.eq_entries;
    eq.mem_kbuf = rdma_drv_kbuf::type_id::create({eq.get_name(), "_buf"});
    status = eq.mem_kbuf.alloc(hw, eq.entries * RDMA_CEQE_BYTES, 1'b0, cfg.vf_id);
    if (!status.ok())
      return;
    if (eq.is_aeq)
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_AEQC_CREATE);
    else
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CEQC_CREATE);
    pba = eq.mem_kbuf.base_iova() >> 12;
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQN, eq.eqn)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQ_ST, 1)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQ_SIZE, $clog2(eq.entries))
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_NXT_EQ_PBA, pba)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_CUR_EQ_PBA, pba)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_CUR_PBA_VLD, 1)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQ_OM, eq.mem_kbuf.alloc_type)
    `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_MSI_X_IDX, eq.msix_idx)
    cmq.exec(sqe, cqe, status);
    if (!status.ok())
      void'(eq.mem_kbuf.free(hw));
  endtask

  // 功能：xtrdma_init_pble：PBL 对象页作为 PBLE 池。
  // 输入/输出及副作用：建池。
  // 失败/边界：无。
  protected function void init_pble();
    pble = rdma_drv_pble::type_id::create("pble");
    pble.init(hw, hmc[HMC_PBL].pages);
  endfunction

  // 功能：xtrdma_modify_qp0_to_err：直接改写 HMC 中 QP0 的 QPC（状态 ERR、HOST_ID、VF_ID），不经 CMQ。
  // 输入/输出及副作用：读改写主机内存。
  // 失败/边界：读写失败返回错误。
  protected function rdma_status modify_qp0_to_err();
    rdma_drv_dma page;
    int unsigned offset;
    rdma_bytes_t qpc;
    rdma_status status;

    void'(hmc[HMC_QPC].locate(0, page, offset));
    status = hw.read(page, offset, RDMA_QPC_BYTES, qpc);
    if (!status.ok())
      return status;
    `RDMA_DRV_SET(qpc, RDMA_QPC_QP_ST, QP_STATE_ERR)
    `RDMA_DRV_SET(qpc, RDMA_QPC_HOST_ID, cfg.host_id)
    `RDMA_DRV_SET(qpc, RDMA_QPC_VF_ID, cfg.vf_id)
    return hw.write(page, offset, qpc);
  endfunction

  // 功能：逆序拆除：删除 EQ（hw_cmds 为 1 时下发 AEQC/CEQC_DELETE 与 SD 清除），释放 HMC 页、
  //   SD 表与 CMQ。
  // 输入/输出及副作用：释放全部资源。
  // 失败/边界：命令失败被忽略（与驱动 deinit 一致）。
  protected task teardown(bit hw_cmds);
    rdma_bytes_t sqe;
    rdma_bytes_t cqe;
    rdma_status status;

    if (aeq != null) begin
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_AEQC_DELETE);
      `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQN, aeq.eqn)
      if (hw_cmds)
        cmq.exec(sqe, cqe, status);
      void'(aeq.mem_kbuf.free(hw));
      aeq = null;
    end
    foreach (ceqs[i]) begin
      sqe = rdma_drv_cmq::new_sqe(RDMA_OP_CEQC_DELETE);
      `RDMA_DRV_SET(sqe, RDMA_EQC_BODY_EQN, ceqs[i].eqn)
      if (hw_cmds)
        cmq.exec(sqe, cqe, status);
      void'(ceqs[i].mem_kbuf.free(hw));
    end
    ceqs.delete();
    if (hw_cmds && sd_tables.size() != 0)
      update_sds(1'b0, status);
    for (int t = 0; t < 4; t++)
      if (hmc[t] != null) begin
        foreach (hmc[t].pages[i])
          void'(hw.free_dma(hmc[t].pages[i]));
        hmc[t] = null;
      end
    foreach (sd_tables[i])
      void'(hw.free_dma(sd_tables[i]));
    sd_tables.delete();
    void'(cmq.destroy());
  endtask
endclass
