// 目录：设备层 src/dev/rdma_dev_cmq.sv。
// 职责：NIC 的 CMQ 消费者与 context 存储。驱动经 CMQC_HIGH 写 SQ 基址、CMQC_LOW 使能
//   （cmq.c xtrdma_sc_cmq_create），每次 CMQ doorbell 给出新 PI/polarity；设备按序 DMA 读取 SQE，
//   按 opcode 更新 context 表，再把完成写入紧随 SQ 的 CQ 环（cmq.c 的 sq_buf/cq_buf 布局）。
// 依赖：rdma_dev_dma（设备 DMA 端口）、rdma_defs.svh 的 CMQ/MRT/doorbell 字段常量。
// 所有权与生命周期：context 表与 DMA 端口归本对象（NIC 共用该端口）；reset 清空全部设备状态。
// 设计说明：设备保存驱动下发的 context 原始字节（QPC 为 512B 缓冲区，其余为 SQE 中的 context 区），
//   查询类命令按驱动 *_cqe_info 读取的偏移原样回填；数据面（NIC）按需解码这些字节。

typedef enum int {
  RDMA_DEV_QP,
  RDMA_DEV_CQ,
  RDMA_DEV_CEQ,
  RDMA_DEV_AEQ,
  RDMA_DEV_SRQ,
  RDMA_DEV_MR
} rdma_dev_kind_e;

