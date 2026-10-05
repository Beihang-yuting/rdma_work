// 目录：设备层 src/dev/rdma_dev.sv。
// 职责：NIC 设备顶层：按 BAR 偏移把寄存器写分派给 CMQ 与各 doorbell 处理单元
//   （xtrdma_hw.h 的 XTRDMA_PF_NTFE_* 位于 BAR+0x2000 起的 notify 窗口）。
// 依赖：rdma_dev_cmq、rdma_host_mem_api、rdma_defs.svh。
// 所有权与生命周期：拥有 CMQ 消费者/context 存储与数据面 NIC；host_mem 只借用；configure 复位。
class rdma_dev extends uvm_object;
  `rdma_object_utils(rdma_dev)

  rdma_dev_cmq cmq;
  rdma_dev_nic nic;
  // 观测：收到的数据面/QP 控制 doorbell（notify 窗口内偏移与值），由数据面单元消费。
  bit [63:0] doorbell_offsets[$];
  bit [63:0] doorbell_values[$];

  // 功能：构造设备及其 CMQ 消费者。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：configure 前寄存器写返回 INVALID_STATE。
  function new(string name = "rdma_dev");
    super.new(name);
    cmq = rdma_dev_cmq::type_id::create({name, "_cmq"});
    nic = rdma_dev_nic::type_id::create({name, "_nic"});
    nic.ctx = cmq;
  endfunction

  // 功能：绑定设备 DMA 使用的主机内存并复位。
  // 输入/输出及副作用：保存非拥有引用。
  // 失败/边界：无。
  function void configure(rdma_host_mem_api host_mem);
    cmq.configure(host_mem);
    nic.host_mem = host_mem;
    nic.reset();
  endfunction

  // 功能：BAR 寄存器写：notify 窗口内按偏移分派。
  // 输入/输出及副作用：转交对应单元。
  // 失败/边界：窗口外或尚未建模的寄存器返回 INVALID_ARGUMENT/UNSUPPORTED_OPCODE。
  function rdma_status write_register(bit [63:0] bar_offset, bit [63:0] value);
    bit [63:0] offset;

    if (bar_offset < RDMA_NOTIFY_WINDOW_OFFSET ||
        bar_offset >= RDMA_NOTIFY_WINDOW_OFFSET + RDMA_NOTIFY_WINDOW_SIZE)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "BAR write is outside the notify window");
    offset = bar_offset - RDMA_NOTIFY_WINDOW_OFFSET;
    if (offset inside {RDMA_DB_CMQC_HIGH_OFFSET, RDMA_DB_CMQC_LOW_OFFSET, RDMA_DB_CMQ_OFFSET})
      return cmq.write_register(offset, value);
    if (offset inside {RDMA_DB_SQ_OFFSET, RDMA_DB_RQ_OFFSET, RDMA_DB_CQ_OFFSET, RDMA_DB_CEQ_OFFSET,
                       RDMA_DB_AEQ_OFFSET, RDMA_DB_SRFQ_OFFSET, RDMA_DB_RTS2SQD_OFFSET,
                       RDMA_DB_SQD2RTS_OFFSET, RDMA_DB_QP_FLUSH_OFFSET,
                       RDMA_DB_TX_FLUSH_OFFSET}) begin
      doorbell_offsets.push_back(offset);
      doorbell_values.push_back(value);
      if (offset == RDMA_DB_SQ_OFFSET)
        nic.sq_doorbell(value);
      if (offset == RDMA_DB_CQ_OFFSET)
        nic.cq_doorbell(value);
      return rdma_status::success();
    end
    return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                             $sformatf("notify register %0h is not modeled", offset));
  endfunction
endclass
