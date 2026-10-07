// 目录/层次：协议与资源模型层 model/rdma_semantic_requests.sv。
// 职责：定义语义层的 QP 状态/WR/网络/CMQ opcode 枚举、AETH syndrome，以及语义报文 rdma_packet。
// 依赖：rdma_status；不访问硬件或外部资源。
// 所有权与生命周期：报文对象拥有自身字段。

typedef enum bit [3:0] {
  RDMA_QPS_RESET = 4'd0,
  RDMA_QPS_INIT  = 4'd1,
  RDMA_QPS_RTR   = 4'd2,
  RDMA_QPS_RTS   = 4'd3,
  RDMA_QPS_SQD   = 4'd4,
  RDMA_QPS_SQE   = 4'd5,
  RDMA_QPS_ERROR = 4'd6
} rdma_qp_state_e;

typedef enum bit [4:0] {
  RDMA_WR_SEND            = 5'd0,
  RDMA_WR_SEND_WITH_IMM   = 5'd1,
  RDMA_WR_RDMA_WRITE      = 5'd2,
  RDMA_WR_WRITE_WITH_IMM  = 5'd3,
  RDMA_WR_RDMA_READ       = 5'd4,
  RDMA_WR_ATOMIC_CMP_SWAP = 5'd5,
  RDMA_WR_ATOMIC_FETCH_ADD= 5'd6,
  RDMA_WR_LOCAL_INVALIDATE= 5'd7,
  RDMA_WR_RECV            = 5'd8,
  RDMA_WR_SEND_WITH_INV   = 5'd9,
  RDMA_WR_REG_MR          = 5'd10,
  RDMA_WR_BIND_MW         = 5'd11,
  RDMA_WR_FLUSH           = 5'd12
} rdma_work_opcode_e;

typedef enum bit [1:0] {
  RDMA_TIMEOUT_NONE   = 2'd0,
  RDMA_TIMEOUT_CYCLES = 2'd1,
  RDMA_TIMEOUT_TIME   = 2'd2
} rdma_timeout_policy_e;

typedef enum bit [4:0] {
  RDMA_NET_SEND             = 5'd0,
  RDMA_NET_SEND_WITH_IMM    = 5'd1,
  RDMA_NET_RDMA_WRITE       = 5'd2,
  RDMA_NET_WRITE_WITH_IMM   = 5'd3,
  RDMA_NET_RDMA_READ_REQUEST= 5'd4,
  RDMA_NET_RDMA_READ_RESP   = 5'd5,
  RDMA_NET_ACK              = 5'd6,
  RDMA_NET_NAK              = 5'd7,
  // RC 原子请求使用 RoCEv2 AtomicETH；保留独立语义值，禁止降级为 SEND。
  RDMA_NET_ATOMIC_CMP_SWAP  = 5'd8,
  RDMA_NET_ATOMIC_FETCH_ADD = 5'd9,
  // RC 原子响应携带 Atomic ACK ETH 的原始值，供 responder 完成语义闭环。
  RDMA_NET_ATOMIC_ACK       = 5'd10
} rdma_network_opcode_e;

// 多包消息中报文的位置；单包消息为 ONLY。与 opcode 组合决定 BTH opcode 与扩展头。
typedef enum bit [1:0] {
  RDMA_SEG_ONLY   = 2'd0,
  RDMA_SEG_FIRST  = 2'd1,
  RDMA_SEG_MIDDLE = 2'd2,
  RDMA_SEG_LAST   = 2'd3
} rdma_packet_segment_e;

// AETH syndrome：bit[7:5] 为类型（000 ACK、001 RNR NAK、011 NAK），ACK 的 bit[4:0] 为信用值；
//   设备不做端到端信用，ACK 填 0x1F（信用无效，IBTA 9.7.5.1.2，与 Linux rxe 一致）；
//   NAK 为 0x60|code，code 3 表示 remote access error。
localparam bit [7:0] RDMA_AETH_ACK = 8'h1f;
localparam bit [7:0] RDMA_AETH_NAK_REMOTE_ACCESS = 8'h62;
// RNR NAK（timer 字段取 0）。
localparam bit [7:0] RDMA_AETH_RNR_NAK = 8'h20;
localparam bit [7:0] RDMA_AETH_NAK_INVALID_REQUEST = 8'h61;
localparam bit [7:0] RDMA_AETH_NAK_REMOTE_OPERATIONAL = 8'h63;
// PSN 序列错误 NAK（NAK code 0）：响应方期望的 PSN 放在 BTH.PSN。
localparam bit [7:0] RDMA_AETH_NAK_PSN_SEQ = 8'h60;