// 设备保存的一个 context。
class rdma_dev_object extends uvm_object;
  `rdma_object_utils(rdma_dev_object)

  byte unsigned bytes[];
  // CQ：最近一次 CQC_RESIZE 的 SQE（新基址/尺寸/旧 CI），由数据面在 resize 后采用。
  byte unsigned resize_sqe[];
  // CQ：最近一次 CQC_MODIFY 的 SQE qword0（状态与 URC 标志）。
  bit [63:0] modify_word;

  // 功能：构造对象并置默认状态。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_dev_object");
    super.new(name);
    modify_word = '0;
  endfunction
endclass

class rdma_dev_cmq extends uvm_object;
  `rdma_object_utils(rdma_dev_cmq)

  // cmq.h XTRDMA_CMQ_SQ_SIZE / XTRDMA_CMQ_CQ_SIZE。
  localparam int unsigned DEPTH = 32;
  localparam int unsigned CQ_OFFSET = DEPTH * RDMA_CMQE_BYTES;
  // cmq.h：CQC/MRT 查询结果在 CQE 中的字节偏移；EQC/SRFQC context 在 SQE/CQE 的字节偏移与长度。
  localparam int unsigned CQC_QUERY_OFFSET = 8;
  localparam int unsigned MRT_QUERY_OFFSET = 16;
  localparam int unsigned EQ_CTX_OFFSET = 16;
  localparam int unsigned EQ_CTX_BYTES = 32;

  // 数据面：CQC_RESIZE 需在命令完成前由 NIC 在旧 CQ 写 RESIZE CQE 并切换生产者位置。
  rdma_dev_nic nic;
  // 故障注入：置位后接受 CMQ doorbell 但不消费 SQE（命令永不完成，驱动超时）；复位清除。
  bit stall;
  // 故障注入：下一条 opcode 为 fail_opcode 的命令不执行（无状态效果），以 fail_ecode 完成。
  protected bit fail_armed;
  protected bit [7:0] fail_opcode;
  protected bit [7:0] fail_ecode;
  // 设备 DMA 端口（CMQ 与 NIC 共用）。
  rdma_dev_dma dma;
  protected bit [63:0] sq_pa;
  protected bit enabled;
  protected longint unsigned sq_seq;
  protected longint unsigned cq_seq;
  protected rdma_dev_object objects[rdma_dev_kind_e][int unsigned];
  // HMC：IFA_UPDATE 的每类对象 data 字（FVM_SOA 等），SD_UPDATE 的 SD 号 → PD 表（或页）地址。
  protected bit [63:0] ifa_data[4];
  protected bit [63:0] sd_pa[int unsigned];
  // 观测：按序执行过的 opcode 与对应 ecode。
  bit [7:0] executed_opcodes[$];
  bit [7:0] executed_ecodes[$];

  // 功能：构造对象并置默认状态。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_dev_cmq");
    super.new(name);
    dma = null;
    reset();
  endfunction

  // 功能：创建设备 DMA 端口（factory，可被覆盖）并绑定主机内存，清空状态。
  // 输入/输出及副作用：新建 dma；host_mem 为非拥有引用。
  // 失败/边界：host_mem 为 null 时之后的 doorbell 返回 INVALID_STATE。
  function void configure(rdma_host_mem host_mem_arg);
    dma = null;
    if (host_mem_arg != null) begin
      dma = rdma_dev_dma::type_id::create({get_name(), "_dma"});
      dma.host_mem = host_mem_arg;
    end
    reset();
  endfunction

  // 功能：设备复位：关闭 CMQ、清空游标与全部 context。
  // 输入/输出及副作用：修改本对象状态。
  // 失败/边界：无。
  function void reset();
    enabled = 1'b0;
    stall = 1'b0;
    fail_armed = 1'b0;
    sq_pa = '0;
    sq_seq = 0;
    cq_seq = 0;
    objects.delete();
    foreach (ifa_data[t])
      ifa_data[t] = '0;
    sd_pa.delete();
    executed_opcodes.delete();
    executed_ecodes.delete();
  endfunction

  // 功能：查找一个已创建的 context。
  // 输入/输出及副作用：obj 输出设备内部对象（调用方只读）。
  // 失败/边界：不存在返回 0 且 obj 为 null。
  function bit lookup(rdma_dev_kind_e kind, int unsigned id, output rdma_dev_object obj);
    obj = null;
    if (!objects.exists(kind) || !objects[kind].exists(id))
      return 1'b0;
    obj = objects[kind][id];
    return 1'b1;
  endfunction

  // 功能：故障注入：下一条 opcode 命令不执行并以 ecode 完成（一次性）。
  // 输入/输出及副作用：设置注入状态。
  // 失败/边界：复位清除。
  function void inject_failure(bit [7:0] opcode, bit [7:0] ecode);
    fail_armed = 1'b1;
    fail_opcode = opcode;
    fail_ecode = ecode;
  endfunction

  // 功能：取某类中任一（编号最小）已创建 context 的编号。
  // 输入/输出及副作用：id 输出。
  // 失败/边界：该类为空返回 0。
  function bit first_id(rdma_dev_kind_e kind, output int unsigned id);
    id = 0;
    if (!objects.exists(kind) || objects[kind].size() == 0)
      return 1'b0;
    return objects[kind].first(id);
  endfunction

  // 功能：某类 context 的数量。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：无。
  function int unsigned count(rdma_dev_kind_e kind);
    if (!objects.exists(kind))
      return 0;
    return objects[kind].num();
  endfunction

  // 功能：处理 notify 窗口内的 CMQ 寄存器写：CMQC_HIGH（SQ 基址）、CMQC_LOW（使能）、CMQ doorbell。
  // 输入/输出及副作用：offset 为 notify 窗口内偏移，value 为 8B 寄存器值；doorbell 触发 SQE 处理。
  // 失败/边界：非 CMQ 寄存器、未使能时的 doorbell、乱序 PI 或非法 SQE 返回错误。
  task write_register(bit [63:0] offset, bit [63:0] value, output rdma_status status);
    status = rdma_status::success();
    if (offset == RDMA_DB_CMQC_HIGH_OFFSET) begin
      sq_pa = value;
      return;
    end
    if (offset == RDMA_DB_CMQC_LOW_OFFSET) begin
      // cmq.c：PI/CI 初值 0，bit31 置 1 表示 CMQC 有效。
      enabled = value[31];
      sq_seq = 0;
      cq_seq = 0;
      return;
    end
    if (offset == RDMA_DB_CMQ_OFFSET) begin
      doorbell(value, status);
      return;
    end
    status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "not a CMQ register");
  endtask

  // 功能：CMQ doorbell：处理 [sq_seq, 目标序号) 的全部 SQE；目标序号由 PI 与 polarity 唯一确定。
  // 输入/输出及副作用：读 SQ、写 CQ、更新 context 表。
  // 失败/边界：未配置/未使能、目标不在下一圈内、任一 SQE 非法时返回错误并停在该 SQE。
  protected task doorbell(bit [63:0] value, output rdma_status status);
    longint unsigned target;
    bit [4:0] pi;
    bit polarity;

    status = rdma_status::success();
    if (dma == null || !enabled) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ is not enabled");
      return;
    end
    if (stall)
      return;
    pi = value[RDMA_CMQ_DB_PI_LSB +: RDMA_CMQ_DB_PI_WIDTH];
    polarity = value[RDMA_CMQ_DB_POLARITY_LSB];
    target = 0;
    for (longint unsigned s = sq_seq + 1; s <= sq_seq + DEPTH; s++)
      if (s % DEPTH == pi && ((s / DEPTH) & 1) == polarity)
        target = s;
    if (target == 0) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "CMQ doorbell PI is not ahead of the device");
      return;
    end
    while (sq_seq < target) begin
      consume_one(status);
      if (!status.ok())
        return;
    end
  endtask

  // 功能：读取并执行一个 SQE，写出对应 CQE。
  // 输入/输出及副作用：推进 sq_seq/cq_seq。
  // 失败/边界：DMA 失败、valid/wrap/index 与设备游标不符或执行发现协议错误时返回错误。
  protected task consume_one(output rdma_status status);
    byte unsigned sqe[];
    byte unsigned cqe[];
    bit [63:0] word0;
    bit lap;
    bit [7:0] ecode;

    read_bytes(sq_pa + (sq_seq % DEPTH) * RDMA_CMQE_BYTES, RDMA_CMQE_BYTES, sqe, status);
    if (!status.ok())
      return;
    word0 = rdma_be::qword(sqe, 0);
    lap = (sq_seq / DEPTH) & 1;
    // cmq.c：VALID=polarity，WRAP=!polarity；polarity 每圈翻转，首圈为 1。
    if (word0[RDMA_CMQ_WRAP_LSB] != lap || word0[RDMA_CMQ_VALID_LSB] == lap ||
        word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] != sq_seq % DEPTH) begin
      status = rdma_status::make(RDMA_SC_CODEC_ERROR, "CMQ SQE envelope does not match the ring");
      return;
    end
    cqe = new[RDMA_CMQE_BYTES];
    foreach (cqe[i])
      cqe[i] = 0;
    if (fail_armed && word0[RDMA_CMQ_OPCODE_LSB +: 8] == fail_opcode) begin
      fail_armed = 1'b0;
      ecode = fail_ecode;
    end
    else begin
      execute(sqe, cqe, ecode, status);
      if (!status.ok())
        return;
    end
    sq_seq++;
    executed_opcodes.push_back(word0[RDMA_CMQ_OPCODE_LSB +: 8]);
    executed_ecodes.push_back(ecode);
    write_cqe(word0, ecode, cqe, status);
  endtask

  // 功能：写出 CQE：owner 按 CQ 圈数取值，wrap/index/opcode 回显 SQE，ecode 为执行结果。
  // 输入/输出及副作用：写 CQ 环，推进 cq_seq。
  // 失败/边界：DMA 失败返回其 status。
  protected task write_cqe(bit [63:0] sqe_word0, bit [7:0] ecode, byte unsigned cqe[],
                           output rdma_status status);
    bit [63:0] head;

    head = rdma_be::qword(cqe, 0);
    head[RDMA_CMQ_VALID_LSB] = !((cq_seq / DEPTH) & 1);
    head[RDMA_CMQ_WRAP_LSB] = sqe_word0[RDMA_CMQ_WRAP_LSB];
    head[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] =
      sqe_word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH];
    head[RDMA_CMQ_OPCODE_LSB +: 8] = sqe_word0[RDMA_CMQ_OPCODE_LSB +: 8];
    head[RDMA_CMQ_CMD_ECODE_LSB +: 8] = ecode;
    rdma_be::put_qword(cqe, 0, head);
    write_bytes(sq_pa + CQ_OFFSET + (cq_seq % DEPTH) * RDMA_CMQE_BYTES, cqe, status);
    if (status.ok())
      cq_seq++;
  endtask

  // 功能：按 opcode 执行一条命令：更新 context 表，查询类在 cqe 中回填结果。
  // 输入/输出及副作用：cqe 为 64B 完成缓冲（qword0 由调用方补全），ecode 输出。
  // 失败/边界：协议错误（签名不符、操作不存在的 QP/SRQ/MR）返回错误 status。
  protected task execute(byte unsigned sqe[], inout byte unsigned cqe[], output bit [7:0] ecode,
                         output rdma_status status);
    bit [7:0] opcode;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    status = rdma_status::success();
    opcode = rdma_be::qword(sqe, 0) >> RDMA_CMQ_OPCODE_LSB;
    case (opcode)
      RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY, RDMA_OP_QPC_QUERY, RDMA_OP_QPC_DELETE,
      RDMA_OP_QPC_FORCE_DELETE: begin
        execute_qp(opcode, sqe, ecode, status);
      end
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER, RDMA_OP_MR_DEREGISTER, RDMA_OP_KEY_QUERY: begin
        status = execute_mr(opcode, sqe, cqe, ecode);
      end
      RDMA_OP_CQC_CREATE, RDMA_OP_CQC_MODIFY, RDMA_OP_CQC_RESIZE, RDMA_OP_CQC_DELETE,
      RDMA_OP_CQC_FORCE_DELETE, RDMA_OP_CQC_QUERY: begin
        execute_cq(opcode, sqe, cqe, ecode);
      end
      RDMA_OP_CEQC_CREATE, RDMA_OP_CEQC_MODIFY, RDMA_OP_CEQC_DELETE, RDMA_OP_CEQC_QUERY: begin
        execute_eq(RDMA_DEV_CEQ, opcode, sqe, cqe, ecode);
      end
      RDMA_OP_AEQC_CREATE, RDMA_OP_AEQC_MODIFY, RDMA_OP_AEQC_DELETE, RDMA_OP_AEQC_QUERY: begin
        execute_eq(RDMA_DEV_AEQ, opcode, sqe, cqe, ecode);
      end
      RDMA_OP_SRFQC_CREATE, RDMA_OP_SRFQC_MODIFY, RDMA_OP_SRFQC_DELETE,
      RDMA_OP_SRFQC_QUERY: begin
        status = execute_srq(opcode, sqe, cqe, ecode);
      end
      RDMA_OP_SD_UPDATE: begin
        update_sds(sqe, status);
      end
      RDMA_OP_IFA_UPDATE: begin
        ifa_data[(rdma_be::qword(sqe, 0) >> 60) & 2'b11] = rdma_be::qword(sqe, 8);
      end
      default: begin
        // OCC/TQ flush、IFA/GID/MAC 等表项：设备侧无可观测状态，按成功完成。
      end
    endcase
  endtask

  // 功能：SD_UPDATE：校验签名后记录每个 SD 表项（前 2 项在 SQE 字节 32 起，其余在 sd_buf_addr）；
  //   VF_VALID=0 的表项表示清除。
  // 输入/输出及副作用：更新 sd_pa；DMA 读扩展表。
  // 失败/边界：签名不符或 DMA 失败返回错误。
  protected task update_sds(byte unsigned sqe[], output rdma_status status);
    int unsigned n;
    byte unsigned entries[];
    byte unsigned extra[];
    int unsigned idx;

    check_sd_signature(sqe, status);
    if (!status.ok())
      return;
    n = rdma_be::qword(sqe, 0) & 8'hff;
    entries = rdma_be::slice(sqe, 32, RDMA_SD_CARRIED_IN_SQE * RDMA_SD_ENTRY_BYTES);
    if (n > RDMA_SD_CARRIED_IN_SQE) begin
      read_bytes(rdma_be::qword(sqe, 24), (n - RDMA_SD_CARRIED_IN_SQE) * RDMA_SD_ENTRY_BYTES,
                 extra, status);
      if (!status.ok())
        return;
      entries = {entries, extra};
    end
    for (int unsigned i = 0; i < n; i++) begin
      idx = rdma_be::field(entries, i * RDMA_SD_ENTRY_BYTES + RDMA_SD_ENTRY_IDX_WORD_BYTE_OFFSET,
                           RDMA_SD_ENTRY_IDX_LSB, RDMA_SD_ENTRY_IDX_WIDTH);
      if (rdma_be::field(entries, i * RDMA_SD_ENTRY_BYTES + RDMA_SD_ENTRY_VF_VALID_WORD_BYTE_OFFSET,
                         RDMA_SD_ENTRY_VF_VALID_LSB, RDMA_SD_ENTRY_VF_VALID_WIDTH))
        sd_pa[idx] = rdma_be::field(entries, i * RDMA_SD_ENTRY_BYTES +
                                    RDMA_SD_ENTRY_PA_WORD_BYTE_OFFSET, RDMA_SD_ENTRY_PA_LSB,
                                    RDMA_SD_ENTRY_PA_WIDTH) << RDMA_SD_ENTRY_PA_LSB;
      else
        sd_pa.delete(idx);
    end
  endtask

  // 功能：HMC 对象地址：obj_type 类对象区内 offset 处 → FVM 地址（FVM_SOA<<9 + offset）→ SD →
  //   PD 表项 → 页 + 页内偏移（4K INDIRECT）。
  // 输入/输出及副作用：iova 输出；DMA 读 PD 表项。
  // 失败/边界：对象类未配置、SD 未建立或 PD 表项无效返回 DMA_TRANSLATION。
  task hmc_addr(int unsigned obj_type, longint unsigned offset, output bit [63:0] iova,
                output rdma_status status);
    bit [63:0] fvm;
    bit [63:0] entry;
    int unsigned sd;
    byte unsigned bytes[];

    iova = '0;
    if (!ifa_data[obj_type][RDMA_IFA_DATA_VALID_LSB]) begin
      status = rdma_status::make(RDMA_SC_DMA_TRANSLATION, "HMC object class is not configured");
      return;
    end
    fvm = (ifa_data[obj_type][RDMA_IFA_DATA_FVM_SOA_LSB +: RDMA_IFA_DATA_FVM_SOA_WIDTH]
           << RDMA_HMC_FVM_SOA_SHIFT) + offset;
    sd = fvm / (RDMA_HMC_PAGE_BYTES * RDMA_HMC_PD_PER_SD);
    if (!sd_pa.exists(sd)) begin
      status = rdma_status::make(RDMA_SC_DMA_TRANSLATION, "HMC SD is not mapped");
      return;
    end
    read_bytes(sd_pa[sd] + ((fvm / RDMA_HMC_PAGE_BYTES) % RDMA_HMC_PD_PER_SD) * 8, 8, bytes,
               status);
    if (!status.ok())
      return;
    entry = rdma_be::qword(bytes, 0);
    if (!entry[RDMA_PD_ENTRY_VLD_LSB]) begin
      status = rdma_status::make(RDMA_SC_DMA_TRANSLATION, "HMC PD entry is not valid");
      return;
    end
    iova = ((entry >> RDMA_PD_ENTRY_PBA_LSB) << RDMA_PD_ENTRY_PBA_LSB) +
           fvm % RDMA_HMC_PAGE_BYTES;
  endtask

  // 功能：队列缓冲地址：HUGE/DIRECT 为 (pba<<12)+offset；INDIRECT 先读 PD 表 (pba<<12) 的第
  //   offset/4K 项，再加页内偏移。
  // 输入/输出及副作用：iova 输出；可能 DMA 读 PD 表。
  // 失败/边界：PD 表项无效或 L3 模式返回 DMA_TRANSLATION。
  task buffer_addr(int unsigned om, bit [63:0] pba, longint unsigned offset,
                   output bit [63:0] iova, output rdma_status status);
    byte unsigned bytes[];
    bit [63:0] entry;

    iova = (pba << 12) + offset;
    status = rdma_status::success();
    if (om != RDMA_ALLOC_TYPE_INDIRECT) begin
      if (om == RDMA_ALLOC_TYPE_L3_INDIRECT)
        status = rdma_status::make(RDMA_SC_DMA_TRANSLATION, "L3 indirect buffers are not modeled");
      return;
    end
    read_bytes((pba << 12) + (offset / RDMA_HMC_PAGE_BYTES) * 8, 8, bytes, status);
    if (!status.ok())
      return;
    entry = rdma_be::qword(bytes, 0);
    if (!entry[RDMA_PD_ENTRY_VLD_LSB]) begin
      status = rdma_status::make(RDMA_SC_DMA_TRANSLATION, "buffer PD entry is not valid");
      return;
    end
    iova = ((entry >> RDMA_PD_ENTRY_PBA_LSB) << RDMA_PD_ENTRY_PBA_LSB) +
           offset % RDMA_HMC_PAGE_BYTES;
  endtask

  // 功能：SD_UPDATE：sd_num>2 时（SIGN_EN），签名覆盖整条 SQE 与 sd_buf_addr 处的扩展 SD 表
  //   （cmq.c xtrdma_sc_update_sd），含签名的全体异或恒为 0xff。
  // 输入/输出及副作用：DMA 读扩展表。
  // 失败/边界：签名不符或 DMA 失败返回错误。
  protected task check_sd_signature(byte unsigned sqe[], output rdma_status status);
    int unsigned n;
    byte unsigned extra[];

    status = rdma_status::success();
    if (!rdma_be::field(sqe, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET, RDMA_CMQ_SIGN_EN_LSB,
                        RDMA_CMQ_SIGN_EN_WIDTH))
      return;
    n = rdma_be::qword(sqe, 0) & 8'hff;
    read_bytes(rdma_be::qword(sqe, 24), (n - RDMA_SD_CARRIED_IN_SQE) * RDMA_SD_ENTRY_BYTES, extra,
               status);
    if (!status.ok())
      return;
    if ((rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(extra)) != 8'hff)
      status = rdma_status::make(RDMA_SC_CODEC_ERROR, "SD_UPDATE signature mismatch");
  endtask

  // 功能：QP 命令。CREATE/全量 MODIFY 从 QPC 缓冲区 DMA 读取 512B 并校验签名；仅状态 MODIFY
  //   改写 QPC 状态字段；部分 MODIFY 按 4 个 (起始 qword, 字节使能, 数据) 模板写入；
  //   QUERY 把 QPC DMA 写回缓冲区；DELETE 删除。
  // 输入/输出及副作用：更新 QP 表或主机内存。
  // 失败/边界：签名不符、DMA 失败或操作不存在的 QP 返回错误。
  protected task execute_qp(bit [7:0] opcode, byte unsigned sqe[], output bit [7:0] ecode,
                            output rdma_status status);
    int unsigned qpn;
    bit [63:0] buffer;
    bit [1:0] mode;
    rdma_dev_object obj;
    byte unsigned qpc[];
    int unsigned old_state;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    status = rdma_status::success();
    qpn = rdma_be::field(sqe, RDMA_CMQ_QPN_WORD_BYTE_OFFSET, RDMA_CMQ_QPN_LSB, RDMA_CMQ_QPN_WIDTH);
    old_state = qp_state(qpn);
    buffer = rdma_be::field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                            RDMA_CMQ_QPC_BUFFER_ADDR_LSB,
                            RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH) << RDMA_CMQ_QPC_BUFFER_ADDR_LSB;
    mode = rdma_be::field(sqe, RDMA_CMQ_MODIFY_MODE_WORD_BYTE_OFFSET, RDMA_CMQ_MODIFY_MODE_LSB,
                 RDMA_CMQ_MODIFY_MODE_WIDTH);
    if (opcode == RDMA_OP_QPC_CREATE ||
        (opcode == RDMA_OP_QPC_MODIFY && mode == RDMA_QPC_MODIFY_FULL)) begin
      if (opcode == RDMA_OP_QPC_MODIFY && !lookup(RDMA_DEV_QP, qpn, obj)) begin
        status = rdma_status::make(RDMA_SC_INVALID_STATE, "QPC_MODIFY on an absent QP");
        return;
      end
      obj = rdma_dev_object::type_id::create($sformatf("qpc_%0d", qpn));
      read_bytes(buffer, RDMA_QPC_BYTES, obj.bytes, status);
      if (!status.ok())
        return;
      // cmq.c：签名 = ~(SQE 其余字节异或 ^ QPC 字节异或)，故含签名的全体异或恒为 0xff。
      if ((rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(obj.bytes)) != 8'hff) begin
        status = rdma_status::make(RDMA_SC_CODEC_ERROR, "QPC command signature mismatch");
        return;
      end
      objects[RDMA_DEV_QP][qpn] = obj;
      if (opcode == RDMA_OP_QPC_CREATE && nic != null)
        nic.forget(RDMA_DEV_QP, qpn);
      if (nic != null)
        nic.qpc_written(qpn, old_state);
      return;
    end
    if (!lookup(RDMA_DEV_QP, qpn, obj)) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "QP command on an absent QP");
      return;
    end
    if (opcode == RDMA_OP_QPC_QUERY) begin
      write_bytes(buffer, obj.bytes, status);
      return;
    end
    if (opcode != RDMA_OP_QPC_MODIFY) begin
      objects[RDMA_DEV_QP].delete(qpn);
      return;
    end
    qpc = obj.bytes;
    if (mode == RDMA_QPC_MODIFY_STATE_ONLY)
      rdma_be::set_field(qpc, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                         RDMA_QPC_QP_ST_WIDTH,
                         rdma_be::field(sqe, RDMA_CMQ_NEXT_QP_STATE_WORD_BYTE_OFFSET,
                                        RDMA_CMQ_NEXT_QP_STATE_LSB,
                                        RDMA_CMQ_NEXT_QP_STATE_WIDTH));
    else
      apply_partial(qpc, sqe);
    obj.bytes = qpc;
    if (nic != null)
      nic.qpc_written(qpn, old_state);
  endtask

  // 功能：QP 当前状态（QPC QP_ST）。
  // 输入/输出及副作用：纯查询。
  // 失败/边界：QP 不存在返回 0（RESET）。
  protected function int unsigned qp_state(int unsigned qpn);
    rdma_dev_object obj;

    if (!lookup(RDMA_DEV_QP, qpn, obj))
      return 0;
    return rdma_be::field(obj.bytes, RDMA_QPC_QP_ST_WORD_BYTE_OFFSET, RDMA_QPC_QP_ST_LSB,
                          RDMA_QPC_QP_ST_WIDTH);
  endfunction

  // 功能：部分修改：模板 t 的 start_qword/wbe 在 SQE qword2（每模板 16 位），数据在 qword4+t；
  //   wbe 第 7-b 位对应该 qword 的第 b 个字节（大端序，b=0 为最高字节）。
  // 输入/输出及副作用：修改 qpc 字节。
  // 失败/边界：越界 qword 被忽略。
  protected function void apply_partial(inout byte unsigned qpc[], input byte unsigned sqe[]);
    bit [63:0] layout;
    bit [5:0] start;
    bit [7:0] wbe;
    bit [63:0] data;

    layout = rdma_be::qword(sqe, RDMA_CMQ_MODIFY_MODE_WORD_BYTE_OFFSET);
    for (int t = 0; t < 4; t++) begin
      start = layout[RDMA_CMQ_MODIFY_START_QWORD0_LSB - 16 * t +: 6];
      wbe = layout[RDMA_CMQ_MODIFY_WBE0_LSB - 16 * t +: 8];
      data = rdma_be::qword(sqe, RDMA_CMQ_MODIFY_DATA0_WORD_BYTE_OFFSET + 8 * t);
      if (start * 8 + 8 > qpc.size())
        continue;
      for (int b = 0; b < 8; b++)
        if (wbe[7 - b])
          qpc[start * 8 + b] = data[63 - 8 * b -: 8];
    end
  endfunction

  // 功能：MR 命令。KEY_ALLOC/MR_REGISTER 保存 64B MRT body（SQE 全文），MR_DEREGISTER 按 NXT_ST
  //   删除或保留，KEY_QUERY 在 CQE 字节 16 起回填 MRT body。
  // 输入/输出及副作用：更新 MR 表或 cqe。
  // 失败/边界：注销/查询不存在的 MR 返回错误。
  protected function rdma_status execute_mr(bit [7:0] opcode, byte unsigned sqe[],
                                            inout byte unsigned cqe[], output bit [7:0] ecode);
    int unsigned stag;
    rdma_dev_object obj;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    stag = rdma_be::field(sqe, RDMA_MRT_BODY_STAG_IDX_WORD_BYTE_OFFSET, RDMA_MRT_BODY_STAG_IDX_LSB,
                 RDMA_MRT_BODY_STAG_IDX_WIDTH);
    if (opcode == RDMA_OP_KEY_ALLOC || opcode == RDMA_OP_MR_REGISTER) begin
      obj = rdma_dev_object::type_id::create($sformatf("mrt_%0d", stag));
      obj.bytes = sqe;
      objects[RDMA_DEV_MR][stag] = obj;
      return rdma_status::success();
    end
    if (!lookup(RDMA_DEV_MR, stag, obj))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "MR command on an absent MR");
    if (opcode == RDMA_OP_KEY_QUERY) begin
      for (int unsigned i = MRT_QUERY_OFFSET; i < RDMA_CMQE_BYTES; i++)
        cqe[i] = obj.bytes[i];
      return rdma_status::success();
    end
    if (rdma_be::field(sqe, RDMA_MRT_BODY_NXT_ST_WORD_BYTE_OFFSET, RDMA_MRT_BODY_NXT_ST_LSB,
              RDMA_MRT_BODY_NXT_ST_WIDTH) == RDMA_MR_ST_INVALID)
      objects[RDMA_DEV_MR].delete(stag);
    return rdma_status::success();
  endfunction

  // 功能：CQ 命令。CREATE 保存 SQE 中 56B CQC；MODIFY/RESIZE 记录参数；DELETE 删除；
  //   QUERY 在 CQE 字节 8 起回填 CQC。删除/查询不存在的 CQ 返回 CQC_INVLD。
  // 输入/输出及副作用：更新 CQ 表或 cqe。
  // 失败/边界：无协议错误路径。
  protected task execute_cq(bit [7:0] opcode, byte unsigned sqe[], inout byte unsigned cqe[],
                            output bit [7:0] ecode);
    int unsigned cqn;
    rdma_dev_object obj;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqn = rdma_be::field(sqe, RDMA_CQC_BODY_CQN_WORD_BYTE_OFFSET, RDMA_CQC_BODY_CQN_LSB,
                RDMA_CQC_BODY_CQN_WIDTH);
    if (opcode == RDMA_OP_CQC_CREATE) begin
      obj = rdma_dev_object::type_id::create($sformatf("cqc_%0d", cqn));
      obj.bytes = rdma_be::slice(sqe, CQC_QUERY_OFFSET, RDMA_CMQE_BYTES - CQC_QUERY_OFFSET);
      objects[RDMA_DEV_CQ][cqn] = obj;
      if (nic != null)
        nic.forget(RDMA_DEV_CQ, cqn);
      return;
    end
    if (!lookup(RDMA_DEV_CQ, cqn, obj)) begin
      ecode = RDMA_ECODE_EC_RCE_CQC_INVLD;
      return;
    end
    case (opcode)
      RDMA_OP_CQC_MODIFY: obj.modify_word = rdma_be::qword(sqe, 0);
      RDMA_OP_CQC_RESIZE: begin
        obj.resize_sqe = sqe;
        resize_cq(cqn, obj, sqe);
      end
      RDMA_OP_CQC_QUERY: begin
        foreach (obj.bytes[i])
          cqe[CQC_QUERY_OFFSET + i] = obj.bytes[i];
      end
      default: objects[RDMA_DEV_CQ].delete(cqn);
    endcase
  endtask

  // 功能：CQC_RESIZE：NIC 先在旧 CQ 写 RESIZE CQE 并把生产者位置接到新 CQ，再把 CQC 的
  //   CUR_CQ_PD_PBA/CQ_SIZE/CQ_OM 改为命令中的新值。
  // 输入/输出及副作用：修改 obj.bytes；经 NIC DMA 写旧 CQ。
  // 失败/边界：未接 NIC（纯控制面测试）时只更新 CQC。
  protected task resize_cq(int unsigned cqn, rdma_dev_object obj, byte unsigned sqe[]);
    if (nic != null)
      nic.resize_cq(cqn, sqe);
    rdma_be::set_field(obj.bytes,
                       RDMA_CQC_BODY_CUR_CQ_PD_PBA_WORD_BYTE_OFFSET - CQC_QUERY_OFFSET,
                       RDMA_CQC_BODY_CUR_CQ_PD_PBA_LSB, RDMA_CQC_BODY_CUR_CQ_PD_PBA_WIDTH,
                       `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_CQ_SD_OR_PD_PBA));
    rdma_be::set_field(obj.bytes, RDMA_CQC_BODY_CQ_SIZE_WORD_BYTE_OFFSET - CQC_QUERY_OFFSET,
                       RDMA_CQC_BODY_CQ_SIZE_LSB, RDMA_CQC_BODY_CQ_SIZE_WIDTH,
                       `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_CQ_SIZE));
    rdma_be::set_field(obj.bytes, RDMA_CQC_BODY_CQ_OM_WORD_BYTE_OFFSET - CQC_QUERY_OFFSET,
                       RDMA_CQC_BODY_CQ_OM_LSB, RDMA_CQC_BODY_CQ_OM_WIDTH,
                       `RDMA_BE_GET(sqe, RDMA_CQC_RESIZE_CQ_OM));
  endtask

  // 功能：CEQ/AEQ 命令：context 在 SQE/CQE 字节 16..47，EQN 在 qword0 低 12 位。
  // 输入/输出及副作用：更新 EQ 表或 cqe。
  // 失败/边界：删除/查询不存在的 EQ 返回 CEQC_INVLD/AEQC_INVLD。
  protected function void execute_eq(rdma_dev_kind_e kind, bit [7:0] opcode,
                                     byte unsigned sqe[], inout byte unsigned cqe[],
                                     output bit [7:0] ecode);
    int unsigned eqn;
    rdma_dev_object obj;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    eqn = rdma_be::field(sqe, RDMA_EQC_BODY_EQN_WORD_BYTE_OFFSET, RDMA_EQC_BODY_EQN_LSB,
                RDMA_EQC_BODY_EQN_WIDTH);
    if (opcode inside {RDMA_OP_CEQC_CREATE, RDMA_OP_AEQC_CREATE, RDMA_OP_CEQC_MODIFY,
                       RDMA_OP_AEQC_MODIFY}) begin
      obj = rdma_dev_object::type_id::create($sformatf("eqc_%0d", eqn));
      obj.bytes = rdma_be::slice(sqe, EQ_CTX_OFFSET, EQ_CTX_BYTES);
      objects[kind][eqn] = obj;
      return;
    end
    if (!lookup(kind, eqn, obj)) begin
      ecode = RDMA_ECODE_EC_RCE_AEQC_INVLD;
      if (kind == RDMA_DEV_CEQ)
        ecode = RDMA_ECODE_EC_RCE_CEQC_INVLD;
      return;
    end
    if (!(opcode inside {RDMA_OP_CEQC_QUERY, RDMA_OP_AEQC_QUERY})) begin
      objects[kind].delete(eqn);
      return;
    end
    rdma_be::put_qword(cqe, 0, eqn);
    foreach (obj.bytes[i])
      cqe[EQ_CTX_OFFSET + i] = obj.bytes[i];
  endfunction

  // 功能：SRFQ 命令：context 在 SQE/CQE 字节 16..47，SRFQN 在 qword0 低 16 位。
  // 输入/输出及副作用：更新 SRQ 表或 cqe。
  // 失败/边界：删除/查询不存在的 SRFQ 返回错误 status。
  protected function rdma_status execute_srq(bit [7:0] opcode, byte unsigned sqe[],
                                             inout byte unsigned cqe[], output bit [7:0] ecode);
    int unsigned srfqn;
    rdma_dev_object obj;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    srfqn = rdma_be::field(sqe, RDMA_SRQC_BODY_SRFQN_WORD_BYTE_OFFSET, RDMA_SRQC_BODY_SRFQN_LSB,
                  RDMA_SRQC_BODY_SRFQN_WIDTH);
    if (opcode == RDMA_OP_SRFQC_CREATE || opcode == RDMA_OP_SRFQC_MODIFY) begin
      obj = rdma_dev_object::type_id::create($sformatf("srfqc_%0d", srfqn));
      obj.bytes = rdma_be::slice(sqe, EQ_CTX_OFFSET, EQ_CTX_BYTES);
      objects[RDMA_DEV_SRQ][srfqn] = obj;
      if (nic != null)
        nic.forget(RDMA_DEV_SRQ, srfqn);
      return rdma_status::success();
    end
    if (!lookup(RDMA_DEV_SRQ, srfqn, obj))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "SRFQ command on an absent SRQ");
    if (opcode == RDMA_OP_SRFQC_DELETE) begin
      objects[RDMA_DEV_SRQ].delete(srfqn);
      return rdma_status::success();
    end
    rdma_be::put_qword(cqe, 0, srfqn);
    foreach (obj.bytes[i])
      cqe[EQ_CTX_OFFSET + i] = obj.bytes[i];
    return rdma_status::success();
  endfunction

  // ---------------------------------------------------------------- DMA
  // 功能：经 DMA 端口读 size 字节到 out。
  // 输入/输出及副作用：读主机内存。
  // 失败/边界：DMA 失败返回其 status，out 为空。
  protected task read_bytes(bit [63:0] iova, int unsigned size, output byte unsigned out[],
                            output rdma_status status);
    dma.read(iova, size, out, status);
  endtask

  // 功能：经 DMA 端口写 bytes。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：DMA 失败返回其 status。
  protected task write_bytes(bit [63:0] iova, byte unsigned bytes[], output rdma_status status);
    dma.write(iova, bytes, status);
  endtask
endclass
