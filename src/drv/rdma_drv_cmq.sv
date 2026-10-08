// 目录：驱动层 src/drv/rdma_drv_cmq.sv。
// 职责：cmq.c 的同步命令队列：create（4KiB 缓冲，SQ 在前、CQ 在后，写 CMQC_HIGH/LOW）、
//   exec（填 VALID/WRAP/INDEX 信封与可选签名、写 SQE、敲 CMQ doorbell、轮询对应 CQE 并校验）。
//   驱动 xtrdma_process_cmq_cmd 对每条命令等待完成，故这里一次只有一条在途。
// 依赖：rdma_drv_hw、rdma_be、rdma_defs.svh。
// 所有权与生命周期：本对象拥有 CMQ 缓冲区；destroy 释放（驱动 destroy_cmq 不写寄存器）。
class rdma_drv_cmq extends uvm_object;
  `rdma_object_utils(rdma_drv_cmq)

  // cmq.h XTRDMA_CMQ_SQ_SIZE / XTRDMA_CMQ_CQ_SIZE。
  localparam int unsigned DEPTH = 32;
  localparam int unsigned CQ_OFFSET = DEPTH * RDMA_CMQE_BYTES;

  protected rdma_drv_hw hw;
  protected rdma_drv_dma mem_buf;
  protected longint unsigned pi;
  protected longint unsigned ci;
  // 轮询完成的间隔与上限（行为模型中设备在 doorbell 内同步完成，首轮即可见）。
  time poll_interval;
  int unsigned poll_limit;
  bit [7:0] last_ecode;

  // 功能：构造未创建的 CMQ。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：create 前 exec 返回 INVALID_STATE。
  function new(string name = "rdma_drv_cmq");
    super.new(name);
    hw = null;
    mem_buf = null;
    pi = 0;
    ci = 0;
    poll_interval = 10ns;
    poll_limit = 1000;
    last_ecode = '0;
  endfunction

  // 功能：xtrdma_create_cmq + xtrdma_sc_cmq_create：分配并清零缓冲，写 SQ 基址与使能。
  // 输入/输出及副作用：分配 DMA、写 CMQC_HIGH/LOW。
  // 失败/边界：分配或寄存器写失败返回错误并释放已分配缓冲。
  task create_cmq(rdma_drv_hw hw_arg, output rdma_status status);
    hw = hw_arg;
    pi = 0;
    ci = 0;
    status = hw.alloc_dma(4096, 4096, mem_buf);
    if (!status.ok())
      return;
    hw.notify(RDMA_DB_CMQC_HIGH_OFFSET, mem_buf.iova, status);
    if (status.ok())
      hw.notify(RDMA_DB_CMQC_LOW_OFFSET, 64'h8000_0000, status);
    if (!status.ok())
      void'(destroy());
  endtask

  // 功能：xtrdma_destroy_cmq：释放缓冲。
  // 输入/输出及副作用：释放 DMA。
  // 失败/边界：未创建视为成功。
  function rdma_status destroy();
    rdma_status status;

    status = rdma_status::success();
    if (hw != null && mem_buf != null)
      status = hw.free_dma(mem_buf);
    mem_buf = null;
    return status;
  endfunction

  // 功能：新建只含 opcode 的 64B SQE（其余字段由调用方按 cmq.c 填充函数写入）。
  // 输入/输出及副作用：返回新数组。
  // 失败/边界：任意 8 位 opcode 都会原样写入且不做支持性校验；信封位仍为零，提交前必须 seal。
  static function rdma_bytes_t new_sqe(bit [7:0] opcode);
    rdma_bytes_t sqe;

    sqe = rdma_be::zeros(RDMA_CMQE_BYTES);
    rdma_be::set_field(sqe, RDMA_CMQ_OPCODE_WORD_BYTE_OFFSET, RDMA_CMQ_OPCODE_LSB,
                       RDMA_CMQ_OPCODE_WIDTH, opcode);
    return sqe;
  endfunction

  // 功能：表驱动 opcode 的 SQE：字段表（由驱动填充函数生成）编码 body，写 opcode，再按 seal 填信封；
  //   只有 SD_UPDATE 在 sd_num>2 时（字段表置 sd_sign_en）按 xtrdma_sc_update_sd 对含信封的整条 SQE 与
  //   扩展 SD 表签名（其余表驱动 opcode 在 qword 8 的同一位置是业务字段）。
  // 输入/输出及副作用：sqe 输出完整 64B SQE。
  // 失败/边界：字段编码失败返回其 status。
  static function rdma_status compose_fields(bit [7:0] opcode, rdma_hw_cmq_field_body body,
                                             int unsigned idx, bit polarity,
                                             output rdma_bytes_t sqe);
    rdma_hw_cmq_field_codec codec;
    rdma_hw_image image;
    rdma_bytes_t extra;
    rdma_status status;
    bit sign;

    sqe = new[0];
    codec = rdma_hw_cmq_field_codec::type_id::create("drv_field_codec");
    status = codec.encode(opcode, body, image);
    if (!status.ok())
      return status;
    sqe = new[RDMA_CMQE_BYTES];
    foreach (sqe[i])
      sqe[i] = image.bytes[i];
    rdma_be::set_field(sqe, RDMA_CMQ_OPCODE_WORD_BYTE_OFFSET, RDMA_CMQ_OPCODE_LSB,
                       RDMA_CMQ_OPCODE_WIDTH, opcode);
    extra = new[0];
    sign = 1'b0;
    if (opcode == RDMA_OP_SD_UPDATE) begin
      sign = rdma_be::field(sqe, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET, RDMA_CMQ_SIGN_EN_LSB,
                            RDMA_CMQ_SIGN_EN_WIDTH);
      if (body.blobs.exists("sd_extra_data"))
        extra = body.blobs["sd_extra_data"];
    end
    seal(sqe, idx, polarity, sign, extra);
    return rdma_status::success();
  endfunction

  // 功能：填信封（VALID=polarity，WRAP=!polarity，INDEX=idx）；sign 时置 SIGN_EN 并按
  //   ~(SQE 全部字节异或 ^ extra 字节异或) 写签名（QPC 命令的 extra 为 512B QPC，SD_UPDATE 为扩展表）。
  // 输入/输出及副作用：修改 sqe。
  // 失败/边界：调用者须提供 64B SQE 和环深度内 idx；sign=0 时忽略 extra，字段写入按固定位宽截断。
  static function void seal(inout rdma_bytes_t sqe, input int unsigned idx, input bit polarity,
                            input bit sign, input rdma_bytes_t extra);
    bit [63:0] word0;

    word0 = rdma_be::qword(sqe, 0);
    word0[RDMA_CMQ_VALID_LSB] = polarity;
    word0[RDMA_CMQ_WRAP_LSB] = !polarity;
    word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] = idx;
    rdma_be::put_qword(sqe, 0, word0);
    if (!sign)
      return;
    rdma_be::set_field(sqe, RDMA_CMQ_SIGN_EN_WORD_BYTE_OFFSET, RDMA_CMQ_SIGN_EN_LSB,
                       RDMA_CMQ_SIGN_EN_WIDTH, 1);
    rdma_be::set_field(sqe, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET, RDMA_CMQ_SIGNATURE_LSB,
                       RDMA_CMQ_SIGNATURE_WIDTH, 0);
    rdma_be::set_field(sqe, RDMA_CMQ_SIGNATURE_WORD_BYTE_OFFSET, RDMA_CMQ_SIGNATURE_LSB,
                       RDMA_CMQ_SIGNATURE_WIDTH,
                       ~(rdma_be::xor_bytes(sqe) ^ rdma_be::xor_bytes(extra)));
  endfunction

  // 功能：执行表驱动 opcode（见 compose_fields），信封取当前生产者位置。
  // 输入/输出及副作用：同 submit。
  // 失败/边界：字段编码失败返回其 status；其余同 submit。
  task exec_fields(bit [7:0] opcode, rdma_hw_cmq_field_body body, output rdma_bytes_t cqe,
                   output rdma_status status);
    rdma_bytes_t sqe;

    cqe = new[0];
    status = compose_fields(opcode, body, pi % DEPTH, !((pi / DEPTH) & 1), sqe);
    if (status.ok())
      submit(sqe, cqe, status);
  endtask

  // 功能：执行一条命令（不带签名）。
  // 输入/输出及副作用：同 exec_signed。
  // 失败/边界：同 exec_signed。
  task exec(rdma_bytes_t sqe, output rdma_bytes_t cqe, output rdma_status status);
    rdma_bytes_t none;

    exec_signed(sqe, 1'b0, none, cqe, status);
  endtask

  // 功能：执行一条命令：按当前生产者位置 seal（见 seal）后提交。
  // 输入/输出及副作用：同 submit。
  // 失败/边界：同 submit。
  task exec_signed(rdma_bytes_t sqe, bit sign, rdma_bytes_t extra, output rdma_bytes_t cqe,
                   output rdma_status status);
    seal(sqe, pi % DEPTH, !((pi / DEPTH) & 1), sign, extra);
    submit(sqe, cqe, status);
  endtask

  // 功能：提交已 seal 的 SQE：写到生产者槽、PI 加一并敲 doorbell，轮询 CQE。
  // 输入/输出及副作用：写 CMQ 环与 doorbell；cqe 输出完成字节；last_ecode 记录 ecode。
  // 失败/边界：未创建返回 INVALID_STATE；超时返回 TIMEOUT；CQE 回显不符返回 CODEC_ERROR；
  //   ecode 非 0 返回 UNKNOWN_HW_ERROR。
  task submit(rdma_bytes_t sqe, output rdma_bytes_t cqe, output rdma_status status);
    bit [63:0] db;
    int unsigned idx;

    cqe = new[0];
    if (mem_buf == null) begin
      status = rdma_status::make(RDMA_SC_INVALID_STATE, "CMQ is not created");
      return;
    end
    idx = pi % DEPTH;
    status = hw.write(mem_buf, idx * RDMA_CMQE_BYTES, sqe);
    if (!status.ok())
      return;
    pi++;
    db = '0;
    db[RDMA_CMQ_DB_PI_LSB +: RDMA_CMQ_DB_PI_WIDTH] = pi % DEPTH;
    db[RDMA_CMQ_DB_POLARITY_LSB] = (pi / DEPTH) & 1;
    hw.notify(RDMA_DB_CMQ_OFFSET, db, status);
    if (!status.ok())
      return;
    poll_cqe(rdma_be::qword(sqe, 0), cqe, status);
  endtask

  // 功能：xtrdma_sc_cmq_next_cqe_valid + xtrdma_get_cqe_common_info：等待第 ci 个 CQE 的 owner
  //   与当前圈一致，校验 wrap/index/opcode 回显并取 ecode。
  // 输入/输出及副作用：读 CQ 环，推进 ci。
  // 失败/边界：超时、回显不符或 ecode 非 0 返回错误。
  protected task poll_cqe(bit [63:0] sqe_word0, output rdma_bytes_t cqe,
                          output rdma_status status);
    bit [63:0] head;

    head = '0;
    for (int unsigned n = 0; n <= poll_limit; n++) begin
      status = hw.read(mem_buf, CQ_OFFSET + (ci % DEPTH) * RDMA_CMQE_BYTES, RDMA_CMQE_BYTES, cqe);
      if (!status.ok())
        return;
      head = rdma_be::qword(cqe, 0);
      if (head[RDMA_CMQ_VALID_LSB] == !((ci / DEPTH) & 1))
        break;
      if (n == poll_limit) begin
        status = rdma_status::make(RDMA_SC_TIMEOUT, "CMQ completion did not arrive");
        return;
      end
      #(poll_interval);
    end
    ci++;
    if (head[RDMA_CMQ_WRAP_LSB] != sqe_word0[RDMA_CMQ_WRAP_LSB] ||
        head[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] !=
        sqe_word0[RDMA_CMQ_WQE_INDEX_LSB +: RDMA_CMQ_WQE_INDEX_WIDTH] ||
        head[RDMA_CMQ_OPCODE_LSB +: 8] != sqe_word0[RDMA_CMQ_OPCODE_LSB +: 8]) begin
      status = rdma_status::make(RDMA_SC_CODEC_ERROR, "CMQ completion does not echo the request");
      return;
    end
    last_ecode = head[RDMA_CMQ_CMD_ECODE_LSB +: 8];
    if (last_ecode != RDMA_CMQ_SUCCESS_ECODE)
      status = rdma_status::make(RDMA_SC_UNKNOWN_HW_ERROR,
                                 $sformatf("CMQ opcode %02h failed with ecode %02h",
                                           head[RDMA_CMQ_OPCODE_LSB +: 8], last_ecode));
  endtask
endclass
