// 目录：设备层 src/dev/rdma_dev_cmq.sv。
// 职责：NIC 的 CMQ 消费者与 context 存储。驱动经 CMQC_HIGH 写 SQ 基址、CMQC_LOW 使能
//   （cmq.c xtrdma_sc_cmq_create），每次 CMQ doorbell 给出新 PI/polarity；设备按序 DMA 读取 SQE，
//   按 opcode 更新 context 表，再把完成写入紧随 SQ 的 CQ 环（cmq.c 的 sq_buf/cq_buf 布局）。
// 依赖：rdma_host_mem_api.dma_read/dma_write、rdma_defs.svh 的 CMQ/MRT/doorbell 字段常量。
// 所有权与生命周期：context 表归本对象；host_mem 只借用。reset 清空全部设备状态。
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

  protected rdma_host_mem_api host_mem;
  protected bit [63:0] sq_pa;
  protected bit enabled;
  protected longint unsigned sq_seq;
  protected longint unsigned cq_seq;
  protected rdma_dev_object objects[rdma_dev_kind_e][int unsigned];
  // 观测：按序执行过的 opcode 与对应 ecode。
  bit [7:0] executed_opcodes[$];
  bit [7:0] executed_ecodes[$];

  // 功能：构造对象并置默认状态。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_dev_cmq");
    super.new(name);
    host_mem = null;
    reset();
  endfunction

  // 功能：绑定设备 DMA 使用的主机内存并清空状态。
  // 输入/输出及副作用：保存非拥有引用。
  // 失败/边界：host_mem 为 null 时之后的 doorbell 返回 INVALID_STATE。
  function void configure(rdma_host_mem_api host_mem_arg);
    host_mem = host_mem_arg;
    reset();
  endfunction

  // 功能：设备复位：关闭 CMQ、清空游标与全部 context。
  // 输入/输出及副作用：修改本对象状态。
  // 失败/边界：无。
  function void reset();
    enabled = 1'b0;
    sq_pa = '0;
    sq_seq = 0;
    cq_seq = 0;
    objects.delete();
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
  function rdma_status write_register(bit [63:0] offset, bit [63:0] value);
    if (offset == RDMA_DB_CMQC_HIGH_OFFSET) begin
      sq_pa = value;
      return rdma_status::success();
    end
    if (offset == RDMA_DB_CMQC_LOW_OFFSET) begin
      // cmq.c：PI/CI 初值 0，bit31 置 1 表示 CMQC 有效。
      enabled = value[31];
      sq_seq = 0;
      cq_seq = 0;
      return rdma_status::success();
    end
    if (offset == RDMA_DB_CMQ_OFFSET)
      return doorbell(value);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "not a CMQ register");
  endfunction

  // 功能：CMQ doorbell：处理 [sq_seq, 目标序号) 的全部 SQE；目标序号由 PI 与 polarity 唯一确定。
  // 输入/输出及副作用：读 SQ、写 CQ、更新 context 表。
  // 失败/边界：未配置/未使能、目标不在下一圈内、任一 SQE 非法时返回错误并停在该 SQE。
  protected function rdma_status doorbell(bit [63:0] value);
    longint unsigned target;
    bit [4:0] pi;
    bit polarity;
    rdma_status status;

    if (host_mem == null || !enabled)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ is not enabled");
    pi = value[RDMA_CMQ_DB_PI_LSB +: RDMA_CMQ_DB_PI_WIDTH];
    polarity = value[RDMA_CMQ_DB_POLARITY_LSB];
    target = 0;
    for (longint unsigned s = sq_seq + 1; s <= sq_seq + DEPTH; s++)
      if (s % DEPTH == pi && ((s / DEPTH) & 1) == polarity)
        target = s;
    if (target == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ doorbell PI is not ahead of the device");
    while (sq_seq < target) begin
      status = consume_one();
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：读取并执行一个 SQE，写出对应 CQE。
  // 输入/输出及副作用：推进 sq_seq/cq_seq。
  // 失败/边界：DMA 失败、valid/wrap/index 与设备游标不符或执行发现协议错误时返回错误。
  protected function rdma_status consume_one();
    byte unsigned sqe[];
    byte unsigned cqe[];
    bit [63:0] word0;
    bit lap;
    bit [7:0] ecode;
    rdma_status status;

    status = read_bytes(sq_pa + (sq_seq % DEPTH) * RDMA_CMQE_BYTES, RDMA_CMQE_BYTES, sqe);
    if (!status.ok())
      return status;
    word0 = rdma_be::qword(sqe, 0);
    lap = (sq_seq / DEPTH) & 1;
    // cmq.c：VALID=polarity，WRAP=!polarity；polarity 每圈翻转，首圈为 1。
    if (word0[RDMA_CMQ_WRAP_LSB] != lap || word0[RDMA_CMQ_VALID_LSB] == lap ||
        word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] != sq_seq % DEPTH)
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "CMQ SQE envelope does not match the ring");
    cqe = new[RDMA_CMQE_BYTES];
    foreach (cqe[i])
      cqe[i] = 0;
    status = execute(sqe, cqe, ecode);
    if (!status.ok())
      return status;
    sq_seq++;
    executed_opcodes.push_back(word0[RDMA_CMQ_OPCODE_LSB +: 8]);
    executed_ecodes.push_back(ecode);
    return write_cqe(word0, ecode, cqe);
  endfunction

  // 功能：写出 CQE：owner 按 CQ 圈数取值，wrap/index/opcode 回显 SQE，ecode 为执行结果。
  // 输入/输出及副作用：写 CQ 环，推进 cq_seq。
  // 失败/边界：DMA 失败返回其 status。
  protected function rdma_status write_cqe(bit [63:0] sqe_word0, bit [7:0] ecode,
                                           byte unsigned cqe[]);
    bit [63:0] head;
    rdma_status status;

    head = rdma_be::qword(cqe, 0);
    head[RDMA_CMQ_VALID_LSB] = !((cq_seq / DEPTH) & 1);
    head[RDMA_CMQ_WRAP_LSB] = sqe_word0[RDMA_CMQ_WRAP_LSB];
    head[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] =
      sqe_word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH];
    head[RDMA_CMQ_OPCODE_LSB +: 8] = sqe_word0[RDMA_CMQ_OPCODE_LSB +: 8];
    head[RDMA_CMQ_CMD_ECODE_LSB +: 8] = ecode;
    rdma_be::put_qword(cqe, 0, head);
    status = write_bytes(sq_pa + CQ_OFFSET + (cq_seq % DEPTH) * RDMA_CMQE_BYTES, cqe);
    if (status.ok())
      cq_seq++;
    return status;
  endfunction

  // 功能：按 opcode 执行一条命令：更新 context 表，查询类在 cqe 中回填结果。
  // 输入/输出及副作用：cqe 为 64B 完成缓冲（qword0 由调用方补全），ecode 输出。
  // 失败/边界：协议错误（签名不符、操作不存在的 QP/SRQ/MR）返回错误 status。
  protected function rdma_status execute(byte unsigned sqe[], inout byte unsigned cqe[],
                                         output bit [7:0] ecode);
    bit [7:0] opcode;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    opcode = rdma_be::qword(sqe, 0) >> RDMA_CMQ_OPCODE_LSB;
    case (opcode)
      RDMA_OP_QPC_CREATE, RDMA_OP_QPC_MODIFY, RDMA_OP_QPC_QUERY, RDMA_OP_QPC_DELETE,
      RDMA_OP_QPC_FORCE_DELETE: begin
        return execute_qp(opcode, sqe, ecode);
      end
      RDMA_OP_KEY_ALLOC, RDMA_OP_MR_REGISTER, RDMA_OP_MR_DEREGISTER, RDMA_OP_KEY_QUERY: begin
        return execute_mr(opcode, sqe, cqe, ecode);
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
        return execute_srq(opcode, sqe, cqe, ecode);
      end
      RDMA_OP_SD_UPDATE: begin
        return check_sd_signature(sqe);
      end
      default: begin
        // OCC/TQ flush、IFA/GID/MAC 等表项：设备侧无可观测状态，按成功完成。
      end
    endcase
    return rdma_status::success();
  endfunction

  // 功能：SD_UPDATE：sd_num>2 时（SIGN_EN），签名覆盖整条 SQE 与 sd_buf_addr 处的扩展 SD 表
  //   （cmq.c xtrdma_sc_update_sd），含签名的全体异或恒为 0xff。
  // 输入/输出及副作用：DMA 读扩展表。
  // 失败/边界：签名不符或 DMA 失败返回错误。
  protected function rdma_status check_sd_signature(byte unsigned sqe[]);
    int unsigned n;
    byte unsigned extra[];
    rdma_status status;

    if (!rdma_be::field(sqe, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET, RDMA_CMQ_SIGN_EN_LSB,
                        RDMA_CMQ_SIGN_EN_WIDTH))
      return rdma_status::success();
    n = rdma_be::qword(sqe, 0) & 8'hff;
    status = read_bytes(rdma_be::qword(sqe, 24), (n - RDMA_SD_CARRIED_IN_SQE) * RDMA_SD_ENTRY_BYTES,
                        extra);
    if (!status.ok())
      return status;
    if ((rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(extra)) != 8'hff)
      return rdma_status::make(RDMA_SC_CODEC_ERROR, "SD_UPDATE signature mismatch");
    return rdma_status::success();
  endfunction

  // 功能：QP 命令。CREATE/全量 MODIFY 从 QPC 缓冲区 DMA 读取 512B 并校验签名；仅状态 MODIFY
  //   改写 QPC 状态字段；部分 MODIFY 按 4 个 (起始 qword, 字节使能, 数据) 模板写入；
  //   QUERY 把 QPC DMA 写回缓冲区；DELETE 删除。
  // 输入/输出及副作用：更新 QP 表或主机内存。
  // 失败/边界：签名不符、DMA 失败或操作不存在的 QP 返回错误。
  protected function rdma_status execute_qp(bit [7:0] opcode, byte unsigned sqe[],
                                            output bit [7:0] ecode);
    int unsigned qpn;
    bit [63:0] buffer;
    bit [1:0] mode;
    rdma_dev_object obj;
    byte unsigned qpc[];
    rdma_status status;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    qpn = rdma_be::field(sqe, RDMA_CMQ_QPN_WORD_BYTE_OFFSET, RDMA_CMQ_QPN_LSB, RDMA_CMQ_QPN_WIDTH);
    buffer = rdma_be::field(sqe, RDMA_CMQ_QPC_BUFFER_ADDR_WORD_BYTE_OFFSET,
                            RDMA_CMQ_QPC_BUFFER_ADDR_LSB,
                            RDMA_CMQ_QPC_BUFFER_ADDR_WIDTH) << RDMA_CMQ_QPC_BUFFER_ADDR_LSB;
    mode = rdma_be::field(sqe, RDMA_CMQ_MODIFY_MODE_WORD_BYTE_OFFSET, RDMA_CMQ_MODIFY_MODE_LSB,
                 RDMA_CMQ_MODIFY_MODE_WIDTH);
    if (opcode == RDMA_OP_QPC_CREATE ||
        (opcode == RDMA_OP_QPC_MODIFY && mode == RDMA_QPC_MODIFY_FULL)) begin
      if (opcode == RDMA_OP_QPC_MODIFY && !lookup(RDMA_DEV_QP, qpn, obj))
        return rdma_status::make(RDMA_SC_INVALID_STATE, "QPC_MODIFY on an absent QP");
      obj = rdma_dev_object::type_id::create($sformatf("qpc_%0d", qpn));
      status = read_bytes(buffer, RDMA_QPC_BYTES, obj.bytes);
      if (!status.ok())
        return status;
      // cmq.c：签名 = ~(SQE 其余字节异或 ^ QPC 字节异或)，故含签名的全体异或恒为 0xff。
      if ((rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(obj.bytes)) != 8'hff)
        return rdma_status::make(RDMA_SC_CODEC_ERROR, "QPC command signature mismatch");
      objects[RDMA_DEV_QP][qpn] = obj;
      return rdma_status::success();
    end
    if (!lookup(RDMA_DEV_QP, qpn, obj))
      return rdma_status::make(RDMA_SC_INVALID_STATE, "QP command on an absent QP");
    if (opcode == RDMA_OP_QPC_QUERY)
      return write_bytes(buffer, obj.bytes);
    if (opcode != RDMA_OP_QPC_MODIFY) begin
      objects[RDMA_DEV_QP].delete(qpn);
      return rdma_status::success();
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
    return rdma_status::success();
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
  protected function void execute_cq(bit [7:0] opcode, byte unsigned sqe[],
                                     inout byte unsigned cqe[], output bit [7:0] ecode);
    int unsigned cqn;
    rdma_dev_object obj;

    ecode = RDMA_CMQ_SUCCESS_ECODE;
    cqn = rdma_be::field(sqe, RDMA_CQC_BODY_CQN_WORD_BYTE_OFFSET, RDMA_CQC_BODY_CQN_LSB,
                RDMA_CQC_BODY_CQN_WIDTH);
    if (opcode == RDMA_OP_CQC_CREATE) begin
      obj = rdma_dev_object::type_id::create($sformatf("cqc_%0d", cqn));
      obj.bytes = rdma_be::slice(sqe, CQC_QUERY_OFFSET, RDMA_CMQE_BYTES - CQC_QUERY_OFFSET);
      objects[RDMA_DEV_CQ][cqn] = obj;
      return;
    end
    if (!lookup(RDMA_DEV_CQ, cqn, obj)) begin
      ecode = RDMA_ECODE_EC_RCE_CQC_INVLD;
      return;
    end
    case (opcode)
      RDMA_OP_CQC_MODIFY: obj.modify_word = rdma_be::qword(sqe, 0);
      RDMA_OP_CQC_RESIZE: obj.resize_sqe = sqe;
      RDMA_OP_CQC_QUERY: begin
        foreach (obj.bytes[i])
          cqe[CQC_QUERY_OFFSET + i] = obj.bytes[i];
      end
      default: objects[RDMA_DEV_CQ].delete(cqn);
    endcase
  endfunction

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
  // 功能：DMA 读 size 字节到 out。
  // 输入/输出及副作用：读主机内存。
  // 失败/边界：DMA 失败返回其 status，out 为空。
  protected function rdma_status read_bytes(bit [63:0] iova, int unsigned size,
                                            output byte unsigned out[]);
    byte data[];
    rdma_status status;

    out = new[0];
    status = host_mem.dma_read(iova, size, data);
    if (!status.ok())
      return status;
    out = new[data.size()];
    foreach (data[i])
      out[i] = data[i];
    return status;
  endfunction

  // 功能：DMA 写 bytes。
  // 输入/输出及副作用：写主机内存。
  // 失败/边界：DMA 失败返回其 status。
  protected function rdma_status write_bytes(bit [63:0] iova, byte unsigned bytes[]);
    byte data[];

    data = new[bytes.size()];
    foreach (data[i])
      data[i] = bytes[i];
    return host_mem.dma_write(iova, data);
  endfunction
endclass
