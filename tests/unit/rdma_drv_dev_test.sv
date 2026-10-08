// 目录：单元测试层 tests/unit/rdma_drv_dev_test.sv。
// 职责：驱动 probe/remove（rdma_drv_dev）对设备模型的完整命令序列：CMQ 建立、4 类 HMC 对象
//   IFA_UPDATE、带签名的 SD_UPDATE（设备校验扩展 SD 表签名）、CEQ/AEQ 创建与 EQC 内容、QP0 置 ERR，
//   以及 remove 的 flush/删除/清 SD 顺序和 DMA 内存全部归还。
// 依赖：rdma_drv_dev、rdma_dev、rdma_dpu_system（dpu_common）、rdma_host_mem（外部 host_mem）。
// 所有权与生命周期：测试拥有主机内存、设备与驱动对象。
class rdma_drv_dev_test extends uvm_test;
  `uvm_component_utils(rdma_drv_dev_test)

  rdma_host_mem mem;
  rdma_dev dev;
  rdma_drv_dev drv;

  // 功能：构造测试组件。
  // 输入/输出及副作用：name/parent 透传给 uvm_test；mem/dev/drv 保持 null，尚未取得系统资源所有权。
  // 失败/边界：parent=null 是顶层 test 的正常形式；probe/remove 夹具只在 run_phase 建立并收尾。
  function new(string name = "rdma_drv_dev_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 功能：probe → 检查 → remove → 检查。
  // 输入/输出及副作用：持有 objection 直到结束。
  // 失败/边界：以 UVM_ERROR/FATAL 报告。
  task run_phase(uvm_phase phase);
    rdma_dpu_system sys;
    rdma_dpu_function func;
    rdma_drv_config cfg;
    rdma_status status;

    phase.raise_objection(this);
    // Host0：PF0 + VF1..VF3，取 VF3（global Function ID 3）。
    sys = rdma_dpu_test_system::single_host("drv_dev", 3);
    func = sys.nodes[3].func;
    if (func.key.kind != DPU_FUNCTION_VF || func.global_id != 3)
      `uvm_fatal("DRV_DEV", $sformatf("dpu_common Function %s has global ID %0d",
                                      dpu_function_key_name(func.key), func.global_id))
    mem = sys.nodes[3].mem;
    dev = sys.nodes[3].dev;
    cfg = rdma_drv_config::type_id::create("drv_dev_cfg");
    cfg.ceq_cnt = 2;
    cfg.first_ceqn = 4;
    sys.probe(3, status, cfg);
    expect_ok("probe", status);
    drv = sys.nodes[3].drv;
    check_probe();
    drv.remove(status);
    expect_ok("remove", status);
    check_remove();
    phase.drop_objection(this);
  endtask

  // 功能：断言 status 成功。
  // 输入/输出及副作用：what 用于报告。
  // 失败/边界：null 或失败报告 UVM_FATAL。
  function void expect_ok(string what, rdma_status status);
    if (status == null || !status.ok())
      `uvm_fatal("DRV_DEV", $sformatf("%s failed: %s", what,
                 status == null ? "null" : status.convert2string()))
  endfunction

  // 功能：probe 命令序列为 IFA_UPDATE×4、SD_UPDATE、CEQC_CREATE×2、AEQC_CREATE；EQC 携带缓冲
  //   PD 表地址；QP0 的 QPC 状态为 ERR 且带 VF_ID。
  // 输入/输出及副作用：只读设备与主机内存。
  // 失败/边界：不符报告 UVM_ERROR。
  task check_probe();
    bit [7:0] expected[$];
    rdma_dev_object eqc;
    rdma_drv_dma page;
    int unsigned offset;
    rdma_bytes_t qpc;
    bit [63:0] iova;
    rdma_status status;

    expected = '{RDMA_OP_IFA_UPDATE, RDMA_OP_IFA_UPDATE, RDMA_OP_IFA_UPDATE, RDMA_OP_IFA_UPDATE,
                 RDMA_OP_SD_UPDATE, RDMA_OP_CEQC_CREATE, RDMA_OP_CEQC_CREATE,
                 RDMA_OP_AEQC_CREATE};
    if (dev.cmq.executed_opcodes != expected)
      `uvm_error("PROBE", $sformatf("probe command sequence %p", dev.cmq.executed_opcodes))
    if (drv.sd_tables.size() != 4)
      `uvm_error("PROBE", $sformatf("%0d SDs for four object classes", drv.sd_tables.size()))
    if (dev.cmq.count(RDMA_DEV_CEQ) != 2 || dev.cmq.count(RDMA_DEV_AEQ) != 1)
      `uvm_error("PROBE", "device does not hold two CEQs and one AEQ")
    if (!dev.cmq.lookup(RDMA_DEV_CEQ, 5, eqc))
      `uvm_fatal("PROBE", "device does not hold CEQ 5")
    if (drv.ceqs.size() != 2 || drv.ceqs[1].mem_kbuf.alloc_type != RDMA_ALLOC_TYPE_INDIRECT)
      `uvm_fatal("PROBE", "driver CEQ 5 buffer is not an INDIRECT allocation")
    if (rdma_be::field(eqc.bytes, RDMA_EQC_BODY_CUR_EQ_PBA_WORD_BYTE_OFFSET - 16,
                       RDMA_EQC_BODY_CUR_EQ_PBA_LSB, RDMA_EQC_BODY_CUR_EQ_PBA_WIDTH) !=
        drv.ceqs[1].mem_kbuf.base_iova() >> 12)
      `uvm_error("PROBE", "CEQ 5 context does not carry its PD table address")
    dev.cmq.hmc_addr(0, 5 * RDMA_QPC_BYTES, iova, status);
    expect_ok("HMC QPC 5", status);
    if (iova != drv.hmc[0].pages[0].iova + 5 * RDMA_QPC_BYTES)
      `uvm_error("PROBE", "device HMC translation of QPC 5 does not match the driver page")
    dev.cmq.hmc_addr(3, 600 * 8, iova, status);
    expect_ok("HMC PBL 600", status);
    if (iova != drv.hmc[3].pages[1].iova + (600 - 512) * 8)
      `uvm_error("PROBE", "device HMC translation of PBLE 600 does not match the driver page")
    dev.cmq.buffer_addr(RDMA_ALLOC_TYPE_INDIRECT, drv.ceqs[0].mem_kbuf.base_iova() >> 12, 48, iova,
                        status);
    expect_ok("CEQ buffer", status);
    if (iova != drv.ceqs[0].mem_kbuf.pages[0].iova + 48)
      `uvm_error("PROBE", "device INDIRECT translation of the CEQ buffer is wrong")
    void'(drv.hmc[0].locate(0, page, offset));
    expect_ok("read QP0", drv.hw.read(page, offset, RDMA_QPC_BYTES, qpc));
    if (rdma_be::field(qpc, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                       RDMA_QPC_QP_ST_WIDTH) != 4 ||
        rdma_be::field(qpc, RDMA_QPC_VF_ID_WORD_BYTE_OFFSET, RDMA_QPC_VF_ID_LSB,
                       RDMA_QPC_VF_ID_WIDTH) != 3)
      `uvm_error("PROBE", "QP0 context was not set to ERR with the VF id")
  endtask

  // 功能：remove 追加 TQ_FLUSH、OCC_FLUSH、AEQC_DELETE、CEQC_DELETE×2、SD_UPDATE（清除），
  //   设备 EQ 全部删除，驱动分配的 DMA 内存全部归还。
  // 输入/输出及副作用：只读。
  // 失败/边界：不符报告 UVM_ERROR。
  function void check_remove();
    bit [7:0] tail[$];
    bit [7:0] expected[$];

    tail = dev.cmq.executed_opcodes[8:$];
    expected = '{RDMA_OP_TQ_FLUSH, RDMA_OP_OCC_FLUSH, RDMA_OP_AEQC_DELETE, RDMA_OP_CEQC_DELETE,
                 RDMA_OP_CEQC_DELETE, RDMA_OP_SD_UPDATE};
    if (tail != expected)
      `uvm_error("REMOVE", $sformatf("remove command sequence %p", tail))
    if (dev.cmq.count(RDMA_DEV_CEQ) != 0 || dev.cmq.count(RDMA_DEV_AEQ) != 0)
      `uvm_error("REMOVE", "device still holds event queues")
    if (mem.live_allocations() != 0)
      `uvm_error("REMOVE", $sformatf("%0d DMA allocations leaked", mem.live_allocations()))
  endfunction
endclass