typedef enum bit [5:0] {
  RDMA_CMQ_CREATE_PD  = 6'd0,
  RDMA_CMQ_REGISTER_MR= 6'd1,
  RDMA_CMQ_CREATE_CQ  = 6'd2,
  RDMA_CMQ_CREATE_QP  = 6'd3,
  RDMA_CMQ_CREATE_SRQ = 6'd4,
  RDMA_CMQ_CREATE_CEQ = 6'd5,
  RDMA_CMQ_CREATE_AEQ = 6'd6,
  RDMA_CMQ_DESTROY    = 6'd7,
  RDMA_CMQ_MODIFY_QP  = 6'd8,
  RDMA_CMQ_QUERY      = 6'd9
} rdma_cmq_opcode_e;


class rdma_packet extends uvm_object;
  `rdma_object_utils(rdma_packet)

  rdma_transport_e transport;
  rdma_network_opcode_e opcode;
  rdma_packet_segment_e segment;
  bit [23:0] destination_qpn;
  bit [23:0] source_qpn;
  bit [23:0] psn;
  // BTH AckReq：请求方要求响应方对本包回 ACK（RC SEND/WRITE 的末包置位；IBTA 9.7.2）。
  bit ack_req;
  // header_bytes 是 BTH 之后扩展头的线上字节（IBTA 顺序：RETH、AETH、AtomicETH、
  //   AtomicAckETH、ImmDt），由 pack_headers()/unpack_headers() 与下列结构化字段互转。
  byte unsigned header_bytes[$];
  bit [63:0] reth_va;
  bit [31:0] reth_rkey;
  bit [31:0] reth_len;
  bit [7:0] aeth_syndrome;
  bit [23:0] aeth_msn;
  bit [31:0] imm;
  bit [63:0] atomic_va;
  bit [31:0] atomic_rkey;
  bit [63:0] atomic_swap_add;
  bit [63:0] atomic_compare;
  bit [63:0] atomic_orig;
  // UD 的 DETH Q_Key（源 QPN 即 source_qpn）。
  bit [31:0] deth_qkey;
  string metadata[$];
  byte unsigned payload[$];

  // 功能：构造网络包，默认 RC、SEND、ONLY，QPN/PSN 与扩展头清零。
  // 输入/输出及副作用：name 为 UVM 实例名；仅初始化本地字段。
  // 失败/边界：无。
  function new(string name = "rdma_packet");
    super.new(name);
    transport = RDMA_TRANSPORT_RC;
    opcode = RDMA_NET_SEND;
    segment = RDMA_SEG_ONLY;
    destination_qpn = '0;
    source_qpn = '0;
    psn = '0;
    ack_req = 1'b0;
    reth_va = '0;
    reth_rkey = '0;
    reth_len = '0;
    aeth_syndrome = '0;
    aeth_msn = '0;
    imm = '0;
    atomic_va = '0;
    atomic_rkey = '0;
    atomic_swap_add = '0;
    atomic_compare = '0;
    atomic_orig = '0;
    deth_qkey = '0;
  endfunction

  // 功能：判断报文是否携带 RETH（WRITE 首/单包与 READ 请求）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_reth();
    return (opcode inside {RDMA_NET_RDMA_WRITE, RDMA_NET_WRITE_WITH_IMM} &&
            segment inside {RDMA_SEG_FIRST, RDMA_SEG_ONLY}) ||
           opcode == RDMA_NET_RDMA_READ_REQUEST;
  endfunction

  // 功能：判断报文是否携带 AETH（READ 响应首/尾/单包、ACK/NAK、ATOMIC ACK）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_aeth();
    return (opcode == RDMA_NET_RDMA_READ_RESP && segment != RDMA_SEG_MIDDLE) ||
           opcode inside {RDMA_NET_ACK, RDMA_NET_NAK, RDMA_NET_ATOMIC_ACK};
  endfunction

  // 功能：判断报文是否携带 AtomicETH（CMP_SWAP/FETCH_ADD 请求）。
  // 输入/输出及副作用：只读 opcode。
  // 失败/边界：无。
  function bit has_atomic_eth();
    return opcode inside {RDMA_NET_ATOMIC_CMP_SWAP, RDMA_NET_ATOMIC_FETCH_ADD};
  endfunction

  // 功能：判断报文是否携带 ImmDt（带立即数的 SEND/WRITE 尾包或单包）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function bit has_immdt();
    return opcode inside {RDMA_NET_SEND_WITH_IMM, RDMA_NET_WRITE_WITH_IMM} &&
           segment inside {RDMA_SEG_LAST, RDMA_SEG_ONLY};
  endfunction

  // 功能：按 opcode/segment 计算扩展头总长度（与 pack_headers 一致）。
  // 输入/输出及副作用：只读 opcode/segment。
  // 失败/边界：无。
  function int unsigned header_length();
    int unsigned n;

    n = 0;
    if (has_reth())
      n += 16;
    if (has_aeth())
      n += 4;
    if (has_atomic_eth())
      n += 28;
    if (opcode == RDMA_NET_ATOMIC_ACK)
      n += 8;
    if (has_immdt())
      n += 4;
    return n;
  endfunction

  // 功能：按 IBTA 顺序把结构化扩展头序列化为 header_bytes（大端）。
  // 输入/输出及副作用：覆盖 header_bytes。
  // 失败/边界：无；不携带的头不输出。
  function void pack_headers();
    header_bytes.delete();
    if (has_reth()) begin
      put_be(reth_va, 8);
      put_be(reth_rkey, 4);
      put_be(reth_len, 4);
    end
    if (has_aeth())
      put_be({aeth_syndrome, aeth_msn}, 4);
    if (has_atomic_eth()) begin
      put_be(atomic_va, 8);
      put_be(atomic_rkey, 4);
      put_be(atomic_swap_add, 8);
      put_be(atomic_compare, 8);
    end
    if (opcode == RDMA_NET_ATOMIC_ACK)
      put_be(atomic_orig, 8);
    if (has_immdt())
      put_be(imm, 4);
  endfunction

  // 功能：从 header_bytes 解析结构化扩展头。
  // 输入/输出及副作用：写入 reth/aeth/atomic/imm 字段。
  // 失败/边界：字节不足时返回 0，已解析字段保持部分更新。
  function bit unpack_headers();
    int unsigned offset;
    bit [63:0] v;

    offset = 0;
    if (has_reth()) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      reth_va = v;
      if (!get_be(offset, 4, v))
        return 1'b0;
      reth_rkey = v[31:0];
      if (!get_be(offset, 4, v))
        return 1'b0;
      reth_len = v[31:0];
    end
    if (has_aeth()) begin
      if (!get_be(offset, 4, v))
        return 1'b0;
      aeth_syndrome = v[31:24];
      aeth_msn = v[23:0];
    end
    if (has_atomic_eth()) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_va = v;
      if (!get_be(offset, 4, v))
        return 1'b0;
      atomic_rkey = v[31:0];
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_swap_add = v;
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_compare = v;
    end
    if (opcode == RDMA_NET_ATOMIC_ACK) begin
      if (!get_be(offset, 8, v))
        return 1'b0;
      atomic_orig = v;
    end
    if (has_immdt()) begin
      if (!get_be(offset, 4, v))
        return 1'b0;
      imm = v[31:0];
    end
    return 1'b1;
  endfunction

  // 功能：把 value 的低 bytes 个字节按大端追加到 header_bytes。
  // 输入/输出及副作用：追加 header_bytes。
  // 失败/边界：bytes 超过 8 时只取低 8 字节。
  protected function void put_be(bit [63:0] value, int unsigned bytes);
    for (int i = int'(bytes) - 1; i >= 0; i--)
      header_bytes.push_back(value >> (8 * i));
  endfunction

  // 功能：从 header_bytes[offset] 读取 bytes 个大端字节到 value，并推进 offset。
  // 输入/输出及副作用：offset 为 inout 游标，value 输出。
  // 失败/边界：剩余字节不足时返回 0，offset 与 value 不变。
  protected function bit get_be(
    inout int unsigned offset,
    input int unsigned bytes,
    output bit [63:0] value
  );
    value = '0;
    if (offset + bytes > header_bytes.size())
      return 1'b0;
    for (int unsigned i = 0; i < bytes; i++)
      value = (value << 8) | header_bytes[offset + i];
    offset += bytes;
    return 1'b1;
  endfunction

  // 功能：复制网络包全部值字段（含扩展头、metadata、payload）。
  // 输入/输出及副作用：rhs 为源对象；覆盖本对象字段，源不变。
  // 失败/边界：类型不符触发 UVM fatal（packet copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_packet rhs_packet;

    super.do_copy(rhs);
    if (!$cast(rhs_packet, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "packet copy type mismatch")
    transport = rhs_packet.transport;
    opcode = rhs_packet.opcode;
    segment = rhs_packet.segment;
    destination_qpn = rhs_packet.destination_qpn;
    source_qpn = rhs_packet.source_qpn;
    psn = rhs_packet.psn;
    ack_req = rhs_packet.ack_req;
    header_bytes = rhs_packet.header_bytes;
    reth_va = rhs_packet.reth_va;
    reth_rkey = rhs_packet.reth_rkey;
    reth_len = rhs_packet.reth_len;
    aeth_syndrome = rhs_packet.aeth_syndrome;
    aeth_msn = rhs_packet.aeth_msn;
    imm = rhs_packet.imm;
    atomic_va = rhs_packet.atomic_va;
    atomic_rkey = rhs_packet.atomic_rkey;
    atomic_swap_add = rhs_packet.atomic_swap_add;
    atomic_compare = rhs_packet.atomic_compare;
    atomic_orig = rhs_packet.atomic_orig;
    deth_qkey = rhs_packet.deth_qkey;
    metadata = rhs_packet.metadata;
    payload = rhs_packet.payload;
  endfunction
endclass
